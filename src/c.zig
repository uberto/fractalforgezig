//! Single C-interop boundary for SDL3, SDL_GPU, and the ImGui backend bridge.
//!
//! The Dear ImGui *core* C API is declared separately in `cimgui.zig` (a thin
//! hand-written extern header) because cimgui.h's docking build trips Zig's
//! translate-c on C bitfields. Everything here translates cleanly.
//!
//! Rule: only `gpu/`, `ui/`, and `main.zig` may import this. The pure fractal
//! core must never touch `c` — keep C types at the edges.
pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_gpu.h");
    @cInclude("imgui_bridge.h");
});
