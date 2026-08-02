<!-- LLM-only for src/fractal/. Imperative, <=500 words, shipped APIs only. -->

# src/fractal/ context

## Purpose

Pure core: view → Mandelbrot image. NEVER import SDL/GPU/`c.zig`/`@cImport` (fast test tier). No
globals/clock/random; register each module in `src/root.zig`'s `test` block. Failures: TYPED
errors (never `unreachable`) + a pure message builder. ONLY `engine.zig` logs (scoped
`std.log(.fractal)`, strings from those builders).

Decoupling: ITERATION runs ONCE into a persistent `[]f32`; palette edits rerun ONLY the CHEAP
color pass (`iterbuf`→`colorpass`, baked `gradient` LUT + `mapping` → RGBA8).

## Modules

- `viewport.zig` — M3 view model + pixel↔complex. `SquareView{center_re,center_im,side:f64}`
  (aspect 1); `defaultView()`=M0's square (center `-0.75+0i`, side 3.5). Duals
  `centerMag()`/`fromCenterMag` (`magnification()`=`1/(side·√2)`) and `corners()`/`fromCorners`
  (`min`=bottom-left; SNAPS square by the LARGER axis about the midpoint); these and
  `fromCenterSide` → `ViewportError.DegenerateRegion` +
  `degenerateRegionMessage(buf[message_buf_len],what,value)`. `pixelToComplex(px,py,S)`/
  `complexToPixel(c,S)` (assert `S>0`); `cursorCoord(wx,wy,ImageRect{x,y,side})`→`?Complex`,
  null on letterbox; `imageViewport(S)`→M0 `Viewport` for `iterbuf`; `fixedView(w,h)`=M0;
  `computeImageRect(w,h)`→`ImageRect` (side=min(w,h), centered; side=0 for degenerate).
  Readout: `coordDigits(mag)`=`clamp(4+ceil(log10 mag),4,17)`;
  `formatCoord(buf,c,mag)`→`"a ± bi"`, `coord_buf_len`=64. `Complex{re,im}`;
  `fixed_re_min/max`=-2.5/1.0, `fixed_im_min/max`=∓1.25.
- `navigate.zig` — T2 transforms → a NEW `SquareView`; `factor` scales the SIDE (`<1`=zoom IN;
  `zoom_step_in`=0.5/`zoom_step_out`=2.0). `zoomAbout(v,anchor,f)` pins `anchor` to its pixel
  (scroll); `zoomCentered(v,point,f)` recenters (right-click); `panByPixels(v,dpx,dpy,S)` moves
  the VIEW (pass NEGATED mouse delta; `(0,+S)` lowers `im`); `boxSelect(v,a,b,S)` square-snaps
  a drag; `reset()`=`defaultView()`. All→`DegenerateRegion` on non-finite input, zero-area drag,
  `S==0`, side over/underflow. Warn-only floor: `atPrecisionFloor(v)`
  (`side<precision_floor_side`=1e-13); `precisionFloorMessage(buf[floor_message_buf_len],side)`.
- `refine.zig` — T6 coarse→fine helper. `PassDecision{coarse,full,none}`;
  `decidePass(interacting,idle_ns,full_pass_done)`; `idle_threshold_ns`=150 ms.
- `autoiter.zig` — T3 `max_iter` policy (A6); READ, never re-derive.
  `autoMaxIter(mag) AutoIterError!u32`=`clamp(base_max_iter(512)+iter_per_doubling(80)·
  log2(mag/default_magnification),512,max_max_iter(4096))`, round-to-nearest, MONOTONE;
  non-finite/≤0 `mag`→`InvalidMagnification`
  (`viewport.degenerateRegionMessage`). `IterPolicy{auto=true,manual_value=512}`:
  `manual(v)` validates `[min_manual_iter(16),4096]` else `MaxIterOutOfRange`; `effective(mag)`=
  ramp when `auto` else `clampManual(v)`. `maxIterRangeMessage(buf[range_message_buf_len],v)`;
  `policySummary(buf[summary_buf_len],policy,mag)`→`"max_iter=1152 (auto)"`, ALWAYS via
  `effective` (CLAMPED; propagates its error).
- `mandelbrot.zig` — `iterate(c_re,c_im,max_iter) f32`→smooth escape value, else
  `interior_sentinel`(-1.0).
- `color.zig` — M0 STOPGAP; `Rgba8=[4]u8`, `interior_color`, `smoothToRgba(smooth,max_iter)`→grayscale RGBA8.
- `gradient.zig` — palette + LUT bake. `Stop{pos:f32 in [0,1],color:Rgba8}`; `Gradient`=ascending
  fixed-cap (`max_stops`=32) array; `fromStops(slice)` asserts ascending; `stops()`;
  `bakeLut(g,out:*[lut_size=1024]Rgba8)`; `default()`=5-stop opaque.
- `mapping.zig` — smooth→[0,1] LUT-index maps. `Mode=enum{linear,log,cyclic}`;
  `Params{mode=.linear,period=default_period(32.0)}` (cyclic-only, >0);
  `mapToUnit(smooth,max_iter,params) f32` CLAMPED [0,1] (cyclic [0,1)); bad inputs→0.
- `iterbuf.zig` — ITERATION only. `iterationBufferLen(vp)`=w*h;
  `iterateInto(buf:[]f32,vp,max_iter) iterbuf.IterError!void` PURE (+0.5 pixel centers;
  bad `buf.len`→`BufferSizeMismatch`);
  `iterate(...)` wraps it → `IterationResult{values,elapsed_ns}` (caller frees; `std.time.Timer`).
- `colorpass.zig` — cheap pass.
  `colorInto(rgba,iter,lut:*const [1024]Rgba8,max_iter,params,interior) ColorError!void` PURE;
  `rgba.len==iter.len*4` checked BEFORE any write else
  `BufferSizeMismatch`; sentinel→`interior`; alpha FORCED 255.
- `engine.zig` — DECOUPLING crux + M3 state. `Engine` owns `view: SquareView`,
  `image_side`(S px), `policy`, DERIVED `max_iter`, `iter:[]f32`/`rgba:[]u8`, `gradient`+`lut`,
  `params`, `interior`, read-only `iteration_passes`/`color_passes`.
  `init(alloc,view,image_side,policy) ResizeError!Engine` allocs+zeroes, installs
  `default()`/linear/opaque-black WITHOUT iterating; `deinit()` frees.
  `iterate() IterateError!void` refreshes `max_iter` via `policy.effective`, refills via
  `imageViewport()`, recolors, logs; bumps BOTH counters — the ONLY `iteration_passes` path,
  shared by `setViewport(v)`/`setPolicy(p)`/`resize(S) ResizeError!void` (reallocs only on a
  pixel-count change). Failure-atomic: rejected input/alloc keeps the previous state.
  `setGradient(g)`(→`EmptyGradient` if `g.count==0`)/`setMapping(p)`/`setInterior(c)` rerun
  ONLY the color pass: bump `color_passes`, `iteration_passes` UNCHANGED (THE GUARANTEE, after
  navigation too). `output()`. Builders: `summary`/`colorPassSummary(...)`→
  `"color pass {n}: mode={s}, stops={k}"`;
  `iterateSummary(buf[iterate_summary_buf_len])`/`iteratePassSummary(buf,pass,view,S,policy)`→
  `"iterate pass 3: center=…, mag=…, max_iter=512 (auto), S=900px"` (max_iter ALWAYS from
  `policySummary`); `degenerateViewMessage(buf[viewport.message_buf_len],view)`;
  `imageSideMessage(buf[image_side_message_buf_len],S)`;
  `resizeFailureMessage(buf[resize_message_buf_len],S,bytes)`; `requestedBytes(S)` saturating.
  `EngineError{EmptyGradient,BufferSizeMismatch,DegenerateImageSide}`;
  `IterateError`=+`ViewportError`+`AutoIterError`; `ResizeError`=+`OutOfMemory`.

## Coordinate convention

Pixel: origin TOP-LEFT, y DOWN, +0.5=pixel center; `im` UP — pixel→complex NEGATES y (top=max im).
Centers `f64` (M7 defer). Tests in-file, one intent each.
