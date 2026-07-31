<!-- LLM-only context for src/ui/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/ui/ context

## Purpose

Own Dear ImGui: context lifecycle, SDL3 + SDL_GPU backends, per-frame
new-frame/render/shutdown, and the single fixed window layout + palette editor. C-interop
edge — keep ImGui/SDL types behind `../c.zig` / `../cimgui.zig`; never leak into the core.

## Letterbox layout + resize flow (T5)

T5 makes the window resizable. The fractal renders as a centered square `S = min(w, h)` px,
letterboxed; the SDL clear color fills the bars automatically.

`viewport.computeImageRect(w, h)` — pure, `fractal/viewport.zig`, unit-tested — returns
`ImageRect{x=(w-S)/2, y=(h-S)/2, side=S}` (`side=0` for degenerate input). `main.zig`
calls it at startup (after `SDL_GetWindowSize`) and on `SDL_EVENT_WINDOW_RESIZED`
(`event.window.data1/data2`, screen coords). On resize: `handleResize(device, texture*,
image_rect*, engine*, new_w, new_h)` — skips silently when `S==0` (minimized, no error
spam); when `S` changed: `engine.resize(S)` (`.err` on failure), destroy old texture,
`createRgbaTexture` at `S×S`, re-upload `engine.output()`, log
`"resize: window WxH → image SxS"` at `.app`. `image_rect` threads through `runLoop` as
`*ImageRect` so T6 can map mouse events through it.

## Layout: single window, two fixed regions

- `panels.zig` — `draw(device, texture, vp, image_rect, max_iter, stats, engine, editor,
  quit_requested)`. ImGui edge, NOT pure. Window pinned to work area (`ffImguiFillMainViewport`),
  no title/resize/move + menu bar. Menu: File→Quit, Help→About. Left child: fractal image
  (`ffImguiImage` at `image_rect.side × image_rect.side`). Right child: data panel (ms,
  counters, mode, stops, bounds, `max_iter`) + **Palette panel**.
- **Palette panel + recolor flow (M2).** Per stop: `igColorEdit4` + `igSliderFloat` pos +
  `igSmallButton` "Remove"; then "Add stop", mapping `igCombo_Str_arr`, period
  `igSliderFloat` (`igBeginDisabled` unless cyclic), interior `igColorEdit4`. Changes OR
  into `Edits{gradient,mapping,interior}`. **Flow = edit → recolor → re-upload, NEVER
  re-iterate**: `applyEdits` runs the matching setter, re-uploads `engine.output()`, logs
  `engine.summary()` (`.ui`); errors log `.err` and skip. `iterate` runs ONCE at startup.
- `editor.zig` — PURE, in `root.zig`. `Editor{stops_buf,count,mode_index,period,interior}`:
  `initDefault`; `toGradient` copies + SORTS ascending; `params`→`mapping.Params`;
  `addStop`/`removeStop` keep 1..`max_stops`; `modeToIndex`/`indexToMode`+`mode_items`.
- `stats.zig` — PURE, in `root.zig`. `Stats{render_ms,frame_ms,dispatch_count}`;
  `fromRender`/`observeFrame`; `nsToMs`; `containSize`; `renderSummary`.

## Bridge helpers (vendor/bridge)

`ffImguiFillMainViewport`, `ffImguiContentAvail`, `ffImguiBeginChild`/`ffImguiEndChild`,
`ffImguiImage(texture, w, h)`, `ffImguiSetCursorScreenPos(x, y)` — wrap by-value `ImVec2`
calls. `ffImguiImage` passes raw `SDL_GPUTexture*` as `ImTextureID` (1.92+).

## Stack + C-interop

Vendored via `build.zig`: cimgui + Dear ImGui docking + SDL3/SDLGPU3 backends. Single
non-docking window. `../c.zig` (`@cImport`) — SDL3, SDL_GPU, `imgui_bridge.h`. `../cimgui.zig`
— `extern` decls for the ImGui C API (context, text, menus, palette widgets). NOT
`@cImport cimgui.h` (docking bitfields → `opaque{}`).

## `Ui` (imgui.zig)

`Ui.init(window, device)` — `igCreateContext` + `ffImguiInitBackends`. Per frame:
`newFrame()` → build UI → `endFrame()` → `prepareDrawData(cmd)` before render pass →
`renderDrawData(cmd, pass)`. `processEvent(&event)` for SDL. `shutdown()` tears down
backends then context. App order: `SDL_Init`→`CreateWindow`→`Device.create`→`Ui.init`.

## Testing

Window/backends/layout are visual: manual smoke + log check. Pure logic (`stats.zig`,
`editor.zig`) IS unit-tested.
