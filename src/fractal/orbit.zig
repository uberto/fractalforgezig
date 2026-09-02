//! Pure orbit sequence for the M10 orbit inspector. NO SDL/GPU/ImGui imports —
//! this lives in the fast test tier (`zig build test`, no window/device) and is
//! fully unit-tested. No allocation, no global state, deterministic.
//!
//! Generates the successive iterates of the Mandelbrot map for a point `c`:
//! `z₀ = 0`, `z₁ = z₀² + c = c`, `z₂ = z₁² + c`, … into a caller-owned buffer.
//! The plotting (draw list, connect-lines toggle, mini-Mandelbrot backdrop) is
//! glue in T4 and deals in screen space; this module deals only in complex-plane
//! coordinates.
//!
//! Length convention (pinned by M10's acceptance tests): a cap `max_iter` writes
//! `z₀` plus up to `max_iter` further iterates, so an interior point fills the
//! buffer to `max_iter + 1` points. The caller sizes `out` at `max_iter + 1`.
const std = @import("std");
const mandelbrot = @import("mandelbrot.zig");

/// Outcome of `compute`: how many points landed in `out` (including `z₀`) and
/// whether the orbit ended by crossing the escape radius (vs. filling the cap).
pub const Result = struct { points_written: usize, escaped: bool };

/// Fill `out` with the orbit of `c` under z → z² + c, starting z₀ = 0.
///
/// Writes `out[0] = {0, 0}`, then for each step computes `z = z² + c`, writes it,
/// and tests the escape radius. Stops early when `|z|² > bail_radius_squared`
/// (writing the escaping point, `escaped = true`), or when `out` is full (with
/// whatever `escaped` state holds). `out` must hold at least `max_iter + 1`
/// points; the caller sizes it so. A shorter `out` is clamped to its length —
/// never an out-of-bounds write.
pub fn compute(c_re: f64, c_im: f64, max_iter: u32, out: [][2]f64) Result {
    if (out.len == 0) return .{ .points_written = 0, .escaped = false };

    out[0] = .{ 0.0, 0.0 };
    var written: usize = 1;

    var z_re: f64 = 0.0;
    var z_im: f64 = 0.0;
    var n: u32 = 0;
    while (n < max_iter) : (n += 1) {
        if (written >= out.len) break; // buffer full: clamp, no out-of-bounds write.

        const next_re = z_re * z_re - z_im * z_im + c_re;
        const next_im = 2.0 * z_re * z_im + c_im;
        z_re = next_re;
        z_im = next_im;
        out[written] = .{ z_re, z_im };
        written += 1;

        if (z_re * z_re + z_im * z_im > mandelbrot.bail_radius_squared) {
            return .{ .points_written = written, .escaped = true };
        }
    }
    return .{ .points_written = written, .escaped = false };
}

test "the orbit starts at the origin and its second point is c" {
    var buf: [33][2]f64 = undefined;
    const c_re = -0.5;
    const c_im = 0.25;
    const r = compute(c_re, c_im, 32, &buf);

    try std.testing.expect(r.points_written >= 2);
    try std.testing.expectEqual(@as(f64, 0.0), buf[0][0]);
    try std.testing.expectEqual(@as(f64, 0.0), buf[0][1]);
    try std.testing.expectEqual(c_re, buf[1][0]);
    try std.testing.expectEqual(c_im, buf[1][1]);
}

test "an escaping point is marked escaped and ends before the cap" {
    var buf: [33][2]f64 = undefined;
    const r = compute(2.0, 0.0, 32, &buf);

    try std.testing.expect(r.escaped);
    try std.testing.expect(r.points_written < 33);
}

test "the escaping point itself is the last one written" {
    // c = 2 escapes on the second step (z₁ = 2, z₂ = 6); |z₂|² = 36 > 4, so the
    // last written point must sit outside the bail radius.
    var buf: [33][2]f64 = undefined;
    const r = compute(2.0, 0.0, 32, &buf);

    const last = buf[r.points_written - 1];
    try std.testing.expect(last[0] * last[0] + last[1] * last[1] > mandelbrot.bail_radius_squared);
}

test "an interior point fills the buffer to max_iter + 1 points" {
    var buf: [33][2]f64 = undefined;
    const r = compute(0.0, 0.0, 32, &buf);

    try std.testing.expect(!r.escaped);
    try std.testing.expectEqual(@as(usize, 33), r.points_written);
}

test "a buffer shorter than max_iter + 1 is clamped, never overrun" {
    // 5-slot buffer with a 32-cap interior point: must stop at the buffer length,
    // report not escaped, and leave the guard bytes untouched.
    var buf: [6][2]f64 = undefined;
    const guard = [2]f64{ 111.0, 222.0 };
    buf[5] = guard;
    const window = buf[0..5];

    const r = compute(0.0, 0.0, 32, window);

    try std.testing.expectEqual(@as(usize, 5), r.points_written);
    try std.testing.expect(!r.escaped);
    try std.testing.expectEqual(guard[0], buf[5][0]);
    try std.testing.expectEqual(guard[1], buf[5][1]);
}

test "a zero-length buffer writes nothing and reports no points" {
    var buf: [0][2]f64 = undefined;
    const r = compute(0.0, 0.0, 32, &buf);

    try std.testing.expectEqual(@as(usize, 0), r.points_written);
    try std.testing.expect(!r.escaped);
}

test "a max_iter of zero writes only the origin" {
    var buf: [33][2]f64 = undefined;
    const r = compute(-0.5, 0.25, 0, &buf);

    try std.testing.expectEqual(@as(usize, 1), r.points_written);
    try std.testing.expect(!r.escaped);
    try std.testing.expectEqual(@as(f64, 0.0), buf[0][0]);
    try std.testing.expectEqual(@as(f64, 0.0), buf[0][1]);
}

test "compute is deterministic for repeated identical input" {
    var a: [33][2]f64 = undefined;
    var b: [33][2]f64 = undefined;
    const ra = compute(-0.5, 0.25, 32, &a);
    const rb = compute(-0.5, 0.25, 32, &b);

    try std.testing.expectEqual(ra.points_written, rb.points_written);
    try std.testing.expectEqual(ra.escaped, rb.escaped);
    try std.testing.expectEqualSlices([2]f64, a[0..ra.points_written], b[0..rb.points_written]);
}
