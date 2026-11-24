//! Export a captured scene to a directory-relative temporary PNG, then publish it.
const std = @import("std");
const builtin = @import("builtin");
const render = @import("export_render.zig");
const png = @import("png.zig");
const log = std.log.scoped(.image_export);

pub const Size = render.Size;
pub const Error = error{
    InvalidDimensions,
    InvalidSnapshot,
    InvalidDestination,
    Cancelled,
    RenderFailed,
    OpenDirectoryFailed,
    CreateTemporaryFailed,
    WriteFailed,
    FlushFailed,
    PublishFailed,
};

pub const Control = struct {
    context: ?*anyopaque = null,
    afterRows: ?*const fn (?*anyopaque, u32) bool = null,
    overwrite_basename: ?[]const u8 = null,
};

const Hooks = struct {
    cancel: ?render.Cancel = null,
    claim: ?*const fn (?*anyopaque) bool = null,
};

pub fn save(allocator: std.mem.Allocator, dir: std.fs.Dir, basename: []const u8, scene: render.Snapshot, size: Size, control: ?Control) Error!void {
    return saveWithHooks(allocator, dir, basename, scene, size, control orelse .{}, .{});
}

fn validBasename(name: []const u8) bool {
    return name.len > 0 and name.len <= std.fs.max_name_bytes and
        !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and
        std.mem.indexOfAny(u8, name, "/\x00") == null;
}

fn saveWithHooks(allocator: std.mem.Allocator, dir: std.fs.Dir, basename: []const u8, scene: render.Snapshot, size: Size, control: Control, hooks: Hooks) Error!void {
    try size.validate();
    if (!validBasename(basename)) return error.InvalidDestination;
    try render.Cancel.check(hooks.cancel);

    var renderer = render.BandRenderer.init(allocator, scene, size, hooks.cancel) catch |err| switch (err) {
        error.Cancelled => return error.Cancelled,
        error.InvalidDimensions => return error.InvalidDimensions,
        error.InvalidSnapshot => return error.InvalidSnapshot,
        else => return error.RenderFailed,
    };
    defer renderer.deinit();

    var temporary_name: [64]u8 = undefined;
    var temporary_path: []const u8 = undefined;
    const file = while (true) {
        try render.Cancel.check(hooks.cancel);
        temporary_path = std.fmt.bufPrint(&temporary_name, ".fractal-export-{x}.tmp", .{std.crypto.random.int(u128)}) catch unreachable;
        if (std.mem.eql(u8, temporary_path, basename)) continue;
        break dir.createFile(temporary_path, .{ .exclusive = true, .mode = 0o600 }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return error.CreateTemporaryFailed,
        };
    };
    errdefer dir.deleteFile(temporary_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.err("cleanup failed for temporary export {s} targeting {s}: {s}", .{ temporary_path, basename, @errorName(err) }),
    };

    // The file must be closed even on error and before cancel and publish compete.
    {
        defer file.close();
        try render.Cancel.check(hooks.cancel);
        var buffer: [16 * 1024]u8 = undefined;
        var writer = file.writer(&buffer);
        var encoder = png.Encoder.init(&writer.interface, size) catch return error.WriteFailed;
        const stride = @as(usize, size.width) * 4;
        while (renderer.next(hooks.cancel) catch |err| switch (err) {
            error.Cancelled => return error.Cancelled,
            else => return error.RenderFailed,
        }) |band| {
            for (0..band.rows) |row| {
                try render.Cancel.check(hooks.cancel);
                encoder.writeRow(band.rgba[row * stride ..][0..stride]) catch return error.WriteFailed;
            }
            if (control.afterRows) |afterRows| {
                if (afterRows(control.context, band.first_row + band.rows)) return error.Cancelled;
            }
        }
        try render.Cancel.check(hooks.cancel);
        encoder.finish() catch return error.FlushFailed;
        try render.Cancel.check(hooks.cancel);
        file.sync() catch return error.FlushFailed;
    }

    if (hooks.claim) |claim| {
        if (!claim(control.context)) return error.Cancelled;
    } else try render.Cancel.check(hooks.cancel);

    const replace = if (control.overwrite_basename) |approved| std.mem.eql(u8, approved, basename) else false;
    if (replace) {
        dir.rename(temporary_path, basename) catch return error.PublishFailed;
    } else {
        try renameExclusive(dir, temporary_path, basename);
    }
}

extern "c" fn renameatx_np(c_int, [*:0]const u8, c_int, [*:0]const u8, c_uint) c_int;

fn renameExclusive(dir: std.fs.Dir, from: []const u8, to: []const u8) Error!void {
    const source = std.posix.toPosixPath(from) catch return error.PublishFailed;
    const destination = std.posix.toPosixPath(to) catch return error.PublishFailed;
    switch (builtin.os.tag) {
        .macos => {
            const rename_excl = 0x00000004; // macOS RENAME_EXCL
            if (renameatx_np(dir.fd, &source, dir.fd, &destination, rename_excl) != 0) return error.PublishFailed;
        },
        .linux => {
            const rename_noreplace = 1; // Linux RENAME_NOREPLACE
            if (std.os.linux.renameat2(dir.fd, &source, dir.fd, &destination, rename_noreplace) != 0) return error.PublishFailed;
        },
        else => return error.PublishFailed,
    }
}

pub const Status = union(enum) {
    idle,
    running: u32,
    cancelling: u32,
    publishing,
    succeeded,
    cancelled,
    failed: Error,
};

pub const CancelResult = enum { accepted, too_late, inactive };

/// Pin this object at a stable address until joined. The owner alone calls
/// the public methods. The worker thread only reads its owned job and publishes
/// progress and status.
pub const Worker = struct {
    const State = enum(u8) { idle, running, cancelling, publishing, succeeded, cancelled, failed };
    const Job = struct {
        scene: render.Snapshot,
        size: Size,
        path: [std.fs.max_path_bytes]u8 = undefined,
        len: usize,
        approved: [std.fs.max_path_bytes]u8 = undefined,
        approved_len: ?usize = null,
    };

    job: Job = undefined,
    thread: ?std.Thread = null,
    state: std.atomic.Value(State) = .init(.idle),
    rows: std.atomic.Value(u32) = .init(0),
    failure: Error = undefined,
    publication_hooks: if (builtin.is_test) struct {
        context: ?*anyopaque = null,
        before: ?*const fn (?*anyopaque) void = null,
        after: ?*const fn (?*anyopaque) void = null,
    } else void = if (builtin.is_test) .{} else {},

    /// Supply an absolute native path with the final filename, including any
    /// suffix added by the UI. Borrowed inputs are copied before start returns.
    pub fn start(self: *Worker, path: []const u8, approved_path: ?[]const u8, scene: render.Snapshot, size: Size) (Error || std.Thread.SpawnError || error{Busy})!void {
        try size.validate();
        if (self.thread != null) return error.Busy;
        if (path.len >= std.fs.max_path_bytes or !std.fs.path.isAbsolute(path) or
            path[path.len - 1] == '/' or std.mem.indexOfScalar(u8, path, 0) != null or
            !validBasename(std.fs.path.basename(path))) return error.InvalidDestination;
        self.job = .{ .scene = scene, .size = size, .len = path.len };
        @memcpy(self.job.path[0..path.len], path);
        if (approved_path) |approved| {
            if (approved.len < self.job.approved.len) {
                @memcpy(self.job.approved[0..approved.len], approved);
                self.job.approved_len = approved.len;
            }
        }
        self.rows.store(0, .monotonic);
        self.state.store(.running, .release);
        errdefer self.state.store(.idle, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn poll(self: *const Worker) Status {
        return switch (self.state.load(.acquire)) {
            .idle => .idle,
            .running => .{ .running = self.rows.load(.monotonic) },
            .cancelling => .{ .cancelling = self.rows.load(.monotonic) },
            .publishing => .publishing,
            .cancelled => .cancelled,
            .succeeded => .succeeded,
            .failed => .{ .failed = self.failure },
        };
    }

    pub fn cancel(self: *Worker) CancelResult {
        return switch (self.state.cmpxchgStrong(.running, .cancelling, .acq_rel, .acquire) orelse return .accepted) {
            .cancelling => .accepted,
            .publishing => .too_late,
            else => .inactive,
        };
    }

    /// Release the finished thread before starting another job. The terminal
    /// status remains available after the join.
    pub fn join(self: *Worker) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn shutdown(self: *Worker) void {
        _ = self.cancel();
        self.join();
    }

    fn run(self: *Worker) void {
        self.runJob() catch |err| {
            if (err == error.Cancelled) {
                self.state.store(.cancelled, .release);
                return;
            }
            self.failure = err;
            switch (self.state.cmpxchgStrong(.running, .failed, .release, .monotonic) orelse return) {
                .cancelling => self.state.store(.cancelled, .release),
                .publishing => self.state.store(.failed, .release),
                else => unreachable,
            }
            return;
        };
        self.state.store(.succeeded, .release);
    }

    fn runJob(self: *Worker) Error!void {
        if (self.state.load(.acquire) == .cancelling) return error.Cancelled;
        const job = &self.job;
        const path = job.path[0..job.len];
        const basename = std.fs.path.basename(path);
        var dir = std.fs.openDirAbsolute(std.fs.path.dirname(path).?, .{}) catch return error.OpenDirectoryFailed;
        defer dir.close();
        const overwrite_basename = if (job.approved_len) |len|
            if (std.mem.eql(u8, job.approved[0..len], path)) basename else null
        else
            null;
        return saveWithHooks(std.heap.page_allocator, dir, basename, job.scene, job.size, .{
            .context = self,
            .afterRows = publishRows,
            .overwrite_basename = overwrite_basename,
        }, .{
            .cancel = .{ .context = self, .isCancelled = isCancelled },
            .claim = claimPublication,
        });
    }

    fn fromContext(context: ?*anyopaque) *Worker {
        return @ptrCast(@alignCast(context.?));
    }

    fn publishRows(context: ?*anyopaque, rows: u32) bool {
        fromContext(context).rows.store(rows, .monotonic);
        return isCancelled(context);
    }

    fn isCancelled(context: ?*anyopaque) bool {
        return fromContext(context).state.load(.acquire) == .cancelling;
    }

    fn claimPublication(context: ?*anyopaque) bool {
        const self = fromContext(context);
        if (builtin.is_test) {
            if (self.publication_hooks.before) |hook| hook(self.publication_hooks.context);
        }
        if (self.state.cmpxchgStrong(.running, .publishing, .acq_rel, .acquire) != null) return false;
        if (builtin.is_test) {
            if (self.publication_hooks.after) |hook| hook(self.publication_hooks.context);
        }
        return true;
    }
};

const StopAtCheckpoint = struct {
    // A 1 × 1 save without kernel checks polls cancellation only nine times.
    remaining: usize = 10,
    dir: std.fs.Dir,
    temporary_present: bool = false,

    fn isCancelled(context: ?*anyopaque) bool {
        const self: *StopAtCheckpoint = @ptrCast(@alignCast(context.?));
        self.remaining -= 1;
        if (self.remaining != 0) return false;
        var scan = self.dir.iterate();
        _ = (scan.next() catch unreachable).?;
        self.temporary_present = (scan.next() catch unreachable) != null;
        return true;
    }
};

fn expectWorkCancelled(side: f64, temporary_present: bool) !void {
    const testing = std.testing;
    const size: Size = .{ .width = 1, .height = 1 };
    const scene: render.Snapshot = .{
        .view = try @import("viewport.zig").SquareView.fromCenterSide(.{ .re = 0, .im = 0 }, side),
        .source = size,
        .lut = @splat(.{ 1, 2, 3, 255 }),
        .params = .{},
        .interior = .{ 1, 2, 3, 255 },
        .max_iter = 10_000,
    };
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "image.png", .data = "old" });
    var stop = StopAtCheckpoint{ .dir = tmp.dir };
    try testing.expectError(error.Cancelled, saveWithHooks(testing.allocator, tmp.dir, "image.png", scene, size, .{
        .overwrite_basename = "image.png",
    }, .{ .cancel = .{ .context = &stop, .isCancelled = StopAtCheckpoint.isCancelled } }));
    try testing.expectEqual(temporary_present, stop.temporary_present);
    var previous: [64]u8 = undefined;
    try testing.expectEqualStrings("old", try tmp.dir.readFile("image.png", &previous));
    var scan = tmp.dir.iterate();
    try testing.expectEqualStrings("image.png", (try scan.next()).?.name);
    try testing.expectEqual(null, try scan.next());
}

test "save forwards cancellation to reference orbit preparation" {
    try expectWorkCancelled(1e-30, false);
}

test "save forwards cancellation to an in-flight pixel and removes temporary output" {
    try expectWorkCancelled(1.0, true);
}
