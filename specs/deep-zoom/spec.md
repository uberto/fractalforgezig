<!-- Living spec for the `deep-zoom` capability. TRACKED and committed.
     Describes only behavior that is SHIPPED and PASSING. -->

# Capability: deep-zoom

## Purpose

Let the user keep zooming long after double-precision pixel coordinates give up. Below a view side
of roughly 1e-13, iterating each pixel from its own double-precision coordinate collapses the image
into quantized blocks; this capability carries the view centre in extended precision, iterates one
reference orbit per render and computes each pixel as a small offset from it, so the picture keeps
resolving detail down to a side of 1e-30 — seventeen decades deeper. It also owns the promises that
come with that depth: that the deep image is as trustworthy as full-precision iteration, that the
GPU either matches the CPU or hands the work back, that the coordinates on screen carry enough
digits to write a location down and paste it back, and that a gesture at depth does not silently
round the centre to a double.

## Requirements

### Requirement: Deep-zoom rendering

The system SHALL render resolved fractal detail at any view side down to 1e-30, rather than the
quantized blocks that direct double-precision iteration produces below ~1e-13.

#### Scenario: Detail at the deepest supported zoom

- **WHEN** a view whose side is 1e-30, centered on a point of the set's boundary, is rendered
  with the iteration count the automatic policy chooses for that depth
- **THEN** the rendered smooth values vary across the image (the great majority of pixels carry
  values distinct from one another) instead of collapsing to a single constant value
- **Test**: `src/deep_zoom_test.zig::acceptance: a view at side 1e-30 renders varied detail`

#### Scenario: Below the supported floor the user is warned and the render still happens

- **WHEN** the view side is below 1e-30
- **THEN** the app reports a precision-floor warning naming the offending side and what to do
  about it, and still renders the view rather than refusing the navigation
- **Test**: `src/fractal/navigate.zig::acceptance: past the precision floor the view is still accepted and the warning is actionable`

### Requirement: Perturbation accuracy

The system SHALL compute deep views to an accuracy indistinguishable, in interior/exterior
classification, from iterating each pixel at full precision, so a deep image contains no glitch
artifacts.

#### Scenario: Accuracy where the shallow and deep paths meet

- **WHEN** a view at the depth where the renderer switches from direct to deep iteration
  (side 1e-6) is rendered by the deep path
- **THEN** every pixel's smooth value is within 1.0 iteration of the same pixel computed by
  full-precision direct iteration, and the interior/exterior classification matches exactly
- **Test**: `src/deep_zoom_test.zig::acceptance: at the switch threshold the deep path matches full precision`

#### Scenario: Accuracy at extreme depth

- **WHEN** a view at side 1e-25 is rendered by the deep path
- **THEN** the interior/exterior classification of every pixel matches full-precision direct
  iteration of the same pixel, and the mean absolute difference in smooth value across the
  sampled image is under 5.0 iterations
- **Test**: `src/deep_zoom_test.zig::acceptance: at 1e-25 the deep path matches full-precision classification`

### Requirement: GPU deep zoom

The system SHALL render deep views on the GPU wherever the GPU can deliver the required
precision, and SHALL fall back to the CPU with a logged warning naming the reason wherever it
cannot, so a deep view always renders.

#### Scenario: GPU agrees with the CPU at depth

- **WHEN** a view at side 1e-20 is rendered on the GPU and on the CPU
- **THEN** the two images agree: the same interior/exterior classification for all but a
  negligible number of pixels sitting exactly on the escape boundary, and smooth values within
  1% of the iteration count wherever both escape
- **Test**: `src/gpu_headless_test.zig::compute: GPU deep zoom at 1e-20 matches the CPU deep path`

#### Scenario: Past the GPU's precision floor the CPU takes over

- **WHEN** a view is deeper than the GPU path supports, or needs a reference orbit larger than
  the GPU orbit budget
- **THEN** the render is completed by the CPU path, a warning is logged naming which limit was
  hit, and the resulting image is the CPU image
- **Test**: `src/deep_zoom_test.zig::acceptance: past the GPU floor the engine renders on the CPU`
- **Test**: `src/fractal/engine.zig::an orbit longer than the GPU budget keeps the render on the CPU`
- **Test**: `src/fractal/perturb.zig::gpuFallbackMessage names the GPU precision floor and says the CPU finished`

### Requirement: Full-precision view coordinates

The system SHALL display and accept view centers to the precision the current depth needs, up to
34 significant decimals, so a deep location can be read off, written down, and pasted back.

#### Scenario: A 34-digit center survives a round trip

- **WHEN** a center given to 30 decimals is set as the view center and then read back
- **THEN** every one of those decimals is preserved exactly
- **Test**: `src/deep_zoom_test.zig::acceptance: a 30-decimal center round-trips through the view`

#### Scenario: The coordinate readout lengthens with depth

- **WHEN** the view is zoomed deeper
- **THEN** the coordinate readout shows more decimals, up to 34, so the digits that distinguish
  neighbouring pixels are always visible
- **Test**: `src/fractal/viewport.zig::acceptance: coordinate digits grow with depth up to 34`

### Requirement: Deep navigation keeps its precision

The system SHALL preserve the full precision of the view center through zoom, pan and
box-select gestures, so navigation at depth does not silently snap back to double precision.

#### Scenario: Zooming at a cursor anchor at depth

- **WHEN** the view is at side 1e-25 and the user zooms in on a point away from the image center
- **THEN** the resulting center still carries its full-precision decimals (it differs from the
  double-precision rounding of itself) and the zoom is anchored on the chosen point
- **Test**: `src/deep_zoom_test.zig::acceptance: a cursor-anchored zoom at 1e-25 keeps full precision`
- **Test**: `src/fractal/navigate.zig::zoomAbout at depth still pins the anchor to its pixel`

## Notes

- The switch between direct and deep iteration, the reference orbit's lifetime, the GPU's own
  precision floor and orbit budget, and the extended-precision centre type are implementation:
  see `src/fractal/context.md` and `src/gpu/context.md`.
- The iteration count a deep view is rendered with comes from `rendering`'s **Adaptive iteration
  count**; the depth at which the warning of **Deep-zoom rendering** fires is the same one
  `navigation`'s **Zoom depth limit** names. Saving a deep centre is `persistence`'s **Saved view
  fidelity**; the readout's digit budget is `view-coordinates`' **Coordinate readout precision**.
- **How the GPU agreement scenario is quantified.** "Negligible" and "within 1%" are pinned by the
  test as: at most 16 of 256 sampled pixels outside tolerance, and a mean absolute difference under
  60 iterations, at 1e-20 with `max_iter` 20000 (user-approved amendment, 2026-08-14). The GPU
  carries its per-pixel offsets as 32-bit floats, so the residual is input quantization, not a
  different algorithm.
- **What is pinned less tightly than the requirement reads.** The "still renders" half of *Below the
  supported floor* is pinned only as far as the navigation being accepted and the warning being
  actionable; no test renders an image below 1e-30. *Deep navigation keeps its precision* names pan
  and box-select, which carry no approved scenario of their own; they are pinned at unit tier by
  `src/fractal/navigate.zig::panByPixels at depth shifts the center by the documented one-pixel distance`
  and `src/fractal/navigate.zig::boxSelect keeps a deep selection's two corners apart instead of collapsing them`.
- **Ground truth caveat.** The full-precision comparison the accuracy scenarios use is
  `mandelbrot.iterateExact`, which is itself only trustworthy to about 1e-20: below that its own
  drift exceeds the deep path's. The accuracy budgets at 1e-25 are therefore dominated by oracle
  error, not by product error.
