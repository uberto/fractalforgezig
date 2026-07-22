<!-- LLM-only context for src/ui/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/ui/ context

## Purpose

Own Dear ImGui: context lifecycle, the SDL3 platform + SDL_GPU renderer backends,
per-frame new-frame/render/shutdown, and the single fixed M0 window layout.
C-interop edge — keep ImGui/SDL types here and behind `../c.zig` / `../cimgui.zig`;
never leak them into the fractal core.

## Layout (T8) — single window, two fixed regions

- `panels.zig` — `draw(texture, tex_w, tex_h, vp, max_iter, stats, quit_requested)`.
  ImGui edge (imports `../c.zig` + `../cimgui.zig`), so it is NOT pure and NOT
  registered in `root.zig`. One window pinned to the OS window work area
  (`ffImguiFillMainViewport`), flags = no-title/resize/move/collapse/saved-settings
  + menu bar. Menu bar: File→Quit (sets `quit_requested.*`), Help→About (modal via
  `igOpenPopup_Str` + `igBeginPopupModal`). Two child regions side by side: the
  fractal image (`ffImguiImage`, aspect-fit via `stats.containSize`) and a read-only
  data panel (render ms, frame ms, dispatch count = 0, visible re/im bounds derived
  from `vp`, `max_iter`). Text is pre-formatted in Zig and drawn with
  `igTextUnformatted` (avoids ImGui's C `%`-varargs formatter).
- `stats.zig` — PURE, unit-tested, no ImGui/GPU. `Stats{ render_ms, frame_ms,
  dispatch_count }` (`fromRender(ns)`, `observeFrame(ns)`), `nsToMs`,
  `containSize(img_w,img_h,region_w,region_h) Size` (letterbox fit), and
  `renderSummary(buf,w,h,max_iter,ns)` — the `.app` startup success line
  `"rendered {w}x{h} Mandelbrot, max_iter={n}, in {ms} ms"`. Registered in
  `root.zig`; the fast tier proves the numbers/strings with no window.

## Bridge helpers for struct-by-value ImGui calls (vendor/bridge)

`ffImguiFillMainViewport`, `ffImguiContentAvail(&w,&h)`,
`ffImguiBeginChild(id,w,h,border)`/`ffImguiEndChild`, `ffImguiImage(tex,w,h)` wrap
ImGui calls that take `ImVec2`/`ImTextureRef` by value, exposing plain scalars so
Zig avoids struct-ABI concerns. `ffImguiImage` passes the raw `SDL_GPUTexture*` as
the `ImTextureID` (Dear ImGui 1.92, 2025/08/08+); the backend supplies the sampler.

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

The window/backends + layout are inherently visual: verified by manual smoke
(`zig build run`) plus a runtime log check for `driver=metal`, "Dear ImGui
initialized", and the `rendered ...` summary line. Pure logic (Stats, summary,
containSize) lives in `stats.zig` and `../gpu/message.zig` and IS unit-tested.
