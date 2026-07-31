//! Executable entry point. The M0 payoff (T8): open one macOS window, bring up an
//! SDL_GPU (Metal) device + swapchain, render the fixed CPU Mandelbrot once at
//! startup, upload it to a GPU texture, and display it via `ImGui::Image` inside a
//! single fixed window (menu bar + fractal region + read-only data panel).
//!
//! Keep this file thin: it is the init/render/shutdown glue. Pure math lives in
//! `fractal/`, the GPU edge in `gpu/`, and the ImGui layout in `ui/`.
const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const c = @import("c.zig").c;
const gpu = @import("gpu/device.zig");
const ui_mod = @import("ui/imgui.zig");
const viewport = @import("fractal/viewport.zig");
const engine_mod = @import("fractal/engine.zig");
const texture_mod = @import("gpu/texture.zig");
const stats_mod = @import("ui/stats.zig");
const editor_mod = @import("ui/editor.zig");
const panels = @import("ui/panels.zig");

const app_log = std.log.scoped(.app);

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

    const ui = try ui_mod.Ui.init(window, device);
    defer ui.shutdown();

    // T5: read initial window size and compute the letterboxed image rect.
    // SDL_GetWindowSize returns screen coordinates (consistent throughout the app;
    // see results/T5.md for the HiDPI note).
    var win_w: c_int = 0;
    var win_h: c_int = 0;
    _ = c.SDL_GetWindowSize(window, &win_w, &win_h);
    var image_rect = viewport.computeImageRect(@intCast(win_w), @intCast(win_h));
    const initial_S = image_rect.side;

    if (initial_S == 0) {
        // Degenerate startup window — cannot render; abort cleanly.
        app_log.err("startup window has zero side (S=0); cannot initialise the engine", .{});
        return error.DegenerateWindowSize;
    }

    // Build the decoupling color engine: it holds the persistent f32 smooth-value
    // buffer + the RGBA8 output + the default gradient/mapping/interior. `iterate` runs
    // the EXPENSIVE Mandelbrot pass ONCE at startup and colors with the default palette;
    // from then on palette/mapping edits (T6, in the UI) rerun ONLY the cheap color pass
    // and re-upload — the iteration buffer is never recomputed (M2's guarantee). Data
    // flow is one-directional: iterate -> color -> upload -> display.
    // M3: the engine owns the view (T1 `SquareView`), the image side (T5: S = min(w,h))
    // and the `max_iter` policy (T3, default auto), and re-iterates whenever any of them
    // changes. T5 calls `engine.resize(S)` on each window resize event.
    const view = viewport.SquareView.defaultView();
    const vp = view.imageViewport(initial_S);
    var engine = engine_mod.Engine.init(std.heap.page_allocator, view, initial_S, .{}) catch |err| {
        app_log.err("color engine init failed ({s}); aborting startup", .{@errorName(err)});
        return err;
    };
    defer engine.deinit();

    var iterate_timer = std.time.Timer.start() catch null;
    engine.iterate() catch |err| {
        app_log.err("CPU Mandelbrot iteration failed ({s}); aborting startup", .{@errorName(err)});
        return err;
    };
    const iterate_ns = if (iterate_timer) |*t| t.read() else 0;

    // Create the texture at the initial S×S size (not a hardcoded constant).
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

    app_log.info("entering event loop", .{});
    runLoop(window, device, ui, &texture, vp, &image_rect, &app_stats, &engine, &editor);
    app_log.info("event loop exited; shutting down cleanly", .{});
}

/// Pump events and render the single fixed window each frame until quit.
/// On `SDL_EVENT_WINDOW_RESIZED`, recompute `S = min(w, h)`, call `engine.resize(S)`,
/// recreate the texture at the new `S×S`, and re-upload. A zero `S` (minimized) is
/// skipped entirely — no error, no log spam. The `image_rect` and `texture` are
/// owned by `main` (on the stack / defer-destroyed), so we take mutable pointers.
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
) void {
    var frame_timer: ?std.time.Timer = std.time.Timer.start() catch |err| blk: {
        app_log.warn("frame timer unavailable ({s}); frame ms will read 0", .{@errorName(err)});
        break :blk null;
    };

    var running = true;
    while (running) {
        if (frame_timer) |*t| t.reset();

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            _ = ui.processEvent(&event);
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                    if (event.window.windowID == c.SDL_GetWindowID(window)) running = false;
                },
                // T5: recompute S and image_rect on every resize; recreate engine buffers
                // and GPU texture when S changes. Minimized windows (S==0) are skipped.
                c.SDL_EVENT_WINDOW_RESIZED => {
                    handleResize(
                        device,
                        texture,
                        image_rect,
                        engine,
                        @intCast(event.window.data1),
                        @intCast(event.window.data2),
                    );
                },
                else => {},
            }
        }

        ui.newFrame();
        var quit_requested = false;
        // `engine.max_iter` (not a local constant): the engine derives it from its
        // `IterPolicy`, so the panel always shows the count the render actually used.
        panels.draw(device.handle, texture.*, vp, image_rect.*, engine.max_iter, app_stats.*, engine, editor, &quit_requested);
        if (quit_requested) running = false;
        ui.endFrame();

        renderFrame(window, device, ui);

        if (frame_timer) |*t| app_stats.observeFrame(t.read());
    }
}

/// Handle a window resize: recompute the image rect, and when S changes, resize the
/// engine buffers, recreate the GPU texture, and re-upload. A zero S (window minimized)
/// is a no-op. Logs `.app` on success, `.err` on engine/texture failure (and skips
/// the re-render to avoid rendering with a stale texture).
fn handleResize(
    device: gpu.Device,
    texture: *texture_mod.Texture,
    image_rect: *viewport.ImageRect,
    engine: *engine_mod.Engine,
    new_w: u32,
    new_h: u32,
) void {
    const new_rect = viewport.computeImageRect(new_w, new_h);
    const new_s = new_rect.side;

    // Degenerate (minimized): skip silently — no error log spam.
    if (new_s == 0) {
        image_rect.* = new_rect;
        return;
    }

    const old_s = engine.image_side;

    // Always update the image_rect so T6's cursor mapping stays current.
    image_rect.* = new_rect;

    if (new_s == old_s) return; // S unchanged — no texture/engine work needed.

    // Resize the engine buffers and re-iterate.
    engine.resize(new_s) catch |err| {
        app_log.err("engine resize to {d}×{d} failed ({s}); keeping previous render", .{ new_s, new_s, @errorName(err) });
        return;
    };

    // Destroy the old texture and recreate at the new S×S.
    texture.destroy();
    texture.* = texture_mod.createRgbaTexture(device.handle, new_s, new_s) catch |err| {
        app_log.err("texture recreation at {d}×{d} failed ({s}); display may be stale", .{ new_s, new_s, @errorName(err) });
        return;
    };

    // Re-upload the fresh iteration result.
    texture_mod.upload(device.handle, texture.*, engine.output()) catch |err| {
        app_log.err("texture re-upload after resize failed ({s})", .{@errorName(err)});
        return;
    };

    app_log.info("resize: window {d}x{d} → image {d}x{d}", .{ new_w, new_h, new_s, new_s });
}

/// Acquire the swapchain, upload ImGui buffers, and render into a clearing
/// render pass. When the swapchain texture is unavailable (e.g. minimized),
/// submit the empty command buffer and skip drawing.
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
    // A null swapchain texture is the expected not-ready/minimized case (not an
    // error): submit the empty command buffer and skip drawing this frame.
    const tex = swapchain_texture orelse {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    };

    // MANDATORY: upload draw buffers before opening the render pass.
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
