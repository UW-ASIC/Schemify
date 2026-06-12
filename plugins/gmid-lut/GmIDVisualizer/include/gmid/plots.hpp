#pragma once

#include "simulator.hpp"

#include <filesystem>
#include <vector>

namespace gmid {

// ---------------------------------------------------------------------------
// Dynamic plot series  —  x/y filled from real simulator output
// ---------------------------------------------------------------------------

struct PlotSeries {
    std::vector<double> x;
    std::vector<double> y;
};

// ---------------------------------------------------------------------------
// Extracted slice at the mid-VDS operating point.
// Each vector has one entry per valid VGS step (deep cut-off points removed).
// ---------------------------------------------------------------------------

struct MosfetSlice {
    std::vector<double> vgs;   // V
    std::vector<double> id;    // A
    std::vector<double> jd;    // A/µm  (Id / width_um)
    std::vector<double> gm;    // S
    std::vector<double> gds;   // S
    std::vector<double> gmid;  // V⁻¹  (gm / Id)
    std::vector<double> av;    // V/V  (gm / gds)
};

struct BjtSlice {
    std::vector<double> vbe;   // V
    std::vector<double> ic;    // A
    std::vector<double> gm;    // S
    std::vector<double> gds;   // S  (go)
    std::vector<double> gmic;  // V⁻¹  (gm / Ic)
    std::vector<double> av;    // gm·ro
    std::vector<double> beta;  // Ic / Ib
};

// Extract the mid-VDS slice and compute all gm/Id quantities.
MosfetSlice extract_mosfet_slice(const SweepResult& r, const SweepConfig& cfg);
BjtSlice    extract_bjt_slice   (const SweepResult& r, const SweepConfig& cfg);

// ---------------------------------------------------------------------------
// Render a full set of SVGs from a completed sweep.
// Returns the paths of every written file.
// ---------------------------------------------------------------------------

std::vector<std::filesystem::path> generate_mosfet_set(
        const SweepResult& data,
        const SweepConfig& cfg,
        const std::filesystem::path& out_dir);

std::vector<std::filesystem::path> generate_bjt_set(
        const SweepResult& data,
        const SweepConfig& cfg,
        const std::filesystem::path& out_dir);

} // namespace gmid
