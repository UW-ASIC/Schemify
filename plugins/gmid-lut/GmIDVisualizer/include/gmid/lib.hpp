#pragma once

// ---------------------------------------------------------------------------
// gmid::characterise()  —  programmatic entry point
//
// Equivalent to the gmid_runner CLI but callable from C++ or (via the
// C-linkage wrappers at the bottom) from any language with FFI.
//
// Usage (C++):
//   gmid::SweepConfig cfg;
//   cfg.model_file  = "path/to/pdk.lib";
//   cfg.device_name = "sky130_fd_pr__nfet_01v8";
//   cfg.kind        = gmid::ModelKind::mosfet;
//   cfg.vgs_stop    = 1.8;   // match your PDK supply
//   cfg.vds_stop    = 1.8;
//   cfg.work_dir    = "/tmp/gmid_work";
//
//   auto result = gmid::characterise(cfg, "/tmp/gmid_out");
//   if (!result.ok()) { /* result.error */ }
//   for (auto& plot : result.plots) {
//       plot.svg;      // filesystem path to SVG
//       plot.lut;      // x/y array matching the plot axes
//   }
// ---------------------------------------------------------------------------

#include "simulator.hpp"

#include <filesystem>
#include <string>
#include <vector>

namespace gmid {

// ---------------------------------------------------------------------------
// Per-plot LUT  —  parallel x/y arrays, one entry per valid VGS/VBE step
// ---------------------------------------------------------------------------

struct LutPoint {
    double x;
    double y;
};

struct PlotResult {
    std::filesystem::path svg;        // written SVG file
    std::string_view      title;      // e.g. "Gm/Id  vs  Current Density"
    std::string_view      x_label;
    std::string_view      y_label;
    std::vector<LutPoint> lut;        // data behind the SVG
};

// ---------------------------------------------------------------------------
// Top-level result
// ---------------------------------------------------------------------------

struct CharResult {
    std::vector<PlotResult> plots;    // 6 plots (mosfet or bjt)
    std::string             error;    // non-empty on failure

    [[nodiscard]] bool ok() const noexcept { return error.empty(); }
};

// ---------------------------------------------------------------------------
// Main entry point
//
// Runs the ngspice sweep defined by `cfg`, writes SVGs to `out_dir`, and
// returns a CharResult with per-plot LUT arrays alongside each SVG path.
// ---------------------------------------------------------------------------

CharResult characterise(const SweepConfig&           cfg,
                        const std::filesystem::path& out_dir);

} // namespace gmid

// ===========================================================================
// C-linkage API  —  for FFI from Python, Zig, Rust, etc.
// ===========================================================================

extern "C" {

struct GmidLutPoint { double x; double y; };

struct GmidPlotResult {
    char          svg_path[1024];
    char          title[128];
    char          x_label[64];
    char          y_label[64];
    GmidLutPoint* lut;       // heap-allocated; freed by gmid_free_result
    int           lut_len;
};

struct GmidCharResult {
    GmidPlotResult* plots;   // heap-allocated array; freed by gmid_free_result
    int             plot_count;
    char            error[512];  // empty string on success
};

// Run a characterisation sweep.  All string pointers must remain valid for
// the duration of the call.  Returns a heap-allocated result; caller must
// pass it to gmid_free_result when done.
GmidCharResult* gmid_characterise(
    const char* model_file,
    const char* device_name,   // NULL → auto-detect from .model statement
    const char* kind,          // "mosfet" or "bjt"
    const char* out_dir,
    const char* work_dir,      // NULL → out_dir + "/work"
    double vgs_start, double vgs_stop, int vgs_steps,
    double vds_start, double vds_stop, int vds_steps,
    double width_um, double length_um, double temp_c);

void gmid_free_result(GmidCharResult* r);

} // extern "C"
