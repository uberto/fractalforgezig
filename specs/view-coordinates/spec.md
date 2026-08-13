<!-- Living spec for the `view-coordinates` capability. TRACKED and committed.
     Describes only behavior that is SHIPPED and PASSING. -->

# Capability: view-coordinates

## Purpose

Define what "where the user is looking" means, and keep the answer consistent everywhere it is
used: in the image on screen, in the numbers in the coordinate panel, in the readout under the
cursor, and in the gestures `navigation` measures. A location the user can read off the screen must
be the same location they can type back in, and the pixel they point at must be the pixel the app
thinks they pointed at.

## Requirements

### Requirement: Square view model

The system SHALL describe the visible region as a square patch of the complex plane given by its
centre and its side length, and SHALL open on the square that contains the whole set.

#### Scenario: The home view frames the whole set

- **WHEN** the app opens
- **THEN** the view is the square containing the classical Mandelbrot region, so nothing of the set
  is cut off
- **Test**: `src/fractal/viewport.zig::defaultView contains the whole M0 fixed region`
- **Test**: `src/fractal/viewport.zig::defaultView snaps the M0 fixed region to its enclosing square`

#### Scenario: A view with no extent is not a view

- **WHEN** a region is described with a non-positive or non-finite extent, or a non-finite centre
- **THEN** it is refused rather than accepted as a degenerate view
- **Test**: `src/fractal/viewport.zig::fromCenterSide rejects a non-positive side and a non-finite center`

### Requirement: Interchangeable view notations

The system SHALL let the same view be read and entered either as a centre plus a magnification or
as two opposite corners, with each notation reproducing the other exactly.

#### Scenario: Centre and magnification round-trip

- **WHEN** a view is read as centre plus magnification and rebuilt from those numbers
- **THEN** the view is the one it started as, including for deep and off-centre views
- **Test**: `src/fractal/viewport.zig::fromCenterMag inverts centerMag for the default, deep-zoom and off-center views`

#### Scenario: Corners round-trip

- **WHEN** a view is read as its two opposite corners and rebuilt from them
- **THEN** the view is the one it started as, including for deep and off-centre views
- **Test**: `src/fractal/viewport.zig::fromCorners inverts corners for the default, deep-zoom and off-center views`

#### Scenario: Magnification means one thing only

- **WHEN** the magnification of a view is read
- **THEN** it is the reciprocal of the view's diagonal length, so halving the extent exactly
  doubles it
- **Test**: `src/fractal/viewport.zig::magnification is the reciprocal of the square's diagonal length`
- **Test**: `src/fractal/viewport.zig::halving the side exactly doubles the magnification`

#### Scenario: A non-square pair of corners becomes the square that contains it

- **WHEN** a view is entered as two corners that do not form a square
- **THEN** the view is the square containing them, grown on the shorter axis only
- **Test**: `src/fractal/viewport.zig::fromCorners snaps a wide rectangle to a square sized by the larger axis`
- **Test**: `src/fractal/viewport.zig::the square snapped from a tall rectangle contains it, expanded only on the short axis`

#### Scenario: An unusable typed view is refused and the panel resyncs

- **WHEN** the user commits a view whose magnification is not a finite positive number, or text
  that is not a number at all
- **THEN** the view is refused and the panel goes back to showing the view actually in use
- **Test**: `src/fractal/viewport.zig::fromCenterMag rejects a non-positive or non-finite magnification`
- **Test**: `src/ui/editor.zig::ViewEditor.parseAndApplyCenterMag returns null on bad buffer`
- **Test**: `src/ui/editor.zig::ViewEditor.syncFromView updates buffers to the new view`

### Requirement: Pixel to plane mapping

The system SHALL map every pixel of the image to a point of the complex plane and back without
drift, with the imaginary axis pointing up while pixel rows run down, and with equal spacing on
both axes at any image shape.

#### Scenario: Pixel centres round-trip exactly

- **WHEN** a pixel centre is mapped to the plane and back
- **THEN** it is the pixel it started as
- **Test**: `src/fractal/viewport.zig::pixelToComplex and complexToPixel are exact inverses at pixel centers`

#### Scenario: The imaginary axis points up

- **WHEN** two pixels one row apart are mapped
- **THEN** the lower pixel has the smaller imaginary part
- **Test**: `src/fractal/viewport.zig::pixel-y grows downward while complex-im grows upward in the square model`

#### Scenario: The round trip is still sub-pixel at depth

- **WHEN** pixels of a deeply zoomed view are mapped to the plane and back
- **THEN** the error stays far below one pixel, so a deep view's readout and gestures still agree
- **Test**: `src/fractal/viewport.zig::the pixel round-trip stays far sub-pixel on a deep zoom`

#### Scenario: A non-square image is not stretched

- **WHEN** the image is wider than it is tall
- **THEN** one pixel is worth the same distance on both axes
- **Test**: `src/fractal/viewport.zig::non-square image preserves aspect: per-pixel re and im steps are equal`

### Requirement: Aspect-preserving display

The system SHALL fit the rendered image inside the area available for it without ever stretching
it, leaving bars where the shapes differ, and SHALL read the cursor through exactly the rectangle
it drew into.

#### Scenario: A square render stays square in a wide area

- **WHEN** a square image is shown in an area wider than it is tall
- **THEN** it is drawn square and centred, not stretched to fill the width
- **Test**: `src/fractal/viewport.zig::fitImageRect keeps a square render square inside a wide region (the M5 aspect bug)`
- **Test**: `src/fractal/viewport.zig::fitImageRect centers the fitted image horizontally in a wide region`

#### Scenario: A coarse preview fills the same area as the full image

- **WHEN** a low-resolution preview of the same shape is shown
- **THEN** it is scaled up to the whole area, so the picture does not jump size when it refines
- **Test**: `src/fractal/viewport.zig::fitImageRect scales a coarse preview up to the whole region (same aspect)`

#### Scenario: The bars are not part of the image

- **WHEN** the cursor is over a letterbox bar rather than the picture
- **THEN** no coordinate is reported for it
- **Test**: `src/fractal/viewport.zig::cursorCoord returns null over the letterbox bars`

#### Scenario: The cursor over the picture reports its point

- **WHEN** the cursor is over the picture
- **THEN** the complex point under it is reported, and the centre pixel reports the view centre
- **Test**: `src/fractal/viewport.zig::cursorCoord returns the complex value under a window pixel inside the image`
- **Test**: `src/fractal/viewport.zig::cursorCoord rectangular image: center pixel maps to view center`

### Requirement: Coordinate readout precision

The system SHALL show a coordinate with more decimals as the view is magnified, so the digits that
distinguish neighbouring pixels are visible, up to the limit of the numbers it holds.

#### Scenario: Deeper zoom shows more decimals

- **WHEN** the view is magnified
- **THEN** the readout shows more decimals than it did
- **Test**: `src/fractal/viewport.zig::coordDigits increases as magnification grows`
- **Test**: `src/fractal/viewport.zig::formatCoord shows more decimals at a deeper magnification`

#### Scenario: The digit count stays within useful bounds

- **WHEN** the view is at any magnification, however shallow or extreme
- **THEN** the readout shows at least the base number of decimals and never more than the numbers
  can distinguish
- **Test**: `src/fractal/viewport.zig::coordDigits clamps to the documented range`
- **Test**: `src/fractal/viewport.zig::coordDigits is the base precision at the default view`

#### Scenario: A negative imaginary part reads as a subtraction

- **WHEN** the coordinate's imaginary part is negative, including a value that rounds to zero from
  below
- **THEN** it is shown as `a - bi`, never as `a + -bi`
- **Test**: `src/fractal/viewport.zig::formatCoord renders a negative imaginary part with a minus`
- **Test**: ``src/fractal/viewport.zig::formatCoord renders a negative-zero imaginary part with a minus, never `+ -` ``

#### Scenario: A coordinate that does not fit is not truncated

- **WHEN** a coordinate cannot be rendered in the space available
- **THEN** the attempt fails rather than producing a half-written number the user might copy
- **Test**: `src/fractal/viewport.zig::formatCoord reports NoSpaceLeft instead of truncating`

## Notes

- Gestures measured in these coordinates are specified in `navigation`; the panel and readout that
  display them are in `app-shell`.
- The digit cap is the one the current number format supports; `rendering`'s and `navigation`'s
  depth limits are the matching statement about how deep the view itself can usefully go.
