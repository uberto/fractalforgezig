const std = @import("std");
const testing = std.testing;
const images = @import("fractal/image_export.zig");
const render = @import("fractal/export_render.zig");
const viewport = @import("fractal/viewport.zig");
const gradient = @import("fractal/gradient.zig");
const colorpass = @import("fractal/colorpass.zig");
const iterbuf = @import("fractal/iterbuf.zig");
const perturb = @import("fractal/perturb.zig");

fn snapshot() render.Snapshot {
    var lut: [gradient.lut_size]gradient.Rgba8 = undefined;
    gradient.bakeLut(gradient.Gradient.fromStops(&.{
        .{ .pos = 0, .color = .{ 9, 46, 17, 255 } },
        .{ .pos = 1, .color = .{ 250, 220, 180, 255 } },
    }), &lut);
    return .{
        .view = viewport.SquareView.defaultView(),
        .source = .{ .width = 40, .height = 20 },
        .lut = lut,
        .max_iter = 153,
        .params = .{ .mode = .cyclic, .period = 13, .banded = true },
        .interior = .{ 11, 22, 33, 255 },
    };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i32, a) + b - c;
    const da = @abs(p - a);
    const db = @abs(p - b);
    const dc = @abs(p - c);
    if (da <= db and da <= dc) return a;
    if (db <= dc) return b;
    return c;
}

// Independent, small fixture reader for 8-bit noninterlaced RGB/RGBA output.
fn readPng(dir: std.fs.Dir, comptime w: usize, comptime h: usize) ![w * h * 4]u8 {
    const encoded = try dir.readFileAlloc(testing.allocator, "image.png", 100_000);
    defer testing.allocator.free(encoded);
    try testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", encoded[0..8]);
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(testing.allocator);
    var channels: usize = 0;
    var end = false;
    var cursor: usize = 8;
    while (cursor < encoded.len) {
        const len = std.mem.readInt(u32, encoded[cursor..][0..4], .big);
        const chunk = encoded[cursor + 4 ..][0 .. 4 + len];
        const payload = chunk[4..];
        cursor += len + 8;
        try testing.expectEqual(std.hash.Crc32.hash(chunk), std.mem.readInt(u32, encoded[cursor..][0..4], .big));
        cursor += 4;
        if (std.mem.eql(u8, chunk[0..4], "IHDR")) {
            try testing.expectEqual(@as(u32, w), std.mem.readInt(u32, payload[0..4], .big));
            try testing.expectEqual(@as(u32, h), std.mem.readInt(u32, payload[4..8], .big));
            try testing.expectEqual(@as(u8, 8), payload[8]);
            channels = switch (payload[9]) {
                2 => 3,
                6 => 4,
                else => return error.UnexpectedColorType,
            };
            try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, payload[10..13]);
        } else if (std.mem.eql(u8, chunk[0..4], "IDAT")) {
            try idat.appendSlice(testing.allocator, payload);
        } else if (std.mem.eql(u8, chunk[0..4], "IEND")) {
            end = true;
        }
    }
    try testing.expect(end and channels > 0);
    var compressed = std.Io.Reader.fixed(idat.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflater = std.compress.flate.Decompress.init(&compressed, .zlib, &window);
    var rows: [h * (1 + 4 * w)]u8 = undefined;
    const stride = 1 + w * channels;
    try inflater.reader.readSliceAll(rows[0 .. h * stride]);
    try testing.expectError(error.EndOfStream, inflater.reader.takeByte());
    var result: [w * h * 4]u8 = undefined;
    for (0..h) |y| {
        const row = rows[y * stride ..][0..stride];
        for (1..stride) |i| {
            const a: u8 = if (i > channels) row[i - channels] else 0;
            const b: u8 = if (y > 0) rows[(y - 1) * stride + i] else 0;
            const c: u8 = if (y > 0 and i > channels) rows[(y - 1) * stride + i - channels] else 0;
            row[i] +%= switch (row[0]) {
                0 => 0,
                1 => a,
                2 => b,
                3 => @intCast((@as(u16, a) + b) / 2),
                4 => paeth(a, b, c),
                else => return error.UnexpectedFilter,
            };
        }
        for (0..w) |x| {
            const out = result[(y * w + x) * 4 ..][0..4];
            out[0..3].* = row[1 + x * channels ..][0..3].*;
            out[3] = if (channels == 4) row[4 + x * channels] else 255;
        }
    }
    return result;
}

test "exported file decodes at requested dimensions with opaque pixels" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try images.save(testing.allocator, tmp.dir, "image.png", snapshot(), .{ .width = 7, .height = 11 }, null);
    const rgba = try readPng(tmp.dir, 7, 11);
    for (0..77) |i| try testing.expectEqual(@as(u8, 255), rgba[i * 4 + 3]);
}

test "invalid dimensions are rejected" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "image.png", .data = "previous bytes" });
    var memory: [0]u8 = .{};
    var empty = std.heap.FixedBufferAllocator.init(&memory);
    for ([_]images.Size{
        .{ .width = 0, .height = 1 },
        .{ .width = 1, .height = 0 },
        .{ .width = 16_385, .height = 1 },
        .{ .width = 1, .height = 16_385 },
        .{ .width = 10_001, .height = 10_000 },
    }) |size| {
        try testing.expectError(error.InvalidDimensions, images.save(empty.allocator(), tmp.dir, "image.png", snapshot(), size, null));
        var old: [64]u8 = undefined;
        try testing.expectEqualStrings("previous bytes", try tmp.dir.readFile("image.png", &old));
        try expectSoleEntry(tmp.dir, "image.png");
    }
    try (images.Size{ .width = 10_000, .height = 10_000 }).validate();
}

test "export mapping preserves center, diagonal and orientation" {
    var scene = snapshot();
    scene.view = try viewport.SquareView.fromCenterSide(.{ .re = -0.75, .im = 0.125 }, 3.5);
    // The rendered 40 × 20 source spans 7 × 3.5 complex units.
    const diagonal: f64 = @sqrt(7.0 * 7.0 + 3.5 * 3.5);
    for ([_]images.Size{
        .{ .width = 120, .height = 120 },
        .{ .width = 120, .height = 40 },
        .{ .width = 40, .height = 120 },
        .{ .width = 40, .height = 20 },
        .{ .width = 80, .height = 40 },
    }) |size| {
        const output = try scene.viewport(size);
        try testing.expectEqual(size.width, output.width);
        try testing.expectEqual(size.height, output.height);
        const w: f64 = @floatFromInt(size.width);
        const h: f64 = @floatFromInt(size.height);
        const expected_scale = diagonal / @sqrt(w * w + h * h);
        const middle = output.pixelToComplex(w / 2, h / 2);
        try testing.expectEqual(@as(f64, -0.75), middle.re);
        try testing.expectEqual(@as(f64, 0.125), middle.im);
        const first = output.pixelToComplex(0.5, 0.5);
        const last = output.pixelToComplex(w - 0.5, h - 0.5);
        try testing.expectApproxEqAbs(middle.re - (w - 1) * expected_scale / 2, first.re, 1e-12);
        try testing.expectApproxEqAbs(middle.im + (h - 1) * expected_scale / 2, first.im, 1e-12);
        try testing.expectApproxEqAbs(middle.re + (w - 1) * expected_scale / 2, last.re, 1e-12);
        try testing.expectApproxEqAbs(middle.im - (h - 1) * expected_scale / 2, last.im, 1e-12);
    }
}

test "exported shallow pixels match current color settings at new samples" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var scene = snapshot();
    scene.view = try viewport.SquareView.fromCenterSide(.{ .re = -0.75, .im = 0.25 }, 3.5);
    try images.save(testing.allocator, tmp.dir, "image.png", scene, .{ .width = 23, .height = 17 }, null);
    const expected_view: viewport.Viewport = .{
        .center_re = -0.75,
        .center_im = 0.25,
        .scale = @sqrt(7.0 * 7.0 + 3.5 * 3.5) / @sqrt(23.0 * 23.0 + 17.0 * 17.0),
        .width = 23,
        .height = 17,
    };
    var smooth: [23 * 17]f32 = undefined;
    var expected: [smooth.len * 4]u8 = undefined;
    try iterbuf.iterateInto(&smooth, expected_view, scene.max_iter);
    try colorpass.colorInto(&expected, &smooth, &scene.lut, scene.max_iter, scene.params, scene.interior);
    const actual = try readPng(tmp.dir, 23, 17);
    try testing.expectEqualSlices(u8, &expected, &actual);
}

test "exported deep pixels retain the precision of the selected center" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var scene = snapshot();
    const center: viewport.ComplexHi = .{
        .re = -0.743643887037158704752191506114774,
        .im = 0.131825904205311970493132056385139,
    };
    scene.view = try viewport.SquareView.fromCenterSide(center, 1e-30);
    scene.source = .{ .width = 8, .height = 8 };
    scene.max_iter = 65_536;
    scene.params = .{ .mode = .cyclic, .period = 10.0 };
    var orbit = try perturb.ReferenceOrbit.compute(testing.allocator, center, scene.max_iter);
    defer orbit.deinit(testing.allocator);
    // The source spans 1e-30 along both axes. Its diagonal is 1e-30 × sqrt(2).
    const expected_view: viewport.Viewport = .{
        .center_re = @floatCast(center.re),
        .center_im = @floatCast(center.im),
        .scale = 1e-30 * @sqrt(2.0) / @sqrt(11.0 * 11.0 + 9.0 * 9.0),
        .width = 11,
        .height = 9,
    };
    var smooth: [11 * 9]f32 = undefined;
    var expected: [11 * 9 * 4]u8 = undefined;
    try iterbuf.iterateDeepBandInto(&smooth, expected_view, scene.max_iter, 0, 9, &orbit);
    try colorpass.colorInto(&expected, &smooth, &scene.lut, scene.max_iter, scene.params, scene.interior);
    try images.save(testing.allocator, tmp.dir, "image.png", scene, .{ .width = 11, .height = 9 }, null);
    const actual = try readPng(tmp.dir, 11, 9);
    try testing.expectEqualSlices(u8, &expected, &actual);
    var varies = false;
    for (1..smooth.len) |i| varies = varies or !std.mem.eql(u8, actual[0..4], actual[i * 4 ..][0..4]);
    try testing.expect(varies);
}

fn stopAfterRows(context: ?*anyopaque, rows: u32) bool {
    const seen: *u32 = @ptrCast(@alignCast(context.?));
    seen.* = rows;
    return true;
}

fn expectSoleEntry(dir: std.fs.Dir, expected: []const u8) !void {
    var scan = dir.iterate();
    const entry = (try scan.next()) orelse return error.MissingEntry;
    try testing.expectEqualStrings(expected, entry.name);
    try testing.expect((try scan.next()) == null);
}

test "cancel after progress preserves the old file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "image.png", .data = "previous bytes" });
    var seen: u32 = 0;
    try testing.expectError(error.Cancelled, images.save(testing.allocator, tmp.dir, "image.png", snapshot(), .{ .width = 17, .height = 1024 }, .{ .context = &seen, .afterRows = stopAfterRows, .overwrite_basename = "image.png" }));
    try testing.expect(seen > 0 and seen < 1024);
    var old: [64]u8 = undefined;
    try testing.expectEqualStrings("previous bytes", try tmp.dir.readFile("image.png", &old));
    try expectSoleEntry(tmp.dir, "image.png");
}

const PublicationBlocker = struct {
    dir: std.fs.Dir,
    created: bool = false,

    fn afterRows(context: ?*anyopaque, rows: u32) bool {
        const self: *PublicationBlocker = @ptrCast(@alignCast(context.?));
        if (rows == 3) {
            self.dir.makeDir("image.png") catch return true;
            self.created = true;
        }
        return false;
    }
};

test "publish failure removes the temporary file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var blocker = PublicationBlocker{ .dir = tmp.dir };
    try testing.expectError(error.PublishFailed, images.save(testing.allocator, tmp.dir, "image.png", snapshot(), .{ .width = 5, .height = 3 }, .{ .context = &blocker, .afterRows = PublicationBlocker.afterRows }));
    try testing.expect(blocker.created);
    try expectSoleEntry(tmp.dir, "image.png");
    var directory = try tmp.dir.openDir("image.png", .{});
    defer directory.close();
}

fn recordRows(context: ?*anyopaque, rows: u32) bool {
    const seen: *u32 = @ptrCast(@alignCast(context.?));
    seen.* = rows;
    return false;
}

test "exporting rows does not allocate the whole image" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const memory = try testing.allocator.alloc(u8, 4 * 1024 * 1024);
    defer testing.allocator.free(memory);
    var bounded = std.heap.FixedBufferAllocator.init(memory);
    var seen: u32 = 0;
    var scene = snapshot();
    scene.max_iter = 4;
    try images.save(bounded.allocator(), tmp.dir, "image.png", scene, .{ .width = 1024, .height = 4096 }, .{ .context = &seen, .afterRows = recordRows });
    try testing.expectEqual(@as(u32, 4096), seen);
    try expectSoleEntry(tmp.dir, "image.png");
    var file = try tmp.dir.openFile("image.png", .{});
    defer file.close();
    var signature: [8]u8 = undefined;
    try testing.expectEqual(signature.len, try file.readAll(&signature));
    try testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", &signature);
}
