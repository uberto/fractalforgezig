//! PURE gesture reduction (M7): turn the trackpad/wheel events that arrive during one frame
//! into AT MOST ONE view-change intent, and decide where one gesture ends and the next
//! begins so the event loop can push exactly ONE undo entry per gesture.
//!
//! NO SDL/ImGui/C/GPU imports, no clock, no allocation — the whole module is plain `f64`
//! arithmetic over plain data, so every gesture in this milestone is unit-testable in the
//! fast `zig build test` tier with no window and no GPU device (`src/context.md`,
//! pure-vs-glue rule). Aggregated into `src/root.zig`'s `test` block; without that import
//! none of the tests below run. `main.zig` owns the SDL side: it reduces each event to
//! `addPinch` / `addWheel` / `endPinch`, calls `take()` once per frame, and applies the
//! intent through `navigate`.
//!
//! OBSERVABILITY: none, deliberately. This is the pure tier, which never imports `log`
//! (`src/fractal/context.md`): it returns intents and the EDGE decides what to say about
//! them. Do not "fix" this by adding logging — a log line here would be unreachable from
//! the pure test tier's assertions and would fire once per event during a fast pinch.
//!
//! FACTOR CONVENTION — the one thing a reader gets backwards. `Intent.zoom_factor` scales
//! the view's SIDE (`navigate.zoomAbout`), so `factor < 1` zooms **IN**. A pinch reports the
//! opposite sense: `scale > 1` means the fingers OPENED, which must zoom in, so the factor
//! handed out is the RECIPROCAL of the accumulated pinch scale. Two updates of 2.0 therefore
//! produce a factor of 1/4, not 4.
//!
//! REFUSAL, NOT CORRECTION. A pinch scale that is not finite and positive, and a wheel sample
//! with a non-finite delta, contribute NOTHING instead of being clamped or passed on: handing
//! `navigate` a bad factor only produces a rejected view one layer down, and this module's job
//! is to produce a valid intent or none at all. The wide-end CLAMP is not restated here either
//! — `navigate` already saturates every side-growing transform at `max_view_side`
//! (`navigate.zig`), and a rule with two homes has none.
const std = @import("std");
const navigate = @import("../fractal/navigate.zig");

/// Which pointing device the wheel events are coming from. `.auto` is the default so the app
/// behaves sensibly with no configuration; `.mouse` / `.trackpad` are the user's declaration,
/// which always wins over detection.
pub const InputMode = enum { auto, mouse, trackpad };

/// One SDL_EVENT_MOUSE_WHEEL, reduced to plain data. `integer_y` is SDL's whole-tick
/// accumulation (`event.wheel.integer_y`, SDL >= 3.2.12).
pub const WheelSample = struct { x: f64 = 0, y: f64 = 0, integer_y: i32 = 0 };

/// What a wheel event means: today's discrete zoom, or a two-finger swipe pan.
pub const WheelAction = enum { zoom, pan };

/// Decide what one wheel event means. The user's declaration wins: `.mouse` always zooms and
/// `.trackpad` always pans, whatever the deltas look like.
///
/// PLACEHOLDER (T2): `.auto` currently answers `.zoom`, which is only right for a real mouse
/// notch. **`T3` owns the `auto` discriminator** (horizontal component, then whole-tick vs
/// fractional `integer_y`) and the approved classification scenarios are checked against `T3`,
/// not against this line. The two declared modes below are final.
pub fn classifyWheel(sample: WheelSample, mode: InputMode) WheelAction {
    _ = sample;
    return switch (mode) {
        .trackpad => .pan,
        .mouse, .auto => .zoom,
    };
}

/// The sign SDL's horizontal / vertical wheel delta is multiplied by to become the VIEW pixel
/// delta `navigate.panByPixels` takes (which moves the view, so the content moves the other
/// way — hence the axes do not agree, `panByPixels` also flipping pixel-y against `im`).
///
/// UNVERIFIED, AND ON PURPOSE. What macOS reports for a two-finger swipe — and how the user's
/// natural-scrolling setting flips it — is measured by `T1`'s probe, not knowable from the
/// headers; `T8` sets these two constants from `pilot/input-probe.log` and the user confirms
/// the direction on screen. The MAGNITUDE is contract (a swipe pans by exactly its pixel
/// distance) and is what the tests assert; the sign lives here, in one place, so `T8` flips a
/// constant instead of an immutable test.
const pan_x_sign: f64 = -1.0;
const pan_y_sign: f64 = 1.0;

/// What one frame's gesture input asks for. `zoom_factor` is a SIDE multiplier consumable
/// directly by `navigate.zoomAbout` (< 1 zooms in). Pan is in pixels, already normalized to
/// content-follows-the-fingers. `began` is true on the first frame of a gesture run.
pub const Intent = struct {
    zoom_factor: ?f64 = null,
    pan_dx: f64 = 0,
    pan_dy: f64 = 0,
    began: bool = false,
};

/// Collects one frame's gesture input. Zero-initialized (`Accumulator{}`) and owned by the
/// event loop; `add*` during the event drain, `take()` once per frame.
pub const Accumulator = struct {
    /// Product of this frame's INCREMENTAL pinch scales (see `addPinch`). Kept as a scale
    /// rather than a factor so `take()` inverts the product exactly once.
    pinch_scale: f64 = 1.0,
    /// Product of this frame's discrete wheel steps, already SIDE factors.
    wheel_factor: f64 = 1.0,
    /// A zoom contribution arrived this frame. Not derivable from the two products above: a
    /// frame with no zoom and a frame whose scales multiply back to 1.0 must differ.
    has_zoom: bool = false,
    pan_dx: f64 = 0,
    pan_dy: f64 = 0,
    /// A pan contribution arrived this frame — likewise not derivable, since deltas cancel.
    has_pan: bool = false,
    /// A gesture run is open: the next intent is a continuation, not a beginning.
    in_run: bool = false,
    /// `endPinch` fired while this frame already held input, so the run closes at the frame
    /// boundary — AFTER that input is delivered as part of the run that is ending.
    end_after_take: bool = false,

    /// Fold in one pinch update.
    ///
    /// PRECONDITION ON THE CALLER: `scale` is INCREMENTAL — the ratio since the PREVIOUS
    /// update of the same gesture, not the gesture's total. That is why updates multiply:
    /// three updates of 1.25, 1.6 and 2.0 in one frame are one zoom of 1.25·1.6·2.0 = 4.
    /// SDL documents `event.pinch.scale` as "the scale change since the last
    /// SDL_EVENT_PINCH_UPDATE" (`SDL_events.h:804`), so the reduction in `main.zig` is
    /// expected to be a pass-through — but nobody has MEASURED it, and this module must not
    /// care. Converting whatever the platform reports into an incremental ratio is the
    /// CALLER's job (`T4`), so a probe surprise is fixed at the call site (`T8`) and this
    /// reduction stays a product.
    ///
    /// A scale that is not finite and positive is IGNORED (refusal, not correction): it
    /// contributes nothing and does not start a gesture run.
    pub fn addPinch(a: *Accumulator, scale: f64) void {
        if (!positiveFinite(scale)) return;
        a.pinch_scale *= scale;
        a.has_zoom = true;
    }

    /// Fold in one wheel event: ask `classifyWheel` what it means, then either compose a zoom
    /// step (today's `navigate.zoom_step_in` / `zoom_step_out`, so the existing wheel feel is
    /// bit-for-bit unchanged) or sum a pan delta. A sample with no delta on the axis its
    /// reading uses contributes nothing, as does a non-finite delta.
    pub fn addWheel(a: *Accumulator, sample: WheelSample, mode: InputMode) void {
        // A half-trustworthy event is not trustworthy: one non-finite axis voids the sample.
        if (!std.math.isFinite(sample.x) or !std.math.isFinite(sample.y)) return;
        switch (classifyWheel(sample, mode)) {
            .zoom => {
                // Direction and step size are today's, unchanged: up zooms in, down zooms out
                // (`main.zig`'s SDL_EVENT_MOUSE_WHEEL handler), 2x per notch.
                if (sample.y == 0) return;
                a.wheel_factor *= if (sample.y > 0) navigate.zoom_step_in else navigate.zoom_step_out;
                a.has_zoom = true;
            },
            .pan => {
                if (sample.x == 0 and sample.y == 0) return;
                a.pan_dx += pan_x_sign * sample.x;
                a.pan_dy += pan_y_sign * sample.y;
                a.has_pan = true;
            },
        }
    }

    /// The fingers left the trackpad: close the current gesture run, so the next gesture
    /// reports `began` again and the event loop pushes a second undo entry. Input that already
    /// arrived this frame still belongs to the run that is ending.
    pub fn endPinch(a: *Accumulator) void {
        if (a.has_zoom or a.has_pan) {
            // Deliver this frame first, then close: the last update of a pinch is part of that
            // pinch, so it must not be reported as the beginning of a new run.
            a.end_after_take = true;
        } else {
            a.in_run = false;
            a.end_after_take = false;
        }
    }

    /// Drain the frame. Null when no gesture input arrived since the last call.
    ///
    /// ONLY `endPinch` MAY END A GESTURE RUN. An input-less frame returns null and leaves the
    /// run EXACTLY as it was, so the next update after an idle frame still reports
    /// `began = false`. This is not what the milestone's acceptance suite pins — plan review
    /// proved that ending the run here on any input-less frame leaves all 16 of them green —
    /// but the two readings differ where it matters: a slow pinch that happens to deliver
    /// nothing for one frame would start a NEW run mid-gesture, and so a second undo entry,
    /// which is exactly what the requirement *One whole gesture is one undo step* forbids. A
    /// run is a run of consecutive frames CARRYING INPUT, with `endPinch` forcing the boundary.
    /// (The unit test *an idle frame does not end a gesture run* below does pin it; the
    /// acceptance suite cannot.)
    ///
    /// A frame is delivered at most once: the accumulation is reset here, so a second call in
    /// the same frame is null and the frame's input is never applied twice.
    pub fn take(a: *Accumulator) ?Intent {
        // An input-less frame: null, and the run is left EXACTLY as it was (see above).
        if (!a.has_zoom and !a.has_pan) {
            a.closeIfEnding();
            return null;
        }
        // The reciprocal of the pinch-scale product, composed with the wheel's own side steps.
        // Dividing once — rather than inverting each update — keeps a wheel-only frame's factor
        // bit-identical to the constant it came from.
        const factor: ?f64 = if (a.has_zoom) blk: {
            const f = a.wheel_factor / a.pinch_scale;
            break :blk if (positiveFinite(f)) f else null;
        } else null;
        if (factor == null and !a.has_pan) {
            // The only zoom this frame asked for is unusable (the product left the f64 range),
            // so there is nothing to apply: refuse the frame rather than hand on a bad factor
            // or an intent that does nothing.
            a.resetFrame();
            a.closeIfEnding();
            return null;
        }
        const intent = Intent{
            .zoom_factor = factor,
            .pan_dx = a.pan_dx,
            .pan_dy = a.pan_dy,
            .began = !a.in_run,
        };
        a.resetFrame();
        if (a.end_after_take) {
            a.in_run = false;
            a.end_after_take = false;
        } else {
            a.in_run = true;
        }
        return intent;
    }

    /// Drop this frame's accumulation. Touches NO run state: `in_run` and `end_after_take`
    /// outlive a frame by design.
    fn resetFrame(a: *Accumulator) void {
        a.pinch_scale = 1.0;
        a.wheel_factor = 1.0;
        a.has_zoom = false;
        a.pan_dx = 0;
        a.pan_dy = 0;
        a.has_pan = false;
    }

    /// Apply a pending `endPinch` on a frame that delivered nothing, so a run cannot stay half
    /// closed and leak the boundary into a later frame.
    fn closeIfEnding(a: *Accumulator) void {
        if (a.end_after_take) {
            a.in_run = false;
            a.end_after_take = false;
        }
    }
};

/// The predicate both a pinch scale and a resulting zoom factor must satisfy: `navigate` needs
/// a finite, positive side multiplier, and anything else is refused rather than corrected.
fn positiveFinite(x: f64) bool {
    return std.math.isFinite(x) and x > 0;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "take on a fresh accumulator reports no gesture input" {
    var acc = Accumulator{};
    try testing.expect(acc.take() == null);
}

test "three pinch updates in one frame yield one zoom factor that is the reciprocal of their product" {
    var acc = Accumulator{};
    acc.addPinch(1.25);
    acc.addPinch(1.6);
    acc.addPinch(2.0);
    const intent = acc.take() orelse return error.TestUnexpectedNull;
    try testing.expectApproxEqRel(@as(f64, 1.0) / 4.0, intent.zoom_factor orelse return error.TestUnexpectedNull, 1e-15);
}

test "take drains the frame so a second call in the same frame reports nothing" {
    var acc = Accumulator{};
    acc.addPinch(1.5);
    _ = acc.take() orelse return error.TestUnexpectedNull;
    try testing.expect(acc.take() == null);
}

test "opening fingers shrink the view side and closing fingers grow it" {
    var open = Accumulator{};
    open.addPinch(2.0);
    const opened = (open.take() orelse return error.TestUnexpectedNull).zoom_factor orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(f64, 0.5), opened);

    var close = Accumulator{};
    close.addPinch(0.5);
    const closed = (close.take() orelse return error.TestUnexpectedNull).zoom_factor orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(f64, 2.0), closed);
}

test "a pinch scale of exactly one asks for the identity zoom" {
    var acc = Accumulator{};
    acc.addPinch(1.0);
    const intent = acc.take() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(f64, 1.0), intent.zoom_factor orelse return error.TestUnexpectedNull);
}

test "a pinch scale that is not finite and positive is ignored rather than clamped" {
    const bad = [_]f64{ 0.0, -1.0, -2.5, std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) };
    for (bad) |scale| {
        var acc = Accumulator{};
        acc.addPinch(scale);
        try testing.expect(acc.take() == null);
    }
}

test "an ignored pinch scale leaves the rest of the frame's updates intact" {
    var acc = Accumulator{};
    acc.addPinch(2.0);
    acc.addPinch(std.math.nan(f64));
    acc.addPinch(2.0);
    const intent = acc.take() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(f64, 0.25), intent.zoom_factor orelse return error.TestUnexpectedNull);
}

test "an ignored pinch scale does not start a gesture run" {
    var acc = Accumulator{};
    acc.addPinch(0.0);
    try testing.expect(acc.take() == null);
    acc.addPinch(1.1);
    try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
}

test "a pinch product that leaves the f64 range yields no zoom rather than a bad factor" {
    // Overflow: the product is +inf, so a reciprocal would be 0 — a factor `navigate` rejects.
    var over = Accumulator{};
    for (0..3) |_| over.addPinch(1.0e300);
    try testing.expect(over.take() == null);

    // Underflow: the product is 0, so a reciprocal would be +inf.
    var under = Accumulator{};
    for (0..3) |_| under.addPinch(1.0e-300);
    try testing.expect(under.take() == null);
}

test "several swipe deltas in one frame sum into one pan" {
    var acc = Accumulator{};
    acc.addWheel(.{ .x = 3.0, .y = 1.5 }, .trackpad);
    acc.addWheel(.{ .x = 4.0, .y = 2.5 }, .trackpad);
    acc.addWheel(.{ .x = 5.0, .y = 6.0 }, .trackpad);
    const intent = acc.take() orelse return error.TestUnexpectedNull;
    // MAGNITUDE only: which sign means "with the fingers" is `T8`'s to set from the probe log.
    try testing.expectApproxEqAbs(@as(f64, 12.0), @abs(intent.pan_dx), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10.0), @abs(intent.pan_dy), 1e-9);
    try testing.expect(intent.zoom_factor == null);
}

test "the pan a swipe asks for follows the module's declared axis signs" {
    // Pins that the sign constants are really applied, per axis, without freezing today's
    // guess at their value: `T8` flips a constant and this test still holds.
    var acc = Accumulator{};
    acc.addWheel(.{ .x = 12.5, .y = -7.25 }, .trackpad);
    const intent = acc.take() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(pan_x_sign * 12.5, intent.pan_dx);
    try testing.expectEqual(pan_y_sign * -7.25, intent.pan_dy);
}

test "a wheel event with no delta contributes nothing whichever way it is read" {
    for ([_]InputMode{ .trackpad, .mouse }) |mode| {
        var acc = Accumulator{};
        acc.addWheel(.{ .x = 0.0, .y = 0.0, .integer_y = 0 }, mode);
        try testing.expect(acc.take() == null);
    }
}

test "a wheel event with a non-finite delta is ignored" {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    var acc = Accumulator{};
    acc.addWheel(.{ .x = nan, .y = 0.0 }, .trackpad);
    acc.addWheel(.{ .x = 0.0, .y = inf }, .trackpad);
    acc.addWheel(.{ .x = 0.0, .y = nan }, .mouse);
    try testing.expect(acc.take() == null);
}

test "a wheel notch up in mouse mode zooms in by the existing 2x step" {
    var acc = Accumulator{};
    acc.addWheel(.{ .x = 0.0, .y = 1.0, .integer_y = 1 }, .mouse);
    const intent = acc.take() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(navigate.zoom_step_in, intent.zoom_factor orelse return error.TestUnexpectedNull);
    try testing.expectEqual(@as(f64, 0.0), intent.pan_dx);
    try testing.expectEqual(@as(f64, 0.0), intent.pan_dy);
}

test "a wheel notch down in mouse mode zooms out by the existing 2x step" {
    var acc = Accumulator{};
    acc.addWheel(.{ .x = 0.0, .y = -1.0, .integer_y = -1 }, .mouse);
    const intent = acc.take() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(navigate.zoom_step_out, intent.zoom_factor orelse return error.TestUnexpectedNull);
}

test "two wheel notches in one frame compose into a single four-fold zoom" {
    var acc = Accumulator{};
    acc.addWheel(.{ .x = 0.0, .y = 1.0, .integer_y = 1 }, .mouse);
    acc.addWheel(.{ .x = 0.0, .y = 1.0, .integer_y = 1 }, .mouse);
    const intent = acc.take() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(navigate.zoom_step_in * navigate.zoom_step_in, intent.zoom_factor orelse return error.TestUnexpectedNull);
    try testing.expect(acc.take() == null);
}

test "one frame carrying both a pinch and a swipe yields a single intent carrying both" {
    var acc = Accumulator{};
    acc.addPinch(2.0);
    acc.addWheel(.{ .x = 6.0, .y = 8.0 }, .trackpad);
    const intent = acc.take() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(f64, 0.5), intent.zoom_factor orelse return error.TestUnexpectedNull);
    try testing.expectApproxEqAbs(@as(f64, 6.0), @abs(intent.pan_dx), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 8.0), @abs(intent.pan_dy), 1e-9);
    try testing.expect(acc.take() == null);
}

test "a gesture spread over three frames reports began on the first frame only" {
    var acc = Accumulator{};
    acc.addPinch(1.1);
    try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
    acc.addPinch(1.1);
    try testing.expect(!(acc.take() orelse return error.TestUnexpectedNull).began);
    acc.addPinch(1.1);
    try testing.expect(!(acc.take() orelse return error.TestUnexpectedNull).began);
}

test "an idle frame does not end a gesture run" {
    // The bug this forbids: a slow pinch delivering nothing for one frame must NOT become two
    // undo entries. Only `endPinch` ends a run.
    var acc = Accumulator{};
    acc.addPinch(1.1);
    try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
    try testing.expect(acc.take() == null);
    acc.addPinch(1.1);
    try testing.expect(!(acc.take() orelse return error.TestUnexpectedNull).began);
}

test "endPinch ends the run so the next pinch begins a new one" {
    var acc = Accumulator{};
    acc.addPinch(1.1);
    try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
    acc.endPinch();
    try testing.expect(acc.take() == null);
    acc.addPinch(1.1);
    try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
}

test "endPinch after the last update of a frame keeps that frame in the ending run" {
    var acc = Accumulator{};
    acc.addPinch(1.1);
    try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
    // The fingers lift in the same frame as the gesture's last update: that update is a
    // continuation, and the run is closed once it has been delivered.
    acc.addPinch(1.1);
    acc.endPinch();
    try testing.expect(!(acc.take() orelse return error.TestUnexpectedNull).began);
    acc.addPinch(1.1);
    try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
}

test "classifyWheel reads every wheel event as a pan when the user has declared a trackpad" {
    // A whole mouse-like notch and a fractional swipe: the declaration wins over both.
    try testing.expectEqual(WheelAction.pan, classifyWheel(.{ .x = 0.0, .y = -1.0, .integer_y = -1 }, .trackpad));
    try testing.expectEqual(WheelAction.pan, classifyWheel(.{ .x = 4.5, .y = -0.317, .integer_y = 0 }, .trackpad));
}

test "classifyWheel reads every wheel event as a zoom when the user has declared a mouse" {
    // `.auto` is deliberately NOT asserted here: `T3` owns that branch.
    try testing.expectEqual(WheelAction.zoom, classifyWheel(.{ .x = 0.0, .y = -1.0, .integer_y = -1 }, .mouse));
    try testing.expectEqual(WheelAction.zoom, classifyWheel(.{ .x = 4.5, .y = -0.317, .integer_y = 0 }, .mouse));
}
