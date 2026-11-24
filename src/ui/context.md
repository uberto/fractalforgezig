<!-- LLM-only context for src/ui/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/ui/ context

## Purpose

Keep Dear ImGui and SDL types behind `../c.zig` and `../cimgui.zig`.

## Aspect + resize

Render target=fractal REGION (`render_w/render_h`); `main.zig` targets it full-res, re-arming
on change. `viewport.fitImageRect` letterboxes, NEVER stretches, IS the coordinate-mapping rect.
Keep `no_scrollbar` to avoid resize oscillation.

## Layout: single window, two fixed regions

`panels.zig`—`draw(…)→DrawResult{ctx_action,image_rect,render_w,render_h,needs_rerender,
save_requested,open_requested,coord,toggle_julia/orbit/fullscreen}`:`image_rect`=fitted ON-SCREEN
rect(mapping),`render_w/h`=REGION size. `rendering` freezes data panel(`igBeginDisabled`),leaving image navigation and the status bar enabled. Pass inspector and full-screen flags to
`drawMenuBar`. Apply `DrawResult` requests in main. Status-bar lookup:`engine.renderViewport().pixelIndex(pt.lo())`(rect stride),NOT square map.
Palette edits stops/mode/period/banded/interior;
`applyEdits`→setter→deferred main upload,NEVER re-iterates. `drawPalettePanel` draws preset
grid(`drawSwatchGallery`):`SwatchGallery` bakes each `presets.gradientOf` to a texture ONCE,
click→`applyPreset`. `editor.zig`(PURE):`Editor{…,banded}`+`params()`(carries `banded`)+`toGradient`
+`addStop`/`removeStop`+`syncFromColouring`+`applyScheme`+`indexToInputMode`.
`stats.zig`(PURE):`Stats{render_ms,frame_ms,gpu_render_ms}`,`renderSummary`.

## Inspectors (main.zig glue,pilot-only)

Two OWN top-level `igBegin`/`igEnd`(`p_open`⇒T5 close box). `JuliaInspector`:256²,`iterateJuliaInto`
+`colorInto`,freeze-on-leave. `OrbitInspector`:full-set backdrop baked ONCE(re-bake on
resize/palette),overlays `orbit.compute` via `ImDrawList_AddCircleFilled`/`_AddLine`(cimgui);
`connect` toggles path. Texture upload DEFERRED.

## Navigation + progressive render (main.zig)

`NavState` holds drag/right-click/pass/idle+gesture state
(`gestures`/`history_debt`/`past_floor`/`input_mode`). Left-drag→`navigate.boxSelect` on release;
middle/Space+left→`panByPixels`. wheel/pinch→`nav.gestures`(pure `ui/gesture.zig`):
`addPinch`(INCREMENTAL,multiplies)/`addWheel`/`endPinch`+`take()` DRAIN a frame→ONE
`Intent{zoom_factor,pan_dx,pan_dy,began}`;`zoom_factor` INVERTS scale(open⇒zoom IN);ONLY `endPinch`
ends a pinch run,a `.wheel_pan` run ends on a pan-less drain,bad input IGNORED;
`classifyWheel(sample,mode)` by `nav.input_mode`(Input combo REQUESTS `CoordRequest.input_mode`):
`.mouse`/`.trackpad` wins,`.auto` pans on ANY horizontal then `y!=integer_y`(whole-tick),else
zooms. Installed ONCE/frame zoom-about-`cursorCoord`|pan-by-`real_s`,`began`⇒`HistoryDebt`(1
undo/run,OWED till a view installs);right-click→`zoomCentered`;hover→`viewport.formatCoord`. EVERY
view/policy change→`applyViewCoarse`/`showViewCoarse`/`showPolicyCoarse`:`cancelPass`→
`installView`/`installPolicy`→`renderCoarse`(blocking,per-axis `coarse_divisor`)→`syncFromView`
→`armFullPass`;nothing iterates full-res synchronously. `refine.decidePass(…,nav.cancelled)` fires
`beginFullPass`;`stepPassChunk` runs one `engine.stepPass()`/frame. m9 Cancel:`requestCancel`(status
Cancel OR Escape while `rendering`)⇒`cancelPass`+`rendering=false`,`full_pass_done`/`cancelled=true`,
logs `render cancelled at NN%`;`cancelled` suppresses promotion(no re-arm loop). Render⇒`armFullPass`
clears `cancelled`,as does every view change. Pump: live pass/present owed → poll. Otherwise use `export_flow.waitMs` (16 ms
for live work or pickers, 50 ms for an active export, indefinite while idle).

## Coord panel + ViewEditor

`ViewEditor` (`editor.zig`, PURE, tested): center re/im + corner a/b re/im buffers
`coord_buf_bytes`(64 B), `mag_buf` SAME, `auto_iter`, `manual_iter_buf`. COORDINATES `f128`. `writeCoordHi`: `.decimal` else `.scientific`, keeping
decimal ONLY if it re-parses identical. NEVER `{d}` an `f128`; `parseCoordHi` reads EXPONENT back.
`coordDigits`/`max_coord_digits` budget the READ-ONLY readout; NEVER cut editable text.
`mag`/`manual_iter_buf` stay f64/u32.
`initFromView`/`syncFromView` fill all 7; `syncFromPolicy(policy,max_iter)` shows the count
IN USE (ramp under Auto); `iterFieldReadOnly()`(=`auto_iter`)⇒read-only+greyed, re-synced/frame;
`leaveAuto`(TOTAL) pins what SHOWS else `base_max_iter`; `iterRejection`→`IterRejection` picks the
`.err` msg.
`parseAndApplyCenterMag`/`parseAndApplyCorners`→`?SquareView`, `parseIterPolicy`→`?IterPolicy`;
`drawCoordPanel` REQUESTS (returns `CoordRequest{view,policy,input_mode}`), never applies; parse
failure logs `.err` and re-syncs.

## Pickers and PNG export

`dialog.zig` owns native filters and callbacks. Legacy `PendingDialog` manages fractal and
scheme dialogs. PNG uses process-lifetime `export_flow.Picker` to copy complete paths and publish
terminal outcomes atomically when SDL invokes the callback off-thread.

`export_panel.Panel` stays on main; hold one `Capture` from dimensions through picker and optional
exact-path overwrite confirmation. Use the fresh fitted rect for defaults and `Displayed.scene`
for render geometry, view and colors. Only successful texture uploads replace the displayed
metadata. Poll `image_export.Worker` while active; keep SDL and ImGui on main. Scheme load uses
`scheme.applyToEngine`→`syncFromColouring`→deferred upload.

## Testing

`stats.zig`/`editor.zig`/`gesture.zig` PURE+unit-tested; `dialog.zig`
glue. `panels.zig` imports `c.zig`⇒OUT of `root.zig`, tests NEVER run—keep pure logic in
`editor.zig`/`stats.zig`/`gesture.zig`. Pilot View menu and full screen.

Bind BLA to `engine.use_bla` in `drawDataPanel` and report `needs_rerender`. Disable BLA
when `engine.usesDeepPath()` is false.
