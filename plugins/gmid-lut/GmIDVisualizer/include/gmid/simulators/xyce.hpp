#pragma once

#include "../simulator.hpp"

#include <expected>
#include <filesystem>
#include <string>
#include <string_view>

namespace gmid {

// ---------------------------------------------------------------------------
// Xyce backend  (Sandia open-source parallel SPICE)
//
// Generates a netlist, runs `Xyce`, and parses the .prn output file.
//
// Requirements: `Xyce` must be on $PATH (or set via xyce_bin).
// ---------------------------------------------------------------------------

struct XyceBackend {
    std::filesystem::path xyce_bin = "Xyce";

    [[nodiscard]] static constexpr std::string_view name() noexcept {
        return "xyce";
    }

    [[nodiscard]] bool available() const;

    [[nodiscard]] std::expected<SweepResult, std::string>
    run(const SweepConfig& cfg) const;

private:
    [[nodiscard]] std::expected<std::filesystem::path, std::string>
    write_netlist(const SweepConfig& cfg) const;

    [[nodiscard]] static std::expected<SweepResult, std::string>
    parse_output(const std::filesystem::path& prn_file, const SweepConfig& cfg);
};

static_assert(Simulator<XyceBackend>);

} // namespace gmid
