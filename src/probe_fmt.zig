//! Pure line formatters for the input probe (`src/probe.zig`, `zig build probe`).
//!
//! NO SDL/C imports: the probe itself imports `c.zig` and therefore cannot live in
//! the fast test tier, so every string the probe writes is built HERE, from plain
//! data, and pinned by the unit tests below (`root.zig::startupLine` pattern).
//! `T8` parses `pilot/input-probe.log`, so these formats are a contract: change one
//! and change its test.
const std = @import("std");

/// Render `SDL_TouchDeviceType` (`SDL_touch.h:83`) as a readable name. Takes the raw
/// `i32` so this file stays C-free; an unrecognised value reads `unknown` rather than
/// being folded into one of the four known names.
pub fn touchDeviceTypeName(sdl_type: i32) []const u8 {
    return switch (sdl_type) {
        -1 => "invalid",
        0 => "direct",
        1 => "indirect-absolute",
        2 => "indirect-relative",
        else => "unknown",
    };
}

/// Render `SDL_MouseWheelDirection` as a readable name. `flipped` means SDL has already
/// negated `x`/`y` (`SDL_events.h:501`), which `T8` must know before reading a sign.
pub fn wheelDirectionName(sdl_direction: u32) []const u8 {
    return switch (sdl_direction) {
        0 => "normal",
        1 => "flipped",
        else => "unknown",
    };
}

/// `sdl-version <major>.<minor>.<micro>` from the packed int `SDL_GetVersion` returns
/// (`SDL_version.h:92-118`).
pub fn versionLine(buf: []u8, sdl_version: u32) ![]u8 {
    return std.fmt.bufPrint(buf, "sdl-version {d}.{d}.{d}", .{
        sdl_version / 1_000_000,
        (sdl_version / 1_000) % 1_000,
        sdl_version % 1_000,
    });
}

/// `mouse index=<n> id=<id> name="<name>"`, or `name=none` when SDL reports no name.
/// The quotes are the marker: unquoted `none` can never be confused with a real name.
pub fn mouseLine(buf: []u8, index: usize, id: u32, name: ?[]const u8) ![]u8 {
    if (name) |n| {
        return std.fmt.bufPrint(buf, "mouse index={d} id={d} name=\"{s}\"", .{ index, id, n });
    }
    return std.fmt.bufPrint(buf, "mouse index={d} id={d} name=none", .{ index, id });
}

/// `touch-device index=<n> id=<id> type=<name>`, `type` from `touchDeviceTypeName`.
pub fn touchDeviceLine(buf: []u8, index: usize, id: u64, type_name: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, "touch-device index={d} id={d} type={s}", .{ index, id, type_name });
}

/// Which class of device a `countLine` counts.
pub const DeviceKind = enum { mouse, touch };

/// `<kind>-count <n>`, written before the per-device lines so ZERO devices is stated
/// explicitly. Silence would be ambiguous: it could also mean the probe never asked.
pub fn countLine(buf: []u8, kind: DeviceKind, n: usize) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}-count {d}", .{ @tagName(kind), n });
}

/// One `SDL_EVENT_MOUSE_WHEEL` (`SDL_events.h:492`) as plain data. `direction` is already
/// a name (`wheelDirectionName`) and `mouse_name` is `SDL_GetMouseNameForID`'s answer.
pub const Wheel = struct {
    which: u32,
    x: f32,
    y: f32,
    integer_x: i32,
    integer_y: i32,
    direction: []const u8,
    mouse_x: f32,
    mouse_y: f32,
    mouse_name: ?[]const u8,
};

/// `wheel which=<id> x=<f> y=<f> integer_x=<i> integer_y=<i> direction=<name>
/// mouse_x=<f> mouse_y=<f> mouse_name=<"name"|none>`.
///
/// Floats carry SIX decimals on purpose: whether the deltas are fractional is exactly the
/// trackpad-vs-mouse question `T8` has to answer from this log.
pub fn wheelLine(buf: []u8, w: Wheel) ![]u8 {
    const head = try std.fmt.bufPrint(
        buf,
        "wheel which={d} x={d:.6} y={d:.6} integer_x={d} integer_y={d} direction={s} mouse_x={d:.6} mouse_y={d:.6} mouse_name=",
        .{ w.which, w.x, w.y, w.integer_x, w.integer_y, w.direction, w.mouse_x, w.mouse_y },
    );
    const tail = if (w.mouse_name) |n|
        try std.fmt.bufPrint(buf[head.len..], "\"{s}\"", .{n})
    else
        try std.fmt.bufPrint(buf[head.len..], "none", .{});
    return buf[0 .. head.len + tail.len];
}

/// Which of the three pinch events this is (`SDL_events.h:222-224`).
pub const PinchKind = enum { begin, update, end };

/// One `SDL_PinchFingerEvent` (`SDL_events.h:799`) as plain data.
pub const Pinch = struct {
    kind: PinchKind,
    scale: f32,
    window_id: u32,
    timestamp_ns: u64,
};

/// `pinch kind=<begin|update|end> scale=<f> windowID=<id> timestamp=<ns>`.
///
/// The header calls `scale` "the scale change since the last update", so consecutive
/// `update` scales should MULTIPLY. This log is how `T8` checks that against real numbers.
pub fn pinchLine(buf: []u8, p: Pinch) ![]u8 {
    return std.fmt.bufPrint(buf, "pinch kind={s} scale={d:.6} windowID={d} timestamp={d}", .{
        @tagName(p.kind), p.scale, p.window_id, p.timestamp_ns,
    });
}

/// Which of the three finger events this is.
pub const FingerKind = enum { down, up, motion };

/// One `SDL_TouchFingerEvent` (`SDL_events.h:781`) as plain data. `device_type` is already
/// a name (`touchDeviceTypeName`).
pub const Finger = struct {
    kind: FingerKind,
    touch_id: u64,
    finger_id: u64,
    x: f32,
    y: f32,
    dx: f32,
    dy: f32,
    device_type: []const u8,
};

/// `finger kind=<down|up|motion> touchID=<id> fingerID=<id> x=<f> y=<f> dx=<f> dy=<f>
/// device=<name>`. Positions are SDL-normalised 0..1 and deltas -1..1, signs kept.
pub fn fingerLine(buf: []u8, f: Finger) ![]u8 {
    return std.fmt.bufPrint(
        buf,
        "finger kind={s} touchID={d} fingerID={d} x={d:.6} y={d:.6} dx={d:.6} dy={d:.6} device={s}",
        .{ @tagName(f.kind), f.touch_id, f.finger_id, f.x, f.y, f.dx, f.dy, f.device_type },
    );
}

/// The SUCCESS summary, logged once when the user closes the window: how many input events
/// were recorded and where they went. Zero events is the answer the user most needs to see
/// (it means the gestures never reached SDL), so it is stated rather than implied.
pub fn finishedLine(buf: []u8, recorded: usize, path: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, "input probe finished: recorded {d} input events to '{s}'", .{ recorded, path });
}

/// What the user must do, printed at startup and written as the log's header. Kept here
/// (pure) so the instructions the user reads are the ones the tests pin. Copied from
/// `plan.md` → *How to run* → *The probe*.
pub const usage_banner: []const u8 =
    \\input probe: this window draws NOTHING. It only records input events, to the
    \\terminal and to .inception/m7-trackpad-gestures/pilot/input-probe.log.
    \\Do these five things, then close the window (or press Esc) to quit:
    \\  1. one mouse-wheel notch up and one down (if a mouse is attached);
    \\  2. a two-finger swipe left, right, up, down on the trackpad;
    \\  3. a pinch open;
    \\  4. a pinch closed;
    \\  5. note whether macOS "natural scrolling" is on or off (System Settings ->
    \\     Trackpad -> Scroll & Zoom) and say so in chat: the log cannot see it.
;

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "touchDeviceTypeName names every SDL_TouchDeviceType" {
    try testing.expectEqualStrings("invalid", touchDeviceTypeName(-1));
    try testing.expectEqualStrings("direct", touchDeviceTypeName(0));
    try testing.expectEqualStrings("indirect-absolute", touchDeviceTypeName(1));
    try testing.expectEqualStrings("indirect-relative", touchDeviceTypeName(2));
}

test "touchDeviceTypeName reports an unrecognised type as unknown rather than guessing" {
    try testing.expectEqualStrings("unknown", touchDeviceTypeName(7));
}

test "wheelDirectionName names both SDL wheel directions" {
    try testing.expectEqualStrings("normal", wheelDirectionName(0));
    try testing.expectEqualStrings("flipped", wheelDirectionName(1));
}

test "wheelDirectionName reports an unrecognised direction rather than guessing" {
    try testing.expectEqualStrings("unknown", wheelDirectionName(9));
}

test "versionLine splits the packed SDL version into major.minor.micro" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("sdl-version 3.4.12", try versionLine(&buf, 3_004_012));
}

test "versionLine keeps zero minor and micro components" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("sdl-version 3.0.0", try versionLine(&buf, 3_000_000));
}

test "mouseLine quotes the reported mouse name" {
    var buf: [128]u8 = undefined;
    const line = try mouseLine(&buf, 0, 3, "Apple Internal Trackpad");
    try testing.expectEqualStrings("mouse index=0 id=3 name=\"Apple Internal Trackpad\"", line);
}

test "mouseLine marks a nameless mouse as none instead of an empty quote" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("mouse index=1 id=4 name=none", try mouseLine(&buf, 1, 4, null));
}

test "countLine states the device class and how many were reported" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("mouse-count 2", try countLine(&buf, .mouse, 2));
    try testing.expectEqualStrings("touch-count 0", try countLine(&buf, .touch, 0));
}

test "touchDeviceLine records the device id and its readable type" {
    var buf: [128]u8 = undefined;
    const line = try touchDeviceLine(&buf, 0, 4294967297, "indirect-absolute");
    try testing.expectEqualStrings("touch-device index=0 id=4294967297 type=indirect-absolute", line);
}

test "wheelLine records every wheel field T8 needs, in one line" {
    var buf: [256]u8 = undefined;
    const line = try wheelLine(&buf, .{
        .which = 3,
        .x = 0.0,
        .y = 1.0,
        .integer_x = 0,
        .integer_y = 1,
        .direction = "normal",
        .mouse_x = 640.5,
        .mouse_y = 360.25,
        .mouse_name = "Mouse",
    });
    try testing.expectEqualStrings(
        "wheel which=3 x=0.000000 y=1.000000 integer_x=0 integer_y=1 direction=normal" ++
            " mouse_x=640.500000 mouse_y=360.250000 mouse_name=\"Mouse\"",
        line,
    );
}

test "wheelLine keeps a fractional delta visible to six decimals" {
    var buf: [256]u8 = undefined;
    const line = try wheelLine(&buf, .{
        .which = 0,
        .x = -0.25,
        .y = 0.03125,
        .integer_x = 0,
        .integer_y = 0,
        .direction = "flipped",
        .mouse_x = 0.0,
        .mouse_y = 0.0,
        .mouse_name = null,
    });
    try testing.expectEqualStrings(
        "wheel which=0 x=-0.250000 y=0.031250 integer_x=0 integer_y=0 direction=flipped" ++
            " mouse_x=0.000000 mouse_y=0.000000 mouse_name=none",
        line,
    );
}

test "wheelLine reports a too-small buffer instead of truncating the line" {
    var buf: [8]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, wheelLine(&buf, .{
        .which = 0,
        .x = 0.0,
        .y = 0.0,
        .integer_x = 0,
        .integer_y = 0,
        .direction = "normal",
        .mouse_x = 0.0,
        .mouse_y = 0.0,
        .mouse_name = null,
    }));
}

test "pinchLine records the scale, window and timestamp of an update" {
    var buf: [128]u8 = undefined;
    const line = try pinchLine(&buf, .{
        .kind = .update,
        .scale = 1.03125,
        .window_id = 1,
        .timestamp_ns = 123456789,
    });
    try testing.expectEqualStrings("pinch kind=update scale=1.031250 windowID=1 timestamp=123456789", line);
}

test "pinchLine tags each phase of the gesture distinctly" {
    var buf: [128]u8 = undefined;
    var other: [128]u8 = undefined;
    const begin = try pinchLine(&buf, .{ .kind = .begin, .scale = 1.0, .window_id = 1, .timestamp_ns = 1 });
    try testing.expectEqualStrings("pinch kind=begin scale=1.000000 windowID=1 timestamp=1", begin);
    const end = try pinchLine(&other, .{ .kind = .end, .scale = 1.0, .window_id = 1, .timestamp_ns = 1 });
    try testing.expectEqualStrings("pinch kind=end scale=1.000000 windowID=1 timestamp=1", end);
}

test "fingerLine records position, delta and device type, keeping delta signs" {
    var buf: [256]u8 = undefined;
    const line = try fingerLine(&buf, .{
        .kind = .motion,
        .touch_id = 7,
        .finger_id = 2,
        .x = 0.5,
        .y = 0.25,
        .dx = -0.125,
        .dy = 0.0625,
        .device_type = "indirect-absolute",
    });
    try testing.expectEqualStrings(
        "finger kind=motion touchID=7 fingerID=2 x=0.500000 y=0.250000 dx=-0.125000 dy=0.062500" ++
            " device=indirect-absolute",
        line,
    );
}

test "fingerLine tags a finger going down and coming up distinctly" {
    var down: [256]u8 = undefined;
    var up: [256]u8 = undefined;
    const f = Finger{ .kind = .down, .touch_id = 1, .finger_id = 1, .x = 0, .y = 0, .dx = 0, .dy = 0, .device_type = "direct" };
    try testing.expect(std.mem.indexOf(u8, try fingerLine(&down, f), "kind=down") != null);
    var f_up = f;
    f_up.kind = .up;
    try testing.expect(std.mem.indexOf(u8, try fingerLine(&up, f_up), "kind=up") != null);
}

test "finishedLine summarises how many events were recorded and where" {
    var buf: [128]u8 = undefined;
    const line = try finishedLine(&buf, 42, "pilot/input-probe.log");
    try testing.expectEqualStrings("input probe finished: recorded 42 input events to 'pilot/input-probe.log'", line);
}

test "finishedLine states an empty run rather than implying it" {
    var buf: [128]u8 = undefined;
    const line = try finishedLine(&buf, 0, "pilot/input-probe.log");
    try testing.expectEqualStrings("input probe finished: recorded 0 input events to 'pilot/input-probe.log'", line);
}

test "usage_banner tells the user all five things to do and names the log file" {
    for ([_][]const u8{ "1.", "2.", "3.", "4.", "5." }) |step| {
        try testing.expect(std.mem.indexOf(u8, usage_banner, step) != null);
    }
    try testing.expect(std.mem.indexOf(u8, usage_banner, "input-probe.log") != null);
}
