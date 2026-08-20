<!-- Living spec for the `navigation` capability. TRACKED and committed.
     Describes only behavior that is SHIPPED and PASSING. -->

# Capability: navigation

## Purpose

Let the user move around the Mandelbrot set: zoom towards what they are pointing at, drag the
plane about, rubber-band a region to fill the image, and get home again. Every gesture is a
promise about where the picture ends up relative to where the user aimed — a zoom that drifts off
the point under the cursor is a bug, not a rounding detail. This capability also owns telling the
user when they have zoomed past the depth the app can still resolve.

## Requirements

### Requirement: Cursor-anchored zoom

The system SHALL keep the point under the cursor fixed on screen while zooming with the scroll
wheel, so the user zooms towards what they are looking at rather than towards the image centre.

#### Scenario: Zooming in leaves the pointed-at point where it was

- **WHEN** the user scrolls to zoom in on a point away from the image centre
- **THEN** that point still lands on the same pixel afterwards
- **Test**: `src/fractal/navigate.zig::zoomAbout keeps the anchor under the same pixel when zooming in`

#### Scenario: Zooming out leaves the pointed-at point where it was

- **WHEN** the user scrolls to zoom out on a point away from the image centre
- **THEN** that point still lands on the same pixel afterwards
- **Test**: `src/fractal/navigate.zig::zoomAbout keeps the anchor under the same pixel when zooming out`

#### Scenario: In then out about the same point is a no-op

- **WHEN** the user zooms one step in and one step out about the same point
- **THEN** the view is exactly the one they started from
- **Test**: `src/fractal/navigate.zig::zoomAbout in then out about the same anchor restores the view`

### Requirement: Centered zoom

The system SHALL make the clicked point the new view centre when the user zooms from the
right-click menu, and change the magnification by exactly the step it names.

#### Scenario: The clicked point becomes the centre

- **WHEN** the user picks a zoom from the menu opened at a point
- **THEN** that point is the new view centre
- **Test**: `src/fractal/navigate.zig::zoomCentered makes the given point the new center`

#### Scenario: A 2x step is a 2x step

- **WHEN** the user picks "zoom in 2x"
- **THEN** the view covers exactly half the width it did, and the magnification exactly doubles
- **Test**: `src/fractal/navigate.zig::zoomCentered with the zoom-in step halves the side`
- **Test**: `src/fractal/navigate.zig::zoomCentered scales the diagonal by exactly the factor`

### Requirement: Pan

The system SHALL translate the view by a drag, moving the image content by exactly the distance
dragged and leaving the magnification untouched.

#### Scenario: The content follows the cursor exactly

- **WHEN** the user drags the image by a pixel delta
- **THEN** the content shifts by exactly that many pixels
- **Test**: `src/fractal/navigate.zig::panByPixels shifts the image content by exactly the pixel delta`

#### Scenario: Panning does not change the zoom

- **WHEN** the user pans
- **THEN** the view's extent, and so its magnification, is unchanged
- **Test**: `src/fractal/navigate.zig::panByPixels leaves the side, and therefore the magnification, untouched`

#### Scenario: Panning works the same at depth

- **WHEN** a deep, off-centre view is panned on an image of any size
- **THEN** the centre moves by the delta measured at that view's own scale
- **Test**: `src/fractal/navigate.zig::panByPixels moves the center of a deep off-center view at its own image side`

### Requirement: Box select

The system SHALL zoom to the region the user rubber-bands, showing the whole selection, expanded
on its shorter axis only so nothing is cropped and nothing is distorted.

#### Scenario: The selection is fully visible afterwards

- **WHEN** the user drags out a non-square selection
- **THEN** the new view contains all of it, grown only on the shorter axis
- **Test**: `src/fractal/navigate.zig::boxSelect contains the selection, expanding only the shorter axis`

#### Scenario: A tall selection is sized by its long axis

- **WHEN** the selection is taller than it is wide
- **THEN** the new view is sized from its vertical extent and grown horizontally
- **Test**: `src/fractal/navigate.zig::boxSelect sizes a taller-than-wide selection from its vertical axis`
- **Test**: `src/fractal/navigate.zig::boxSelect contains a taller-than-wide selection, expanding only the horizontal axis`

#### Scenario: Drag direction does not matter

- **WHEN** the user drags the selection bottom-right to top-left instead of the other way
- **THEN** the resulting view is the same
- **Test**: `src/fractal/navigate.zig::boxSelect accepts the drag corners in either order`

#### Scenario: A single-axis drag is still usable

- **WHEN** the drag has no vertical extent at all
- **THEN** the horizontal extent sizes the view rather than the gesture being thrown away
- **Test**: `src/fractal/navigate.zig::boxSelect keeps a zero-height drag usable by sizing it on the horizontal axis`

### Requirement: Reset to the home view

The system SHALL return to the home view — the whole set in frame — on request, from any depth.

#### Scenario: Reset gives back the home view

- **WHEN** the user resets the view
- **THEN** the view is the home view
- **Test**: `src/fractal/navigate.zig::reset returns the default view`

### Requirement: Impossible gestures are refused

The system SHALL refuse a gesture that cannot produce a valid view, keep the current view, and be
able to say what was wrong with it — never applying a broken view or crashing.

#### Scenario: A click with no drag is not a selection

- **WHEN** the user clicks without dragging
- **THEN** the zero-area selection is refused
- **Test**: `src/fractal/navigate.zig::boxSelect rejects a zero-area selection from a click without a drag`

#### Scenario: A zoom that would collapse the view is refused

- **WHEN** a zoom step would shrink the view's extent to nothing, or grow it beyond what can be
  represented
- **THEN** the gesture is refused
- **Test**: `src/fractal/navigate.zig::zoomAbout rejects a factor that underflows the side to zero`
- **Test**: `src/fractal/navigate.zig::zoomAbout rejects a factor that overflows the side to infinity`

#### Scenario: A gesture on a collapsed window is refused, not asserted

- **WHEN** a pan or a selection arrives while the image has zero size, as it does on a minimized
  window
- **THEN** the gesture is refused and the app keeps running
- **Test**: `src/fractal/navigate.zig::panByPixels rejects a zero image side instead of asserting`
- **Test**: `src/fractal/navigate.zig::boxSelect rejects zero image dimensions instead of asserting`

#### Scenario: The refusal says what was wrong

- **WHEN** a gesture is refused
- **THEN** the message names the offending value and what the user should do instead
- **Test**: `src/fractal/viewport.zig::degenerateRegionMessage names the offending value and what to do`

### Requirement: Zoom depth limit

The system SHALL warn the user, without refusing the navigation, when the view side goes below
1e-30, the depth at which the extended-precision center stops resolving detail.

#### Scenario: Crossing the floor still navigates, and is flagged

- **WHEN** a zoom takes the view past the depth limit
- **THEN** the zoom succeeds and the view is flagged as past the limit
- **Test**: `src/fractal/navigate.zig::a zoom that crosses the precision floor still succeeds but is flagged`

#### Scenario: The warning fires only past the new floor

- **WHEN** the view side is 1e-20
- **THEN** no precision-floor warning is raised; and when the side is 1e-31, the warning is
  raised
- **Test**: `src/fractal/navigate.zig::acceptance: the precision floor sits at 1e-30`
- **Test**: `src/fractal/viewport.zig::atPrecisionFloor does not flag the default view`
- **Test**: `src/fractal/viewport.zig::atPrecisionFloor does not flag a side just above the floor`

#### Scenario: The warning is actionable

- **WHEN** the warning is raised
- **THEN** it names the offending view extent, the limit crossed, what the user will see, and what
  to do about it
- **Test**: `src/fractal/viewport.zig::precisionFloorMessage names the offending side, the 1e-30 limit and what to do`
- **Test**: `src/fractal/navigate.zig::acceptance: past the precision floor the view is still accepted and the warning is actionable`

### Requirement: Maximum zoom-out

The system SHALL stop the view growing once it is wider than the whole set is: a zoom-out that would
take the view side past 8.0 SHALL saturate at the greater of 8.0 and the view's current width
instead, keeping a valid view rather than refusing the gesture.

#### Scenario: Zooming out repeatedly stops at the widest view

- **WHEN** the user keeps scrolling to zoom out from the home view
- **THEN** the view stops widening at side 8.0 — a bit over twice the home framing — instead of
  growing without bound
- **Test**: `src/fractal/navigate.zig::repeated zoom-out saturates at the maximum side instead of growing without bound`

#### Scenario: A zoom-out at the widest view changes nothing

- **WHEN** the user zooms out again while already at the widest view
- **THEN** the view is unchanged, and the point under the cursor is still under it
- **Test**: `src/fractal/navigate.zig::a zoom-out notch at the maximum side changes nothing at all`
- **Test**: `src/fractal/navigate.zig::a clamped zoom-out still keeps the anchor under its own pixel`

#### Scenario: The bound does not touch the views the user works in

- **WHEN** the user is at the home view, takes their first zoom-out notch from it, or rubber-bands a
  region
- **THEN** the home view and its first zoom-out notch are exactly what they always were, and only a
  selection wider than the bound is narrowed to it
- **Test**: `src/fractal/navigate.zig::the maximum side leaves the home view and its first zoom-out notch unclamped`
- **Test**: `src/fractal/navigate.zig::boxSelect cannot commit a selection wider than the maximum side`

## Notes

- The pixel↔complex mapping every gesture is measured in, and the fitted on-screen rectangle the
  cursor is read through, belong to `view-coordinates`.
- The depth the **Zoom depth limit** names is the same depth at which `rendering`'s **Adaptive
  iteration count** stops climbing.
- The two ends of the zoom range are deliberately different. **Zoom depth limit** is a warning
  only: nothing clamps the side, and a view below it still renders, because the user legitimately
  wants to go deeper than the app can guarantee. **Maximum zoom-out** clamps, because past the whole
  set there is nothing further to see. What makes depths between 1e-13 and 1e-30 usable at all is
  `deep-zoom`; keeping a gesture's centre exact at those depths is `deep-zoom`'s **Deep navigation
  keeps its precision**.
- The bound is on *navigation* only: a view wider than 8.0 arriving from outside navigation (a saved
  file, a typed magnification) is left at its own width, and zooming in from it still works.
