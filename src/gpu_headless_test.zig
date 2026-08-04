//! Test-only root for the headless GPU texture round-trip suite.
//!
//! Rooted in `src/` (NOT `src/gpu/`) so `gpu/texture.zig`'s `../c.zig` and
//! `../fractal/*` imports resolve inside the module path. This aggregates the
//! ONE C-linking test artifact; `zig build test` and `zig build test-gpu` build
//! it. The pure tier (`src/root.zig`) stays C-free and must not import this.
const std = @import("std");
const c = @import("c.zig").c;

test {
    _ = @import("gpu/texture.zig");
    _ = @import("gpu/compute.zig");
    std.testing.refAllDecls(@This());
}

fn openHeadlessDevice() error{SkipZigTest}!*c.SDL_GPUDevice {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.log.warn("skipping headless GPU test: SDL_Init failed", .{});
        return error.SkipZigTest;
    }
    const shader_formats = c.SDL_GPU_SHADERFORMAT_MSL | c.SDL_GPU_SHADERFORMAT_METALLIB;
    return c.SDL_CreateGPUDevice(shader_formats, true, null) orelse {
        std.log.warn("skipping headless GPU test: no GPU device", .{});
        c.SDL_Quit();
        return error.SkipZigTest;
    };
}

fn closeHeadlessDevice(device: *c.SDL_GPUDevice) void {
    c.SDL_DestroyGPUDevice(device);
    c.SDL_Quit();
}

// ─── Compute pipeline smoke tests ────────────────────────────────────────────

const compute = @import("gpu/compute.zig");

test "compute: pipeline creates successfully with embedded MSL source" {
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);

    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();
    // If we reach here the MSL compiled without error.
}

test "compute: dispatch at S=4 produces 16 finite results" {
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);

    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();

    const uniforms = compute.MandelbrotUniforms{
        .center_re = -0.75,
        .center_im = 0.0,
        .scale = @floatCast(3.5 / 4.0),
        .side = 4,
        .max_iter = 64,
    };

    var iter_out: [4 * 4]f32 = undefined;
    try compute.dispatch(pipeline, uniforms, &iter_out);

    for (iter_out) |v| {
        try std.testing.expect(std.math.isFinite(v));
    }
}
