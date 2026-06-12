#pragma once

#include "../simulator.hpp"

#include <expected>
#include <filesystem>
#include <string>
#include <string_view>

namespace gmid {

// ---------------------------------------------------------------------------
// ngspice backend
//
// Generates a SPICE netlist, runs `ngspice -b`, and parses the text output
// produced by the `wrdata` command.
//
// Requirements: `ngspice` must be on $PATH (or set via ngspice_bin).
// ---------------------------------------------------------------------------

struct NgspiceBackend {
    std::filesystem::path ngspice_bin = "ngspice";   // override if needed

    [[nodiscard]] static constexpr std::string_view name() noexcept {
        return "ngspice";
    }

    [[nodiscard]] bool available() const;

    [[nodiscard]] std::expected<SweepResult, std::string>
    run(const SweepConfig& cfg) const;

private:
    // Generate the .sp netlist into work_dir, return its path
    [[nodiscard]] std::expected<std::filesystem::path, std::string>
    write_netlist(const SweepConfig& cfg) const;

    // Parse the wrdata text output into SweepResult
    [[nodiscard]] static std::expected<SweepResult, std::string>
    parse_wrdata(const std::filesystem::path& data_file, const SweepConfig& cfg);
};

static_assert(Simulator<NgspiceBackend>);

} // namespace gmid
