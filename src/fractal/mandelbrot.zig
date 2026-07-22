//! Pure Mandelbrot iteration + smooth (fractional) escape value. NO SDL/GPU
//! imports — this lives in the fast test tier (`zig build test`, no window/device)
//! and is fully unit-tested. No allocation, no global state, deterministic.
//!
//! The heart of the fractal: iterate `z = z² + c` starting from `z = 0` and return
//! a CONTINUOUS escape value, not an integer count. Integer counts band the image;
//! only the fractional value can be fixed up into a smooth gradient downstream (T5).
//!
//! ─── Constants M1's GPU shader MUST mirror exactly ───────────────────────────
//! The M1 compute shader has to reproduce these values bit-for-similar, so every
//! magic number here is a shared contract, spelled out and named:
//!
//!   * `bail_radius_squared = 4.0` — escape test is `|z|² > 4` (bail radius 2).
//!   * `extra_iterations = 2` — after the first step that crosses the bail radius
//!     we run two MORE `z = z² + c` steps before evaluating the smooth term. With a
//!     bail radius as small as 2, `|z|` at the crossing sits just above 2 and the
//!     smooth correction is coarse; each extra squaring roughly doubles `log₂|z|`
//!     while we also advance `n` by one, so `n − log₂(log₂|z|)` stays (near-)
//!     invariant but far more accurate. This is the "iterate a few extra steps"
//!     option from the task (equivalent in intent to raising the bail radius).
//!   * Smooth value = `n + 1 − log₂(log₂(|z|))`, evaluated on the enlarged `|z|`
//!     and the advanced `n`. `|z| = sqrt(|z|²)`.
//!   * Interior sentinel = `-1.0` — returned when `max_iter` is reached without
//!     escaping. Distinct from every escaped value (escaped values are ≥ 0 for the
//!     fixed viewport's `|c| ≤ ~2.8`; see the NaN/Inf guard for pathological `c`).
const std = @import("std");

/// Escape threshold on the SQUARED modulus — avoids a sqrt in the hot loop.
/// Bail radius 2 ⇒ `|z|² > 4`. Shared with M1's shader.
pub const bail_radius_squared: f64 = 4.0;

/// Number of extra `z = z² + c` steps taken after the escape crossing to stabilise
/// the smooth value at this small bail radius. Shared with M1's shader.
pub const extra_iterations: u32 = 2;

/// Value returned for interior points (reached `max_iter` without escaping).
pub const interior_sentinel: f32 = -1.0;

/// Iterate `z = z² + c` from `z = 0` and return the smooth escape value
/// `n + 1 − log₂(log₂(|z|))` for escaping points, or `interior_sentinel` (`-1.0`)
/// for points that survive `max_iter` iterations.
///
/// Inputs are `f64` (the coordinate mapping in `viewport.zig` produces `f64`);
/// the result is `f32` to match M1's `R32Float` iteration buffer. Pure and
/// deterministic: no allocation, no global state, no I/O.
pub fn iterate(c_re: f64, c_im: f64, max_iter: u32) f32 {
    var z_re: f64 = 0.0;
    var z_im: f64 = 0.0;

    // Main escape loop. `n` counts completed `z = z² + c` steps. We test the bail
    // radius AFTER stepping so `n` is the count at the moment of crossing.
    var n: u32 = 0;
    var escaped = false;
    while (n < max_iter) {
        const next_re = z_re * z_re - z_im * z_im + c_re;
        const next_im = 2.0 * z_re * z_im + c_im;
        z_re = next_re;
        z_im = next_im;
        n += 1;
        if (z_re * z_re + z_im * z_im > bail_radius_squared) {
            escaped = true;
            break;
        }
    }

    // Survived to max_iter without escaping ⇒ interior point.
    if (!escaped) return interior_sentinel;

    // `n` at the crossing — a finite, ≥ 1 fallback if the smooth term degenerates.
    const escape_n = n;

    // Extra iterations grow `|z|` well past the bail radius so the double-log is
    // accurate; advance `n` in lockstep so the smooth formula stays consistent.
    var extra: u32 = 0;
    while (extra < extra_iterations) : (extra += 1) {
        const next_re = z_re * z_re - z_im * z_im + c_re;
        const next_im = 2.0 * z_re * z_im + c_im;
        z_re = next_re;
        z_im = next_im;
        n += 1;
    }

    const mag_squared = z_re * z_re + z_im * z_im;
    const magnitude = @sqrt(mag_squared);
    const smooth = @as(f64, @floatFromInt(n)) + 1.0 - std.math.log2(std.math.log2(magnitude));

    // Guard: a wildly fast escape (huge `|c|`) can overflow `|z|` to Inf during the
    // extra steps, or produce a NaN from Inf−Inf, making the double-log non-finite.
    // Those `c` never occur in the fixed viewport, but the core must not leak
    // NaN/Inf into the buffer. Fall back to the plain escape count: finite, ≥ 1,
    // and clearly distinct from the interior sentinel.
    if (!std.math.isFinite(smooth)) return @floatFromInt(escape_n);

    return @floatCast(smooth);
}

test "origin never escapes and returns the interior sentinel" {
    try std.testing.expectEqual(interior_sentinel, iterate(0.0, 0.0, 512));
}

test "a point well outside the set returns a small positive escaped value" {
    const v = iterate(2.0, 2.0, 512);
    try std.testing.expect(v != interior_sentinel);
    try std.testing.expect(v > 0.0);
}

test "a point inside the main cardioid returns the interior sentinel" {
    // c = -0.5 satisfies |1 - sqrt(1 - 4c)| < 1 ⇒ inside the main cardioid.
    try std.testing.expectEqual(interior_sentinel, iterate(-0.5, 0.0, 512));
}

test "a point just outside the cardioid cusp escapes — boundary is distinguishable" {
    // The set meets the real axis in [-2, 0.25]; c = 0.3 is just past the cusp.
    const v = iterate(0.3, 0.0, 512);
    try std.testing.expect(v != interior_sentinel);
    try std.testing.expect(v > 0.0);
}

test "the smooth value is fractional, not an integer count" {
    const v = iterate(2.0, 2.0, 512);
    try std.testing.expect(v != @floor(v));
}

test "the smooth value increases as c approaches the set boundary" {
    // c = 0.3 is nearer the boundary (0.25) than c = 1.0, so it escapes later
    // and must yield the larger smooth value.
    const near = iterate(0.3, 0.0, 512);
    const far = iterate(1.0, 0.0, 512);
    try std.testing.expect(near > far);
}

test "fast-escaping points never return NaN or Inf" {
    // Extremely large c forces an escape on the first step and huge |z| during the
    // extra iterations; the result must still be finite (or the sentinel).
    const v = iterate(1.0e6, 1.0e6, 512);
    try std.testing.expect(std.math.isFinite(v) or v == interior_sentinel);
}

test "iterate is deterministic for repeated identical input" {
    try std.testing.expectEqual(iterate(0.3, 0.0, 512), iterate(0.3, 0.0, 512));
}
