//! Pure UI-STATE for the palette editor + mapping selector. NO ImGui/SDL/GPU/log
//! imports — this lives in the fast test tier (`zig build test`, no window/device) and
//! is fully unit-tested. `panels.zig` (the ImGui edge) owns the widget calls and reads /
//! mutates an `Editor` through these pure helpers; keeping the state model here means the
//! combo↔enum mapping and the stop add/remove/sort list ops stay testable without ImGui.
//!
//! The `Editor` mirrors the engine's editable inputs (plan A7): an ordered list of
//! gradient `Stop`s, the mapping mode (as a combo index) + `cyclic` period, and the
//! dedicated interior color (plan A5). It is a plain value: the edge holds one, mutates
//! it in place from the widgets, and — on any change — feeds `toGradient()` /`params()` /
//! `interior` to the matching engine setter (never re-iterating).
//!
//! Ordering: the editor stores stops in AUTHORING order (a position slider can push a
//! stop past its neighbors), so `toGradient()` copies + SORTS ascending by `pos` before
//! building the `Gradient` the bake requires. Editing therefore never trips the bake's
//! ascending precondition even mid-drag.
const std = @import("std");
const gradient = @import("../fractal/gradient.zig");
const mapping = @import("../fractal/mapping.zig");
const color = @import("../fractal/color.zig");
const viewport = @import("../fractal/viewport.zig");
const autoiter = @import("../fractal/autoiter.zig");
const scheme = @import("../fractal/scheme.zig");
const presets = @import("../fractal/presets.zig");
const gesture = @import("gesture.zig");

/// Reused verbatim from `color.zig` (M0). Channel order R, G, B, A. Do not redefine.
pub const Rgba8 = color.Rgba8;

/// Combo item labels, indexed by the `Editor.mode_index` (see `indexToMode`). The order
/// here IS the combo order the UI shows and MUST match `modeToIndex`.
pub const mode_items = [_][:0]const u8{ "linear", "log", "cyclic" };

/// Item labels for the INPUT-DEVICE control (M7/T6), indexed by `inputModeToIndex`. The order
/// here IS the order the control shows, so `Auto` first is what a fresh session displays
/// (`gesture.InputMode.auto` is also the default `NavState.input_mode`). Title case, unlike
/// `mode_items`: these read as three named devices rather than three formulae.
pub const input_mode_items = [_][:0]const u8{ "Auto", "Mouse", "Trackpad" };

/// The color a freshly-added stop gets: a neutral mid-gray at the palette's midpoint, so
/// a new stop is immediately visible and editable without reading undefined memory.
const new_stop_color: Rgba8 = .{ 128, 128, 128, 255 };
const new_stop_pos: f32 = 0.5;

/// Editable palette + mapping state driven by the UI. A plain value the edge owns; all
/// mutation goes through the methods below so the invariants (>= 1 stop, <= `max_stops`)
/// hold and the model stays ImGui-free and testable.
pub const Editor = struct {
    /// Authoring-order stop list (NOT necessarily ascending; `toGradient` sorts).
    stops_buf: [gradient.max_stops]gradient.Stop = undefined,
    count: usize = 0,
    /// The selected mapping mode as a combo index (see `indexToMode`).
    mode_index: c_int = 0,
    /// The `cyclic` period; ignored by linear/log (mirrors `mapping.Params`).
    period: f32 = mapping.default_period,
    /// Whether iteration bands are shown (banded) or the escape value gives a continuous
    /// gradient (smooth). Part of the colouring; surfaced by `params()` (mirrors
    /// `mapping.Params.banded`).
    banded: bool = false,
    /// The dedicated interior color (plan A5).
    interior: Rgba8 = color.interior_color,

    /// Build the editor pre-loaded with the engine's defaults: the default multi-stop
    /// palette, linear mapping, the default period, and opaque-black interior. Matches
    /// `Engine.init` so the UI and engine agree before the first edit.
    pub fn initDefault() Editor {
        var e = Editor{};
        const s = gradient.default().stops();
        @memcpy(e.stops_buf[0..s.len], s);
        e.count = s.len;
        e.mode_index = modeToIndex(.linear);
        e.period = mapping.default_period;
        e.interior = color.interior_color;
        return e;
    }

    /// The active stops, in authoring order.
    pub fn stops(self: *const Editor) []const gradient.Stop {
        return self.stops_buf[0..self.count];
    }

    /// The selected mapping mode.
    pub fn mode(self: *const Editor) mapping.Mode {
        return indexToMode(self.mode_index);
    }

    /// The mapping selection for `Engine.setMapping`.
    pub fn params(self: *const Editor) mapping.Params {
        return .{ .mode = indexToMode(self.mode_index), .period = self.period, .banded = self.banded };
    }

    /// Repopulate the editor from a colouring just loaded onto the engine, so the panel shows
    /// what was loaded rather than the values previously on display (requirement "Loading
    /// restores the palette panel"). Mirrors `ViewEditor.syncFromView`/`syncFromPolicy`: it
    /// overwrites every field. The stop count is clamped to `gradient.max_stops` (a `Gradient`
    /// never holds more, so the clamp is defensive, not lossy).
    pub fn syncFromColouring(self: *Editor, g: gradient.Gradient, p: mapping.Params, interior: Rgba8) void {
        const src = g.stops();
        const n = @min(src.len, gradient.max_stops);
        @memcpy(self.stops_buf[0..n], src[0..n]);
        self.count = n;
        self.mode_index = modeToIndex(p.mode);
        self.period = p.period;
        self.banded = p.banded;
        self.interior = interior;
    }

    /// Load a preset or scheme into the editor as an EDITABLE starting point (requirement
    /// "Built-in colouring presets" → "applying a preset replaces the colouring and stays
    /// editable"): the stops/mode/period/banded/interior all become the scheme's, and the
    /// stops can still be added/removed/recoloured afterwards. An unknown `mapping_mode`
    /// falls back to the current mode rather than trapping — presets are always valid, so
    /// this only guards a hand-built scheme.
    pub fn applyScheme(self: *Editor, s: scheme.Scheme) void {
        const n = @min(s.stops.len, gradient.max_stops);
        for (s.stops[0..n], 0..) |st, i| {
            self.stops_buf[i] = .{ .pos = st.pos, .color = .{ st.r, st.g, st.b, st.a } };
        }
        self.count = n;
        self.mode_index = modeToIndex(std.meta.stringToEnum(mapping.Mode, s.mapping_mode) orelse self.mode());
        self.period = s.mapping_period;
        self.banded = s.banded;
        self.interior = .{ s.interior_r, s.interior_g, s.interior_b, s.interior_a };
    }

    /// Build the ascending-sorted `Gradient` for `Engine.setGradient`. Copies the stops,
    /// sorts them by `pos`, and constructs the `Gradient` (whose bake requires ascending
    /// order). Requires `count >= 1`.
    pub fn toGradient(self: *const Editor) gradient.Gradient {
        var tmp: [gradient.max_stops]gradient.Stop = undefined;
        @memcpy(tmp[0..self.count], self.stops_buf[0..self.count]);
        std.mem.sort(gradient.Stop, tmp[0..self.count], {}, lessByPos);
        return gradient.Gradient.fromStops(tmp[0..self.count]);
    }

    /// Append a neutral mid-gray stop at the palette midpoint. Returns `false` (a no-op)
    /// when already at `max_stops` capacity.
    pub fn addStop(self: *Editor) bool {
        if (self.count >= gradient.max_stops) return false;
        self.stops_buf[self.count] = .{ .pos = new_stop_pos, .color = new_stop_color };
        self.count += 1;
        return true;
    }

    /// Remove the stop at `index`, shifting the tail down. Returns `false` (a no-op) when
    /// `index` is out of range or removing would drop below the one-stop minimum the bake
    /// requires.
    pub fn removeStop(self: *Editor, index: usize) bool {
        if (index >= self.count or self.count <= 1) return false;
        var i = index;
        while (i + 1 < self.count) : (i += 1) self.stops_buf[i] = self.stops_buf[i + 1];
        self.count -= 1;
        return true;
    }
};

fn lessByPos(_: void, a: gradient.Stop, b: gradient.Stop) bool {
    return a.pos < b.pos;
}

/// Editable view state for the coordinate panel in `panels.zig`. Pure value — no ImGui/SDL
/// imports. `panels.zig` reads/writes the text buffers via `igInputText` and calls the pure
/// helpers here to parse and validate.
///
/// Two representations (always kept in sync):
///   * **Center + magnification** (`center_re_buf`, `center_im_buf`, `mag_buf`)
///   * **Two opposite corners** (`corner_a_re_buf` … `corner_b_im_buf`)
/// Both are text so they can be bound directly to `igInputText`.
///
/// M6/T2: every COORDINATE buffer is `viewport.coord_text_buf_len` bytes — the one shared
/// definition of "text long enough for a full-precision center" (a 34-significant-decimal
/// signed number plus its terminator). Never hand-write a size here; a short buffer would
/// truncate a deep coordinate on the way to the screen. F1 gave the magnification field the
/// same width: it is still an `f64`, but a 32-byte buffer could not hold its own readout.
///
/// M6/T7: the NUMBER path through the coordinate buffers is `f128` end to end
/// (`writeCoordHi` / `parseCoordHi`), so a 34-decimal center typed here reaches the view
/// unrounded. Magnification and the manual iteration count deliberately stay `f64` / `u32`:
/// a magnification is a scale, not a position — its `f64` ~17 digits still pin the side to
/// far better than a pixel at every depth this app reaches.
pub const coord_buf_bytes = viewport.coord_text_buf_len;

pub const ViewEditor = struct {
    center_re_buf: [coord_buf_bytes]u8 = std.mem.zeroes([coord_buf_bytes]u8),
    center_im_buf: [coord_buf_bytes]u8 = std.mem.zeroes([coord_buf_bytes]u8),
    /// The magnification. Still an `f64` scale rather than a `ComplexHi` position — but the
    /// same WIDTH as the coordinate fields (F1): its text can be 32 characters at the depths
    /// this milestone opened and over 60 past them, and a field narrower than its own readout
    /// is a field the user cannot type back into.
    mag_buf: [coord_buf_bytes]u8 = std.mem.zeroes([coord_buf_bytes]u8),
    corner_a_re_buf: [coord_buf_bytes]u8 = std.mem.zeroes([coord_buf_bytes]u8),
    corner_a_im_buf: [coord_buf_bytes]u8 = std.mem.zeroes([coord_buf_bytes]u8),
    corner_b_re_buf: [coord_buf_bytes]u8 = std.mem.zeroes([coord_buf_bytes]u8),
    corner_b_im_buf: [coord_buf_bytes]u8 = std.mem.zeroes([coord_buf_bytes]u8),
    auto_iter: bool = true,
    manual_iter_buf: [manual_iter_buf_bytes]u8 = std.mem.zeroes([manual_iter_buf_bytes]u8),

    /// Build a `ViewEditor` pre-loaded from `view`. All text buffers are populated and
    /// null-terminated. Cannot fail — `defaultView()` is always representable.
    pub fn initFromView(view: viewport.SquareView) ViewEditor {
        var ve = ViewEditor{};
        ve.syncFromView(view);
        return ve;
    }

    /// Write all text buffers from `view`, overwriting any previous content. Called after
    /// any navigation commit so the panel stays in sync with the engine.
    pub fn syncFromView(ve: *ViewEditor, view: viewport.SquareView) void {
        const cm = view.centerMag();
        const crs = view.corners();
        // Coordinates go out at FULL precision (`writeCoordHi`); the magnification is a scale
        // and stays `f64` (`writeF64`) — see `coord_buf_bytes`.
        writeCoordHi(&ve.center_re_buf, cm.center.re);
        writeCoordHi(&ve.center_im_buf, cm.center.im);
        writeF64(&ve.mag_buf, cm.magnification);
        writeCoordHi(&ve.corner_a_re_buf, crs.min.re);
        writeCoordHi(&ve.corner_a_im_buf, crs.min.im);
        writeCoordHi(&ve.corner_b_re_buf, crs.max.re);
        writeCoordHi(&ve.corner_b_im_buf, crs.max.im);
    }

    /// Parse center + magnification buffers and build a `SquareView`. Returns null on any
    /// parse failure or if the view is degenerate.
    pub fn parseAndApplyCenterMag(ve: ViewEditor) ?viewport.SquareView {
        const re = parseCoordHi(&ve.center_re_buf) orelse return null;
        const im = parseCoordHi(&ve.center_im_buf) orelse return null;
        const mag = parseF64(&ve.mag_buf) orelse return null;
        const cm = viewport.CenterMag{
            .center = .{ .re = re, .im = im },
            .magnification = mag,
        };
        return viewport.SquareView.fromCenterMag(cm) catch null;
    }

    /// Parse corner buffers and build a `SquareView` (snapped to the larger axis). Returns
    /// null on any parse failure or if the view is degenerate.
    pub fn parseAndApplyCorners(ve: ViewEditor) ?viewport.SquareView {
        const a_re = parseCoordHi(&ve.corner_a_re_buf) orelse return null;
        const a_im = parseCoordHi(&ve.corner_a_im_buf) orelse return null;
        const b_re = parseCoordHi(&ve.corner_b_re_buf) orelse return null;
        const b_im = parseCoordHi(&ve.corner_b_im_buf) orelse return null;
        const a = viewport.ComplexHi{ .re = a_re, .im = a_im };
        const b = viewport.ComplexHi{ .re = b_re, .im = b_im };
        return viewport.SquareView.fromCorners(a, b) catch null;
    }

    /// Write the max_iter widgets from the engine's truth: `auto_iter` mirrors `policy.auto`, and
    /// `manual_iter_buf` gets `effective_iter` — the count the CURRENT buffer was actually computed
    /// with (`engine.max_iter`), NOT `policy.manual_value`.
    ///
    /// Those two differ exactly where it matters. Under Auto, `manual_value` is the number the user
    /// last pinned — stale and misleading — while `effective_iter` is what the ramp chose for this
    /// magnification, and that is the number the user must see (M7 "Visible iteration count").
    /// Under a manual pin the engine's effective count IS the pin, so the field reads back the
    /// same. Do not re-derive the ramp here: `engine.max_iter` is the single source of truth and
    /// the engine recomputes it on every iteration path.
    ///
    /// Called after a policy commit, after a REJECTED one (to restore the field), and once a frame
    /// while the field is a read-only readout, so the panel never shows a count the image was not
    /// rendered with. Cannot fail.
    pub fn syncFromPolicy(ve: *ViewEditor, policy: autoiter.IterPolicy, effective_iter: u32) void {
        ve.auto_iter = policy.auto;
        // Print into all but the LAST byte and terminate UNCONDITIONALLY. F1's lesson: a
        // terminator written only `if (s.len < buf.len)` left a full buffer unterminated, and
        // ImGui then read past the field and aborted the app. Reserving the byte makes the
        // write below always in bounds.
        const room = ve.manual_iter_buf[0 .. manual_iter_buf_bytes - 1];
        const s = std.fmt.bufPrint(room, "{d}", .{effective_iter}) catch {
            // Unreachable as sized: `room` holds the widest `u32` (asserted at comptime below).
            // Kept as a fallback rather than `unreachable` so shrinking the buffer would show a
            // wrong number instead of aborting.
            ve.manual_iter_buf[0] = '0';
            ve.manual_iter_buf[1] = 0;
            return;
        };
        ve.manual_iter_buf[s.len] = 0;
    }

    /// Parse `manual_iter_buf` as a `u32` and return a manual `IterPolicy`. Returns null if
    /// the text is not a valid number or is out of range.
    pub fn parseIterPolicy(ve: ViewEditor) ?autoiter.IterPolicy {
        const s = sliceUntilNull(&ve.manual_iter_buf);
        const v = std.fmt.parseInt(u32, s, 10) catch return null;
        return autoiter.IterPolicy.manual(v) catch null;
    }

    /// True while the iteration field must be shown read-only: the count on display is Auto's, so
    /// it is a readout, not an input (M7 "The shown count is not editable while it is automatic").
    ///
    /// Reads the CHECKBOX (`auto_iter`), not a policy, and deliberately: the checkbox is what the
    /// user just clicked, and `syncFromPolicy` keeps it mirroring the engine's policy, so within
    /// one frame the checkbox is the fresher of the two.
    pub fn iterFieldReadOnly(ve: ViewEditor) bool {
        return ve.auto_iter;
    }

    /// The policy to install when the user unchecks Auto: the count ON DISPLAY, pinned, so editing
    /// continues from whatever the ramp chose rather than from the number last typed (M7 "Turning
    /// automatic off pins what was on display").
    ///
    /// TOTAL — it cannot fail. The checkbox has already flipped by the time this runs, so there is
    /// nobody left to hand an error to. Text that names no valid count (blank, garbage, or outside
    /// `[min_manual_iter, max_manual_iter]`) falls back to `auto_exit_fallback` =
    /// `autoiter.base_max_iter` (512): the engine's own default pin AND the bottom of the auto
    /// ramp, so the user lands on a count that certainly renders instead of on a rejected policy or
    /// a zero. Unreachable through the shipped UI — the field is read-only while Auto is on, so its
    /// text is exactly what `syncFromPolicy` wrote, and the ramp's range
    /// [`base_max_iter`, `auto_max_iter`] sits inside the manual range.
    pub fn leaveAuto(ve: ViewEditor) autoiter.IterPolicy {
        return ve.parseIterPolicy() orelse auto_exit_fallback;
    }

    /// Classify what is in `manual_iter_buf` so the ImGui edge can log the right rejection without
    /// re-parsing it. Only meaningful after `parseIterPolicy` returned null; a valid entry reports
    /// `out_of_range` of its own value, which no caller asks for.
    ///
    /// Takes `ve` by POINTER because `not_a_number` borrows the buffer: use the slice before the
    /// next edit of the field.
    pub fn iterRejection(ve: *const ViewEditor) IterRejection {
        const s = sliceUntilNull(&ve.manual_iter_buf);
        const v = std.fmt.parseInt(u32, s, 10) catch return .{ .not_a_number = s };
        return .{ .out_of_range = v };
    }
};

/// Bytes in `ViewEditor.manual_iter_buf`. Sized so the widest `u32` fits WITH its terminator,
/// which is what makes `syncFromPolicy` total (asserted in the `comptime` block below).
pub const manual_iter_buf_bytes = 16;

/// What `leaveAuto` pins when the displayed text names no valid count. Built through the
/// validating constructor at comptime so it can never drift out of range.
const auto_exit_fallback: autoiter.IterPolicy = autoiter.IterPolicy.manual(autoiter.base_max_iter) catch
    @compileError("base_max_iter must itself be a valid manual pin");

/// Why an iteration entry was rejected, so the edge logs the right message. `out_of_range` carries
/// the number the user typed — exactly what `autoiter.maxIterRangeMessage` needs; `not_a_number`
/// carries the text, which is the only thing there is to name when no number was typed at all.
pub const IterRejection = union(enum) {
    not_a_number: []const u8,
    out_of_range: u32,
};

/// Significant decimal digits a shortest-round-trip `f128` can need (`viewport.max_coord_digits`
/// is 34, the DISPLAY budget; the format itself can want 36).
const max_f128_digits = 36;

/// Scratch for the decimal rendering, NOT the field: `std.fmt.float.render`'s decimal mode
/// rejects a buffer that cannot hold its conservative bound — the leading `0.`, the zero run
/// after the point AND every significant digit again (`req_bytes` in `std/fmt/float.zig`) — so
/// the 36-character reference centre demands 68 bytes even though it prints in 36. That bound
/// exceeds the text by at most the digit count, so this size renders every text that can fit a
/// coordinate field; whether it FITS is then a plain length check.
const decimal_scratch_len = viewport.coord_text_buf_len + max_f128_digits;

/// Scratch for the MAGNIFICATION's decimal rendering (`writeF64`). Not a field size: it is
/// `std.fmt.float`'s own conservative bound for an `f64` in decimal mode (347 bytes, enough
/// for `5e-324`'s 326 characters), so the render never fails for want of room and "does the
/// text fit the field" stays a plain length check on the result.
const f64_decimal_scratch_len = std.fmt.float.bufferSize(.decimal, f64);

comptime {
    // `writeCoordHi`'s exponent-form fallback must ALWAYS fit, terminator included, so its
    // `catch unreachable` really is unreachable: 53 bytes name any `f128` in scientific mode.
    std.debug.assert(viewport.coord_text_buf_len - 1 >= std.fmt.float.bufferSize(.scientific, f128));
    std.debug.assert(decimal_scratch_len >= std.fmt.float.min_buffer_size);
    // The same guarantee for `writeF64`'s fallback, on the buffer it is actually handed (F1).
    std.debug.assert(coord_buf_bytes - 1 >= std.fmt.float.bufferSize(.scientific, f64));
    // `syncFromPolicy` prints into all but the last byte so its terminator is unconditional; that
    // reserved byte is only affordable because the rest already holds the widest `u32`.
    std.debug.assert(manual_iter_buf_bytes - 1 >=
        std.fmt.comptimePrint("{d}", .{std.math.maxInt(u32)}).len);
}

/// Write ONE coordinate into a null-terminated text buffer at full `f128` precision.
///
/// SIBLING, DO NOT MERGE: `src/fractal/persist.zig`'s `writeCenter` also renders an `f128` to
/// decimal, and the two look mergeable but are NOT. They optimise for opposite things. THIS one
/// renders into a generous scratch, length-checks the ACTUAL output against the field, and re-parses
/// to PROVE the plain form is lossless — readable and verified, exactly what a live editor field
/// wants. `writeCenter` writes straight into a fixed destination and lets `render`'s conservative
/// length BOUND pick the form — cheap, bounded, no re-parse, exactly what the save path wants. On
/// the real deep-zoom residue `7.500000620552782493177801370620728e-11` they legitimately DISAGREE:
/// this one shows it plain, `writeCenter` writes the exponent form (pinned by a persist test). A
/// shared helper cannot honour both contracts at once, so they stay separate on purpose. (m8/T8
/// parked, user-confirmed.)
///
/// Form: the SHORTEST-ROUND-TRIP decimal (`0.131825904205311970493132056385139`) when it fits,
/// else the shortest-round-trip exponent form (`3.7e-33`). Both name the value exactly, so
/// `parseCoordHi` returns the identical `f128` — which is what a user pasting a coordinate back
/// depends on. A FIXED number of decimals is what does NOT work: `{d:.34}` prints on an absolute
/// 1e-34 grid, coarser than the `f128` ulp for |value| < 1 (measured with `nextAfter`: 2.41e-35 =
/// 2^-115 at the reference centre's 0.1318…, so the grid is 4.15× coarser there — NOT ~1.2e-35,
/// which is 2^-116 and would mean 116 significand bits; `f128` has 113, and the ulp changes with
/// the binade, 9.63e-35 = 2^-113 at the centre's -0.7436…). So neighbouring centres collapse onto
/// one text — walking 1000 consecutive `f128` values upward from 0.1318…, 759 of them print the
/// same 34 decimals as their neighbour — and anything below the grid prints as `0.0`.
/// `viewport.max_coord_digits` is the READOUT's digit budget (`viewport.formatCoord`, status bar),
/// not a losslessness guarantee; nothing here cuts the editable text to
/// `coordDigits(magnification)`, which would drop real digits (29 decimals at side 1e-25).
///
/// Rendering goes through `std.fmt.float.render` rather than `{d}`, deliberately. `{d}` renders
/// via a stack buffer sized for an `f64` (347 bytes) and, when a value needs more, SILENTLY
/// substitutes the literal text `"(float)"` — which fits here, so `bufPrint` would succeed and
/// put a non-number in the field. `render` writes into THIS buffer and returns
/// `error.BufferTooSmall` instead, making the fallback a branch we control.
///
/// WHICH FORM A FIELD SHOWS, measured on this code (not guessed): decimal while its text fits the
/// 63 usable bytes, i.e. `2 + zeros-after-the-point + significant digits`. A coordinate in the
/// Mandelbrot region needs ~37 and is always decimal. A FULL-length 36-digit mantissa fits down to
/// 1e-27 and takes the exponent form from 1e-28; a shorter mantissa reaches deeper (`3.7e-33` with
/// two digits is still decimal at 36 characters). So the exponent form is ORDINARY at this
/// milestone's depths — deep zooming leaves a long-mantissa residue in the other axis — NOT an
/// absurd-paste corner. It round-trips exactly and `parseCoordHi` reads it back, so copy/paste
/// keeps working; do not "fix" it by truncating digits to keep the decimal shape.
///
/// `buf` must be at least `viewport.coord_text_buf_len` bytes. The last byte is never rendered
/// into, so the terminator always has room.
fn writeCoordHi(buf: []u8, value: f128) void {
    std.debug.assert(buf.len >= viewport.coord_text_buf_len);
    // The last byte is the terminator's; nothing may render into it.
    const room = buf[0 .. buf.len - 1];
    var scratch: [decimal_scratch_len]u8 = undefined;
    if (decimalIfExact(&scratch, value, room.len)) |s| {
        @memcpy(room[0..s.len], s);
        buf[s.len] = 0;
        return;
    }
    // Never errors without a precision, and `min_buffer_size` is asserted above.
    const e = std.fmt.float.render(room, value, .{ .mode = .scientific }) catch unreachable;
    buf[e.len] = 0;
}

/// The plain decimal name of `value` — rendered into `scratch` — but ONLY if it is at most
/// `room` bytes long and parses back to the identical `f128`. Null (the caller's signal to use
/// the exponent form) when any check fails. The re-parse is what makes losslessness ENFORCED
/// rather than claimed: no text the panel shows can name a different number than the view holds.
fn decimalIfExact(scratch: []u8, value: f128, room: usize) ?[]const u8 {
    const s = std.fmt.float.render(scratch, value, .{ .mode = .decimal }) catch return null;
    if (s.len > room) return null;
    const back = std.fmt.parseFloat(f128, s) catch return null;
    return if (back == value) s else null;
}

/// Parse ONE coordinate from a null-terminated buffer at full `f128` precision. Returns null
/// on failure — the panel's "null means rejected, change nothing" convention. A buffer with no
/// terminator at all (the longest paste ImGui can leave) is parsed as its whole length; never
/// past the end.
fn parseCoordHi(buf: []const u8) ?f128 {
    const s = sliceUntilNull(buf);
    return std.fmt.parseFloat(f128, s) catch null;
}

/// Write an `f64` into a null-terminated text buffer. Used for the MAGNIFICATION only
/// (coordinates go through `writeCoordHi`, whose reserve-the-last-byte shape this copies).
///
/// F1 — TWO defects lived in the old three-line version, both of them reachable by scrolling:
///   1. It terminated CONDITIONALLY (`if (s.len < buf.len) buf[s.len] = 0`), so a text exactly
///      as long as the buffer left NO terminator. ImGui's `InputTextEx` asserts on that
///      (`"Is your input buffer properly zero-terminated?"`) and the process ABORTS — with
///      asserts compiled out it is an overflowing `memcpy` instead. So the last byte is now
///      reserved for the terminator and nothing renders into it: unconditional, like
///      `writeCoordHi`.
///   2. On overflow it wrote a bare `"0"` — terminated and safe, but a flat lie the user
///      cannot type back. The fallback is now the shortest EXPONENT form, which names the same
///      `f64` and always fits (`bufferSize(.scientific, f64)` = 53 < the field), so every
///      magnification the panel shows is a value `parseF64` returns unchanged.
///
/// `buf` must have room for the exponent form plus its terminator; `mag_buf` is
/// `coord_buf_bytes` (64) and the comptime block above pins that.
fn writeF64(buf: []u8, value: f64) void {
    std.debug.assert(buf.len >= std.fmt.float.bufferSize(.scientific, f64) + 1);
    // The last byte is the terminator's; nothing may render into it.
    const room = buf[0 .. buf.len - 1];
    var scratch: [f64_decimal_scratch_len]u8 = undefined;
    // Plain decimal while it fits the field — `0.0884` reads better than `8.84e-2`.
    if (std.fmt.float.render(&scratch, value, .{ .mode = .decimal })) |s| {
        if (s.len <= room.len) {
            @memcpy(room[0..s.len], s);
            buf[s.len] = 0;
            return;
        }
    } else |_| {}
    // Never errors: `room` is asserted above to hold the scientific form.
    const e = std.fmt.float.render(room, value, .{ .mode = .scientific }) catch unreachable;
    buf[e.len] = 0;
}

/// Parse an f64 from a null-terminated buffer. Returns null on failure.
fn parseF64(buf: []const u8) ?f64 {
    const s = sliceUntilNull(buf);
    return std.fmt.parseFloat(f64, s) catch null;
}

/// Return the slice of `buf` up to (but not including) the first null byte.
fn sliceUntilNull(buf: anytype) []const u8 {
    const arr: []const u8 = buf;
    for (arr, 0..) |b, i| {
        if (b == 0) return arr[0..i];
    }
    return arr;
}

/// Map a mapping `Mode` to its combo index. Inverse of `indexToMode`. The order matches
/// `mode_items`.
pub fn modeToIndex(m: mapping.Mode) c_int {
    return switch (m) {
        .linear => 0,
        .log => 1,
        .cyclic => 2,
    };
}

/// Map a combo index back to a mapping `Mode`. Any out-of-range index defaults to
/// `linear` (plan A6) rather than trapping, so a stray combo value can never crash the UI.
pub fn indexToMode(i: c_int) mapping.Mode {
    return switch (i) {
        0 => .linear,
        1 => .log,
        2 => .cyclic,
        else => .linear,
    };
}

/// Map a `gesture.InputMode` to its index in `input_mode_items`. Inverse of `indexToInputMode`.
///
/// This exists because the control DERIVES what it shows from the mode actually in force
/// (`NavState.input_mode`) every frame instead of keeping a second copy of it: there is no
/// widget state to drift, and a request main.zig did not install snaps visibly back.
pub fn inputModeToIndex(m: gesture.InputMode) c_int {
    return switch (m) {
        .auto => 0,
        .mouse => 1,
        .trackpad => 2,
    };
}

/// Map an item index back to a `gesture.InputMode`. Any out-of-range index falls back to
/// `.auto` — the detection default — rather than trapping, exactly as `indexToMode` falls back
/// to `linear`: a stray widget value must not be able to crash the UI, and `.auto` is the one
/// answer that is never a lie about the user's intent.
pub fn indexToInputMode(i: c_int) gesture.InputMode {
    return switch (i) {
        0 => .auto,
        1 => .mouse,
        2 => .trackpad,
        else => .auto,
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectApproxEqAbs = testing.expectApproxEqAbs;

test "acceptance: after a load the palette editor shows the loaded colouring" {
    const g = gradient.Gradient.fromStops(&[_]gradient.Stop{
        .{ .pos = 0.0, .color = .{ 1, 2, 3, 255 } },
        .{ .pos = 1.0, .color = .{ 9, 8, 7, 255 } },
    });
    var ed = Editor.initDefault();
    ed.syncFromColouring(g, .{ .mode = .cyclic, .period = 21.0, .banded = true }, .{ 5, 6, 7, 255 });

    try expectEqual(@as(usize, 2), ed.stops().len);
    try expectEqual(gradient.Rgba8{ 1, 2, 3, 255 }, ed.stops()[0].color);
    try expectEqual(mapping.Mode.cyclic, ed.mode());
    try expectApproxEqAbs(@as(f32, 21.0), ed.period, 1e-6);
    try expectEqual(true, ed.banded);
    try expectEqual(@as(u8, 5), ed.interior[0]);
}

test "acceptance: applying a preset replaces the colouring and stays editable" {
    const p = presets.all()[0];
    var ed = Editor.initDefault();
    ed.applyScheme(p.scheme);

    // The editor took the preset's colouring.
    try expectEqual(p.scheme.stops.len, ed.stops().len);
    try expectEqual(std.meta.stringToEnum(mapping.Mode, p.scheme.mapping_mode).?, ed.mode());

    // ...and it is still editable afterwards: a stop can be added (the preset is below the cap).
    const before = ed.stops().len;
    try expect(ed.addStop());
    try expectEqual(before + 1, ed.stops().len);
}

test "initDefault mirrors the engine's default palette, mapping, period, and interior" {
    const e = Editor.initDefault();
    const def = gradient.default();
    try testing.expectEqual(def.count, e.count);
    try testing.expectEqualSlices(gradient.Stop, def.stops(), e.stops());
    try testing.expectEqual(mapping.Mode.linear, e.mode());
    try testing.expectEqual(mapping.default_period, e.period);
    try testing.expectEqual(color.interior_color, e.interior);
}

test "modeToIndex and indexToMode round-trip every mapping mode" {
    inline for (.{ mapping.Mode.linear, .log, .cyclic }) |m| {
        try testing.expectEqual(m, indexToMode(modeToIndex(m)));
    }
}

test "indexToMode defaults an out-of-range index to linear" {
    try testing.expectEqual(mapping.Mode.linear, indexToMode(7));
    try testing.expectEqual(mapping.Mode.linear, indexToMode(-1));
}

test "params reflects the selected mode index and period" {
    var e = Editor.initDefault();
    e.mode_index = modeToIndex(.cyclic);
    e.period = 17.0;
    const p = e.params();
    try testing.expectEqual(mapping.Mode.cyclic, p.mode);
    try testing.expectEqual(@as(f32, 17.0), p.period);
}

test "addStop appends one stop and reports success while there is room" {
    var e = Editor.initDefault();
    const before = e.count;
    try testing.expect(e.addStop());
    try testing.expectEqual(before + 1, e.count);
}

test "addStop refuses (no-op) once at max_stops capacity" {
    var e = Editor{ .count = gradient.max_stops };
    try testing.expect(!e.addStop());
    try testing.expectEqual(gradient.max_stops, e.count);
}

test "removeStop deletes the indexed stop and shifts the tail down" {
    var e = Editor{};
    e.stops_buf[0] = .{ .pos = 0.0, .color = .{ 1, 0, 0, 255 } };
    e.stops_buf[1] = .{ .pos = 0.5, .color = .{ 2, 0, 0, 255 } };
    e.stops_buf[2] = .{ .pos = 1.0, .color = .{ 3, 0, 0, 255 } };
    e.count = 3;
    try testing.expect(e.removeStop(1)); // drop the middle stop
    try testing.expectEqual(@as(usize, 2), e.count);
    try testing.expectEqual(@as(f32, 0.0), e.stops()[0].pos);
    try testing.expectEqual(@as(f32, 1.0), e.stops()[1].pos); // tail shifted into place
}

test "removeStop refuses to drop below the one-stop minimum" {
    var e = Editor{};
    e.stops_buf[0] = .{ .pos = 0.0, .color = .{ 1, 2, 3, 255 } };
    e.count = 1;
    try testing.expect(!e.removeStop(0));
    try testing.expectEqual(@as(usize, 1), e.count);
}

test "removeStop refuses an out-of-range index" {
    var e = Editor.initDefault();
    const before = e.count;
    try testing.expect(!e.removeStop(before));
    try testing.expectEqual(before, e.count);
}

test "toGradient sorts out-of-order stops ascending by position" {
    var e = Editor{};
    e.stops_buf[0] = .{ .pos = 0.9, .color = .{ 9, 0, 0, 255 } };
    e.stops_buf[1] = .{ .pos = 0.1, .color = .{ 1, 0, 0, 255 } };
    e.stops_buf[2] = .{ .pos = 0.5, .color = .{ 5, 0, 0, 255 } };
    e.count = 3;
    const g = e.toGradient();
    const s = g.stops();
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqual(@as(f32, 0.1), s[0].pos);
    try testing.expectEqual(@as(f32, 0.5), s[1].pos);
    try testing.expectEqual(@as(f32, 0.9), s[2].pos);
}

test "toGradient preserves the stop count" {
    const e = Editor.initDefault();
    try testing.expectEqual(e.count, e.toGradient().count);
}

test "mode_items order matches the combo index mapping" {
    try testing.expectEqualStrings("linear", mode_items[@intCast(modeToIndex(.linear))]);
    try testing.expectEqualStrings("log", mode_items[@intCast(modeToIndex(.log))]);
    try testing.expectEqualStrings("cyclic", mode_items[@intCast(modeToIndex(.cyclic))]);
}

// ─── Input-device control tests (M7/T6) ───────────────────────────────────────
//
// The panel's control is untestable (`panels.zig` imports `c.zig`), so what these pin is the
// only part of it that CAN be wrong silently: the item the user clicks and the `InputMode` that
// reaches `gesture.classifyWheel`. A label table one place out of step with the mapping would
// hand the classifier the wrong device and leave every gesture test green.

/// Index of the item whose LABEL is `label` — what the user actually clicks. Test-only: the
/// widget code goes the other way (mode → index), so a test that started from the index could
/// not tell an off-by-one label order from a correct one.
fn indexOfInputModeLabel(label: []const u8) c_int {
    for (input_mode_items, 0..) |item, i| {
        if (std.mem.eql(u8, item, label)) return @intCast(i);
    }
    return -1;
}

test "each input-device label sits at the index its mode maps to" {
    try testing.expectEqualStrings("Auto", input_mode_items[@intCast(inputModeToIndex(.auto))]);
    try testing.expectEqualStrings("Mouse", input_mode_items[@intCast(inputModeToIndex(.mouse))]);
    try testing.expectEqualStrings("Trackpad", input_mode_items[@intCast(inputModeToIndex(.trackpad))]);
}

test "the input-device list offers exactly one item per input mode" {
    try testing.expectEqual(@typeInfo(gesture.InputMode).@"enum".fields.len, input_mode_items.len);
}

test "the item the control shows before the user picks anything is Auto" {
    try testing.expectEqual(gesture.InputMode.auto, indexToInputMode(0));
    try testing.expectEqualStrings("Auto", input_mode_items[0]);
}

test "every input mode round-trips through its item index" {
    for ([_]gesture.InputMode{ .auto, .mouse, .trackpad }) |m| {
        try testing.expectEqual(m, indexToInputMode(inputModeToIndex(m)));
    }
}

test "an out-of-range input-device index falls back to auto rather than trapping" {
    for ([_]c_int{ -1, 3, 99 }) |i| {
        try testing.expectEqual(gesture.InputMode.auto, indexToInputMode(i));
    }
}

test "picking the Mouse item makes a fractional wheel event zoom" {
    const fractional = gesture.WheelSample{ .x = 0.0, .y = -0.317, .integer_y = 0 };
    // Left to detect for itself the app would read this as a trackpad swipe...
    try testing.expectEqual(gesture.WheelAction.pan, gesture.classifyWheel(fractional, .auto));

    // ...but the item labelled "Mouse" declares a mouse, and the declaration wins.
    const declared = indexToInputMode(indexOfInputModeLabel("Mouse"));
    var acc = gesture.Accumulator{};
    acc.addWheel(fractional, declared);
    const intent = acc.take() orelse return error.TestUnexpectedNull;
    try testing.expect(intent.zoom_factor != null);
}

test "picking the Trackpad item makes a whole-tick wheel event pan" {
    const notch = gesture.WheelSample{ .x = 0.0, .y = -1.0, .integer_y = -1 };
    // Left to detect for itself the app would read this as a mouse notch...
    try testing.expectEqual(gesture.WheelAction.zoom, gesture.classifyWheel(notch, .auto));

    // ...but the item labelled "Trackpad" declares a trackpad, and the declaration wins.
    const declared = indexToInputMode(indexOfInputModeLabel("Trackpad"));
    var acc = gesture.Accumulator{};
    acc.addWheel(notch, declared);
    const intent = acc.take() orelse return error.TestUnexpectedNull;
    try testing.expect(intent.zoom_factor == null);
    try testing.expect(intent.pan_dy != 0.0);
}

// ─── ViewEditor tests ─────────────────────────────────────────────────────────

test "ViewEditor.initFromView round-trips through parseAndApplyCenterMag" {
    const view = viewport.SquareView.defaultView();
    const ve = ViewEditor.initFromView(view);
    const parsed = ve.parseAndApplyCenterMag() orelse return error.TestUnexpectedNull;
    try testing.expectApproxEqAbs(@as(f64, -0.75), parsed.center_re, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), parsed.center_im, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 3.5), parsed.side, 1e-10);
    // magnification round-trip
    try testing.expectApproxEqRel(view.magnification(), parsed.magnification(), 1e-12);
}

test "ViewEditor.initFromView round-trips through parseAndApplyCorners" {
    const view = viewport.SquareView.defaultView();
    const ve = ViewEditor.initFromView(view);
    const parsed = ve.parseAndApplyCorners() orelse return error.TestUnexpectedNull;
    const orig_corners = view.corners();
    const new_corners = parsed.corners();
    try testing.expectApproxEqAbs(orig_corners.min.re, new_corners.min.re, 1e-10);
    try testing.expectApproxEqAbs(orig_corners.min.im, new_corners.min.im, 1e-10);
    try testing.expectApproxEqAbs(orig_corners.max.re, new_corners.max.re, 1e-10);
    try testing.expectApproxEqAbs(orig_corners.max.im, new_corners.max.im, 1e-10);
}

test "ViewEditor.parseAndApplyCenterMag returns null on bad buffer" {
    var ve = ViewEditor.initFromView(viewport.SquareView.defaultView());
    @memset(&ve.center_re_buf, 0);
    @memcpy(ve.center_re_buf[0..12], "not_a_number");
    ve.center_re_buf[12] = 0;
    try testing.expect(ve.parseAndApplyCenterMag() == null);
}

test "ViewEditor.parseAndApplyCorners returns null on bad buffer" {
    var ve = ViewEditor.initFromView(viewport.SquareView.defaultView());
    @memset(&ve.corner_a_re_buf, 0);
    @memcpy(ve.corner_a_re_buf[0..12], "not_a_number");
    ve.corner_a_re_buf[12] = 0;
    try testing.expect(ve.parseAndApplyCorners() == null);
}

test "ViewEditor.syncFromView updates buffers to the new view" {
    const view1 = viewport.SquareView.defaultView();
    var ve = ViewEditor.initFromView(view1);
    const view2 = viewport.SquareView{ .center_re = 0.25, .center_im = -0.5, .side = 0.5 };
    ve.syncFromView(view2);
    const parsed = ve.parseAndApplyCenterMag() orelse return error.TestUnexpectedNull;
    try testing.expectApproxEqAbs(@as(f64, 0.25), parsed.center_re, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, -0.5), parsed.center_im, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.5), parsed.side, 1e-10);
}

test "every ViewEditor coordinate buffer is sized from viewport's shared constant" {
    const ve = ViewEditor{};
    inline for (.{
        ve.center_re_buf,
        ve.center_im_buf,
        ve.corner_a_re_buf,
        ve.corner_a_im_buf,
        ve.corner_b_re_buf,
        ve.corner_b_im_buf,
    }) |buf| {
        try testing.expectEqual(viewport.coord_text_buf_len, buf.len);
    }
}

test "a ViewEditor coordinate buffer holds a full-precision center plus a terminator" {
    // The 34-significant-decimal center M6 must be able to show: 36 characters of text.
    const typed = "-0.743643887037158704752191506114774";
    var ve = ViewEditor.initFromView(viewport.SquareView.defaultView());
    ve.center_re_buf = std.mem.zeroes(@TypeOf(ve.center_re_buf));
    @memcpy(ve.center_re_buf[0..typed.len], typed);
    try testing.expect(typed.len < ve.center_re_buf.len);
    try testing.expectEqualStrings(typed, sliceUntilNull(&ve.center_re_buf));
}

// ─── ViewEditor full-precision coordinate tests (M6/T7) ───────────────────────

/// The milestone's reference centre, as the user would type it: 33 decimals of a
/// seahorse-valley boundary point. Text, not a float literal, so the tests compare against
/// exactly what `parseFloat` makes of the typed characters.
const deep_re_text = "-0.743643887037158704752191506114774";
const deep_im_text = "0.131825904205311970493132056385139";

/// Every depth the panel must stay lossless across: home, the middle of the range, and the
/// `viewport.precision_floor_side` floor.
const depth_sides = [_]f64{ 3.5, 1.0e-3, 1.0e-9, 1.0e-15, 1.0e-20, 1.0e-25, 1.0e-30 };

fn deepView(side: f64) !viewport.SquareView {
    return viewport.SquareView.fromCenterSide(.{
        .re = try std.fmt.parseFloat(f128, deep_re_text),
        .im = try std.fmt.parseFloat(f128, deep_im_text),
    }, side);
}

/// Decimals in a fixed-notation number text (0 when there is no decimal point).
fn decimalsOf(text: []const u8) usize {
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return 0;
    return text.len - dot - 1;
}

fn typeInto(buf: []u8, text: []const u8) void {
    @memset(buf, 0);
    @memcpy(buf[0..text.len], text);
}

/// The `f128` `k` steps from `x` along its own bit pattern. One zoom or pan step moves a centre
/// by a handful of ulps, and such a value is NOT a short decimal literal — so it round-trips
/// through text only if the writer emits a shortest-round-trip form. Fixtures parsed from typed
/// decimals cannot tell an exact writer from a 34-decimal one; these can.
fn ulpShift(x: f128, k: i32) f128 {
    const bits: u128 = @bitCast(x);
    const moved = if (k >= 0) bits + @as(u128, @intCast(k)) else bits - @as(u128, @intCast(-k));
    return @bitCast(moved);
}

/// Offsets applied to the reference centre: 0 is the number a user types, the others are the
/// neighbouring `f128` values real navigation actually lands on.
const ulp_offsets = [_]i32{ 0, 1, -1, 3, -7 };

/// Centres the panel must carry losslessly. Beyond the reference point: zooming deep along the
/// real axis leaves `center_im` a tiny NON-ZERO residue, and zooming toward the origin does the
/// same to `center_re` — magnitudes whose plain-decimal text is far longer than the buffer.
const centre_bases = [_][2][]const u8{
    .{ deep_re_text, deep_im_text },
    .{ deep_re_text, "3.7e-33" },
    .{ "1.9e-31", deep_im_text },
};

/// Magnitudes one coordinate FIELD must survive: the residues above, a centre a real deep-zoom
/// trajectory toward the real axis produced (34 digits at 1e-11), a full-length mantissa past the
/// exponent-form crossover, ordinary depth, the home centre, and pasted absurdities at both ends.
const magnitude_texts = [_][]const u8{
    "1e-4900",          "-3.7e-33",
    "1.9e-31",          "7.500000620552782493177801370620728e-11",
    exponent_form_text, "1e-20",
    deep_im_text,       deep_re_text,
    "-0.75",            "1e30",
    "-1e300",           "1e4900",
};

/// A full-length mantissa at a depth this milestone reaches: 36 significant digits at 1e-28, whose
/// decimal spelling is 64 characters — one past the field — so it is written in exponent form.
const exponent_form_text = "1.23456789012345678901234567890123456e-28";

test "a 30-decimal centre typed into the panel applies exactly, unrounded" {
    var ve = ViewEditor.initFromView(try deepView(1.0e-25));
    typeInto(&ve.center_re_buf, deep_re_text);

    const applied = ve.parseAndApplyCenterMag() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(try std.fmt.parseFloat(f128, deep_re_text), applied.center_re);
}

test "syncFromView writes a centre that parses back to the identical f128 at every depth" {
    for (centre_bases) |base| {
        const re0 = try std.fmt.parseFloat(f128, base[0]);
        const im0 = try std.fmt.parseFloat(f128, base[1]);
        for (ulp_offsets) |k| {
            const center: viewport.ComplexHi = .{ .re = ulpShift(re0, k), .im = ulpShift(im0, k) };
            for (depth_sides) |side| {
                const view = try viewport.SquareView.fromCenterSide(center, side);
                var ve = ViewEditor{};
                ve.syncFromView(view);
                const applied = ve.parseAndApplyCenterMag() orelse return error.TestUnexpectedResult;
                try testing.expectEqual(view.center_re, applied.center_re);
                try testing.expectEqual(view.center_im, applied.center_im);
            }
        }
    }
}

test "a coordinate whose decimal text cannot fit the field still round-trips exactly" {
    for (magnitude_texts) |text| {
        const value = try std.fmt.parseFloat(f128, text);
        var buf = std.mem.zeroes([coord_buf_bytes]u8);
        writeCoordHi(&buf, value);
        const back = parseCoordHi(&buf) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(value, back);
    }
}

test "a deep coordinate too long for the field is shown in exponent form, and exactly" {
    // The exponent branch is reached by ordinary deep navigation, not only by a pasted absurdity,
    // so it needs its own pin: the form must actually be taken AND still name the value.
    const value = try std.fmt.parseFloat(f128, exponent_form_text);
    var buf = std.mem.zeroes([coord_buf_bytes]u8);
    writeCoordHi(&buf, value);
    try testing.expect(std.mem.indexOfScalar(u8, sliceUntilNull(&buf), 'e') != null);
    try testing.expectEqual(value, parseCoordHi(&buf) orelse return error.TestUnexpectedResult);
}

test "no coordinate is ever displayed as the float formatter's placeholder text" {
    // `{d}` renders a value needing over 347 bytes as the literal `"(float)"`, silently. That
    // fits a coordinate field, so it would reach the screen as a number the user cannot paste.
    for (magnitude_texts) |text| {
        var buf = std.mem.zeroes([coord_buf_bytes]u8);
        writeCoordHi(&buf, try std.fmt.parseFloat(f128, text));
        try testing.expect(std.mem.indexOf(u8, sliceUntilNull(&buf), "(float)") == null);
    }
}

test "a centre finer than the display's decimal grid is shown as itself, never as zero" {
    // 1e-35 is below one step of a 34-decimal grid, so a fixed-decimal writer prints "-0.0" and
    // the panel would hand `main.zig` a centre of exactly zero for a non-zero view.
    const tiny = try std.fmt.parseFloat(f128, "-1e-35");
    var ve = ViewEditor{};
    ve.syncFromView(try viewport.SquareView.fromCenterSide(.{ .re = -0.75, .im = tiny }, 1.0e-30));
    const applied = ve.parseAndApplyCenterMag() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(tiny, applied.center_im);
}

test "the displayed centre gains decimals with depth and never passes the 34-digit cap" {
    var home = ViewEditor.initFromView(viewport.SquareView.defaultView());
    var deep = ViewEditor.initFromView(try deepView(1.0e-25));
    const home_decimals = decimalsOf(sliceUntilNull(&home.center_re_buf));
    const deep_decimals = decimalsOf(sliceUntilNull(&deep.center_re_buf));
    try testing.expect(home_decimals < deep_decimals);
    try testing.expect(deep_decimals <= viewport.max_coord_digits);
}

test "a shallow view's centre is displayed without trailing-zero padding" {
    var ve = ViewEditor.initFromView(viewport.SquareView.defaultView());
    try testing.expectEqualStrings("-0.75", sliceUntilNull(&ve.center_re_buf));
    try testing.expectEqualStrings("0", sliceUntilNull(&ve.center_im_buf));
}

test "syncFromView null-terminates every coordinate buffer inside its bounds" {
    var ve = ViewEditor{};
    ve.syncFromView(try deepView(1.0e-30));
    inline for (.{
        "center_re_buf",   "center_im_buf",   "mag_buf",         "corner_a_re_buf",
        "corner_a_im_buf", "corner_b_re_buf", "corner_b_im_buf",
    }) |name| {
        const buf = &@field(ve, name);
        try testing.expect(std.mem.indexOfScalar(u8, buf, 0) != null);
    }
}

test "an absurd centre magnitude is displayed in a form that still round-trips, not overrun" {
    // `{d}` of 1e30 is 31 positional digits, and of 1e-300 over 300 — past the buffer, so the
    // exponent fallback must keep the value truthful rather than write past the end or lie.
    var ve = ViewEditor{};
    ve.syncFromView(try viewport.SquareView.fromCenterSide(.{ .re = 1.0e30, .im = -1.0e30 }, 1.0));
    const text = sliceUntilNull(&ve.center_re_buf);
    try testing.expect(text.len < ve.center_re_buf.len);
    try testing.expectEqual(@as(f128, 1.0e30), try std.fmt.parseFloat(f128, text));
}

test "a paste that fills the whole buffer with no terminator is parsed within bounds" {
    var ve = ViewEditor.initFromView(viewport.SquareView.defaultView());
    // What ImGui can leave behind at most: every byte a digit, no null anywhere.
    @memset(&ve.center_re_buf, '1');
    ve.center_re_buf[1] = '.';
    const applied = ve.parseAndApplyCenterMag() orelse return error.TestUnexpectedResult;
    const whole = try std.fmt.parseFloat(f128, &ve.center_re_buf);
    try testing.expectEqual(whole, applied.center_re);
}

test "a paste longer than the buffer is rejected or truncated, never applied past the end" {
    const too_long = "-0.1234567890123456789012345678901234567890123456789012345678901234567890";
    var ve = ViewEditor.initFromView(viewport.SquareView.defaultView());
    // ImGui copies at most `buf_size - 1` bytes and terminates; mirror that exactly.
    const keep = ve.center_re_buf.len - 1;
    @memset(&ve.center_re_buf, 0);
    @memcpy(ve.center_re_buf[0..keep], too_long[0..keep]);
    const applied = ve.parseAndApplyCenterMag() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(try std.fmt.parseFloat(f128, too_long[0..keep]), applied.center_re);
    try testing.expectEqual(@as(u8, 0), ve.center_re_buf[ve.center_re_buf.len - 1]);
}

test "parseAndApplyCorners at depth keeps the centre's digits to within an f128 ulp" {
    const view = try deepView(1.0e-25);
    var ve = ViewEditor.initFromView(view);
    const applied = ve.parseAndApplyCorners() orelse return error.TestUnexpectedResult;
    // The corner text is lossless; re-centring is `(a + b) / 2`, so the recovered centre can
    // land one `f128` ulp (~1.4e-34 here) off — nine orders of magnitude finer than the f64
    // rounding this milestone exists to escape.
    const one_ulp: f128 = std.math.floatEps(f128);
    try testing.expectApproxEqRel(view.center_re, applied.center_re, one_ulp);
    try testing.expectApproxEqRel(view.center_im, applied.center_im, one_ulp);
}

test "parseAndApplyCorners at depth recovers a square side to the f128 differencing limit" {
    const view = try deepView(1.0e-25);
    var ve = ViewEditor.initFromView(view);
    const applied = ve.parseAndApplyCorners() orelse return error.TestUnexpectedResult;
    // The corner TEXT is exact; the residual error is intrinsic to describing a 1e-25 span by
    // two absolute coordinates near 0.74, whose `f128` ulp is ~1.4e-34 — i.e. ~3e-10 of the
    // side. Differencing the corners without text (`view.corners()` in `f128`) gives the same
    // 2.8e-10, so this is `SquareView`'s geometry, not the panel's formatting.
    try testing.expectApproxEqRel(view.side, applied.side, 1e-8);
}

test "the centre a deep view shows is not the f64 rounding of itself" {
    var ve = ViewEditor.initFromView(try deepView(1.0e-25));
    const applied = ve.parseAndApplyCenterMag() orelse return error.TestUnexpectedResult;
    const rounded: f128 = @as(f64, @floatCast(applied.center_re));
    try testing.expect(applied.center_re != rounded);
}

test "a non-numeric magnification is rejected, leaving no view to apply" {
    var ve = ViewEditor.initFromView(viewport.SquareView.defaultView());
    typeInto(&ve.mag_buf, "wide");
    try testing.expect(ve.parseAndApplyCenterMag() == null);
}

test "the magnification field still round-trips at the precision floor" {
    const view = try deepView(viewport.precision_floor_side);
    var ve = ViewEditor.initFromView(view);
    const applied = ve.parseAndApplyCenterMag() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(view.magnification(), applied.magnification());
}

// ─── F1: the magnification field's terminator and its width ───────────────────
//
// The defect these pin: `writeF64` terminated CONDITIONALLY, so a magnification whose text
// was exactly as long as `mag_buf` left the field unterminated — ImGui's `InputTextEx`
// asserts on that and the process aborts. Every boundary below is MEASURED from the buffer's
// own length and the formatter's own output, never quoted: a fixture picked by hand is how
// this bug survived a whole milestone of tests that named `mag_buf`.

/// The plain-decimal text length of `value`, measured through the same renderer the field
/// uses. The tests derive their fixtures from this rather than counting characters by eye.
fn decimalTextLen(value: f64) usize {
    var scratch: [f64_decimal_scratch_len]u8 = undefined;
    const s = std.fmt.float.render(&scratch, value, .{ .mode = .decimal }) catch
        return f64_decimal_scratch_len;
    return s.len;
}

/// A magnification whose plain-decimal text is EXACTLY `len` characters long, found by
/// walking the powers of ten and measuring each one. Null when no power of ten in `f64`'s
/// range renders at that length. Derived, so it follows `mag_buf` if the buffer is ever
/// resized again.
fn magnificationWithTextLen(len: usize) ?f64 {
    var e: i32 = -320;
    while (e <= 308) : (e += 1) {
        const m = std.math.pow(f64, 10.0, @as(f64, @floatFromInt(e)));
        if (decimalTextLen(m) == len) return m;
    }
    return null;
}

/// The magnification text the field currently holds, as the C string ImGui would read.
fn magText(ve: *const ViewEditor) []const u8 {
    return sliceUntilNull(&ve.mag_buf);
}

/// The exponent-form text length of `value`, measured through the same renderer the field
/// falls back to when the plain decimal spelling will not fit. Paired with `decimalTextLen`
/// so a test can name the exact index the terminator is REQUIRED to land on.
fn scientificTextLen(value: f64) usize {
    var scratch: [f64_decimal_scratch_len]u8 = undefined;
    const s = std.fmt.float.render(&scratch, value, .{ .mode = .scientific }) catch
        return f64_decimal_scratch_len;
    return s.len;
}

/// The index the terminator must land on for `value` in a `buf_len`-byte field: the plain
/// decimal spelling's length while that spelling fits BESIDE a terminator, else the exponent
/// spelling's. Both lengths are measured through the field's own renderer, never quoted.
fn requiredTerminatorIndex(value: f64, buf_len: usize) usize {
    const decimal = decimalTextLen(value);
    return if (decimal <= buf_len - 1) decimal else scientificTextLen(value);
}

/// Write `value` into a field PRE-FILLED with a non-zero byte, and return where the
/// terminator ended up (null when `writeF64` left none — the state that aborts ImGui).
///
/// The pre-fill is the whole point: `mag_buf` is `std.mem.zeroes`-initialised, so a test that
/// only asks whether SOME zero byte exists is satisfied by the initialiser and passes against
/// a `writeF64` that writes nothing at all. Filling with `'x'` first means only a terminator
/// this code actually wrote can answer.
fn terminatorIndexAfterWrite(ve: *ViewEditor, value: f64) ?usize {
    @memset(&ve.mag_buf, 'x');
    writeF64(&ve.mag_buf, value);
    return std.mem.indexOfScalar(u8, &ve.mag_buf, 0);
}

test "the magnification field is terminated when its text exactly fills the buffer" {
    var ve = ViewEditor{};
    const exact = magnificationWithTextLen(ve.mag_buf.len) orelse return error.TestUnexpectedResult;
    // The fixture is the exactly-full case because it was MEASURED to be, not assumed.
    try testing.expectEqual(ve.mag_buf.len, decimalTextLen(exact));
    // Over a non-zero pre-fill, so the terminator has to have been written here, and at the
    // END OF THE TEXT: no terminator anywhere is what aborts ImGui's `InputTextEx`, and one
    // in the wrong place truncates or leaks the field's tail into the readout.
    const idx = terminatorIndexAfterWrite(&ve, exact) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(requiredTerminatorIndex(exact, ve.mag_buf.len), idx);
}

test "the magnification field is terminated one character either side of exactly full" {
    var ve = ViewEditor{};
    // `len - 1` is the case the UNCONDITIONAL write exists for: the decimal text exactly
    // fills `room`, so `buf[s.len]` is the field's last byte and a `s.len < room.len` guard
    // would skip it. `len + 1` is the first text too long to spell in full.
    for ([_]usize{ ve.mag_buf.len - 1, ve.mag_buf.len + 1 }) |len| {
        const m = magnificationWithTextLen(len) orelse return error.TestUnexpectedResult;
        const idx = terminatorIndexAfterWrite(&ve, m) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(requiredTerminatorIndex(m, ve.mag_buf.len), idx);
    }
}

test "a magnification too long to spell in full is shown in exponent form, not as a bare zero" {
    var ve = ViewEditor{};
    const long = magnificationWithTextLen(ve.mag_buf.len + 1) orelse return error.TestUnexpectedResult;
    writeF64(&ve.mag_buf, long);
    // The old fallback wrote "0" — a terminated, safe, flatly wrong readout that also cannot
    // be typed back. The field must still NAME the magnification it stands for.
    try testing.expectEqual(long, parseF64(&ve.mag_buf) orelse return error.TestUnexpectedResult);
}

test "mag_buf is sized from the same shared constant as the coordinate buffers" {
    const ve = ViewEditor{};
    try testing.expectEqual(coord_buf_bytes, ve.mag_buf.len);
}

test "every magnification the zoom ladder can reach stays terminated and re-enterable" {
    // The whole 2x notch ladder through the real view model, in BOTH directions, from views
    // 3.5·2^40 wide (past the widest a wheel can now reach, so a typed magnification is
    // covered too) down to 3.5·2^-300. M1's crash notch — 43 out from home, side 3.0786e13 —
    // and the zoom-in state at side 1.08e-32 both fall on this ladder by construction.
    var ve = ViewEditor{};
    var k: i32 = -300;
    while (k <= 40) : (k += 1) {
        const side = std.math.ldexp(@as(f64, 3.5), k);
        const view = try viewport.SquareView.fromCenterSide(.{ .re = -0.75, .im = 0.0 }, side);
        ve.syncFromView(view);
        // Terminated inside its own bounds…
        try testing.expect(std.mem.indexOfScalar(u8, &ve.mag_buf, 0) != null);
        // …and what it shows is a name for the magnification it holds, short enough to type
        // back into the field it came from.
        try testing.expect(magText(&ve).len < ve.mag_buf.len);
        try testing.expectEqual(view.magnification(), parseF64(&ve.mag_buf) orelse return error.TestUnexpectedResult);
    }
}

test "the magnifications M1 crashed the app with are terminated and re-enterable" {
    // Typed straight into the field, these are the one-step triggers M1 recorded: the first
    // reached the unterminated (aborting) state, the second the bare-"0" state.
    var ve = ViewEditor{};
    for ([_]f64{ 2.2968209681316936e-14, 1.4355131050823085e-15 }) |mag| {
        writeF64(&ve.mag_buf, mag);
        try testing.expect(std.mem.indexOfScalar(u8, &ve.mag_buf, 0) != null);
        try testing.expectEqual(mag, parseF64(&ve.mag_buf) orelse return error.TestUnexpectedResult);
    }
}

test "ViewEditor.parseIterPolicy parses valid number" {
    var ve = ViewEditor{};
    @memcpy(ve.manual_iter_buf[0..3], "256");
    ve.manual_iter_buf[3] = 0;
    const policy = ve.parseIterPolicy() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u32, 256), policy.manual_value);
    try testing.expectEqual(false, policy.auto);
}

test "ViewEditor.parseIterPolicy returns null on invalid text" {
    var ve = ViewEditor{};
    @memcpy(ve.manual_iter_buf[0..3], "abc");
    ve.manual_iter_buf[3] = 0;
    try testing.expect(ve.parseIterPolicy() == null);
}

test "ViewEditor.syncFromPolicy round-trips a manual policy through parseIterPolicy" {
    var ve = ViewEditor{};
    ve.syncFromPolicy(try autoiter.IterPolicy.manual(512), 512);
    const parsed = ve.parseIterPolicy() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u32, 512), parsed.manual_value);
}

test "ViewEditor.syncFromPolicy mirrors the auto flag" {
    var ve = ViewEditor{ .auto_iter = false };
    ve.syncFromPolicy(.{ .auto = true }, autoiter.base_max_iter);
    try testing.expect(ve.auto_iter);
}

test "ViewEditor.syncFromPolicy overwrites garbage text with the policy value" {
    var ve = ViewEditor{};
    @memcpy(ve.manual_iter_buf[0..3], "abc");
    ve.manual_iter_buf[3] = 0;
    ve.syncFromPolicy(try autoiter.IterPolicy.manual(64), 64);
    const parsed = ve.parseIterPolicy() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u32, 64), parsed.manual_value);
}

// ── M7: the iteration count on display is the one in use ───────────────────────────────

test "ViewEditor.syncFromPolicy shows the effective count even when the policy names another" {
    var ve = ViewEditor{};
    ve.syncFromPolicy(try autoiter.IterPolicy.manual(256), 4096);
    try testing.expectEqualStrings("4096", sliceUntilNull(&ve.manual_iter_buf));
}

test "ViewEditor.syncFromPolicy always leaves manual_iter_buf null-terminated" {
    var ve = ViewEditor{};
    // Widest first, so every later (shorter) write has stale digits behind its terminator.
    const counts = [_]u32{
        std.math.maxInt(u32),
        autoiter.max_manual_iter,
        autoiter.auto_max_iter,
        autoiter.base_max_iter,
        autoiter.min_manual_iter,
        1,
        0,
    };
    for (counts) |count| {
        ve.syncFromPolicy(.{ .auto = true }, count);
        try testing.expect(std.mem.indexOfScalar(u8, &ve.manual_iter_buf, 0) != null);
        var expected: [manual_iter_buf_bytes]u8 = undefined;
        try testing.expectEqualStrings(
            try std.fmt.bufPrint(&expected, "{d}", .{count}),
            sliceUntilNull(&ve.manual_iter_buf),
        );
    }
}

test "ViewEditor.leaveAuto falls back to the base count when the text names no valid count" {
    // Blank, garbage, below `min_manual_iter`, above `max_manual_iter`, and too wide for a u32.
    for ([_][]const u8{ "", "abc", "15", "16777217", "99999999999" }) |text| {
        var ve = ViewEditor{};
        @memcpy(ve.manual_iter_buf[0..text.len], text);
        ve.manual_iter_buf[text.len] = 0;
        const pinned = ve.leaveAuto();
        try testing.expect(!pinned.auto);
        try testing.expectEqual(autoiter.base_max_iter, pinned.manual_value);
        // In range by construction: the validating constructor accepts what we fell back to.
        _ = try autoiter.IterPolicy.manual(pinned.manual_value);
    }
}

test "ViewEditor.iterRejection reports the number the user typed when it is out of range" {
    var ve = ViewEditor{};
    @memcpy(ve.manual_iter_buf[0..2], "15");
    ve.manual_iter_buf[2] = 0;
    try testing.expectEqual(@as(u32, 15), ve.iterRejection().out_of_range);
}

test "ViewEditor.iterRejection reports the offending text when it is not a number at all" {
    var ve = ViewEditor{};
    @memcpy(ve.manual_iter_buf[0..4], "12x4");
    ve.manual_iter_buf[4] = 0;
    try testing.expectEqualStrings("12x4", ve.iterRejection().not_a_number);
}

// ── Requirement: Visible iteration count (M7) ─────────────────────────────────────────

test "acceptance: the auto policy displays the ramp's count, not the last pinned one" {
    var ve = ViewEditor{};
    // The user pinned 256 earlier in the session.
    ve.syncFromPolicy(try autoiter.IterPolicy.manual(256), 256);
    try testing.expectEqualStrings("256", sliceUntilNull(&ve.manual_iter_buf));

    // They switch back to Auto at a depth whose ramp value is 4096. The field shows the
    // count the image is ACTUALLY computed with, not the number they last typed.
    ve.syncFromPolicy(.{ .auto = true }, 4096);
    try testing.expectEqualStrings("4096", sliceUntilNull(&ve.manual_iter_buf));
}

test "acceptance: the iteration count is read-only while the policy is automatic" {
    var ve = ViewEditor{};
    ve.syncFromPolicy(.{ .auto = true }, 8192);
    try testing.expect(ve.iterFieldReadOnly());

    ve.syncFromPolicy(try autoiter.IterPolicy.manual(1024), 1024);
    try testing.expect(!ve.iterFieldReadOnly());
}

test "acceptance: leaving auto pins the count that was on display" {
    var ve = ViewEditor{};
    // Auto at depth is showing 16384.
    ve.syncFromPolicy(.{ .auto = true }, 16384);
    try testing.expectEqualStrings("16384", sliceUntilNull(&ve.manual_iter_buf));

    // Unchecking Auto pins exactly that, so editing continues from what auto chose.
    ve.auto_iter = false;
    const pinned = ve.leaveAuto();
    try testing.expect(!pinned.auto);
    try testing.expectEqual(@as(u32, 16384), pinned.manual_value);
    try testing.expect(!ve.iterFieldReadOnly());
}
