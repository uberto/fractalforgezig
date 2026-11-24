// mandelbrot.metal — MSL compute kernel for Mandelbrot iteration.
//
// Uniform layout (MandelbrotUniforms):
//   float  center_re  — real part of the viewport center (complex plane)
//   float  center_im  — imaginary part of the viewport center (complex plane)
//   float  scale      — complex-plane distance per pixel (view.side / min(width, height))
//   uint   width      — image width in pixels
//   uint   height     — image height in pixels
//   uint   max_iter   — maximum iteration count before declaring interior
//   uint   row_offset  — global image row this band starts at
//   uint   band_rows   — rows in this band (band_rows == height ⇒ whole image)
//
// BANDS: one dispatch covers `band_rows` rows starting at `row_offset`, and `iter_out` holds
// ONLY those rows (band-local indices). `height` stays the FULL image height because the
// complex mapping is anchored on the image center, not the band's. This is what lets a
// high max_iter be split across frames instead of one multi-second dispatch the GPU
// watchdog would abort.
//
// Pixel-to-complex mapping (matches viewport.zig rectViewport / pixelToComplex):
//   re = center_re + (col + 0.5 - width  / 2.0) * scale
//   im = center_im + (height / 2.0 - row - 0.5) * scale   // y-axis inverted, GLOBAL row
//
// SDL_GPU MSL buffer slot order: uniforms first (buffer(0)), readwrite last (buffer(1)).
//
// ─── M6/T6: mandelbrot_iterate_deep (the perturbation kernel) ────────────────────────────────
//
// SDL_GPU assigns MSL [[buffer(n)]] slots in ONE fixed order: uniform buffers, then READ-ONLY
// storage buffers, then READ-WRITE storage buffers. So this file's second kernel binds
//   buffer(0) = MandelbrotDeepUniforms   (uniform)
//   buffer(1) = orbit, float2 per entry  (read-only storage: the reference orbit Z_0..Z_{len-1})
//   buffer(2) = iter_out                 (read-write storage — LAST, always)
// Getting that order wrong does not fail: the kernel reads zeros and the image goes flat.
//
// The deep kernel iterates each pixel's DELTA from the view centre instead of its absolute `c`,
// which is what keeps a 32-bit float useful past a view side of 1e-5 (see fractal/perturb.zig).
// It needs no centre in its uniforms: the centre is orbit[1] (= C, since Z_0 = 0), at whatever
// precision the CPU recorded it in.

#define BAIL_RADIUS_SQUARED 4.0f   // fractal/mandelbrot.zig: bail_radius_squared
#define EXTRA_ITERATIONS    2      // fractal/mandelbrot.zig: extra_iterations
#define INTERIOR_SENTINEL  -1.0f   // fractal/mandelbrot.zig: interior_sentinel

#include <metal_stdlib>
using namespace metal;

struct MandelbrotUniforms {
    float center_re;
    float center_im;
    float scale;
    uint  width;
    uint  height;
    uint  max_iter;
    uint  row_offset;
    uint  band_rows;
};

struct MandelbrotDeepUniforms {
    float scale;
    uint  width;
    uint  height;
    uint  max_iter;
    uint  row_offset;
    uint  band_rows;
    uint  orbit_len;
};

kernel void mandelbrot_iterate(
    constant MandelbrotUniforms&  u        [[ buffer(0) ]],
    device float*                 iter_out [[ buffer(1) ]],
    uint                          gid      [[ thread_position_in_grid ]]
) {
    uint total = u.width * u.band_rows;
    if (gid >= total) return;

    uint col = gid % u.width;
    uint row = gid / u.width + u.row_offset;  // GLOBAL row: the mapping is image-anchored

    float w_half = float(u.width)  * 0.5f;
    float h_half = float(u.height) * 0.5f;
    float c_re = u.center_re + (float(col) + 0.5f - w_half) * u.scale;
    float c_im = u.center_im + (h_half - float(row) - 0.5f) * u.scale;

    float z_re = 0.0f;
    float z_im = 0.0f;

    uint  n       = 0;
    bool  escaped = false;
    uint  escape_n = 0;

    while (n < u.max_iter) {
        float next_re = z_re * z_re - z_im * z_im + c_re;
        float next_im = 2.0f * z_re * z_im + c_im;
        z_re = next_re;
        z_im = next_im;
        n += 1;
        if (z_re * z_re + z_im * z_im > 4.0f) {
            escaped  = true;
            escape_n = n;
            break;
        }
    }

    if (!escaped) {
        iter_out[gid] = -1.0f;
        return;
    }

    for (uint e = 0; e < 2; e++) {
        float next_re = z_re * z_re - z_im * z_im + c_re;
        float next_im = 2.0f * z_re * z_im + c_im;
        z_re = next_re;
        z_im = next_im;
        n += 1;
    }

    float mag = length(float2(z_re, z_im));
    float smooth_val = float(n) + 1.0f - log2(log2(mag));

    if (!isfinite(smooth_val)) {
        smooth_val = float(escape_n);
    }

    iter_out[gid] = smooth_val;
}

// ─── The deep (perturbation) kernel ──────────────────────────────────────────────────────────
//
// Uniform layout (MandelbrotDeepUniforms — NO centre; orbit[1] carries it):
//   float scale       — complex-plane distance per pixel (view.side / min(width, height))
//   uint  width       — image width in pixels
//   uint  height      — FULL image height (the mapping is image-anchored, not band-anchored)
//   uint  max_iter    — iteration budget
//   uint  row_offset  — global image row this band starts at
//   uint  band_rows   — rows in this band
//   uint  orbit_len   — entries in `orbit` (Z_0 .. Z_{orbit_len-1}); Z_0 = 0, Z_1 = C
//
// This is `fractal/perturb.zig: iterateDelta` transliterated: same rebasing rule, same escape
// test on the FULL value, same colouring tail. Where it must differ it is called out inline —
// keep the two in step, and prefer changing this file to diverging from the CPU definition.
// Match compute.zig's 48-byte GpuBlaBlock; keep the fields scalar.
struct GpuBlaBlock {
    float a_re;
    float a_im;
    float q_re;
    float q_im;
    float b_re;
    float b_im;
    float r;
    float cubic;
    float mixed;
    float parameter_squared;
    float delta_roundoff;
    float parameter_roundoff;
};

#define BLA_ROUNDOFF (8.0f * FLT_EPSILON)

// At the supported precision floor even normal deltas have subnormal squares.
// Scale the norm and evaluate the polynomial with large coefficients first.
static float bla_norm(float2 z) {
    float largest = max(abs(z.x), abs(z.y));
    float smallest = min(abs(z.x), abs(z.y));
    if (largest == 0.0f) return 0.0f;
    float ratio = smallest / largest;
    return largest * sqrt(1.0f + ratio * ratio);
}

static float2 complex_mul(float2 x, float2 y) {
    return float2(x.x * y.x - x.y * y.y, x.x * y.y + x.y * y.x);
}

static bool bla_smooth_escape_certified(float endpoint, float uncertainty, float parameter) {
    if (uncertainty > 0.125f || parameter > 2.0f) return false;
    float lower = (endpoint - uncertainty) * (1.0f - BLA_ROUNDOFF);
    if (!(lower > 1.0f)) return false;
    float relative_error = uncertainty / lower;
    for (uint e = 0; e < EXTRA_ITERATIONS; e++) {
        float squared = lower * lower;
        lower = (squared - parameter) * (1.0f - BLA_ROUNDOFF);
        if (!(lower > 1.0f)) return false;
        relative_error *= (2.0f * squared / lower) * (1.0f + BLA_ROUNDOFF);
    }
    return relative_error * (1.0f + BLA_ROUNDOFF) / (log(2.0f) * log(lower)) < 0.5f;
}

// The caller restarts with the plain perturbation kernel's arithmetic if the uncertainty
// envelope cannot resolve a rebase, escape or smooth value after a skip.
template<bool accelerated>
static float deep_pixel(
    constant MandelbrotDeepUniforms& u,
    const device float2* orbit,
    const device GpuBlaBlock* table,
    uint gid,
    thread bool& replay
) {
    // An orbit of only `Z_0 = 0` carries no `Z_1 = C`: nothing to iterate against, and no way
    // to recover the centre. Answer like an exhausted budget instead of reading past the end.
    if (u.orbit_len < 2) {
        return INTERIOR_SENTINEL;
    }

    uint col = gid % u.width;
    uint row = gid / u.width + u.row_offset;  // GLOBAL row: the mapping is image-anchored

    float w_half = float(u.width)  * 0.5f;
    float h_half = float(u.height) * 0.5f;
    // The DELTA from the view centre, not the absolute `c`: this is the whole point of the
    // perturbation path, and it is what keeps a 32-bit float useful this far down.
    float dc_re = (float(col) + 0.5f - w_half) * u.scale;
    float dc_im = (h_half - float(row) - 0.5f) * u.scale;

    uint  m    = 0;      // orbit anchor: the invariant is `z == Z_m + δ`, with `m < orbit_len`
    float d_re = 0.0f;
    float d_im = 0.0f;
    float z_re = 0.0f;   // Z_0 + δ_0 = 0 + 0
    float z_im = 0.0f;

    uint n        = 0;
    bool escaped  = false;
    uint escape_n = 0;

    float uncertainty = 0.0f;
    float dc = 0.0f;
    bool can_skip = false;
    if (accelerated) {
        dc = bla_norm(float2(dc_re, dc_im)) * (1.0f + BLA_ROUNDOFF);
        // The first storage entry is the header. A valid nonempty tree has the
        // expected total number of blocks for this orbit, checked by the uploader.
        can_skip = table[0].r > 0.0f && dc <= table[0].r;
    }

    while (n < u.max_iter) {
        // Rebasing (Zhuoran): re-anchor on Z_0 when the delta has grown to dominate the value
        // it corrects, or when the orbit has no next entry. EXACT, because Z_0 = 0.
        //
        // The dominance test is the CPU's, on raw squares, DELIBERATELY. At these view sides the
        // squares do underflow (δ ≈ 1e-21 ⇒ δ² ≈ 1e-42, flushed to zero in a 32-bit float), so a
        // scale-invariant form was written and measured against this one on the 1e-20 agreement
        // test: dividing all four components by the largest first — same predicate, no underflow
        // — moved 7 outlier pixels to 9 and the worst deviation from 429 to 461 iterations. It
        // buys nothing measurable and costs four divisions in the hottest loop in the program, so
        // this stays a transliteration of `perturb.iterateDelta`, which is the one definition of
        // the rule. Do not "fix" the underflow without re-measuring.
        float d_mag_squared = d_re * d_re + d_im * d_im;
        if (accelerated && uncertainty > 0.0f && m > 0 && m + 1 < u.orbit_len) {
            float2 ref = orbit[m];
            float z_abs = bla_norm(float2(z_re, z_im));
            float rebase_margin = abs(dot(ref, ref + 2.0f * float2(d_re, d_im)));
            // The existing GPU rule compares rounded squares. If neither
            // component can change on addition of this anchor, both rounded
            // sides are equal for the entire interval and the rule never rebases.
            float2 min_delta = max(abs(float2(d_re, d_im)) - uncertainty, 0.0f);
            bool anchor_rounds_away = all((ref == 0.0f) |
                (abs(ref) < (0.25f * FLT_EPSILON) * min_delta));
            if (!anchor_rounds_away &&
                rebase_margin <= 2.0f * bla_norm(ref) * uncertainty +
                BLA_ROUNDOFF * (z_abs * z_abs + d_mag_squared)) {
                replay = true;
                return INTERIOR_SENTINEL;
            }
        }
        if (z_re * z_re + z_im * z_im < d_mag_squared || m + 1 >= u.orbit_len) {
            if (accelerated && uncertainty > 0.0f)
                uncertainty += BLA_ROUNDOFF * bla_norm(float2(z_re, z_im));
            d_re = z_re;
            d_im = z_im;
            m = 0;
        }

        float2 ref = orbit[m];
        if (accelerated && can_skip) {
            float2 delta = float2(d_re, d_im);
            float d = bla_norm(delta);
            float input_bound = (d + uncertainty) * (1.0f + BLA_ROUNDOFF);
            uint level_start = 1;
            uint level_count = u.orbit_len - 1;
            uint best_index = 0;
            uint best_len = 1;
            for (uint len = 1, index = m; level_count != 0;
                 len <<= 1, index >>= 1) {
                if (index >= level_count || len > u.max_iter - n) break;
                const device GpuBlaBlock& candidate = table[level_start + index];
                if (!(candidate.r > 0.0f && input_bound <= candidate.r)) break;
                best_index = level_start + index;
                best_len = len;
                if ((index & 1) != 0) break;
                level_start += level_count;
                level_count >>= 1;
            }
            if (best_len > 1) {
                const device GpuBlaBlock& block = table[best_index];
                float2 a = float2(block.a_re, block.a_im);
                float2 q = float2(block.q_re, block.q_im);
                float2 b = float2(block.b_re, block.b_im);
                float2 next_delta = complex_mul(a, delta) +
                    complex_mul(complex_mul(q, delta), delta) + complex_mul(b, float2(dc_re, dc_im));
                float2 next_z = orbit[m + best_len] + next_delta;
                float a_abs = bla_norm(a), q_abs = bla_norm(q), b_abs = bla_norm(b);
                float residual = ((block.cubic * input_bound * input_bound +
                    block.mixed * dc + block.delta_roundoff) * input_bound +
                    (block.parameter_squared * dc + block.parameter_roundoff) * dc) *
                    (1.0f + BLA_ROUNDOFF);
                float next_uncertainty = uncertainty * (a_abs + q_abs * (2.0f * d + uncertainty)) +
                    residual + BLA_ROUNDOFF * (a_abs * d + q_abs * d * d + b_abs * dc);
                if (bla_norm(next_z) + next_uncertainty <= 2.0f * (1.0f - BLA_ROUNDOFF)) {
                    uncertainty = next_uncertainty;
                    d_re = next_delta.x;
                    d_im = next_delta.y;
                    m += best_len;
                    n += best_len;
                    z_re = next_z.x;
                    z_im = next_z.y;
                    continue;
                }
            }
            if (uncertainty > 0.0f) {
                uncertainty = uncertainty * (2.0f * bla_norm(ref + delta) + uncertainty) +
                    BLA_ROUNDOFF * (2.0f * bla_norm(ref) * input_bound +
                    input_bound * input_bound + dc);
            }
        }
        float next_d_re = 2.0f * (ref.x * d_re - ref.y * d_im) +
            (d_re * d_re - d_im * d_im) + dc_re;
        float next_d_im = 2.0f * (ref.x * d_im + ref.y * d_re) +
            2.0f * d_re * d_im + dc_im;
        d_re = next_d_re;
        d_im = next_d_im;
        m += 1;
        n += 1;

        // Restore the invariant, then escape-test on the FULL value (after the step, so `n` is
        // the count at the moment of crossing).
        float2 anchor = orbit[m];
        z_re = anchor.x + d_re;
        z_im = anchor.y + d_im;
        float endpoint = 0.0f;
        if (accelerated && uncertainty > 0.0f) {
            endpoint = bla_norm(float2(z_re, z_im));
            if (abs(endpoint - 2.0f) <= uncertainty + BLA_ROUNDOFF * endpoint) {
                replay = true;
                return INTERIOR_SENTINEL;
            }
        }
        if (z_re * z_re + z_im * z_im > BAIL_RADIUS_SQUARED) {
            if (accelerated && uncertainty > 0.0f && !bla_smooth_escape_certified(
                endpoint, uncertainty + BLA_ROUNDOFF * endpoint,
                bla_norm(orbit[1] + float2(dc_re, dc_im)) * (1.0f + BLA_ROUNDOFF))) {
                replay = true;
                return INTERIOR_SENTINEL;
            }
            escaped  = true;
            escape_n = n;
            break;
        }
    }

    if (!escaped) {
        return INTERIOR_SENTINEL;
    }

    // The colouring tail runs on the ABSOLUTE value. |z| > 2 here, so the pixel's `c` may be
    // taken as `Z_1 + δc`: the rounding it drops cannot move a double-log of a value about to
    // be squared twice. Same formula as `mandelbrot_iterate` above, so deep and shallow values
    // stay comparable across the threshold.
    float2 c1 = orbit[1];
    float c_re = c1.x + dc_re;
    float c_im = c1.y + dc_im;

    for (uint e = 0; e < EXTRA_ITERATIONS; e++) {
        float next_re = z_re * z_re - z_im * z_im + c_re;
        float next_im = 2.0f * z_re * z_im + c_im;
        z_re = next_re;
        z_im = next_im;
        n += 1;
    }

    float mag = length(float2(z_re, z_im));
    float smooth_val = float(n) + 1.0f - log2(log2(mag));

    if (!isfinite(smooth_val)) {
        smooth_val = float(escape_n);
    }

    return smooth_val;
}

kernel void mandelbrot_iterate_deep(
    constant MandelbrotDeepUniforms& u        [[ buffer(0) ]],
    const device float2*             orbit    [[ buffer(1) ]],
    device float*                    iter_out [[ buffer(2) ]],
    uint                             gid      [[ thread_position_in_grid ]]
) {
    if (gid >= u.width * u.band_rows) return;
    bool replay = false;
    iter_out[gid] = deep_pixel<false>(u, orbit, nullptr, gid, replay);
}

kernel void mandelbrot_iterate_deep_bla(
    constant MandelbrotDeepUniforms& u        [[ buffer(0) ]],
    const device float2*             orbit    [[ buffer(1) ]],
    const device GpuBlaBlock*        table    [[ buffer(2) ]],
    device float*                    iter_out [[ buffer(3) ]],
    uint                             gid      [[ thread_position_in_grid ]]
) {
    if (gid >= u.width * u.band_rows) return;
    bool replay = false;
    float value = deep_pixel<true>(u, orbit, table, gid, replay);
    iter_out[gid] = replay ? deep_pixel<false>(u, orbit, nullptr, gid, replay) : value;
}
