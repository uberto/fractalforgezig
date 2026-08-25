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

    // The Metal compute shader source lives in src/gpu/shaders/mandelbrot.metal.
    // It is @embedFile'd as raw MSL text and passed to SDL_CreateGPUComputePipeline
    // with SDL_GPU_SHADERFORMAT_MSL — no xcrun/metallib build step required.
    // Full Xcode (for the metal compiler) is therefore not a build dependency.

    b.installArtifact(exe);

    // `zig build run`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // `zig build probe` — USER-ONLY input probe (src/probe.zig). Opens a window and
    // records wheel/pinch/finger events; NO agent may run it (standing rule 2026-08-20).
    // Its own module so the probe never links into the app, and `configureNativeStack` is
    // reused rather than a second link configuration hand-rolled (it pulls in the ImGui
    // C++ the probe does not call, which is harmless).
    const probe_mod = b.createModule(.{
        .root_source_file = b.path("src/probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    configureNativeStack(b, probe_mod);

    const probe_exe = b.addExecutable(.{
        .name = "input-probe",
        .root_module = probe_mod,
    });

    const probe_cmd = b.addRunArtifact(probe_exe);
    const probe_step = b.step("probe", "USER ONLY: run the input probe (opens a window; no agent may run this)");
    probe_step.dependOn(&probe_cmd.step);

    // COMPILED by `zig build` (so a plain build catches a broken probe) but deliberately
    // NOT installed into zig-out and NOT reachable from `test`/`test-gpu`: the probe is a
    // measurement tool, not a shipped artifact, and must not pollute the gates.
    b.getInstallStep().dependOn(&probe_exe.step);

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

    // Headless GPU texture round-trip test. A SEPARATE artifact because it links
    // the native stack (SDL/GPU) and creates a real device — the fast pure tier
    // above must stay C-free. At runtime it SKIPS cleanly (logged reason) when no
    // GPU device is available, so it never fails the suite on headless CI.
    const gpu_test_mod = b.createModule(.{
        .root_source_file = b.path("src/gpu_headless_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    configureNativeStack(b, gpu_test_mod);
    const gpu_tests = b.addTest(.{ .root_module = gpu_test_mod });
    const run_gpu_tests = b.addRunArtifact(gpu_tests);
    const gpu_test_step = b.step("test-gpu", "Run the headless GPU texture round-trip test");
    gpu_test_step.dependOn(&run_gpu_tests.step);
    // Also part of the milestone's `zig build test` gate.
    test_step.dependOn(&run_gpu_tests.step);
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
