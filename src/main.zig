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
const fractal_render = @import("fractal/render.zig");
const texture_mod = @import("gpu/texture.zig");
const stats_mod = @import("ui/stats.zig");
const panels = @import("ui/panels.zig");

const app_log = std.log.scoped(.app);

const window_title = "fractalforge";
const window_w = 1280;
const window_h = 720;

// The fixed M0 render resolution. Aspect 1050:750 == 3.5:2.5 matches the fixed
// viewport region exactly, so the whole set is shown with no letterbox in the
// mapping. The image is then aspect-fit into its on-screen region by the UI.
const render_w = 1050;
const render_h = 750;
const max_iter = 512;

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

    // Render the fixed Mandelbrot on the CPU (pure core) and upload it once to a
    // GPU texture. Data flow is one-directional: render -> upload -> display.
    const vp = viewport.Viewport.fixedView(render_w, render_h);
    const result = try fractal_render.render(std.heap.page_allocator, vp, max_iter);
    var pixels_owned = true;
    defer if (pixels_owned) std.heap.page_allocator.free(result.pixels);

    const texture = try texture_mod.createRgbaTexture(device.handle, render_w, render_h);
    defer texture.destroy();
    try texture_mod.upload(device.handle, texture, result.pixels);
    // Upload copied the bytes into the GPU transfer buffer; the CPU copy is done.
    std.heap.page_allocator.free(result.pixels);
    pixels_owned = false;

    var summary_buf: [128]u8 = undefined;
    const summary = try stats_mod.renderSummary(&summary_buf, render_w, render_h, max_iter, result.elapsed_ns);
    app_log.info("{s}", .{summary});

    var app_stats = stats_mod.Stats.fromRender(result.elapsed_ns);

    app_log.info("entering event loop", .{});
    runLoop(window, device, ui, texture, vp, &app_stats);
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
            if (event.type == c.SDL_EVENT_QUIT) running = false;
        }

        ui.newFrame();
        var quit_requested = false;
        panels.draw(texture.handle, texture.width, texture.height, vp, max_iter, app_stats.*, &quit_requested);
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
    const cmd = c.SDL_AcquireGPUCommandBuffer(device.handle) orelse return;

    var swapchain_texture: ?*c.SDL_GPUTexture = null;
    if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, window, &swapchain_texture, null, null)) {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    }
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
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    };
    ui.renderDrawData(cmd, pass);
    c.SDL_EndGPURenderPass(pass);

    _ = c.SDL_SubmitGPUCommandBuffer(cmd);
}
