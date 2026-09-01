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

The system SHALL save and restore the view center without loss of precision at any supported depth,
writing it as a decimal string, and SHALL still load files that carry the center as a JSON number.

#### Scenario: The saved view comes back as it went in

- **WHEN** the current state is written to a file and read back
- **THEN** the view's centre and extent are the values that were saved
- **Test**: `src/fractal/persist.zig::round-trip: fromEngine → toJson → fromJson fields match`

#### Scenario: Reopening a file restores the view that was showing

- **WHEN** a saved file is applied to a running app
- **THEN** the app's view is the one the file was saved from
- **Test**: `src/fractal/persist.zig::applyToEngine: loaded state matches original engine`

#### Scenario: A deep view saves and reopens exactly

- **WHEN** a view at side 1e-25 with a full-precision center is saved and the file reopened
- **THEN** the restored center equals the saved center exactly, digit for digit
- **Test**: `src/fractal/persist.zig::acceptance: a deep center round-trips through JSON exactly`

#### Scenario: A file written before this milestone still opens

- **WHEN** a `.fractal` file whose center is a JSON number is opened
- **THEN** it loads successfully and the view center is that number
- **Test**: `src/fractal/persist.zig::acceptance: a legacy numeric center still parses`

### Requirement: The whole picture is saved

The system SHALL save, in one file, everything that determines the image — the view, the iteration
policy, and the complete palette including every stop, the mapping mode, its period, the banded flag
and the interior colour — and SHALL restore all of it together.

#### Scenario: The iteration policy, the mapping and the stop count survive the round trip

- **WHEN** the current state is written to a file and read back
- **THEN** the iteration policy, the mapping mode, its period, the number of gradient stops and the
  interior colour's red channel are all the values that were saved
- **Test**: `src/fractal/persist.zig::round-trip: fromEngine → toJson → fromJson fields match`

#### Scenario: The stops themselves and the whole interior colour survive too

- **WHEN** the current state is written to a file and read back
- **THEN** each gradient stop's position and colour, all four channels of the interior colour, and the
  banded flag are the values that were saved
- **Test**: `src/fractal/persist.zig::acceptance: every stop and every interior channel survives a round-trip`

#### Scenario: The reopened app looks like the one that saved

- **WHEN** a saved file is applied to a running app
- **THEN** the app's palette, mapping, banded flag and interior colour match the ones the file was
  saved from
- **Test**: `src/fractal/persist.zig::acceptance: applying a loaded picture restores the whole colouring`

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
  deliberate non-goal. Deep zoom kept that non-goal: the centre is now written as a decimal string
  and **both** spellings — string and JSON number — are accepted on load, instead of a version
  field being introduced.
- The precision the centre must survive at comes from `deep-zoom`'s **Full-precision view
  coordinates**; the side stays a JSON number.
