//! SDL3 native file-dialog wrapper for save/open operations.
//!
//! SDL3's `SDL_ShowSaveFileDialog` / `SDL_ShowOpenFileDialog` are asynchronous:
//! they launch the OS-native dialog and fire a C callback on the main thread after
//! `SDL_PumpEvents` (which happens inside `SDL_WaitEvent`/`SDL_PollEvent`).
//!
//! To integrate safely with the ImGui frame loop (which must not mutate engine state
//! mid-frame), this module uses a `PendingDialog` struct that the C callback writes
//! into. The main loop polls `takePending` each frame and applies the result after
//! `ui.endFrame()` — the same deferred pattern used for GPU toggle and texture upload.
//!
//! Only one dialog at a time. `showSave`/`showOpen` are no-ops if `pending.kind != .none`.
const std = @import("std");
const c = @import("../c.zig").c;

const log = std.log.scoped(.ui);

/// Maximum path length stored in `PendingDialog`. Paths longer than this are truncated.
pub const max_path_len = 511;

/// Outcome kind stored in `PendingDialog` after the callback fires.
pub const Kind = enum { none, save, open };

/// Written by the C callback; polled by the main loop each frame.
/// Stack-allocate one in `runLoop`; its lifetime must outlive all dialog callbacks.
pub const PendingDialog = struct {
    kind: Kind = .none,
    path_buf: [max_path_len + 1]u8 = undefined,
    path_len: usize = 0,
};

/// The path selected by the user (valid only until the next `showSave`/`showOpen`/`takePending`).
pub const PendingResult = struct {
    kind: Kind,
    /// Slice into `PendingDialog.path_buf`. Valid until next call that resets the pending state.
    path: []const u8,
};

// ─── File filter ─────────────────────────────────────────────────────────────

const fractal_filter = c.SDL_DialogFileFilter{
    .name = "Fractal files (*.fractal)",
    .pattern = "*.fractal",
};

// ─── C callback ──────────────────────────────────────────────────────────────

fn dialogCallback(
    userdata: ?*anyopaque,
    filelist: [*c]const [*c]const u8,
    filter: c_int,
) callconv(.c) void {
    _ = filter;
    const pending: *PendingDialog = @ptrCast(@alignCast(userdata orelse return));

    // filelist is null or filelist[0] is null on cancel.
    if (filelist == null) return;
    const first = filelist[0] orelse return;

    const src = std.mem.span(first);
    if (src.len > max_path_len) {
        log.warn("dialog path truncated ({d} > {d} bytes)", .{ src.len, max_path_len });
    }
    const copy_len = @min(src.len, max_path_len);
    @memcpy(pending.path_buf[0..copy_len], src[0..copy_len]);
    pending.path_buf[copy_len] = 0;
    pending.path_len = copy_len;
    // kind is set by showSave/showOpen before the dialog opens; callback only fills the path.
}

// ─── Public API ──────────────────────────────────────────────────────────────

/// Show the OS save dialog. No-op if a dialog result is already pending.
/// The callback fires on the main thread after `SDL_PumpEvents`.
pub fn showSave(window: *c.SDL_Window, pending: *PendingDialog) void {
    if (pending.kind != .none) return;
    pending.kind = .save;
    pending.path_len = 0;
    c.SDL_ShowSaveFileDialog(dialogCallback, pending, window, &fractal_filter, 1, null);
}

/// Show the OS open dialog. No-op if a dialog result is already pending.
pub fn showOpen(window: *c.SDL_Window, pending: *PendingDialog) void {
    if (pending.kind != .none) return;
    pending.kind = .open;
    pending.path_len = 0;
    c.SDL_ShowOpenFileDialog(dialogCallback, pending, window, &fractal_filter, 1, null, false);
}

/// Check whether a dialog completed. Returns `null` if no result is ready or the user
/// cancelled (path_len == 0). Resets `pending` to `.none` so the next dialog can open.
pub fn takePending(pending: *PendingDialog) ?PendingResult {
    if (pending.kind == .none) return null;
    const kind = pending.kind;
    const path_len = pending.path_len;
    pending.kind = .none;
    if (path_len == 0) return null; // cancelled
    return PendingResult{
        .kind = kind,
        .path = pending.path_buf[0..path_len],
    };
}
