<!-- LLM-only context for src/ui/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/ui/ context

## Purpose

Own Dear ImGui: context lifecycle, the SDL3 platform + SDL_GPU renderer backends,
per-frame new-frame/render/shutdown, and the single fixed M0 window layout.
C-interop edge — keep ImGui/SDL types here and behind `../c.zig` / `../cimgui.zig`;
never leak them into the fractal core.

## Layout (T8): single window, two fixed regions

- `panels.zig` — `draw(texture, tex_w, tex_h, vp, max_iter, stats, quit_requested)`.
  ImGui edge (imports `../c.zig` + `../cimgui.zig`), so NOT pure and NOT registered in
  `root.zig`. One window pinned to the OS work area (`ffImguiFillMainViewport`), flags
  = no title/resize/move/collapse/bring-to-front/saved-settings + menu bar. Menu bar:
  File→Quit (sets `quit_requested.*`), Help→About (modal via `igOpenPopup_Str` +
  `igBeginPopupModal`). Two side-by-side child regions: the fractal image
  (`ffImguiImage`, aspect-fit via `stats.containSize`) and a read-only data panel
  (render/frame ms, dispatch count 0, visible re/im bounds from `vp`, `max_iter`).
  Text is pre-formatted in Zig and drawn with `igTextUnformatted`.
- `stats.zig` — PURE, unit-tested, no ImGui/GPU. `Stats{ render_ms, frame_ms,
  dispatch_count }` (`fromRender(ns)`, `observeFrame(ns)`), `nsToMs`,
  `containSize(img_w,img_h,region_w,region_h) Size`, and
  `renderSummary(buf,w,h,max_iter,ns)` — the `.app` startup line
  `"rendered {w}x{h} Mandelbrot, max_iter={n}, in {ms} ms"`. Registered in `root.zig`.

## Bridge helpers (vendor/bridge, struct-by-value ImGui calls)

`ffImguiFillMainViewport`, `ffImguiContentAvail(&w,&h)`,
`ffImguiBeginChild(id,w,h,border)`/`ffImguiEndChild`, `ffImguiImage(tex,w,h)` wrap
ImGui calls taking `ImVec2`/`ImTextureRef` by value, exposing plain scalars so Zig
avoids struct-ABI concerns. `ffImguiImage` passes the raw `SDL_GPUTexture*` as the
`ImTextureID` (Dear ImGui 1.92, 2025/08/08+); the backend supplies the sampler.

## The stack + C-interop boundary

- Vendored, compiled from source by `build.zig`: cimgui + Dear ImGui **docking**
  branch + `imgui_impl_sdl3` + `imgui_impl_sdlgpu3`. M0 is a **single, non-docking**
  window — do NOT set the docking config flag (vendored only for M2/M3).
- `../c.zig` (`@cImport`) — SDL3, SDL_GPU, and the backend bridge `imgui_bridge.h`.
- `../cimgui.zig` — a thin hand-written `extern` header for the ImGui **core** C API
  (`igCreateContext`, `igNewFrame`, `igRender`, `igBegin`, `igEnd`,
  `igTextUnformatted`, ...). We do NOT `@cImport cimgui.h`: its docking build embeds
  C-bitfield structs that translate-c turns into `opaque{}`. Grow it as needed.
- `vendor/bridge/imgui_bridge.{h,cpp}` — first-party C-linkage shim wrapping the C++
  backends (init/event/new-frame/prepare/render/shutdown) using only SDL types.

## `Ui` (imgui.zig)

- `Ui.init(window, device)` — `igCreateContext`, then `ffImguiInitBackends(window,
  device.handle, device.swapchainTextureFormat())`. Logs `std.log.scoped(.ui)`;
  returns `error.ImGuiContextCreationFailed` / `error.ImGuiBackendInitFailed` — no panic.
- Per frame: `newFrame()` → build UI → `endFrame()` (`igRender`) →
  `prepareDrawData(cmd)` BEFORE the render pass → `renderDrawData(cmd, pass)` inside it.
- `processEvent(&event)` feeds SDL events to the platform backend.
- `shutdown()` tears down backends (renderer before platform), then the context.

## Init / shutdown order (whole app, main.zig)

Up: `SDL_Init(VIDEO)` → `SDL_CreateWindow` → `Device.create` → `Ui.init`. Down
(reverse, via `defer`): `Ui.shutdown` → `Device.destroy` → `SDL_DestroyWindow` →
`SDL_Quit`.

## Testing

Window/backends/layout are visual: manual smoke (`zig build run`) + a log check for
`driver=metal`, "Dear ImGui initialized", and the `rendered ...` summary. Pure logic
(`stats.zig`, `../gpu/message.zig`) IS unit-tested.
