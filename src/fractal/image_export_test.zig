const std = @import("std");
const images = @import("image_export.zig");
const render = @import("export_render.zig");
const viewport = @import("viewport.zig");
const gradient = @import("gradient.zig");
const testing = std.testing;
const name = "poster.png";
const old = "original content";
const size: images.Size = .{ .width = 2, .height = 3 };

fn snapshot() render.Snapshot {
    return .{
        .view = viewport.SquareView.defaultView(),
        .source = size,
        .lut = @splat(.{ 14, 27, 31, 255 }),
        .params = .{},
        .interior = .{ 14, 27, 31, 255 },
        .max_iter = 4,
    };
}

fn expectEntry(dir: std.fs.Dir, expected: []const u8) !void {
    var list = dir.iterate();
    try testing.expectEqualStrings(expected, (try list.next()).?.name);
    try testing.expectEqual(null, try list.next());
}

fn expectOld(dir: std.fs.Dir) !void {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(old, try dir.readFile(name, &buf));
    try expectEntry(dir, name);
}

fn expectPng(dir: std.fs.Dir) !void {
    var buf: [1024]u8 = undefined;
    const data = try dir.readFile(name, &buf);
    try testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", data[0..8]);
    var compressed: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&compressed);
    var cursor: usize = 8;
    while (cursor < data.len) {
        const len = std.mem.readInt(u32, data[cursor..][0..4], .big);
        const kind = data[cursor + 4 ..][0..4];
        if (std.mem.eql(u8, kind, "IDAT")) try stream.writeAll(data[cursor + 8 ..][0..len]);
        cursor += len + 12;
    }
    var reader = std.Io.Reader.fixed(stream.buffered());
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decoder = std.compress.flate.Decompress.init(&reader, .zlib, &window);
    var rows: [21]u8 = undefined;
    try decoder.reader.readSliceAll(&rows);
    try testing.expectEqualSlices(u8, &(.{ 0, 14, 27, 31, 14, 27, 31 } ** 3), &rows);
}

test "invalid dimensions take precedence over allocation and path access" {
    try testing.expectError(error.InvalidDimensions, images.save(testing.failing_allocator, undefined, "", snapshot(), .{ .width = 0, .height = 1 }, null));
}

test "matching basename permits decodable replacement" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = name, .data = old });
    try images.save(testing.allocator, tmp.dir, name, snapshot(), size, .{ .overwrite_basename = name });
    try expectPng(tmp.dir);
    try expectEntry(tmp.dir, name);
}

const LateArrival = struct {
    dir: std.fs.Dir,
    directory: bool,

    fn arrive(context: ?*anyopaque, rows: u32) bool {
        const self: *LateArrival = @ptrCast(@alignCast(context.?));
        if (rows != size.height) return false;
        if (self.directory) {
            self.dir.makeDir(name) catch unreachable;
        } else {
            self.dir.writeFile(.{ .sub_path = name, .data = old, .flags = .{ .exclusive = true } }) catch unreachable;
        }
        return false;
    }
};

test "an unauthorized file arriving during the final band survives publication" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arrival = LateArrival{ .dir = tmp.dir, .directory = false };
    try testing.expectError(error.PublishFailed, images.save(testing.allocator, tmp.dir, name, snapshot(), size, .{ .context = &arrival, .afterRows = LateArrival.arrive, .overwrite_basename = "other.png" }));
    try expectOld(tmp.dir);
}

test "even authorized publication fails and cleans up when the target becomes a directory" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arrival = LateArrival{ .dir = tmp.dir, .directory = true };
    try testing.expectError(error.PublishFailed, images.save(testing.allocator, tmp.dir, name, snapshot(), size, .{ .context = &arrival, .afterRows = LateArrival.arrive, .overwrite_basename = name }));
    var directory = try tmp.dir.openDir(name, .{});
    defer directory.close();
    try expectEntry(tmp.dir, name);
}

const Progress = struct {
    rows: u32 = 0,
    stop: bool = false,
    fn update(context: ?*anyopaque, rows: u32) bool {
        const self: *Progress = @ptrCast(@alignCast(context.?));
        self.rows = rows;
        return self.stop;
    }
};

test "cancel after real progress preserves destination and cleans up" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = name, .data = old });
    var progress: Progress = .{ .stop = true };
    try testing.expectError(error.Cancelled, images.save(testing.allocator, tmp.dir, name, snapshot(), .{ .width = 8, .height = 1024 }, .{ .context = &progress, .afterRows = Progress.update, .overwrite_basename = name }));
    try testing.expect(progress.rows > 0 and progress.rows < 1024);
    try expectOld(tmp.dir);
}

test "sustained export writes every row below full-image allocation" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const memory = try testing.allocator.alloc(u8, 128 * 1024);
    defer testing.allocator.free(memory);
    var fixed = std.heap.FixedBufferAllocator.init(memory);
    var progress: Progress = .{};
    try images.save(fixed.allocator(), tmp.dir, name, snapshot(), .{ .width = 512, .height = 1024 }, .{ .context = &progress, .afterRows = Progress.update });
    try testing.expectEqual(1024, progress.rows);
    try expectEntry(tmp.dir, name);
}

fn fullPath(dir: std.fs.Dir, buffer: []u8, basename: []const u8) ![]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ try dir.realpath(".", &root), basename });
}

test "worker rejects overwrite authorization for a different full path with the same basename" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var other = testing.tmpDir(.{});
    defer other.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = name, .data = old });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var other_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var worker: images.Worker = .{};
    defer worker.shutdown();
    try worker.start(try fullPath(tmp.dir, &path_buffer, name), try fullPath(other.dir, &other_buffer, name), snapshot(), size);
    worker.join();
    try testing.expectEqual(error.PublishFailed, worker.poll().failed);
    try expectOld(tmp.dir);
}

test "worker can join and then start another job" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try fullPath(tmp.dir, &path_buffer, name);
    var worker: images.Worker = .{};
    defer worker.shutdown();
    for (0..2) |_| {
        try worker.start(path, path, snapshot(), size);
        worker.join();
        try testing.expectEqual(.succeeded, std.meta.activeTag(worker.poll()));
        try expectPng(tmp.dir);
    }
}

const Barrier = struct {
    reached: std.Thread.ResetEvent = .{},
    release: std.Thread.ResetEvent = .{},

    fn pause(context: ?*anyopaque) void {
        const barrier: *Barrier = @ptrCast(@alignCast(context.?));
        barrier.reached.set();
        barrier.release.wait();
    }
};

test "cancel just before publication claim wins and preserves the original" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = name, .data = old });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try fullPath(tmp.dir, &path_buffer, name);
    var barrier: Barrier = .{};
    var worker: images.Worker = .{ .publication_hooks = .{ .context = &barrier, .before = Barrier.pause } };
    defer worker.shutdown();
    try worker.start(path, path, snapshot(), size);
    barrier.reached.wait();
    {
        defer barrier.release.set();
        try testing.expectEqual(size.height, worker.poll().running);
        try testing.expectEqual(.accepted, worker.cancel());
    }
    worker.join();
    try testing.expectEqual(.cancelled, std.meta.activeTag(worker.poll()));
    try expectOld(tmp.dir);
}

test "publication claim wins against subsequent cancellation and replaces the original" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = name, .data = old });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try fullPath(tmp.dir, &path_buffer, name);
    var barrier: Barrier = .{};
    var worker: images.Worker = .{ .publication_hooks = .{ .context = &barrier, .after = Barrier.pause } };
    defer worker.shutdown();
    try worker.start(path, path, snapshot(), size);
    barrier.reached.wait();
    {
        defer barrier.release.set();
        try testing.expectEqual(.publishing, std.meta.activeTag(worker.poll()));
        try testing.expectEqual(.too_late, worker.cancel());
    }
    worker.join();
    try testing.expectEqual(.succeeded, std.meta.activeTag(worker.poll()));
    try expectPng(tmp.dir);
    try expectEntry(tmp.dir, name);
}

test "a late cancellation leaves publication failure as the terminal result" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try fullPath(tmp.dir, &path_buffer, name);
    var barrier: Barrier = .{};
    var worker: images.Worker = .{ .publication_hooks = .{ .context = &barrier, .after = Barrier.pause } };
    defer worker.shutdown();
    try worker.start(path, null, snapshot(), size);
    barrier.reached.wait();
    {
        defer barrier.release.set();
        try tmp.dir.writeFile(.{ .sub_path = name, .data = old, .flags = .{ .exclusive = true } });
        try testing.expectEqual(.too_late, worker.cancel());
    }
    worker.join();
    try testing.expectEqual(error.PublishFailed, worker.poll().failed);
    try expectOld(tmp.dir);
}

const Shutdown = struct {
    worker: *images.Worker,
    reached: std.Thread.ResetEvent = .{},

    fn waitForCancellation(context: ?*anyopaque) void {
        const self: *Shutdown = @ptrCast(@alignCast(context.?));
        self.reached.set();
        while (std.meta.activeTag(self.worker.poll()) == .running) {
            std.Thread.yield() catch {};
        }
    }
};

test "shutdown requests cancellation and joins the active export" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = name, .data = old });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try fullPath(tmp.dir, &path_buffer, name);
    var worker: images.Worker = .{};
    var shutdown: Shutdown = .{ .worker = &worker };
    worker.publication_hooks = .{ .context = &shutdown, .before = Shutdown.waitForCancellation };
    try worker.start(path, path, snapshot(), size);
    shutdown.reached.wait();
    worker.shutdown();
    try testing.expectEqual(.cancelled, std.meta.activeTag(worker.poll()));
    try expectOld(tmp.dir);
}
