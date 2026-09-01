//! Save/restore a COLOURING ONLY — gradient stops, mapping mode + period, the banded flag and
//! the interior colour — to/from a JSON byte stream. A colour-only sibling of `persist.zig`:
//! pure (no SDL/GPU/ImGui imports) and INDEPENDENT of it. A scheme carries NOTHING that
//! identifies the view — no centre, side, iteration policy — so none of `persist`'s `f128`
//! centre-text machinery belongs here.
//!
//! OWNERSHIP: `fromEngine` and `fromJson` allocate `stops` on the caller-supplied allocator;
//! the caller MUST call `free` after use. `mapping_mode` is ALWAYS a static string (a
//! `mapping.Mode` tag name), never heap-allocated, so `free` releases only `stops`.
//!
//! NO version field, matching the `.fractal` convention (`persist.zig`).
const std = @import("std");
const gradient_mod = @import("gradient.zig");
const mapping_mod = @import("mapping.zig");
const engine_mod = @import("engine.zig");

const Rgba8 = gradient_mod.Rgba8;

// ─── Serialisable stop ─────────────────────────────────────────────────────────

/// A gradient stop as it appears in the scheme file. Flat fields for easy JSON handling.
pub const SchemeStop = struct {
    pos: f32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

// ─── Scheme ──────────────────────────────────────────────────────────────────

/// A complete, view-free colouring. `stops` is heap-allocated by `fromEngine`/`fromJson`;
/// call `free`. `mapping_mode` is a static `mapping.Mode` tag name ("linear" | "log" |
/// "cyclic"), never owned, so `free` leaves it alone.
pub const Scheme = struct {
    /// Heap-allocated when produced by `fromEngine`/`fromJson`. Call `free`.
    stops: []SchemeStop,
    /// Tag name of `mapping_mod.Mode`: "linear" | "log" | "cyclic". Static, never freed.
    mapping_mode: []const u8,
    mapping_period: f32,
    banded: bool,
    interior_r: u8,
    interior_g: u8,
    interior_b: u8,
    interior_a: u8,
};

// ─── Error types ─────────────────────────────────────────────────────────────

pub const ParseError = error{
    InvalidJson,
    MissingField,
    InvalidField,
    GradientEmpty,
    GradientNotSorted,
    UnknownMappingMode,
    OutOfMemory,
};

pub const WriteError = error{JsonWriteFailed};

/// `applyToEngine` only calls the colour setters, which return `EngineError`. `OutOfMemory` is
/// carried for parity with the colour-apply contract even though no allocation happens here.
pub const ApplyError = engine_mod.EngineError || error{OutOfMemory};

// ─── JSON wire format ──────────────────────────────────────────────────────────

/// Intermediate struct that maps directly to/from JSON via std.json. All fields
/// optional-or-defaultable so a missing required field is detectable (not a silent default).
const Wire = struct {
    stops: ?[]const WireStop = null,
    mapping_mode: ?[]const u8 = null,
    mapping_period: ?f32 = null,
    banded: ?bool = null,
    interior_r: ?u8 = null,
    interior_g: ?u8 = null,
    interior_b: ?u8 = null,
    interior_a: ?u8 = null,
};

const WireStop = struct {
    pos: f32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

// ─── Buffer sizing ─────────────────────────────────────────────────────────────

/// Generous per-stop byte budget in `indent_2` form: the five keys (`pos`,`r`,`g`,`b`,`a`),
/// their values, punctuation and indentation. Comfortably over the ~90 bytes a stop needs.
const scheme_stop_bytes = 128;

/// Fixed non-stop bytes: the `mapping_mode`/`mapping_period`/`banded`/`interior_*` keys, their
/// values, and the surrounding braces and newlines. Comfortably over the ~200 bytes they need.
const scheme_fixed_bytes = 512;

/// The buffer length that fits `toJson`'s output for ANY valid `Scheme`. A scheme carries NO
/// view text (no `f128` centre), so it needs only the stops plus the fixed colouring fields.
/// Callers (main.zig's scheme save) MUST size their buffer from here rather than hand-writing a
/// number: a buffer that no longer fits `gradient.max_stops` stops is an overflow, not cosmetic.
pub const min_json_buf_len = scheme_fixed_bytes + gradient_mod.max_stops * scheme_stop_bytes;

// ─── Public API ──────────────────────────────────────────────────────────────

/// Serialise `scheme` as indented JSON into `buf`. Returns the bytes written. A buffer too
/// small yields `WriteError.JsonWriteFailed` rather than a truncated file.
pub fn toJson(scheme: Scheme, buf: []u8) WriteError![]u8 {
    var wire_stops_buf: [gradient_mod.max_stops]WireStop = undefined;
    for (scheme.stops, 0..) |s, i| {
        wire_stops_buf[i] = .{ .pos = s.pos, .r = s.r, .g = s.g, .b = s.b, .a = s.a };
    }
    const wire = Wire{
        .stops = wire_stops_buf[0..scheme.stops.len],
        .mapping_mode = scheme.mapping_mode,
        .mapping_period = scheme.mapping_period,
        .banded = scheme.banded,
        .interior_r = scheme.interior_r,
        .interior_g = scheme.interior_g,
        .interior_b = scheme.interior_b,
        .interior_a = scheme.interior_a,
    };
    var writer = std.io.Writer.fixed(buf);
    std.json.Stringify.value(wire, .{ .whitespace = .indent_2 }, &writer) catch return WriteError.JsonWriteFailed;
    return writer.buffered();
}

/// Parse JSON bytes into a `Scheme`. Allocates `stops` on `alloc`; caller must call `free`.
/// Maps every failure to a NAMED `ParseError`: not JSON → `InvalidJson`; a required setting
/// absent → `MissingField`; a present-but-bad value → `InvalidField`; empty stops →
/// `GradientEmpty`; positions not ascending → `GradientNotSorted`; a mapping mode that is not
/// linear/log/cyclic → `UnknownMappingMode`.
pub fn fromJson(json: []const u8, alloc: std.mem.Allocator) ParseError!Scheme {
    const parsed = std.json.parseFromSlice(
        Wire,
        alloc,
        json,
        .{ .ignore_unknown_fields = true },
    ) catch return ParseError.InvalidJson;
    defer parsed.deinit();

    const w = parsed.value;

    // Required fields.
    const wire_stops = w.stops orelse return ParseError.MissingField;
    const mapping_mode_str = w.mapping_mode orelse return ParseError.MissingField;
    const mapping_period = w.mapping_period orelse return ParseError.MissingField;
    const banded = w.banded orelse return ParseError.MissingField;
    const interior_r = w.interior_r orelse return ParseError.MissingField;
    const interior_g = w.interior_g orelse return ParseError.MissingField;
    const interior_b = w.interior_b orelse return ParseError.MissingField;
    const interior_a = w.interior_a orelse return ParseError.MissingField;

    // Validate.
    if (wire_stops.len == 0) return ParseError.GradientEmpty;
    if (wire_stops.len > gradient_mod.max_stops) return ParseError.InvalidField;
    const mode = std.meta.stringToEnum(mapping_mod.Mode, mapping_mode_str) orelse
        return ParseError.UnknownMappingMode;

    // Validate stop order (ascending positions).
    var prev: f32 = -std.math.inf(f32);
    for (wire_stops) |s| {
        if (s.pos < prev) return ParseError.GradientNotSorted;
        prev = s.pos;
    }

    // Copy stops into a fresh heap allocation the caller owns.
    const stops = alloc.alloc(SchemeStop, wire_stops.len) catch return ParseError.OutOfMemory;
    for (wire_stops, 0..) |s, i| {
        stops[i] = .{ .pos = s.pos, .r = s.r, .g = s.g, .b = s.b, .a = s.a };
    }

    return Scheme{
        .stops = stops,
        // A static tag name, so `free` need not (and must not) release it. The `mapping_mode`
        // string borrowed from the parse arena would otherwise dangle after `parsed.deinit()`.
        .mapping_mode = @tagName(mode),
        .mapping_period = mapping_period,
        .banded = banded,
        .interior_r = interior_r,
        .interior_g = interior_g,
        .interior_b = interior_b,
        .interior_a = interior_a,
    };
}

/// Copy the current engine COLOURING into a `Scheme`. Allocates `stops` on `alloc`; caller
/// must call `free`. Carries nothing about the view.
pub fn fromEngine(engine: *const engine_mod.Engine, alloc: std.mem.Allocator) error{OutOfMemory}!Scheme {
    const src_stops = engine.gradient.stops();
    const stops = try alloc.alloc(SchemeStop, src_stops.len);
    for (src_stops, 0..) |s, i| {
        stops[i] = .{
            .pos = s.pos,
            .r = s.color[0],
            .g = s.color[1],
            .b = s.color[2],
            .a = s.color[3],
        };
    }
    return Scheme{
        .stops = stops,
        // A static tag name — never freed (see `free`).
        .mapping_mode = @tagName(engine.params.mode),
        .mapping_period = engine.params.period,
        .banded = engine.params.banded,
        .interior_r = engine.interior[0],
        .interior_g = engine.interior[1],
        .interior_b = engine.interior[2],
        .interior_a = engine.interior[3],
    };
}

/// Apply a `Scheme`'s colouring to an engine. Calls the COLOUR setters ONLY — `setGradient`,
/// `setMapping`, `setInterior` — so it inherits the engine's "colour edits never re-iterate"
/// guarantee (a colour pass bumps `color_passes`, leaves `iteration_passes` untouched). It NEVER
/// calls `setViewport` or touches the view.
///
/// ASSUMES the mapping mode is valid: a `Scheme` is only ever produced by `fromJson` (which has
/// already rejected an unknown mode) or by `presets.zig` (always valid). `mapping_mode` is
/// resolved with `std.meta.stringToEnum`, falling back to the engine's current mode rather than
/// inventing an out-of-contract error — which is why `ApplyError` has no `UnknownMappingMode`.
pub fn applyToEngine(scheme: Scheme, engine: *engine_mod.Engine) ApplyError!void {
    var stop_buf: [gradient_mod.max_stops]gradient_mod.Stop = undefined;
    for (scheme.stops, 0..) |s, i| {
        stop_buf[i] = .{ .pos = s.pos, .color = .{ s.r, s.g, s.b, s.a } };
    }
    const gradient = gradient_mod.Gradient.fromStops(stop_buf[0..scheme.stops.len]);
    try engine.setGradient(gradient);

    const mode = std.meta.stringToEnum(mapping_mod.Mode, scheme.mapping_mode) orelse engine.params.mode;
    try engine.setMapping(.{ .mode = mode, .period = scheme.mapping_period, .banded = scheme.banded });

    try engine.setInterior(.{ scheme.interior_r, scheme.interior_g, scheme.interior_b, scheme.interior_a });
}

/// Free heap allocations made by `fromEngine` or `fromJson`. Releases `stops` only;
/// `mapping_mode` is always a static tag name.
pub fn free(scheme: Scheme, alloc: std.mem.Allocator) void {
    alloc.free(scheme.stops);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectApproxEqAbs = testing.expectApproxEqAbs;
const viewport = @import("viewport.zig");

test "acceptance: a saved scheme carries the colouring and not the view" {
    const alloc = testing.allocator;
    var engine = try engine_mod.Engine.init(alloc, try viewport.SquareView.fromCenterSide(
        .{ .re = -0.5, .im = 0.25 },
        1.0,
    ), 32, .{});
    defer engine.deinit();

    const s = try fromEngine(&engine, alloc);
    defer free(s, alloc);

    var buf: [4096]u8 = undefined;
    const json = try toJson(s, &buf);

    // The colouring IS present...
    try expect(std.mem.indexOf(u8, json, "stops") != null);
    try expect(std.mem.indexOf(u8, json, "mapping_mode") != null);
    try expect(std.mem.indexOf(u8, json, "banded") != null);
    try expect(std.mem.indexOf(u8, json, "interior_r") != null);
    // ...and NOTHING identifying the view is.
    try expect(std.mem.indexOf(u8, json, "center") == null);
    try expect(std.mem.indexOf(u8, json, "side") == null);
    try expect(std.mem.indexOf(u8, json, "policy") == null);
}

test "acceptance: loading a scheme replaces the colouring and keeps the view" {
    const alloc = testing.allocator;
    var engine = try engine_mod.Engine.init(alloc, try viewport.SquareView.fromCenterSide(
        .{ .re = -0.5, .im = 0.25 },
        1.0,
    ), 32, .{});
    defer engine.deinit();

    const before_re = engine.view.center_re;
    const before_im = engine.view.center_im;
    const before_side = engine.view.side;

    var stops = [_]SchemeStop{
        .{ .pos = 0.0, .r = 10, .g = 20, .b = 30, .a = 255 },
        .{ .pos = 1.0, .r = 200, .g = 100, .b = 50, .a = 255 },
    };
    const s = Scheme{
        .stops = &stops,
        .mapping_mode = "cyclic",
        .mapping_period = 12.5,
        .banded = true,
        .interior_r = 7,
        .interior_g = 8,
        .interior_b = 9,
        .interior_a = 255,
    };
    try applyToEngine(s, &engine);

    // The view did not move.
    try expectEqual(before_re, engine.view.center_re);
    try expectEqual(before_im, engine.view.center_im);
    try expectEqual(before_side, engine.view.side);
    // The colouring became the scheme's.
    try expectEqual(mapping_mod.Mode.cyclic, engine.params.mode);
    try expectApproxEqAbs(@as(f32, 12.5), engine.params.period, 1e-6);
    try expectEqual(true, engine.params.banded);
    try expectEqual(@as(u8, 10), engine.gradient.stops()[0].color[0]);
    try expectEqual(@as(u8, 7), engine.interior[0]);
}

test "acceptance: loading a scheme repaints without re-iterating" {
    const alloc = testing.allocator;
    var engine = try engine_mod.Engine.init(alloc, try viewport.SquareView.fromCenterSide(
        .{ .re = -0.5, .im = 0.25 },
        1.0,
    ), 32, .{});
    defer engine.deinit();

    const before_iters = engine.iteration_passes;
    const before_colors = engine.color_passes;

    var stops = [_]SchemeStop{
        .{ .pos = 0.0, .r = 10, .g = 20, .b = 30, .a = 255 },
        .{ .pos = 1.0, .r = 200, .g = 100, .b = 50, .a = 255 },
    };
    const s = Scheme{
        .stops = &stops,
        .mapping_mode = "linear",
        .mapping_period = 32.0,
        .banded = false,
        .interior_r = 0,
        .interior_g = 0,
        .interior_b = 0,
        .interior_a = 255,
    };
    try applyToEngine(s, &engine);

    // A colour pass, not an iteration pass (THE GUARANTEE).
    try expectEqual(before_iters, engine.iteration_passes);
    try expect(engine.color_passes > before_colors);
}

test "acceptance: a damaged scheme file is refused with a named reason" {
    const alloc = testing.allocator;
    // Not JSON at all.
    try testing.expectError(ParseError.InvalidJson, fromJson("not a scheme", alloc));
    // Valid JSON, but the colouring settings are missing.
    try testing.expectError(ParseError.MissingField, fromJson("{}", alloc));
    // Well-formed but with an empty gradient.
    const empty_stops =
        \\{"stops":[],"mapping_mode":"linear","mapping_period":32.0,"banded":false,
        \\"interior_r":0,"interior_g":0,"interior_b":0,"interior_a":255}
    ;
    try testing.expectError(ParseError.GradientEmpty, fromJson(empty_stops, alloc));
    // Well-formed but naming a mapping mode that does not exist.
    const bad_mode =
        \\{"stops":[{"pos":0.0,"r":0,"g":0,"b":0,"a":255}],"mapping_mode":"rainbow",
        \\"mapping_period":32.0,"banded":false,
        \\"interior_r":0,"interior_g":0,"interior_b":0,"interior_a":255}
    ;
    try testing.expectError(ParseError.UnknownMappingMode, fromJson(bad_mode, alloc));
}

// ─── Module-owned coverage (not acceptance tests) ──────────────────────────────

test "round-trip: fromEngine → toJson → fromJson preserves the whole colouring" {
    const alloc = testing.allocator;
    var engine = try engine_mod.Engine.init(alloc, try viewport.SquareView.fromCenterSide(
        .{ .re = -0.5, .im = 0.25 },
        1.0,
    ), 32, .{});
    defer engine.deinit();
    try engine.setMapping(.{ .mode = .cyclic, .period = 17.0, .banded = true });

    const s = try fromEngine(&engine, alloc);
    defer free(s, alloc);

    var buf: [4096]u8 = undefined;
    const loaded = try fromJson(try toJson(s, &buf), alloc);
    defer free(loaded, alloc);

    try expectEqual(s.stops.len, loaded.stops.len);
    try testing.expectEqualStrings("cyclic", loaded.mapping_mode);
    try expectApproxEqAbs(@as(f32, 17.0), loaded.mapping_period, 1e-6);
    try expectEqual(true, loaded.banded);
}

test "fromJson: an unsorted gradient is refused with GradientNotSorted" {
    const alloc = testing.allocator;
    const unsorted =
        \\{"stops":[{"pos":0.8,"r":0,"g":0,"b":0,"a":255},{"pos":0.2,"r":9,"g":8,"b":7,"a":255}],
        \\"mapping_mode":"linear","mapping_period":32.0,"banded":false,
        \\"interior_r":0,"interior_g":0,"interior_b":0,"interior_a":255}
    ;
    try testing.expectError(ParseError.GradientNotSorted, fromJson(unsorted, alloc));
}

test "fromJson: too many stops is refused with InvalidField" {
    const alloc = testing.allocator;
    var list = std.ArrayList(u8){};
    defer list.deinit(alloc);
    try list.appendSlice(alloc, "{\"stops\":[");
    var i: usize = 0;
    while (i < gradient_mod.max_stops + 1) : (i += 1) {
        if (i != 0) try list.append(alloc, ',');
        try list.appendSlice(alloc, "{\"pos\":0.0,\"r\":0,\"g\":0,\"b\":0,\"a\":255}");
    }
    try list.appendSlice(alloc, "],\"mapping_mode\":\"linear\",\"mapping_period\":32.0,\"banded\":false," ++
        "\"interior_r\":0,\"interior_g\":0,\"interior_b\":0,\"interior_a\":255}");
    try testing.expectError(ParseError.InvalidField, fromJson(list.items, alloc));
}

test "free releases everything fromJson allocated" {
    // `testing.allocator` fails this test if `stops` leaks.
    const alloc = testing.allocator;
    const json =
        \\{"stops":[{"pos":0.0,"r":0,"g":0,"b":0,"a":255},{"pos":1.0,"r":9,"g":8,"b":7,"a":255}],
        \\"mapping_mode":"cyclic","mapping_period":32.0,"banded":true,
        \\"interior_r":0,"interior_g":0,"interior_b":0,"interior_a":255}
    ;
    const loaded = try fromJson(json, alloc);
    free(loaded, alloc);
}

test "applyToEngine: an already-valid scheme falls back to the engine mode for a bad tag" {
    // `applyToEngine` assumes a valid mode and must NOT error on one it cannot resolve; it keeps
    // the engine's current mode instead. This pins that fallback branch.
    const alloc = testing.allocator;
    var engine = try engine_mod.Engine.init(alloc, try viewport.SquareView.fromCenterSide(
        .{ .re = -0.5, .im = 0.25 },
        1.0,
    ), 32, .{});
    defer engine.deinit();
    try engine.setMapping(.{ .mode = .log, .period = 20.0, .banded = false });

    var stops = [_]SchemeStop{.{ .pos = 0.0, .r = 1, .g = 2, .b = 3, .a = 255 }};
    const s = Scheme{
        .stops = &stops,
        .mapping_mode = "rainbow", // not a real mode
        .mapping_period = 9.0,
        .banded = false,
        .interior_r = 0,
        .interior_g = 0,
        .interior_b = 0,
        .interior_a = 255,
    };
    try applyToEngine(s, &engine);
    try expectEqual(mapping_mod.Mode.log, engine.params.mode);
}
