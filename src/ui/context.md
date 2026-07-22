<!-- LLM-only context for src/ui/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/ui/ context

## Purpose

Own Dear ImGui: context lifecycle, the SDL3 platform + SDL_GPU renderer backends,
and per-frame new-frame/render/shutdown. C-interop edge — keep ImGui/SDL types
here and behind `../c.zig` / `../cimgui.zig`; never leak them into the fractal core.

## The stack (vendored, compiled from source by build.zig)

- cimgui + Dear ImGui **docking** branch + `imgui_impl_sdl3` + `imgui_impl_sdlgpu3`
  in `vendor/` (pins in `vendor/VERSIONS.md`).
- M0 is a **single window, non-docking**. Do NOT set the docking config flag; the
  docking branch is vendored only so M2/M3 can add dockable panels later.

## C-interop boundary (two edges, deliberately split)

- `../c.zig` (`@cImport`) — SDL3, SDL_GPU, and the backend bridge `imgui_bridge.h`.
- `../cimgui.zig` — a thin hand-written `extern` header for the ImGui **core** C
  API (`igCreateContext`, `igNewFrame`, `igRender`, `igShowDemoWindow`, `igBegin`,
  `igEnd`, `igText`, ...). We do NOT `@cImport cimgui.h`: its docking build embeds
  internal structs with C bitfields that Zig translate-c turns into `opaque{}` and
  cannot embed by value. Grow `cimgui.zig` as later tasks need more calls.
- `vendor/bridge/imgui_bridge.{h,cpp}` — first-party C-linkage shim. The backend
  headers are C++ and take C++-only types (`ImDrawData*`,
  `ImGui_ImplSDLGPU3_InitInfo`); the bridge wraps init/event/new-frame/prepare/
  render/shutdown using only SDL types so Zig can call them.

## `Ui` (imgui.zig)

- `Ui.init(window, device)` — `igCreateContext`, then
  `ffImguiInitBackends(window, device.handle, device.swapchainTextureFormat())`
  (= `ImGui_ImplSDL3_InitForSDLGPU` + `ImGui_ImplSDLGPU3_Init`). Logs
  `std.log.scoped(.ui)`; returns `error.ImGuiContextCreationFailed` /
  `error.ImGuiBackendInitFailed` on failure — no panic.
- Per frame: `newFrame()` (backends + `igNewFrame`) -> build UI ->
  `endFrame()` (`igRender`) -> `prepareDrawData(cmd)` BEFORE the render pass ->
  `renderDrawData(cmd, pass)` inside it.
- `processEvent(&event)` feeds SDL events to the platform backend.
- `shutdown()` tears down backends (renderer then platform) then destroys the
  context. Order matters; do renderer before platform.

## Init / shutdown order (whole app, see main.zig)

Up: `SDL_Init(VIDEO)` -> `SDL_CreateWindow` -> `Device.create` ->
`Ui.init`. Down (reverse, via `defer`): `Ui.shutdown` -> `Device.destroy` ->
`SDL_DestroyWindow` -> `SDL_Quit`.

## Testing note

The window/backends are inherently visual: verified by manual smoke (`zig build
run`) plus a runtime log check for `driver=metal` + "Dear ImGui initialized".
Pure string builders live in `../gpu/message.zig`. T8 replaces `buildUi` in
main.zig with the real menu bar + fractal/data panels using `cimgui.zig`.
