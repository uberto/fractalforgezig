//! Pure viewport ↔ complex-plane mapping. NO SDL/GPU imports — this lives in the
//! fast test tier (`zig build test`, no window/device) and is fully unit-tested.
//!
//! Coordinate convention (get this right or the set flips vertically downstream):
//!   * Pixel space: origin top-left, x grows right, y grows DOWN. `(px, py)` are
//!     continuous sample coordinates where `(0, 0)` is the top-left corner of the
//!     top-left pixel and `(w, h)` the bottom-right corner of the image. Integer
//!     `+ 0.5` therefore lands on a pixel center (T4/T6's concern, not here).
//!   * Complex space: `re` grows right, `im` grows UP. So pixel-y and complex-im
//!     point in OPPOSITE directions — the mapping negates the y term.
//!
//! PRECISION SPLIT (M6, and the rule the whole deep-zoom milestone rests on):
//!   * `ComplexHi` (`f128`, ~34 significant decimals) says WHERE THE VIEW IS —
//!     `SquareView.center_re/center_im`, the gesture anchors, the readout, the save file.
//!   * `Complex` / `Viewport` (`f64`) say where a PIXEL IS RELATIVE TO the view — the
//!     per-pixel rect mapping `iterbuf` iterates over.
//! `f128` is SOFTWARE-EMULATED on arm64 (~100× slower than `f64`), so it must never enter
//! a per-pixel loop: a handful of `f128` operations per frame is free, one per pixel is
//! catastrophic. Every `*Hi` mapping here therefore computes the pixel's OFFSET in `f64`
//! and does the single widening ADDITION onto the `f128` center. `side` stays `f64` — at
//! 1e-30 a side still carries ~16 significant digits, only the center needs more.
const std = @import("std");

/// A point on the complex plane in `f64` — the PER-PIXEL type. Plain data, no methods: the
/// fractal core reads `re`/`im` directly. Use this for anything inside (or one step away
/// from) an iteration loop; use `ComplexHi` for a view-level position.
pub const Complex = struct {
    re: f64,
    im: f64,
};

/// A point on the complex plane in `f128` — the VIEW-LEVEL type (~34 significant decimals,
/// enough to distinguish neighbouring pixels down to side 1e-30). Same shape as `Complex`,
/// so an anonymous `.{ .re = …, .im = … }` literal builds either.
///
/// Costs: `f128` arithmetic is emulated in software here, so keep it to a handful of
/// operations per frame (a view center, a gesture anchor, a readout) and NEVER put it in a
/// per-pixel loop. `lo()` is the one-way door back to the fast `f64` world.
pub const ComplexHi = struct {
    re: f128,
    im: f128,

    /// This point rounded to the `f64` `Complex` the per-pixel paths use. Lossy by
    /// construction — call it only where the extra digits genuinely cannot matter (a
    /// GPU uniform, a hit-test against an already-`f64` render buffer).
    pub fn lo(self: ComplexHi) Complex {
        return .{ .re = @floatCast(self.re), .im = @floatCast(self.im) };
    }
};

/// The fixed M0 target region on the complex plane (M0 non-goal: no navigation). M3 keeps
/// it as the *home* region: `SquareView.defaultView()` is the square that contains it.
pub const fixed_re_min: f64 = -2.5;
pub const fixed_re_max: f64 = 1.0;
pub const fixed_im_min: f64 = -1.25;
pub const fixed_im_max: f64 = 1.25;

/// Rejected view geometry. Returned (never logged — this module is log-free, see
/// `src/fractal/context.md`) so the edge that accepted the input (T7's coordinate panel,
/// T6's gestures) logs `std.log.err` and shows the user a message; build that message
/// with `degenerateRegionMessage` so there is exactly one wording.
pub const ViewportError = error{
    /// The requested region has no usable extent: a zero/negative/non-finite side or
    /// magnification, or two identical corners.
    DegenerateRegion,
};

/// The M3 model: the region of the complex plane the fractal is rendered from, always a
/// SQUARE (plan A1: aspect == 1, so a letterboxed square image is never distorted).
/// A plain value — every transform (T2) returns a NEW `SquareView`.
///
/// Two equivalent, lossless representations (plan A3), both editable in T7's panel:
///   * **center + magnification** — `centerMag()` / `fromCenterMag()`, where
///     `magnification = 1 / |diagonal| = 1 / (side · √2)` and therefore
///     `side = 1 / (magnification · √2)`. Halving the side doubles the magnification.
///   * **two opposite corners** — `corners()` / `fromCorners()`; a non-square input
///     rectangle is SNAPPED to the square that contains it (side = the larger of
///     `|Δre|`, `|Δim|`, centered on the midpoint of the two inputs), so a selection is
///     expanded on at most one axis and never distorted.
///
/// Pixels come in only as a square image side `S` (px): the view carries no resolution
/// (plan A2 — `S = min(window_w, window_h)`, chosen by T5). See `pixelToComplex`.
///
/// M6: `center_re`/`center_im` are `f128` and `side` stays `f64` (see the file header's
/// precision split). Keep precision-sensitive math inside this struct; callers that need an
/// `f64` center ask for `centerLo()` and thereby say, in writing, that they accept the loss.
pub const SquareView = struct {
    center_re: f128,
    center_im: f128,
    /// Side length of the square region in complex-plane units. Always finite and > 0
    /// for a view built through the constructors below. `f64`: a side of 1e-30 still has
    /// ~16 significant digits, so widening it would buy nothing.
    side: f64,

    /// The default (home) view: the smallest square CONTAINING the M0 fixed region,
    /// i.e. center `(-0.75, 0)`, side 3.5 (the larger axis, `|Δre|`), so
    /// `re ∈ [-2.5, 1.0]`, `im ∈ [-1.75, 1.75]`, magnification `1/(3.5·√2) ≈ 0.2020305`.
    /// Always valid, so it needs no error union; T2's `reset()` returns exactly this.
    pub fn defaultView() SquareView {
        return .{
            .center_re = (fixed_re_min + fixed_re_max) / 2.0,
            .center_im = (fixed_im_min + fixed_im_max) / 2.0,
            .side = @max(fixed_re_max - fixed_re_min, fixed_im_max - fixed_im_min),
        };
    }

    /// The validating constructor every other one funnels into: rejects a non-finite
    /// center and a side that is not finite and positive. Takes the center at FULL
    /// precision — a 34-decimal center given here comes back out of `center()` unchanged.
    pub fn fromCenterSide(center_point: ComplexHi, side: f64) ViewportError!SquareView {
        if (!isFiniteComplexHi(center_point)) return ViewportError.DegenerateRegion;
        if (!std.math.isFinite(side) or side <= 0.0) return ViewportError.DegenerateRegion;
        return .{ .center_re = center_point.re, .center_im = center_point.im, .side = side };
    }

    /// The view's center on the complex plane, at full precision. This is what the readout,
    /// the save file and the gesture anchors must carry.
    pub fn center(self: SquareView) ComplexHi {
        return .{ .re = self.center_re, .im = self.center_im };
    }

    /// The view's center rounded to `f64`, for the few consumers that genuinely cannot use
    /// more: the GPU uniform conversion and the `Viewport` bridges below (the per-pixel rect
    /// mapping). Everything else wants `center()`.
    pub fn centerLo(self: SquareView) Complex {
        return self.center().lo();
    }

    /// Unitless zoom scalar, `1 / |diagonal| = 1 / (side · √2)` (plan A3). T3's adaptive
    /// `max_iter` heuristic and T7's panel both read this — do not recompute it.
    pub fn magnification(self: SquareView) f64 {
        return 1.0 / (self.side * sqrt2);
    }

    /// This view in center + magnification form.
    pub fn centerMag(self: SquareView) CenterMag {
        return .{ .center = self.center(), .magnification = self.magnification() };
    }

    /// Build a view from center + magnification: `side = 1 / (magnification · √2)`.
    pub fn fromCenterMag(cm: CenterMag) ViewportError!SquareView {
        if (!std.math.isFinite(cm.magnification) or cm.magnification <= 0.0) {
            return ViewportError.DegenerateRegion;
        }
        return fromCenterSide(cm.center, 1.0 / (cm.magnification * sqrt2));
    }

    /// This view as its two opposite corners: `min` = bottom-left (min re, min im),
    /// `max` = top-right (max re, max im).
    pub fn corners(self: SquareView) Corners {
        const h: f128 = @as(f128, self.side) / 2.0;
        return .{
            .min = .{ .re = self.center_re - h, .im = self.center_im - h },
            .max = .{ .re = self.center_re + h, .im = self.center_im + h },
        };
    }

    /// Build a view from any two opposite corners, in any order, SNAPPED to a square:
    /// `side = max(|Δre|, |Δim|)` centered on the midpoint of `a` and `b` (plan A1). The
    /// result therefore always contains the input rectangle, expanded on the shorter axis
    /// only. Identical corners (zero extent) are a `DegenerateRegion`.
    /// Both corners and the midpoint are carried at full precision, so a selection dragged
    /// inside a deep view keeps the digits that distinguish its two corners; only the SIDE
    /// (which needs no more than `f64`) is narrowed, after the differencing.
    pub fn fromCorners(a: ComplexHi, b: ComplexHi) ViewportError!SquareView {
        if (!isFiniteComplexHi(a) or !isFiniteComplexHi(b)) return ViewportError.DegenerateRegion;
        const side: f64 = @floatCast(@max(@abs(b.re - a.re), @abs(b.im - a.im)));
        const mid = ComplexHi{ .re = (a.re + b.re) / 2.0, .im = (a.im + b.im) / 2.0 };
        return fromCenterSide(mid, side);
    }

    /// Map an IMAGE-space pixel to the complex plane for a square image of side
    /// `image_side` px. `(0, 0)` is the top-left corner of the image and
    /// `(image_side, image_side)` its bottom-right corner, so pixel `(i + 0.5, j + 0.5)`
    /// is the center of pixel `(i, j)`. `py` is negated: pixel-y grows DOWN while `im`
    /// grows UP (see the file header). Precondition: `image_side > 0` — callers that may
    /// see a minimized window (T5/T6) go through `cursorCoord`, which is null-safe.
    /// `f64` throughout (the center is rounded FIRST, so the arithmetic is exactly what it
    /// was before the center widened): below ~1e-13 neighbouring pixels collapse onto the
    /// same value here. That is the whole reason `pixelToComplexHi` exists — use this one
    /// only for shallow work.
    pub fn pixelToComplex(self: SquareView, px: f64, py: f64, image_side: u32) Complex {
        std.debug.assert(image_side > 0);
        const s: f64 = @floatFromInt(image_side);
        const c = self.centerLo();
        return .{
            .re = c.re + (px / s - 0.5) * self.side,
            .im = c.im - (py / s - 0.5) * self.side,
        };
    }

    /// The FULL-PRECISION complex point a pixel of a square `image_side` image samples —
    /// the deep-zoom counterpart of `pixelToComplex`, and the gesture-anchor source at
    /// depth (`navigate.zoomAbout` / `zoomCentered`). Same geometry, same conventions.
    ///
    /// Cost: the pixel's OFFSET from the center is computed in `f64` (it is tiny and needs
    /// no more digits) and only the final addition onto the `f128` center is extended
    /// precision — two `f128` adds per call. Fine per gesture; NEVER call it per pixel.
    /// Precondition: `image_side > 0`.
    pub fn pixelToComplexHi(self: SquareView, px: f64, py: f64, image_side: u32) ComplexHi {
        std.debug.assert(image_side > 0);
        const s: f64 = @floatFromInt(image_side);
        const off_re = (px / s - 0.5) * self.side;
        const off_im = (py / s - 0.5) * self.side;
        return .{
            .re = self.center_re + @as(f128, off_re),
            .im = self.center_im - @as(f128, off_im),
        };
    }

    /// `pixelToComplexHi` through the RECTANGULAR mapping (`rectViewport`'s geometry: one
    /// shared `scale = side / min(w, h)`, so a non-square image shows more of the plane on
    /// its longer axis) — the full-precision anchor for anything that starts from a
    /// `w × h` on-screen image, i.e. `cursorCoord` and `navigate.boxSelect`. Same
    /// offset-in-`f64`, add-in-`f128` structure. Precondition: `w > 0` and `h > 0`.
    pub fn rectPixelToComplexHi(self: SquareView, px: f64, py: f64, w: u32, h: u32) ComplexHi {
        std.debug.assert(w > 0 and h > 0);
        const vp = self.rectViewport(w, h);
        const off_re = (px - @as(f64, @floatFromInt(w)) / 2.0) * vp.scale;
        const off_im = (py - @as(f64, @floatFromInt(h)) / 2.0) * vp.scale;
        return .{
            .re = self.center_re + @as(f128, off_re),
            .im = self.center_im - @as(f128, off_im),
        };
    }

    /// Inverse of `pixelToComplex` at the same `image_side`: the (continuous) image-space
    /// pixel a complex point lands on. Values outside `[0, image_side]` mean the point is
    /// outside the view. Precondition: `image_side > 0`.
    /// Stays `f64` (the center is rounded first): it answers "which pixel", and a pixel
    /// index never needs more than `f64`.
    pub fn complexToPixel(self: SquareView, c: Complex, image_side: u32) Pixel {
        std.debug.assert(image_side > 0);
        const s: f64 = @floatFromInt(image_side);
        const ctr = self.centerLo();
        return .{
            .x = ((c.re - ctr.re) / self.side + 0.5) * s,
            .y = ((ctr.im - c.im) / self.side + 0.5) * s,
        };
    }

    /// The complex value under a WINDOW-space pixel, mapped through the letterboxed
    /// image rect, or `null` when the pixel is on a letterbox bar (or the rect is
    /// degenerate, e.g. a minimized window). This is the hover-readout and gesture-anchor
    /// entry point: T6 feeds it raw mouse coordinates plus T5's image rect.
    /// Uses the full w×h rectangle for correct re-axis mapping on non-square images.
    ///
    /// Returns a `ComplexHi`: this is the gesture-anchor source, so at depth an `f64` return
    /// would round the anchor onto the view center and every scroll-zoom would silently snap
    /// the center back to double precision (see `navigate.zoomAbout`). Narrow with `lo()` for
    /// an `f64`-only consumer such as `Viewport.pixelIndex`.
    pub fn cursorCoord(self: SquareView, window_x: f64, window_y: f64, rect: ImageRect) ?ComplexHi {
        if (rect.w == 0 or rect.h == 0) return null;
        const p = rect.toImagePixel(window_x, window_y) orelse return null;
        return self.rectPixelToComplexHi(p.x, p.y, rect.w, rect.h);
    }

    /// Bridge to the M0/M2 `Viewport` for a square image. The center is NARROWED to `f64`
    /// here — `Viewport` is the per-pixel mapping and must stay `f64` (see the file header).
    /// Precondition: `image_side > 0`.
    pub fn imageViewport(self: SquareView, image_side: u32) Viewport {
        std.debug.assert(image_side > 0);
        const s: f64 = @floatFromInt(image_side);
        const c = self.centerLo();
        return .{
            .center_re = c.re,
            .center_im = c.im,
            .scale = self.side / s,
            .width = image_side,
            .height = image_side,
        };
    }

    /// Rectangular viewport: the view's complex square is mapped onto a `w × h` pixel
    /// region. Scale is chosen so the shorter axis exactly fits `self.side` complex units
    /// and the longer axis shows more of the plane (no letterboxing, no distortion).
    /// Precondition: `w > 0` and `h > 0`.
    ///
    /// The center is NARROWED to `f64`, which is correct for the SHALLOW render path this
    /// feeds (identical output to before the center widened) and is exactly why it cannot
    /// serve a deep render: T4 gives the deep path an offset-based mapping instead.
    pub fn rectViewport(self: SquareView, w: u32, h: u32) Viewport {
        std.debug.assert(w > 0 and h > 0);
        const scale = self.side / @as(f64, @floatFromInt(@min(w, h)));
        const c = self.centerLo();
        return .{
            .center_re = c.re,
            .center_im = c.im,
            .scale = scale,
            .width = w,
            .height = h,
        };
    }
};

/// `√2`, the diagonal-to-side ratio of a square — the constant in plan A3's
/// magnification formula. Computed at comptime.
const sqrt2: f64 = @sqrt(2.0);

fn isFiniteComplexHi(c: ComplexHi) bool {
    return std.math.isFinite(c.re) and std.math.isFinite(c.im);
}

/// The center + magnification form of a `SquareView` (see `SquareView.centerMag`). The
/// center is full precision; the magnification is `f64` because the side is.
pub const CenterMag = struct {
    center: ComplexHi,
    magnification: f64,
};

/// The two-opposite-corners form of a `SquareView`: `min` is bottom-left, `max` is
/// top-right (see `SquareView.corners`). Full precision: at depth the two corners differ
/// only in digits `f64` does not have.
pub const Corners = struct {
    min: ComplexHi,
    max: ComplexHi,
};

/// A continuous pixel coordinate (image or window space, whichever the API says).
pub const Pixel = struct {
    x: f64,
    y: f64,
};

/// The image region inside the window: top-left origin `(x, y)` in window pixels,
/// plus `w × h` dimensions. `side = min(w, h)` is kept for navigation geometry
/// (zoom/pan math always uses the square navigation side). A zero `side` means degenerate.
pub const ImageRect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    /// Navigation square side: `min(w, h)`. Used by `cursorCoord` / `pixelToComplex`.
    side: u32,

    /// Window-space pixel → image-space pixel, or `null` when outside the image.
    pub fn toImagePixel(self: ImageRect, window_x: f64, window_y: f64) ?Pixel {
        if (self.side == 0) return null;
        const ox: f64 = @floatFromInt(self.x);
        const oy: f64 = @floatFromInt(self.y);
        const px = window_x - ox;
        const py = window_y - oy;
        if (px < 0.0 or py < 0.0 or px >= @as(f64, @floatFromInt(self.w)) or py >= @as(f64, @floatFromInt(self.h))) return null;
        return .{ .x = px, .y = py };
    }
};

/// Decimals the coordinate readout shows at the shallowest zoom.
pub const min_coord_digits: usize = 4;

/// Decimal cap, and THE shared "how many digits does a center need" constant: `f128` carries
/// 113 mantissa bits ≈ 34 significant decimals, which is also exactly what a lossless decimal
/// round trip of an `f128` takes (`{d:.34}` → `parseFloat(f128, …)` is exact). Past this the
/// digits would be noise, and at side 1e-30 near |re| ≈ 1 they are all needed.
///
/// The readout (T7) and the save format (T8) MUST both format the center through this one
/// definition, or a saved location would not match the one on screen.
pub const max_coord_digits: usize = 34;

/// Integer digits the readout must fit: the Mandelbrot region lives well inside
/// |re|, |im| < 10. An absurd center needs more and returns `error.NoSpaceLeft`.
const max_coord_int_digits: usize = 1;

/// One signed coordinate at `max_coord_digits` decimals: sign, integer digits, the decimal
/// point, the decimals.
const coord_part_len: usize = 1 + max_coord_int_digits + 1 + max_coord_digits;

/// Buffer size that fits any `formatCoord` result for a view inside the Mandelbrot region,
/// pinned by a test: the signed real part, the `" + "` / `" - "` separator that CARRIES the
/// imaginary sign (so the imaginary part itself is unsigned, one byte shorter), and the
/// trailing `i`. An absurd center (|re| ≥ 10) needs more and returns `error.NoSpaceLeft`.
pub const coord_buf_len: usize =
    coord_part_len + " + ".len + (coord_part_len - 1) + "i".len;

/// Buffer size for ONE coordinate as EDITABLE, NULL-TERMINATED text: `coord_part_len` bytes
/// of digits plus the terminator, rounded up to 64 so an exponent form or a pasted extra
/// digit still fits. This is what the coordinate panel's text buffers (`ui/editor.zig`'s
/// `ViewEditor`) and any other full-precision center text must be sized from — never a
/// hand-written 32 or 40.
pub const coord_text_buf_len: usize = 64;

/// Decimals `formatCoord` uses at a given magnification. RULE:
/// `digits = clamp(min_coord_digits + ceil(log10(magnification)), min, max)`.
/// Rationale: the view spans `1/magnification` across its diagonal, so each extra decade
/// of zoom consumes one decimal digit before anything visible changes; adding
/// `min_coord_digits` on top keeps ~4 decimals of *sub-view* detail at every depth. A
/// non-finite or non-positive magnification is degenerate and falls back to the minimum.
pub fn coordDigits(magnification: f64) usize {
    if (!std.math.isFinite(magnification) or magnification <= 0.0) return min_coord_digits;
    const decades = @ceil(@log10(magnification));
    if (decades <= 0.0) return min_coord_digits;
    const headroom: f64 = @floatFromInt(max_coord_digits - min_coord_digits);
    if (decades >= headroom) return max_coord_digits;
    return min_coord_digits + @as(usize, @intFromFloat(decades));
}

/// Render a complex value for the coordinate readout as `"a + bi"` — or `"a - bi"` when
/// the imaginary part is negative, so the readout never shows `+ -0.5i`. The sign comes
/// from `std.math.signbit`, so `im = -0.0` reads `- 0.0000i` exactly like any tiny
/// negative value that rounds to zero at this precision. Precision comes
/// from `coordDigits(magnification)`, so the readout gains digits as the user zooms in.
/// Pure (writes only into `buf`) so the exact string is unit-tested; `buf` should be
/// `coord_buf_len` bytes — a short buffer returns `error.NoSpaceLeft` rather than
/// truncating.
///
/// Takes the center at FULL precision (`ComplexHi`) so the extra decimals `coordDigits`
/// asks for at depth are real digits rather than zeros: an `f64` argument would already
/// have thrown them away. Specified for views inside the Mandelbrot region — a magnitude
/// so absurd that `std.fmt` cannot render it in fixed notation prints its `(float)`
/// placeholder instead of erroring.
pub fn formatCoord(buf: []u8, c: ComplexHi, magnification: f64) ![]u8 {
    const digits = coordDigits(magnification);
    // signbit, NOT `< 0.0`: `-0.0 < 0.0` is false, which would print `+ -0.0000i`.
    const negative = std.math.signbit(c.im);
    return std.fmt.bufPrint(buf, "{[re]d:.[p]} {[sign]s} {[im]d:.[p]}i", .{
        .re = c.re,
        .sign = @as([]const u8, if (negative) "-" else "+"),
        .im = if (negative) -c.im else c.im,
        .p = digits,
    });
}

const degenerate_prefix = "rejected viewport: ";
const degenerate_suffix = " is not a finite positive extent; " ++
    "enter a positive magnification or two distinct corners";

/// Longest `what` label `degenerateRegionMessage` accepts within `message_buf_len`
/// (the shipped labels are `"magnification"`, `"side"`, `"corner extent"`, ≤ 13 bytes).
pub const max_what_len: usize = 16;

/// Widest `{e}` rendering of an f64: sign + leading digit + `.` + 16 more significant
/// digits + `e` + exponent sign + 3 exponent digits, e.g. `-1.3508404415422605e-270`.
/// This is what bounds the message: `{d}` would instead expand `5e-324` into 447 bytes.
/// Exported so the other pure message builders that embed an f64 (see
/// `navigate.floor_message_buf_len`) derive their buffer from the same measured bound.
pub const max_float_chars: usize = 24;

/// Buffer size that fits ANY `degenerateRegionMessage` result — the fixed wording, a
/// `what` up to `max_what_len` bytes and any f64 value, including `±floatMax` and
/// subnormals. Exactly the worst case, pinned by a test; a shorter buffer returns
/// `error.NoSpaceLeft`.
pub const message_buf_len: usize =
    degenerate_prefix.len + max_what_len + 1 + max_float_chars + degenerate_suffix.len;

/// The human-actionable message for a `ViewportError.DegenerateRegion`: `what` names the
/// offending input (`"magnification"`, `"side"`, `"corner extent"`) and `value` is what
/// arrived, rendered in scientific notation (`{e}`) so that a hostile magnitude such as
/// `-1e308` or `5e-324` stays a few characters instead of hundreds of digits — that keeps
/// the message inside `message_buf_len` on the very path that reports a failure. Pure so
/// the wording is unit-tested once and reused by every edge that logs `std.log.err` /
/// shows the user the rejection (T6, T7); pass a `[message_buf_len]u8`.
pub fn degenerateRegionMessage(buf: []u8, what: []const u8, value: f64) ![]u8 {
    return std.fmt.bufPrint(
        buf,
        degenerate_prefix ++ "{s}={e}" ++ degenerate_suffix,
        .{ what, value },
    );
}

// ─── Precision floor ─────────────────────────────────────────────────────────
//
// MOVED HERE (M6/T2) from `navigate.zig`: the floor is a property of what a VIEW can
// represent, which is this module's subject, and both this module and `navigate.zig` now need
// it. `navigate.zig` re-exports all four names, so its callers (and its own tests) keep using
// them unqualified. M6/T5 then lowered the VALUE to 1e-30; the behaviour is unchanged — still
// a warning, never a refusal.

/// Side below which coordinate arithmetic visibly quantizes: a view around |re| ≈ 1 has
/// ~1e-34 absolute resolution once the centre is `f128`, so a side of 1e-30 leaves only ~4
/// significant digits across the image — the documented warning threshold, not a hard stop.
///
/// M6/T5 moved this DOWN by 17 decades, from f64's 1e-13 to the extended-precision centre's
/// 1e-30, because f64 is no longer what binds: `perturb.zig` iterates a per-pixel *offset* in
/// f64 while the centre itself is `f128` (`max_coord_digits` ≈ 34 decimals), so the centre is
/// what quantizes first. Same "only a handful of digits left across the image" judgement the
/// old f64 bound made, applied to the representation that actually binds now.
pub const precision_floor_side: f64 = 1.0e-30;

/// Whether `v` is zoomed past `precision_floor_side` and will therefore render blocky. The
/// comparison is strict, so the floor value itself still counts as usable. Callers warn with
/// `precisionFloorMessage` and keep going — this is deliberately NOT an error, so a deep zoom
/// is never silently refused. Precondition: a view from the constructors above, i.e. a finite
/// positive side (they reject anything else).
pub fn atPrecisionFloor(v: SquareView) bool {
    return v.side < precision_floor_side;
}

const floor_prefix = "precision floor reached: side=";
/// The limit is rendered from `precision_floor_side` at comptime, so the wording can never
/// disagree with the predicate — and the buffer length below follows the wording's real size,
/// so lowering the floor cannot silently overflow the message.
///
/// It names the limit as "the deepest supported side" rather than M0's "the f64 limit": since
/// M6 the bound is the extended-precision centre, not f64, and a message naming f64 at 1e-30
/// would send the user looking for the wrong problem.
const floor_suffix = std.fmt.comptimePrint(
    " is below the deepest supported side {e}; the image quantizes into blocks from here, " ++
        "so zoom out or reset the view",
    .{precision_floor_side},
);

/// Buffer size that fits ANY `precisionFloorMessage` result: the fixed wording plus the
/// widest `{e}` rendering of an f64 (`max_float_chars`). Exactly the worst case, pinned by a
/// test; a shorter buffer returns `error.NoSpaceLeft`.
pub const floor_message_buf_len: usize =
    floor_prefix.len + max_float_chars + floor_suffix.len;

/// The human-actionable warning for a view at the precision floor: names the offending side,
/// the limit it crossed, what the user will see and what to do about it. `{e}` bounds the
/// number the same way `degenerateRegionMessage` does (a `{d}` subnormal would run to
/// hundreds of digits). Pure so the wording is unit-tested once and reused by every edge that
/// logs it (`std.log.warn` in `main.zig`); pass a `[floor_message_buf_len]u8`. The error set
/// is spelled out rather than inferred so callers can switch on it exhaustively.
pub fn precisionFloorMessage(buf: []u8, side: f64) error{NoSpaceLeft}![]u8 {
    return std.fmt.bufPrint(buf, floor_prefix ++ "{e}" ++ floor_suffix, .{side});
}

/// The IMAGE viewport `iterbuf`/`engine` iterate over: a region plus its pixel
/// dimensions, parameterized so pixels are square. M3's authoritative *model* is
/// `SquareView` (center + side, aspect 1, no resolution); build the matching image
/// viewport with `SquareView.imageViewport(S)` rather than deriving `scale` by hand.
/// `fixedView` remains the M0/M2 entry point for the non-square fixed view.
///
/// `scale` is the size of ONE pixel in complex-plane units, identical for both
/// axes — that single shared value is what keeps the mapping aspect-correct
/// (never stretched). `center_re`/`center_im` sit at the exact geometric center
/// of the image (pixel `(width/2, height/2)`).
pub const Viewport = struct {
    center_re: f64,
    center_im: f64,
    /// Complex-plane units per pixel. Shared across x and y ⇒ square pixels.
    scale: f64,
    width: u32,
    height: u32,

    /// Build the fixed M0 view for a given image size. Centers on the midpoint of
    /// the fixed target region and picks the smallest uniform `scale` that keeps
    /// the entire region visible (contain fit). When `width : height` equals the
    /// region's `3.5 : 2.5` aspect, the corners land exactly on the fixed bounds.
    /// Precondition: `width > 0` and `height > 0`.
    pub fn fixedView(width: u32, height: u32) Viewport {
        const re_range = fixed_re_max - fixed_re_min;
        const im_range = fixed_im_max - fixed_im_min;
        const w: f64 = @floatFromInt(width);
        const h: f64 = @floatFromInt(height);
        // Contain: the tighter (larger) per-pixel scale wins so nothing is cropped.
        const scale = @max(re_range / w, im_range / h);
        return .{
            .center_re = (fixed_re_min + fixed_re_max) / 2.0,
            .center_im = (fixed_im_min + fixed_im_max) / 2.0,
            .scale = scale,
            .width = width,
            .height = height,
        };
    }

    /// Map a pixel sample coordinate to the complex plane. Pure: no allocation, no
    /// global state, deterministic. `py` is negated so that increasing pixel-y
    /// (downward) yields decreasing `im` (the complex plane is y-up).
    pub fn pixelToComplex(self: Viewport, px: f64, py: f64) Complex {
        const w: f64 = @floatFromInt(self.width);
        const h: f64 = @floatFromInt(self.height);
        return .{
            .re = self.center_re + (px - w / 2.0) * self.scale,
            .im = self.center_im - (py - h / 2.0) * self.scale,
        };
    }

    /// Exact inverse of `pixelToComplex`: the (continuous) pixel a complex point samples.
    /// Values outside `[0, width] × [0, height]` mean the point is off this image. Needed
    /// because the render buffer is RECTANGULAR (`width × height`), so the square-view
    /// `SquareView.complexToPixel` would index it on the wrong stride — the status bar's
    /// iteration readout goes through here. Precondition: `scale != 0`.
    pub fn complexToPixel(self: Viewport, point: Complex) Pixel {
        const w: f64 = @floatFromInt(self.width);
        const h: f64 = @floatFromInt(self.height);
        return .{
            .x = (point.re - self.center_re) / self.scale + w / 2.0,
            .y = (self.center_im - point.im) / self.scale + h / 2.0,
        };
    }

    /// Index into a `width * height` row-major per-pixel buffer for a complex point, or
    /// null when the point falls outside the image. The clamp-free bounds check is what
    /// keeps a hover just past the image edge from reading a neighbouring row.
    pub fn pixelIndex(self: Viewport, point: Complex) ?usize {
        if (self.width == 0 or self.height == 0) return null;
        const p = self.complexToPixel(point);
        if (p.x < 0.0 or p.y < 0.0) return null;
        if (p.x >= @as(f64, @floatFromInt(self.width)) or p.y >= @as(f64, @floatFromInt(self.height))) return null;
        const col: usize = @intFromFloat(p.x);
        const row: usize = @intFromFloat(p.y);
        return row * self.width + col;
    }
};

test "fixedView centers on the midpoint of the fixed M0 bounds" {
    const vp = Viewport.fixedView(700, 500);
    try std.testing.expectApproxEqAbs(@as(f64, -0.75), vp.center_re, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), vp.center_im, 1e-12);
}

test "center pixel maps to the view's complex center" {
    const vp = Viewport.fixedView(700, 500);
    const c = vp.pixelToComplex(350.0, 250.0);
    try std.testing.expectApproxEqAbs(vp.center_re, c.re, 1e-12);
    try std.testing.expectApproxEqAbs(vp.center_im, c.im, 1e-12);
}

test "aspect-matched image maps the four pixel corners to the fixed complex bounds" {
    // 700:500 == 3.5:2.5, so corners land exactly on the fixed region.
    const vp = Viewport.fixedView(700, 500);

    const top_left = vp.pixelToComplex(0.0, 0.0);
    try std.testing.expectApproxEqAbs(fixed_re_min, top_left.re, 1e-9);
    try std.testing.expectApproxEqAbs(fixed_im_max, top_left.im, 1e-9); // top pixel = max im

    const bottom_right = vp.pixelToComplex(700.0, 500.0);
    try std.testing.expectApproxEqAbs(fixed_re_max, bottom_right.re, 1e-9);
    try std.testing.expectApproxEqAbs(fixed_im_min, bottom_right.im, 1e-9); // bottom pixel = min im
}

test "pixel-y grows downward while complex-im grows upward" {
    const vp = Viewport.fixedView(700, 500);
    const upper = vp.pixelToComplex(350.0, 100.0);
    const lower = vp.pixelToComplex(350.0, 400.0);
    // Smaller pixel-y is higher on screen and must have the larger imaginary part.
    try std.testing.expect(upper.im > lower.im);
}

test "non-square image preserves aspect: per-pixel re and im steps are equal" {
    const vp = Viewport.fixedView(800, 600); // 4:3, not the region's 3.5:2.5
    const origin = vp.pixelToComplex(100.0, 100.0);
    const step_re = vp.pixelToComplex(101.0, 100.0).re - origin.re;
    const step_im = origin.im - vp.pixelToComplex(100.0, 101.0).im;
    try std.testing.expectApproxEqAbs(step_re, step_im, 1e-15);
    try std.testing.expectApproxEqAbs(vp.scale, step_re, 1e-15);
}

test "contain fit keeps the whole fixed region visible on a non-matching aspect" {
    const vp = Viewport.fixedView(800, 600);
    // The wider region axis (re) fills the image; im must not be cropped.
    const top_left = vp.pixelToComplex(0.0, 0.0);
    try std.testing.expectApproxEqAbs(fixed_re_min, top_left.re, 1e-9);
    try std.testing.expect(top_left.im >= fixed_im_max - 1e-9);
}

test "pixelToComplex is deterministic for repeated identical input" {
    const vp = Viewport.fixedView(1920, 1080);
    const a = vp.pixelToComplex(123.0, 456.0);
    const b = vp.pixelToComplex(123.0, 456.0);
    try std.testing.expectEqual(a.re, b.re);
    try std.testing.expectEqual(a.im, b.im);
}

test "Viewport.complexToPixel inverts pixelToComplex on a non-square image" {
    const vp = Viewport.fixedView(800, 600);
    const p = vp.complexToPixel(vp.pixelToComplex(123.0, 456.0));
    try std.testing.expectApproxEqAbs(@as(f64, 123.0), p.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 456.0), p.y, 1e-9);
}

test "Viewport.pixelIndex uses the image width as the row stride" {
    const vp = Viewport.fixedView(800, 600);
    // Pixel (10, 3) — its center, so truncation cannot land on a neighbour.
    const idx = vp.pixelIndex(vp.pixelToComplex(10.5, 3.5)) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(usize, 3 * 800 + 10), idx);
}

test "Viewport.pixelIndex rejects a point past the right edge" {
    const vp = Viewport.fixedView(800, 600);
    try std.testing.expect(vp.pixelIndex(vp.pixelToComplex(800.5, 300.0)) == null);
}

test "Viewport.pixelIndex rejects a point above the top edge" {
    const vp = Viewport.fixedView(800, 600);
    try std.testing.expect(vp.pixelIndex(vp.pixelToComplex(400.0, -0.5)) == null);
}

test "Viewport.pixelIndex stays inside a full-image buffer for every pixel center" {
    const vp = Viewport.fixedView(37, 11); // odd, non-square, small
    const len: usize = 37 * 11;
    var y: u32 = 0;
    while (y < 11) : (y += 1) {
        var x: u32 = 0;
        while (x < 37) : (x += 1) {
            const pt = vp.pixelToComplex(@as(f64, @floatFromInt(x)) + 0.5, @as(f64, @floatFromInt(y)) + 0.5);
            const idx = vp.pixelIndex(pt) orelse return error.TestUnexpectedNull;
            try std.testing.expect(idx < len);
        }
    }
}

// ─── Tests: M3 SquareView model ──────────────────────────────────────────────
//
// Three representative views the round-trip tests share: the default square, a deep
// zoom on a known seahorse-valley point, and a shallow off-center view. Built as
// literals on purpose — the round-trip must hold for any valid view, not just ones
// that came out of a constructor.
const round_trip_views = [_]SquareView{
    .{ .center_re = -0.75, .center_im = 0.0, .side = 3.5 },
    .{ .center_re = -0.743643887037151, .center_im = 0.131825904205330, .side = 1.0e-6 },
    .{ .center_re = 0.2549870375, .center_im = -0.000470125, .side = 0.125 },
};

/// The default square's magnification, spelled out from plan A3 rather than read back
/// from the code under test.
const default_magnification: f64 = 1.0 / (3.5 * @sqrt(2.0));

/// Round-trip tolerance for a view: corner/center arithmetic quantizes at one ULP of the
/// LARGEST magnitude involved, so a deep zoom near `re = -0.74` can only be recovered to a
/// few ULPs of `0.74` — the documented f64 floor (M7 widens the center, not M3).
fn roundTripTolerance(v: SquareView) f64 {
    const magnitude: f64 = @floatCast(@max(@abs(v.center_re), @abs(v.center_im)));
    return 4.0 * std.math.floatEps(f64) * @max(magnitude, v.side);
}

test "defaultView snaps the M0 fixed region to its enclosing square" {
    const v = SquareView.defaultView();
    try std.testing.expectEqual(@as(f64, -0.75), v.center_re);
    try std.testing.expectEqual(@as(f64, 0.0), v.center_im);
    // Larger axis wins: |Δre| = 3.5 > |Δim| = 2.5.
    try std.testing.expectEqual(@as(f64, 3.5), v.side);
}

test "defaultView contains the whole M0 fixed region" {
    const c = SquareView.defaultView().corners();
    try std.testing.expect(c.min.re <= fixed_re_min);
    try std.testing.expect(c.max.re >= fixed_re_max);
    try std.testing.expect(c.min.im <= fixed_im_min);
    try std.testing.expect(c.max.im >= fixed_im_max);
}

test "defaultView equals the square snap of the M0 fixed corners" {
    const snapped = try SquareView.fromCorners(
        .{ .re = fixed_re_min, .im = fixed_im_min },
        .{ .re = fixed_re_max, .im = fixed_im_max },
    );
    try std.testing.expectEqual(SquareView.defaultView(), snapped);
}

test "magnification is the reciprocal of the square's diagonal length" {
    const v = try SquareView.fromCenterSide(.{ .re = 0.0, .im = 0.0 }, 2.0);
    // side 2 ⇒ diagonal 2·√2 ⇒ magnification 1/(2·√2).
    try std.testing.expectApproxEqRel(@as(f64, 1.0 / (2.0 * @sqrt(2.0))), v.magnification(), 1e-15);
    try std.testing.expectApproxEqRel(default_magnification, SquareView.defaultView().magnification(), 1e-15);
}

test "halving the side exactly doubles the magnification" {
    const wide = try SquareView.fromCenterSide(.{ .re = -0.75, .im = 0.0 }, 3.5);
    const tight = try SquareView.fromCenterSide(.{ .re = -0.75, .im = 0.0 }, 1.75);
    try std.testing.expectEqual(wide.magnification() * 2.0, tight.magnification());
}

test "fromCenterMag inverts centerMag for the default, deep-zoom and off-center views" {
    for (round_trip_views) |v| {
        const back = try SquareView.fromCenterMag(v.centerMag());
        const tol = roundTripTolerance(v);
        try std.testing.expectApproxEqRel(v.side, back.side, 1e-15);
        try std.testing.expectApproxEqAbs(v.center_re, back.center_re, tol);
        try std.testing.expectApproxEqAbs(v.center_im, back.center_im, tol);
    }
}

test "fromCorners inverts corners for the default, deep-zoom and off-center views" {
    for (round_trip_views) |v| {
        const c = v.corners();
        const back = try SquareView.fromCorners(c.min, c.max);
        const tol = roundTripTolerance(v);
        try std.testing.expectApproxEqAbs(v.side, back.side, tol);
        try std.testing.expectApproxEqAbs(v.center_re, back.center_re, tol);
        try std.testing.expectApproxEqAbs(v.center_im, back.center_im, tol);
    }
}

test "corners reports the bottom-left and top-right of the square" {
    const c = SquareView.defaultView().corners();
    try std.testing.expectApproxEqAbs(@as(f64, -2.5), c.min.re, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -1.75), c.min.im, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), c.max.re, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.75), c.max.im, 1e-15);
}

test "fromCorners snaps a wide rectangle to a square sized by the larger axis" {
    // |Δre| = 4, |Δim| = 1 ⇒ side 4, centered on the midpoint (0, 0).
    const v = try SquareView.fromCorners(.{ .re = -2.0, .im = -0.5 }, .{ .re = 2.0, .im = 0.5 });
    try std.testing.expectApproxEqRel(@as(f64, 4.0), v.side, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), v.center_re, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), v.center_im, 1e-15);
}

test "the square snapped from a tall rectangle contains it, expanded only on the short axis" {
    // |Δre| = 0.2, |Δim| = 3 ⇒ side 3: re grows, im is untouched.
    const a = ComplexHi{ .re = 0.1, .im = -1.5 };
    const b = ComplexHi{ .re = 0.3, .im = 1.5 };
    const v = try SquareView.fromCorners(a, b);
    const c = v.corners();
    try std.testing.expectApproxEqRel(@as(f64, 3.0), v.side, 1e-15);
    try std.testing.expect(c.min.re <= a.re and c.max.re >= b.re);
    try std.testing.expectApproxEqAbs(a.im, c.min.im, 1e-15);
    try std.testing.expectApproxEqAbs(b.im, c.max.im, 1e-15);
}

test "fromCorners ignores the order of the two given corners" {
    const a = ComplexHi{ .re = -1.25, .im = 0.5 };
    const b = ComplexHi{ .re = 0.75, .im = -0.25 };
    try std.testing.expectEqual(
        try SquareView.fromCorners(a, b),
        try SquareView.fromCorners(b, a),
    );
}

test "fromCorners rejects a zero-extent rectangle" {
    const p = ComplexHi{ .re = -0.75, .im = 0.1 };
    try std.testing.expectError(ViewportError.DegenerateRegion, SquareView.fromCorners(p, p));
}

test "fromCorners rejects non-finite corners" {
    const ok = ComplexHi{ .re = 0.0, .im = 0.0 };
    const nan = ComplexHi{ .re = std.math.nan(f128), .im = 0.0 };
    const inf = ComplexHi{ .re = 0.0, .im = std.math.inf(f128) };
    try std.testing.expectError(ViewportError.DegenerateRegion, SquareView.fromCorners(ok, nan));
    try std.testing.expectError(ViewportError.DegenerateRegion, SquareView.fromCorners(inf, ok));
}

test "fromCenterMag rejects a non-positive or non-finite magnification" {
    const c = ComplexHi{ .re = 0.0, .im = 0.0 };
    try std.testing.expectError(ViewportError.DegenerateRegion, SquareView.fromCenterMag(.{ .center = c, .magnification = 0.0 }));
    try std.testing.expectError(ViewportError.DegenerateRegion, SquareView.fromCenterMag(.{ .center = c, .magnification = -1.0 }));
    try std.testing.expectError(ViewportError.DegenerateRegion, SquareView.fromCenterMag(.{ .center = c, .magnification = std.math.nan(f64) }));
}

test "fromCenterSide rejects a non-positive side and a non-finite center" {
    const c = ComplexHi{ .re = 0.0, .im = 0.0 };
    try std.testing.expectError(ViewportError.DegenerateRegion, SquareView.fromCenterSide(c, 0.0));
    try std.testing.expectError(ViewportError.DegenerateRegion, SquareView.fromCenterSide(c, -3.5));
    try std.testing.expectError(ViewportError.DegenerateRegion, SquareView.fromCenterSide(c, std.math.inf(f64)));
    try std.testing.expectError(ViewportError.DegenerateRegion, SquareView.fromCenterSide(.{ .re = std.math.nan(f128), .im = 0.0 }, 1.0));
}

test "the image corner pixels map to the view corners" {
    const v = SquareView.defaultView();
    const s: u32 = 512;
    const top_left = v.pixelToComplex(0.0, 0.0, s);
    try std.testing.expectApproxEqAbs(@as(f64, -2.5), top_left.re, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.75), top_left.im, 1e-12); // top row = max im
    const bottom_right = v.pixelToComplex(512.0, 512.0, s);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), bottom_right.re, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -1.75), bottom_right.im, 1e-12);
}

test "the image center pixel maps to the view center" {
    const v = round_trip_views[1];
    const c = v.pixelToComplex(256.0, 256.0, 512);
    // Against `centerLo`, not `center()`: this is the f64 mapping, so the center it works
    // from is the f64-rounded one (`pixelToComplexHi` is what reproduces the f128 center).
    const ctr = v.centerLo();
    try std.testing.expectApproxEqAbs(ctr.re, c.re, v.side * 1e-12);
    try std.testing.expectApproxEqAbs(ctr.im, c.im, v.side * 1e-12);
}

const pixel_centers = [_]Pixel{
    .{ .x = 0.5, .y = 0.5 },
    .{ .x = 123.5, .y = 456.5 },
    .{ .x = 899.5, .y = 899.5 },
};

test "pixelToComplex and complexToPixel are exact inverses at pixel centers" {
    const v = SquareView.defaultView();
    const s: u32 = 900;
    for (pixel_centers) |p| {
        const back = v.complexToPixel(v.pixelToComplex(p.x, p.y, s), s);
        try std.testing.expectApproxEqAbs(p.x, back.x, 1e-9);
        try std.testing.expectApproxEqAbs(p.y, back.y, 1e-9);
    }
}

test "the pixel round-trip stays far sub-pixel on a deep zoom" {
    // side 1e-6 near re = -0.74: the complex offset is ~1e-9 ULP of the center, so the
    // recovered pixel drifts ~1e-7 px. Still invisible; the f64 floor proper is ~1e-13, which
    // is why M6 widened the CENTRE to `f128` and this f64 round trip is for shallow work only.
    const v = round_trip_views[1];
    const s: u32 = 900;
    for (pixel_centers) |p| {
        const back = v.complexToPixel(v.pixelToComplex(p.x, p.y, s), s);
        try std.testing.expectApproxEqAbs(p.x, back.x, 1e-6);
        try std.testing.expectApproxEqAbs(p.y, back.y, 1e-6);
    }
}

test "pixel-y grows downward while complex-im grows upward in the square model" {
    const v = SquareView.defaultView();
    const upper = v.pixelToComplex(100.5, 10.5, 512);
    const lower = v.pixelToComplex(100.5, 400.5, 512);
    try std.testing.expect(upper.im > lower.im);
}

test "toImagePixel translates a window pixel into image-local pixel coordinates" {
    const rect = ImageRect{ .x = 100, .y = 20, .w = 400, .h = 400, .side = 400 };
    const p = rect.toImagePixel(150.5, 70.25) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 50.5), p.x);
    try std.testing.expectEqual(@as(f64, 50.25), p.y);
}

test "toImagePixel treats the image rect as half-open: the far edge is outside" {
    const rect = ImageRect{ .x = 100, .y = 20, .w = 400, .h = 400, .side = 400 };
    try std.testing.expect(rect.toImagePixel(100.0, 20.0) != null); // near edge included
    try std.testing.expect(rect.toImagePixel(500.0, 100.0) == null); // x + side excluded
    try std.testing.expect(rect.toImagePixel(200.0, 420.0) == null); // y + side excluded
}

test "toImagePixel rejects letterbox-bar pixels on every side" {
    const rect = ImageRect{ .x = 100, .y = 20, .w = 400, .h = 400, .side = 400 };
    try std.testing.expect(rect.toImagePixel(99.9, 200.0) == null); // left bar
    try std.testing.expect(rect.toImagePixel(640.0, 200.0) == null); // right bar
    try std.testing.expect(rect.toImagePixel(200.0, 19.9) == null); // top bar
    try std.testing.expect(rect.toImagePixel(200.0, 600.0) == null); // bottom bar
}

test "toImagePixel rejects every pixel of a zero-side image rect" {
    const rect = ImageRect{ .x = 0, .y = 0, .w = 0, .h = 0, .side = 0 };
    try std.testing.expect(rect.toImagePixel(0.0, 0.0) == null);
}

test "cursorCoord returns the complex value under a window pixel inside the image" {
    const v = SquareView.defaultView();
    const rect = ImageRect{ .x = 100, .y = 20, .w = 400, .h = 400, .side = 400 };
    const got = v.cursorCoord(150.5, 70.25, rect) orelse return error.TestUnexpectedResult;
    // Square rect: use rectViewport as the reference (same formula cursorCoord now uses).
    const vp = v.rectViewport(rect.w, rect.h);
    const want = vp.pixelToComplex(50.5, 50.25);
    try std.testing.expectApproxEqAbs(want.re, got.re, 1e-12);
    try std.testing.expectApproxEqAbs(want.im, got.im, 1e-12);
}

test "cursorCoord rectangular image: center pixel maps to view center" {
    const v = SquareView.defaultView();
    // Wide image: 800×400, side=400. Center pixel = (400, 200).
    const rect = ImageRect{ .x = 0, .y = 0, .w = 800, .h = 400, .side = 400 };
    const got = v.cursorCoord(400.0, 200.0, rect) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(v.center_re, got.re, 1e-12);
    try std.testing.expectApproxEqAbs(v.center_im, got.im, 1e-12);
}

test "cursorCoord returns null over the letterbox bars" {
    const v = SquareView.defaultView();
    const rect = ImageRect{ .x = 100, .y = 20, .w = 400, .h = 400, .side = 400 };
    try std.testing.expect(v.cursorCoord(10.0, 200.0, rect) == null);
    try std.testing.expect(v.cursorCoord(200.0, 900.0, rect) == null);
}

test "cursorCoord returns null for a degenerate zero-side image rect" {
    const v = SquareView.defaultView();
    try std.testing.expect(v.cursorCoord(0.0, 0.0, .{ .x = 0, .y = 0, .w = 0, .h = 0, .side = 0 }) == null);
}

test "coordDigits is the base precision at the default view" {
    try std.testing.expectEqual(min_coord_digits, coordDigits(default_magnification));
}

test "coordDigits increases as magnification grows" {
    const mags = [_]f64{ default_magnification, 1.0, 1.0e2, 1.0e6, 1.0e10 };
    var prev = coordDigits(mags[0]);
    for (mags[1..]) |m| {
        const d = coordDigits(m);
        try std.testing.expect(d >= prev);
        prev = d;
    }
    try std.testing.expect(coordDigits(1.0e6) > coordDigits(default_magnification));
}

test "coordDigits follows the documented decade rule" {
    // digits = clamp(min + ceil(log10(mag)), min, max): mag 1e6 ⇒ 4 + 6 = 10.
    try std.testing.expectEqual(@as(usize, 10), coordDigits(1.0e6));
    try std.testing.expectEqual(@as(usize, 5), coordDigits(1.0e1));
}

test "coordDigits clamps to the documented range" {
    try std.testing.expectEqual(min_coord_digits, coordDigits(1.0e-30));
    try std.testing.expectEqual(max_coord_digits, coordDigits(1.0e30));
}

test "coordDigits guards a non-finite or non-positive magnification" {
    try std.testing.expectEqual(min_coord_digits, coordDigits(0.0));
    try std.testing.expectEqual(min_coord_digits, coordDigits(-1.0));
    try std.testing.expectEqual(min_coord_digits, coordDigits(std.math.nan(f64)));
    try std.testing.expectEqual(min_coord_digits, coordDigits(std.math.inf(f64)));
}

test "formatCoord renders a positive imaginary part with a plus" {
    var buf: [coord_buf_len]u8 = undefined;
    const line = try formatCoord(&buf, .{ .re = -0.75, .im = 0.25 }, default_magnification);
    try std.testing.expectEqualStrings("-0.7500 + 0.2500i", line);
}

test "formatCoord renders a negative imaginary part with a minus" {
    var buf: [coord_buf_len]u8 = undefined;
    const line = try formatCoord(&buf, .{ .re = 0.5, .im = -0.125 }, default_magnification);
    try std.testing.expectEqualStrings("0.5000 - 0.1250i", line);
}

test "formatCoord shows more decimals at a deeper magnification" {
    var buf: [coord_buf_len]u8 = undefined;
    const line = try formatCoord(&buf, .{ .re = -0.75, .im = 0.25 }, 1.0e6);
    try std.testing.expectEqualStrings("-0.7500000000 + 0.2500000000i", line);
}

test "formatCoord reports NoSpaceLeft instead of truncating" {
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, formatCoord(&buf, .{ .re = -0.75, .im = 0.25 }, default_magnification));
}

test "formatCoord renders a negative-zero imaginary part with a minus, never `+ -`" {
    var buf: [coord_buf_len]u8 = undefined;
    const line = try formatCoord(&buf, .{ .re = 0.5, .im = -0.0 }, default_magnification);
    try std.testing.expectEqualStrings("0.5000 - 0.0000i", line);
}

test "degenerateRegionMessage names the offending value and what to do" {
    var buf: [message_buf_len]u8 = undefined;
    const msg = try degenerateRegionMessage(&buf, "magnification", 0.0);
    try std.testing.expectEqualStrings(
        "rejected viewport: magnification=0e0 is not a finite positive extent; " ++
            "enter a positive magnification or two distinct corners",
        msg,
    );
}

test "degenerateRegionMessage fits the documented buffer for the largest-magnitude f64" {
    var buf: [message_buf_len]u8 = undefined;
    const msg = try degenerateRegionMessage(&buf, "corner extent", -std.math.floatMax(f64));
    try std.testing.expectEqualStrings(
        "rejected viewport: corner extent=-1.7976931348623157e308 is not a finite " ++
            "positive extent; enter a positive magnification or two distinct corners",
        msg,
    );
}

test "degenerateRegionMessage fits the documented buffer for the smallest subnormal f64" {
    var buf: [message_buf_len]u8 = undefined;
    const msg = try degenerateRegionMessage(&buf, "side", std.math.floatTrueMin(f64));
    try std.testing.expectEqualStrings(
        "rejected viewport: side=5e-324 is not a finite positive extent; " ++
            "enter a positive magnification or two distinct corners",
        msg,
    );
}

test "message_buf_len is exactly the worst-case message length" {
    var buf: [message_buf_len]u8 = undefined;
    // Widest `{e}` rendering an f64 can produce: sign, 17 significant digits, 3-digit exponent.
    const widest_value: f64 = -1.3508404415422605e-270;
    const widest_what = "x" ** max_what_len;
    const msg = try degenerateRegionMessage(&buf, widest_what, widest_value);
    try std.testing.expectEqual(message_buf_len, msg.len);
}

test "degenerateRegionMessage reports NoSpaceLeft instead of truncating" {
    var buf: [message_buf_len - 1]u8 = undefined;
    const widest_what = "x" ** max_what_len;
    try std.testing.expectError(
        error.NoSpaceLeft,
        degenerateRegionMessage(&buf, widest_what, -1.3508404415422605e-270),
    );
}

/// Compute the letterboxed square `ImageRect` for a window of `window_w × window_h`
/// screen pixels (plan A2: the fractal renders into a centered square of side
/// `S = min(window_w, window_h)`).
///
/// Pure: no SDL/GPU/ImGui — lives in the fast test tier. Returns a zero-side rect
/// safely for degenerate (0 × anything) input; T5 skips the render pass for those.
/// The rect is consumed by `cursorCoord` (T6's gesture entry) and the texture upload.
pub fn computeImageRect(window_w: u32, window_h: u32) ImageRect {
    if (window_w == 0 or window_h == 0) return .{ .x = 0, .y = 0, .w = 0, .h = 0, .side = 0 };
    return .{
        .x = 0,
        .y = 0,
        .w = window_w,
        .h = window_h,
        .side = @min(window_w, window_h),
    };
}

/// Fit a `tex_w × tex_h` render into the `region_w × region_h` screen region at
/// `(region_x, region_y)` WITHOUT distorting it: scale by `min(region_w/tex_w, region_h/tex_h)`
/// and center the result, leaving equal bars on the two spare sides.
///
/// Why the UI needs this: the render buffer and the region it is drawn into are only the same
/// shape once a pass at the region's exact dimensions has finished. In between — at startup,
/// while a window resize is still being dragged, and during the coarse navigation preview —
/// they differ, and drawing the texture across the whole region would STRETCH the fractal
/// (M5 bug: the first frame was a square render splashed across a wide region). Fitting makes
/// that structurally impossible: a mismatch shows as brief bars, never as a wrong aspect.
///
/// The returned rect is also the coordinate-mapping rect: it has the texture's aspect, so
/// `cursorCoord`'s `rectViewport(w, h)` maps it onto exactly the complex region the render
/// covers. Pure: no SDL/GPU/ImGui. Degenerate (any zero) input yields a zero-side rect, which
/// the callers treat as "nothing to map".
pub fn fitImageRect(
    region_x: i32,
    region_y: i32,
    region_w: u32,
    region_h: u32,
    tex_w: u32,
    tex_h: u32,
) ImageRect {
    if (region_w == 0 or region_h == 0 or tex_w == 0 or tex_h == 0) {
        return .{ .x = 0, .y = 0, .w = 0, .h = 0, .side = 0 };
    }
    const rw: f64 = @floatFromInt(region_w);
    const rh: f64 = @floatFromInt(region_h);
    const tw: f64 = @floatFromInt(tex_w);
    const th: f64 = @floatFromInt(tex_h);
    const scale = @min(rw / tw, rh / th);
    // Round to whole pixels, but never past the region and never to zero.
    const fit_w: u32 = @max(1, @min(region_w, @as(u32, @intFromFloat(@round(tw * scale)))));
    const fit_h: u32 = @max(1, @min(region_h, @as(u32, @intFromFloat(@round(th * scale)))));
    return .{
        .x = region_x + @as(i32, @intCast((region_w - fit_w) / 2)),
        .y = region_y + @as(i32, @intCast((region_h - fit_h) / 2)),
        .w = fit_w,
        .h = fit_h,
        .side = @min(fit_w, fit_h),
    };
}

test "fitImageRect fills the region exactly when the aspects already match" {
    const r = fitImageRect(10, 20, 800, 600, 400, 300);
    try std.testing.expectEqual(@as(u32, 800), r.w);
}

test "fitImageRect leaves the region height untouched when the aspects match" {
    const r = fitImageRect(10, 20, 800, 600, 400, 300);
    try std.testing.expectEqual(@as(u32, 600), r.h);
}

test "fitImageRect keeps a square render square inside a wide region (the M5 aspect bug)" {
    // A 720×720 startup render in a 1012×666 region must stay square, not stretch to 1012.
    const r = fitImageRect(0, 0, 1012, 666, 720, 720);
    try std.testing.expectEqual(r.h, r.w);
}

test "fitImageRect centers the fitted image horizontally in a wide region" {
    const r = fitImageRect(0, 0, 1000, 500, 500, 500); // fits to 500×500 ⇒ 250 px bars
    try std.testing.expectEqual(@as(i32, 250), r.x);
}

test "fitImageRect centers the fitted image vertically in a tall region" {
    const r = fitImageRect(0, 0, 400, 1000, 200, 200); // fits to 400×400 ⇒ 300 px bars
    try std.testing.expectEqual(@as(i32, 300), r.y);
}

test "fitImageRect offsets by the region origin" {
    const r = fitImageRect(37, 11, 600, 300, 200, 100);
    try std.testing.expectEqual(@as(i32, 37), r.x);
}

test "fitImageRect scales a coarse preview up to the whole region (same aspect)" {
    // The navigation preview renders at a quarter of each axis; it must still fill the region.
    const r = fitImageRect(0, 0, 1012, 666, 1012 / 4, 666 / 4);
    try std.testing.expectEqual(@as(u32, 1012), r.w);
}

test "fitImageRect never exceeds the region width when rounding up" {
    const r = fitImageRect(0, 0, 101, 101, 100, 100);
    try std.testing.expect(r.w <= 101);
}

test "fitImageRect reports side as min(w, h) for the navigation geometry" {
    const r = fitImageRect(0, 0, 1000, 500, 500, 500);
    try std.testing.expectEqual(@as(u32, 500), r.side);
}

test "fitImageRect returns a degenerate rect for a zero-size region" {
    const r = fitImageRect(0, 0, 0, 600, 400, 300);
    try std.testing.expectEqual(@as(u32, 0), r.side);
}

test "fitImageRect returns a degenerate rect for a zero-size texture" {
    const r = fitImageRect(0, 0, 800, 600, 0, 300);
    try std.testing.expectEqual(@as(u32, 0), r.side);
}

test "imageViewport is a square M0 viewport of side S pixels" {
    const v = SquareView.defaultView();
    const vp = v.imageViewport(512);
    try std.testing.expectEqual(@as(u32, 512), vp.width);
    try std.testing.expectEqual(@as(u32, 512), vp.height);
    try std.testing.expectApproxEqRel(@as(f64, 3.5 / 512.0), vp.scale, 1e-15);
}

test "imageViewport reproduces the square view's pixel mapping" {
    const v = round_trip_views[2];
    const s: u32 = 256;
    const vp = v.imageViewport(s);
    const samples = [_]Pixel{ .{ .x = 0.5, .y = 0.5 }, .{ .x = 128.5, .y = 200.5 }, .{ .x = 255.5, .y = 255.5 } };
    for (samples) |p| {
        const want = v.pixelToComplex(p.x, p.y, s);
        const got = vp.pixelToComplex(p.x, p.y);
        try std.testing.expectApproxEqAbs(want.re, got.re, v.side * 1e-12);
        try std.testing.expectApproxEqAbs(want.im, got.im, v.side * 1e-12);
    }
}

// ─── Tests: computeImageRect ─────────────────────────────────────────────────

test "computeImageRect landscape: w=1280 h=720, side=min=720" {
    const r = computeImageRect(1280, 720);
    try std.testing.expectEqual(@as(u32, 1280), r.w);
    try std.testing.expectEqual(@as(u32, 720), r.h);
    try std.testing.expectEqual(@as(u32, 720), r.side);
    try std.testing.expectEqual(@as(i32, 0), r.x);
    try std.testing.expectEqual(@as(i32, 0), r.y);
}

test "computeImageRect portrait: w=600 h=900, side=min=600" {
    const r = computeImageRect(600, 900);
    try std.testing.expectEqual(@as(u32, 600), r.w);
    try std.testing.expectEqual(@as(u32, 900), r.h);
    try std.testing.expectEqual(@as(u32, 600), r.side);
    try std.testing.expectEqual(@as(i32, 0), r.x);
    try std.testing.expectEqual(@as(i32, 0), r.y);
}

test "computeImageRect square: w=h=800, side=800" {
    const r = computeImageRect(800, 800);
    try std.testing.expectEqual(@as(u32, 800), r.w);
    try std.testing.expectEqual(@as(u32, 800), r.h);
    try std.testing.expectEqual(@as(u32, 800), r.side);
    try std.testing.expectEqual(@as(i32, 0), r.x);
    try std.testing.expectEqual(@as(i32, 0), r.y);
}

test "computeImageRect degenerate zero-width: side=0" {
    const r = computeImageRect(0, 800);
    try std.testing.expectEqual(@as(u32, 0), r.side);
}

test "computeImageRect degenerate zero-height: side=0" {
    const r = computeImageRect(800, 0);
    try std.testing.expectEqual(@as(u32, 0), r.side);
}

test "computeImageRect degenerate zero-both: side=0, origin at zero" {
    const r = computeImageRect(0, 0);
    try std.testing.expectEqual(@as(u32, 0), r.side);
    try std.testing.expectEqual(@as(i32, 0), r.x);
    try std.testing.expectEqual(@as(i32, 0), r.y);
}

test "computeImageRect fills full window: w=w, h=h, side=min(w,h), origin at (0,0)" {
    const r = computeImageRect(1920, 1080);
    try std.testing.expectEqual(@as(u32, 1920), r.w);
    try std.testing.expectEqual(@as(u32, 1080), r.h);
    try std.testing.expectEqual(@as(u32, 1080), r.side);
    try std.testing.expectEqual(@as(i32, 0), r.x);
    try std.testing.expectEqual(@as(i32, 0), r.y);
}

// ─── Tests: precision floor (MOVED from navigate.zig by M6/T2) ────────────────

/// The widest `{e}` rendering an f64 can produce (24 chars) — the worst case for the
/// warning message's buffer. Same value brute-forced for `degenerateRegionMessage`.
const widest_float: f64 = -1.3508404415422605e-270;

test "precision_floor_side is the deep-zoom floor, not the old f64 one" {
    try std.testing.expectEqual(@as(f64, 1.0e-30), precision_floor_side);
}

test "atPrecisionFloor flags a side below the deep-zoom precision floor" {
    const v = try SquareView.fromCenterSide(.{ .re = -0.75, .im = 0.0 }, 1.0e-31);
    try std.testing.expect(atPrecisionFloor(v));
}

test "atPrecisionFloor does not flag the default view" {
    try std.testing.expect(!atPrecisionFloor(SquareView.defaultView()));
}

test "atPrecisionFloor does not flag a side just above the floor" {
    const shallow = try SquareView.fromCenterSide(.{ .re = -0.75, .im = 0.0 }, 1.0e-29);
    try std.testing.expect(!atPrecisionFloor(shallow));
}

test "atPrecisionFloor leaves the whole newly usable deep range unflagged" {
    // M6/T5's user-visible unlock: 1e-20 is seven decades past where the OLD f64 floor
    // warned, and the deep path renders it, so the warning must stay silent there.
    const usable = try SquareView.fromCenterSide(.{ .re = -0.75, .im = 0.0 }, 1.0e-20);
    try std.testing.expect(!atPrecisionFloor(usable));
}

test "atPrecisionFloor puts the boundary one ULP below the floor value" {
    const center_pt = ComplexHi{ .re = -0.75, .im = 0.0 };
    const at_floor = try SquareView.fromCenterSide(center_pt, precision_floor_side);
    try std.testing.expect(!atPrecisionFloor(at_floor));
    const one_ulp_below: f64 = @bitCast(@as(u64, @bitCast(precision_floor_side)) - 1);
    const below = try SquareView.fromCenterSide(center_pt, one_ulp_below);
    try std.testing.expect(atPrecisionFloor(below));
}

test "precisionFloorMessage names the offending side, the 1e-30 limit and what to do" {
    var buf: [floor_message_buf_len]u8 = undefined;
    const msg = try precisionFloorMessage(&buf, 1.0e-31);
    try std.testing.expectEqualStrings(
        "precision floor reached: side=1e-31 is below the deepest supported side 1e-30; " ++
            "the image quantizes into blocks from here, so zoom out or reset the view",
        msg,
    );
}

test "precisionFloorMessage renders a deep side in exponent form, not 33 leading zeros" {
    var buf: [floor_message_buf_len]u8 = undefined;
    const msg = try precisionFloorMessage(&buf, 4.7e-33);
    try std.testing.expect(std.mem.indexOf(u8, msg, "side=4.7e-33") != null);
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

// ─── Tests: M6 extended-precision center ─────────────────────────────────────
//
// The reference deep-zoom center, given to 33 significant decimals — more than `f64` can
// hold, so any test below that passes with an `f64` center would be vacuous. The literals
// are written out (not parsed) where a comptime value is wanted; Zig comptime float
// literals are arbitrary precision, so both spellings agree exactly.
const deep_center_re_text = "-0.743643887037158704752191506114774";
const deep_center_im_text = "0.131825904205311970493132056385139";
const deep_center_hi = ComplexHi{
    .re = -0.743643887037158704752191506114774,
    .im = 0.131825904205311970493132056385139,
};
/// A depth `f64` cannot navigate: one pixel of a 1000 px image is ~1e-28 wide here, far
/// below the ~1e-16 relative resolution of an `f64` near |re| ≈ 0.74.
const deep_hi_side: f64 = 1.0e-25;

test "a 34-decimal center survives fromCenterSide and center() unchanged" {
    const v = try SquareView.fromCenterSide(deep_center_hi, deep_hi_side);
    try std.testing.expectEqual(deep_center_hi.re, v.center().re);
    try std.testing.expectEqual(deep_center_hi.im, v.center().im);
}

test "the stored center keeps digits an f64 center would have thrown away" {
    const v = try SquareView.fromCenterSide(deep_center_hi, deep_hi_side);
    const narrowed: f128 = @as(f64, @floatCast(deep_center_hi.re));
    try std.testing.expect(v.center().re != narrowed);
}

test "a 34-decimal center survives the centerMag round trip unchanged" {
    const v = try SquareView.fromCenterSide(deep_center_hi, deep_hi_side);
    const back = try SquareView.fromCenterMag(v.centerMag());
    try std.testing.expectEqual(deep_center_hi.re, back.center_re);
    try std.testing.expectEqual(deep_center_hi.im, back.center_im);
}

test "centerLo narrows the stored center to the f64 the per-pixel paths use" {
    const v = try SquareView.fromCenterSide(deep_center_hi, deep_hi_side);
    try std.testing.expectEqual(@as(f64, @floatCast(deep_center_hi.re)), v.centerLo().re);
    try std.testing.expectEqual(@as(f64, @floatCast(deep_center_hi.im)), v.centerLo().im);
}

test "pixelToComplexHi separates two adjacent pixels at side 1e-25" {
    const v = try SquareView.fromCenterSide(deep_center_hi, deep_hi_side);
    const left = v.pixelToComplexHi(500.0, 500.0, 1000);
    const right = v.pixelToComplexHi(501.0, 500.0, 1000);
    try std.testing.expect(right.re > left.re);
}

test "pixelToComplex collapses those same two pixels, which is why the Hi form exists" {
    const v = try SquareView.fromCenterSide(deep_center_hi, deep_hi_side);
    const left = v.pixelToComplex(500.0, 500.0, 1000);
    const right = v.pixelToComplex(501.0, 500.0, 1000);
    try std.testing.expectEqual(left.re, right.re);
}

test "pixelToComplexHi maps the image center pixel to the full-precision center" {
    const v = try SquareView.fromCenterSide(deep_center_hi, deep_hi_side);
    const c = v.pixelToComplexHi(500.0, 500.0, 1000);
    try std.testing.expectEqual(deep_center_hi.re, c.re);
    try std.testing.expectEqual(deep_center_hi.im, c.im);
}

test "pixelToComplexHi agrees with pixelToComplex on a shallow view" {
    const v = SquareView.defaultView();
    const hi = v.pixelToComplexHi(123.5, 456.5, 512);
    const lo = v.pixelToComplex(123.5, 456.5, 512);
    try std.testing.expectApproxEqAbs(lo.re, hi.re, 1e-15);
    try std.testing.expectApproxEqAbs(lo.im, hi.im, 1e-15);
}

test "pixelToComplexHi negates pixel-y like every other mapping here" {
    const v = try SquareView.fromCenterSide(deep_center_hi, deep_hi_side);
    const upper = v.pixelToComplexHi(500.0, 499.0, 1000);
    const lower = v.pixelToComplexHi(500.0, 501.0, 1000);
    try std.testing.expect(upper.im > lower.im);
}

test "rectPixelToComplexHi separates two adjacent pixels of a deep non-square image" {
    const v = try SquareView.fromCenterSide(deep_center_hi, deep_hi_side);
    const left = v.rectPixelToComplexHi(400.0, 200.0, 800, 400);
    const right = v.rectPixelToComplexHi(401.0, 200.0, 800, 400);
    try std.testing.expect(right.re > left.re);
}

test "cursorCoord keeps full precision so a deep gesture anchor is not rounded" {
    const v = try SquareView.fromCenterSide(deep_center_hi, deep_hi_side);
    const rect = ImageRect{ .x = 0, .y = 0, .w = 1000, .h = 1000, .side = 1000 };
    const center_hit = v.cursorCoord(500.0, 500.0, rect) orelse return error.TestUnexpectedResult;
    const one_right = v.cursorCoord(501.0, 500.0, rect) orelse return error.TestUnexpectedResult;
    try std.testing.expect(one_right.re > center_hit.re);
}

test "fromCorners keeps a deep selection's center at full precision" {
    const v = try SquareView.fromCenterSide(deep_center_hi, deep_hi_side);
    const c = v.corners();
    const back = try SquareView.fromCorners(c.min, c.max);
    try std.testing.expectEqual(v.center_re, back.center_re);
}

test "Viewport carries no f128 field, so the per-pixel mapping stays fast" {
    inline for (@typeInfo(Viewport).@"struct".fields) |field| {
        try std.testing.expect(field.type != f128);
    }
}

test "coordDigits climbs past the old 17-digit ceiling to f128's 34" {
    // The readout's depth ceiling IS the representation's: M6 raised the cap from 17 (f64) to
    // 34 (f128), so a magnification the old cap flattened now keeps growing.
    try std.testing.expectEqual(@as(usize, 25), coordDigits(1.0e21));
    try std.testing.expectEqual(@as(usize, 34), coordDigits(1.0e40));
}

test "formatCoord emits every one of the 34 digits at maximum magnification" {
    var buf: [coord_buf_len]u8 = undefined;
    const line = try formatCoord(&buf, .{ .re = -0.75, .im = 0.25 }, std.math.floatMax(f64));
    try std.testing.expectEqualStrings(
        "-0.7500000000000000000000000000000000 + 0.2500000000000000000000000000000000i",
        line,
    );
}

test "coord_buf_len is exactly the worst case for a coordinate in the Mandelbrot region" {
    var buf: [coord_buf_len]u8 = undefined;
    // Both parts negative and one integer digit wide: the longest string `formatCoord`
    // produces for a view of the set, at the deepest digit count.
    const line = try formatCoord(&buf, .{ .re = -1.5, .im = -1.5 }, 1.0e40);
    try std.testing.expectEqual(coord_buf_len, line.len);
}

test "max_coord_digits round-trips an f128 coordinate through decimal text exactly" {
    // The claim `coord_text_buf_len` and T7/T8's shared formatting rest on: a center
    // printed at `max_coord_digits` decimals parses back bit-identically.
    const want = try std.fmt.parseFloat(f128, deep_center_re_text);
    var buf: [coord_text_buf_len]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{[v]d:.[p]}", .{ .v = want, .p = max_coord_digits });
    try std.testing.expectEqual(want, try std.fmt.parseFloat(f128, text));
}

test "the reference center's literal and its decimal text are the same f128" {
    try std.testing.expectEqual(try std.fmt.parseFloat(f128, deep_center_re_text), deep_center_hi.re);
    try std.testing.expectEqual(try std.fmt.parseFloat(f128, deep_center_im_text), deep_center_hi.im);
}

test "coord_text_buf_len holds a signed 34-decimal coordinate plus a terminator" {
    var buf: [coord_text_buf_len]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{[v]d:.[p]}", .{
        .v = @as(f128, -1.5),
        .p = max_coord_digits,
    });
    try std.testing.expect(text.len < coord_text_buf_len);
}
