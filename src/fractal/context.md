<!-- LLM-only context for src/fractal/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/fractal/ context

## Purpose

Pure fractal core: viewport → Mandelbrot image. NEVER import SDL/GPU/`c.zig`/log or `@cImport`
here — this is the fast test tier (no window/GPU). Keep functions pure: no globals/clock/random,
deterministic. Register every module in `src/root.zig`'s `test` block.

The decoupling (M2's point): ITERATION runs ONCE into a persistent `[]f32`; the CHEAP color pass
reruns on palette/mapping edits WITHOUT re-iterating (`iterbuf` → `colorpass` with a baked
`gradient` LUT + `mapping` → RGBA8; `engine` owns the state and the two proving counters).

## Modules

- `viewport.zig` — M3 view model + pixel↔complex. `SquareView{center_re, center_im, side: f64}`
  (aspect 1, NO resolution); `defaultView()` = the square containing the M0 region (center
  `-0.75+0i`, side 3.5). Lossless duals `centerMag()`/`fromCenterMag` (`magnification()` =
  `1/(side·√2)`) and `corners()`/`fromCorners` (`min`=bottom-left; SNAPS to a square by the LARGER
  axis around the midpoint); they and `fromCenterSide` validate → `ViewportError.DegenerateRegion`,
  unlogged — the edge logs `degenerateRegionMessage(buf[message_buf_len],what,value)`.
  `pixelToComplex(px,py,S)`/`complexToPixel(c,S)` (assert `S>0`);
  `cursorCoord(wx,wy,ImageRect{x,y,side})` → `?Complex`, null over letterbox bars;
  `imageViewport(S)` → the M0 `Viewport` `iterbuf` iterates (`fixedView(w,h)` = M0 path). Readout:
  `coordDigits(mag)` = `clamp(4+ceil(log10 mag),4,17)`, `formatCoord(buf,c,mag)` →
  `"a + bi"`/`"a - bi"`, `coord_buf_len`=64. `Complex{re,im}`; `fixed_re_min/max`=-2.5/1.0,
  `fixed_im_min/max`=∓1.25.
- `mandelbrot.zig` — `iterate(c_re,c_im,max_iter) f32` → smooth escape value, or
  `interior_sentinel` (-1.0) inside.
- `color.zig` — M0 STOPGAP; only `Rgba8 = [4]u8` + `interior_color` still used.
- `gradient.zig` — palette model + LUT bake. `Stop{pos: f32 in [0,1], color: Rgba8}`;
  `Gradient` = fixed-cap (`max_stops`=32) ascending-`pos` array; `fromStops(slice)` debug-asserts
  ≥1/ascending/in [0,1]; `stops()`. `bakeLut(g, out: *[lut_size = 1024]Rgba8)` per-channel linear
  interp, ends clamped; `default()` = 5-stop palette, opaque.
- `mapping.zig` — smooth→[0,1] LUT-index transforms. `Mode = enum{linear,log,cyclic}`;
  `Params{mode = .linear, period = default_period (32.0)}` (cyclic-only, >0).
  `mapToUnit(smooth,max_iter,params) f32` CLAMPED [0,1] (cyclic [0,1)); bad inputs → 0.
- `iterbuf.zig` — ITERATION only. `iterationBufferLen(vp)` (=w*h); `iterateInto(buf: []f32, vp,
  max_iter) IterError!void` PURE (pixel center +0.5; interior keeps -1.0; wrong `buf.len` →
  `IterError.BufferSizeMismatch`, unlogged). `iterate(...)` wraps it →
  `IterationResult{values (caller frees), elapsed_ns}`; `std.time.Timer` lives ONLY here.
- `colorpass.zig` — the cheap pass. `colorInto(rgba: []u8, iter: []const f32, lut: *const
  [1024]Rgba8, max_iter, params, interior) ColorError!void` PURE; the
  `rgba.len==iter.len*4` guard runs BEFORE any write else `BufferSizeMismatch`. Per pixel: sentinel
  → `interior`, else `lut[clamped @intFromFloat(mapToUnit(...)*1023)]`. Alpha FORCED 255.
- `engine.zig` — the DECOUPLING crux, pure. `Engine` owns `iter: []f32`, `rgba: []u8`, `vp`,
  `max_iter`, `gradient`+baked `lut`, `params`, `interior`, read-only
  `iteration_passes`/`color_passes`. `init(alloc,vp,max_iter)` allocs+zeroes and installs
  `default()`/linear/opaque-black WITHOUT iterating; `deinit()` frees. `iterate()` refills+recolors,
  bumping BOTH counters (the only path touching `iteration_passes`).
  `setGradient(g)`/`setMapping(p)`/`setInterior(c)` rerun ONLY the color pass, bump `color_passes`,
  leave `iteration_passes` UNCHANGED; `setGradient` returns `EmptyGradient` before mutating if
  `g.count==0`. `output()`; `summary(buf)`/`colorPassSummary(...)` → `"color pass {n}: mode={s},
  stops={k}"` (exact string tested; the edge logs it). `EngineError{EmptyGradient,
  BufferSizeMismatch}` — typed, never `unreachable`.

## Coordinate convention

Pixel space: origin TOP-LEFT, x right, y DOWN; integer +0.5 = pixel center. Complex: `re` right,
`im` UP — so every pixel→complex NEGATES the y term (top row = max im), pinned by tests. Centers
stay `f64` (M7 defer, isolated in `viewport.zig`); deep-zoom round-trips are ULP-limited, not
broken. Tests are in-file, one intent.
