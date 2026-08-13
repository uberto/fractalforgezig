<!-- Living spec for the `persistence` capability. TRACKED and committed.
     Describes only behavior that is SHIPPED and PASSING. -->

# Capability: persistence

## Purpose

Let the user keep a picture they found. A `.fractal` file records everything that makes the image
what it is — where the view is, how hard the fractal was iterated, and the whole palette — so
reopening it puts them back exactly where they were, and so a location can be handed to someone
else. A file that has been damaged must say so and change nothing.

## Requirements

### Requirement: Saved view fidelity

The system SHALL save and restore the view center and side as JSON numbers, to the precision of a 64-bit float.

#### Scenario: The saved view comes back as it went in

- **WHEN** the current state is written to a file and read back
- **THEN** the view's centre and extent are the values that were saved
- **Test**: `src/fractal/persist.zig::round-trip: fromEngine → toJson → fromJson fields match`

#### Scenario: Reopening a file restores the view that was showing

- **WHEN** a saved file is applied to a running app
- **THEN** the app's view is the one the file was saved from
- **Test**: `src/fractal/persist.zig::applyToEngine: loaded state matches original engine`

### Requirement: The whole picture is saved

The system SHALL save, in one file, everything that determines the image — the view, the iteration
policy, and the complete palette including every stop, the mapping mode, its period and the interior
colour — and SHALL restore all of it together.

#### Scenario: The iteration policy, the mapping and the stop count survive the round trip

- **WHEN** the current state is written to a file and read back
- **THEN** the iteration policy, the mapping mode, its period, the number of gradient stops and the
  interior colour's red channel are all the values that were saved
- **Test**: `src/fractal/persist.zig::round-trip: fromEngine → toJson → fromJson fields match`

#### Scenario: The stops themselves and the whole interior colour survive too

- **WHEN** the current state is written to a file and read back
- **THEN** each gradient stop's position and colour, and all four channels of the interior colour,
  are the values that were saved
- **Test**: _not pinned by a test_ — the round-trip test compares the palette only by stop *count*
  and the interior colour only by its red channel, so the stop contents and the remaining channels
  are shipped but unpinned

#### Scenario: The reopened app looks like the one that saved

- **WHEN** a saved file is applied to a running app
- **THEN** the app's palette, mapping and iteration settings match the ones the file was saved from
- **Test**: _not pinned by a test_ — only the *view* half of the apply is pinned, by
  `src/fractal/persist.zig::applyToEngine: loaded state matches original engine`, which asserts the
  restored centre and side and nothing about the palette, mapping or iteration policy

### Requirement: A damaged file is refused with a named reason

The system SHALL refuse a file it cannot use, naming which way it was wrong, and SHALL leave the
running app's view and palette untouched.

#### Scenario: A file that is not a saved picture at all

- **WHEN** a file that is not valid JSON is opened
- **THEN** it is refused as invalid
- **Test**: `src/fractal/persist.zig::fromJson: not-JSON returns InvalidJson`

#### Scenario: A file missing something it needs

- **WHEN** a file without the required settings is opened
- **THEN** it is refused for the missing setting rather than filled in with guesses
- **Test**: `src/fractal/persist.zig::fromJson: empty object returns MissingField`

#### Scenario: A file whose view could never be rendered

- **WHEN** a file records a view with no extent
- **THEN** it is refused as an invalid value
- **Test**: `src/fractal/persist.zig::fromJson: side=0 returns InvalidField`

#### Scenario: A file whose palette is unusable

- **WHEN** a file records a palette with no stops, or with stops out of order
- **THEN** it is refused, naming which of the two it was
- **Test**: `src/fractal/persist.zig::fromJson: empty stops returns GradientEmpty`
- **Test**: `src/fractal/persist.zig::fromJson: unsorted stops returns GradientNotSorted`

## Notes

- The Save and Open menu items and the system file dialog they open belong to `app-shell`.
- The file carries no version field; M5 recorded "no file format versioning / migration" as a
  deliberate non-goal.
