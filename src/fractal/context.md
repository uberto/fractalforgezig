<!-- LLM-only context for src/fractal/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/fractal/ context

## Purpose

Pure fractal core: the math that turns a viewport into a colored Mandelbrot image.
NEVER `@cImport` or import SDL/GPU/`c.zig` here — this folder is the fast, isolated
test tier and must run under `zig build test` with no window and no GPU device. Keep
every function pure: no hidden globals, no clock/random, deterministic. Register each
new module in `src/root.zig`'s `test` block (`_ = @import("fractal/<mod>.zig");`).

## Modules

- `viewport.zig` — shipped (T3). Maps pixels to the complex plane. Symbols:
  - `Viewport` struct: `center_re`, `center_im` (f64), `scale` (complex units per
    pixel, shared across both axes ⇒ square pixels, never stretched), `width`,
    `height` (u32).
  - `Viewport.fixedView(width, height) Viewport` — the fixed M0 view (plan: no
    navigation). Centers on the region midpoint; picks the smallest uniform `scale`
    that *contains* the whole fixed region (letterbox on the axis whose aspect
    exceeds the region's `3.5 : 2.5`).
  - `Viewport.pixelToComplex(px, py) Complex` — the mapping; `px`/`py` are f64
    continuous sample coordinates.
  - `Complex` struct: `{ re, im }`.
  - Fixed bounds as pub consts: `fixed_re_min/max` = `-2.5 / 1.0`,
    `fixed_im_min/max` = `-1.25 / 1.25`.
- `mandelbrot.zig` — shipped (T4). `iterate(c_re, c_im, max_iter) f32` → smooth
  escape value, or `interior_sentinel` (`-1.0`) for interior points.
- `color.zig` — shipped (T5). `smoothToRgba(smooth, max_iter) Rgba8` (grayscale +
  opaque-black `interior_color`); `Rgba8 = [4]u8`.
- `render.zig` — shipped (T6). Composes the three above; NO reimplementation of
  mapping/iteration/coloring. Symbols:
  - `renderInto(buf, vp, max_iter) RenderError!void` — PURE, deterministic fill.
    `buf.len` must equal `bufferLen(vp)`; mismatch returns
    `RenderError.BufferSizeMismatch` (no logging — pure core stays infra-free).
    Samples each pixel CENTER (`x+0.5`,`y+0.5`); every pixel opaque.
  - `render(alloc, vp, max_iter) !RenderResult` — timing/alloc wrapper.
    `RenderResult{ pixels: []u8 (caller frees), elapsed_ns: u64 }`. `std.time.Timer`
    lives ONLY here — never assert on `elapsed_ns` magnitude.
  - `bufferLen(vp) usize` — RGBA8 byte length (`width*height*4`).
  - Golden test = key-pixel assertions on the 64x48 fixed view: interior pixel =
    interior color, slow-escape exterior = non-black gray, plus top/bottom symmetry
    about the real axis.

## Coordinate convention (do not get this wrong)

Pixel space: origin TOP-LEFT, x right, y DOWN; `(0,0)` = top-left corner of pixel 0,
`(width,height)` = bottom-right image corner; integer `+0.5` hits a pixel center.
Complex space: `re` right, `im` UP. Pixel-y and complex-im point OPPOSITE, so
`pixelToComplex` NEGATES the y term: smaller pixel-y ⇒ larger `im` (top of screen is
max imaginary). Flipping this mirrors the set vertically and every downstream task
inherits the bug — pinned by the orientation and corner tests, and by render.zig's
symmetry test.

## M7 precision seam

`center_re`/`center_im` are `f64` today — a deliberate defer (see the plan). Arbitrary
precision is only needed near ~1e-15 magnification (M7). The center type is isolated in
`Viewport` so M7 can widen it without touching callers; do not reach around the API to
do precision-sensitive math on the raw `f64` center.

## Tests

In-file `test "..."` blocks with `std.testing`, one intent each. Assert coordinate
orientation explicitly. `expectApproxEqAbs` with tight tolerance for f64 mapping.
