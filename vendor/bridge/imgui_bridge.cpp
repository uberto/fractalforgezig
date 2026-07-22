// Implementation of the C-linkage ImGui backend bridge. See imgui_bridge.h.
// Compiled as C++ alongside the vendored Dear ImGui backends; every exported
// symbol has C linkage so Zig can call it via translate-c.
#include "imgui.h"
#include "imgui_impl_sdl3.h"
#include "imgui_impl_sdlgpu3.h"

#include "imgui_bridge.h"

extern "C" bool ffImguiInitBackends(SDL_Window *window, SDL_GPUDevice *device, SDL_GPUTextureFormat color_format)
{
    if (!ImGui_ImplSDL3_InitForSDLGPU(window))
        return false;

    ImGui_ImplSDLGPU3_InitInfo init_info = {};
    init_info.Device = device;
    init_info.ColorTargetFormat = color_format;
    init_info.MSAASamples = SDL_GPU_SAMPLECOUNT_1;
    if (!ImGui_ImplSDLGPU3_Init(&init_info)) {
        ImGui_ImplSDL3_Shutdown();
        return false;
    }
    return true;
}

extern "C" bool ffImguiProcessEvent(const SDL_Event *event)
{
    return ImGui_ImplSDL3_ProcessEvent(event);
}

extern "C" void ffImguiNewFrame(void)
{
    ImGui_ImplSDLGPU3_NewFrame();
    ImGui_ImplSDL3_NewFrame();
}

extern "C" void ffImguiPrepareDrawData(SDL_GPUCommandBuffer *command_buffer)
{
    ImGui_ImplSDLGPU3_PrepareDrawData(ImGui::GetDrawData(), command_buffer);
}

extern "C" void ffImguiRenderDrawData(SDL_GPUCommandBuffer *command_buffer, SDL_GPURenderPass *render_pass)
{
    ImGui_ImplSDLGPU3_RenderDrawData(ImGui::GetDrawData(), command_buffer, render_pass, nullptr);
}

extern "C" void ffImguiShutdownBackends(void)
{
    ImGui_ImplSDLGPU3_Shutdown();
    ImGui_ImplSDL3_Shutdown();
}
