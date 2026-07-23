//! Thin hand-written `extern` declarations for the cimgui (Dear ImGui) C API.
//!
//! Why not `@cImport("cimgui.h")`? cimgui's docking build embeds internal
//! structs that use C bitfields (e.g. `ImGuiContext.BoxSelectState`), which
//! Zig's translate-c collapses to `opaque{}` and then cannot embed by value.
//! We only ever hold `*ImGuiContext` as an opaque handle and call a small set
//! of core functions, so we declare exactly those here and link the symbols
//! from the compiled `vendor/cimgui/cimgui.cpp` (each is `extern "C"`).
//!
//! Grow this list as later tasks (T8) need more of the API. Keep types simple:
//! opaque handles for structs, `c_int` for the Flags typedefs.

/// Opaque Dear ImGui context handle (`ImGuiContext*`).
pub const ImGuiContext = opaque {};

/// `ImFontAtlas*` — unused in M0, kept opaque for igCreateContext's parameter.
pub const ImFontAtlas = opaque {};

/// `ImGuiWindowFlags` / `ImGuiPopupFlags` are plain `int` typedefs in ImGui.
pub const WindowFlags = c_int;
pub const PopupFlags = c_int;

/// `ImGuiColorEditFlags` / `ImGuiSliderFlags` are plain `int` typedefs in ImGui.
pub const ColorEditFlags = c_int;
pub const SliderFlags = c_int;

/// Window flags used by the single fixed M0 app window (values from cimgui.h).
pub const window_flags_no_title_bar: WindowFlags = 1 << 0;
pub const window_flags_no_resize: WindowFlags = 1 << 1;
pub const window_flags_no_move: WindowFlags = 1 << 2;
pub const window_flags_no_collapse: WindowFlags = 1 << 5;
pub const window_flags_no_saved_settings: WindowFlags = 1 << 8;
pub const window_flags_menu_bar: WindowFlags = 1 << 10;
pub const window_flags_no_bring_to_front: WindowFlags = 1 << 13;

pub extern fn igCreateContext(shared_font_atlas: ?*ImFontAtlas) ?*ImGuiContext;
pub extern fn igDestroyContext(ctx: ?*ImGuiContext) void;
pub extern fn igNewFrame() void;
pub extern fn igRender() void;
pub extern fn igShowDemoWindow(p_open: ?*bool) void;
pub extern fn igBegin(name: [*:0]const u8, p_open: ?*bool, flags: WindowFlags) bool;
pub extern fn igEnd() void;
pub extern fn igText(fmt: [*:0]const u8, ...) void;
pub extern fn igTextUnformatted(text: [*:0]const u8, text_end: ?[*:0]const u8) void;
pub extern fn igSeparator() void;
pub extern fn igSpacing() void;
pub extern fn igSameLine(offset_from_start_x: f32, spacing: f32) void;

// Menu bar (scalar-only signatures — no struct-by-value across the ABI).
pub extern fn igBeginMenuBar() bool;
pub extern fn igEndMenuBar() void;
pub extern fn igBeginMenu(label: [*:0]const u8, enabled: bool) bool;
pub extern fn igEndMenu() void;
pub extern fn igMenuItem_Bool(label: [*:0]const u8, shortcut: ?[*:0]const u8, selected: bool, enabled: bool) bool;

// Modal popup (used by Help→About).
pub extern fn igOpenPopup_Str(str_id: [*:0]const u8, popup_flags: PopupFlags) void;
pub extern fn igBeginPopupModal(name: [*:0]const u8, p_open: ?*bool, flags: WindowFlags) bool;
pub extern fn igEndPopup() void;
pub extern fn igCloseCurrentPopup() void;
pub extern fn igSmallButton(label: [*:0]const u8) bool;

// Palette editor widgets (T6). All scalar/pointer signatures — no struct-by-value
// across the ABI, so they need no bridge helper.
pub extern fn igSeparatorText(label: [*:0]const u8) void;
pub extern fn igPushID_Int(int_id: c_int) void;
pub extern fn igPopID() void;
pub extern fn igColorEdit4(label: [*:0]const u8, col: *[4]f32, flags: ColorEditFlags) bool;
pub extern fn igSliderFloat(label: [*:0]const u8, v: *f32, v_min: f32, v_max: f32, format: [*:0]const u8, flags: SliderFlags) bool;
pub extern fn igCombo_Str_arr(label: [*:0]const u8, current_item: *c_int, items: [*]const [*:0]const u8, items_count: c_int, popup_max_height_in_items: c_int) bool;
pub extern fn igBeginDisabled(disabled: bool) void;
pub extern fn igEndDisabled() void;
