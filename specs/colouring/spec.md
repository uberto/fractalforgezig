<!-- Living spec for the `colouring` capability. TRACKED and committed.
     Describes only behavior that is SHIPPED and PASSING. -->

# Capability: colouring

## Purpose

Turn each pixel's escape result into a colour the user chose. This is the part of the app the user
plays with most, so it has to be both expressive — an editable gradient, three ways of mapping
iteration values onto it, a separate colour for the set's interior — and instant, which is why
`rendering` guarantees a colour edit never re-runs the fractal.

## Requirements

### Requirement: Gradient stop model

The system SHALL colour escaped pixels by interpolating between a list of colour stops the user
places, and SHALL hold the outermost colours flat beyond the first and last stop.

#### Scenario: Colours blend between two stops

- **WHEN** the palette has two stops
- **THEN** a value half-way between them is coloured the per-channel average of the two
- **Test**: `src/fractal/gradient.zig::two-stop LUT: the midpoint texel is the per-channel average (interpolation)`

#### Scenario: Beyond the end stops the end colours hold

- **WHEN** a value falls before the first stop or after the last
- **THEN** it takes the first or last stop's colour exactly, rather than fading out
- **Test**: `src/fractal/gradient.zig::texels before the first stop clamp to the first stop's color`
- **Test**: `src/fractal/gradient.zig::texels after the last stop clamp to the last stop's color`

#### Scenario: A one-colour palette paints one colour

- **WHEN** the palette has a single stop
- **THEN** the whole exterior is that colour, with no interpolation artefacts
- **Test**: `src/fractal/gradient.zig::a single-color gradient bakes a uniform LUT`

#### Scenario: Transparency in a stop is honoured, not ignored

- **WHEN** a stop is given a partly transparent colour
- **THEN** its alpha is interpolated like any other channel rather than being forced opaque in the
  palette
- **Test**: `src/fractal/gradient.zig::alpha is interpolated, not forced: a translucent stop produces a translucent midpoint`

#### Scenario: The same palette always gives the same colours

- **WHEN** the default palette is prepared twice
- **THEN** the two results are identical
- **Test**: `src/fractal/gradient.zig::baking the default palette is deterministic`

### Requirement: Stop editing

The system SHALL let the user add, remove and recolour stops and move them along the gradient,
always keeping at least one stop, refusing to exceed the supported maximum, and ordering the stops
however they were entered.

#### Scenario: A stop can be added while there is room

- **WHEN** the user adds a stop below the maximum
- **THEN** it is appended and the palette grows by one
- **Test**: `src/ui/editor.zig::addStop appends one stop and reports success while there is room`

#### Scenario: The maximum number of stops is enforced

- **WHEN** the user adds a stop at the maximum
- **THEN** nothing changes
- **Test**: `src/ui/editor.zig::addStop refuses (no-op) once at max_stops capacity`

#### Scenario: The last stop cannot be removed

- **WHEN** the user removes the only remaining stop
- **THEN** the removal is refused, so a palette is never empty
- **Test**: `src/ui/editor.zig::removeStop refuses to drop below the one-stop minimum`

#### Scenario: A removed stop leaves no gap

- **WHEN** the user removes a stop from the middle of the list
- **THEN** the stops after it move down and the palette shrinks by one
- **Test**: `src/ui/editor.zig::removeStop deletes the indexed stop and shifts the tail down`

#### Scenario: Out-of-order stops are sorted, not rejected

- **WHEN** the user drags a stop past its neighbour
- **THEN** the palette is used in ascending position order without losing any stop
- **Test**: `src/ui/editor.zig::toGradient sorts out-of-order stops ascending by position`
- **Test**: `src/ui/editor.zig::toGradient preserves the stop count`

#### Scenario: An empty palette is refused and the image is left alone

- **WHEN** a palette with no stops is applied
- **THEN** it is refused and the image is not repainted
- **Test**: `src/fractal/engine.zig::setGradient with an empty gradient returns EmptyGradient and does not recolor`

### Requirement: Iteration mapping modes

The system SHALL offer three ways of mapping a pixel's escape value onto the gradient — linear,
logarithmic and cyclic — with the cyclic mode repeating over a period the user sets.

#### Scenario: Linear runs straight through the gradient

- **WHEN** the linear mode is used
- **THEN** the gradient position rises steadily with the escape value, from one end of the gradient
  to the other
- **Test**: `src/fractal/mapping.zig::linear: monotonic increasing between 0 and max_iter`
- **Test**: `src/fractal/mapping.zig::linear: smooth == 0 maps to 0`
- **Test**: `src/fractal/mapping.zig::linear: smooth == max_iter maps to 1`

#### Scenario: Logarithmic brings out the slow-escaping detail

- **WHEN** the logarithmic mode is used
- **THEN** a mid-range escape value lands further along the gradient than it would linearly, still
  rising steadily and still spanning the whole gradient
- **Test**: `src/fractal/mapping.zig::log: compresses high values — a mid value maps higher than linear`
- **Test**: `src/fractal/mapping.zig::log: is monotonic increasing`
- **Test**: `src/fractal/mapping.zig::log: endpoints map to 0 and 1`

#### Scenario: Cyclic repeats the gradient over its period

- **WHEN** the cyclic mode is used
- **THEN** two escape values one period apart are coloured identically, and changing the period
  changes the colouring
- **Test**: `src/fractal/mapping.zig::cyclic: smooth and smooth + period map to the same value`
- **Test**: `src/fractal/mapping.zig::cyclic: a different period changes the result`

#### Scenario: A nonsensical value never produces a nonsensical colour

- **WHEN** an escape value is negative or not a number, or the period is not positive, or the
  iteration limit is zero
- **THEN** the gradient position falls back to the start of the gradient rather than going out of
  range
- **Test**: `src/fractal/mapping.zig::all modes: a non-finite smooth clamps to 0`
- **Test**: `src/fractal/mapping.zig::cyclic: a non-positive period guards to 0 (no divide by zero)`
- **Test**: `src/fractal/mapping.zig::linear and log: max_iter == 0 guards to 0`

### Requirement: Interior colour

The system SHALL paint the pixels that never escaped in a single colour the user picks separately
from the gradient, so palette work never disturbs the body of the set and vice versa.

#### Scenario: Interior pixels take the interior colour

- **WHEN** a pixel never escaped
- **THEN** it is painted the interior colour
- **Test**: `src/fractal/colorpass.zig::colorInto: the interior sentinel writes the passed interior color, opaque`

#### Scenario: A gradient edit does not touch the interior

- **WHEN** the gradient is edited
- **THEN** interior pixels still show the interior colour
- **Test**: `src/fractal/engine.zig::setGradient leaves interior pixels tracking the (unchanged) interior color`

#### Scenario: Changing the interior colour repaints only the interior

- **WHEN** the interior colour is changed
- **THEN** interior pixels take the new colour without the fractal being recomputed
- **Test**: `src/fractal/engine.zig::setInterior recolors interior pixels without re-iterating`

#### Scenario: An escaped pixel is never given the interior colour

- **WHEN** a pixel escaped, however slowly
- **THEN** it is coloured through the gradient, not with the interior colour
- **Test**: `src/fractal/engine.zig::the known exterior pixel escapes and is colored through the LUT, not the interior color`

### Requirement: Fully opaque image

The system SHALL produce a fully opaque image whatever alpha the palette or interior colour carry,
so the fractal is never shown blended with whatever is behind it.

#### Scenario: Every pixel of the painted image is opaque

- **WHEN** an image is painted with any palette
- **THEN** every pixel is fully opaque
- **Test**: `src/fractal/colorpass.zig::colorInto: every written pixel is fully opaque (alpha 255)`
- **Test**: `src/fractal/engine.zig::iterate: the whole output image is fully opaque (alpha 255)`

### Requirement: Colouring is reproducible

The system SHALL paint the same image byte for byte from the same escape values and the same
palette settings.

#### Scenario: The same input paints the same image twice

- **WHEN** the same escape values are painted twice with the same settings
- **THEN** the two images are byte-identical
- **Test**: `src/fractal/colorpass.zig::colorInto is deterministic: two runs produce byte-identical images`

#### Scenario: The painted image keeps the fractal's symmetry

- **WHEN** a view centred on the real axis is painted
- **THEN** the image mirrors top to bottom, as the escape values do
- **Test**: `src/fractal/colorpass.zig::full-image golden: top/bottom symmetry is preserved (colored image mirrors)`

## Notes

- That a colour edit costs no fractal recomputation is stated in `rendering` (**Colour edits never
  re-iterate**); this capability owns only what the colours are.
- The palette, mapping mode, period and interior colour are all part of what `persistence` saves.
