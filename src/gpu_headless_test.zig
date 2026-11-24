//! Test-only root for the headless GPU texture round-trip suite.
//!
//! Rooted in `src/` (NOT `src/gpu/`) so `gpu/texture.zig`'s `../c.zig` and
//! `../fractal/*` imports resolve inside the module path. This aggregates the
//! ONE C-linking test artifact; `zig build test` and `zig build test-gpu` build
//! it. The pure tier (`src/root.zig`) stays C-free and must not import this.
const std = @import("std");
const c = @import("c.zig").c;
const bla = @import("fractal/bla.zig");

test {
    _ = @import("gpu/texture.zig");
    _ = @import("gpu/compute.zig");
    std.testing.refAllDecls(@This());
}

fn openHeadlessDevice() error{SkipZigTest}!*c.SDL_GPUDevice {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.log.warn("skipping headless GPU test: SDL_Init failed", .{});
        return error.SkipZigTest;
    }
    const shader_formats = c.SDL_GPU_SHADERFORMAT_MSL | c.SDL_GPU_SHADERFORMAT_METALLIB;
    return c.SDL_CreateGPUDevice(shader_formats, true, null) orelse {
        std.log.warn("skipping headless GPU test: no GPU device", .{});
        c.SDL_Quit();
        return error.SkipZigTest;
    };
}

fn closeHeadlessDevice(device: *c.SDL_GPUDevice) void {
    c.SDL_DestroyGPUDevice(device);
    c.SDL_Quit();
}

// ─── Compute pipeline smoke tests ────────────────────────────────────────────

const compute = @import("gpu/compute.zig");
const viewport = @import("fractal/viewport.zig");
const perturb = @import("fractal/perturb.zig");
const iterbuf = @import("fractal/iterbuf.zig");
const mandelbrot_mod = @import("fractal/mandelbrot.zig");
/// The APPLICATION, imported for the one test that proves its `IterFn` wrapper reaches the deep
/// kernel. Every other criterion of T6 can pass with `src/main.zig` left unwired, in which case
/// the running app renders every deep view on the CPU — so the wrapper is pinned here, on a real
/// device, rather than trusted.
const app = @import("main.zig");

test "compute: pipeline creates successfully with embedded MSL source" {
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);

    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();
    // If we reach here the MSL compiled without error.
}

test "compute: pipeline creation reports ShaderCompilationFailed on a broken shader" {
    // Could not be written before round 2: this path logged with `std.log.err`, and Zig 0.15's
    // test runner turns any logged error into a non-zero exit ("1 errors were logged") while
    // still reporting every test as passing. Routing it through `emitErr` — a no-op under test —
    // is what makes the failure assertable, and it is the exit a future `mandelbrot.metal` typo
    // takes, so it must return a typed error rather than crash or hand back a half-built pipeline.
    //
    // EXPECTED NOISE: Metal itself prints `ERROR: Creating MTLLibrary failed … expected
    // unqualified-id` while this test runs. That line is the shader compiler doing its job on
    // deliberately invalid MSL, not a failing gate — the tier stays green and exits 0.
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);

    try std.testing.expectError(
        compute.Error.ShaderCompilationFailed,
        compute.ComputePipeline.createFromSource(device, "this is not valid MSL"),
    );
}

test "compute: gpuIterate interior pixels match CPU (deep interior, no precision boundary)" {
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);

    const mandelbrot = @import("fractal/mandelbrot.zig");
    const vp = @import("fractal/viewport.zig");

    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();

    const S: u32 = 16;
    const max_iter: u32 = 64;
    // Use a view centered deep inside the Mandelbrot set (origin = 0+0i, scale small).
    // All pixels in a tiny square around (0,0) are interior; CPU and GPU must agree.
    const view = try vp.SquareView.fromCenterSide(.{ .re = 0.0, .im = 0.0 }, 0.1);

    var gpu_iter: [S * S]f32 = undefined;
    try compute.gpuIterate(pipeline, view, S, S, max_iter, &gpu_iter);

    var interior_count: u32 = 0;
    for (gpu_iter) |v| {
        if (v < 0.0) interior_count += 1;
    }
    try std.testing.expectEqual(@as(u32, S * S), interior_count);

    const exterior_view = try vp.SquareView.fromCenterSide(.{ .re = 2.0, .im = 2.0 }, 0.01);
    var exterior_iter: [S * S]f32 = undefined;
    try compute.gpuIterate(pipeline, exterior_view, S, S, max_iter, &exterior_iter);

    // CPU reference for center pixel.
    const scale: f64 = exterior_view.side / @as(f64, @floatFromInt(S));
    // `centerLo`: the CPU reference iterates in f64, like the GPU path (M6 keeps the extended
    // precision at the VIEW level only).
    const ctr = exterior_view.centerLo();
    const c_re = ctr.re + 0.5 * scale - exterior_view.side * 0.5;
    const c_im = ctr.im + exterior_view.side * 0.5 - 0.5 * scale;
    const cpu_val = mandelbrot.iterate(c_re, c_im, max_iter);
    const gpu_val = exterior_iter[0];

    // Both must be escaped (positive).
    try std.testing.expect(cpu_val > 0.0);
    try std.testing.expect(gpu_val > 0.0);
}

test "compute: dispatch at S=4 produces 16 finite results" {
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);

    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();

    const uniforms = compute.MandelbrotUniforms{
        .center_re = -0.75,
        .center_im = 0.0,
        .scale = @floatCast(3.5 / 4.0),
        .width = 4,
        .height = 4,
        .max_iter = 64,
        .band_rows = 4,
    };

    var iter_out: [4 * 4]f32 = undefined;
    try compute.dispatch(pipeline, uniforms, &iter_out);

    for (iter_out) |v| {
        try std.testing.expect(std.math.isFinite(v));
    }
}

test "compute: a band dispatch equals those rows of the whole-image dispatch" {
    // The band's whole reason to exist is progressive GPU rendering, so the claim that matters
    // is that splitting an image into bands changes NOTHING about the values — if `row_offset`
    // were dropped from the complex mapping, the band would render the top of the image.
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);

    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();

    const S: u32 = 16;
    const max_iter: u32 = 128;
    // Off-center and non-square so a row mix-up cannot coincidentally still match.
    const view = try viewport.SquareView.fromCenterSide(.{ .re = -0.4, .im = 0.35 }, 1.25);
    const w: u32 = S;
    const h: u32 = S / 2;

    var whole: [S * (S / 2)]f32 = undefined;
    try compute.gpuIterate(pipeline, view, w, h, max_iter, &whole);

    // Same image, computed as three uneven bands.
    var banded: [S * (S / 2)]f32 = undefined;
    const bands = [_][2]u32{ .{ 0, 3 }, .{ 3, 1 }, .{ 4, h - 4 } };
    for (bands) |b| {
        const start: usize = @as(usize, b[0]) * @as(usize, w);
        const len: usize = @as(usize, b[1]) * @as(usize, w);
        try compute.gpuIterateRows(pipeline, view, w, h, max_iter, b[0], b[1], banded[start..][0..len]);
    }

    try std.testing.expectEqualSlices(f32, &whole, &banded);
}

test "compute: a band that runs past the last row is rejected, not clamped" {
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);

    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();

    var band: [4 * 2]f32 = undefined;
    const uniforms = compute.MandelbrotUniforms{
        .center_re = -0.75,
        .center_im = 0.0,
        .scale = @floatCast(3.5 / 4.0),
        .width = 4,
        .height = 4,
        .max_iter = 16,
        .row_offset = 3, // 3 + 2 > 4
        .band_rows = 2,
    };
    try std.testing.expectError(compute.Error.BandOutOfBounds, compute.dispatch(pipeline, uniforms, &band));
}

// ─── M6/T6: the DEEP (perturbation) compute path ──────────────────────────────
//
// Every render here is 16x16 or smaller ON PURPOSE: the deep kernel runs `max_iter` delta steps
// per thread, and at the iteration counts these depths need (20000+) a full-window dispatch
// takes long enough to look like a hang.

/// The milestone's reference centre — the seahorse-valley boundary point every deep-zoom test in
/// this repo uses, which keeps producing structure past 1e-30.
const deep_center = viewport.ComplexHi{
    .re = -0.743643887037158704752191506114774,
    .im = 0.131825904205311970493132056385139,
};

/// One `float`/`uint` member of an MSL struct, in declaration order.
const MslField = struct { type_name: []const u8, name: []const u8 };

/// Extract the members of `struct <name> { ... };` from the MSL source the pipeline actually
/// compiles (`compute.msl_source`), so the layout test below compares the Zig `extern struct`
/// against the SHADER TEXT rather than against a comment describing it.
fn mslStructFields(source: []const u8, name: []const u8, out: []MslField) ![]MslField {
    var decl_buf: [64]u8 = undefined;
    const decl = try std.fmt.bufPrint(&decl_buf, "struct {s} {{", .{name});
    const start = std.mem.indexOf(u8, source, decl) orelse return error.MslStructNotFound;
    const body_start = start + decl.len;
    const body_len = std.mem.indexOf(u8, source[body_start..], "};") orelse return error.MslStructUnterminated;

    var count: usize = 0;
    var lines = std.mem.tokenizeAny(u8, source[body_start..][0..body_len], "\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var parts = std.mem.tokenizeAny(u8, line, " \t");
        const type_name = parts.next() orelse return error.MslFieldUnparsed;
        const field_name = std.mem.trimRight(u8, parts.next() orelse return error.MslFieldUnparsed, ";");
        if (count == out.len) return error.MslTooManyFields;
        out[count] = .{ .type_name = type_name, .name = field_name };
        count += 1;
    }
    return out[0..count];
}

/// Assert a Zig uniform `extern struct` and the MSL struct of the same name agree completely:
/// same field names in the same order, same scalar widths, same offsets, same total size.
///
/// A mismatched uniform layout is one of the two ways a kernel silently reads the wrong numbers
/// (the other is slot order) and neither fails loudly — the image just goes wrong. So the check
/// is mechanical and reads the shader text the pipeline really compiles, not a comment about it.
fn expectMslLayoutMatches(comptime T: type, msl_name: []const u8) !void {
    var buf: [16]MslField = undefined;
    const msl = try mslStructFields(std.mem.span(compute.msl_source), msl_name, &buf);
    const fields = @typeInfo(T).@"struct".fields;
    try std.testing.expectEqual(fields.len, msl.len);

    var expected_offset: usize = 0;
    inline for (fields, 0..) |field, i| {
        try std.testing.expectEqualStrings(msl[i].name, field.name);
        const as_msl: []const u8 = if (field.type == f32)
            "float"
        else if (field.type == u32)
            "uint"
        else
            @compileError("uniform fields must be f32 or u32; MSL has no other scalar to match");
        try std.testing.expectEqualStrings(msl[i].type_name, as_msl);
        try std.testing.expectEqual(expected_offset, @offsetOf(T, field.name));
        expected_offset += @sizeOf(field.type);
    }
    try std.testing.expectEqual(expected_offset, @sizeOf(T));
}

test "compute: the deep uniform struct matches the MSL struct field for field" {
    // 7 scalars, offsets 0,4,8,12,16,20,24, total 28 bytes.
    try expectMslLayoutMatches(compute.MandelbrotDeepUniforms, "MandelbrotDeepUniforms");
}

test "compute: the shallow uniform struct matches the MSL struct field for field" {
    // Not new work, but now that one .metal file feeds two pipelines, an edit for the deep kernel
    // can shift the shallow struct — so pin it the same way. 8 scalars, 32 bytes.
    try expectMslLayoutMatches(compute.MandelbrotUniforms, "MandelbrotUniforms");
}

/// How much of the GPU-vs-CPU deep-zoom disagreement is unavoidable, measured WITHOUT a GPU:
/// run the CPU's own `perturb.iterateDelta` twice at `side`, once on exact `f64` inputs and once
/// on precisely the numbers a `float` kernel is handed — an `f32` pixel scale, an `f32` pixel
/// delta, and the reference orbit narrowed to `f32` — with `f64` arithmetic BOTH times.
/// Whatever this reports is a floor no MSL kernel can beat, however correct it is.
///
/// Returns the number of escaping pixels whose smooth value moves by more than `tolerance`.
fn quantizationFloorOutliers(side: f64, max_iter: u32, tolerance: f64) !u32 {
    const view = try viewport.SquareView.fromCenterSide(deep_center, side);
    var orbit = try perturb.ReferenceOrbit.compute(std.testing.allocator, view.center(), max_iter);
    defer orbit.deinit(std.testing.allocator);

    var narrowed = orbit;
    narrowed.re = try std.testing.allocator.alloc(f64, orbit.len());
    defer std.testing.allocator.free(narrowed.re);
    narrowed.im = try std.testing.allocator.alloc(f64, orbit.len());
    defer std.testing.allocator.free(narrowed.im);
    narrowed.capacity = orbit.len();
    for (0..orbit.len()) |i| {
        narrowed.re[i] = @as(f32, @floatCast(orbit.re[i]));
        narrowed.im[i] = @as(f32, @floatCast(orbit.im[i]));
    }

    const scale_exact = side / 16.0;
    const scale_narrow: f64 = @as(f32, @floatCast(scale_exact));

    var outliers: u32 = 0;
    for (0..16) |row| {
        for (0..16) |col| {
            const fx = @as(f64, @floatFromInt(col)) + 0.5 - 8.0;
            const fy = 8.0 - @as(f64, @floatFromInt(row)) - 0.5;
            const exact = perturb.iterateDelta(orbit, fx * scale_exact, fy * scale_exact, max_iter);
            const narrow = perturb.iterateDelta(
                narrowed,
                @as(f32, @floatCast(fx * scale_narrow)),
                @as(f32, @floatCast(fy * scale_narrow)),
                max_iter,
            );
            if (exact == mandelbrot_mod.interior_sentinel) continue;
            if (narrow == mandelbrot_mod.interior_sentinel) continue;
            if (@abs(exact - narrow) > tolerance) outliers += 1;
        }
    }
    return outliers;
}

test "compute: f32 inputs alone move a dozen pixels past 1% of max_iter at 1e-20" {
    // WHY the agreement test below budgets outliers instead of asserting every pixel: a `float`
    // pixel delta holds 24 bits, so each GPU pixel samples a point up to ~6e-8 of a pixel spacing
    // away from the CPU's, and at this depth a handful of near-boundary pixels answer hundreds of
    // iterations differently for that alone. This runs no shader at all — pure `f64` arithmetic
    // on `f32`-quantized inputs — so it measures the FLOOR, not the kernel. Keeping it next to
    // the agreement test is what stops that budget from looking arbitrary, or from being widened
    // later to cover a real defect.
    const max_iter: u32 = 20000;
    const tolerance = 0.01 * @as(f64, @floatFromInt(max_iter));
    const outliers = try quantizationFloorOutliers(1.0e-20, max_iter, tolerance);
    try std.testing.expect(outliers >= 8); // measured 12 of 256; the GPU kernel measures 7
}

test "compute: the deep kernel agrees with the CPU deep path at 1e-20" {
    // At `perturb.gpu_floor_side` the `float` delta kernel must produce the CPU deep path's
    // image. The three assertions below are AT5's, as the user amended it — see
    // `.inception/m6-deep-zoom/acceptance-tests.md`, AT5 `### AMENDMENT 2026-08-14`, which settled
    // the question this comment used to record as open: the per-pixel 1%-of-`max_iter` figure is
    // no longer fatal on first breach (no MSL kernel can hold it — the test above measures the
    // f32-input floor with perfect arithmetic), so the outliers are BUDGETED and a mean-absolute-
    // error bound was added to carry the teeth that budget gives up. Statistics accumulate in
    // `f64` here for the same reason they do in AT5.
    //
    // What each assertion catches:
    //   * classification (budget 2, unchanged, measured 0 of 256) — a wrong slot order, a
    //     mismatched uniform layout or a dead kernel turns escaping pixels interior wholesale;
    //   * a COUNT of pixels beyond 1% of `max_iter` (budget 16, measured 7) — the geometry pin at
    //     this depth: every pixel of this tile escapes, so classification is blind to a flipped or
    //     shifted grid, whereas a y-flip puts 52 pixels over the figure and a dropped `+0.5`
    //     puts 41. DO NOT widen this budget without replacing that coverage;
    //   * the MEAN absolute error (< 60.0, measured 15.9) — broad defects (wrong slot order,
    //     struct layout, rebasing, orbit indexing) spread error over the whole tile.
    // `worst` is logged as a diagnostic and deliberately NOT asserted: a per-pixel maximum
    // measures this scene's hypersensitivity, not the kernel (it reads 1111 one step away, at
    // side 5e-20, while all three assertions above still pass there).
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);
    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();

    const max_iter: u32 = 20000;
    const view = try viewport.SquareView.fromCenterSide(deep_center, 1.0e-20);

    var orbit = try perturb.ReferenceOrbit.compute(std.testing.allocator, view.center(), max_iter);
    defer orbit.deinit(std.testing.allocator);

    var gpu_buf: [16 * 16]f32 = undefined;
    var cpu_buf: [16 * 16]f32 = undefined;
    try compute.gpuIterateDeepRows(pipeline, view, &orbit, 16, 16, max_iter, 0, 16, &gpu_buf);
    try iterbuf.iterateDeepBandInto(&cpu_buf, view.rectViewport(16, 16), max_iter, 0, 16, &orbit);

    const per_pixel_tol: f64 = 0.01 * @as(f64, @floatFromInt(max_iter)); // 200 iterations
    var class_mismatches: u32 = 0;
    var over_tol: u32 = 0;
    var exterior: u32 = 0;
    var sum_abs_err: f64 = 0;
    var worst: f64 = 0;
    for (gpu_buf, cpu_buf) |g, cpu| {
        const cpu_interior = cpu == mandelbrot_mod.interior_sentinel;
        const gpu_interior = g == mandelbrot_mod.interior_sentinel;
        if (cpu_interior != gpu_interior) {
            class_mismatches += 1;
            continue;
        }
        if (!cpu_interior) {
            const delta = @abs(@as(f64, cpu) - @as(f64, g));
            if (delta > worst) worst = delta;
            if (delta > per_pixel_tol) over_tol += 1;
            sum_abs_err += delta;
            exterior += 1;
        }
    }
    // NaN when nothing escaped, which the `exterior > 0` assertion below reports properly (and
    // `NaN < 60.0` is false, so a vacuous tile cannot pass the mean check either way).
    const mean_abs_err = sum_abs_err / @as(f64, @floatFromInt(exterior));
    // Silent when green, and the numbers when red: `expect` prints no values, and this suite logs
    // nothing at `info` under the test runner. `worst` rides along as a DIAGNOSTIC only.
    errdefer std.log.warn(
        "deep agreement at 1e-20 FAILED: exterior={d}/256 class_mismatches={d} over_tol={d} mean={d:.4} worst={d:.2}",
        .{ exterior, class_mismatches, over_tol, mean_abs_err, worst },
    );
    try std.testing.expect(class_mismatches <= 2);
    try std.testing.expect(over_tol <= 16);
    try std.testing.expect(exterior > 0);
    try std.testing.expect(mean_abs_err < 60.0);
}

test "compute: the deep render resolves structure at 1e-20 rather than one flat value" {
    // Guards the agreement test above against the degenerate way to pass it: if both paths
    // returned the interior sentinel everywhere, they would "agree" perfectly and the kernel
    // could be doing nothing at all.
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);
    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();

    const max_iter: u32 = 20000;
    const view = try viewport.SquareView.fromCenterSide(deep_center, 1.0e-20);
    var orbit = try perturb.ReferenceOrbit.compute(std.testing.allocator, view.center(), max_iter);
    defer orbit.deinit(std.testing.allocator);

    var gpu_buf: [16 * 16]f32 = undefined;
    try compute.gpuIterateDeepRows(pipeline, view, &orbit, 16, 16, max_iter, 0, 16, &gpu_buf);

    var distinct = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer distinct.deinit();
    for (gpu_buf) |v| try distinct.put(@bitCast(v), {});
    try std.testing.expect(distinct.count() > 1);
}

test "compute: deep bands compose into the same image as one whole-image deep dispatch" {
    // The per-dispatch orbit upload must not make a banded render differ from a one-shot one:
    // this is what lets the progressive pass chunk a deep GPU render across frames.
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);
    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();

    const w: u32 = 16;
    const h: u32 = 8; // non-square, so a row mix-up cannot coincidentally still match
    const max_iter: u32 = 2000;
    const view = try viewport.SquareView.fromCenterSide(deep_center, 1.0e-12);
    var orbit = try perturb.ReferenceOrbit.compute(std.testing.allocator, view.center(), max_iter);
    defer orbit.deinit(std.testing.allocator);

    var whole: [16 * 8]f32 = undefined;
    try compute.gpuIterateDeepRows(pipeline, view, &orbit, w, h, max_iter, 0, h, &whole);

    var banded: [16 * 8]f32 = undefined;
    const bands = [_][2]u32{ .{ 0, 3 }, .{ 3, 1 }, .{ 4, h - 4 } };
    for (bands) |b| {
        const start: usize = @as(usize, b[0]) * @as(usize, w);
        const len: usize = @as(usize, b[1]) * @as(usize, w);
        try compute.gpuIterateDeepRows(pipeline, view, &orbit, w, h, max_iter, b[0], b[1], banded[start..][0..len]);
    }
    try std.testing.expectEqualSlices(f32, &whole, &banded);
}

test "compute: a deep band that runs past the last row is rejected, not clamped" {
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);
    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();

    const view = try viewport.SquareView.fromCenterSide(deep_center, 1.0e-12);
    var orbit = try perturb.ReferenceOrbit.compute(std.testing.allocator, view.center(), 64);
    defer orbit.deinit(std.testing.allocator);

    var band: [4 * 2]f32 = undefined;
    try std.testing.expectError(
        compute.Error.BandOutOfBounds,
        compute.gpuIterateDeepRows(pipeline, view, &orbit, 4, 4, 64, 3, 2, &band), // 3 + 2 > 4
    );
}

test "compute: a deep dispatch of zero rows is a no-op, not an error" {
    // RENAMED in round 2 (was "…leaves the buffer untouched"): `iter_out.len` must equal
    // `width * band_rows`, so a zero-row band's buffer is necessarily zero-length and there is no
    // content an assertion could observe. What is actually under test is that an empty band is
    // accepted and creates no zero-sized GPU buffer — which is what lets the progressive pass ask
    // for a band of nothing at the end of a render.
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);
    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();

    const view = try viewport.SquareView.fromCenterSide(deep_center, 1.0e-12);
    var orbit = try perturb.ReferenceOrbit.compute(std.testing.allocator, view.center(), 64);
    defer orbit.deinit(std.testing.allocator);

    var empty: [0]f32 = undefined;
    try compute.gpuIterateDeepRows(pipeline, view, &orbit, 4, 4, 64, 2, 0, &empty);
}

test "compute: a deep band whose buffer is the wrong length is rejected" {
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);
    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();

    const view = try viewport.SquareView.fromCenterSide(deep_center, 1.0e-12);
    var orbit = try perturb.ReferenceOrbit.compute(std.testing.allocator, view.center(), 64);
    defer orbit.deinit(std.testing.allocator);

    var band: [4 * 2]f32 = undefined; // one row short of the 4×3 band asked for below
    try std.testing.expectError(
        compute.Error.IterBufferSizeMismatch,
        compute.gpuIterateDeepRows(pipeline, view, &orbit, 4, 4, 64, 0, 3, &band),
    );
}

test "compute: the deep kernel answers the interior sentinel for a degenerate orbit" {
    // Parity with `perturb.iterateDelta` on the edge case both implementations document: an orbit
    // of only `Z_0 = 0` carries no `Z_1 = C`, so there is nothing to iterate against and no way to
    // recover the centre. The CPU side is pinned in `perturb.zig`; this pins the kernel's own
    // `orbit_len < 2` branch, which is otherwise unreachable from any test.
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);
    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();

    const view = try viewport.SquareView.fromCenterSide(deep_center, 1.0e-12);
    // `max_iter = 0` records `Z_0` alone — the same construction the CPU parity test uses.
    var orbit = try perturb.ReferenceOrbit.compute(std.testing.allocator, view.center(), 0);
    defer orbit.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), orbit.len());

    // Pre-filled with a marker no kernel produces, so a dispatch that wrote NOTHING would fail
    // here rather than passing on undefined memory that happened to read as the sentinel.
    var band: [4 * 4]f32 = @splat(1234.5);
    try compute.gpuIterateDeepRows(pipeline, view, &orbit, 4, 4, 64, 0, 4, &band);
    for (band) |v| try std.testing.expectEqual(mandelbrot_mod.interior_sentinel, v);
}

test "compute: the deep path refuses a view below the GPU precision floor" {
    // Defence in depth: the engine's pre-check is what normally keeps this call from happening,
    // so the backend must refuse rather than hand back a quantized image to a caller that
    // skipped it. Both layers ask `engine.gpuDeepFallbackReason`, so there is one floor.
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);
    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();

    const view = try viewport.SquareView.fromCenterSide(deep_center, 1.0e-25);
    var orbit = try perturb.ReferenceOrbit.compute(std.testing.allocator, view.center(), 64);
    defer orbit.deinit(std.testing.allocator);

    var band: [4 * 4]f32 = undefined;
    try std.testing.expectError(
        compute.Error.BelowGpuPrecisionFloor,
        compute.gpuIterateDeepRows(pipeline, view, &orbit, 4, 4, 64, 0, 4, &band),
    );
}

test "compute: the deep path refuses an orbit longer than the GPU budget" {
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);
    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();

    // Built by hand rather than iterated: only its LENGTH is under test, and `max_iter` above
    // 131072 would spend seconds in the `f128` orbit loop to prove nothing extra.
    const too_long = perturb.gpu_max_orbit_len + 1;
    const re = try std.testing.allocator.alloc(f64, too_long);
    defer std.testing.allocator.free(re);
    const im = try std.testing.allocator.alloc(f64, too_long);
    defer std.testing.allocator.free(im);
    @memset(re, 0.0);
    @memset(im, 0.0);
    const orbit = perturb.ReferenceOrbit{ .re = re, .im = im, .capacity = too_long };

    const view = try viewport.SquareView.fromCenterSide(deep_center, 1.0e-12);
    var band: [4 * 4]f32 = undefined;
    try std.testing.expectError(
        compute.Error.OrbitTooLongForGpu,
        compute.gpuIterateDeepRows(pipeline, view, &orbit, 4, 4, 64, 0, 4, &band),
    );
}

test "compute: both pipelines survive repeated create/destroy cycles" {
    // `destroy` releases the shallow AND the deep pipeline; a half-released pipeline (or a GPU
    // buffer leaked per dispatch) shows up as a later cycle failing to create or dispatch.
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);

    const view = try viewport.SquareView.fromCenterSide(deep_center, 1.0e-12);
    var orbit = try perturb.ReferenceOrbit.compute(std.testing.allocator, view.center(), 256);
    defer orbit.deinit(std.testing.allocator);

    var cycle: u32 = 0;
    while (cycle < 8) : (cycle += 1) {
        const pipeline = try compute.ComputePipeline.create(device);
        defer pipeline.destroy();
        var shallow: [4 * 4]f32 = undefined;
        var deep: [4 * 4]f32 = undefined;
        try compute.gpuIterateRows(pipeline, view, 4, 4, 256, 0, 4, &shallow);
        try compute.gpuIterateDeepRows(pipeline, view, &orbit, 4, 4, 256, 0, 4, &deep);
        for (deep) |v| try std.testing.expect(std.math.isFinite(v));
    }
}

test "compute: the app's IterFn wrapper dispatches a deep band to the deep kernel" {
    // THE end-to-end wiring assertion. `src/main.zig`'s wrapper is the only path from the
    // running app to the deep kernel, and every other test here calls `compute` directly — so
    // without this one the kernel could ship fully tested with the app still rendering every
    // deep view on the CPU. Bit-identical to a direct deep dispatch is the proof: the shallow
    // kernel or a refusal would both differ.
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);
    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();
    app.installComputePipeline(pipeline);
    defer app.installComputePipeline(null);

    // 1e-15: deep enough to need perturbation, shallow enough for the GPU to be allowed.
    const max_iter: u32 = 4096;
    const view = try viewport.SquareView.fromCenterSide(deep_center, 1.0e-15);
    var orbit = try perturb.ReferenceOrbit.compute(std.testing.allocator, view.center(), max_iter);
    defer orbit.deinit(std.testing.allocator);

    var through_app: [16 * 16]f32 = undefined;
    var direct: [16 * 16]f32 = undefined;
    try app.gpuIterFn(view, 16, 16, max_iter, 0, 16, &through_app, &orbit);
    try compute.gpuIterateDeepRows(pipeline, view, &orbit, 16, 16, max_iter, 0, 16, &direct);

    try std.testing.expectEqualSlices(f32, &direct, &through_app);
}

test "compute: the app's IterFn wrapper still dispatches a shallow band to the direct kernel" {
    // The other half of the routing: a null orbit must reach `mandelbrot_iterate` exactly as it
    // did before this task, so a shallow view's image is unchanged.
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);
    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();
    app.installComputePipeline(pipeline);
    defer app.installComputePipeline(null);

    const view = viewport.SquareView.defaultView();
    var through_app: [16 * 16]f32 = undefined;
    var direct: [16 * 16]f32 = undefined;
    try app.gpuIterFn(view, 16, 16, 512, 0, 16, &through_app, null);
    try compute.gpuIterateRows(pipeline, view, 16, 16, 512, 0, 16, &direct);

    try std.testing.expectEqualSlices(f32, &direct, &through_app);
}

// ---------------------------------------------------------------------------
// M6 acceptance test (AT5, AMENDED 2026-08-14) — materialized verbatim from
// `.inception/m6-deep-zoom/acceptance-tests.md:280-338`. Immutable: do not weaken.
// ---------------------------------------------------------------------------

test "compute: GPU deep zoom at 1e-20 matches the CPU deep path" {
    const mandelbrot = @import("fractal/mandelbrot.zig");
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);
    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();

    const max_iter: u32 = 20000;
    const view = try viewport.SquareView.fromCenterSide(.{
        .re = -0.743643887037158704752191506114774,
        .im = 0.131825904205311970493132056385139,
    }, 1.0e-20);

    var orbit = try perturb.ReferenceOrbit.compute(std.testing.allocator, view.center(), max_iter);
    defer orbit.deinit(std.testing.allocator);

    var gpu_buf: [16 * 16]f32 = undefined;
    var cpu_buf: [16 * 16]f32 = undefined;
    try compute.gpuIterateDeepRows(pipeline, view, &orbit, 16, 16, max_iter, 0, 16, &gpu_buf);
    try iterbuf.iterateDeepBandInto(&cpu_buf, view.rectViewport(16, 16), max_iter, 0, 16, &orbit);

    // AMENDED 2026-08-14 by user ruling; see this test's amendment note above.
    const per_pixel_tol: f64 = 0.01 * @as(f64, @floatFromInt(max_iter)); // 200 iterations
    var class_mismatches: u32 = 0;
    var over_tol: u32 = 0;
    var exterior: u32 = 0;
    var sum_abs_err: f64 = 0;
    // The capture is `cpu` and not the approved text's `c`: this file's `c` is the cimgui
    // @cImport alias at :8, and a capture may not shadow a container declaration in Zig.
    for (gpu_buf, cpu_buf) |g, cpu| {
        const c_interior = cpu == mandelbrot.interior_sentinel;
        const g_interior = g == mandelbrot.interior_sentinel;
        if (c_interior != g_interior) {
            class_mismatches += 1;
            continue;
        }
        if (!c_interior) {
            const d = @abs(@as(f64, cpu) - @as(f64, g));
            if (d > per_pixel_tol) over_tol += 1;
            sum_abs_err += d;
            exterior += 1;
        }
    }

    // 256 pixels; only near-boundary flips are tolerated. A real kernel defect mismatches
    // by the dozen. UNCHANGED from the original approved test — measured 0 on every variant.
    try std.testing.expect(class_mismatches <= 2);

    // f32 deltas alone put a handful of hypersensitive pixels over the 200-iteration figure
    // even with perfect f64 arithmetic (measured: 4 with an f64 orbit, 11 with an f32 orbit).
    // Budget the outliers rather than the tolerance.
    try std.testing.expect(over_tol <= 16);

    // The mean is what actually has teeth: broad defects — wrong slot order, mismatched struct
    // layout, broken rebasing, wrong orbit indexing, a flipped or half-pixel-shifted grid —
    // spread error across the whole tile and measure in the hundreds or thousands here, not 60.
    try std.testing.expect(exterior > 0);
    const mean_abs_err = sum_abs_err / @as(f64, @floatFromInt(exterior));
    try std.testing.expect(mean_abs_err < 60.0);
}

test "compute: the accelerated deep kernel agrees with the CPU accelerated path at 1e-20" {
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);
    const pipeline = try compute.ComputePipeline.create(device);
    defer pipeline.destroy();

    const max_iter: u32 = 20000;
    const view = try viewport.SquareView.fromCenterSide(deep_center, 1.0e-20);

    var orbit = try perturb.ReferenceOrbit.compute(std.testing.allocator, view.center(), max_iter);
    defer orbit.deinit(std.testing.allocator);

    var table = try bla.BlaTable.build(std.testing.allocator, &orbit, view.side * @sqrt(0.5));
    defer table.deinit(std.testing.allocator);

    app.installComputePipeline(pipeline);
    defer app.installComputePipeline(null);

    var gpu_buf: [16 * 16]f32 = undefined;
    var cpu_buf: [16 * 16]f32 = undefined;
    // Drive the live callback over nonzero-offset bands against the full-image CPU oracle.
    try app.gpuBlaIterFn(view, 16, 16, max_iter, 0, 5, gpu_buf[0 .. 5 * 16], &orbit, &table);
    try app.gpuBlaIterFn(view, 16, 16, max_iter, 5, 11, gpu_buf[5 * 16 ..], &orbit, &table);
    try iterbuf.iterateDeepBandBlaInto(&cpu_buf, view.rectViewport(16, 16), max_iter, 0, 16, &orbit, &table);

    const per_pixel_tol: f64 = 0.01 * @as(f64, @floatFromInt(max_iter)); // 200 iterations
    var class_mismatches: u32 = 0;
    var over_tol: u32 = 0;
    var exterior: u32 = 0;
    var sum_abs_err: f64 = 0;
    var worst: f64 = 0;
    for (gpu_buf, cpu_buf) |g, cpu| {
        const cpu_interior = cpu == mandelbrot_mod.interior_sentinel;
        const gpu_interior = g == mandelbrot_mod.interior_sentinel;
        if (cpu_interior != gpu_interior) {
            class_mismatches += 1;
            continue;
        }
        if (!cpu_interior) {
            const delta = @abs(@as(f64, cpu) - @as(f64, g));
            if (delta > worst) worst = delta;
            if (delta > per_pixel_tol) over_tol += 1;
            sum_abs_err += delta;
            exterior += 1;
        }
    }
    // NaN when nothing escaped, which the `exterior > 0` assertion below reports properly (and
    // `NaN < 60.0` is false, so a vacuous tile cannot pass the mean check either way).
    const mean_abs_err = sum_abs_err / @as(f64, @floatFromInt(exterior));
    // Silent when green, and the numbers when red: `expect` prints no values, and this suite logs
    // nothing at `info` under the test runner. `worst` rides along as a DIAGNOSTIC only.
    errdefer std.log.warn(
        "BLA agreement at 1e-20 FAILED: exterior={d}/256 class_mismatches={d} over_tol={d} mean={d:.4} worst={d:.2}",
        .{ exterior, class_mismatches, over_tol, mean_abs_err, worst },
    );
    try std.testing.expect(class_mismatches <= 2);
    try std.testing.expect(over_tol <= 16);
    try std.testing.expect(exterior > 0);
    try std.testing.expect(mean_abs_err < 60.0);
}

test "compute: the BLA table storage stride matches Metal" {
    try expectMslLayoutMatches(compute.GpuBlaBlock, "GpuBlaBlock");
}

test "compute: the quadratic kernel finishes a stable deep pixel with skips" {
    const alloc = std.testing.allocator;
    // Substitute a work-count return into the same shader the app loads. Plain replay
    // retains its sentinel, so merely dispatching the BLA pipeline cannot pass this test.
    const counted = try std.mem.replaceOwned(u8, alloc, std.mem.span(compute.msl_source), "    float uncertainty = 0.0f;", "    uint saved_steps = 0;\n    float uncertainty = 0.0f;");
    defer alloc.free(counted);
    const with_skips = try std.mem.replaceOwned(u8, alloc, counted, "                    n += best_len;", "                    n += best_len;\n                    saved_steps += best_len - 1;");
    defer alloc.free(with_skips);
    const with_result = try std.mem.replaceOwned(u8, alloc, with_skips, "    if (!escaped) {\n        return INTERIOR_SENTINEL;", "    if (accelerated) return float(saved_steps);\n    if (!escaped) {\n        return INTERIOR_SENTINEL;");
    defer alloc.free(with_result);
    const source = try alloc.dupeZ(u8, with_result);
    defer alloc.free(source);

    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);
    const pipeline = try compute.ComputePipeline.createFromSource(device, source);
    defer pipeline.destroy();

    const max_iter = 4096;
    const view = try viewport.SquareView.fromCenterSide(.{ .re = -0.1, .im = 0 }, 1.0e-20);
    var orbit = try perturb.ReferenceOrbit.compute(alloc, view.center(), max_iter);
    defer orbit.deinit(alloc);
    var table = try bla.BlaTable.build(alloc, &orbit, view.side * @sqrt(0.5));
    defer table.deinit(alloc);

    var band: [2]f32 = undefined;
    try compute.gpuIterateDeepBlaRows(pipeline, view, &orbit, &table, 2, 2, max_iter, 0, 1, &band);
    for (band) |saved| try std.testing.expect(saved > max_iter / 2);
}

test "compute: the quadratic kernel matches CPU exterior values after skips without replay" {
    const alloc = std.testing.allocator;
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);
    // Preserve the calculated smooth result, marking any replay or no-skip pixel
    // invalid at the dispatch boundary so neither path can satisfy parity.
    const shader = std.mem.span(compute.msl_source);
    const tracked = try replaceShaderOnce(alloc, shader, "    float uncertainty = 0.0f;", "    bool took_skip = false;\n    float uncertainty = 0.0f;");
    defer alloc.free(tracked);
    const marked = try replaceShaderOnce(alloc, tracked, "                    n += best_len;", "                    n += best_len;\n                    took_skip = true;");
    defer alloc.free(marked);
    const checked = try replaceShaderOnce(alloc, marked, "    return smooth_val;\n}\n\nkernel void mandelbrot_iterate_deep(", "    if (accelerated && !took_skip) replay = true;\n    return smooth_val;\n}\n\nkernel void mandelbrot_iterate_deep(");
    defer alloc.free(checked);
    const no_replay = try replaceShaderOnce(alloc, checked, "replay ? deep_pixel<false>(u, orbit, nullptr, gid, replay) : value", "replay ? INTERIOR_SENTINEL : value");
    defer alloc.free(no_replay);
    const source = try alloc.dupeZ(u8, no_replay);
    defer alloc.free(source);
    const pipeline = try compute.ComputePipeline.createFromSource(device, source);
    defer pipeline.destroy();

    const max_iter = 128;
    const view = try viewport.SquareView.fromCenterSide(.{ .re = 0.27, .im = 0 }, 1.0e-20);
    var orbit = try perturb.ReferenceOrbit.compute(alloc, view.center(), max_iter);
    defer orbit.deinit(alloc);
    var table = try bla.BlaTable.build(alloc, &orbit, view.side * @sqrt(0.5));
    defer table.deinit(alloc);

    var gpu_band: [2]f32 = undefined;
    var cpu_band: [2]f32 = undefined;
    try compute.gpuIterateDeepBlaRows(pipeline, view, &orbit, &table, 2, 2, max_iter, 0, 1, &gpu_band);
    try iterbuf.iterateDeepBandBlaInto(&cpu_band, view.rectViewport(2, 2), max_iter, 0, 1, &orbit, &table);

    for (gpu_band, cpu_band) |gpu_value, cpu_value| {
        try std.testing.expect(cpu_value != mandelbrot_mod.interior_sentinel);
        try std.testing.expectApproxEqAbs(cpu_value, gpu_value, 0.01);
    }
}

fn replaceShaderOnce(alloc: std.mem.Allocator, shader: []const u8, before: []const u8, after: []const u8) ![]u8 {
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, shader, before));
    return std.mem.replaceOwned(u8, alloc, shader, before, after);
}
