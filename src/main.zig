//! Executable entry point. M0 skeleton: log a startup line and exit 0.
//! No window / GPU / fractal yet (those arrive in later M0 tasks).
const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");

const log = std.log.scoped(.app);

pub fn main() !void {
    var buf: [128]u8 = undefined;
    const line = try root.startupLine(&buf, builtin.zig_version_string);
    log.info("{s}", .{line});
}
