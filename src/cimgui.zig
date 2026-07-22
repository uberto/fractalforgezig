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

/// `ImGuiWindowFlags` is a plain `int` typedef in ImGui.
pub const WindowFlags = c_int;

pub extern fn igCreateContext(shared_font_atlas: ?*ImFontAtlas) ?*ImGuiContext;
pub extern fn igDestroyContext(ctx: ?*ImGuiContext) void;
pub extern fn igNewFrame() void;
pub extern fn igRender() void;
pub extern fn igShowDemoWindow(p_open: ?*bool) void;
pub extern fn igBegin(name: [*:0]const u8, p_open: ?*bool, flags: WindowFlags) bool;
pub extern fn igEnd() void;
pub extern fn igText(fmt: [*:0]const u8, ...) void;
