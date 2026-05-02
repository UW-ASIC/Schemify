// GmIDVisualizer — Schemify plugin (pure C++, ABI v6)
//
// Bridges gmid::PluginState (business logic in dep/) to the Schemify
// shared-buffer message protocol via the C SDK header.

#include "lib.h"              // Schemify C ABI (tools/api/c/inc/)
#include "gmid/plugin.hpp"    // gmid::PluginState
#include "gmid/lib.hpp"       // gmid::characterise, CharResult, PlotResult
#include "gmid/types.hpp"     // gmid::wid::*, gmid::Status, etc.

#include <cstddef>
#include <cstring>
#include <string>

// ---------------------------------------------------------------------------
// Plugin-local state
// ---------------------------------------------------------------------------

static gmid::PluginState& g_state = *new gmid::PluginState;

// Sweep parameter sliders (defaults match SweepConfig)
static float s_vgs_stop   = 1.8f;
static float s_vds_stop   = 1.8f;
static float s_width_um   = 10.0f;
static float s_length_um  = 0.18f;
static float s_temp_c     = 27.0f;

// Collapsible section states
static bool s_sec_model_open  = true;
static bool s_sec_sweep_open  = true;
static bool s_sec_plots_open  = true;
static bool s_sec_lut_open    = false;

// Plot data cache (copied from CharResult for rendering)
struct PlotCache {
    std::string title;
    std::vector<float> xs;
    std::vector<float> ys;
};
static std::vector<PlotCache> s_plots;

// LUT data cache
struct LutRow { float x; float y; };
static std::vector<LutRow> s_lut;

// Widget ID namespaces (extending types.hpp wid:: for sweep/plot/lut)
enum : uint32_t {
    WID_TITLE         = 0,
    WID_SEC_MODEL     = 10,
    WID_SEC_SWEEP     = 20,
    WID_SLIDER_VGS    = 21,
    WID_SLIDER_VDS    = 22,
    WID_SLIDER_W      = 23,
    WID_SLIDER_L      = 24,
    WID_SLIDER_TEMP   = 25,
    WID_RUN           = 30,
    WID_SEC_PLOTS     = 40,
    WID_SEC_LUT       = 42,
    WID_PLOT_BASE     = 100,
    WID_LUT_ROW_BASE  = 500,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static inline void wr_label(SpWriter* w, const char* s, uint32_t id) {
    sp_write_ui_label(w, s, strlen(s), id);
}
static inline void wr_button(SpWriter* w, const char* s, uint32_t id) {
    sp_write_ui_button(w, s, strlen(s), id);
}
static inline void wr_status(SpWriter* w, const char* s) {
    sp_write_set_status(w, s, strlen(s));
}
static inline void wr_collapsible_start(SpWriter* w, const char* s, bool open, uint32_t id) {
    sp_write_ui_collapsible_start(w, s, strlen(s), open ? 1 : 0, id);
}

// ---------------------------------------------------------------------------
// Draw — full widget tree
// ---------------------------------------------------------------------------

static void draw_panel(SpWriter* w) {
    using namespace gmid;

    // Title
    wr_label(w, "gm/ID Characterization", WID_TITLE);
    sp_write_ui_separator(w, 1);

    // ── Model section ──
    wr_collapsible_start(w, "Model", s_sec_model_open, WID_SEC_MODEL);

    if (g_state.model_path.empty()) {
        wr_label(w, "No model selected", wid::no_model);
    } else {
        const char* kind_str = (g_state.model_kind == ModelKind::mosfet) ? "MOSFET" : "BJT";
        std::string kind_line = std::string("Type: ") + kind_str;
        wr_label(w, kind_line.c_str(), wid::validated_kind);

        std::string path_line = "File: " + g_state.model_path.filename().string();
        wr_label(w, path_line.c_str(), wid::validated_path);
    }

    wr_button(w, "Browse...", wid::browse);

    // Recent models dropdown
    if (g_state.recent_count > 0) {
        wr_label(w, "Recent:", wid::recent_label);
        for (uint8_t i = 0; i < g_state.recent_count; ++i) {
            std::string name = g_state.recent_models[i].filename().string();
            wr_button(w, name.c_str(), wid::recent_base + i);
        }
    }

    sp_write_ui_collapsible_end(w, WID_SEC_MODEL);

    // ── Sweep parameters ──
    wr_collapsible_start(w, "Sweep Parameters", s_sec_sweep_open, WID_SEC_SWEEP);

    wr_label(w, "VGS stop (V)", 26);
    sp_write_ui_slider(w, s_vgs_stop, 0.0f, 5.0f, WID_SLIDER_VGS);

    wr_label(w, "VDS stop (V)", 27);
    sp_write_ui_slider(w, s_vds_stop, 0.0f, 5.0f, WID_SLIDER_VDS);

    wr_label(w, "Width (um)", 28);
    sp_write_ui_slider(w, s_width_um, 0.1f, 100.0f, WID_SLIDER_W);

    wr_label(w, "Length (um)", 29);
    sp_write_ui_slider(w, s_length_um, 0.01f, 10.0f, WID_SLIDER_L);

    wr_label(w, "Temperature (C)", 31);
    sp_write_ui_slider(w, s_temp_c, -40.0f, 125.0f, WID_SLIDER_TEMP);

    sp_write_ui_collapsible_end(w, WID_SEC_SWEEP);

    // ── Run button + status ──
    sp_write_ui_separator(w, wid::sep_mid);

    if (g_state.status == Status::running) {
        wr_label(w, g_state.status_msg.c_str(), wid::status_running);
        sp_write_ui_progress(w, -1.0f, wid::status_running + 1);
    } else {
        wr_button(w, "Run Sweep", WID_RUN);

        if (g_state.status == Status::done)
            wr_label(w, g_state.status_msg.c_str(), wid::status_done);
        else if (g_state.status == Status::idle)
            wr_label(w, "Ready", wid::status_idle);
    }

    if (g_state.status == Status::err && !g_state.error_msg.empty()) {
        std::string err = "Error: " + g_state.error_msg;
        wr_label(w, err.c_str(), wid::error_detail);
    }

    // ── Plots section ──
    sp_write_ui_separator(w, wid::sep_bot);
    wr_collapsible_start(w, "Plots", s_sec_plots_open, WID_SEC_PLOTS);

    if (s_plots.empty()) {
        wr_label(w, "No plots generated yet", wid::plots_none);
    } else {
        for (size_t i = 0; i < s_plots.size(); ++i) {
            auto& pc = s_plots[i];
            uint32_t plot_id = WID_PLOT_BASE + static_cast<uint32_t>(i);
            sp_write_ui_plot(w, pc.title.c_str(), pc.title.size(),
                             pc.xs.data(), pc.ys.data(),
                             static_cast<uint32_t>(pc.xs.size()), plot_id);
        }
    }

    sp_write_ui_collapsible_end(w, WID_SEC_PLOTS);

    // ── LUT section ──
    wr_collapsible_start(w, "LUT Data", s_sec_lut_open, WID_SEC_LUT);

    if (s_lut.empty()) {
        wr_label(w, "Run a sweep to see data", WID_LUT_ROW_BASE);
    } else {
        // Header
        sp_write_ui_begin_row(w, WID_LUT_ROW_BASE);
        wr_label(w, "X", WID_LUT_ROW_BASE + 1);
        wr_label(w, "Y", WID_LUT_ROW_BASE + 2);
        sp_write_ui_end_row(w, WID_LUT_ROW_BASE);

        size_t max_rows = (s_lut.size() < 50) ? s_lut.size() : 50;
        for (size_t i = 0; i < max_rows; ++i) {
            uint32_t row_id = WID_LUT_ROW_BASE + 10 + static_cast<uint32_t>(i) * 3;
            char xbuf[32], ybuf[32];
            snprintf(xbuf, sizeof(xbuf), "%.4g", static_cast<double>(s_lut[i].x));
            snprintf(ybuf, sizeof(ybuf), "%.4g", static_cast<double>(s_lut[i].y));

            sp_write_ui_begin_row(w, row_id);
            wr_label(w, xbuf, row_id + 1);
            wr_label(w, ybuf, row_id + 2);
            sp_write_ui_end_row(w, row_id);
        }
    }

    sp_write_ui_collapsible_end(w, WID_SEC_LUT);
}

// ---------------------------------------------------------------------------
// Run sweep and cache results for rendering
// ---------------------------------------------------------------------------

static void run_and_cache(SpWriter* w) {
    g_state.run_sweep();
    sp_write_request_refresh(w);

    if (g_state.status != gmid::Status::done)
        return;

    // Re-run characterise to get LUT data (run_sweep generates SVGs via plots.cpp)
    // Build config from current slider state
    auto name_result = gmid::extract_device_name(g_state.model_path);
    if (!name_result) return;

    gmid::SweepConfig cfg;
    cfg.model_file  = g_state.model_path;
    cfg.device_name = std::move(*name_result);
    cfg.kind        = g_state.model_kind;
    cfg.vgs_stop    = static_cast<double>(s_vgs_stop);
    cfg.vds_stop    = static_cast<double>(s_vds_stop);
    cfg.width_um    = static_cast<double>(s_width_um);
    cfg.length_um   = static_cast<double>(s_length_um);
    cfg.temp_c      = static_cast<double>(s_temp_c);
    cfg.work_dir    = g_state.config_dir / "work";

    auto result = gmid::characterise(cfg, g_state.figures_dir);
    if (!result.ok()) return;

    // Cache plots for sp_write_ui_plot
    s_plots.clear();
    s_lut.clear();

    for (auto& pr : result.plots) {
        PlotCache pc;
        pc.title = std::string(pr.title);
        pc.xs.reserve(pr.lut.size());
        pc.ys.reserve(pr.lut.size());
        for (auto& pt : pr.lut) {
            pc.xs.push_back(static_cast<float>(pt.x));
            pc.ys.push_back(static_cast<float>(pt.y));
        }
        s_plots.push_back(std::move(pc));
    }

    // Use first plot's LUT as the default LUT table
    if (!result.plots.empty()) {
        for (auto& pt : result.plots[0].lut)
            s_lut.push_back({static_cast<float>(pt.x), static_cast<float>(pt.y)});
    }
}

// ---------------------------------------------------------------------------
// ProcessFn — Schemify ABI v6 entry point
// ---------------------------------------------------------------------------

static size_t gmid_process(const uint8_t* in_ptr, size_t in_len,
                           uint8_t* out_ptr, size_t out_cap) {
    SpReader r = sp_reader_init(in_ptr, in_len);
    SpWriter w = sp_writer_init(out_ptr, out_cap);
    SpMsg msg;

    while (sp_reader_next(&r, &msg)) {
        switch (msg.tag) {

        case SP_TAG_LOAD:
            g_state.init();
            sp_write_register_panel(&w,
                "gmid", 4, "gm/ID Visualizer", 16, "gmid", 4,
                SP_LAYOUT_RIGHT_SIDEBAR, 0);
            wr_status(&w, "GmID Visualizer loaded");
            break;

        case SP_TAG_UNLOAD:
            g_state = gmid::PluginState{};
            s_plots.clear();
            s_lut.clear();
            break;

        case SP_TAG_DRAW_PANEL:
            draw_panel(&w);
            break;

        case SP_TAG_BUTTON_CLICKED: {
            uint32_t wid = msg.u.button_clicked.widget_id;

            if (wid == static_cast<uint32_t>(gmid::wid::browse)) {
                // File picker — zenity fallback
                FILE* fp = popen("zenity --file-selection --title='Select SPICE model' 2>/dev/null", "r");
                if (fp) {
                    char path[1024] = {};
                    if (fgets(path, sizeof(path), fp)) {
                        // Strip trailing newline
                        size_t len = strlen(path);
                        if (len > 0 && path[len - 1] == '\n') path[len - 1] = '\0';
                        g_state.select_model(path);
                    }
                    pclose(fp);
                }
                sp_write_request_refresh(&w);
            }
            else if (wid == WID_RUN) {
                run_and_cache(&w);
            }
            else if (wid >= static_cast<uint32_t>(gmid::wid::recent_base) &&
                     wid <  static_cast<uint32_t>(gmid::wid::recent_base + gmid::wid::recent_max)) {
                auto idx = static_cast<uint8_t>(wid - gmid::wid::recent_base);
                if (idx < g_state.recent_count)
                    g_state.select_model(g_state.recent_models[idx]);
                sp_write_request_refresh(&w);
            }
            else if (wid >= static_cast<uint32_t>(gmid::wid::open_svg_base) &&
                     wid <  static_cast<uint32_t>(gmid::wid::open_svg_base + gmid::wid::open_svg_max)) {
                auto idx = static_cast<size_t>(wid - gmid::wid::open_svg_base);
                if (idx < g_state.plots.size()) {
                    std::string cmd = "xdg-open " + g_state.plots[idx].string() + " &";
                    [[maybe_unused]] int rc = system(cmd.c_str());
                }
            }
            break;
        }

        case SP_TAG_SLIDER_CHANGED: {
            uint32_t wid = msg.u.slider_changed.widget_id;
            float    val = msg.u.slider_changed.val;
            if      (wid == WID_SLIDER_VGS)  s_vgs_stop  = val;
            else if (wid == WID_SLIDER_VDS)  s_vds_stop  = val;
            else if (wid == WID_SLIDER_W)    s_width_um  = val;
            else if (wid == WID_SLIDER_L)    s_length_um = val;
            else if (wid == WID_SLIDER_TEMP) s_temp_c    = val;
            break;
        }

        default:
            break;
        }
    }

    return sp_writer_overflow(&w) ? static_cast<size_t>(-1) : w.pos;
}

// ---------------------------------------------------------------------------
// Export descriptor
// ---------------------------------------------------------------------------

SCHEMIFY_PLUGIN("GmIDVisualizer", "0.1.0", gmid_process)
