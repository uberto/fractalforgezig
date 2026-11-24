//! Main-thread UI and native picker handoff. The worker holds its own job and
//! never reads editor state or calls SDL or ImGui.
const std = @import("std");
const c = @import("../c.zig").c;
const ig = @import("../cimgui.zig");
const viewport = @import("../fractal/viewport.zig");
const render = @import("../fractal/export_render.zig");
const image_export = @import("../fractal/image_export.zig");
const flow = @import("export_flow.zig");
const dialog = @import("dialog.zig");
const log = std.log.scoped(.export_ui);

const Phase = enum { closed, dimensions, picker, overwrite, active, result };

pub const Panel = struct {
    phase: Phase = .closed,
    width: [16]u8 = @splat(0),
    height: [16]u8 = @splat(0),
    capture: flow.Capture = undefined,
    destination: flow.Destination = undefined,
    message: [std.fs.max_path_bytes + 64]u8 = undefined,
    message_len: usize = 0,
    hovered: bool = false,
    worker: image_export.Worker = .{},

    pub fn available(self: *const Panel) bool {
        return self.phase == .closed or self.phase == .result;
    }

    pub fn pickerOpen(self: *const Panel) bool {
        return self.phase == .picker;
    }

    pub fn needsPoll(self: *const Panel) bool {
        return self.phase == .active;
    }

    pub fn open(self: *Panel, rect: viewport.ImageRect) void {
        const size = flow.defaults(rect) catch |err| {
            self.fail("dimensions", "", err, .result);
            return;
        };
        _ = std.fmt.bufPrintZ(&self.width, "{d}", .{size.width}) catch unreachable;
        _ = std.fmt.bufPrintZ(&self.height, "{d}", .{size.height}) catch unreachable;
        self.message_len = 0;
        self.phase = .dimensions;
    }

    pub fn poll(self: *Panel) void {
        switch (self.phase) {
            .picker => {
                const result = dialog.takeExportPng() orelse return;
                switch (result.outcome) {
                    .waiting => unreachable,
                    .cancelled => self.cancelled("PNG destination selection canceled."),
                    .failed => self.fail("picker", "", error.PickerFailed, .result),
                    .too_long => self.fail("picker", "", error.PathTooLong, .result),
                    .chosen => self.choose(result.path),
                }
            },
            .active => switch (self.worker.poll()) {
                .succeeded => {
                    self.worker.join();
                    self.phase = .result;
                    const summary = flow.successMessage(&self.message, self.destination.path(), self.capture.size) catch unreachable;
                    self.message_len = summary.len;
                    log.info("{s} path={s}", .{ summary, self.destination.path() });
                },
                .cancelled => {
                    self.worker.join();
                    self.cancelled("PNG export canceled.");
                },
                .failed => |err| {
                    self.worker.join();
                    self.fail("worker", self.destination.path(), err, .result);
                },
                else => {},
            },
            else => {},
        }
    }

    fn choose(self: *Panel, path: []const u8) void {
        self.destination = flow.Destination.init(path) catch |err| {
            self.fail("destination", path, err, .result);
            return;
        };
        const final_path = self.destination.path();
        // SDL does not report whether the platform picker confirmed replacement.
        // Ask about the exact final path whenever it already exists.
        std.fs.accessAbsolute(final_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                self.start(null);
            } else {
                log.warn("PNG destination check: path={s} error={s}", .{ final_path, @errorName(err) });
                self.fail("destination", final_path, error.CheckDestinationFailed, .result);
            }
            return;
        };
        self.phase = .overwrite;
    }

    fn start(self: *Panel, approved: ?[]const u8) void {
        const path = self.destination.path();
        self.capture.start(&self.worker, &self.destination, approved) catch |err| {
            self.fail("start", path, err, .result);
            return;
        };
        self.phase = .active;
    }

    fn fail(self: *Panel, stage: []const u8, path: []const u8, err: anyerror, phase: Phase) void {
        self.setMessage(flow.failureMessage(err));
        self.phase = phase;
        log.err("PNG export: stage={s} path={s} error={s} action={s}", .{ stage, path, @errorName(err), self.message[0..self.message_len] });
    }

    fn cancelled(self: *Panel, message: []const u8) void {
        self.setMessage(message);
        self.phase = .result;
        log.info("{s}", .{message});
    }

    fn setMessage(self: *Panel, message: []const u8) void {
        @memcpy(self.message[0..message.len], message);
        self.message_len = message.len;
    }

    pub const Action = enum { none, pick, replace, cancel_worker };

    pub fn draw(self: *Panel, file_dialog_available: bool) Action {
        self.hovered = false;
        if (self.phase == .closed or self.phase == .picker) return .none;
        var show = true;
        const visible = ig.igBegin("Export PNG", if (self.phase == .active) null else &show, ig.window_flags_no_collapse | ig.window_flags_always_auto_resize | ig.window_flags_no_saved_settings);
        defer ig.igEnd();
        if (!show) {
            self.phase = .closed;
            return .none;
        }
        if (!visible) return .none;
        self.hovered = ig.igIsWindowHovered(0);
        ig.igPushTextWrapPos(420);
        defer ig.igPopTextWrapPos();

        switch (self.phase) {
            .dimensions => {
                _ = ig.igInputText("Width (px)", &self.width, self.width.len, 0, null, null);
                _ = ig.igInputText("Height (px)", &self.height, self.height.len, 0, null, null);
                drawText(flow.limits);
                if (self.message_len > 0 and !std.mem.eql(u8, self.message[0..self.message_len], flow.limits))
                    drawText(self.message[0..self.message_len]);
                ig.igBeginDisabled(!file_dialog_available);
                const pick = ig.igSmallButton("Choose destination…");
                ig.igEndDisabled();
                if (pick) return .pick;
                ig.igSameLine(0, 8);
                if (ig.igSmallButton("Cancel")) self.phase = .closed;
            },
            .overwrite => {
                drawText("Replace this PNG?");
                drawText(self.destination.path());
                if (ig.igSmallButton("Replace")) return .replace;
                ig.igSameLine(0, 8);
                if (ig.igSmallButton("Cancel")) self.cancelled("PNG replacement canceled.");
            },
            .active => {
                const status = self.worker.poll();
                switch (status) {
                    .running, .cancelling => |rows| {
                        var buf: [64]u8 = undefined;
                        const label = std.fmt.bufPrintZ(&buf, "{d} / {d} rows", .{ rows, self.capture.size.height }) catch unreachable;
                        ig.igProgressBar(@as(f32, @floatFromInt(rows)) / @as(f32, @floatFromInt(self.capture.size.height)), .{ .x = 220, .y = 0 }, label.ptr);
                        if (status == .cancelling) drawText("Canceling export…");
                        if (status == .running and ig.igSmallButton("Cancel export")) return .cancel_worker;
                    },
                    .publishing => drawText("Publishing PNG…"),
                    else => {},
                }
            },
            .result => {
                drawText(self.message[0..self.message_len]);
                if (ig.igSmallButton("Close")) self.phase = .closed;
            },
            .closed, .picker => unreachable,
        }
        return .none;
    }

    pub fn apply(self: *Panel, action: Action, window: *c.SDL_Window, rect: viewport.ImageRect, displayed: ?render.Snapshot) void {
        switch (action) {
            .none => {},
            .pick => {
                self.capture = flow.Capture.commit(std.mem.sliceTo(&self.width, 0), std.mem.sliceTo(&self.height, 0), rect, displayed) catch |err| {
                    self.fail("capture", "", err, .dimensions);
                    return;
                };
                self.phase = .picker;
                dialog.showExportPng(window);
            },
            .replace => self.start(self.destination.path()),
            .cancel_worker => _ = self.worker.cancel(),
        }
    }
};

fn drawText(value: []const u8) void {
    ig.igTextUnformatted(@ptrCast(value.ptr), @ptrCast(value.ptr + value.len));
}
