<!-- Living spec for the `app-shell` capability. TRACKED and committed.
     Describes only behavior that is SHIPPED and PASSING. -->

# Capability: app-shell

## Purpose

The application the user actually opens: one window with the fractal on the left and the controls on
the right, a status line that tells them what is under the cursor or how far a render has got, and
menus for saving, opening and quitting. Its job is to keep the app answering — a render is never
allowed to freeze the window — and to make every refusal visible with enough context to act on.

Most of this capability is ImGui and file-dialog glue, which this project deliberately does not unit
test (see `src/ui/context.md`); its scenarios are pinned where a pure helper carries the behavior and
marked unpinned where only a manual smoke run verifies them.

## Requirements

### Requirement: One resizable window, two fixed regions

The system SHALL present the fractal image and the controls side by side in a single resizable
window, and SHALL treat a resize as a change of render resolution rather than stretching the image
it already has.

#### Scenario: The image area is the window minus the control panel

- **WHEN** the window is a given size
- **THEN** the fractal occupies the area left of the fixed-width control panel, with a status line
  reserved beneath it, and that area is the resolution the fractal is rendered at
- **Test**: _not pinned by a test_ — manual smoke run (the area is measured from ImGui layout);
  the image's placement inside it is pinned by
  `src/fractal/viewport.zig::fitImageRect fills the region exactly when the aspects already match`
  and `src/fractal/viewport.zig::fitImageRect offsets by the region origin`

#### Scenario: A collapsed window does not break the layout

- **WHEN** the area available for the fractal, or the image to put in it, has no width or height
- **THEN** the layout yields a zero-size image area instead of an invalid one
- **Test**: `src/fractal/viewport.zig::fitImageRect returns a degenerate rect for a zero-size region`
- **Test**: `src/fractal/viewport.zig::fitImageRect returns a degenerate rect for a zero-size texture`

#### Scenario: A resize drag settles before rendering at full resolution

- **WHEN** the user drags the window edge
- **THEN** the in-flight full-resolution render is abandoned and re-armed for the size the user
  settles on, and the image shown meanwhile is fitted rather than stretched
- **Test**: _not pinned by a test_ — manual smoke run (the region size comes from ImGui layout);
  the fitting half is pinned by `view-coordinates`' **Aspect-preserving display**

### Requirement: Status readout under the cursor

The system SHALL show, for the pixel under the cursor, its coordinate and its escape result — or
that it never escaped, together with the iteration limit it was tested to — and SHALL show a
placeholder when the cursor is not over the image.

#### Scenario: Hovering the image shows where and what

- **WHEN** the cursor is over the fractal
- **THEN** the status line shows that point's coordinate and its iteration result
- **Test**: _not pinned by a test_ — manual smoke run; the coordinate's wording is pinned by
  `src/fractal/viewport.zig::formatCoord renders a positive imaginary part with a plus`

#### Scenario: An interior pixel reports how hard it was tested

- **WHEN** the cursor is over a pixel that never escaped
- **THEN** the status line says it is interior and names the iteration limit it survived
- **Test**: _not pinned by a test_ — manual smoke run

#### Scenario: Off the image there is nothing to report

- **WHEN** the cursor is over the control panel or a letterbox bar
- **THEN** the status line shows a placeholder rather than a stale coordinate
- **Test**: _not pinned by a test_ — manual smoke run; the "no point here" half is pinned by
  `src/fractal/viewport.zig::cursorCoord returns null over the letterbox bars`

### Requirement: Visible progress instead of a frozen window

The system SHALL show how far a full-resolution render has got, as a proportion and as a
percentage, and SHALL disable the editing controls until it finishes, so a slow render reads as
work in progress rather than a hang.

#### Scenario: A render in flight shows its percentage

- **WHEN** a full-resolution render is part way through
- **THEN** the status line shows a progress indicator labelled with the percentage complete
- **Test**: `src/fractal/progressive.zig::progressLabel renders the completion percentage`
- **Test**: `src/fractal/engine.zig::passFraction reports the completed row ratio mid-pass`

#### Scenario: A nonsensical progress value still reads sensibly

- **WHEN** the reported fraction is out of range
- **THEN** the label reads as complete rather than showing an impossible percentage
- **Test**: `src/fractal/progressive.zig::progressLabel clamps an out-of-range fraction to 100%`

#### Scenario: The editing controls are inert while rendering

- **WHEN** a full-resolution render is in flight
- **THEN** the palette and view controls are disabled until it completes
- **Test**: _not pinned by a test_ — manual smoke run (ImGui glue)

### Requirement: Render statistics

The system SHALL report what the last render cost and what it did — processor time, frame time,
graphics time when the GPU ran, and how many render and repaint passes have happened — so the user
can tell a slow view from a slow machine.

#### Scenario: A completed render reports its cost

- **WHEN** a render completes
- **THEN** its duration is reported in milliseconds to two decimals
- **Test**: `src/ui/stats.zig::renderSummary formats the success-summary line with ms to two decimals`
- **Test**: `src/ui/stats.zig::Stats.fromRender sets render_ms and zeroes frame_ms, dispatch_count, and gpu_render_ms`

#### Scenario: Frame time is tracked separately from render time

- **WHEN** a frame is drawn
- **THEN** only the frame time changes, so a fast frame cannot hide a slow render
- **Test**: `src/ui/stats.zig::Stats.observeFrame updates only frame_ms`

#### Scenario: A GPU render reports its own timing

- **WHEN** iteration ran on the GPU
- **THEN** the reported summary names the view extent, the iteration limit and the elapsed
  milliseconds
- **Test**: `src/gpu/message.zig::gpuIterateSummary formats side, max_iter, and elapsed ms`

#### Scenario: Each render logs the view and count it actually used

- **WHEN** a render completes
- **THEN** the logged line names the view, the iteration limit used and whether that limit was
  automatic or pinned — and the limit named is the one the render used
- **Test**: `src/fractal/engine.zig::iteratePassSummary produces the documented one-line re-iterate summary`
- **Test**: `src/fractal/engine.zig::the logged max_iter is exactly the count the engine iterated with`

#### Scenario: A summary is never a plausible fabrication

- **WHEN** the iteration limit for the current view cannot be determined
- **THEN** the summary fails rather than reporting a made-up count
- **Test**: `src/fractal/engine.zig::iteratePassSummary propagates an invalid magnification instead of fabricating a count`

### Requirement: Save and open through the system file dialog

The system SHALL offer Save and Open in the File menu, filtered to the app's own file type, and
SHALL treat cancelling the dialog as changing nothing.

#### Scenario: Saving asks where, through the system dialog

- **WHEN** the user picks File → Save
- **THEN** the system file dialog opens, filtered to the app's file type
- **Test**: _not pinned by a test_ — manual smoke run (the dialog is platform glue)

#### Scenario: Cancelling changes nothing

- **WHEN** the user dismisses the dialog without choosing a file
- **THEN** nothing is saved or loaded and the view is untouched
- **Test**: _not pinned by a test_ — manual smoke run

#### Scenario: One dialog at a time

- **WHEN** a dialog is already open and another is requested
- **THEN** the second request is ignored rather than stacking dialogs
- **Test**: _not pinned by a test_ — manual smoke run

### Requirement: Failures are surfaced, never swallowed

The system SHALL, when it refuses an action, log a message naming what failed and what the user can
do about it, and SHALL keep running with its previous state intact.

#### Scenario: A refused view names the offending value

- **WHEN** a view is refused
- **THEN** the logged message names the offending value in the same wording the coordinate panel
  uses
- **Test**: `src/fractal/engine.zig::degenerateViewMessage names the offending side in T1's wording`
- **Test**: `src/fractal/engine.zig::degenerateViewMessage names a non-finite center instead of the side`

#### Scenario: A refused image size says what is needed

- **WHEN** an image size is refused
- **THEN** the logged message names the rejected size and what is required instead
- **Test**: `src/fractal/engine.zig::imageSideMessage names the rejected pixel side and what is needed`

#### Scenario: A render too big for memory says how big it was

- **WHEN** the memory for a requested image cannot be obtained
- **THEN** the logged message names the requested size, what it would have cost, and the ways out
- **Test**: `src/fractal/engine.zig::resizeFailureMessage names the requested square, its cost and the ways out`

#### Scenario: A rejected panel entry resyncs rather than lying

- **WHEN** the user commits an unparseable value in the coordinate or iteration fields
- **THEN** the failure is logged and the fields go back to showing the values actually in use
- **Test**: `src/ui/editor.zig::ViewEditor.syncFromPolicy overwrites garbage text with the policy value`

### Requirement: Clean startup

The system SHALL announce itself on startup, naming the build's language version and the graphics
driver in use, and SHALL come up showing an image immediately rather than waiting on a
full-resolution render.

#### Scenario: Startup names the build

- **WHEN** the app starts
- **THEN** it logs a startup line naming the app and the language version it was built with
- **Test**: `src/root.zig::startupLine formats the startup banner with the zig version`

#### Scenario: Startup names the graphics driver

- **WHEN** the graphics device is created
- **THEN** the driver in use is logged
- **Test**: `src/gpu/message.zig::deviceReady reports the driver name`

#### Scenario: The window appears before the full-resolution image does

- **WHEN** the app starts
- **THEN** the window comes up showing a coarse image, which is then refined to full resolution
- **Test**: _not pinned by a test_ — manual smoke run; the refinement half is pinned by
  `rendering`'s **Progressive refinement**

#### Scenario: A window with no usable size is reported, not rendered

- **WHEN** the startup window has zero size
- **THEN** startup fails with a logged error naming the problem instead of attempting a render
- **Test**: _not pinned by a test_ — manual smoke run

## Notes

- The gestures the image area accepts are specified in `navigation`; the numbers the coordinate
  panel shows and accepts are in `view-coordinates`; what the file dialogs read and write is in
  `persistence`.
- Unpinned scenarios above are shipped behavior in the ImGui and platform-dialog tiers, which carry
  no unit tests by design. They are verified by the manual smoke run (`zig build run`) and named
  here so a future milestone can pin them if the tiers ever become testable.
