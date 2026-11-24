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
//!
//! M6 — TWO iteration paths, one geometry. `iterateBandInto` is the DIRECT `f64` path
//! (unchanged, and it must stay that way: it is what every shallow render still uses).
//! `iterateDeepBandInto` is its perturbation sibling for views at or below
//! `perturb.threshold_side`, where neighbouring pixels' `c` values collapse onto the same
//! `f64`. The two differ ONLY in the inner call: the deep path's `pixelOffset` is exactly the
//! offset half of `Viewport.pixelToComplex` (pinned equal by a test), so crossing the depth
//! threshold cannot flip, shift or rescale the image — the shallow path adds that offset to an
//! `f64` centre, the deep path hands it to `perturb.iterateDelta` against an `f128` one.
//! `engine.zig` picks the path (it owns the reference orbit); this module never decides.
const std = @import("std");
const viewport = @import("viewport.zig");
const mandelbrot = @import("mandelbrot.zig");
const perturb = @import("perturb.zig");
const bla = @import("bla.zig");

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

/// Fill `buf` with one smooth Julia value per pixel for `vp`, holding the parameter
/// `c = (c_re, c_im)` FIXED while each pixel's mapped complex coordinate is used as the
/// SEED `z₀` (`mandelbrot.iterateJulia`). This is the buffer-filling twin of `iterateInto`
/// for the Julia inspector: same length contract (`buf.len` MUST equal
/// `iterationBufferLen(vp)`; a mismatch returns `IterError.BufferSizeMismatch` rather than
/// writing out of bounds), same pixel-CENTER sampling, and interior pixels keep the `-1.0`
/// sentinel. Shallow `f64` only — the inspector never deep-zooms.
///
/// PURE and deterministic: no allocation, no clock, no global state.
pub fn iterateJuliaInto(buf: []f32, vp: Viewport, c_re: f64, c_im: f64, max_iter: u32) IterError!void {
    const expected = iterationBufferLen(vp);
    if (buf.len != expected) return IterError.BufferSizeMismatch;

    var y: u32 = 0;
    while (y < vp.height) : (y += 1) {
        var x: u32 = 0;
        while (x < vp.width) : (x += 1) {
            // Sample the pixel CENTER (the +0.5 convention). The mapped coordinate is the
            // SEED z₀; c is the fixed pair — the mirror of the Mandelbrot roles.
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const py = @as(f64, @floatFromInt(y)) + 0.5;
            const z0 = vp.pixelToComplex(px, py);
            const smooth = mandelbrot.iterateJulia(z0.re, z0.im, c_re, c_im, max_iter);

            const idx = @as(usize, y) * @as(usize, vp.width) + @as(usize, x);
            std.debug.assert(idx < buf.len);
            buf[idx] = smooth;
        }
    }
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

    const start = @as(usize, y0) * @as(usize, vp.width);
    const len = @as(usize, rows) * @as(usize, vp.width);
    return iterateBandInto(buf[start..][0..len], vp, max_iter, y0, rows);
}

/// Iterate image rows `y0 .. y0 + rows` of `vp` into a BAND-LOCAL buffer: `band.len` is
/// `rows * width` and row `y0` lands at index 0. This is the same contract the GPU backend
/// implements (`gpu/compute.zig`'s `gpuIterateRows` writes a band-local download), so an
/// `engine.IterFn` can be satisfied by either side without the caller reshuffling indices.
///
/// PURE and deterministic. A `band.len` that is not `rows * width` returns
/// `IterError.BufferSizeMismatch`, and a band running past the last row
/// `IterError.RowRangeOutOfBounds` — rejected, never clamped, so a scheduler bug fails
/// loudly. `rows == 0` is a legal no-op.
pub fn iterateBandInto(band: []f32, vp: Viewport, max_iter: u32, y0: u32, rows: u32) IterError!void {
    if (band.len != @as(usize, rows) * @as(usize, vp.width)) return IterError.BufferSizeMismatch;
    const end = @as(u64, y0) + @as(u64, rows);
    if (end > @as(u64, vp.height)) return IterError.RowRangeOutOfBounds;

    var y: u32 = 0;
    while (y < rows) : (y += 1) {
        var x: u32 = 0;
        while (x < vp.width) : (x += 1) {
            // Sample the pixel CENTER (see the file header on the +0.5 convention). The row is
            // the GLOBAL one (`y0 + y`): the mapping is anchored on the image, not the band.
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const py = @as(f64, @floatFromInt(y0 + y)) + 0.5;
            const c = vp.pixelToComplex(px, py);
            const smooth = mandelbrot.iterate(c.re, c.im, max_iter);

            const idx = @as(usize, y) * @as(usize, vp.width) + @as(usize, x);
            // Per-pixel bounds guard (habit for M1's tiled writes). The length check above
            // already guarantees this holds for every in-range pixel.
            std.debug.assert(idx < band.len);
            band[idx] = smooth;
        }
    }
}

/// The offset of pixel `(x, row)`'s CENTER from the image center, in complex-plane units —
/// i.e. exactly the two terms `Viewport.pixelToComplex` adds to `center_re` / subtracts from
/// `center_im`, lifted out so both iteration paths share ONE definition of the geometry.
///
/// This is the pixel-centre convention, not a re-derivation of it: origin TOP-LEFT, `+0.5`
/// for the center of the pixel, and the imaginary part NEGATED because pixel-y grows DOWN
/// while `im` grows UP. `row` is the GLOBAL image row, so a band is anchored on the image and
/// never on itself. `f64` — and it must stay `f64`: this is the value the deep path spends
/// its precision on, and `f128` here would be ~100× slower for nothing (see `perturb.zig`).
pub fn pixelOffset(vp: Viewport, x: u32, row: u32) struct { re: f64, im: f64 } {
    const w: f64 = @floatFromInt(vp.width);
    const h: f64 = @floatFromInt(vp.height);
    const px = @as(f64, @floatFromInt(x)) + 0.5;
    const py = @as(f64, @floatFromInt(row)) + 0.5;
    return .{
        .re = (px - w / 2.0) * vp.scale,
        .im = -(py - h / 2.0) * vp.scale,
    };
}

/// The DEEP sibling of `iterateBandInto`: same band-local contract, same pixel geometry, but
/// each pixel is iterated as a `δc` OFFSET from `orbit`'s high-precision centre
/// (`perturb.iterateDelta`) instead of from an `f64` absolute `c`. Use it for views at or
/// below `perturb.threshold_side`, where an `f64` `c` can no longer tell neighbouring pixels
/// apart; `engine.zig` makes that choice and owns the one orbit per render.
///
/// `vp` must be the SAME viewport the shallow path would get (`SquareView.rectViewport`), and
/// only its `scale`/`width`/`height` are read: the centre comes from `orbit`, at full
/// precision, which is the entire point. `band.len` is `rows * width` with row `y0` at index
/// 0; a wrong length returns `IterError.BufferSizeMismatch` and a band past the last row
/// `IterError.RowRangeOutOfBounds` — rejected, never clamped. `rows == 0` is a legal no-op.
///
/// PURE, deterministic, and `f64` end to end (no `f128` token may enter this loop — it is
/// software-emulated on arm64 and would cost ~100× for no accuracy the deltas can use).
pub fn iterateDeepBandInto(
    band: []f32,
    vp: Viewport,
    max_iter: u32,
    y0: u32,
    rows: u32,
    orbit: *const perturb.ReferenceOrbit,
) IterError!void {
    // Delegate to the counted variant and discard the tally — the two share one loop, so the
    // plain band and the step-counting band can never drift apart.
    _ = try iterateDeepBandCountedInto(band, vp, max_iter, y0, rows, orbit);
}

/// The step-COUNTING sibling of `iterateDeepBandInto`: fills `band` with the SAME smooth values
/// and RETURNS the total elementary iteration steps the plain deep path spent over the band (the
/// sum of `perturb.iterateDeltaCounted(...).steps`). T3's engine calls this to accumulate the
/// per-render `last_cpu_deep_steps` the acceleration is measured against. Same band-local
/// contract as `iterateDeepBandInto` (`BufferSizeMismatch` / `RowRangeOutOfBounds`, `rows == 0`
/// a legal no-op). PURE, deterministic, `f64` end to end (no `f128`).
pub fn iterateDeepBandCountedInto(
    band: []f32,
    vp: Viewport,
    max_iter: u32,
    y0: u32,
    rows: u32,
    orbit: *const perturb.ReferenceOrbit,
) IterError!u64 {
    if (band.len != @as(usize, rows) * @as(usize, vp.width)) return IterError.BufferSizeMismatch;
    const end = @as(u64, y0) + @as(u64, rows);
    if (end > @as(u64, vp.height)) return IterError.RowRangeOutOfBounds;

    var total: u64 = 0;
    var y: u32 = 0;
    while (y < rows) : (y += 1) {
        var x: u32 = 0;
        while (x < vp.width) : (x += 1) {
            const off = pixelOffset(vp, x, y0 + y);
            const r = perturb.iterateDeltaCounted(orbit.*, off.re, off.im, max_iter);
            total += r.steps;

            const idx = @as(usize, y) * @as(usize, vp.width) + @as(usize, x);
            std.debug.assert(idx < band.len);
            band[idx] = r.value;
        }
    }
    return total;
}

/// The BLA-accelerated sibling of `iterateDeepBandInto`: identical band-local contract and pixel
/// geometry, but each pixel is iterated by `bla.iterateDeltaBla` against the caller-built `table`
/// instead of `perturb.iterateDelta`. The engine (T3) builds one table per render and passes it
/// here. PURE, deterministic, `f64` end to end.
pub fn iterateDeepBandBlaInto(
    band: []f32,
    vp: Viewport,
    max_iter: u32,
    y0: u32,
    rows: u32,
    orbit: *const perturb.ReferenceOrbit,
    table: *const bla.BlaTable,
) IterError!void {
    _ = try iterateDeepBandBlaCountedInto(band, vp, max_iter, y0, rows, orbit, table);
}

/// The step-COUNTING sibling of `iterateDeepBandBlaInto`: fills `band` with the accelerated smooth
/// values and RETURNS the total elementary steps the BLA path spent (sum of
/// `bla.iterateDeltaBlaCounted(...).steps`, each taken skip counting as one). Directly comparable
/// to `iterateDeepBandCountedInto`'s total, so T3 can weigh the two per-render tallies. Same
/// band-local contract; PURE, deterministic, `f64` end to end.
pub fn iterateDeepBandBlaCountedInto(
    band: []f32,
    vp: Viewport,
    max_iter: u32,
    y0: u32,
    rows: u32,
    orbit: *const perturb.ReferenceOrbit,
    table: *const bla.BlaTable,
) IterError!u64 {
    if (band.len != @as(usize, rows) * @as(usize, vp.width)) return IterError.BufferSizeMismatch;
    const end = @as(u64, y0) + @as(u64, rows);
    if (end > @as(u64, vp.height)) return IterError.RowRangeOutOfBounds;

    var total: u64 = 0;
    var y: u32 = 0;
    while (y < rows) : (y += 1) {
        var x: u32 = 0;
        while (x < vp.width) : (x += 1) {
            const off = pixelOffset(vp, x, y0 + y);
            const r = bla.iterateDeltaBlaCounted(orbit, table, off.re, off.im, max_iter);
            total += r.steps;

            const idx = @as(usize, y) * @as(usize, vp.width) + @as(usize, x);
            std.debug.assert(idx < band.len);
            band[idx] = r.value;
        }
    }
    return total;
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

test "iterateJuliaInto rejects a buffer whose length is not width*height" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var too_small: [golden_w * golden_h - 1]f32 = undefined;
    try std.testing.expectError(
        IterError.BufferSizeMismatch,
        iterateJuliaInto(&too_small, vp, 0.0, 0.0, golden_iter),
    );
}

test "iterateJuliaInto for c=0 fills interior at the centre and escaped pixels at the corners" {
    // c = 0 ⇒ the filled Julia set is the closed unit disk. A view centred on the origin with
    // side 4 (real/imag span [-2, 2]) puts the origin at the centre pixel (interior) and the
    // image corners near |z₀| ≈ 2.6 (escaped) — the Julia analogue of the unit-disk fact.
    const jw = 16;
    const jh = 16;
    const view = try viewport.SquareView.fromCenterSide(.{ .re = 0.0, .im = 0.0 }, 4.0);
    const vp = view.rectViewport(jw, jh);
    var buf: [jw * jh]f32 = undefined;
    try iterateJuliaInto(&buf, vp, 0.0, 0.0, golden_iter);

    // Centre pixel: seed near the origin ⇒ interior sentinel.
    try std.testing.expectEqual(mandelbrot.interior_sentinel, valueAt(&buf, jw, jw / 2, jh / 2));

    // All four corners: seed well outside the unit circle ⇒ a finite, escaped smooth value.
    const corners = [_][2]usize{ .{ 0, 0 }, .{ jw - 1, 0 }, .{ 0, jh - 1 }, .{ jw - 1, jh - 1 } };
    for (corners) |cxy| {
        const v = valueAt(&buf, jw, cxy[0], cxy[1]);
        try std.testing.expect(v != mandelbrot.interior_sentinel);
        try std.testing.expect(std.math.isFinite(v));
    }
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

test "iterateBandInto fills a band-local buffer with the SAME values as the full-buffer band" {
    // The GPU backend downloads band-local (`gpu/compute.zig`), the CPU pass writes into the
    // full buffer; both go through this function, so the two must be scalar-identical.
    const vp = Viewport.fixedView(golden_w, golden_h);
    const y0: u32 = 9;
    const rows: u32 = 4;

    var whole: [golden_w * golden_h]f32 = undefined;
    try iterateRowsInto(&whole, vp, golden_iter, y0, rows);

    var band: [golden_w * 4]f32 = undefined;
    try iterateBandInto(&band, vp, golden_iter, y0, rows);

    try std.testing.expectEqualSlices(f32, whole[y0 * golden_w ..][0 .. rows * golden_w], &band);
}

test "iterateBandInto rejects a band buffer that is not rows*width" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var band: [golden_w * 2 + 1]f32 = undefined;
    try std.testing.expectError(
        IterError.BufferSizeMismatch,
        iterateBandInto(&band, vp, golden_iter, 0, 2),
    );
}

test "iterateBandInto rejects a band that runs past the last row" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var band: [golden_w * 3]f32 = undefined;
    try std.testing.expectError(
        IterError.RowRangeOutOfBounds,
        iterateBandInto(&band, vp, golden_iter, golden_h - 2, 3),
    );
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

// ─── M6: the DEEP band path ──────────────────────────────────────────────────
//
// The deep view every test here renders: the milestone's reference centre (the seahorse-valley
// boundary point, deliberately NOT on the real axis, so a vertically flipped image is a gross
// mismatch rather than a symmetry that hides the flip).
const deep_center = viewport.ComplexHi{
    .re = -0.743643887037158704752191506114774,
    .im = 0.131825904205311970493132056385139,
};

const deep_w = 16;
const deep_h = 16;
const deep_iter = 4096;

/// A `deep_w × deep_h` view of `side` at the reference centre, plus its reference orbit.
/// Caller owns the orbit: `defer orbit.deinit(std.testing.allocator)`.
fn deepFixture(side: f64, max_iter: u32) !struct { vp: Viewport, orbit: perturb.ReferenceOrbit } {
    const view = try viewport.SquareView.fromCenterSide(deep_center, side);
    return .{
        .vp = view.rectViewport(deep_w, deep_h),
        .orbit = try perturb.ReferenceOrbit.compute(std.testing.allocator, view.center(), max_iter),
    };
}

test "pixelOffset is exactly the offset half of Viewport.pixelToComplex (centre, +0.5, y down)" {
    // The load-bearing claim: the deep path samples the SAME points as the shallow one. A
    // half-pixel shift, a flipped `im`, or a scale taken from the wrong axis all fail here,
    // and they fail BIT-exactly — `center + offset` is the very expression `pixelToComplex`
    // evaluates, so nothing weaker than equality is honest.
    const vp = viewport.SquareView.defaultView().rectViewport(golden_w, golden_h);
    var row: u32 = 0;
    while (row < golden_h) : (row += 1) {
        var x: u32 = 0;
        while (x < golden_w) : (x += 1) {
            const off = pixelOffset(vp, x, row);
            const c = vp.pixelToComplex(
                @as(f64, @floatFromInt(x)) + 0.5,
                @as(f64, @floatFromInt(row)) + 0.5,
            );
            // Both offsets are ADDED to the centre — `off.im` already carries the negation
            // (`dc_im = (h/2 − row − 0.5)·scale`), which is what `perturb.iterateDelta` wants,
            // since it evaluates `c = C + δc`.
            try std.testing.expectEqual(c.re, vp.center_re + off.re);
            try std.testing.expectEqual(c.im, vp.center_im + off.im);
        }
    }
}

test "iterateDeepBandInto in bands reproduces the whole-image deep pass exactly" {
    // The contract the progressive renderer rests on, now for the deep path: chunking is
    // invisible, and one shared orbit serves every band.
    var f = try deepFixture(1.0e-9, deep_iter);
    defer f.orbit.deinit(std.testing.allocator);

    var whole: [deep_w * deep_h]f32 = undefined;
    try iterateDeepBandInto(&whole, f.vp, deep_iter, 0, deep_h, &f.orbit);

    var banded: [deep_w * deep_h]f32 = undefined;
    var y0: u32 = 0;
    const band: u32 = 7; // does not divide 16 evenly — the last band is short
    while (y0 < deep_h) : (y0 += band) {
        const rows: u32 = @min(band, deep_h - y0);
        const start = @as(usize, y0) * deep_w;
        try iterateDeepBandInto(banded[start..][0 .. rows * deep_w], f.vp, deep_iter, y0, rows, &f.orbit);
    }
    try std.testing.expectEqualSlices(f32, &whole, &banded);
}

test "iterateDeepBandInto rejects a band that runs past the last row" {
    var f = try deepFixture(1.0e-9, 64);
    defer f.orbit.deinit(std.testing.allocator);
    var band: [deep_w * 3]f32 = undefined;
    try std.testing.expectError(
        IterError.RowRangeOutOfBounds,
        iterateDeepBandInto(&band, f.vp, 64, deep_h - 2, 3, &f.orbit),
    );
}

test "iterateDeepBandInto rejects a band buffer that is not rows*width" {
    var f = try deepFixture(1.0e-9, 64);
    defer f.orbit.deinit(std.testing.allocator);
    var band: [deep_w * 2 + 1]f32 = undefined;
    try std.testing.expectError(
        IterError.BufferSizeMismatch,
        iterateDeepBandInto(&band, f.vp, 64, 0, 2, &f.orbit),
    );
}

test "iterateDeepBandInto with zero rows is a no-op" {
    var f = try deepFixture(1.0e-9, 64);
    defer f.orbit.deinit(std.testing.allocator);
    var band: [0]f32 = undefined;
    try iterateDeepBandInto(&band, f.vp, 64, 5, 0, &f.orbit);
}

test "at the switch threshold the deep band agrees with the shallow band on classification" {
    // Crossing `perturb.threshold_side` must preserve STRUCTURE: every pixel lands on the same
    // side of "escapes at all", so the shape on screen is the same shape. Smooth values are a
    // different matter and deliberately not asserted equal here — the shallow path is off by up
    // to ~85 iterations at 1e-6 (see the two tests below), so some near-boundary pixels DO
    // change colour when the threshold is crossed. That is an accepted consequence of the
    // agreed 1e-6 switch, with the deep side being the correct one; it is not blended away.
    var f = try deepFixture(perturb.threshold_side, deep_iter);
    defer f.orbit.deinit(std.testing.allocator);

    var deep: [deep_w * deep_h]f32 = undefined;
    try iterateDeepBandInto(&deep, f.vp, deep_iter, 0, deep_h, &f.orbit);
    var shallow: [deep_w * deep_h]f32 = undefined;
    try iterateBandInto(&shallow, f.vp, deep_iter, 0, deep_h);

    for (deep, shallow) |d, s| {
        try std.testing.expectEqual(
            s == mandelbrot.interior_sentinel,
            d == mandelbrot.interior_sentinel,
        );
    }
}

/// Full-precision ground truth for pixel `(x, row)` of a deep fixture: the SAME `f64` pixel
/// offset the render uses, added onto the `f128` centre and iterated in `f128`
/// (`mandelbrot.iterateExact`) — the comparison the milestone's `Perturbation accuracy`
/// requirement and AT3 are worded against. Never a renderer path; test-only, and slow.
fn exactAt(vp: Viewport, x: u32, row: u32) f32 {
    const off = pixelOffset(vp, x, row);
    return mandelbrot.iterateExact(
        deep_center.re + @as(f128, off.re),
        deep_center.im + @as(f128, off.im),
        deep_iter,
    );
}

test "at the switch threshold every pixel of the deep band is within 1.0 iteration of full precision" {
    // The accuracy half of the contract, and the ONE comparison it is worded against: the spec's
    // scenario `Accuracy where the shallow and deep paths meet` requires "within 1.0 iteration of
    // the same pixel computed by full-precision direct iteration", and AT3 measures exactly that.
    // Not against the shallow render — the SHALLOW path is the inaccurate one here, as the next
    // test pins. Interior pixels have no smooth value to compare; the sibling test above covers
    // their classification.
    //
    // Not a duplicate of `perturb.zig`'s grid test: that one drives `iterateDelta` with
    // hand-written offsets, this one drives the whole BAND — so it is the band's geometry
    // (`pixelOffset`, the `+0.5`, the negated `im`, the shared `scale`) that is being measured
    // against ground truth. Know what this canNOT catch: `exactAt` maps its pixel through the
    // SAME `pixelOffset`, so a CONSISTENT geometry error — a half-pixel shift, a vertical flip —
    // cancels on both sides and leaves this test green. The bit-exact geometry pin is
    // `pixelOffset is exactly the offset half of Viewport.pixelToComplex` above; keep it.
    // The measured worst case here on correct code is 0.0117, ~85× inside the bound.
    var f = try deepFixture(perturb.threshold_side, deep_iter);
    defer f.orbit.deinit(std.testing.allocator);

    var deep: [deep_w * deep_h]f32 = undefined;
    try iterateDeepBandInto(&deep, f.vp, deep_iter, 0, deep_h, &f.orbit);

    var compared: u32 = 0;
    var row: u32 = 0;
    while (row < deep_h) : (row += 1) {
        var x: u32 = 0;
        while (x < deep_w) : (x += 1) {
            const want = exactAt(f.vp, x, row);
            if (want == mandelbrot.interior_sentinel) continue;
            try std.testing.expectApproxEqAbs(want, deep[row * deep_w + x], 1.0);
            compared += 1;
        }
    }
    try std.testing.expect(compared > 0);
}

test "at the switch threshold it is the SHALLOW path that drifts from full precision, not the deep one" {
    // Why the test above compares against `iterateExact` rather than against the shallow
    // render: at 1e-6 the direct `f64` path is already off by ~85 iterations on a
    // hypersensitive near-boundary pixel (the figure `acceptance-tests.md` records for it),
    // while the deep path is off by 0.01. "Deep agrees with shallow within 1.0" is therefore
    // not satisfiable at the threshold, and would demand the deep path REPRODUCE that error.
    // Pinned here so nobody re-derives the wrong comparison from the switch's symmetry.
    var f = try deepFixture(perturb.threshold_side, deep_iter);
    defer f.orbit.deinit(std.testing.allocator);

    // The offending pixel, found by scanning the 16×16 image: col 2, row 4.
    const x: u32 = 2;
    const row: u32 = 4;
    const want = exactAt(f.vp, x, row);
    try std.testing.expect(want != mandelbrot.interior_sentinel);

    var deep: [deep_w]f32 = undefined;
    try iterateDeepBandInto(&deep, f.vp, deep_iter, row, 1, &f.orbit);
    var shallow: [deep_w * deep_h]f32 = undefined;
    try iterateBandInto(&shallow, f.vp, deep_iter, 0, deep_h);

    try std.testing.expectApproxEqAbs(want, deep[x], 1.0); // deep: measured 0.0117 off
    try std.testing.expect(@abs(want - shallow[row * deep_w + x]) > 1.0); // shallow: 85.5 off
}

test "iterateDeepBandInto resolves distinct values at side 1e-30, where the shallow path cannot" {
    // The whole point of the path, at module level: at 1e-30 every pixel's `f64` `c` is the
    // SAME number, so the shallow path returns one constant value; the deep path still sees
    // structure. (65536 iterations is what this depth needs — T5 raises the auto ramp to it.)
    const max_iter: u32 = 65536;
    var f = try deepFixture(1.0e-30, max_iter);
    defer f.orbit.deinit(std.testing.allocator);

    var deep: [deep_w * deep_h]f32 = undefined;
    try iterateDeepBandInto(&deep, f.vp, max_iter, 0, deep_h, &f.orbit);
    var shallow: [deep_w * deep_h]f32 = undefined;
    try iterateBandInto(&shallow, f.vp, max_iter, 0, deep_h);

    var deep_distinct = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer deep_distinct.deinit();
    var shallow_distinct = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer shallow_distinct.deinit();
    for (deep) |v| try deep_distinct.put(@bitCast(v), {});
    for (shallow) |v| try shallow_distinct.put(@bitCast(v), {});

    try std.testing.expectEqual(@as(u32, 1), shallow_distinct.count());
    try std.testing.expect(deep_distinct.count() >= 224); // 256 pixels; AT1's ratio (56/64)
}

test "iterateDeepBandCountedInto returns the sum of its pixels' steps" {
    const max_iter: u32 = 4096;
    var f = try deepFixture(1.0e-15, max_iter);
    defer f.orbit.deinit(std.testing.allocator);

    const y0 = 2;
    var band: [deep_w * 2]f32 = undefined;
    var expected: u64 = 0;
    for (0..band.len) |i| {
        const off = pixelOffset(f.vp, @intCast(i % deep_w), @intCast(y0 + i / deep_w));
        expected += perturb.iterateDeltaCounted(f.orbit, off.re, off.im, max_iter).steps;
    }
    try std.testing.expectEqual(expected, try iterateDeepBandCountedInto(&band, f.vp, max_iter, y0, 2, &f.orbit));
}

test "iterateDeepBandBlaInto draws the same band as the plain deep band, in fewer steps" {
    // The band-level equivalence T3 renders through: same classification and smooth value within
    // one iteration for every pixel, at a materially smaller elementary-step total. A genuinely
    // deep grid (side 1e-25, 65536) whose pixels escape, where BLA has long runs to skip.
    const max_iter: u32 = 65536;
    var f = try deepFixture(1.0e-25, max_iter);
    defer f.orbit.deinit(std.testing.allocator);
    const max_dc = f.vp.scale * @as(f64, @floatFromInt(@max(deep_w, deep_h))) * std.math.sqrt2 / 2.0;
    var table = try bla.BlaTable.build(std.testing.allocator, &f.orbit, max_dc);
    defer table.deinit(std.testing.allocator);

    var plain: [deep_w * deep_h]f32 = undefined;
    const plain_steps = try iterateDeepBandCountedInto(&plain, f.vp, max_iter, 0, deep_h, &f.orbit);
    var accel: [deep_w * deep_h]f32 = undefined;
    const bla_steps = try iterateDeepBandBlaCountedInto(&accel, f.vp, max_iter, 0, deep_h, &f.orbit, &table);

    var compared: u32 = 0;
    for (plain, accel) |p, b| {
        const p_int = p == mandelbrot.interior_sentinel;
        const b_int = b == mandelbrot.interior_sentinel;
        try std.testing.expectEqual(p_int, b_int);
        if (!p_int) {
            try std.testing.expectApproxEqAbs(p, b, 1.0);
            compared += 1;
        }
    }
    try std.testing.expect(compared > 0);
    try std.testing.expect(bla_steps > 0);
    try std.testing.expect(bla_steps < plain_steps);
}

test "iterateDeepBandBlaInto and its plain sibling reject a mis-sized band and an out-of-range row" {
    // The band-local contract holds for the accelerated bands too: a wrong length and a row past
    // the last are rejected, never clamped.
    const max_iter: u32 = 256;
    var f = try deepFixture(1.0e-15, max_iter);
    defer f.orbit.deinit(std.testing.allocator);
    var table = try bla.BlaTable.build(std.testing.allocator, &f.orbit, 1.0e-15);
    defer table.deinit(std.testing.allocator);

    var wrong: [deep_w * 2 + 1]f32 = undefined;
    try std.testing.expectError(
        IterError.BufferSizeMismatch,
        iterateDeepBandBlaInto(&wrong, f.vp, max_iter, 0, 2, &f.orbit, &table),
    );
    var band: [deep_w * 3]f32 = undefined;
    try std.testing.expectError(
        IterError.RowRangeOutOfBounds,
        iterateDeepBandBlaCountedInto(&band, f.vp, max_iter, deep_h - 2, 3, &f.orbit, &table),
    );
}
