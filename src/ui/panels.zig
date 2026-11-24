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
const gesture = @import("gesture.zig");
const viewport = @import("../fractal/viewport.zig");
const engine_mod = @import("../fractal/engine.zig");
const texture_mod = @import("../gpu/texture.zig");
const gradient = @import("../fractal/gradient.zig");
const presets_mod = @import("../fractal/presets.zig");
const navigate = @import("../fractal/navigate.zig");
const autoiter = @import("../fractal/autoiter.zig");
const progressive = @import("../fractal/progressive.zig");

const ui_log = std.log.scoped(.ui);

const window_name = "fractalforge";
const about_popup = "About fractalforge";

/// Width (px) of one character of the bundled default ImGui font (ProggyClean is a 7×13
/// bitmap font, so every glyph advances 7 px). Only used to SIZE the coordinate fields; nothing
/// depends on it being exact, a pixel either way just changes the spare column.
const font_char_w: f32 = 7.0;

/// Characters one coordinate field must SHOW: the sign, `0.`, `max_coord_digits` decimals and a
/// spare column for the caret. A field narrower than this hides digits behind a horizontal
/// scroll, which defeats the point of carrying 34 of them (M6/T7).
const coord_field_chars: f32 = @floatFromInt(viewport.max_coord_digits + 4);

/// Room kept to the RIGHT of a coordinate field for its ImGui label (`a.re`, the longest, plus
/// the item-inner spacing).
const coord_label_gutter: f32 = 5.0 * font_char_w + 8.0;

/// Width (px) reserved for the data panel; the fractal region gets the rest. Wide enough that a
/// `coord_field_chars` coordinate field AND its label fit inside the child's padding — a
/// full-precision centre the user cannot read is not a readout (M6/T7 widened 260 → 340).
pub const data_panel_w: f32 = 340.0;
/// Horizontal gap between the fractal region and the data panel.
pub const region_spacing: f32 = 8.0;

/// Flags for the single fixed window: a fixed, non-movable, non-resizable frame
/// with a menu bar and no persisted state (so the layout is deterministic).
///
/// NO SCROLLBAR is load-bearing, not cosmetic. The host window fills the viewport and never
/// needs to scroll, but ImGui would still add a vertical scrollbar whenever the content
/// happened to overflow by a pixel — and that scrollbar takes its width out of
/// `ffImguiContentAvail`, which sizes the fractal region, which sizes the content. The result
/// is a two-frame oscillation (996 px ↔ 982 px here) that kept cancelling the full-resolution
/// pass, so the image never sharpened. Keep the region's width independent of its content.
const window_flags: ig.WindowFlags =
    ig.window_flags_no_title_bar |
    ig.window_flags_no_resize |
    ig.window_flags_no_move |
    ig.window_flags_no_collapse |
    ig.window_flags_no_saved_settings |
    ig.window_flags_no_bring_to_front |
    ig.window_flags_no_scrollbar |
    ig.window_flags_no_scroll_with_mouse |
    ig.window_flags_menu_bar;

/// Context-menu action returned from `draw` so `main.zig` can act without re-opening ImGui.
pub const CtxAction = enum { none, zoom_in, zoom_out, center_here };

/// Result of one `draw` call: the context-menu action and the live geometry.
///
/// TWO rectangles come out of a frame and they are NOT the same thing:
///   * `image_rect` — where the texture actually landed on screen: the aspect-preserving
///     fit of the CURRENT texture inside the fractal region (`viewport.fitImageRect`). This
///     is the coordinate-mapping rect (hover readout, box-select, scroll anchor).
///   * `render_w` / `render_h` — the fractal REGION's pixel size, i.e. the resolution the
///     engine should render at so the image fills the region without distortion. main.zig
///     treats this as the full-resolution target for the next pass.
/// They coincide once a pass at the region's size has finished; they differ at startup,
/// mid-resize, and while the coarse navigation preview is on screen.
///
/// `needs_rerender` is set when an in-panel toggle (e.g. GPU/CPU) changed the iteration
/// path — main.zig must call engine.iterate() + upload after the frame.
/// `save_requested` / `open_requested` are set when File→Save… / File→Open… is clicked;
/// main.zig opens the appropriate SDL dialog after the frame.
pub const DrawResult = struct {
    ctx_action: CtxAction,
    image_rect: viewport.ImageRect,
    render_w: u32 = 0,
    render_h: u32 = 0,
    needs_rerender: bool = false,
    save_requested: bool = false,
    open_requested: bool = false,
    /// Set when the Coloring panel's "Save scheme…" / "Load scheme…" button was clicked;
    /// main.zig opens the appropriate SDL `.fpal` dialog after the frame. These sit INSIDE the
    /// `igBeginDisabled(rendering)` block, so they cannot fire while a render pass is running.
    save_scheme_requested: bool = false,
    load_scheme_requested: bool = false,
    /// Set when the status-bar Cancel control was clicked this frame (m9). It lives in the
    /// always-live status bar, OUTSIDE `igBeginDisabled(rendering)`, so the user can stop an
    /// in-flight pass — the whole point of the control. main.zig cancels the pass after the frame.
    cancel_requested: bool = false,
    /// Set when the status-bar Render control was clicked this frame (m9): the user wants to
    /// re-run the full-resolution pass for the unchanged view after a cancel. main.zig re-arms it.
    render_requested: bool = false,
    /// A view / `max_iter` policy the coord panel wants installed (see `CoordRequest`).
    coord: CoordRequest = .{},
    /// Set when a View-menu item was clicked this frame (T5). main.zig owns the bools these
    /// govern — `julia.open`, `orbit.open`, and the loop's `fullscreen` — and flips them after
    /// the frame, so the menu is a request just like File→Save/Open. `toggle_fullscreen` also
    /// drives `SDL_SetWindowFullscreen`; the checkmarks come back through `julia_open` /
    /// `orbit_open` / `fullscreen` passed INTO `draw`, so they always mirror the live state.
    toggle_julia: bool = false,
    toggle_orbit: bool = false,
    toggle_fullscreen: bool = false,
};

/// What the coord panel asks the app to do this frame. The panel NEVER installs these
/// itself: a view or policy change means a full re-iteration, and that must go through
/// main.zig's progressive pass (coarse preview → chunked full-res pass with a progress bar).
/// Applying it inside the ImGui frame is what used to freeze the window for the whole
/// length of a full-resolution render, with no feedback at all.
pub const CoordRequest = struct {
    view: ?viewport.SquareView = null,
    policy: ?autoiter.IterPolicy = null,
    /// The pointing device the user just declared (M7/T6), null when they did not touch the
    /// control this frame. Installing it is a plain `NavState.input_mode` write — unlike its two
    /// siblings it re-renders NOTHING, because it only changes what the NEXT wheel event means.
    /// It is still a request rather than a direct write: the panel is drawn inside the ImGui
    /// frame and does not own engine or navigation state (see this struct's rule above).
    input_mode: ?gesture.InputMode = null,
};

/// Number of built-in presets — comptime-known, so it sizes `SwatchGallery.textures` exactly.
const preset_count = presets_mod.all().len;

/// On-screen size (px) of one preset preview swatch. The baked LUT is `gradient.lut_size` wide
/// and one texel tall; ImGui scales it to this box, so the ramp reads as a smooth horizontal
/// gradient. Sized so a few fit across the fixed `data_panel_w` (see the wrap math below).
const preview_w: f32 = 96.0;
const preview_h: f32 = 20.0;
/// Gap between swatches in the wrap grid.
const swatch_gap: f32 = 8.0;

/// Preview textures for the built-in colour presets (T5). Each preset's gradient is baked ONCE
/// to a `lut_size`×1 LUT and uploaded to its own small GPU texture; the swatch gallery draws
/// these every frame. Built once at startup and freed at teardown — NEVER per frame, which would
/// leak a GPU texture each frame. The `handle`s live behind `texture_mod`.
pub const SwatchGallery = struct {
    /// One preview texture per `presets.all()` entry, in the same order.
    textures: [preset_count]texture_mod.Texture,

    /// Bake every preset's gradient ramp into its own preview texture and upload it. On any GPU
    /// failure, destroys the textures created so far and returns the error, so the caller never
    /// leaks a half-built gallery. Logs the failing call via `texture_mod` (scope `.gpu`).
    pub fn init(device: *c.SDL_GPUDevice) texture_mod.Error!SwatchGallery {
        var self: SwatchGallery = undefined;
        var made: usize = 0;
        errdefer for (self.textures[0..made]) |t| t.destroy();

        for (presets_mod.all(), 0..) |preset, i| {
            var lut: [gradient.lut_size]gradient.Rgba8 = undefined;
            gradient.bakeLut(presets_mod.gradientOf(preset), &lut);
            self.textures[i] = try texture_mod.createRgbaTexture(device, gradient.lut_size, 1);
            made += 1;
            try texture_mod.upload(device, self.textures[i], std.mem.sliceAsBytes(lut[0..]));
        }
        return self;
    }

    /// Release every preview texture. Call exactly once during teardown.
    pub fn deinit(self: SwatchGallery) void {
        for (self.textures) |t| t.destroy();
    }
};

/// Build one frame of the fixed layout. Call between `Ui.newFrame` and `Ui.endFrame`.
/// Sets `quit_requested.*` when File→Quit is chosen. Returns the context-menu action
/// selected this frame (`.none` when no menu item was chosen).
///
/// `open_ctx_menu` / `right_click_pt` / `hover_pt` come from the navigation layer in
/// `main.zig`; the popup and status bar are rendered here, inside the ImGui window,
/// so they share the correct ID stack.
///
/// `input_mode` is the device declaration in force right now (`NavState.input_mode`): it is what
/// the input control DISPLAYS. The control does not keep its own copy — a new choice comes back in
/// `CoordRequest.input_mode` for main.zig to install, so there is no second copy to drift.
///
/// `rendering` freezes the edit panels (a value edited against a half-rendered image would be
/// applied to the next pass anyway); `progress` is the in-flight pass's completion, which
/// takes over the status bar as a progress bar. Both come from the engine's pass state.
///
/// `cancelled` is `NavState.cancelled`: the user stopped this view's refinement and has not
/// restarted it. Together with `rendering` it drives `progressive.statusControl` to pick the
/// status-bar control — Cancel while rendering, Render after a cancel, neither otherwise — which
/// is why both flow through to `drawStatusBar`.
///
/// `julia_open` / `orbit_open` / `fullscreen` are the CURRENT states (T5), owned by main.zig:
/// the two inspectors' open flags and the full-screen mode. They feed the View menu's checkmarks
/// and — for `fullscreen` — the layout branch that hides the data panel and gives the fractal the
/// whole content region. A click on a View item comes back as a `toggle_*` flag in `DrawResult`
/// for main.zig to apply after the frame; the panel never flips these itself.
pub fn draw(
    device: *c.SDL_GPUDevice,
    texture: texture_mod.Texture,
    max_iter: u32,
    s: stats.Stats,
    engine: *engine_mod.Engine,
    editor: *editor_mod.Editor,
    view_editor: *editor_mod.ViewEditor,
    gallery: *const SwatchGallery,
    open_ctx_menu: bool,
    right_click_pt: viewport.ComplexHi,
    hover_pt: ?viewport.ComplexHi,
    input_mode: gesture.InputMode,
    rendering: bool,
    progress: ?f32,
    cancelled: bool,
    julia_open: bool,
    orbit_open: bool,
    fullscreen: bool,
    quit_requested: *bool,
) DrawResult {
    var ctx_action = CtxAction.none;
    var needs_rerender = false;
    var save_requested = false;
    var open_requested = false;
    var save_scheme_requested = false;
    var load_scheme_requested = false;
    var cancel_requested = false;
    var render_requested = false;
    var toggle_julia = false;
    var toggle_orbit = false;
    var toggle_fullscreen = false;
    var coord_request = CoordRequest{};
    // live_rect is updated from ImGui geometry below; fallback keeps old rect on collapsed window.
    var live_rect = viewport.ImageRect{ .x = 0, .y = 0, .w = 0, .h = 0, .side = 0 };
    // The fractal region's size this frame — the resolution the engine should render at.
    var region_w: u32 = 0;
    var region_h: u32 = 0;

    c.ffImguiFillMainViewport();
    if (ig.igBegin(window_name, null, window_flags)) {
        const menu = drawMenuBar(quit_requested, julia_open, orbit_open, fullscreen);
        if (menu.open_about) ig.igOpenPopup_Str(about_popup, 0);
        if (menu.save_requested) save_requested = true;
        if (menu.open_requested) open_requested = true;
        if (menu.toggle_julia) toggle_julia = true;
        if (menu.toggle_orbit) toggle_orbit = true;
        if (menu.toggle_fullscreen) toggle_fullscreen = true;
        // Open the right-click nav popup inside the window so the ID stack is correct.
        if (open_ctx_menu) ig.igOpenPopup_Str("##nav_ctx", 0);

        var avail_w: f32 = 0;
        var avail_h: f32 = 0;
        c.ffImguiContentAvail(&avail_w, &avail_h);
        // Full screen (T5) hides the data panel and hands the WHOLE content region to the fractal;
        // otherwise the panel takes its fixed `data_panel_w` (plus the gap) off the right.
        var fractal_w = if (fullscreen) avail_w else avail_w - data_panel_w - region_spacing;
        if (fractal_w < 0) fractal_w = 0;
        // Reserve one text line + spacing for the status bar so the image fits.
        const status_bar_h: f32 = ig.igGetTextLineHeightWithSpacing() + 6.0;
        const fractal_h = avail_h - status_bar_h;

        const frac_w_u: u32 = if (fractal_w > 0) @intFromFloat(fractal_w) else 0;
        const frac_h_u: u32 = if (fractal_h > 0) @intFromFloat(fractal_h) else 0;
        region_w = frac_w_u;
        region_h = frac_h_u;

        // Group fractal image + status bar so SameLine aligns the data panel to the top.
        ig.igBeginGroup();
        const no_scroll: ig.WindowFlags = ig.window_flags_no_scrollbar | ig.window_flags_no_scroll_with_mouse;
        _ = ig.igBeginChild_Str("fractal_region", .{ .x = fractal_w, .y = fractal_h }, 1, no_scroll);

        // Fit the texture into the region WITHOUT stretching it (see DrawResult): the
        // texture and the region are the same shape only after a pass at the region's
        // size, so the drawn rect is the aspect-preserving fit, and that same rect is
        // what coordinate mapping must use.
        const region_origin = ig.igGetCursorScreenPos();
        live_rect = viewport.fitImageRect(
            @intFromFloat(@max(0, region_origin.x)),
            @intFromFloat(@max(0, region_origin.y)),
            frac_w_u,
            frac_h_u,
            texture.width,
            texture.height,
        );

        drawFractal(texture.handle, live_rect);
        ig.igEndChild();

        // Status bar sits outside the fractal child, directly below it — and, crucially, OUTSIDE
        // the data panel's `igBeginDisabled(rendering)` block, so its Cancel/Render controls stay
        // clickable while a pass runs (the whole point of a Cancel button).
        const status = drawStatusBar(engine, live_rect, hover_pt, progress, rendering, cancelled);
        if (status.cancel) cancel_requested = true;
        if (status.render) render_requested = true;
        ig.igEndGroup();

        // The data panel is hidden in full screen: skip the SameLine and the whole child (and its
        // `igBeginDisabled` block) so the fractal keeps the full content region. Every request the
        // panel raises (needs_rerender, scheme save/load, coord view/policy/input) simply stays at
        // its default this frame — there is no panel to raise them.
        if (!fullscreen) {
            ig.igSameLine(0, region_spacing);

            _ = c.ffImguiBeginChild("data_panel", 0, 0, true);
            ig.igBeginDisabled(rendering);
            if (drawDataPanel(engine.renderViewport(), max_iter, s, engine)) needs_rerender = true;
            ig.igSpacing();
            coord_request = drawCoordPanel(engine, view_editor);
            ig.igSpacing();
            coord_request.input_mode = drawInputPanel(input_mode);
            ig.igSpacing();
            if (ig.igCollapsingHeader_TreeNodeFlags("Coloring", 0)) {
                const pal = drawPalettePanel(device, texture, engine, editor, gallery);
                if (pal.save_scheme) save_scheme_requested = true;
                if (pal.load_scheme) load_scheme_requested = true;
            }
            ig.igEndDisabled();
            c.ffImguiEndChild();
        }

        // Context menu must be opened and rendered in the same window scope.
        ctx_action = drawNavContextMenu(right_click_pt);

        drawAboutModal();
    }
    ig.igEnd();
    return .{
        .ctx_action = ctx_action,
        .image_rect = live_rect,
        .render_w = region_w,
        .render_h = region_h,
        .needs_rerender = needs_rerender,
        .save_requested = save_requested,
        .open_requested = open_requested,
        .save_scheme_requested = save_scheme_requested,
        .load_scheme_requested = load_scheme_requested,
        .cancel_requested = cancel_requested,
        .render_requested = render_requested,
        .coord = coord_request,
        .toggle_julia = toggle_julia,
        .toggle_orbit = toggle_orbit,
        .toggle_fullscreen = toggle_fullscreen,
    };
}

const MenuResult = struct {
    open_about: bool = false,
    save_requested: bool = false,
    open_requested: bool = false,
    /// Set when a View-menu item was clicked this frame: the user asked to flip that state.
    /// main.zig owns the bools (`julia.open`, `orbit.open`, the loop's `fullscreen`), so it
    /// applies the toggle after the frame — the menu only reports the click, exactly like
    /// File→Save/Open above. The current value is passed IN as the item's `selected` arg so the
    /// checkmark always mirrors the live state (a window closed by its own box clears the flag,
    /// and the menu follows next frame).
    toggle_julia: bool = false,
    toggle_orbit: bool = false,
    toggle_fullscreen: bool = false,
};

/// Draw the menu bar. Sets `quit_requested.*` on File→Quit. `julia_open` / `orbit_open` /
/// `fullscreen` are the CURRENT states, passed in as each View item's `selected` arg so the
/// checkmark reflects live state; a click reports a toggle request for main.zig to apply.
fn drawMenuBar(quit_requested: *bool, julia_open: bool, orbit_open: bool, fullscreen: bool) MenuResult {
    var result = MenuResult{};
    if (ig.igBeginMenuBar()) {
        if (ig.igBeginMenu("File", true)) {
            if (ig.igMenuItem_Bool("Save\xe2\x80\xa6", null, false, true)) result.save_requested = true;
            if (ig.igMenuItem_Bool("Open\xe2\x80\xa6", null, false, true)) result.open_requested = true;
            ig.igSeparator();
            if (ig.igMenuItem_Bool("Quit", null, false, true)) quit_requested.* = true;
            ig.igEndMenu();
        }
        if (ig.igBeginMenu("View", true)) {
            if (ig.igMenuItem_Bool("Julia inspector", null, julia_open, true)) result.toggle_julia = true;
            if (ig.igMenuItem_Bool("Orbit inspector", null, orbit_open, true)) result.toggle_orbit = true;
            ig.igSeparator();
            if (ig.igMenuItem_Bool("Full screen", "F11", fullscreen, true)) result.toggle_fullscreen = true;
            ig.igEndMenu();
        }
        if (ig.igBeginMenu("Help", true)) {
            if (ig.igMenuItem_Bool("About", null, false, true)) result.open_about = true;
            ig.igEndMenu();
        }
        ig.igEndMenuBar();
    }
    return result;
}

/// Draw the Mandelbrot texture into the pre-fitted `image_rect` (see `viewport.fitImageRect`):
/// the cursor is moved to the rect's screen origin so the image is centered in its region,
/// and the image is drawn at the rect's size — which carries the TEXTURE's aspect, so the
/// fractal is never stretched. A degenerate rect (minimized window) draws nothing.
fn drawFractal(texture: *c.SDL_GPUTexture, image_rect: viewport.ImageRect) void {
    if (image_rect.w == 0 or image_rect.h == 0) return;
    c.ffImguiSetCursorScreenPos(@floatFromInt(image_rect.x), @floatFromInt(image_rect.y));
    c.ffImguiImage(texture, @floatFromInt(image_rect.w), @floatFromInt(image_rect.h));
}

/// Width of the status bar's iteration field, the longest of its two forms
/// (`"  interior (N)"`) at the widest `max_iter` the policy can hand the engine —
/// `max_manual_iter`, which is larger than the auto ramp's `auto_max_iter`. DERIVED at comptime
/// rather than a hand-written 32, so raising the auto ceiling (M6/T5 took it 4096 → 65536, and
/// `iter 65536` is five digits where M0 assumed four) cannot silently truncate the readout.
const iter_info_buf_len: usize =
    std.fmt.comptimePrint("  interior ({d})", .{autoiter.max_manual_iter}).len;

/// Width (px) reserved for the status bar's Cancel/Render button so the progress bar can take the
/// rest of the line. Wide enough for "Cancel"/"Render" at the 7-px bitmap font plus button
/// padding, with room to spare; nothing depends on it being exact.
const status_button_w: f32 = 72.0;
/// Gap between the progress bar and the Cancel button that shares its line.
const status_button_gap: f32 = 8.0;

/// What the status bar's control reported this frame — at most one of the two is ever set,
/// because `statusControl` offers exactly one control at a time (see `progressive.statusControl`).
const StatusResult = struct {
    /// The Cancel control was clicked (only offered while a pass is in flight).
    cancel: bool = false,
    /// The Render control was clicked (only offered after a cancel).
    render: bool = false,
};

/// One-line status bar at the bottom of the fractal region. `progressive.statusControl` maps the
/// render state to what it shows:
///   * `.cancel` (a pass is in flight) → a PROGRESS BAR sharing its line with a Cancel button, so
///     the user can both see the app working and stop it;
///   * `.render` (the pass was cancelled) → a Render button to re-run the same view;
///   * `.none` → the coordinate + iteration readout when the cursor is over the image, `---` else.
/// The returned `StatusResult` tells `draw` which control fired; the buttons live here, OUTSIDE the
/// data panel's disabled block, so Cancel stays clickable during a render.
fn drawStatusBar(
    engine: *const engine_mod.Engine,
    rect: viewport.ImageRect,
    hover_pt: ?viewport.ComplexHi,
    progress: ?f32,
    rendering: bool,
    cancelled: bool,
) StatusResult {
    ig.igSpacing();
    const line_h = ig.igGetTextLineHeightWithSpacing();
    switch (progressive.statusControl(rendering, cancelled)) {
        .cancel => {
            // `progress` is null in the brief coarse-preview window before the full pass begins;
            // read that as 0% so the bar and its Cancel button appear the moment rendering starts.
            const f = progress orelse 0.0;
            var label_buf: [progressive.progress_label_buf_len]u8 = undefined;
            const label: ?[*:0]const u8 = if (progressive.progressLabel(&label_buf, f)) |l| l.ptr else |_| null;
            // Share the line: the bar takes what is left after the button and the gap, floored at
            // one pixel so a very narrow window never asks for a negative width.
            var avail_w: f32 = 0;
            var avail_h: f32 = 0;
            c.ffImguiContentAvail(&avail_w, &avail_h);
            var bar_w = avail_w - status_button_w - status_button_gap;
            if (bar_w < 1.0) bar_w = 1.0;
            ig.igProgressBar(f, .{ .x = bar_w, .y = line_h }, label);
            ig.igSameLine(0, status_button_gap);
            return .{ .cancel = ig.igButton("Cancel", .{ .x = status_button_w, .y = line_h }) };
        },
        .render => return .{ .render = ig.igButton("Render", .{ .x = status_button_w, .y = line_h }) },
        .none => {},
    }
    if (hover_pt) |pt| {
        var coord_buf: [viewport.coord_buf_len]u8 = undefined;
        const mag = engine.view.magnification();
        const coord_slice = viewport.formatCoord(&coord_buf, pt, mag) catch {
            ig.igTextUnformatted("---", null);
            return .{};
        };

        // Look up the iteration value for this pixel from the engine's iter buffer. The
        // lookup goes through the engine's own RENDER viewport, not the on-screen rect: the
        // buffer is `image_w × image_h` and only matches the screen rect once a pass at the
        // region's size has finished (see `DrawResult`).
        var iter_info_buf: [iter_info_buf_len]u8 = undefined;
        // `catch` yields a SHORT LITERAL, never `&iter_info_buf`: the buffer is `undefined`, so
        // handing it back on overflow would paint the whole thing as text — garbage on screen,
        // not a truncated number. `iter_info_buf_len` is still sized to the widest form, so the
        // fallbacks stay unreachable; they are cheap insurance against the next widening.
        const iter_str: []const u8 = blk: {
            if (rect.side == 0) break :blk "";
            // `lo()`: the render buffer is f64 all the way down, and this only asks WHICH
            // pixel the cursor is over.
            const idx = engine.renderViewport().pixelIndex(pt.lo()) orelse break :blk "";
            if (idx >= engine.iter.len) break :blk "";
            const smooth = engine.iter[idx];
            if (smooth < 0.0) {
                // Interior means "never escaped within max_iter", so the bound is the useful
                // number to show — it says how hard the point was tested.
                break :blk std.fmt.bufPrint(&iter_info_buf, "  interior ({d})", .{engine.max_iter}) catch "  interior";
            } else {
                const iters: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(engine.max_iter)), smooth));
                break :blk std.fmt.bufPrint(&iter_info_buf, "  iter {d}", .{iters}) catch "  iter";
            }
        };

        // Compose into a single null-terminated line.
        var line_buf: [viewport.coord_buf_len + iter_info_buf_len]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s}{s}", .{ coord_slice, iter_str }) catch coord_slice;
        var nt: [viewport.coord_buf_len + iter_info_buf_len + 1]u8 = undefined;
        @memcpy(nt[0..line.len], line);
        nt[line.len] = 0;
        ig.igTextUnformatted(nt[0..line.len :0].ptr, null);
    } else {
        ig.igTextUnformatted("---", null);
    }
    return .{};
}

/// Right-click navigation context menu. Must be called inside the ImGui window Begin/End.
fn drawNavContextMenu(right_click_pt: viewport.ComplexHi) CtxAction {
    _ = right_click_pt; // used by the caller to act on the returned action
    var action = CtxAction.none;
    if (ig.igBeginPopup("##nav_ctx", 0)) {
        if (ig.igMenuItem_Bool("Zoom in 2\xc3\x97", null, false, true)) action = .zoom_in;
        if (ig.igMenuItem_Bool("Zoom out 2\xc3\x97", null, false, true)) action = .zoom_out;
        if (ig.igMenuItem_Bool("Center here", null, false, true)) action = .center_here;
        ig.igEndPopup();
    }
    return action;
}

/// Return true when a render setting changes so main.zig can re-iterate and upload after the frame.
fn drawDataPanel(vp: viewport.Viewport, max_iter: u32, s: stats.Stats, engine: *engine_mod.Engine) bool {
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
    if (s.gpu_render_ms > 0.0) textf("GPU render: {d:.2} ms", .{s.gpu_render_ms});
    textf("iteration passes: {d}", .{engine.iteration_passes});
    textf("color passes: {d}", .{engine.color_passes});
    textf("mode: {s}", .{@tagName(engine.params.mode)});
    textf("stops: {d}", .{engine.gradient.count});

    // M4: GPU/CPU toggle. Disabled if no compute pipeline is wired.
    // Flipping this sets needs_rerender=true so main.zig does the actual iterate+upload.
    const gpu_available = engine.gpu_iter_fn != null;
    ig.igBeginDisabled(!gpu_available);
    const gpu_toggled = ig.igCheckbox("GPU", &engine.use_gpu);
    ig.igEndDisabled();

    ig.igSameLine(0, -1);
    const deep = engine.usesDeepPath();
    ig.igBeginDisabled(!deep);
    const bla_toggled = ig.igCheckbox("BLA", &engine.use_bla);
    ig.igEndDisabled();
    if (!deep) ig.igTextUnformatted("BLA applies only at deep zoom.", null);

    ig.igSpacing();
    ig.igTextUnformatted("Viewport", null);
    ig.igSeparator();
    textf("re: [{d:.4}, {d:.4}]", .{ re_min, re_max });
    textf("im: [{d:.4}, {d:.4}]", .{ im_min, im_max });
    textf("max_iter: {d}", .{max_iter});

    return gpu_toggled or bla_toggled;
}

/// Width (px) for one coordinate input: enough to SHOW `coord_field_chars` characters, capped by
/// the room actually left in the data panel (minus the label gutter) and floored at 8 characters
/// so a squeezed panel still draws a usable field. Call inside the data-panel child.
///
/// This reads `ContentAvail` but does NOT reopen the scrollbar↔ContentAvail feedback loop this
/// repo hit in M5: the loop needed content size to feed back into the REGION size. Here the
/// child's width comes from the `data_panel_w` constant, and an item's width cannot change the
/// panel's content HEIGHT (these are single-line inputs) — so a scrollbar appearing only narrows
/// the fields once and settles.
fn coordFieldWidth() f32 {
    var avail_w: f32 = 0;
    var avail_h: f32 = 0;
    c.ffImguiContentAvail(&avail_w, &avail_h);
    const want = coord_field_chars * font_char_w;
    const room = avail_w - coord_label_gutter;
    return @max(@min(want, room), 8.0 * font_char_w);
}

/// The coordinate editing panel: center+magnification and corners (both forms, kept in
/// sync), Reset to home button, and the auto/manual max_iter control. On commit (Enter on
/// an input field, Reset clicked, or Auto toggled) the panel:
///   1. Parses and validates via the pure `ViewEditor` helpers.
///   2. RETURNS the requested view / policy in a `CoordRequest` — it does NOT call the
///      engine. main.zig installs it through the progressive pass, so the app shows a
///      coarse preview and a progress bar instead of freezing (see `CoordRequest`).
/// On failure, logs `std.log.err` (scope `.ui`) with actionable context and restores the
/// text buffers from the engine's committed state — a parse failure changes nothing.
///
/// At most ONE view request and ONE policy request per frame: the fields are alternative
/// spellings of the same view, so committing two in one frame would queue a stale one.
///
/// M6/T7: the centre and corner fields carry the view's FULL `f128` precision, so a 34-decimal
/// location can be read off, written down and pasted back unrounded. They are sized by
/// `coordFieldWidth` to show all of it (an `igInputText` also stays selectable + horizontally
/// scrollable, so a copy always takes the whole value even if the panel is squeezed).
fn drawCoordPanel(engine: *const engine_mod.Engine, ve: *editor_mod.ViewEditor) CoordRequest {
    var req = CoordRequest{};

    ig.igSeparatorText("Coord");

    // One width for every coordinate field this panel draws (see `coordFieldWidth`).
    const field_w = coordFieldWidth();

    ig.igSeparatorText("Center / Mag");
    // Center Re / Center Im / Magnification — three spellings of one center+mag commit.
    const center_mag_ids = [_][*:0]const u8{ "re##cre", "im##cim", "mag##mag" };
    // SLICES, not `*[64]u8`: the three buffers are one shared size since F1, but the loop
    // reads `buf.len` for ImGui's `buf_size` rather than assuming it.
    const center_mag_bufs = [_][]u8{ &ve.center_re_buf, &ve.center_im_buf, &ve.mag_buf };
    for (center_mag_ids, center_mag_bufs) |label, buf| {
        ig.igSetNextItemWidth(field_w);
        if (ig.igInputText(label, buf.ptr, buf.len, ig.input_text_flags_enter_returns_true, null, null)) {
            if (req.view != null) continue;
            if (ve.parseAndApplyCenterMag()) |new_view| {
                req.view = new_view;
            } else {
                ui_log.err("invalid center/mag — enter finite numbers and a positive magnification", .{});
                ve.syncFromView(engine.view);
            }
        }
    }

    ig.igSeparatorText("Corners");
    const corner_ids = [_][*:0]const u8{ "a.re##are", "a.im##aim", "b.re##bre", "b.im##bim" };
    const corner_bufs = [_][]u8{
        &ve.corner_a_re_buf,
        &ve.corner_a_im_buf,
        &ve.corner_b_re_buf,
        &ve.corner_b_im_buf,
    };
    for (corner_ids, corner_bufs) |label, buf| {
        ig.igSetNextItemWidth(field_w);
        if (ig.igInputText(label, buf.ptr, buf.len, ig.input_text_flags_enter_returns_true, null, null)) {
            if (req.view != null) continue;
            if (ve.parseAndApplyCorners()) |new_view| {
                req.view = new_view;
            } else {
                ui_log.err("invalid corners — enter two distinct finite numbers", .{});
                ve.syncFromView(engine.view);
            }
        }
    }

    // Reset to home
    if (ig.igButton("Reset", .{ .x = 0, .y = 0 })) {
        if (req.view == null) req.view = navigate.reset();
    }

    // max_iter control: Auto checkbox + the field showing the count in use
    ig.igSeparatorText("max_iter");
    if (ig.igCheckbox("Auto", &ve.auto_iter)) {
        // Leaving auto pins the count ON DISPLAY (`ViewEditor.leaveAuto`, which is total), so the
        // user edits on from whatever the ramp chose — not from the number they last typed, which
        // is what the pre-M7 `parseIterPolicy() orelse engine.policy.manual_value` handed back.
        req.policy = if (ve.auto_iter) .{ .auto = true } else ve.leaveAuto();
    }
    // Under Auto the field is a READOUT of `engine.max_iter`, so it must reject edits and must
    // still be readable. Two mechanisms, two jobs, both deliberate:
    //   * `input_text_flags_read_only` is what REJECTS the edit — ImGui keeps drawing, selecting
    //     and copying the text, which is the point for a value the user wants to read.
    //   * `igBeginDisabled` is what GREYS it. The read-only flag alone does NOT: ImGui draws
    //     read-only text in the normal `ImGuiCol_Text`
    //     (`vendor/cimgui/imgui/imgui_widgets.cpp:5528` picks `ImGuiCol_TextDisabled` only for a
    //     HINT), and grey is what the user asked for.
    // Neither is load-bearing alone; removing either loses one of the two properties.
    const iter_read_only = ve.iterFieldReadOnly();
    const iter_flags: ig.InputTextFlags = ig.input_text_flags_enter_returns_true |
        if (iter_read_only) ig.input_text_flags_read_only else 0;
    ig.igBeginDisabled(iter_read_only);
    if (ig.igInputText("iter##iter", &ve.manual_iter_buf, ve.manual_iter_buf.len, iter_flags, null, null)) {
        if (req.policy == null) {
            if (ve.parseIterPolicy()) |policy| {
                req.policy = policy;
            } else {
                logRejectedIter(ve);
                // Restore the buffer from the engine's COMMITTED state: its policy and the count
                // the pixels on screen were computed with.
                ve.syncFromPolicy(engine.policy, engine.max_iter);
            }
        }
    }
    ig.igEndDisabled();

    return req;
}

/// Log a rejected `max_iter` entry on `.ui`, naming what the user typed.
///
/// The RANGE wording lives in exactly ONE place — `autoiter.maxIterRangeMessage`, which names the
/// offending value, the bounds and the two ways out — and is reused verbatim for the case it was
/// written for: a number outside the bounds. Text that is not a number at all has no `u32` to hand
/// it, so that branch names the offending text and stops, rather than restating the bounds in a
/// second wording that could drift from the first. Which branch applies is decided by the pure,
/// unit-tested `ViewEditor.iterRejection`, so the only untested part left here is the formatting.
fn logRejectedIter(ve: *const editor_mod.ViewEditor) void {
    switch (ve.iterRejection()) {
        .out_of_range => |value| {
            var buf: [autoiter.range_message_buf_len]u8 = undefined;
            if (autoiter.maxIterRangeMessage(&buf, value)) |msg| {
                ui_log.err("{s}", .{msg});
            } else |err| {
                // `range_message_buf_len` is the exact worst case, so this cannot happen; still
                // say something actionable rather than swallowing the rejection.
                ui_log.err("rejected max_iter {d} ({s})", .{ value, @errorName(err) });
            }
        },
        .not_a_number => |text| ui_log.err(
            "rejected max_iter: '{s}' is not a whole number; type one, or switch max_iter back to auto",
            .{text},
        ),
    }
}

/// The input-device item labels as null-terminated C pointers, derived at comptime from the pure
/// `editor.input_mode_items` — same construction as `mode_items_c` below, same reason.
const input_mode_items_c = blk: {
    var arr: [editor_mod.input_mode_items.len][*:0]const u8 = undefined;
    for (editor_mod.input_mode_items, 0..) |s, i| arr[i] = s.ptr;
    break :blk arr;
};

/// Hover text for the input-device control. States the problem before the setting, because a user
/// who has not read the spec has no reason to expect a "device" question from a fractal viewer.
///
/// HARD-WRAPPED on purpose: ImGui sizes a tooltip to its longest line and never wraps it for you,
/// so one long line would be a tooltip wider than the window.
const input_mode_help =
    "A trackpad two-finger swipe and a mouse wheel notch reach\n" ++
    "the app as the SAME event, so it has to guess which one\n" ++
    "you are using. Auto guesses from the event, and gets a\n" ++
    "Magic Mouse wrong. If scrolling pans when you meant to\n" ++
    "zoom, or zooms when you meant to pan, name your device.";

/// The input-device control (M7/T6): which pointing device the mouse-wheel events are coming from,
/// so the user can overrule detection when `Auto` gets it wrong.
///
/// REQUESTS, NEVER APPLIES — like `drawCoordPanel`. Returns the newly chosen mode, or null when the
/// user did not touch the control this frame; main.zig installs it into `NavState.input_mode` after
/// the frame. `current` is that same field, so what the control shows is always the mode actually
/// in force: `index` below is a FRAME-LOCAL derived from it, not stored widget state. ImGui reads
/// the selection through that pointer and writes the click back into it in the same call, so a
/// local is sufficient — and it means a request that never got installed snaps visibly back
/// instead of leaving the panel disagreeing with the wheel.
///
/// A combo rather than a radio row: the widget itself needed no new `../cimgui.zig` decl
/// (`igCombo_Str_arr` is already there for the palette mapping — only the tooltip added one), and
/// its width comes from ImGui's default item width, which is a fraction of the panel's own content
/// region. So it cannot push the data panel past `data_panel_w` and squeeze the coordinate fields.
fn drawInputPanel(current: gesture.InputMode) ?gesture.InputMode {
    ig.igSeparatorText("Input");
    var index: c_int = editor_mod.inputModeToIndex(current);
    const clicked = ig.igCombo_Str_arr("device", &index, &input_mode_items_c, input_mode_items_c.len, -1);
    // Tooltip on the combo itself, hence immediately after it: `igBeginItemTooltip` attaches to the
    // LAST item submitted. `igEndTooltip` ONLY when it returned true — pairing it unconditionally
    // would end a scope that was never begun.
    if (ig.igBeginItemTooltip()) {
        ig.igTextUnformatted(input_mode_help, null);
        ig.igEndTooltip();
    }
    if (!clicked) return null;
    const chosen = editor_mod.indexToInputMode(index);
    // Re-picking the item already active is not a change to install; `NavState.input_mode` would
    // end up the same either way, but returning null keeps "a request means something changed".
    if (chosen == current) return null;
    return chosen;
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
/// What the Coloring panel asks the app to do this frame beyond its own colour edits. Save/Load
/// scheme both open an OS file dialog, which main.zig launches AFTER the frame (like File→Save…).
const PaletteResult = struct {
    save_scheme: bool = false,
    load_scheme: bool = false,
};

fn drawPalettePanel(
    device: *c.SDL_GPUDevice,
    texture: texture_mod.Texture,
    engine: *engine_mod.Engine,
    editor: *editor_mod.Editor,
    gallery: *const SwatchGallery,
) PaletteResult {
    var result = PaletteResult{};
    var edits = Edits{};

    drawSwatchGallery(device, texture, engine, editor, gallery);

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
    // Banded vs smooth is part of the colouring, applied as a colour pass (never re-iterates).
    // Sits in the palette panel, which the caller already wraps in `igBeginDisabled(rendering)`.
    if (ig.igCheckbox("banded", &editor.banded)) {
        edits.mapping = true;
    }

    ig.igSeparatorText("Interior");
    var interior = colorToFloats(editor.interior);
    if (ig.igColorEdit4("interior", &interior, 0)) {
        editor.interior = floatsToColor(interior);
        edits.interior = true;
    }

    if (edits.any()) applyEdits(device, texture, engine, editor, edits);

    // Save / Load a portable colour scheme (`.fpal`). These only RAISE a request; main.zig opens
    // the OS dialog after the frame and does the file I/O (like File→Save…). They live here,
    // inside the caller's `igBeginDisabled(rendering)` block, so both grey out during a pass.
    ig.igSeparatorText("Scheme");
    if (ig.igSmallButton("Save scheme\xe2\x80\xa6")) result.save_scheme = true;
    ig.igSameLine(0, 8.0);
    if (ig.igSmallButton("Load scheme\xe2\x80\xa6")) result.load_scheme = true;

    return result;
}

/// Draw the built-in preset gallery: a wrap grid of clickable gradient-ramp swatches, each a
/// preview texture baked from `presets.gradientOf` (see `SwatchGallery`). Clicking one applies
/// that preset as an EDITABLE starting point (requirement "Built-in colouring presets"). Lives
/// inside the caller's `igBeginDisabled(rendering)` block, so the whole grid greys out and stops
/// responding while a render pass runs.
///
/// The wrap count is derived from the FIXED `data_panel_w`, not the live content-region width, so
/// a data-panel scrollbar appearing or disappearing can never feed back into the layout (the
/// scrollbar↔ContentAvail oscillation recorded for this project).
fn drawSwatchGallery(
    device: *c.SDL_GPUDevice,
    texture: texture_mod.Texture,
    engine: *engine_mod.Engine,
    editor: *editor_mod.Editor,
    gallery: *const SwatchGallery,
) void {
    ig.igSeparatorText("Presets");

    // Usable width inside the data-panel child (window padding + border on both edges); a fixed
    // estimate keeps the wrap count constant across frames.
    const usable_w: f32 = data_panel_w - 24.0;
    const per_row: usize = @max(1, @as(usize, @intFromFloat(@floor((usable_w + swatch_gap) / (preview_w + swatch_gap)))));

    for (presets_mod.all(), 0..) |preset, idx| {
        ig.igPushID_Int(@intCast(idx));
        defer ig.igPopID();

        c.ffImguiImage(gallery.textures[idx].handle, preview_w, preview_h);
        if (ig.igIsItemClicked(0)) applyPreset(device, texture, engine, editor, preset);

        // Name in a hover tooltip (kept off the grid so the swatches stay compact).
        if (ig.igBeginItemTooltip()) {
            var name_buf: [64]u8 = undefined;
            const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{preset.name}) catch "preset";
            ig.igTextUnformatted(name_z.ptr, null);
            ig.igEndTooltip();
        }

        // Wrap: keep placing swatches on the same row until the row is full or the list ends.
        const at_row_end = (idx + 1) % per_row == 0;
        if (!at_row_end and idx + 1 < presets_mod.all().len) ig.igSameLine(0, swatch_gap);
    }
}

/// Apply a preset as an editable starting point: load it into the editor (`applyScheme`), then
/// push the colouring to the engine as a COLOUR pass only (`applyEdits` → the same setters palette
/// edits use, never re-iterating) and re-upload. Logs a one-line "applied preset <name>".
fn applyPreset(
    device: *c.SDL_GPUDevice,
    texture: texture_mod.Texture,
    engine: *engine_mod.Engine,
    editor: *editor_mod.Editor,
    preset: presets_mod.Preset,
) void {
    editor.applyScheme(preset.scheme);
    applyEdits(device, texture, engine, editor, .{ .gradient = true, .mapping = true, .interior = true });
    ui_log.info("applied preset {s}", .{preset.name});
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
