//! Executable entry point. Thin init/render/shutdown glue.
//! Pure math lives in `fractal/`, GPU edge in `gpu/`, ImGui layout in `ui/`.
//!
//! T6 additions: mouse/keyboard navigation (box-select, pan, scroll-zoom,
//! right-click zoom menu), hover coordinate readout, and coarse→fine recompute
//! driven by the pure `refine.PassDecision` helper.
const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const c = @import("c.zig").c;
const ig = @import("cimgui.zig");
const gpu = @import("gpu/device.zig");
const ui_mod = @import("ui/imgui.zig");
const viewport = @import("fractal/viewport.zig");
const navigate = @import("fractal/navigate.zig");
const autoiter = @import("fractal/autoiter.zig");
const engine_mod = @import("fractal/engine.zig");
const texture_mod = @import("gpu/texture.zig");
const compute_mod = @import("gpu/compute.zig");
const stats_mod = @import("ui/stats.zig");
const editor_mod = @import("ui/editor.zig");
const gesture = @import("ui/gesture.zig");
const panels = @import("ui/panels.zig");
const refine = @import("fractal/refine.zig");
const perturb = @import("fractal/perturb.zig");
const persist = @import("fractal/persist.zig");
const scheme = @import("fractal/scheme.zig");
const dialog = @import("ui/dialog.zig");

const app_log = std.log.scoped(.app);

/// Module-level compute pipeline so the IterFn (which has no closure) can reach it.
var g_compute_pipeline: ?compute_mod.ComputePipeline = null;

/// Install (or clear) the pipeline the `IterFn` reaches through. `main` sets it once after the
/// device exists; a test uses it to drive `gpuIterFn` against a headless device, which is the
/// only way to pin THE ROUTING the app actually runs rather than a copy of it.
pub fn installComputePipeline(pl: ?compute_mod.ComputePipeline) void {
    g_compute_pipeline = pl;
}

/// The IterFn wired into engine.gpu_iter_fn when GPU mode is enabled. One BAND per call
/// (`engine.IterFn`), so a GPU render is chunked across frames like the CPU one.
///
/// ROUTING (M6/T6): a non-null `orbit` means the engine has decided this view needs the DEEP
/// (perturbation) path, so the band goes to `gpuIterateDeepRows`, which uploads that orbit and
/// iterates per-pixel deltas; a null orbit is a shallow view and goes to `gpuIterateRows`,
/// unchanged. This is the ONLY path from the running app to the deep kernel — if the deep branch
/// is ever removed or made to fall through to `gpuIterateRows`, the app renders a flat colour at
/// depth (a WRONG image, not a coarse one) while every unit test still passes.
///
/// `gpuIterateDeepRows` refuses views outside the `f32` envelope with a typed error; the engine
/// has already checked the same envelope and would not have called us, but if it somehow does,
/// the returned error puts that band back on the CPU rather than on screen.
pub fn gpuIterFn(
    view: viewport.SquareView,
    w: u32,
    h: u32,
    max_iter: u32,
    y0: u32,
    rows: u32,
    iter_band: []f32,
    orbit: ?*const perturb.ReferenceOrbit,
) anyerror!void {
    const pl = g_compute_pipeline orelse return error.GpuPipelineNotReady;
    if (orbit) |o| {
        try compute_mod.gpuIterateDeepRows(pl, view, o, w, h, max_iter, y0, rows, iter_band);
    } else {
        try compute_mod.gpuIterateRows(pl, view, w, h, max_iter, y0, rows, iter_band);
    }
}

const window_title = "fractalforge";
const initial_window_w = 1280;
const initial_window_h = 720;

/// Divisor for the COARSE preview resolution, applied to EACH axis (`w/4 × h/4`), so the
/// preview keeps the region's aspect ratio and costs ~1/16 of a full pass. Dividing a single
/// square "navigation side" instead is what used to make the preview square — and therefore
/// letterboxed differently from the full-res image it was replaced by.
const coarse_divisor: u32 = 4;

/// How many region-size changes may restart the full-resolution pass before the loop stops
/// chasing the size (see `NavState.region_thrash`). A UI layout whose size depends on its own
/// content can oscillate between two values every frame; without this, each frame would cancel
/// the pass and the image would stay blocky forever. Finishing at a slightly stale size is
/// strictly better: `viewport.fitImageRect` letterboxes the difference instead of stretching.
const region_thrash_limit: u8 = 8;

pub fn main() !void {
    var buf: [128]u8 = undefined;
    const banner = try root.startupLine(&buf, builtin.zig_version_string);
    app_log.info("{s}", .{banner});

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        app_log.err("SDL_Init failed: {s}", .{std.mem.span(c.SDL_GetError())});
        return error.SdlInitFailed;
    }
    defer c.SDL_Quit();

    // T5: window is resizable so the user can change S = min(window_w, window_h).
    const window = c.SDL_CreateWindow(window_title, initial_window_w, initial_window_h, c.SDL_WINDOW_RESIZABLE) orelse {
        app_log.err("SDL_CreateWindow failed: {s}", .{std.mem.span(c.SDL_GetError())});
        return error.SdlWindowCreationFailed;
    };
    defer c.SDL_DestroyWindow(window);

    const device = try gpu.Device.create(window);
    defer device.destroy();

    // Initialize the Metal compute pipeline for GPU iteration (M4).
    // Failure is non-fatal: the GPU checkbox in the UI will be disabled if null.
    g_compute_pipeline = compute_mod.ComputePipeline.create(device.handle) catch |err| blk: {
        app_log.warn("GPU compute pipeline init failed ({s}); GPU mode unavailable", .{@errorName(err)});
        break :blk null;
    };
    defer if (g_compute_pipeline) |pl| pl.destroy();

    const ui = try ui_mod.Ui.init(window, device);
    defer ui.shutdown();

    // Read the initial window size and ESTIMATE the fractal region: the exact region size
    // is only known once ImGui has laid the frame out, and `runLoop` picks it up from
    // `DrawResult.render_w/render_h` on the first frame. The estimate only has to be close
    // enough to pick a sane startup resolution.
    var win_w: c_int = 0;
    var win_h: c_int = 0;
    _ = c.SDL_GetWindowSize(window, &win_w, &win_h);
    const panel_taken: u32 = @as(u32, @intFromFloat(panels.data_panel_w + panels.region_spacing));
    const est_w: u32 = if (@as(u32, @intCast(win_w)) > panel_taken) @as(u32, @intCast(win_w)) - panel_taken else 1;
    const est_h: u32 = if (win_h > 0) @intCast(win_h) else 1;

    if (@min(est_w, est_h) == 0) {
        app_log.err("startup window has zero side (S=0); cannot initialise the engine", .{});
        return error.DegenerateWindowSize;
    }

    // Engine: holds the view, w×h, policy, iteration buffer, RGBA output.
    //
    // Startup renders COARSE (region/`coarse_divisor` on each axis), exactly like a
    // navigation preview: the window comes up in milliseconds, and the loop's idle check
    // promotes it to a full-resolution PROGRESSIVE pass at the region's real, rectangular
    // size. Starting at full resolution here is what used to block the first frame — and,
    // because the region's aspect was unknown, what produced the stretched first image.
    const view = viewport.SquareView.defaultView();
    const init_w = @max(est_w / coarse_divisor, 1);
    const init_h = @max(est_h / coarse_divisor, 1);
    var engine = engine_mod.Engine.initRect(std.heap.page_allocator, view, init_w, init_h, .{}) catch |err| {
        app_log.err("color engine init failed ({s}); aborting startup", .{@errorName(err)});
        return err;
    };
    defer engine.deinit();
    // Wire GPU iteration function if the pipeline is available (M4).
    if (g_compute_pipeline != null) {
        engine.gpu_iter_fn = gpuIterFn;
    }

    var iterate_timer = std.time.Timer.start() catch null;
    engine.iterate() catch |err| {
        app_log.err("Mandelbrot iteration failed ({s}); aborting startup", .{@errorName(err)});
        return err;
    };
    const iterate_ns = if (iterate_timer) |*t| t.read() else 0;

    // Where the coarse image lands on screen until the first frame reports the real region:
    // aspect-preserving, so even this placeholder is never stretched.
    var image_rect = viewport.fitImageRect(0, 0, est_w, est_h, engine.image_w, engine.image_h);

    var texture = try texture_mod.createRgbaTexture(device.handle, engine.image_w, engine.image_h);
    defer texture.destroy();
    try texture_mod.upload(device.handle, texture, engine.output());

    var summary_buf: [128]u8 = undefined;
    const summary = try stats_mod.renderSummary(&summary_buf, engine.image_w, engine.image_h, engine.max_iter, iterate_ns);
    app_log.info("{s}", .{summary});
    var color_buf: [96]u8 = undefined;
    if (engine.summary(&color_buf)) |line| app_log.info("{s}", .{line}) else |_| {}

    var app_stats = stats_mod.Stats.fromRender(iterate_ns);
    var editor = editor_mod.Editor.initDefault();
    var view_editor = editor_mod.ViewEditor.initFromView(engine.view);

    // Preview textures for the built-in preset swatches (baked once; see `panels.SwatchGallery`).
    var gallery = try panels.SwatchGallery.init(device.handle);
    defer gallery.deinit();

    app_log.info("entering event loop", .{});
    runLoop(window, device, ui, &texture, &image_rect, &app_stats, &engine, &editor, &view_editor, &gallery);
    app_log.info("event loop exited; shutting down cleanly", .{});
}

// ─── Navigation state ─────────────────────────────────────────────────────────

/// Box-select drag state.
const DragState = enum { none, active };

const history_cap = 64;

/// All navigation state for one run of the event loop. No globals.
const NavState = struct {
    /// Whether a left-drag box-select is in progress.
    drag_state: DragState = .none,
    /// Image-space pixel where the left button went down (box-select start).
    drag_start_px: viewport.Pixel = .{ .x = 0.0, .y = 0.0 },
    /// Window-space position where the left button went down (rubber-band drawing).
    drag_start_win_x: f32 = 0.0,
    drag_start_win_y: f32 = 0.0,

    /// Stashed complex point for the right-click context menu. FULL precision (M6): it is a
    /// gesture anchor, and at depth an `f64` copy would round it onto the view center.
    right_click_pt: viewport.ComplexHi = .{ .re = -0.75, .im = 0.0 },
    /// Whether to open the right-click popup this frame.
    open_ctx_menu: bool = false,

    /// One frame's gesture input — trackpad pinch AND every `SDL_EVENT_MOUSE_WHEEL` — reduced
    /// by the pure `ui/gesture.zig` accumulator to AT MOST ONE view change.
    /// DRAINED EXACTLY ONCE PER FRAME, by the drain step that follows the event-drain loop in
    /// `runLoop` — so N pinch updates or N swipe deltas arriving in one frame cost one coarse
    /// render and one undo entry, not N of each.
    gestures: gesture.Accumulator = .{},
    /// The undo entry the CURRENT gesture run still owes — the pure latch that makes one whole
    /// gesture one undo step even when the run's first frame changes nothing on screen. Read
    /// instead of `Intent.began` at the drain's install (see there, and `gesture.HistoryDebt`
    /// for the bug it exists to prevent). Not in `main.zig` as a bare `bool` on purpose: the
    /// decision it encodes is the whole content of that bug and this file has no test tier.
    history_debt: gesture.HistoryDebt = .{},
    /// Which pointing device the wheel events are coming from, and the ONE place that answer
    /// lives. `.auto` detects (a whole tick with no horizontal component is a mouse notch and
    /// zooms; anything else is a two-finger swipe and pans); the data panel's Input → device
    /// control overrules the detection by asking for a new value here
    /// (`panels.CoordRequest.input_mode`, installed after the frame). The panel keeps no copy: it
    /// DISPLAYS this field, so the two cannot disagree. Session-only by design — a milestone
    /// non-goal — so it is not saved to a `.fractal` file and starts at `.auto` every run.
    input_mode: gesture.InputMode = .auto,
    /// Whether the view now on screen is already past `viewport.precision_floor_side`.
    /// Exists ONLY to make that warning EDGE-TRIGGERED: a continuous pinch installs a view
    /// every frame, so warning on every install would print ~60 identical lines a second and
    /// bury everything else. Maintained by `showViewCoarse`, the one place a view is installed.
    past_floor: bool = false,

    /// Whether the full-res pass has been run for the current view. False from startup on:
    /// the first image is a coarse preview (see `main`), promoted by the idle check.
    full_pass_done: bool = false,
    /// True from the moment a coarse preview goes up until the full-resolution pass finishes.
    /// Passed to `panels.draw`, which FREEZES the edit panels while it is set: a value edited
    /// against a half-rendered image would only apply to the next pass anyway.
    rendering: bool = true,
    /// Set when the user cancelled this view's refinement (Cancel button or Escape) and has not
    /// restarted it or changed the view. Fed to `refine.decidePass`, where it wins over every
    /// other rule so idle promotion cannot re-arm the very pass the user just stopped (the
    /// cancel→re-arm→cancel loop). Cleared by `armFullPass` on a Render restart and at every view
    /// change (each `showViewCoarse`/`showPolicyCoarse` supersedes the cancelled view).
    cancelled: bool = false,
    /// Set when engine output changed and needs to be uploaded to the GPU texture.
    /// Upload is deferred to after ui.endFrame() so ImGui never sees a destroyed handle.
    needs_upload: bool = false,
    /// Set for the ONE frame after an upload: the pixels went to the texture *after* the frame
    /// that was presented, so what the user sees is one frame stale. The loop must draw once
    /// more before it is allowed to block on events — otherwise a render that finishes in a
    /// single chunk (GPU mode) stays invisible until an unrelated event, e.g. a mouse move,
    /// happens to wake the loop up.
    needs_present: bool = false,
    /// Nanoseconds taken by the most recent iteration pass (for render_ms display).
    last_render_ns: u64 = 0,
    /// Wall-clock nanoseconds accumulated by the chunks of the in-flight progressive pass.
    /// Reset by `beginFullPass`, reported as render_ms / gpu_render_ms on completion — so the
    /// stat still measures the whole iteration even though it is spread over many frames.
    pass_ns: u64 = 0,
    /// How many times a region-size change has restarted the full-resolution pass since one
    /// last completed. A layout that oscillates between two sizes would otherwise cancel the
    /// pass every frame and never produce a sharp image; past `region_thrash_limit` the loop
    /// stops chasing the size and lets the in-flight pass finish (see the region check in
    /// `runLoop`). Cleared by `stepPassChunk` on completion.
    region_thrash: u8 = 0,

    /// Timer measuring idle time since the last navigation action.
    idle_timer: ?std.time.Timer = null,

    /// Undo/redo history. `undo_buf[0..undo_len]` are views we can return to
    /// (most-recent-first). `redo_buf[0..redo_len]` are views popped by undo.
    undo_buf: [history_cap]viewport.SquareView = undefined,
    undo_len: usize = 0,
    redo_buf: [history_cap]viewport.SquareView = undefined,
    redo_len: usize = 0,
};

/// Push `old_view` onto the undo stack before committing a new view.
/// Clears the redo stack (a new navigation invalidates the redo chain).
fn historyPush(nav: *NavState, old_view: viewport.SquareView) void {
    if (nav.undo_len < history_cap) {
        nav.undo_buf[nav.undo_len] = old_view;
        nav.undo_len += 1;
    } else {
        // Shift oldest entry out to make room (FIFO eviction at the bottom).
        std.mem.copyForwards(viewport.SquareView, nav.undo_buf[0 .. history_cap - 1], nav.undo_buf[1..history_cap]);
        nav.undo_buf[history_cap - 1] = old_view;
    }
    nav.redo_len = 0;
}

/// Undo: restore the most recent view on the undo stack, push current onto redo.
fn historyUndo(
    engine: *engine_mod.Engine,
    nav: *NavState,
    real_w: u32,
    real_h: u32,
    view_editor: *editor_mod.ViewEditor,
) void {
    if (nav.undo_len == 0) return;
    const prev = nav.undo_buf[nav.undo_len - 1];
    nav.undo_len -= 1;
    if (nav.redo_len < history_cap) {
        nav.redo_buf[nav.redo_len] = engine.view;
        nav.redo_len += 1;
    }
    showViewCoarse(engine, nav, prev, real_w, real_h, view_editor);
}

/// Redo: restore the most recent undone view.
fn historyRedo(
    engine: *engine_mod.Engine,
    nav: *NavState,
    real_w: u32,
    real_h: u32,
    view_editor: *editor_mod.ViewEditor,
) void {
    if (nav.redo_len == 0) return;
    const next = nav.redo_buf[nav.redo_len - 1];
    nav.redo_len -= 1;
    if (nav.undo_len < history_cap) {
        nav.undo_buf[nav.undo_len] = engine.view;
        nav.undo_len += 1;
    }
    showViewCoarse(engine, nav, next, real_w, real_h, view_editor);
}

// ─── View-change helpers ───────────────────────────────────────────────────────

/// Recreate the GPU texture if its dimensions differ from engine.image_w × engine.image_h.
fn syncTexture(device: gpu.Device, texture: *texture_mod.Texture, engine: *engine_mod.Engine) void {
    if (texture.width == engine.image_w and texture.height == engine.image_h) return;
    texture.destroy();
    texture.* = texture_mod.createRgbaTexture(device.handle, engine.image_w, engine.image_h) catch |err| {
        app_log.err("texture sync to {d}×{d} failed ({s})", .{ engine.image_w, engine.image_h, @errorName(err) });
        return;
    };
}

/// Apply a new view: push the old one on the undo stack, then show it (see `showViewCoarse`).
/// Every USER navigation (gesture, context menu, coord panel) comes through here; undo/redo
/// and file-load skip the history push and call `showViewCoarse` directly.
///
/// RETURNS whether an undo entry was actually pushed, which is false exactly when the no-op
/// guard below refused the view. Only the gesture drain reads it — a gesture run owes ONE entry
/// and must keep owing it until one is really pushed (`gesture.HistoryDebt`); every other caller
/// is a single discrete navigation and discards the answer.
fn applyViewCoarse(
    engine: *engine_mod.Engine,
    nav: *NavState,
    new_view: viewport.SquareView,
    real_w: u32,
    real_h: u32,
    view_editor: *editor_mod.ViewEditor,
) bool {
    // A gesture that lands on the view already on screen is a no-op: re-installing it would
    // re-render an identical image and stack up duplicate undo entries. This is the ORDINARY
    // case at `navigate.max_view_side` (F1), where every further zoom-out notch saturates on
    // the same view — and it was always true of a zero-delta drag.
    if (std.meta.eql(new_view, engine.view)) return false;
    historyPush(nav, engine.view);
    showViewCoarse(engine, nav, new_view, real_w, real_h, view_editor);
    return true;
}

/// Install `new_view` and render it COARSE right away, then arm the full-resolution pass.
///
/// This is the ONE path every view change takes, and the reason none of them can freeze the
/// window: `installView` does not render, the coarse pass costs ~1/16 of a full one, and the
/// full-resolution render that follows is the chunked progressive pass (`beginFullPass` /
/// `stepPassChunk`) with a progress bar. A rejected view leaves the previous image up.
fn showViewCoarse(
    engine: *engine_mod.Engine,
    nav: *NavState,
    new_view: viewport.SquareView,
    real_w: u32,
    real_h: u32,
    view_editor: *editor_mod.ViewEditor,
) void {
    // Any in-flight pass belongs to the OLD view; its remaining rows must not land.
    engine.cancelPass();
    engine.installView(new_view) catch |err| {
        app_log.err("navigation rejected ({s}); keeping previous view", .{@errorName(err)});
        view_editor.syncFromView(engine.view);
        return;
    };

    // Warn on the CROSSING of the precision floor, not on every view that sits past it.
    // A continuous pinch (M7) comes through here once per frame, so an unconditional warn is
    // a ~60 lines/second flood; `nav.past_floor` makes it one line per crossing, and one more
    // if the user zooms back out over the floor and in again.
    const now_past_floor = navigate.atPrecisionFloor(new_view);
    if (now_past_floor and !nav.past_floor) {
        var floor_buf: [navigate.floor_message_buf_len]u8 = undefined;
        if (navigate.precisionFloorMessage(&floor_buf, new_view.side)) |msg| {
            app_log.warn("{s}", .{msg});
        } else |_| {}
    }
    nav.past_floor = now_past_floor;

    renderCoarse(engine, nav, real_w, real_h);
    view_editor.syncFromView(engine.view);
    armFullPass(nav);
}

/// Install a new `max_iter` policy: coarse now, full-res progressively after — but ONLY when the
/// policy actually changes the resolved `max_iter`. The count feeds the iteration, so an unchanged
/// count means byte-identical pixels and a render would be pure waste (and, since m9, a visible
/// Cancel/progress-bar flash). Leaving Auto pins the count already on display, so it lands here
/// unchanged and renders nothing; typing a new value, or an Auto ramp that resolves to a different
/// count, re-renders as before.
fn showPolicyCoarse(
    engine: *engine_mod.Engine,
    nav: *NavState,
    policy: autoiter.IterPolicy,
    real_w: u32,
    real_h: u32,
    view_editor: *editor_mod.ViewEditor,
) void {
    const previous_iter = engine.max_iter;
    engine.installPolicy(policy) catch |err| {
        app_log.err("max_iter policy rejected ({s}); keeping the previous one", .{@errorName(err)});
        // Rejected: the engine kept its previous policy AND its previous count, so this restores
        // the field to what the pixels on screen were computed with.
        view_editor.syncFromPolicy(engine.policy, engine.max_iter);
        return;
    };
    // `installPolicy` refreshed `max_iter` for the new policy without touching the pixels. If the
    // count is unchanged, the image on screen (or the pass still refining it) is already correct:
    // record the policy for future view changes and leave any in-flight pass running — no cancel,
    // no re-render. This is the "deselect Auto" case: the field was pinned to `engine.max_iter`, so
    // the pin equals it and nothing needs redrawing.
    if (engine.max_iter == previous_iter) {
        view_editor.syncFromPolicy(engine.policy, engine.max_iter);
        return;
    }
    engine.cancelPass();
    renderCoarse(engine, nav, real_w, real_h);
    // After the coarse render `engine.max_iter` is the count the new policy actually resolved to —
    // the ramp's value under Auto, the pin under a manual policy. Never re-derive it here.
    view_editor.syncFromPolicy(engine.policy, engine.max_iter);
    armFullPass(nav);
}

/// One blocking iterate at the COARSE resolution — `real_w/coarse_divisor` ×
/// `real_h/coarse_divisor`, i.e. per-axis, so the preview carries the region's aspect ratio.
/// Cheap by construction (~1/16 of the pixels), which is what makes a blocking call here
/// acceptable while the full-resolution render is chunked.
fn renderCoarse(engine: *engine_mod.Engine, nav: *NavState, real_w: u32, real_h: u32) void {
    var t = std.time.Timer.start() catch null;
    const coarse_w = @max(real_w / coarse_divisor, 1);
    const coarse_h = @max(real_h / coarse_divisor, 1);
    engine.resizeRect(coarse_w, coarse_h) catch |err| {
        app_log.err(
            "coarse pass at {d}×{d} failed ({s}); display keeps the previous image",
            .{ coarse_w, coarse_h, @errorName(err) },
        );
        return;
    };
    if (t) |*timer| nav.last_render_ns = timer.read();
    nav.needs_upload = true;
}

/// Arm the coarse→fine promotion: the loop's idle check (`refine.decidePass`) starts the
/// full-resolution progressive pass once the user has held still past the idle threshold.
///
/// Clears `nav.cancelled` (m9): this is called from every view change (`showViewCoarse` /
/// `showPolicyCoarse` / resize / GPU toggle / load) AND from the status-bar Render restart, and
/// each of those supersedes a cancelled view — so a re-armed pass must render normally rather than
/// be suppressed by the stale cancel latch. The cancel path itself does NOT arm, so it keeps the
/// latch set.
fn armFullPass(nav: *NavState) void {
    nav.rendering = true;
    nav.full_pass_done = false;
    nav.cancelled = false;
    nav.idle_timer = std.time.Timer.start() catch null;
}

/// Stop the in-flight full-resolution pass at the user's request (Cancel button or Escape).
/// Abandons the pass so its remaining rows never land — the partly-refined image stays on screen —
/// and sets `nav.full_pass_done` so neither idle promotion nor the region re-arm restarts it, plus
/// `nav.cancelled` so `refine.decidePass` keeps it suppressed until the user restarts or navigates.
/// Reads the completion BEFORE abandoning the pass (`passFraction` returns null once it is gone).
/// Guard the call on `nav.rendering`: cancelling when nothing is rendering is meaningless.
fn requestCancel(engine: *engine_mod.Engine, nav: *NavState) void {
    const pct: u32 = if (engine.passFraction()) |f|
        @intFromFloat(@round(std.math.clamp(f, 0.0, 1.0) * 100.0))
    else
        0;
    engine.cancelPass();
    nav.rendering = false;
    nav.full_pass_done = true;
    nav.cancelled = true;
    app_log.info("render cancelled at {d}%", .{pct});
}

/// Start the full-resolution progressive pass for the current view at the fractal region's
/// real, rectangular size. `beginPass` reallocates the buffers and seeds them with a
/// nearest-neighbour upsample of the coarse image, so the very first frame already shows the
/// right framing as a BLOCKY preview that then sharpens band by band.
fn beginFullPass(engine: *engine_mod.Engine, nav: *NavState, real_w: u32, real_h: u32) void {
    nav.pass_ns = 0;
    engine.beginPass(real_w, real_h) catch |err| {
        app_log.err(
            "full-res pass at {d}×{d} could not start ({s}); display stays coarse",
            .{ real_w, real_h, @errorName(err) },
        );
        nav.full_pass_done = true;
        nav.rendering = false;
        return;
    };
    nav.needs_upload = true;
}

/// Run ONE time-budgeted chunk of the in-flight pass — once per frame, which is exactly what
/// keeps the window drawing (and the status-bar progress bar moving) during a full-resolution
/// render. On completion, reports the pass's accumulated cost as render_ms / gpu_render_ms.
fn stepPassChunk(engine: *engine_mod.Engine, nav: *NavState, app_stats: *stats_mod.Stats) void {
    var t = std.time.Timer.start() catch null;
    const finished = engine.stepPass() catch |err| {
        app_log.err("progressive pass aborted ({s}); keeping the partly refined image", .{@errorName(err)});
        engine.cancelPass();
        nav.full_pass_done = true;
        nav.rendering = false;
        return;
    };
    if (t) |*timer| nav.pass_ns += timer.read();
    nav.needs_upload = true;
    if (!finished) return;

    nav.full_pass_done = true;
    nav.rendering = false;
    nav.region_thrash = 0;
    // The full pass's own timing supersedes the coarse preview's.
    nav.last_render_ns = 0;
    const ms = stats_mod.nsToMs(nav.pass_ns);
    if (engine.use_gpu) {
        app_stats.gpu_render_ms = ms;
        app_stats.render_ms = 0.0;
    } else {
        app_stats.render_ms = ms;
        app_stats.gpu_render_ms = 0.0;
    }
    app_log.info("full-res pass complete: {d}×{d} in {d:.1} ms", .{ engine.image_w, engine.image_h, ms });
}

// ─── Main event / render loop ─────────────────────────────────────────────────

/// Pump events and render the single fixed window each frame until quit.
/// T6: adds navigation input, coarse→fine dispatch, and hover readout.
/// T7: adds coord panel with `view_editor`.
fn runLoop(
    window: *c.SDL_Window,
    device: gpu.Device,
    ui: ui_mod.Ui,
    texture: *texture_mod.Texture,
    image_rect: *viewport.ImageRect,
    app_stats: *stats_mod.Stats,
    engine: *engine_mod.Engine,
    editor: *editor_mod.Editor,
    view_editor: *editor_mod.ViewEditor,
    gallery: *const panels.SwatchGallery,
) void {
    var frame_timer: ?std.time.Timer = std.time.Timer.start() catch |err| blk: {
        app_log.warn("frame timer unavailable ({s}); frame ms will read 0", .{@errorName(err)});
        break :blk null;
    };

    // Startup is a coarse preview (see `main`), so the loop opens "rendering": the first
    // frame reports the region size and the idle check promotes it to a full-res pass.
    var nav = NavState{ .idle_timer = std.time.Timer.start() catch null };
    var pending_dialog = dialog.PendingDialog{};
    // The FULL-RESOLUTION target: the fractal region's live pixel size, reported by
    // `panels.draw` each frame. Tracked separately from `engine.image_w/h`, which is at the
    // coarse preview size while a navigation is in flight.
    var real_w: u32 = engine.image_w;
    var real_h: u32 = engine.image_h;
    // The navigation square side that goes with it (pan/zoom geometry is square).
    var real_s: u32 = engine.image_side;

    var running = true;
    while (running) {
        if (frame_timer) |*t| t.reset();

        // ── SDL event pump — wait for the first event then drain the queue.
        // How long we may block depends on whether the app owes the user work:
        //   * a progressive pass in flight → DON'T block at all; every frame runs one more
        //     chunk, and blocking here would stall the render and the progress bar;
        //   * an upload not yet on screen (`needs_present`) → DON'T block either; the pixels
        //     were uploaded after the last frame was presented, so one more frame is owed
        //     before we may sleep, or the finished image never shows up;
        //   * a coarse preview waiting for its full pass, or a pending file dialog → a short
        //     timeout, so the idle threshold can elapse (and the Cocoa runloop keeps
        //     pumping, which is how the dialog's completion callback gets delivered);
        //   * otherwise the image is final AND on screen → block until something happens,
        //     keeping the CPU idle instead of spinning.
        var event: c.SDL_Event = undefined;
        const owes_full_pass = !nav.full_pass_done or pending_dialog.kind != dialog.Kind.none;
        const wait_ms: i32 = if (owes_full_pass) 16 else -1;
        const got_event = if (engine.pass != null or nav.needs_present)
            c.SDL_PollEvent(&event)
        else
            c.SDL_WaitEventTimeout(&event, wait_ms);
        if (got_event) {
            while (true) {
                _ = ui.processEvent(&event);
                switch (event.type) {
                    c.SDL_EVENT_QUIT => running = false,
                    c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                        if (event.window.windowID == c.SDL_GetWindowID(window)) running = false;
                    },
                    // A resize needs no handler: the region-size check below sees the new
                    // `render_w/render_h` next frame, cancels any in-flight pass and re-arms
                    // the full pass — which, because the size keeps changing while the mouse
                    // drags the window edge, only runs once the resize SETTLES.
                    // ── The wheel (M7). PURE PLUMBING, no navigation: reduce the event to
                    // plain data and hand it to the accumulator. What it MEANS is
                    // `gesture.classifyWheel`'s decision (a mouse notch zooms exactly as it
                    // always has; a trackpad two-finger swipe pans), and the view changes at
                    // the ONE drain site after this loop — never here, so a frame carrying
                    // several notches or several swipe deltas costs one coarse render and one
                    // undo entry instead of one of each per event.
                    //
                    // THE THREE FIELDS ARE COPIED WITH THEIR SIGNS UNTOUCHED, and
                    // `event.wheel.direction` is deliberately NOT read — the pre-M7 handler
                    // ignored it too, and `gesture.wheelSample` says why reacting to it would
                    // invert the existing wheel zoom on a default macOS setup, invisibly.
                    c.SDL_EVENT_MOUSE_WHEEL => {
                        nav.gestures.addWheel(
                            gesture.wheelSample(event.wheel.x, event.wheel.y, event.wheel.integer_y),
                            nav.input_mode,
                        );
                    },
                    // ── Trackpad pinch (M7). These three only FEED the accumulator; the
                    // view changes once per frame in the drain step after this loop, which is
                    // what keeps a 60-updates-a-second gesture at one coarse render a frame.
                    // The `windowID` guard matches SDL_EVENT_WINDOW_CLOSE_REQUESTED above:
                    // an event for another window is not ours to act on.
                    c.SDL_EVENT_PINCH_BEGIN => {
                        if (event.pinch.windowID == c.SDL_GetWindowID(window)) {
                            // Force a FRESH gesture run: a new pinch must not inherit the
                            // previous one's, or its first frame would not report `began` and
                            // the whole gesture would cost no undo entry.
                            nav.gestures.endPinch();
                        }
                    },
                    c.SDL_EVENT_PINCH_UPDATE => {
                        if (event.pinch.windowID == c.SDL_GetWindowID(window)) {
                            // ── THE INCREMENTAL-SCALE SEAM. Read this before changing either
                            // side of it. `Accumulator.addPinch` MULTIPLIES a frame's scales
                            // together, so it requires the ratio SINCE THE PREVIOUS UPDATE,
                            // and an IMMUTABLE acceptance test pins that product
                            // (1.25 · 1.6 · 2.0 = 4.0). SDL documents `event.pinch.scale` as
                            // "the scale change since the last SDL_EVENT_PINCH_UPDATE"
                            // (`SDL_events.h:804`) — i.e. ALREADY INCREMENTAL — so this
                            // pass-through is correct AS DOCUMENTED. It is also UNMEASURED:
                            // if `T8`'s probe log shows the value is really ABSOLUTE (a total
                            // scale since PINCH_BEGIN), the fix belongs RIGHT HERE — divide by
                            // the previous absolute value before calling `addPinch` — and NOT
                            // in `ui/gesture.zig`, whose product semantics that immutable test
                            // pins. Nothing else about the reduction (the scale→side-factor
                            // inversion in particular) belongs at this call site.
                            nav.gestures.addPinch(event.pinch.scale);
                        }
                    },
                    c.SDL_EVENT_PINCH_END => {
                        if (event.pinch.windowID == c.SDL_GetWindowID(window)) {
                            // Fingers lifted: close the run, so the NEXT pinch reports `began`
                            // and gets its own undo entry.
                            nav.gestures.endPinch();
                        }
                    },
                    // Right mouse button down: stash the cursor point for the context menu.
                    c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                        if (event.button.button == c.SDL_BUTTON_RIGHT) {
                            const cursor = engine.view.cursorCoord(@floatCast(event.button.x), @floatCast(event.button.y), image_rect.*);
                            if (cursor) |pt| {
                                nav.right_click_pt = pt;
                                nav.open_ctx_menu = true;
                            }
                        }
                    },
                    // Ctrl+Z = undo, Ctrl+Y = redo.
                    c.SDL_EVENT_KEY_DOWN => {
                        const mods = c.SDL_GetModState();
                        const ctrl = (mods & c.SDL_KMOD_CTRL) != 0;
                        if (ctrl) {
                            if (event.key.scancode == c.SDL_SCANCODE_Z) {
                                historyUndo(engine, &nav, real_w, real_h, view_editor);
                            } else if (event.key.scancode == c.SDL_SCANCODE_Y) {
                                historyRedo(engine, &nav, real_w, real_h, view_editor);
                            }
                        } else if (event.key.scancode == c.SDL_SCANCODE_ESCAPE and nav.rendering) {
                            // Escape while a pass is in flight is the keyboard twin of the
                            // status-bar Cancel button (m9): same abandon-and-keep behaviour.
                            requestCancel(engine, &nav);
                        }
                    },
                    else => {},
                }
                if (!c.SDL_PollEvent(&event)) break;
            }
        }

        // ── Drain the gesture accumulator — EXACTLY ONCE PER FRAME ────────────
        // Runs after the event drain and before the frame is built, so however many pinch
        // updates, wheel notches and swipe deltas arrived this frame, they become ONE view
        // change. `take()` returning null means no gesture input arrived: do NOTHING at all (no
        // view change, no history entry, no log line).
        //
        // The applyViewCoarse-vs-showViewCoarse choice below IS THE UNDO MECHANISM. Do not
        // "simplify" it to `applyViewCoarse` everywhere: that one pushes history, this one does
        // not, so the FIRST INSTALL of a gesture run records the PRE-GESTURE view and every later
        // frame of the same run only shows its result. That is what makes one Ctrl+Z after a long
        // pinch return to where the pinch started instead of to its second-to-last frame — one
        // undo entry per GESTURE, not per frame. `historyPush` is not called from here;
        // `applyViewCoarse` owns it, including its no-op guard (which is what stops a pinch-out
        // saturated at `navigate.max_view_side` stacking entries).
        //
        // WHICH INSTALL IS THE FIRST ONE IS `nav.history_debt`'S ANSWER, NOT `intent.began`'S.
        // `began` is reported once per run and never re-offered, so reading it directly loses the
        // run's entry whenever the begin frame installs nothing — the saturated-then-reversed
        // pinch, a refused `zoomAbout`, a cursor off the image rect. The debt stays owed until an
        // entry is really pushed; `gesture.HistoryDebt` documents the case and its tests pin it,
        // which is why the latch is a pure type and not a `bool` here.
        // Which frames report `began` is the accumulator's business and depends on the event
        // SOURCE (`gesture.RunSource`): one wheel notch is one run and so one undo entry, as it
        // has always been, and a whole pinch is one run — only `endPinch` ends it. A swipe is one
        // run only for as long as pan input keeps arriving: a frame that drains with no pan input
        // (or a zoom-only frame) closes the `.wheel_pan` run in `gesture.closeUndelivered`, so a
        // PAUSED swipe is two runs and two undo entries.
        if (nav.gestures.take()) |intent| {
            // A run that has just begun OWES its one undo entry from here on. Noted BEFORE any
            // of the work below, because every reason that work can install nothing must leave
            // the debt standing rather than spend it.
            nav.history_debt.owe(intent.began);

            // ONE cursor read for the whole drained frame — the same `SDL_GetMouseState` the
            // hover readout uses a few lines below. Neither the pinch event
            // (`SDL_PinchFingerEvent` has no position, `SDL_events.h:799-806`) nor the reduced
            // wheel sample carries a position, so the live cursor is the only anchor there is.
            var gesture_x: f32 = 0.0;
            var gesture_y: f32 = 0.0;
            _ = c.SDL_GetMouseState(&gesture_x, &gesture_y);
            const cursor_x: f64 = @floatCast(gesture_x);
            const cursor_y: f64 = @floatCast(gesture_y);

            // ONE candidate view for the frame, installed ONCE at the end: the zoom first, then
            // the pan ON ITS RESULT. Installing each half separately would cost two coarse
            // renders for one frame and — on the frame a gesture begins — TWO history entries,
            // so one Ctrl+Z would only undo half of it. NOTE FOR THE REVIEWER: the mixed
            // zoom+pan case is UNTESTED BY DESIGN — no approved acceptance test feeds a zoom and
            // a pan together (`acceptance-tests.md`, "What these tests do not pin", item 4), and
            // dropping the pan half here leaves all 16 green. It is reachable: a trackpad can
            // deliver a pinch and a swipe in the same frame. Read this block, do not trust the
            // suite.
            var next_view: ?viewport.SquareView = null;
            // AT MOST ONE LOG LINE PER DRAINED FRAME (never one per event, or a continuous
            // gesture floods the log): the first refusal speaks for the frame.
            var refusal_logged = false;

            if (intent.zoom_factor) |factor| {
                const anchor = engine.view.cursorCoord(cursor_x, cursor_y, image_rect.*);
                // A null anchor means the cursor is outside the fitted image rect — over the
                // data panel or on a letterbox bar — and the zoom is simply IGNORED: a gesture
                // over the panels must not move the view. A zoom NEEDS the anchor: it is the
                // point that has to stay under the cursor.
                if (anchor) |pt| {
                    if (navigate.zoomAbout(engine.view, pt, factor)) |v| {
                        next_view = v;
                    } else |err| {
                        // Refused: keep the previous view up, exactly as the pre-M7 wheel path's
                        // `catch null` did.
                        app_log.err(
                            "gesture zoom by side factor {d} refused ({s}); keeping the view at side {d}",
                            .{ factor, @errorName(err), engine.view.side },
                        );
                        refusal_logged = true;
                    }
                }
            }

            if (intent.pan_dx != 0.0 or intent.pan_dy != 0.0) {
                // GATED ON THE IMAGE RECT CONTAINING THE CURSOR, not on `cursorCoord` returning
                // a point. A pan has no anchor — it is a translation by a pixel delta — so it
                // must not depend on the anchor mapping succeeding, and asking for a complex
                // coordinate it never uses would be a lie about the requirement. It still has to
                // be gated, or a two-finger scroll over the data panel would move the picture.
                if (image_rect.toImagePixel(cursor_x, cursor_y) != null) {
                    // `real_s` — the navigation square side, `min(real_w, real_h)` — is EXACTLY
                    // what the middle-drag pan passes (`handleNavInput`, "pass the NEGATED mouse
                    // delta"). Any other side (e.g. `engine.image_w`, which is the coarse
                    // preview width mid-gesture) would make a swipe and a drag of the same pixel
                    // distance move the plane by different amounts on a non-square window.
                    const base = next_view orelse engine.view;
                    if (navigate.panByPixels(base, intent.pan_dx, intent.pan_dy, real_s)) |v| {
                        next_view = v;
                    } else |err| {
                        // `panByPixels` REFUSES a zero image side (a minimized window) and a
                        // delta that overflows the centre, rather than asserting — so this is a
                        // live-state error, not a bug: keep the view as it is and say so once.
                        if (!refusal_logged) {
                            app_log.err(
                                "gesture pan by ({d}, {d}) px refused ({s}); image side {d}, keeping the view",
                                .{ intent.pan_dx, intent.pan_dy, @errorName(err), real_s },
                            );
                            refusal_logged = true;
                        }
                    }
                }
            }

            // The single install. `next_view` is null when the gesture was ignored (cursor off
            // the image) or refused, and then the view is left exactly as it was — and the run's
            // undo entry stays OWED, so the first later frame that does move the view pushes it.
            if (next_view) |v| {
                if (nav.history_debt.owes()) {
                    // Settle ONLY on the answer, never on the choice: `applyViewCoarse` returns
                    // false when its no-op guard refused the view (bit-identical to what is on
                    // screen), and that frame pushed nothing, so the entry is still owed.
                    if (applyViewCoarse(engine, &nav, v, real_w, real_h, view_editor)) nav.history_debt.settle();
                } else {
                    showViewCoarse(engine, &nav, v, real_w, real_h, view_editor);
                }
            }
        }

        // ── ImGui frame ───────────────────────────────────────────────────────
        ui.newFrame();

        // Compute hover point before building the UI so the status bar can use it.
        var mx: f32 = 0.0;
        var my: f32 = 0.0;
        _ = c.SDL_GetMouseState(&mx, &my);
        const hover_pt = engine.view.cursorCoord(@floatCast(mx), @floatCast(my), image_rect.*);

        // While Auto is on, the iteration field is a READOUT of `engine.max_iter`, and the ramp
        // moves that on every zoom — so refresh it from the engine once per frame, before the panel
        // draws it. One site, and it covers every path that can change the count. Guarded on
        // `iterFieldReadOnly`: overwriting the buffer while the pin is manual would fight the
        // user's own half-typed text.
        if (view_editor.iterFieldReadOnly()) view_editor.syncFromPolicy(engine.policy, engine.max_iter);

        var quit_requested = false;
        // open_ctx_menu and right_click_pt are consumed inside draw (popup lives there).
        const draw_result = panels.draw(
            device.handle,
            texture.*,
            engine.max_iter,
            app_stats.*,
            engine,
            editor,
            view_editor,
            gallery,
            nav.open_ctx_menu,
            nav.right_click_pt,
            hover_pt,
            nav.input_mode,
            nav.rendering,
            engine.passFraction(),
            nav.cancelled,
            &quit_requested,
        );
        // Update image_rect from the live ImGui geometry every frame so coordinate
        // mapping uses the actual on-screen image (not the OS window size).
        if (draw_result.image_rect.side > 0) image_rect.* = draw_result.image_rect;
        nav.open_ctx_menu = false;
        if (quit_requested) running = false;

        // ── Cancel / Render controls (m9) ─────────────────────────────────────
        // The status-bar Cancel button and Escape both route through `requestCancel`; Escape is
        // handled in the event loop above, the button here. Guarded on `nav.rendering` so a
        // stale click cannot fire once the pass has already finished. Render re-arms the same view
        // through `armFullPass` (which clears the cancel latch), and the normal completion summary
        // covers the restart's success.
        if (draw_result.cancel_requested and nav.rendering) requestCancel(engine, &nav);
        if (draw_result.render_requested and nav.cancelled) armFullPass(&nav);

        // ── Follow the fractal region's live size ─────────────────────────────
        // The region — not the OS window — is the full-resolution target, and only ImGui
        // knows it (menu bar, status bar, padding and the data panel all take a slice). A
        // change means a window resize or a layout change: the in-flight pass is for the old
        // size, so drop it and re-arm. Re-arming restarts the idle timer, so a drag that
        // resizes the window every frame defers the full pass until it settles.
        //
        // Bounded by `region_thrash_limit`: a layout that oscillates would otherwise cancel the
        // pass every frame and never sharpen. Past the limit, keep the current target and let
        // the pass finish — a stale size is letterboxed by `fitImageRect`, never stretched.
        if (draw_result.render_w > 0 and draw_result.render_h > 0 and
            (draw_result.render_w != real_w or draw_result.render_h != real_h))
        {
            if (nav.region_thrash < region_thrash_limit) {
                nav.region_thrash += 1;
                real_w = draw_result.render_w;
                real_h = draw_result.render_h;
                real_s = @min(real_w, real_h);
                engine.cancelPass();
                armFullPass(&nav);
            } else if (nav.region_thrash == region_thrash_limit) {
                nav.region_thrash += 1; // warn once per stalled pass
                app_log.warn(
                    "fractal region size keeps changing ({d}×{d} vs {d}×{d}); finishing the pass at {d}×{d}",
                    .{ draw_result.render_w, draw_result.render_h, real_w, real_h, real_w, real_h },
                );
            }
        }

        // GPU/CPU toggle: re-render on the new path — coarse now, full-res progressively.
        if (draw_result.needs_rerender) {
            engine.cancelPass();
            renderCoarse(engine, &nav, real_w, real_h);
            armFullPass(&nav);
        }

        // Open file dialogs when menu items were clicked (after the ImGui frame).
        if (draw_result.save_requested) dialog.showSave(window, &pending_dialog);
        if (draw_result.open_requested) dialog.showOpen(window, &pending_dialog);
        if (draw_result.save_scheme_requested) dialog.showSaveScheme(window, &pending_dialog);
        if (draw_result.load_scheme_requested) dialog.showOpenScheme(window, &pending_dialog);

        // Act on the context-menu selection.
        if (draw_result.ctx_action != .none) {
            const pt = nav.right_click_pt;
            const new_view: ?viewport.SquareView = switch (draw_result.ctx_action) {
                .zoom_in => navigate.zoomCentered(engine.view, pt, navigate.zoom_step_in) catch null,
                .zoom_out => navigate.zoomCentered(engine.view, pt, navigate.zoom_step_out) catch null,
                .center_here => viewport.SquareView.fromCenterSide(pt, engine.view.side) catch null,
                .none => null,
            };
            if (new_view) |v| _ = applyViewCoarse(engine, &nav, v, real_w, real_h, view_editor);
        }

        // Coord-panel commits. The panel only PARSES and asks (see `panels.CoordRequest`);
        // installing a view or policy is a re-render, and it goes through the same coarse →
        // progressive path as a gesture so the window keeps drawing.
        if (draw_result.coord.view) |v| _ = applyViewCoarse(engine, &nav, v, real_w, real_h, view_editor);
        if (draw_result.coord.policy) |p| showPolicyCoarse(engine, &nav, p, real_w, real_h, view_editor);

        // The declared pointing device (M7/T6). The ONLY request from the panel that installs
        // without a re-render: it changes what the NEXT wheel event means, not what is on screen,
        // so there is no coarse preview, no history entry and — deliberately — no log line. It is
        // a preference the user can see the effect of by scrolling once; announcing it would be
        // noise, and a failure is impossible: the field write cannot fail.
        if (draw_result.coord.input_mode) |m| nav.input_mode = m;

        // Navigation ImGui input: box-select and pan.
        handleNavInput(engine, &nav, image_rect.*, real_w, real_h, real_s, view_editor);

        ui.endFrame();

        // ── Coarse→fine pass dispatch ─────────────────────────────────────────
        // A pass already in flight advances by one chunk per frame; otherwise the pure
        // `refine.decidePass` decides whether the user has been still long enough to promote
        // the coarse preview to a full-resolution pass.
        if (engine.pass != null) {
            stepPassChunk(engine, &nav, app_stats);
        } else {
            const interacting = (nav.drag_state == .active) or
                ig.igIsMouseDragging(ig.mouse_button_middle, -1.0) or
                (ig.igIsKeyDown_Nil(ig.key_space) and ig.igIsMouseDragging(ig.mouse_button_left, -1.0));
            const idle_ns: u64 = if (nav.idle_timer) |*t| t.read() else 0;
            switch (refine.decidePass(interacting, idle_ns, nav.full_pass_done, nav.cancelled)) {
                .full => beginFullPass(engine, &nav, real_w, real_h),
                .coarse, .none => {},
            }
        }

        renderFrame(window, device, ui);

        // ── Deferred texture sync + upload ────────────────────────────────────
        // MUST be after renderFrame: ImGui submits the GPU commands (including
        // the sampler binding for the fractal texture) inside renderFrame.
        // Only after submission is it safe to destroy and recreate the texture.
        const did_upload = nav.needs_upload;
        if (nav.needs_upload) {
            syncTexture(device, texture, engine);
            texture_mod.upload(device.handle, texture.*, engine.output()) catch |err| {
                app_log.err("texture upload failed ({s})", .{@errorName(err)});
            };
            nav.needs_upload = false;
        }
        // An upload lands after this frame was presented, so the new pixels are owed one more
        // frame. Cleared automatically on that frame, which uploads nothing.
        nav.needs_present = did_upload;

        // ── File dialog result processing ─────────────────────────────────────
        if (dialog.takePending(&pending_dialog)) |result| {
            handleDialogResult(result, device, texture, engine, &nav, real_w, real_h, editor, view_editor);
        }

        // Only update frame_ms when the fractal actually re-rendered; skip mouse-move frames.
        if (did_upload) {
            if (frame_timer) |*t| app_stats.observeFrame(t.read());
        }
        if (nav.last_render_ns > 0) {
            app_stats.render_ms = stats_mod.nsToMs(nav.last_render_ns);
            nav.last_render_ns = 0;
        }
    }
}

/// Process a completed file-dialog result: save state to disk or load from disk.
fn handleDialogResult(
    result: dialog.PendingResult,
    device: gpu.Device,
    texture: *texture_mod.Texture,
    engine: *engine_mod.Engine,
    nav: *NavState,
    real_w: u32,
    real_h: u32,
    editor: *editor_mod.Editor,
    view_editor: *editor_mod.ViewEditor,
) void {
    const alloc = std.heap.page_allocator;
    const path = result.path;

    switch (result.kind) {
        .save => {
            const state = persist.fromEngine(engine, alloc) catch |err| {
                app_log.err("save: fromEngine failed ({s})", .{@errorName(err)});
                return;
            };
            defer persist.freeState(state, alloc);

            // Ensure path ends in .fractal; use path as-is (SDL dialog already filters).
            const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
                app_log.err("save: cannot create '{s}' ({s})", .{ path, @errorName(err) });
                return;
            };
            defer file.close();

            // Sized from persist's own constant: M6/T8 made the centre two decimal STRINGS, so
            // the minimum grew. Never hand-write a length here.
            var json_buf: [persist.min_json_buf_len]u8 = undefined;
            const json_bytes = persist.toJson(state, &json_buf) catch |err| {
                app_log.err("save: toJson failed ({s})", .{@errorName(err)});
                return;
            };
            file.writeAll(json_bytes) catch |err| {
                app_log.err("save: write failed for '{s}' ({s})", .{ path, @errorName(err) });
                return;
            };
            app_log.info("state saved to '{s}'", .{path});
        },
        .open => {
            const file = std.fs.cwd().openFile(path, .{}) catch |err| {
                app_log.err("open: cannot read '{s}' ({s})", .{ path, @errorName(err) });
                return;
            };
            defer file.close();

            // Read allowance: a state we WRITE always fits in `min_json_buf_len`; a hand-edited
            // or re-indented file gets room on top of that rather than being truncated into a
            // parse error.
            var file_buf: [4 * persist.min_json_buf_len]u8 = undefined;
            const n = file.readAll(&file_buf) catch |err| {
                app_log.err("open: read failed for '{s}' ({s})", .{ path, @errorName(err) });
                return;
            };
            const json_bytes = file_buf[0..n];

            const state = persist.fromJson(json_bytes, alloc) catch |err| {
                app_log.err("open: parse failed for '{s}' ({s})", .{ path, @errorName(err) });
                return;
            };
            defer persist.freeState(state, alloc);

            // Drop to the coarse size FIRST: `applyToEngine` installs the loaded view with
            // `setViewport`, which re-iterates at the engine's current resolution — at full
            // res that is the blocking render the progressive path exists to avoid.
            engine.cancelPass();
            renderCoarse(engine, nav, real_w, real_h);

            persist.applyToEngine(state, engine) catch |err| {
                app_log.err("open: applyToEngine failed for '{s}' ({s})", .{ path, @errorName(err) });
                return;
            };

            syncTexture(device, texture, engine);
            view_editor.syncFromView(engine.view);
            view_editor.syncFromPolicy(engine.policy, engine.max_iter);
            // The load replaced the engine's colouring; resync the palette panel so it shows
            // what was loaded, not the values previously on display (requirement "Loading
            // restores the palette panel").
            editor.syncFromColouring(engine.gradient, engine.params, engine.interior);
            nav.needs_upload = true;
            armFullPass(nav);
            app_log.info("state loaded from '{s}'", .{path});
        },
        .save_scheme => {
            // The COLOURING only — no view, no iteration count. See `scheme.zig`.
            const s = scheme.fromEngine(engine, alloc) catch |err| {
                app_log.err("save scheme: fromEngine failed ({s})", .{@errorName(err)});
                return;
            };
            defer scheme.free(s, alloc);

            const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
                app_log.err("save scheme: cannot create '{s}' ({s})", .{ path, @errorName(err) });
                return;
            };
            defer file.close();

            // Sized from scheme's own constant, never a hand-written number: a scheme carries no
            // view text, so its worst case is `max_stops` stops plus the fixed colouring fields.
            var json_buf: [scheme.min_json_buf_len]u8 = undefined;
            const json_bytes = scheme.toJson(s, &json_buf) catch |err| {
                app_log.err("save scheme: toJson failed ({s})", .{@errorName(err)});
                return;
            };
            file.writeAll(json_bytes) catch |err| {
                app_log.err("save scheme: write failed for '{s}' ({s})", .{ path, @errorName(err) });
                return;
            };
            app_log.info("colour scheme saved to '{s}' ({d} stops)", .{ path, s.stops.len });
        },
        .open_scheme => {
            const file = std.fs.cwd().openFile(path, .{}) catch |err| {
                app_log.err("load scheme: cannot read '{s}' ({s}); keeping the current colouring", .{ path, @errorName(err) });
                return;
            };
            defer file.close();

            // Read allowance: a scheme we WRITE always fits in `min_json_buf_len`; a hand-edited
            // or re-indented file gets room on top of that rather than being truncated into a
            // spurious parse error.
            var file_buf: [4 * scheme.min_json_buf_len]u8 = undefined;
            const n = file.readAll(&file_buf) catch |err| {
                app_log.err("load scheme: read failed for '{s}' ({s}); keeping the current colouring", .{ path, @errorName(err) });
                return;
            };

            // A file we cannot use is REFUSED with its named reason (from `ParseError`), and the
            // current colouring is left untouched — nothing has been applied to the engine yet.
            const s = scheme.fromJson(file_buf[0..n], alloc) catch |err| {
                app_log.err("load scheme: '{s}' refused ({s}); keeping the current colouring", .{ path, @errorName(err) });
                return;
            };
            defer scheme.free(s, alloc);

            // Colour setters ONLY (`scheme.applyToEngine`): the view does not move and the fractal
            // is not re-iterated — a colour pass, not an iteration pass.
            scheme.applyToEngine(s, engine) catch |err| {
                app_log.err("load scheme: apply failed for '{s}' ({s}); keeping the current colouring", .{ path, @errorName(err) });
                return;
            };

            // Show the loaded colouring in the palette panel (requirement "Loading restores the
            // palette panel"). The image was recoloured in place — same size, so no texture
            // resize — so upload it and owe one more present frame to put it on screen.
            editor.syncFromColouring(engine.gradient, engine.params, engine.interior);
            texture_mod.upload(device.handle, texture.*, engine.output()) catch |err| {
                app_log.err("load scheme: re-upload of recoloured buffer failed ({s})", .{@errorName(err)});
            };
            nav.needs_present = true;
            app_log.info("colour scheme loaded from '{s}' ({d} stops)", .{ path, s.stops.len });
        },
        .none => {},
    }
}

// ─── Per-frame navigation input ───────────────────────────────────────────────

/// Rubber-band rect colour: bright white, fully opaque (0xAABBGGRR in ImGui packing).
const drag_rect_col: ig.ImU32 = 0xFF_FF_FF_FF;

/// Process box-select (left-drag) and pan (middle-drag / Space+left-drag) for one frame.
fn handleNavInput(
    engine: *engine_mod.Engine,
    nav: *NavState,
    rect: viewport.ImageRect,
    real_w: u32,
    real_h: u32,
    real_s: u32,
    view_editor: *editor_mod.ViewEditor,
) void {
    const space_held = ig.igIsKeyDown_Nil(ig.key_space);

    // ── Pan: middle-drag or Space+left-drag ───────────────────────────────────
    const mid_dragging = ig.igIsMouseDragging(ig.mouse_button_middle, -1.0);
    const space_left_dragging = space_held and ig.igIsMouseDragging(ig.mouse_button_left, -1.0);
    if (mid_dragging or space_left_dragging) {
        const btn: c_int = if (mid_dragging) ig.mouse_button_middle else ig.mouse_button_left;
        const delta = ig.igGetMouseDragDelta(btn, -1.0);
        // Navigate.panByPixels: "pass the NEGATED mouse delta" so content follows cursor.
        if (delta.x != 0.0 or delta.y != 0.0) {
            const new_view = navigate.panByPixels(
                engine.view,
                @floatCast(-delta.x),
                @floatCast(-delta.y),
                real_s,
            ) catch |err| blk: {
                app_log.warn("pan rejected ({s})", .{@errorName(err)});
                break :blk null;
            };
            if (new_view) |v| {
                _ = applyViewCoarse(engine, nav, v, real_w, real_h, view_editor);
                ig.igResetMouseDragDelta(btn);
            }
        }
    }

    // ── Box-select: left-drag without Space ───────────────────────────────────
    if (!space_held) {
        const left_down = ig.igIsMouseDown_Nil(ig.mouse_button_left);
        const left_dragging = ig.igIsMouseDragging(ig.mouse_button_left, -1.0);

        // Start: button just went down and the cursor is on the image.
        if (left_down and !left_dragging and nav.drag_state == .none) {
            var mx: f32 = 0.0;
            var my: f32 = 0.0;
            _ = c.SDL_GetMouseState(&mx, &my);
            const img_px = rect.toImagePixel(@floatCast(mx), @floatCast(my));
            if (img_px) |px| {
                nav.drag_state = .active;
                nav.drag_start_px = px;
                nav.drag_start_win_x = mx;
                nav.drag_start_win_y = my;
            }
        }

        // While dragging: draw rubber-band rectangle on the foreground draw list
        // (always valid, draws on top of all windows).
        if (nav.drag_state == .active and left_dragging) {
            var mx: f32 = 0.0;
            var my: f32 = 0.0;
            _ = c.SDL_GetMouseState(&mx, &my);
            if (ig.igGetForegroundDrawList_ViewportPtr(null)) |dl| {
                ig.ImDrawList_AddRect(
                    dl,
                    .{ .x = nav.drag_start_win_x, .y = nav.drag_start_win_y },
                    .{ .x = mx, .y = my },
                    drag_rect_col,
                    0.0,
                    1.5,
                    0,
                );
            }
        }

        // Commit on left-button release. Clamp the end point to the image boundary
        // so a drag that finishes outside the image still zooms to a valid region.
        if (nav.drag_state == .active and !left_down) {
            var ex: f32 = 0.0;
            var ey: f32 = 0.0;
            _ = c.SDL_GetMouseState(&ex, &ey);
            // Use toImagePixel first; if outside the rect, clamp to [0, w) × [0, h).
            const end_px: viewport.Pixel = rect.toImagePixel(@floatCast(ex), @floatCast(ey)) orelse blk: {
                if (rect.w == 0 or rect.h == 0) break :blk nav.drag_start_px;
                const ox: f64 = @floatFromInt(rect.x);
                const oy: f64 = @floatFromInt(rect.y);
                break :blk .{
                    .x = @max(0.0, @min(@as(f64, @floatFromInt(rect.w)) - 1.0, @as(f64, @floatCast(ex)) - ox)),
                    .y = @max(0.0, @min(@as(f64, @floatFromInt(rect.h)) - 1.0, @as(f64, @floatCast(ey)) - oy)),
                };
            };
            const new_view = navigate.boxSelect(
                engine.view,
                nav.drag_start_px,
                end_px,
                rect.w,
                rect.h,
            ) catch |err| blk: {
                app_log.warn("box-select rejected ({s})", .{@errorName(err)});
                break :blk null;
            };
            if (new_view) |v| _ = applyViewCoarse(engine, nav, v, real_w, real_h, view_editor);
            nav.drag_state = .none;
            ig.igResetMouseDragDelta(ig.mouse_button_left);
        }
    } else {
        // Space is held: cancel any active box-select drag without committing.
        if (nav.drag_state == .active and !ig.igIsMouseDown_Nil(ig.mouse_button_left)) {
            nav.drag_state = .none;
            ig.igResetMouseDragDelta(ig.mouse_button_left);
        }
    }
}

// ─── Frame rendering ──────────────────────────────────────────────────────────

/// Acquire the swapchain, upload ImGui buffers, and render into a clearing render pass.
fn renderFrame(window: *c.SDL_Window, device: gpu.Device, ui: ui_mod.Ui) void {
    const cmd = c.SDL_AcquireGPUCommandBuffer(device.handle) orelse {
        app_log.err("SDL_AcquireGPUCommandBuffer failed: {s}", .{std.mem.span(c.SDL_GetError())});
        return;
    };

    var swapchain_texture: ?*c.SDL_GPUTexture = null;
    if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, window, &swapchain_texture, null, null)) {
        app_log.err("SDL_WaitAndAcquireGPUSwapchainTexture failed: {s}", .{std.mem.span(c.SDL_GetError())});
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    }
    const tex = swapchain_texture orelse {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    };

    ui.prepareDrawData(cmd);

    var color_target = c.SDL_GPUColorTargetInfo{
        .texture = tex,
        .clear_color = .{ .r = 0.06, .g = 0.06, .b = 0.09, .a = 1.0 },
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_STORE,
    };
    const pass = c.SDL_BeginGPURenderPass(cmd, &color_target, 1, null) orelse {
        app_log.err("SDL_BeginGPURenderPass failed: {s}", .{std.mem.span(c.SDL_GetError())});
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    };
    ui.renderDrawData(cmd, pass);
    c.SDL_EndGPURenderPass(pass);

    _ = c.SDL_SubmitGPUCommandBuffer(cmd);
}
