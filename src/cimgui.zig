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

// Navigation input (T6): mouse IO, draw-list overlay, hover and popup queries.

/// A 2D vector as plain C scalars — no struct-by-value ABI concern because Zig
/// maps `extern struct { x: f32, y: f32 }` identically to `struct ImVec2_c`.
pub const ImVec2 = extern struct { x: f32, y: f32 };

/// Unsigned 32-bit RGBA color as packed `0xAABBGGRR`.
pub const ImU32 = u32;

/// Opaque draw-list handle. Obtain via `igGetWindowDrawList`.
pub const ImDrawList = opaque {};

/// Mouse button indices used by `igIsMouseDown_Nil` etc.
pub const mouse_button_left: c_int = 0;
pub const mouse_button_right: c_int = 1;
pub const mouse_button_middle: c_int = 2;

/// `ImGuiKey` values for keyboard queries.
pub const Key = c_int;
pub const key_space: Key = 524; // ImGuiKey_Space

/// `ImGuiHoveredFlags` — pass 0 for the default (any hovered window).
pub const HoveredFlags = c_int;
pub const hovered_flags_none: HoveredFlags = 0;

/// `ImGuiButtonFlags` — pass 0 for the default.
pub const ButtonFlags = c_int;

/// `ImDrawFlags` — pass 0 for no rounding/anti-aliasing overrides.
pub const DrawFlags = c_int;

/// `ImGuiCond` — when to apply `igSetNextWindowPos`.
pub const Cond = c_int;
pub const cond_always: Cond = 1;

// Mouse/keyboard IO queries
pub extern fn igIsMouseDown_Nil(button: c_int) bool;
pub extern fn igIsMouseDragging(button: c_int, lock_threshold: f32) bool;
pub extern fn igGetMouseDragDelta(button: c_int, lock_threshold: f32) ImVec2;
pub extern fn igResetMouseDragDelta(button: c_int) void;
pub extern fn igIsKeyDown_Nil(key: Key) bool;
pub extern fn igIsWindowHovered(flags: HoveredFlags) bool;

// Draw-list overlay (rubber-band rect for box-select)
pub extern fn igGetWindowDrawList() ?*ImDrawList;
pub extern fn ImDrawList_AddRect(
    self: *ImDrawList,
    p_min: ImVec2,
    p_max: ImVec2,
    col: ImU32,
    rounding: f32,
    thickness: f32,
    flags: DrawFlags,
) void;

// Context-menu popup (right-click zoom)
pub extern fn igBeginPopup(str_id: [*:0]const u8, flags: WindowFlags) bool;

// Invisible overlay button over the image (captures hover/click without stealing focus)
pub extern fn igInvisibleButton(str_id: [*:0]const u8, size: ImVec2, flags: ButtonFlags) bool;

// Cursor position in screen space (used for tooltip / coordinate readout placement)
pub extern fn igGetCursorScreenPos() ImVec2;

// Size of the current window's content region (inner size, not including scrollbars).
pub extern fn igGetContentRegionAvail() ImVec2;

// Layout helpers
pub extern fn igGetTextLineHeightWithSpacing() f32;

// Foreground draw list: draws on top of all windows; works outside of any window context.
// Pass null for the main viewport.
pub extern fn igGetForegroundDrawList_ViewportPtr(viewport: ?*anyopaque) ?*ImDrawList;

// Tooltip (hover coordinate readout)
pub extern fn igBeginTooltip() bool;
pub extern fn igEndTooltip() void;

// Coordinate panel widgets (T7): text input, checkbox, button.
pub const InputTextFlags = c_int;
/// `ImGuiInputTextFlags_EnterReturnsTrue` — confirm the field on Enter.
pub const input_text_flags_enter_returns_true: InputTextFlags = 1 << 6;
/// `ImGuiInputTextFlags_ReadOnly` — show the value but reject edits.
pub const input_text_flags_read_only: InputTextFlags = 1 << 9;

/// Text input widget. Returns true when the user commits the edit (Enter if
/// `input_text_flags_enter_returns_true`, or focus lost). `buf` must be null-terminated
/// and writable; `buf_size` is the TOTAL byte capacity (including the null terminator).
/// callback and user_data must be null for the basic usage T7 needs.
pub extern fn igInputText(
    label: [*:0]const u8,
    buf: [*]u8,
    buf_size: usize,
    flags: InputTextFlags,
    callback: ?*anyopaque,
    user_data: ?*anyopaque,
) bool;

/// Checkbox widget. Returns true when the value changes. `v` is read and written.
pub extern fn igCheckbox(label: [*:0]const u8, v: *bool) bool;

/// Button widget. Returns true when clicked. `size` is `{0,0}` for auto-size.
pub extern fn igButton(label: [*:0]const u8, size: ImVec2) bool;

// Group helpers — treats enclosed widgets as a single item for SameLine / cursor tracking.
pub extern fn igBeginGroup() void;
pub extern fn igEndGroup() void;

// Child window with explicit child + window flags.
pub extern fn igBeginChild_Str(str_id: [*:0]const u8, size: ImVec2, child_flags: c_int, window_flags: WindowFlags) bool;
pub extern fn igEndChild() void;

pub const window_flags_no_scrollbar: WindowFlags = 1 << 3;
pub const window_flags_no_scroll_with_mouse: WindowFlags = 1 << 4;

// Collapsible header. Returns true when the section is open/expanded.
pub const TreeNodeFlags = c_int;
pub extern fn igCollapsingHeader_TreeNodeFlags(label: [*:0]const u8, flags: TreeNodeFlags) bool;
