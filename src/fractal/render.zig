//! Pure full-image render: compose viewport mapping (T3), Mandelbrot iteration
//! (T4), and coloring (T5) into an RGBA8 buffer for the whole image. NO SDL/GPU
//! imports — this lives in the fast test tier (`zig build test`, no window/device)
//! and is fully unit- and golden-tested.
//!
//! Split of concerns (deliberate — do not merge):
//!   * `renderInto` is the PURE, deterministic path: same inputs ⇒ byte-identical
//!     buffer, no clock, no allocation. This is what the golden test pins.
//!   * `render` is the timing/allocation wrapper for the app: it allocates the
//!     buffer and measures wall-clock elapsed with `std.time.Timer`. Timing lives
//!     ONLY here so nothing on the pure path is exposed to wall-clock flakiness.
//!
//! Pixel sampling: each integer pixel `(x, y)` is sampled at its CENTER
//! `(x + 0.5, y + 0.5)` (the `+0.5` convention documented in `viewport.zig`), so
//! the fixed centered view is exactly symmetric about the real axis: because the
//! Mandelbrot set is symmetric under conjugation and `center_im == 0`, pixel row
//! `y` and row `height-1-y` sample conjugate `c` values and must be byte-identical.
//! That top/bottom mirror is the strongest cheap correctness signal here.
const std = @import("std");
const viewport = @import("viewport.zig");
const mandelbrot = @import("mandelbrot.zig");
const color = @import("color.zig");

const Viewport = viewport.Viewport;

/// Errors returned by `renderInto` / `render`.
pub const RenderError = error{
    /// `buf.len` did not equal `width * height * 4`. Returned (not a silent
    /// out-of-bounds write) so a mis-sized buffer fails loudly and testably.
    /// This is a caller programming error; the pure core stays infra-free and
    /// leaves logging/reporting to the edge (the app wiring), matching the
    /// milestone's "pure fractal core has no SDL/GPU/log infra" testability rule.
    BufferSizeMismatch,
};

/// Result of the timing wrapper: the freshly allocated RGBA8 image plus the
/// wall-clock nanoseconds `renderInto` took. `pixels` is owned by the caller,
/// who must free it with the same allocator passed to `render`.
pub const RenderResult = struct {
    pixels: []u8,
    elapsed_ns: u64,
};

/// Byte length an RGBA8 buffer must have for `vp` (`width * height * 4`).
pub fn bufferLen(vp: Viewport) usize {
    return @as(usize, vp.width) * @as(usize, vp.height) * 4;
}

/// Fill `buf` with the RGBA8 Mandelbrot image for `vp` at `max_iter`. PURE and
/// deterministic: no allocation, no clock, no global state. `buf.len` MUST equal
/// `bufferLen(vp)`; a mismatch returns `RenderError.BufferSizeMismatch` (logged)
/// rather than writing out of bounds. Every pixel is written opaque (alpha 255).
pub fn renderInto(buf: []u8, vp: Viewport, max_iter: u32) RenderError!void {
    const expected = bufferLen(vp);
    if (buf.len != expected) return RenderError.BufferSizeMismatch;

    var y: u32 = 0;
    while (y < vp.height) : (y += 1) {
        var x: u32 = 0;
        while (x < vp.width) : (x += 1) {
            // Sample the pixel CENTER (see the file header on the +0.5 convention).
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const py = @as(f64, @floatFromInt(y)) + 0.5;
            const c = vp.pixelToComplex(px, py);
            const smooth = mandelbrot.iterate(c.re, c.im, max_iter);
            const rgba = color.smoothToRgba(smooth, max_iter);

            const idx = (@as(usize, y) * @as(usize, vp.width) + @as(usize, x)) * 4;
            // Per-pixel bounds guard (habit for M1's tiled writes). `expected ==
            // buf.len` already guarantees this holds for every in-range pixel.
            std.debug.assert(idx + 4 <= buf.len);
            buf[idx + 0] = rgba[0];
            buf[idx + 1] = rgba[1];
            buf[idx + 2] = rgba[2];
            buf[idx + 3] = rgba[3];
        }
    }
}

/// Allocate an RGBA8 buffer for `vp`, render into it, and return it alongside the
/// wall-clock time the render took. Timing is confined to this wrapper so the pure
/// `renderInto` path stays deterministically testable. On error the buffer is
/// freed and the error is propagated. Caller owns `result.pixels`.
pub fn render(alloc: std.mem.Allocator, vp: Viewport, max_iter: u32) !RenderResult {
    const pixels = try alloc.alloc(u8, bufferLen(vp));
    errdefer alloc.free(pixels);

    var timer = try std.time.Timer.start();
    try renderInto(pixels, vp, max_iter);
    const elapsed_ns = timer.read();

    return .{ .pixels = pixels, .elapsed_ns = elapsed_ns };
}

// ─── Tests ───────────────────────────────────────────────────────────────────
//
// The golden view: the fixed M0 viewport at 64x48, max_iter 512. Key-pixel
// assertions are used rather than a full checked-in byte array — a 12 KiB array
// would be unreviewable and brittle, whereas a deep-interior pixel, a slow-escape
// exterior pixel, and full top/bottom symmetry together pin orientation, interior
// color, exterior color, and the mapping/iteration/coloring composition.
const golden_w = 64;
const golden_h = 48;
const golden_iter = 512;

// Pixel coordinates verified against a trusted render of the golden view:
//   * (46, 24) samples c ≈ (0.01, -0.026) — deep inside the main cardioid ⇒ the
//     interior color (opaque black).
//   * (53, 23) samples c ≈ (0.38, 0.026) — just outside the cardioid cusp, a slow
//     escape ⇒ a distinctly non-black grayscale pixel.
const interior_px = .{ .x = 46, .y = 24 };
const exterior_px = .{ .x = 53, .y = 23 };

fn pixelAt(buf: []const u8, w: usize, x: usize, y: usize) color.Rgba8 {
    const i = (y * w + x) * 4;
    return .{ buf[i + 0], buf[i + 1], buf[i + 2], buf[i + 3] };
}

test "renderInto fills the whole buffer with fully opaque pixels" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var buf: [golden_w * golden_h * 4]u8 = undefined;
    try renderInto(&buf, vp, golden_iter);

    var i: usize = 3; // alpha byte of pixel 0
    while (i < buf.len) : (i += 4) {
        try std.testing.expectEqual(@as(u8, 255), buf[i]);
    }
}

test "renderInto rejects a buffer whose length is not width*height*4" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var too_small: [golden_w * golden_h * 4 - 4]u8 = undefined;
    try std.testing.expectError(RenderError.BufferSizeMismatch, renderInto(&too_small, vp, golden_iter));
}

test "renderInto is deterministic: two renders produce byte-identical buffers" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var a: [golden_w * golden_h * 4]u8 = undefined;
    var b: [golden_w * golden_h * 4]u8 = undefined;
    try renderInto(&a, vp, golden_iter);
    try renderInto(&b, vp, golden_iter);
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "golden: a known deep-interior pixel is the interior color" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var buf: [golden_w * golden_h * 4]u8 = undefined;
    try renderInto(&buf, vp, golden_iter);
    try std.testing.expectEqual(
        color.interior_color,
        pixelAt(&buf, golden_w, interior_px.x, interior_px.y),
    );
}

test "golden: a known slow-escape exterior pixel is a non-black grayscale, not the interior color" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var buf: [golden_w * golden_h * 4]u8 = undefined;
    try renderInto(&buf, vp, golden_iter);
    const px = pixelAt(&buf, golden_w, exterior_px.x, exterior_px.y);
    try std.testing.expect(!std.meta.eql(px, color.interior_color));
    try std.testing.expect(px[0] > 0); // not black
    try std.testing.expectEqual(px[0], px[1]); // grayscale
    try std.testing.expectEqual(px[0], px[2]);
    try std.testing.expectEqual(@as(u8, 255), px[3]);
}

test "golden: the fixed centered view is symmetric about the real axis (top/bottom mirror)" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var buf: [golden_w * golden_h * 4]u8 = undefined;
    try renderInto(&buf, vp, golden_iter);

    var y: usize = 0;
    while (y < golden_h) : (y += 1) {
        const mirror = golden_h - 1 - y;
        var x: usize = 0;
        while (x < golden_w) : (x += 1) {
            try std.testing.expectEqual(
                pixelAt(&buf, golden_w, x, y),
                pixelAt(&buf, golden_w, x, mirror),
            );
        }
    }
}

test "render wrapper allocates the buffer and populates a non-zero elapsed_ns" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    const result = try render(std.testing.allocator, vp, golden_iter);
    defer std.testing.allocator.free(result.pixels);
    try std.testing.expectEqual(bufferLen(vp), result.pixels.len);
    try std.testing.expect(result.elapsed_ns > 0);
}

test "render wrapper produces the same bytes as the pure renderInto path" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    const result = try render(std.testing.allocator, vp, golden_iter);
    defer std.testing.allocator.free(result.pixels);

    var expected: [golden_w * golden_h * 4]u8 = undefined;
    try renderInto(&expected, vp, golden_iter);
    try std.testing.expectEqualSlices(u8, &expected, result.pixels);
}
