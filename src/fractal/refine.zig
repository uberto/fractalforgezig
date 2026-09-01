//! Pure coarse→fine pass-decision helper (T6, plan A7).
//!
//! Encapsulates the "which pass to run now" logic so it is testable without any
//! SDL/ImGui dependency. The edge in `main.zig` calls `decidePass` once per frame
//! and acts on the result; no state lives here — the caller owns `interacting`,
//! `idle_ns`, and `full_pass_done`.
//!
//! Pass strategy (plan A7):
//!   - `cancelled == true`    → `.none`: the user stopped this view's refinement; leave the
//!     partly-refined image exactly as it is and do not re-arm the pass on idle.
//!   - `interacting == true`  → `.coarse`: run the ¼-S preview every frame during drag.
//!   - idle long enough and full not done → `.full`: run the full-res pass after release.
//!   - otherwise → `.none`: do nothing this frame.
//!
//! NO SDL/ImGui/GPU imports — this lives in the fast test tier (`zig build test`).

/// Result: which pass the edge should schedule this frame.
pub const PassDecision = enum { coarse, full, none };

/// How many nanoseconds of idle time must elapse before promoting to the full pass.
/// 150 ms is enough to avoid firing during fast scroll/drag, but short enough that
/// the sharp render appears quickly after the user stops interacting.
pub const idle_threshold_ns: u64 = 150_000_000;

/// Decide which pass to run this frame:
/// - `interacting`:    the user is currently dragging, scrolling, or pressing Space+LMB
/// - `idle_ns`:        nanoseconds elapsed since the last navigation action
/// - `full_pass_done`: whether the full-res pass has already run for the current view
/// - `cancelled`:      the user has cancelled this view's refinement and not restarted it
///
/// Rules (plan A7, `cancelled` added m9):
///   0. `cancelled` → `.none`  (leave the partly-refined image as it is; do NOT re-arm the
///      very pass the user just cancelled, so idle promotion cannot fight the cancel)
///   1. `interacting` → `.coarse`  (run the cheap ¼-res preview while the user moves)
///   2. `!interacting` and `idle_ns >= idle_threshold_ns` and `!full_pass_done` → `.full`
///   3. otherwise → `.none`  (view is already sharp or we are still in the idle window)
pub fn decidePass(interacting: bool, idle_ns: u64, full_pass_done: bool, cancelled: bool) PassDecision {
    if (cancelled) return .none;
    if (interacting) return .coarse;
    if (!full_pass_done and idle_ns >= idle_threshold_ns) return .full;
    return .none;
}

// ─── Tests ───────────────────────────────────────────────────────────────────
// All tests are pure (no SDL/ImGui), deterministic (no clock/random/shared state).
// One assertion of intent per test; edge cases covered.
const std = @import("std");

test "decidePass: interacting always returns coarse" {
    // During a drag/scroll, always run the cheap preview regardless of idle or full state.
    try std.testing.expectEqual(PassDecision.coarse, decidePass(true, 0, false, false));
    try std.testing.expectEqual(PassDecision.coarse, decidePass(true, idle_threshold_ns + 1, false, false));
    try std.testing.expectEqual(PassDecision.coarse, decidePass(true, idle_threshold_ns + 1, true, false));
}

test "decidePass: idle past threshold and full not done returns full" {
    // After the user stops interacting and the idle window has passed, upgrade to full res.
    try std.testing.expectEqual(PassDecision.full, decidePass(false, idle_threshold_ns, false, false));
    try std.testing.expectEqual(PassDecision.full, decidePass(false, idle_threshold_ns + 1, false, false));
    try std.testing.expectEqual(PassDecision.full, decidePass(false, 999_999_999, false, false));
}

test "decidePass: idle past threshold but full already done returns none" {
    // Once the full pass has been rendered for this view, don't repeat it.
    try std.testing.expectEqual(PassDecision.none, decidePass(false, idle_threshold_ns, true, false));
    try std.testing.expectEqual(PassDecision.none, decidePass(false, idle_threshold_ns + 1, true, false));
}

test "decidePass: idle but not past threshold yet returns none" {
    // During the idle window (user just released), wait before starting the expensive pass.
    try std.testing.expectEqual(PassDecision.none, decidePass(false, 0, false, false));
    try std.testing.expectEqual(PassDecision.none, decidePass(false, idle_threshold_ns - 1, false, false));
    try std.testing.expectEqual(PassDecision.none, decidePass(false, 1, false, false));
}

test "decidePass: a cancelled view is not promoted; clearing the cancel restores promotion" {
    // Idle past the threshold with no full pass done: normally this promotes to `.full`. Once
    // the user has cancelled, the same state must yield `.none` so the partly-refined image is
    // left as it is and idle promotion cannot re-arm the pass the user just cancelled.
    try std.testing.expectEqual(PassDecision.none, decidePass(false, idle_threshold_ns + 1, false, true));
    // Clearing the cancel restores normal promotion for the very same view state.
    try std.testing.expectEqual(PassDecision.full, decidePass(false, idle_threshold_ns + 1, false, false));
}

test "decidePass: cancel overrides interacting (no coarse preview is armed either)" {
    // The cancel latch is checked before the interacting branch, so it also suppresses the
    // ¼-res preview — "NOT .coarse and NOT .full regardless", per the task's pure rule.
    try std.testing.expectEqual(PassDecision.none, decidePass(true, 0, false, true));
}
