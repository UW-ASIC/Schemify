# What is Schemify?

Schemify is an open-source schematic editor written in [Zig](https://ziglang.org/). It targets mixed-signal IC design workflows where analog schematics need to coexist with digital RTL blocks synthesized from Verilog.

## Goals

- **XSchem compatibility** — read and write `.sch` / `.sym` files directly so existing projects migrate without manual conversion.
- **Netlist generation** — produce correct ngspice and Xyce SPICE netlists from a schematic, with a comptime device dispatch system that carries no runtime vtable cost.
- **Digital co-simulation** — digital blocks embedded in a schematic are compiled with [Verilator](https://www.veripool.org/verilator/) or synthesized with [Yosys](https://yosyshq.net/yosys/) as part of the normal simulation flow.
- **Extensible** — a stable plugin interface (`PluginIF.zig`) lets you add devices, themes, and simulation back-ends without forking the repository.
- **Web deployment** — `zig build -Dbackend=web` ships the full editor running in a browser via HTML5 Canvas.

## Architecture Overview

```
src/
  main.zig          ← application entry point (only the 4 dvui callbacks)
  _dvuiIF.zig       ← dvui contract wiring
  state.zig         ← process-lifetime AppState (config, open schematics, history)
  command.zig       ← Command union + undo/redo History
  PluginIF.zig      ← stable public API for plugins
  toml.zig          ← Config.toml parser
  core/
    FileIO.zig      ← schematic I/O (XSchem ↔ CHN conversion)
    devices/        ← comptime device system + netlist emission
    xschem/         ← XSchem reader / writer / types
    chn/            ← CHN reader / writer / types
  gui/              ← dvui rendering layer
```

## Prior Work

Schemify builds on ideas from [XSchem](https://xschem.sourceforge.io/) by Stefan Schippers and is designed to integrate naturally with the [SKY130](https://github.com/google/skywater-pdk) and GF180 open PDKs.

## Design Principles

**Data-oriented design.** Schemify uses `std.MultiArrayList` (Structure-of-Arrays) for schematic data — iterating all X coordinates of wires touches contiguous memory, not a stride through full structs.

**Command queue pattern.** All mutations go through a `Command` union. Undo records command inverses, not full snapshots. The command queue drains once per frame — clean separation between input, mutation, and render.

**Comptime device dispatch.** The device system uses Zig's comptime to generate device-specific netlist emission with zero runtime vtable overhead.

**Dual backend.** The same source compiles to a native binary (raylib/OpenGL) or a WASM module (HTML5 Canvas). The backend is a compile-time switch.
