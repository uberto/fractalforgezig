//! The single fixed M0 window: a menu bar (File→Quit, Help→About) over two regions
//! — the Mandelbrot image (left) and a read-only data panel (right). This is the
//! ImGui-facing edge: it imports the C bridge (`../c.zig`) and the core cimgui
//! decls (`../cimgui.zig`), so it is NOT part of the fast pure test tier and is NOT
//! registered in `root.zig`. All numbers/strings it shows come from the pure
//! `stats.zig` (unit-tested) and the fixed `Viewport` (see `../fractal/viewport.zig`).
//!
//! No docking, no multi-viewport (plan non-goal): one window pinned to the OS
//! window's work area via the bridge helper `ffImguiFillMainViewport`.
const std = @import("std");
const c = @import("../c.zig").c;
const ig = @import("../cimgui.zig");
const stats = @import("stats.zig");
const viewport = @import("../fractal/viewport.zig");

const window_name = "fractalforge";
const about_popup = "About fractalforge";

/// Width (px) reserved for the data panel; the fractal region gets the rest.
const data_panel_w: f32 = 260.0;
/// Horizontal gap between the fractal region and the data panel.
const region_spacing: f32 = 8.0;

/// Flags for the single fixed window: a fixed, non-movable, non-resizable frame
/// with a menu bar and no persisted state (so the layout is deterministic).
const window_flags: ig.WindowFlags =
    ig.window_flags_no_title_bar |
    ig.window_flags_no_resize |
    ig.window_flags_no_move |
    ig.window_flags_no_collapse |
    ig.window_flags_no_saved_settings |
    ig.window_flags_no_bring_to_front |
    ig.window_flags_menu_bar;

/// Build one frame of the fixed layout. Call between `Ui.newFrame` and
/// `Ui.endFrame`. Sets `quit_requested.*` when File→Quit is chosen; everything
/// else is drawn read-only. `texture` is the uploaded Mandelbrot (T7).
pub fn draw(
    texture: *c.SDL_GPUTexture,
    tex_w: u32,
    tex_h: u32,
    vp: viewport.Viewport,
    max_iter: u32,
    s: stats.Stats,
    quit_requested: *bool,
) void {
    c.ffImguiFillMainViewport();
    if (ig.igBegin(window_name, null, window_flags)) {
        const open_about = drawMenuBar(quit_requested);
        if (open_about) ig.igOpenPopup_Str(about_popup, 0);

        var avail_w: f32 = 0;
        var avail_h: f32 = 0;
        c.ffImguiContentAvail(&avail_w, &avail_h);
        var fractal_w = avail_w - data_panel_w - region_spacing;
        if (fractal_w < 0) fractal_w = 0;

        _ = c.ffImguiBeginChild("fractal_region", fractal_w, 0, true);
        drawFractal(texture, tex_w, tex_h);
        c.ffImguiEndChild();

        ig.igSameLine(0, region_spacing);

        _ = c.ffImguiBeginChild("data_panel", 0, 0, true);
        drawDataPanel(vp, max_iter, s);
        c.ffImguiEndChild();

        drawAboutModal();
    }
    ig.igEnd();
}

/// Draw the menu bar. Sets `quit_requested.*` on File→Quit; returns true when
/// Help→About was clicked so the caller can open the modal at window scope.
fn drawMenuBar(quit_requested: *bool) bool {
    var open_about = false;
    if (ig.igBeginMenuBar()) {
        if (ig.igBeginMenu("File", true)) {
            if (ig.igMenuItem_Bool("Quit", null, false, true)) quit_requested.* = true;
            ig.igEndMenu();
        }
        if (ig.igBeginMenu("Help", true)) {
            if (ig.igMenuItem_Bool("About", null, false, true)) open_about = true;
            ig.igEndMenu();
        }
        ig.igEndMenuBar();
    }
    return open_about;
}

/// Draw the Mandelbrot texture, aspect-fit to the current region (letterbox).
fn drawFractal(texture: *c.SDL_GPUTexture, tex_w: u32, tex_h: u32) void {
    var region_w: f32 = 0;
    var region_h: f32 = 0;
    c.ffImguiContentAvail(&region_w, &region_h);
    const fit = stats.containSize(
        @floatFromInt(tex_w),
        @floatFromInt(tex_h),
        region_w,
        region_h,
    );
    c.ffImguiImage(texture, fit.w, fit.h);
}

/// Read-only observability panel: render/frame ms, dispatch count, the visible
/// complex-plane bounds, and max_iter. Bounds are derived from the fixed viewport.
fn drawDataPanel(vp: viewport.Viewport, max_iter: u32, s: stats.Stats) void {
    const w: f64 = @floatFromInt(vp.width);
    const h: f64 = @floatFromInt(vp.height);
    const re_min = vp.center_re - (w / 2.0) * vp.scale;
    const re_max = vp.center_re + (w / 2.0) * vp.scale;
    const im_min = vp.center_im - (h / 2.0) * vp.scale;
    const im_max = vp.center_im + (h / 2.0) * vp.scale;

    ig.igTextUnformatted("Render stats", null);
    ig.igSeparator();
    textf("CPU render: {d:.2} ms", .{s.render_ms});
    textf("Frame: {d:.2} ms", .{s.frame_ms});
    textf("Dispatches: {d}", .{s.dispatch_count});

    ig.igSpacing();
    ig.igTextUnformatted("Viewport", null);
    ig.igSeparator();
    textf("re: [{d:.4}, {d:.4}]", .{ re_min, re_max });
    textf("im: [{d:.4}, {d:.4}]", .{ im_min, im_max });
    textf("max_iter: {d}", .{max_iter});
}

/// The Help→About modal. Draw unconditionally each frame; ImGui shows it only after
/// `igOpenPopup_Str`. Closes on the Close button.
fn drawAboutModal() void {
    if (ig.igBeginPopupModal(about_popup, null, ig.window_flags_no_resize)) {
        ig.igTextUnformatted("fractalforge - M0 skeleton", null);
        ig.igTextUnformatted("CPU Mandelbrot -> SDL_GPU texture -> Dear ImGui.", null);
        ig.igSeparator();
        if (ig.igSmallButton("Close")) ig.igCloseCurrentPopup();
        ig.igEndPopup();
    }
}

/// Format `fmt`/`args` into a stack buffer and draw as one unformatted text line.
/// Using `igTextUnformatted` avoids passing a Zig-built string through ImGui's
/// C varargs `%`-formatter. On overflow the line is silently skipped (UI-only).
fn textf(comptime fmt: []const u8, args: anytype) void {
    var buf: [160]u8 = undefined;
    const line = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    ig.igTextUnformatted(line.ptr, null);
}
