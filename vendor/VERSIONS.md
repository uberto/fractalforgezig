# Vendored dependency provenance

Frozen source snapshots compiled from `build.zig`. No live/submodule dependency:
re-vendor by re-cloning at the pins below and copying the same file set.

## cimgui (`vendor/cimgui/`)

- Repo: https://github.com/cimgui/cimgui
- Branch: `docking_inter`
- Commit: `053280dfff63a74cc56a3e493671bee4bb6c60e4`
- Generated against Dear ImGui `1.92.8` (docking), with `imgui_internal.h` API.
- Files: `cimgui.h`, `cimgui.cpp`, `cimconfig.h`, `LICENSE`.

## Dear ImGui (`vendor/cimgui/imgui/`)

- Repo: https://github.com/ocornut/imgui
- Branch: `docking`
- Commit: `b61e56346a92cfcaf1f43a545ca37b0b32239654`
- Core: `imgui.cpp`, `imgui_draw.cpp`, `imgui_tables.cpp`, `imgui_widgets.cpp`,
  `imgui_demo.cpp` + headers (`imgui.h`, `imgui_internal.h`, `imconfig.h`,
  `imstb_*.h`), `LICENSE.txt`.
- Backends (`imgui/backends/`): `imgui_impl_sdl3.{cpp,h}`,
  `imgui_impl_sdlgpu3.{cpp,h}`, `imgui_impl_sdlgpu3_shaders.h`.

The docking branch is vendored for forward-compat (M2/M3 dockable panels). M0
does NOT enable the docking config flag.

## Bridge (`vendor/bridge/`)

First-party thin C-linkage shim over the ImGui SDL3 + SDL_GPU backends
(`imgui_bridge.{h,cpp}`) so Zig can call them without C++-only types.

## SDL3

System library via Homebrew (`/opt/homebrew`), linked dynamically — not vendored.
Verified against SDL 3.4.12.
