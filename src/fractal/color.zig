//! Pure smooth-value → RGBA8 mapping. NO SDL/GPU imports — this lives in the fast
//! test tier (`zig build test`, no window/device) and is fully unit-tested. No
//! allocation, no global state, deterministic.
//!
//! M0 STOPGAP: this is a plain grayscale ramp with a distinct interior color. The
//! full 1D-LUT / gradient color pass is M2. `smoothToRgba`'s SIGNATURE is stable so
//! M2 can add a LUT-based sibling (e.g. `smoothToRgbaLut`) beside it and swap the
//! render loop's call site without reshaping callers.
//!
//! Mapping contract:
//!   * Interior sentinel (`mandelbrot.interior_sentinel` == `-1.0`) → opaque black
//!     `{0, 0, 0, 255}`. This is the documented interior color.
//!   * Escaped values → grayscale, normalized against the FIXED reference `max_iter`:
//!     `t = clamp(smooth / max_iter, 0, 1)`, channel = `round(t * 255)`. Linear, not
//!     histogram-equalized (equalization arrives with the M2 color pipeline). So
//!     `smooth = 0` → black, `smooth = max_iter` → white; larger escaped values are
//!     never darker (monotonic).
//!   * Alpha is ALWAYS 255 — the image is fully opaque.
//!   * The normalization is CLAMPED to `[0, 1]` before the byte conversion, so an
//!     out-of-range `smooth` (a negative that is not the sentinel, or one above
//!     `max_iter`) saturates to black / white rather than producing a wrapped or
//!     garbage byte from `@intFromFloat`.
const std = @import("std");
const mandelbrot = @import("mandelbrot.zig");

/// A single pixel, channel order R, G, B, A. Matches the `R8G8B8A8` texture the GPU
/// path uploads in T7.
pub const Rgba8 = [4]u8;

/// The documented interior color: opaque black. Returned for the interior sentinel.
pub const interior_color: Rgba8 = .{ 0, 0, 0, 255 };

/// Map a smooth iteration value to an RGBA8 pixel. Pure and deterministic: no
/// allocation, no global state, no I/O.
///
/// `smooth` is the value produced by `mandelbrot.iterate`: `interior_sentinel`
/// (`-1.0`) for interior points, otherwise a continuous escaped value. `max_iter`
/// is the fixed normalization reference. See the file header for the full contract.
pub fn smoothToRgba(smooth: f32, max_iter: u32) Rgba8 {
    // Interior points get the distinct interior color, not the low end of the ramp.
    if (smooth == mandelbrot.interior_sentinel) return interior_color;

    // Normalize against the fixed reference and CLAMP before converting to a byte,
    // so out-of-range input saturates instead of wrapping / overflowing the u8.
    const reference: f32 = @floatFromInt(max_iter);
    const t = std.math.clamp(smooth / reference, 0.0, 1.0);
    const channel: u8 = @intFromFloat(@round(t * 255.0));

    return .{ channel, channel, channel, 255 };
}

test "the interior sentinel maps to the documented opaque-black interior color" {
    try std.testing.expectEqual(
        Rgba8{ 0, 0, 0, 255 },
        smoothToRgba(mandelbrot.interior_sentinel, 512),
    );
}

test "smooth = 0 maps to opaque black (low endpoint of the grayscale ramp)" {
    try std.testing.expectEqual(Rgba8{ 0, 0, 0, 255 }, smoothToRgba(0.0, 512));
}

test "smooth = max_iter maps to opaque white (high endpoint of the grayscale ramp)" {
    try std.testing.expectEqual(Rgba8{ 255, 255, 255, 255 }, smoothToRgba(512.0, 512));
}

test "escaped grayscale is monotonic: a larger smooth value is never darker" {
    const darker = smoothToRgba(100.0, 512);
    const lighter = smoothToRgba(300.0, 512);
    try std.testing.expect(lighter[0] >= darker[0]);
}

test "an out-of-range negative (not the sentinel) clamps to black, not a wrapped byte" {
    const px = smoothToRgba(-5.0, 512);
    try std.testing.expectEqual(Rgba8{ 0, 0, 0, 255 }, px);
}

test "an out-of-range value above max_iter clamps to white, not a wrapped byte" {
    const px = smoothToRgba(10_000.0, 512);
    try std.testing.expectEqual(Rgba8{ 255, 255, 255, 255 }, px);
}

test "alpha is always fully opaque for a mid-ramp escaped value" {
    try std.testing.expectEqual(@as(u8, 255), smoothToRgba(256.0, 512)[3]);
}

test "smoothToRgba is deterministic for repeated identical input" {
    try std.testing.expectEqual(smoothToRgba(123.5, 512), smoothToRgba(123.5, 512));
}
