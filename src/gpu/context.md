<!-- LLM-only context for src/gpu/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/gpu/ context

## Purpose

Own the SDL_GPU device lifecycle and (later, T7) the RGBA -> texture upload path.
On macOS the backend is Metal. This folder is a C-interop edge: SDL/GPU C types
live here and behind `../c.zig`; never leak them into the pure fractal core.

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
- `message.zig` — PURE log/summary string builders (`sdlFailure`, `deviceReady`),
  no SDL import, unit-tested in the fast tier. `device.zig` uses them for the
  strings it hands to `std.log`. Add new observability strings here so they stay
  testable; `src/root.zig` aggregates this module's tests.

## Interop rule

`device.zig` imports `../c.zig` (SDL3 + SDL_GPU translated once). Keep pure logic
in `message.zig` so `zig build test` needs no window/device. The test tier must
never `@cImport` — only `message.zig` (pure) is imported into `root.zig`.

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
- T7 adds `texture.zig` here for CPU RGBA uploads + a headless round-trip test
  (create a device WITHOUT a window). Keep that path one-directional (no readback
  in the hot path).
