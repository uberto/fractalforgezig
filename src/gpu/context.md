<!-- LLM-only context for src/gpu/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/gpu/ context

C-interop edge: SDL_GPU device lifecycle, texture upload, Metal compute iteration.
NEVER leak SDL/GPU types into `src/fractal/`; imports go `gpu/` → `fractal/` only.

## Files

- `device.zig` — `Device{handle, window}`. `create(window)` requests the
  `SDL_GPU_SHADERFORMAT_MSL|..._METALLIB` formats, claims the swapchain, logs the driver;
  typed error + `std.log.err` on failure. `destroy()` once.
  `swapchainTextureFormat()` → ImGui.
- `texture.zig` — `createRgbaTexture(device,w,h)` → `Texture`; `upload(device,tex,pixels)`
  (transfer buffer → copy pass). `download` is DIAGNOSTIC/TEST ONLY.
- `message.zig` — PURE builders, no SDL: `sdlFailure`, `deviceReady`, `gpuIterateSummary`,
  `gpuDeepIterateSummary` (`"gpu deep iterate: …"` — proof the deep kernel ran).
  Fast tier, via `src/root.zig`.
- `compute.zig` — iteration via Metal compute, compiled at runtime from
  `shaders/mandelbrot.metal` (`msl_source` is `pub` so tests parse its structs).
  `ComputePipeline{handle, deep_handle, device}` is immutable and passed BY VALUE;
  `create(device)` builds both kernels or neither; `destroy()` releases both.

### Shallow path

`MandelbrotUniforms{center_re,center_im,scale: f32, width,height,max_iter,row_offset,
band_rows: u32}`, entry `"mandelbrot_iterate"`, threadcount 64×1×1.
`dispatch(pipeline,uniforms,iter_out)` is synchronous: compute → copy → fence → memcpy.
`gpuIterateRows(pipeline,view,w,h,max_iter,y0,rows,iter_band)` (`scale = view.side/min(w,h)`)
IS `fractal/engine.IterFn`, so one progressive chunk = ONE dispatch, not a multi-second one the
watchdog kills. `gpuIterate(...)` = the whole-image band `(0,h)`.
BAND CONTRACT (both paths): `iter_out.len == width*band_rows`, band-LOCAL (row `row_offset` at
index 0); `height` is ALWAYS the FULL image height (image-anchored mapping); a band past
the last row is REJECTED (`BandOutOfBounds`), never clamped; zero rows = no-op.

### Deep path

`mandelbrot_iterate_deep` transliterates `fractal/perturb.iterateDelta` — per-pixel `float`
DELTAS from the centre, Zhuoran rebasing, same escape test and smoothing tail. Never re-derive
the mapping or emulate `f64` in MSL; keep it in step with that CPU definition.
`MandelbrotDeepUniforms{scale: f32, width,height,max_iter,row_offset,band_rows,orbit_len: u32}`
(28 bytes) carries NO centre — `orbit[1]` IS `C`.
`dispatchDeep(pipeline,uniforms,orbit,iter_out)` narrows the orbit into a mapped UPLOAD buffer
(no allocator), uploads it in the compute command buffer, binds it read-only, dispatches.
Re-uploaded EVERY dispatch BY DESIGN: the engine frees the orbit at each render boundary;
nothing here may cache it.
`gpuIterateDeepRows(pipeline,view,orbit,w,h,max_iter,y0,rows,iter_band)` REFUSES via
`engine.gpuDeepFallbackReason` BEFORE touching the GPU — `BelowGpuPrecisionFloor`
(`side < perturb.gpu_floor_side`) or `OrbitTooLongForGpu` (`> perturb.gpu_max_orbit_len`);
the engine checks the same rule first (defence in depth).
`float` deltas hold 24 bits: a few of 256 pixels differ from the CPU by hundreds of iterations
at 1e-20—input quantization, NOT kernel error (see the agreement tests).

### MSL slot order (critical)

SDL_GPU assigns ONE order: uniforms, then READ-ONLY storage, then READ-WRITE last.
Shallow: uniforms `buffer(0)`, `iter_out` `buffer(1)`. Deep: uniforms `buffer(0)`, `orbit`
`buffer(1)`, `iter_out` `buffer(2)`. A wrong order does not fail — zeros, flat image.
`half` is a reserved MSL type; suffix instead (`w_half`, `h_half`).

## Gotchas

- Frame order: acquire cmd → `SDL_WaitAndAcquireGPUSwapchainTexture` (skip if null) →
  `Ui.prepareDrawData(cmd)` → render pass → `Ui.renderDrawData` → submit. Compute ran earlier.
- SDL creators return optionals: `orelse` + typed error, never `unreachable`.
  Metal validation is ON in debug — read the console.
- C-linking tests: `src/gpu_headless_test.zig` (`zig build test-gpu`), named
  `"compute: …"`, skip via `error.SkipZigTest`.
- Compute dispatch and `download` are the ONLY CPU←GPU paths; no hot-path readback.
