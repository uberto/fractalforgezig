//! Adaptive `max_iter` policy (plan A6): how many Mandelbrot iterations a view is worth,
//! and how the user pins that number instead. Pure — NO SDL/ImGui/GPU imports, no logging,
//! no allocation, no clock — so every branch runs in the fast `zig build test` tier
//! (plan A8). This is the SINGLE source of truth shared by the engine (T4) and the panel
//! (T7): neither may re-derive the formula.
//!
//! THE HEURISTIC (`autoMaxIter`), spelled out because T7's tooltip and T8's docs quote it:
//!
//!     max_iter = clamp(base_max_iter + iter_per_doubling · log2(magnification / mag0),
//!                      base_max_iter, auto_max_iter)
//!
//! where `mag0` is the DEFAULT view's magnification (read from T1's
//! `SquareView.defaultView().magnification()`, never recomputed here) and
//! `magnification = 1/(side·√2)` (plan A3). Rationale, term by term:
//!   * `base_max_iter = 512` — the M0 value, so the home view renders exactly as it did
//!     before M3 and the auto ramp can only ever ADD detail.
//!   * one doubling of magnification (one 2× zoom step) costs `iter_per_doubling = 80`
//!     extra iterations. Linear-in-log2 is the standard ramp: escape-time detail near the
//!     boundary needs roughly a constant number of extra iterations per zoom step, and a
//!     linear-in-log law is what keeps it monotone and predictable to the user.
//!   * `auto_max_iter = 4096` is where the AUTO ramp stops. Not a cost limit but a
//!     usefulness limit: `80` is not arbitrary — `(4096 − 512)/80 = 44.8` doublings puts
//!     that value at side ≈ 1.15e-13, i.e. essentially exactly
//!     `navigate.precision_floor_side` (1e-13, the deepest zoom f64 supports). So the ramp
//!     climbs across the WHOLE usable zoom range and only tops out where f64 has run out of
//!     precision and the image cannot improve anyway. Pinned by the tests, so changing one
//!     constant without the others breaks the build.
//!
//! Both auto clamps are load-bearing: zooming OUT past the home view never drops below the
//! M0 baseline, and the auto ramp can never ask for a count the zoom depth cannot use.
//!
//! MANUAL OVERRIDE: `IterPolicy` is plain data — `{ auto, manual_value }`. `manual(value)`
//! is the VALIDATING constructor T7's numeric field calls: an out-of-range value comes back
//! as `AutoIterError.MaxIterOutOfRange` (with `maxIterRangeMessage` for the wording) instead of
//! being silently accepted. `effective()` additionally CLAMPS `manual_value`, so even a
//! hand-built struct can never hand the engine a 1-iteration render.
//!
//! A pinned value is bounded SEPARATELY from the ramp, and far higher (`max_manual_iter` =
//! 2^24): the ramp is calibrated to f64 zoom depth, but someone pinning the count by hand is
//! doing something the ramp does not model — hunting boundary filaments that need many more
//! iterations at a magnification f64 still resolves. That is their time to spend, so the only
//! bound left is representational (the `f32` iteration buffer), not a policy judgement.
//!
//! Errors are returned UNLOGGED (this tier never imports `log`, see
//! `src/fractal/context.md`): the edge logs them, using `maxIterRangeMessage` for a rejected
//! pinned value and T1's `viewport.degenerateRegionMessage(buf, "magnification", mag)` for a
//! magnification that is not finite and positive — one wording per failure, defined once.
const std = @import("std");
const viewport = @import("viewport.zig");
const navigate = @import("navigate.zig");

const SquareView = viewport.SquareView;

/// The M0 iteration count: what `autoMaxIter` returns at the default view and the floor of
/// the auto ramp (zooming out never renders coarser than M0 did).
pub const base_max_iter: u32 = 512;

/// Where the AUTO ramp stops — the count that matches the deepest zoom f64 supports (see the
/// file header). It bounds the ramp ONLY: a manual value may go far past it.
pub const auto_max_iter: u32 = 4096;

/// Highest value the user may pin manually: 2^24, the largest integer an `f32` represents
/// EXACTLY. The iteration buffer is `[]f32` smooth values, so past this bound consecutive
/// iteration counts stop being distinguishable and both the coloring and the status-bar
/// readout would quietly lie. Not a performance bound — a pinned count in the millions is a
/// deliberate trade of time for filament detail, and the render is progressive, so the cost
/// shows up as a slower progress bar rather than a frozen window.
pub const max_manual_iter: u32 = 1 << 24;

/// Lowest value the user may pin manually. Below this the set is an undifferentiated blob,
/// so a smaller number is almost certainly a typo rather than a deliberate speed trade.
pub const min_manual_iter: u32 = 16;

/// Extra iterations granted per doubling of magnification (one 2× zoom step). See the file
/// header for why it is 80.
pub const iter_per_doubling: f64 = 80.0;

/// The magnification the ramp is anchored at: the default (home) view's, straight from T1.
/// Comptime-evaluated, so there is no second definition of the magnification formula.
pub const default_magnification: f64 = SquareView.defaultView().magnification();

/// Rejected `max_iter` inputs. Returned, never logged (see the file header). Named for this
/// module (like `viewport.ViewportError` / `engine.EngineError`) because `iterbuf.zig` already
/// exports a DIFFERENT `IterError` (buffer sizing); T4 imports both, so a bare `IterError`
/// here would read as one type in two places.
pub const AutoIterError = error{
    /// The magnification handed to the heuristic is not finite and positive, so
    /// `log2(mag/mag0)` has no meaning. A view from T1's constructors always has a finite
    /// positive side, but an extreme one (a subnormal side) can still overflow its
    /// magnification to infinity — hence a typed error rather than an assert.
    InvalidMagnification,
    /// A pinned value outside `[min_manual_iter, max_manual_iter]`; report it with
    /// `maxIterRangeMessage`.
    MaxIterOutOfRange,
};

/// The adaptive iteration count for a view at `magnification` — the formula in the file
/// header. Monotonically NON-DECREASING in `magnification` and clamped to
/// `[base_max_iter, auto_max_iter]` at both ends.
///
/// The float result is ROUNDED to nearest (not truncated) so an exact power-of-two zoom
/// lands on the exact documented value even if `log2` is a last-ULP off; rounding is
/// monotone, so that costs nothing.
pub fn autoMaxIter(magnification: f64) AutoIterError!u32 {
    if (!std.math.isFinite(magnification) or magnification <= 0.0) {
        return AutoIterError.InvalidMagnification;
    }
    const doublings = std.math.log2(magnification / default_magnification);
    const raw = @as(f64, @floatFromInt(base_max_iter)) + iter_per_doubling * doublings;
    // Negated comparison so a NaN `raw` (unreachable today, but one refactor away) falls
    // back to the baseline instead of trapping in `@intFromFloat`.
    if (!(raw > @as(f64, @floatFromInt(base_max_iter)))) return base_max_iter;
    if (raw >= @as(f64, @floatFromInt(auto_max_iter))) return auto_max_iter;
    return @intFromFloat(@round(raw));
}

/// Clamp a pinned value into the supported range. `effective` applies this so a policy
/// built by hand (deserialized in M5, or a struct literal) still cannot request an absurd
/// render; T7's field should call `IterPolicy.manual` instead and surface the error.
pub fn clampManual(value: u32) u32 {
    return std.math.clamp(value, min_manual_iter, max_manual_iter);
}

/// How `max_iter` is chosen: plain data (plan A6's "auto toggle + numeric field"), so T7
/// can bind the toggle and the field directly and M5 can serialize it. Defaults to the
/// auto ramp with the M0 count as the remembered manual value, i.e. flipping the toggle off
/// without typing anything reproduces M0.
pub const IterPolicy = struct {
    auto: bool = true,
    manual_value: u32 = base_max_iter,

    /// A policy that pins `value`, or `MaxIterOutOfRange` when it is outside
    /// `[min_manual_iter, max_manual_iter]` (both ends inclusive). This is the entry point for
    /// user input — it is the only place that says no.
    pub fn manual(value: u32) AutoIterError!IterPolicy {
        if (value < min_manual_iter or value > max_manual_iter) return AutoIterError.MaxIterOutOfRange;
        return .{ .auto = false, .manual_value = value };
    }

    /// The iteration count to render this view with: the heuristic when `auto`, else the
    /// clamped pinned value. A pinned value ignores `magnification` entirely, so a garbage
    /// magnification cannot fail a manual render.
    pub fn effective(self: IterPolicy, magnification: f64) AutoIterError!u32 {
        if (self.auto) return autoMaxIter(magnification);
        return clampManual(self.manual_value);
    }
};

const range_prefix = "rejected max_iter: ";
/// The bounds inside the wording are rendered from the constants at comptime, so the
/// message can never disagree with `manual`'s check.
const range_suffix = std.fmt.comptimePrint(
    " is outside the supported range {d}..{d}; enter a value in that range or switch " ++
        "max_iter back to auto",
    .{ min_manual_iter, max_manual_iter },
);

/// Digits in the widest `u32` — the rejected value is whatever the user typed, not a
/// clamped one, so the buffer must fit `4294967295`.
const max_u32_digits: usize = std.fmt.comptimePrint("{d}", .{std.math.maxInt(u32)}).len;

/// Buffer size that fits ANY `maxIterRangeMessage` result. Exactly the worst case, pinned
/// by a test; a shorter buffer returns `error.NoSpaceLeft`.
pub const range_message_buf_len: usize = range_prefix.len + max_u32_digits + range_suffix.len;

/// The human-actionable message for `AutoIterError.MaxIterOutOfRange`: what arrived, the range
/// it missed, and the two ways out. Pure so the wording is unit-tested once and reused by
/// every edge that logs `std.log.err` / shows the user the rejection (T7); pass a
/// `[range_message_buf_len]u8`.
pub fn maxIterRangeMessage(buf: []u8, value: u32) ![]u8 {
    return std.fmt.bufPrint(buf, range_prefix ++ "{d}" ++ range_suffix, .{value});
}

const summary_prefix = "max_iter=";
const auto_suffix: []const u8 = " (auto)";
const manual_suffix: []const u8 = " (manual)";

/// Digits in the largest value `effective` can return (`max_manual_iter`, which is larger
/// than `auto_max_iter`).
const max_effective_digits: usize = std.fmt.comptimePrint("{d}", .{max_manual_iter}).len;

/// Buffer size that fits ANY `policySummary` result (the longest is a manual value at the cap).
/// Exactly the worst case, pinned by a test. It is sized for `effective`'s RANGE — a second
/// reason `policySummary` must print `effective`'s value and never a raw `manual_value`.
pub const summary_buf_len: usize =
    summary_prefix.len + max_effective_digits + manual_suffix.len;

/// The success summary for a chosen iteration count: `"max_iter=1152 (auto)"` or
/// `"max_iter=750 (manual)"`, so the engine's per-pass log line (T4) and T7's panel say the
/// same thing about the same number. Pure (writes only into `buf`) so the exact wording is
/// unit-tested; pass a `[summary_buf_len]u8`.
///
/// The number it prints is ALWAYS `effective`'s, never `manual_value` read directly — so the
/// summary cannot claim a count the render will not use (an out-of-range hand-built policy
/// summarises as its CLAMPED value), and it PROPAGATES `effective`'s error instead of
/// substituting a plausible number, so a magnification that overflowed to `inf` can never be
/// logged as a confident `max_iter=512 (auto)`. Both halves are pinned by tests.
pub fn policySummary(buf: []u8, policy: IterPolicy, magnification: f64) ![]u8 {
    const value = try policy.effective(magnification);
    return std.fmt.bufPrint(buf, summary_prefix ++ "{d}{s}", .{
        value,
        if (policy.auto) auto_suffix else manual_suffix,
    });
}

// ─── Tests ───────────────────────────────────────────────────────────────────

/// The default view's magnification, taken from T1's API (never recomputed here).
const mag0: f64 = SquareView.defaultView().magnification();

/// `iter_per_doubling` as the integer step the tests below compare against.
const step: u32 = @intFromFloat(iter_per_doubling);

test "autoMaxIter returns the M0 baseline at the default view's magnification" {
    try std.testing.expectEqual(@as(u32, 512), try autoMaxIter(mag0));
}

test "autoMaxIter follows the documented formula eight doublings in" {
    // base + k·log2(mag/mag0) = 512 + 80·8 = 1152.
    try std.testing.expectEqual(@as(u32, 1152), try autoMaxIter(std.math.ldexp(mag0, 8)));
}

test "autoMaxIter rounds the ramp to the nearest iteration, not down" {
    // 3× the default magnification ⇒ 512 + 80·log2(3) = 638.797, which rounds to 639.
    try std.testing.expectEqual(@as(u32, 639), try autoMaxIter(mag0 * 3.0));
}

test "each doubling of magnification adds exactly iter_per_doubling inside the ramp" {
    var e: i32 = 1;
    while (e <= 40) : (e += 1) {
        const lo = try autoMaxIter(std.math.ldexp(mag0, e - 1));
        const hi = try autoMaxIter(std.math.ldexp(mag0, e));
        try std.testing.expectEqual(step, hi - lo);
    }
}

test "autoMaxIter never decreases across a fine magnification sweep" {
    var prev: u32 = 0;
    var mag = mag0 / 1024.0;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const value = try autoMaxIter(mag);
        try std.testing.expect(value >= prev);
        prev = value;
        mag *= 1.03;
    }
}

test "autoMaxIter clamps to the baseline at or below the default magnification" {
    try std.testing.expectEqual(base_max_iter, try autoMaxIter(mag0 / 2.0));
    try std.testing.expectEqual(base_max_iter, try autoMaxIter(mag0 / 1.0e6));
    try std.testing.expectEqual(base_max_iter, try autoMaxIter(std.math.floatTrueMin(f64)));
}

test "autoMaxIter clamps to the documented cap at extreme magnification" {
    try std.testing.expectEqual(auto_max_iter, try autoMaxIter(1.0e30));
    try std.testing.expectEqual(auto_max_iter, try autoMaxIter(std.math.floatMax(f64)));
}

test "the ramp reaches the cap on the 45th doubling and not the 44th" {
    // 512 + 80·44 = 4032 < 4096; 512 + 80·45 = 4112, clamped to 4096.
    try std.testing.expectEqual(@as(u32, 4032), try autoMaxIter(std.math.ldexp(mag0, 44)));
    try std.testing.expectEqual(auto_max_iter, try autoMaxIter(std.math.ldexp(mag0, 45)));
}

test "autoMaxIter rejects a non-finite or non-positive magnification" {
    try std.testing.expectError(AutoIterError.InvalidMagnification, autoMaxIter(0.0));
    try std.testing.expectError(AutoIterError.InvalidMagnification, autoMaxIter(-1.0));
    try std.testing.expectError(AutoIterError.InvalidMagnification, autoMaxIter(std.math.nan(f64)));
    try std.testing.expectError(AutoIterError.InvalidMagnification, autoMaxIter(std.math.inf(f64)));
}

test "the ramp spans the whole f64-usable zoom range, capping at the precision floor" {
    const center = viewport.Complex{ .re = -0.75, .im = 0.0 };
    const floor_view = try SquareView.fromCenterSide(center, navigate.precision_floor_side);
    try std.testing.expectEqual(auto_max_iter, try autoMaxIter(floor_view.magnification()));
    // Two decades shallower than the floor the ramp is still climbing, so the cap is
    // not reached long before f64 gives up.
    const usable = try SquareView.fromCenterSide(center, 1.0e-11);
    try std.testing.expect(try autoMaxIter(usable.magnification()) < auto_max_iter);
}

test "an auto policy delegates to the heuristic" {
    const p = IterPolicy{ .auto = true, .manual_value = 64 };
    try std.testing.expectEqual(try autoMaxIter(mag0), try p.effective(mag0));
    const deep = std.math.ldexp(mag0, 12);
    try std.testing.expectEqual(try autoMaxIter(deep), try p.effective(deep));
}

test "a manual policy returns the pinned value regardless of magnification" {
    const p = try IterPolicy.manual(750);
    try std.testing.expectEqual(@as(u32, 750), try p.effective(mag0));
    try std.testing.expectEqual(@as(u32, 750), try p.effective(1.0e9));
}

test "effective clamps a hand-built manual value below the supported range" {
    const p = IterPolicy{ .auto = false, .manual_value = 0 };
    try std.testing.expectEqual(min_manual_iter, try p.effective(mag0));
}

test "effective clamps a hand-built manual value above the supported range" {
    const p = IterPolicy{ .auto = false, .manual_value = std.math.maxInt(u32) };
    try std.testing.expectEqual(max_manual_iter, try p.effective(mag0));
}

test "a manual value in the millions is accepted, not clamped to the auto ramp's ceiling" {
    // The whole point of the manual field: the auto ramp stops at `auto_max_iter` because f64
    // zoom depth runs out there, but a pinned count is the user's own cost/detail trade.
    const p = try IterPolicy.manual(2_000_000);
    try std.testing.expectEqual(@as(u32, 2_000_000), try p.effective(mag0));
    try std.testing.expect(p.manual_value > auto_max_iter);
}

test "the default policy is auto at the M0 baseline" {
    const p = IterPolicy{};
    try std.testing.expect(p.auto);
    try std.testing.expectEqual(base_max_iter, try p.effective(mag0));
}

test "manual rejects a value below the supported range" {
    try std.testing.expectError(AutoIterError.MaxIterOutOfRange, IterPolicy.manual(0));
    try std.testing.expectError(AutoIterError.MaxIterOutOfRange, IterPolicy.manual(min_manual_iter - 1));
}

test "manual rejects a value above the supported range" {
    try std.testing.expectError(AutoIterError.MaxIterOutOfRange, IterPolicy.manual(max_manual_iter + 1));
    try std.testing.expectError(AutoIterError.MaxIterOutOfRange, IterPolicy.manual(std.math.maxInt(u32)));
}

test "manual accepts both ends of the supported range" {
    try std.testing.expectEqual(min_manual_iter, (try IterPolicy.manual(min_manual_iter)).manual_value);
    try std.testing.expectEqual(max_manual_iter, (try IterPolicy.manual(max_manual_iter)).manual_value);
}

test "a manual policy ignores a non-finite magnification instead of failing" {
    const p = try IterPolicy.manual(1024);
    try std.testing.expectEqual(@as(u32, 1024), try p.effective(std.math.nan(f64)));
}

test "an auto policy propagates an invalid magnification as a typed error" {
    const p = IterPolicy{};
    try std.testing.expectError(AutoIterError.InvalidMagnification, p.effective(0.0));
}

test "maxIterRangeMessage names the offending value, the range and what to do" {
    var buf: [range_message_buf_len]u8 = undefined;
    const msg = try maxIterRangeMessage(&buf, 5);
    try std.testing.expectEqualStrings(
        "rejected max_iter: 5 is outside the supported range 16..16777216; " ++
            "enter a value in that range or switch max_iter back to auto",
        msg,
    );
}

test "range_message_buf_len is exactly the worst-case message length" {
    var buf: [range_message_buf_len]u8 = undefined;
    const msg = try maxIterRangeMessage(&buf, std.math.maxInt(u32));
    try std.testing.expectEqual(range_message_buf_len, msg.len);
}

test "maxIterRangeMessage reports NoSpaceLeft instead of truncating" {
    var buf: [range_message_buf_len - 1]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, maxIterRangeMessage(&buf, std.math.maxInt(u32)));
}

test "policySummary reports the auto value and that it was derived automatically" {
    var buf: [summary_buf_len]u8 = undefined;
    try std.testing.expectEqualStrings("max_iter=512 (auto)", try policySummary(&buf, .{}, mag0));
}

test "policySummary reports a pinned manual value" {
    var buf: [summary_buf_len]u8 = undefined;
    const p = try IterPolicy.manual(750);
    try std.testing.expectEqualStrings("max_iter=750 (manual)", try policySummary(&buf, p, mag0));
}

test "policySummary reports the clamped effective value, not a raw out-of-range manual one" {
    // Guards the one-source-of-truth premise: a summary formatted from `manual_value` directly
    // would advertise 99999999 while the render used 16777216.
    var buf: [summary_buf_len]u8 = undefined;
    // 99999999 is above the cap but has the SAME digit count as the clamped 16777216, so the
    // claim is about the value and cannot be satisfied by a buffer-length accident.
    const p = IterPolicy{ .auto = false, .manual_value = 99_999_999 };
    try std.testing.expectEqualStrings("max_iter=16777216 (manual)", try policySummary(&buf, p, mag0));
}

test "policySummary propagates an invalid magnification instead of summarising a fabricated count" {
    var buf: [summary_buf_len]u8 = undefined;
    const p = IterPolicy{};
    try std.testing.expectError(
        AutoIterError.InvalidMagnification,
        policySummary(&buf, p, 0.0),
    );
    try std.testing.expectError(
        AutoIterError.InvalidMagnification,
        policySummary(&buf, p, std.math.inf(f64)),
    );
}

test "summary_buf_len is exactly the worst-case summary length" {
    var buf: [summary_buf_len]u8 = undefined;
    const p = try IterPolicy.manual(max_manual_iter);
    const line = try policySummary(&buf, p, mag0);
    try std.testing.expectEqual(summary_buf_len, line.len);
}

test "policySummary reports NoSpaceLeft instead of truncating" {
    var buf: [summary_buf_len - 1]u8 = undefined;
    const p = try IterPolicy.manual(max_manual_iter);
    try std.testing.expectError(error.NoSpaceLeft, policySummary(&buf, p, mag0));
}
