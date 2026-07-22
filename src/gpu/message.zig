//! Pure log/summary string builders for the GPU layer.
//!
//! These have NO SDL/GPU imports so they run in the fast, isolated test tier
//! (`zig build test`, no window/device). `device.zig` calls them to build the
//! strings it hands to `std.log`. Keeping the formatting pure is the milestone's
//! standing requirement for testable observability.
const std = @import("std");

/// Build a failure message for a named SDL/GPU call, embedding the
/// `SDL_GetError()` string. Example: "SDL_CreateGPUDevice failed: <err>".
pub fn sdlFailure(buf: []u8, call: []const u8, sdl_error: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s} failed: {s}", .{ call, sdl_error });
}

/// Build the success summary logged once the GPU device is created and the
/// window swapchain is claimed. Example: "SDL_GPU device ready (driver=metal)".
pub fn deviceReady(buf: []u8, driver: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, "SDL_GPU device ready (driver={s})", .{driver});
}

test "sdlFailure embeds the call name and SDL error string" {
    var buf: [128]u8 = undefined;
    const msg = try sdlFailure(&buf, "SDL_CreateGPUDevice", "no usable GPU found");
    try std.testing.expectEqualStrings("SDL_CreateGPUDevice failed: no usable GPU found", msg);
}

test "deviceReady reports the driver name" {
    var buf: [128]u8 = undefined;
    const msg = try deviceReady(&buf, "metal");
    try std.testing.expectEqualStrings("SDL_GPU device ready (driver=metal)", msg);
}
