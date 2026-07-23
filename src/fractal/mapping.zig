//! Pure smooth-iteration → `[0,1]` mapping transforms. NO SDL/GPU/log imports —
//! this lives in the fast test tier (`zig build test`, no window/device) and is fully
//! unit-tested. No allocation, no global state, deterministic.
//!
//! The color pass (T4) turns each pixel's smooth escape value into a LUT index in
//! `[0,1]` before sampling the baked gradient (`gradient.bakeLut`). WHICH transform is
//! used changes the look dramatically, so the mapping is factored out here and selected
//! by the UI (T6):
//!   * `linear` — even spread across the whole iteration range.
//!   * `log`    — compresses the fast-escaping exterior (most pixels escape quickly), so
//!                low iteration counts get more of the palette; reveals exterior detail.
//!   * `cyclic` — repeating bands with an adjustable `period`, for contour-line looks.
//!
//! Contract of `mapToUnit(smooth, max_iter, params)`:
//!   * Input `smooth` is an ESCAPED (non-sentinel) smooth iteration value; the caller
//!     handles the interior `-1.0` sentinel separately (plan A5), so it never reaches
//!     here. We STILL defensively clamp: `smooth < 0` OR non-finite (`inf`/`nan`) → `0`.
//!   * The result is ALWAYS clamped to `[0,1]` (cyclic to `[0,1)`); nothing downstream
//!     ever indexes the LUT out of range.
//!   * `max_iter == 0` (degenerate) and `period <= 0` (would divide by zero) both guard
//!     to `0` rather than trapping.
//!
//! Formulas are documented inline BELOW so a future GPU fragment-shader color pass can be
//! written to match this CPU math bit-for-bit (M-future GPU parity, plan A1).
const std = @import("std");

/// The available mapping transforms. Selected in the UI (T6); default is `linear`
/// (plan A6).
pub const Mode = enum { linear, log, cyclic };

/// Sane default `cyclic` period: a smooth value spans this many iterations per band.
/// Chosen so the default view shows a handful of visible bands; the UI exposes a slider.
/// MUST stay `> 0` (see `Params`); a value `<= 0` guards to a `0` result.
pub const default_period: f32 = 32.0;

/// Mapping selection. `period` is used ONLY by `Mode.cyclic` and MUST be `> 0`; other
/// modes ignore it. Defaults to `linear` + `default_period`.
pub const Params = struct {
    mode: Mode = .linear,
    period: f32 = default_period,
};

/// Map an escaped smooth iteration value to a LUT index in `[0,1]`.
///
/// Guards (applied first, for every mode): a negative or non-finite `smooth` maps to `0`.
///
/// Per-mode formula (documented for GPU parity):
///   * linear: `smooth / max_iter`, clamped to `[0,1]`. `smooth == 0 → 0`,
///     `smooth == max_iter → 1`, monotonic increasing in between.
///   * log:    `log(1 + smooth) / log(1 + max_iter)`, clamped to `[0,1]`. The `+1`
///     keeps the numerator/denominator finite and non-negative at `smooth == 0`
///     (`log(1) == 0`). Monotonic increasing; a mid value maps HIGHER than linear.
///   * cyclic: `fract(smooth / period)` where `fract(x) = x - floor(x)`, giving `[0,1)`.
///     `smooth` and `smooth + period` collapse to the same value (repeating bands).
///
/// Degenerate guards: `max_iter == 0` (linear/log) and `period <= 0` (cyclic) both
/// return `0` instead of dividing by zero.
pub fn mapToUnit(smooth: f32, max_iter: u32, params: Params) f32 {
    // Defensive input guard: the interior sentinel is handled by the caller, but any
    // negative or non-finite value can never be a valid LUT index — clamp it to 0.
    if (!std.math.isFinite(smooth) or smooth < 0.0) return 0.0;

    switch (params.mode) {
        .linear => {
            if (max_iter == 0) return 0.0; // guard div-by-zero
            const denom: f32 = @floatFromInt(max_iter);
            return std.math.clamp(smooth / denom, 0.0, 1.0);
        },
        .log => {
            if (max_iter == 0) return 0.0; // guard div-by-zero (log(1) == 0)
            const denom = std.math.log(f32, std.math.e, 1.0 + @as(f32, @floatFromInt(max_iter)));
            const num = std.math.log(f32, std.math.e, 1.0 + smooth);
            return std.math.clamp(num / denom, 0.0, 1.0);
        },
        .cyclic => {
            if (params.period <= 0.0) return 0.0; // guard div-by-zero
            const scaled = smooth / params.period;
            const frac = scaled - @floor(scaled); // fract(x) in [0,1)
            // scaled is >= 0 here (smooth >= 0, period > 0), so frac is already [0,1);
            // clamp only to defend against float rounding landing exactly on 1.0.
            return std.math.clamp(frac, 0.0, 1.0);
        },
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

test "linear: smooth == 0 maps to 0" {
    try expectEqual(@as(f32, 0.0), mapToUnit(0.0, 100, .{ .mode = .linear }));
}

test "linear: smooth == max_iter maps to 1" {
    try expectEqual(@as(f32, 1.0), mapToUnit(100.0, 100, .{ .mode = .linear }));
}

test "linear: monotonic increasing between 0 and max_iter" {
    const a = mapToUnit(25.0, 100, .{ .mode = .linear });
    const b = mapToUnit(50.0, 100, .{ .mode = .linear });
    try expect(a < b);
}

test "linear: smooth above max_iter clamps to 1" {
    try expectEqual(@as(f32, 1.0), mapToUnit(250.0, 100, .{ .mode = .linear }));
}

test "log: is monotonic increasing" {
    const a = mapToUnit(20.0, 100, .{ .mode = .log });
    const b = mapToUnit(60.0, 100, .{ .mode = .log });
    try expect(a < b);
}

test "log: result stays within [0,1]" {
    const v = mapToUnit(60.0, 100, .{ .mode = .log });
    try expect(v >= 0.0 and v <= 1.0);
}

test "log: endpoints map to 0 and 1" {
    try expectEqual(@as(f32, 0.0), mapToUnit(0.0, 100, .{ .mode = .log }));
    try expectApproxEqAbs(@as(f32, 1.0), mapToUnit(100.0, 100, .{ .mode = .log }), 1e-6);
}

test "log: compresses high values — a mid value maps higher than linear" {
    const mid = 50.0;
    const lin = mapToUnit(mid, 100, .{ .mode = .linear });
    const lg = mapToUnit(mid, 100, .{ .mode = .log });
    try expect(lg > lin);
}

test "cyclic: smooth and smooth + period map to the same value" {
    const p: f32 = 32.0;
    const a = mapToUnit(10.0, 100, .{ .mode = .cyclic, .period = p });
    const b = mapToUnit(10.0 + p, 100, .{ .mode = .cyclic, .period = p });
    try expectApproxEqAbs(a, b, 1e-5);
}

test "cyclic: output is always in [0,1)" {
    const v = mapToUnit(40.0, 100, .{ .mode = .cyclic, .period = 32.0 });
    try expect(v >= 0.0 and v < 1.0);
}

test "cyclic: a different period changes the result" {
    const a = mapToUnit(40.0, 100, .{ .mode = .cyclic, .period = 32.0 });
    const b = mapToUnit(40.0, 100, .{ .mode = .cyclic, .period = 50.0 });
    try expect(a != b);
}

test "cyclic: a non-positive period guards to 0 (no divide by zero)" {
    try expectEqual(@as(f32, 0.0), mapToUnit(40.0, 100, .{ .mode = .cyclic, .period = 0.0 }));
}

test "all modes: a negative smooth clamps to 0" {
    try expectEqual(@as(f32, 0.0), mapToUnit(-5.0, 100, .{ .mode = .linear }));
    try expectEqual(@as(f32, 0.0), mapToUnit(-5.0, 100, .{ .mode = .log }));
    try expectEqual(@as(f32, 0.0), mapToUnit(-5.0, 100, .{ .mode = .cyclic, .period = 32.0 }));
}

test "all modes: a non-finite smooth clamps to 0" {
    const inf = std.math.inf(f32);
    const nan = std.math.nan(f32);
    try expectEqual(@as(f32, 0.0), mapToUnit(inf, 100, .{ .mode = .linear }));
    try expectEqual(@as(f32, 0.0), mapToUnit(nan, 100, .{ .mode = .log }));
    try expectEqual(@as(f32, 0.0), mapToUnit(inf, 100, .{ .mode = .cyclic, .period = 32.0 }));
}

test "linear and log: max_iter == 0 guards to 0" {
    try expectEqual(@as(f32, 0.0), mapToUnit(5.0, 0, .{ .mode = .linear }));
    try expectEqual(@as(f32, 0.0), mapToUnit(5.0, 0, .{ .mode = .log }));
}

test "mapToUnit is deterministic: same inputs yield identical output" {
    const p = Params{ .mode = .cyclic, .period = 17.0 };
    try expectEqual(mapToUnit(42.0, 200, p), mapToUnit(42.0, 200, p));
}

test "Params defaults to linear with the documented default period" {
    const p = Params{};
    try expectEqual(Mode.linear, p.mode);
    try expectEqual(default_period, p.period);
}
