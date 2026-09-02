// Thin C-linkage bridge over the Dear ImGui SDL3 + SDL_GPU backends.
//
// Purpose: the backend headers (imgui_impl_sdl3.h / imgui_impl_sdlgpu3.h) are
// C++ and traffic in C++-only types (ImDrawData*, ImGui_ImplSDLGPU3_InitInfo).
// Zig cannot @cImport them directly. This bridge exposes exactly the calls the
// per-frame loop needs using only plain SDL3 / C types, so `src/c.zig` can
// translate it cleanly. ImGui core (context, widgets) is reached separately via
// cimgui.h — this file covers only the platform+renderer backend glue.
//
// Frame order the caller must follow:
//   ffImguiNewFrame(); igNewFrame(); <build UI>; igRender();
//   <acquire swapchain + command buffer>;
//   ffImguiPrepareDrawData(cmd);              // MANDATORY, before the render pass
//   <begin render pass on the swapchain target>;
//   ffImguiRenderDrawData(cmd, pass);
//   <end render pass + submit>.
#pragma once

#include <SDL3/SDL.h>
#include <SDL3/SDL_gpu.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Wire the SDL3 platform backend + SDL_GPU renderer backend to an existing,
// window-claimed GPU device. `color_format` must be the swapchain texture
// format (SDL_GetGPUSwapchainTextureFormat). Returns false on failure; the
// caller logs SDL_GetError() and tears down.
bool ffImguiInitBackends(SDL_Window *window, SDL_GPUDevice *device, SDL_GPUTextureFormat color_format);

// Feed an SDL event to the platform backend. Returns true if consumed.
bool ffImguiProcessEvent(const SDL_Event *event);

// Begin a new backend frame (renderer + platform). Call igNewFrame() after.
void ffImguiNewFrame(void);

// Upload vertex/index buffers for the current frame's draw data. MUST be called
// with a live command buffer BEFORE the render pass that renders ImGui.
void ffImguiPrepareDrawData(SDL_GPUCommandBuffer *command_buffer);

// Record ImGui draw commands into an active render pass targeting the swapchain.
void ffImguiRenderDrawData(SDL_GPUCommandBuffer *command_buffer, SDL_GPURenderPass *render_pass);

// Tear down both backends (renderer then platform). Destroy the ImGui context
// afterwards via cimgui's igDestroyContext.
void ffImguiShutdownBackends(void);

// ── UI layout helpers ──────────────────────────────────────────────────────
// These wrap ImGui calls that traffic in C++-only value types (ImVec2,
// ImTextureRef), exposing plain scalars so Zig (src/ui/panels.zig) can drive the
// layout without struct-by-value ABI concerns. Control flow (quit/about flags)
// stays in Zig via the scalar cimgui.zig core calls.

// Position + size the NEXT window to exactly cover the main viewport's work area
// (the single fixed M0 app window). Call before igBegin.
void ffImguiFillMainViewport(void);

// Write the current content region's available size (in pixels) into *out_w/*out_h.
void ffImguiContentAvail(float *out_w, float *out_h);

// Begin a child region of the given size (0 = fill remaining). Returns visibility;
// call ffImguiEndChild exactly once afterwards regardless of the return value.
bool ffImguiBeginChild(const char *str_id, float w, float h, bool border);
void ffImguiEndChild(void);

// Draw `texture` as an image of `w`x`h` logical pixels at the cursor. The SDL_GPU
// ImGui backend binds the texture via its own sampler; `texture` is the raw handle.
void ffImguiImage(SDL_GPUTexture *texture, float w, float h);

// Set the cursor to an absolute screen position (bypasses the child-window layout).
// Use for letterboxed images that must sit at a computed position in window space.
void ffImguiSetCursorScreenPos(float x, float y);

// Tint the background of floating popups (ImGuiCol_PopupBg) — the colour-picker
// popup, the right-click menu, tooltips and modals — so they read as a distinct
// panel instead of blending into the near-black main window. Call once after
// igCreateContext, before the first frame.
void ffImguiSetPopupBg(float r, float g, float b, float a);

#ifdef __cplusplus
}
#endif
