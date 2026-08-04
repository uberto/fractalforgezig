// mandelbrot.metal — MSL compute kernel for Mandelbrot iteration.
//
// Uniform layout (MandelbrotUniforms):
//   float  center_re  — real part of the viewport center (complex plane)
//   float  center_im  — imaginary part of the viewport center (complex plane)
//   float  scale      — complex-plane distance per pixel (side_length / side_pixels)
//   uint   side       — square image side in pixels (width == height == side)
//   uint   max_iter   — maximum iteration count before declaring interior
//
// Pixel-to-complex mapping (matches viewport.zig pixelToComplex, +0.5 pixel center):
//   re = center_re + (col + 0.5 - side / 2.0) * scale
//   im = center_im + (side / 2.0 - row - 0.5) * scale   // y-axis inverted: top = max im
//
// Output buffer (iter_out):
//   For each pixel index (row * side + col), writes one float:
//     - Interior points (reached max_iter without escaping): -1.0  (interior_sentinel)
//     - Escaped points: smooth escape value = n + 1 - log2(log2(|z|))
//       where n is the iteration count (with 2 extra steps for accuracy) at escape.
//
// Smooth formula (matches fractal/mandelbrot.zig exactly):
//   bail_radius_squared = 4.0  (bail radius 2; tested as |z|^2 > 4)
//   extra_iterations    = 2    (after escape crossing, 2 more z=z^2+c steps)
//   smooth = n + 1.0 - log2(log2(length(z)))  evaluated after extra steps
//   NaN/Inf guard: falls back to float(escape_n) — the plain escape count.

#include <metal_stdlib>
using namespace metal;

struct MandelbrotUniforms {
    float center_re;
    float center_im;
    float scale;
    uint  side;
    uint  max_iter;
};

kernel void mandelbrot_iterate(
    device float*                 iter_out [[ buffer(0) ]],
    constant MandelbrotUniforms&  u        [[ buffer(1) ]],
    uint                          gid      [[ thread_position_in_grid ]]
) {
    uint total = u.side * u.side;
    if (gid >= total) return;

    uint col = gid % u.side;
    uint row = gid / u.side;

    // Pixel-to-complex: pixel center at (col + 0.5, row + 0.5), y-axis inverted.
    float half = float(u.side) * 0.5f;
    float c_re = u.center_re + (float(col) + 0.5f - half) * u.scale;
    float c_im = u.center_im + (half - float(row) - 0.5f) * u.scale;

    // Mandelbrot iteration: z = z^2 + c, starting from z = 0.
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

    // Interior: never escaped within max_iter.
    if (!escaped) {
        iter_out[gid] = -1.0f;
        return;
    }

    // Extra iterations to grow |z| well past bail radius, improving smooth term.
    // Matches mandelbrot.zig extra_iterations = 2.
    for (uint e = 0; e < 2; e++) {
        float next_re = z_re * z_re - z_im * z_im + c_re;
        float next_im = 2.0f * z_re * z_im + c_im;
        z_re = next_re;
        z_im = next_im;
        n += 1;
    }

    float mag = length(float2(z_re, z_im));
    float smooth_val = float(n) + 1.0f - log2(log2(mag));

    // NaN/Inf guard: fast-escaping huge-|c| points may overflow. Fall back to
    // plain escape count (finite, >= 1, distinct from interior_sentinel -1.0).
    if (!isfinite(smooth_val)) {
        smooth_val = float(escape_n);
    }

    iter_out[gid] = smooth_val;
}
