<!-- LLM-only context for src/fractal/. Keep under 500 words. -->

# src/fractal/ context

Keep the core independent of SDL and GPU. Register tests in `src/root.zig`.
Return typed errors and log render failures in `engine.zig`. On palette edits,
reuse the `[]f32` iteration buffer and rerun `colorpass.colorInto`.

## Geometry and iteration

Store the view centre as f128 and side as f64 in `viewport.SquareView`.
Use `rectViewport` for render geometry and `fitImageRect` for display and cursor
mapping. Sample pixel centres. Window y increases down, imaginary y up.
Use `navigate` for view transforms and `autoiter.IterPolicy` for iteration limits.

Use `mandelbrot.iterate` and `iterateJulia` for direct iteration. Share
`smoothEscapeValue` and mark bounded pixels with `interior_sentinel`. Reserve
`iterateExact` for tests. Use `orbit.compute` for the inspector.

## Deep rendering

Use `Engine.usesDeepPath` for the depth decision (side ≤ 1e-6).
Compute the f128 centre orbit once with `perturb.ReferenceOrbit.compute`.
Store f64 samples and use f64 deltas in `perturb.iterateDelta`. Rebase on orbit
exhaustion or when the combined point is smaller than the delta.

With `Engine.use_bla`, build one `bla.BlaTable` for the orbit and largest sampled
parameter delta. Merge quadratic maps while bounding omitted terms and both
child domains. Skip when the delta envelope fits the block and certifies the
endpoint. Take exact steps when no skip qualifies. Use
`bla.iterateDeltaBlaCounted` to tally exact steps, rebases, skips, rejected
evaluations and replay. Compare the two counted deep band entry points in
`iterbuf.zig` at the same sample locations. Read `last_cpu_deep_steps` after the render.

Dispatch band-local output through `gpu_iter_fn` or `gpu_bla_iter_fn` with full
render dimensions. Borrow the orbit and table for the band and free them when
the render ends or is cancelled. Exceeding `bla.gpu_max_table_len` logs
`bla.gpuFallbackMessage` and uses CPU BLA. Check the GPU floor and orbit budget
through `gpuDeepFallbackReason`.

## Progressive render and files

Use `installView` and `installPolicy` to defer iteration. Start with
`beginPass`, render via `stepPass` or deterministic `stepPassRows`, and read
`passFraction`. Cancel on input changes. Let `refine.decidePass` choose coarse
or full work and preserve the cancellation latch.

Use `persist.fromEngine`, `toJson`, `fromJson` and `applyToEngine`; release owned
state via `freeState`. Write exact decimal-string centres and keep legacy numeric
centre decoding. Default an absent `use_bla` field to false. Use `scheme` for
colour-only files and `presets.all` for built-in colourings.

## Image export

Use `export_render.Snapshot` to carry rendered size, full-precision view, baked
LUT, mapping, interior color and resolved iteration limit by value. Use
`Snapshot.viewport` for diagonal-preserving geometry. Reuse `BandRenderer` across eight-row bands and reuse the reference orbit.
Preserve the resolved iteration cap and use CPU direct iteration or plain
perturbation as the output scale requires. Relay cancellation and typed errors
through the core. Log progress at the edge.
Encode RGBA input as opaque RGB with stored DEFLATE via `png.Encoder.init`, `writeRow` and
`finish`. Borrow the destination writer through finish and close it before
publication. Discard temporary output if encoding or writer flush fails.

Use `image_export.save` for directory-relative atomic output. Pass
`Control.overwrite_basename` only after approval. Pin `image_export.Worker` until
joined and supply the exact approved path separately. Read `poll` for progress
or terminal results. Call `cancel` before publication and `shutdown` at app exit.
