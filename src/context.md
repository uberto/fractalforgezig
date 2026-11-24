<!-- LLM-only context for src/. Keep under 500 words. -->

# src/ context

- Use `main.zig` for the SDL/ImGui loop, texture lifecycle and teardown. Render a coarse preview, then step a refinement band per frame with `engine.stepPass`. Keep navigation active during refinement.
- Record displayed scene metadata on successful texture uploads. At export dimension confirmation, capture against the current draw rectangle and the uploaded scene. Leave the native picker and progress presentation in `ui/export_panel.zig`. Keep SDL and ImGui calls on main.
- Keep `fractal/` independent of SDL and GPU. Use `gpu/` for SDL GPU uploads and Metal iteration. Use `c.zig` for translated SDL3 and backend bridge declarations and `cimgui.zig` for handwritten ImGui declarations.
- Register pure tests in `root.zig`. Preserve the acceptance tests in `deep_zoom_test.zig`, `gesture_test.zig` and `image_export_test.zig`.
- Scope `std.log` at the application and infrastructure edges. Include actionable failure context and propagate errors. Keep pure helpers testable without SDL or a device.

Store the center in `viewport.ComplexHi` (f128) and pixel offsets in f64. Use f64 direct iteration above the perturbation threshold and an f128 reference orbit with f64 deltas below it. Treat `viewport.precision_floor_side` as a warning and `navigate.max_view_side` as a clamp. See the fractal context for precision and export APIs.

Use Zig 0.15.2 with module-based build declarations. Run `zig fmt --check src build.zig`, `zig build test --summary all` and `zig build --summary all`. Run `zig build test-gpu` for the Metal tier alone. Read exit codes even when the runner prints success and check whether device-dependent tests skipped. Reserve `zig build run` and `zig build probe` for the user.
