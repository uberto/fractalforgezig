//! Built-in colouring PRESETS — a small gallery of complete, ready-made colourings the UI
//! (T5) shows as swatches. Each `Preset` is a name plus a `scheme.Scheme`: gradient stops,
//! mapping mode + period, the banded flag and the interior colour. Pure and allocation-free:
//! every preset's `scheme.stops` points at a `const` array baked into the binary, so callers
//! NEVER `free` a preset scheme (unlike `fromEngine`/`fromJson` schemes, which own heap `stops`).
//!
//! `all()` returns the fixed list (more than one). `gradientOf` turns a preset's `SchemeStop`s
//! into a `gradient.Gradient` so the swatch can be baked with `gradient.bakeLut` — the same
//! ramp the colour pass would produce. The FIRST preset (`all()[0]`) spans `pos` 0.0..1.0 so its
//! baked LUT ends are its end stops exactly (the preview contract).
//!
//! Every preset is a VALID colouring: 1..`gradient.max_stops` stops, positions non-decreasing,
//! a known mapping mode ("linear" | "log" | "cyclic"), a period, a banded flag and four interior
//! channels. Applying one (T6) just replaces the editor's colouring as an editable starting point.
const std = @import("std");
const gradient = @import("gradient.zig");
const mapping = @import("mapping.zig");
const scheme = @import("scheme.zig");

// ─── Preset ────────────────────────────────────────────────────────────────────

/// A named, complete colouring. `scheme.stops` points at `const` data — no `free` needed.
pub const Preset = struct {
    name: []const u8,
    scheme: scheme.Scheme,
};

// ─── Stop tables (const, binary-baked) ──────────────────────────────────────────
// `Scheme.stops` is `[]SchemeStop` (non-const, to match heap-owned schemes); a preset points
// it at these immutable tables via `@constCast`. Nothing ever mutates a preset table.

const classic_stops = [_]scheme.SchemeStop{
    .{ .pos = 0.00, .r = 0, .g = 7, .b = 60, .a = 255 }, // deep blue
    .{ .pos = 0.25, .r = 32, .g = 107, .b = 203, .a = 255 }, // blue
    .{ .pos = 0.50, .r = 237, .g = 255, .b = 255, .a = 255 }, // white
    .{ .pos = 0.75, .r = 255, .g = 170, .b = 0, .a = 255 }, // orange
    .{ .pos = 1.00, .r = 0, .g = 2, .b = 20, .a = 255 }, // dark
};

const fire_stops = [_]scheme.SchemeStop{
    .{ .pos = 0.00, .r = 0, .g = 0, .b = 0, .a = 255 }, // black
    .{ .pos = 0.35, .r = 160, .g = 20, .b = 0, .a = 255 }, // red
    .{ .pos = 0.65, .r = 255, .g = 120, .b = 0, .a = 255 }, // orange
    .{ .pos = 0.85, .r = 255, .g = 220, .b = 40, .a = 255 }, // yellow
    .{ .pos = 1.00, .r = 255, .g = 255, .b = 255, .a = 255 }, // white
};

const ice_stops = [_]scheme.SchemeStop{
    .{ .pos = 0.00, .r = 2, .g = 6, .b = 40, .a = 255 }, // navy
    .{ .pos = 0.40, .r = 20, .g = 80, .b = 180, .a = 255 }, // blue
    .{ .pos = 0.75, .r = 90, .g = 200, .b = 235, .a = 255 }, // cyan
    .{ .pos = 1.00, .r = 240, .g = 250, .b = 255, .a = 255 }, // frost
};

const grayscale_stops = [_]scheme.SchemeStop{
    .{ .pos = 0.00, .r = 0, .g = 0, .b = 0, .a = 255 }, // black
    .{ .pos = 1.00, .r = 255, .g = 255, .b = 255, .a = 255 }, // white
};

const contour_stops = [_]scheme.SchemeStop{
    .{ .pos = 0.00, .r = 10, .g = 10, .b = 30, .a = 255 }, // dark
    .{ .pos = 0.50, .r = 120, .g = 220, .b = 140, .a = 255 }, // green
    .{ .pos = 1.00, .r = 250, .g = 250, .b = 210, .a = 255 }, // pale
};

const bands_stops = [_]scheme.SchemeStop{
    .{ .pos = 0.00, .r = 20, .g = 0, .b = 40, .a = 255 }, // violet
    .{ .pos = 0.50, .r = 220, .g = 40, .b = 120, .a = 255 }, // magenta
    .{ .pos = 1.00, .r = 255, .g = 210, .b = 90, .a = 255 }, // gold
};

const ember_stops = [_]scheme.SchemeStop{
    .{ .pos = 0.00, .r = 8, .g = 0, .b = 0, .a = 255 }, // near-black
    .{ .pos = 0.30, .r = 90, .g = 10, .b = 20, .a = 255 }, // dark red
    .{ .pos = 0.70, .r = 220, .g = 90, .b = 30, .a = 255 }, // ember
    .{ .pos = 1.00, .r = 255, .g = 200, .b = 120, .a = 255 }, // glow
};

// ─── The gallery ─────────────────────────────────────────────────────────────────

const presets = [_]Preset{
    .{ .name = "Classic", .scheme = .{
        .stops = @constCast(&classic_stops),
        .mapping_mode = "linear",
        .mapping_period = 32.0,
        .banded = false,
        .interior_r = 0,
        .interior_g = 0,
        .interior_b = 0,
        .interior_a = 255,
    } },
    .{ .name = "Fire", .scheme = .{
        .stops = @constCast(&fire_stops),
        .mapping_mode = "linear",
        .mapping_period = 32.0,
        .banded = false,
        .interior_r = 0,
        .interior_g = 0,
        .interior_b = 0,
        .interior_a = 255,
    } },
    .{ .name = "Ice", .scheme = .{
        .stops = @constCast(&ice_stops),
        .mapping_mode = "linear",
        .mapping_period = 32.0,
        .banded = false,
        .interior_r = 2,
        .interior_g = 6,
        .interior_b = 40,
        .interior_a = 255,
    } },
    .{ .name = "Grayscale", .scheme = .{
        .stops = @constCast(&grayscale_stops),
        .mapping_mode = "linear",
        .mapping_period = 32.0,
        .banded = false,
        .interior_r = 0,
        .interior_g = 0,
        .interior_b = 0,
        .interior_a = 255,
    } },
    .{ .name = "Contour", .scheme = .{
        .stops = @constCast(&contour_stops),
        .mapping_mode = "cyclic",
        .mapping_period = 16.0,
        .banded = false,
        .interior_r = 0,
        .interior_g = 0,
        .interior_b = 0,
        .interior_a = 255,
    } },
    .{ .name = "Bands", .scheme = .{
        .stops = @constCast(&bands_stops),
        .mapping_mode = "linear",
        .mapping_period = 32.0,
        .banded = true,
        .interior_r = 0,
        .interior_g = 0,
        .interior_b = 0,
        .interior_a = 255,
    } },
    .{ .name = "Ember", .scheme = .{
        .stops = @constCast(&ember_stops),
        .mapping_mode = "log",
        .mapping_period = 32.0,
        .banded = false,
        .interior_r = 8,
        .interior_g = 0,
        .interior_b = 0,
        .interior_a = 255,
    } },
};

// ─── Public API ──────────────────────────────────────────────────────────────────

/// The built-in presets. A fixed, binary-baked list; the slice and every preset's `stops`
/// point at `const` data, so callers never `free` them.
pub fn all() []const Preset {
    return &presets;
}

/// Convert a preset's `SchemeStop`s into a bakeable `gradient.Gradient` (via
/// `gradient.Gradient.fromStops`) so the swatch gallery (T5) can bake a preview LUT with
/// `gradient.bakeLut`. Every preset holds a valid stop set, so `fromStops`'s precondition holds.
pub fn gradientOf(p: Preset) gradient.Gradient {
    var buf: [gradient.max_stops]gradient.Stop = undefined;
    for (p.scheme.stops, 0..) |s, i| {
        buf[i] = .{ .pos = s.pos, .color = .{ s.r, s.g, s.b, s.a } };
    }
    return gradient.Gradient.fromStops(buf[0..p.scheme.stops.len]);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

test "acceptance: the presets are complete, valid colourings" {
    const list = all();
    try expect(list.len > 1); // more than one to choose from

    for (list) |p| {
        // At least one stop, no more than the maximum.
        try expect(p.scheme.stops.len >= 1);
        try expect(p.scheme.stops.len <= gradient.max_stops);
        // Stops in sortable (non-decreasing) order.
        var prev: f32 = -1.0;
        for (p.scheme.stops) |st| {
            try expect(st.pos >= prev);
            prev = st.pos;
        }
        // A known mapping mode.
        try expect(std.meta.stringToEnum(mapping.Mode, p.scheme.mapping_mode) != null);
    }
}

test "acceptance: a preset's preview is its own gradient" {
    const p = all()[0];
    var lut: [gradient.lut_size]gradient.Rgba8 = undefined;
    gradient.bakeLut(gradientOf(p), &lut);

    const first = p.scheme.stops[0];
    const last = p.scheme.stops[p.scheme.stops.len - 1];
    // The ramp's ends are the gradient's end stops.
    try expectEqual(first.r, lut[0][0]);
    try expectEqual(first.g, lut[0][1]);
    try expectEqual(first.b, lut[0][2]);
    try expectEqual(last.r, lut[gradient.lut_size - 1][0]);
    try expectEqual(last.g, lut[gradient.lut_size - 1][1]);
    try expectEqual(last.b, lut[gradient.lut_size - 1][2]);
}
