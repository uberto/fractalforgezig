<!-- LLM-only context for src/gpu/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/gpu/ context

Keep SDL/GPU types here. Imports go GPU → fractal.

- `device.zig` creates `Device{handle, window}`, claims the swapchain, and logs the driver.
  Call `destroy` once. Pass `swapchainTextureFormat()` to ImGui.
- `texture.zig` creates RGBA textures and uploads pixels through a transfer buffer and copy pass.
  Reserve `download` for diagnostics and tests.
- `message.zig` builds log strings without SDL. Watch for `gpu deep iterate` and
  `gpu deep BLA iterate` to identify dispatched bands.
- `compute.zig` builds all three kernels at runtime from `shaders/mandelbrot.metal`.
  Pass `ComputePipeline` by value. Destroy it once before device teardown.

## Row bands

`gpuIterateRows`, `gpuIterateDeepRows` and `gpuIterateDeepBlaRows` take full image dimensions
and write exactly `width * rows` values starting at band-local index zero. Anchor mapping on the
full image and the global row. Reject out-of-bounds bands. Treat zero rows as a no-op.
Each dispatch synchronously computes, downloads and waits on a fence.

## Deep and accelerated deep

Use `mandelbrot_iterate_deep` for f32 pixel deltas and Zhuoran rebasing.
`MandelbrotDeepUniforms` is 28 bytes and carries scale, image dimensions, iteration budget,
band position and orbit length. Recover the center from `orbit[1]`. Share the perturbation loop
and escape smoothing across the two kernels.

Call `gpuIterateDeepBlaRows` with the orbit and the BLA table built for it. Upload a level-ordered
sequence of 48-byte `GpuBlaBlock` entries. The header holds the parameter radius. Each block holds
the three complex coefficients, validity radius and residual bounds as f32. Apply the quadratic
map only within the admissible radius and iteration budget. Replay ambiguous pixels using plain
GPU perturbation.

Upload the orbit and optional BLA table each dispatch. The engine owns their render lifetime.
Check precision floor and orbit budget via `engine.gpuDeepFallbackReason` before allocating GPU
resources. Reject a table beyond `bla.gpu_max_table_len` or with incompatible orbit dimensions.

## Metal slots and tests

Bind uniforms first, read-only storage next and writable output last per SDL_GPU. Shallow uses
uniform/output at 0/1. Plain deep uses uniform/orbit/output at 0/1/2. Accelerated deep uses
uniform/orbit/table/output at 0/1/2/3.

Run `zig build test-gpu` for the headless Metal suite in `src/gpu_headless_test.zig`. Check for
device skips. Read the Metal validation console in Debug builds. Treat SDL optionals as typed
errors. Submit the HUD render pass after acquiring the swapchain and preparing ImGui draw data.
