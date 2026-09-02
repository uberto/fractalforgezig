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
    return iterateIn(f64, c_re, c_im, max_iter);
}

/// The SAME algorithm as `iterate`, carried out in `f128` (~34 significant decimals).
///
/// **This is the GROUND TRUTH for tests, not a render path.** `f128` is software-emulated
/// (~100× slower than `f64`), so calling this per pixel would make a render unusable — never
/// wire it to a renderer or a GPU path. Its job is to say what the right answer *is*, so
/// `perturb.zig`'s deep path can be measured against it (M6/T3). The deep render path is
/// `perturb.iterateDelta`, which is `f64` throughout.
///
/// TRUST IT ONLY TO ~1e-20. Measured at the milestone reference centre, its own drift against the
/// same algorithm run as an `f128` PERTURBATION ladder is 514 iterations at 1e-25, 1322 at 1e-30
/// and 8175 at 1e-31, while the shipped `f64`-delta path tracks that ladder to ~1 iteration. So
/// below ~1e-20 a disagreement is more likely THIS function's error than the renderer's, and the
/// accuracy budgets in the deep tests are dominated by oracle error. Verify deeper work against
/// an `f128` perturbation ladder, not against this.
pub fn iterateExact(c_re: f128, c_im: f128, max_iter: u32) f32 {
    return iterateIn(f128, c_re, c_im, max_iter);
}

/// The Julia variant of `iterate`: iterate `z = z² + c` from the SEED `z = (z0_re, z0_im)`
/// with `c` held fixed, returning the same smooth escape value / `interior_sentinel` as
/// `iterate`. This is the exact mirror of the Mandelbrot map with the two roles swapped —
/// the pixel is the seed `z₀` and `c` is the point under the pointer (T3 supplies it).
///
/// `f64` only: the inspector preview is a shallow, fixed-`max_iter` side view, never a deep
/// zoom. Shares the ONE escape loop with `iterate` (`iterateFrom`), so the two differ solely
/// in the initial `z` and the Julia preview colours by the very same convention as the main
/// image. Pure and deterministic: no allocation, no global state, no I/O.
pub fn iterateJulia(z0_re: f64, z0_im: f64, c_re: f64, c_im: f64, max_iter: u32) f32 {
    return iterateFrom(f64, z0_re, z0_im, c_re, c_im, max_iter);
}

/// `iterate`'s body, parameterized on the float type so `iterateExact` is the same
/// algorithm BY CONSTRUCTION rather than by a comment that could drift. `F` is `f64` for
/// the render path and `f128` for the test ground truth. Iterates from `z = 0` (the
/// Mandelbrot seed); the shared loop lives in `iterateFrom`.
fn iterateIn(comptime F: type, c_re: F, c_im: F, max_iter: u32) f32 {
    return iterateFrom(F, 0.0, 0.0, c_re, c_im, max_iter);
}

/// The shared escape loop for BOTH the Mandelbrot map (`iterateIn`, seed `z₀ = 0`) and the
/// Julia map (`iterateJulia`, seed = the pixel). Iterate `z = z² + c` from `(z0_re, z0_im)`
/// with `c` fixed; the escape test and the smooth-value tail are identical to what `iterate`
/// has always done, so the Mandelbrot path is unchanged byte-for-byte when `z₀ = 0`.
fn iterateFrom(comptime F: type, z0_re: F, z0_im: F, c_re: F, c_im: F, max_iter: u32) f32 {
    var z_re: F = z0_re;
    var z_im: F = z0_im;

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
        if (z_re * z_re + z_im * z_im > @as(F, bail_radius_squared)) {
            escaped = true;
            break;
        }
    }

    // Survived to max_iter without escaping ⇒ interior point.
    if (!escaped) return interior_sentinel;

    return smoothEscapeValue(F, z_re, z_im, c_re, c_im, n);
}

/// The smooth-value TAIL, from the moment the escape test first passed: run
/// `extra_iterations` further `z = z² + c` steps and evaluate
/// `n + 1 − log₂(log₂(|z|))`, falling back to `escape_n` if that degenerates.
///
/// Split out of `iterate` (M6/T3) with its behavior unchanged so the perturbation path
/// (`perturb.iterateDelta`) can produce values COMPARABLE to `iterate`'s by calling the
/// very same code. The two paths meet at `perturb.threshold_side`, and any difference in
/// this convention would show as a visible seam even with perfect iteration counts — so
/// there is exactly one definition of it, here.
///
/// `z_re`/`z_im` are `z` at the crossing, `c_re`/`c_im` the point being iterated, and
/// `escape_n` the completed-step count at the crossing (also the fallback value).
pub fn smoothEscapeValue(comptime F: type, z_re: F, z_im: F, c_re: F, c_im: F, escape_n: u32) f32 {
    var w_re = z_re;
    var w_im = z_im;
    var n = escape_n;

    // Extra iterations grow `|z|` well past the bail radius so the double-log is
    // accurate; advance `n` in lockstep so the smooth formula stays consistent.
    var extra: u32 = 0;
    while (extra < extra_iterations) : (extra += 1) {
        const next_re = w_re * w_re - w_im * w_im + c_re;
        const next_im = 2.0 * w_re * w_im + c_im;
        w_re = next_re;
        w_im = next_im;
        n += 1;
    }

    const mag_squared = w_re * w_re + w_im * w_im;
    const magnitude = @sqrt(mag_squared);
    const smooth = @as(F, @floatFromInt(n)) + 1.0 - std.math.log2(std.math.log2(magnitude));

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

// ─── iterateJulia (M10 Julia inspector) ──────────────────────────────────────

test "iterateJulia holds c fixed: an interior seed for c=0 returns the sentinel" {
    // c = 0 ⇒ z → z²; a seed inside the unit circle stays bounded (interior).
    try std.testing.expectEqual(interior_sentinel, iterateJulia(0.5, 0.0, 0.0, 0.0, 512));
}

test "iterateJulia holds c fixed: a seed outside the unit circle for c=0 escapes" {
    // Same c = 0 map, but |z₀| > 1 ⇒ z² grows without bound (a real positive smooth value).
    const v = iterateJulia(2.0, 0.0, 0.0, 0.0, 512);
    try std.testing.expect(v != interior_sentinel);
    try std.testing.expect(v > 0.0);
}

test "iterateJulia never returns NaN or Inf for a seed that overflows immediately" {
    const v = iterateJulia(1.0e6, 1.0e6, -0.8, 0.156, 512);
    try std.testing.expect(v == interior_sentinel or std.math.isFinite(v));
}

test "iterateJulia is the seed-varying mirror of iterate: seed=0 matches iterate for the same c" {
    // With z₀ = 0 the Julia map IS the Mandelbrot map, so it must reproduce iterate exactly —
    // the defining relationship between the two, and a guard that the shared loop did not drift.
    const c_re = 0.3;
    const c_im = 0.0;
    try std.testing.expectEqual(iterate(c_re, c_im, 512), iterateJulia(0.0, 0.0, c_re, c_im, 512));
}

// ─── iterateExact (M6 ground truth) ──────────────────────────────────────────

test "iterateExact reproduces iterate's smooth values wherever f64 is trustworthy" {
    // Shallow points, spread over interior / exterior / near-boundary: the two functions
    // run the SAME algorithm, so at a depth where f64 is exact enough they must agree to
    // far better than a coloring step. This is what licenses `iterateExact` as the ground
    // truth for the deep-path tests.
    const points = [_][2]f64{
        .{ 0.3, 0.0 },    .{ 1.0, 0.0 },     .{ -0.5, 0.5 }, .{ 0.25, 0.5 },
        .{ -1.75, 0.02 }, .{ 0.35, 0.35 },   .{ -0.1, 0.9 }, .{ 0.4, -0.2 },
        .{ -1.26, 0.0 },  .{ -0.16, 1.035 },
    };
    for (points) |p| {
        const lo = iterate(p[0], p[1], 512);
        const hi = iterateExact(p[0], p[1], 512);
        try std.testing.expectApproxEqAbs(lo, hi, 1.0e-3);
    }
}

test "iterateExact returns the interior sentinel for a point inside the set" {
    try std.testing.expectEqual(interior_sentinel, iterateExact(0.0, 0.0, 512));
}

test "iterateExact classifies the milestone's reference center as interior" {
    // The seahorse-valley boundary point every deep-zoom test is centered on: it must not
    // escape, or the reference orbit those tests build would be a few entries long.
    try std.testing.expectEqual(interior_sentinel, iterateExact(
        -0.743643887037158704752191506114774,
        0.131825904205311970493132056385139,
        2048,
    ));
}

test "iterateExact separates two c values an f64 cannot tell apart" {
    // The whole reason this function exists. Both arguments below collapse to the SAME f64
    // (|c| ≈ 0.74, so one ulp is ~1.1e-16 and the 1e-20 nudge vanishes), yet 1e-14 from the
    // reference center the escape count is sensitive enough that the f128 path resolves
    // them: measured 3103.7732 vs 3103.7766.
    const base_re: f128 = -0.743643887037158704752191506114774 + 1.0e-14;
    const nudged_re: f128 = base_re + 1.0e-20;
    const c_im: f128 = 0.131825904205311970493132056385139;
    try std.testing.expectEqual(@as(f64, @floatCast(base_re)), @as(f64, @floatCast(nudged_re)));
    try std.testing.expect(
        iterateExact(base_re, c_im, 4096) != iterateExact(nudged_re, c_im, 4096),
    );
}

test "iterateExact never returns NaN or Inf for a fast-escaping point" {
    const v = iterateExact(1.0e6, 1.0e6, 512);
    try std.testing.expect(std.math.isFinite(v) or v == interior_sentinel);
}
