<!-- LLM-only context for src/fractal/. Keep under 500 words. -->

# src/fractal/ context

Keep the core independent of SDL and GPU types. Register pure modules in
`src/root.zig`. Return typed errors and use `engine.zig` to log render failures.
Keep iteration separate from colouring. Reuse the `[]f32` iteration buffer on
palette edits and rerun only `colorpass.colorInto` with the baked gradient LUT
and mapping parameters.

## Geometry and iteration

Store the view centre as f128 and side as f64 in `viewport.SquareView`.
Use `rectViewport` for render geometry and `fitImageRect` for display and cursor
mapping. Sample pixel centres. Window y increases down, imaginary y up.
Use `navigate` for view transforms and `autoiter.IterPolicy` for iteration limits.

Use `mandelbrot.iterate` for direct iteration and `iterateJulia` for fixed-parameter
Julia iteration. Share `smoothEscapeValue` and use `interior_sentinel` for bounded
pixels. Reserve `iterateExact` for test comparisons. Use `orbit.compute` for the
orbit inspector.

## Deep rendering

Use `Engine.usesDeepPath` for the depth decision (side ≤ 1e-6).
Compute the centre orbit once per render with `perturb.ReferenceOrbit.compute`
in f128 and store its samples in f64. Run CPU pixel deltas in f64.
Use `perturb.iterateDelta` for plain perturbation. Rebase on orbit exhaustion
or when the combined point is smaller than the delta.

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
`Snapshot.viewport` for diagonal-preserving geometry. Reuse a `BandRenderer`
across sequential output bands. Keep cancellation and typed errors available
through the pure API. Publish progress and log at the file or application edge.
