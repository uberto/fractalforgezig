//! Pure UI-STATE for the palette editor + mapping selector. NO ImGui/SDL/GPU/log
//! imports — this lives in the fast test tier (`zig build test`, no window/device) and
//! is fully unit-tested. `panels.zig` (the ImGui edge) owns the widget calls and reads /
//! mutates an `Editor` through these pure helpers; keeping the state model here means the
//! combo↔enum mapping and the stop add/remove/sort list ops stay testable without ImGui.
//!
//! The `Editor` mirrors the engine's editable inputs (plan A7): an ordered list of
//! gradient `Stop`s, the mapping mode (as a combo index) + `cyclic` period, and the
//! dedicated interior color (plan A5). It is a plain value: the edge holds one, mutates
//! it in place from the widgets, and — on any change — feeds `toGradient()` /`params()` /
//! `interior` to the matching engine setter (never re-iterating).
//!
//! Ordering: the editor stores stops in AUTHORING order (a position slider can push a
//! stop past its neighbors), so `toGradient()` copies + SORTS ascending by `pos` before
//! building the `Gradient` the bake requires. Editing therefore never trips the bake's
//! ascending precondition even mid-drag.
const std = @import("std");
const gradient = @import("../fractal/gradient.zig");
const mapping = @import("../fractal/mapping.zig");
const color = @import("../fractal/color.zig");
const viewport = @import("../fractal/viewport.zig");
const autoiter = @import("../fractal/autoiter.zig");

/// Reused verbatim from `color.zig` (M0). Channel order R, G, B, A. Do not redefine.
pub const Rgba8 = color.Rgba8;

/// Combo item labels, indexed by the `Editor.mode_index` (see `indexToMode`). The order
/// here IS the combo order the UI shows and MUST match `modeToIndex`.
pub const mode_items = [_][:0]const u8{ "linear", "log", "cyclic" };

/// The color a freshly-added stop gets: a neutral mid-gray at the palette's midpoint, so
/// a new stop is immediately visible and editable without reading undefined memory.
const new_stop_color: Rgba8 = .{ 128, 128, 128, 255 };
const new_stop_pos: f32 = 0.5;

/// Editable palette + mapping state driven by the UI. A plain value the edge owns; all
/// mutation goes through the methods below so the invariants (>= 1 stop, <= `max_stops`)
/// hold and the model stays ImGui-free and testable.
pub const Editor = struct {
    /// Authoring-order stop list (NOT necessarily ascending; `toGradient` sorts).
    stops_buf: [gradient.max_stops]gradient.Stop = undefined,
    count: usize = 0,
    /// The selected mapping mode as a combo index (see `indexToMode`).
    mode_index: c_int = 0,
    /// The `cyclic` period; ignored by linear/log (mirrors `mapping.Params`).
    period: f32 = mapping.default_period,
    /// The dedicated interior color (plan A5).
    interior: Rgba8 = color.interior_color,

    /// Build the editor pre-loaded with the engine's defaults: the default multi-stop
    /// palette, linear mapping, the default period, and opaque-black interior. Matches
    /// `Engine.init` so the UI and engine agree before the first edit.
    pub fn initDefault() Editor {
        var e = Editor{};
        const s = gradient.default().stops();
        @memcpy(e.stops_buf[0..s.len], s);
        e.count = s.len;
        e.mode_index = modeToIndex(.linear);
        e.period = mapping.default_period;
        e.interior = color.interior_color;
        return e;
    }

    /// The active stops, in authoring order.
    pub fn stops(self: *const Editor) []const gradient.Stop {
        return self.stops_buf[0..self.count];
    }

    /// The selected mapping mode.
    pub fn mode(self: *const Editor) mapping.Mode {
        return indexToMode(self.mode_index);
    }

    /// The mapping selection for `Engine.setMapping`.
    pub fn params(self: *const Editor) mapping.Params {
        return .{ .mode = indexToMode(self.mode_index), .period = self.period };
    }

    /// Build the ascending-sorted `Gradient` for `Engine.setGradient`. Copies the stops,
    /// sorts them by `pos`, and constructs the `Gradient` (whose bake requires ascending
    /// order). Requires `count >= 1`.
    pub fn toGradient(self: *const Editor) gradient.Gradient {
        var tmp: [gradient.max_stops]gradient.Stop = undefined;
        @memcpy(tmp[0..self.count], self.stops_buf[0..self.count]);
        std.mem.sort(gradient.Stop, tmp[0..self.count], {}, lessByPos);
        return gradient.Gradient.fromStops(tmp[0..self.count]);
    }

    /// Append a neutral mid-gray stop at the palette midpoint. Returns `false` (a no-op)
    /// when already at `max_stops` capacity.
    pub fn addStop(self: *Editor) bool {
        if (self.count >= gradient.max_stops) return false;
        self.stops_buf[self.count] = .{ .pos = new_stop_pos, .color = new_stop_color };
        self.count += 1;
        return true;
    }

    /// Remove the stop at `index`, shifting the tail down. Returns `false` (a no-op) when
    /// `index` is out of range or removing would drop below the one-stop minimum the bake
    /// requires.
    pub fn removeStop(self: *Editor, index: usize) bool {
        if (index >= self.count or self.count <= 1) return false;
        var i = index;
        while (i + 1 < self.count) : (i += 1) self.stops_buf[i] = self.stops_buf[i + 1];
        self.count -= 1;
        return true;
    }
};

fn lessByPos(_: void, a: gradient.Stop, b: gradient.Stop) bool {
    return a.pos < b.pos;
}

/// Editable view state for the coordinate panel in `panels.zig`. Pure value — no ImGui/SDL
/// imports. `panels.zig` reads/writes the text buffers via `igInputText` and calls the pure
/// helpers here to parse and validate.
///
/// Two representations (always kept in sync):
///   * **Center + magnification** (`center_re_buf`, `center_im_buf`, `mag_buf`)
///   * **Two opposite corners** (`corner_a_re_buf` … `corner_b_im_buf`)
/// Both are text so they can be bound directly to `igInputText`.
pub const ViewEditor = struct {
    center_re_buf: [32]u8 = std.mem.zeroes([32]u8),
    center_im_buf: [32]u8 = std.mem.zeroes([32]u8),
    mag_buf: [32]u8 = std.mem.zeroes([32]u8),
    corner_a_re_buf: [32]u8 = std.mem.zeroes([32]u8),
    corner_a_im_buf: [32]u8 = std.mem.zeroes([32]u8),
    corner_b_re_buf: [32]u8 = std.mem.zeroes([32]u8),
    corner_b_im_buf: [32]u8 = std.mem.zeroes([32]u8),
    auto_iter: bool = true,
    manual_iter_buf: [16]u8 = std.mem.zeroes([16]u8),

    /// Build a `ViewEditor` pre-loaded from `view`. All text buffers are populated and
    /// null-terminated. Cannot fail — `defaultView()` is always representable.
    pub fn initFromView(view: viewport.SquareView) ViewEditor {
        var ve = ViewEditor{};
        ve.syncFromView(view);
        return ve;
    }

    /// Write all text buffers from `view`, overwriting any previous content. Called after
    /// any navigation commit so the panel stays in sync with the engine.
    pub fn syncFromView(ve: *ViewEditor, view: viewport.SquareView) void {
        const cm = view.centerMag();
        const crs = view.corners();
        writeF64(&ve.center_re_buf, cm.center.re);
        writeF64(&ve.center_im_buf, cm.center.im);
        writeF64(&ve.mag_buf, cm.magnification);
        writeF64(&ve.corner_a_re_buf, crs.min.re);
        writeF64(&ve.corner_a_im_buf, crs.min.im);
        writeF64(&ve.corner_b_re_buf, crs.max.re);
        writeF64(&ve.corner_b_im_buf, crs.max.im);
    }

    /// Parse center + magnification buffers and build a `SquareView`. Returns null on any
    /// parse failure or if the view is degenerate.
    pub fn parseAndApplyCenterMag(ve: ViewEditor) ?viewport.SquareView {
        const re = parseF64(&ve.center_re_buf) orelse return null;
        const im = parseF64(&ve.center_im_buf) orelse return null;
        const mag = parseF64(&ve.mag_buf) orelse return null;
        const cm = viewport.CenterMag{
            .center = .{ .re = re, .im = im },
            .magnification = mag,
        };
        return viewport.SquareView.fromCenterMag(cm) catch null;
    }

    /// Parse corner buffers and build a `SquareView` (snapped to the larger axis). Returns
    /// null on any parse failure or if the view is degenerate.
    pub fn parseAndApplyCorners(ve: ViewEditor) ?viewport.SquareView {
        const a_re = parseF64(&ve.corner_a_re_buf) orelse return null;
        const a_im = parseF64(&ve.corner_a_im_buf) orelse return null;
        const b_re = parseF64(&ve.corner_b_re_buf) orelse return null;
        const b_im = parseF64(&ve.corner_b_im_buf) orelse return null;
        const a = viewport.Complex{ .re = a_re, .im = a_im };
        const b = viewport.Complex{ .re = b_re, .im = b_im };
        return viewport.SquareView.fromCorners(a, b) catch null;
    }

    /// Parse `manual_iter_buf` as a `u32` and return a manual `IterPolicy`. Returns null if
    /// the text is not a valid number or is out of range.
    pub fn parseIterPolicy(ve: ViewEditor) ?autoiter.IterPolicy {
        const s = sliceUntilNull(&ve.manual_iter_buf);
        const v = std.fmt.parseInt(u32, s, 10) catch return null;
        return autoiter.IterPolicy.manual(v) catch null;
    }
};

/// Write an f64 value into a null-terminated text buffer using `"{d}"` format.
fn writeF64(buf: *[32]u8, value: f64) void {
    const s = std.fmt.bufPrint(buf, "{d}", .{value}) catch {
        // If the value somehow doesn't fit (shouldn't happen for f64), write "0".
        buf[0] = '0';
        buf[1] = 0;
        return;
    };
    // Null-terminate after the written content.
    if (s.len < buf.len) buf[s.len] = 0;
}

/// Parse an f64 from a null-terminated buffer. Returns null on failure.
fn parseF64(buf: *const [32]u8) ?f64 {
    const s = sliceUntilNull(buf);
    return std.fmt.parseFloat(f64, s) catch null;
}

/// Return the slice of `buf` up to (but not including) the first null byte.
fn sliceUntilNull(buf: anytype) []const u8 {
    const arr: []const u8 = buf;
    for (arr, 0..) |b, i| {
        if (b == 0) return arr[0..i];
    }
    return arr;
}

/// Map a mapping `Mode` to its combo index. Inverse of `indexToMode`. The order matches
/// `mode_items`.
pub fn modeToIndex(m: mapping.Mode) c_int {
    return switch (m) {
        .linear => 0,
        .log => 1,
        .cyclic => 2,
    };
}

/// Map a combo index back to a mapping `Mode`. Any out-of-range index defaults to
/// `linear` (plan A6) rather than trapping, so a stray combo value can never crash the UI.
pub fn indexToMode(i: c_int) mapping.Mode {
    return switch (i) {
        0 => .linear,
        1 => .log,
        2 => .cyclic,
        else => .linear,
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "initDefault mirrors the engine's default palette, mapping, period, and interior" {
    const e = Editor.initDefault();
    const def = gradient.default();
    try testing.expectEqual(def.count, e.count);
    try testing.expectEqualSlices(gradient.Stop, def.stops(), e.stops());
    try testing.expectEqual(mapping.Mode.linear, e.mode());
    try testing.expectEqual(mapping.default_period, e.period);
    try testing.expectEqual(color.interior_color, e.interior);
}

test "modeToIndex and indexToMode round-trip every mapping mode" {
    inline for (.{ mapping.Mode.linear, .log, .cyclic }) |m| {
        try testing.expectEqual(m, indexToMode(modeToIndex(m)));
    }
}

test "indexToMode defaults an out-of-range index to linear" {
    try testing.expectEqual(mapping.Mode.linear, indexToMode(7));
    try testing.expectEqual(mapping.Mode.linear, indexToMode(-1));
}

test "params reflects the selected mode index and period" {
    var e = Editor.initDefault();
    e.mode_index = modeToIndex(.cyclic);
    e.period = 17.0;
    const p = e.params();
    try testing.expectEqual(mapping.Mode.cyclic, p.mode);
    try testing.expectEqual(@as(f32, 17.0), p.period);
}

test "addStop appends one stop and reports success while there is room" {
    var e = Editor.initDefault();
    const before = e.count;
    try testing.expect(e.addStop());
    try testing.expectEqual(before + 1, e.count);
}

test "addStop refuses (no-op) once at max_stops capacity" {
    var e = Editor{ .count = gradient.max_stops };
    try testing.expect(!e.addStop());
    try testing.expectEqual(gradient.max_stops, e.count);
}

test "removeStop deletes the indexed stop and shifts the tail down" {
    var e = Editor{};
    e.stops_buf[0] = .{ .pos = 0.0, .color = .{ 1, 0, 0, 255 } };
    e.stops_buf[1] = .{ .pos = 0.5, .color = .{ 2, 0, 0, 255 } };
    e.stops_buf[2] = .{ .pos = 1.0, .color = .{ 3, 0, 0, 255 } };
    e.count = 3;
    try testing.expect(e.removeStop(1)); // drop the middle stop
    try testing.expectEqual(@as(usize, 2), e.count);
    try testing.expectEqual(@as(f32, 0.0), e.stops()[0].pos);
    try testing.expectEqual(@as(f32, 1.0), e.stops()[1].pos); // tail shifted into place
}

test "removeStop refuses to drop below the one-stop minimum" {
    var e = Editor{};
    e.stops_buf[0] = .{ .pos = 0.0, .color = .{ 1, 2, 3, 255 } };
    e.count = 1;
    try testing.expect(!e.removeStop(0));
    try testing.expectEqual(@as(usize, 1), e.count);
}

test "removeStop refuses an out-of-range index" {
    var e = Editor.initDefault();
    const before = e.count;
    try testing.expect(!e.removeStop(before));
    try testing.expectEqual(before, e.count);
}

test "toGradient sorts out-of-order stops ascending by position" {
    var e = Editor{};
    e.stops_buf[0] = .{ .pos = 0.9, .color = .{ 9, 0, 0, 255 } };
    e.stops_buf[1] = .{ .pos = 0.1, .color = .{ 1, 0, 0, 255 } };
    e.stops_buf[2] = .{ .pos = 0.5, .color = .{ 5, 0, 0, 255 } };
    e.count = 3;
    const g = e.toGradient();
    const s = g.stops();
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqual(@as(f32, 0.1), s[0].pos);
    try testing.expectEqual(@as(f32, 0.5), s[1].pos);
    try testing.expectEqual(@as(f32, 0.9), s[2].pos);
}

test "toGradient preserves the stop count" {
    const e = Editor.initDefault();
    try testing.expectEqual(e.count, e.toGradient().count);
}

test "mode_items order matches the combo index mapping" {
    try testing.expectEqualStrings("linear", mode_items[@intCast(modeToIndex(.linear))]);
    try testing.expectEqualStrings("log", mode_items[@intCast(modeToIndex(.log))]);
    try testing.expectEqualStrings("cyclic", mode_items[@intCast(modeToIndex(.cyclic))]);
}

// ─── ViewEditor tests ─────────────────────────────────────────────────────────

test "ViewEditor.initFromView round-trips through parseAndApplyCenterMag" {
    const view = viewport.SquareView.defaultView();
    const ve = ViewEditor.initFromView(view);
    const parsed = ve.parseAndApplyCenterMag() orelse return error.TestUnexpectedNull;
    try testing.expectApproxEqAbs(@as(f64, -0.75), parsed.center_re, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), parsed.center_im, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 3.5), parsed.side, 1e-10);
    // magnification round-trip
    try testing.expectApproxEqRel(view.magnification(), parsed.magnification(), 1e-12);
}

test "ViewEditor.initFromView round-trips through parseAndApplyCorners" {
    const view = viewport.SquareView.defaultView();
    const ve = ViewEditor.initFromView(view);
    const parsed = ve.parseAndApplyCorners() orelse return error.TestUnexpectedNull;
    const orig_corners = view.corners();
    const new_corners = parsed.corners();
    try testing.expectApproxEqAbs(orig_corners.min.re, new_corners.min.re, 1e-10);
    try testing.expectApproxEqAbs(orig_corners.min.im, new_corners.min.im, 1e-10);
    try testing.expectApproxEqAbs(orig_corners.max.re, new_corners.max.re, 1e-10);
    try testing.expectApproxEqAbs(orig_corners.max.im, new_corners.max.im, 1e-10);
}

test "ViewEditor.parseAndApplyCenterMag returns null on bad buffer" {
    var ve = ViewEditor.initFromView(viewport.SquareView.defaultView());
    @memset(&ve.center_re_buf, 0);
    @memcpy(ve.center_re_buf[0..12], "not_a_number");
    ve.center_re_buf[12] = 0;
    try testing.expect(ve.parseAndApplyCenterMag() == null);
}

test "ViewEditor.parseAndApplyCorners returns null on bad buffer" {
    var ve = ViewEditor.initFromView(viewport.SquareView.defaultView());
    @memset(&ve.corner_a_re_buf, 0);
    @memcpy(ve.corner_a_re_buf[0..12], "not_a_number");
    ve.corner_a_re_buf[12] = 0;
    try testing.expect(ve.parseAndApplyCorners() == null);
}

test "ViewEditor.syncFromView updates buffers to the new view" {
    const view1 = viewport.SquareView.defaultView();
    var ve = ViewEditor.initFromView(view1);
    const view2 = viewport.SquareView{ .center_re = 0.25, .center_im = -0.5, .side = 0.5 };
    ve.syncFromView(view2);
    const parsed = ve.parseAndApplyCenterMag() orelse return error.TestUnexpectedNull;
    try testing.expectApproxEqAbs(@as(f64, 0.25), parsed.center_re, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, -0.5), parsed.center_im, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.5), parsed.side, 1e-10);
}

test "ViewEditor.parseIterPolicy parses valid number" {
    var ve = ViewEditor{};
    @memcpy(ve.manual_iter_buf[0..3], "256");
    ve.manual_iter_buf[3] = 0;
    const policy = ve.parseIterPolicy() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u32, 256), policy.manual_value);
    try testing.expectEqual(false, policy.auto);
}

test "ViewEditor.parseIterPolicy returns null on invalid text" {
    var ve = ViewEditor{};
    @memcpy(ve.manual_iter_buf[0..3], "abc");
    ve.manual_iter_buf[3] = 0;
    try testing.expect(ve.parseIterPolicy() == null);
}
