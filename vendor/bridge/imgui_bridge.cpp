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

extern "C" void ffImguiFillMainViewport(void)
{
    const ImGuiViewport *vp = ImGui::GetMainViewport();
    ImGui::SetNextWindowPos(vp->WorkPos);
    ImGui::SetNextWindowSize(vp->WorkSize);
}

extern "C" void ffImguiContentAvail(float *out_w, float *out_h)
{
    const ImVec2 avail = ImGui::GetContentRegionAvail();
    if (out_w) *out_w = avail.x;
    if (out_h) *out_h = avail.y;
}

extern "C" bool ffImguiBeginChild(const char *str_id, float w, float h, bool border)
{
    return ImGui::BeginChild(str_id, ImVec2(w, h), border ? ImGuiChildFlags_Borders : ImGuiChildFlags_None);
}

extern "C" void ffImguiEndChild(void)
{
    ImGui::EndChild();
}

extern "C" void ffImguiImage(SDL_GPUTexture *texture, float w, float h)
{
    // Since Dear ImGui 1.92 (2025/08/08) the SDL_GPU backend takes the raw
    // SDL_GPUTexture* as the ImTextureID; the backend supplies the sampler.
    ImGui::Image((ImTextureID)(intptr_t)texture, ImVec2(w, h));
}

extern "C" void ffImguiSetCursorScreenPos(float x, float y)
{
    ImGui::SetCursorScreenPos(ImVec2(x, y));
}
