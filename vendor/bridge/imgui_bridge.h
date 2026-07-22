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

#ifdef __cplusplus
}
#endif
