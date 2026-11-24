<!-- LLM-only context for src/ui/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/ui/ context

## Purpose

Own Dear ImGui: context, SDL3+SDL_GPU backends, cycle, layout, palette editor; keep ImGui/SDL types behind `../c.zig`/`../cimgui.zig`.

## Aspect + resize

Render target=fractal REGION (`render_w/render_h`); `main.zig` targets it full-res, re-arming
on change. `viewport.fitImageRect` letterboxes, NEVER stretches, IS the coordinate-mapping rect.
Keep `no_scrollbar`: cut a `ContentAvail`→region→content oscillation that cancelled passes.

## Layout: single window, two fixed regions

`panels.zig`—`draw(…)→DrawResult{ctx_action,image_rect,render_w,render_h,needs_rerender,
save_requested,open_requested,coord,toggle_julia/orbit/fullscreen}`:`image_rect`=fitted ON-SCREEN
rect(mapping),`render_w/h`=REGION size. `rendering` freezes data panel(`igBeginDisabled`),leaving
image+wheel/pinch+status-bar live. Pass the live inspector and full-screen flags to `drawMenuBar`. Let main apply
`DrawResult` toggles and Cancel/Render requests. Keep the status bar enabled during rendering. Status-bar lookup:`engine.renderViewport().pixelIndex(pt.lo())`(rect stride),NOT square map.
Left image,right data+coord+palette. Palette edits stops/mode/period/banded/interior;
`applyEdits`→setter→re-upload,NEVER re-iterates. `drawPalettePanel` draws preset
grid(`drawSwatchGallery`):`SwatchGallery` bakes each `presets.gradientOf` to a texture ONCE,
click→`applyPreset`. `editor.zig`(PURE):`Editor{…,banded}`+`params()`(carries `banded`)+`toGradient`
+`addStop`/`removeStop`+`syncFromColouring`+`applyScheme`+`indexToInputMode`.
`stats.zig`(PURE):`Stats{render_ms,frame_ms,gpu_render_ms}`,`renderSummary`.

## Inspectors (main.zig glue,pilot-only)

Two OWN top-level `igBegin`/`igEnd`(`p_open`⇒T5 close box). `JuliaInspector`:256²,`iterateJuliaInto`
+`colorInto`,freeze-on-leave. `OrbitInspector`:full-set backdrop baked ONCE(re-bake on
resize/palette),overlays `orbit.compute` via `ImDrawList_AddCircleFilled`/`_AddLine`(cimgui);
`connect` toggles path. Texture upload DEFERRED.

## Frame setup

Use the cimgui extern declarations and the bridge for by-value `ImVec2` calls.
Call `newFrame`, build the UI, call `endFrame`, and prepare draw data before the render pass.

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
clears `cancelled`,as does every view change. Pump:`engine.pass!=null`→`SDL_PollEvent`,else
`SDL_WaitEventTimeout(16)` if owed/`-1` idle.

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

## File dialog: dialog.zig

`PendingDialog{kind,path_buf,path_len}`—stack-alloc in `runLoop`, outlives callbacks.
`showSave`/`showOpen`(+`…Scheme` variants)`(window,pending)` no-op unless `kind==.none`.
`takePending`→`?PendingResult`, `null` on cancel. Filters `.fractal`/`.fpal`(colour-only). Scheme
Save/Load: BUTTONS in the Coloring header, inside `igBeginDisabled(rendering)`; load
`scheme.fromJson`→`applyToEngine`(setters, no re-iterate)→`syncFromColouring`, bad file refused.

## Testing

Visual=manual smoke+logs. `stats.zig`/`editor.zig`/`gesture.zig` PURE+unit-tested; `dialog.zig`
glue. `panels.zig` imports `c.zig`⇒OUT of `root.zig`, tests NEVER run—keep pure logic in
`editor.zig`/`stats.zig`/`gesture.zig`. View menu + full screen are pilot-only glue.

In `drawDataPanel`, bind BLA beside GPU to `engine.use_bla` and report toggle changes through
`needs_rerender`. Disable BLA and show the deep-zoom hint when `engine.usesDeepPath()` is false.
Verify the control by hand.
