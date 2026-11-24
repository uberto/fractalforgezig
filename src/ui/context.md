<!-- LLM-only context for src/ui/. Keep under 500 words. -->

# src/ui/ context

Keep SDL and ImGui types behind `../c.zig` and `../cimgui.zig`. Use `panels.draw` to return requests via `DrawResult` and apply them in main. Derive full-resolution targets from the fractal region and map pointer coordinates via the fitted `image_rect`. Keep scrollbars disabled to prevent resize oscillation. Use `engine.renderViewport().pixelIndex` for status lookup.

Freeze the data panel during refinement. Keep navigation and status controls enabled. Send palette edits through `applyEdits` and defer the upload. Reapply color without iteration. Bake preset swatches once. Let `editor.Editor` drive gradient and mapping changes and `stats.renderSummary` summarize timing. Bind BLA to `engine.use_bla` and disable the control outside the deep path.

Use separate top-level windows for the Julia and orbit inspectors. Freeze the Julia image when the pointer leaves. Reuse the orbit backdrop until resize or recoloring. Defer texture uploads.

Accumulate wheel and pinch input in `gesture.zig` and drain one intent per frame. Preserve cursor-anchored zoom and one history entry per gesture. Install camera or policy changes through the coarse path and defer refinement through `refine.decidePass`. Latch explicit cancellation via `requestCancel` until a new view or manual Render re-arms the pass.

Keep f128 editable text round-trippable in `editor.ViewEditor`. Use scientific notation when a decimal cannot round-trip. Budget digits only for the read-only readout. Show the resolved iteration count under Auto and pin it via `leaveAuto`. Return changes through `CoordRequest` and resync on parse failure.

## PNG export

Keep native filters and callbacks in `dialog.zig`. Use the process-lifetime `export_flow.Picker` mailbox to copy paths and publish terminal picker states across threads. Keep `export_panel.Panel` on main. Carry one `Capture` across dimension confirmation, picker and any exact-path overwrite confirmation. Use the fresh fitted rect for defaults and `Displayed.scene` for the rendered geometry and colouring. Only replace displayed metadata after a successful upload. Defer capture during mixed-framing seeded refinement.

Pass the snapshot and final path to `image_export.Worker` and poll on main. Use `export_flow.waitMs` to keep an idle window responsive to export and picker changes. Surface terminal status with the export stage and actionable text. Keep pure transition tests in `export_flow.zig` and reserve the GUI checks for the user.
