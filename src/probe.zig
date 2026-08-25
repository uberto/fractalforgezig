//! USER-ONLY input probe (`zig build probe`). Opens a window that draws NOTHING, records
//! every wheel / pinch / finger event to the terminal AND to
//! `.inception/m7-trackpad-gestures/pilot/input-probe.log`, and quits when the window is
//! closed (or Esc). NO agent may run it: launching a window takes over the user's machine
//! (standing rule, 2026-08-20). Agents may only compile it.
//!
//! It is the milestone's SPIKE: whether `SDL_EVENT_PINCH_*` arrives at all, what
//! `event.pinch.scale` carries, and whether a two-finger swipe is distinguishable from a
//! wheel notch cannot be read off the headers. `T8` parses the log this writes.
//!
//! No ImGui, no GPU device, no texture, no drawing — a window plus an event loop.
//!
//! ─── LOG LINE FORMATS (the contract `T8` parses) ────────────────────────────────
//! Space-separated `key=value`; floats always six decimals; a quoted value is a real
//! name and bare `none` means SDL reported nothing. First token identifies the line.
//!
//!   <the usage banner, one line per banner line, no `=`>
//!   sdl-version <major>.<minor>.<micro>
//!   mouse-count <n>
//!   mouse index=<n> id=<SDL_MouseID> name=<"name"|none>
//!   touch-count <n>
//!   touch-device index=<n> id=<SDL_TouchID> type=<direct|indirect-absolute|indirect-relative|invalid|unknown>
//!   wheel which=<SDL_MouseID> x=<f> y=<f> integer_x=<i> integer_y=<i> direction=<normal|flipped|unknown> mouse_x=<f> mouse_y=<f> mouse_name=<"name"|none>
//!   pinch kind=<begin|update|end> scale=<f> windowID=<id> timestamp=<ns>
//!   finger kind=<down|up|motion> touchID=<id> fingerID=<id> x=<f> y=<f> dx=<f> dy=<f> device=<type name>
//!   input probe finished: recorded <n> input events to '<path>'   (last line, the summary)
//!
//! Every one of those lines is built by a pure, unit-tested function in `probe_fmt.zig`
//! — this file is untested glue on purpose, so change a format THERE and its test moves
//! with it.
const std = @import("std");
const c = @import("c.zig").c;
const probe_fmt = @import("probe_fmt.zig");

/// The probe's entire output is log lines, so keep `info` visible whatever the build mode
/// is optimized to (`std.log`'s default level is `.err` in release builds).
pub const std_options: std.Options = .{ .log_level = .info };

const probe_log = std.log.scoped(.probe);

/// Relative to the repo root, which is where `zig build` runs.
const log_dir = ".inception/m7-trackpad-gestures/pilot";
const log_path = log_dir ++ "/input-probe.log";

const window_title = "fractalforge input probe — draws nothing; do the 5 gestures, then close";
const window_w = 900;
const window_h = 600;

/// Enough for the longest line format above with a long device name.
const line_buf_len = 512;

/// Terminal + file sink. The terminal is unconditional; the file is best-effort, because
/// losing the file must not cost the user their gestures.
const Sink = struct {
    file: ?std.fs.File,

    /// Create (truncating) the log file, so a second run never appends to a stale one.
    /// Any failure is logged with its cause and leaves a terminal-only sink.
    fn open() Sink {
        std.fs.cwd().makePath(log_dir) catch |err| {
            probe_log.err(
                "cannot create the probe log directory '{s}' ({s}); recording to the terminal only — copy the output by hand",
                .{ log_dir, @errorName(err) },
            );
            return .{ .file = null };
        };
        const file = std.fs.cwd().createFile(log_path, .{ .truncate = true }) catch |err| {
            probe_log.err(
                "cannot create the probe log '{s}' ({s}); recording to the terminal only — copy the output by hand",
                .{ log_path, @errorName(err) },
            );
            return .{ .file = null };
        };
        return .{ .file = file };
    }

    fn close(self: *Sink) void {
        if (self.file) |file| {
            file.close();
            self.file = null;
        }
    }

    /// Write one line to the terminal and to the file. `File.writeAll` is UNBUFFERED, so
    /// each line reaches the OS before the next event is read — the user quits by closing
    /// the window, and a buffered tail would be the part we most wanted.
    fn write(self: *Sink, text: []const u8) void {
        probe_log.info("{s}", .{text});
        const file = self.file orelse return;
        file.writeAll(text) catch |err| return self.dropFile(err);
        file.writeAll("\n") catch |err| return self.dropFile(err);
    }

    /// A write failure is reported once, then the file is given up: the terminal keeps
    /// recording rather than the probe drowning in identical errors.
    fn dropFile(self: *Sink, err: anyerror) void {
        probe_log.err(
            "writing the probe log '{s}' failed ({s}); recording to the terminal only from here",
            .{ log_path, @errorName(err) },
        );
        self.close();
    }

    /// Emit an already-formatted line, reporting a formatting failure instead of hiding it.
    /// One unformattable line must not end the run the user is in the middle of.
    fn emit(self: *Sink, formatted: anyerror![]u8) void {
        const text = formatted catch |err| {
            probe_log.err("could not format a probe line ({s}); it is missing from the log", .{@errorName(err)});
            return;
        };
        self.write(text);
    }
};

pub fn main() !void {
    var sink = Sink.open();
    defer sink.close();

    // The instructions go into the log as its header too, so the log records what the
    // user was asked to do alongside what they did.
    var banner_lines = std.mem.splitScalar(u8, probe_fmt.usage_banner, '\n');
    while (banner_lines.next()) |line| sink.write(line);

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        probe_log.err("SDL_Init(SDL_INIT_VIDEO) failed: {s}", .{std.mem.span(c.SDL_GetError())});
        return error.SdlInitFailed;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(window_title, window_w, window_h, 0) orelse {
        probe_log.err("SDL_CreateWindow failed: {s}", .{std.mem.span(c.SDL_GetError())});
        return error.SdlCreateWindowFailed;
    };
    defer c.SDL_DestroyWindow(window);

    recordDevices(&sink);

    var event: c.SDL_Event = undefined;
    var recorded: usize = 0;
    var running = true;
    while (running) {
        // Blocking wait: a probe that spins would heat the machine it is borrowing.
        if (!c.SDL_WaitEvent(&event)) {
            probe_log.err("SDL_WaitEvent failed: {s}", .{std.mem.span(c.SDL_GetError())});
            return error.SdlWaitEventFailed;
        }
        switch (event.type) {
            c.SDL_EVENT_QUIT => running = false,
            c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => running = false,
            c.SDL_EVENT_KEY_DOWN => {
                if (event.key.scancode == c.SDL_SCANCODE_ESCAPE) running = false;
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                var buf: [line_buf_len]u8 = undefined;
                sink.emit(probe_fmt.wheelLine(&buf, .{
                    .which = event.wheel.which,
                    .x = event.wheel.x,
                    .y = event.wheel.y,
                    .integer_x = event.wheel.integer_x,
                    .integer_y = event.wheel.integer_y,
                    .direction = probe_fmt.wheelDirectionName(@intCast(event.wheel.direction)),
                    .mouse_x = event.wheel.mouse_x,
                    .mouse_y = event.wheel.mouse_y,
                    .mouse_name = mouseName(event.wheel.which),
                }));
                recorded += 1;
            },
            c.SDL_EVENT_PINCH_BEGIN, c.SDL_EVENT_PINCH_UPDATE, c.SDL_EVENT_PINCH_END => {
                var buf: [line_buf_len]u8 = undefined;
                sink.emit(probe_fmt.pinchLine(&buf, .{
                    .kind = switch (event.type) {
                        c.SDL_EVENT_PINCH_BEGIN => .begin,
                        c.SDL_EVENT_PINCH_UPDATE => .update,
                        else => .end,
                    },
                    .scale = event.pinch.scale,
                    .window_id = event.pinch.windowID,
                    .timestamp_ns = event.pinch.timestamp,
                }));
                recorded += 1;
            },
            c.SDL_EVENT_FINGER_DOWN, c.SDL_EVENT_FINGER_UP, c.SDL_EVENT_FINGER_MOTION => {
                var buf: [line_buf_len]u8 = undefined;
                sink.emit(probe_fmt.fingerLine(&buf, .{
                    .kind = switch (event.type) {
                        c.SDL_EVENT_FINGER_DOWN => .down,
                        c.SDL_EVENT_FINGER_UP => .up,
                        else => .motion,
                    },
                    .touch_id = event.tfinger.touchID,
                    .finger_id = event.tfinger.fingerID,
                    .x = event.tfinger.x,
                    .y = event.tfinger.y,
                    .dx = event.tfinger.dx,
                    .dy = event.tfinger.dy,
                    .device_type = probe_fmt.touchDeviceTypeName(@intCast(c.SDL_GetTouchDeviceType(event.tfinger.touchID))),
                }));
                recorded += 1;
            },
            else => {},
        }
    }

    var summary_buf: [line_buf_len]u8 = undefined;
    sink.emit(probe_fmt.finishedLine(&summary_buf, recorded, log_path));
}

/// `SDL_GetMouseNameForID`, as an optional slice. An empty name is reported as absent so
/// the log never carries a meaningless `name=""`.
fn mouseName(id: c.SDL_MouseID) ?[]const u8 {
    const name = c.SDL_GetMouseNameForID(id);
    if (name == null or name[0] == 0) return null;
    return std.mem.span(name);
}

/// Record, once at startup, the SDL runtime version and every mouse and touch device SDL
/// knows about. Which trackpad is which `SDL_MouseID` is the fact that decides whether the
/// wheel-vs-swipe question can be answered from `which` alone.
fn recordDevices(sink: *Sink) void {
    var buf: [line_buf_len]u8 = undefined;
    sink.emit(probe_fmt.versionLine(&buf, @intCast(c.SDL_GetVersion())));

    var mouse_count: c_int = 0;
    const mice = c.SDL_GetMice(&mouse_count);
    if (mice == null) {
        probe_log.err("SDL_GetMice failed: {s}; no mouse list in the log", .{std.mem.span(c.SDL_GetError())});
    } else {
        defer c.SDL_free(@ptrCast(mice));
        const n: usize = @intCast(mouse_count);
        sink.emit(probe_fmt.countLine(&buf, .mouse, n));
        for (0..n) |i| sink.emit(probe_fmt.mouseLine(&buf, i, mice[i], mouseName(mice[i])));
    }

    var touch_count: c_int = 0;
    const touch_devices = c.SDL_GetTouchDevices(&touch_count);
    if (touch_devices == null) {
        probe_log.err("SDL_GetTouchDevices failed: {s}; no touch device list in the log", .{std.mem.span(c.SDL_GetError())});
    } else {
        defer c.SDL_free(@ptrCast(touch_devices));
        const n: usize = @intCast(touch_count);
        sink.emit(probe_fmt.countLine(&buf, .touch, n));
        for (0..n) |i| {
            const id = touch_devices[i];
            const type_name = probe_fmt.touchDeviceTypeName(@intCast(c.SDL_GetTouchDeviceType(id)));
            sink.emit(probe_fmt.touchDeviceLine(&buf, i, id, type_name));
        }
    }
}
