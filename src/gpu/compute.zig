//! SDL_GPU compute pipeline for Mandelbrot iteration.
//!
//! Owns the pipeline lifetime and exposes `gpuIterate` — the GPU equivalent of
//! `fractal/iterbuf.iterateInto`. The shader source is embedded at compile time
//! from `shaders/mandelbrot.metal` and compiled at runtime via SDL_GPU's MSL
//! backend (SDL_GPU_SHADERFORMAT_MSL) — no xcrun/metallib build step needed.
//!
//! DATA FLOW: uniforms → GPU compute → f32 storage buffer → download → iter []f32.
//! The iter buffer is then handed to the existing CPU colorpass unchanged.
//!
//! BANDS: a dispatch covers a horizontal BAND of the image (`row_offset`, `band_rows`), so the
//! progressive pass can split a render across frames on the GPU exactly as it does on the CPU.
//! A whole-image dispatch is just the band `(0, height)`. This matters at a high `max_iter`:
//! one dispatch over the full image can run for seconds and be aborted by the GPU's
//! command-buffer watchdog, which would then drop the whole render onto the CPU inside a
//! single frame.
//!
//! On any SDL failure every function logs through `emitErr` (scope `.gpu`, a no-op under test —
//! see its doc comment) with the SDL error string and returns a Zig error — never `unreachable`.
//! There are no direct `std.log.err` calls in this file, deliberately: one is enough to make
//! `zig build test-gpu` exit non-zero while reporting every test as passing.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const message = @import("message.zig");
const viewport = @import("../fractal/viewport.zig");
const perturb = @import("../fractal/perturb.zig");
const bla = @import("../fractal/bla.zig");
const engine = @import("../fractal/engine.zig");

const log = std.log.scoped(.gpu);

/// The MSL source embedded at compile time; passed to SDL_GPU as-is.
/// `pub` so a test can parse the shader's own struct declarations out of it and compare them
/// with the Zig uniform structs field-for-field — the layouts have to agree, and reading the
/// source the pipeline was really built from is the only check that cannot go stale.
pub const msl_source: [*:0]const u8 = @embedFile("shaders/mandelbrot.metal");

/// Uniform block passed to the shader — matches the MSL `MandelbrotUniforms`
/// struct field-for-field (C layout).
pub const MandelbrotUniforms = extern struct {
    center_re: f32,
    center_im: f32,
    scale: f32, // complex units per pixel (based on min(w,h))
    width: u32,
    /// The FULL image height, even for a one-row band: the complex mapping is anchored on the
    /// image center, so a band that lied about the height would render the wrong region.
    height: u32,
    max_iter: u32,
    /// First image row this dispatch computes.
    row_offset: u32 = 0,
    /// Rows this dispatch computes; `iter_out` holds exactly `width * band_rows` values.
    band_rows: u32,
};

/// Uniform block for the DEEP (perturbation) kernel — matches the MSL
/// `MandelbrotDeepUniforms` struct field-for-field (C layout), pinned by a test.
///
/// There is deliberately no centre here: the reference orbit's `Z_1` IS the centre `C`, at the
/// precision the CPU recorded it, and a deep pixel is only ever expressed as a DELTA from it.
/// An `f32` centre would be useless at these view sides anyway.
pub const MandelbrotDeepUniforms = extern struct {
    /// Complex units per pixel (based on `min(w, h)`), i.e. the delta step between neighbours.
    scale: f32,
    width: u32,
    /// The FULL image height, even for a one-row band — same anchoring rule as the shallow
    /// uniforms: the mapping is image-centred, so a band must not lie about the height.
    height: u32,
    max_iter: u32,
    /// First image row this dispatch computes.
    row_offset: u32 = 0,
    /// Rows this dispatch computes; `iter_out` holds exactly `width * band_rows` values.
    band_rows: u32,
    /// Entries in the orbit storage buffer (`Z_0 .. Z_{orbit_len-1}`); the kernel rebases when
    /// it runs off the end, so it must know where the end is.
    orbit_len: u32,
};

pub const Error = error{
    ShaderCompilationFailed,
    GpuBufferCreationFailed,
    GpuTransferBufferCreationFailed,
    GpuTransferBufferMapFailed,
    GpuCommandBufferFailed,
    GpuFenceSubmitFailed,
    GpuFenceWaitFailed,
    IterBufferSizeMismatch,
    /// `row_offset + band_rows` runs past `height`, so the band is not inside the image.
    BandOutOfBounds,
    /// The view side is below `perturb.gpu_floor_side`: `f32` deltas cannot resolve the pixel
    /// spacing, so the backend REFUSES rather than returning a wrong image. The engine checks
    /// the same condition before it ever calls a backend; this is defence in depth.
    BelowGpuPrecisionFloor,
    /// The reference orbit is longer than `perturb.gpu_max_orbit_len`, i.e. too large to upload
    /// per dispatch. Also refused, for the same reason.
    OrbitTooLongForGpu,
    BlaTableTooLongForGpu,
    BlaTableOrbitSizeMismatch,
};

/// Immutable Metal compute pipelines for shallow, deep and accelerated deep iteration.
/// Create once per device, then release all handles once during teardown.
pub const ComputePipeline = struct {
    handle: *c.SDL_GPUComputePipeline,
    /// The deep sibling of `handle`; used only by `dispatchDeep`.
    deep_handle: *c.SDL_GPUComputePipeline,
    bla_handle: *c.SDL_GPUComputePipeline,
    device: *c.SDL_GPUDevice,

    /// Compile the embedded MSL source via SDL_GPU's Metal backend and return
    /// the pipeline. Logs through `emitErr` (scope `.gpu`) and returns
    /// `ShaderCompilationFailed` on failure — never panics.
    pub fn create(device: *c.SDL_GPUDevice) Error!ComputePipeline {
        return createFromSource(device, msl_source);
    }

    /// `create`, with the MSL source given rather than embedded. The app only ever wants
    /// `create`; this seam exists so a test can drive the `ShaderCompilationFailed` path with a
    /// deliberately broken shader, which is the only untested exit from pipeline creation and the
    /// one a future edit of `mandelbrot.metal` is most likely to hit.
    pub fn createFromSource(device: *c.SDL_GPUDevice, source: [*:0]const u8) Error!ComputePipeline {
        const info = c.SDL_GPUComputePipelineCreateInfo{
            .code_size = std.mem.len(source),
            .code = @ptrCast(source),
            .entrypoint = "mandelbrot_iterate",
            .format = c.SDL_GPU_SHADERFORMAT_MSL,
            .num_samplers = 0,
            .num_readonly_storage_textures = 0,
            .num_readonly_storage_buffers = 0,
            .num_readwrite_storage_textures = 0,
            .num_readwrite_storage_buffers = 1, // iter_out — MSL buffer(1) (after uniforms)
            .num_uniform_buffers = 1, // MandelbrotUniforms — MSL buffer(0) (uniforms first)
            .threadcount_x = 64,
            .threadcount_y = 1,
            .threadcount_z = 1,
            .props = 0,
        };
        const handle = c.SDL_CreateGPUComputePipeline(device, &info) orelse {
            const sdl_err = std.mem.span(c.SDL_GetError());
            emitErr("SDL_CreateGPUComputePipeline failed: {s}", .{sdl_err});
            return Error.ShaderCompilationFailed;
        };

        // SDL assigns MSL `[[buffer(n)]]` slots in ONE order — uniform buffers, then read-only
        // storage buffers, then read-write storage buffers — so these counts are what place the
        // orbit at buffer(1) and the output at buffer(2). Declaring them in any other
        // combination silently misbinds: the kernel would read zeros, not fail.
        const deep_info = c.SDL_GPUComputePipelineCreateInfo{
            .code_size = std.mem.len(source),
            .code = @ptrCast(source),
            .entrypoint = "mandelbrot_iterate_deep",
            .format = c.SDL_GPU_SHADERFORMAT_MSL,
            .num_samplers = 0,
            .num_readonly_storage_textures = 0,
            .num_readonly_storage_buffers = 1, // orbit — MSL buffer(1)
            .num_readwrite_storage_textures = 0,
            .num_readwrite_storage_buffers = 1, // iter_out — MSL buffer(2), readwrite LAST
            .num_uniform_buffers = 1, // MandelbrotDeepUniforms — MSL buffer(0), uniforms FIRST
            .threadcount_x = 64,
            .threadcount_y = 1,
            .threadcount_z = 1,
            .props = 0,
        };
        const deep_handle = c.SDL_CreateGPUComputePipeline(device, &deep_info) orelse {
            const sdl_err = std.mem.span(c.SDL_GetError());
            emitErr("SDL_CreateGPUComputePipeline (deep) failed: {s}", .{sdl_err});
            c.SDL_ReleaseGPUComputePipeline(device, handle);
            return Error.ShaderCompilationFailed;
        };

        var bla_info = deep_info;
        bla_info.entrypoint = "mandelbrot_iterate_deep_bla";
        bla_info.num_readonly_storage_buffers = 2;
        const bla_handle = c.SDL_CreateGPUComputePipeline(device, &bla_info) orelse {
            logSdlFailure("SDL_CreateGPUComputePipeline (BLA)");
            c.SDL_ReleaseGPUComputePipeline(device, deep_handle);
            c.SDL_ReleaseGPUComputePipeline(device, handle);
            return Error.ShaderCompilationFailed;
        };
        return .{ .handle = handle, .deep_handle = deep_handle, .bla_handle = bla_handle, .device = device };
    }

    /// Release all pipelines. Call exactly once during teardown.
    pub fn destroy(self: ComputePipeline) void {
        c.SDL_ReleaseGPUComputePipeline(self.device, self.handle);
        c.SDL_ReleaseGPUComputePipeline(self.device, self.deep_handle);
        c.SDL_ReleaseGPUComputePipeline(self.device, self.bla_handle);
    }
};

/// Run the Mandelbrot compute shader for ONE BAND and download the results into `iter_out`,
/// whose length must equal `u.width * u.band_rows` — the band only, indexed from 0. The band
/// must lie inside the image (`row_offset + band_rows <= height`).
///
/// Synchronous: when this returns (success), `iter_out` contains valid f32 iter
/// values — negatives are interior pixels (sentinel -1.0), positives are smooth
/// escape values. Logs the GPU timing at `std.log.info(.gpu)`.
pub fn dispatch(
    pipeline: ComputePipeline,
    uniforms: MandelbrotUniforms,
    iter_out: []f32,
) Error!void {
    if (uniforms.row_offset + uniforms.band_rows > uniforms.height) {
        emitErr("dispatch: band rows {d}..{d} runs past the image height {d}", .{
            uniforms.row_offset,
            uniforms.row_offset + uniforms.band_rows,
            uniforms.height,
        });
        return Error.BandOutOfBounds;
    }
    const pixel_count: u32 = uniforms.width * uniforms.band_rows;
    if (iter_out.len != pixel_count) {
        emitErr("dispatch: iter_out.len={d} != width*band_rows={d}", .{ iter_out.len, pixel_count });
        return Error.IterBufferSizeMismatch;
    }
    if (pixel_count == 0) return; // an empty band is a no-op, not a zero-sized GPU buffer

    const device = pipeline.device;
    const byte_size: u32 = pixel_count * @sizeOf(f32);

    // Storage buffer the shader writes into.
    const storage_buf = c.SDL_CreateGPUBuffer(device, &c.SDL_GPUBufferCreateInfo{
        .usage = c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
        .size = byte_size,
        .props = 0,
    }) orelse {
        logSdlFailure("SDL_CreateGPUBuffer");
        return Error.GpuBufferCreationFailed;
    };
    defer c.SDL_ReleaseGPUBuffer(device, storage_buf);

    // Transfer buffer for downloading the result to CPU.
    const transfer = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
        .size = byte_size,
        .props = 0,
    }) orelse {
        logSdlFailure("SDL_CreateGPUTransferBuffer");
        return Error.GpuTransferBufferCreationFailed;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer);

    var opt_timer: ?std.time.Timer = std.time.Timer.start() catch null;

    // --- Compute pass ---
    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        logSdlFailure("SDL_AcquireGPUCommandBuffer");
        return Error.GpuCommandBufferFailed;
    };

    const rw_binding = c.SDL_GPUStorageBufferReadWriteBinding{
        .buffer = storage_buf,
        .cycle = false,
    };
    const pass = c.SDL_BeginGPUComputePass(cmd, null, 0, &rw_binding, 1) orelse {
        logSdlFailure("SDL_BeginGPUComputePass");
        _ = c.SDL_CancelGPUCommandBuffer(cmd);
        return Error.GpuCommandBufferFailed;
    };

    c.SDL_BindGPUComputePipeline(pass, pipeline.handle);

    // Bind the storage buffer at slot 0 (matches `buffer(0)` in the MSL kernel).
    const buf_ptr: *c.SDL_GPUBuffer = storage_buf;
    c.SDL_BindGPUComputeStorageBuffers(pass, 0, &buf_ptr, 1);

    // Push uniforms at slot 0 (matches `buffer(1)` — SDL counts uniform slots separately).
    c.SDL_PushGPUComputeUniformData(cmd, 0, &uniforms, @sizeOf(MandelbrotUniforms));

    // Dispatch: one thread per pixel, threadgroup size 64.
    const groups = (pixel_count + 63) / 64;
    c.SDL_DispatchGPUCompute(pass, groups, 1, 1);

    c.SDL_EndGPUComputePass(pass);

    // --- Copy pass: storage buffer → transfer buffer ---
    const copy_cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        logSdlFailure("SDL_AcquireGPUCommandBuffer (copy)");
        return Error.GpuCommandBufferFailed;
    };
    const copy_pass = c.SDL_BeginGPUCopyPass(copy_cmd) orelse {
        logSdlFailure("SDL_BeginGPUCopyPass");
        _ = c.SDL_CancelGPUCommandBuffer(copy_cmd);
        return Error.GpuCommandBufferFailed;
    };

    const src_region = c.SDL_GPUBufferRegion{
        .buffer = storage_buf,
        .offset = 0,
        .size = byte_size,
    };
    const dst_location = c.SDL_GPUTransferBufferLocation{
        .transfer_buffer = transfer,
        .offset = 0,
    };
    c.SDL_DownloadFromGPUBuffer(copy_pass, &src_region, &dst_location);
    c.SDL_EndGPUCopyPass(copy_pass);

    // Submit the compute command first, then the copy.
    if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
        logSdlFailure("SDL_SubmitGPUCommandBuffer (compute)");
        return Error.GpuFenceSubmitFailed;
    }

    // Submit copy and wait on fence so download is visible on CPU.
    const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(copy_cmd) orelse {
        logSdlFailure("SDL_SubmitGPUCommandBufferAndAcquireFence");
        return Error.GpuFenceSubmitFailed;
    };
    defer c.SDL_ReleaseGPUFence(device, fence);
    var fences = [_]?*c.SDL_GPUFence{fence};
    if (!c.SDL_WaitForGPUFences(device, true, &fences, 1)) {
        logSdlFailure("SDL_WaitForGPUFences");
        return Error.GpuFenceWaitFailed;
    }

    // Map the transfer buffer and copy f32 results to iter_out.
    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse {
        logSdlFailure("SDL_MapGPUTransferBuffer");
        return Error.GpuTransferBufferMapFailed;
    };
    const src_f32: [*]const f32 = @ptrCast(@alignCast(mapped));
    @memcpy(iter_out, src_f32[0..pixel_count]);
    c.SDL_UnmapGPUTransferBuffer(device, transfer);

    if (opt_timer) |*t| {
        const elapsed_ms = @as(f64, @floatFromInt(t.read())) / 1_000_000.0;
        log.info("gpu iterate: {d}x{d} rows {d}..{d}, max_iter={d}, {d:.2} ms", .{
            uniforms.width,
            uniforms.height,
            uniforms.row_offset,
            uniforms.row_offset + uniforms.band_rows,
            uniforms.max_iter,
            elapsed_ms,
        });
    }
}

/// High-level GPU iteration for the ROW BAND `y0 .. y0+rows` of a `w x h` image: build the
/// uniforms, dispatch, download, log timing. The GPU equivalent of
/// `iterbuf.iterateRowsInto`, and like it, `iter_band` is the band ALONE — exactly `rows * w`
/// values, written from index 0. `scale` uses `min(w, h)` (the whole image), so bands of one
/// image always agree on the mapping.
pub fn gpuIterateRows(
    pipeline: ComputePipeline,
    view: viewport.SquareView,
    w: u32,
    h: u32,
    max_iter: u32,
    y0: u32,
    rows: u32,
    iter_band: []f32,
) Error!void {
    const scale = view.side / @as(f64, @floatFromInt(@min(w, h)));
    const uniforms = MandelbrotUniforms{
        .center_re = @floatCast(view.center_re),
        .center_im = @floatCast(view.center_im),
        .scale = @floatCast(scale),
        .width = w,
        .height = h,
        .max_iter = max_iter,
        .row_offset = y0,
        .band_rows = rows,
    };
    try dispatch(pipeline, uniforms, iter_band);
}

/// Whole-image GPU iteration: the band `(0, h)`. Equivalent of `iterbuf.iterateInto` on GPU.
/// `iter.len` must equal `w * h`.
pub fn gpuIterate(
    pipeline: ComputePipeline,
    view: viewport.SquareView,
    w: u32,
    h: u32,
    max_iter: u32,
    iter: []f32,
) Error!void {
    try gpuIterateRows(pipeline, view, w, h, max_iter, 0, h, iter);
}

/// Storage ABI shared with Metal. Fields are scalar so both sides use a 48-byte stride.
pub const GpuBlaBlock = extern struct {
    a_re: f32 = 0,
    a_im: f32 = 0,
    q_re: f32 = 0,
    q_im: f32 = 0,
    b_re: f32 = 0,
    b_im: f32 = 0,
    r: f32 = 0,
    cubic: f32 = 0,
    mixed: f32 = 0,
    parameter_squared: f32 = 0,
    delta_roundoff: f32 = 0,
    parameter_roundoff: f32 = 0,
};

fn packBlaTable(table: *const bla.BlaTable, dst: []GpuBlaBlock) void {
    // Entry zero carries the parameter domain. Remaining entries are flattened low-to-high
    // by level, so the shader can derive every index from the orbit length.
    // Lift the propagated CPU roundoff terms to the shader precision.
    const roundoff_ratio = @as(f64, std.math.floatEps(f32)) / std.math.floatEps(f64);
    const margin = 1 - 8 * @as(f64, std.math.floatEps(f32));
    dst[0] = .{ .r = if (dst.len > 1) @floatCast(table.max_dc * margin) else 0 };
    var index: usize = 1;
    for (table.levels) |level| {
        for (level) |block| {
            var packed_block = GpuBlaBlock{
                .a_re = @floatCast(block.a_re),
                .a_im = @floatCast(block.a_im),
                .q_re = @floatCast(block.q_re),
                .q_im = @floatCast(block.q_im),
                .b_re = @floatCast(block.b_re),
                .b_im = @floatCast(block.b_im),
                .r = @floatCast(block.r * margin),
                .cubic = @floatCast(block.remainder.cubic),
                .mixed = @floatCast(block.remainder.mixed),
                .parameter_squared = @floatCast(block.remainder.parameter_squared),
                .delta_roundoff = @floatCast(block.remainder.delta_roundoff * roundoff_ratio),
                .parameter_roundoff = @floatCast(block.remainder.parameter_roundoff * roundoff_ratio),
            };
            inline for (@typeInfo(GpuBlaBlock).@"struct".fields) |field| {
                if (!std.math.isFinite(@field(packed_block, field.name))) packed_block = .{};
            }
            dst[index] = packed_block;
            index += 1;
        }
    }
    std.debug.assert(index == dst.len);
}

/// Upload the orbit, run the deep perturbation kernel for one row band, then read it back.
pub fn dispatchDeep(
    pipeline: ComputePipeline,
    uniforms: MandelbrotDeepUniforms,
    orbit: *const perturb.ReferenceOrbit,
    iter_out: []f32,
) Error!void {
    return dispatchDeepWithTable(pipeline, uniforms, orbit, null, iter_out);
}

fn dispatchDeepWithTable(
    pipeline: ComputePipeline,
    uniforms: MandelbrotDeepUniforms,
    orbit: *const perturb.ReferenceOrbit,
    table: ?*const bla.BlaTable,
    iter_out: []f32,
) Error!void {
    if (uniforms.row_offset + uniforms.band_rows > uniforms.height) {
        emitErr("dispatchDeep: band rows {d}..{d} runs past the image height {d}", .{
            uniforms.row_offset,
            uniforms.row_offset + uniforms.band_rows,
            uniforms.height,
        });
        return Error.BandOutOfBounds;
    }
    const pixel_count: u32 = uniforms.width * uniforms.band_rows;
    if (iter_out.len != pixel_count) {
        emitErr("dispatchDeep: iter_out.len={d} != width*band_rows={d}", .{ iter_out.len, pixel_count });
        return Error.IterBufferSizeMismatch;
    }
    if (pixel_count == 0) return; // an empty band is a no-op, not a zero-sized GPU buffer

    const device = pipeline.device;
    const byte_size: u32 = pixel_count * @sizeOf(f32);
    const orbit_len = orbit.len();
    // `Z_0` alone cannot be iterated against; the kernel answers `interior_sentinel` for it, and
    // a zero-sized buffer is not creatable, so give it one entry to bind.
    const orbit_entries: u32 = @intCast(@max(orbit_len, 1));
    const orbit_bytes: u32 = orbit_entries * 2 * @sizeOf(f32);

    // Storage buffer the shader writes into.
    const storage_buf = c.SDL_CreateGPUBuffer(device, &c.SDL_GPUBufferCreateInfo{
        .usage = c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
        .size = byte_size,
        .props = 0,
    }) orelse {
        logSdlFailure("SDL_CreateGPUBuffer");
        return Error.GpuBufferCreationFailed;
    };
    defer c.SDL_ReleaseGPUBuffer(device, storage_buf);

    // Read-only storage buffer holding the reference orbit as `float2` pairs.
    const orbit_buf = c.SDL_CreateGPUBuffer(device, &c.SDL_GPUBufferCreateInfo{
        .usage = c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ,
        .size = orbit_bytes,
        .props = 0,
    }) orelse {
        logSdlFailure("SDL_CreateGPUBuffer (orbit)");
        return Error.GpuBufferCreationFailed;
    };
    defer c.SDL_ReleaseGPUBuffer(device, orbit_buf);

    // Transfer buffer for uploading the orbit.
    const orbit_transfer = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = orbit_bytes,
        .props = 0,
    }) orelse {
        logSdlFailure("SDL_CreateGPUTransferBuffer (orbit)");
        return Error.GpuTransferBufferCreationFailed;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(device, orbit_transfer);

    const table_entries = if (table) |t| t.len() + 1 else 0;
    const table_bytes: u32 = @intCast(table_entries * @sizeOf(GpuBlaBlock));
    const table_buf = if (table == null) null else c.SDL_CreateGPUBuffer(device, &.{
        .usage = c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ,
        .size = table_bytes,
        .props = 0,
    }) orelse {
        logSdlFailure("SDL_CreateGPUBuffer (BLA table)");
        return Error.GpuBufferCreationFailed;
    };
    defer if (table_buf) |buf| c.SDL_ReleaseGPUBuffer(device, buf);

    const table_transfer = if (table == null) null else c.SDL_CreateGPUTransferBuffer(device, &.{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = table_bytes,
        .props = 0,
    }) orelse {
        logSdlFailure("SDL_CreateGPUTransferBuffer (BLA table)");
        return Error.GpuTransferBufferCreationFailed;
    };
    defer if (table_transfer) |buf| c.SDL_ReleaseGPUTransferBuffer(device, buf);
    if (table_transfer) |upload| {
        const mapped = c.SDL_MapGPUTransferBuffer(device, upload, false) orelse {
            logSdlFailure("SDL_MapGPUTransferBuffer (BLA table)");
            return Error.GpuTransferBufferMapFailed;
        };
        const dst: [*]GpuBlaBlock = @ptrCast(@alignCast(mapped));
        packBlaTable(table.?, dst[0..table_entries]);
        c.SDL_UnmapGPUTransferBuffer(device, upload);
    }

    // Transfer buffer for downloading the result to CPU.
    const transfer = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
        .size = byte_size,
        .props = 0,
    }) orelse {
        logSdlFailure("SDL_CreateGPUTransferBuffer");
        return Error.GpuTransferBufferCreationFailed;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer);

    // Narrow the orbit into the mapped upload buffer directly: no intermediate allocation, so
    // this stays callable from an `IterFn` that has no allocator.
    {
        const mapped = c.SDL_MapGPUTransferBuffer(device, orbit_transfer, false) orelse {
            logSdlFailure("SDL_MapGPUTransferBuffer (orbit)");
            return Error.GpuTransferBufferMapFailed;
        };
        const dst: [*][2]f32 = @ptrCast(@alignCast(mapped));
        for (0..orbit_entries) |i| {
            if (i < orbit_len) {
                dst[i] = .{ @floatCast(orbit.re[i]), @floatCast(orbit.im[i]) };
            } else {
                dst[i] = .{ 0.0, 0.0 };
            }
        }
        c.SDL_UnmapGPUTransferBuffer(device, orbit_transfer);
    }

    var opt_timer: ?std.time.Timer = std.time.Timer.start() catch null;

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        logSdlFailure("SDL_AcquireGPUCommandBuffer");
        return Error.GpuCommandBufferFailed;
    };

    // --- Upload pass: transfer buffers → read-only orbit and optional BLA table ---
    // In the SAME command buffer as the compute pass below, and before it, so the upload is
    // ordered ahead of the dispatch that reads it without a second fence.
    {
        const upload_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
            logSdlFailure("SDL_BeginGPUCopyPass (orbit upload)");
            _ = c.SDL_CancelGPUCommandBuffer(cmd);
            return Error.GpuCommandBufferFailed;
        };
        const src_location = c.SDL_GPUTransferBufferLocation{
            .transfer_buffer = orbit_transfer,
            .offset = 0,
        };
        const dst_region = c.SDL_GPUBufferRegion{
            .buffer = orbit_buf,
            .offset = 0,
            .size = orbit_bytes,
        };
        c.SDL_UploadToGPUBuffer(upload_pass, &src_location, &dst_region, false);
        if (table_transfer) |upload| {
            c.SDL_UploadToGPUBuffer(
                upload_pass,
                &.{ .transfer_buffer = upload, .offset = 0 },
                &.{ .buffer = table_buf.?, .offset = 0, .size = table_bytes },
                false,
            );
        }
        c.SDL_EndGPUCopyPass(upload_pass);
    }

    // --- Compute pass ---
    const rw_binding = c.SDL_GPUStorageBufferReadWriteBinding{
        .buffer = storage_buf,
        .cycle = false,
    };
    const pass = c.SDL_BeginGPUComputePass(cmd, null, 0, &rw_binding, 1) orelse {
        logSdlFailure("SDL_BeginGPUComputePass");
        _ = c.SDL_CancelGPUCommandBuffer(cmd);
        return Error.GpuCommandBufferFailed;
    };

    c.SDL_BindGPUComputePipeline(pass, if (table == null) pipeline.deep_handle else pipeline.bla_handle);

    // SDL places the writable result after every read-only buffer. Uniform and orbit
    // remain at MSL slots 0 and 1. Output is at 2 for plain deep and 3 for BLA.
    const reads = [_]*c.SDL_GPUBuffer{ orbit_buf, table_buf orelse orbit_buf };
    c.SDL_BindGPUComputeStorageBuffers(pass, 0, &reads, if (table == null) 1 else 2);

    // Uniform slot 0 = MSL buffer(0); SDL counts uniform slots separately.
    c.SDL_PushGPUComputeUniformData(cmd, 0, &uniforms, @sizeOf(MandelbrotDeepUniforms));

    const groups = (pixel_count + 63) / 64;
    c.SDL_DispatchGPUCompute(pass, groups, 1, 1);

    c.SDL_EndGPUComputePass(pass);

    // --- Copy pass: storage buffer → transfer buffer ---
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        logSdlFailure("SDL_BeginGPUCopyPass (readback)");
        _ = c.SDL_CancelGPUCommandBuffer(cmd);
        return Error.GpuCommandBufferFailed;
    };

    const src_region = c.SDL_GPUBufferRegion{
        .buffer = storage_buf,
        .offset = 0,
        .size = byte_size,
    };
    const dst_location = c.SDL_GPUTransferBufferLocation{
        .transfer_buffer = transfer,
        .offset = 0,
    };
    c.SDL_DownloadFromGPUBuffer(copy_pass, &src_region, &dst_location);
    c.SDL_EndGPUCopyPass(copy_pass);

    const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd) orelse {
        logSdlFailure("SDL_SubmitGPUCommandBufferAndAcquireFence");
        return Error.GpuFenceSubmitFailed;
    };
    defer c.SDL_ReleaseGPUFence(device, fence);
    var fences = [_]?*c.SDL_GPUFence{fence};
    if (!c.SDL_WaitForGPUFences(device, true, &fences, 1)) {
        logSdlFailure("SDL_WaitForGPUFences");
        return Error.GpuFenceWaitFailed;
    }

    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse {
        logSdlFailure("SDL_MapGPUTransferBuffer");
        return Error.GpuTransferBufferMapFailed;
    };
    const src_f32: [*]const f32 = @ptrCast(@alignCast(mapped));
    @memcpy(iter_out, src_f32[0..pixel_count]);
    c.SDL_UnmapGPUTransferBuffer(device, transfer);

    if (opt_timer) |*t| {
        const elapsed_ms = @as(f64, @floatFromInt(t.read())) / 1_000_000.0;
        var buf: [160]u8 = undefined;
        const msg = message.gpuDeepIterateSummary(
            &buf,
            uniforms.width,
            uniforms.height,
            uniforms.row_offset,
            uniforms.band_rows,
            uniforms.max_iter,
            orbit_len,
            if (table != null) table_entries - 1 else null,
            elapsed_ms,
        ) catch return;
        log.info("{s}", .{msg});
    }
}

/// High-level DEEP GPU iteration for the ROW BAND `y0 .. y0+rows` of a `w x h` image: the deep
/// sibling of `gpuIterateRows`, and the GPU equivalent of `iterbuf.iterateDeepBandInto`.
/// `iter_band` is the band ALONE — exactly `rows * w` values, written from index 0.
///
/// REFUSES, before touching the GPU, any view the `f32` kernel cannot render honestly:
/// `engine.gpuDeepFallbackReason` is the one definition of that envelope, and the engine has
/// already consulted it, so reaching a refusal here means a caller bypassed the engine. Refusing
/// twice is cheap; rendering a wrong deep image is not.
pub fn gpuIterateDeepRows(
    pipeline: ComputePipeline,
    view: viewport.SquareView,
    orbit: *const perturb.ReferenceOrbit,
    w: u32,
    h: u32,
    max_iter: u32,
    y0: u32,
    rows: u32,
    iter_band: []f32,
) Error!void {
    return gpuIterateDeepRowsWithTable(pipeline, view, orbit, null, w, h, max_iter, y0, rows, iter_band);
}

/// Accelerated sibling of gpuIterateDeepRows, using this render's CPU-built BLA table.
pub fn gpuIterateDeepBlaRows(
    pipeline: ComputePipeline,
    view: viewport.SquareView,
    orbit: *const perturb.ReferenceOrbit,
    table: *const bla.BlaTable,
    w: u32,
    h: u32,
    max_iter: u32,
    y0: u32,
    rows: u32,
    iter_band: []f32,
) Error!void {
    const blocks = table.len();
    if (blocks > bla.gpu_max_table_len) {
        emitErr("gpuIterateDeepBlaRows: table of {d} blocks exceeds the GPU budget of {d}; use CPU", .{
            blocks, bla.gpu_max_table_len,
        });
        return Error.BlaTableTooLongForGpu;
    }
    if (blocks > 0 and !tableMatchesOrbit(table, orbit.len())) {
        emitErr("gpuIterateDeepBlaRows: table dimensions do not match orbit length {d}; rebuild the table", .{orbit.len()});
        return Error.BlaTableOrbitSizeMismatch;
    }
    return gpuIterateDeepRowsWithTable(pipeline, view, orbit, table, w, h, max_iter, y0, rows, iter_band);
}

// Shader offsets depend on the orbit length. Check each level before uploading.
fn tableMatchesOrbit(table: *const bla.BlaTable, orbit_len: usize) bool {
    var expected = orbit_len -| 1;
    for (table.levels) |level| {
        if (expected == 0 or level.len != expected) return false;
        expected /= 2;
    }
    return expected == 0;
}

fn gpuIterateDeepRowsWithTable(
    pipeline: ComputePipeline,
    view: viewport.SquareView,
    orbit: *const perturb.ReferenceOrbit,
    table: ?*const bla.BlaTable,
    w: u32,
    h: u32,
    max_iter: u32,
    y0: u32,
    rows: u32,
    iter_band: []f32,
) Error!void {
    if (engine.gpuDeepFallbackReason(view.side, orbit.len())) |reason| {
        switch (reason) {
            .below_gpu_precision_floor => {
                emitErr("gpuIterateDeepRows: view side {e} is below the GPU precision floor {e}", .{
                    view.side,
                    perturb.gpu_floor_side,
                });
                return Error.BelowGpuPrecisionFloor;
            },
            .orbit_too_long_for_gpu => {
                emitErr("gpuIterateDeepRows: orbit of {d} entries exceeds the GPU budget of {d}", .{
                    orbit.len(),
                    perturb.gpu_max_orbit_len,
                });
                return Error.OrbitTooLongForGpu;
            },
        }
    }

    const scale = view.side / @as(f64, @floatFromInt(@min(w, h)));
    const uniforms = MandelbrotDeepUniforms{
        .scale = @floatCast(scale),
        .width = w,
        .height = h,
        .max_iter = max_iter,
        .row_offset = y0,
        .band_rows = rows,
        .orbit_len = @intCast(orbit.len()),
    };
    try dispatchDeepWithTable(pipeline, uniforms, orbit, table, iter_band);
}

fn logSdlFailure(call: []const u8) void {
    var buf: [256]u8 = undefined;
    const sdl_error = std.mem.span(c.SDL_GetError());
    const msg = message.sdlFailure(&buf, call, sdl_error) catch call;
    emitErr("{s}", .{msg});
}

/// `std.log.err` (scope `.gpu`) in the app, a NO-OP in tests — same reason as
/// `fractal/engine.zig`'s `emitErr`: Zig 0.15's test runner panics on any logged error, so a
/// test that drives a rejection path (e.g. an out-of-bounds band) could never be green.
/// The typed error is still returned and asserted; nothing observable is lost.
fn emitErr(comptime format: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    log.err(format, args);
}
