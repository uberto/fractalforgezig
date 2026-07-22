<!-- LLM-only context for src/fractal/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/fractal/ context

## Purpose

Pure fractal core: the math that turns a viewport into a colored Mandelbrot image.
NEVER `@cImport` or import SDL/GPU/`c.zig` here — this folder is the fast, isolated
test tier and must compile and run under `zig build test` with no window and no GPU
device. Keep every function pure: no allocation of hidden globals, no clock/random,
deterministic. Register each new module in `src/root.zig`'s aggregation `test` block
(`_ = @import("fractal/<mod>.zig");`) so its in-file tests run.

## Modules

- `viewport.zig` — shipped (T3). Maps pixels to the complex plane. Symbols:
  - `Viewport` struct: `center_re`, `center_im` (f64), `scale` (complex units per
    pixel, shared across both axes ⇒ square pixels, never stretched), `width`,
    `height` (u32).
  - `Viewport.fixedView(width, height) Viewport` — the fixed M0 view (plan: no
    navigation). Centers on the region midpoint and picks the smallest uniform
    `scale` that *contains* the whole fixed region (letterbox on the axis whose
    aspect exceeds the region's `3.5 : 2.5`).
  - `Viewport.pixelToComplex(px, py) Complex` — the mapping. `px`/`py` are f64
    continuous sample coordinates.
  - `Complex` struct: `{ re, im }`.
  - Fixed bounds as pub consts: `fixed_re_min/max` = `-2.5 / 1.0`,
    `fixed_im_min/max` = `-1.25 / 1.25`.
- `mandelbrot.zig` — T4 (iteration + smooth escape value). Not yet present.
- `color.zig` — T5 (smooth value → RGBA8 grayscale + interior). Not yet present.
- `render.zig` — T6 (full-image render to an RGBA buffer + golden test). Not yet.

## Coordinate convention (do not get this wrong)

Pixel space: origin TOP-LEFT, x right, y DOWN. `(0,0)` is the top-left corner of the
top-left pixel; `(width, height)` is the bottom-right image corner; integer `+0.5`
hits a pixel center. Complex space: `re` right, `im` UP. Pixel-y and complex-im point
in OPPOSITE directions, so `pixelToComplex` NEGATES the y term: smaller pixel-y ⇒
larger `im` (top of screen is the maximum imaginary part). Flipping this mirrors the
set vertically and every downstream task inherits the bug — it is pinned by the
"pixel-y grows downward while complex-im grows upward" and corner tests.

## M7 precision seam

`center_re`/`center_im` are `f64` today — a deliberate defer (see the milestone plan).
Arbitrary precision is only needed near ~1e-15 magnification (M7). The center type is
isolated in `Viewport` so M7 can widen it without touching callers; do not let callers
reach around the API to do precision-sensitive math on the raw `f64` center.

## Tests

In-file `test "..."` blocks with `std.testing`, one intent each. Assert the coordinate
orientation explicitly. Use `expectApproxEqAbs` with tight tolerance for f64 mapping.
