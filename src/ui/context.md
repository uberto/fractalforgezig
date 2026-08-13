<!-- LLM-only context for src/ui/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/ui/ context

## Purpose

Own Dear ImGui: context lifecycle, SDL3+SDL_GPU backends, per-frame
new-frame/render/shutdown, the fixed layout+palette editor. C-interop edge — keep ImGui/SDL
types behind `../c.zig`/`../cimgui.zig`; never leak into the core.

## Aspect + resize (M5)

The render target is the fractal REGION (rectangular) and only ImGui knows its size, so `draw`
reports it as `render_w/render_h`; `main.zig` takes that as the full-res target, and a change
cancels the pass + re-arms (so a resize DRAG defers to the settled size). No
`handleResize`. Draw via `viewport.fitImageRect(region…,texture…)`: aspect-preserving, so a
texture not yet matching the region is letterboxed, NEVER stretched — and that same rect is
the coordinate-mapping rect. The host window MUST keep `no_scrollbar`: a scrollbar's width comes
out of `ContentAvail`, which sizes the region, which sizes the content → a two-frame size
oscillation that cancelled every full pass. Backstop: `region_thrash_limit` warns after 8 chased
changes and lets the pass finish.

## Layout: single window, two fixed regions

`panels.zig` — `draw(device,texture,max_iter,stats,engine,editor,view_editor,open_ctx_menu,
right_click_pt,hover_pt,rendering,progress:?f32,quit*)→DrawResult{ctx_action,image_rect,
render_w,render_h,needs_rerender,save_requested,open_requested,coord}`: `image_rect`=fitted
ON-SCREEN rect (mapping), `render_w/h`=REGION size (resolution target). `rendering` freezes
the edit panels (`igBeginDisabled`); `progress` (=`engine.passFraction()`) replaces the
status-bar readout with `igProgressBar` + `progressive.progressLabel`. Status-bar lookup uses
`engine.renderViewport().pixelIndex(pt.lo())` (rect stride), NOT the square map.
Left: fractal image, right: data+coord+palette. Menu: File→Save…/Open…/Quit, Help→About.
Palette: `igColorEdit4`+`igSliderFloat`+Remove; Add-stop, mode combo, period, interior.
`applyEdits`→setter→re-upload; NEVER re-iterates. `editor.zig` (PURE): `Editor`+`toGradient`+
`addStop`/`removeStop`. `stats.zig` (PURE): `Stats{render_ms,frame_ms,gpu_render_ms}`,
`renderSummary`.

## Stack, bridge, `Ui` (imgui.zig)

Vendored via `build.zig`: cimgui+Dear ImGui docking+SDL3/SDLGPU3 backends. `../cimgui.zig`
holds `extern` decls, NOT `@cImport cimgui.h` (docking bitfields → `opaque{}`). Bridge
(`vendor/bridge`) wraps by-value `ImVec2` calls: `ffImguiFillMainViewport`,
`ffImguiContentAvail`, `ffImguiBeginChild`/`End`, `ffImguiImage(texture,w,h)` (raw
`SDL_GPUTexture*` as `ImTextureID`), `ffImguiSetCursorScreenPos`. `Ui.init(window,device)`;
per frame `newFrame()`→build→`endFrame()`→`prepareDrawData(cmd)` BEFORE the render pass→
`renderDrawData(cmd,pass)`; `processEvent`; `shutdown()`.
Order: `SDL_Init`→`CreateWindow`→`Device.create`→`Ui.init`.

## Navigation + progressive render (main.zig)

`NavState{drag_state,drag_start_px,right_click_pt,full_pass_done,rendering,pass_ns,region_thrash,
idle_timer}`.
Box-select (left-drag)→`navigate.boxSelect` on release, rubber-band `ImDrawList_AddRect`; pan
(middle/Space+left)→`panByPixels`, reset delta after; scroll→`cursorCoord`+`zoomAbout`;
right-click→`igOpenPopup_Str`→`drawContextMenu`→`zoomCentered`; hover→`formatCoord` tooltip.
EVERY view/policy change goes through `applyViewCoarse`/`showViewCoarse`/`showPolicyCoarse`:
`cancelPass`→`installView`/`installPolicy`→`renderCoarse` (one blocking
`resizeRect(real_w/coarse_divisor,real_h/coarse_divisor)` — divides EACH axis, so the blocky
preview keeps the aspect)→`syncFromView`→`armFullPass`. NOTHING iterates at full res
synchronously. `refine.decidePass` then fires `beginFullPass`; `stepPassChunk` runs one
`engine.stepPass()` per frame. While `engine.pass != null` the loop `SDL_PollEvent`s (never
blocks); else `SDL_WaitEventTimeout(16)` when a pass is owed, `-1` when idle.

## Coord panel + ViewEditor

`ViewEditor` (`editor.zig`, PURE, tested): `coord_buf_bytes`-wide buffers for center re/im/mag +
corners a/b re/im (both forms synced), `auto_iter`, `manual_iter_buf`; parse/format still f64. `initFromView`/`syncFromView` fill all 7;
`syncFromPolicy` inverts `parseIterPolicy`. `parseAndApplyCenterMag`/`parseAndApplyCorners`→
`?SquareView`, `parseIterPolicy`→`?IterPolicy`; null on failure. `drawCoordPanel` REQUESTS,
never applies: returns `CoordRequest{view,policy}` (first commit wins) for `main.zig` — an
ImGui frame is no place for engine work. Parse failure logs `.err`, re-syncs from engine.

## File dialog (M5): dialog.zig

`PendingDialog{kind,path_buf,path_len}` — stack-alloc in `runLoop`, outlives callbacks.
`showSave`/`showOpen(window,pending)` no-op if `kind != .none` (one dialog only).
`takePending`→`?PendingResult`, `null` on cancel/none, resets to `.none`. C callback
(`callconv(.c)`) writes the path in, never allocates. Filter `*.fractal`.

## Testing

Visual (layout/navigation/coord/progress) = manual smoke + log check. Pure (`stats.zig`,
`editor.zig`, `fractal/refine.zig`, `fractal/progressive.zig`) IS unit-tested; `dialog.zig` is
glue, no unit tests.
