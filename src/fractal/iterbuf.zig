//! Pure Mandelbrot ITERATION stage → a persistent `[]f32` smooth-value buffer.
//! NO SDL/GPU/log imports — this lives in the fast test tier (`zig build test`,
//! no window/device) and is fully unit-tested. No global state, deterministic.
//!
//! M2 decoupling (the whole point): the expensive iteration runs ONCE into this
//! buffer of smooth values; the cheap color pass (T4) reruns on palette/mapping
//! changes without ever re-iterating. So this module deliberately stops at the
//! smooth value — it does NO coloring. One f32 per pixel; the CPU analogue of the
//! spec's `R32Float` iteration texture.
//!
//! Split of concerns (mirrors M0's render.zig — do not merge):
//!   * `iterateInto` is the PURE, deterministic path: same inputs ⇒ scalar-identical
//!     buffer, no clock, no allocation. This is what the golden test pins.
//!   * `iterate` is the timing/allocation wrapper for the app: it allocates the
//!     buffer and measures wall-clock elapsed with `std.time.Timer`. Timing lives
//!     ONLY here so nothing on the pure path is exposed to wall-clock flakiness.
//!
//! Pixel sampling: each integer pixel `(x, y)` is sampled at its CENTER
//! `(x + 0.5, y + 0.5)` (the `+0.5` convention documented in `viewport.zig`), so
//! the fixed centered view is exactly symmetric about the real axis: because the
//! Mandelbrot set is symmetric under conjugation and `center_im == 0`, pixel row
//! `y` and row `height-1-y` sample conjugate `c` values and produce scalar-identical
//! smooth values. That top/bottom mirror is the strongest cheap correctness signal.
//!
//! Interior points keep `mandelbrot.interior_sentinel` (`-1.0`) verbatim; the color
//! pass gives them their dedicated interior color outside the LUT (plan A5).
const std = @import("std");
const viewport = @import("viewport.zig");
const mandelbrot = @import("mandelbrot.zig");

const Viewport = viewport.Viewport;

/// Errors returned by `iterateInto` / `iterate`.
pub const IterError = error{
    /// `buf.len` did not equal `iterationBufferLen(vp)`. Returned (not a silent
    /// out-of-bounds write) so a mis-sized buffer fails loudly and testably. This
    /// is a caller programming error; the pure core stays infra-free and leaves
    /// logging/reporting to the edge (the engine/app wiring), matching the
    /// milestone's "pure fractal core has no SDL/GPU/log infra" testability rule.
    BufferSizeMismatch,
    /// `iterateRowsInto` was asked for a band (`y0 + rows`) that runs past the image's
    /// last row. Returned rather than clamped so a scheduler that loses track of its
    /// row cursor fails loudly instead of silently re-iterating the bottom row.
    RowRangeOutOfBounds,
};

/// Result of the timing wrapper: the freshly allocated smooth-value buffer plus the
/// wall-clock nanoseconds `iterateInto` took. `values` is owned by the caller, who
/// must free it with the same allocator passed to `iterate`.
pub const IterationResult = struct {
    values: []f32,
    elapsed_ns: u64,
};

/// Number of f32 smooth values a buffer must hold for `vp` (`width * height`).
pub fn iterationBufferLen(vp: Viewport) usize {
    return @as(usize, vp.width) * @as(usize, vp.height);
}

/// Fill `buf` with one smooth iteration value per pixel for `vp` at `max_iter`.
/// PURE and deterministic: no allocation, no clock, no global state. `buf.len` MUST
/// equal `iterationBufferLen(vp)`; a mismatch returns `IterError.BufferSizeMismatch`
/// rather than writing out of bounds. Interior pixels keep the `-1.0` sentinel.
///
/// Delegates to `iterateRowsInto` for every row, so the whole-image path and the
/// row-band path used by the progressive renderer share ONE per-pixel implementation
/// (and therefore produce scalar-identical values — pinned by a test below).
pub fn iterateInto(buf: []f32, vp: Viewport, max_iter: u32) IterError!void {
    return iterateRowsInto(buf, vp, max_iter, 0, vp.height);
}

/// Iterate ONLY image rows `y0 .. y0 + rows` of `vp` into `buf`, leaving every other row
/// untouched. `buf` is the FULL `width * height` buffer (not the band), so a band write
/// lands at the same indices the whole-image pass would use — that is what lets M5's
/// progressive renderer fill an image in per-frame chunks while the rest of the buffer
/// still shows the upsampled preview (`progressive.upsampleInto`).
///
/// PURE and deterministic. `buf.len` MUST equal `iterationBufferLen(vp)`; a band that
/// would run past the last row is rejected with `IterError.RowRangeOutOfBounds` rather
/// than clamped, so a scheduler bug fails loudly and testably. `rows == 0` is a legal
/// no-op (the scheduler can call it on a finished pass).
pub fn iterateRowsInto(buf: []f32, vp: Viewport, max_iter: u32, y0: u32, rows: u32) IterError!void {
    const expected = iterationBufferLen(vp);
    if (buf.len != expected) return IterError.BufferSizeMismatch;
    const end = @as(u64, y0) + @as(u64, rows);
    if (end > @as(u64, vp.height)) return IterError.RowRangeOutOfBounds;

    var y: u32 = y0;
    while (y < y0 + rows) : (y += 1) {
        var x: u32 = 0;
        while (x < vp.width) : (x += 1) {
            // Sample the pixel CENTER (see the file header on the +0.5 convention).
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const py = @as(f64, @floatFromInt(y)) + 0.5;
            const c = vp.pixelToComplex(px, py);
            const smooth = mandelbrot.iterate(c.re, c.im, max_iter);

            const idx = @as(usize, y) * @as(usize, vp.width) + @as(usize, x);
            // Per-pixel bounds guard (habit for M1's tiled writes). `expected ==
            // buf.len` already guarantees this holds for every in-range pixel.
            std.debug.assert(idx < buf.len);
            buf[idx] = smooth;
        }
    }
}

/// Allocate an f32 smooth-value buffer for `vp`, iterate into it, and return it
/// alongside the wall-clock time the iteration took. Timing is confined to this
/// wrapper so the pure `iterateInto` path stays deterministically testable. On error
/// the buffer is freed and the error is propagated. Caller owns `result.values`.
pub fn iterate(alloc: std.mem.Allocator, vp: Viewport, max_iter: u32) !IterationResult {
    const values = try alloc.alloc(f32, iterationBufferLen(vp));
    errdefer alloc.free(values);

    var timer = try std.time.Timer.start();
    try iterateInto(values, vp, max_iter);
    const elapsed_ns = timer.read();

    return .{ .values = values, .elapsed_ns = elapsed_ns };
}

// ─── Tests ───────────────────────────────────────────────────────────────────
//
// The golden view: the fixed M0 viewport at 64x48, max_iter 512. Key-pixel
// assertions are used rather than a checked-in scalar array — a 3072-element array
// would be unreviewable and brittle, whereas a deep-interior pixel, a slow-escape
// exterior pixel, and full top/bottom symmetry together pin orientation, interior
// sentinel, escaped values, and the mapping/iteration composition.
//
// RGBA/grayscale golden assertions from M0's render.zig are DELIBERATELY absent:
// coloring moved to the T4 color pass. This module stops at the smooth value.
const golden_w = 64;
const golden_h = 48;
const golden_iter = 512;

// Pixel coordinates verified against a trusted render of the golden view:
//   * (46, 24) samples c ≈ (0.01, -0.026) — deep inside the main cardioid ⇒ the
//     interior sentinel.
//   * (53, 23) samples c ≈ (0.38, 0.026) — just outside the cardioid cusp, a slow
//     escape ⇒ a finite, non-sentinel smooth value.
const interior_px = .{ .x = 46, .y = 24 };
const exterior_px = .{ .x = 53, .y = 23 };

fn valueAt(buf: []const f32, w: usize, x: usize, y: usize) f32 {
    return buf[y * w + x];
}

test "iterationBufferLen is one f32 per pixel (width*height)" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    try std.testing.expectEqual(@as(usize, golden_w * golden_h), iterationBufferLen(vp));
}

test "iterateInto marks a known deep-interior pixel with the exact -1.0 sentinel" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var buf: [golden_w * golden_h]f32 = undefined;
    try iterateInto(&buf, vp, golden_iter);
    try std.testing.expectEqual(
        mandelbrot.interior_sentinel,
        valueAt(&buf, golden_w, interior_px.x, interior_px.y),
    );
}

test "iterateInto marks a known slow-escape exterior pixel with a finite non-sentinel value" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var buf: [golden_w * golden_h]f32 = undefined;
    try iterateInto(&buf, vp, golden_iter);
    const v = valueAt(&buf, golden_w, exterior_px.x, exterior_px.y);
    try std.testing.expect(std.math.isFinite(v));
    try std.testing.expect(v != mandelbrot.interior_sentinel);
}

test "iterateInto: every pixel is either the interior sentinel or a finite escaped value" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var buf: [golden_w * golden_h]f32 = undefined;
    try iterateInto(&buf, vp, golden_iter);
    for (buf) |v| {
        const ok = (v == mandelbrot.interior_sentinel) or
            (std.math.isFinite(v) and v != mandelbrot.interior_sentinel);
        try std.testing.expect(ok);
    }
}

test "iterateInto rejects a buffer whose length is not width*height" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var too_small: [golden_w * golden_h - 1]f32 = undefined;
    try std.testing.expectError(IterError.BufferSizeMismatch, iterateInto(&too_small, vp, golden_iter));
}

test "iterateInto is deterministic: two runs produce scalar-identical buffers" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var a: [golden_w * golden_h]f32 = undefined;
    var b: [golden_w * golden_h]f32 = undefined;
    try iterateInto(&a, vp, golden_iter);
    try iterateInto(&b, vp, golden_iter);
    try std.testing.expectEqualSlices(f32, &a, &b);
}

test "iterateInto: the fixed centered view is symmetric about the real axis (top/bottom mirror)" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var buf: [golden_w * golden_h]f32 = undefined;
    try iterateInto(&buf, vp, golden_iter);

    var y: usize = 0;
    while (y < golden_h) : (y += 1) {
        const mirror = golden_h - 1 - y;
        var x: usize = 0;
        while (x < golden_w) : (x += 1) {
            try std.testing.expectEqual(
                valueAt(&buf, golden_w, x, y),
                valueAt(&buf, golden_w, x, mirror),
            );
        }
    }
}

test "iterateRowsInto writes exactly the requested band and leaves the rest untouched" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var buf: [golden_w * golden_h]f32 = undefined;
    const sentinel: f32 = 12345.0;
    @memset(&buf, sentinel);
    try iterateRowsInto(&buf, vp, golden_iter, 10, 3);

    // Rows 10..12 are filled (no longer the sentinel); every other row still is.
    var y: usize = 0;
    while (y < golden_h) : (y += 1) {
        const in_band = (y >= 10 and y < 13);
        var x: usize = 0;
        while (x < golden_w) : (x += 1) {
            const touched = valueAt(&buf, golden_w, x, y) != sentinel;
            try std.testing.expectEqual(in_band, touched);
        }
    }
}

test "iterateRowsInto in bands reproduces the whole-image pass exactly" {
    // The guarantee the progressive renderer rests on: chunking changes nothing.
    const vp = Viewport.fixedView(golden_w, golden_h);
    var whole: [golden_w * golden_h]f32 = undefined;
    try iterateInto(&whole, vp, golden_iter);

    var banded: [golden_w * golden_h]f32 = undefined;
    var y0: u32 = 0;
    const band: u32 = 7; // does not divide golden_h evenly — the last band is short
    while (y0 < golden_h) : (y0 += band) {
        try iterateRowsInto(&banded, vp, golden_iter, y0, @min(band, golden_h - y0));
    }
    try std.testing.expectEqualSlices(f32, &whole, &banded);
}

test "iterateRowsInto rejects a band that runs past the last row" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var buf: [golden_w * golden_h]f32 = undefined;
    try std.testing.expectError(
        IterError.RowRangeOutOfBounds,
        iterateRowsInto(&buf, vp, golden_iter, golden_h - 2, 3),
    );
}

test "iterateRowsInto with zero rows is a no-op" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var buf: [golden_w * golden_h]f32 = undefined;
    @memset(&buf, 0.0);
    try iterateRowsInto(&buf, vp, golden_iter, 5, 0);
    try std.testing.expectEqual(@as(f32, 0.0), valueAt(&buf, golden_w, 0, 5));
}

test "iterate wrapper allocates the buffer and populates a non-zero elapsed_ns" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    const result = try iterate(std.testing.allocator, vp, golden_iter);
    defer std.testing.allocator.free(result.values);
    try std.testing.expectEqual(iterationBufferLen(vp), result.values.len);
    try std.testing.expect(result.elapsed_ns > 0);
}

test "iterate wrapper produces the same values as the pure iterateInto path" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    const result = try iterate(std.testing.allocator, vp, golden_iter);
    defer std.testing.allocator.free(result.values);

    var expected: [golden_w * golden_h]f32 = undefined;
    try iterateInto(&expected, vp, golden_iter);
    try std.testing.expectEqualSlices(f32, &expected, result.values);
}
