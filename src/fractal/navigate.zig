//! Pure navigation transforms over T1's `SquareView`. NO SDL/ImGui/GPU imports — this
//! lives in the fast test tier (`zig build test`) so every gesture's math is unit-tested
//! without a window (plan A8). Every function takes a view and returns a NEW one; nothing
//! here mutates, logs, or reads input.
//!
//! FACTOR CONVENTION — get this right when wiring T6: `factor` scales the view's SIDE, so
//! `factor < 1` zooms **IN** (a smaller region fills the image, magnification grows) and
//! `factor > 1` zooms **OUT**. Use `zoom_step_in` / `zoom_step_out` for the 2× steps.
//!
//! WHICH ZOOM FOR WHICH GESTURE (plan A4 — swapping these is a user-visible bug):
//!   * scroll wheel → `zoomAbout(v, cursor_point, f)`: the point under the cursor stays
//!     under the cursor (zoom-toward-cursor).
//!   * right-click menu → `zoomCentered(v, clicked_point, f)`: the clicked point becomes
//!     the new center.
//!
//! All pixel↔complex math is DELEGATED to `viewport.zig` (`pixelToComplex`,
//! `imageViewport(S).scale`, `fromCorners`, `fromCenterSide`) — this module must never
//! restate the mapping, and it never validates a view itself: every result funnels through
//! T1's validating constructors, so a hostile input (non-finite point/delta/factor, a
//! zero-area drag, a factor that overflows or underflows the side) comes back as
//! `ViewportError.DegenerateRegion` instead of a silently broken view. Errors are returned
//! UNLOGGED — the edge that accepted the gesture (T6) logs them, building the user-facing
//! text with `viewport.degenerateRegionMessage`; a still-valid-but-unrenderable deep zoom
//! is a warning instead, via `atPrecisionFloor` + `precisionFloorMessage`.
const std = @import("std");
const viewport = @import("viewport.zig");

const Complex = viewport.Complex;
const Pixel = viewport.Pixel;
const SquareView = viewport.SquareView;
const ViewportError = viewport.ViewportError;

/// The 2× zoom-IN step: halves the side, doubles the magnification (plan A3/A4). This is
/// what the right-click menu's "Zoom in 2×" and one scroll notch up pass as `factor`.
pub const zoom_step_in: f64 = 0.5;
/// The 2× zoom-OUT step, the exact reciprocal of `zoom_step_in` (both are powers of two,
/// so a zoom in followed by a zoom out restores the side bit-for-bit).
pub const zoom_step_out: f64 = 2.0;

/// Scale the view's side by `factor` while keeping `anchor` at the same on-screen
/// position — the scroll-wheel gesture (pass the complex point under the cursor, from
/// `SquareView.cursorCoord`). The anchor's offset from the center is expressed in view
/// widths, which the zoom must preserve, hence `center' = anchor - (anchor - center)·factor`.
/// `factor < 1` zooms in. Fails with `DegenerateRegion` for a non-finite anchor and for any
/// `factor` that leaves the side non-finite or non-positive (including a zoom so deep the
/// side underflows to zero, or so far out that it overflows).
pub fn zoomAbout(v: SquareView, anchor: Complex, factor: f64) ViewportError!SquareView {
    const new_center = Complex{
        .re = anchor.re - (anchor.re - v.center_re) * factor,
        .im = anchor.im - (anchor.im - v.center_im) * factor,
    };
    return SquareView.fromCenterSide(new_center, v.side * factor);
}

/// Scale the view's side by `factor` AND recenter on `point` — the right-click "zoom in /
/// out 2×" gesture (plan A4). Because magnification is `1/(side·√2)`, the diagonal scales
/// by exactly `factor`. `factor < 1` zooms in. Same failure modes as `zoomAbout`.
pub fn zoomCentered(v: SquareView, point: Complex, factor: f64) ViewportError!SquareView {
    return SquareView.fromCenterSide(point, v.side * factor);
}

/// Translate the view by a PIXEL delta measured on a square image of side `image_side` px,
/// keeping the side (and so the magnification) unchanged. The delta moves the VIEW, not the
/// content: `(+S, 0)` shifts the view right by exactly one image width and `(0, +S)` shifts
/// it DOWN by one image height (`im` decreases, because pixel-y grows down while `im` grows
/// up). A grab-and-drag gesture therefore passes the NEGATED mouse delta so the content
/// follows the cursor. `DegenerateRegion` for a non-finite delta or `image_side == 0` (a
/// minimized window) — the latter is an error rather than T1's debug assert because it
/// arrives from live window state.
pub fn panByPixels(v: SquareView, dpx: f64, dpy: f64, image_side: u32) ViewportError!SquareView {
    if (image_side == 0) return ViewportError.DegenerateRegion;
    // One definition of complex-units-per-pixel: T1's image bridge, not a local formula.
    const scale = v.imageViewport(image_side).scale;
    const new_center = Complex{
        .re = v.center_re + dpx * scale,
        .im = v.center_im - dpy * scale,
    };
    return SquareView.fromCenterSide(new_center, v.side);
}

/// The view a rubber-band selection commits to: map the drag's two corner PIXELS (any two
/// opposite corners, in any order, on a square image of side `image_side` px) through T1's
/// mapping and snap the result to the square that CONTAINS them — `fromCorners` grows the
/// shorter axis only, so the selection is never cropped and never distorted (plan A1).
/// A drag along a single axis is still usable (the other axis supplies the side); only a
/// genuinely zero-area selection (a click with no drag) is a `DegenerateRegion`, as is a
/// non-finite corner or `image_side == 0`.
pub fn boxSelect(v: SquareView, a: Pixel, b: Pixel, image_side: u32) ViewportError!SquareView {
    if (image_side == 0) return ViewportError.DegenerateRegion;
    return SquareView.fromCorners(
        v.pixelToComplex(a.x, a.y, image_side),
        v.pixelToComplex(b.x, b.y, image_side),
    );
}

/// The home view the "Reset" action returns to: T1's `SquareView.defaultView()` (the square
/// containing the M0 fixed region). Always valid, so no error union.
pub fn reset() SquareView {
    return SquareView.defaultView();
}

/// Side below which f64 coordinate arithmetic visibly quantizes (milestone non-goal: fixing
/// it needs arbitrary precision, which is M7). A view around |re| ≈ 1 has ~1e-16 absolute
/// resolution, so a side of 1e-13 leaves only ~3 significant digits across the image — the
/// documented warning threshold, not a hard stop.
pub const precision_floor_side: f64 = 1.0e-13;

/// Whether `v` is zoomed past `precision_floor_side` and will therefore render blocky. The
/// comparison is strict, so the floor value itself still counts as usable. Callers (T6/T7)
/// warn with `precisionFloorMessage` and keep going — this is deliberately NOT an error, so
/// a deep zoom is never silently refused. Precondition: a view from T1's constructors, i.e.
/// a finite positive side (they reject anything else).
pub fn atPrecisionFloor(v: SquareView) bool {
    return v.side < precision_floor_side;
}

const floor_prefix = "precision floor reached: side=";
/// The limit is rendered from `precision_floor_side` at comptime, so the wording can never
/// disagree with the predicate.
const floor_suffix = std.fmt.comptimePrint(
    " is below the f64 limit {e}; the image quantizes into blocks from here, " ++
        "so zoom out or reset the view",
    .{precision_floor_side},
);

/// Buffer size that fits ANY `precisionFloorMessage` result: the fixed wording plus the
/// widest `{e}` rendering of an f64 (`viewport.max_float_chars`). Exactly the worst case,
/// pinned by a test; a shorter buffer returns `error.NoSpaceLeft`.
pub const floor_message_buf_len: usize =
    floor_prefix.len + viewport.max_float_chars + floor_suffix.len;

/// The human-actionable warning for a view at the precision floor: names the offending side,
/// the limit it crossed, what the user will see and what to do about it. `{e}` bounds the
/// number the same way `viewport.degenerateRegionMessage` does (a `{d}` subnormal would run
/// to hundreds of digits). Pure so the wording is unit-tested once and reused by every edge
/// that logs it (`std.log.warn` in T6/T7); pass a `[floor_message_buf_len]u8`. The error set is
/// spelled out rather than inferred so callers can switch on it exhaustively.
pub fn precisionFloorMessage(buf: []u8, side: f64) error{NoSpaceLeft}![]u8 {
    return std.fmt.bufPrint(buf, floor_prefix ++ "{e}" ++ floor_suffix, .{side});
}

// ─── Tests ───────────────────────────────────────────────────────────────────
//
// `S = 512` (a power of two) against the default view's side 3.5 makes one pixel worth
// exactly `3.5/512 = 7·2^-10` complex units, so the expected values below are exact in
// binary f64 and can be asserted with `expectEqual` rather than a tolerance. They are
// spelled out as literals (not read back from the code under test) wherever the value is
// the point of the test.
const test_side: u32 = 512;
const test_side_f: f64 = @floatFromInt(test_side);

// A DEEP, OFF-CENTER view at an image side that is NOT `test_side` — the fixture that proves
// the transforms read the view and `image_side` they are HANDED, rather than the default view
// or a hard-coded 512 (every other case here starts from `defaultView()` at 512, where those
// two mistakes are invisible). `1e-3 / 256` is exact (a power-of-two division), but neither the
// center nor `1e-3` is dyadic, so the expected literals in the two tests below are NOT nice
// decimals: they were computed independently in IEEE-754 double precision from T1's documented
// formulas, in the same operation order, not read back from the code under test.
const deep_center = Complex{ .re = -0.743, .im = 0.131 };
const deep_side: f64 = 1.0e-3;
const deep_image_side: u32 = 256;

/// The widest `{e}` rendering an f64 can produce (24 chars) — the worst case for the
/// warning message's buffer. Same value T1 brute-forced for `degenerateRegionMessage`.
const widest_float: f64 = -1.3508404415422605e-270;

test "zoomAbout with the zoom-in step halves the side" {
    const v = SquareView.defaultView();
    const zoomed = try zoomAbout(v, .{ .re = -1.0, .im = 0.25 }, zoom_step_in);
    try std.testing.expectEqual(@as(f64, 1.75), zoomed.side);
}

test "zoomAbout keeps the anchor under the same pixel when zooming in" {
    const v = SquareView.defaultView();
    const anchor = v.pixelToComplex(100.5, 400.5, test_side);
    const zoomed = try zoomAbout(v, anchor, zoom_step_in);
    const after = zoomed.complexToPixel(anchor, test_side);
    try std.testing.expectApproxEqAbs(@as(f64, 100.5), after.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 400.5), after.y, 1e-9);
}

test "zoomAbout keeps the anchor under the same pixel when zooming out" {
    const v = SquareView.defaultView();
    const anchor = v.pixelToComplex(5.5, 500.5, test_side);
    const zoomed = try zoomAbout(v, anchor, zoom_step_out);
    const after = zoomed.complexToPixel(anchor, test_side);
    try std.testing.expectApproxEqAbs(@as(f64, 5.5), after.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 500.5), after.y, 1e-9);
}

test "zoomAbout the view center moves the center nowhere" {
    const v = SquareView.defaultView();
    const zoomed = try zoomAbout(v, v.center(), 0.25);
    try std.testing.expectEqual(v.center_re, zoomed.center_re);
    try std.testing.expectEqual(v.center_im, zoomed.center_im);
}

test "zoomAbout in then out about the same anchor restores the view" {
    const v = SquareView.defaultView();
    const anchor = v.pixelToComplex(320.5, 96.5, test_side);
    const there = try zoomAbout(v, anchor, zoom_step_in);
    const back = try zoomAbout(there, anchor, zoom_step_out);
    try std.testing.expectEqual(v.side, back.side);
    try std.testing.expectApproxEqAbs(v.center_re, back.center_re, 1e-15);
    try std.testing.expectApproxEqAbs(v.center_im, back.center_im, 1e-15);
}

test "zoomAbout rejects a non-finite anchor" {
    const v = SquareView.defaultView();
    const nan = std.math.nan(f64);
    try std.testing.expectError(ViewportError.DegenerateRegion, zoomAbout(v, .{ .re = nan, .im = 0.0 }, 0.5));
    try std.testing.expectError(ViewportError.DegenerateRegion, zoomAbout(v, .{ .re = 0.0, .im = std.math.inf(f64) }, 0.5));
}

test "zoomAbout rejects a non-positive or non-finite factor" {
    const v = SquareView.defaultView();
    const anchor = Complex{ .re = -0.5, .im = 0.0 };
    try std.testing.expectError(ViewportError.DegenerateRegion, zoomAbout(v, anchor, 0.0));
    try std.testing.expectError(ViewportError.DegenerateRegion, zoomAbout(v, anchor, -0.5));
    try std.testing.expectError(ViewportError.DegenerateRegion, zoomAbout(v, anchor, std.math.nan(f64)));
    try std.testing.expectError(ViewportError.DegenerateRegion, zoomAbout(v, anchor, std.math.inf(f64)));
}

test "zoomAbout rejects a factor that underflows the side to zero" {
    const origin = Complex{ .re = 0.0, .im = 0.0 };
    const v = try SquareView.fromCenterSide(origin, 1.0e-300);
    // 1e-300 · 1e-100 is below the smallest subnormal, so the side collapses to 0.
    try std.testing.expectError(ViewportError.DegenerateRegion, zoomAbout(v, origin, 1.0e-100));
}

test "zoomAbout rejects a factor that overflows the side to infinity" {
    const origin = Complex{ .re = 0.0, .im = 0.0 };
    const v = try SquareView.fromCenterSide(origin, 1.0e300);
    try std.testing.expectError(ViewportError.DegenerateRegion, zoomAbout(v, origin, 1.0e100));
}

test "zoomCentered makes the given point the new center" {
    const v = SquareView.defaultView();
    const p = Complex{ .re = -0.743643887037151, .im = 0.131825904205330 };
    const zoomed = try zoomCentered(v, p, zoom_step_in);
    try std.testing.expectEqual(p.re, zoomed.center_re);
    try std.testing.expectEqual(p.im, zoomed.center_im);
}

test "zoomCentered with the zoom-in step halves the side" {
    const zoomed = try zoomCentered(SquareView.defaultView(), .{ .re = -0.5, .im = 0.5 }, zoom_step_in);
    try std.testing.expectEqual(@as(f64, 1.75), zoomed.side);
}

test "zoomCentered with the zoom-out step doubles the side" {
    const zoomed = try zoomCentered(SquareView.defaultView(), .{ .re = -0.5, .im = 0.5 }, zoom_step_out);
    try std.testing.expectEqual(@as(f64, 7.0), zoomed.side);
}

test "zoomCentered scales the diagonal by exactly the factor" {
    const v = SquareView.defaultView();
    const p = Complex{ .re = -0.5, .im = 0.5 };
    // magnification = 1/|diagonal| (plan A3), so multiplying the diagonal by `factor`
    // is exactly dividing the magnification by it.
    const in = try zoomCentered(v, p, zoom_step_in);
    const out = try zoomCentered(v, p, zoom_step_out);
    try std.testing.expectEqual(v.magnification() * 2.0, in.magnification());
    try std.testing.expectEqual(v.magnification() / 2.0, out.magnification());
}

test "zoomCentered rejects a non-finite point" {
    const v = SquareView.defaultView();
    const nan = std.math.nan(f64);
    try std.testing.expectError(ViewportError.DegenerateRegion, zoomCentered(v, .{ .re = nan, .im = 0.0 }, 0.5));
    try std.testing.expectError(ViewportError.DegenerateRegion, zoomCentered(v, .{ .re = 0.0, .im = -std.math.inf(f64) }, 0.5));
}

test "zoomCentered rejects a non-positive or non-finite factor" {
    const v = SquareView.defaultView();
    const p = Complex{ .re = -0.5, .im = 0.5 };
    try std.testing.expectError(ViewportError.DegenerateRegion, zoomCentered(v, p, 0.0));
    try std.testing.expectError(ViewportError.DegenerateRegion, zoomCentered(v, p, -2.0));
    try std.testing.expectError(ViewportError.DegenerateRegion, zoomCentered(v, p, std.math.nan(f64)));
    try std.testing.expectError(ViewportError.DegenerateRegion, zoomCentered(v, p, std.math.inf(f64)));
}

test "the two zoom steps are reciprocal so a 2x in undoes a 2x out" {
    try std.testing.expectEqual(@as(f64, 1.0), zoom_step_in * zoom_step_out);
}

test "panByPixels by the full image width shifts the view by exactly one width" {
    const v = SquareView.defaultView();
    const panned = try panByPixels(v, test_side_f, 0.0, test_side);
    try std.testing.expectEqual(@as(f64, 2.75), panned.center_re); // -0.75 + 3.5
    try std.testing.expectEqual(v.center_im, panned.center_im);
}

test "panByPixels leaves the side, and therefore the magnification, untouched" {
    const v = SquareView.defaultView();
    const panned = try panByPixels(v, 37.0, -19.0, test_side);
    try std.testing.expectEqual(v.side, panned.side);
}

test "panByPixels with a positive pixel-y delta moves the view down the complex plane" {
    const v = SquareView.defaultView();
    // 128 px down at 3.5/512 per pixel = 0.875 lower in `im` (pixel-y grows DOWN).
    const panned = try panByPixels(v, 0.0, 128.0, test_side);
    try std.testing.expectEqual(@as(f64, -0.875), panned.center_im);
    try std.testing.expectEqual(v.center_re, panned.center_re);
}

test "panByPixels shifts the image content by exactly the pixel delta" {
    const v = SquareView.defaultView();
    const dpx: f64 = 37.0;
    const dpy: f64 = -19.0;
    const panned = try panByPixels(v, dpx, dpy, test_side);
    // A point drawn at pixel p before the pan is drawn at p - delta after it.
    const point = v.pixelToComplex(200.5, 300.5, test_side);
    const after = panned.complexToPixel(point, test_side);
    try std.testing.expectApproxEqAbs(200.5 - dpx, after.x, 1e-9);
    try std.testing.expectApproxEqAbs(300.5 - dpy, after.y, 1e-9);
}

test "panByPixels with a zero delta returns an identical view" {
    const v = SquareView.defaultView();
    try std.testing.expectEqual(v, try panByPixels(v, 0.0, 0.0, test_side));
}

test "panByPixels rejects a zero image side instead of asserting" {
    try std.testing.expectError(
        ViewportError.DegenerateRegion,
        panByPixels(SquareView.defaultView(), 4.0, 4.0, 0),
    );
}

test "panByPixels rejects a non-finite pixel delta" {
    const v = SquareView.defaultView();
    try std.testing.expectError(ViewportError.DegenerateRegion, panByPixels(v, std.math.nan(f64), 0.0, test_side));
    try std.testing.expectError(ViewportError.DegenerateRegion, panByPixels(v, 0.0, std.math.inf(f64), test_side));
}

test "panByPixels rejects a pixel delta that overflows the center" {
    const v = try SquareView.fromCenterSide(.{ .re = 0.0, .im = 0.0 }, 1.0e300);
    // At S = 1 one pixel spans 1e300 units, so a 1e10 px delta leaves f64's range.
    try std.testing.expectError(ViewportError.DegenerateRegion, panByPixels(v, 1.0e10, 0.0, 1));
}

test "panByPixels moves the center of a deep off-center view at its own image side" {
    const v = try SquareView.fromCenterSide(deep_center, deep_side);
    // One pixel is 1e-3/256 = 3.90625e-6 units here, so +64 px right is +2.5e-4 in `re` and
    // -32 px (up the screen) is +1.25e-4 in `im`.
    const panned = try panByPixels(v, 64.0, -32.0, deep_image_side);
    try std.testing.expectEqual(@as(f64, -0.74275), panned.center_re);
    try std.testing.expectEqual(@as(f64, 0.131125), panned.center_im);
}

// A NON-square drag on the deep off-center view above, at `deep_image_side`: 160 px wide by
// 120 px tall, so the square takes its side from the horizontal axis. The expected side is
// a fraction of a ULP at the corners' magnitude short of 160 · 1e-3/256 = 6.25e-4 because
// differencing two corners so close together cancels — hence the long literal.
const deep_drag_a = Pixel{ .x = 40.0, .y = 60.0 };
const deep_drag_b = Pixel{ .x = 200.0, .y = 180.0 };

test "boxSelect maps the drag through the given view at the given image side" {
    const v = try SquareView.fromCenterSide(deep_center, deep_side);
    const selected = try boxSelect(v, deep_drag_a, deep_drag_b, deep_image_side);
    // Mapping through the default view instead would give side ≈ 2.1875 (3500× too wide);
    // mapping at 512 instead of 256 would halve every number here.
    try std.testing.expectEqual(@as(f64, -0.74303125), selected.center_re);
    try std.testing.expectEqual(@as(f64, 0.13103125), selected.center_im);
    try std.testing.expectEqual(@as(f64, 0.0006249999999999867), selected.side);
}

// A deliberately NON-square drag on the default view at `test_side`: 300 px wide by
// 100 px tall. One pixel is 3.5/512 = 0.0068359375 complex units, so the enclosing square
// has side 300 · 0.0068359375 = 2.05078125 (the longer, horizontal axis) and is centered
// on the drag's midpoint pixel (250, 200) ⇒ (-0.791015625, +0.3828125).
const drag_a = Pixel{ .x = 100.0, .y = 150.0 };
const drag_b = Pixel{ .x = 400.0, .y = 250.0 };

test "boxSelect snaps a non-square selection to a square sized by its longer axis" {
    const selected = try boxSelect(SquareView.defaultView(), drag_a, drag_b, test_side);
    try std.testing.expectEqual(@as(f64, 2.05078125), selected.side);
}

test "boxSelect centers the new view on the selection midpoint" {
    const selected = try boxSelect(SquareView.defaultView(), drag_a, drag_b, test_side);
    try std.testing.expectEqual(@as(f64, -0.791015625), selected.center_re);
    try std.testing.expectEqual(@as(f64, 0.3828125), selected.center_im);
}

test "boxSelect contains the selection, expanding only the shorter axis" {
    const v = SquareView.defaultView();
    const selected = try boxSelect(v, drag_a, drag_b, test_side);
    const c = selected.corners();
    const top_left = v.pixelToComplex(drag_a.x, drag_a.y, test_side);
    const bottom_right = v.pixelToComplex(drag_b.x, drag_b.y, test_side);
    // Longer (horizontal) axis: untouched, so the selection's re bounds are the square's.
    try std.testing.expectEqual(top_left.re, c.min.re);
    try std.testing.expectEqual(bottom_right.re, c.max.re);
    // Shorter (vertical) axis: grown on both sides, so the selection stays strictly inside.
    try std.testing.expect(c.min.im < bottom_right.im);
    try std.testing.expect(c.max.im > top_left.im);
}

// The MIRROR drag: 100 px wide by 300 px tall, i.e. PORTRAIT, so the enclosing square must
// take its side from the VERTICAL axis (300 · 3.5/512 = 2.05078125) and grow the `re` bounds
// instead. Without this case the larger-axis rule is only ever exercised on its horizontal
// branch through `boxSelect`, and an implementation that sized the square from `|Δre|` alone —
// cropping a tall selection, which plan A1 forbids — would pass. Midpoint pixel (250, 250)
// ⇒ center (-0.791015625, +0.041015625).
const tall_drag_a = Pixel{ .x = 200.0, .y = 100.0 };
const tall_drag_b = Pixel{ .x = 300.0, .y = 400.0 };

test "boxSelect sizes a taller-than-wide selection from its vertical axis" {
    const selected = try boxSelect(SquareView.defaultView(), tall_drag_a, tall_drag_b, test_side);
    // The 300 px height, not the 100 px width (which would give 0.68359375).
    try std.testing.expectEqual(@as(f64, 2.05078125), selected.side);
}

test "boxSelect contains a taller-than-wide selection, expanding only the horizontal axis" {
    const v = SquareView.defaultView();
    const selected = try boxSelect(v, tall_drag_a, tall_drag_b, test_side);
    const c = selected.corners();
    const top_left = v.pixelToComplex(tall_drag_a.x, tall_drag_a.y, test_side);
    const bottom_right = v.pixelToComplex(tall_drag_b.x, tall_drag_b.y, test_side);
    // Longer (vertical) axis: untouched, so the selection's im bounds ARE the square's.
    try std.testing.expectEqual(bottom_right.im, c.min.im);
    try std.testing.expectEqual(top_left.im, c.max.im);
    // Shorter (horizontal) axis: grown by (2.05078125 - 0.68359375)/2 on each side, equally.
    try std.testing.expectEqual(@as(f64, 0.68359375), top_left.re - c.min.re);
    try std.testing.expectEqual(@as(f64, 0.68359375), c.max.re - bottom_right.re);
}

test "boxSelect accepts the drag corners in either order" {
    const v = SquareView.defaultView();
    try std.testing.expectEqual(
        try boxSelect(v, drag_a, drag_b, test_side),
        try boxSelect(v, drag_b, drag_a, test_side),
    );
}

test "boxSelect rejects a zero-area selection from a click without a drag" {
    const p = Pixel{ .x = 256.0, .y = 256.0 };
    try std.testing.expectError(
        ViewportError.DegenerateRegion,
        boxSelect(SquareView.defaultView(), p, p, test_side),
    );
}

test "boxSelect keeps a zero-height drag usable by sizing it on the horizontal axis" {
    // 128 px wide, 0 px tall ⇒ side 128 · 3.5/512 = 0.875, not a rejection.
    const selected = try boxSelect(
        SquareView.defaultView(),
        .{ .x = 100.0, .y = 200.0 },
        .{ .x = 228.0, .y = 200.0 },
        test_side,
    );
    try std.testing.expectEqual(@as(f64, 0.875), selected.side);
}

test "boxSelect rejects a zero image side instead of asserting" {
    try std.testing.expectError(
        ViewportError.DegenerateRegion,
        boxSelect(SquareView.defaultView(), drag_a, drag_b, 0),
    );
}

test "boxSelect rejects a non-finite pixel corner" {
    const v = SquareView.defaultView();
    const nan_corner = Pixel{ .x = std.math.nan(f64), .y = 10.0 };
    const inf_corner = Pixel{ .x = 10.0, .y = std.math.inf(f64) };
    try std.testing.expectError(ViewportError.DegenerateRegion, boxSelect(v, nan_corner, drag_b, test_side));
    try std.testing.expectError(ViewportError.DegenerateRegion, boxSelect(v, drag_a, inf_corner, test_side));
}

test "reset returns the default view" {
    try std.testing.expectEqual(SquareView.defaultView(), reset());
}

test "atPrecisionFloor flags a side below the f64 precision floor" {
    const v = try SquareView.fromCenterSide(.{ .re = -0.75, .im = 0.0 }, 1.0e-14);
    try std.testing.expect(atPrecisionFloor(v));
}

test "atPrecisionFloor does not flag the default view" {
    try std.testing.expect(!atPrecisionFloor(SquareView.defaultView()));
}

test "atPrecisionFloor does not flag a side just above the floor" {
    const shallow = try SquareView.fromCenterSide(.{ .re = -0.75, .im = 0.0 }, 1.0e-12);
    try std.testing.expect(!atPrecisionFloor(shallow));
}

test "atPrecisionFloor puts the boundary one ULP below the floor value" {
    const center = Complex{ .re = -0.75, .im = 0.0 };
    const at_floor = try SquareView.fromCenterSide(center, precision_floor_side);
    try std.testing.expect(!atPrecisionFloor(at_floor));
    const one_ulp_below: f64 = @bitCast(@as(u64, @bitCast(precision_floor_side)) - 1);
    const below = try SquareView.fromCenterSide(center, one_ulp_below);
    try std.testing.expect(atPrecisionFloor(below));
}

test "a zoom that crosses the precision floor still succeeds but is flagged" {
    // 3.5 · 2^-45 ≈ 9.9476e-14 — the first power-of-two zoom step below the floor.
    const deep = try zoomCentered(
        SquareView.defaultView(),
        .{ .re = -0.75, .im = 0.0 },
        std.math.ldexp(@as(f64, 1.0), -45),
    );
    try std.testing.expect(deep.side < precision_floor_side);
    try std.testing.expect(atPrecisionFloor(deep));
}

test "precisionFloorMessage names the offending side, the limit and what to do" {
    var buf: [floor_message_buf_len]u8 = undefined;
    const msg = try precisionFloorMessage(&buf, 9.9e-14);
    try std.testing.expectEqualStrings(
        "precision floor reached: side=9.9e-14 is below the f64 limit 1e-13; " ++
            "the image quantizes into blocks from here, so zoom out or reset the view",
        msg,
    );
}

test "floor_message_buf_len is exactly the worst-case message length" {
    var buf: [floor_message_buf_len]u8 = undefined;
    const msg = try precisionFloorMessage(&buf, widest_float);
    try std.testing.expectEqual(floor_message_buf_len, msg.len);
}

test "precisionFloorMessage reports NoSpaceLeft instead of truncating" {
    var buf: [floor_message_buf_len - 1]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, precisionFloorMessage(&buf, widest_float));
}
