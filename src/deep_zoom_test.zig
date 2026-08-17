//! Acceptance tests for M6 deep zoom that span modules (viewport + perturb + engine + ui).
//! Aggregated from `src/root.zig`; pure tier only — no window, no GPU device.
const std = @import("std");
const testing = std.testing;
const viewport = @import("fractal/viewport.zig");
const navigate = @import("fractal/navigate.zig");
const perturb = @import("fractal/perturb.zig");
const mandelbrot = @import("fractal/mandelbrot.zig");
const iterbuf = @import("fractal/iterbuf.zig");
const engine = @import("fractal/engine.zig");
const editor = @import("ui/editor.zig");

/// The reference center for every deep-zoom test: the seahorse-valley boundary point from
/// the Mandelbrot deep-zoom literature, which keeps producing structure past 1e-30.
const deep_center = viewport.ComplexHi{
    .re = -0.743643887037158704752191506114774,
    .im = 0.131825904205311970493132056385139,
};

test "acceptance: a view at side 1e-30 renders varied detail" {
    const view = try viewport.SquareView.fromCenterSide(deep_center, 1.0e-30);
    var eng = try engine.Engine.init(testing.allocator, view, 8, .{});
    defer eng.deinit();
    try eng.iterate();

    var seen = std.AutoHashMap(u32, void).init(testing.allocator);
    defer seen.deinit();
    for (eng.iter) |v| try seen.put(@bitCast(v), {});

    // 64 pixels; the prototype measured 1021/1024 distinct at this depth. A quantized
    // render collapses to a handful of values, so 56 separates "resolved" from "blocks".
    try testing.expect(seen.count() >= 56);
}

test "acceptance: at the switch threshold the deep path matches full precision" {
    const max_iter: u32 = 4096;
    var orbit = try perturb.ReferenceOrbit.compute(testing.allocator, deep_center, max_iter);
    defer orbit.deinit(testing.allocator);

    const side: f64 = perturb.threshold_side; // 1e-6
    const n = 16;
    const scale = side / @as(f64, @floatFromInt(n));
    for (0..n) |row| {
        for (0..n) |col| {
            const dc_re = (@as(f64, @floatFromInt(col)) + 0.5 - n / 2.0) * scale;
            const dc_im = (n / 2.0 - @as(f64, @floatFromInt(row)) - 0.5) * scale;
            const got = perturb.iterateDelta(orbit, dc_re, dc_im, max_iter);
            const want = mandelbrot.iterateExact(
                deep_center.re + @as(f128, dc_re),
                deep_center.im + @as(f128, dc_im),
                max_iter,
            );
            try testing.expectEqual(want == mandelbrot.interior_sentinel, got == mandelbrot.interior_sentinel);
            if (want != mandelbrot.interior_sentinel) {
                try testing.expectApproxEqAbs(want, got, 1.0);
            }
        }
    }
}

test "acceptance: at 1e-25 the deep path matches full-precision classification" {
    const max_iter: u32 = 65536;
    var orbit = try perturb.ReferenceOrbit.compute(testing.allocator, deep_center, max_iter);
    defer orbit.deinit(testing.allocator);

    const side: f64 = 1.0e-25;
    const n = 16;
    const scale = side / @as(f64, @floatFromInt(n));
    var error_sum: f64 = 0.0;
    var counted: u32 = 0;
    for (0..n) |row| {
        for (0..n) |col| {
            const dc_re = (@as(f64, @floatFromInt(col)) + 0.5 - n / 2.0) * scale;
            const dc_im = (n / 2.0 - @as(f64, @floatFromInt(row)) - 0.5) * scale;
            const got = perturb.iterateDelta(orbit, dc_re, dc_im, max_iter);
            const want = mandelbrot.iterateExact(
                deep_center.re + @as(f128, dc_re),
                deep_center.im + @as(f128, dc_im),
                max_iter,
            );
            // Classification must be exact: a glitched pixel is one that lands on the
            // wrong side of "escapes at all".
            try testing.expectEqual(want == mandelbrot.interior_sentinel, got == mandelbrot.interior_sentinel);
            if (want != mandelbrot.interior_sentinel) {
                error_sum += @abs(@as(f64, want) - @as(f64, got));
                counted += 1;
            }
        }
    }
    // Measured 1.66 on the dialog prototype. Chaotic amplification near the boundary makes a
    // handful of pixels differ by more; the MEAN is what distinguishes correct-with-noise
    // from broken.
    try testing.expect(counted > 0);
    try testing.expect(error_sum / @as(f64, @floatFromInt(counted)) < 5.0);
}

var gpu_calls: u32 = 0;

fn countingIterFn(
    view: viewport.SquareView,
    image_w: u32,
    image_h: u32,
    max_iter: u32,
    y0: u32,
    rows: u32,
    iter_band: []f32,
    orbit: ?*const perturb.ReferenceOrbit,
) anyerror!void {
    gpu_calls += 1;
    const vp = view.rectViewport(image_w, image_h);
    if (orbit) |o| return iterbuf.iterateDeepBandInto(iter_band, vp, max_iter, y0, rows, o);
    return iterbuf.iterateBandInto(iter_band, vp, max_iter, y0, rows);
}

test "acceptance: past the GPU floor the engine renders on the CPU" {
    const deep = try viewport.SquareView.fromCenterSide(deep_center, 1.0e-25);
    var eng = try engine.Engine.init(testing.allocator, deep, 8, .{});
    defer eng.deinit();
    eng.gpu_iter_fn = &countingIterFn;
    eng.use_gpu = true;

    gpu_calls = 0;
    try eng.iterate();

    try testing.expectEqual(@as(u32, 0), gpu_calls);
    try testing.expect(eng.iteration_passes == 1);

    var buf: [perturb.fallback_message_buf_len]u8 = undefined;
    const msg = try perturb.gpuFallbackMessage(&buf, .below_gpu_precision_floor);
    try testing.expect(std.mem.indexOf(u8, msg, "CPU") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "1e-20") != null);
}

test "acceptance: a 30-decimal center round-trips through the view" {
    const typed = "-0.743643887037158704752191506114774";

    var ve = editor.ViewEditor.initFromView(
        try viewport.SquareView.fromCenterSide(deep_center, 1.0e-25),
    );
    ve.center_re_buf = std.mem.zeroes(@TypeOf(ve.center_re_buf));
    @memcpy(ve.center_re_buf[0..typed.len], typed);

    const applied = ve.parseAndApplyCenterMag() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(try std.fmt.parseFloat(f128, typed), applied.center_re);
}

test "acceptance: a cursor-anchored zoom at 1e-25 keeps full precision" {
    const v = try viewport.SquareView.fromCenterSide(deep_center, 1.0e-25);
    const image_side: u32 = 1000;
    // One pixel to the RIGHT of the image center: a ~1e-28 offset in the complex plane.
    const anchor = v.pixelToComplexHi(501.0, 500.0, image_side);

    const zoomed = try navigate.zoomCentered(v, anchor, 0.5);

    try testing.expect(zoomed.center_re != v.center_re);
    try testing.expect(zoomed.center_re > v.center_re);
}
