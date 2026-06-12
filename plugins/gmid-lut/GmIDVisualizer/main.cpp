// ---------------------------------------------------------------------------
// Standalone runner — exercises the library without a Schemify host.
//
// The same source files that build libGmIDVisualizer.so are compiled directly
// into this executable; no dynamic loading is required.  Use this to verify
// a PDK model file produces valid SVG plots before deploying to Schemify.
//
// Build (CMake):
//   cmake -B build && cmake --build build --target gmid_runner
//
// Usage:
//   gmid_runner --model-file <path> --kind <mosfet|bjt> --out-dir <dir>
// ---------------------------------------------------------------------------

#include "gmid/model_validator.hpp"
#include "gmid/plots.hpp"
#include "gmid/simulator.hpp"
#include "gmid/simulators/ngspice.hpp"
#include "gmid/simulators/xyce.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <string_view>

static void usage(std::string_view prog) {
  std::cerr
      << "usage: " << prog
      << " --model-file <path> --kind <mosfet|bjt> --out-dir <dir>\n"
         "                  [--device-name <name>]\n"
         "\n"
         "PDK sweep parameters (must match your process supply voltage):\n"
         "  --vgs-start <V>   VGS sweep start      (default 0.0)\n"
         "  --vgs-stop  <V>   VGS sweep stop        (default 1.8  — change for "
         "3.3V/5V PDK)\n"
         "  --vgs-steps <N>   VGS sweep points      (default 181)\n"
         "  --vds-start <V>   VDS sweep start        (default 0.05)\n"
         "  --vds-stop  <V>   VDS sweep stop         (default 1.8  — change "
         "for 3.3V/5V PDK)\n"
         "  --vds-steps <N>   VDS sweep points       (default 18)\n"
         "\n"
         "  --subckt          Force X-card instantiation (wrapper decks)\n"
         "\n"
         "Bias:\n"
         "  --vsb   <V>       Fixed source-bulk bias  (default 0.0)\n"
         "\n"
         "Output:\n"
         "  --emit-data <path> Dump raw sweep grid as CSV "
         "(vgs,vds,vbs,id[,ib])\n"
         "\n"
         "Device geometry:\n"
         "  --width  <um>     Gate width  in µm      (default 10.0)\n"
         "  --length <um>     Gate length in µm       (default 0.18)\n"
         "  --temp   <C>      Temperature in °C       (default 27.0)\n";
}

static double parse_double(const char *s, std::string_view flag) {
  try {
    return std::stod(s);
  } catch (...) {
    std::cerr << "error: " << flag << " requires a numeric value, got '" << s
              << "'\n";
    std::exit(1);
  }
}

static int parse_int(const char *s, std::string_view flag) {
  try {
    return std::stoi(s);
  } catch (...) {
    std::cerr << "error: " << flag << " requires an integer value, got '" << s
              << "'\n";
    std::exit(1);
  }
}

int main(int argc, char *argv[]) {
  std::filesystem::path model_file;
  std::filesystem::path out_dir;
  std::string_view kind_str;
  std::string device_name;
  std::string_view simulator_str = "ngspice";
  std::filesystem::path emit_data;
  bool force_subckt = false;

  gmid::SweepConfig cfg; // initialised with sensible defaults from the struct

  for (int i = 1; i < argc; ++i) {
    const std::string_view arg{argv[i]};

    // Required
    if (arg == "--model-file" && i + 1 < argc) {
      model_file = argv[++i];
      continue;
    }
    if (arg == "--kind" && i + 1 < argc) {
      kind_str = argv[++i];
      continue;
    }
    if (arg == "--out-dir" && i + 1 < argc) {
      out_dir = argv[++i];
      continue;
    }
    if (arg == "--device-name" && i + 1 < argc) {
      device_name = argv[++i];
      continue;
    }
    if (arg == "--simulator" && i + 1 < argc) {
      simulator_str = argv[++i];
      continue;
    }

    // VGS sweep
    if (arg == "--vgs-start" && i + 1 < argc) {
      cfg.vgs_start = parse_double(argv[++i], arg);
      continue;
    }
    if (arg == "--vgs-stop" && i + 1 < argc) {
      cfg.vgs_stop = parse_double(argv[++i], arg);
      continue;
    }
    if (arg == "--vgs-steps" && i + 1 < argc) {
      cfg.vgs_steps = parse_int(argv[++i], arg);
      continue;
    }

    // VDS sweep
    if (arg == "--vds-start" && i + 1 < argc) {
      cfg.vds_start = parse_double(argv[++i], arg);
      continue;
    }
    if (arg == "--vds-stop" && i + 1 < argc) {
      cfg.vds_stop = parse_double(argv[++i], arg);
      continue;
    }
    if (arg == "--vds-steps" && i + 1 < argc) {
      cfg.vds_steps = parse_int(argv[++i], arg);
      continue;
    }

    // Fixed source-bulk bias
    if (arg == "--vsb" && i + 1 < argc) {
      cfg.vbs_start = parse_double(argv[++i], arg);
      cfg.vbs_stop = cfg.vbs_start;
      continue;
    }

    // Raw data dump
    if (arg == "--emit-data" && i + 1 < argc) {
      emit_data = argv[++i];
      continue;
    }

    // Force subcircuit instantiation (X-card) — needed when the model file
    // is a wrapper deck (.lib corner select) that auto-detect can't scan.
    if (arg == "--subckt") {
      force_subckt = true;
      continue;
    }

    // Device geometry
    if (arg == "--width" && i + 1 < argc) {
      cfg.width_um = parse_double(argv[++i], arg);
      continue;
    }
    if (arg == "--length" && i + 1 < argc) {
      cfg.length_um = parse_double(argv[++i], arg);
      continue;
    }
    if (arg == "--temp" && i + 1 < argc) {
      cfg.temp_c = parse_double(argv[++i], arg);
      continue;
    }

    usage(argv[0]);
    return 1;
  }

  if (model_file.empty() || kind_str.empty() || out_dir.empty()) {
    usage(argv[0]);
    return 1;
  }

  // Validate model file (wrapper decks carry no .model/.subckt text, so
  // skip when the caller forces subckt mode and names the device).
  if (!(force_subckt && !device_name.empty())) {
    auto kind_result = gmid::validate_model_file(model_file);
    if (!kind_result) {
      std::cerr << "error: " << kind_result.error() << '\n';
      return 1;
    }
  }

  // Extract device name if not provided on command line
  if (device_name.empty()) {
    auto name_result = gmid::extract_device_name(model_file);
    if (!name_result) {
      std::cerr << "error: " << name_result.error() << '\n';
      return 1;
    }
    device_name = std::move(*name_result);
  }

  cfg.model_file = model_file;
  cfg.device_name = device_name;
  cfg.kind =
      (kind_str == "bjt") ? gmid::ModelKind::bjt : gmid::ModelKind::mosfet;
  cfg.work_dir = out_dir / "work";
  cfg.subcircuit = force_subckt || gmid::is_subcircuit(model_file, device_name);

  std::cerr << "info: device='" << device_name << "'"
            << (cfg.subcircuit ? " (subckt)" : " (model)")
            << "  VGS=[" << cfg.vgs_start << "," << cfg.vgs_stop << "]V"
            << "  VDS=[" << cfg.vds_start << "," << cfg.vds_stop << "]V"
            << "  W=" << cfg.width_um << "um  L=" << cfg.length_um << "um"
            << "  sim=" << simulator_str << "\n";

  std::expected<gmid::SweepResult, std::string> sweep;
  if (simulator_str == "xyce") {
    gmid::XyceBackend sim;
    sweep = sim.run(cfg);
  } else {
    gmid::NgspiceBackend sim;
    sweep = sim.run(cfg);
  }
  if (!sweep) {
    std::cerr << "error: " << sweep.error() << '\n';
    return 1;
  }
  std::cerr << "info: sweep complete — " << sweep->size() << " points\n";

  // Raw grid dump: gm/gds are left to the consumer (regular grid → finite
  // differences), matching the numeric extraction the plots use internally.
  if (!emit_data.empty()) {
    std::ofstream csv(emit_data);
    if (!csv) {
      std::cerr << "error: cannot write " << emit_data << '\n';
      return 1;
    }
    const bool is_mosfet = (cfg.kind == gmid::ModelKind::mosfet);
    csv << (is_mosfet ? "vgs,vds,vbs,id\n" : "vbe,vce,vbs,ic,ib\n");
    for (std::size_t i = 0; i < sweep->size(); ++i) {
      csv << sweep->vgs[i] << ',' << sweep->vds[i] << ',' << cfg.vbs_start
          << ',' << sweep->id[i];
      if (!is_mosfet)
        csv << ',' << sweep->vth[i]; // ib parked in vth slot (see parser)
      csv << '\n';
    }
    std::cout << "DATA:" << emit_data.string() << '\n';
  }

  auto paths = (cfg.kind == gmid::ModelKind::mosfet)
                   ? gmid::generate_mosfet_set(*sweep, cfg, out_dir)
                   : gmid::generate_bjt_set(*sweep, cfg, out_dir);

  for (const auto &p : paths)
    std::cout << "SVG:" << p.string() << '\n';

  return 0;
}
