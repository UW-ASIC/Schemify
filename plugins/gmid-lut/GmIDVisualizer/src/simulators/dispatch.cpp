#include "gmid/simulator.hpp"
#include "gmid/simulators/ngspice.hpp"
#include "gmid/simulators/xyce.hpp"

namespace gmid {

std::string_view sim_name(const SimulatorVar& sim) {
    return std::visit([](const auto& s) { return s.name(); }, sim);
}

bool sim_available(const SimulatorVar& sim) {
    return std::visit([](const auto& s) { return s.available(); }, sim);
}

std::expected<SweepResult, std::string>
sim_run(SimulatorVar& sim, const SweepConfig& cfg) {
    return std::visit([&cfg](auto& s) { return s.run(cfg); }, sim);
}

} // namespace gmid
