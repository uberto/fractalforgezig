<!-- LLM-only context for src/ui/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/ui/ context

## Purpose

Own Dear ImGui: context lifecycle, SDL3 + SDL_GPU backends, per-frame
new-frame/render/shutdown, and the single fixed window layout + palette editor. C-interop
edge — keep ImGui/SDL types behind `../c.zig` / `../cimgui.zig`; never leak into the core.

## Letterbox layout + resize flow (T5)

Window is resizable. Fractal renders as centered square `S = min(w,h)` px; SDL clear color
fills bars. `viewport.computeImageRect(w,h)` (pure, tested) → `ImageRect{x,y,side}`.
`handleResize(device,texture*,image_rect*,engine*,w,h)`: skips `S==0`; on S change:
`engine.resize(S)`, destroy+recreate texture, re-upload, log `"resize: WxH → SxS"`. Screen
coords throughout (`SDL_GetWindowSize`/`event.window.data1,2`).

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

## Navigation input + coarse→fine (T6, main.zig)

All navigation glue in `main.zig`. `NavState{drag_state, drag_start_px, right_click_pt,
full_pass_done, idle_timer}`. `real_s` = full-res S (engine may be at coarse size).

- **Box-select** (left-drag, no Space): `handleNavInput` → `navigate.boxSelect`→
  `engine.setViewport` on release; rubber-band via `igGetWindowDrawList`/`ImDrawList_AddRect`.
- **Pan** (middle-drag / Space+left): `igGetMouseDragDelta`→`navigate.panByPixels`→
  `engine.setViewport`; `igResetMouseDragDelta` after each apply.
- **Scroll-zoom** (`SDL_EVENT_MOUSE_WHEEL`): cursor→`cursorCoord`→`navigate.zoomAbout`.
- **Right-click** (`SDL_BUTTON_RIGHT`→stash point, `igOpenPopup_Str`): `drawContextMenu`
  renders "Zoom in/out 2×"→`navigate.zoomCentered`.
- **Hover**: `drawHoverReadout` → `cursorCoord`→`formatCoord`→`igBeginTooltip`; null=skip.
- **Coarse→fine**: `applyViewCoarse` resizes to `max(real_s/4,1)`, calls `setViewport`,
  uploads, marks `full_pass_done=false`. `runFullPass` restores `real_s`, uploads, marks
  done. `refine.decidePass(interacting,idle_ns,full_pass_done)` (pure, tested in
  `fractal/refine.zig`) drives the per-frame decision: `.full`→`runFullPass`; else skip.

## Testing

Visual (window/layout/navigation): manual smoke + log check. Pure (`stats.zig`,
`editor.zig`, `fractal/refine.zig`) IS unit-tested.
