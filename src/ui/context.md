<!-- LLM-only context for src/ui/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/ui/ context

## Purpose

Own Dear ImGui: context lifecycle, SDL3+SDL_GPU backends, the per-frame cycle, the fixed layout +
palette editor. C-interop edge: keep ImGui/SDL types behind `../c.zig`/`../cimgui.zig`.

## Aspect + resize (M5)

Render target = the fractal REGION. `draw` reports it as `render_w/render_h`; `main.zig` uses that
as the full-res target and cancels + re-arms the pass on a change. No `handleResize`.
`viewport.fitImageRect(region…,texture…)` letterboxes a mismatched texture, NEVER stretches, and
IS the coordinate-mapping rect. Keep `no_scrollbar` on the host window: a scrollbar's width leaves
`ContentAvail` → sizes the region → sizes the content → oscillation that cancelled every full pass.
`region_thrash_limit` warns after 8 chased changes.

## Layout: single window, two fixed regions

`panels.zig` — `draw(…)→DrawResult{ctx_action,image_rect,render_w,render_h,needs_rerender,
save_requested,open_requested,coord}`: `image_rect`=fitted ON-SCREEN rect (mapping),
`render_w/h`=REGION size (resolution target). `rendering` freezes edit panels
(`igBeginDisabled`); `progress`(=`engine.passFraction()`) swaps the readout for
`igProgressBar`+`progressive.progressLabel`. Status-bar lookup:
`engine.renderViewport().pixelIndex(pt.lo())` (rect stride), NOT the square map; `catch` fallbacks
must be short LITERALS, never the `undefined` buffer. Left: image; right:
data+coord+palette. Menu: File→Save…/Open…/Quit, Help→About. Palette widgets edit
stops/mode/period/interior; `applyEdits`→setter→re-upload, NEVER re-iterates. `editor.zig` (PURE):
`Editor`+`toGradient`+`addStop`/`removeStop`. `stats.zig` (PURE):
`Stats{render_ms,frame_ms,gpu_render_ms}`, `renderSummary`.

## Stack, bridge, `Ui` (imgui.zig)

Vendored via `build.zig`: cimgui + Dear ImGui docking + SDL3/SDLGPU3 backends. `../cimgui.zig`
holds `extern` decls, NOT `@cImport cimgui.h` (docking bitfields → `opaque{}`); add a decl there
for a scalar call (e.g. `igSetNextItemWidth`). Bridge (`vendor/bridge`) wraps by-value `ImVec2`
calls: `ffImguiFillMainViewport`, `ffImguiContentAvail`, `ffImguiBeginChild`/`End`,
`ffImguiImage(texture,w,h)`, `ffImguiSetCursorScreenPos`. Per frame:
`newFrame()`→build→`endFrame()`→`prepareDrawData(cmd)` BEFORE the render
pass→`renderDrawData(cmd,pass)`. Init order:
`SDL_Init`→`CreateWindow`→`Device.create`→`Ui.init`.

## Navigation + progressive render (main.zig)

`NavState` holds the drag/right-click/pass/idle state. Left-drag→`navigate.boxSelect` on release;
middle/Space+left→`panByPixels`, reset delta after; scroll→`cursorCoord`+`zoomAbout`;
right-click→`drawContextMenu`→`zoomCentered`; hover→`formatCoord` tooltip. EVERY view/policy
change goes through
`applyViewCoarse`/`showViewCoarse`/`showPolicyCoarse`:
`cancelPass`→`installView`/`installPolicy`→`renderCoarse` (blocking `resizeRect`, dividing EACH
axis by `coarse_divisor` so the preview keeps the aspect)→`syncFromView`→`armFullPass`. NOTHING
iterates at full res synchronously. `refine.decidePass` fires `beginFullPass`; `stepPassChunk` runs
one `engine.stepPass()` per frame. While `engine.pass != null` the loop `SDL_PollEvent`s; else
`SDL_WaitEventTimeout(16)` when a pass is owed, `-1` when idle.

## Coord panel + ViewEditor

`ViewEditor` (`editor.zig`, PURE, tested): center re/im + corner a/b re/im buffers are
`coord_buf_bytes` (= `viewport.coord_text_buf_len`, 64 B), `mag_buf` 32 B, `auto_iter`,
`manual_iter_buf`. COORDINATES are `f128` throughout: `writeCoordHi` formats `{d:.34}`
(`viewport.max_coord_digits`) then TRIMS trailing zeros — same decimal value, so `parseCoordHi`
returns the identical `f128` (`-0.75`, not 34 zeros). Magnification and `manual_iter_buf` stay
f64/u32 (`writeF64`/`parseF64`). NEVER cut editable text to `coordDigits` (it drops real digits);
that count is the readout's, applied inside `viewport.formatCoord(buf,pt,mag)`. `panels.zig` sizes
fields via `coordFieldWidth()` so 34 decimals SHOW (hence `data_panel_w` 340).
`initFromView`/`syncFromView` fill all 7; `syncFromPolicy` inverts `parseIterPolicy`.
`parseAndApplyCenterMag`/`parseAndApplyCorners`→`?SquareView`, `parseIterPolicy`→`?IterPolicy`;
null on failure. `drawCoordPanel` REQUESTS, never applies: returns `CoordRequest{view,policy}` for
`main.zig`; parse failure logs `.err` and re-syncs.

## File dialog (M5): dialog.zig

`PendingDialog{kind,path_buf,path_len}` — stack-alloc in `runLoop`, outlives callbacks.
`showSave`/`showOpen(window,pending)` no-op unless `kind == .none`. `takePending`→`?PendingResult`,
`null` on cancel. The `callconv(.c)` callback writes the path in, never allocates. Filter
`*.fractal`.

## Testing

Visual = manual smoke + log check. Pure (`stats.zig`,
`editor.zig`) IS unit-tested; `dialog.zig` is glue. `panels.zig` is NOT in `root.zig`, so a test
written there never runs.
