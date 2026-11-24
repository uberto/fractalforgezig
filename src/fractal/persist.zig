//! Save/restore the complete render state (view, policy, gradient, mapping, interior)
//! to/from a JSON byte stream. Pure: no SDL/GPU/ImGui imports.
//!
//! OWNERSHIP: `fromEngine` allocates `stops` on the caller-supplied allocator.
//! The caller MUST call `freeState` after use. `fromJson` similarly allocates `stops`.
//!
//! APPLY ORDER: `applyToEngine` calls the cheap color setters first, then
//! `setViewport` LAST — it re-iterates, so the palette is already in place.
//!
//! CENTRE SPELLING (M6/T8): the view centre is `f128` and is written as a quoted DECIMAL
//! STRING, because a JSON number is read back at double precision by std.json and by every
//! other tool — which threw away the ~17 low digits that put a deep view where it is. The
//! loader accepts BOTH spellings (string and number); see `CenterJson`. There is deliberately
//! NO version field in this format, so that loader branch is the whole of its backwards
//! compatibility. That string is base-10 either way, but plain (`-0.75`) for shallow centres and
//! e-notation (`7.5…e-11`) for the deep ones — both exact, see `writeCenter`. `side` stays `f64`,
//! matching `SquareView`.
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
    /// The view centre at FULL precision — the same `f128` the engine navigates in. Persisted
    /// as a decimal string (see `CenterJson`), never as a JSON number.
    center_re: f128,
    center_im: f128,
    /// A span, not a position: `f64` here matches `SquareView.side` exactly.
    side: f64,
    policy_auto: bool,
    policy_manual_value: u32,
    /// Heap-allocated slice. Call `freeState` when done.
    stops: []SerialStop,
    /// Tag name of `mapping_mod.Mode`: "linear" | "log" | "cyclic".
    mapping_mode: []const u8,
    mapping_period: f32,
    /// Whether iteration bands are shown (M8). Defaults to `false` (smooth), mirroring
    /// `mapping_mod.Params.banded`: a `.fractal` file written before this field existed carries no
    /// `banded` key and loads as smooth (see `Wire.banded` and `fromJson`).
    banded: bool = false,
    use_bla: bool = false,
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

// ─── The centre's text form (M6/T8) ───────────────────────────────────────────

/// Significant decimal digits the shortest round-tripping text of an `f128` can need:
/// `ceil(1 + 113 · log10(2))` = 36 for a 113-bit mantissa. NOT the same thing as "34 decimals
/// after the point" — see `writeCenter`.
const max_center_digits = 36;

/// How many leading zeros after the point the PLAIN decimal form is budgeted for. This is a
/// BUDGET, not a claim about what values exist: it buys a readable plain form for the shallow
/// centres a user actually looks at, at a fraction of the type's own worst case
/// (`std.fmt.float.bufferSize(.decimal, f128)` = 5011 bytes, which nothing here needs and no
/// event handler's stack should carry). A centre `std.fmt.float.render` will not commit to this
/// many bytes is written in the exponent form instead — routine at this milestone's depths, and
/// sooner than the digits alone suggest: see `writeCenter` for the bound that decides it.
const plain_center_zeros_budget = 40;

/// Bytes one persisted centre coordinate can need: sign, the leading `0`, the point, the
/// `plain_center_zeros_budget` zeros after it, and the digits themselves. Two of these replaced
/// M5's two ~20-character numbers, which is why `min_json_buf_len` grew.
pub const center_text_max_len = 3 + plain_center_zeros_budget + max_center_digits;

comptime {
    // `writeCenter`'s exponent-form fallback must ALWAYS fit, so its `catch unreachable` really
    // is unreachable.
    std.debug.assert(center_text_max_len >= std.fmt.float.bufferSize(.scientific, f128));
}

/// Bytes every field EXCEPT the centre can need: `gradient.max_stops` (32) stops at ~100 bytes
/// each in `indent_2` form plus the ~300 bytes of fixed keys, braces and small numbers. M5
/// documented this as "4 KiB is sufficient" and it still is — only the centre grew.
const json_fixed_fields_len = 4096;

/// The buffer length that fits `toJson`'s output for ANY valid `AppState`. Callers (`main.zig`'s
/// save and load paths) MUST size their buffers from here rather than hand-writing a length: a
/// buffer that no longer fits the two centre strings is an overflow, not a cosmetic problem.
pub const min_json_buf_len = json_fixed_fields_len + 2 * (center_text_max_len + 2);

/// Render ONE centre coordinate as the decimal text the file carries. Returns a slice of `buf`.
///
/// SIBLING, DO NOT MERGE: `src/ui/editor.zig`'s `writeCoordHi` also renders an `f128` to decimal,
/// and the two look mergeable but are NOT. They optimise for opposite things. THIS one writes
/// straight into a fixed 79-byte destination and lets `render`'s conservative length BOUND decide
/// the form — cheap, bounded, no re-parse, exactly what the save path wants. `writeCoordHi` renders
/// into a generous scratch, length-checks the ACTUAL output, and re-parses to PROVE the plain form
/// is lossless — readable and verified, exactly what the live editor field wants. On the real
/// deep-zoom residue `7.500000620552782493177801370620728e-11` they legitimately DISAGREE: this one
/// emits the exponent form (pinned below), `writeCoordHi` emits plain. A shared helper cannot honour
/// both contracts at once, so they stay separate on purpose. (m8/T8 parked, user-confirmed.)
///
/// FORMAT: `{d}` — full precision, i.e. the SHORTEST decimal that reparses to the identical
/// `f128`. Do NOT replace it with a fixed decimal count: `{d:.34}` reads like "34 digits" but
/// means 34 digits AFTER THE POINT, a 1e-34 grid that is COARSER than the `f128` ulp for
/// |v| < 1 — measured on this milestone's own reference centre, 204 of 512 neighbouring values
/// could not be recovered from it. `{d}` is also what keeps the home view readable as `-0.75`
/// instead of a wall of zeros.
///
/// We call `std.fmt.float.render` — exactly what the `{d}` formatter calls — rather than
/// `bufPrint("{d}", …)` on purpose: the FORMATTER renders into a fixed 347-byte scratch buffer
/// and, for a value needing more, silently emits the placeholder `(float)`. That text would go
/// straight into the save file and fail to load. Calling `render` makes it a branch we control.
///
/// BOTH FORMS ARE ON THE NORMAL PATH; the exponent fallback is NOT dead code for absurd pasted
/// magnitudes, so do not "simplify" it away. We get the plain form for exactly as long as `render`
/// ACCEPTS THE DESTINATION BUFFER we hand it, and that acceptance test is a conservative BOUND, not
/// the real output length: `formatDecimal` demands `2 + |exponent of the last digit| + digit count`
/// bytes (`std/fmt/float.zig:282-288`), which counts every significant digit a second time on top
/// of the zero run after the point. So a value of `d` significant digits at decimal exponent `-E`
/// must fit `1 + 2·d + E` into `center_text_max_len` (79) even though its text is far shorter — the
/// 36-character reference centre already asks for 68. Measured crossovers: a 34-digit mantissa
/// takes the exponent form from 1e-11, a 35-digit one from 1e-9. That is a property of THIS call,
/// not of `f128`, of decimal text, or of how deep a decimal string can name a centre: `src/ui/`'s
/// `editor.decimalIfExact` renders into a generous scratch and then length-checks the ACTUAL
/// output, which keeps a full 36-digit mantissa plain down to ~1e-27. Adopting that here is a
/// deliberate non-goal for now — the current spelling is the one verified at scale — so expect the
/// exponent form at ordinary deep-zoom magnitudes: a real `zoomAbout` sequence near the real axis
/// left `center_im` at `7.500000620552782493177801370620728e-11`. Both forms name the value
/// exactly, so the round trip is unaffected either way, and the tests below pin each.
fn writeCenter(buf: *[center_text_max_len]u8, value: f128) []const u8 {
    return std.fmt.float.render(buf, value, .{ .mode = .decimal }) catch
        std.fmt.float.render(buf, value, .{ .mode = .scientific }) catch unreachable;
}

/// The view centre as it travels through JSON.
///
/// BACKWARDS COMPATIBILITY LIVES HERE, AND ONLY HERE. This format has no version field and no
/// migration step (a deliberate M5 non-goal the user re-confirmed for M6), so these two branches
/// are the only reason every `.fractal` written before this milestone still opens:
///   * WRITING is always a quoted decimal STRING at full `f128` precision (`writeCenter`).
///   * READING accepts EITHER a JSON string (this milestone) OR a JSON number (every pre-M6
///     file). NEVER delete or "simplify" the number branch — doing so silently breaks every
///     existing save file, and no version field would warn you.
/// Neither branch converts through `f64`: both keep the token's raw digits and `fromJson` hands
/// them to `std.fmt.parseFloat(f128, …)`, so a 34-digit number spelling loads with all 34.
const CenterJson = struct {
    /// The digits exactly as the file spells them (or as `writeCenter` rendered them). Borrowed
    /// from the parse arena, so it is only valid until `parsed.deinit()` — `fromJson` converts
    /// it to an `f128` before returning.
    text: []const u8,
    /// Which spelling the file used. Not needed to compute the value; it exists so a test can
    /// pin that BOTH branches are really exercised.
    spelling: Spelling = .string,

    const Spelling = enum { string, number };

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        // A string, never a number: `std.json` reads a JSON number back through `f64`.
        try jws.write(self.text);
    }

    pub fn jsonParse(
        alloc: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !@This() {
        const token = try source.nextAllocMax(alloc, .alloc_always, options.max_value_len.?);
        return switch (token) {
            // The M6 spelling: "-0.743643887037158704752191506114774".
            .allocated_string => |s| .{ .text = s, .spelling = .string },
            // The pre-M6 spelling, which must keep loading forever: -0.75.
            .allocated_number => |s| .{ .text = s, .spelling = .number },
            else => error.UnexpectedToken,
        };
    }
};

// ─── JSON wire format ─────────────────────────────────────────────────────────

/// Intermediate struct that maps directly to/from JSON via std.json.
/// All fields optional-or-defaultable so we can detect missing required fields.
const Wire = struct {
    center_re: ?CenterJson = null,
    center_im: ?CenterJson = null,
    side: ?f64 = null,
    policy_auto: ?bool = null,
    policy_manual_value: ?u32 = null,
    stops: ?[]const WireStop = null,
    mapping_mode: ?[]const u8 = null,
    mapping_period: ?f32 = null,
    /// Optional so a pre-M8 file (no `banded` key) is NOT a `MissingField`: absent means smooth.
    /// This is the whole of the field's backwards compatibility — there is no version field.
    banded: ?bool = null,
    /// Older pictures omit this key and restore with acceleration off.
    use_bla: ?bool = null,
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
/// `buf` must be at least `min_json_buf_len` bytes for any valid `AppState`; a shorter buffer
/// yields `WriteError.JsonWriteFailed` rather than a truncated file.
pub fn toJson(state: AppState, buf: []u8) WriteError![]u8 {
    var wire_stops_buf: [gradient_mod.max_stops]WireStop = undefined;
    for (state.stops, 0..) |s, i| {
        wire_stops_buf[i] = .{ .pos = s.pos, .r = s.r, .g = s.g, .b = s.b, .a = s.a };
    }
    // The centre goes out as text at full precision; see `writeCenter` and `CenterJson`.
    var center_re_text: [center_text_max_len]u8 = undefined;
    var center_im_text: [center_text_max_len]u8 = undefined;
    const wire = Wire{
        .center_re = .{ .text = writeCenter(&center_re_text, state.center_re) },
        .center_im = .{ .text = writeCenter(&center_im_text, state.center_im) },
        .side = state.side,
        .policy_auto = state.policy_auto,
        .policy_manual_value = state.policy_manual_value,
        .stops = wire_stops_buf[0..state.stops.len],
        .mapping_mode = state.mapping_mode,
        .mapping_period = state.mapping_period,
        .banded = state.banded,
        .use_bla = state.use_bla,
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
    const center_re_json = w.center_re orelse return ParseError.MissingField;
    const center_im_json = w.center_im orelse return ParseError.MissingField;
    const side = w.side orelse return ParseError.MissingField;
    const policy_auto = w.policy_auto orelse return ParseError.MissingField;
    const policy_manual_value = w.policy_manual_value orelse return ParseError.MissingField;
    const wire_stops = w.stops orelse return ParseError.MissingField;
    const mapping_mode_str = w.mapping_mode orelse return ParseError.MissingField;
    const mapping_period = w.mapping_period orelse return ParseError.MissingField;
    // Optional, never MissingField: a pre-M8 file with no `banded` key loads as smooth.
    const banded = w.banded orelse false;
    const use_bla = w.use_bla orelse false;
    const interior_r = w.interior_r orelse return ParseError.MissingField;
    const interior_g = w.interior_g orelse return ParseError.MissingField;
    const interior_b = w.interior_b orelse return ParseError.MissingField;
    const interior_a = w.interior_a orelse return ParseError.MissingField;

    // The centre, from whichever spelling the file used (see `CenterJson`), straight to `f128`
    // — never through `f64`, which is the loss this format change exists to remove. Empty or
    // non-numeric digits are an `InvalidField`; an out-of-range magnitude parses to an infinity
    // and the finiteness check below rejects it. Neither case leaves a silently-zero centre.
    const center_re = std.fmt.parseFloat(f128, center_re_json.text) catch
        return ParseError.InvalidField;
    const center_im = std.fmt.parseFloat(f128, center_im_json.text) catch
        return ParseError.InvalidField;

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
        .banded = banded,
        .use_bla = use_bla,
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
        // M6/T8: carried at FULL precision — no `@floatCast` here, and none in `toJson` either.
        // The centre is the one field a deep view cannot afford to round.
        .center_re = engine.view.center_re,
        .center_im = engine.view.center_im,
        .side = engine.view.side,
        .policy_auto = engine.policy.auto,
        .policy_manual_value = engine.policy.manual_value,
        .stops = stops,
        .mapping_mode = mode_copy,
        .mapping_period = engine.params.period,
        .banded = engine.params.banded,
        .use_bla = engine.use_bla,
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
    const params = mapping_mod.Params{ .mode = mode, .period = state.mapping_period, .banded = state.banded };
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
    engine.use_bla = state.use_bla;
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
    try testing.expectEqual(state.use_bla, loaded.use_bla);
    try testing.expectEqual(state.interior_r, loaded.interior_r);
}

test "the BLA setting round-trips and is off when absent" {
    const alloc = testing.allocator;
    const legacy_json =
        \\{"center_re":"-0.75","center_im":"0","side":1.0,
        \\"policy_auto":true,"policy_manual_value":512,
        \\"stops":[{"pos":0,"r":0,"g":0,"b":0,"a":255}],
        \\"mapping_mode":"linear","mapping_period":32.0,
        \\"interior_r":0,"interior_g":0,"interior_b":0,"interior_a":255}
    ;
    var state = try fromJson(legacy_json, alloc);
    defer freeState(state, alloc);
    try testing.expect(!state.use_bla);

    state.use_bla = true;
    var buf: [min_json_buf_len]u8 = undefined;
    const loaded = try fromJson(try toJson(state, &buf), alloc);
    defer freeState(loaded, alloc);
    try testing.expect(loaded.use_bla);
}

test "fromEngine captures the enabled BLA setting" {
    const alloc = testing.allocator;
    var engine = try engine_mod.Engine.init(alloc, viewport.SquareView.defaultView(), 2, .{});
    defer engine.deinit();
    engine.use_bla = true;

    const state = try fromEngine(&engine, alloc);
    defer freeState(state, alloc);
    try testing.expect(state.use_bla);
}

test "applyToEngine replaces the current BLA setting" {
    const alloc = testing.allocator;
    var engine = try engine_mod.Engine.init(alloc, viewport.SquareView.defaultView(), 2, .{});
    defer engine.deinit();
    var stops = oneStop();

    var state = deepState(-0.75, 0.0, 1.0, &stops);
    for ([_]bool{ true, false }) |enabled| {
        state.use_bla = enabled;
        try applyToEngine(state, &engine);
        try testing.expectEqual(enabled, engine.use_bla);
    }
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

// ─── M6/T8: the centre survives a save as a decimal string ────────────────────

/// The milestone's reference centre, as text — the seahorse-valley boundary point. TEXT, not a
/// float literal, so every assertion below compares against exactly what the characters denote.
const deep_re_text = "-0.743643887037158704752191506114774";
const deep_im_text = "0.131825904205311970493132056385139";

/// A `center_im` a REAL `zoomAbout` sequence toward the real axis landed on (34 significant
/// digits at 1e-11), i.e. the residue an ordinary deep zoom leaves behind. Its plain decimal form
/// does not fit `center_text_max_len`, so it is the navigation-reachable value that exercises
/// `writeCenter`'s exponent-form branch. CAREFUL: it is exactly an `f64` value (the offset that
/// produced it was f64), so shift it by an ulp before using it to prove nothing narrows.
const nav_residue_im_text = "7.500000620552782493177801370620728e-11";

/// A minimal single-stop state at `centre`, so a centre test asserts ONLY the centre.
fn deepState(center_re: f128, center_im: f128, side: f64, stops: []SerialStop) AppState {
    return AppState{
        .center_re = center_re,
        .center_im = center_im,
        .side = side,
        .policy_auto = true,
        .policy_manual_value = 512,
        .stops = stops,
        .mapping_mode = "linear",
        .mapping_period = 32.0,
        .interior_r = 0,
        .interior_g = 0,
        .interior_b = 0,
        .interior_a = 255,
    };
}

fn oneStop() [1]SerialStop {
    return [1]SerialStop{.{ .pos = 0.0, .r = 0, .g = 0, .b = 0, .a = 255 }};
}

/// `v` shifted by `n` `f128` ulps toward +inf. A value NO decimal literal in this file could
/// name — the point of using it as a fixture (a hand-written literal cannot expose a lossy
/// format, because it is already whatever the format rounds it to).
fn ulpsUp(v: f128, n: u32) f128 {
    const bits: u128 = @bitCast(v);
    return @bitCast(bits + n);
}

test "a deep centre round-trips through JSON bit-identically" {
    const alloc = testing.allocator;
    var engine = try engine_mod.Engine.init(alloc, try viewport.SquareView.fromCenterSide(.{
        .re = try std.fmt.parseFloat(f128, deep_re_text),
        .im = try std.fmt.parseFloat(f128, deep_im_text),
    }, 1.0e-25), 64, .{});
    defer engine.deinit();

    const state = try fromEngine(&engine, alloc);
    defer freeState(state, alloc);

    var json_buf: [4096]u8 = undefined;
    const json_bytes = try toJson(state, &json_buf);
    const loaded = try fromJson(json_bytes, alloc);
    defer freeState(loaded, alloc);

    try testing.expectEqual(try std.fmt.parseFloat(f128, deep_re_text), loaded.center_re);
    try testing.expectEqual(try std.fmt.parseFloat(f128, deep_im_text), loaded.center_im);
}

test "a centre one f128 ulp off a decimal literal still round-trips bit-identically" {
    const alloc = testing.allocator;
    var stops = oneStop();
    const base_re = try std.fmt.parseFloat(f128, deep_re_text);
    const base_im = try std.fmt.parseFloat(f128, deep_im_text);

    var n: u32 = 0;
    while (n < 64) : (n += 1) {
        const state = deepState(ulpsUp(base_re, n), ulpsUp(base_im, n), 1.0e-25, &stops);
        var json_buf: [4096]u8 = undefined;
        const json_bytes = try toJson(state, &json_buf);
        const loaded = try fromJson(json_bytes, alloc);
        defer freeState(loaded, alloc);
        try testing.expectEqual(state.center_re, loaded.center_re);
        try testing.expectEqual(state.center_im, loaded.center_im);
    }
}

test "a legacy numeric centre still parses, at the precision its digits denote" {
    const legacy =
        \\{"center_re":-0.75,"center_im":0.1,"side":0.5,"policy_auto":true,
        \\"policy_manual_value":512,"stops":[{"pos":0.0,"r":0,"g":0,"b":0,"a":255}],
        \\"mapping_mode":"linear","mapping_period":32.0,
        \\"interior_r":0,"interior_g":0,"interior_b":0,"interior_a":255}
    ;
    const loaded = try fromJson(legacy, testing.allocator);
    defer freeState(loaded, testing.allocator);

    try testing.expectEqual(@as(f128, -0.75), loaded.center_re);
    try testing.expectEqual(@as(f128, 0.1), loaded.center_im);
}

test "a legacy numeric centre carries more digits than f64 can hold" {
    const legacy =
        \\{"center_re":-0.743643887037158704752191506114774,"center_im":0.0,"side":1.0e-25,
        \\"policy_auto":true,
        \\"policy_manual_value":512,"stops":[{"pos":0.0,"r":0,"g":0,"b":0,"a":255}],
        \\"mapping_mode":"linear","mapping_period":32.0,
        \\"interior_r":0,"interior_g":0,"interior_b":0,"interior_a":255}
    ;
    const loaded = try fromJson(legacy, testing.allocator);
    defer freeState(loaded, testing.allocator);

    try testing.expectEqual(try std.fmt.parseFloat(f128, deep_re_text), loaded.center_re);
}

test "a string-spelled centre loads with every digit intact" {
    const json =
        \\{"center_re":"-0.743643887037158704752191506114774",
        \\"center_im":"0.131825904205311970493132056385139","side":1.0e-25,"policy_auto":true,
        \\"policy_manual_value":512,"stops":[{"pos":0.0,"r":0,"g":0,"b":0,"a":255}],
        \\"mapping_mode":"linear","mapping_period":32.0,
        \\"interior_r":0,"interior_g":0,"interior_b":0,"interior_a":255}
    ;
    const loaded = try fromJson(json, testing.allocator);
    defer freeState(loaded, testing.allocator);

    try testing.expectEqual(try std.fmt.parseFloat(f128, deep_re_text), loaded.center_re);
    try testing.expectEqual(try std.fmt.parseFloat(f128, deep_im_text), loaded.center_im);
}

test "both centre spellings reach the loader through their own branch" {
    const numeric =
        \\{"center_re":-0.75,"center_im":0.25,"side":0.5,"policy_auto":true,
        \\"policy_manual_value":512,"stops":[{"pos":0.0,"r":0,"g":0,"b":0,"a":255}],
        \\"mapping_mode":"linear","mapping_period":32.0,
        \\"interior_r":0,"interior_g":0,"interior_b":0,"interior_a":255}
    ;
    const parsed_numeric = try std.json.parseFromSlice(Wire, testing.allocator, numeric, .{
        .ignore_unknown_fields = true,
    });
    defer parsed_numeric.deinit();
    try testing.expectEqual(CenterJson.Spelling.number, parsed_numeric.value.center_re.?.spelling);

    const stringly =
        \\{"center_re":"-0.75","center_im":"0.25","side":0.5,"policy_auto":true,
        \\"policy_manual_value":512,"stops":[{"pos":0.0,"r":0,"g":0,"b":0,"a":255}],
        \\"mapping_mode":"linear","mapping_period":32.0,
        \\"interior_r":0,"interior_g":0,"interior_b":0,"interior_a":255}
    ;
    const parsed_string = try std.json.parseFromSlice(Wire, testing.allocator, stringly, .{
        .ignore_unknown_fields = true,
    });
    defer parsed_string.deinit();
    try testing.expectEqual(CenterJson.Spelling.string, parsed_string.value.center_re.?.spelling);
}

test "a deep centre survives a real file: bytes written, read back and parsed" {
    // The in-memory `toJson`/`fromJson` pair cannot catch a byte-level encoding problem, so this
    // one test drives the actual filesystem. `persist.zig` itself stays pure — the FILE is the
    // caller's (here, the test's) business.
    const alloc = testing.allocator;
    var stops = oneStop();
    const base_re = try std.fmt.parseFloat(f128, deep_re_text);
    const base_im = try std.fmt.parseFloat(f128, deep_im_text);
    // One ulp off the literal, so the fixture is a value no decimal literal in this file names.
    const state = deepState(ulpsUp(base_re, 1), ulpsUp(base_im, 1), 1.0e-25, &stops);

    var json_buf: [min_json_buf_len]u8 = undefined;
    const json_bytes = try toJson(state, &json_buf);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "deep.fractal", .data = json_bytes });
    const read_back = try tmp.dir.readFileAlloc(alloc, "deep.fractal", min_json_buf_len);
    defer alloc.free(read_back);

    const loaded = try fromJson(read_back, alloc);
    defer freeState(loaded, alloc);
    try testing.expectEqual(state.center_re, loaded.center_re);
    try testing.expectEqual(state.center_im, loaded.center_im);
}

test "applyToEngine installs the loaded centre in the engine at full precision" {
    const alloc = testing.allocator;
    var stops = oneStop();
    const base_re = try std.fmt.parseFloat(f128, deep_re_text);
    const base_im = try std.fmt.parseFloat(f128, deep_im_text);
    var state = deepState(ulpsUp(base_re, 3), ulpsUp(base_im, 3), 1.0e-25, &stops);
    // A small manual count and a tiny image keep the deep re-iteration `setViewport` triggers
    // cheap; this test is about the centre, not about the render.
    state.policy_auto = false;
    state.policy_manual_value = 16;

    var engine = try engine_mod.Engine.init(
        alloc,
        viewport.SquareView.defaultView(),
        8,
        .{ .auto = false, .manual_value = 16 },
    );
    defer engine.deinit();

    try applyToEngine(state, &engine);
    try testing.expectEqual(state.center_re, engine.view.center_re);
    try testing.expectEqual(state.center_im, engine.view.center_im);
}

test "every centre text this module writes reparses to the identical f128" {
    // Adversarial magnitudes, not tidy literals: the extremes of the type, values whose plain
    // decimal form cannot fit (which take the exponent form), and ulp neighbours of the
    // milestone's reference centre.
    const base_re = try std.fmt.parseFloat(f128, deep_re_text);
    var cases = std.ArrayList(f128){};
    defer cases.deinit(testing.allocator);
    try cases.appendSlice(testing.allocator, &[_]f128{
        0.0,
        -0.0,
        -0.75,
        2.0,
        @bitCast(@as(u128, 1)), // the smallest subnormal
        std.math.floatMin(f128),
        std.math.floatMax(f128),
        -std.math.floatMax(f128),
        1.0e30,
        -1.0e-40,
    });
    var n: u32 = 0;
    while (n < 8) : (n += 1) try cases.append(testing.allocator, ulpsUp(base_re, n));

    for (cases.items) |v| {
        var buf: [center_text_max_len]u8 = undefined;
        const text = writeCenter(&buf, v);
        try testing.expect(text.len <= center_text_max_len);
        try testing.expectEqual(v, try std.fmt.parseFloat(f128, text));
    }
}

test "the centres a user reads stay in plain decimal, not a wall of zeros" {
    // ONLY about readability, and only for these two magnitudes: which form is used depends on the
    // conservative bound `render` applies to our buffer (`writeCenter`), not on the region, so this
    // is NOT an invariant of "centres inside the Mandelbrot region" — deeper ones legitimately take
    // the exponent form. What it pins is that the shallow view a user recognises stays recognisable
    // in the file, which is the whole reason `writeCenter` prefers `.decimal` first.
    var buf: [center_text_max_len]u8 = undefined;
    try testing.expectEqualStrings("-0.75", writeCenter(&buf, -0.75));
    try testing.expectEqualStrings(
        "-0.743643887037158704752191506114774",
        writeCenter(&buf, try std.fmt.parseFloat(f128, deep_re_text)),
    );
}

test "a centre a deep zoom really lands on is written in the exponent form" {
    // Guards the FIXTURE of the round-trip test below: if a future std widens the plain form's
    // reach and this goes green-to-red, nothing is broken — but `writeCenter`'s measured
    // crossover, and the test below's claim to cover the fallback, both need re-deriving.
    var buf: [center_text_max_len]u8 = undefined;
    try testing.expectEqualStrings(
        nav_residue_im_text,
        writeCenter(&buf, try std.fmt.parseFloat(f128, nav_residue_im_text)),
    );
}

test "a centre in exponent form round-trips out of the engine bit-identically" {
    const alloc = testing.allocator;
    // ONE ulp off `nav_residue_im_text`, because that literal is itself EXACTLY an `f64` value
    // (measured) — a zoom near the axis reaches it by adding an f64 offset to the centre. A test
    // that used it unshifted would still pass if this module narrowed the centre through `f64`.
    const center_im = ulpsUp(try std.fmt.parseFloat(f128, nav_residue_im_text), 1);
    var engine = try engine_mod.Engine.init(alloc, try viewport.SquareView.fromCenterSide(.{
        .re = try std.fmt.parseFloat(f128, deep_re_text),
        .im = center_im,
    }, 1.0e-25), 64, .{});
    defer engine.deinit();

    const state = try fromEngine(&engine, alloc);
    defer freeState(state, alloc);

    var json_buf: [min_json_buf_len]u8 = undefined;
    const json_bytes = try toJson(state, &json_buf);
    const loaded = try fromJson(json_bytes, alloc);
    defer freeState(loaded, alloc);

    try testing.expectEqual(center_im, loaded.center_im);
}

test "an exponent-form centre one f128 ulp off a literal still round-trips bit-identically" {
    // The fallback gets the same treatment as the plain form: values no decimal literal in this
    // file could name, so a lossy rendering cannot hide behind a hand-picked fixture.
    const alloc = testing.allocator;
    var stops = oneStop();
    const base_re = try std.fmt.parseFloat(f128, deep_re_text);
    const base_im = try std.fmt.parseFloat(f128, nav_residue_im_text);

    var exponent_forms: u32 = 0;
    var n: u32 = 0;
    while (n < 64) : (n += 1) {
        const center_im = ulpsUp(base_im, n);
        var text_buf: [center_text_max_len]u8 = undefined;
        if (std.mem.indexOfScalar(u8, writeCenter(&text_buf, center_im), 'e') != null) {
            exponent_forms += 1;
        }

        const state = deepState(base_re, center_im, 1.0e-25, &stops);
        var json_buf: [min_json_buf_len]u8 = undefined;
        const json_bytes = try toJson(state, &json_buf);
        const loaded = try fromJson(json_bytes, alloc);
        defer freeState(loaded, alloc);
        try testing.expectEqual(state.center_im, loaded.center_im);
    }
    // Fixture guard, part of the same intent: a sweep that had drifted entirely into the plain
    // form would stop covering the fallback while still passing. Not all 64 neighbours take it —
    // one whose shortest text happens to be a digit or two shorter fits the plain form again,
    // which is the mantissa-length dependence `writeCenter` documents.
    try testing.expect(exponent_forms > 0);
}

test "min_json_buf_len fits the largest state: max_stops and worst-case centres" {
    var stops: [gradient_mod.max_stops]SerialStop = undefined;
    for (&stops, 0..) |*s, i| {
        // Bit patterns, not tidy fractions: an `f32` whose shortest exact text needs all nine
        // significant digits is the widest a stop line can get.
        s.* = .{
            .pos = @bitCast(@as(u32, 0x3E123456) + @as(u32, @intCast(i))),
            .r = 200,
            .g = 201,
            .b = 202,
            .a = 255,
        };
    }
    var state = deepState(-std.math.floatMax(f128), std.math.floatMin(f128), 1.0e-30, &stops);
    state.mapping_mode = "cyclic";
    var json_buf: [min_json_buf_len]u8 = undefined;
    const json_bytes = try toJson(state, &json_buf);
    try testing.expect(json_bytes.len <= min_json_buf_len);
}

test "toJson refuses a buffer too small to hold the state, rather than truncating it" {
    var stops = oneStop();
    const state = deepState(-0.75, 0.25, 1.0, &stops);
    var tiny: [16]u8 = undefined;
    try testing.expectError(WriteError.JsonWriteFailed, toJson(state, &tiny));
}

test "a non-finite centre is rejected on load, never installed" {
    var stops = oneStop();
    const state = deepState(std.math.nan(f128), 0.0, 1.0, &stops);
    var json_buf: [min_json_buf_len]u8 = undefined;
    const json_bytes = try toJson(state, &json_buf);
    try testing.expectError(ParseError.InvalidField, fromJson(json_bytes, testing.allocator));
}

test "freeState releases everything fromJson allocated" {
    // `testing.allocator` fails this test if either the stops or the mapping-mode copy leaks.
    const json =
        \\{"center_re":"-0.75","center_im":"0.0","side":1.0,"policy_auto":true,
        \\"policy_manual_value":512,"stops":[{"pos":0.0,"r":0,"g":0,"b":0,"a":255},
        \\{"pos":1.0,"r":9,"g":8,"b":7,"a":255}],
        \\"mapping_mode":"cyclic","mapping_period":32.0,
        \\"interior_r":0,"interior_g":0,"interior_b":0,"interior_a":255}
    ;
    const loaded = try fromJson(json, testing.allocator);
    freeState(loaded, testing.allocator);
}

test "a loaded deep centre is not the f64 rounding of itself" {
    const alloc = testing.allocator;
    var stops = oneStop();
    const state = deepState(
        try std.fmt.parseFloat(f128, deep_re_text),
        try std.fmt.parseFloat(f128, deep_im_text),
        1.0e-25,
        &stops,
    );
    var json_buf: [4096]u8 = undefined;
    const loaded = try fromJson(try toJson(state, &json_buf), alloc);
    defer freeState(loaded, alloc);

    const narrowed: f128 = @as(f64, @floatCast(loaded.center_re));
    try testing.expect(loaded.center_re != narrowed);
}

test "the saved bytes preserve the field layout including BLA" {
    // Pin the key order, indentation, and spelling of the saved fields.
    const expected =
        \\{
        \\  "center_re": "-0.75",
        \\  "center_im": "0.25",
        \\  "side": 0.5,
        \\  "policy_auto": false,
        \\  "policy_manual_value": 1024,
        \\  "stops": [
        \\    {
        \\      "pos": 0,
        \\      "r": 0,
        \\      "g": 0,
        \\      "b": 0,
        \\      "a": 255
        \\    },
        \\    {
        \\      "pos": 1,
        \\      "r": 255,
        \\      "g": 255,
        \\      "b": 255,
        \\      "a": 255
        \\    }
        \\  ],
        \\  "mapping_mode": "cyclic",
        \\  "mapping_period": 16,
        \\  "banded": false,
        \\  "use_bla": false,
        \\  "interior_r": 1,
        \\  "interior_g": 2,
        \\  "interior_b": 3,
        \\  "interior_a": 255
        \\}
    ;
    var stops = [_]SerialStop{
        .{ .pos = 0.0, .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .pos = 1.0, .r = 255, .g = 255, .b = 255, .a = 255 },
    };
    const state = AppState{
        .center_re = -0.75,
        .center_im = 0.25,
        .side = 0.5,
        .policy_auto = false,
        .policy_manual_value = 1024,
        .stops = &stops,
        .mapping_mode = "cyclic",
        .mapping_period = 16.0,
        .interior_r = 1,
        .interior_g = 2,
        .interior_b = 3,
        .interior_a = 255,
    };
    var json_buf: [4096]u8 = undefined;
    try testing.expectEqualStrings(expected, try toJson(state, &json_buf));
}

test "an empty centre string is rejected as InvalidField" {
    const json =
        \\{"center_re":"","center_im":"0.0","side":1.0,"policy_auto":true,
        \\"policy_manual_value":512,"stops":[{"pos":0.0,"r":0,"g":0,"b":0,"a":255}],
        \\"mapping_mode":"linear","mapping_period":32.0,
        \\"interior_r":0,"interior_g":0,"interior_b":0,"interior_a":255}
    ;
    try testing.expectError(ParseError.InvalidField, fromJson(json, testing.allocator));
}

test "a non-numeric centre string is rejected as InvalidField" {
    const json =
        \\{"center_re":"the seahorse valley","center_im":"0.0","side":1.0,"policy_auto":true,
        \\"policy_manual_value":512,"stops":[{"pos":0.0,"r":0,"g":0,"b":0,"a":255}],
        \\"mapping_mode":"linear","mapping_period":32.0,
        \\"interior_r":0,"interior_g":0,"interior_b":0,"interior_a":255}
    ;
    try testing.expectError(ParseError.InvalidField, fromJson(json, testing.allocator));
}

test "an out-of-range centre string is rejected as InvalidField, not stored as infinity" {
    const json =
        \\{"center_re":"-1e5000","center_im":"0.0","side":1.0,"policy_auto":true,
        \\"policy_manual_value":512,"stops":[{"pos":0.0,"r":0,"g":0,"b":0,"a":255}],
        \\"mapping_mode":"linear","mapping_period":32.0,
        \\"interior_r":0,"interior_g":0,"interior_b":0,"interior_a":255}
    ;
    try testing.expectError(ParseError.InvalidField, fromJson(json, testing.allocator));
}

test "a missing centre key is still MissingField, never a silent zero centre" {
    const json =
        \\{"center_im":"0.0","side":1.0,"policy_auto":true,
        \\"policy_manual_value":512,"stops":[{"pos":0.0,"r":0,"g":0,"b":0,"a":255}],
        \\"mapping_mode":"linear","mapping_period":32.0,
        \\"interior_r":0,"interior_g":0,"interior_b":0,"interior_a":255}
    ;
    try testing.expectError(ParseError.MissingField, fromJson(json, testing.allocator));
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

// ---------------------------------------------------------------------------
// M6 acceptance tests (AT10, AT11) — materialized verbatim from
// `.inception/m6-deep-zoom/acceptance-tests.md`. Immutable: do not weaken.
// ---------------------------------------------------------------------------

test "acceptance: a deep center round-trips through JSON exactly" {
    const alloc = testing.allocator;
    const center_re_text = "-0.743643887037158704752191506114774";
    const center_im_text = "0.131825904205311970493132056385139";

    var engine = try engine_mod.Engine.init(alloc, try viewport.SquareView.fromCenterSide(.{
        .re = -0.743643887037158704752191506114774,
        .im = 0.131825904205311970493132056385139,
    }, 1.0e-25), 64, .{});
    defer engine.deinit();

    const state = try fromEngine(&engine, alloc);
    defer freeState(state, alloc);

    var json_buf: [4096]u8 = undefined;
    const json_bytes = try toJson(state, &json_buf);
    const loaded = try fromJson(json_bytes, alloc);
    defer freeState(loaded, alloc);

    try testing.expectEqual(try std.fmt.parseFloat(f128, center_re_text), loaded.center_re);
    try testing.expectEqual(try std.fmt.parseFloat(f128, center_im_text), loaded.center_im);
}

test "acceptance: a legacy numeric center still parses" {
    const legacy =
        \\{"center_re":-0.75,"center_im":0.1,"side":0.5,"policy_auto":true,
        \\"policy_manual_value":512,"stops":[{"pos":0.0,"r":0,"g":0,"b":0,"a":255}],
        \\"mapping_mode":"linear","mapping_period":32.0,
        \\"interior_r":0,"interior_g":0,"interior_b":0,"interior_a":255}
    ;
    const loaded = try fromJson(legacy, testing.allocator);
    defer freeState(loaded, testing.allocator);

    try testing.expectEqual(@as(f128, -0.75), loaded.center_re);
    try testing.expectEqual(@as(f128, 0.1), loaded.center_im);
}

// ---------------------------------------------------------------------------
// M8 acceptance tests — materialized verbatim from
// `.inception/m8-coloring-schemes/acceptance-tests.md` (`src/fractal/persist.zig`
// section). Immutable: do not weaken.
// ---------------------------------------------------------------------------

test "acceptance: every stop and every interior channel survives a round-trip" {
    const alloc = testing.allocator;
    var stops = [_]SerialStop{
        .{ .pos = 0.0, .r = 1, .g = 2, .b = 3, .a = 255 },
        .{ .pos = 0.5, .r = 40, .g = 50, .b = 60, .a = 200 },
        .{ .pos = 1.0, .r = 250, .g = 240, .b = 230, .a = 255 },
    };
    const state = AppState{
        .center_re = -0.5,
        .center_im = 0.25,
        .side = 1.0,
        .policy_auto = true,
        .policy_manual_value = 512,
        .stops = &stops,
        .mapping_mode = "cyclic",
        .mapping_period = 17.0,
        .banded = true,
        .interior_r = 11,
        .interior_g = 22,
        .interior_b = 33,
        .interior_a = 210,
    };

    var buf: [4096]u8 = undefined;
    const json = try toJson(state, &buf);
    const loaded = try fromJson(json, alloc);
    defer freeState(loaded, alloc);

    try testing.expectEqual(state.stops.len, loaded.stops.len);
    for (state.stops, loaded.stops) |a, b| {
        try testing.expectApproxEqAbs(a.pos, b.pos, 1e-6);
        try testing.expectEqual(a.r, b.r);
        try testing.expectEqual(a.g, b.g);
        try testing.expectEqual(a.b, b.b);
        try testing.expectEqual(a.a, b.a);
    }
    try testing.expectEqualStrings(state.mapping_mode, loaded.mapping_mode);
    try testing.expectApproxEqAbs(state.mapping_period, loaded.mapping_period, 1e-6);
    try testing.expectEqual(state.banded, loaded.banded);
    try testing.expectEqual(state.interior_r, loaded.interior_r);
    try testing.expectEqual(state.interior_g, loaded.interior_g);
    try testing.expectEqual(state.interior_b, loaded.interior_b);
    try testing.expectEqual(state.interior_a, loaded.interior_a);
}

test "acceptance: applying a loaded picture restores the whole colouring" {
    const alloc = testing.allocator;
    var engine = try engine_mod.Engine.init(alloc, try viewport.SquareView.fromCenterSide(
        .{ .re = 0.0, .im = 0.0 },
        2.0,
    ), 32, .{});
    defer engine.deinit();

    var stops = [_]SerialStop{
        .{ .pos = 0.0, .r = 1, .g = 2, .b = 3, .a = 255 },
        .{ .pos = 1.0, .r = 250, .g = 240, .b = 230, .a = 255 },
    };
    const state = AppState{
        .center_re = 0.0,
        .center_im = 0.0,
        .side = 2.0,
        .policy_auto = true,
        .policy_manual_value = 512,
        .stops = &stops,
        .mapping_mode = "cyclic",
        .mapping_period = 17.0,
        .banded = true,
        .interior_r = 11,
        .interior_g = 22,
        .interior_b = 33,
        .interior_a = 210,
    };
    try applyToEngine(state, &engine);

    try testing.expectEqual(state.stops.len, engine.gradient.stops().len);
    try testing.expectEqual(@as(u8, 1), engine.gradient.stops()[0].color[0]);
    try testing.expectEqual(mapping_mod.Mode.cyclic, engine.params.mode);
    try testing.expectApproxEqAbs(@as(f32, 17.0), engine.params.period, 1e-6);
    try testing.expectEqual(true, engine.params.banded);
    try testing.expectEqual(@as(u8, 11), engine.interior[0]);
}
