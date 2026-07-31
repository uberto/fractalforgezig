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
const editor_mod = @import("editor.zig");
const viewport = @import("../fractal/viewport.zig");
const engine_mod = @import("../fractal/engine.zig");
const texture_mod = @import("../gpu/texture.zig");

const ui_log = std.log.scoped(.ui);

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
/// `Ui.endFrame`. Sets `quit_requested.*` when File→Quit is chosen.
///
/// The palette panel edits `editor`; on ANY change it drives the matching engine setter
/// (`setGradient`/`setMapping`/`setInterior`) and RE-UPLOADS the engine's RGBA buffer to
/// `texture` — it NEVER calls `iterate`. The data panel surfaces the engine's two pass
/// counters so that decoupling is visible.
///
/// `image_rect` is the letterboxed square in window coordinates (T5), computed by
/// `viewport.computeImageRect(window_w, window_h)`. The fractal texture is drawn at
/// that position so that T6 can map input coordinates through the same rect.
pub fn draw(
    device: *c.SDL_GPUDevice,
    texture: texture_mod.Texture,
    vp: viewport.Viewport,
    image_rect: viewport.ImageRect,
    max_iter: u32,
    s: stats.Stats,
    engine: *engine_mod.Engine,
    editor: *editor_mod.Editor,
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
        drawFractal(texture.handle, image_rect);
        c.ffImguiEndChild();

        ig.igSameLine(0, region_spacing);

        _ = c.ffImguiBeginChild("data_panel", 0, 0, true);
        drawDataPanel(vp, max_iter, s, engine);
        ig.igSpacing();
        drawPalettePanel(device, texture, engine, editor);
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

/// Draw the Mandelbrot texture at the letterboxed `image_rect` position inside the
/// fractal child region. The child's cursor is moved to the image_rect origin (relative
/// to the child's own origin) then the texture is drawn at `S × S` pixels, so bars
/// appear as the child background (SDL clear color shows through) rather than a stretch.
fn drawFractal(texture: *c.SDL_GPUTexture, image_rect: viewport.ImageRect) void {
    const s: f32 = @floatFromInt(image_rect.side);
    c.ffImguiImage(texture, s, s);
}

/// Read-only observability panel: render/frame ms, the decoupling PASS COUNTERS (iteration
/// vs color) plus the live mode + stop count, the visible complex-plane bounds, and
/// max_iter. The counters make the milestone guarantee visible: a palette/mapping edit
/// bumps `color passes` while `iteration passes` stays fixed.
fn drawDataPanel(vp: viewport.Viewport, max_iter: u32, s: stats.Stats, engine: *const engine_mod.Engine) void {
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
    textf("iteration passes: {d}", .{engine.iteration_passes});
    textf("color passes: {d}", .{engine.color_passes});
    textf("mode: {s}", .{@tagName(engine.params.mode)});
    textf("stops: {d}", .{engine.gradient.count});

    ig.igSpacing();
    ig.igTextUnformatted("Viewport", null);
    ig.igSeparator();
    textf("re: [{d:.4}, {d:.4}]", .{ re_min, re_max });
    textf("im: [{d:.4}, {d:.4}]", .{ im_min, im_max });
    textf("max_iter: {d}", .{max_iter});
}

/// The mapping-mode combo labels as null-terminated C pointers, derived at comptime from
/// the pure `editor.mode_items` (the single source of truth for label + order) so the two
/// never drift. `igCombo_Str_arr` wants `[*:0]const u8` entries, not slices.
const mode_items_c = blk: {
    var arr: [editor_mod.mode_items.len][*:0]const u8 = undefined;
    for (editor_mod.mode_items, 0..) |s, i| arr[i] = s.ptr;
    break :blk arr;
};

/// Which editable inputs a frame's widget interactions touched. Accumulated while drawing
/// so the edge runs exactly the matching engine setter(s) once and re-uploads once.
const Edits = struct {
    gradient: bool = false,
    mapping: bool = false,
    interior: bool = false,

    fn any(self: Edits) bool {
        return self.gradient or self.mapping or self.interior;
    }
};

/// The palette editor + mapping selector. Draws the stop list (color + position, with
/// per-row Remove), Add-stop, the mapping combo + cyclic-period slider, and the interior
/// color edit. On ANY change it applies the edit to `engine` and re-uploads to `texture`
/// via `applyEdits` — never re-iterating.
fn drawPalettePanel(
    device: *c.SDL_GPUDevice,
    texture: texture_mod.Texture,
    engine: *engine_mod.Engine,
    editor: *editor_mod.Editor,
) void {
    var edits = Edits{};

    ig.igSeparatorText("Palette");
    var i: usize = 0;
    while (i < editor.count) : (i += 1) {
        ig.igPushID_Int(@intCast(i));
        defer ig.igPopID();

        var col = colorToFloats(editor.stops_buf[i].color);
        if (ig.igColorEdit4("color", &col, 0)) {
            editor.stops_buf[i].color = floatsToColor(col);
            edits.gradient = true;
        }
        if (ig.igSliderFloat("pos", &editor.stops_buf[i].pos, 0.0, 1.0, "%.3f", 0)) {
            edits.gradient = true;
        }
        if (ig.igSmallButton("Remove")) {
            if (editor.removeStop(i)) edits.gradient = true;
        }
    }
    if (ig.igSmallButton("Add stop")) {
        if (editor.addStop()) edits.gradient = true;
    }

    ig.igSeparatorText("Mapping");
    if (ig.igCombo_Str_arr("mode", &editor.mode_index, &mode_items_c, mode_items_c.len, -1)) {
        edits.mapping = true;
    }
    // The period only affects the cyclic mode, so disable it otherwise for clarity.
    const cyclic = editor.mode() == .cyclic;
    ig.igBeginDisabled(!cyclic);
    if (ig.igSliderFloat("period", &editor.period, 1.0, 128.0, "%.1f", 0)) {
        edits.mapping = true;
    }
    ig.igEndDisabled();

    ig.igSeparatorText("Interior");
    var interior = colorToFloats(editor.interior);
    if (ig.igColorEdit4("interior", &interior, 0)) {
        editor.interior = floatsToColor(interior);
        edits.interior = true;
    }

    if (edits.any()) applyEdits(device, texture, engine, editor, edits);
}

/// Apply the frame's edits to the engine and re-upload the recolored buffer. Runs ONLY
/// the color pass (never `iterate`). On an engine or upload failure logs `std.log.err`
/// (scope `.ui`) with actionable context and skips the frame's update rather than
/// crashing; on success logs the engine's one-line recolor summary.
fn applyEdits(
    device: *c.SDL_GPUDevice,
    texture: texture_mod.Texture,
    engine: *engine_mod.Engine,
    editor: *editor_mod.Editor,
    edits: Edits,
) void {
    if (edits.gradient) engine.setGradient(editor.toGradient()) catch |err| {
        ui_log.err("palette edit rejected ({s}); keeping previous colors", .{@errorName(err)});
        return;
    };
    if (edits.mapping) engine.setMapping(editor.params()) catch |err| {
        ui_log.err("mapping edit rejected ({s}); keeping previous colors", .{@errorName(err)});
        return;
    };
    if (edits.interior) engine.setInterior(editor.interior) catch |err| {
        ui_log.err("interior edit rejected ({s}); keeping previous colors", .{@errorName(err)});
        return;
    };

    texture_mod.upload(device, texture, engine.output()) catch |err| {
        ui_log.err("re-upload of recolored buffer failed ({s})", .{@errorName(err)});
        return;
    };

    var buf: [96]u8 = undefined;
    const summary = engine.summary(&buf) catch return;
    ui_log.info("{s}", .{summary});
}

/// Convert an `Rgba8` (0..255) to the `[4]f32` in `[0,1]` that `igColorEdit4` edits.
fn colorToFloats(color: [4]u8) [4]f32 {
    var out: [4]f32 = undefined;
    inline for (0..4) |k| out[k] = @as(f32, @floatFromInt(color[k])) / 255.0;
    return out;
}

/// Convert an edited `[4]f32` in `[0,1]` back to an `Rgba8`, rounding and clamping.
fn floatsToColor(col: [4]f32) [4]u8 {
    var out: [4]u8 = undefined;
    inline for (0..4) |k| {
        out[k] = @intFromFloat(@round(std.math.clamp(col[k], 0.0, 1.0) * 255.0));
    }
    return out;
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
