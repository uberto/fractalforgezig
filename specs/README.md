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
| [rendering](rendering/spec.md) | Mandelbrot iteration, smooth escape values, the iteration/colour decoupling, the adaptive and pinned iteration counts, progressive refinement. |
| [navigation](navigation/spec.md) | Cursor-anchored zoom, centered zoom, pan, box-select, reset, refusal of impossible gestures, the zoom depth limit warning. |
| [view-coordinates](view-coordinates/spec.md) | The square view model, the centre/magnification and corner duals, pixel↔complex mapping, aspect-preserving display, the coordinate readout's precision. |
| [colouring](colouring/spec.md) | The gradient stop model, stop editing, the three iteration→gradient mapping modes, the interior colour, opaque output. |
| [gpu-acceleration](gpu-acceleration/spec.md) | GPU iteration agreeing with the CPU, banded dispatch, CPU fallback on GPU failure, the user's backend choice. |
| [persistence](persistence/spec.md) | Saving and reopening the complete render state as a `.fractal` JSON file, and refusing a corrupt one. |
| [app-shell](app-shell/spec.md) | The window and its two-region layout, the status bar, progress reporting, render statistics, the file dialogs, startup and failure logging. |

## Provenance

This spec was written **retroactively** at the start of milestone `m6-deep-zoom` from the
behavior that milestones M0–M5 actually shipped, established by reading the code and its tests.
It therefore lags rather than leads the code where the two could differ, and it deliberately
omits anything the code does not do. Scenarios marked `_not pinned by a test_` describe shipped
behavior that only a manual smoke run verifies today (the ImGui and file-dialog glue tiers, which
carry no unit tests by design — see `src/ui/context.md`).

## Verification

- `zig build test` — the fast pure tier; runs every test cited from `src/fractal/**`,
  `src/gpu/message.zig`, `src/ui/stats.zig`, `src/ui/editor.zig` and `src/root.zig`.
- `zig build test-gpu` — the GPU tier; runs every test cited from `src/gpu_headless_test.zig`.
- `zig build run` — the manual smoke run the unpinned scenarios rely on.
