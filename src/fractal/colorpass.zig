//! Pure COLOR pass: persistent smooth-value buffer + baked LUT + mapping → RGBA8.
//! NO SDL/GPU/log imports — this lives in the fast test tier (`zig build test`, no
//! window/device) and is fully unit-tested. No allocation (writes into the caller's
//! buffer), no global state, deterministic.
//!
//! This is the CHEAP half of M2's decoupled pipeline. The expensive iteration runs
//! ONCE into a persistent `[]f32` smooth-value buffer (`iterbuf`, T1); this pass then
//! reruns on every palette/mapping change (T5/T6) WITHOUT ever re-iterating: it just
//! maps each smooth value to a LUT index (`mapping.mapToUnit`, T3) and copies the
//! baked texel (`gradient.bakeLut`, T2). It composes those three modules and adds no
//! new coloring math of its own.
//!
//! Per-pixel contract (`colorInto`):
//!   * Interior sentinel (`mandelbrot.interior_sentinel` == `-1.0`) → the caller's
//!     `interior` color (plan A5: interior is separately editable, outside the LUT).
//!   * Otherwise `t = mapping.mapToUnit(smooth, max_iter, params)` (already clamped to
//!     `[0,1]`), then `idx = @intFromFloat(t * (lut_size - 1))` CLAMPED to
//!     `0..lut_size-1`, and the texel is `lut[idx]`. The clamp guarantees `t == 1.0`
//!     indexes the last texel and nothing ever reads the LUT out of bounds.
//!   * Alpha is FORCED to `255` on every written pixel (both branches). The color pass
//!     always emits an OPAQUE image — the final framebuffer is not composited, so the
//!     interior/LUT alpha channels are not propagated (matches M0's `color.zig`, which
//!     also always wrote `255`). Callers author opaque interior/stops by default, so
//!     this is observably identical for the default palette.
//!
//! Buffer-size guard: `rgba.len` MUST equal `iter.len * 4`; a mismatch returns
//! `ColorError.BufferSizeMismatch` (no logging — the pure core leaves reporting to the
//! edge, exactly like `iterbuf.IterError`) rather than writing out of bounds.
//!
//! NOTE (decided, see result doc): the task spec's illustrative signature omitted
//! `max_iter`, but `mapping.mapToUnit` requires it, so it is a parameter here, grouped
//! with `params` just as in `mapToUnit(smooth, max_iter, params)`. The T5 engine holds
//! `max_iter` (it drove the iteration) and passes it through.
const std = @import("std");
const color = @import("color.zig");
const gradient = @import("gradient.zig");
const mapping = @import("mapping.zig");
const mandelbrot = @import("mandelbrot.zig");

/// Reused verbatim from `color.zig` (M0). Channel order R, G, B, A. Do not redefine.
pub const Rgba8 = color.Rgba8;

/// Errors returned by `colorInto`.
pub const ColorError = error{
    /// `rgba.len` did not equal `iter.len * 4`. Returned (not a silent out-of-bounds
    /// write) so a mis-sized output buffer fails loudly and testably. This is a caller
    /// programming error; the pure core stays infra-free and leaves logging/reporting
    /// to the edge (the T5 engine / app wiring), matching the milestone's "pure fractal
    /// core has no SDL/GPU/log infra" rule (mirrors `iterbuf.IterError`).
    BufferSizeMismatch,
};

/// Color a persistent smooth-value buffer into a packed RGBA8 image.
///
/// `iter` is one f32 smooth value per pixel (from `iterbuf.iterateInto`). `rgba` is the
/// caller-owned output, 4 bytes per pixel; `rgba.len` MUST equal `iter.len * 4` or
/// `ColorError.BufferSizeMismatch` is returned before any write. `lut` is a baked
/// palette (`gradient.bakeLut`); `params` selects the mapping (`mapping.Params`);
/// `interior` is the dedicated interior color (plan A5). See the file header for the
/// full per-pixel contract. Pure and deterministic: no allocation, no clock, no I/O.
pub fn colorInto(
    rgba: []u8,
    iter: []const f32,
    lut: *const [gradient.lut_size]Rgba8,
    max_iter: u32,
    params: mapping.Params,
    interior: Rgba8,
) ColorError!void {
    if (rgba.len != iter.len * 4) return ColorError.BufferSizeMismatch;

    // `t` in [0,1] scales onto texel indices 0..lut_size-1; keep the max as an f32 and
    // as a usize so the float multiply and the final index clamp share one constant.
    const lut_index_max: usize = gradient.lut_size - 1;
    const lut_index_max_f: f32 = @floatFromInt(lut_index_max);

    var i: usize = 0;
    while (i < iter.len) : (i += 1) {
        const smooth = iter[i];
        const texel: Rgba8 = if (smooth == mandelbrot.interior_sentinel)
            interior // interior points are colored outside the LUT (plan A5)
        else texel: {
            const t = mapping.mapToUnit(smooth, max_iter, params); // already in [0,1]
            const scaled = t * lut_index_max_f; // 0..lut_index_max (t is non-negative)
            const raw: usize = @intFromFloat(scaled);
            // Clamp so t == 1.0 lands on the last texel and float rounding never reads
            // past the LUT (AC: no out-of-bounds index).
            break :texel lut[@min(raw, lut_index_max)];
        };

        const base = i * 4;
        rgba[base + 0] = texel[0];
        rgba[base + 1] = texel[1];
        rgba[base + 2] = texel[2];
        rgba[base + 3] = 255; // the color pass always emits an opaque image
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────
//
// Unit tests pin the per-pixel contract on tiny hand-built buffers; the full-image
// golden reuses iterbuf's fixed 64x48 view and its verified key-pixel coordinates
// (a deep-interior pixel + a slow-escape exterior pixel) so the color-specific
// assertions that lived in M0's render.zig now live beside the color pass.
const viewport = @import("viewport.zig");
const iterbuf = @import("iterbuf.zig");
const Viewport = viewport.Viewport;

const golden_w = 64;
const golden_h = 48;
const golden_iter = 512;
// Verified in iterbuf.zig against a trusted render of the fixed view.
const interior_px = .{ .x = 46, .y = 24 };
const exterior_px = .{ .x = 53, .y = 23 };
// A distinctive, opaque interior color so golden assertions can tell it apart from any
// LUT texel. Opaque because the pass emits an opaque image (see header).
const test_interior: Rgba8 = .{ 5, 10, 15, 255 };

fn bakeDefault() [gradient.lut_size]Rgba8 {
    var lut: [gradient.lut_size]Rgba8 = undefined;
    gradient.bakeLut(gradient.default(), &lut);
    return lut;
}

fn pixelAt(rgba: []const u8, w: usize, x: usize, y: usize) Rgba8 {
    const base = (y * w + x) * 4;
    return .{ rgba[base + 0], rgba[base + 1], rgba[base + 2], rgba[base + 3] };
}

test "colorInto: the interior sentinel writes the passed interior color, opaque" {
    var lut = bakeDefault();
    const iter = [_]f32{mandelbrot.interior_sentinel};
    var rgba: [4]u8 = undefined;
    try colorInto(&rgba, &iter, &lut, golden_iter, .{}, test_interior);
    try std.testing.expectEqual(test_interior, pixelAt(&rgba, 1, 0, 0));
}

test "colorInto: an escaped value routes through mapping + LUT to the expected texel" {
    var lut = bakeDefault();
    // smooth = 128, max_iter = 512, linear ⇒ t = 0.25 ⇒ idx = @intFromFloat(255.75) = 255.
    const smooth: f32 = 128.0;
    const params = mapping.Params{ .mode = .linear };
    const expected = lut[@intFromFloat(mapping.mapToUnit(smooth, golden_iter, params) * 1023.0)];
    const iter = [_]f32{smooth};
    var rgba: [4]u8 = undefined;
    try colorInto(&rgba, &iter, &lut, golden_iter, params, test_interior);
    // Default LUT is opaque, so the forced-255 alpha matches lut[idx] exactly.
    try std.testing.expectEqual(expected, pixelAt(&rgba, 1, 0, 0));
}

test "colorInto: t == 1.0 clamps to the last texel (no out-of-bounds index)" {
    var lut = bakeDefault();
    // smooth == max_iter under linear ⇒ t == 1.0 ⇒ idx must land on texel 1023.
    const iter = [_]f32{@floatFromInt(golden_iter)};
    var rgba: [4]u8 = undefined;
    try colorInto(&rgba, &iter, &lut, golden_iter, .{ .mode = .linear }, test_interior);
    try std.testing.expectEqual(lut[gradient.lut_size - 1], pixelAt(&rgba, 1, 0, 0));
}

test "colorInto: every written pixel is fully opaque (alpha 255)" {
    var lut = bakeDefault();
    // Mix an interior sentinel and an escaped value; both branches must force alpha 255.
    const iter = [_]f32{ mandelbrot.interior_sentinel, 42.0 };
    var rgba: [8]u8 = undefined;
    try colorInto(&rgba, &iter, &lut, golden_iter, .{}, test_interior);
    try std.testing.expectEqual(@as(u8, 255), rgba[3]);
    try std.testing.expectEqual(@as(u8, 255), rgba[7]);
}

test "colorInto: a buffer that is not iter.len*4 returns BufferSizeMismatch" {
    var lut = bakeDefault();
    const iter = [_]f32{ 0.0, 1.0, 2.0, 3.0 };
    var wrong: [15]u8 = undefined; // one byte short of 4*4
    try std.testing.expectError(
        ColorError.BufferSizeMismatch,
        colorInto(&wrong, &iter, &lut, golden_iter, .{}, test_interior),
    );
}

test "colorInto: it never allocates its output — a mismatch fails before any write" {
    // Distinct from the size-guard test's intent: prove the guard runs FIRST, so a
    // caller who ignores the error is not left with a partially-written buffer.
    var lut = bakeDefault();
    const iter = [_]f32{ 0.0, 1.0 };
    var wrong = [_]u8{ 7, 7, 7, 7 }; // 4 bytes for 2 pixels ⇒ mismatch
    _ = colorInto(&wrong, &iter, &lut, golden_iter, .{}, test_interior) catch {};
    try std.testing.expectEqualSlices(u8, &[_]u8{ 7, 7, 7, 7 }, &wrong);
}

test "colorInto is deterministic: two runs produce byte-identical images" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var iter: [golden_w * golden_h]f32 = undefined;
    try iterbuf.iterateInto(&iter, vp, golden_iter);
    var lut = bakeDefault();

    var a: [golden_w * golden_h * 4]u8 = undefined;
    var b: [golden_w * golden_h * 4]u8 = undefined;
    try colorInto(&a, &iter, &lut, golden_iter, .{}, test_interior);
    try colorInto(&b, &iter, &lut, golden_iter, .{}, test_interior);
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "full-image golden: the known interior pixel is the interior color" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var iter: [golden_w * golden_h]f32 = undefined;
    try iterbuf.iterateInto(&iter, vp, golden_iter);
    var lut = bakeDefault();
    var rgba: [golden_w * golden_h * 4]u8 = undefined;
    try colorInto(&rgba, &iter, &lut, golden_iter, .{}, test_interior);
    try std.testing.expectEqual(
        test_interior,
        pixelAt(&rgba, golden_w, interior_px.x, interior_px.y),
    );
}

test "full-image golden: a known exterior pixel is a non-interior LUT color" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var iter: [golden_w * golden_h]f32 = undefined;
    try iterbuf.iterateInto(&iter, vp, golden_iter);
    var lut = bakeDefault();
    var rgba: [golden_w * golden_h * 4]u8 = undefined;
    try colorInto(&rgba, &iter, &lut, golden_iter, .{}, test_interior);
    const px = pixelAt(&rgba, golden_w, exterior_px.x, exterior_px.y);
    try std.testing.expect(!std.meta.eql(px, test_interior));
}

test "full-image golden: every pixel is opaque (alpha 255 across the image)" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var iter: [golden_w * golden_h]f32 = undefined;
    try iterbuf.iterateInto(&iter, vp, golden_iter);
    var lut = bakeDefault();
    var rgba: [golden_w * golden_h * 4]u8 = undefined;
    try colorInto(&rgba, &iter, &lut, golden_iter, .{}, test_interior);
    var i: usize = 3;
    while (i < rgba.len) : (i += 4) try std.testing.expectEqual(@as(u8, 255), rgba[i]);
}

test "full-image golden: top/bottom symmetry is preserved (colored image mirrors)" {
    const vp = Viewport.fixedView(golden_w, golden_h);
    var iter: [golden_w * golden_h]f32 = undefined;
    try iterbuf.iterateInto(&iter, vp, golden_iter);
    var lut = bakeDefault();
    var rgba: [golden_w * golden_h * 4]u8 = undefined;
    try colorInto(&rgba, &iter, &lut, golden_iter, .{}, test_interior);

    var y: usize = 0;
    while (y < golden_h) : (y += 1) {
        const mirror = golden_h - 1 - y;
        var x: usize = 0;
        while (x < golden_w) : (x += 1) {
            try std.testing.expectEqual(
                pixelAt(&rgba, golden_w, x, y),
                pixelAt(&rgba, golden_w, x, mirror),
            );
        }
    }
}

test "the reused Rgba8 is color.Rgba8, not a redefined type" {
    try std.testing.expectEqual(color.Rgba8, Rgba8);
}
