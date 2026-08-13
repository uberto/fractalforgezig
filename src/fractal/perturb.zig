//! Perturbation theory: the DEEP render path. Pure arithmetic — no SDL/GPU imports, no
//! logging (only `engine.zig` logs in this folder), no globals, fully unit-tested in the fast
//! tier.
//!
//! ─── Why ─────────────────────────────────────────────────────────────────────
//! Iterating `z = z² + c` directly in `f64` stops resolving detail below a view side of
//! ~1e-13: neighbouring pixels' `c` values round to the same number and the image collapses
//! into blocks. Perturbation fixes that by iterating ONE high-precision orbit at the view
//! centre and then iterating each pixel's *difference* from it in ordinary `f64`. The
//! differences are tiny, so `f64`'s relative precision is spent where it matters.
//!
//! With `Z` the centre's orbit (`Z_{m+1} = Z_m² + C`, `Z_0 = 0`), a pixel at `c = C + δc`
//! writes `z_n = Z_m + δ_n` and iterates
//!
//!     δ ← 2·Z_m·δ + δ² + δc        (exact: it is the algebra of `(Z+δ)² + (C+δc)`)
//!
//! escaping when `|Z_m + δ|² > bail_radius_squared`.
//!
//! ─── The one performance rule ─────────────────────────────────────────────────
//! `f128` is software-emulated on arm64 (~100× slower). It appears here ONCE PER RENDER, in
//! `ReferenceOrbit.compute`, and NOWHERE ELSE. `iterateDelta` is `f64` throughout, and the
//! orbit is stored as `f64` pairs on purpose: the deltas are `f64`, so `f128` orbit entries
//! would buy nothing and cost a conversion per iteration. (`mandelbrot.iterateExact` is
//! `f128` too, but it is test ground truth, never a render path.)
//!
//! ─── Colouring ────────────────────────────────────────────────────────────────
//! `iterateDelta` returns a value COMPARABLE to `mandelbrot.iterate`'s — same smoothing
//! formula, same `extra_iterations`, same NaN/Inf fallback, same `interior_sentinel` — by
//! calling `mandelbrot.smoothEscapeValue`, not by restating it. The two paths meet at
//! `threshold_side` (T4), and a difference in the *colouring* convention would show as a
//! visible seam even with perfect iteration counts.
const std = @import("std");
const mandelbrot = @import("mandelbrot.zig");
const viewport = @import("viewport.zig");

/// View side at or below which the renderer uses this deep path (T4 owns the decision).
/// Above it the proven direct `f64` path stays in charge: at 1e-6 both are accurate, and the
/// deep path is measurably the MORE accurate of the two there, so the switch is seam-free.
pub const threshold_side: f64 = 1.0e-6;

/// View side below which the GPU cannot be trusted with the deltas: its arithmetic is 32-bit
/// `float` (~1e-7 relative), and a `δ` of 1e-20 against pixel spacing that small leaves it
/// nothing to work with. Deeper than this, T6 renders on the CPU and logs
/// `gpuFallbackMessage(.below_gpu_precision_floor)`.
pub const gpu_floor_side: f64 = 1.0e-20;

/// Longest reference orbit the GPU path will upload: 2^17 entries = 1 MiB as `float2`, which
/// fits comfortably in a storage buffer and is uploaded per dispatch (T6). A longer orbit
/// falls back to the CPU with `gpuFallbackMessage(.orbit_too_long_for_gpu)`.
pub const gpu_max_orbit_len: usize = 1 << 17;

/// Why a deep render could not use the GPU. Reported by T6's fallback, worded by
/// `gpuFallbackMessage`; the render always still happens, on the CPU.
pub const FallbackReason = enum {
    /// `view.side < gpu_floor_side`.
    below_gpu_precision_floor,
    /// `orbit.len() > gpu_max_orbit_len`.
    orbit_too_long_for_gpu,
};

/// A reference orbit could not be computed. Returned, never logged (this module is log-free,
/// see `src/fractal/context.md`); the edge that accepted the view logs it.
pub const OrbitError = error{
    /// The centre is NaN or ±Inf, so no orbit exists. `viewport.SquareView`'s constructors
    /// reject such a centre, so this can only come from a hand-built centre.
    NonFiniteCenter,
};

/// The orbit of the view centre: `Z_0 = 0, Z_1 = C, Z_2 = C² + C, …`, iterated in `f128` and
/// stored as `f64` pairs (see the file header's performance rule). One per render, shared by
/// every pixel and every progressive band.
///
/// `re[0] == im[0] == 0` ALWAYS: index 0 is `Z_0`, which is what makes rebasing exact.
/// `re[1]`/`im[1]` are therefore the centre itself, rounded to `f64`.
///
/// The recording stops as soon as the centre's own orbit escapes, so `len()` can be much
/// shorter than `max_iter + 1` — that is normal, and `iterateDelta` handles it by rebasing.
pub const ReferenceOrbit = struct {
    /// Real parts, `Z_0 … Z_{len-1}`. Trimmed to what was recorded.
    re: []f64,
    /// Imaginary parts, same length as `re`.
    im: []f64,
    /// Length of the ALLOCATION behind `re`/`im` (`max_iter + 1`). `re`/`im` are trimmed
    /// views into it when the centre escaped early, so `deinit` needs the original size to
    /// hand back. Kept as a field rather than shrinking with `realloc`, which can itself
    /// fail — on the very path that is reporting success.
    capacity: usize,

    /// Iterate `Z ← Z² + C` from `Z = 0` in `f128`, recording each `Z` as an `f64` pair, and
    /// stop early once the centre's orbit escapes (`|Z|² > bail_radius_squared`); the
    /// escaping entry IS recorded, because rebasing needs to read it.
    ///
    /// This is the ONLY `f128` loop in the render path, and it runs once per render.
    /// Caller owns the result: `defer orbit.deinit(alloc)`.
    pub fn compute(
        alloc: std.mem.Allocator,
        center: viewport.ComplexHi,
        max_iter: u32,
    ) (std.mem.Allocator.Error || OrbitError)!ReferenceOrbit {
        if (!std.math.isFinite(center.re) or !std.math.isFinite(center.im)) {
            return OrbitError.NonFiniteCenter;
        }

        // `max_iter` steps produce `Z_1 … Z_max_iter`, plus `Z_0 = 0` at index 0.
        const capacity = @as(usize, max_iter) + 1;
        const re = try alloc.alloc(f64, capacity);
        errdefer alloc.free(re);
        const im = try alloc.alloc(f64, capacity);
        errdefer alloc.free(im);

        var z_re: f128 = 0.0;
        var z_im: f128 = 0.0;
        re[0] = 0.0;
        im[0] = 0.0;

        var count: usize = 1;
        while (count < capacity) {
            const next_re = z_re * z_re - z_im * z_im + center.re;
            const next_im = 2.0 * z_re * z_im + center.im;
            z_re = next_re;
            z_im = next_im;
            re[count] = @floatCast(z_re);
            im[count] = @floatCast(z_im);
            count += 1;
            if (z_re * z_re + z_im * z_im > @as(f128, mandelbrot.bail_radius_squared)) break;
        }

        return .{ .re = re[0..count], .im = im[0..count], .capacity = capacity };
    }

    /// Free everything `compute` allocated and leave the orbit empty (so a double `deinit`
    /// is harmless).
    pub fn deinit(self: *ReferenceOrbit, alloc: std.mem.Allocator) void {
        alloc.free(self.re.ptr[0..self.capacity]);
        alloc.free(self.im.ptr[0..self.capacity]);
        self.* = .{ .re = self.re[0..0], .im = self.im[0..0], .capacity = 0 };
    }

    /// Number of recorded entries, `Z_0 … Z_{len-1}`. At least 1 (`Z_0`); shorter than
    /// `max_iter + 1` exactly when the centre's own orbit escaped.
    pub fn len(self: ReferenceOrbit) usize {
        return self.re.len;
    }
};

/// Iterate ONE pixel of the deep path: the pixel sits at `c = C + δc` where `C` is
/// `orbit`'s centre, so `dc_re`/`dc_im` is its offset from the view centre in `f64`.
///
/// Returns exactly what `mandelbrot.iterate` would return for the same point — the same
/// smooth value on escape, `mandelbrot.interior_sentinel` for a point that survives
/// `max_iter` — but computed on the deltas, so it keeps resolving detail far past the depth
/// at which `f64` `c` values collapse onto each other.
///
/// `orbit` is taken BY VALUE: it is two slices and a length (40 bytes), not a copy of the
/// data. `f64` throughout — no `f128` may enter this function.
pub fn iterateDelta(orbit: ReferenceOrbit, dc_re: f64, dc_im: f64, max_iter: u32) f32 {
    const orbit_len = orbit.len();
    // An orbit of only `Z_0 = 0` (computed with `max_iter = 0`) carries no `Z_1 = C`, so
    // there is nothing to iterate against and no way to recover the centre. Answer like an
    // exhausted budget rather than reading past the end.
    if (orbit_len < 2) return mandelbrot.interior_sentinel;

    // `m` is the orbit index the current value is anchored on: the invariant maintained
    // across the loop is `z_re/z_im == Z_m + δ` with `m < orbit_len`. `n` counts completed
    // `z = z² + c` steps, exactly as in `mandelbrot.iterate`.
    var m: usize = 0;
    var d_re: f64 = 0.0;
    var d_im: f64 = 0.0;
    var z_re: f64 = 0.0; // Z_0 + δ_0 = 0 + 0
    var z_im: f64 = 0.0;

    var n: u32 = 0;
    var escaped = false;
    while (n < max_iter) {
        // ─── Rebasing (Zhuoran's method) ──────────────────────────────────────
        // Re-anchor the delta on `Z_0` when either
        //   * the delta has grown to dominate the value it is a correction to
        //     (`|Z_m + δ| < |δ|`), which is where `f64` starts losing the detail the
        //     perturbation exists to keep — this is what eliminates Pauldelbrot glitches
        //     without a second reference orbit; or
        //   * the reference orbit has no next entry (`m + 1 == orbit_len`, i.e. the CENTRE's
        //     own orbit escaped), so there is no `Z_{m+1}` to pair the next delta with.
        //
        // The substitution is EXACT, not an approximation: `Z_0 = 0`, so setting
        // `δ ← Z_m + δ` and `m ← 0` leaves `Z_0 + δ` equal to the very same `z` we had.
        // Nothing about what is being computed changes; the delta is merely re-expressed
        // against a part of the orbit where `f64` still has precision to spend. It is also
        // why ONE centre-anchored orbit suffices for every pixel of the image.
        const d_mag_squared = d_re * d_re + d_im * d_im;
        if (z_re * z_re + z_im * z_im < d_mag_squared or m + 1 >= orbit_len) {
            d_re = z_re;
            d_im = z_im;
            m = 0;
        }

        // One perturbation step: δ ← 2·Z_m·δ + δ² + δc, advancing the anchor to Z_{m+1}.
        const ref_re = orbit.re[m];
        const ref_im = orbit.im[m];
        const next_d_re = 2.0 * (ref_re * d_re - ref_im * d_im) +
            (d_re * d_re - d_im * d_im) + dc_re;
        const next_d_im = 2.0 * (ref_re * d_im + ref_im * d_re) +
            2.0 * d_re * d_im + dc_im;
        d_re = next_d_re;
        d_im = next_d_im;
        m += 1;
        n += 1;

        // Restore the invariant, then escape-test on the FULL value like `mandelbrot.iterate`
        // does (after the step, so `n` is the count at the moment of crossing).
        z_re = orbit.re[m] + d_re;
        z_im = orbit.im[m] + d_im;
        if (z_re * z_re + z_im * z_im > mandelbrot.bail_radius_squared) {
            escaped = true;
            break;
        }
    }

    if (!escaped) return mandelbrot.interior_sentinel;

    // The smooth tail runs on the ABSOLUTE value, in `f64`, through the one shared definition
    // of the colouring convention. `|z| > 2` here, so the pixel's `c` may be taken as
    // `Z_1 (= C, rounded to f64) + δc`: the ~1e-16 it drops cannot move a double-log of a
    // value that is about to be squared twice, and this is what keeps the deep path's values
    // comparable to `mandelbrot.iterate`'s at the threshold.
    return mandelbrot.smoothEscapeValue(
        f64,
        z_re,
        z_im,
        orbit.re[1] + dc_re,
        orbit.im[1] + dc_im,
        n,
    );
}

const fallback_prefix = "GPU deep-zoom path skipped: ";
const fallback_suffix = "; the CPU completed this render";
/// Rendered from the constants at comptime, so the wording can never disagree with the limits
/// T6 actually tests against.
const floor_reason_text = std.fmt.comptimePrint(
    "the view side is below the GPU precision floor {e}",
    .{gpu_floor_side},
);
const orbit_reason_text = std.fmt.comptimePrint(
    "the reference orbit is longer than the GPU budget of {d} entries",
    .{gpu_max_orbit_len},
);

/// Buffer size that fits ANY `gpuFallbackMessage` result: both messages are fully known at
/// comptime (the reason SELECTS a wording, it does not interpolate a runtime value), so this
/// is the exact worst case, pinned by a test. A shorter buffer returns `error.NoSpaceLeft`.
pub const fallback_message_buf_len: usize = fallback_prefix.len + fallback_suffix.len +
    @max(floor_reason_text.len, orbit_reason_text.len);

/// The warning for a deep render that could not use the GPU: names the limit that was hit
/// and says the CPU completed the render, so an operator reading a slow render's log knows
/// both why it was slow and that the image is real. Pure (writes only into `buf`) so the
/// wording is unit-tested once; T6's call site logs it. Pass a `[fallback_message_buf_len]u8`.
pub fn gpuFallbackMessage(buf: []u8, reason: FallbackReason) error{NoSpaceLeft}![]u8 {
    const reason_text = switch (reason) {
        .below_gpu_precision_floor => floor_reason_text,
        .orbit_too_long_for_gpu => orbit_reason_text,
    };
    return std.fmt.bufPrint(buf, fallback_prefix ++ "{s}" ++ fallback_suffix, .{reason_text});
}

const path_summary_prefix = "render path: ";
const deep_path_text = std.fmt.comptimePrint(
    "deep (perturbation, side at or below {e})",
    .{threshold_side},
);
const direct_path_text = "direct (f64)";
const path_summary_infix = ", side=";

/// Buffer size that fits ANY `pathSummary` result: the widest wording plus the widest `{e}`
/// rendering of an f64 (`viewport.max_float_chars`, the same measured bound every other pure
/// message builder in this folder derives from). Exactly the worst case, pinned by a test.
pub const path_summary_buf_len: usize = path_summary_prefix.len +
    @max(deep_path_text.len, direct_path_text.len) +
    path_summary_infix.len + viewport.max_float_chars;

/// The per-render summary of which iteration path ran and at what depth — the line T4's
/// `engine.zig` logs once per render, and the first thing to read when a render is slow or
/// wrong. `{e}` bounds the side the same way the other builders here do (a `{d}` subnormal
/// would run to hundreds of digits). Pure so the wording is unit-tested; pass a
/// `[path_summary_buf_len]u8`.
pub fn pathSummary(buf: []u8, side: f64, used_deep: bool) error{NoSpaceLeft}![]u8 {
    return std.fmt.bufPrint(buf, path_summary_prefix ++ "{s}" ++ path_summary_infix ++ "{e}", .{
        if (used_deep) deep_path_text else direct_path_text,
        side,
    });
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The reference centre for the deep tests: the seahorse-valley boundary point from the
/// Mandelbrot deep-zoom literature, which keeps producing structure past 1e-30. Same value
/// the milestone's acceptance tests use.
const deep_center = viewport.ComplexHi{
    .re = -0.743643887037158704752191506114774,
    .im = 0.131825904205311970493132056385139,
};

/// How the deep path compared against `mandelbrot.iterateExact` over a grid of pixels.
const GridComparison = struct {
    /// Pixels where one path said "interior" and the other said "escaped". The strict
    /// number: a perturbation glitch shows up as exactly this.
    classification_mismatches: u32,
    /// Pixels where both paths escaped (the ones the smooth value is compared on).
    compared: u32,
    mean_abs_error: f64,
    worst_abs_error: f64,
};

/// Compare `iterateDelta` against `mandelbrot.iterateExact` on the centres of an `n × n`
/// image of side `side` around `deep_center`. Both paths are measured against the SAME
/// full-precision ground truth — never against each other, since a perturbation at an
/// `f64`-rounded centre and direct iteration at an `f128` centre iterate slightly different
/// points and near-boundary counts are hypersensitive.
fn compareGrid(alloc: std.mem.Allocator, side: f64, n: usize, max_iter: u32) !GridComparison {
    var orbit = try ReferenceOrbit.compute(alloc, deep_center, max_iter);
    defer orbit.deinit(alloc);

    const n_f: f64 = @floatFromInt(n);
    const scale = side / n_f;
    var result = GridComparison{
        .classification_mismatches = 0,
        .compared = 0,
        .mean_abs_error = 0.0,
        .worst_abs_error = 0.0,
    };
    var error_sum: f64 = 0.0;

    for (0..n) |row| {
        for (0..n) |col| {
            const dc_re = (@as(f64, @floatFromInt(col)) + 0.5 - n_f / 2.0) * scale;
            const dc_im = (n_f / 2.0 - @as(f64, @floatFromInt(row)) - 0.5) * scale;
            const got = iterateDelta(orbit, dc_re, dc_im, max_iter);
            const want = mandelbrot.iterateExact(
                deep_center.re + @as(f128, dc_re),
                deep_center.im + @as(f128, dc_im),
                max_iter,
            );
            const got_interior = got == mandelbrot.interior_sentinel;
            const want_interior = want == mandelbrot.interior_sentinel;
            if (got_interior != want_interior) {
                result.classification_mismatches += 1;
                continue;
            }
            if (want_interior) continue;
            const diff = @abs(@as(f64, want) - @as(f64, got));
            error_sum += diff;
            result.compared += 1;
            result.worst_abs_error = @max(result.worst_abs_error, diff);
        }
    }
    if (result.compared > 0) {
        result.mean_abs_error = error_sum / @as(f64, @floatFromInt(result.compared));
    }
    return result;
}

test "at the switch threshold every sampled pixel matches full precision within one iteration" {
    // Where the direct and deep paths meet (side 1e-6): identical classification and a
    // smooth value within one iteration, so the switch cannot introduce a visible seam.
    // Measured on the dialog prototype: mean 0.0122, worst 0.26.
    const cmp = try compareGrid(testing.allocator, threshold_side, 16, 4096);
    try testing.expectEqual(@as(u32, 0), cmp.classification_mismatches);
    try testing.expect(cmp.compared > 0);
    try testing.expect(cmp.worst_abs_error <= 1.0);
}

test "at side 1e-25 classification matches full precision and the mean error stays small" {
    // The glitch test: a perturbation glitch flips a pixel's interior/exterior answer, and
    // rebasing is what prevents it. Chaotic amplification near the boundary makes a handful
    // of pixels differ by much more than the mean; the MEAN is what separates
    // correct-with-noise from broken. Measured on the prototype: 0 mismatches, mean 1.66.
    const cmp = try compareGrid(testing.allocator, 1.0e-25, 16, 65536);
    try testing.expectEqual(@as(u32, 0), cmp.classification_mismatches);
    try testing.expect(cmp.compared > 0);
    try testing.expect(cmp.mean_abs_error < 5.0);
}

test "a zero delta reproduces the reference centre's own escape value" {
    // δc = 0 is the centre itself, so the deep path must return the centre's own value.
    const escaping = viewport.ComplexHi{ .re = 0.3, .im = 0.0 };
    var orbit = try ReferenceOrbit.compute(testing.allocator, escaping, 512);
    defer orbit.deinit(testing.allocator);
    try testing.expectApproxEqAbs(
        mandelbrot.iterateExact(escaping.re, escaping.im, 512),
        iterateDelta(orbit, 0.0, 0.0, 512),
        1.0e-3,
    );
}

test "a zero delta reproduces the reference centre's interior classification" {
    var orbit = try ReferenceOrbit.compute(testing.allocator, deep_center, 2048);
    defer orbit.deinit(testing.allocator);
    try testing.expectEqual(mandelbrot.interior_sentinel, iterateDelta(orbit, 0.0, 0.0, 2048));
}

test "a pixel whose delta outgrows the reference still matches full precision" {
    // Rebasing's OTHER trigger (`|Z_m + δ| < |δ|`), observed as an OUTCOME rather than by
    // inspecting a branch. This pixel — 1e-6 view, 2.8e-7 above the reference centre —
    // rebases 20 times on the way to escaping at ~2291. Measured: with rebasing it lands
    // 0.001 from the ground truth; with the dominance rule removed it lands 69 iterations
    // away, so this assertion is exactly what rebasing buys.
    const max_iter: u32 = 4096;
    var orbit = try ReferenceOrbit.compute(testing.allocator, deep_center, max_iter);
    defer orbit.deinit(testing.allocator);

    const dc_re: f64 = -3.125e-8;
    const dc_im: f64 = 2.8125e-7;
    const got = iterateDelta(orbit, dc_re, dc_im, max_iter);
    const want = mandelbrot.iterateExact(
        deep_center.re + @as(f128, dc_re),
        deep_center.im + @as(f128, dc_im),
        max_iter,
    );
    try testing.expect(want != mandelbrot.interior_sentinel);
    try testing.expectApproxEqAbs(want, got, 1.0);
}

test "an orbit shorter than max_iter still classifies its neighbourhood correctly" {
    // Rebasing's exhaustion trigger, observed as an OUTCOME. This centre escapes after four
    // steps, so the recorded orbit (5 entries) is far shorter than `max_iter` and the delta
    // loop runs out of `Z_m` after four steps unless it re-anchors on `Z_0`.
    //
    // What the two assertions below are each worth, measured on throwaway copies of this file
    // (nothing instrumented or mutated is committed; compile each variant with its OWN
    // `--cache-dir`, or `zig run` serves a sibling copy's stale binary and every variant
    // reports the first one's numbers):
    //   * these 25 pixels drive 7 exhaustion rebases and 0 dominance rebases, so the branch
    //     under test is the only one running here;
    //   * on correct code all 25 `got` values equal `want` bit-for-bit in `f32` — worst
    //     difference **0.0** — which is what pays for the tight tolerance below;
    //   * deleting the `m + 1 >= orbit_len` disjunct makes the loop read `orbit.re[5]` of a
    //     5-entry orbit — an `index out of bounds` panic, not a failed assertion;
    //   * three plausible ways to get the branch *wrong* are caught by the VALUE assertion
    //     ONLY — none of them misclassifies a single pixel — and each is a different size, so
    //     the figures do not transfer between them. Splitting the `if` so exhaustion runs
    //     (a) `m = 0` alone, without `δ ← Z_m + δ`: worst **14.1925** at `dc = (0.05, 0.01)`
    //         (want 5.0067, got 19.1991); 7 of the 25 pixels more than 1.0 off;
    //     (b) `m = orbit_len - 2` alone (clamp onto the last entry, no re-anchor): worst
    //         **2.5037** at `dc = (-0.01, -0.05)` (want 5.1577, got 7.6614); 3 pixels more
    //         than 1.0 off. At `dc = (0.05, 0.01)` this variant is only 0.4782 off, i.e. (a)'s
    //         worst pixel is not even a failing pixel here;
    //     (c) `δ ← Z_m + δ` kept but `m = orbit_len - 2`: worst **0.8897** at
    //         `dc = (0.05, -0.05)` (want 5.4877, got 4.5981); **0** pixels more than 1.0 off,
    //         so a 1.0 tolerance let this one pass with the branch broken — that is why the
    //         tolerance here is 0.25.
    //     All three put 7 pixels more than 0.25 off, and every other test in the file stays
    //     green under all three.
    const max_iter: u32 = 512;
    const shallow_center = viewport.ComplexHi{ .re = -0.5, .im = 0.9 };
    var orbit = try ReferenceOrbit.compute(testing.allocator, shallow_center, max_iter);
    defer orbit.deinit(testing.allocator);
    try testing.expect(orbit.len() < max_iter);

    // All 25 sampled pixels ESCAPE (`iterateExact` values 4.34–5.49); none is interior. So the
    // classification assertion only rules out a sentinel-or-crash regression and the smooth
    // value is what pins the arithmetic. The neighbourhood stays this narrow deliberately:
    // widening it to ±0.35 does straddle the set (4 of 25 interior), but `δ` then dominates
    // within the first steps, so dominance rebasing fires 1413 times and the exhaustion branch
    // fires 0 times — it would test the other trigger twice and this one not at all.
    const offsets = [_]f64{ -0.05, -0.01, 0.0, 0.01, 0.05 };
    for (offsets) |dc_re| {
        for (offsets) |dc_im| {
            const got = iterateDelta(orbit, dc_re, dc_im, max_iter);
            const want = mandelbrot.iterateExact(
                shallow_center.re + @as(f128, dc_re),
                shallow_center.im + @as(f128, dc_im),
                max_iter,
            );
            try testing.expectEqual(
                want == mandelbrot.interior_sentinel,
                got == mandelbrot.interior_sentinel,
            );
            if (want != mandelbrot.interior_sentinel) {
                // 0.25, tighter than AT3's approved 1.0, because a 1.0 tolerance passes with
                // variant (c) above broken (0.8897). Not brittle: correct code is exact here
                // (worst difference 0.0, and one `f32` ulp at these values is ~5e-7), so this
                // sits ~5 decades above any arithmetic noise while failing (c) by 3.6×.
                try testing.expectApproxEqAbs(want, got, 0.25);
            }
        }
    }
}

test "compute on a centre that escapes at once records a two-entry orbit" {
    const far = viewport.ComplexHi{ .re = 2.0, .im = 2.0 };
    var orbit = try ReferenceOrbit.compute(testing.allocator, far, 512);
    defer orbit.deinit(testing.allocator);
    // Z_0 = 0 and Z_1 = 2 + 2i, whose |Z|² = 8 already escapes.
    try testing.expectEqual(@as(usize, 2), orbit.len());
}

test "a short orbit's slices are trimmed below the allocation, which deinit still frees" {
    // What "trimmed" means: `max_iter + 1 = 513` entries are allocated, but this centre escapes
    // at once, so the PUBLIC slices are much shorter — a `for (orbit.re)` can never walk into
    // the uninitialised tail. `capacity` is what keeps `deinit` freeing the whole allocation
    // (asserted by the no-leak test, which fails on a partial free).
    var orbit = try ReferenceOrbit.compute(testing.allocator, .{ .re = 2.0, .im = 2.0 }, 512);
    defer orbit.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 513), orbit.capacity);
    try testing.expect(orbit.re.len < orbit.capacity);
    try testing.expectEqual(orbit.re.len, orbit.im.len);
}

test "the recorded orbit starts at Z_0 = 0, which is what makes rebasing exact" {
    var orbit = try ReferenceOrbit.compute(testing.allocator, deep_center, 8);
    defer orbit.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 0.0), orbit.re[0]);
    try testing.expectEqual(@as(f64, 0.0), orbit.im[0]);
}

test "the orbit's second entry is the centre itself, since Z_1 = C" {
    var orbit = try ReferenceOrbit.compute(testing.allocator, deep_center, 8);
    defer orbit.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, @floatCast(deep_center.re)), orbit.re[1]);
    try testing.expectEqual(@as(f64, @floatCast(deep_center.im)), orbit.im[1]);
}

test "an interior centre records one entry per iteration plus Z_0" {
    var orbit = try ReferenceOrbit.compute(testing.allocator, deep_center, 64);
    defer orbit.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 65), orbit.len());
}

test "compute rejects a non-finite centre instead of recording a NaN orbit" {
    try testing.expectError(OrbitError.NonFiniteCenter, ReferenceOrbit.compute(
        testing.allocator,
        .{ .re = std.math.nan(f128), .im = 0.0 },
        64,
    ));
    try testing.expectError(OrbitError.NonFiniteCenter, ReferenceOrbit.compute(
        testing.allocator,
        .{ .re = 0.0, .im = std.math.inf(f128) },
        64,
    ));
}

/// `checkAllAllocationFailures` harness: compute an orbit and hand it straight back.
fn computeAndFree(alloc: std.mem.Allocator) !void {
    var orbit = try ReferenceOrbit.compute(alloc, deep_center, 64);
    orbit.deinit(alloc);
}

test "compute leaks nothing, including when one of its allocations fails" {
    try testing.checkAllAllocationFailures(testing.allocator, computeAndFree, .{});
}

test "the orbit carries no f128 field, so the delta loop cannot touch one" {
    // The milestone's one performance rule, pinned structurally rather than by a comment:
    // `f128` is software-emulated, so an `f128` orbit entry would put it in the per-pixel
    // loop and make a deep render ~100× slower.
    inline for (@typeInfo(ReferenceOrbit).@"struct".fields) |field| {
        try testing.expect(field.type != f128);
        try testing.expect(field.type != []f128);
    }
    try testing.expectEqual(f64, std.meta.Child(@TypeOf(@as(ReferenceOrbit, undefined).re)));
}

test "iterateDelta returns a finite value or the sentinel for hostile deltas" {
    var orbit = try ReferenceOrbit.compute(testing.allocator, deep_center, 256);
    defer orbit.deinit(testing.allocator);

    const hostile = [_]f64{
        0.0,
        1.0e-300,
        -1.0e-300,
        1.0e6,
        -1.0e6,
        std.math.floatMax(f64),
        std.math.nan(f64),
        std.math.inf(f64),
        -std.math.inf(f64),
    };
    for (hostile) |dc_re| {
        for (hostile) |dc_im| {
            const v = iterateDelta(orbit, dc_re, dc_im, 256);
            try testing.expect(std.math.isFinite(v) or v == mandelbrot.interior_sentinel);
        }
    }
}

test "iterateDelta on an orbit with no steps returns the interior sentinel" {
    // `max_iter = 0` records only `Z_0`, so there is no `Z_1 = C` to step onto and the
    // orbit carries no information. Answer with the sentinel rather than reading past it.
    var orbit = try ReferenceOrbit.compute(testing.allocator, deep_center, 0);
    defer orbit.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), orbit.len());
    try testing.expectEqual(mandelbrot.interior_sentinel, iterateDelta(orbit, 1.0e-6, 0.0, 64));
}

test "the switch threshold and the GPU limits are the documented constants" {
    try testing.expectEqual(@as(f64, 1.0e-6), threshold_side);
    try testing.expectEqual(@as(f64, 1.0e-20), gpu_floor_side);
    // The budget is what fits comfortably in a GPU storage buffer as `float2` (8 bytes).
    try testing.expectEqual(@as(usize, 1024 * 1024), gpu_max_orbit_len * 8);
}

test "gpuFallbackMessage names the GPU precision floor and says the CPU finished" {
    var buf: [fallback_message_buf_len]u8 = undefined;
    const msg = try gpuFallbackMessage(&buf, .below_gpu_precision_floor);
    try testing.expect(std.mem.indexOf(u8, msg, "1e-20") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "CPU") != null);
}

test "gpuFallbackMessage names the orbit budget and says the CPU finished" {
    var buf: [fallback_message_buf_len]u8 = undefined;
    const msg = try gpuFallbackMessage(&buf, .orbit_too_long_for_gpu);
    try testing.expect(std.mem.indexOf(u8, msg, "131072") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "CPU") != null);
}

test "fallback_message_buf_len is exactly the longest fallback message" {
    var exact: [fallback_message_buf_len]u8 = undefined;
    var short: [fallback_message_buf_len - 1]u8 = undefined;
    var longest: usize = 0;
    for ([_]FallbackReason{ .below_gpu_precision_floor, .orbit_too_long_for_gpu }) |reason| {
        longest = @max(longest, (try gpuFallbackMessage(&exact, reason)).len);
    }
    try testing.expectEqual(fallback_message_buf_len, longest);
    // The orbit-budget wording is the longer of the two, so it is the one a one-byte-short
    // buffer must refuse rather than truncate.
    try testing.expectError(
        error.NoSpaceLeft,
        gpuFallbackMessage(&short, .orbit_too_long_for_gpu),
    );
}

test "pathSummary names the side and says the deep path ran" {
    var buf: [path_summary_buf_len]u8 = undefined;
    const msg = try pathSummary(&buf, 1.0e-25, true);
    try testing.expect(std.mem.indexOf(u8, msg, "1e-25") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "deep") != null);
}

test "pathSummary names the side and says the direct path ran" {
    var buf: [path_summary_buf_len]u8 = undefined;
    const msg = try pathSummary(&buf, 3.5, false);
    try testing.expect(std.mem.indexOf(u8, msg, "3.5") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "direct") != null);
}

test "path_summary_buf_len fits the widest summary, and a shorter buffer is refused" {
    var exact: [path_summary_buf_len]u8 = undefined;
    var short: [path_summary_buf_len - 1]u8 = undefined;
    const widest = try pathSummary(&exact, -std.math.floatMin(f64), true);
    try testing.expectEqual(path_summary_buf_len, widest.len);
    try testing.expectError(error.NoSpaceLeft, pathSummary(&short, -std.math.floatMin(f64), true));
}
