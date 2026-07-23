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
