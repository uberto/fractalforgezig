//! Dear ImGui integration edge: create the ImGui context (via cimgui), wire the
//! SDL3 + SDL_GPU backends (via the C bridge), drive per-frame new-frame/render,
//! and tear everything down in order. M0 target is a single window with a plain
//! (non-docking) config — the docking config flag is intentionally NOT set.
const std = @import("std");
const c = @import("../c.zig").c;
const ig = @import("../cimgui.zig");
const device_mod = @import("../gpu/device.zig");

const log = std.log.scoped(.ui);

pub const Error = error{
    ImGuiContextCreationFailed,
    ImGuiBackendInitFailed,
};

/// Owns the ImGui context and the SDL3/SDLGPU3 backends for one window.
pub const Ui = struct {
    ctx: *ig.ImGuiContext,

    /// Create the ImGui context and wire the backends to an already-created,
    /// window-claimed GPU device. Logs `std.log.err` + returns an error on
    /// failure; no `unreachable`.
    pub fn init(window: *c.SDL_Window, device: device_mod.Device) Error!Ui {
        const ctx = ig.igCreateContext(null) orelse {
            log.err("igCreateContext returned null", .{});
            return Error.ImGuiContextCreationFailed;
        };
        errdefer ig.igDestroyContext(ctx);

        const color_format = device.swapchainTextureFormat();
        if (!c.ffImguiInitBackends(window, device.handle, color_format)) {
            const sdl_error = std.mem.span(c.SDL_GetError());
            log.err("ImGui SDL3/SDLGPU3 backend init failed: {s}", .{sdl_error});
            return Error.ImGuiBackendInitFailed;
        }

        log.info("Dear ImGui initialized (SDL3 + SDLGPU3 backends)", .{});
        return .{ .ctx = ctx };
    }

    /// Feed an SDL event to the platform backend. Returns true if consumed.
    pub fn processEvent(_: Ui, event: *const c.SDL_Event) bool {
        return c.ffImguiProcessEvent(event);
    }

    /// Begin a new ImGui frame (backends first, then core). Build UI after this.
    pub fn newFrame(_: Ui) void {
        c.ffImguiNewFrame();
        ig.igNewFrame();
    }

    /// Finalize this frame's draw data. Call after building UI, before acquiring
    /// the swapchain, so `prepare`/`render` have valid draw data to upload.
    pub fn endFrame(_: Ui) void {
        ig.igRender();
    }

    /// Upload vertex/index buffers for the current frame. MUST run with a live
    /// command buffer BEFORE the render pass.
    pub fn prepareDrawData(_: Ui, command_buffer: *c.SDL_GPUCommandBuffer) void {
        c.ffImguiPrepareDrawData(command_buffer);
    }

    /// Record ImGui draw commands into an active render pass on the swapchain.
    pub fn renderDrawData(_: Ui, command_buffer: *c.SDL_GPUCommandBuffer, render_pass: *c.SDL_GPURenderPass) void {
        c.ffImguiRenderDrawData(command_buffer, render_pass);
    }

    /// Tear down backends (renderer then platform) then the ImGui context.
    pub fn shutdown(self: Ui) void {
        c.ffImguiShutdownBackends();
        ig.igDestroyContext(self.ctx);
    }
};
