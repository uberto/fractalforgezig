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
//! RUN BOUNDARIES ARE PER EVENT SOURCE, and that is a decision, not an oversight: a pinch is
//! bounded by the fingers landing and lifting (`endPinch`), a two-finger swipe arrives as wheel
//! events that have no end marker at all, and a wheel notch is a complete gesture on its own. One
//! rule for all three cannot be right, and getting it wrong costs the user undo entries. See
//! `RunSource` for the three rules and the tests that pin them.
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

/// Reduce one `SDL_EVENT_MOUSE_WHEEL` to plain data: `event.wheel.x` → `x`, `event.wheel.y` → `y`,
/// `event.wheel.integer_y` → `integer_y`. A STRAIGHT COPY — the three signs are SDL's and are
/// passed through untouched.
///
/// WHY THIS TRIVIAL FUNCTION EXISTS AT ALL: it puts the mapping in the pure tier, where a test can
/// pin it, instead of inline in `main.zig`, which has no test tier. What it pins is precisely the
/// mistake that would be invisible otherwise — a sign flip. `event.wheel.direction` is DELIBERATELY
/// not a parameter and is not read: the pre-M7 handler ignored it too, and on macOS the flipped
/// reading it reports is what "natural scrolling" — the DEFAULT setting — produces, so negating x
/// and y for it would invert the existing wheel zoom. That is a regression no test in this tier
/// could catch, since only SDL supplies the sign. Whether `direction` needs honouring at all is a
/// question for `T8`, which has the measured probe log and owns every sign in this milestone.
pub fn wheelSample(x: f64, y: f64, integer_y: i32) WheelSample {
    return .{ .x = x, .y = y, .integer_y = integer_y };
}

/// What a wheel event means: today's discrete zoom, or a two-finger swipe pan.
pub const WheelAction = enum { zoom, pan };

/// Decide what one wheel event means. The user's declaration wins: `.mouse` always zooms and
/// `.trackpad` always pans, whatever the deltas look like.
///
/// `.auto` is a HEURISTIC, tried in this precedence (one early return per rule, because the
/// rules are measured separately and `T8` may have to change exactly one of them):
///   1. a non-zero horizontal component is a two-finger swipe, because a plain wheel has no
///      horizontal axis at all. This is the STRONG signal: it wins even when the vertical
///      part has accumulated a whole tick.
///   2. otherwise a vertical delta that is not a whole tick is a swipe, trackpads reporting
///      continuous motion where a wheel reports notches. The test is against `integer_y`,
///      SDL's OWN tick accumulation (`SDL_events.h:504-505`), and not `@floor(y) == y` or a
///      threshold picked here: a trackpad can deliver an exactly integral delta by
///      coincidence (`y = -1.0`, `integer_y = 0` — a swipe) and a fast wheel can deliver
///      several notches at once (`y = -3.0`, `integer_y = -3` — a zoom). Only `integer_y`
///      separates those two.
///   3. otherwise it is a mouse notch: a whole-tick vertical delta with no horizontal
///      component, which zooms exactly as it has always done.
///
/// WHERE `.auto` IS KNOWN TO BE WRONG: a Magic Mouse scrolls with precise fractional deltas,
/// indistinguishable from a trackpad's, so `.auto` reads its scroll as a swipe and pans. The
/// cure is the user declaring `.mouse`, which is why that declaration exists. `.auto` is a
/// convenience for the common cases, never a promise.
pub fn classifyWheel(sample: WheelSample, mode: InputMode) WheelAction {
    switch (mode) {
        // A declaration is a fact, not evidence. No delta can outvote it.
        .mouse => return .zoom,
        .trackpad => return .pan,
        .auto => {},
    }

    // Rule 1: any horizontal motion at all means fingers, not a wheel.
    if (sample.x != 0) return .pan;

    // Rule 2: continuous vertical motion means fingers. `y` disagreeing with the whole ticks
    // SDL counted is exactly "this delta is not a notch".
    if (sample.y != @as(f64, @floatFromInt(sample.integer_y))) return .pan;

    // Rule 3: a whole tick and nothing sideways — a wheel notch, zooming as it always has.
    // (A motionless event lands here too; `addWheel` then contributes nothing for it.)
    return .zoom;
}

/// The sign SDL's horizontal / vertical wheel delta is multiplied by to become the VIEW pixel
/// delta `navigate.panByPixels` takes (which moves the view, so the content moves the other
/// way — hence the axes do not agree, `panByPixels` also flipping pixel-y against `im`).
///
/// UNVERIFIED, AND ON PURPOSE — PROVISIONAL UNTIL `T8`. What macOS reports for a two-finger
/// swipe — and how the user's natural-scrolling setting flips it — is measured by `T1`'s probe,
/// not knowable from the headers; `T8` sets these two constants from `pilot/input-probe.log` and
/// the user confirms the direction on screen. The MAGNITUDE is contract (a swipe pans by exactly
/// its pixel distance) and is what the tests assert; the sign lives here, in one place, so `T8`
/// flips a constant instead of an immutable test.
///
/// The intent is CONTENT-FOLLOWS-THE-FINGERS (the Google-Maps feel the user asked for). If the
/// gesture comes out backwards on screen, negating the offending constant here is the WHOLE fix —
/// there is no second place a swipe's direction is decided, and nothing downstream needs to
/// change.
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

/// What is keeping the current gesture run open — and so WHAT IS ALLOWED TO CLOSE IT.
///
/// RUN BOUNDARIES ARE PER EVENT SOURCE, deliberately, because the three sources bound their
/// gestures in three different ways and no single rule is right for all of them. The next
/// reader's instinct will be to collapse these into one rule; the tests *an idle frame ends a
/// wheel-pan run but never a pinch run* and *a wheel notch arriving during a pinch does not
/// split the pinch run* exist to stop that.
///   - `.pinch` — closed ONLY by `endPinch` (the fingers leaving the trackpad). An idle frame
///     must NOT close it: fingers held still send no updates, and splitting there would cost a
///     second undo entry for one gesture. `T2`'s reviewer mutation-verified this.
///   - `.wheel_pan` — a two-finger swipe arrives as wheel events, which have NO end event, so
///     the first frame that drains with no pan input is the boundary. Without that, the second
///     swipe of a session would push no undo entry and could not be undone.
///   - a wheel NOTCH opens no run at all: it is discrete and self-contained, so its run closes
///     with the very frame that delivered it — one notch, one undo entry, exactly as before
///     M7. That is why there is no `.wheel_zoom` member.
const RunSource = enum { none, pinch, wheel_pan };

/// Collects one frame's gesture input. Zero-initialized (`Accumulator{}`) and owned by the
/// event loop; `add*` during the event drain, `take()` once per frame.
pub const Accumulator = struct {
    /// Product of this frame's INCREMENTAL pinch scales (see `addPinch`). Kept as a scale
    /// rather than a factor so `take()` inverts the product exactly once.
    pinch_scale: f64 = 1.0,
    /// Product of this frame's discrete wheel steps, already SIDE factors.
    wheel_factor: f64 = 1.0,
    /// A PINCH update arrived this frame. Not derivable from `pinch_scale`: a frame with no
    /// pinch and a frame whose scales multiply back to 1.0 must differ. Kept apart from
    /// `has_wheel_zoom` because the two open different kinds of run (see `RunSource`).
    has_pinch: bool = false,
    /// A wheel event READ AS A ZOOM arrived this frame — a discrete notch.
    has_wheel_zoom: bool = false,
    pan_dx: f64 = 0,
    pan_dy: f64 = 0,
    /// A pan contribution arrived this frame — likewise not derivable, since deltas cancel.
    has_pan: bool = false,
    /// Which source is keeping a run open, `.none` when the next intent begins one.
    run: RunSource = .none,
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
        a.has_pinch = true;
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
                a.has_wheel_zoom = true;
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
        if (a.hasInput()) {
            // Deliver this frame first, then close: the last update of a pinch is part of that
            // pinch, so it must not be reported as the beginning of a new run.
            a.end_after_take = true;
        } else {
            a.run = .none;
            a.end_after_take = false;
        }
    }

    /// Drain the frame. Null when no gesture input arrived since the last call.
    ///
    /// WHERE A RUN ENDS, AND WHY IT DEPENDS ON THE SOURCE (`RunSource`). A `.pinch` run is
    /// closed by `endPinch` ALONE: an input-less frame leaves it exactly as it was, so a slow
    /// pinch that delivers nothing for one frame does NOT start a new run mid-gesture and cost
    /// a second undo entry — the bug the requirement *One whole gesture is one undo step*
    /// exists to prevent (the acceptance suite cannot see it; the unit tests *an idle frame
    /// ends a wheel-pan run but never a pinch run* and *a wheel notch arriving during a pinch
    /// does not split the pinch run* do). The wheel has no end event, so it cannot rely on
    /// `endPinch`: a `.wheel_pan` run is closed by the first frame that DRAINS WITH NO PAN
    /// INPUT (otherwise the second swipe of a session would push no undo entry at all), and a
    /// wheel notch — discrete and self-contained — closes its run with the frame that carries
    /// it, so N notches are N undo entries exactly as before M7.
    ///
    /// A frame is delivered at most once: the accumulation is reset here, so a second call in
    /// the same frame is null and the frame's input is never applied twice.
    pub fn take(a: *Accumulator) ?Intent {
        // An input-less frame delivers nothing and ends only what a missing frame can end.
        if (!a.hasInput()) {
            a.closeUndelivered();
            return null;
        }
        // The reciprocal of the pinch-scale product, composed with the wheel's own side steps.
        // Dividing once — rather than inverting each update — keeps a wheel-only frame's factor
        // bit-identical to the constant it came from.
        const factor: ?f64 = if (a.hasZoom()) blk: {
            const f = a.wheel_factor / a.pinch_scale;
            break :blk if (positiveFinite(f)) f else null;
        } else null;
        if (factor == null and !a.has_pan) {
            // The only zoom this frame asked for is unusable (the product left the f64 range),
            // so there is nothing to apply: refuse the frame rather than hand on a bad factor
            // or an intent that does nothing. Nothing was delivered, so the run boundaries are
            // the input-less frame's.
            a.resetFrame();
            a.closeUndelivered();
            return null;
        }
        const intent = Intent{
            .zoom_factor = factor,
            .pan_dx = a.pan_dx,
            .pan_dy = a.pan_dy,
            .began = a.run == .none,
        };
        const had_pinch = a.has_pinch;
        const had_pan = a.has_pan;
        a.resetFrame();
        if (a.end_after_take) {
            // The fingers lifted: this frame was the run's last, whatever opened it.
            a.run = .none;
            a.end_after_take = false;
        } else if (had_pinch or a.run == .pinch) {
            // A pinch run outlives frames that carry no pinch update (a swipe-only frame is,
            // for the pinch, an idle frame) — `endPinch` is the only thing that ends it.
            a.run = .pinch;
        } else if (had_pan) {
            a.run = .wheel_pan;
        } else {
            // Wheel notches only: a discrete gesture is over the moment it is delivered, so
            // the NEXT notch reports `began` again and gets its own undo entry.
            a.run = .none;
        }
        return intent;
    }

    /// A zoom contribution — from either source — arrived this frame.
    fn hasZoom(a: Accumulator) bool {
        return a.has_pinch or a.has_wheel_zoom;
    }

    /// Any gesture contribution at all arrived this frame.
    fn hasInput(a: Accumulator) bool {
        return a.hasZoom() or a.has_pan;
    }

    /// Drop this frame's accumulation. Touches NO run state: `run` and `end_after_take`
    /// outlive a frame by design.
    fn resetFrame(a: *Accumulator) void {
        a.pinch_scale = 1.0;
        a.wheel_factor = 1.0;
        a.has_pinch = false;
        a.has_wheel_zoom = false;
        a.pan_dx = 0;
        a.pan_dy = 0;
        a.has_pan = false;
    }

    /// A frame that delivered no intent: it ends a `.wheel_pan` run — no pan input arrived, so
    /// the swipe is over and the next one deserves its own undo entry — and leaves a `.pinch`
    /// run open, because fingers held still on a trackpad send no updates. It also applies a
    /// pending `endPinch`, so a run cannot stay half closed and leak the boundary into a later
    /// frame.
    fn closeUndelivered(a: *Accumulator) void {
        if (a.run == .wheel_pan) a.run = .none;
        if (a.end_after_take) {
            a.run = .none;
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

// ── T3: the `.auto` discriminator ──────────────────────────────────────────────────────

test "the input mode a caller gets without choosing one is auto" {
    // The declaration order is load-bearing, not cosmetic: `.auto` is the zero value, so a
    // zero-initialized settings field (`T6`) means "work it out", never a wrong declaration.
    try testing.expectEqual(InputMode.auto, @as(InputMode, @enumFromInt(0)));
}

test "auto reads a whole-tick vertical delta with no horizontal component as a mouse notch" {
    // Today's behaviour, preserved exactly: this is what a plain wheel delivers, both ways.
    try testing.expectEqual(WheelAction.zoom, classifyWheel(.{ .x = 0.0, .y = -1.0, .integer_y = -1 }, .auto));
    try testing.expectEqual(WheelAction.zoom, classifyWheel(.{ .x = 0.0, .y = 1.0, .integer_y = 1 }, .auto));
}

test "auto reads a fractional vertical delta as a two-finger swipe" {
    try testing.expectEqual(WheelAction.pan, classifyWheel(.{ .x = 0.0, .y = -0.317, .integer_y = 0 }, .auto));
}

test "auto reads any horizontal component as a swipe even when the vertical part is a whole tick" {
    // A plain wheel has no horizontal axis, so horizontal motion is the STRONG signal and it
    // beats the whole tick sitting next to it.
    try testing.expectEqual(WheelAction.pan, classifyWheel(.{ .x = 4.5, .y = -1.0, .integer_y = -1 }, .auto));
    try testing.expectEqual(WheelAction.pan, classifyWheel(.{ .x = -6.0, .y = 0.0, .integer_y = 0 }, .auto));
}

test "auto reads a vertical delta that overshoots its whole tick as a swipe" {
    // The cases an `@floor(y) == y` test gets wrong, and why the comparison is against SDL's
    // own tick accumulation: a swipe whose delta happens to have just crossed a tick
    // boundary (`y` fractional, `integer_y` non-zero) and one that ran past it.
    try testing.expectEqual(WheelAction.pan, classifyWheel(.{ .x = 0.0, .y = 0.3, .integer_y = 1 }, .auto));
    try testing.expectEqual(WheelAction.pan, classifyWheel(.{ .x = 0.0, .y = -1.5, .integer_y = -1 }, .auto));
}

test "auto reads a coincidentally integral delta that carries no tick as a swipe" {
    // A trackpad can deliver exactly -1.0 without SDL calling it a notch. `integer_y` is the
    // discriminator, so this pans; a threshold or floor test on `y` would zoom.
    try testing.expectEqual(WheelAction.pan, classifyWheel(.{ .x = 0.0, .y = -1.0, .integer_y = 0 }, .auto));
}

test "auto reads several whole ticks arriving at once as a fast mouse wheel" {
    try testing.expectEqual(WheelAction.zoom, classifyWheel(.{ .x = 0.0, .y = -3.0, .integer_y = -3 }, .auto));
}

test "a declared mouse zooms the fractional sample auto reads as a swipe" {
    const fractional = WheelSample{ .x = 0.0, .y = -0.317, .integer_y = 0 };
    try testing.expectEqual(WheelAction.pan, classifyWheel(fractional, .auto));
    try testing.expectEqual(WheelAction.zoom, classifyWheel(fractional, .mouse));
}

test "a declared mouse zooms the diagonal sample auto reads as a swipe" {
    const diagonal = WheelSample{ .x = 4.5, .y = -1.0, .integer_y = -1 };
    try testing.expectEqual(WheelAction.pan, classifyWheel(diagonal, .auto));
    try testing.expectEqual(WheelAction.zoom, classifyWheel(diagonal, .mouse));
}

test "a declared trackpad pans the whole-tick sample auto reads as a notch" {
    const notch = WheelSample{ .x = 0.0, .y = -1.0, .integer_y = -1 };
    try testing.expectEqual(WheelAction.zoom, classifyWheel(notch, .auto));
    try testing.expectEqual(WheelAction.pan, classifyWheel(notch, .trackpad));
}

test "a sample auto classifies as a zoom asks for a zoom and no pan" {
    // The seam `T5` applies: a zoom intent must not also move the view sideways.
    var acc = Accumulator{};
    acc.addWheel(.{ .x = 0.0, .y = -1.0, .integer_y = -1 }, .auto);
    const intent = acc.take() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(navigate.zoom_step_out, intent.zoom_factor orelse return error.TestUnexpectedNull);
    try testing.expectEqual(@as(f64, 0.0), intent.pan_dx);
    try testing.expectEqual(@as(f64, 0.0), intent.pan_dy);
}

test "a sample auto classifies as a pan asks for a pan and no zoom" {
    var acc = Accumulator{};
    acc.addWheel(.{ .x = 4.5, .y = -0.317, .integer_y = 0 }, .auto);
    const intent = acc.take() orelse return error.TestUnexpectedNull;
    try testing.expect(intent.zoom_factor == null);
    try testing.expect(intent.pan_dx != 0.0);
    try testing.expect(intent.pan_dy != 0.0);
}

test "a wheel event with no motion does not start a gesture run in any mode" {
    // A motionless wheel event must cost nothing at all — starting a run would spend an undo
    // entry on it, so the pinch that follows must still report `began`.
    for ([_]InputMode{ .auto, .mouse, .trackpad }) |mode| {
        var acc = Accumulator{};
        acc.addWheel(.{ .x = 0.0, .y = 0.0, .integer_y = 0 }, mode);
        try testing.expect(acc.take() == null);
        acc.addPinch(1.25);
        try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
    }
}

// ─── T5: the SDL reduction, and the per-source run boundaries ────────────────

test "wheelSample copies SDL's three wheel fields through with their signs unchanged" {
    // The reduction is a STRAIGHT COPY. It must not negate, clamp or reorder anything: a sign
    // flip here would invert the existing wheel zoom, and no test in this tier could see it
    // because the sign comes from SDL.
    const sample = wheelSample(-12.5, 7.25, -3);
    try testing.expectEqual(WheelSample{ .x = -12.5, .y = 7.25, .integer_y = -3 }, sample);
}

test "wheelSample keeps a scroll-down notch negative, as SDL delivered it" {
    // Negating x and y for SDL's flipped wheel reading — a plausible-looking "fix" — would turn
    // this sample into +1.0 and invert every zoom on a macOS trackpad's default setting.
    const notch = wheelSample(0.0, -1.0, -1);
    try testing.expectEqual(@as(f64, -1.0), notch.y);
    try testing.expectEqual(@as(i32, -1), notch.integer_y);
}

test "an SDL notch reduced through wheelSample still zooms out by the existing step" {
    // The whole regression seam, end to end: wheelSample → classifyWheel → addWheel → Intent.
    const notch = wheelSample(0.0, -1.0, -1);
    try testing.expectEqual(WheelAction.zoom, classifyWheel(notch, .auto));
    var acc = Accumulator{};
    acc.addWheel(notch, .auto);
    const intent = acc.take() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(navigate.zoom_step_out, intent.zoom_factor orelse return error.TestUnexpectedNull);
    try testing.expectEqual(@as(f64, 0.0), intent.pan_dx);
    try testing.expectEqual(@as(f64, 0.0), intent.pan_dy);
}

test "an SDL notch up reduced through wheelSample still zooms in by the existing step" {
    const notch = wheelSample(0.0, 1.0, 1);
    var acc = Accumulator{};
    acc.addWheel(notch, .auto);
    const intent = acc.take() orelse return error.TestUnexpectedNull;
    try testing.expectEqual(navigate.zoom_step_in, intent.zoom_factor orelse return error.TestUnexpectedNull);
}

test "every mouse wheel notch is its own gesture run, so every notch is one undo entry" {
    // THE REGRESSION THIS MILESTONE ALMOST SHIPPED: with a run that only `endPinch` could
    // close, the first notch of a session pushed a history entry and no later notch ever did,
    // so one Ctrl+Z after ten notches jumped back to the pre-FIRST-notch view.
    var acc = Accumulator{};
    for (0..4) |_| {
        acc.addWheel(wheelSample(0.0, -1.0, -1), .auto);
        try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
    }
}

test "a notch leaves no run open, so a pinch right after it is its own undo entry" {
    var acc = Accumulator{};
    acc.addWheel(wheelSample(0.0, -1.0, -1), .auto);
    try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
    acc.addPinch(1.25);
    try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
}

test "a swipe spread over consecutive frames is one gesture run" {
    var acc = Accumulator{};
    acc.addWheel(.{ .x = 3.0, .y = 1.5, .integer_y = 0 }, .trackpad);
    try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
    acc.addWheel(.{ .x = 3.0, .y = 1.5, .integer_y = 0 }, .trackpad);
    try testing.expect(!(acc.take() orelse return error.TestUnexpectedNull).began);
    acc.addWheel(.{ .x = 3.0, .y = 1.5, .integer_y = 0 }, .trackpad);
    try testing.expect(!(acc.take() orelse return error.TestUnexpectedNull).began);
}

test "two swipes separated by an idle frame are two gesture runs" {
    // A wheel-pan gesture has no end event, so the frame that drains WITHOUT pan input is its
    // boundary — otherwise the second swipe of a session could not be undone.
    var acc = Accumulator{};
    acc.addWheel(.{ .x = 3.0, .y = 1.5, .integer_y = 0 }, .trackpad);
    try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
    try testing.expect(acc.take() == null);
    acc.addWheel(.{ .x = 3.0, .y = 1.5, .integer_y = 0 }, .trackpad);
    try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
}

test "an idle frame ends a wheel-pan run but never a pinch run" {
    // RUN BOUNDARIES ARE PER SOURCE, and this is the test that stops a future reader
    // collapsing them into one rule: the SAME idle frame must end the swipe's run and leave
    // the pinch's open, because fingers held still on a pinch send no updates.
    var swiping = Accumulator{};
    swiping.addWheel(.{ .x = 3.0, .y = 1.5, .integer_y = 0 }, .trackpad);
    _ = swiping.take() orelse return error.TestUnexpectedNull;
    try testing.expect(swiping.take() == null);
    swiping.addWheel(.{ .x = 3.0, .y = 1.5, .integer_y = 0 }, .trackpad);
    try testing.expect((swiping.take() orelse return error.TestUnexpectedNull).began);

    var pinching = Accumulator{};
    pinching.addPinch(1.1);
    _ = pinching.take() orelse return error.TestUnexpectedNull;
    try testing.expect(pinching.take() == null);
    pinching.addPinch(1.1);
    try testing.expect(!(pinching.take() orelse return error.TestUnexpectedNull).began);
}

test "a wheel notch arriving during a pinch does not split the pinch run" {
    // The notch is a complete gesture, but it must not END somebody else's: a pinch run is
    // closed by `endPinch` alone, so the frames after the notch are still continuations.
    var acc = Accumulator{};
    acc.addPinch(1.1);
    try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
    acc.addPinch(1.1);
    acc.addWheel(wheelSample(0.0, -1.0, -1), .auto);
    try testing.expect(!(acc.take() orelse return error.TestUnexpectedNull).began);
    acc.addPinch(1.1);
    try testing.expect(!(acc.take() orelse return error.TestUnexpectedNull).began);
}

test "a swipe frame in the middle of a pinch leaves the pinch run open" {
    // A trackpad can deliver a swipe and a pinch in the same gesture; a frame carrying only
    // the swipe is, for the PINCH, an idle frame — and must not cost a second undo entry.
    var acc = Accumulator{};
    acc.addPinch(1.1);
    try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
    acc.addWheel(.{ .x = 3.0, .y = 1.5, .integer_y = 0 }, .trackpad);
    try testing.expect(!(acc.take() orelse return error.TestUnexpectedNull).began);
    acc.addPinch(1.1);
    try testing.expect(!(acc.take() orelse return error.TestUnexpectedNull).began);
}

test "endPinch still ends a run that a wheel swipe is keeping open" {
    var acc = Accumulator{};
    acc.addWheel(.{ .x = 3.0, .y = 1.5, .integer_y = 0 }, .trackpad);
    try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
    acc.addWheel(.{ .x = 3.0, .y = 1.5, .integer_y = 0 }, .trackpad);
    acc.endPinch();
    try testing.expect(!(acc.take() orelse return error.TestUnexpectedNull).began);
    acc.addWheel(.{ .x = 3.0, .y = 1.5, .integer_y = 0 }, .trackpad);
    try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
}
