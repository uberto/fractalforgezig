# Image export

### E1 · Custom-size PNG

The app SHALL offer File → Export PNG… with positive integer width and height and a PNG destination.

#### Scenario: S1 · Requested dimensions

- **WHEN** the user exports a 7 × 11 image **THEN** the destination contains a decodable 7 × 11 opaque PNG.
- **Test**: [`exported file decodes at requested dimensions with opaque pixels`](../../src/image_export_test.zig)

#### Scenario: S2 · Dimension limits

- **WHEN** dimensions are zero, exceed 16,384 on either axis, or exceed 100,000,000 total pixels **THEN** the export is rejected before allocation or destination changes.
- **Test**: [`invalid dimensions are rejected`](../../src/image_export_test.zig)

### E2 · Framing

The exported image SHALL retain the displayed image’s full-precision center and complex-plane diagonal at an isotropic pixel scale, with the real axis increasing rightward and the imaginary axis increasing upward. Changing the aspect ratio can crop one axis and reveal more on the other.

#### Scenario: S3 · Fixed diagonal

- **WHEN** exporting a 2:1 visible image to 1:1, 3:1 or 1:3 **THEN** the center and diagonal are preserved and each axis spans the length implied by the output aspect ratio. **WHEN** exporting at a different resolution with the same aspect ratio **THEN** both complex-plane spans remain unchanged.
- **Test**: [`export mapping preserves center, diagonal and orientation`](../../src/image_export_test.zig)

### E3 · Rendered snapshot

The export SHALL rerender the captured view with its original iteration limit and coloring, independently of preview pixels and subsequent app changes.

#### Scenario: S4 · Shallow colouring

- **WHEN** exporting a shallow view with a custom palette and mapping **THEN** the decoded pixels match the independently colored render at the requested output pixel centers.
- **Test**: [`exported shallow pixels match current color settings at new samples`](../../src/image_export_test.zig)

#### Scenario: S5 · Deep precision

- **WHEN** exporting a deep view **THEN** the output retains the detail generated from its full-precision center and resolved iteration limit.
- **Test**: [`exported deep pixels retain the precision of the selected center`](../../src/image_export_test.zig)

### E4 · Responsive export and atomic publication

The app SHALL show progress and allow cancellation before publication, with bounded export memory and with failed or canceled exports preserving the destination.

#### Scenario: S6 · Cancellation

- **WHEN** a tall export is canceled after rows have completed **THEN** progress has advanced, the previous destination survives, and no temporary file remains.
- **Test**: [`cancel after progress preserves the old file`](../../src/image_export_test.zig)

#### Scenario: S7 · Publication failure

- **WHEN** an export cannot publish its completed PNG **THEN** it reports failure and removes temporary output.
- **Test**: [`publish failure removes the temporary file`](../../src/image_export_test.zig)

#### Scenario: S8 · Bounded memory

- **WHEN** an export is tall **THEN** all rows are written within a fixed memory budget that cannot hold the whole image.
- **Test**: [`exporting rows does not allocate the whole image`](../../src/image_export_test.zig)

## GUI pilot

The [manual PNG export checks](../../README.md#manual-png-export-checks) cover the File menu, native picker, fitted-image defaults, progress and terminal messages. The headless acceptance suite passed. User GUI verification is pending.
