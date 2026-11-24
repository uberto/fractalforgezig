<!-- LLM-only context for src/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/ context

## Purpose

Render Mandelbrot on CPU or Metal in a native macOS Dear ImGui window.

## Layout map

- `main.zig` — executable entry: one window, SDL_GPU device + ImGui, event loop, clean teardown.
  Show a coarse preview, then refine one self-timed band per frame with `engine.stepPass()`.
  Disable the data panel during refinement.
  Capture PNG dimensions with the current draw rectangle and metadata from the uploaded
  texture. `ui/export_panel.zig` owns the picker and progress. The worker owns its copied
  snapshot and path. Keep ImGui and SDL calls on main.
- `root.zig` — register pure tests and small pure helpers such as `startupLine`.
- `c.zig` — the `@cImport` C-interop edge: SDL3 + SDL_GPU + the ImGui backend bridge,
  translated once. Only `gpu/`, `ui/`, `main.zig` import it.
- `cimgui.zig` — hand-written `extern` decls for the Dear ImGui C API (bitfields defeat
  `@cImport`).
- `fractal/` — pure fractal core (viewport mapping, Mandelbrot iteration, perturbation, color,
  progressive chunk scheduling, JSON persistence). No SDL/GPU imports.
- `gpu/` — SDL3 GPU device, RGBA→texture upload, Metal compute iteration.
- `ui/` — SDL3 window + cimgui/Dear ImGui shell; pure `gesture.zig` reduces trackpad/wheel
  events to view changes.
- `deep_zoom_test.zig`, `gesture_test.zig` — the deep-zoom and trackpad-gesture acceptance tests;
  IMMUTABLE, never weaken one.

## Precision model

View coordinates are `f128` (`fractal/viewport.ComplexHi`); per-pixel offsets stay `f64`. Above
`perturb.threshold_side` (1e-6) pixels iterate directly; below it the engine builds ONE reference
orbit per render at the centre and iterates `f64` deltas against it (perturbation, Zhuoran
rebasing), CPU or GPU. `viewport.precision_floor_side` (1e-30) only WARNS; the wide end
(`navigate.max_view_side` 8.0) does CLAMP. Under `perturb.gpu_floor_side` (1e-20) the GPU hands bands back to the CPU. `autoiter`
ramps `max_iter` quadratically to 65536. Details: `fractal/context.md`.

## Pure-vs-glue rule

Pure logic must be unit-testable with **no window and no GPU device**: keep SDL/GPU imports at
the edges (`gpu/`, `ui/`, `main.zig`). Import each new pure module into `root.zig`'s `test`
block, or its tests never run.

## Observability

Scope `std.log` per module (`.app`, `.fractal`, `.gpu`, `.ui`). On failure: `std.log.err` with
actionable context (what failed + the SDL error string) and a returned Zig error — never
`unreachable`, never a swallowed error. Build log strings in pure, unit-tested functions (see
`startupLine`).

## Commands

- `zig build` — compile the app + probe; installs `zig-out/bin/fractalforge`.
- `zig build run` — run the app (USER ONLY).
- `zig build probe` — USER ONLY: a window logging wheel/pinch/finger events.
- `zig build test` — BOTH tiers: pure (`src/root.zig`) + C-linking GPU.
- `zig build test-gpu` — the GPU tier alone (`src/gpu_headless_test.zig`); it SKIPS with no
  Metal device, and a skip is not a pass.
- `zig fmt --check .` — must be clean.

Read each gate's exit code separately — `std.log.err` in a test prints success but exits 1.

## Zig version

Pinned to **Zig 0.15.2** with the module-based build API: `addExecutable`/`addTest` take a
`root_module` from `b.createModule(.{ .root_source_file, .target, .optimize })`.
