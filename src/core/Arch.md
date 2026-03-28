# Core Module Architecture

This document describes the runtime architecture of `src/core`, with focus on data layout, control flow, and module responsibilities.

## 1) Module Boundaries

- `Schemify.zig`
  - Canonical in-memory model.
  - Owns all schematic/symbol data (instances, pins, wires, props, nets).
  - Provides lifecycle, builders, validation, HDL sync, and net resolution.

- `Reader.zig`
  - Parses `.chn` / `.chn_prim` / `.chn_testbench` text into `Schemify`.
  - Uses section/subsection state-machine parsing.
  - Stores parsed connectivity in `conns`, then repacks to per-instance contiguous ranges.

- `Writer.zig`
  - Serializes `Schemify` back to `.chn` family formats.
  - Emits symbol, schematic, grouped instances, nets, digital config, and annotations.

- `Netlist.zig`
  - Converts `Schemify` to SPICE text.
  - Handles include/model/code blocks, instance emission, subckt wrapping, analyses/measures, and digital backends.

- `Devices.zig`
  - Device taxonomy (`DeviceKind`) and PDK lookup/emission integration.
  - Bridges builtin devices and PDK-resolved cells to SPICE component emission.

- `SpiceIF.zig`
  - SPICE backend abstraction and low-level component formatting.

- `HdlParser.zig`
  - Verilog/VHDL port parsing used by validation/sync paths.

- `YosysJson.zig`
  - Parser/emitter for synthesized gate-level JSON in digital layout mode.

- `Synthesis.zig`
  - Yosys synthesis invocation utilities (independent helper layer).

## 2) Core Data Model (Schemify)

`Schemify` is arena-backed and primarily data-oriented:

- Geometry uses `std.MultiArrayList` (`lines`, `rects`, `arcs`, `circles`, `wires`, `texts`, `pins`, `instances`).
- Variable-length aggregates use `ArrayListUnmanaged` (`props`, `conns`, `nets`, `net_conns`, `sym_props`, `sym_data`, `globals`).
- `instances` reference slices of shared `props`/`conns` via `prop_start/prop_count` and `conn_start/conn_count`.

Key invariant: after parsing or net-resolution passes, each instance connection range is contiguous in `conns`.

## 3) Parse -> Model Flow

1. `Reader.readCHN` initializes `Schemify` and dispatches `parseCHNImpl`.
2. Header sets `stype` (`primitive`, `component`, `testbench`).
3. State machine parses top-level sections:
   - `SYMBOL`: pins, params, drawing, metadata.
   - `SCHEMATIC`: instances, nets, wires, digital config, code/annotations.
   - `TESTBENCH`: includes, analyses, measures, plus schematic content.
4. Nets are first collected as tagged `(inst_idx, pin, net)` rows.
5. `repackTaggedConns` compacts tagged rows into per-instance contiguous `conns` ranges.

## 4) Net Resolution Flow

`Schemify.resolveNets` computes resolved logical nets from geometric/topological connectivity:

1. Reset derived net state (`nets`, `net_conns`, `conns` connection ranges).
2. Build union-find sets from wire endpoints.
3. Merge T-junctions (wire endpoint touching wire interior).
4. Register instance pin points (with transform by `rot/flip` + origin).
5. Unite pin points with touching wires (tolerance-based).
6. Apply wire label naming with deterministic rank:
   - semantic names > `0` > auto names (`netN`).
7. Auto-name unnamed roots while skipping collisions with existing `netN` labels.
8. Build final `nets`, then `net_conns` and instance-level `conns`.

## 5) Model -> SPICE Flow

`Netlist.emitSpice` emits in ordered stages:

1. Netlist header and `.include/.lib` collection.
2. Optional `.subckt` signature (non-testbench).
3. Optional PDK preamble includes.
4. Header code blocks (`code/param` with `place=header`).
5. Instance emission pipeline (first-match wins):
   - precomputed `spice_line`
   - `spice_format` template expansion
   - PDK primitive/component emission
   - builtin `DeviceKind` emission
   - fallback `X...` subcircuit call
6. Body code blocks, digital block expansion, `.ends`, inline subckts.
7. Symbol-level SPICE defs, `.GLOBAL`, model blocks, analyses/measures, end code blocks, `.end`.

## 6) Digital Data/Control Paths

Digital config lives under `Schemify.digital`:

- Behavioral path (`sim` mode): inline/file HDL references and backend-specific directives.
- Synthesized path (`layout` mode): Yosys JSON parse + gate-level SPICE emission.
- Validation/sync:
  - `validateDigital` checks config consistency and optional pin compatibility.
  - `syncSymbolFromHdl` updates symbol pins from parsed HDL ports.
  - `validateHdlPinMatch` performs read-only mismatch detection.

## 7) Compatibility and Safety Notes

- Public model interfaces remain in `Schemify` and are intended to be stable for callers.
- Reader/Writer are tolerant of partial/legacy data and skip malformed rows conservatively.
- Netlist emission prioritizes preserving existing behavior paths before fallback generation.
