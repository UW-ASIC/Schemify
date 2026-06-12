#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace gmid {

// ---------------------------------------------------------------------------
// Canvas & layout constants
// ---------------------------------------------------------------------------

struct Canvas {
    static constexpr int width       = 860;
    static constexpr int height      = 520;
    static constexpr int margin_l    = 90;
    static constexpr int margin_b    = 70;
    static constexpr int margin_t    = 60;
    static constexpr int margin_r    = 30;
    static constexpr int plot_w      = width  - margin_l - margin_r;   // 740
    static constexpr int plot_h      = height - margin_t - margin_b;   // 390
    static constexpr int grid_lines  = 6;
};

// ---------------------------------------------------------------------------
// Theme colours  (dark background, blue accent)
// ---------------------------------------------------------------------------

namespace color {
    inline constexpr std::string_view bg        = "#11161d";
    inline constexpr std::string_view grid      = "#9fb3d1";
    inline constexpr std::string_view label     = "#cfd8ea";
    inline constexpr std::string_view title     = "#eef2ff";
    inline constexpr std::string_view plot_line = "#58a6ff";
} // namespace color

// ---------------------------------------------------------------------------
// Sample count used for every sweep
// ---------------------------------------------------------------------------

inline constexpr std::size_t N_SAMPLES = 320;

// ---------------------------------------------------------------------------
// Plot specification (fully constexpr)
// ---------------------------------------------------------------------------

struct PlotSpec {
    std::string_view title;
    std::string_view x_label;
    std::string_view y_label;
    std::string_view filename;
};

inline constexpr std::array<PlotSpec, 6> mosfet_specs {{
    {"Gm/Id  vs  Current Density",    "Gm/Id (1/V)",  "Jd (A/\u00B5m)",      "gmid_vs_current_density.svg"},
    {"Gm/Id  vs  Transconductance",   "Gm/Id (1/V)",  "gm (S)",              "gmid_vs_gm.svg"},
    {"Gm/Id  vs  Output Conductance", "Gm/Id (1/V)",  "gds (S)",             "gmid_vs_gds.svg"},
    {"Gm/Id  vs  Intrinsic Gain",     "Gm/Id (1/V)",  "gm/gds (V/V)",        "gmid_vs_av.svg"},
    {"VGS  vs  Gm/Id",                "VGS (V)",       "Gm/Id (1/V)",         "vgs_vs_gmid.svg"},
    {"VGS  vs  Drain Current",        "VGS (V)",       "Id (A)",              "vgs_vs_id.svg"},
}};

inline constexpr std::array<PlotSpec, 6> bjt_specs {{
    {"gm/Ic  vs  Collector Current Density", "gm/Ic (1/V)", "Jc (A/\u00B5m)", "gmid_vs_current_density.svg"},
    {"gm/Ic  vs  Transconductance",          "gm/Ic (1/V)", "gm (S)",         "gmid_vs_gm.svg"},
    {"gm/Ic  vs  Intrinsic Gain",            "gm/Ic (1/V)", "gm\u00B7ro",     "gmid_vs_av.svg"},
    {"gm/Ic  vs  Current Gain \u03B2",       "gm/Ic (1/V)", "\u03B2",         "gmid_vs_beta.svg"},
    {"VBE  vs  gm/Ic",                       "VBE (V)",      "gm/Ic (1/V)",   "vbe_vs_gmid.svg"},
    {"VBE  vs  Collector Current",           "VBE (V)",      "Ic (A)",         "vbe_vs_ic.svg"},
}};

// ---------------------------------------------------------------------------
// Model kind
// ---------------------------------------------------------------------------

enum class ModelKind : std::uint8_t { mosfet, bjt, unknown };

// ---------------------------------------------------------------------------
// Plugin runtime status
// ---------------------------------------------------------------------------

enum class Status : std::uint8_t { idle, running, done, err };

// ---------------------------------------------------------------------------
// Widget IDs
// ---------------------------------------------------------------------------

namespace wid {
    inline constexpr int title           = 0;
    inline constexpr int sep_top         = 1;
    inline constexpr int model_row       = 2;
    inline constexpr int model_toggle    = 3;
    inline constexpr int browse          = 4;
    inline constexpr int recent_label    = 5;
    inline constexpr int no_model        = 10;
    inline constexpr int validated_kind  = 11;
    inline constexpr int validated_path  = 12;
    inline constexpr int sep_mid         = 20;
    inline constexpr int run             = 21;
    inline constexpr int status_idle     = 23;
    inline constexpr int status_running  = 24;
    inline constexpr int status_done     = 25;
    inline constexpr int error_label     = 26;
    inline constexpr int error_detail    = 27;
    inline constexpr int sep_bot         = 30;
    inline constexpr int plots_label     = 31;
    inline constexpr int plots_none      = 32;

    inline constexpr int recent_base     = 100;
    inline constexpr int recent_max      = 8;
    inline constexpr int open_svg_base   = 300;
    inline constexpr int open_svg_max    = 24;
} // namespace wid

} // namespace gmid
