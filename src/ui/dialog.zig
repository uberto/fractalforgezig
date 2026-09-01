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

/// Outcome kind stored in `PendingDialog` after the callback fires. `save`/`open` are the whole
/// picture (`.fractal`); `save_scheme`/`open_scheme` are a colour-only scheme (`.fpal`).
pub const Kind = enum { none, save, open, save_scheme, open_scheme };

/// Written by the C callback; polled by the main loop each frame.
/// Stack-allocate one in `runLoop`; its lifetime must outlive all dialog callbacks.
pub const PendingDialog = struct {
    kind: Kind = .none,
    /// Set to true by the callback when it fires (even on cancel). Distinguishes
    /// "waiting for callback" from "user cancelled (path_len == 0)".
    callback_fired: bool = false,
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

/// `pattern` is a semicolon-separated list of BARE EXTENSIONS — `"fractal"`, NOT `"*.fractal"`.
/// SDL3 validates this and only accepts `[a-zA-Z0-9_.-]`, or a lone `"*"` for "all files"
/// (`SDL_dialog.h`, `SDL_DialogFileFilter`). A glob like `"*.fractal"` fails validation
/// ("Invalid character '*' in pattern"), and the failure arrives as a callback with a NULL
/// filelist — so the dialog silently never appears. That was the M5 save/open bug.
const fractal_filter = c.SDL_DialogFileFilter{
    .name = "Fractal files (*.fractal)", // free-form label; the glob is fine HERE
    .pattern = "fractal",
};

/// A colour-only scheme file. BARE extension `fpal`, never `*.fpal` — same SDL3 validation rule
/// as `fractal_filter` above (a glob in `pattern` fails and the dialog silently never appears).
const scheme_filter = c.SDL_DialogFileFilter{
    .name = "Colour schemes (*.fpal)", // free-form label; the glob is fine HERE
    .pattern = "fpal",
};

// ─── C callback ──────────────────────────────────────────────────────────────

fn dialogCallback(
    userdata: ?*anyopaque,
    filelist: [*c]const [*c]const u8,
    filter: c_int,
) callconv(.c) void {
    _ = filter;
    const pending: *PendingDialog = @ptrCast(@alignCast(userdata orelse return));

    // SDL3 encodes THREE outcomes here, and conflating the first two is how a dialog that
    // never opened used to look exactly like a dialog the user dismissed:
    //   * `filelist == null`        → SDL FAILED; the reason is in `SDL_GetError()`.
    //   * `filelist[0] == null`     → the user cancelled or chose nothing.
    //   * otherwise                 → a path was chosen.
    // Every branch must set `callback_fired`, or `takePending` never clears `kind` and every
    // later dialog is silently swallowed by the one-at-a-time guard.
    if (filelist == null) {
        pending.callback_fired = true;
        log.err("file dialog failed to open: {s}", .{std.mem.span(c.SDL_GetError())});
        return;
    }
    const first = filelist[0] orelse {
        pending.callback_fired = true;
        log.info("dialog cancelled", .{});
        return;
    };

    const src = std.mem.span(first);
    log.info("dialog callback: path={s}", .{src});
    if (src.len > max_path_len) {
        log.warn("dialog path truncated ({d} > {d} bytes)", .{ src.len, max_path_len });
    }
    const copy_len = @min(src.len, max_path_len);
    @memcpy(pending.path_buf[0..copy_len], src[0..copy_len]);
    pending.path_buf[copy_len] = 0;
    pending.path_len = copy_len;
    pending.callback_fired = true;
}

// ─── Public API ──────────────────────────────────────────────────────────────

/// Show the OS save dialog. No-op if a dialog result is already pending.
/// The callback fires on the main thread after `SDL_PumpEvents`.
pub fn showSave(window: *c.SDL_Window, pending: *PendingDialog) void {
    if (pending.kind != .none) return;
    pending.kind = .save;
    pending.path_len = 0;
    pending.callback_fired = false;
    c.SDL_ShowSaveFileDialog(dialogCallback, pending, window, &fractal_filter, 1, null);
    log.info("save dialog requested", .{});
}

/// Show the OS open dialog. No-op if a dialog result is already pending.
pub fn showOpen(window: *c.SDL_Window, pending: *PendingDialog) void {
    if (pending.kind != .none) return;
    pending.kind = .open;
    pending.path_len = 0;
    pending.callback_fired = false;
    c.SDL_ShowOpenFileDialog(dialogCallback, pending, window, &fractal_filter, 1, null, false);
    log.info("open dialog requested", .{});
}

/// Show the OS save dialog for a colour SCHEME (`.fpal`). No-op if a dialog is already pending.
/// Mirrors `showSave`; only the file filter differs.
pub fn showSaveScheme(window: *c.SDL_Window, pending: *PendingDialog) void {
    if (pending.kind != .none) return;
    pending.kind = .save_scheme;
    pending.path_len = 0;
    pending.callback_fired = false;
    c.SDL_ShowSaveFileDialog(dialogCallback, pending, window, &scheme_filter, 1, null);
    log.info("save-scheme dialog requested", .{});
}

/// Show the OS open dialog for a colour SCHEME (`.fpal`). No-op if a dialog is already pending.
/// Mirrors `showOpen`; only the file filter differs.
pub fn showOpenScheme(window: *c.SDL_Window, pending: *PendingDialog) void {
    if (pending.kind != .none) return;
    pending.kind = .open_scheme;
    pending.path_len = 0;
    pending.callback_fired = false;
    c.SDL_ShowOpenFileDialog(dialogCallback, pending, window, &scheme_filter, 1, null, false);
    log.info("open-scheme dialog requested", .{});
}

/// Check whether a dialog completed. Returns `null` if no result is ready yet or the user
/// cancelled (path_len == 0). Resets `pending` to `.none` so the next dialog can open.
pub fn takePending(pending: *PendingDialog) ?PendingResult {
    if (pending.kind == .none) return null;
    if (!pending.callback_fired) return null; // dialog still open
    const kind = pending.kind;
    const path_len = pending.path_len;
    pending.kind = .none;
    pending.callback_fired = false;
    if (path_len == 0) return null; // cancelled
    return PendingResult{
        .kind = kind,
        .path = pending.path_buf[0..path_len],
    };
}
