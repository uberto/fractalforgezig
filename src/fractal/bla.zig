//! Bivariate Linear Approximation (BLA), degree-2 form: the ACCELERATOR for the deep
//! (perturbation) path. Pure arithmetic — no SDL/GPU imports, no logging (only `engine.zig` logs
//! in this folder), `f64` end to end, fully unit-tested in the fast tier.
//!
//! ─── Why ─────────────────────────────────────────────────────────────────────
//! `perturb.iterateDelta` iterates one pixel's delta `δ ← 2·Z_m·δ + δ² + δc` one step at a
//! time. Near a deep reference orbit, long runs of those steps are, over a small `δ`, almost
//! perfectly a low-degree polynomial in `δ`. BLA precomputes, once per render, a binary tree of
//! such local maps over the reference orbit so a pixel can leap over a whole run of iterations
//! in ONE application — but only where that leap is provably valid.
//!
//! Each block evaluates A·δ + Q·δ² + B·δc. The merge bounds the omitted
//! terms and uses the full midpoint excursion to intersect its children's domains.
const std = @import("std");
const mandelbrot = @import("mandelbrot.zig");
const perturb = @import("perturb.zig");

const conditioning_fraction: f64 = 1e-6;
const model_tolerance: f64 = 1e-6;
// Eight machine epsilons cover the rounding of the short products and
// sums in a local complex arithmetic expression, including norm evaluation.
const roundoff = 8 * std.math.floatEps(f64);
const bail_radius = @sqrt(mandelbrot.bail_radius_squared);

fn magnitude(re: f64, im: f64) f64 {
    return @sqrt(re * re + im * im);
}

const Remainder = struct {
    cubic: f64 = 0,
    mixed: f64 = 0,
    parameter_squared: f64 = 0,
    delta_roundoff: f64 = 0,
    parameter_roundoff: f64 = 0,

    fn bound(self: Remainder, d: f64, c: f64) f64 {
        return ((self.cubic * d * d + self.mixed * c + self.delta_roundoff) * d +
            (self.parameter_squared * c + self.parameter_roundoff) * c) * (1 + roundoff);
    }
};

/// Largest table (in blocks) the GPU path will accept. A full binary tree over an orbit of `L`
/// entries is `≈ 2·(L−1)` blocks, so this is sized as twice `perturb.gpu_max_orbit_len`: any
/// orbit the GPU could upload produces a table that also fits. A longer table is finished on the
/// CPU with `gpuFallbackMessage` (T3/T4 own that decision).
pub const gpu_max_table_len: usize = 2 * perturb.gpu_max_orbit_len;

/// One quadratic map over `len` reference steps, valid for input magnitude <= r.
const Block = struct {
    a_re: f64,
    a_im: f64,
    q_re: f64,
    q_im: f64,
    b_re: f64,
    b_im: f64,
    /// Validity radius on `|δ_in|` (see the file header). Compared as `|δ|² ≤ r²`.
    r: f64,
    remainder: Remainder,
    /// Number of elementary reference steps this block leaps over in one application.
    len: u32,
};

/// A binary tree of `Block`s over one `perturb.ReferenceOrbit`, heap-allocated and owned by the
/// caller (`defer table.deinit(alloc)`). `levels[0]` holds one block per orbit step; each higher
/// level merges adjacent pairs, halving the count, until fewer than two blocks remain. Built once
/// per render by `build`, consumed per pixel by `iterateDeltaBla`.
pub const BlaTable = struct {
    /// `levels[ℓ][j]` covers reference steps `[j·2^ℓ, (j+1)·2^ℓ)`. `levels[0]` is the longest.
    levels: [][]Block,
    max_dc: f64 = 0,

    /// Build the tree for `orbit`, sized to a view whose largest pixel delta is `max_dc`
    /// (`side·√2/2`). `f64` only — the orbit is already computed; BLA never touches `f128`.
    /// Returns an EMPTY table (no levels) for an orbit too short to carry a single step.
    pub fn build(
        alloc: std.mem.Allocator,
        orbit: *const perturb.ReferenceOrbit,
        max_dc: f64,
    ) std.mem.Allocator.Error!BlaTable {
        const orbit_len = orbit.len();
        // A level-0 block over step `m` needs `Z_m` and lands on `Z_{m+1}`, so `m ∈ [0, L−2]`:
        // `n0 = L−1` base blocks. Fewer than one ⇒ nothing to accelerate.
        if (orbit_len < 2) return .{ .levels = &.{} };
        const n0 = orbit_len - 1;

        // How many levels: keep halving until a level would hold fewer than one block.
        var num_levels: usize = 1;
        {
            var count = n0;
            while (count / 2 >= 1) : (num_levels += 1) count /= 2;
        }

        var levels = try alloc.alloc([]Block, num_levels);
        errdefer alloc.free(levels);
        // Track how many level slices are populated, so a mid-build failure frees exactly those.
        var built: usize = 0;
        errdefer for (levels[0..built]) |lvl| alloc.free(lvl);

        // Level 0: one block per step, EXACT (a single perturbation step is degree-2 already).
        // Leave room inside both the rebase and escape thresholds at every start.
        levels[0] = try alloc.alloc(Block, n0);
        built = 1;
        for (0..n0) |m| {
            const zr = orbit.re[m];
            const zi = orbit.im[m];
            const ref = magnitude(zr, zi);
            const r = @max(0, @min(conditioning_fraction * ref, bail_radius * (1 - roundoff) - ref));
            levels[0][m] = .{
                .a_re = 2.0 * zr,
                .a_im = 2.0 * zi,
                .q_re = 1.0,
                .q_im = 0.0,
                .b_re = 1.0,
                .b_im = 0.0,
                .r = r,
                .remainder = .{
                    .delta_roundoff = roundoff * (2 * ref + r),
                    .parameter_roundoff = roundoff,
                },
                .len = 1,
            };
        }

        // Higher levels: merge adjacent pairs of the level below.
        var ell: usize = 1;
        while (ell < num_levels) : (ell += 1) {
            const child = levels[ell - 1];
            const count = child.len / 2;
            levels[ell] = try alloc.alloc(Block, count);
            built = ell + 1;
            for (0..count) |j| {
                levels[ell][j] = mergeBlocks(child[2 * j], child[2 * j + 1], max_dc);
            }
        }

        return .{ .levels = levels, .max_dc = max_dc };
    }

    /// Free the tree and leave it empty (a double `deinit` is harmless).
    pub fn deinit(self: *BlaTable, alloc: std.mem.Allocator) void {
        for (self.levels) |lvl| alloc.free(lvl);
        alloc.free(self.levels);
        self.* = .{ .levels = &.{} };
    }

    /// Total number of blocks across every level — the size T3/T4 weigh against
    /// `gpu_max_table_len` to decide whether the GPU can carry this table.
    pub fn len(self: BlaTable) usize {
        var total: usize = 0;
        for (self.levels) |lvl| total += lvl.len;
        return total;
    }

    /// The longest block that STARTS at reference index `m`, whose radius admits `|δ|`
    /// (`dz_mag_sq = |δ|²`), fits the remaining iteration budget (`n + len ≤ max_iter`), and is
    /// aligned to `m`. Blocks at level `ℓ` start only at multiples of `2^ℓ`, so once `m` loses
    /// that alignment (or a block's radius rejects `|δ|`, or the budget runs out) no higher level
    /// can help — climb while all three hold, returning the highest valid block, else `null`.
    ///
    /// Validity is monotone up the tree (the merge takes the stricter child radius), so a valid
    /// level `ℓ` guarantees valid lower levels too; the climb never needs to back-track.
    fn largestValidBlock(self: BlaTable, m: usize, dz_mag_sq: f64, n: u32, max_iter: u32) ?Block {
        var best: ?Block = null;
        var ell: usize = 0;
        while (ell < self.levels.len) : (ell += 1) {
            const step: usize = @as(usize, 1) << @intCast(ell);
            if (m % step != 0) break; // `m` no longer aligns to this (or any higher) level.
            const j = m >> @intCast(ell);
            if (j >= self.levels[ell].len) break; // no block covers `m` at this level.
            const blk = self.levels[ell][j];
            if (@as(u64, n) + @as(u64, blk.len) > max_iter) break; // would overrun the budget.
            // A zero-radius block (a merge whose first child is the `Z_0` step, `A₀ = 0`, so the
            // second run is unreachable and `mapped_r1` collapsed to 0) is NEVER valid, even for a
            // `δ` of exactly 0. Guarding `r <= 0` also stops `|δ|² > r²` from reading `0 > 0` as valid.
            if (blk.r <= 0.0 or dz_mag_sq > blk.r * blk.r) break;
            best = blk;
        }
        return best;
    }
};

/// Compose two adjacent degree-2 blocks — `c0` first, then `c1` — into one covering both runs,
/// truncating the composition back to degree ≤ 2 and folding the dropped ≥`δ³` terms into a
/// tightened radius (see the file header for the full derivation).
fn mergeBlocks(c0: Block, c1: Block, max_dc: f64) Block {
    // A = A₁·A₀
    const a_re = c1.a_re * c0.a_re - c1.a_im * c0.a_im;
    const a_im = c1.a_re * c0.a_im + c1.a_im * c0.a_re;
    // Q = A₁·Q₀ + Q₁·A₀²  (the kept degree-2 term; A₀² is the complex square of c0.A).
    const a0_sq_re = c0.a_re * c0.a_re - c0.a_im * c0.a_im;
    const a0_sq_im = 2.0 * c0.a_re * c0.a_im;
    const q_re = (c1.a_re * c0.q_re - c1.a_im * c0.q_im) +
        (c1.q_re * a0_sq_re - c1.q_im * a0_sq_im);
    const q_im = (c1.a_re * c0.q_im + c1.a_im * c0.q_re) +
        (c1.q_re * a0_sq_im + c1.q_im * a0_sq_re);
    // B = A₁·B₀ + B₁
    const b_re = (c1.a_re * c0.b_re - c1.a_im * c0.b_im) + c1.b_re;
    const b_im = (c1.a_re * c0.b_im + c1.a_im * c0.b_re) + c1.b_im;

    const a0 = magnitude(c0.a_re, c0.a_im);
    const a1 = magnitude(c1.a_re, c1.a_im);
    const q0 = magnitude(c0.q_re, c0.q_im);
    const q1 = magnitude(c1.q_re, c1.q_im);
    const b0 = magnitude(c0.b_re, c0.b_im);
    const b1 = magnitude(c1.b_re, c1.b_im);
    const e0 = c0.remainder;
    const e1 = c1.remainder;

    // The exact first child's output is bounded by L*d + M*c, with
    // d=|delta| and c=|dc|. Absorb nonlinear factors using the domain caps.
    // Tighten the candidate radius monotonically until the complete
    // midpoint (including inherited error) fits the second child.
    var r = c0.r;
    for (0..4) |_| {
        const l = (a0 + (q0 + e0.cubic * r) * r + e0.mixed * max_dc + e0.delta_roundoff) * (1 + roundoff);
        const b = (b0 + e0.parameter_squared * max_dc + e0.parameter_roundoff) * (1 + roundoff);
        if (l * r + b * max_dc <= c1.r * (1 - roundoff)) break;
        r = @max(0, (c1.r * (1 - roundoff) - b * max_dc) / l);
    }
    const l = (a0 + (q0 + e0.cubic * r) * r + e0.mixed * max_dc + e0.delta_roundoff) * (1 + roundoff);
    const b = (b0 + e0.parameter_squared * max_dc + e0.parameter_roundoff) * (1 + roundoff);

    // Expanding Q1*(A0*d + Q0*d² + B0*c)² leaves d³, d⁴, d*c,
    // d²*c and c². Bound d⁴ by r*d³ and d²*c by r*d*c.
    // First-child error is amplified by |A1| + |Q1|*(|mid|+|model|).
    // Substitute L*d+M*c into the second child's error polynomial,
    // using the domain caps to fold the higher powers into those same terms.
    const gain = a1 + 2 * q1 * c1.r;
    var remainder = Remainder{
        .cubic = gain * e0.cubic + e1.cubic * l * l * l + q1 * q0 * (2 * a0 + q0 * r),
        .mixed = gain * e0.mixed + e1.mixed * l + 2 * q1 * b0 * (a0 + q0 * r) +
            e1.cubic * 3 * l * b * (l * r + b * max_dc),
        .parameter_squared = gain * e0.parameter_squared + e1.mixed * b +
            e1.parameter_squared + q1 * b0 * b0 + e1.cubic * b * b * b * max_dc,
        .delta_roundoff = gain * e0.delta_roundoff + e1.delta_roundoff * l + roundoff * a0 * a1 +
            roundoff * (a1 * q0 + q1 * a0 * a0) * r,
        .parameter_roundoff = gain * e0.parameter_roundoff + e1.delta_roundoff * b + e1.parameter_roundoff +
            roundoff * (a1 * b0 + b1),
    };
    inline for (@typeInfo(Remainder).@"struct".fields) |field| {
        @field(remainder, field.name) *= 1 + roundoff;
    }
    if (!(l * r + b * max_dc <= c1.r * (1 - roundoff)) or !std.math.isFinite(remainder.bound(r, max_dc))) {
        r = 0;
    } else {
        // Compare positive coefficient sums so cancellation in the map does
        // not distort its scale. Halving r preserves the mapped-child bound.
        const a = magnitude(a_re, a_im);
        const b_out = magnitude(b_re, b_im) * max_dc;
        const parameter_error = remainder.bound(0, max_dc);
        if (parameter_error > model_tolerance * b_out) r = 0;
        while (r > 0 and remainder.bound(r, max_dc) > model_tolerance * (a * r + b_out)) {
            r *= 0.5;
        }
    }

    return .{
        .a_re = a_re,
        .a_im = a_im,
        .q_re = q_re,
        .q_im = q_im,
        .b_re = b_re,
        .b_im = b_im,
        .r = r,
        .remainder = remainder,
        .len = c0.len + c1.len,
    };
}

/// Iterate a deep pixel with the same classification and smooth escape
/// tolerance as plain perturbation.
///
/// Thin wrapper over `iterateDeltaBlaCounted`, so its value is identical to that core's `.value`.
pub fn iterateDeltaBla(
    orbit: *const perturb.ReferenceOrbit,
    table: *const BlaTable,
    dc_re: f64,
    dc_im: f64,
    max_iter: u32,
) f32 {
    return iterateDeltaBlaCounted(orbit, table, dc_re, dc_im, max_iter).value;
}

/// `iterateDeltaBla`'s loop, counting ELEMENTARY steps: a taken approximation skip counts as ONE step
/// regardless of the run length, a single perturbation step as one, and a rebase as one — so the
/// count is directly comparable to `perturb.iterateDeltaCounted`, and a real skip shows up as a
/// far smaller total. Account for rejected polynomial evaluations and any
/// exact replay as well.
pub fn iterateDeltaBlaCounted(
    orbit: *const perturb.ReferenceOrbit,
    table: *const BlaTable,
    dc_re: f64,
    dc_im: f64,
    max_iter: u32,
) perturb.StepResult {
    const attempt = tryAccelerated(orbit, table, dc_re, dc_im, max_iter);
    if (attempt.value) |value| return .{ .value = value, .steps = attempt.steps };

    var exact = perturb.iterateDeltaCounted(orbit.*, dc_re, dc_im, max_iter);
    exact.steps += attempt.steps;
    return exact;
}

const Attempt = struct {
    // An absent value means the bounds could not certify the result.
    value: ?f32,
    steps: u64,
};

fn tryAccelerated(
    orbit: *const perturb.ReferenceOrbit,
    table: *const BlaTable,
    dc_re: f64,
    dc_im: f64,
    max_iter: u32,
) Attempt {
    const orbit_len = orbit.len();
    // Mirror `perturb.iterateDeltaCounted`: an orbit of only `Z_0` carries no `Z_1 = C`.
    if (orbit_len < 2) return .{ .value = mandelbrot.interior_sentinel, .steps = 0 };

    var m: usize = 0;
    var d_re: f64 = 0.0;
    var d_im: f64 = 0.0;
    var z_re: f64 = 0.0; // Z_0 + δ_0 = 0
    var z_im: f64 = 0.0;
    var steps: u64 = 0;

    const dc = magnitude(dc_re, dc_im) * (1 + roundoff);
    if (dc > table.max_dc) return .{ .value = null, .steps = 0 };
    var uncertainty: f64 = 0;
    var n: u32 = 0;
    var escaped = false;
    while (n < max_iter) {
        // Rebasing (Zhuoran) — IDENTICAL trigger and effect to `perturb.iterateDeltaCounted`, so
        // the accelerated path re-anchors on `Z_0` exactly where the plain one does.
        const d_mag_squared = d_re * d_re + d_im * d_im;
        const z_abs = magnitude(z_re, z_im);
        const ref_abs = magnitude(orbit.re[m], orbit.im[m]);
        const rebase_margin = @abs(ref_abs * ref_abs + 2 * (orbit.re[m] * d_re + orbit.im[m] * d_im));
        if (m > 0 and m + 1 < orbit_len and uncertainty > 0 and
            rebase_margin <= 2 * ref_abs * uncertainty + roundoff * (z_abs * z_abs + d_mag_squared))
            return .{ .value = null, .steps = steps };
        if (z_re * z_re + z_im * z_im < d_mag_squared or m + 1 >= orbit_len) {
            if (uncertainty > 0) uncertainty += roundoff * z_abs;
            d_re = z_re;
            d_im = z_im;
            m = 0;
            steps += 1;
        }

        // Try the longest valid approximation skip starting at `m`; a block of length > 1 is a
        // real skip. (A length-1 block is an exact level-0 step, so fall through to the exact
        // step instead — same value, and it keeps `perturb`'s arithmetic byte-for-byte.)
        // Use the CURRENT `|δ|²` (recomputed, since a rebase just above may have replaced `δ`).
        const d = magnitude(d_re, d_im);
        const input_bound = (d + uncertainty) * (1 + roundoff);
        if (table.largestValidBlock(m, input_bound * input_bound, n, max_iter)) |blk| {
            if (blk.len > 1) {
                // δ ← A·δ + Q·δ² + B·δc
                const d2_re = d_re * d_re - d_im * d_im; // Re(δ²)
                const d2_im = 2.0 * d_re * d_im; // Im(δ²)
                const new_d_re = (blk.a_re * d_re - blk.a_im * d_im) +
                    (blk.q_re * d2_re - blk.q_im * d2_im) +
                    (blk.b_re * dc_re - blk.b_im * dc_im);
                const new_d_im = (blk.a_re * d_im + blk.a_im * d_re) +
                    (blk.q_re * d2_im + blk.q_im * d2_re) +
                    (blk.b_re * dc_im + blk.b_im * dc_re);
                const new_m = m + blk.len;
                const new_z_re = orbit.re[new_m] + new_d_re;
                const new_z_im = orbit.im[new_m] + new_d_im;
                // Mapped child radii certify the intermediate points. Check
                // the endpoint explicitly because it starts no child.
                const a = magnitude(blk.a_re, blk.a_im);
                const q = magnitude(blk.q_re, blk.q_im);
                const b = magnitude(blk.b_re, blk.b_im);
                const next_uncertainty = uncertainty * (a + q * (2 * d + uncertainty)) +
                    blk.remainder.bound(input_bound, dc) + roundoff * (a * d + q * d * d + b * dc);
                if (magnitude(new_z_re, new_z_im) + next_uncertainty <= bail_radius * (1 - roundoff)) {
                    uncertainty = next_uncertainty;
                    d_re = new_d_re;
                    d_im = new_d_im;
                    m = new_m;
                    n += blk.len;
                    steps += 1;
                    z_re = new_z_re;
                    z_im = new_z_im;
                    continue;
                }
                steps += 1; // A rejected polynomial evaluation still costs an elementary step.
            }
        }

        // Fallback: one exact perturbation step — byte-identical to `perturb.iterateDeltaCounted`.
        if (uncertainty > 0) {
            uncertainty = uncertainty * (2 * magnitude(orbit.re[m] + d_re, orbit.im[m] + d_im) + uncertainty) +
                roundoff * (2 * magnitude(orbit.re[m], orbit.im[m]) * input_bound +
                    input_bound * input_bound + dc);
        }
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
        steps += 1;

        z_re = orbit.re[m] + d_re;
        z_im = orbit.im[m] + d_im;
        const endpoint = magnitude(z_re, z_im);
        if (uncertainty > 0 and @abs(endpoint - bail_radius) <= uncertainty + roundoff * endpoint)
            return .{ .value = null, .steps = steps };
        if (z_re * z_re + z_im * z_im > mandelbrot.bail_radius_squared) {
            if (uncertainty > 0 and !smoothEscapeCertified(
                endpoint,
                uncertainty + roundoff * endpoint,
                magnitude(orbit.re[1] + dc_re, orbit.im[1] + dc_im) * (1 + roundoff),
                n,
            )) return .{ .value = null, .steps = steps };
            escaped = true;
            break;
        }
    }

    if (!escaped) return .{ .value = mandelbrot.interior_sentinel, .steps = steps };

    // Same colouring tail as `perturb.iterateDeltaCounted`: never restate the escape maths.
    return .{
        .value = mandelbrot.smoothEscapeValue(
            f64,
            z_re,
            z_im,
            orbit.re[1] + dc_re,
            orbit.im[1] + dc_im,
            n,
        ),
        .steps = steps,
    };
}

fn smoothEscapeCertified(endpoint: f64, uncertainty: f64, parameter: f64, n: u32) bool {
    if (uncertainty > 0.125 or n >= 1 << 23 or parameter > bail_radius) return false;

    // On the segment between the two possible inputs, every magnitude r
    // in the coloring tail is at least the previous minimum squared minus
    // |c|. The relative derivative of z²+c is at most 2r²/(r²-|c|),
    // decreasing with r. Propagate that derivative, then apply the
    // derivative of log2(log2(r)). Half an iteration leaves room for f32
    // conversion and f64 arithmetic in the coloring routine.
    var lower = (endpoint - uncertainty) * (1 - roundoff);
    if (!(lower > 1)) return false;
    var relative_error = uncertainty / lower;
    for (0..mandelbrot.extra_iterations) |_| {
        const squared = lower * lower;
        lower = (squared - parameter) * (1 - roundoff);
        if (!(lower > 1)) return false;
        relative_error *= (2 * squared / lower) * (1 + roundoff);
    }
    return relative_error * (1 + roundoff) / (@log(2.0) * @log(lower)) < 0.5;
}

const fallback_format = "GPU BLA path skipped: the acceleration table has {d} blocks, " ++
    "exceeding the GPU budget of {d} blocks; the CPU completed this render";

/// Capacity for any table block count on this platform.
pub const fallback_message_buf_len: usize =
    (std.fmt.comptimePrint(fallback_format, .{ std.math.maxInt(usize), gpu_max_table_len })).len;

/// Report the size that ruled out GPU acceleration and the CPU completion.
pub fn gpuFallbackMessage(buf: []u8, blocks: usize) error{NoSpaceLeft}![]u8 {
    return std.fmt.bufPrint(buf, fallback_format, .{ blocks, gpu_max_table_len });
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const viewport = @import("viewport.zig");

/// The reference centre for the deep tests: the seahorse-valley boundary point the milestone's
/// acceptance tests use, which keeps producing structure past 1e-30.
const deep_center = viewport.ComplexHi{
    .re = -0.743643887037158704752191506114774,
    .im = 0.131825904205311970493132056385139,
};

/// `max_dc` for a square view of `side`: the corner delta `side·√2/2`, the table-build signature
/// everywhere in this milestone.
fn cornerDc(side: f64) f64 {
    return side * std.math.sqrt2 / 2.0;
}

test "a level-0 block reproduces one perturbation step exactly" {
    // The table's ground truth: a single perturbation step IS degree-2 (`2·Z_m·δ + δ² + δc`),
    // so a level-0 block's `A·δ + Q·δ² + B·δc` reproduces it exactly — no dropped term, hence
    // `Q = 1` and the two evaluations agree to rounding for any `δ`.
    const max_iter: u32 = 4096;
    var orbit = try perturb.ReferenceOrbit.compute(testing.allocator, deep_center, max_iter);
    defer orbit.deinit(testing.allocator);
    var table = try BlaTable.build(testing.allocator, &orbit, cornerDc(1.0e-20));
    defer table.deinit(testing.allocator);

    const m: usize = 8; // an arbitrary interior step; `Z_8` is comfortably non-zero.
    const blk = table.levels[0][m];
    try testing.expectEqual(@as(u32, 1), blk.len);
    try testing.expectEqual(@as(f64, 1.0), blk.q_re);
    try testing.expectEqual(@as(f64, 0.0), blk.q_im);

    const dc_re: f64 = 1.0e-21;
    const dc_im: f64 = -2.0e-21;
    const d_re: f64 = 3.0e-13;
    const d_im: f64 = 1.0e-13;

    // Degree-2 (BLA) result.
    const d2_re = d_re * d_re - d_im * d_im;
    const d2_im = 2.0 * d_re * d_im;
    const bla_re = (blk.a_re * d_re - blk.a_im * d_im) +
        (blk.q_re * d2_re - blk.q_im * d2_im) + (blk.b_re * dc_re - blk.b_im * dc_im);
    const bla_im = (blk.a_re * d_im + blk.a_im * d_re) +
        (blk.q_re * d2_im + blk.q_im * d2_re) + (blk.b_re * dc_im + blk.b_im * dc_re);

    // Exact one-step result: δ ← 2·Z_m·δ + δ² + δc.
    const zr = orbit.re[m];
    const zi = orbit.im[m];
    const exact_re = 2.0 * (zr * d_re - zi * d_im) + (d_re * d_re - d_im * d_im) + dc_re;
    const exact_im = 2.0 * (zr * d_im + zi * d_re) + 2.0 * d_re * d_im + dc_im;

    try testing.expectApproxEqRel(exact_re, bla_re, 1.0e-12);
    try testing.expectApproxEqRel(exact_im, bla_im, 1.0e-12);
}

test "a merged block matches iterating its run directly, inside its radius" {
    // The degree-2 composition's ground truth: applying a length-2 block's `A·δ + Q·δ² + B·δc`
    // must match iterating those two reference steps EXACTLY, for a `δ` well inside the block's
    // radius, to within the dropped `δ³` term the radius keeps negligible.
    const max_iter: u32 = 4096;
    var orbit = try perturb.ReferenceOrbit.compute(testing.allocator, deep_center, max_iter);
    defer orbit.deinit(testing.allocator);
    var table = try BlaTable.build(testing.allocator, &orbit, cornerDc(1.0e-20));
    defer table.deinit(testing.allocator);

    const j: usize = 4; // level-1 block over steps [8, 10): an interior, non-zero run.
    const blk = table.levels[1][j];
    try testing.expectEqual(@as(u32, 2), blk.len);
    try testing.expect(blk.r > 0.0);

    // A δc and a δ comfortably INSIDE the block's radius, so the dropped δ³ is negligible.
    const dc_re: f64 = blk.r * 1.0e-3;
    const dc_im: f64 = -blk.r * 2.0e-3;
    const d_re: f64 = blk.r * 0.2;
    const d_im: f64 = -blk.r * 0.1;

    // Degree-2 (BLA) result.
    const d2_re = d_re * d_re - d_im * d_im;
    const d2_im = 2.0 * d_re * d_im;
    const bla_re = (blk.a_re * d_re - blk.a_im * d_im) +
        (blk.q_re * d2_re - blk.q_im * d2_im) + (blk.b_re * dc_re - blk.b_im * dc_im);
    const bla_im = (blk.a_re * d_im + blk.a_im * d_re) +
        (blk.q_re * d2_im + blk.q_im * d2_re) + (blk.b_re * dc_im + blk.b_im * dc_re);

    // Exact: iterate the two reference steps starting at m = 2*j.
    var er = d_re;
    var ei = d_im;
    var k: usize = 2 * j;
    while (k < 2 * j + 2) : (k += 1) {
        const zr = orbit.re[k];
        const zi = orbit.im[k];
        const nr = 2.0 * (zr * er - zi * ei) + (er * er - ei * ei) + dc_re;
        const ni = 2.0 * (zr * ei + zi * er) + 2.0 * er * ei + dc_im;
        er = nr;
        ei = ni;
    }

    try testing.expectApproxEqAbs(er, bla_re, @abs(er) * 1.0e-6 + 1.0e-25);
    try testing.expectApproxEqAbs(ei, bla_im, @abs(ei) * 1.0e-6 + 1.0e-25);
}

test "a merged block never admits a larger delta than its first child" {
    // The invariant the largest-valid-block climb rests on: `r = min(r₀, …)`, so a parent can
    // never admit a `|δ|` its FIRST child (the one sharing its start index) would reject. Hence a
    // valid parent guarantees a valid first child, and the climb never back-tracks. (The parent
    // is mapped through the first child's full midpoint bound.)
    const max_iter: u32 = 4096;
    var orbit = try perturb.ReferenceOrbit.compute(testing.allocator, deep_center, max_iter);
    defer orbit.deinit(testing.allocator);
    var table = try BlaTable.build(testing.allocator, &orbit, cornerDc(1.0e-20));
    defer table.deinit(testing.allocator);

    try testing.expect(table.levels.len >= 2);
    var ell: usize = 1;
    while (ell < table.levels.len) : (ell += 1) {
        for (table.levels[ell], 0..) |parent, j| {
            try testing.expect(parent.r <= table.levels[ell - 1][2 * j].r);
        }
    }
}

test "a block starting at Z_0 has zero radius, forcing an exact step after each rebase" {
    // The conditioning radius at Z_0 is zero and propagates to its parents. A skip is thus
    // never taken right after a rebase — the exact `δ ← δ² + δc` step there is preserved. (The
    // level-0 block at index 0 is exact and length-1, so it always falls through to that step.)
    const max_iter: u32 = 256;
    var orbit = try perturb.ReferenceOrbit.compute(testing.allocator, deep_center, max_iter);
    defer orbit.deinit(testing.allocator);
    var table = try BlaTable.build(testing.allocator, &orbit, cornerDc(1.0e-20));
    defer table.deinit(testing.allocator);

    try testing.expect(table.levels.len >= 2);
    try testing.expectEqual(@as(f64, 0.0), table.levels[1][0].r);
}

test "a large-delta pixel matches plain perturbation" {
    // The spec's radius scenario (task-owned unit test): a pixel whose delta grows large enough
    // to force repeated rebasing still matches `perturb.iterateDelta` within one iteration and
    // both escape — because an approximation skip is taken ONLY inside a run's safety radius,
    // and a single exact step is taken otherwise, so the accelerated path never diverges.
    const max_iter: u32 = 4096;
    var orbit = try perturb.ReferenceOrbit.compute(testing.allocator, deep_center, max_iter);
    defer orbit.deinit(testing.allocator);
    // The rebasing pixel from `perturb.zig`'s own test: a 1e-6 view offset that rebases ~20 times.
    const side: f64 = 1.0e-6;
    var table = try BlaTable.build(testing.allocator, &orbit, cornerDc(side));
    defer table.deinit(testing.allocator);

    const dc_re: f64 = -3.125e-8;
    const dc_im: f64 = 2.8125e-7;
    const plain = perturb.iterateDeltaCounted(orbit, dc_re, dc_im, max_iter);
    const accelerated = iterateDeltaBlaCounted(&orbit, &table, dc_re, dc_im, max_iter);
    try testing.expect(plain.value != mandelbrot.interior_sentinel);
    try testing.expect(plain.steps - @as(u64, @intFromFloat(@floor(plain.value))) > 10);
    try testing.expectEqual(plain, accelerated);
}

test "iterateDeltaBla classifies a deep interior pixel as interior, in far fewer steps" {
    // A pixel that never escapes: BLA leaps through the reference with big blocks and reaches
    // `max_iter` in a fraction of the plain path's steps, still returning the interior sentinel.
    const max_iter: u32 = 4096;
    var orbit = try perturb.ReferenceOrbit.compute(testing.allocator, deep_center, max_iter);
    defer orbit.deinit(testing.allocator);
    var table = try BlaTable.build(testing.allocator, &orbit, cornerDc(1.0e-25));
    defer table.deinit(testing.allocator);

    const plain = perturb.iterateDeltaCounted(orbit, 0.0, 0.0, max_iter);
    const bla = iterateDeltaBlaCounted(&orbit, &table, 0.0, 0.0, max_iter);
    try testing.expectEqual(mandelbrot.interior_sentinel, bla.value);
    try testing.expectEqual(plain.value, bla.value);
    try testing.expect(bla.steps < plain.steps);
}

test "build on an orbit too short to step returns an empty table" {
    // `max_iter = 0` records only `Z_0`, so there is no step to approximate. An empty table means
    // `iterateDeltaBla` takes only exact steps and equals the plain path (which also bails).
    var orbit = try perturb.ReferenceOrbit.compute(testing.allocator, deep_center, 0);
    defer orbit.deinit(testing.allocator);
    var table = try BlaTable.build(testing.allocator, &orbit, cornerDc(1.0e-20));
    defer table.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), table.levels.len);
    try testing.expectEqual(@as(usize, 0), table.len());
    try testing.expectEqual(
        mandelbrot.interior_sentinel,
        iterateDeltaBla(&orbit, &table, 1.0e-6, 0.0, 64),
    );
}

test "an empty-table BLA loop equals the plain path step for step" {
    // With no blocks, every position falls through to the exact perturbation step, so BLA must
    // reproduce `perturb.iterateDeltaCounted` in both value AND step count.
    const max_iter: u32 = 512;
    // A centre that escapes early, so its orbit is short and carries a genuine step budget.
    const escaping = viewport.ComplexHi{ .re = 0.3, .im = 0.0 };
    var orbit = try perturb.ReferenceOrbit.compute(testing.allocator, escaping, max_iter);
    defer orbit.deinit(testing.allocator);
    var empty = BlaTable{ .levels = &.{} };
    defer empty.deinit(testing.allocator);

    const plain = perturb.iterateDeltaCounted(orbit, 1.0e-7, -1.0e-7, max_iter);
    const bla = iterateDeltaBlaCounted(&orbit, &empty, 1.0e-7, -1.0e-7, max_iter);
    try testing.expectEqual(@as(u32, @bitCast(plain.value)), @as(u32, @bitCast(bla.value)));
    try testing.expectEqual(plain.steps, bla.steps);
}

test "build leaks nothing, including when one of its allocations fails" {
    var orbit = try perturb.ReferenceOrbit.compute(testing.allocator, deep_center, 64);
    defer orbit.deinit(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, buildAndFree, .{&orbit});
}

fn buildAndFree(alloc: std.mem.Allocator, orbit: *const perturb.ReferenceOrbit) !void {
    var table = try BlaTable.build(alloc, orbit, cornerDc(1.0e-20));
    table.deinit(alloc);
}

test "gpuFallbackMessage names the CPU and the table budget" {
    var buf: [fallback_message_buf_len]u8 = undefined;
    const msg = try gpuFallbackMessage(&buf, gpu_max_table_len + 1);
    try testing.expect(std.mem.indexOf(u8, msg, "CPU") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "table") != null);
}

test "fallback_message_buf_len fits the largest block count exactly" {
    var exact: [fallback_message_buf_len]u8 = undefined;
    var short: [fallback_message_buf_len - 1]u8 = undefined;
    const blocks = std.math.maxInt(usize);
    const msg = try gpuFallbackMessage(&exact, blocks);
    try testing.expectEqual(fallback_message_buf_len, msg.len);
    try testing.expectError(error.NoSpaceLeft, gpuFallbackMessage(&short, blocks));
}

test "gpu_max_table_len is twice the orbit budget, enough for a full tree over the longest orbit" {
    // A full binary tree over `L` orbit entries is `< 2·(L−1) < 2·L` blocks, so any orbit the GPU
    // can upload (`perturb.gpu_max_orbit_len`) yields a table that also fits.
    try testing.expectEqual(2 * perturb.gpu_max_orbit_len, gpu_max_table_len);
    try testing.expect(gpu_max_table_len > perturb.gpu_max_orbit_len);
}

test "a full table over a real orbit stays within the GPU budget" {
    const max_iter: u32 = 4096;
    var orbit = try perturb.ReferenceOrbit.compute(testing.allocator, deep_center, max_iter);
    defer orbit.deinit(testing.allocator);
    var table = try BlaTable.build(testing.allocator, &orbit, cornerDc(1.0e-20));
    defer table.deinit(testing.allocator);
    // ≈ 2·(L−1) blocks, and L ≤ max_iter+1 ≪ gpu_max_orbit_len here.
    try testing.expect(table.len() < 2 * orbit.len());
    try testing.expect(table.len() < gpu_max_table_len);
}

test "CPU BLA draws a deep grid in fewer than a tenth of the plain steps" {
    const iterbuf = @import("iterbuf.zig");
    const view = try viewport.SquareView.fromCenterSide(deep_center, 1e-25);
    const vp = view.rectViewport(8, 8);
    const cap = 65536;
    var orbit = try perturb.ReferenceOrbit.compute(testing.allocator, view.center(), cap);
    defer orbit.deinit(testing.allocator);
    var table = try BlaTable.build(testing.allocator, &orbit, cornerDc(1e-25));
    defer table.deinit(testing.allocator);
    var plain: [64]f32 = undefined;
    var accelerated: [64]f32 = undefined;
    const plain_steps = try iterbuf.iterateDeepBandCountedInto(&plain, vp, cap, 0, 8, &orbit);
    const accelerated_steps = try iterbuf.iterateDeepBandBlaCountedInto(&accelerated, vp, cap, 0, 8, &orbit, &table);
    var gap: f32 = 0;
    for (plain, accelerated) |p, a| {
        try testing.expectEqual(p == mandelbrot.interior_sentinel, a == mandelbrot.interior_sentinel);
        gap = @max(gap, @abs(p - a));
        try testing.expectApproxEqAbs(p, a, 1.0);
    }
    errdefer std.debug.print("BLA steps {d}/{d}, gap {d}\n", .{ accelerated_steps, plain_steps, gap });
    try testing.expect(accelerated_steps * 10 < plain_steps);
}

test "the merged remainder covers a pure parameter term at zero delta" {
    const dc = 1e-8;
    var orbit = try perturb.ReferenceOrbit.compute(testing.allocator, .{ .re = 0.25, .im = 0 }, 16);
    defer orbit.deinit(testing.allocator);
    var table = try BlaTable.build(testing.allocator, &orbit, dc);
    defer table.deinit(testing.allocator);

    const block = table.levels[1][1];
    try testing.expect(block.r > 0);
    // At d=0, the first step outputs dc. The contribution dc² in
    // the second step is absent from the merged map.
    try testing.expect(block.remainder.bound(0, dc) >= dc * dc);
}

test "the merged input boundary keeps the full midpoint in the second child" {
    const dc = 1e-8;
    var orbit = try perturb.ReferenceOrbit.compute(testing.allocator, .{ .re = 0.25, .im = 0 }, 16);
    defer orbit.deinit(testing.allocator);
    var table = try BlaTable.build(testing.allocator, &orbit, dc);
    defer table.deinit(testing.allocator);

    // The parent over [4,8] must fit a second child whose radius is
    // smaller than its midpoint under the uncorrected linear mapping.
    const first = table.levels[1][2];
    const second = table.levels[1][3];
    const parent = table.levels[2][1];
    const linear_radius = (second.r - first.b_re * dc) / first.a_re;
    try testing.expect(parent.r > 0);
    try testing.expect(parent.r < linear_radius);
    const middle = first.a_re * parent.r + first.q_re * parent.r * parent.r + first.b_re * dc;
    try testing.expect(middle + first.remainder.bound(parent.r, dc) <= second.r);
}

test "an uncertain escape is replayed and both attempts are counted" {
    const cap = 6;
    // This real coordinate lands on the escape circle at step six.
    var orbit = try perturb.ReferenceOrbit.compute(testing.allocator, .{
        .re = 0.4034021396950287130433964289322666,
        .im = 0,
    }, cap);
    defer orbit.deinit(testing.allocator);
    var table = try BlaTable.build(testing.allocator, &orbit, 1e-14);
    defer table.deinit(testing.allocator);

    const dc = 1e-17;
    const trial = tryAccelerated(&orbit, &table, dc, 0, cap);
    try testing.expectEqual(@as(?f32, null), trial.value);
    try testing.expect(trial.steps > 0);
    const plain = perturb.iterateDeltaCounted(orbit, dc, 0, cap);
    const accelerated = iterateDeltaBlaCounted(&orbit, &table, dc, 0, cap);
    try testing.expectEqual(perturb.StepResult{
        .value = plain.value,
        .steps = plain.steps + trial.steps,
    }, accelerated);
}

test "a certified skip returns its value and charges only its first attempt" {
    const cap = 64;
    var orbit = try perturb.ReferenceOrbit.compute(testing.allocator, .{ .re = -0.5, .im = 0 }, cap);
    defer orbit.deinit(testing.allocator);
    var table = try BlaTable.build(testing.allocator, &orbit, 1e-14);
    defer table.deinit(testing.allocator);

    const dc = 1e-15;
    const trial = tryAccelerated(&orbit, &table, dc, 0, cap);
    const accelerated = iterateDeltaBlaCounted(&orbit, &table, dc, 0, cap);
    try testing.expect(trial.steps < cap);
    try testing.expectEqual(perturb.StepResult{ .value = trial.value.?, .steps = trial.steps }, accelerated);
}

test "CPU BLA preserves plain values across separate reference orbits" {
    const centers = [_]viewport.ComplexHi{
        .{ .re = -0.743643887037151, .im = 0.13182590420533 },
        .{ .re = -1.25066, .im = 0.02012 },
        .{ .re = 0.25, .im = 0 },
        .{ .re = -2, .im = 0 },
    };
    const cap = 8192;
    for (centers) |center| {
        var orbit = try perturb.ReferenceOrbit.compute(testing.allocator, center, cap);
        defer orbit.deinit(testing.allocator);
        for ([_]f64{ 1e-6, 1e-15, 1e-20, 1e-30 }) |side| {
            var table = try BlaTable.build(testing.allocator, &orbit, cornerDc(side));
            defer table.deinit(testing.allocator);
            for (0..35) |i| {
                const dc_re = (@as(f64, @floatFromInt(i % 7)) - 3) * side / 7;
                const dc_im = (2 - @as(f64, @floatFromInt(i / 7))) * side / 7;
                const plain = perturb.iterateDelta(orbit, dc_re, dc_im, cap);
                const accelerated = iterateDeltaBla(&orbit, &table, dc_re, dc_im, cap);
                try testing.expectEqual(plain == mandelbrot.interior_sentinel, accelerated == mandelbrot.interior_sentinel);
                try testing.expectApproxEqAbs(plain, accelerated, 1);
            }
        }
    }
}
