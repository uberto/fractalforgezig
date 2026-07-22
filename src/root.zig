//! Library root. `zig build test` runs this file's tests.
//! Aggregate module tests here via `test { _ = @import("..."); }` as modules
//! land (fractal / gpu / ui). Keep pure logic testable with no window/GPU.
const std = @import("std");

/// Build the startup banner line. Pure (no I/O) so it is unit-testable without
/// a window or GPU device — this is the pattern the rest of the milestone follows
/// for log/summary strings.
pub fn startupLine(buf: []u8, zig_version: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, "fractalforge starting (zig {s})", .{zig_version});
}

test {
    // Aggregation point for submodule tests as they land, e.g.:
    //   _ = @import("fractal/mandelbrot.zig");
    // Only PURE modules belong here: the fast tier must not @cImport SDL/GPU.
    _ = @import("gpu/message.zig");
    std.testing.refAllDecls(@This());
}

test "startupLine formats the startup banner with the zig version" {
    var buf: [128]u8 = undefined;
    const line = try startupLine(&buf, "0.15.2");
    try std.testing.expectEqualStrings("fractalforge starting (zig 0.15.2)", line);
}
