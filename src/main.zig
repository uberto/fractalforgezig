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
const window_w = 1280;
const window_h = 720;

// The render resolution: a SQUARE of `render_side` px, because M3's view model is a
// square region (plan A1) and `SquareView.imageViewport(S)` is the only pixel↔complex
// bridge. T5 makes `render_side` follow the window (`S = min(window_w, window_h)`,
// letterboxed); until then it is fixed and the image is aspect-fit by the UI.
const render_side = 750;

pub fn main() !void {
    var buf: [128]u8 = undefined;
    const banner = try root.startupLine(&buf, builtin.zig_version_string);
    app_log.info("{s}", .{banner});

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        app_log.err("SDL_Init failed: {s}", .{std.mem.span(c.SDL_GetError())});
        return error.SdlInitFailed;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(window_title, window_w, window_h, c.SDL_WINDOW_RESIZABLE) orelse {
        app_log.err("SDL_CreateWindow failed: {s}", .{std.mem.span(c.SDL_GetError())});
        return error.SdlWindowCreationFailed;
    };
    defer c.SDL_DestroyWindow(window);

    const device = try gpu.Device.create(window);
    defer device.destroy();

    const ui = try ui_mod.Ui.init(window, device);
    defer ui.shutdown();

    // Build the decoupling color engine (T5): it holds the persistent f32 smooth-value
    // buffer + the RGBA8 output + the default gradient/mapping/interior. `iterate` runs
    // the EXPENSIVE Mandelbrot pass ONCE at startup and colors with the default palette;
    // from then on palette/mapping edits (T6, in the UI) rerun ONLY the cheap color pass
    // and re-upload — the iteration buffer is never recomputed (M2's guarantee). Data
    // flow is one-directional: iterate -> color -> upload -> display.
    // M3: the engine owns the view (T1 `SquareView`), the image side and the `max_iter`
    // policy (T3, default auto), and re-iterates whenever any of them changes.
    const view = viewport.SquareView.defaultView();
    const vp = view.imageViewport(render_side);
    var engine = engine_mod.Engine.init(std.heap.page_allocator, view, render_side, .{}) catch |err| {
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

    const texture = try texture_mod.createRgbaTexture(device.handle, render_side, render_side);
    defer texture.destroy();
    try texture_mod.upload(device.handle, texture, engine.output());

    var summary_buf: [128]u8 = undefined;
    const summary = try stats_mod.renderSummary(&summary_buf, render_side, render_side, engine.max_iter, iterate_ns);
    app_log.info("{s}", .{summary});
    var color_buf: [96]u8 = undefined;
    if (engine.summary(&color_buf)) |line| app_log.info("{s}", .{line}) else |_| {}

    var app_stats = stats_mod.Stats.fromRender(iterate_ns);
    var editor = editor_mod.Editor.initDefault();

    app_log.info("entering event loop", .{});
    runLoop(window, device, ui, texture, vp, &app_stats, &engine, &editor);
    app_log.info("event loop exited; shutting down cleanly", .{});
}

/// Pump events and render the single fixed window each frame until quit. The
/// SDL_GPU swapchain resizes itself, so window-resize needs no special handling.
fn runLoop(
    window: *c.SDL_Window,
    device: gpu.Device,
    ui: ui_mod.Ui,
    texture: texture_mod.Texture,
    vp: viewport.Viewport,
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
            // Quit on an explicit app-quit, or when the main window's close
            // button is pressed. SDL3 delivers the latter as
            // SDL_EVENT_WINDOW_CLOSE_REQUESTED (not always SDL_EVENT_QUIT), so
            // handle it directly for the window we own — otherwise closing the
            // window leaves the process running with no visible window.
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                    if (event.window.windowID == c.SDL_GetWindowID(window)) running = false;
                },
                else => {},
            }
        }

        ui.newFrame();
        var quit_requested = false;
        // `engine.max_iter` (not a local constant): the engine derives it from its
        // `IterPolicy`, so the panel always shows the count the render actually used.
        panels.draw(device.handle, texture, vp, engine.max_iter, app_stats.*, engine, editor, &quit_requested);
        if (quit_requested) running = false;
        ui.endFrame();

        renderFrame(window, device, ui);

        if (frame_timer) |*t| app_stats.observeFrame(t.read());
    }
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
    const texture = swapchain_texture orelse {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    };

    // MANDATORY: upload draw buffers before opening the render pass.
    ui.prepareDrawData(cmd);

    var color_target = c.SDL_GPUColorTargetInfo{
        .texture = texture,
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
