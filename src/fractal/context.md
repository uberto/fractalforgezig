<!-- LLM-only context for src/fractal/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/fractal/ context

## Purpose

Pure fractal core: the math that turns a viewport into a Mandelbrot image.
NEVER `@cImport` or import SDL/GPU/`c.zig` here — this folder is the fast, isolated
test tier and must run under `zig build test` with no window/GPU. Keep every function
pure: no globals, no clock/random, deterministic. Register each new module in
`src/root.zig`'s `test` block (`_ = @import("fractal/<mod>.zig");`).

## Modules

- `viewport.zig` — shipped (T3). Maps pixels to the complex plane. Symbols:
  - `Viewport` struct: `center_re`, `center_im` (f64), `scale` (complex units per
    pixel, shared across both axes ⇒ square pixels, never stretched), `width`,
    `height` (u32).
  - `Viewport.fixedView(width, height) Viewport` — the fixed M0 view (plan: no
    navigation). Centers on the region midpoint; smallest uniform `scale` that
    *contains* the whole region (letterbox the axis exceeding `3.5 : 2.5`).
  - `Viewport.pixelToComplex(px, py) Complex` — the mapping; `px`/`py` f64 continuous.
  - `Complex` struct: `{ re, im }`.
  - Fixed bounds as pub consts: `fixed_re_min/max` = `-2.5 / 1.0`,
    `fixed_im_min/max` = `-1.25 / 1.25`.
- `mandelbrot.zig` — shipped (T4). `iterate(c_re, c_im, max_iter) f32` → smooth escape
  value, or `interior_sentinel` (`-1.0`) for interior.
- `color.zig` — M0 grayscale STOPGAP. `smoothToRgba(smooth, max_iter) Rgba8`
  (grayscale + opaque-black `interior_color`); `Rgba8 = [4]u8`. Superseded by the M2
  color pass (T4); do not extend it.
- `iterbuf.zig` — shipped (T1). ITERATION stage only: fills a persistent `[]f32`
  smooth-value buffer (CPU analogue of the spec's `R32Float` texture). Does NO
  coloring — M2 decouples iterate-once from recolor-cheap. Reuses
  `viewport.pixelToComplex` + `mandelbrot.iterate` verbatim. Symbols:
  - `iterationBufferLen(vp) usize` — one f32 per pixel (`width*height`).
  - `iterateInto(buf: []f32, vp, max_iter) IterError!void` — PURE, deterministic.
    `buf.len` must equal `iterationBufferLen(vp)` else `IterError.BufferSizeMismatch`
    (no logging — the edge logs). Samples pixel CENTER (`x+0.5`,`y+0.5`). Interior
    keeps the exact `-1.0` `mandelbrot.interior_sentinel`; escaped are finite `!= -1.0`.
  - `iterate(alloc, vp, max_iter) !IterationResult` — timing/alloc wrapper.
    `IterationResult{ values: []f32 (caller frees), elapsed_ns: u64 }`; `std.time.Timer`
    lives ONLY here — never assert on `elapsed_ns` magnitude.
  - Golden test = key-pixel assertions on the 64x48 fixed view (interior sentinel,
    slow-escape exterior, top/bottom symmetry). RGBA golden moved to T4.

## Coordinate convention (do not get this wrong)

Pixel space: origin TOP-LEFT, x right, y DOWN; `(0,0)` = top-left corner of pixel 0,
`(width,height)` = bottom-right image corner; integer `+0.5` hits a pixel center.
Complex space: `re` right, `im` UP. Pixel-y and complex-im point OPPOSITE, so
`pixelToComplex` NEGATES the y term: smaller pixel-y ⇒ larger `im` (top of screen is
max imaginary). Flipping this mirrors the set vertically; pinned by the orientation
and corner tests, and by iterbuf.zig's symmetry test.

## M7 precision seam

`center_re`/`center_im` are `f64` today — a deliberate defer (see the plan). Arbitrary
precision is only needed near ~1e-15 magnification (M7); the type is isolated in
`Viewport` so M7 can widen it. Do not do precision-sensitive math on the raw `f64`.

## Tests

In-file `test "..."` blocks, one intent each. Assert coordinate orientation
explicitly; `expectApproxEqAbs` with tight tolerance for f64 mapping.
