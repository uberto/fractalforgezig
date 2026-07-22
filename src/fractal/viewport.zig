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
//! M7 seam: `center_re`/`center_im` are `f64` today (a deliberate defer — see the
//! milestone plan). Arbitrary precision is only needed near ~1e-15 magnification.
//! The type is isolated here so M7 can widen the center without touching callers;
//! do NOT let callers read the raw `f64` center for precision-sensitive math.
const std = @import("std");

/// A point on the complex plane. Plain data, no methods — the fractal core reads
/// `re`/`im` directly.
pub const Complex = struct {
    re: f64,
    im: f64,
};

/// The fixed M0 target region on the complex plane (plan non-goal: no navigation).
/// The constructed viewport is guaranteed to *contain* this whole region; on an
/// image whose aspect ratio differs from `re_range : im_range` the longer axis
/// gets extra margin rather than stretching the set.
pub const fixed_re_min: f64 = -2.5;
pub const fixed_re_max: f64 = 1.0;
pub const fixed_im_min: f64 = -1.25;
pub const fixed_im_max: f64 = 1.25;

/// A view onto the complex plane, parameterized so pixels are square.
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
