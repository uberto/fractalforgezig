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
//! On any SDL failure every function logs `std.log.err` (scope `.gpu`) with the
//! SDL error string and returns a Zig error — never `unreachable`.
const std = @import("std");
const c = @import("../c.zig").c;
const message = @import("message.zig");
const viewport_mod = @import("../fractal/viewport.zig");

const log = std.log.scoped(.gpu);

/// The MSL source embedded at compile time; passed to SDL_GPU as-is.
const msl_source: [*:0]const u8 = @embedFile("shaders/mandelbrot.metal");

/// Uniform block passed to the shader — matches the MSL `MandelbrotUniforms`
/// struct field-for-field (C layout, no padding between f32 and u32 pairs).
pub const MandelbrotUniforms = extern struct {
    center_re: f32,
    center_im: f32,
    scale: f32,
    side: u32,
    max_iter: u32,
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
            .num_readwrite_storage_buffers = 1, // iter_out buffer(0)
            .num_uniform_buffers = 1, // MandelbrotUniforms buffer(1)
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

/// Run the Mandelbrot compute shader for one full frame and download the results
/// into `iter_out`. `iter_out.len` must equal `u.side * u.side`.
///
/// Synchronous: when this returns (success), `iter_out` contains valid f32 iter
/// values — negatives are interior pixels (sentinel -1.0), positives are smooth
/// escape values. Logs the GPU timing at `std.log.info(.gpu)`.
pub fn dispatch(
    pipeline: ComputePipeline,
    uniforms: MandelbrotUniforms,
    iter_out: []f32,
) Error!void {
    const pixel_count: u32 = uniforms.side * uniforms.side;
    if (iter_out.len != pixel_count) return Error.IterBufferSizeMismatch;

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
        log.info("gpu iterate: S={d}, max_iter={d}, {d:.2} ms", .{ uniforms.side, uniforms.max_iter, elapsed_ms });
    }
}

fn logSdlFailure(call: []const u8) void {
    var buf: [256]u8 = undefined;
    const sdl_error = std.mem.span(c.SDL_GetError());
    const msg = message.sdlFailure(&buf, call, sdl_error) catch call;
    log.err("{s}", .{msg});
}
