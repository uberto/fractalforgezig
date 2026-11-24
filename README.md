# Fractal Forge

Fractal Forge is a Mandelbrot explorer for Apple Silicon macOS. It uses SDL3 and Dear ImGui for the interface, with CPU and Metal rendering.

## Build and run

Use Zig 0.15.2 and install SDL3 with Homebrew. The build looks for SDL3 under `/opt/homebrew`. Dear ImGui is vendored, and SDL compiles the embedded Metal shaders at runtime.

```sh
brew install sdl3
zig build
zig build run
```

Run `zig build test` for the full suite or `zig build test-gpu --summary all` for the headless Metal suite. Device-dependent tests skip when a Metal device is unavailable. See the [feature specifications](specs/README.md) for behavior and acceptance tests.

## Deep-zoom acceleration

Use **BLA** next to **GPU** in the Data panel to enable Bivariate Linear Approximation. At a view side of `1e-6` or smaller, toggling BLA starts a new render. At wider views the control is disabled and shows a deep-zoom hint. Saved `.fractal` pictures retain the setting. Pictures saved before BLA load with it off.

At a side of `1e-25` and an iteration cap of 65,536, a 64 × 64 CPU test tile took 8,057,246 iteration steps with BLA and 66,774,868 with plain perturbation, an 8.29× reduction in steps. Every pixel kept the same interior or exterior classification, and exterior smooth values were within one iteration. Runtime depends on the view and includes work outside the counted iteration steps.

The headless suite ran on Metal and passed all 524 tests. It verified that the accelerated shader completes iterations using skips and that a `1e-20` exterior tile agrees with CPU BLA within 0.01 iteration after skips without replay. Eligible GPU renders may replay individual pixels through plain GPU perturbation when a skip cannot resolve their result. Below the Metal precision floor of `1e-20` or above the 262,144-block GPU table limit, rendering falls back to the CPU.

## Manual GUI checks

The GUI checks are pending.

1. Launch with `zig build run`. In a shallow view, check that BLA is disabled and the deep-zoom hint is visible.
2. Set the view side to `1e-6` or smaller. Toggle BLA and verify that each change starts a render and the completed images agree.
3. Save a deep view with BLA enabled and reopen it. Check that BLA remains enabled. Open a picture saved before BLA and check that it loads with BLA off.
4. To check the GPU table limit, use center `-0.1 + 0i`, side `1e-20`, and a manual cap of 262,145. Enable GPU and BLA. Check that the render completes and the log reports that the CPU handled the oversized table.
