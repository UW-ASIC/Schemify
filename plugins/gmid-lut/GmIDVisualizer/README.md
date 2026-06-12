# GmIDVisualizer

MOSFET and BJT gm/Id characterisation tool. Runs DC sweeps via ngspice or Xyce, then generates SVG plots of the standard analog design figures of merit.

Produces 6 plots per device:

**MOSFET:** gm/Id vs Jd, gm, gds, intrinsic gain; VGS vs gm/Id, Id
**BJT:** gm/Ic vs Jc, gm, intrinsic gain, beta; VBE vs gm/Ic, Ic

## Building

Requires C++23 (clang 19+ or GCC 14+), CMake 3.25+, and ninja.

```sh
nix develop            # or install deps manually
cmake -B build -G Ninja
cmake --build build
```

This produces two targets:

- **`libGmIDVisualizer.so`** — shared library (Schemify plugin or link into your own app)
- **`gmid_runner`** — standalone CLI

## CLI usage

```sh
./build/gmid_runner \
  --model-file path/to/pdk_model.lib \
  --kind mosfet \
  --out-dir ./output
```

All flags:

| Flag | Default | Description |
|------|---------|-------------|
| `--model-file` | *required* | Path to SPICE model file |
| `--kind` | *required* | `mosfet` or `bjt` |
| `--out-dir` | *required* | Directory for SVG output |
| `--device-name` | auto-detect | Override `.model` name extraction |
| `--vgs-start` | 0.0 | VGS sweep start (V) |
| `--vgs-stop` | 1.8 | VGS sweep stop (V) — adjust for your PDK |
| `--vds-start` | 0.05 | VDS sweep start (V) |
| `--vds-stop` | 1.8 | VDS sweep stop (V) |
| `--vgs-steps` | 181 | VGS sweep points |
| `--vds-steps` | 18 | VDS sweep points |
| `--width` | 10.0 | Gate width (um) |
| `--length` | 0.18 | Gate length (um) |
| `--temp` | 27.0 | Temperature (C) |

## Library usage (C++)

```cpp
#include <gmid/lib.hpp>

gmid::SweepConfig cfg;
cfg.model_file  = "sky130.lib";
cfg.device_name = "sky130_fd_pr__nfet_01v8";
cfg.kind        = gmid::ModelKind::mosfet;
cfg.vgs_stop    = 1.8;
cfg.vds_stop    = 1.8;
cfg.work_dir    = "/tmp/gmid_work";

auto result = gmid::characterise(cfg, "/tmp/gmid_out");
if (result.ok()) {
    for (auto& plot : result.plots) {
        // plot.svg  — path to SVG file
        // plot.lut  — vector of {x, y} data points
    }
}
```

## C FFI

A C-linkage API is provided for use from Python, Zig, Rust, etc:

```c
GmidCharResult* r = gmid_characterise(
    "model.lib", NULL, "mosfet", "./out", NULL,
    0.0, 1.8, 181,    /* vgs */
    0.05, 1.8, 18,    /* vds */
    10.0, 0.18, 27.0  /* W, L, T */
);
/* use r->plots[i].svg_path, r->plots[i].lut ... */
gmid_free_result(r);
```

## Simulator backends

- **ngspice** (default) — must be on `$PATH`
- **Xyce** — used when available; accesses internal OP parameters directly

## License

See repository for license details.
