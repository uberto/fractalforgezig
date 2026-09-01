<!-- Living spec for the `rendering` capability. TRACKED and committed.
     Describes only behavior that is SHIPPED and PASSING. -->

# Capability: rendering

## Purpose

Turn the region of the complex plane the user is looking at into an image of the Mandelbrot set.
This capability owns how a pixel is classified (does its point escape, and how quickly), how many
iterations that classification is allowed, and how the image reaches the screen without ever
freezing the app. It deliberately does **not** own which colours the result is painted in — that
is `colouring` — and the separation between the two is itself a requirement here.

## Requirements

### Requirement: Escape-time classification

The system SHALL classify every pixel by iterating the Mandelbrot recurrence from its complex
point and reporting either how quickly the point escaped or that it never escaped within the
current iteration limit.

#### Scenario: A point inside the set never escapes

- **WHEN** a point well inside the set's main body is iterated
- **THEN** it is reported as interior, distinguishably from every escaped value
- **Test**: `src/fractal/mandelbrot.zig::a point inside the main cardioid returns the interior sentinel`

#### Scenario: A point just outside the boundary escapes

- **WHEN** a point just outside the set's boundary is iterated
- **THEN** it is reported as escaped, so the boundary is visible rather than smeared into the
  interior
- **Test**: `src/fractal/mandelbrot.zig::a point just outside the cardioid cusp escapes — boundary is distinguishable`

#### Scenario: The escape value is continuous, not a step count

- **WHEN** an escaping point is iterated
- **THEN** its reported value is fractional, so the image can be shaded smoothly instead of in
  integer bands
- **Test**: `src/fractal/mandelbrot.zig::the smooth value is fractional, not an integer count`

#### Scenario: No pixel is ever reported as a non-number

- **WHEN** points that escape immediately, including far outside the set, are iterated
- **THEN** every reported value is a finite number, never NaN or infinity
- **Test**: `src/fractal/mandelbrot.zig::fast-escaping points never return NaN or Inf`

### Requirement: Reproducible image

The system SHALL produce the identical image for the same view, image size and settings,
regardless of how the work was scheduled or split.

#### Scenario: The same view rendered twice is identical

- **WHEN** the same view is iterated twice at the same size and iteration limit
- **THEN** the two results are identical value for value
- **Test**: `src/fractal/iterbuf.zig::iterateInto is deterministic: two runs produce scalar-identical buffers`

#### Scenario: Splitting the image into row bands changes nothing

- **WHEN** an image is iterated as a sequence of row bands instead of in one pass
- **THEN** the composed result equals the one-pass result exactly
- **Test**: `src/fractal/iterbuf.zig::iterateRowsInto in bands reproduces the whole-image pass exactly`

### Requirement: Colour edits never re-iterate

The system SHALL repaint the current image without recomputing the fractal when only the palette,
the mapping mode or the interior colour change, so palette work stays instant however expensive
the view was to compute.

#### Scenario: A palette edit repaints only

- **WHEN** the gradient is changed after an image has been rendered
- **THEN** the image is repainted and the fractal is not iterated again
- **Test**: `src/fractal/engine.zig::THE GUARANTEE: setGradient bumps color_passes but leaves iteration_passes unchanged`

#### Scenario: A mapping-mode change repaints only

- **WHEN** the iteration→gradient mapping mode is changed after an image has been rendered
- **THEN** the image is repainted and the fractal is not iterated again
- **Test**: `src/fractal/engine.zig::THE GUARANTEE: setMapping bumps color_passes but leaves iteration_passes unchanged`

#### Scenario: A palette edit during a render repaints only

- **WHEN** the palette is edited while a full-resolution refinement is still in flight
- **THEN** the partly refined image is repainted and no pixel is iterated again
- **Test**: `src/fractal/engine.zig::THE GUARANTEE mid-pass: a palette edit during a pass recolors without re-iterating`

#### Scenario: The guarantee holds when the GPU did the iteration

- **WHEN** the palette is edited after an image was iterated on the GPU
- **THEN** the image is repainted without a second GPU dispatch
- **Test**: `src/fractal/engine.zig::THE GUARANTEE holds with GPU path: setGradient after GPU iterate does not re-iterate`

### Requirement: Adaptive iteration count

The system SHALL raise the iteration count automatically as the view is magnified, from 512 at the
home view up to a ceiling of 65536 reached at the deepest resolvable zoom.

#### Scenario: The home view keeps its baseline count

- **WHEN** the automatic policy is asked for the iteration count at the home view
- **THEN** it yields 512
- **Test**: `src/fractal/autoiter.zig::autoMaxIter returns the M0 baseline at the default view's magnification`

#### Scenario: Zooming in never lowers the count

- **WHEN** the automatic policy is sampled across a sweep of increasing magnifications
- **THEN** the count never decreases from one sample to the next
- **Test**: `src/fractal/autoiter.zig::autoMaxIter never decreases across a fine magnification sweep`

#### Scenario: Zooming out never renders coarser than the home view

- **WHEN** the automatic policy is asked for the count at or below the home view's magnification
- **THEN** it yields the baseline 512 rather than anything smaller
- **Test**: `src/fractal/autoiter.zig::autoMaxIter clamps to the baseline at or below the default magnification`

#### Scenario: The ramp spans the whole usable zoom range

- **WHEN** the automatic policy is asked for the iteration count at the home view, and at the
  deepest supported side
- **THEN** it yields 512 at the home view and 65536 at the floor, and never decreases as
  magnification grows
- **Test**: `src/fractal/autoiter.zig::acceptance: the auto ramp spans home to the precision floor`
- **Test**: `src/fractal/autoiter.zig::the ramp spans the whole usable zoom range, capping at the precision floor`

### Requirement: Pinned iteration count

The system SHALL let the user pin the iteration count by hand, use that value at any
magnification, and refuse a value outside the supported range with a message naming the value,
the range and the ways out.

#### Scenario: A pinned count overrides the automatic ramp

- **WHEN** a count is pinned and the view is at an arbitrary magnification
- **THEN** the pinned count is used rather than the ramp's
- **Test**: `src/fractal/autoiter.zig::a manual policy returns the pinned value regardless of magnification`

#### Scenario: A pinned count may go far past the automatic ceiling

- **WHEN** a count in the millions is pinned
- **THEN** it is accepted rather than clamped down to the automatic ramp's ceiling
- **Test**: `src/fractal/autoiter.zig::a manual value in the millions is accepted, not clamped to the auto ramp's ceiling`

#### Scenario: An out-of-range count is refused, not silently accepted

- **WHEN** a count above the supported range is pinned
- **THEN** the request is refused
- **Test**: `src/fractal/autoiter.zig::manual rejects a value above the supported range`

#### Scenario: The refusal says what to do about it

- **WHEN** a pinned count is refused
- **THEN** the message names the offending value, the supported range, and both ways out
- **Test**: `src/fractal/autoiter.zig::maxIterRangeMessage names the offending value, the range and what to do`

#### Scenario: Leaving the automatic choice pins the displayed count

- **WHEN** the user turns the automatic choice off
- **THEN** the count is pinned to the value that was on display, so the user edits on from what the
  ramp had chosen rather than from a stale earlier value — the shared promise with **Visible
  iteration count**'s *Turning automatic off pins what was on display*
- **Test**: `src/ui/editor.zig::acceptance: leaving auto pins the count that was on display`

### Requirement: Visible iteration count

The system SHALL always show the iteration count the image was computed with; while the count is
chosen automatically it SHALL be shown read-only, and turning the automatic choice off SHALL pin
the value being shown so the user edits on from it.

#### Scenario: The automatic count is shown, not the last pinned one

- **WHEN** the count is chosen automatically at a magnification whose ramp value differs from the
  last value the user pinned
- **THEN** the count on display is the one the ramp chose
- **Test**: `src/ui/editor.zig::acceptance: the auto policy displays the ramp's count, not the last pinned one`

#### Scenario: The shown count is not editable while it is automatic

- **WHEN** the count is chosen automatically
- **THEN** the count is displayed read-only
- **Test**: `src/ui/editor.zig::acceptance: the iteration count is read-only while the policy is automatic`

#### Scenario: Turning automatic off pins what was on display

- **WHEN** the user turns the automatic choice off
- **THEN** the count is pinned to the value that was being displayed, and becomes editable
- **Test**: `src/ui/editor.zig::acceptance: leaving auto pins the count that was on display`

### Requirement: Progressive refinement

The system SHALL answer every view change with an immediate coarse image and then refine it to
full resolution in self-timed chunks while reporting progress, so the app is never unresponsive
and the final image is the one a single full-resolution pass would have produced.

#### Scenario: A settled view is promoted to full resolution

- **WHEN** the user stops interacting, the idle threshold passes, and no full-resolution pass has
  completed for the current view
- **THEN** a full-resolution pass is started
- **Test**: `src/fractal/refine.zig::decidePass: idle past threshold and full not done returns full`

#### Scenario: An interaction in progress keeps showing the coarse image

- **WHEN** the user is mid-gesture
- **THEN** the coarse image is what is shown, and no full-resolution pass is started
- **Test**: `src/fractal/refine.zig::decidePass: interacting always returns coarse`

#### Scenario: A chunked refinement equals a one-shot render

- **WHEN** a view is refined in chunks to completion
- **THEN** the resulting image is identical to the same view rendered in one pass
- **Test**: `src/fractal/engine.zig::a progressive pass in chunks produces the same buffer as the one-shot iterate`

#### Scenario: Progress is reported while refining

- **WHEN** a refinement is part-way through
- **THEN** the completed fraction is reported, and renders as a percentage the user can read
- **Test**: `src/fractal/engine.zig::passFraction reports the completed row ratio mid-pass`
- **Test**: `src/fractal/progressive.zig::progressLabel renders the completion percentage`

#### Scenario: A refinement abandoned mid-way leaves what it had

- **WHEN** a new input arrives and the in-flight refinement is cancelled
- **THEN** the partly refined image stays on display instead of reverting or blanking
- **Test**: `src/fractal/engine.zig::cancelPass abandons the pass, leaving the partly refined image on display`

#### Scenario: Chunk size adapts to what the machine can do

- **WHEN** a chunk takes longer than the repaint budget allows
- **THEN** the next chunk is smaller, never smaller than a single row
- **Test**: `src/fractal/progressive.zig::adaptChunkRows shrinks the chunk when the measured chunk overran the budget`
- **Test**: `src/fractal/progressive.zig::adaptChunkRows never shrinks below one row`

### Requirement: Unrenderable requests are refused, not rendered

The system SHALL refuse a view or image size it cannot render, keep displaying what it already
had, and stay usable.

#### Scenario: A degenerate view is refused and the old image stays

- **WHEN** a view with no finite positive extent is installed
- **THEN** the request is refused, the previous view is kept, and nothing is re-iterated
- **Test**: `src/fractal/engine.zig::a degenerate view is rejected: the engine keeps its view and does not re-iterate`

#### Scenario: A zero-pixel image size is refused and the app stays renderable

- **WHEN** the image is resized to zero pixels
- **THEN** the resize is refused and the app can still render
- **Test**: `src/fractal/engine.zig::resize(0) returns DegenerateImageSide and leaves the engine renderable`

#### Scenario: A render that cannot be allocated keeps the previous image

- **WHEN** the memory for a larger image cannot be obtained
- **THEN** the previous image's buffers are intact and nothing is leaked
- **Test**: `src/fractal/engine.zig::a resize whose smooth-buffer allocation fails keeps the previous buffers`
- **Test**: `src/fractal/engine.zig::a resize whose RGBA allocation fails frees the smooth buffer it already took`

## Notes

- The iteration limit chosen for a view is shown to the user by `app-shell`; the depth at which
  the automatic ramp tops out is the same depth `navigation`'s **Zoom depth limit** warns about.
- **Visible iteration count** and **Pinned iteration count** share one promise: unchecking Auto pins
  the value that was on display. Its logic is pinned by the three `src/ui/editor.zig` acceptance
  tests, which drive the pure editor state; that the data panel renders the field read-only while
  Auto is on and refreshes it each frame is ImGui glue and only a manual smoke run verifies it.
- Whether iteration runs on the CPU or the GPU is `gpu-acceleration`'s concern; both backends
  satisfy **Reproducible image** and **Colour edits never re-iterate**.
- How a view below ~1e-13 gets any detail to iterate at all is `deep-zoom`'s concern; the ramp's
  ceiling is calibrated to that capability's 1e-30 floor. A deep pass is expensive: at the app's
  window size a 1e-30 view takes minutes of chunks, and the auto ramp deliberately overshoots the
  minimum count a depth needs.
- **What "never unresponsive" covers, and what it does not.** During a pass the image, the progress
  bar and the wheel (which cancels and re-arms) stay live, but the whole data panel is disabled
  until the pass finishes or is cancelled. So at deep depths a palette edit cannot be *made*
  through the UI while a pass runs: **Colour edits never re-iterate** is a promise about what the
  engine does when such an edit arrives, and it is pinned at engine level, not through the panel.
