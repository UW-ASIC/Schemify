#include "gmid/plugin.hpp"
#include "gmid/model_validator.hpp"
#include "gmid/plots.hpp"
#include "gmid/simulators/ngspice.hpp"

#include <algorithm>
#include <cstdlib>
#include <filesystem>

namespace gmid {

// ---------------------------------------------------------------------------
// PluginState implementation
// ---------------------------------------------------------------------------

void PluginState::init() {
    const char* home = std::getenv("HOME");
    if (!home) home = "/tmp";

    config_dir  = std::filesystem::path(home) / ".config/Schemify/GmIDVisualizer";
    figures_dir = config_dir / "figures";
    std::filesystem::create_directories(figures_dir);
}

void PluginState::select_model(const std::filesystem::path& path) {
    clear_error();

    if (!std::filesystem::exists(path)) {
        status    = Status::err;
        error_msg = "file does not exist: " + path.string();
        return;
    }

    auto result = validate_model_file(path);
    if (!result) {
        status    = Status::err;
        error_msg = result.error();
        return;
    }

    if (*result == ModelKind::unknown) {
        status    = Status::err;
        error_msg = "file is not a recognised MOSFET or BJT model";
        return;
    }

    model_path = path;
    model_kind = *result;
    status     = Status::idle;
    push_recent(path);
}

void PluginState::push_recent(const std::filesystem::path& path) {
    // Remove duplicate if present
    for (std::uint8_t i = 0; i < recent_count; ++i) {
        if (recent_models[i] == path) {
            // Shift down
            for (std::uint8_t j = i; j + 1 < recent_count; ++j)
                recent_models[j] = recent_models[j + 1];
            --recent_count;
            break;
        }
    }

    // Shift right, insert at front
    const auto cap = static_cast<std::uint8_t>(recent_models.size());
    const auto cnt = std::min<std::uint8_t>(recent_count + 1, cap);
    for (std::uint8_t i = cnt - 1; i > 0; --i)
        recent_models[i] = recent_models[i - 1];
    recent_models[0] = path;
    recent_count = cnt;
}

void PluginState::run_sweep() {
    clear_error();

    if (model_path.empty() || model_kind == ModelKind::unknown) {
        status    = Status::err;
        error_msg = "no valid model selected";
        return;
    }

    auto name_result = extract_device_name(model_path);
    if (!name_result) {
        status    = Status::err;
        error_msg = name_result.error();
        return;
    }

    SweepConfig cfg;
    cfg.model_file  = model_path;
    cfg.device_name = std::move(*name_result);
    cfg.kind        = model_kind;
    cfg.work_dir    = config_dir / "work";

    status     = Status::running;
    status_msg = "running ngspice sweep...";

    NgspiceBackend sim;
    auto sweep = sim.run(cfg);
    if (!sweep) {
        status    = Status::err;
        error_msg = sweep.error();
        return;
    }

    status_msg = "generating plots...";

    plots = (model_kind == ModelKind::mosfet)
          ? generate_mosfet_set(*sweep, cfg, figures_dir)
          : generate_bjt_set(*sweep, cfg, figures_dir);

    if (plots.empty()) {
        status    = Status::err;
        error_msg = "plot generation produced no output";
        return;
    }

    status     = Status::done;
    status_msg = std::to_string(plots.size()) + " SVG plots generated";
}

void PluginState::clear_error() noexcept {
    error_msg.clear();
    if (status == Status::err)
        status = Status::idle;
}

} // namespace gmid

// ===========================================================================
// C-linkage plugin entry points
// ===========================================================================

static gmid::PluginState g_state;

extern "C" {

int gmid_on_load() {
    g_state.init();
    return 0;
}

void gmid_on_unload() {
    g_state = gmid::PluginState{};
}

void gmid_on_tick(float /*dt*/) {
    // Reserved for future animated state
}

void gmid_on_draw() {
    // In the real Schemify host this would call widget-building APIs
    // (title, separator, row, label, button, etc.) driven by g_state.
    //
    // The widget tree mirrors the Python original:
    //   - Title bar
    //   - Model selector  (browse + recent dropdown)
    //   - Validation status
    //   - Run button + status line
    //   - Generated plots list with Open buttons
    //
    // Since we don't have the Schemify C++ widget API yet, this is a
    // placeholder that the SDK integration will fill in.
}

void gmid_on_event(int widget_id) {
    using namespace gmid;
    namespace w = gmid::wid;

    if (widget_id == w::model_toggle) {
        g_state.dropdown_open = !g_state.dropdown_open;
        return;
    }

    if (widget_id == w::browse) {
        // File picker — call zenity/kdialog like the Python version.
        // For now, placeholder; real integration would use the Schemify
        // host file-picker API or a popen("zenity ...") call.
        return;
    }

    if (widget_id >= w::recent_base &&
        widget_id <  w::recent_base + w::recent_max) {
        const auto idx = static_cast<std::uint8_t>(widget_id - w::recent_base);
        if (idx < g_state.recent_count)
            g_state.select_model(g_state.recent_models[idx]);
        return;
    }

    if (widget_id == w::run) {
        g_state.run_sweep();
        return;
    }

    if (widget_id >= w::open_svg_base &&
        widget_id <  w::open_svg_base + w::open_svg_max) {
        const auto idx = static_cast<std::size_t>(widget_id - w::open_svg_base);
        if (idx < g_state.plots.size()) {
            // xdg-open in a fire-and-forget child
            const std::string cmd = "xdg-open " + g_state.plots[idx].string() + " &";
            [[maybe_unused]] int rc = std::system(cmd.c_str());
        }
        return;
    }
}

} // extern "C"
