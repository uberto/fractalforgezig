//! Pure DECOUPLING engine — the milestone crux. NO SDL/GPU/log imports: it operates
//! purely on caller-owned buffers, lives in the fast test tier (`zig build test`, no
//! window/device), and is fully unit-tested. The app (T6) owns lifetimes and the GPU
//! upload; this engine owns only the CPU-side state + the decoupling guarantee.
//!
//! THE GUARANTEE (plan A2): editing the palette or mapping reruns ONLY the cheap color
//! pass — it NEVER re-runs the expensive Mandelbrot iteration. We have no GPU dispatches
//! to count, so two counters make the guarantee observable and testable:
//!   * `iteration_passes` — bumped ONLY by `iterate` (refills the `[]f32` smooth buffer).
//!   * `color_passes`     — bumped by every recolor: `iterate` (which recolors too) and
//!     each of `setGradient` / `setMapping` / `setInterior`.
//! A palette/mapping edit therefore bumps `color_passes` while `iteration_passes` stays
//! put — asserted directly in the tests below.
//!
//! Composition (no reimplementation): `iterbuf.iterateInto` (T1) fills the smooth buffer;
//! `gradient.bakeLut` (T2) bakes the LUT; `mapping.Params` (T3) selects the transform;
//! `colorpass.colorInto` (T4) writes the RGBA8 output. This module adds only the
//! persistent state, the counters, the re-bake-on-gradient-change wiring, and a pure
//! summary-line builder.
//!
//! Failure paths return TYPED errors, never `unreachable`: an empty gradient →
//! `EngineError.EmptyGradient`; a mis-sized internal buffer surfaces the composed
//! modules' `BufferSizeMismatch`. The pure core does NO logging — the edge (T6) logs the
//! summary line / error via the repo's scoped `std.log`.
const std = @import("std");
const viewport = @import("viewport.zig");
const iterbuf = @import("iterbuf.zig");
const gradient = @import("gradient.zig");
const mapping = @import("mapping.zig");
const colorpass = @import("colorpass.zig");
const color = @import("color.zig");

const Viewport = viewport.Viewport;

/// Reused verbatim from `color.zig` (M0). Channel order R, G, B, A. Do not redefine.
pub const Rgba8 = color.Rgba8;

/// Errors returned by the engine's fallible operations.
pub const EngineError = error{
    /// A supplied `Gradient` had zero stops; the LUT bake requires at least one. Returned
    /// (not asserted) so a bad edit fails loudly and testably rather than tripping a
    /// debug assert inside `gradient.bakeLut`.
    EmptyGradient,
    /// An internal buffer's length did not match the viewport (`iter.len !=
    /// width*height` or `rgba.len != iter.len*4`). Surfaced from `iterbuf`/`colorpass`
    /// rather than an out-of-bounds write. `init` sizes both buffers correctly, so this
    /// only fires if a caller corrupts the slices — but it is a returned error, never an
    /// `unreachable`, matching the milestone's "no unreachable on failure paths" rule.
    BufferSizeMismatch,
};

/// The persistent color-pipeline state + decoupling counters. The app allocates one via
/// `init`, drives it (`iterate` once, then `setGradient`/`setMapping`/`setInterior` on
/// every edit), reads `output()` to upload, and frees it via `deinit`.
///
/// Fields are public so the data panel (T6) can read the counters directly; treat them
/// as read-only outside the methods below.
pub const Engine = struct {
    alloc: std.mem.Allocator,
    /// The fixed view the iteration buffer was computed for (M2 has no navigation).
    vp: Viewport,
    /// Iteration reference passed through to `iterbuf` and `mapping`.
    max_iter: u32,
    /// Persistent smooth-value buffer (one f32 per pixel). Filled once by `iterate`.
    iter: []f32,
    /// Packed RGBA8 output (4 bytes per pixel). Rewritten by every recolor.
    rgba: []u8,
    /// The current palette; mutated by `setGradient`, baked into `lut`.
    gradient: gradient.Gradient,
    /// The baked LUT for `gradient` (re-baked only when the gradient changes).
    lut: [gradient.lut_size]Rgba8,
    /// The current mapping selection; mutated by `setMapping`.
    params: mapping.Params,
    /// The dedicated interior color (plan A5); mutated by `setInterior`.
    interior: Rgba8,
    /// Number of iteration passes run. Bumped ONLY by `iterate`.
    iteration_passes: u32,
    /// Number of color passes run. Bumped by every recolor (iterate + each edit).
    color_passes: u32,

    /// Allocate the smooth-value + RGBA8 buffers for `vp`, install the default gradient
    /// (baked) / linear mapping / opaque-black interior, and zero both counters. Does NOT
    /// iterate or recolor: after `init` both counters are 0 and the caller drives the
    /// first `iterate`. The smooth buffer is zeroed so a recolor before `iterate` is
    /// well-defined rather than reading undefined memory. Caller must `deinit`.
    pub fn init(alloc: std.mem.Allocator, vp: Viewport, max_iter: u32) !Engine {
        const iter = try alloc.alloc(f32, iterbuf.iterationBufferLen(vp));
        errdefer alloc.free(iter);
        @memset(iter, 0.0);

        const rgba = try alloc.alloc(u8, iter.len * 4);
        errdefer alloc.free(rgba);
        @memset(rgba, 0);

        const g = gradient.default();
        var engine = Engine{
            .alloc = alloc,
            .vp = vp,
            .max_iter = max_iter,
            .iter = iter,
            .rgba = rgba,
            .gradient = g,
            .lut = undefined,
            .params = .{},
            .interior = color.interior_color,
            .iteration_passes = 0,
            .color_passes = 0,
        };
        gradient.bakeLut(g, &engine.lut);
        return engine;
    }

    /// Free the owned buffers. Safe to call once after `init`.
    pub fn deinit(self: *Engine) void {
        self.alloc.free(self.iter);
        self.alloc.free(self.rgba);
    }

    /// (Re)run the EXPENSIVE stage: refill the smooth buffer via `iterbuf` (T1), then
    /// recolor. Bumps `iteration_passes` AND `color_passes` (a recolor happens too). This
    /// is the only path that touches `iteration_passes`.
    pub fn iterate(self: *Engine) EngineError!void {
        try iterbuf.iterateInto(self.iter, self.vp, self.max_iter);
        self.iteration_passes += 1;
        try self.recolor();
    }

    /// Install a new palette, re-bake its LUT, and rerun ONLY the color pass. Bumps
    /// `color_passes`; leaves `iteration_passes` untouched (THE guarantee). Returns
    /// `EngineError.EmptyGradient` (before mutating any state) if `g` has no stops.
    pub fn setGradient(self: *Engine, g: gradient.Gradient) EngineError!void {
        if (g.count == 0) return EngineError.EmptyGradient;
        self.gradient = g;
        gradient.bakeLut(g, &self.lut);
        try self.recolor();
    }

    /// Install a new mapping selection and rerun ONLY the color pass. Bumps
    /// `color_passes`; leaves `iteration_passes` untouched (THE guarantee).
    pub fn setMapping(self: *Engine, params: mapping.Params) EngineError!void {
        self.params = params;
        try self.recolor();
    }

    /// Install a new interior color (plan A5) and rerun ONLY the color pass. Bumps
    /// `color_passes`; leaves `iteration_passes` untouched (THE guarantee).
    pub fn setInterior(self: *Engine, interior: Rgba8) EngineError!void {
        self.interior = interior;
        try self.recolor();
    }

    /// The cheap color pass: map the persistent smooth buffer through the current LUT +
    /// mapping + interior color into `rgba`. Bumps `color_passes`. Never re-iterates.
    fn recolor(self: *Engine) EngineError!void {
        try colorpass.colorInto(self.rgba, self.iter, &self.lut, self.max_iter, self.params, self.interior);
        self.color_passes += 1;
    }

    /// The current packed RGBA8 image for the app to upload/display (read-only view).
    pub fn output(self: *const Engine) []const u8 {
        return self.rgba;
    }

    /// Write this engine's recolor summary line into `buf` (see `colorPassSummary`).
    /// Convenience for the edge (T6) to log after a recolor; delegates to the pure
    /// free builder so the exact string has one definition.
    pub fn summary(self: *const Engine, buf: []u8) ![]u8 {
        return colorPassSummary(buf, self.color_passes, self.params.mode, self.gradient.count);
    }
};

/// Build the one-line recolor summary: `"color pass {n}: mode={s}, stops={k}"` where `n`
/// is the color-pass count, `s` is the mapping mode tag, and `k` is the gradient's stop
/// count. Pure (no I/O) so it is unit-tested for the exact string without a window/GPU;
/// the edge (T6) passes it to `std.log`.
pub fn colorPassSummary(buf: []u8, color_passes: u32, mode: mapping.Mode, stops: usize) ![]u8 {
    return std.fmt.bufPrint(
        buf,
        "color pass {d}: mode={s}, stops={d}",
        .{ color_passes, @tagName(mode), stops },
    );
}

// ─── Tests ───────────────────────────────────────────────────────────────────
//
// The 64x48 fixed view + its verified key-pixel coordinates are reused from iterbuf/
// colorpass so a deep-interior pixel and a slow-escape exterior pixel are known.
const testing = std.testing;

const golden_w = 64;
const golden_h = 48;
const golden_iter = 512;
// Verified in iterbuf.zig against a trusted render of the fixed view.
const interior_px = .{ .x = 46, .y = 24 };
const exterior_px = .{ .x = 53, .y = 23 };

fn testView() Viewport {
    return Viewport.fixedView(golden_w, golden_h);
}

fn pixelAt(rgba: []const u8, x: usize, y: usize) Rgba8 {
    const base = (y * golden_w + x) * 4;
    return .{ rgba[base + 0], rgba[base + 1], rgba[base + 2], rgba[base + 3] };
}

/// A distinctive solid palette that shares no texel with the default gradient's exterior
/// colors, so a recolor to it is guaranteed to change exterior bytes.
fn solidGradient(c: Rgba8) gradient.Gradient {
    return gradient.Gradient.fromStops(&.{
        .{ .pos = 0.0, .color = c },
        .{ .pos = 1.0, .color = c },
    });
}

/// Count how many output bytes differ between two equal-length buffers.
fn diffCount(a: []const u8, b: []const u8) usize {
    var n: usize = 0;
    for (a, b) |x, y| {
        if (x != y) n += 1;
    }
    return n;
}

test "init does not iterate or recolor: both counters start at zero" {
    var e = try Engine.init(testing.allocator, testView(), golden_iter);
    defer e.deinit();
    try testing.expectEqual(@as(u32, 0), e.iteration_passes);
    try testing.expectEqual(@as(u32, 0), e.color_passes);
}

test "init sizes the buffers to the viewport (rgba is 4x the smooth buffer)" {
    var e = try Engine.init(testing.allocator, testView(), golden_iter);
    defer e.deinit();
    try testing.expectEqual(@as(usize, golden_w * golden_h), e.iter.len);
    try testing.expectEqual(e.iter.len * 4, e.rgba.len);
}

test "iterate: the first pass sets iteration_passes to exactly 1" {
    var e = try Engine.init(testing.allocator, testView(), golden_iter);
    defer e.deinit();
    try e.iterate();
    try testing.expectEqual(@as(u32, 1), e.iteration_passes);
}

test "iterate: the whole output image is fully opaque (alpha 255)" {
    var e = try Engine.init(testing.allocator, testView(), golden_iter);
    defer e.deinit();
    try e.iterate();
    var i: usize = 3;
    while (i < e.rgba.len) : (i += 4) try testing.expectEqual(@as(u8, 255), e.rgba[i]);
}

test "THE GUARANTEE: setGradient bumps color_passes but leaves iteration_passes unchanged" {
    var e = try Engine.init(testing.allocator, testView(), golden_iter);
    defer e.deinit();
    try e.iterate();
    const iters_before = e.iteration_passes;
    const colors_before = e.color_passes;
    try e.setGradient(solidGradient(.{ 255, 0, 0, 255 }));
    try testing.expectEqual(iters_before, e.iteration_passes); // NEVER re-iterated
    try testing.expectEqual(colors_before + 1, e.color_passes); // recolored once
}

test "THE GUARANTEE: setMapping bumps color_passes but leaves iteration_passes unchanged" {
    var e = try Engine.init(testing.allocator, testView(), golden_iter);
    defer e.deinit();
    try e.iterate();
    const iters_before = e.iteration_passes;
    const colors_before = e.color_passes;
    try e.setMapping(.{ .mode = .log });
    try testing.expectEqual(iters_before, e.iteration_passes); // NEVER re-iterated
    try testing.expectEqual(colors_before + 1, e.color_passes); // recolored once
}

test "setGradient changes at least one exterior pixel's bytes" {
    var e = try Engine.init(testing.allocator, testView(), golden_iter);
    defer e.deinit();
    try e.iterate();
    var before: [golden_w * golden_h * 4]u8 = undefined;
    @memcpy(&before, e.rgba);
    try e.setGradient(solidGradient(.{ 255, 0, 0, 255 }));
    // A gradient edit only touches exterior pixels (interior is colored outside the LUT),
    // so ANY differing byte is an exterior pixel changing.
    try testing.expect(diffCount(&before, e.rgba) > 0);
}

test "setGradient leaves interior pixels tracking the (unchanged) interior color" {
    var e = try Engine.init(testing.allocator, testView(), golden_iter);
    defer e.deinit();
    try e.iterate();
    try e.setGradient(solidGradient(.{ 255, 0, 0, 255 }));
    // The known deep-interior pixel is colored outside the LUT, so it still equals the
    // engine's interior color after a palette edit.
    try testing.expectEqual(e.interior, pixelAt(e.rgba, interior_px.x, interior_px.y));
}

test "setMapping (linear -> log) changes exterior bytes with no iteration recompute" {
    var e = try Engine.init(testing.allocator, testView(), golden_iter);
    defer e.deinit();
    try e.iterate(); // default mapping is linear
    const iters_before = e.iteration_passes;
    var before: [golden_w * golden_h * 4]u8 = undefined;
    @memcpy(&before, e.rgba);
    try e.setMapping(.{ .mode = .log });
    try testing.expect(diffCount(&before, e.rgba) > 0); // exterior recolored
    try testing.expectEqual(iters_before, e.iteration_passes); // no re-iteration
}

test "setInterior recolors interior pixels without re-iterating" {
    var e = try Engine.init(testing.allocator, testView(), golden_iter);
    defer e.deinit();
    try e.iterate();
    const iters_before = e.iteration_passes;
    const colors_before = e.color_passes;
    const new_interior: Rgba8 = .{ 5, 10, 15, 255 };
    try e.setInterior(new_interior);
    try testing.expectEqual(new_interior, pixelAt(e.rgba, interior_px.x, interior_px.y));
    try testing.expectEqual(iters_before, e.iteration_passes); // no re-iteration
    try testing.expectEqual(colors_before + 1, e.color_passes);
}

test "output() returns the current RGBA8 buffer" {
    var e = try Engine.init(testing.allocator, testView(), golden_iter);
    defer e.deinit();
    try e.iterate();
    try testing.expectEqual(e.rgba.ptr, e.output().ptr);
    try testing.expectEqual(e.rgba.len, e.output().len);
}

test "setGradient with an empty gradient returns EmptyGradient and does not recolor" {
    var e = try Engine.init(testing.allocator, testView(), golden_iter);
    defer e.deinit();
    try e.iterate();
    const colors_before = e.color_passes;
    const empty = gradient.Gradient{}; // count == 0
    try testing.expectError(EngineError.EmptyGradient, e.setGradient(empty));
    try testing.expectEqual(colors_before, e.color_passes); // no recolor happened
}

test "a mis-sized internal buffer surfaces BufferSizeMismatch, not unreachable" {
    var e = try Engine.init(testing.allocator, testView(), golden_iter);
    defer e.deinit();
    try e.iterate();
    // Shrink the output slice (same base pointer) so colorInto's size guard trips; a
    // recolor must RETURN the typed error rather than panicking. Restore before deinit so
    // the allocator frees the original allocation.
    const saved = e.rgba;
    e.rgba = saved[0 .. saved.len - 4];
    defer e.rgba = saved;
    try testing.expectError(EngineError.BufferSizeMismatch, e.setMapping(.{ .mode = .log }));
}

test "colorPassSummary produces the documented one-line string" {
    var buf: [64]u8 = undefined;
    const line = try colorPassSummary(&buf, 2, .log, 5);
    try testing.expectEqualStrings("color pass 2: mode=log, stops=5", line);
}

test "Engine.summary reflects the live counter, mapping mode, and stop count" {
    var e = try Engine.init(testing.allocator, testView(), golden_iter);
    defer e.deinit();
    try e.iterate(); // color_passes -> 1, default 5-stop palette, linear
    var buf: [64]u8 = undefined;
    const line = try e.summary(&buf);
    try testing.expectEqualStrings("color pass 1: mode=linear, stops=5", line);
}
