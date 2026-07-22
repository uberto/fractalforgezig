<!-- LLM-only context for src/. Imperative. Keep <= 500 words. Real shipped APIs only. -->

# src/ context

## Purpose

fractalforge renders a Mandelbrot set (CPU-computed in M0, GPU-uploaded as a texture) in a
native macOS window with a Dear ImGui shell. This folder holds all first-party Zig source.

## Layout map

- `main.zig` — executable entry. Logs the startup line via `std.log.scoped(.app)` and exits.
  Keep it thin: wire modules together, push logic into pure modules.
- `root.zig` — library/test root. `zig build test` compiles this file. Its top-level
  `test { ... }` block aggregates submodule tests via `_ = @import("...");` as they land.
  Also hosts small pure helpers (e.g. `startupLine`).
- `fractal/` — pure fractal core (viewport mapping, Mandelbrot iteration, color, render).
  No SDL/GPU imports. Seeded in T3.
- `gpu/` — SDL3 GPU device + RGBA→texture upload glue. Seeded in T2.
- `ui/` — SDL3 window + cimgui/Dear ImGui shell (menu bar, image panel, debug panel).
  Seeded in T2.

## Pure-vs-glue rule

Pure logic (math, string building, buffers) must be unit-testable with **no window and no
GPU device**. Keep framework/SDL/GPU imports at the edges (`gpu/`, `ui/`, `main.zig`). When a
new pure module lands, import it into `root.zig`'s aggregation `test` block so its tests run.

## Observability

Use `std.log` with a scope per module: `.app`, `.fractal`, `.gpu`, `.ui`. On failure log
`std.log.err` with actionable context (what failed + the SDL error string) and return a Zig
error — never `unreachable` or a swallowed error. Build log/summary strings with pure
functions so they can be unit-tested (see `startupLine`).

## Commands

- `zig build` — compile the executable (installs to `zig-out/`).
- `zig build run` — build then run (M0 skeleton: logs startup line, exits 0).
- `zig build test` — run the fast unit-test tier (`src/root.zig`; no window, no GPU).
- `zig fmt --check .` — formatting gate; must be clean.

## Zig version

Pinned to **Zig 0.15.2**. Use the module-based build API: `addExecutable`/`addTest` take a
`root_module` built with `b.createModule(.{ .root_source_file, .target, .optimize })`.
