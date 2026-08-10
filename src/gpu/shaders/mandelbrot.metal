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
