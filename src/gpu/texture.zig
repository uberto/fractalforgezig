//! CPU RGBA8 -> SDL_GPU texture upload path (the bridge from the pure fractal
//! render to something the GPU/ImGui can draw). This is a C-interop edge: SDL/GPU
//! C types live here behind `../c.zig`; the pure fractal core never touches them.
//!
//! Channel order is R,G,B,A to match `fractal/color.zig`'s `Rgba8` and T5's byte
//! order; the texture format is `SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM`.
//!
//! DATA FLOW IS ONE-DIRECTIONAL in the app: CPU render -> `upload` -> draw. The
//! `download` function copies a texture BACK to the CPU and exists ONLY for tests
//! and diagnostics; it must never be called on the render hot path (the
//! milestone's no-CPU-readback rule). It is deliberately the only reverse edge.
//!
//! On any SDL failure every function logs `std.log.err` (scope `.gpu`) with the
//! `SDL_GetError()` string via the pure builders in `message.zig` and returns a
//! Zig error — never `unreachable`, never a swallowed failure.
const std = @import("std");
const c = @import("../c.zig").c;
const message = @import("message.zig");

const log = std.log.scoped(.gpu);

/// Bytes per RGBA8 texel. The upload/download transfer buffers are sized against
/// this and it defines the tight-packing contract with `fractal/color.zig`.
pub const bytes_per_pixel: u32 = 4;

pub const Error = error{
    GpuTextureCreationFailed,
    GpuTransferBufferCreationFailed,
    GpuTransferBufferMapFailed,
    GpuCommandBufferFailed,
    GpuFenceSubmitFailed,
    GpuFenceWaitFailed,
    /// The caller-supplied pixel/out slice length does not equal
    /// `width * height * bytes_per_pixel` for the texture.
    PixelBufferSizeMismatch,
};

/// A sampled RGBA8 GPU texture plus its dimensions. `handle` stays behind this
/// edge; hand the whole `Texture` to the UI layer (T8). Call `destroy` once.
pub const Texture = struct {
    handle: *c.SDL_GPUTexture,
    width: u32,
    height: u32,
    device: *c.SDL_GPUDevice,

    /// Total tightly-packed RGBA8 byte size of this texture.
    pub fn byteSize(self: Texture) usize {
        return @as(usize, self.width) * @as(usize, self.height) * bytes_per_pixel;
    }

    /// Release the GPU texture. Call exactly once during teardown.
    pub fn destroy(self: Texture) void {
        c.SDL_ReleaseGPUTexture(self.device, self.handle);
    }
};

/// Create a sampled `R8G8B8A8_UNORM` 2D texture of `width` x `height`. On failure
/// logs `std.log.err` with the SDL error string and returns a Zig error.
///
/// Takes the raw `*SDL_GPUDevice` (not the windowed `Device`) so the texture path
/// is usable device-only, with no window/swapchain — this is what the headless
/// test and M1's offscreen compute both need.
pub fn createRgbaTexture(device: *c.SDL_GPUDevice, width: u32, height: u32) Error!Texture {
    var info = c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = width,
        .height = height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
    };
    const handle = c.SDL_CreateGPUTexture(device, &info) orelse {
        logSdlFailure("SDL_CreateGPUTexture");
        return Error.GpuTextureCreationFailed;
    };
    return .{ .handle = handle, .width = width, .height = height, .device = device };
}

/// Upload a tightly-packed RGBA8 buffer into `texture` via a transfer buffer and
/// a copy pass. `pixels.len` must equal `texture.byteSize()`. On any SDL failure
/// logs `std.log.err` with the SDL error string and returns a Zig error.
pub fn upload(device: *c.SDL_GPUDevice, texture: Texture, pixels: []const u8) Error!void {
    if (pixels.len != texture.byteSize()) return Error.PixelBufferSizeMismatch;

    const transfer = try createTransferBuffer(device, c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, texture);
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer);

    // Map, copy the CPU bytes in, unmap. `false` = do not cycle (fresh buffer).
    const mapped = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse {
        logSdlFailure("SDL_MapGPUTransferBuffer");
        return Error.GpuTransferBufferMapFailed;
    };
    const dst: [*]u8 = @ptrCast(mapped);
    @memcpy(dst[0..pixels.len], pixels);
    c.SDL_UnmapGPUTransferBuffer(device, transfer);

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        logSdlFailure("SDL_AcquireGPUCommandBuffer");
        return Error.GpuCommandBufferFailed;
    };
    const pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        logSdlFailure("SDL_BeginGPUCopyPass");
        return Error.GpuCommandBufferFailed;
    };
    var source = textureTransferInfo(transfer, texture);
    var region = textureRegion(texture);
    c.SDL_UploadToGPUTexture(pass, &source, &region, false);
    c.SDL_EndGPUCopyPass(pass);

    // A plain submit is enough: SDL guarantees the upload has completed before any
    // later command that reads the texture (e.g. the next-frame draw).
    if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
        logSdlFailure("SDL_SubmitGPUCommandBuffer");
        return Error.GpuFenceSubmitFailed;
    }
}

/// Copy `texture` back to CPU into `out` (tightly packed RGBA8). `out.len` must
/// equal `texture.byteSize()`.
///
/// DIAGNOSTIC / TEST ONLY. This is a GPU->CPU readback and must NOT be used on the
/// render hot path (milestone no-CPU-readback rule). It blocks on a fence so the
/// download has completed before the bytes are read. On any SDL failure logs
/// `std.log.err` with the SDL error string and returns a Zig error.
pub fn download(device: *c.SDL_GPUDevice, texture: Texture, out: []u8) Error!void {
    if (out.len != texture.byteSize()) return Error.PixelBufferSizeMismatch;

    const transfer = try createTransferBuffer(device, c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD, texture);
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer);

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        logSdlFailure("SDL_AcquireGPUCommandBuffer");
        return Error.GpuCommandBufferFailed;
    };
    const pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        logSdlFailure("SDL_BeginGPUCopyPass");
        return Error.GpuCommandBufferFailed;
    };
    var region = textureRegion(texture);
    var dest = textureTransferInfo(transfer, texture);
    c.SDL_DownloadFromGPUTexture(pass, &region, &dest);
    c.SDL_EndGPUCopyPass(pass);

    // A download is only guaranteed visible on the CPU after its fence signals.
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
    const src: [*]const u8 = @ptrCast(mapped);
    @memcpy(out, src[0..out.len]);
    c.SDL_UnmapGPUTransferBuffer(device, transfer);
}

fn createTransferBuffer(
    device: *c.SDL_GPUDevice,
    usage: c.SDL_GPUTransferBufferUsage,
    texture: Texture,
) Error!*c.SDL_GPUTransferBuffer {
    var info = c.SDL_GPUTransferBufferCreateInfo{
        .usage = usage,
        .size = @intCast(texture.byteSize()),
    };
    return c.SDL_CreateGPUTransferBuffer(device, &info) orelse {
        logSdlFailure("SDL_CreateGPUTransferBuffer");
        return Error.GpuTransferBufferCreationFailed;
    };
}

/// Tightly-packed transfer layout: `pixels_per_row`/`rows_per_layer` = 0 tells SDL
/// to use the region's width/height (no padding), matching our CPU buffers.
fn textureTransferInfo(transfer: *c.SDL_GPUTransferBuffer, texture: Texture) c.SDL_GPUTextureTransferInfo {
    _ = texture;
    return .{ .transfer_buffer = transfer, .offset = 0, .pixels_per_row = 0, .rows_per_layer = 0 };
}

fn textureRegion(texture: Texture) c.SDL_GPUTextureRegion {
    return .{
        .texture = texture.handle,
        .mip_level = 0,
        .layer = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .w = texture.width,
        .h = texture.height,
        .d = 1,
    };
}

fn logSdlFailure(call: []const u8) void {
    var buf: [256]u8 = undefined;
    const sdl_error = std.mem.span(c.SDL_GetError());
    const msg = message.sdlFailure(&buf, call, sdl_error) catch call;
    log.err("{s}", .{msg});
}

// ─── Tests ───────────────────────────────────────────────────────────────────
// These link the native stack (SDL/GPU); they run under `zig build test-gpu`
// (and are also wired into `zig build test`). The device-dependent tests SKIP
// cleanly (error.SkipZigTest) with a logged reason when the environment cannot
// create a GPU device, so headless CI never fails the suite for lack of a GPU.

const testing = std.testing;

/// Create a headless SDL_GPU device (no window / no swapchain claim) for tests,
/// or signal a clean skip. Metal needs the video subsystem initialised first.
fn openHeadlessDevice() error{SkipZigTest}!*c.SDL_GPUDevice {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        log.warn("skipping headless GPU test: SDL_Init failed: {s}", .{std.mem.span(c.SDL_GetError())});
        return error.SkipZigTest;
    }
    const shader_formats = c.SDL_GPU_SHADERFORMAT_MSL | c.SDL_GPU_SHADERFORMAT_METALLIB;
    return c.SDL_CreateGPUDevice(shader_formats, true, null) orelse {
        log.warn("skipping headless GPU test: no GPU device: {s}", .{std.mem.span(c.SDL_GetError())});
        c.SDL_Quit();
        return error.SkipZigTest;
    };
}

fn closeHeadlessDevice(device: *c.SDL_GPUDevice) void {
    c.SDL_DestroyGPUDevice(device);
    c.SDL_Quit();
}

test "the error-message builder embeds a texture call name and the SDL error" {
    // The pure builder shared with device.zig; pin it for the texture call sites
    // so the actionable failure string is guaranteed regardless of a live device.
    var buf: [128]u8 = undefined;
    const msg = try message.sdlFailure(&buf, "SDL_UploadToGPUTexture", "out of device memory");
    try testing.expectEqualStrings("SDL_UploadToGPUTexture failed: out of device memory", msg);
}

test "byteSize is width * height * 4 (tight RGBA8 packing)" {
    const t = Texture{ .handle = undefined, .width = 7, .height = 5, .device = undefined };
    try testing.expectEqual(@as(usize, 7 * 5 * 4), t.byteSize());
}

test "upload rejects a pixel buffer whose length does not match the texture" {
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);

    const tex = try createRgbaTexture(device, 4, 4);
    defer tex.destroy();

    var wrong: [4 * 4 * 4 - 1]u8 = undefined;
    try testing.expectError(Error.PixelBufferSizeMismatch, upload(device, tex, &wrong));
}

test "headless: a known RGBA8 pattern round-trips byte-identically through the GPU" {
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);

    const w: u32 = 8;
    const h: u32 = 8;
    const tex = try createRgbaTexture(device, w, h);
    defer tex.destroy();

    // A deterministic per-pixel pattern touching all four channels and both axes.
    var pattern: [w * h * 4]u8 = undefined;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const i = (y * w + x) * 4;
            pattern[i + 0] = @intCast(x * 32);
            pattern[i + 1] = @intCast(y * 32);
            pattern[i + 2] = @intCast((x + y) * 16);
            pattern[i + 3] = 255;
        }
    }

    try upload(device, tex, &pattern);

    var readback: [w * h * 4]u8 = undefined;
    try download(device, tex, &readback);

    try testing.expectEqualSlices(u8, &pattern, &readback);
}

test "headless: a real Mandelbrot RGBA buffer round-trips (pure core -> GPU -> back)" {
    const device = try openHeadlessDevice();
    defer closeHeadlessDevice(device);

    const mandelbrot = @import("../fractal/mandelbrot.zig");
    const color = @import("../fractal/color.zig");

    const w: u32 = 16;
    const h: u32 = 16;
    const max_iter: u32 = 512;
    const tex = try createRgbaTexture(device, w, h);
    defer tex.destroy();

    // Produce a recognizable Mandelbrot RGBA8 buffer from the pure core over the
    // milestone's fixed viewport, exactly as T6's render will feed the upload path.
    var image: [w * h * 4]u8 = undefined;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const c_re = -2.5 + (@as(f64, @floatFromInt(x)) / @as(f64, w)) * 3.5;
            const c_im = -1.25 + (@as(f64, @floatFromInt(y)) / @as(f64, h)) * 2.5;
            const smooth = mandelbrot.iterate(c_re, c_im, max_iter);
            const px = color.smoothToRgba(smooth, max_iter);
            const i = (y * w + x) * 4;
            image[i + 0] = px[0];
            image[i + 1] = px[1];
            image[i + 2] = px[2];
            image[i + 3] = px[3];
        }
    }

    try upload(device, tex, &image);

    var readback: [w * h * 4]u8 = undefined;
    try download(device, tex, &readback);

    try testing.expectEqualSlices(u8, &image, &readback);
}
