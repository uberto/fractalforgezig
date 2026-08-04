<!-- LLM-only context for src/gpu/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/gpu/ context

## Purpose

Own the SDL_GPU device lifecycle and the RGBA -> texture upload path. On macOS
the backend is Metal. This folder is a C-interop edge: SDL/GPU C types live here
and behind `../c.zig`; never leak them into the pure fractal core.

## Files

- `device.zig` — `Device` struct wrapping `*SDL_GPUDevice` + `*SDL_Window`.
  - `Device.create(window)` calls `SDL_CreateGPUDevice` requesting
    `SDL_GPU_SHADERFORMAT_MSL | SDL_GPU_SHADERFORMAT_METALLIB` (the ImGui SDLGPU3
    backend needs one of these on Metal), then `SDL_ClaimWindowForGPUDevice`.
    Logs the driver name (`std.log.scoped(.gpu)`, e.g. `driver=metal`) on success.
    On failure logs `std.log.err` with the `SDL_GetError()` string and returns
    `error.GpuDeviceCreationFailed` / `error.GpuWindowClaimFailed` — never panics.
  - `Device.swapchainTextureFormat()` -> `SDL_GetGPUSwapchainTextureFormat`; hand
    this to the ImGui renderer backend so its pipeline matches the swapchain.
  - `Device.destroy()` releases the window then destroys the device. Call once.
- `texture.zig` (T7) — CPU RGBA8 -> `SDL_GPU` texture path; takes the raw
  `*SDL_GPUDevice` (not the windowed `Device`) so it works device-only.
  - `createRgbaTexture(device, w, h)` -> `Texture` (`R8G8B8A8_UNORM`, `SAMPLER`,
    one mip). `Texture` = `{handle, width, height, device}`; `byteSize()` = w*h*4;
    `destroy()` once. Channel order R,G,B,A matches `fractal/color.zig` `Rgba8`.
  - `upload(device, tex, pixels)` — transfer buffer (`UPLOAD`) -> map/memcpy/unmap
    -> copy pass `SDL_UploadToGPUTexture` -> plain submit. `pixels.len` must equal
    `tex.byteSize()` or `error.PixelBufferSizeMismatch`.
  - `download(device, tex, out)` — DIAGNOSTIC/TEST ONLY GPU->CPU readback; never
    on the hot path. Copy pass `SDL_DownloadFromGPUTexture` -> submit-and-acquire-
    fence -> `SDL_WaitForGPUFences` -> map/memcpy/unmap.
  - All SDL failures log `std.log.err` via `message.sdlFailure` and return a Zig
    `Error` variant — never `unreachable`.
- `compute.zig` (M4 T2) — Metal compute pipeline for GPU Mandelbrot iteration.
  - `MandelbrotUniforms` extern struct: `{center_re, center_im, scale: f32, side, max_iter: u32}`.
    Must match the MSL `MandelbrotUniforms` in `shaders/mandelbrot.metal` field-for-field.
  - `ComputePipeline.create(device) Error!ComputePipeline` — compiles the embedded MSL
    source (`@embedFile("shaders/mandelbrot.metal")`) via `SDL_CreateGPUComputePipeline`
    with `SDL_GPU_SHADERFORMAT_MSL`. Entry point `"mandelbrot_iterate"`, threadcount 64×1×1,
    1 readwrite storage buffer, 1 uniform buffer. Logs + returns `ShaderCompilationFailed`
    on failure.
  - `ComputePipeline.destroy()` — releases the pipeline.
  - `dispatch(pipeline, uniforms, iter_out: []f32) Error!void` — synchronous: acquires
    command buffer → compute pass (bind pipeline + storage buffer + push uniforms) →
    dispatch `(side*side + 63)/64` threadgroups → end pass → submit → copy pass to
    transfer buffer → submit + wait fence → map + memcpy into `iter_out`. The caller's
    `iter_out` is valid on return. `iter_out.len` must equal `side*side` or
    `IterBufferSizeMismatch`.
  - `shaders/mandelbrot.metal` — MSL compute kernel; `half` is reserved in MSL, use
    `side_half` for the viewport-center variable.
- `message.zig` — PURE log/summary string builders (`sdlFailure`, `deviceReady`),
  no SDL import, unit-tested in the fast tier. `device.zig` uses them for the
  strings it hands to `std.log`. Add new observability strings here so they stay
  testable; `src/root.zig` aggregates this module's tests.

## Interop rule

`device.zig` and `texture.zig` import `../c.zig` (SDL3 + SDL_GPU). Keep pure logic
in `message.zig` so the fast tier needs no device. Only `message.zig` (pure) is
aggregated into `src/root.zig`; C-linking tests use `gpu_headless_test.zig`.

## Frame lifecycle (driven from main.zig)

1. `SDL_AcquireGPUCommandBuffer(device.handle)`.
2. `SDL_WaitAndAcquireGPUSwapchainTexture(cmd, window, &tex, null, null)`; if it
   fails or `tex` is null (minimized), submit the empty command buffer and skip.
3. ImGui: upload buffers BEFORE the pass (`Ui.prepareDrawData(cmd)`).
4. `SDL_BeginGPURenderPass` with one `SDL_GPUColorTargetInfo` (LOADOP_CLEAR,
   STOREOP_STORE, `texture = swapchain tex`).
5. `Ui.renderDrawData(cmd, pass)`, then `SDL_EndGPURenderPass`.
6. `SDL_SubmitGPUCommandBuffer(cmd)`.

Swapchain resize is automatic; re-read size each frame, do nothing special.

## Gotchas

- `SDL_CreateGPUDevice` returns an optional pointer -> use `orelse`.
- Debug mode is enabled in `create` (2nd arg `true`) for validation while in M0.
- Headless GPU test: root `src/gpu_headless_test.zig` (in `src/` so `../c.zig` /
  `../fractal/*` resolve), the ONE C-linking artifact. `zig build test-gpu` runs
  it; `zig build test` depends on it. SKIPS cleanly (`error.SkipZigTest`, logged
  `warn`) when SDL_Init/`SDL_CreateGPUDevice` fail, so no-GPU CI never fails. For
  a windowless device, `SDL_CreateGPUDevice` WITHOUT `SDL_ClaimWindowForGPUDevice`.
- Keep the app's RGBA -> texture path one-directional; `download` is the only
  (test/diagnostic) reverse edge — no hot-path readback.
