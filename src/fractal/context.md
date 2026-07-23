<!-- LLM-only context for src/fractal/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/fractal/ context

## Purpose

Pure fractal core: math turning a viewport into a Mandelbrot image. NEVER import
SDL/GPU/`c.zig`/log or `@cImport` here — this is the fast test tier (`zig build test`, no
window/GPU). Keep functions pure: no globals, no clock/random, deterministic. Register each
module in `src/root.zig`'s `test` block (`_ = @import("fractal/<mod>.zig");`).

The decoupling (M2's point): expensive ITERATION runs ONCE into a persistent `[]f32` buffer;
the CHEAP color pass reruns on every palette/mapping edit WITHOUT re-iterating. Flow: `iterbuf`
→ `colorpass` (baked `gradient` LUT + `mapping`) → RGBA8; `engine` owns state, proving it via
two counters.

## Modules

- `viewport.zig` — pixel → complex plane. `Viewport{ center_re, center_im: f64, scale, width,
  height: u32 }` (square pixels, fixed M0 view — no navigation); `fixedView(w,h)`;
  `pixelToComplex(px,py) Complex`; `Complex{re,im}`. Consts `fixed_re_min/max` = -2.5/1.0,
  `fixed_im_min/max` = -1.25/1.25.
- `mandelbrot.zig` — `iterate(c_re,c_im,max_iter) f32` → smooth escape value, or
  `interior_sentinel` (-1.0) for interior.
- `color.zig` — M0 grayscale STOPGAP: `smoothToRgba(...)`, `Rgba8 = [4]u8`, `interior_color`.
  Superseded by the M2 color pass; do not extend.
- `gradient.zig` — palette model + LUT bake; reuses `color.Rgba8`. `Stop{pos: f32 in [0,1],
  color: Rgba8}`; `Gradient` = fixed-cap (`max_stops`=32) ascending-`pos` array;
  `fromStops(slice)` (debug-asserts ≥1, ascending, in [0,1]); `stops()`.
  `lut_size`=1024; `bakeLut(g, out: *[1024]Rgba8)` per-channel linear interp, ends clamped;
  `default()` = 5-stop deep-blue→blue→white→orange→dark, opaque.
- `mapping.zig` — smooth→[0,1] LUT-index transforms. `Mode = enum{linear,log,cyclic}`;
  `Params{mode = .linear, period: f32 = default_period (32.0)}` (period cyclic-only, >0).
  `mapToUnit(smooth,max_iter,params) f32` CLAMPED [0,1] (cyclic [0,1)); forms inline; guards
  bad inputs → 0.
- `iterbuf.zig` — ITERATION only, no coloring. `iterationBufferLen(vp) usize` (=w*h);
  `iterateInto(buf: []f32, vp, max_iter) IterError!void` PURE (pixel center +0.5; interior keeps
  -1.0; `buf.len` mismatch → `IterError.BufferSizeMismatch`, no logging). `iterate(...)
  !IterationResult{values (caller frees), elapsed_ns}` wraps it; `std.time.Timer` lives ONLY
  here (never assert on its magnitude).
- `colorpass.zig` — the cheap pass; reuses `color.Rgba8`. `colorInto(rgba: []u8, iter: []const
  f32, lut: *const [1024]Rgba8, max_iter, params, interior: Rgba8) ColorError!void` PURE, no
  alloc; guard `rgba.len==iter.len*4` runs BEFORE any write else `BufferSizeMismatch`. Per pixel:
  sentinel → `interior`; else `idx=@intFromFloat(mapToUnit(...)*1023)` clamped → `lut[idx]`.
  Alpha FORCED 255.
- `engine.zig` — the DECOUPLING crux, pure. `Engine` owns `iter: []f32`, `rgba: []u8`, `vp`,
  `max_iter`, `gradient`+baked `lut`, `params`, `interior`, and public read-only
  `iteration_passes`/`color_passes`. `init(alloc,vp,max_iter)` allocs+zeroes buffers, installs
  `default()`/linear/opaque-black, does NOT iterate; `deinit()` frees. `iterate() EngineError!void`
  refills then recolors, bumps BOTH counters (only path touching `iteration_passes`).
  `setGradient(g)`/`setMapping(params)`/`setInterior(c)` rerun ONLY the color pass, bump
  `color_passes`, leave `iteration_passes` UNCHANGED; `setGradient` returns `EmptyGradient`
  (before mutating) if `g.count==0`. `output() []const u8`; `summary(buf)`/free
  `colorPassSummary(...)` → `"color pass {n}: mode={s}, stops={k}"` (exact-string tested; the
  edge logs it). `EngineError{EmptyGradient, BufferSizeMismatch}` — typed, never `unreachable`.

## Coordinate convention (get this right)

Pixel space: origin TOP-LEFT, x right, y DOWN; integer +0.5 hits a pixel center. Complex: `re`
right, `im` UP — opposite pixel-y, so `pixelToComplex` NEGATES the y term (top = max imaginary).
Pinned by orientation + iterbuf symmetry tests. `center_re/im` are `f64` — a deliberate M7
defer, isolated in `Viewport` so M7 can widen it. Tests are in-file `test` blocks, one intent.
