<!-- LLM-only context for src/fractal/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/fractal/ context

## Purpose

Pure fractal core: viewport → Mandelbrot image. NEVER import SDL/GPU/`c.zig`/log or `@cImport`
here — fast test tier (no window/GPU). Pure/deterministic: no globals/clock/random; register
every module in `src/root.zig`'s `test` block.

The decoupling: ITERATION runs ONCE into a persistent `[]f32`; the CHEAP color pass
reruns on palette edits WITHOUT re-iterating (`iterbuf`→`colorpass`, baked `gradient` LUT +
`mapping` → RGBA8; `engine` owns state + both counters).

## Modules

- `viewport.zig` — M3 view model + pixel↔complex. `SquareView{center_re, center_im, side: f64}`
  (aspect 1); `defaultView()` = the square containing the M0 region (center
  `-0.75+0i`, side 3.5). Duals `centerMag()`/`fromCenterMag` (`magnification()` =
  `1/(side·√2)`) and `corners()`/`fromCorners` (`min`=bottom-left; SNAPS square by the LARGER
  axis, around the midpoint); they and `fromCenterSide` validate → `ViewportError.DegenerateRegion`,
  unlogged — the edge logs `degenerateRegionMessage(buf[message_buf_len],what,value)`.
  `pixelToComplex(px,py,S)`/`complexToPixel(c,S)` (assert `S>0`);
  `cursorCoord(wx,wy,ImageRect{x,y,side})`→`?Complex`, null over letterbox bars;
  `imageViewport(S)`→M0 `Viewport` for `iterbuf` (`fixedView(w,h)`=M0 path). Readout:
  `coordDigits(mag)`=`clamp(4+ceil(log10 mag),4,17)`; `formatCoord(buf,c,mag)` → `"a ± bi"`,
  `coord_buf_len`=64. `Complex{re,im}`; `fixed_re_min/max`=-2.5/1.0,
  `fixed_im_min/max`=∓1.25.
- `navigate.zig` — T2 transforms → a NEW `SquareView`; `factor` scales the SIDE (`<1`=zoom IN;
  `zoom_step_in`=0.5/`zoom_step_out`=2.0). `zoomAbout(v,anchor,f)` pins `anchor` to its pixel
  (scroll); `zoomCentered(v,point,f)` recenters (right-click); `panByPixels(v,dpx,dpy,S)` moves
  the VIEW (pass NEGATED mouse delta; `(0,+S)` lowers `im`); `boxSelect(v,a,b,S)` square-snaps
  a drag; `reset()`=`defaultView()`. All→`DegenerateRegion` on non-finite input,
  zero-area drag, `S==0`, side over/underflow. Warn-only floor: `atPrecisionFloor(v)`
  (`side<precision_floor_side`=1e-13); `precisionFloorMessage(buf[floor_message_buf_len],side)`.
- `autoiter.zig` — T3 `max_iter` policy (A6); T4/T7 READ it, never re-derive it.
  `autoMaxIter(mag) IterError!u32`=`clamp(base_max_iter(512)+iter_per_doubling(80)·
  log2(mag/default_magnification),512,max_max_iter(4096))`,
  round-to-nearest, MONOTONE; non-finite/≤0 `mag`→`InvalidMagnification` (edge logs it via
  `viewport.degenerateRegionMessage`). `IterPolicy{auto=true,manual_value=512}`: `manual(v)`
  validates `[min_manual_iter(16),4096]` else `MaxIterOutOfRange`; `effective(mag)`=ramp when
  `auto` else `clampManual(v)`. `maxIterRangeMessage(buf[range_message_buf_len],v)`;
  `policySummary(buf[summary_buf_len],policy,mag)`→`"max_iter=1152 (auto)"`.
- `mandelbrot.zig` — `iterate(c_re,c_im,max_iter) f32`→smooth escape value, else
  `interior_sentinel`(-1.0).
- `color.zig` — M0 STOPGAP; `Rgba8 = [4]u8`, `interior_color`.
- `gradient.zig` — palette + LUT bake. `Stop{pos:f32 in [0,1], color:Rgba8}`; `Gradient`=
  fixed-cap (`max_stops`=32) ascending array; `fromStops(slice)` debug-asserts ascending/in-range;
  `stops()`; `bakeLut(g,out:*[lut_size=1024]Rgba8)` interpolates per channel; `default()`=5-stop
  opaque.
- `mapping.zig` — smooth→[0,1] LUT-index maps. `Mode = enum{linear,log,cyclic}`;
  `Params{mode=.linear, period=default_period(32.0)}` (cyclic-only, >0).
  `mapToUnit(smooth,max_iter,params) f32` CLAMPED [0,1] (cyclic [0,1)); bad inputs→0.
- `iterbuf.zig` — ITERATION only. `iterationBufferLen(vp)`=w*h; `iterateInto(buf:[]f32, vp,
  max_iter) IterError!void` PURE (+0.5 pixel centers; bad `buf.len`→`BufferSizeMismatch`);
  `iterate(...)` wraps it → `IterationResult{values, elapsed_ns}` (caller frees);
  `std.time.Timer` ONLY here.
- `colorpass.zig` — the cheap pass. `colorInto(rgba, iter, lut:*const [1024]Rgba8, max_iter,
  params, interior) ColorError!void` PURE; `rgba.len==iter.len*4` guard runs BEFORE any write else
  `BufferSizeMismatch`; sentinel→`interior`; alpha FORCED 255.
- `engine.zig` — the DECOUPLING crux. `Engine` owns `iter:[]f32`, `rgba:[]u8`, `vp`,
  `max_iter`, `gradient`+`lut`, `params`, `interior`, read-only
  `iteration_passes`/`color_passes`. `init(alloc,vp,max_iter)` allocs+zeroes, installs
  `default()`/linear/opaque-black WITHOUT iterating; `deinit()` frees. `iterate()` refills+recolors,
  bumping BOTH counters (the only `iteration_passes` path).
  `setGradient(g)` (→`EmptyGradient` if `g.count==0`)/`setMapping(p)`/`setInterior(c)` rerun ONLY
  the color pass: bump `color_passes`, leave `iteration_passes` UNCHANGED.
  `output()`; `summary(buf)`/`colorPassSummary(...)`→`"color pass {n}: mode={s}, stops={k}"`
  (edge logs). `EngineError{EmptyGradient, BufferSizeMismatch}`, never `unreachable`.

## Coordinate convention

Pixel space: origin TOP-LEFT, x right, y DOWN; integer +0.5 = pixel center. Complex: `re` right,
`im` UP — so every pixel→complex NEGATES the y term (top row = max im). Centers stay `f64` (M7
defer, in `viewport.zig`); deep-zoom round-trips ULP-limited. Tests are in-file,
one intent.
