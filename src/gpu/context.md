<!-- LLM-only context for src/gpu/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/gpu/ context

## Purpose

C-interop edge: SDL_GPU device lifecycle, RGBA→texture upload, and Metal compute iteration.
Never leak SDL/GPU types into `src/fractal/` (pure tier).

## Files

- `device.zig` — `Device{handle, window}`. `Device.create(window)` requests
  `SDL_GPU_SHADERFORMAT_MSL | SDL_GPU_SHADERFORMAT_METALLIB`, claims window swapchain.
  Logs driver name on success; `std.log.err` + typed error on failure. `destroy()` once.
  `swapchainTextureFormat()` → hand to ImGui SDLGPU3 backend.
- `texture.zig` — CPU RGBA8 → GPU texture. `createRgbaTexture(device, w, h)` → `Texture`.
  `upload(device, tex, pixels)`: transfer buffer → copy pass → submit. `download` is
  DIAGNOSTIC/TEST ONLY — never on hot path. All SDL failures → `std.log.err` + Zig error.
- `compute.zig` (M4) — GPU Mandelbrot iteration via Metal compute.
  - `MandelbrotUniforms` extern struct: `{center_re, center_im, scale: f32, width, height,
    max_iter, row_offset, band_rows: u32}`. Must match `shaders/mandelbrot.metal` MSL struct
    field-for-field. `height` is always the FULL image height — the mapping is image-anchored,
    so a band must NOT shrink it; only `row_offset`/`band_rows` select the rows.
  - `ComputePipeline.create(device)` — `SDL_CreateGPUComputePipeline` with
    `SDL_GPU_SHADERFORMAT_MSL`, entry `"mandelbrot_iterate"`, threadcount 64×1×1,
    1 readwrite storage buffer, 1 uniform buffer. `ShaderCompilationFailed` on error.
  - `dispatch(pipeline, uniforms, iter_out: []f32)` — synchronous: compute pass →
    copy pass → fence wait → memcpy. `iter_out.len` must equal `width*band_rows`
    (band-LOCAL: row `row_offset` lands at index 0), and a band past the last row is
    REJECTED (`BandOutOfBounds`), never clamped. Zero rows = a no-op.
  - `gpuIterateRows(pipeline, view, w, h, max_iter, y0, rows, iter_band)` — converts
    `SquareView` to uniforms (`scale = view.side / min(w,h)`), calls `dispatch`, logs timing.
    This is `fractal/engine.IterFn`, so a progressive chunk is ONE dispatch: one band per
    frame, not one multi-second dispatch the GPU watchdog can kill.
    `gpuIterate(...)` = the whole-image band `(0, h)`.
  - **MSL buffer slot order (critical)**: uniforms at `buffer(0)` FIRST, readwrite
    storage at `buffer(1)` LAST. SDL_GPU enforces this order; swapping causes silent zeros.
  - `shaders/mandelbrot.metal` — `half` is a reserved MSL type; use `side_half`.
- `message.zig` — PURE builders: `sdlFailure`, `deviceReady`, `gpuIterateSummary`.
  No SDL import; unit-tested in fast tier via `src/root.zig`.

## Interop rule

`device.zig`, `texture.zig`, `compute.zig` import `../c.zig`. Pure logic stays in
`message.zig`. Only `message.zig` aggregated into `src/root.zig`; C-linking tests in
`src/gpu_headless_test.zig` (`zig build test-gpu`).

## Frame lifecycle

1. `SDL_AcquireGPUCommandBuffer` → 2. `SDL_WaitAndAcquireGPUSwapchainTexture` (skip if null)
→ 3. `Ui.prepareDrawData(cmd)` → 4. `SDL_BeginGPURenderPass` → 5. `Ui.renderDrawData`
→ 6. `SDL_SubmitGPUCommandBuffer`. GPU compute runs BEFORE this (in engine.iterate).

## Gotchas

- `SDL_CreateGPUDevice` → optional pointer; use `orelse`.
- Debug mode (2nd arg `true`) enabled in `create` for Metal validation.
- Headless test skips cleanly on no-GPU CI (`error.SkipZigTest`).
- `download` and GPU compute dispatch are the ONLY CPU←GPU paths; never add hot-path readback.
