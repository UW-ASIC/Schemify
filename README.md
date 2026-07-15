# Schemify

Schematic capture for analog/mixed-signal circuit design, with a built-in
simulation flow, waveform viewer, MCP automation server, and a subprocess
plugin system.

```
schemify                            # GUI
schemify cli [opts] CMD..           # dispatch commands headless (--headful for live GUI)
schemify mcp [opts]                 # JSON-RPC server on stdio (--headful mirrors a GUI)
schemify export-spice --file f.chn  # netlist a schematic (--format spice|pyspice|ir)
```

All three entry points share one command enum and one wire format:
externally-tagged JSON (`"ZoomIn"`, `{"PlaceDevice": {...}}`).

## Features

- **Schematic editor** — `.chn` documents, `.chn_prim` primitive symbols
  (resistors, sources, MOS, Verilog-A blocks, ...), wires, labels, undo/redo,
  multi-tab.
- **Netlisting** — circuit IR shared with
  [PySpice](https://github.com/OmarSiwy/PySpice) (JSON contract), emitted as
  PySpice Python or plain SPICE.
- **Simulation** — PySpice renders the netlist, analysis directives from the
  SPICE code editor are spliced in, ngspice/Xyce run in batch mode, and the
  rawfile opens in the waveform viewer.
- **Verilog-A / OSDI** — `.va` sources on a `verilog_a_block` are compiled
  with openvaf at sim time (mtime-cached, via PySpice `veriloga()`); the
  instance netlists as an ngspice OSDI N-card with an auto `.model` binding.
- **Verilog blocks** — digital co-simulation (iverilog + ngspice `d_cosim`)
  or Yosys gate-level synthesis.
- **Waveform viewer** — `.raw` parsing, derived traces via math expressions,
  cursors with interpolated readouts.
- **Optimizer** — ask-tell parameter search (random, Nelder–Mead) with
  bounded params and min/max/approach objectives; drive it over MCP to size
  devices against simulated measurements.
- **SPICE import** — netlist → schematic pipeline (parse → recognize →
  place → route).
- **Plugins** — subprocess plugins speaking JSON-RPC 2.0 over stdio, with a
  marketplace for fetching/installing them. See `docs/plugins/`.

## Building

The nix devshell provides the toolchain, the bundled PySpice module, and
ngspice:

```sh
nix develop
cargo build
cargo test --workspace
```

Building outside the devshell works but disables simulation support
(`PYSPICE_MODULE_DIR` unset) and skips the tests that need it.

Runtime tools looked up on `$PATH` as needed: `ngspice` (or `Xyce`),
`openvaf` (Verilog-A), `iverilog`/`yosys` (Verilog blocks).

## MCP automation

`schemify mcp` exposes the whole app over line-delimited JSON-RPC:
`session/dispatch` for any editor command, plus queries
(`query/netlist`, `query/instances`, `query/wave_data`, ...) and
optimizer methods (`optimizer/new`, `optimizer/suggest`,
`optimizer/report`, ...).

Example — size R2 of a voltage divider until V(out) = 2 V:

```jsonc
{"method": "session/dispatch", "params": {"command": {"PlaceDevice": {
    "symbol_path": "resistor", "name": "R2", "x": 100, "y": 70,
    "rotation": 0, "flip": false}}}}
{"method": "optimizer/new",           "params": {"name": "divider-sizing"}}
{"method": "optimizer/add_param",     "params": {"id": 0, "name": "r2",
    "min": "1k", "max": "20k", "init": "5k"}}
{"method": "optimizer/add_objective", "params": {"id": 0, "name": "vout",
    "target": 2.0}}
{"method": "optimizer/set_algorithm", "params": {"id": 0,
    "algorithm": "nelder-mead"}}
// loop: optimizer/suggest -> SetInstanceProp -> RunSim ->
//       query/wave_data -> optimizer/report
```

## Workspace layout

| Crate                 | Purpose                                                                       |
| --------------------- | ----------------------------------------------------------------------------- |
| `crates/schematic`    | Domain model: SoA schematic, devices, `.chn`/`.chn_prim` formats, primitives, connectivity |
| `crates/editor`       | Editor use-cases: `App` state, `Command` dispatch, undo, config, JSON marshaling |
| `crates/sim`          | Circuit IR, SPICE/PySpice codegen, PDK manifests, simulator runner            |
| `crates/wave`         | `.raw` parsing, columnar waveform data, trace expressions                     |
| `crates/optimizer`    | Ask-tell optimizer (random, Nelder–Mead)                                      |
| `crates/net2schem`    | SPICE netlist → schematic (place & route)                                     |
| `crates/plugin-api`   | Plugin wire protocol + Rust guest SDK (all a plugin binary needs)             |
| `crates/plugin-host`  | Plugin manager (subprocess JSON-RPC) + marketplace client                     |
| `crates/gui`          | GUI (eframe/egui)                                                             |
| `crates/agent`        | Headless agent driver (claude-code/codex) + MCP server agents drive the app with |
| `plugins/`            | First-party plugins (theme-registry, pdk-switcher, gmid-lut, pdk-mapper) + marketplace `index.json` |

## Backend Selection for Rendering:

```
  ┌──────────────┬───────────────┬──────────────────────────────────────────┐
  │   Platform   │   Renderer    │                   Why                    │
  ├──────────────┼───────────────┼──────────────────────────────────────────┤
  │ macOS        │ wgpu (Metal)  │ native, best perf                        │
  ├──────────────┼───────────────┼──────────────────────────────────────────┤
  │ Windows      │ wgpu (DX12)   │ native, best perf                        │
  ├──────────────┼───────────────┼──────────────────────────────────────────┤
  │ Linux native │ wgpu (Vulkan) │ native, best perf                        │
  ├──────────────┼───────────────┼──────────────────────────────────────────┤
  │ WSL          │ glow (OpenGL) │ auto-detected, wgpu can't create surface │
  ├──────────────┼───────────────┼──────────────────────────────────────────┤
  │ Any          │ override      │ SCHEMIFY_RENDERER=glow or =wgpu          │
  └──────────────┴───────────────┴──────────────────────────────────────────┘
```
