//! Pure UI observability: render/frame stats aggregation + the startup summary
//! string + the image-fit math. NO ImGui/SDL/GPU imports — this lives in the fast
//! test tier (`zig build test`, no window/device) and is fully unit-tested. The
//! drawing code in `panels.zig` consumes these values; keeping the numbers and
//! strings pure is the milestone's standing requirement for testable observability.
const std = @import("std");

/// Nanoseconds in one millisecond.
const ns_per_ms: f64 = 1_000_000.0;

/// Convert a wall-clock nanosecond duration to milliseconds. Pure, deterministic.
pub fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / ns_per_ms;
}

/// Read-only render/frame statistics shown in the data panel. NO ImGui/GPU deps so
/// the aggregation stays unit-testable.
pub const Stats = struct {
    /// CPU Mandelbrot render time (ms), from the one-time startup render.
    render_ms: f64,
    /// Most recent frame time (ms).
    frame_ms: f64,
    /// GPU compute dispatches issued this milestone. Always 0 in M0.
    dispatch_count: u32,
    /// GPU iteration time (ms) for the last GPU dispatch. 0 when CPU path is active.
    gpu_render_ms: f64,

    /// Build stats from the startup render's elapsed nanoseconds. Frame time starts
    /// at 0 (no frame measured yet); dispatch count at 0 (M0 has no GPU compute).
    pub fn fromRender(render_elapsed_ns: u64) Stats {
        return .{ .render_ms = nsToMs(render_elapsed_ns), .frame_ms = 0.0, .dispatch_count = 0, .gpu_render_ms = 0.0 };
    }

    /// Record the latest frame duration (ns). Touches only `frame_ms`.
    pub fn observeFrame(self: *Stats, frame_elapsed_ns: u64) void {
        self.frame_ms = nsToMs(frame_elapsed_ns);
    }
};

/// A fitted image size in pixels (framebuffer units), returned by `containSize`.
pub const Size = struct { w: f32, h: f32 };

/// Largest size that fits `(img_w, img_h)` inside `(region_w, region_h)` while
/// preserving the image's aspect ratio (letterbox — never stretch). Pure math for
/// the fractal image region so the scaling is testable without ImGui. A non-positive
/// region or image collapses to zero.
pub fn containSize(img_w: f32, img_h: f32, region_w: f32, region_h: f32) Size {
    if (region_w <= 0 or region_h <= 0 or img_w <= 0 or img_h <= 0) return .{ .w = 0, .h = 0 };
    const scale = @min(region_w / img_w, region_h / img_h);
    return .{ .w = img_w * scale, .h = img_h * scale };
}

/// Build the startup success-summary line logged once the Mandelbrot has rendered:
/// `"rendered {w}x{h} Mandelbrot, max_iter={n}, in {ms} ms"`. Pure so it is
/// unit-tested without a window/GPU; `elapsed_ns` is converted to ms (2 decimals).
pub fn renderSummary(buf: []u8, width: u32, height: u32, max_iter: u32, elapsed_ns: u64) ![]u8 {
    return std.fmt.bufPrint(
        buf,
        "rendered {d}x{d} Mandelbrot, max_iter={d}, in {d:.2} ms",
        .{ width, height, max_iter, nsToMs(elapsed_ns) },
    );
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "nsToMs converts nanoseconds to milliseconds" {
    try testing.expectEqual(@as(f64, 1.0), nsToMs(1_000_000));
    try testing.expectEqual(@as(f64, 2.5), nsToMs(2_500_000));
    try testing.expectEqual(@as(f64, 0.0), nsToMs(0));
}

test "Stats.fromRender sets render_ms and zeroes frame_ms, dispatch_count, and gpu_render_ms" {
    const s = Stats.fromRender(12_345_678);
    try testing.expectApproxEqAbs(@as(f64, 12.345678), s.render_ms, 1e-9);
    try testing.expectEqual(@as(f64, 0.0), s.frame_ms);
    try testing.expectEqual(@as(u32, 0), s.dispatch_count);
    try testing.expectEqual(@as(f64, 0.0), s.gpu_render_ms);
}

test "Stats.observeFrame updates only frame_ms" {
    var s = Stats.fromRender(5_000_000);
    s.observeFrame(3_000_000);
    try testing.expectEqual(@as(f64, 3.0), s.frame_ms);
    try testing.expectEqual(@as(f64, 5.0), s.render_ms); // unchanged
    try testing.expectEqual(@as(u32, 0), s.dispatch_count); // unchanged
}

test "containSize is limited by height when the region is wider than the image aspect" {
    // image 2:1, region 10x2 (much wider) => height-bound: h=2, w=4.
    const fit = containSize(200, 100, 10, 2);
    try testing.expectApproxEqAbs(@as(f32, 4.0), fit.w, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2.0), fit.h, 1e-4);
}

test "containSize is limited by width when the region is taller than the image aspect" {
    // image 2:1, region 4x10 (much taller) => width-bound: w=4, h=2.
    const fit = containSize(200, 100, 4, 10);
    try testing.expectApproxEqAbs(@as(f32, 4.0), fit.w, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2.0), fit.h, 1e-4);
}

test "containSize preserves the image aspect ratio exactly" {
    const fit = containSize(1050, 750, 700, 700);
    try testing.expectApproxEqAbs(@as(f32, 1050.0) / 750.0, fit.w / fit.h, 1e-4);
}

test "containSize collapses to zero for a non-positive region" {
    try testing.expectEqual(Size{ .w = 0, .h = 0 }, containSize(100, 100, 0, 50));
    try testing.expectEqual(Size{ .w = 0, .h = 0 }, containSize(100, 100, 50, -1));
}

test "renderSummary formats the success-summary line with ms to two decimals" {
    var buf: [128]u8 = undefined;
    const line = try renderSummary(&buf, 1050, 750, 512, 42_500_000);
    try testing.expectEqualStrings("rendered 1050x750 Mandelbrot, max_iter=512, in 42.50 ms", line);
}
