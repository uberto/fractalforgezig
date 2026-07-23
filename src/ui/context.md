<!-- LLM-only context for src/ui/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/ui/ context

## Purpose

Own Dear ImGui: context lifecycle, SDL3 + SDL_GPU backends, per-frame
new-frame/render/shutdown, and the single fixed window layout + palette editor. C-interop
edge — keep ImGui/SDL types behind `../c.zig` / `../cimgui.zig`; never leak into the core.

## Layout: single window, two fixed regions

- `panels.zig` — `draw(device, texture, vp, max_iter, stats, engine, editor,
  quit_requested)`. ImGui edge, NOT pure, NOT in `root.zig`. One window pinned to the work area
  (`ffImguiFillMainViewport`), flags = no title/resize/move/collapse/settings + menu bar. Menu:
  File→Quit (sets `quit_requested.*`), Help→About. Left child: fractal image (`ffImguiImage`,
  aspect-fit via `stats.containSize`). Right child: data panel (render/frame ms, engine
  `iteration`/`color passes` counters, mode + stop count, re/im bounds, `max_iter`) then the
  **Palette panel** (text via `igTextUnformatted`).
- **Palette panel + recolor flow (M2 T6).** Per stop (`igPushID_Int` keys each row):
  `igColorEdit4` color + `igSliderFloat` pos + `igSmallButton` "Remove"; then
  "Add stop", the mapping `igCombo_Str_arr` (linear/log/cyclic), a period `igSliderFloat`
  (`igBeginDisabled` unless cyclic), an interior `igColorEdit4`. Widget returns OR into an
  `Edits{gradient,mapping,interior}`. **Flow = edit → recolor → re-upload, NEVER
  re-iterate**: `applyEdits` calls the matching setter (`setGradient(editor.toGradient())`
  / `setMapping(editor.params())` / `setInterior`), re-uploads `engine.output()` via
  `texture_mod.upload`, logs `engine.summary()` (`.ui`); errors log `std.log.err(.ui)` and
  skip. `iterate` runs ONCE at startup in `main.zig`.
- `editor.zig` — PURE UI state, no ImGui, in `root.zig`. `Editor{ stops_buf, count,
  mode_index, period, interior }`: `initDefault` mirrors `Engine.init`; `toGradient` copies
  + SORTS stops ascending (so a dragged pos never breaks the bake);
  `params` → `mapping.Params`; `addStop`/`removeStop` keep 1..`max_stops`;
  `modeToIndex`/`indexToMode` + `mode_items` are the combo↔enum source of truth.
- `stats.zig` — PURE, unit-tested, in `root.zig`. `Stats{ render_ms, frame_ms,
  dispatch_count }` (`fromRender`/`observeFrame`), `nsToMs`, `containSize(...)`,
  `renderSummary(...)` → the `.app` startup line `"rendered {w}x{h} Mandelbrot, ..."`.

## Bridge helpers (vendor/bridge, struct-by-value ImGui calls)

`ffImguiFillMainViewport`, `ffImguiContentAvail`, `ffImguiBeginChild`/`ffImguiEndChild`,
`ffImguiImage` wrap by-value `ImVec2`/`ImTextureRef` calls as scalars (avoids struct-ABI).
`ffImguiImage` passes the raw `SDL_GPUTexture*` as the `ImTextureID` (1.92+). The palette
widgets need no bridge (scalar/pointer sigs).

## The stack + C-interop boundary

- Vendored via `build.zig`: cimgui + Dear ImGui **docking** branch + SDL3/SDLGPU3 backends.
  Single non-docking window — do NOT set the docking flag.
- `../c.zig` (`@cImport`) — SDL3, SDL_GPU, bridge `imgui_bridge.h`.
- `../cimgui.zig` — hand-written `extern` decls for the ImGui **core** C API (context, text,
  menus, plus the palette widgets `igColorEdit4`/`igSliderFloat`/`igCombo_Str_arr`/`igPushID_Int`/
  `igBeginDisabled`/`igSeparatorText`). NOT `@cImport cimgui.h` (docking bitfields → `opaque{}`).
- `vendor/bridge/imgui_bridge.{h,cpp}` — C-linkage shim over the C++ backends, SDL types only.

## `Ui` (imgui.zig)

- `Ui.init(window, device)` — `igCreateContext` + `ffImguiInitBackends(...)`. Logs `.ui`;
  returns `error.ImGuiContextCreationFailed`/`error.ImGuiBackendInitFailed` — no panic.
- Per frame: `newFrame()` → build UI → `endFrame()` (`igRender`) → `prepareDrawData(cmd)`
  BEFORE the render pass → `renderDrawData(cmd, pass)` inside it. `processEvent(&event)` feeds
  SDL events. `shutdown()` tears down backends (renderer before platform) then context.
- App order (main.zig): `SDL_Init` → `CreateWindow` → `Device.create` → `Ui.init`; teardown is
  the reverse via `defer`.

## Testing

Window/backends/layout/palette recolor are visual: manual smoke (`zig build run`) + a log
check for `driver=metal`, "Dear ImGui initialized", and the `rendered`/`color pass` summaries.
Pure logic (`stats.zig`, `editor.zig`) IS unit-tested.
