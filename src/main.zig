//! Executable entry point. Thin init/render/shutdown glue.
//! Pure math lives in `fractal/`, GPU edge in `gpu/`, ImGui layout in `ui/`.
//!
//! T6 additions: mouse/keyboard navigation (box-select, pan, scroll-zoom,
//! right-click zoom menu), hover coordinate readout, and coarse→fine recompute
//! driven by the pure `refine.PassDecision` helper.
const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const c = @import("c.zig").c;
const ig = @import("cimgui.zig");
const gpu = @import("gpu/device.zig");
const ui_mod = @import("ui/imgui.zig");
const viewport = @import("fractal/viewport.zig");
const navigate = @import("fractal/navigate.zig");
const engine_mod = @import("fractal/engine.zig");
const texture_mod = @import("gpu/texture.zig");
const compute_mod = @import("gpu/compute.zig");
const stats_mod = @import("ui/stats.zig");
const editor_mod = @import("ui/editor.zig");
const panels = @import("ui/panels.zig");
const refine = @import("fractal/refine.zig");

const app_log = std.log.scoped(.app);

/// Module-level compute pipeline so the IterFn (which has no closure) can reach it.
var g_compute_pipeline: ?compute_mod.ComputePipeline = null;

/// The IterFn wired into engine.gpu_iter_fn when GPU mode is enabled.
fn gpuIterFn(
    view: viewport.SquareView,
    image_side: u32,
    max_iter: u32,
    iter: []f32,
) anyerror!void {
    const pl = g_compute_pipeline orelse return error.GpuPipelineNotReady;
    try compute_mod.gpuIterate(pl, view, image_side, max_iter, iter);
}

const window_title = "fractalforge";
const initial_window_w = 1280;
const initial_window_h = 720;

pub fn main() !void {
    var buf: [128]u8 = undefined;
    const banner = try root.startupLine(&buf, builtin.zig_version_string);
    app_log.info("{s}", .{banner});

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        app_log.err("SDL_Init failed: {s}", .{std.mem.span(c.SDL_GetError())});
        return error.SdlInitFailed;
    }
    defer c.SDL_Quit();

    // T5: window is resizable so the user can change S = min(window_w, window_h).
    const window = c.SDL_CreateWindow(window_title, initial_window_w, initial_window_h, c.SDL_WINDOW_RESIZABLE) orelse {
        app_log.err("SDL_CreateWindow failed: {s}", .{std.mem.span(c.SDL_GetError())});
        return error.SdlWindowCreationFailed;
    };
    defer c.SDL_DestroyWindow(window);

    const device = try gpu.Device.create(window);
    defer device.destroy();

    // Initialize the Metal compute pipeline for GPU iteration (M4).
    // Failure is non-fatal: the GPU checkbox in the UI will be disabled if null.
    g_compute_pipeline = compute_mod.ComputePipeline.create(device.handle) catch |err| blk: {
        app_log.warn("GPU compute pipeline init failed ({s}); GPU mode unavailable", .{@errorName(err)});
        break :blk null;
    };
    defer if (g_compute_pipeline) |pl| pl.destroy();

    const ui = try ui_mod.Ui.init(window, device);
    defer ui.shutdown();

    // T5: read initial window size and compute the letterboxed image rect.
    // Use the approximate fractal region width (full width minus data panel + spacing).
    var win_w: c_int = 0;
    var win_h: c_int = 0;
    _ = c.SDL_GetWindowSize(window, &win_w, &win_h);
    const panel_taken: u32 = @as(u32, @intFromFloat(panels.data_panel_w + panels.region_spacing));
    const fractal_w_init: u32 = if (@as(u32, @intCast(win_w)) > panel_taken) @as(u32, @intCast(win_w)) - panel_taken else 1;
    var image_rect = viewport.computeImageRect(fractal_w_init, @intCast(win_h));
    const initial_S = image_rect.side;

    if (initial_S == 0) {
        app_log.err("startup window has zero side (S=0); cannot initialise the engine", .{});
        return error.DegenerateWindowSize;
    }

    // Engine: holds the view, S, policy, iteration buffer, RGBA output.
    const view = viewport.SquareView.defaultView();
    const vp = view.imageViewport(initial_S);
    var engine = engine_mod.Engine.init(std.heap.page_allocator, view, initial_S, .{}) catch |err| {
        app_log.err("color engine init failed ({s}); aborting startup", .{@errorName(err)});
        return err;
    };
    defer engine.deinit();
    // Wire GPU iteration function if the pipeline is available (M4).
    if (g_compute_pipeline != null) {
        engine.gpu_iter_fn = gpuIterFn;
    }

    var iterate_timer = std.time.Timer.start() catch null;
    engine.iterate() catch |err| {
        app_log.err("CPU Mandelbrot iteration failed ({s}); aborting startup", .{@errorName(err)});
        return err;
    };
    const iterate_ns = if (iterate_timer) |*t| t.read() else 0;

    var texture = try texture_mod.createRgbaTexture(device.handle, initial_S, initial_S);
    defer texture.destroy();
    try texture_mod.upload(device.handle, texture, engine.output());

    var summary_buf: [128]u8 = undefined;
    const summary = try stats_mod.renderSummary(&summary_buf, initial_S, initial_S, engine.max_iter, iterate_ns);
    app_log.info("{s}", .{summary});
    var color_buf: [96]u8 = undefined;
    if (engine.summary(&color_buf)) |line| app_log.info("{s}", .{line}) else |_| {}

    var app_stats = stats_mod.Stats.fromRender(iterate_ns);
    var editor = editor_mod.Editor.initDefault();
    var view_editor = editor_mod.ViewEditor.initFromView(engine.view);

    app_log.info("entering event loop", .{});
    runLoop(window, device, ui, &texture, vp, &image_rect, &app_stats, &engine, &editor, &view_editor);
    app_log.info("event loop exited; shutting down cleanly", .{});
}

// ─── Navigation state ─────────────────────────────────────────────────────────

/// Box-select drag state.
const DragState = enum { none, active };

const history_cap = 64;

/// All navigation state for one run of the event loop. No globals.
const NavState = struct {
    /// Whether a left-drag box-select is in progress.
    drag_state: DragState = .none,
    /// Image-space pixel where the left button went down (box-select start).
    drag_start_px: viewport.Pixel = .{ .x = 0.0, .y = 0.0 },
    /// Window-space position where the left button went down (rubber-band drawing).
    drag_start_win_x: f32 = 0.0,
    drag_start_win_y: f32 = 0.0,

    /// Stashed complex point for the right-click context menu.
    right_click_pt: viewport.Complex = .{ .re = -0.75, .im = 0.0 },
    /// Whether to open the right-click popup this frame.
    open_ctx_menu: bool = false,

    /// Whether the full-res pass has been run for the current view.
    /// `true` at startup (the initial iterate counts as a full pass).
    full_pass_done: bool = true,

    /// Timer measuring idle time since the last navigation action.
    idle_timer: ?std.time.Timer = null,

    /// Undo/redo history. `undo_buf[0..undo_len]` are views we can return to
    /// (most-recent-first). `redo_buf[0..redo_len]` are views popped by undo.
    undo_buf: [history_cap]viewport.SquareView = undefined,
    undo_len: usize = 0,
    redo_buf: [history_cap]viewport.SquareView = undefined,
    redo_len: usize = 0,
};

/// Push `old_view` onto the undo stack before committing a new view.
/// Clears the redo stack (a new navigation invalidates the redo chain).
fn historyPush(nav: *NavState, old_view: viewport.SquareView) void {
    if (nav.undo_len < history_cap) {
        nav.undo_buf[nav.undo_len] = old_view;
        nav.undo_len += 1;
    } else {
        // Shift oldest entry out to make room (FIFO eviction at the bottom).
        std.mem.copyForwards(viewport.SquareView, nav.undo_buf[0 .. history_cap - 1], nav.undo_buf[1..history_cap]);
        nav.undo_buf[history_cap - 1] = old_view;
    }
    nav.redo_len = 0;
}

/// Undo: restore the most recent view on the undo stack, push current onto redo.
fn historyUndo(
    device: gpu.Device,
    texture: *texture_mod.Texture,
    engine: *engine_mod.Engine,
    nav: *NavState,
    view_editor: *editor_mod.ViewEditor,
) void {
    if (nav.undo_len == 0) return;
    const prev = nav.undo_buf[nav.undo_len - 1];
    nav.undo_len -= 1;
    // Push current view onto redo (without clearing undo — just redo).
    if (nav.redo_len < history_cap) {
        nav.redo_buf[nav.redo_len] = engine.view;
        nav.redo_len += 1;
    }
    engine.setViewport(prev) catch |err| {
        app_log.err("undo rejected ({s})", .{@errorName(err)});
        return;
    };
    texture_mod.upload(device.handle, texture.*, engine.output()) catch |err| {
        app_log.err("undo re-upload failed ({s})", .{@errorName(err)});
    };
    nav.full_pass_done = false;
    nav.idle_timer = std.time.Timer.start() catch null;
    view_editor.syncFromView(engine.view);
}

/// Redo: restore the most recent undone view.
fn historyRedo(
    device: gpu.Device,
    texture: *texture_mod.Texture,
    engine: *engine_mod.Engine,
    nav: *NavState,
    view_editor: *editor_mod.ViewEditor,
) void {
    if (nav.redo_len == 0) return;
    const next = nav.redo_buf[nav.redo_len - 1];
    nav.redo_len -= 1;
    if (nav.undo_len < history_cap) {
        nav.undo_buf[nav.undo_len] = engine.view;
        nav.undo_len += 1;
    }
    engine.setViewport(next) catch |err| {
        app_log.err("redo rejected ({s})", .{@errorName(err)});
        return;
    };
    texture_mod.upload(device.handle, texture.*, engine.output()) catch |err| {
        app_log.err("redo re-upload failed ({s})", .{@errorName(err)});
    };
    nav.full_pass_done = false;
    nav.idle_timer = std.time.Timer.start() catch null;
    view_editor.syncFromView(engine.view);
}

// ─── View-change helpers ───────────────────────────────────────────────────────

/// Apply a new view with an immediate coarse (S/4) pass and upload.
/// `real_s` is the full-resolution side we want to restore for the full pass.
/// On success marks full_pass_done=false and starts the idle timer.
fn applyViewCoarse(
    device: gpu.Device,
    texture: *texture_mod.Texture,
    engine: *engine_mod.Engine,
    nav: *NavState,
    new_view: viewport.SquareView,
    real_s: u32,
    view_editor: *editor_mod.ViewEditor,
) void {
    historyPush(nav, engine.view);

    // Coarse side: S/4, minimum 1.
    const coarse_s = @max(real_s / 4, 1);

    // Resize to coarse if the engine is at a different size.
    if (engine.image_side != coarse_s) {
        engine.resize(coarse_s) catch |err| {
            app_log.err("coarse resize to {d} failed ({s})", .{ coarse_s, @errorName(err) });
            // Fall through: setViewport at the current size still gives feedback.
        };
    }

    // Install the new view (re-iterates at whatever size the engine is now).
    engine.setViewport(new_view) catch |err| {
        app_log.err("navigation rejected ({s}); keeping previous view", .{@errorName(err)});
        // Attempt to restore real_s so we aren't stuck at coarse.
        if (engine.image_side != real_s) {
            engine.resize(real_s) catch {};
        }
        return;
    };

    texture_mod.upload(device.handle, texture.*, engine.output()) catch |err| {
        app_log.err("coarse re-upload failed ({s})", .{@errorName(err)});
    };

    // Warn if the new view crossed the precision floor.
    if (navigate.atPrecisionFloor(new_view)) {
        var floor_buf: [navigate.floor_message_buf_len]u8 = undefined;
        if (navigate.precisionFloorMessage(&floor_buf, new_view.side)) |msg| {
            app_log.warn("{s}", .{msg});
        } else |_| {}
    }

    view_editor.syncFromView(engine.view);
    nav.full_pass_done = false;
    nav.idle_timer = std.time.Timer.start() catch null;
}

/// Run the full-resolution pass: resize the engine back to real_s, re-upload.
/// Engine.resize already re-iterates at the current view, so no setViewport needed.
fn runFullPass(
    device: gpu.Device,
    texture: *texture_mod.Texture,
    engine: *engine_mod.Engine,
    nav: *NavState,
    real_s: u32,
    view_editor: *editor_mod.ViewEditor,
) void {
    // If the engine is already at real_s (e.g. coarse_s == real_s for tiny windows)
    // skip the resize; the iteration was already done.
    if (engine.image_side != real_s) {
        engine.resize(real_s) catch |err| {
            app_log.err("full-res resize to {d} failed ({s}); display stays coarse", .{ real_s, @errorName(err) });
            nav.full_pass_done = true; // don't hammer on failure
            return;
        };
    }

    texture_mod.upload(device.handle, texture.*, engine.output()) catch |err| {
        app_log.err("full-res re-upload failed ({s})", .{@errorName(err)});
    };

    view_editor.syncFromView(engine.view);
    nav.full_pass_done = true;
    app_log.info("full-res pass complete: S={d}", .{real_s});
}

// ─── Main event / render loop ─────────────────────────────────────────────────

/// Pump events and render the single fixed window each frame until quit.
/// T6: adds navigation input, coarse→fine dispatch, and hover readout.
/// T7: adds coord panel with `view_editor`.
fn runLoop(
    window: *c.SDL_Window,
    device: gpu.Device,
    ui: ui_mod.Ui,
    texture: *texture_mod.Texture,
    vp: viewport.Viewport,
    image_rect: *viewport.ImageRect,
    app_stats: *stats_mod.Stats,
    engine: *engine_mod.Engine,
    editor: *editor_mod.Editor,
    view_editor: *editor_mod.ViewEditor,
) void {
    var frame_timer: ?std.time.Timer = std.time.Timer.start() catch |err| blk: {
        app_log.warn("frame timer unavailable ({s}); frame ms will read 0", .{@errorName(err)});
        break :blk null;
    };

    var nav = NavState{};
    // Track the full-resolution S independently of engine.image_side (which may be
    // at coarse size during a drag).
    var real_s: u32 = engine.image_side;

    var running = true;
    while (running) {
        if (frame_timer) |*t| t.reset();

        // ── SDL event pump ────────────────────────────────────────────────────
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            _ = ui.processEvent(&event);
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                    if (event.window.windowID == c.SDL_GetWindowID(window)) running = false;
                },
                // T5: resize recomputes S, engine buffers, and GPU texture.
                // After a resize, real_s follows the new S (it is already full-res).
                c.SDL_EVENT_WINDOW_RESIZED => {
                    handleResize(device, texture, image_rect, engine, @intCast(event.window.data1), @intCast(event.window.data2));
                    real_s = engine.image_side;
                    nav.full_pass_done = true; // resize already ran a full pass
                    view_editor.syncFromView(engine.view);
                },
                // Scroll-zoom: zoom toward the cursor point (plan A4).
                c.SDL_EVENT_MOUSE_WHEEL => {
                    if (event.wheel.y != 0.0) {
                        var mx: f32 = 0.0;
                        var my: f32 = 0.0;
                        _ = c.SDL_GetMouseState(&mx, &my);
                        const cursor = engine.view.cursorCoord(@floatCast(mx), @floatCast(my), image_rect.*);
                        if (cursor) |pt| {
                            const factor = if (event.wheel.y > 0.0)
                                navigate.zoom_step_in
                            else
                                navigate.zoom_step_out;
                            const new_view = navigate.zoomAbout(engine.view, pt, factor) catch null;
                            if (new_view) |v|
                                applyViewCoarse(device, texture, engine, &nav, v, real_s, view_editor);
                        }
                    }
                },
                // Right mouse button down: stash the cursor point for the context menu.
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    if (event.button.button == c.SDL_BUTTON_RIGHT) {
                        const cursor = engine.view.cursorCoord(@floatCast(event.button.x), @floatCast(event.button.y), image_rect.*);
                        if (cursor) |pt| {
                            nav.right_click_pt = pt;
                            nav.open_ctx_menu = true;
                        }
                    }
                },
                // Ctrl+Z = undo, Ctrl+Y = redo.
                c.SDL_EVENT_KEY_DOWN => {
                    const mods = c.SDL_GetModState();
                    const ctrl = (mods & c.SDL_KMOD_CTRL) != 0;
                    if (ctrl) {
                        if (event.key.scancode == c.SDL_SCANCODE_Z) {
                            historyUndo(device, texture, engine, &nav, view_editor);
                        } else if (event.key.scancode == c.SDL_SCANCODE_Y) {
                            historyRedo(device, texture, engine, &nav, view_editor);
                        }
                    }
                },
                else => {},
            }
        }

        // ── ImGui frame ───────────────────────────────────────────────────────
        ui.newFrame();

        // Compute hover point before building the UI so the status bar can use it.
        var mx: f32 = 0.0;
        var my: f32 = 0.0;
        _ = c.SDL_GetMouseState(&mx, &my);
        const hover_pt = engine.view.cursorCoord(@floatCast(mx), @floatCast(my), image_rect.*);

        var quit_requested = false;
        // open_ctx_menu and right_click_pt are consumed inside draw (popup lives there).
        const draw_result = panels.draw(
            device.handle,
            texture.*,
            vp,
            engine.max_iter,
            app_stats.*,
            engine,
            editor,
            view_editor,
            nav.open_ctx_menu,
            nav.right_click_pt,
            hover_pt,
            &quit_requested,
        );
        // Update image_rect from the live ImGui geometry every frame so coordinate
        // mapping and resize use the actual fractal region (not the OS window size).
        if (draw_result.image_rect.side > 0) image_rect.* = draw_result.image_rect;
        nav.open_ctx_menu = false;
        if (quit_requested) running = false;

        // Act on the context-menu selection.
        if (draw_result.ctx_action != .none) {
            const pt = nav.right_click_pt;
            const new_view: ?viewport.SquareView = switch (draw_result.ctx_action) {
                .zoom_in => navigate.zoomCentered(engine.view, pt, navigate.zoom_step_in) catch null,
                .zoom_out => navigate.zoomCentered(engine.view, pt, navigate.zoom_step_out) catch null,
                .center_here => viewport.SquareView.fromCenterSide(pt, engine.view.side) catch null,
                .none => null,
            };
            if (new_view) |v| applyViewCoarse(device, texture, engine, &nav, v, real_s, view_editor);
        }

        // Navigation ImGui input: box-select and pan.
        handleNavInput(device, texture, engine, &nav, image_rect.*, real_s, view_editor);

        ui.endFrame();

        // ── Coarse→fine pass decision ─────────────────────────────────────────
        // `interacting` = left dragging OR middle dragging OR Space+left dragging.
        const interacting = (nav.drag_state == .active) or
            ig.igIsMouseDragging(ig.mouse_button_middle, -1.0) or
            (ig.igIsKeyDown_Nil(ig.key_space) and ig.igIsMouseDragging(ig.mouse_button_left, -1.0));
        const idle_ns: u64 = if (nav.idle_timer) |*t| t.read() else 0;
        switch (refine.decidePass(interacting, idle_ns, nav.full_pass_done)) {
            .full => runFullPass(device, texture, engine, &nav, real_s, view_editor),
            .coarse, .none => {},
        }

        renderFrame(window, device, ui);

        if (frame_timer) |*t| app_stats.observeFrame(t.read());
    }
}

// ─── Per-frame navigation input ───────────────────────────────────────────────

/// Rubber-band rect colour: bright white, fully opaque (0xAABBGGRR in ImGui packing).
const drag_rect_col: ig.ImU32 = 0xFF_FF_FF_FF;

/// Process box-select (left-drag) and pan (middle-drag / Space+left-drag) for one frame.
fn handleNavInput(
    device: gpu.Device,
    texture: *texture_mod.Texture,
    engine: *engine_mod.Engine,
    nav: *NavState,
    rect: viewport.ImageRect,
    real_s: u32,
    view_editor: *editor_mod.ViewEditor,
) void {
    const space_held = ig.igIsKeyDown_Nil(ig.key_space);

    // ── Pan: middle-drag or Space+left-drag ───────────────────────────────────
    const mid_dragging = ig.igIsMouseDragging(ig.mouse_button_middle, -1.0);
    const space_left_dragging = space_held and ig.igIsMouseDragging(ig.mouse_button_left, -1.0);
    if (mid_dragging or space_left_dragging) {
        const btn: c_int = if (mid_dragging) ig.mouse_button_middle else ig.mouse_button_left;
        const delta = ig.igGetMouseDragDelta(btn, -1.0);
        // Navigate.panByPixels: "pass the NEGATED mouse delta" so content follows cursor.
        if (delta.x != 0.0 or delta.y != 0.0) {
            const new_view = navigate.panByPixels(
                engine.view,
                @floatCast(-delta.x),
                @floatCast(-delta.y),
                real_s,
            ) catch |err| blk: {
                app_log.warn("pan rejected ({s})", .{@errorName(err)});
                break :blk null;
            };
            if (new_view) |v| {
                applyViewCoarse(device, texture, engine, nav, v, real_s, view_editor);
                ig.igResetMouseDragDelta(btn);
            }
        }
    }

    // ── Box-select: left-drag without Space ───────────────────────────────────
    if (!space_held) {
        const left_down = ig.igIsMouseDown_Nil(ig.mouse_button_left);
        const left_dragging = ig.igIsMouseDragging(ig.mouse_button_left, -1.0);

        // Start: button just went down and the cursor is on the image.
        if (left_down and !left_dragging and nav.drag_state == .none) {
            var mx: f32 = 0.0;
            var my: f32 = 0.0;
            _ = c.SDL_GetMouseState(&mx, &my);
            const img_px = rect.toImagePixel(@floatCast(mx), @floatCast(my));
            if (img_px) |px| {
                nav.drag_state = .active;
                nav.drag_start_px = px;
                nav.drag_start_win_x = mx;
                nav.drag_start_win_y = my;
            }
        }

        // While dragging: draw rubber-band rectangle on the foreground draw list
        // (always valid, draws on top of all windows).
        if (nav.drag_state == .active and left_dragging) {
            var mx: f32 = 0.0;
            var my: f32 = 0.0;
            _ = c.SDL_GetMouseState(&mx, &my);
            if (ig.igGetForegroundDrawList_ViewportPtr(null)) |dl| {
                ig.ImDrawList_AddRect(
                    dl,
                    .{ .x = nav.drag_start_win_x, .y = nav.drag_start_win_y },
                    .{ .x = mx, .y = my },
                    drag_rect_col,
                    0.0,
                    1.5,
                    0,
                );
            }
        }

        // Commit on left-button release. Clamp the end point to the image boundary
        // so a drag that finishes outside the image still zooms to a valid region.
        if (nav.drag_state == .active and !left_down) {
            var ex: f32 = 0.0;
            var ey: f32 = 0.0;
            _ = c.SDL_GetMouseState(&ex, &ey);
            // Use toImagePixel first; if outside the rect, clamp to [0, side).
            const end_px: viewport.Pixel = rect.toImagePixel(@floatCast(ex), @floatCast(ey)) orelse blk: {
                if (real_s == 0) break :blk nav.drag_start_px;
                const s_f: f64 = @floatFromInt(real_s);
                const ox: f64 = @floatFromInt(rect.x);
                const oy: f64 = @floatFromInt(rect.y);
                break :blk .{
                    .x = @max(0.0, @min(s_f - 1.0, @as(f64, @floatCast(ex)) - ox)),
                    .y = @max(0.0, @min(s_f - 1.0, @as(f64, @floatCast(ey)) - oy)),
                };
            };
            const new_view = navigate.boxSelect(
                engine.view,
                nav.drag_start_px,
                end_px,
                real_s,
            ) catch |err| blk: {
                app_log.warn("box-select rejected ({s})", .{@errorName(err)});
                break :blk null;
            };
            if (new_view) |v| applyViewCoarse(device, texture, engine, nav, v, real_s, view_editor);
            nav.drag_state = .none;
            ig.igResetMouseDragDelta(ig.mouse_button_left);
        }
    } else {
        // Space is held: cancel any active box-select drag without committing.
        if (nav.drag_state == .active and !ig.igIsMouseDown_Nil(ig.mouse_button_left)) {
            nav.drag_state = .none;
            ig.igResetMouseDragDelta(ig.mouse_button_left);
        }
    }
}

// ─── Resize handler ───────────────────────────────────────────────────────────

/// Handle a window resize: recompute image rect; when S changes, resize engine,
/// recreate texture, re-upload. Zero S (minimized) is a no-op.
fn handleResize(
    device: gpu.Device,
    texture: *texture_mod.Texture,
    image_rect: *viewport.ImageRect,
    engine: *engine_mod.Engine,
    new_w: u32,
    new_h: u32,
) void {
    // Approximate the fractal region width (data panel + spacing taken from the right).
    // The exact rect is updated each frame from ImGui geometry; this gives the correct
    // engine size so the first post-resize render uses the right resolution.
    const panel_taken: u32 = @as(u32, @intFromFloat(panels.data_panel_w + panels.region_spacing));
    const fractal_w = if (new_w > panel_taken) new_w - panel_taken else 1;
    const new_rect = viewport.computeImageRect(fractal_w, new_h);
    const new_s = new_rect.side;

    if (new_s == 0) {
        image_rect.* = new_rect;
        return;
    }

    const old_s = engine.image_side;
    image_rect.* = new_rect;

    if (new_s == old_s) return;

    engine.resize(new_s) catch |err| {
        app_log.err("engine resize to {d}×{d} failed ({s}); keeping previous render", .{ new_s, new_s, @errorName(err) });
        return;
    };

    texture.destroy();
    texture.* = texture_mod.createRgbaTexture(device.handle, new_s, new_s) catch |err| {
        app_log.err("texture recreation at {d}×{d} failed ({s}); display may be stale", .{ new_s, new_s, @errorName(err) });
        return;
    };

    texture_mod.upload(device.handle, texture.*, engine.output()) catch |err| {
        app_log.err("texture re-upload after resize failed ({s})", .{@errorName(err)});
        return;
    };

    app_log.info("resize: window {d}x{d} → image {d}x{d}", .{ new_w, new_h, new_s, new_s });
}

// ─── Frame rendering ──────────────────────────────────────────────────────────

/// Acquire the swapchain, upload ImGui buffers, and render into a clearing render pass.
fn renderFrame(window: *c.SDL_Window, device: gpu.Device, ui: ui_mod.Ui) void {
    const cmd = c.SDL_AcquireGPUCommandBuffer(device.handle) orelse {
        app_log.err("SDL_AcquireGPUCommandBuffer failed: {s}", .{std.mem.span(c.SDL_GetError())});
        return;
    };

    var swapchain_texture: ?*c.SDL_GPUTexture = null;
    if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, window, &swapchain_texture, null, null)) {
        app_log.err("SDL_WaitAndAcquireGPUSwapchainTexture failed: {s}", .{std.mem.span(c.SDL_GetError())});
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    }
    const tex = swapchain_texture orelse {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    };

    ui.prepareDrawData(cmd);

    var color_target = c.SDL_GPUColorTargetInfo{
        .texture = tex,
        .clear_color = .{ .r = 0.06, .g = 0.06, .b = 0.09, .a = 1.0 },
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_STORE,
    };
    const pass = c.SDL_BeginGPURenderPass(cmd, &color_target, 1, null) orelse {
        app_log.err("SDL_BeginGPURenderPass failed: {s}", .{std.mem.span(c.SDL_GetError())});
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    };
    ui.renderDrawData(cmd, pass);
    c.SDL_EndGPURenderPass(pass);

    _ = c.SDL_SubmitGPUCommandBuffer(cmd);
}
