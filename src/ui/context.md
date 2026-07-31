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

`panels.zig` — `draw(device,texture,vp,image_rect,max_iter,stats,engine,editor,view_editor,
quit_requested)`. ImGui edge. Left child: fractal image. Right child: data panel, coord
panel (T7), palette panel. Menu: File→Quit, Help→About. **Palette + recolor (M2)**: per
stop `igColorEdit4`+`igSliderFloat`+Remove; Add-stop, `igCombo_Str_arr` mode, period
slider, interior color. Changes OR into `Edits`. `applyEdits`→setter→re-upload→log; NEVER
re-iterates. `editor.zig` (PURE): `Editor{stops_buf,count,mode_index,period,interior}`;
`initDefault`; `toGradient` sorts ascending; `addStop`/`removeStop`; `modeToIndex`+
`mode_items`. `stats.zig` (PURE): `Stats{render_ms,frame_ms}`; `renderSummary`.

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

All glue in `main.zig`. `NavState{drag_state,drag_start_px,right_click_pt,full_pass_done,
idle_timer}`. `real_s` = full-res S. Box-select (left-drag): `handleNavInput`→
`navigate.boxSelect`→`setViewport` on release; rubber-band via `ImDrawList_AddRect`. Pan
(middle/Space+left): `panByPixels`→`setViewport`; reset delta after. Scroll
(`SDL_EVENT_MOUSE_WHEEL`): `cursorCoord`→`zoomAbout`. Right-click: stash point,
`igOpenPopup_Str`→`drawContextMenu`→`zoomCentered`. Hover: `cursorCoord`→`formatCoord`→
tooltip. Coarse→fine: `applyViewCoarse` resizes to `max(real_s/4,1)`, `setViewport`, upload,
`full_pass_done=false`. `runFullPass` restores `real_s`, upload, done. `refine.decidePass`
(pure, tested) drives: `.full`→`runFullPass`.

## Coord panel + ViewEditor (T7)

`ViewEditor` in `editor.zig` (PURE, unit-tested): text buffers for center re/im/mag and
corner a/b re/im (both forms synced), `auto_iter` bool, `manual_iter_buf`.
`initFromView`/`syncFromView` populate all 7 buffers from a `SquareView` (`{d}` format,
null-terminated). `parseAndApplyCenterMag`→`?SquareView` (re/im/mag as f64,
`fromCenterMag`; null on failure). `parseAndApplyCorners`→`?SquareView` (four corners,
`fromCorners`; null on failure). `parseIterPolicy`→`?IterPolicy` (`manual_iter_buf` as u32,
`IterPolicy.manual`; null on failure).

`drawCoordPanel` in `panels.zig`: "Coord" section below data panel. `igInputText` fields
(EnterReturnsTrue) for center/mag and corners — on commit: parse → `setViewport` → upload
→ `syncFromView`. `igButton("Reset")` → `navigate.reset()` → same flow. `igCheckbox("Auto")`
+ manual `igInputText` (disabled when auto) → `parseIterPolicy` → `setPolicy` → upload.
Errors log `.err`. `view_editor` created in `main.zig` after engine init; `syncFromView`
called from `applyViewCoarse`, `runFullPass`, and after `handleResize`.

## Testing

Visual (window/layout/navigation/coord panel): manual smoke + log check. Pure (`stats.zig`,
`editor.zig`, `fractal/refine.zig`) IS unit-tested.
