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
kernel void mandelbrot_iterate_deep(
    constant MandelbrotDeepUniforms&  u        [[ buffer(0) ]],
    const device float2*              orbit    [[ buffer(1) ]],
    device float*                     iter_out [[ buffer(2) ]],
    uint                              gid      [[ thread_position_in_grid ]]
) {
    uint total = u.width * u.band_rows;
    if (gid >= total) return;

    // An orbit of only `Z_0 = 0` carries no `Z_1 = C`: nothing to iterate against, and no way
    // to recover the centre. Answer like an exhausted budget instead of reading past the end.
    if (u.orbit_len < 2) {
        iter_out[gid] = INTERIOR_SENTINEL;
        return;
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
        if (z_re * z_re + z_im * z_im < d_mag_squared || m + 1 >= u.orbit_len) {
            d_re = z_re;
            d_im = z_im;
            m = 0;
        }

        float2 ref = orbit[m];
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
        if (z_re * z_re + z_im * z_im > BAIL_RADIUS_SQUARED) {
            escaped  = true;
            escape_n = n;
            break;
        }
    }

    if (!escaped) {
        iter_out[gid] = INTERIOR_SENTINEL;
        return;
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

    iter_out[gid] = smooth_val;
}
