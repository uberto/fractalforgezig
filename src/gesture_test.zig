//! Acceptance tests for M7 trackpad gestures. Pure tier only — no window, no SDL, no clock:
//! each test feeds the plain-data reduction of an SDL event into `gesture` and asserts the
//! VIEW that comes out, via the shipped `navigate` transforms.
//! Aggregated from `src/root.zig`. IMMUTABLE: never weaken one.
const std = @import("std");
const testing = std.testing;
const viewport = @import("fractal/viewport.zig");
const navigate = @import("fractal/navigate.zig");
const gesture = @import("ui/gesture.zig");

/// The image side every gesture test measures pixels against.
const test_side: u32 = 512;

/// An off-centre anchor: BOTH coordinates differ from `defaultView`'s centre (-0.75, 0.0),
/// so an "anchor stays put" assertion can actually fail on either axis.
const off_center = viewport.ComplexHi{ .re = -0.9, .im = 0.1 };

/// The same anchor at `f64`, for `complexToPixel`, which takes a `Complex` not a `ComplexHi`.
const off_center_lo = off_center.lo();

// ── Requirement: Trackpad pinch zoom ──────────────────────────────────────────────────

test "acceptance: pinching open zooms in about the cursor" {
    const v = viewport.SquareView.defaultView();
    var acc = gesture.Accumulator{};
    acc.addPinch(2.0); // fingers opening by 2x

    const intent = acc.take() orelse return error.TestUnexpectedNull;
    const factor = intent.zoom_factor orelse return error.TestUnexpectedNull;
    const zoomed = try navigate.zoomAbout(v, off_center, factor);

    // Opening by 2x halves the view side.
    try testing.expectApproxEqRel(@as(f64, @floatCast(v.side)) / 2.0, @as(f64, @floatCast(zoomed.side)), 1e-12);
    // And the anchor is still under its own pixel — the same promise the wheel zoom makes.
    const before = v.complexToPixel(off_center_lo, test_side);
    const after = zoomed.complexToPixel(off_center_lo, test_side);
    try testing.expectApproxEqAbs(before.x, after.x, 1e-6);
    try testing.expectApproxEqAbs(before.y, after.y, 1e-6);
}

test "acceptance: pinching closed zooms out" {
    const v = try viewport.SquareView.fromCenterSide(off_center, 1.0e-3);
    var acc = gesture.Accumulator{};
    acc.addPinch(0.5); // fingers closing

    const intent = acc.take() orelse return error.TestUnexpectedNull;
    const factor = intent.zoom_factor orelse return error.TestUnexpectedNull;
    const zoomed = try navigate.zoomAbout(v, off_center, factor);

    try testing.expectApproxEqRel(@as(f64, @floatCast(v.side)) * 2.0, @as(f64, @floatCast(zoomed.side)), 1e-12);
    try testing.expect(zoomed.magnification() < v.magnification());
}

test "acceptance: a pinch and its reverse restore the view" {
    const v = try viewport.SquareView.fromCenterSide(off_center, 1.0e-3);

    var open = gesture.Accumulator{};
    open.addPinch(2.0);
    const in_factor = (open.take() orelse return error.TestUnexpectedNull).zoom_factor.?;
    const there = try navigate.zoomAbout(v, off_center, in_factor);

    var close = gesture.Accumulator{};
    close.addPinch(0.5);
    const out_factor = (close.take() orelse return error.TestUnexpectedNull).zoom_factor.?;
    const back = try navigate.zoomAbout(there, off_center, out_factor);

    try testing.expectEqual(v, back);
}

test "acceptance: one whole gesture is one undo step" {
    var acc = gesture.Accumulator{};

    // A gesture arriving over three frames reports `began` on the FIRST frame only, so the
    // event loop pushes exactly one history entry for the whole pinch.
    acc.addPinch(1.1);
    try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
    acc.addPinch(1.1);
    try testing.expect(!(acc.take() orelse return error.TestUnexpectedNull).began);
    acc.addPinch(1.1);
    try testing.expect(!(acc.take() orelse return error.TestUnexpectedNull).began);

    // Fingers lift, then a NEW pinch is a new undo step.
    acc.endPinch();
    try testing.expect(acc.take() == null);
    acc.addPinch(1.1);
    try testing.expect((acc.take() orelse return error.TestUnexpectedNull).began);
}

test "acceptance: pinching out saturates at the maximum side" {
    var v = viewport.SquareView.defaultView();
    // Twenty frames of steady pinch-out: without the clamp the side would grow ~1e6x.
    for (0..20) |_| {
        var acc = gesture.Accumulator{};
        acc.addPinch(0.5);
        const factor = (acc.take() orelse return error.TestUnexpectedNull).zoom_factor.?;
        v = try navigate.zoomAbout(v, off_center, factor);
    }
    try testing.expectApproxEqRel(navigate.max_view_side, @as(f64, @floatCast(v.side)), 1e-12);
}

// ── Requirement: Trackpad two-finger pan ──────────────────────────────────────────────

test "acceptance: a two-finger swipe moves the content with the fingers" {
    const v = viewport.SquareView.defaultView();
    var acc = gesture.Accumulator{};
    // A trackpad swipe: fractional deltas, no whole tick accumulated yet.
    acc.addWheel(.{ .x = 12.5, .y = -7.25, .integer_y = 0 }, .trackpad);

    const intent = acc.take() orelse return error.TestUnexpectedNull;
    try testing.expect(intent.zoom_factor == null);

    // The content travels by exactly the gesture's pixel distance on each axis. MAGNITUDE
    // only: which SIGN means "with the fingers" depends on SDL's convention for a trackpad
    // swipe under macOS natural scrolling, which T1's probe measures — so the direction is
    // on the user's walkthrough checklist, not asserted here. See "What these tests do not
    // pin" above.
    try testing.expectApproxEqAbs(@as(f64, 12.5), @abs(intent.pan_dx), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 7.25), @abs(intent.pan_dy), 1e-9);

    // Whatever the sign, the pan is a real translation of the plane by that delta: the point
    // drawn at a pixel before the pan is drawn at pixel - delta after it.
    const panned = try navigate.panByPixels(v, intent.pan_dx, intent.pan_dy, test_side);
    const point = v.pixelToComplex(200.5, 300.5, test_side);
    const after = panned.complexToPixel(point, test_side);
    try testing.expectApproxEqAbs(200.5 - intent.pan_dx, after.x, 1e-9);
    try testing.expectApproxEqAbs(300.5 - intent.pan_dy, after.y, 1e-9);
}

test "acceptance: a two-finger swipe leaves the magnification untouched" {
    const v = try viewport.SquareView.fromCenterSide(off_center, 1.0e-12);
    var acc = gesture.Accumulator{};
    acc.addWheel(.{ .x = 30.0, .y = 18.0, .integer_y = 0 }, .trackpad);

    const intent = acc.take() orelse return error.TestUnexpectedNull;
    const panned = try navigate.panByPixels(v, intent.pan_dx, intent.pan_dy, test_side);

    try testing.expectEqual(v.side, panned.side);
    try testing.expectEqual(v.magnification(), panned.magnification());
    try testing.expect(!std.meta.eql(v.center(), panned.center()));
}

// ── Requirement: One view change per frame per gesture ─────────────────────────────────

test "acceptance: pinch updates in one frame coalesce into one zoom" {
    var acc = gesture.Accumulator{};
    acc.addPinch(1.25);
    acc.addPinch(1.6);
    acc.addPinch(2.0);

    // ONE intent for the frame, carrying the PRODUCT of the three scales (1.25*1.6*2 = 4).
    const intent = acc.take() orelse return error.TestUnexpectedNull;
    const factor = intent.zoom_factor orelse return error.TestUnexpectedNull;
    const v = viewport.SquareView.defaultView();
    const zoomed = try navigate.zoomAbout(v, off_center, factor);
    try testing.expectApproxEqRel(@as(f64, @floatCast(v.side)) / 4.0, @as(f64, @floatCast(zoomed.side)), 1e-12);

    // Drained: the frame's input is not applied a second time.
    try testing.expect(acc.take() == null);
}

test "acceptance: swipe deltas in one frame coalesce into one pan" {
    var acc = gesture.Accumulator{};
    acc.addWheel(.{ .x = 3.0, .y = 1.5, .integer_y = 0 }, .trackpad);
    acc.addWheel(.{ .x = 4.0, .y = 2.5, .integer_y = 0 }, .trackpad);
    acc.addWheel(.{ .x = 5.0, .y = 6.0, .integer_y = 0 }, .trackpad);

    const first = acc.take() orelse return error.TestUnexpectedNull;
    const second = acc.take();

    // One pan for the frame, summing the three deltas — not three pans.
    try testing.expect(second == null);
    const sum_x = @abs(first.pan_dx);
    const sum_y = @abs(first.pan_dy);
    try testing.expectApproxEqAbs(@as(f64, 12.0), sum_x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10.0), sum_y, 1e-9);
}

// ── Requirement: The pointing device decides what the wheel does ───────────────────────

test "acceptance: a mouse wheel notch still zooms" {
    // Exactly what SDL delivers for one notch of a plain wheel: a whole tick, no horizontal.
    const notch = gesture.WheelSample{ .x = 0.0, .y = -1.0, .integer_y = -1 };
    try testing.expectEqual(gesture.WheelAction.zoom, gesture.classifyWheel(notch, .auto));

    var acc = gesture.Accumulator{};
    acc.addWheel(notch, .auto);
    const intent = acc.take() orelse return error.TestUnexpectedNull;

    // It zooms OUT (negative y, as today) and does not pan at all.
    const factor = intent.zoom_factor orelse return error.TestUnexpectedNull;
    try testing.expectEqual(navigate.zoom_step_out, factor);
    try testing.expectEqual(@as(f64, 0.0), intent.pan_dx);
    try testing.expectEqual(@as(f64, 0.0), intent.pan_dy);
}

test "acceptance: declaring a mouse makes a fractional wheel event zoom" {
    const fractional = gesture.WheelSample{ .x = 0.0, .y = -0.317, .integer_y = 0 };
    // Left to itself this would read as a trackpad swipe...
    try testing.expectEqual(gesture.WheelAction.pan, gesture.classifyWheel(fractional, .auto));
    // ...but the user's declaration wins.
    try testing.expectEqual(gesture.WheelAction.zoom, gesture.classifyWheel(fractional, .mouse));

    var acc = gesture.Accumulator{};
    acc.addWheel(fractional, .mouse);
    const intent = acc.take() orelse return error.TestUnexpectedNull;
    try testing.expect(intent.zoom_factor != null);
    try testing.expectEqual(@as(f64, 0.0), intent.pan_dy);
}

test "acceptance: declaring a trackpad makes a whole-tick wheel event pan" {
    const notch = gesture.WheelSample{ .x = 0.0, .y = -1.0, .integer_y = -1 };
    // Left to itself this reads as a mouse notch...
    try testing.expectEqual(gesture.WheelAction.zoom, gesture.classifyWheel(notch, .auto));
    // ...but the user's declaration wins.
    try testing.expectEqual(gesture.WheelAction.pan, gesture.classifyWheel(notch, .trackpad));

    var acc = gesture.Accumulator{};
    acc.addWheel(notch, .trackpad);
    const intent = acc.take() orelse return error.TestUnexpectedNull;
    try testing.expect(intent.zoom_factor == null);
    try testing.expect(intent.pan_dy != 0.0);
}

test "acceptance: an auto-detected horizontal wheel component pans" {
    // A plain wheel has no horizontal axis, so any horizontal component is a two-finger
    // swipe — true even when the vertical part happens to have accumulated a whole tick.
    const diagonal = gesture.WheelSample{ .x = 4.5, .y = -1.0, .integer_y = -1 };
    try testing.expectEqual(gesture.WheelAction.pan, gesture.classifyWheel(diagonal, .auto));

    const horizontal_only = gesture.WheelSample{ .x = -6.0, .y = 0.0, .integer_y = 0 };
    try testing.expectEqual(gesture.WheelAction.pan, gesture.classifyWheel(horizontal_only, .auto));
}
