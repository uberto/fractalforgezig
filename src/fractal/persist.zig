//! Save/restore the complete render state (view, policy, gradient, mapping, interior)
//! to/from a JSON byte stream. Pure: no SDL/GPU/ImGui imports.
//!
//! OWNERSHIP: `fromEngine` allocates `stops` on the caller-supplied allocator.
//! The caller MUST call `freeState` after use. `fromJson` similarly allocates `stops`.
//!
//! APPLY ORDER: `applyToEngine` calls the cheap color setters first, then
//! `setViewport` LAST — it re-iterates, so the palette is already in place.
const std = @import("std");
const gradient_mod = @import("gradient.zig");
const mapping_mod = @import("mapping.zig");
const autoiter = @import("autoiter.zig");
const engine_mod = @import("engine.zig");
const viewport = @import("viewport.zig");

const Rgba8 = gradient_mod.Rgba8;

// ─── Serializable stop ───────────────────────────────────────────────────────

/// A gradient stop as it appears in the JSON file. Flat fields for easy JSON handling.
pub const SerialStop = struct {
    pos: f32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

// ─── AppState ────────────────────────────────────────────────────────────────

/// The complete saveable render state. `stops` is heap-allocated; call `freeState`.
pub const AppState = struct {
    center_re: f64,
    center_im: f64,
    side: f64,
    policy_auto: bool,
    policy_manual_value: u32,
    /// Heap-allocated slice. Call `freeState` when done.
    stops: []SerialStop,
    /// Tag name of `mapping_mod.Mode`: "linear" | "log" | "cyclic".
    mapping_mode: []const u8,
    mapping_period: f32,
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

pub const ApplyError = engine_mod.EngineError || engine_mod.IterateError || error{OutOfMemory};

// ─── JSON wire format ─────────────────────────────────────────────────────────

/// Intermediate struct that maps directly to/from JSON via std.json.
/// All fields optional-or-defaultable so we can detect missing required fields.
const Wire = struct {
    center_re: ?f64 = null,
    center_im: ?f64 = null,
    side: ?f64 = null,
    policy_auto: ?bool = null,
    policy_manual_value: ?u32 = null,
    stops: ?[]const WireStop = null,
    mapping_mode: ?[]const u8 = null,
    mapping_period: ?f32 = null,
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

// ─── Public API ──────────────────────────────────────────────────────────────

/// Serialize `state` as indented JSON into `buf`. Returns the bytes written.
/// `buf` must be large enough (4 KiB is sufficient for any valid AppState).
pub fn toJson(state: AppState, buf: []u8) WriteError![]u8 {
    var wire_stops_buf: [gradient_mod.max_stops]WireStop = undefined;
    for (state.stops, 0..) |s, i| {
        wire_stops_buf[i] = .{ .pos = s.pos, .r = s.r, .g = s.g, .b = s.b, .a = s.a };
    }
    const wire = Wire{
        .center_re = state.center_re,
        .center_im = state.center_im,
        .side = state.side,
        .policy_auto = state.policy_auto,
        .policy_manual_value = state.policy_manual_value,
        .stops = wire_stops_buf[0..state.stops.len],
        .mapping_mode = state.mapping_mode,
        .mapping_period = state.mapping_period,
        .interior_r = state.interior_r,
        .interior_g = state.interior_g,
        .interior_b = state.interior_b,
        .interior_a = state.interior_a,
    };
    var writer = std.io.Writer.fixed(buf);
    std.json.Stringify.value(wire, .{ .whitespace = .indent_2 }, &writer) catch return WriteError.JsonWriteFailed;
    return writer.buffered();
}

/// Parse JSON bytes into an `AppState`. Allocates `stops` on `alloc`.
/// Caller must call `freeState` after use. Returns `ParseError` on any problem.
pub fn fromJson(json: []const u8, alloc: std.mem.Allocator) ParseError!AppState {
    const parsed = std.json.parseFromSlice(
        Wire,
        alloc,
        json,
        .{ .ignore_unknown_fields = true },
    ) catch return ParseError.InvalidJson;
    defer parsed.deinit();

    const w = parsed.value;

    // Required fields.
    const center_re = w.center_re orelse return ParseError.MissingField;
    const center_im = w.center_im orelse return ParseError.MissingField;
    const side = w.side orelse return ParseError.MissingField;
    const policy_auto = w.policy_auto orelse return ParseError.MissingField;
    const policy_manual_value = w.policy_manual_value orelse return ParseError.MissingField;
    const wire_stops = w.stops orelse return ParseError.MissingField;
    const mapping_mode_str = w.mapping_mode orelse return ParseError.MissingField;
    const mapping_period = w.mapping_period orelse return ParseError.MissingField;
    const interior_r = w.interior_r orelse return ParseError.MissingField;
    const interior_g = w.interior_g orelse return ParseError.MissingField;
    const interior_b = w.interior_b orelse return ParseError.MissingField;
    const interior_a = w.interior_a orelse return ParseError.MissingField;

    // Validate.
    if (side <= 0.0 or !std.math.isFinite(side)) return ParseError.InvalidField;
    if (!std.math.isFinite(center_re) or !std.math.isFinite(center_im)) return ParseError.InvalidField;
    if (wire_stops.len == 0) return ParseError.GradientEmpty;
    if (wire_stops.len > gradient_mod.max_stops) return ParseError.InvalidField;
    _ = std.meta.stringToEnum(mapping_mod.Mode, mapping_mode_str) orelse return ParseError.UnknownMappingMode;

    // Validate stop order.
    var prev: f32 = -std.math.inf(f32);
    for (wire_stops) |s| {
        if (s.pos < prev) return ParseError.GradientNotSorted;
        prev = s.pos;
    }

    // Copy stops into a new heap allocation.
    const stops = alloc.alloc(SerialStop, wire_stops.len) catch return ParseError.OutOfMemory;
    for (wire_stops, 0..) |s, i| {
        stops[i] = .{ .pos = s.pos, .r = s.r, .g = s.g, .b = s.b, .a = s.a };
    }

    // mapping_mode_str is owned by parsed; copy it.
    const mode_copy = alloc.dupe(u8, mapping_mode_str) catch {
        alloc.free(stops);
        return ParseError.OutOfMemory;
    };

    return AppState{
        .center_re = center_re,
        .center_im = center_im,
        .side = side,
        .policy_auto = policy_auto,
        .policy_manual_value = policy_manual_value,
        .stops = stops,
        .mapping_mode = mode_copy,
        .mapping_period = mapping_period,
        .interior_r = interior_r,
        .interior_g = interior_g,
        .interior_b = interior_b,
        .interior_a = interior_a,
    };
}

/// Copy the current engine state into an `AppState`. Allocates `stops` + `mapping_mode`
/// on `alloc`. Caller must call `freeState` after use.
pub fn fromEngine(engine: *const engine_mod.Engine, alloc: std.mem.Allocator) error{OutOfMemory}!AppState {
    const src_stops = engine.gradient.stops();
    const stops = try alloc.alloc(SerialStop, src_stops.len);
    errdefer alloc.free(stops);
    for (src_stops, 0..) |s, i| {
        stops[i] = .{
            .pos = s.pos,
            .r = s.color[0],
            .g = s.color[1],
            .b = s.color[2],
            .a = s.color[3],
        };
    }
    const mode_str = @tagName(engine.params.mode);
    const mode_copy = try alloc.dupe(u8, mode_str);

    return AppState{
        // M6/T2: the view center is `f128` but `AppState` is still `f64`, so this narrows and
        // a center past ~17 significant decimals does NOT survive a save yet. T8 changes the
        // save format (decimal string) to fix that; widening `AppState` here would break the
        // JSON round trip this module owns.
        .center_re = @floatCast(engine.view.center_re),
        .center_im = @floatCast(engine.view.center_im),
        .side = engine.view.side,
        .policy_auto = engine.policy.auto,
        .policy_manual_value = engine.policy.manual_value,
        .stops = stops,
        .mapping_mode = mode_copy,
        .mapping_period = engine.params.period,
        .interior_r = engine.interior[0],
        .interior_g = engine.interior[1],
        .interior_b = engine.interior[2],
        .interior_a = engine.interior[3],
    };
}

/// Apply a loaded `AppState` to an engine, re-iterating for the new view.
/// Cheap setters (gradient, mapping, interior) run first; `setViewport` LAST.
pub fn applyToEngine(state: AppState, engine: *engine_mod.Engine) ApplyError!void {
    // Build gradient.
    var stop_buf: [gradient_mod.max_stops]gradient_mod.Stop = undefined;
    for (state.stops, 0..) |s, i| {
        stop_buf[i] = .{
            .pos = s.pos,
            .color = .{ s.r, s.g, s.b, s.a },
        };
    }
    const gradient = gradient_mod.Gradient.fromStops(stop_buf[0..state.stops.len]);
    engine.setGradient(gradient) catch |err| return err;

    // Mapping.
    const mode = std.meta.stringToEnum(mapping_mod.Mode, state.mapping_mode) orelse mapping_mod.Mode.linear;
    const params = mapping_mod.Params{ .mode = mode, .period = state.mapping_period };
    engine.setMapping(params) catch |err| return err;

    // Interior color.
    const interior: Rgba8 = .{ state.interior_r, state.interior_g, state.interior_b, state.interior_a };
    engine.setInterior(interior) catch |err| return err;

    // Policy.
    const policy = if (state.policy_auto)
        autoiter.IterPolicy{ .auto = true, .manual_value = state.policy_manual_value }
    else
        autoiter.IterPolicy{ .auto = false, .manual_value = state.policy_manual_value };
    engine.policy = policy;

    // View last — triggers re-iteration.
    const view = try viewport.SquareView.fromCenterSide(
        .{ .re = state.center_re, .im = state.center_im },
        state.side,
    );
    try engine.setViewport(view);
}

/// Free heap allocations made by `fromEngine` or `fromJson`.
pub fn freeState(state: AppState, alloc: std.mem.Allocator) void {
    alloc.free(state.stops);
    alloc.free(state.mapping_mode);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "round-trip: fromEngine → toJson → fromJson fields match" {
    const alloc = testing.allocator;
    var engine = try engine_mod.Engine.init(alloc, try viewport.SquareView.fromCenterSide(
        .{ .re = -0.5, .im = 0.25 },
        1.0,
    ), 64, .{});
    defer engine.deinit();

    const state = try fromEngine(&engine, alloc);
    defer freeState(state, alloc);

    var json_buf: [4096]u8 = undefined;
    const json_bytes = try toJson(state, &json_buf);

    const loaded = try fromJson(json_bytes, alloc);
    defer freeState(loaded, alloc);

    try testing.expectApproxEqAbs(state.center_re, loaded.center_re, 1e-15);
    try testing.expectApproxEqAbs(state.center_im, loaded.center_im, 1e-15);
    try testing.expectApproxEqAbs(state.side, loaded.side, 1e-15);
    try testing.expectEqual(state.policy_auto, loaded.policy_auto);
    try testing.expectEqual(state.policy_manual_value, loaded.policy_manual_value);
    try testing.expectEqual(state.stops.len, loaded.stops.len);
    try testing.expectEqualStrings(state.mapping_mode, loaded.mapping_mode);
    try testing.expectApproxEqAbs(state.mapping_period, loaded.mapping_period, 1e-6);
    try testing.expectEqual(state.interior_r, loaded.interior_r);
}

test "fromJson: not-JSON returns InvalidJson" {
    const result = fromJson("not json", testing.allocator);
    try testing.expectError(ParseError.InvalidJson, result);
}

test "fromJson: empty object returns MissingField" {
    const result = fromJson("{}", testing.allocator);
    try testing.expectError(ParseError.MissingField, result);
}

test "fromJson: side=0 returns InvalidField" {
    const json =
        \\{"center_re":0.0,"center_im":0.0,"side":0.0,"policy_auto":true,
        \\"policy_manual_value":512,"stops":[{"pos":0.0,"r":0,"g":0,"b":0,"a":255}],
        \\"mapping_mode":"linear","mapping_period":32.0,
        \\"interior_r":0,"interior_g":0,"interior_b":0,"interior_a":255}
    ;
    const result = fromJson(json, testing.allocator);
    try testing.expectError(ParseError.InvalidField, result);
}

test "fromJson: empty stops returns GradientEmpty" {
    const json =
        \\{"center_re":0.0,"center_im":0.0,"side":1.0,"policy_auto":true,
        \\"policy_manual_value":512,"stops":[],
        \\"mapping_mode":"linear","mapping_period":32.0,
        \\"interior_r":0,"interior_g":0,"interior_b":0,"interior_a":255}
    ;
    const result = fromJson(json, testing.allocator);
    try testing.expectError(ParseError.GradientEmpty, result);
}

test "fromJson: unsorted stops returns GradientNotSorted" {
    const json =
        \\{"center_re":0.0,"center_im":0.0,"side":1.0,"policy_auto":true,
        \\"policy_manual_value":512,
        \\"stops":[{"pos":0.8,"r":0,"g":0,"b":0,"a":255},{"pos":0.2,"r":255,"g":255,"b":255,"a":255}],
        \\"mapping_mode":"linear","mapping_period":32.0,
        \\"interior_r":0,"interior_g":0,"interior_b":0,"interior_a":255}
    ;
    const result = fromJson(json, testing.allocator);
    try testing.expectError(ParseError.GradientNotSorted, result);
}

test "applyToEngine: loaded state matches original engine" {
    const alloc = testing.allocator;
    var engine = try engine_mod.Engine.init(alloc, try viewport.SquareView.fromCenterSide(
        .{ .re = -0.75, .im = 0.0 },
        2.0,
    ), 32, .{});
    defer engine.deinit();

    const state = try fromEngine(&engine, alloc);
    defer freeState(state, alloc);

    // Modify engine to ensure apply actually changes things.
    try engine.setViewport(try viewport.SquareView.fromCenterSide(.{ .re = 0.0, .im = 0.0 }, 0.5));

    try applyToEngine(state, &engine);

    try testing.expectApproxEqAbs(-0.75, engine.view.center_re, 1e-15);
    try testing.expectApproxEqAbs(0.0, engine.view.center_im, 1e-15);
    try testing.expectApproxEqAbs(2.0, engine.view.side, 1e-15);
}
