<!-- LLM-only context for src/ui/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/ui/ context

## Purpose

Own Dear ImGui: context, SDL3+SDL_GPU backends, per-frame cycle, layout, palette editor; keep ImGui/SDL types behind `../c.zig`/`../cimgui.zig`.

## Aspect + resize

Render target=the fractal REGION (`render_w/render_h`); `main.zig` targets it full-res, re-arming
on change. `viewport.fitImageRect` letterboxes, NEVER stretches, IS the coordinate-mapping rect.
Keep `no_scrollbar`: its width cut a `ContentAvail`→region→content oscillation that cancelled
passes.

## Layout: single window, two fixed regions

`panels.zig`—`draw(…)→DrawResult{ctx_action,image_rect,render_w,render_h,needs_rerender,
save_requested,open_requested,coord}`: `image_rect`=fitted ON-SCREEN rect (mapping),
`render_w/h`=REGION size. `rendering` freezes the WHOLE data panel
(`igBeginDisabled`), leaving only image+wheel/pinch+progress live;
`progress`(=`engine.passFraction()`) swaps the readout for
`igProgressBar`+`progressive.progressLabel`. Status-bar lookup:
`engine.renderViewport().pixelIndex(pt.lo())` (rect stride), NOT the square map. Left: image; right: data+coord+palette. Menu: File→Save/Open/Quit, Help.
Palette widgets edit stops/mode/period/banded(checkbox)/interior; `applyEdits`→setter→re-upload, NEVER re-iterates.
`editor.zig` (PURE): `Editor{…,banded}`+`params()`(carries `banded`)+`toGradient`+`addStop`/`removeStop`+`syncFromColouring`(re-fill from a loaded colouring—`main.zig` calls it on every load so the panel shows what loaded)+`applyScheme`(load a preset/scheme as an EDITABLE start)+`indexToInputMode`. `stats.zig`
(PURE): `Stats{render_ms,frame_ms,gpu_render_ms}`, `renderSummary`.

## Stack, bridge, `Ui` (imgui.zig)

`build.zig` vendors cimgui+ImGui docking+SDL3/SDLGPU3 backends. `../cimgui.zig` holds
`extern` decls, NOT `@cImport cimgui.h` (docking bitfields→`opaque{}`). Bridge
(`vendor/bridge`) wraps by-value `ImVec2` calls (`ffImgui*`). Per frame:
`newFrame()`→build→`endFrame()`→`prepareDrawData(cmd)` BEFORE the render
pass→`renderDrawData(cmd,pass)`. Init order:
`SDL_Init`→`CreateWindow`→`Device.create`→`Ui.init`.

## Navigation + progressive render (main.zig)

`NavState` holds drag/right-click/pass/idle + gesture state
(`gestures`/`history_debt`/`past_floor`/`input_mode`). Left-drag→`navigate.boxSelect` on release;
middle/Space+left→`panByPixels`. wheel/pinch→`nav.gestures` (pure
`ui/gesture.zig`, tests in `src/gesture_test.zig`):
`Accumulator.addPinch`(INCREMENTAL,multiplies)/`addWheel`/`endPinch`+`take()` DRAIN a frame to ONE
`Intent{zoom_factor,pan_dx,pan_dy,began}`; `zoom_factor` INVERTS scale (open⇒<1⇒zoom IN, SIDE mult);
ONLY `endPinch` ends a pinch run, a `.wheel_pan` run ends on a pan-less drain, bad input IGNORED;
`classifyWheel(sample,mode)` by `nav.input_mode` (Input combo REQUESTS `CoordRequest.input_mode`):
`.mouse`/`.trackpad` wins, `.auto` pans on ANY horizontal then `y!=integer_y`
(whole-tick, NOT `@floor`), else zooms. Installed
ONCE/frame zoom-about-`cursorCoord`|pan-by-`real_s`, `began`⇒`HistoryDebt` (1 undo/run, OWED till a
view installs);
right-click→`drawNavContextMenu`→`zoomCentered`; hover→`viewport.formatCoord` in the STATUS
BAR. EVERY view/policy change goes through
`applyViewCoarse`/`showViewCoarse`/`showPolicyCoarse`:
`cancelPass`→`installView`/`installPolicy`→`renderCoarse` (blocking, per-axis `coarse_divisor`)
→`syncFromView`→`armFullPass`; NOTHING iterates full-res synchronously.
`refine.decidePass` fires `beginFullPass`; `stepPassChunk` runs one `engine.stepPass()`/frame.
Pump: `engine.pass!=null`→`SDL_PollEvent`, else `SDL_WaitEventTimeout(16)` when a pass is owed / `-1`
idle.

## Coord panel + ViewEditor

`ViewEditor` (`editor.zig`, PURE, tested): center re/im + corner a/b re/im buffers are
`coord_buf_bytes` (=`viewport.coord_text_buf_len`, 64 B); `mag_buf` SAME; `auto_iter`;
`manual_iter_buf`. COORDINATES are `f128`. `writeCoordHi`: `std.fmt.float.render` `.decimal` else `.scientific`,
keeping the decimal ONLY if it re-parses to the identical `f128`. NEVER `{d}` an `f128` (⇒`(float)`);
`parseCoordHi` reads EXPONENT form back, never truncate.
`coordDigits`/`max_coord_digits` budget the READ-ONLY readout (`viewport.formatCoord`); NEVER cut
editable text to them. `mag`/`manual_iter_buf` stay f64/u32 (`writeF64`/`parseF64`).
`initFromView`/`syncFromView` fill all 7; `syncFromPolicy(policy,engine.max_iter)` shows the count
IN USE (ramp's under Auto, NOT `policy.manual_value`); `iterFieldReadOnly()`(=`auto_iter`)⇒field
read-only+greyed, re-synced every frame; `leaveAuto` (TOTAL) pins what SHOWS, else `base_max_iter`;
`iterRejection`→`IterRejection` picks the `.err` message.
`parseAndApplyCenterMag`/`parseAndApplyCorners`→`?SquareView`, `parseIterPolicy`→`?IterPolicy`;
`drawCoordPanel` REQUESTS (returns `CoordRequest{view,policy,input_mode}`), never applies; parse
failure logs `.err` and re-syncs. `writeF64` RESERVES the last byte⇒ALWAYS terminated (else
`InputTextEx` aborts), `.scientific` when the decimal won't fit.

## File dialog: dialog.zig

`PendingDialog{kind,path_buf,path_len}`—stack-alloc in `runLoop`, outlives callbacks.
`showSave`/`showOpen(window,pending)` no-op unless `kind==.none`. `takePending`→`?PendingResult`,
`null` on cancel. `callconv(.c)` callback writes the path in. Filter
`*.fractal`.

## Testing

Visual=manual smoke+logs. `stats.zig`/`editor.zig`/`gesture.zig` are PURE+unit-tested; `dialog.zig`
is glue. M6 DECISION: `panels.zig` imports `c.zig`⇒OUT of `root.zig`, its tests NEVER run—keep pure
logic in `editor.zig`/`stats.zig`/`gesture.zig`.
