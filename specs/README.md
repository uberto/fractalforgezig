<!-- Living spec index. TRACKED and committed. One line per capability.
     Describes only behavior that is SHIPPED and PASSING. Updated at the end of each
     milestone by its D1 task. See ~/.claude/skills/inception/references/spec-layer.md. -->

# fractalforge — living spec

What fractalforge promises its user, capability by capability. Each file states requirements as
normative `SHALL` sentences about **observable behavior**, each with concrete `WHEN`/`THEN`
scenarios and a pointer to the test that pins it. Implementation detail belongs in the in-source
`context.md` files (`src/context.md`, `src/fractal/context.md`, `src/gpu/context.md`,
`src/ui/context.md`), never here.

## Capabilities

| capability | what it covers |
|---|---|
| [rendering](rendering/spec.md) | Mandelbrot iteration, smooth escape values, the iteration/colour decoupling, the adaptive and pinned iteration counts, the always-visible iteration count, progressive refinement. |
| [navigation](navigation/spec.md) | Cursor-anchored zoom, centered zoom, pan, box-select, reset, trackpad pinch zoom and two-finger pan, the per-frame gesture coalescing, the pointing-device wheel discriminator, refusal of impossible gestures, the zoom depth limit warning, the maximum zoom-out clamp. |
| [deep-zoom](deep-zoom/spec.md) | Perturbation rendering below the double-precision floor down to a side of 1e-30, accuracy against full-precision iteration, GPU deep zoom with logged CPU fallback, 34-digit view coordinates, precision-preserving navigation at depth. |
| [view-coordinates](view-coordinates/spec.md) | The square view model, the centre/magnification and corner duals, pixel↔complex mapping, aspect-preserving display, the coordinate readout's precision. |
| [colouring](colouring/spec.md) | The gradient stop model, stop editing, the three iteration→gradient mapping modes, banded vs smooth colouring, the interior colour, opaque output, portable colour-scheme files, and the built-in presets. |
| [gpu-acceleration](gpu-acceleration/spec.md) | GPU iteration agreeing with the CPU, banded dispatch, CPU fallback on GPU failure, the user's backend choice. |
| [persistence](persistence/spec.md) | Saving and reopening the complete render state as a `.fractal` JSON file, and refusing a corrupt one. |
| [app-shell](app-shell/spec.md) | The window and its two-region layout, the status bar, progress reporting, stopping and restarting a render in progress, render statistics, the file dialogs, startup and failure logging. |

## Provenance

This spec was written **retroactively** at the start of milestone `m6-deep-zoom` from the
behavior that milestones M0–M5 actually shipped, established by reading the code and its tests.
It therefore lags rather than leads the code where the two could differ, and it deliberately
omits anything the code does not do. Scenarios marked `_not pinned by a test_` describe shipped
behavior that only a manual smoke run verifies today (the ImGui and file-dialog glue tiers, which
carry no unit tests by design — see `src/ui/context.md`).

Milestone `m6-deep-zoom` then added the `deep-zoom` capability and rewrote the three requirements
it changed: `persistence`'s **Saved view fidelity** (the centre is now a decimal string),
`navigation`'s **Zoom depth limit** (the floor moved seventeen decades deeper, to 1e-30) and
`rendering`'s **Adaptive iteration count** (the ceiling rose with it, to 65536).

Milestone `m7-trackpad-gestures` added four `navigation` requirements — **Trackpad pinch zoom**,
**Trackpad two-finger pan**, **One view change per frame per gesture** and **The pointing device
decides what the wheel does** — and one `rendering` requirement, **Visible iteration count**. It
rewrote nothing: the mouse wheel's behaviour is unchanged, so pinch and swipe are additions. Two
folded parts are `_not pinned by a test_`: the two-finger swipe's direction and pixel scale (the
platform-reported values were never measured — the probe was not run — so they ship provisional and
are on the user's walkthrough checklist), and the event loop's per-gesture history push (glue with
no test tier). The pure logic behind every requirement is test-pinned.

Milestone `m8-coloring-schemes` added four `colouring` requirements — **Banded or smooth iteration
colouring**, **Portable colouring schemes**, **Built-in colouring presets** and **Loading restores
the palette panel** — and rewrote `persistence`'s **The whole picture is saved** to carry the new
`banded` flag and to pin the two scenarios that shipped in M5 but were unpinned. The scheme
Save/Load buttons, the preset swatch gallery and the banded checkbox are ImGui glue whose active
state during a render is pilot-verified (see `rendering`'s panel-disabled note), not unit-tested; the
pure logic behind every new requirement is test-pinned.

Milestone `m9-cancel-render` added one `app-shell` requirement — **Stopping a render in progress** —
and rewrote `rendering`'s **Progressive refinement** to promise that a cancelled view is not refined
again on its own until the user restarts it or changes the view. The two pure decisions are
test-pinned (`refine.decidePass`'s cancel latch and `progressive.statusControl`); the Cancel/Render
buttons, the Escape shortcut and the click→`cancelPass` wiring are ImGui/SDL glue, pilot-verified on
the manual smoke run, exactly like the neighbouring app-shell glue scenarios.

## Verification

- `zig build test` — **both** tiers. The pure tier runs every test cited from `src/fractal/**`,
  `src/gpu/message.zig`, `src/ui/stats.zig`, `src/ui/editor.zig`, `src/root.zig` and
  `src/deep_zoom_test.zig`; it then runs the GPU tier below.
- `zig build test-gpu` — the GPU tier alone; runs every test cited from
  `src/gpu_headless_test.zig`. It needs a real Metal device and skips silently without one, so a
  skip must not be read as a pass.
- `zig build run` — the manual smoke run the unpinned scenarios rely on.
- Read each gate's exit code separately: a test that calls `std.log.err` makes the runner print
  success while exiting 1.
