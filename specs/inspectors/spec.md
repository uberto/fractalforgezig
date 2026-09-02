<!-- Living spec for the `inspectors` capability. TRACKED and committed.
     Describes only behavior that is SHIPPED and PASSING. -->

# Capability: inspectors

## Purpose

The two live side windows the user opens to understand the point under the pointer: a **Julia
inspector** that renders, live, the Julia set for that point, and an **orbit inspector** that plots
the iterates of that point over a mini view of the whole Mandelbrot set. Both are read-only
previews floating over the main window; neither changes the main view, and neither is written to a
saved `.fractal` file — they are session-only.

The pure classification each window draws is unit-tested; the windows themselves, the pointer
tracking and the draw-list overlay are ImGui glue, verified by the manual smoke run and marked
unpinned, exactly like the neighbouring `app-shell` glue scenarios (see `src/ui/context.md`).

## Requirements

### Requirement: Live Julia inspector

The system SHALL show, in a dedicated window that the user can move and resize, the Julia set for
the complex point currently under the pointer on the main fractal — updating as the pointer moves
over the fractal, and holding the last point when the pointer leaves it.

#### Scenario: The Julia set for c = 0 is the filled unit disk

- **WHEN** the Julia set is classified for the parameter `c = 0`
- **THEN** a seed point inside the unit circle is reported as interior and a seed point outside it
  escapes — because the window iterates the seed point with `c` held fixed (the mirror of the
  Mandelbrot map), not the Mandelbrot recurrence
- **Test**: `src/fractal/mandelbrot.zig::acceptance: the Julia set for c=0 is the filled unit disk`

#### Scenario: A fast-escaping Julia point is never a non-number

- **WHEN** a seed point that escapes immediately is classified for a Julia parameter
- **THEN** the reported value is a finite number (or the interior sentinel), never NaN or infinity,
  so the preview is never painted from a non-number
- **Test**: `src/fractal/mandelbrot.zig::acceptance: a fast-escaping Julia point never returns NaN or Inf`

#### Scenario: The preview tracks the pointer and freezes when it leaves

- **WHEN** the pointer moves over the main fractal, then leaves it
- **THEN** the window shows the Julia set for the point under the pointer while it moves, and keeps
  the last one on display when the pointer is off the fractal rather than blanking
- **Test**: _not pinned by a test_ — manual smoke run (ImGui window + live render glue); the
  classification it draws is pinned by the two Julia tests above

### Requirement: Orbit inspector

The system SHALL show, in a dedicated window that the user can move and resize, the orbit of the
point under the pointer — the successive iterates from the origin — plotted over a mini view of the
whole Mandelbrot set, with an option to join the plotted points into a path.

#### Scenario: The orbit starts at the origin and its next point is c

- **WHEN** the orbit of a point `c` is computed
- **THEN** its first plotted point is the origin and its second is `c` itself, because the orbit is
  `z₀ = 0`, `z₁ = z₀² + c = c`, …
- **Test**: `src/fractal/orbit.zig::acceptance: the orbit starts at the origin and its next point is c`

#### Scenario: An escaping point ends its orbit; an interior point fills to the cap

- **WHEN** the orbit of an escaping point and the orbit of a non-escaping point are each computed
  with an iteration cap
- **THEN** the escaping orbit ends early and is marked escaped, while the non-escaping orbit fills
  to the cap and is marked not escaped
- **Test**: `src/fractal/orbit.zig::acceptance: an escaping point ends its orbit at escape, an interior point fills to the cap`

#### Scenario: The plotted points can be joined into a path

- **WHEN** the user turns on the connect-points option
- **THEN** the successive orbit points are joined by line segments over the mini-Mandelbrot instead
  of drawn as separate dots
- **Test**: _not pinned by a test_ — manual smoke run (ImGui draw-list overlay glue)

## Notes

- The inspectors are shallow f64 only: fixed modest `max_iter`, fixed z-plane views, no deep-zoom
  or high-precision path — those belong to `deep-zoom`, and the main view they observe stays
  Mandelbrot (this is not a "Julia set mode").
- The Julia preview reuses the colour LUT and mapping already driving the main image, so it tracks
  the user's chosen palette; recolouring is `colouring`'s concern.
- Which windows are open and where they sit is session-only state, deliberately not part of
  `persistence`'s saved picture.
- The View menu that shows and hides these windows, and the full-screen mode, are specified in
  `app-shell`.
