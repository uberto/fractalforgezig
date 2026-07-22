//! SDL_GPU device lifecycle: create a device on the Metal backend and claim the
//! window swapchain. All C/SDL types stay behind this edge; callers get a small
//! `Device` handle and Zig errors. Pure string building lives in `message.zig`
//! so it is unit-testable without a device.
const std = @import("std");
const c = @import("../c.zig").c;
const message = @import("message.zig");

const log = std.log.scoped(.gpu);

pub const Error = error{
    GpuDeviceCreationFailed,
    GpuWindowClaimFailed,
};

/// A created SDL_GPU device bound to a window. Call `destroy` to tear down.
pub const Device = struct {
    handle: *c.SDL_GPUDevice,
    window: *c.SDL_Window,

    /// Create the GPU device (Metal on macOS: request MSL + metallib shader
    /// formats so the vendored ImGui SDLGPU3 backend finds usable shaders) and
    /// claim `window`'s swapchain. Logs the driver name on success; on failure
    /// logs `std.log.err` with the SDL error string and returns a Zig error.
    pub fn create(window: *c.SDL_Window) Error!Device {
        const shader_formats = c.SDL_GPU_SHADERFORMAT_MSL | c.SDL_GPU_SHADERFORMAT_METALLIB;
        const handle = c.SDL_CreateGPUDevice(shader_formats, true, null) orelse {
            logSdlFailure("SDL_CreateGPUDevice");
            return Error.GpuDeviceCreationFailed;
        };
        errdefer c.SDL_DestroyGPUDevice(handle);

        if (!c.SDL_ClaimWindowForGPUDevice(handle, window)) {
            logSdlFailure("SDL_ClaimWindowForGPUDevice");
            return Error.GpuWindowClaimFailed;
        }

        var buf: [256]u8 = undefined;
        const driver = std.mem.span(c.SDL_GetGPUDeviceDriver(handle));
        const line = message.deviceReady(&buf, driver) catch "SDL_GPU device ready";
        log.info("{s}", .{line});

        return .{ .handle = handle, .window = window };
    }

    /// Swapchain texture format for the claimed window; hand this to the ImGui
    /// renderer backend so its pipeline matches the target.
    pub fn swapchainTextureFormat(self: Device) c.SDL_GPUTextureFormat {
        return c.SDL_GetGPUSwapchainTextureFormat(self.handle, self.window);
    }

    /// Release the window swapchain then destroy the device. Idempotent-safe to
    /// call exactly once during shutdown.
    pub fn destroy(self: Device) void {
        c.SDL_ReleaseWindowFromGPUDevice(self.handle, self.window);
        c.SDL_DestroyGPUDevice(self.handle);
    }
};

fn logSdlFailure(call: []const u8) void {
    var buf: [256]u8 = undefined;
    const sdl_error = std.mem.span(c.SDL_GetError());
    const msg = message.sdlFailure(&buf, call, sdl_error) catch call;
    log.err("{s}", .{msg});
}
