#pragma once

#include "types.hpp"

#include <cstddef>
#include <expected>
#include <filesystem>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace gmid {

// ---------------------------------------------------------------------------
// Sweep configuration  —  what to simulate
// ---------------------------------------------------------------------------

struct SweepConfig {
    std::filesystem::path model_file;
    std::string           device_name;           // e.g. "nch_lvt"
    ModelKind             kind = ModelKind::mosfet;

    // Voltage sweep ranges
    double vgs_start = 0.0,  vgs_stop = 1.8;
    double vds_start = 0.05, vds_stop = 1.8;
    double vbs_start = 0.0,  vbs_stop = 0.0;
    int    vgs_steps = 181;  // → 10 mV resolution
    int    vds_steps = 18;
    int    vbs_steps = 1;

    // Device geometry
    double width_um  = 10.0;
    double length_um = 0.18;

    // Temperature
    double temp_c = 27.0;

    // True when the device is defined via .subckt (e.g. sky130 PDK)
    // — netlist must use "X1 … <name>" instead of "M1 … <name>"
    bool subcircuit = false;

    // Working directory for intermediate files
    std::filesystem::path work_dir;
};

// ---------------------------------------------------------------------------
// Sweep result  —  SoA layout for cache-friendly bulk processing
//
// Each vector has the same length: vgs_steps * vds_steps * vbs_steps.
// Outer loop = vbs, mid = vds, inner = vgs.
// ---------------------------------------------------------------------------

struct SweepResult {
    // Bias conditions (inputs)
    std::vector<double> vgs;
    std::vector<double> vds;
    std::vector<double> vbs;

    // Operating-point parameters (outputs)
    std::vector<double> id;
    std::vector<double> gm;
    std::vector<double> gds;
    std::vector<double> cgs;
    std::vector<double> cgd;
    std::vector<double> vth;

    [[nodiscard]] std::size_t size() const noexcept { return id.size(); }

    void reserve(std::size_t n) {
        vgs.reserve(n); vds.reserve(n); vbs.reserve(n);
        id.reserve(n);  gm.reserve(n);  gds.reserve(n);
        cgs.reserve(n); cgd.reserve(n); vth.reserve(n);
    }

    void clear() noexcept {
        vgs.clear(); vds.clear(); vbs.clear();
        id.clear();  gm.clear();  gds.clear();
        cgs.clear(); cgd.clear(); vth.clear();
    }
};

// ---------------------------------------------------------------------------
// Simulator concept  —  any backend must satisfy this
//
// Use with templates for zero-cost static dispatch, or with SimulatorVar
// (below) for runtime selection.
// ---------------------------------------------------------------------------

template <typename T>
concept Simulator = requires(T& sim, const SweepConfig& cfg) {
    { sim.name()      } -> std::convertible_to<std::string_view>;
    { sim.available()  } -> std::same_as<bool>;
    { sim.run(cfg)     } -> std::same_as<std::expected<SweepResult, std::string>>;
};

// ---------------------------------------------------------------------------
// Forward-declare concrete backends  (defined in simulators/*.hpp)
// ---------------------------------------------------------------------------

struct NgspiceBackend;
struct XyceBackend;

// ---------------------------------------------------------------------------
// Runtime-selectable simulator  (variant-based, no vtable)
//
// Add new backends here — the rest of the code is generic over SimulatorVar.
// ---------------------------------------------------------------------------

using SimulatorVar = std::variant<NgspiceBackend, XyceBackend>;

// Dispatch helpers — work with any variant whose alternatives satisfy Simulator
std::string_view sim_name(const SimulatorVar& sim);
bool             sim_available(const SimulatorVar& sim);

std::expected<SweepResult, std::string>
sim_run(SimulatorVar& sim, const SweepConfig& cfg);

} // namespace gmid
