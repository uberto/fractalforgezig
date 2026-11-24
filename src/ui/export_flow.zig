const std = @import("std");
const render = @import("../fractal/export_render.zig");
const viewport = @import("../fractal/viewport.zig");
const image_export = @import("../fractal/image_export.zig");

test "dimensions are decimal integers and validated before capture" {
    try std.testing.expectEqual(render.Size{ .width = 7, .height = 11 }, try parseSize("7", "11"));
    for ([_][2][]const u8{ .{ "0", "11" }, .{ "16385", "1" }, .{ "10001", "10000" }, .{ "1e2", "11" }, .{ "+7", "11" } }) |pair| {
        try std.testing.expectError(error.InvalidDimensions, parseSize(pair[0], pair[1]));
    }
}

test "capture uses rendered spans, while defaults use fitted dimensions" {
    const scene = testScene();
    const rect = viewport.fitImageRect(0, 0, 3, 3, 7, 4);
    try std.testing.expectEqual(render.Size{ .width = 3, .height = 2 }, try defaults(rect));
    const captured = try Capture.commit("5", "5", rect, scene);
    const scale = (try captured.scene.viewport(captured.size)).scale;
    try std.testing.expectApproxEqAbs(scene.view.rectViewport(7, 4).scale * @sqrt(@as(f64, 65)) / @sqrt(@as(f64, 50)), scale, 1e-14);
}

test "failed uploads preserve the old scene and incoherent uploads clear it" {
    const first = testScene();
    var displayed: Displayed = .{ .scene = first };
    displayed.uploaded(error.TextureUploadFailed);
    try std.testing.expectEqual(first.view, displayed.scene.?.view);
    displayed.uploaded(null);
    try std.testing.expectEqual(@as(?render.Snapshot, null), displayed.scene);
}

test "an empty rectangle or unavailable displayed scene cannot dispatch" {
    const empty = viewport.fitImageRect(0, 0, 0, 0, 7, 4);
    try std.testing.expectError(error.NoDisplayedScene, Capture.commit("5", "5", empty, testScene()));
    const rect = viewport.fitImageRect(0, 0, 7, 4, 7, 4);
    try std.testing.expectError(error.NoDisplayedScene, Capture.commit("5", "5", rect, null));
}

test "picker distinguishes cancel failure selection and overlong paths and resets" {
    var pending: Picker = .{};
    for ([_]?[]const u8{ null, "", "/tmp/image", &([_]u8{'a'} ** std.fs.max_path_bytes) }, [_]Outcome{ .failed, .cancelled, .chosen, .too_long }) |path, outcome| {
        pending.complete(path);
        try std.testing.expectEqual(outcome, pending.take().?);
        try std.testing.expectEqual(@as(?Outcome, null), pending.take());
    }
}

test "normalization preserves case and exact final path authorization" {
    const upper = try Destination.init("/tmp/demo.PNG");
    try std.testing.expectEqualStrings("/tmp/demo.PNG", upper.path());
    const normalized = try Destination.init("/tmp/demo.jpg");
    try std.testing.expectEqualStrings("/tmp/demo.jpg.png", normalized.path());
    try std.testing.expect(normalized.approval("/tmp/demo.jpg") == null);
    try std.testing.expectEqualStrings(normalized.path(), normalized.approval(normalized.path()).?);
    try std.testing.expectError(error.PathTooLong, Destination.init("/" ++ "a" ** (std.fs.max_path_bytes - 3)));
}

test "idle export observes progress and completion with a bounded wait" {
    try std.testing.expectEqual(@as(i32, -1), waitMs(false, false));
    try std.testing.expectEqual(@as(i32, 50), waitMs(false, true));
    try std.testing.expectEqual(@as(i32, 16), waitMs(true, true));
}

test "publish failures and successful exports identify user action and result" {
    try std.testing.expectEqualStrings("Could not publish PNG. Check permissions or choose a different filename.", failureMessage(error.PublishFailed));
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Exported demo.png (7 × 11)", try successMessage(&buf, "/tmp/demo.png", .{ .width = 7, .height = 11 }));
}

fn testScene() render.Snapshot {
    return .{
        .view = viewport.SquareView.fromCenterSide(.{ .re = -0.5, .im = 0.25 }, 3) catch unreachable,
        .source = .{ .width = 7, .height = 4 },
        .lut = @splat(.{ 1, 2, 3, 255 }),
        .params = .{},
        .interior = .{ 0, 0, 0, 255 },
        .max_iter = 20,
    };
}

pub const limits = "Use whole numbers from 1 to 16,384, up to 100,000,000 pixels total.";

pub fn parseSize(width: []const u8, height: []const u8) error{InvalidDimensions}!render.Size {
    const size: render.Size = .{ .width = try parseAxis(width), .height = try parseAxis(height) };
    try size.validate();
    return size;
}

fn parseAxis(value: []const u8) error{InvalidDimensions}!u32 {
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidDimensions;
    }
    return std.fmt.parseInt(u32, value, 10) catch error.InvalidDimensions;
}

pub fn defaults(rect: viewport.ImageRect) error{NoDisplayedScene}!render.Size {
    if (rect.w == 0 or rect.h == 0) return error.NoDisplayedScene;
    return .{ .width = rect.w, .height = rect.h };
}

/// Metadata travels with the uploaded texture. Failed uploads preserve the
/// previous image and successful uploads without coherent geometry clear it.
pub const Displayed = struct {
    scene: ?render.Snapshot,

    pub fn uploaded(self: *Displayed, result: anyerror!?render.Snapshot) void {
        self.scene = result catch return;
    }
};

pub const Capture = struct {
    size: render.Size,
    scene: render.Snapshot,

    pub fn commit(width: []const u8, height: []const u8, rect: viewport.ImageRect, displayed: ?render.Snapshot) !Capture {
        const size = try parseSize(width, height);
        _ = try defaults(rect);
        const scene = displayed orelse return error.NoDisplayedScene;
        _ = try scene.viewport(size);
        return .{ .size = size, .scene = scene };
    }

    pub fn start(self: Capture, worker: *image_export.Worker, destination: *const Destination, approved: ?[]const u8) !void {
        try worker.start(destination.path(), if (approved) |path| destination.approval(path) else null, self.scene, self.size);
    }
};

pub const Outcome = enum(u8) { waiting, failed, cancelled, chosen, too_long };

/// One callback publishes its copied payload with release ordering. The main thread
/// consumes it before another picker is opened.
pub const Picker = struct {
    outcome: std.atomic.Value(Outcome) = .init(.waiting),
    buf: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,

    pub fn complete(self: *Picker, selection: ?[]const u8) void {
        const outcome: Outcome = if (selection) |path| outcome: {
            if (path.len == 0) break :outcome .cancelled;
            if (path.len >= self.buf.len) break :outcome .too_long;
            @memcpy(self.buf[0..path.len], path);
            self.len = path.len;
            break :outcome .chosen;
        } else .failed;
        self.outcome.store(outcome, .release);
    }

    pub fn take(self: *Picker) ?Outcome {
        const outcome = self.outcome.load(.acquire);
        if (outcome == .waiting) return null;
        self.outcome.store(.waiting, .monotonic);
        return outcome;
    }
};

pub const Destination = struct {
    buf: [std.fs.max_path_bytes]u8 = undefined,
    len: usize,

    pub fn init(selected: []const u8) !Destination {
        if (!std.fs.path.isAbsolute(selected) or std.mem.endsWith(u8, selected, "/") or
            std.mem.indexOfScalar(u8, selected, 0) != null) return error.InvalidDestination;
        const has_suffix = selected.len >= 4 and std.ascii.eqlIgnoreCase(selected[selected.len - 4 ..], ".png");
        const suffix = if (has_suffix) "" else ".png";
        var result: Destination = .{ .len = selected.len + suffix.len };
        if (result.len >= result.buf.len) return error.PathTooLong;
        @memcpy(result.buf[0..selected.len], selected);
        @memcpy(result.buf[selected.len..result.len], suffix);
        return result;
    }

    pub fn path(self: *const Destination) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn approval(self: *const Destination, approved: []const u8) ?[]const u8 {
        return if (std.mem.eql(u8, self.path(), approved)) self.path() else null;
    }
};

pub fn waitMs(owes_live_or_dialog: bool, owes_export: bool) i32 {
    if (owes_live_or_dialog) return 16;
    return if (owes_export) 50 else -1;
}

pub fn failureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidDimensions => limits,
        error.NoDisplayedScene, error.InvalidSnapshot => "No coherent image to export. Wait for the viewport to finish rendering and retry.",
        error.PathTooLong => "The destination path is too long. Choose a shorter folder or filename.",
        error.InvalidDestination => "Choose an absolute path with a valid PNG filename.",
        error.PickerFailed => "Could not open the PNG save dialog. Reopen File → Export PNG and retry.",
        error.CheckDestinationFailed => "Could not check the PNG destination. Check folder permissions or choose another folder.",
        error.RenderFailed => "Could not render PNG pixels. Try smaller dimensions or fewer iterations.",
        error.OpenDirectoryFailed => "Could not open the destination folder. Choose an accessible folder.",
        error.CreateTemporaryFailed => "Could not create a temporary PNG. Check folder permissions and free space.",
        error.WriteFailed => "Could not write the temporary PNG. Check free space and disk access.",
        error.FlushFailed => "Could not finish writing the temporary PNG. Check free space and disk access.",
        error.PublishFailed => "Could not publish PNG. Check permissions or choose a different filename.",
        else => "Could not start PNG export. Close other applications and retry.",
    };
}

pub fn successMessage(buf: []u8, path: []const u8, size: render.Size) ![]const u8 {
    return std.fmt.bufPrint(buf, "Exported {s} ({d} × {d})", .{ std.fs.path.basename(path), size.width, size.height });
}

test "worker uses the displayed scene frozen before a delayed picker completes" {
    const mandelbrot = @import("../fractal/mandelbrot.zig");
    const colorpass = @import("../fractal/colorpass.zig");
    var live = testScene();
    live.interior = .{ 19, 25, 29, 255 };
    const original = live;
    var displayed: Displayed = .{ .scene = original };
    // A same-frame edit has reached the engine, while draw still uses the old texture.
    live.view = try viewport.SquareView.fromCenterSide(.{ .re = 100, .im = 100 }, 3);
    const rect = viewport.fitImageRect(0, 0, 7, 4, 7, 4);
    const capture = try Capture.commit("7", "4", rect, displayed.scene);
    var picker: Picker = .{};

    // A palette edit arrives while the picker owns the capture.
    live.lut = @splat(.{ 254, 255, 254, 255 });
    live.interior = .{ 255, 254, 255, 255 };
    displayed.uploaded(live);
    try std.testing.expectEqual(@as(?Outcome, null), picker.take());

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory: [std.fs.max_path_bytes]u8 = undefined;
    var selected: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&selected, "{s}/poster", .{try temp.dir.realpath(".", &directory)});
    picker.complete(path);
    try std.testing.expectEqual(Outcome.chosen, picker.take().?);
    const destination = try Destination.init(picker.buf[0..picker.len]);
    var worker: image_export.Worker = .{};
    defer worker.shutdown();
    try capture.start(&worker, &destination, null);
    worker.join();
    try std.testing.expectEqual(image_export.Status.succeeded, worker.poll());

    var file: [1024]u8 = undefined;
    const png = try temp.dir.readFile("poster.png", &file);
    var idat: [512]u8 = undefined;
    var compressed = std.Io.Writer.fixed(&idat);
    var offset: usize = 8;
    while (offset < png.len) {
        const length = std.mem.readInt(u32, png[offset..][0..4], .big);
        if (std.mem.eql(u8, png[offset + 4 ..][0..4], "IDAT"))
            try compressed.writeAll(png[offset + 8 ..][0..length]);
        offset += length + 12;
    }
    var input = std.Io.Reader.fixed(compressed.buffered());
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decoder = std.compress.flate.Decompress.init(&input, .zlib, &window);

    const source = original.view.rectViewport(7, 4);
    for (0..4) |y| {
        var row: [22]u8 = undefined;
        try decoder.reader.readSliceAll(&row);
        try std.testing.expectEqual(@as(u8, 0), row[0]);
        for (0..7) |x| {
            const point = source.pixelToComplex(@as(f64, @floatFromInt(x)) + 0.5, @as(f64, @floatFromInt(y)) + 0.5);
            const smooth = mandelbrot.iterate(point.re, point.im, original.max_iter);
            var rgba: [4]u8 = undefined;
            try colorpass.colorInto(&rgba, &.{smooth}, &original.lut, original.max_iter, original.params, original.interior);
            try std.testing.expectEqualSlices(u8, rgba[0..3], row[1 + 3 * x ..][0..3]);
        }
    }
}
