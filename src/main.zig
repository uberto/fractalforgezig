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
const persist = @import("fractal/persist.zig");
const dialog = @import("ui/dialog.zig");

const app_log = std.log.scoped(.app);

/// Module-level compute pipeline so the IterFn (which has no closure) can reach it.
var g_compute_pipeline: ?compute_mod.ComputePipeline = null;

/// The IterFn wired into engine.gpu_iter_fn when GPU mode is enabled.
fn gpuIterFn(
    view: viewport.SquareView,
    w: u32,
    h: u32,
    max_iter: u32,
    iter: []f32,
) anyerror!void {
    const pl = g_compute_pipeline orelse return error.GpuPipelineNotReady;
    try compute_mod.gpuIterate(pl, view, w, h, max_iter, iter);
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

    // Engine: holds the view, w×h, policy, iteration buffer, RGBA output.
    const view = viewport.SquareView.defaultView();
    const init_w = image_rect.side; // start square; first resize will go rectangular
    const init_h = image_rect.side;
    var engine = engine_mod.Engine.initRect(std.heap.page_allocator, view, init_w, init_h, .{}) catch |err| {
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
        app_log.err("Mandelbrot iteration failed ({s}); aborting startup", .{@errorName(err)});
        return err;
    };
    const iterate_ns = if (iterate_timer) |*t| t.read() else 0;

    var texture = try texture_mod.createRgbaTexture(device.handle, engine.image_w, engine.image_h);
    defer texture.destroy();
    try texture_mod.upload(device.handle, texture, engine.output());

    var summary_buf: [128]u8 = undefined;
    const summary = try stats_mod.renderSummary(&summary_buf, engine.image_w, engine.image_h, engine.max_iter, iterate_ns);
    app_log.info("{s}", .{summary});
    var color_buf: [96]u8 = undefined;
    if (engine.summary(&color_buf)) |line| app_log.info("{s}", .{line}) else |_| {}

    var app_stats = stats_mod.Stats.fromRender(iterate_ns);
    var editor = editor_mod.Editor.initDefault();
    var view_editor = editor_mod.ViewEditor.initFromView(engine.view);

    app_log.info("entering event loop", .{});
    runLoop(window, device, ui, &texture, &image_rect, &app_stats, &engine, &editor, &view_editor);
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
    /// True while a coarse pass is shown and the full-res pass hasn't run yet.
    /// Passed to panels.draw so the UI can visually indicate rendering in progress.
    rendering: bool = false,
    /// Set when engine output changed and needs to be uploaded to the GPU texture.
    /// Upload is deferred to after ui.endFrame() so ImGui never sees a destroyed handle.
    needs_upload: bool = false,
    /// Nanoseconds taken by the most recent iteration pass (for render_ms display).
    last_render_ns: u64 = 0,

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
    engine: *engine_mod.Engine,
    nav: *NavState,
    view_editor: *editor_mod.ViewEditor,
) void {
    if (nav.undo_len == 0) return;
    const prev = nav.undo_buf[nav.undo_len - 1];
    nav.undo_len -= 1;
    if (nav.redo_len < history_cap) {
        nav.redo_buf[nav.redo_len] = engine.view;
        nav.redo_len += 1;
    }
    engine.setViewport(prev) catch |err| {
        app_log.err("undo rejected ({s})", .{@errorName(err)});
        return;
    };
    nav.needs_upload = true;
    nav.full_pass_done = false;
    nav.idle_timer = std.time.Timer.start() catch null;
    view_editor.syncFromView(engine.view);
}

/// Redo: restore the most recent undone view.
fn historyRedo(
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
    nav.needs_upload = true;
    nav.full_pass_done = false;
    nav.idle_timer = std.time.Timer.start() catch null;
    view_editor.syncFromView(engine.view);
}

// ─── View-change helpers ───────────────────────────────────────────────────────

/// Recreate the GPU texture if its dimensions differ from engine.image_w × engine.image_h.
fn syncTexture(device: gpu.Device, texture: *texture_mod.Texture, engine: *engine_mod.Engine) void {
    if (texture.width == engine.image_w and texture.height == engine.image_h) return;
    texture.destroy();
    texture.* = texture_mod.createRgbaTexture(device.handle, engine.image_w, engine.image_h) catch |err| {
        app_log.err("texture sync to {d}×{d} failed ({s})", .{ engine.image_w, engine.image_h, @errorName(err) });
        return;
    };
}

/// Apply a new view with an immediate coarse (S/4) pass and upload.
/// `real_w/real_h` are the full-resolution dimensions to restore for the full pass.
fn applyViewCoarse(
    engine: *engine_mod.Engine,
    nav: *NavState,
    new_view: viewport.SquareView,
    real_s: u32,
    view_editor: *editor_mod.ViewEditor,
) void {
    historyPush(nav, engine.view);
    var t = std.time.Timer.start() catch null;

    // Coarse: real_s/4 (square navigation side / 4) for both dimensions.
    // Using the navigation square side keeps the coarse pass square for simplicity.
    const coarse_s = @max(real_s / 4, 1);
    const coarse_w = coarse_s;
    const coarse_h = coarse_s;

    // Resize to coarse if dimensions changed.
    if (engine.image_w != coarse_w or engine.image_h != coarse_h) {
        engine.resizeRect(coarse_w, coarse_h) catch |err| {
            app_log.err("coarse resize to {d}×{d} failed ({s})", .{ coarse_w, coarse_h, @errorName(err) });
        };
    }

    // Install the new view (re-iterates at current size).
    engine.setViewport(new_view) catch |err| {
        app_log.err("navigation rejected ({s}); keeping previous view", .{@errorName(err)});
        return;
    };

    // Warn if the new view crossed the precision floor.
    if (navigate.atPrecisionFloor(new_view)) {
        var floor_buf: [navigate.floor_message_buf_len]u8 = undefined;
        if (navigate.precisionFloorMessage(&floor_buf, new_view.side)) |msg| {
            app_log.warn("{s}", .{msg});
        } else |_| {}
    }

    if (t) |*timer| nav.last_render_ns = timer.read();
    nav.needs_upload = true;
    nav.rendering = true;
    view_editor.syncFromView(engine.view);
    nav.full_pass_done = false;
    nav.idle_timer = std.time.Timer.start() catch null;
}

/// Restore full-resolution dimensions, re-iterate, sync texture, re-upload.
fn runFullPass(
    engine: *engine_mod.Engine,
    nav: *NavState,
    real_w: u32,
    real_h: u32,
    view_editor: *editor_mod.ViewEditor,
) void {
    var t = std.time.Timer.start() catch null;
    if (engine.image_w != real_w or engine.image_h != real_h) {
        engine.resizeRect(real_w, real_h) catch |err| {
            app_log.err("full-res resize to {d}×{d} failed ({s}); display stays coarse", .{ real_w, real_h, @errorName(err) });
            nav.full_pass_done = true;
            return;
        };
    }
    if (t) |*timer| nav.last_render_ns = timer.read();

    nav.needs_upload = true;
    nav.rendering = false;
    view_editor.syncFromView(engine.view);
    nav.full_pass_done = true;
    app_log.info("full-res pass complete: {d}×{d}", .{ engine.image_w, engine.image_h });
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
    var pending_dialog = dialog.PendingDialog{};
    // Track the full-resolution dimensions independently of engine.image_w/h (which may
    // be at coarse size during a drag).
    var real_w: u32 = engine.image_w;
    var real_h: u32 = engine.image_h;
    // Keeping real_s for the few remaining callers that still need a nav-square side.
    var real_s: u32 = engine.image_side;

    var running = true;
    while (running) {
        if (frame_timer) |*t| t.reset();

        // ── SDL event pump — wait for the first event then drain the queue.
        // WaitEvent blocks until at least one event arrives, keeping CPU idle.
        // When a dialog is pending we use a short timeout so the Cocoa runloop
        // keeps pumping and can deliver the file-dialog completion callback.
        var event: c.SDL_Event = undefined;
        const wait_ms: i32 = if (pending_dialog.kind != dialog.Kind.none) 16 else -1;
        if (c.SDL_WaitEventTimeout(&event, wait_ms)) {
            while (true) {
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
                        real_w = engine.image_w;
                        real_h = engine.image_h;
                        real_s = engine.image_side;
                        nav.full_pass_done = true;
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
                                    applyViewCoarse(engine, &nav, v, real_s, view_editor);
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
                                historyUndo(engine, &nav, view_editor);
                            } else if (event.key.scancode == c.SDL_SCANCODE_Y) {
                                historyRedo(engine, &nav, view_editor);
                            }
                        }
                    },
                    else => {},
                }
                if (!c.SDL_PollEvent(&event)) break;
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
            engine.max_iter,
            app_stats.*,
            engine,
            editor,
            view_editor,
            nav.open_ctx_menu,
            nav.right_click_pt,
            hover_pt,
            nav.rendering,
            &quit_requested,
        );
        // Update image_rect from the live ImGui geometry every frame so coordinate
        // mapping and resize use the actual fractal region (not the OS window size).
        if (draw_result.image_rect.side > 0) image_rect.* = draw_result.image_rect;
        nav.open_ctx_menu = false;
        if (quit_requested) running = false;

        // GPU/CPU toggle: re-iterate on the new path, upload will happen in the deferred block.
        if (draw_result.needs_rerender) {
            var t = std.time.Timer.start() catch null;
            engine.iterate() catch |err| {
                app_log.err("GPU toggle re-iterate failed ({s}); reverting", .{@errorName(err)});
                engine.use_gpu = !engine.use_gpu;
            };
            if (t) |*timer| {
                const ns = timer.read();
                if (engine.use_gpu) {
                    app_stats.gpu_render_ms = stats_mod.nsToMs(ns);
                    app_stats.render_ms = 0.0;
                } else {
                    app_stats.render_ms = stats_mod.nsToMs(ns);
                    app_stats.gpu_render_ms = 0.0;
                }
            }
            nav.needs_upload = true;
        }

        // Open file dialogs when menu items were clicked (after the ImGui frame).
        if (draw_result.save_requested) dialog.showSave(window, &pending_dialog);
        if (draw_result.open_requested) dialog.showOpen(window, &pending_dialog);

        // Act on the context-menu selection.
        if (draw_result.ctx_action != .none) {
            const pt = nav.right_click_pt;
            const new_view: ?viewport.SquareView = switch (draw_result.ctx_action) {
                .zoom_in => navigate.zoomCentered(engine.view, pt, navigate.zoom_step_in) catch null,
                .zoom_out => navigate.zoomCentered(engine.view, pt, navigate.zoom_step_out) catch null,
                .center_here => viewport.SquareView.fromCenterSide(pt, engine.view.side) catch null,
                .none => null,
            };
            if (new_view) |v| applyViewCoarse(engine, &nav, v, real_s, view_editor);
        }

        // Navigation ImGui input: box-select and pan.
        handleNavInput(engine, &nav, image_rect.*, real_s, view_editor);

        ui.endFrame();

        // ── Coarse→fine pass decision ─────────────────────────────────────────
        const interacting = (nav.drag_state == .active) or
            ig.igIsMouseDragging(ig.mouse_button_middle, -1.0) or
            (ig.igIsKeyDown_Nil(ig.key_space) and ig.igIsMouseDragging(ig.mouse_button_left, -1.0));
        const idle_ns: u64 = if (nav.idle_timer) |*t| t.read() else 0;
        switch (refine.decidePass(interacting, idle_ns, nav.full_pass_done)) {
            .full => runFullPass(engine, &nav, real_w, real_h, view_editor),
            .coarse, .none => {},
        }

        renderFrame(window, device, ui);

        // ── Deferred texture sync + upload ────────────────────────────────────
        // MUST be after renderFrame: ImGui submits the GPU commands (including
        // the sampler binding for the fractal texture) inside renderFrame.
        // Only after submission is it safe to destroy and recreate the texture.
        const did_upload = nav.needs_upload;
        if (nav.needs_upload) {
            syncTexture(device, texture, engine);
            texture_mod.upload(device.handle, texture.*, engine.output()) catch |err| {
                app_log.err("texture upload failed ({s})", .{@errorName(err)});
            };
            nav.needs_upload = false;
        }

        // ── File dialog result processing ─────────────────────────────────────
        if (dialog.takePending(&pending_dialog)) |result| {
            handleDialogResult(result, device, texture, engine, &nav, view_editor);
        }

        // Only update frame_ms when the fractal actually re-rendered; skip mouse-move frames.
        if (did_upload) {
            if (frame_timer) |*t| app_stats.observeFrame(t.read());
        }
        if (nav.last_render_ns > 0) {
            app_stats.render_ms = stats_mod.nsToMs(nav.last_render_ns);
            nav.last_render_ns = 0;
        }
    }
}

/// Process a completed file-dialog result: save state to disk or load from disk.
fn handleDialogResult(
    result: dialog.PendingResult,
    device: gpu.Device,
    texture: *texture_mod.Texture,
    engine: *engine_mod.Engine,
    nav: *NavState,
    view_editor: *editor_mod.ViewEditor,
) void {
    const alloc = std.heap.page_allocator;
    const path = result.path;

    switch (result.kind) {
        .save => {
            const state = persist.fromEngine(engine, alloc) catch |err| {
                app_log.err("save: fromEngine failed ({s})", .{@errorName(err)});
                return;
            };
            defer persist.freeState(state, alloc);

            // Ensure path ends in .fractal; use path as-is (SDL dialog already filters).
            const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
                app_log.err("save: cannot create '{s}' ({s})", .{ path, @errorName(err) });
                return;
            };
            defer file.close();

            var json_buf: [8192]u8 = undefined;
            const json_bytes = persist.toJson(state, &json_buf) catch |err| {
                app_log.err("save: toJson failed ({s})", .{@errorName(err)});
                return;
            };
            file.writeAll(json_bytes) catch |err| {
                app_log.err("save: write failed for '{s}' ({s})", .{ path, @errorName(err) });
                return;
            };
            app_log.info("state saved to '{s}'", .{path});
        },
        .open => {
            const file = std.fs.cwd().openFile(path, .{}) catch |err| {
                app_log.err("open: cannot read '{s}' ({s})", .{ path, @errorName(err) });
                return;
            };
            defer file.close();

            var file_buf: [8192]u8 = undefined;
            const n = file.readAll(&file_buf) catch |err| {
                app_log.err("open: read failed for '{s}' ({s})", .{ path, @errorName(err) });
                return;
            };
            const json_bytes = file_buf[0..n];

            const state = persist.fromJson(json_bytes, alloc) catch |err| {
                app_log.err("open: parse failed for '{s}' ({s})", .{ path, @errorName(err) });
                return;
            };
            defer persist.freeState(state, alloc);

            persist.applyToEngine(state, engine) catch |err| {
                app_log.err("open: applyToEngine failed for '{s}' ({s})", .{ path, @errorName(err) });
                return;
            };

            syncTexture(device, texture, engine);
            view_editor.syncFromView(engine.view);
            nav.needs_upload = true;
            nav.full_pass_done = false;
            nav.idle_timer = std.time.Timer.start() catch null;
            app_log.info("state loaded from '{s}'", .{path});
        },
        .none => {},
    }
}

// ─── Per-frame navigation input ───────────────────────────────────────────────

/// Rubber-band rect colour: bright white, fully opaque (0xAABBGGRR in ImGui packing).
const drag_rect_col: ig.ImU32 = 0xFF_FF_FF_FF;

/// Process box-select (left-drag) and pan (middle-drag / Space+left-drag) for one frame.
fn handleNavInput(
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
                applyViewCoarse(engine, nav, v, real_s, view_editor);
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
            // Use toImagePixel first; if outside the rect, clamp to [0, w) × [0, h).
            const end_px: viewport.Pixel = rect.toImagePixel(@floatCast(ex), @floatCast(ey)) orelse blk: {
                if (rect.w == 0 or rect.h == 0) break :blk nav.drag_start_px;
                const ox: f64 = @floatFromInt(rect.x);
                const oy: f64 = @floatFromInt(rect.y);
                break :blk .{
                    .x = @max(0.0, @min(@as(f64, @floatFromInt(rect.w)) - 1.0, @as(f64, @floatCast(ex)) - ox)),
                    .y = @max(0.0, @min(@as(f64, @floatFromInt(rect.h)) - 1.0, @as(f64, @floatCast(ey)) - oy)),
                };
            };
            const new_view = navigate.boxSelect(
                engine.view,
                nav.drag_start_px,
                end_px,
                rect.w,
                rect.h,
            ) catch |err| blk: {
                app_log.warn("box-select rejected ({s})", .{@errorName(err)});
                break :blk null;
            };
            if (new_view) |v| applyViewCoarse(engine, nav, v, real_s, view_editor);
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
    // Approximate the fractal region dimensions (data panel taken from the right).
    const panel_taken: u32 = @as(u32, @intFromFloat(panels.data_panel_w + panels.region_spacing));
    const frac_w = if (new_w > panel_taken) new_w - panel_taken else 1;
    const frac_h = if (new_h > 0) new_h else 1;

    if (frac_w == 0 or frac_h == 0) return;
    if (frac_w == engine.image_w and frac_h == engine.image_h) return;

    engine.resizeRect(frac_w, frac_h) catch |err| {
        app_log.err("engine resize to {d}×{d} failed ({s}); keeping previous render", .{ frac_w, frac_h, @errorName(err) });
        return;
    };

    texture.destroy();
    texture.* = texture_mod.createRgbaTexture(device.handle, frac_w, frac_h) catch |err| {
        app_log.err("texture recreation at {d}×{d} failed ({s}); display may be stale", .{ frac_w, frac_h, @errorName(err) });
        return;
    };

    texture_mod.upload(device.handle, texture.*, engine.output()) catch |err| {
        app_log.err("texture re-upload after resize failed ({s})", .{@errorName(err)});
        return;
    };

    _ = image_rect; // updated each frame from ImGui geometry
    app_log.info("resize: window {d}x{d} → fractal {d}×{d}", .{ new_w, new_h, frac_w, frac_h });
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
