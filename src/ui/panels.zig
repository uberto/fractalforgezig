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
const navigate = @import("../fractal/navigate.zig");
const autoiter = @import("../fractal/autoiter.zig");

const ui_log = std.log.scoped(.ui);

const window_name = "fractalforge";
const about_popup = "About fractalforge";

/// Width (px) reserved for the data panel; the fractal region gets the rest.
pub const data_panel_w: f32 = 260.0;
/// Horizontal gap between the fractal region and the data panel.
pub const region_spacing: f32 = 8.0;

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

/// Context-menu action returned from `draw` so `main.zig` can act without re-opening ImGui.
pub const CtxAction = enum { none, zoom_in, zoom_out, center_here };

/// Result of one `draw` call: the context-menu action and the live image rect.
/// The image rect is derived from the actual ImGui child dimensions this frame —
/// main.zig must use this (not the OS window size) for coordinate mapping and resize.
/// `needs_rerender` is set when an in-panel toggle (e.g. GPU/CPU) changed the iteration
/// path — main.zig must call engine.iterate() + upload after the frame.
/// `save_requested` / `open_requested` are set when File→Save… / File→Open… is clicked;
/// main.zig opens the appropriate SDL dialog after the frame.
pub const DrawResult = struct {
    ctx_action: CtxAction,
    image_rect: viewport.ImageRect,
    needs_rerender: bool = false,
    save_requested: bool = false,
    open_requested: bool = false,
};

/// Build one frame of the fixed layout. Call between `Ui.newFrame` and `Ui.endFrame`.
/// Sets `quit_requested.*` when File→Quit is chosen. Returns the context-menu action
/// selected this frame (`.none` when no menu item was chosen).
///
/// `open_ctx_menu` / `right_click_pt` / `hover_pt` come from the navigation layer in
/// `main.zig`; the popup and status bar are rendered here, inside the ImGui window,
/// so they share the correct ID stack.
pub fn draw(
    device: *c.SDL_GPUDevice,
    texture: texture_mod.Texture,
    max_iter: u32,
    s: stats.Stats,
    engine: *engine_mod.Engine,
    editor: *editor_mod.Editor,
    view_editor: *editor_mod.ViewEditor,
    open_ctx_menu: bool,
    right_click_pt: viewport.Complex,
    hover_pt: ?viewport.Complex,
    quit_requested: *bool,
) DrawResult {
    var ctx_action = CtxAction.none;
    var needs_rerender = false;
    var save_requested = false;
    var open_requested = false;
    // live_rect is updated from ImGui geometry below; fallback keeps old rect on collapsed window.
    var live_rect = viewport.ImageRect{ .x = 0, .y = 0, .w = 0, .h = 0, .side = 0 };

    c.ffImguiFillMainViewport();
    if (ig.igBegin(window_name, null, window_flags)) {
        const menu = drawMenuBar(quit_requested);
        if (menu.open_about) ig.igOpenPopup_Str(about_popup, 0);
        if (menu.save_requested) save_requested = true;
        if (menu.open_requested) open_requested = true;
        // Open the right-click nav popup inside the window so the ID stack is correct.
        if (open_ctx_menu) ig.igOpenPopup_Str("##nav_ctx", 0);

        var avail_w: f32 = 0;
        var avail_h: f32 = 0;
        c.ffImguiContentAvail(&avail_w, &avail_h);
        var fractal_w = avail_w - data_panel_w - region_spacing;
        if (fractal_w < 0) fractal_w = 0;
        // Reserve one text line + spacing for the status bar so the image fits.
        const status_bar_h: f32 = ig.igGetTextLineHeightWithSpacing() + 6.0;
        const fractal_h = avail_h - status_bar_h;

        const frac_w_u: u32 = if (fractal_w > 0) @intFromFloat(fractal_w) else 0;
        const frac_h_u: u32 = if (fractal_h > 0) @intFromFloat(fractal_h) else 0;

        // Group fractal image + status bar so SameLine aligns the data panel to the top.
        ig.igBeginGroup();
        const no_scroll: ig.WindowFlags = ig.window_flags_no_scrollbar | ig.window_flags_no_scroll_with_mouse;
        _ = ig.igBeginChild_Str("fractal_region", .{ .x = fractal_w, .y = fractal_h }, 1, no_scroll);

        // Record the actual screen-space top-left for coord mapping.
        const img_origin = ig.igGetCursorScreenPos();
        live_rect = .{
            .x = @intFromFloat(@max(0, img_origin.x)),
            .y = @intFromFloat(@max(0, img_origin.y)),
            .w = frac_w_u,
            .h = frac_h_u,
            .side = @min(frac_w_u, frac_h_u),
        };

        drawFractal(texture.handle, live_rect);
        ig.igEndChild();

        // Status bar sits outside the fractal child, directly below it.
        drawStatusBar(engine, live_rect, hover_pt);
        ig.igEndGroup();

        ig.igSameLine(0, region_spacing);

        _ = c.ffImguiBeginChild("data_panel", 0, 0, true);
        if (drawDataPanel(engine.renderViewport(), max_iter, s, engine)) needs_rerender = true;
        ig.igSpacing();
        drawCoordPanel(device, texture, engine, view_editor);
        ig.igSpacing();
        if (ig.igCollapsingHeader_TreeNodeFlags("Coloring", 0)) {
            drawPalettePanel(device, texture, engine, editor);
        }
        c.ffImguiEndChild();

        // Context menu must be opened and rendered in the same window scope.
        ctx_action = drawNavContextMenu(right_click_pt);

        drawAboutModal();
    }
    ig.igEnd();
    return .{
        .ctx_action = ctx_action,
        .image_rect = live_rect,
        .needs_rerender = needs_rerender,
        .save_requested = save_requested,
        .open_requested = open_requested,
    };
}

const MenuResult = struct {
    open_about: bool = false,
    save_requested: bool = false,
    open_requested: bool = false,
};

/// Draw the menu bar. Sets `quit_requested.*` on File→Quit.
fn drawMenuBar(quit_requested: *bool) MenuResult {
    var result = MenuResult{};
    if (ig.igBeginMenuBar()) {
        if (ig.igBeginMenu("File", true)) {
            if (ig.igMenuItem_Bool("Save\xe2\x80\xa6", null, false, true)) result.save_requested = true;
            if (ig.igMenuItem_Bool("Open\xe2\x80\xa6", null, false, true)) result.open_requested = true;
            ig.igSeparator();
            if (ig.igMenuItem_Bool("Quit", null, false, true)) quit_requested.* = true;
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

/// Draw the Mandelbrot texture at its natural `w × h` size.
fn drawFractal(texture: *c.SDL_GPUTexture, image_rect: viewport.ImageRect) void {
    const w: f32 = @floatFromInt(image_rect.w);
    const h: f32 = @floatFromInt(image_rect.h);
    c.ffImguiImage(texture, w, h);
}

/// One-line status bar at the bottom of the fractal region: coordinate + iteration value
/// when the cursor is over the image; blank when over the bars.
fn drawStatusBar(engine: *const engine_mod.Engine, rect: viewport.ImageRect, hover_pt: ?viewport.Complex) void {
    ig.igSpacing();
    if (hover_pt) |pt| {
        var coord_buf: [viewport.coord_buf_len]u8 = undefined;
        const mag = engine.view.magnification();
        const coord_slice = viewport.formatCoord(&coord_buf, pt, mag) catch {
            ig.igTextUnformatted("---", null);
            return;
        };

        // Look up the iteration value for this pixel from the engine's iter buffer.
        var iter_info_buf: [32]u8 = undefined;
        const iter_str: []u8 = blk: {
            if (rect.side == 0) break :blk std.fmt.bufPrint(&iter_info_buf, "", .{}) catch &iter_info_buf;
            // Map the complex point back to a pixel index.
            const px = engine.view.complexToPixel(pt, rect.side);
            const col: u32 = @intFromFloat(@max(0.0, @min(@as(f64, @floatFromInt(rect.side - 1)), px.x)));
            const row: u32 = @intFromFloat(@max(0.0, @min(@as(f64, @floatFromInt(rect.side - 1)), px.y)));
            const idx = row * rect.side + col;
            if (idx >= engine.iter.len) break :blk std.fmt.bufPrint(&iter_info_buf, "", .{}) catch &iter_info_buf;
            const smooth = engine.iter[idx];
            if (smooth < 0.0) {
                break :blk std.fmt.bufPrint(&iter_info_buf, "  interior", .{}) catch &iter_info_buf;
            } else {
                const iters: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(engine.max_iter)), smooth));
                break :blk std.fmt.bufPrint(&iter_info_buf, "  iter {d}", .{iters}) catch &iter_info_buf;
            }
        };

        // Compose into a single null-terminated line.
        var line_buf: [viewport.coord_buf_len + 32]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s}{s}", .{ coord_slice, iter_str }) catch coord_slice;
        var nt: [viewport.coord_buf_len + 33]u8 = undefined;
        @memcpy(nt[0..line.len], line);
        nt[line.len] = 0;
        ig.igTextUnformatted(nt[0..line.len :0].ptr, null);
    } else {
        ig.igTextUnformatted("---", null);
    }
}

/// Right-click navigation context menu. Must be called inside the ImGui window Begin/End.
fn drawNavContextMenu(right_click_pt: viewport.Complex) CtxAction {
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

/// Render stats + GPU/CPU toggle panel. Returns true when the GPU toggle was flipped
/// so main.zig can re-iterate and upload after the frame (never do GPU work inside ImGui).
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
    const toggled = ig.igCheckbox("GPU", &engine.use_gpu);
    ig.igEndDisabled();

    ig.igSpacing();
    ig.igTextUnformatted("Viewport", null);
    ig.igSeparator();
    textf("re: [{d:.4}, {d:.4}]", .{ re_min, re_max });
    textf("im: [{d:.4}, {d:.4}]", .{ im_min, im_max });
    textf("max_iter: {d}", .{max_iter});

    return toggled;
}

/// The coordinate editing panel: center+magnification and corners (both forms, kept in
/// sync), Reset to home button, and the auto/manual max_iter control. On commit (Enter on
/// an input field, Reset clicked, or Auto toggled) the panel:
///   1. Parses and validates via the pure `ViewEditor` helpers.
///   2. Calls the engine setter (`setViewport` or `setPolicy`).
///   3. Re-uploads the RGBA buffer to the GPU texture.
///   4. Syncs all text buffers from the engine's committed state.
/// On failure, logs `std.log.err` (scope `.ui`) with actionable context and keeps the old
/// state — never re-iterates on a parse failure.
fn drawCoordPanel(
    device: *c.SDL_GPUDevice,
    texture: texture_mod.Texture,
    engine: *engine_mod.Engine,
    ve: *editor_mod.ViewEditor,
) void {
    var nav_changed = false;
    var policy_changed = false;

    ig.igSeparatorText("Coord");

    ig.igSeparatorText("Center / Mag");
    // Center Re
    if (ig.igInputText("re##cre", &ve.center_re_buf, ve.center_re_buf.len, ig.input_text_flags_enter_returns_true, null, null)) {
        if (ve.parseAndApplyCenterMag()) |new_view| {
            applyNavChange(device, texture, engine, ve, new_view);
            nav_changed = true;
        } else {
            ui_log.err("invalid center/mag — enter finite numbers and a positive magnification", .{});
            ve.syncFromView(engine.view);
        }
    }
    // Center Im
    if (ig.igInputText("im##cim", &ve.center_im_buf, ve.center_im_buf.len, ig.input_text_flags_enter_returns_true, null, null)) {
        if (!nav_changed) {
            if (ve.parseAndApplyCenterMag()) |new_view| {
                applyNavChange(device, texture, engine, ve, new_view);
                nav_changed = true;
            } else {
                ui_log.err("invalid center/mag — enter finite numbers and a positive magnification", .{});
                ve.syncFromView(engine.view);
            }
        }
    }
    // Magnification
    if (ig.igInputText("mag##mag", &ve.mag_buf, ve.mag_buf.len, ig.input_text_flags_enter_returns_true, null, null)) {
        if (!nav_changed) {
            if (ve.parseAndApplyCenterMag()) |new_view| {
                applyNavChange(device, texture, engine, ve, new_view);
                nav_changed = true;
            } else {
                ui_log.err("invalid center/mag — enter finite numbers and a positive magnification", .{});
                ve.syncFromView(engine.view);
            }
        }
    }

    ig.igSeparatorText("Corners");
    // Corner A Re
    if (ig.igInputText("a.re##are", &ve.corner_a_re_buf, ve.corner_a_re_buf.len, ig.input_text_flags_enter_returns_true, null, null)) {
        if (!nav_changed) {
            if (ve.parseAndApplyCorners()) |new_view| {
                applyNavChange(device, texture, engine, ve, new_view);
                nav_changed = true;
            } else {
                ui_log.err("invalid corners — enter two distinct finite numbers", .{});
                ve.syncFromView(engine.view);
            }
        }
    }
    // Corner A Im
    if (ig.igInputText("a.im##aim", &ve.corner_a_im_buf, ve.corner_a_im_buf.len, ig.input_text_flags_enter_returns_true, null, null)) {
        if (!nav_changed) {
            if (ve.parseAndApplyCorners()) |new_view| {
                applyNavChange(device, texture, engine, ve, new_view);
                nav_changed = true;
            } else {
                ui_log.err("invalid corners — enter two distinct finite numbers", .{});
                ve.syncFromView(engine.view);
            }
        }
    }
    // Corner B Re
    if (ig.igInputText("b.re##bre", &ve.corner_b_re_buf, ve.corner_b_re_buf.len, ig.input_text_flags_enter_returns_true, null, null)) {
        if (!nav_changed) {
            if (ve.parseAndApplyCorners()) |new_view| {
                applyNavChange(device, texture, engine, ve, new_view);
                nav_changed = true;
            } else {
                ui_log.err("invalid corners — enter two distinct finite numbers", .{});
                ve.syncFromView(engine.view);
            }
        }
    }
    // Corner B Im
    if (ig.igInputText("b.im##bim", &ve.corner_b_im_buf, ve.corner_b_im_buf.len, ig.input_text_flags_enter_returns_true, null, null)) {
        if (!nav_changed) {
            if (ve.parseAndApplyCorners()) |new_view| {
                applyNavChange(device, texture, engine, ve, new_view);
                nav_changed = true;
            } else {
                ui_log.err("invalid corners — enter two distinct finite numbers", .{});
                ve.syncFromView(engine.view);
            }
        }
    }

    // Reset to home
    if (ig.igButton("Reset", .{ .x = 0, .y = 0 })) {
        if (!nav_changed) {
            const home = navigate.reset();
            applyNavChange(device, texture, engine, ve, home);
            nav_changed = true;
        }
    }

    // max_iter control: Auto checkbox + manual field
    ig.igSeparatorText("max_iter");
    if (ig.igCheckbox("Auto", &ve.auto_iter)) {
        // Toggle: apply the policy change immediately.
        applyPolicyChange(device, texture, engine, ve);
        policy_changed = true;
    }
    // Manual field is disabled when auto is on.
    ig.igBeginDisabled(ve.auto_iter);
    if (ig.igInputText("iter##iter", &ve.manual_iter_buf, ve.manual_iter_buf.len, ig.input_text_flags_enter_returns_true, null, null)) {
        if (!policy_changed) {
            if (ve.parseIterPolicy()) |policy| {
                applyPolicyChangeWithPolicy(device, texture, engine, ve, policy);
            } else {
                ui_log.err("invalid max_iter — enter an integer between {d} and {d}", .{ autoiter.min_manual_iter, autoiter.max_max_iter });
                // Restore the buffer to the engine's current policy value.
                syncIterBuf(ve, engine.policy);
            }
        }
    }
    ig.igEndDisabled();
}

/// Apply a new view to the engine and re-upload. On failure logs and keeps the old view.
/// Syncs `ve` to the committed engine view on success.
fn applyNavChange(
    device: *c.SDL_GPUDevice,
    texture: texture_mod.Texture,
    engine: *engine_mod.Engine,
    ve: *editor_mod.ViewEditor,
    new_view: viewport.SquareView,
) void {
    engine.setViewport(new_view) catch |err| {
        ui_log.err("navigation rejected ({s}); keeping previous view", .{@errorName(err)});
        ve.syncFromView(engine.view);
        return;
    };
    texture_mod.upload(device, texture, engine.output()) catch |err| {
        ui_log.err("re-upload after coord edit failed ({s})", .{@errorName(err)});
    };
    ve.syncFromView(engine.view);
}

/// Build a policy from the editor's `auto_iter` toggle and `manual_iter_buf`, then apply.
fn applyPolicyChange(
    device: *c.SDL_GPUDevice,
    texture: texture_mod.Texture,
    engine: *engine_mod.Engine,
    ve: *editor_mod.ViewEditor,
) void {
    if (ve.auto_iter) {
        applyPolicyChangeWithPolicy(device, texture, engine, ve, .{ .auto = true });
    } else {
        const policy = ve.parseIterPolicy() orelse blk: {
            // Fall back to current manual_value when the text is blank/garbage.
            break :blk autoiter.IterPolicy{ .auto = false, .manual_value = engine.policy.manual_value };
        };
        applyPolicyChangeWithPolicy(device, texture, engine, ve, policy);
    }
}

/// Apply a given `IterPolicy` to the engine and re-upload.
fn applyPolicyChangeWithPolicy(
    device: *c.SDL_GPUDevice,
    texture: texture_mod.Texture,
    engine: *engine_mod.Engine,
    ve: *editor_mod.ViewEditor,
    policy: autoiter.IterPolicy,
) void {
    engine.setPolicy(policy) catch |err| {
        ui_log.err("policy change rejected ({s}); keeping previous policy", .{@errorName(err)});
        syncIterBuf(ve, engine.policy);
        return;
    };
    texture_mod.upload(device, texture, engine.output()) catch |err| {
        ui_log.err("re-upload after policy change failed ({s})", .{@errorName(err)});
    };
    ve.auto_iter = engine.policy.auto;
    syncIterBuf(ve, engine.policy);
}

/// Write the engine's manual_value into `ve.manual_iter_buf`.
fn syncIterBuf(ve: *editor_mod.ViewEditor, policy: autoiter.IterPolicy) void {
    const s = std.fmt.bufPrint(&ve.manual_iter_buf, "{d}", .{policy.manual_value}) catch return;
    if (s.len < ve.manual_iter_buf.len) ve.manual_iter_buf[s.len] = 0;
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
