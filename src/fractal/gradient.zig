//! Pure gradient-stop model + 1024-texel RGBA8 LUT baking. NO SDL/GPU/log imports —
//! this lives in the fast test tier (`zig build test`, no window/device) and is fully
//! unit-tested. No allocation, no global state, deterministic.
//!
//! The palette is authored as a small ORDERED set of gradient `Stop`s (position in
//! `[0,1]` + an `Rgba8` color) and BAKED once into a `lut_size`-entry RGBA8 lookup
//! table. The color pass (T4) then indexes that table cheaply per pixel; editing the
//! palette (T6) just re-bakes — it never re-runs the Mandelbrot iteration. This is the
//! data model the gradient editor mutates.
//!
//! Storage / ordering invariant: `Gradient` holds its stops in a fixed-capacity array
//! (`max_stops`) kept in ASCENDING `pos` order. `bakeLut` relies on that order to find
//! the two bracketing stops for a given `t`; `fromStops` documents (and debug-asserts)
//! the ascending precondition. A fixed array keeps the module allocation-free while
//! still letting the editor add/remove stops up to `max_stops`.
//!
//! Bake contract (plan A3):
//!   * `lut_size == 1024` texels. For texel `i`, `t = i / (lut_size - 1)` so `i == 0`
//!     maps to `t == 0` and `i == lut_size-1` maps to `t == 1` exactly.
//!   * For a `t` between two stops, each channel is LINEARLY interpolated between the
//!     bracketing stops' colors.
//!   * For `t` at or before the first stop's `pos`, the texel clamps to the FIRST
//!     stop's color; at or after the last stop's `pos`, it clamps to the LAST stop's
//!     color. (Ends are held, never extrapolated.)
//!
//! Alpha convention: alpha is interpolated per-channel exactly like R/G/B — it is NOT
//! forced. The default palette (and every stop callers are expected to author) uses
//! alpha `255`, so a default-derived LUT is fully opaque; a caller that authors a
//! translucent stop gets a translucent, interpolated alpha. Interior points are colored
//! outside this LUT (plan A5), so LUT alpha is a pure per-stop property.
const std = @import("std");
const color = @import("color.zig");

/// Reused verbatim from `color.zig` (M0). Channel order R, G, B, A. Do not redefine.
pub const Rgba8 = color.Rgba8;

/// Number of texels in a baked LUT (plan A3). Fixed by the spec.
pub const lut_size = 1024;

/// Maximum number of stops a `Gradient` can hold. Fixed capacity keeps the module
/// allocation-free; the editor (T6) adds/removes stops within this bound.
pub const max_stops = 32;

/// A single gradient control point: a color anchored at `pos` on the `[0,1]` axis.
/// `pos` outside `[0,1]` is meaningless for baking (all texels sample `t` in `[0,1]`)
/// and should not be authored; `fromStops` debug-asserts the range.
pub const Stop = struct {
    pos: f32,
    color: Rgba8,
};

/// An ordered palette: `count` stops (ascending `pos`) in a fixed-capacity array.
pub const Gradient = struct {
    stops_buf: [max_stops]Stop = undefined,
    count: usize = 0,

    /// Build a `Gradient` from a slice of stops. PRECONDITION (debug-asserted): at
    /// least one stop, at most `max_stops`, each `pos` in `[0,1]`, and the slice is
    /// sorted ASCENDING by `pos`. The bake relies on that order.
    pub fn fromStops(list: []const Stop) Gradient {
        std.debug.assert(list.len >= 1 and list.len <= max_stops);
        var g = Gradient{ .count = list.len };
        var prev: f32 = -std.math.inf(f32);
        for (list, 0..) |s, i| {
            std.debug.assert(s.pos >= 0.0 and s.pos <= 1.0);
            std.debug.assert(s.pos >= prev); // ascending
            prev = s.pos;
            g.stops_buf[i] = s;
        }
        return g;
    }

    /// The active stops, ascending by `pos`.
    pub fn stops(self: *const Gradient) []const Stop {
        return self.stops_buf[0..self.count];
    }
};

/// Linearly interpolate each channel (R, G, B AND A) between `a` and `b` at `t` in
/// `[0,1]`, rounding to the nearest byte. `t == 0` yields `a`, `t == 1` yields `b`.
fn lerpChannel(a: Rgba8, b: Rgba8, t: f32) Rgba8 {
    var out: Rgba8 = undefined;
    inline for (0..4) |k| {
        const av: f32 = @floatFromInt(a[k]);
        const bv: f32 = @floatFromInt(b[k]);
        const v = av + (bv - av) * t;
        // Clamp defensively before the byte conversion (t is in-range, but this keeps
        // any float rounding from ever tripping @intFromFloat on an out-of-u8 value).
        out[k] = @intFromFloat(@round(std.math.clamp(v, 0.0, 255.0)));
    }
    return out;
}

/// Sample the gradient at `t` (expected in `[0,1]`), clamping to the end stops outside
/// the `[first.pos, last.pos]` range. Assumes `list` is non-empty and ascending.
fn sampleAt(list: []const Stop, t: f32) Rgba8 {
    const first = list[0];
    const last = list[list.len - 1];
    if (t <= first.pos) return first.color; // clamp before the first stop
    if (t >= last.pos) return last.color; // clamp after the last stop

    // Find the bracketing pair [list[j-1], list[j]] with list[j-1].pos < t <= list[j].pos.
    var j: usize = 1;
    while (j < list.len) : (j += 1) {
        const lo = list[j - 1];
        const hi = list[j];
        if (t <= hi.pos) {
            const span = hi.pos - lo.pos;
            // Coincident stops (span == 0): take the lower color rather than divide by 0.
            const local = if (span > 0.0) (t - lo.pos) / span else 0.0;
            return lerpChannel(lo.color, hi.color, local);
        }
    }
    return last.color; // unreachable: t < last.pos handled above
}

/// Bake `gradient` into exactly `lut_size` RGBA8 texels. For texel `i`,
/// `t = i / (lut_size - 1)`; the color is the per-channel linear interpolation of the
/// bracketing stops, clamped to the end colors outside the stop range (see file header).
/// Pure and deterministic. `gradient` must hold at least one stop.
pub fn bakeLut(gradient: Gradient, out: *[lut_size]Rgba8) void {
    const list = gradient.stops();
    std.debug.assert(list.len >= 1);
    const denom: f32 = @floatFromInt(lut_size - 1);
    var i: usize = 0;
    while (i < lut_size) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / denom;
        out[i] = sampleAt(list, t);
    }
}

/// The default multi-stop fractal palette (plan A4): the classic
/// deep-blue → blue → white → orange → dark cycle. Five stops spanning `t = 0..1`, all
/// fully opaque. Editable in-app (T6).
pub fn default() Gradient {
    return Gradient.fromStops(&.{
        .{ .pos = 0.00, .color = .{ 0, 7, 60, 255 } }, // deep blue
        .{ .pos = 0.25, .color = .{ 32, 107, 203, 255 } }, // blue
        .{ .pos = 0.50, .color = .{ 237, 255, 255, 255 } }, // white
        .{ .pos = 0.75, .color = .{ 255, 170, 0, 255 } }, // orange
        .{ .pos = 1.00, .color = .{ 0, 2, 20, 255 } }, // dark
    });
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const black: Rgba8 = .{ 0, 0, 0, 255 };
const white: Rgba8 = .{ 255, 255, 255, 255 };

test "bakeLut produces exactly 1024 texels" {
    // The array type itself pins the count; assert the constant the spec fixes (A3).
    try std.testing.expectEqual(@as(usize, 1024), lut_size);
    var lut: [lut_size]Rgba8 = undefined;
    bakeLut(default(), &lut);
    try std.testing.expectEqual(@as(usize, 1024), lut.len);
}

test "two-stop LUT: texel 0 is the first color and texel 1023 is the last color" {
    const g = Gradient.fromStops(&.{
        .{ .pos = 0.0, .color = black },
        .{ .pos = 1.0, .color = white },
    });
    var lut: [lut_size]Rgba8 = undefined;
    bakeLut(g, &lut);
    try std.testing.expectEqual(black, lut[0]);
    try std.testing.expectEqual(white, lut[lut_size - 1]);
}

test "two-stop LUT: the midpoint texel is the per-channel average (interpolation)" {
    const g = Gradient.fromStops(&.{
        .{ .pos = 0.0, .color = Rgba8{ 0, 0, 0, 255 } },
        .{ .pos = 1.0, .color = Rgba8{ 200, 100, 50, 255 } },
    });
    var lut: [lut_size]Rgba8 = undefined;
    bakeLut(g, &lut);
    // Texel 511 samples t ≈ 0.4995, the closest texel to the geometric midpoint.
    const mid = lut[511];
    try std.testing.expectApproxEqAbs(@as(f32, 100), @as(f32, @floatFromInt(mid[0])), 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 50), @as(f32, @floatFromInt(mid[1])), 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 25), @as(f32, @floatFromInt(mid[2])), 1.0);
}

test "texels before the first stop clamp to the first stop's color" {
    // First stop sits at t=0.25, so every texel with t < 0.25 must hold its color.
    const g = Gradient.fromStops(&.{
        .{ .pos = 0.25, .color = Rgba8{ 10, 20, 30, 255 } },
        .{ .pos = 1.0, .color = white },
    });
    var lut: [lut_size]Rgba8 = undefined;
    bakeLut(g, &lut);
    try std.testing.expectEqual(Rgba8{ 10, 20, 30, 255 }, lut[0]);
}

test "texels after the last stop clamp to the last stop's color" {
    // Last stop sits at t=0.75, so every texel with t > 0.75 must hold its color.
    const g = Gradient.fromStops(&.{
        .{ .pos = 0.0, .color = black },
        .{ .pos = 0.75, .color = Rgba8{ 200, 40, 90, 255 } },
    });
    var lut: [lut_size]Rgba8 = undefined;
    bakeLut(g, &lut);
    try std.testing.expectEqual(Rgba8{ 200, 40, 90, 255 }, lut[lut_size - 1]);
}

test "a single-color gradient bakes a uniform LUT" {
    const c = Rgba8{ 77, 88, 99, 255 };
    const g = Gradient.fromStops(&.{
        .{ .pos = 0.0, .color = c },
        .{ .pos = 1.0, .color = c },
    });
    var lut: [lut_size]Rgba8 = undefined;
    bakeLut(g, &lut);
    for (lut) |texel| try std.testing.expectEqual(c, texel);
}

test "a one-effective-stop gradient bakes a uniform LUT" {
    const c = Rgba8{ 12, 34, 56, 255 };
    const g = Gradient.fromStops(&.{.{ .pos = 0.5, .color = c }});
    var lut: [lut_size]Rgba8 = undefined;
    bakeLut(g, &lut);
    for (lut) |texel| try std.testing.expectEqual(c, texel);
}

test "default() returns a palette with at least 3 stops covering t=0..1" {
    const g = default();
    const s = g.stops();
    try std.testing.expect(s.len >= 3);
    try std.testing.expectEqual(@as(f32, 0.0), s[0].pos);
    try std.testing.expectEqual(@as(f32, 1.0), s[s.len - 1].pos);
}

test "default() stops are stored in ascending position order" {
    const s = default().stops();
    var i: usize = 1;
    while (i < s.len) : (i += 1) try std.testing.expect(s[i].pos >= s[i - 1].pos);
}

test "baking the default palette is deterministic" {
    var a: [lut_size]Rgba8 = undefined;
    var b: [lut_size]Rgba8 = undefined;
    bakeLut(default(), &a);
    bakeLut(default(), &b);
    try std.testing.expectEqualSlices(Rgba8, &a, &b);
}

test "alpha is interpolated per-channel: opaque endpoints yield a fully opaque LUT" {
    // Documented convention: alpha follows RGB. The default palette is all-255, so the
    // whole baked LUT is opaque.
    var lut: [lut_size]Rgba8 = undefined;
    bakeLut(default(), &lut);
    for (lut) |texel| try std.testing.expectEqual(@as(u8, 255), texel[3]);
}

test "alpha is interpolated, not forced: a translucent stop produces a translucent midpoint" {
    const g = Gradient.fromStops(&.{
        .{ .pos = 0.0, .color = Rgba8{ 0, 0, 0, 0 } },
        .{ .pos = 1.0, .color = Rgba8{ 0, 0, 0, 200 } },
    });
    var lut: [lut_size]Rgba8 = undefined;
    bakeLut(g, &lut);
    try std.testing.expectApproxEqAbs(@as(f32, 100), @as(f32, @floatFromInt(lut[511][3])), 1.0);
}

test "the reused Rgba8 is color.Rgba8, not a redefined type" {
    try std.testing.expectEqual(color.Rgba8, Rgba8);
}
