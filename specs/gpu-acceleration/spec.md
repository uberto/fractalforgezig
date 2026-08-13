<!-- Living spec for the `gpu-acceleration` capability. TRACKED and committed.
     Describes only behavior that is SHIPPED and PASSING. -->

# Capability: gpu-acceleration

## Purpose

Make the fractal fast by iterating it on the graphics hardware, without making the app dependent on
that hardware. The user's promise here is negative as much as positive: the GPU should be quicker,
but a missing, refusing or failing GPU must cost them nothing but time — an image always appears,
and it is the same image either way.

## Requirements

### Requirement: GPU results match the CPU

The system SHALL produce the same classification of the set on the graphics hardware as it does on
the processor, so switching backend changes how long the image takes and not what it shows.

#### Scenario: The GPU agrees with the CPU about the set

- **WHEN** a view is iterated on the GPU and on the CPU
- **THEN** the pixels the CPU calls interior are the pixels the GPU calls interior
- **Test**: `src/gpu_headless_test.zig::compute: gpuIterate interior pixels match CPU (deep interior, no precision boundary)`

#### Scenario: The GPU returns a usable value for every pixel it was asked about

- **WHEN** a small image is iterated on the GPU
- **THEN** every pixel of it comes back as a finite number
- **Test**: `src/gpu_headless_test.zig::compute: dispatch at S=4 produces 16 finite results`

### Requirement: GPU work is split into bands

The system SHALL dispatch GPU iteration in row bands, each band containing exactly what those rows
of a whole-image dispatch would contain, so no single piece of GPU work is long enough to stall the
display or be killed by the driver.

#### Scenario: A band equals its rows of the whole image

- **WHEN** a band of rows is iterated on its own
- **THEN** it holds exactly the values those rows have in a whole-image dispatch
- **Test**: `src/gpu_headless_test.zig::compute: a band dispatch equals those rows of the whole-image dispatch`

#### Scenario: A band past the end of the image is refused, not quietly trimmed

- **WHEN** a band is requested that runs past the last row
- **THEN** it is refused rather than clamped to fit
- **Test**: `src/gpu_headless_test.zig::compute: a band that runs past the last row is rejected, not clamped`

#### Scenario: The CPU path bands identically

- **WHEN** the same band is iterated on the CPU into a band-sized buffer
- **THEN** it holds the same values as that band of the whole image, so the two backends are
  interchangeable band by band
- **Test**: `src/fractal/iterbuf.zig::iterateBandInto fills a band-local buffer with the SAME values as the full-buffer band`

### Requirement: The CPU always finishes the job

The system SHALL complete a render on the processor, with a logged warning naming the reason,
whenever GPU iteration is unavailable or fails, so an image always appears.

#### Scenario: No usable GPU means the image still renders

- **WHEN** GPU iteration is asked for but no GPU iteration path is available
- **THEN** the render completes on the CPU and counts as a completed render
- **Test**: `src/fractal/engine.zig::use_gpu=true with no gpu_iter_fn: CPU fallback runs, iteration_passes increments`

#### Scenario: The GPU path is used when it is there

- **WHEN** GPU iteration is asked for and available
- **THEN** it is what runs, and the render completes
- **Test**: `src/fractal/engine.zig::use_gpu=true with a gpu_iter_fn: the fn is called, iteration_passes increments`

#### Scenario: A machine with no GPU compute still starts

- **WHEN** the GPU compute pipeline cannot be created at startup
- **THEN** the app starts, logs a warning naming the failure, and runs with the CPU backend and the
  GPU choice unavailable
- **Test**: _not pinned by a test_ — manual smoke run; the success half is pinned by
  `src/gpu_headless_test.zig::compute: pipeline creates successfully with embedded MSL source`

### Requirement: The user chooses the backend

The system SHALL let the user switch iteration between the GPU and the CPU while the app is
running, and SHALL offer the GPU choice only when the machine can actually do it.

#### Scenario: Switching backend re-renders the current view

- **WHEN** the user toggles the GPU choice
- **THEN** the current view is rendered again on the newly chosen backend
- **Test**: _not pinned by a test_ — manual smoke run (the toggle is ImGui glue)

#### Scenario: The choice is unavailable without a GPU path

- **WHEN** no GPU iteration path was created at startup
- **THEN** the GPU choice is shown disabled rather than offering something that cannot work
- **Test**: _not pinned by a test_ — manual smoke run (the toggle is ImGui glue)

### Requirement: GPU failures are reported in the user's terms

The system SHALL report a GPU failure by naming the operation that failed and what the driver said
about it, rather than failing silently or crashing.

#### Scenario: A failed graphics call names itself and the driver's reason

- **WHEN** a graphics call fails
- **THEN** the logged message contains the call's name and the driver's error text
- **Test**: `src/gpu/message.zig::sdlFailure embeds the call name and SDL error string`

#### Scenario: A successful start names the driver in use

- **WHEN** the graphics device is created
- **THEN** the driver actually in use is logged, so a wrong-backend report is diagnosable
- **Test**: `src/gpu/message.zig::deviceReady reports the driver name`

## Notes

- That the resulting image is identical however the work was split is `rendering`'s **Reproducible
  image**; this capability adds only that the GPU is one of the ways to split it.
- GPU iteration timing is reported to the user by `app-shell`'s **Render statistics**.
