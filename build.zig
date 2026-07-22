const std = @import("std");

// Homebrew SDL3 (headers + dylib) on Apple Silicon.
const homebrew_prefix = "/opt/homebrew";

// Vendored Dear ImGui (docking branch) + cimgui + SDL backends. Compiled from
// source; see vendor/cimgui/context is captured in src/ui/context.md.
const imgui_sources = [_][]const u8{
    "vendor/cimgui/cimgui.cpp",
    "vendor/cimgui/imgui/imgui.cpp",
    "vendor/cimgui/imgui/imgui_draw.cpp",
    "vendor/cimgui/imgui/imgui_tables.cpp",
    "vendor/cimgui/imgui/imgui_widgets.cpp",
    "vendor/cimgui/imgui/imgui_demo.cpp",
    "vendor/cimgui/imgui/backends/imgui_impl_sdl3.cpp",
    "vendor/cimgui/imgui/backends/imgui_impl_sdlgpu3.cpp",
    "vendor/bridge/imgui_bridge.cpp",
};

// Applied to every ImGui/cimgui/bridge translation unit AND to the Zig
// @cImport of cimgui.h so struct layouts match the pre-generated cimgui.h.
const imgui_cpp_flags = [_][]const u8{
    "-std=c++17",
    "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS=1",
    "-fno-exceptions",
    "-fno-rtti",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Executable (module-based API, Zig 0.15.2). libc++ is required by the
    // vendored ImGui C++ sources.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    configureNativeStack(b, exe_mod);

    const exe = b.addExecutable(.{
        .name = "fractalforge",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // `zig build run`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` — fast, isolated unit-test tier. Runs the PURE core only
    // (src/root.zig aggregates pure modules): no window, no GPU, no C sources.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

/// Wire SDL3 + the vendored ImGui/cimgui/bridge C++ into `mod`. Include paths
/// are added for both the C++ compile and the Zig @cImport in `src/c.zig`.
fn configureNativeStack(b: *std.Build, mod: *std.Build.Module) void {
    // SDL3 from Homebrew.
    mod.addIncludePath(.{ .cwd_relative = homebrew_prefix ++ "/include" });
    mod.addLibraryPath(.{ .cwd_relative = homebrew_prefix ++ "/lib" });
    mod.linkSystemLibrary("SDL3", .{});

    // Vendored headers (cimgui core C API, ImGui/backends, bridge).
    mod.addIncludePath(b.path("vendor/cimgui"));
    mod.addIncludePath(b.path("vendor/cimgui/imgui"));
    mod.addIncludePath(b.path("vendor/cimgui/imgui/backends"));
    mod.addIncludePath(b.path("vendor/bridge"));

    mod.addCSourceFiles(.{
        .files = &imgui_sources,
        .flags = &imgui_cpp_flags,
    });
}
