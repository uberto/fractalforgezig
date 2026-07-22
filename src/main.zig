//! Executable entry point. M0 toolchain spike (T2): open one macOS window, bring
//! up an SDL_GPU (Metal) device + swapchain, render a single Dear ImGui window
//! into it each frame, and shut everything down cleanly on quit.
//!
//! Fractal math and the CPU->texture path arrive in later M0 tasks (T3-T8). This
//! file is the real init/shutdown glue, not a throwaway; keep it thin and push
//! logic into `gpu/` and `ui/`.
const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const c = @import("c.zig").c;
const ig = @import("cimgui.zig");
const gpu = @import("gpu/device.zig");
const ui_mod = @import("ui/imgui.zig");

const app_log = std.log.scoped(.app);

const window_title = "fractalforge";
const window_w = 1280;
const window_h = 720;

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

    app_log.info("entering event loop", .{});
    runLoop(window, device, ui);
    app_log.info("event loop exited; shutting down cleanly", .{});
}

/// Pump events and render one ImGui window per frame until quit. The SDL_GPU
/// swapchain resizes itself, so window-resize needs no special handling beyond
/// re-reading the swapchain size each frame.
fn runLoop(window: *c.SDL_Window, device: gpu.Device, ui: ui_mod.Ui) void {
    var show_demo: bool = true;
    var running = true;
    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            _ = ui.processEvent(&event);
            if (event.type == c.SDL_EVENT_QUIT) running = false;
        }

        ui.newFrame();
        buildUi(&show_demo);
        ui.endFrame();

        renderFrame(window, device, ui);
    }
}

/// Build the single ImGui frame: the demo window plus one dummy data panel.
/// T8 replaces this with the real menu bar + fractal/data panels.
fn buildUi(show_demo: *bool) void {
    ig.igShowDemoWindow(show_demo);

    if (ig.igBegin("fractalforge", null, 0)) {
        ig.igText("SDL_GPU + Dear ImGui toolchain spike (M0 / T2).");
        ig.igText("Fractal render lands in later M0 tasks.");
    }
    ig.igEnd();
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
