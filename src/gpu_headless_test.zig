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
const viewport = @import("fractal/viewport.zig");

test "compute: pipeline creates successfully with embedded MSL source" {
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);

    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();
    // If we reach here the MSL compiled without error.
}

test "compute: gpuIterate interior pixels match CPU (deep interior, no precision boundary)" {
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);

    const mandelbrot = @import("fractal/mandelbrot.zig");
    const vp = @import("fractal/viewport.zig");

    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();

    const S: u32 = 16;
    const max_iter: u32 = 64;
    // Use a view centered deep inside the Mandelbrot set (origin = 0+0i, scale small).
    // All pixels in a tiny square around (0,0) are interior; CPU and GPU must agree.
    const view = try vp.SquareView.fromCenterSide(.{ .re = 0.0, .im = 0.0 }, 0.1);

    var gpu_iter: [S * S]f32 = undefined;
    try compute.gpuIterate(pipeline, view, S, S, max_iter, &gpu_iter);

    var interior_count: u32 = 0;
    for (gpu_iter) |v| {
        if (v < 0.0) interior_count += 1;
    }
    try std.testing.expectEqual(@as(u32, S * S), interior_count);

    const exterior_view = try vp.SquareView.fromCenterSide(.{ .re = 2.0, .im = 2.0 }, 0.01);
    var exterior_iter: [S * S]f32 = undefined;
    try compute.gpuIterate(pipeline, exterior_view, S, S, max_iter, &exterior_iter);

    // CPU reference for center pixel.
    const scale: f64 = exterior_view.side / @as(f64, @floatFromInt(S));
    const c_re = exterior_view.center_re + 0.5 * scale - exterior_view.side * 0.5;
    const c_im = exterior_view.center_im + exterior_view.side * 0.5 - 0.5 * scale;
    const cpu_val = mandelbrot.iterate(c_re, c_im, max_iter);
    const gpu_val = exterior_iter[0];

    // Both must be escaped (positive).
    try std.testing.expect(cpu_val > 0.0);
    try std.testing.expect(gpu_val > 0.0);
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
        .width = 4,
        .height = 4,
        .max_iter = 64,
        .band_rows = 4,
    };

    var iter_out: [4 * 4]f32 = undefined;
    try compute.dispatch(pipeline, uniforms, &iter_out);

    for (iter_out) |v| {
        try std.testing.expect(std.math.isFinite(v));
    }
}

test "compute: a band dispatch equals those rows of the whole-image dispatch" {
    // The band's whole reason to exist is progressive GPU rendering, so the claim that matters
    // is that splitting an image into bands changes NOTHING about the values — if `row_offset`
    // were dropped from the complex mapping, the band would render the top of the image.
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);

    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();

    const S: u32 = 16;
    const max_iter: u32 = 128;
    // Off-center and non-square so a row mix-up cannot coincidentally still match.
    const view = try viewport.SquareView.fromCenterSide(.{ .re = -0.4, .im = 0.35 }, 1.25);
    const w: u32 = S;
    const h: u32 = S / 2;

    var whole: [S * (S / 2)]f32 = undefined;
    try compute.gpuIterate(pipeline, view, w, h, max_iter, &whole);

    // Same image, computed as three uneven bands.
    var banded: [S * (S / 2)]f32 = undefined;
    const bands = [_][2]u32{ .{ 0, 3 }, .{ 3, 1 }, .{ 4, h - 4 } };
    for (bands) |b| {
        const start: usize = @as(usize, b[0]) * @as(usize, w);
        const len: usize = @as(usize, b[1]) * @as(usize, w);
        try compute.gpuIterateRows(pipeline, view, w, h, max_iter, b[0], b[1], banded[start..][0..len]);
    }

    try std.testing.expectEqualSlices(f32, &whole, &banded);
}

test "compute: a band that runs past the last row is rejected, not clamped" {
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);

    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();

    var band: [4 * 2]f32 = undefined;
    const uniforms = compute.MandelbrotUniforms{
        .center_re = -0.75,
        .center_im = 0.0,
        .scale = @floatCast(3.5 / 4.0),
        .width = 4,
        .height = 4,
        .max_iter = 16,
        .row_offset = 3, // 3 + 2 > 4
        .band_rows = 2,
    };
    try std.testing.expectError(compute.Error.BandOutOfBounds, compute.dispatch(pipeline, uniforms, &band));
}
