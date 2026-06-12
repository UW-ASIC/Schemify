#pragma once

#include "types.hpp"

#include <array>
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace gmid {

// ---------------------------------------------------------------------------
// Plugin state  —  single, flat, cache-friendly struct.
//
// No virtuals, no indirection. The host (Schemify) owns one instance and
// drives it through the free-function C API below.
// ---------------------------------------------------------------------------

struct PluginState {
    // Model selection
    std::filesystem::path           model_path{};
    ModelKind                       model_kind   = ModelKind::unknown;
    std::array<std::filesystem::path, wid::recent_max> recent_models{};
    std::uint8_t                    recent_count = 0;

    // UI state
    bool                            dropdown_open = false;
    Status                          status        = Status::idle;
    std::string                     status_msg{};
    std::string                     error_msg{};

    // Generated plots
    std::vector<std::filesystem::path> plots{};

    // Config
    std::filesystem::path           config_dir{};
    std::filesystem::path           figures_dir{};

    // -----------------------------------------------------------------------
    // Operations
    // -----------------------------------------------------------------------

    void init();
    void select_model(const std::filesystem::path& path);
    void push_recent(const std::filesystem::path& path);
    void run_sweep();
    void clear_error() noexcept;
};

} // namespace gmid

// ---------------------------------------------------------------------------
// C-linkage plugin entry points  (Schemify shared-library interface)
//
// The host calls these through dlsym / GetProcAddress.  All state is kept
// inside a file-static PluginState; no global constructors.
// ---------------------------------------------------------------------------

extern "C" {
    int  gmid_on_load();
    void gmid_on_unload();
    void gmid_on_tick(float dt);
    void gmid_on_draw();                // host queries widget tree here
    void gmid_on_event(int widget_id);
}
