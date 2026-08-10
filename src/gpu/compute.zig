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
//! On any SDL failure every function logs `std.log.err` (scope `.gpu`) with the
//! SDL error string and returns a Zig error — never `unreachable`.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const message = @import("message.zig");
const viewport = @import("../fractal/viewport.zig");

const log = std.log.scoped(.gpu);

/// The MSL source embedded at compile time; passed to SDL_GPU as-is.
const msl_source: [*:0]const u8 = @embedFile("shaders/mandelbrot.metal");

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
};

/// A compiled Metal compute pipeline for `mandelbrot_iterate`.
/// Call `create` once per device; `destroy` once during teardown.
pub const ComputePipeline = struct {
    handle: *c.SDL_GPUComputePipeline,
    device: *c.SDL_GPUDevice,

    /// Compile the embedded MSL source via SDL_GPU's Metal backend and return
    /// the pipeline. Logs `std.log.err(.gpu)` and returns `ShaderCompilationFailed`
    /// on failure — never panics.
    pub fn create(device: *c.SDL_GPUDevice) Error!ComputePipeline {
        const info = c.SDL_GPUComputePipelineCreateInfo{
            .code_size = std.mem.len(msl_source),
            .code = @ptrCast(msl_source),
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
            log.err("SDL_CreateGPUComputePipeline failed: {s}", .{sdl_err});
            return Error.ShaderCompilationFailed;
        };
        return .{ .handle = handle, .device = device };
    }

    /// Release the pipeline. Call exactly once during teardown.
    pub fn destroy(self: ComputePipeline) void {
        c.SDL_ReleaseGPUComputePipeline(self.device, self.handle);
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
