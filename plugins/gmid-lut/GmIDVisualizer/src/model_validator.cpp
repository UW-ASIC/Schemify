#include "gmid/model_validator.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstddef>
#include <fstream>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <unordered_set>
#include <vector>

namespace gmid {

// ---------------------------------------------------------------------------
// Compile-time needle tables
// ---------------------------------------------------------------------------

inline constexpr std::array mos_needles{
    std::string_view{"nmos"},  std::string_view{"pmos"},
    std::string_view{"mosfet"},std::string_view{"level="},
    std::string_view{"nfet"},  std::string_view{"pfet"},
    std::string_view{"vth0"},  std::string_view{"tox"},
};

inline constexpr std::array bjt_needles{
    std::string_view{"npn"},  std::string_view{"pnp"},
    std::string_view{"bjt"},  std::string_view{"is="},
    std::string_view{"bf="},  std::string_view{"br="},
    std::string_view{"vaf="}, std::string_view{"ikf="},
};

static constexpr std::size_t MAX_READ = 2'000'000;

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

std::expected<ModelKind, std::string>
validate_model_file(const std::filesystem::path& path) {

    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file)
        return std::unexpected(std::string{"cannot open file: "} + path.string());

    const auto file_size = static_cast<std::size_t>(file.tellg());
    file.seekg(0);

    const std::size_t read_len = std::min(file_size, MAX_READ);
    std::string buf(read_len, '\0');
    file.read(buf.data(), static_cast<std::streamsize>(read_len));

    // Lower-case in place — single pass, branch-free on modern compilers
    std::ranges::transform(buf, buf.begin(),
        [](unsigned char c) -> char { return static_cast<char>(c | ((c >= 'A' && c <= 'Z') << 5)); });

    auto has_any = [&buf](auto const& needles) {
        for (auto n : needles)
            if (buf.find(n) != std::string::npos) return true;
        return false;
    };

    const bool has_mos = has_any(mos_needles);
    const bool has_bjt = has_any(bjt_needles);

    if (has_mos && !has_bjt) return ModelKind::mosfet;
    if (has_bjt && !has_mos) return ModelKind::bjt;
    if (has_mos && has_bjt)  return ModelKind::mosfet;   // tie-break: MOSFET wins
    return ModelKind::unknown;
}

std::expected<std::string, std::string>
extract_device_name(const std::filesystem::path& path) {
    std::ifstream file(path);
    if (!file)
        return std::unexpected("cannot open: " + path.string());

    std::string first_subckt;   // fallback if no .model found
    std::string line;
    while (std::getline(file, line)) {
        std::string lower = line;
        std::ranges::transform(lower, lower.begin(),
            [](unsigned char c) { return static_cast<char>(std::tolower(c)); });

        if (auto pos = lower.find(".model"); pos != std::string::npos) {
            std::istringstream ss(line.substr(pos + 6));
            std::string name;
            if (ss >> name) return name;
        }
        if (first_subckt.empty()) {
            if (auto pos = lower.find(".subckt"); pos != std::string::npos) {
                std::istringstream ss(line.substr(pos + 7));
                std::string name;
                if (ss >> name) first_subckt = name;
            }
        }
    }
    if (!first_subckt.empty()) return first_subckt;
    return std::unexpected("no .model or .subckt statement found in: " + path.string());
}

static bool file_has_subckt(const std::filesystem::path& path,
                            const std::string& lower_name) {
    std::ifstream file(path);
    if (!file) return false;

    std::string line;
    while (std::getline(file, line)) {
        std::string lower = line;
        std::ranges::transform(lower, lower.begin(),
            [](unsigned char c) { return static_cast<char>(std::tolower(c)); });

        const auto pos = lower.find(".subckt");
        if (pos == std::string::npos) continue;

        std::istringstream ss(lower.substr(pos + 7));
        std::string name;
        if ((ss >> name) && name == lower_name) return true;
    }
    return false;
}

bool is_subcircuit(const std::filesystem::path& path,
                   const std::string& device_name) {
    std::string lower_name = device_name;
    std::ranges::transform(lower_name, lower_name.begin(),
        [](unsigned char c) { return static_cast<char>(std::tolower(c)); });

    // Check the file itself first
    if (file_has_subckt(path, lower_name)) return true;

    // Check sibling .spice files (corner file may .include the pm3 model)
    namespace fs = std::filesystem;
    auto dir = path.parent_path();
    if (dir.empty() || !fs::is_directory(dir)) return false;

    for (const auto& entry : fs::directory_iterator(dir)) {
        if (!entry.is_regular_file()) continue;
        const auto& ext = entry.path().extension();
        if (ext != ".spice" && ext != ".lib") continue;
        if (entry.path() == path) continue;
        if (file_has_subckt(entry.path(), lower_name)) return true;
    }
    return false;
}

static int file_subckt_pins(const std::filesystem::path& path,
                            const std::string& lower_name) {
    std::ifstream file(path);
    if (!file) return 0;

    std::string line;
    while (std::getline(file, line)) {
        std::string lower = line;
        std::ranges::transform(lower, lower.begin(),
            [](unsigned char c) { return static_cast<char>(std::tolower(c)); });

        auto pos = lower.find(".subckt");
        if (pos == std::string::npos) continue;

        std::istringstream ss(lower.substr(pos + 7));
        std::string name;
        if (!(ss >> name) || name != lower_name) continue;

        int count = 0;
        std::string token;
        while (ss >> token) {
            if (token.find('=') != std::string::npos) break;
            ++count;
        }
        return count;
    }
    return 0;
}

int subcircuit_pin_count(const std::filesystem::path& path,
                         const std::string& device_name) {
    std::string lower_name = device_name;
    std::ranges::transform(lower_name, lower_name.begin(),
        [](unsigned char c) { return static_cast<char>(std::tolower(c)); });

    int n = file_subckt_pins(path, lower_name);
    if (n > 0) return n;

    namespace fs = std::filesystem;
    auto dir = path.parent_path();
    if (dir.empty() || !fs::is_directory(dir)) return 0;

    for (const auto& entry : fs::directory_iterator(dir)) {
        if (!entry.is_regular_file()) continue;
        const auto& ext = entry.path().extension();
        if (ext != ".spice" && ext != ".lib") continue;
        if (entry.path() == path) continue;
        n = file_subckt_pins(entry.path(), lower_name);
        if (n > 0) return n;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Recursive .include resolver
// ---------------------------------------------------------------------------

// Extract the file path from a .include directive, or nullopt if not one.
static std::optional<std::string>
parse_include_path(const std::string& line) {
    std::string lower = line;
    std::ranges::transform(lower, lower.begin(),
        [](unsigned char c) { return static_cast<char>(std::tolower(c)); });

    // Find .include (or .inc as abbreviated form)
    std::size_t pos = std::string::npos, skip = 0;
    if (auto p = lower.find(".include"); p != std::string::npos) {
        // Verify it's at the start (ignoring leading whitespace)
        bool ok = true;
        for (std::size_t i = 0; i < p; ++i)
            if (!std::isspace(static_cast<unsigned char>(lower[i]))) { ok = false; break; }
        if (ok) { pos = p; skip = 8; }
    }
    if (pos == std::string::npos) {
        if (auto p = lower.find(".inc "); p != std::string::npos) {
            bool ok = true;
            for (std::size_t i = 0; i < p; ++i)
                if (!std::isspace(static_cast<unsigned char>(lower[i]))) { ok = false; break; }
            if (ok) { pos = p; skip = 4; }
        }
    }
    if (pos == std::string::npos) return std::nullopt;

    auto rest = line.substr(pos + skip);
    auto start = rest.find_first_not_of(" \t");
    if (start == std::string::npos) return std::nullopt;

    // Quoted path
    if (rest[start] == '"' || rest[start] == '\'') {
        char quote = rest[start];
        auto end = rest.find(quote, start + 1);
        if (end == std::string::npos) return std::nullopt;
        return rest.substr(start + 1, end - start - 1);
    }

    // Unquoted path — take until whitespace or end
    auto end = rest.find_first_of(" \t\r\n", start);
    if (end == std::string::npos) end = rest.size();
    return rest.substr(start, end - start);
}

static std::expected<std::string, std::string>
resolve_impl(const std::filesystem::path& path,
             std::unordered_set<std::string>& visited) {
    namespace fs = std::filesystem;

    std::error_code ec;
    auto canonical = fs::canonical(path, ec);
    if (ec)
        return std::unexpected("cannot resolve path: " + path.string()
                               + " (" + ec.message() + ")");

    auto key = canonical.string();
    if (visited.contains(key))
        return std::string{};   // already inlined — skip to avoid duplicates
    visited.insert(key);

    std::ifstream file(canonical);
    if (!file)
        return std::unexpected("cannot open: " + path.string());

    auto parent = canonical.parent_path();
    std::ostringstream out;
    std::string line;

    while (std::getline(file, line)) {
        auto inc_path = parse_include_path(line);
        if (inc_path) {
            fs::path resolved{*inc_path};
            if (resolved.is_relative())
                resolved = parent / resolved;

            if (fs::exists(resolved)) {
                auto result = resolve_impl(resolved, visited);
                if (!result) return result;
                out << *result;
                continue;   // replaced the .include with inlined content
            }
            // File not found locally — leave the directive for the simulator
        }
        out << line << '\n';
    }
    return out.str();
}

std::expected<std::string, std::string>
resolve_includes(const std::filesystem::path& path) {
    std::unordered_set<std::string> visited;
    return resolve_impl(path, visited);
}

// Walk up from the model file directory looking for PDK-wide parameter and
// model files.  Sky130 (and similar PDKs) keep these in libs.tech/ngspice/ —
// normally pulled in by the combined corner files but absent from per-device
// files.
//
// We include (in order):
//   1. parameters/lod.spice       — LOD params (wlod_diff, etc.)
//   2. parameters/invariant.spice — corner-independent defaults
//   3. corners/<corner>/nonfet.spice — corner-specific parasitic junction mults
//   4. parasitics/*.model.spice   — parasitic diode model definitions
//
// The corner is detected from the model filename (__tt, __ff, …).
// We deliberately avoid all.spice because its `.option scale=1.0u` can
// conflict with the per-device netlist.
static std::vector<std::filesystem::path>
find_pdk_parameter_files(const std::filesystem::path& model_file) {
    namespace fs = std::filesystem;
    std::vector<fs::path> params;

    // Detect corner from the model filename; default to "tt" (typical) when
    // the filename has no corner tag (e.g. BJT .model.spice files).
    // MOSFETs use double-letter tags (__tt, __ff, …); BJTs use single (__t, __f, __s).
    const auto stem = model_file.stem().string();
    std::string corner = "tt";
    // {tag_in_filename, corner_directory_name}
    static constexpr std::pair<std::string_view, std::string_view> corner_map[] = {
        {"__tt_leak", "tt_leak"}, {"__tt", "tt"}, {"__ff", "ff"},
        {"__ss", "ss"}, {"__sf", "sf"}, {"__fs", "fs"},
        {"__leak", "leak"}, {"__wafer", "wafer"},
        // BJT single-letter corners → map to MOSFET-style dir names
        {"__t", "tt"}, {"__f", "ff"}, {"__s", "ss"},
    };
    for (auto [tag, dir] : corner_map) {
        if (auto p = stem.find(tag); p != std::string::npos) {
            corner = std::string(dir);
            break;
        }
    }

    auto dir = model_file.parent_path();
    for (int depth = 0; depth < 10 && !dir.empty() && dir != dir.parent_path();
         ++depth, dir = dir.parent_path()) {
        auto ngspice_dir = dir / "libs.tech" / "ngspice";
        if (!fs::is_directory(ngspice_dir)) continue;

        // Global parameter files
        auto params_dir = ngspice_dir / "parameters";
        if (fs::is_directory(params_dir)) {
            if (auto f = params_dir / "lod.spice"; fs::is_regular_file(f))
                params.push_back(f);
            if (auto f = params_dir / "invariant.spice"; fs::is_regular_file(f))
                params.push_back(f);
        }

        // Corner-specific nonfet params (parasitic junction multipliers)
        {
            auto f = ngspice_dir / "corners" / corner / "nonfet.spice";
            if (fs::is_regular_file(f))
                params.push_back(f);
        }

        // Parasitic diode/resistor model definitions
        auto parasitic_dir = ngspice_dir / "parasitics";
        if (fs::is_directory(parasitic_dir)) {
            for (const auto& entry : fs::directory_iterator(parasitic_dir)) {
                if (!entry.is_regular_file()) continue;
                if (entry.path().extension() == ".spice")
                    params.push_back(entry.path());
            }
        }

        break;
    }
    return params;
}

std::expected<std::string, std::string>
resolve_model_with_deps(const std::filesystem::path& model_file) {
    namespace fs = std::filesystem;
    std::unordered_set<std::string> visited;
    std::ostringstream out;

    // ---- PDK-wide parameter files (lod.spice, invariant.spice, …) ----
    for (const auto& pf : find_pdk_parameter_files(model_file)) {
        auto r = resolve_impl(pf, visited);
        if (!r) return r;
        out << *r;
    }

    // ---- Resolve sibling mismatch files first ----
    const auto model_dir  = model_file.parent_path();
    const auto model_stem = model_file.stem().string();
    auto base = model_stem;
    for (auto tag : {"__tt", "__ff", "__ss", "__sf", "__fs",
                     "__leak", "__wafer", "__tt_leak"}) {
        if (auto p = base.find(tag); p != std::string::npos) {
            base = base.substr(0, p);
            break;
        }
    }

    for (const auto& entry : fs::directory_iterator(model_dir)) {
        if (!entry.is_regular_file()) continue;
        const auto fn = entry.path().filename().string();
        if (fn.find(base) != 0) continue;
        if (fn.size() > base.size() && fn[base.size()] != '_') continue;
        if (fn.size() > base.size() + 1
            && fn[base.size()] == '_' && fn[base.size() + 1] != '_')
            continue;
        if (fn.find("mismatch") != std::string::npos) {
            auto r = resolve_impl(entry.path(), visited);
            if (!r) return r;
            out << *r;
        }
    }

    // ---- Then resolve the main model file ----
    auto r = resolve_impl(model_file, visited);
    if (!r) return r;
    out << *r;

    return out.str();
}

} // namespace gmid
