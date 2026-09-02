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
    _ = @import("fractal/viewport.zig");
    _ = @import("fractal/navigate.zig");
    _ = @import("fractal/autoiter.zig");
    _ = @import("fractal/mandelbrot.zig");
    // M10: pure orbit sequence for the orbit inspector (complex-plane only).
    _ = @import("fractal/orbit.zig");
    _ = @import("fractal/perturb.zig");
    _ = @import("fractal/color.zig");
    _ = @import("fractal/gradient.zig");
    _ = @import("fractal/mapping.zig");
    _ = @import("fractal/iterbuf.zig");
    _ = @import("fractal/colorpass.zig");
    _ = @import("fractal/engine.zig");
    _ = @import("ui/stats.zig");
    _ = @import("ui/editor.zig");
    // M7: pure per-frame gesture reduction (pinch/wheel -> one Intent per frame).
    _ = @import("ui/gesture.zig");
    _ = @import("fractal/refine.zig");
    _ = @import("fractal/progressive.zig");
    _ = @import("fractal/persist.zig");
    // M8: colour-only save/load — a view-free sibling of persist.zig.
    _ = @import("fractal/scheme.zig");
    // M8: built-in colouring presets (const data) + bakeable preview gradients.
    _ = @import("fractal/presets.zig");
    // Pure line formatters for the user-only input probe (`zig build probe`).
    _ = @import("probe_fmt.zig");
    // Cross-module acceptance tests for M6 deep zoom (pure tier: no window, no GPU).
    _ = @import("deep_zoom_test.zig");
    // Cross-module acceptance tests for M7 trackpad gestures (pure tier: no window, no GPU).
    _ = @import("gesture_test.zig");
    std.testing.refAllDecls(@This());
}

test "startupLine formats the startup banner with the zig version" {
    var buf: [128]u8 = undefined;
    const line = try startupLine(&buf, "0.15.2");
    try std.testing.expectEqualStrings("fractalforge starting (zig 0.15.2)", line);
}
