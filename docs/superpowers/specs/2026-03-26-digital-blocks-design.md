# Digital Blocks in .chn: Behavioral vs Synthesized Models

> **Date:** 2026-03-26
> **Status:** Approved design
> **Approach:** Bottom-up (data model -> format -> netlist -> HDL -> synthesis)
> **Source:** `src_new/core/TODO.md`

---

## 1. Context

A digital block (counter, FSM, DAC decoder) lives inside an analog schematic. At simulation time we want the fast behavioral model. At layout time we want the synthesized gate-level netlist. The `.chn` format needs to express both modes, auto-generate symbols from HDL source, and let the netlister pick the right model.

### Already Implemented

- `DigitalConfig`, `HdlLanguage`, `BehavioralModel`, `SynthesizedModel` types in `Schemify.zig`
- `digital: ?DigitalConfig` field on the `Schemify` struct
- Pin `width: u16` field with bus expansion in netlist emission
- Reader parses the full `digital:` section (language, behavioral inline/file, synthesized, supply_map)
- Writer serializes the `digital:` section
- Basic `emitDigitalBlock()` in `Netlist.zig` for Verilog, XSPICE, Xyce, VHDL (behavioral only)

### Remaining Work

1. Format extensions (`generate` construct for bus nets)
2. Netlist mode switch (`sim` vs `layout`) + supply pin injection
3. Yosys JSON netlist parser (for layout mode gate-level expansion)
4. HDL port parser (Verilog/VHDL) + symbol sync
5. Synthesis integration (yosys invocation)
6. Validation additions

---

## 2. Format Extensions

### 2.1 `generate` Construct

Syntactic sugar for bus-level net connections inside SCHEMATIC/TESTBENCH:

```
generate bit in 0..7:
  nets:
    count_{bit} -> XCNT.COUNT_{bit}, R_LADDER.tap_{bit}
```

**Expansion strategy:** Expand at parse time into flat nets. The `generate` construct is syntactic sugar only. Writer always writes flat nets (no round-trip of generate syntax). This keeps the data model simple and avoids carrying template state through the pipeline.

**Types local to `Reader.zig`** (not stored on the `Schemify` struct — expanded at parse time):

```zig
const Generate = struct {
    var_name: []const u8,       // "bit"
    range_start: i32,           // 0
    range_end: i32,             // 7
    net_templates: []const NetTemplate,
};

const NetTemplate = struct {
    name_template: []const u8,          // "count_{bit}"
    conn_templates: []const []const u8, // ["XCNT.COUNT_{bit}", "R_LADDER.tap_{bit}"]
};
```

These types are used only during parsing. The Reader expands them into concrete net/conn entries immediately and discards the templates.

**Reader changes:** Parse `generate <var> in <start>..<end>:` at indent level 1 inside SCHEMATIC/TESTBENCH. For each value in the range, substitute `{var}` in the net name and connection templates, then append the resulting nets to the flat net list.

### 2.2 Bus Pins

Already implemented. `Pin.width: u16 = 1`. Writer emits `width=N` for N > 1. Netlist emitter expands bus pins in `.subckt` headers.

---

## 3. Netlist Mode Switch + Supply Pin Injection

### 3.1 `NetlistMode` Enum

Add to `SpiceIF.zig`:

```zig
pub const NetlistMode = enum { sim, layout };
```

### 3.2 `emitSpice` Signature Change

```zig
pub fn emitSpice(
    self: *const Schemify,
    gpa: Allocator,
    backend: Backend,
    pdk: ?*const Devices.Pdk,
    mode: NetlistMode,  // NEW — default .sim at call sites
) ![]u8
```

All existing call sites pass `.sim` for backwards compatibility.

### 3.3 Mode-Aware `emitDigitalBlock`

- **`mode == .sim`**: Current behavior unchanged. Emit behavioral model (Verilog comment/YDIG/XSPICE/`.include` depending on backend + language).
- **`mode == .layout`**: Read `digital.synthesized.source` path. Parse the yosys JSON netlist (Section 4). Expand into gate-level `.subckt` with standard cell instantiations. If no synthesized source exists, emit `* ERROR: no synthesized model for <name>` and log a warning.

### 3.4 Supply Pin Injection (Layout Mode Only)

Synthesized netlists need VDD/VSS that behavioral models don't declare.

Logic:
1. Check `digital.synthesized.supply_map` — if present, use explicit mapping (e.g., `VPWR -> VDD`, `VGND -> VSS`)
2. If absent, auto-detect supply pins from the yosys module ports (names matching VDD/VSS/VPWR/VGND/VNB/VPB)
3. Add the supply pins to the `.subckt` port list in the generated SPICE. The *parent* schematic handles binding those ports to actual supply nets when it instantiates this block.
4. If `supply_map` is absent and no recognizable supply pins are found in the yosys module, emit: `* WARNING: Synthesized block X may need VDD/VSS — verify parent connections`

Generated SPICE (layout mode):

```spice
.subckt counter_8bit CLK EN RST COUNT_0 ... COUNT_7 CARRY VDD VSS
X_inv_0 net_1 net_2 VDD VSS sky130_fd_sc_hd__inv_2
X_nand_0 net_3 net_4 net_5 VDD VSS sky130_fd_sc_hd__nand2_1
X_dff_0 CLK net_5 COUNT_0 VDD VSS sky130_fd_sc_hd__dfxtp_1
...
.ends
```

### 3.5 CLI Integration

`commands/Netlist.zig` gains `--mode sim|layout` flag (default: `sim`).

---

## 4. Yosys JSON Netlist Parser

### 4.1 New File: `src_new/core/YosysJson.zig`

Parses yosys's JSON output format into an in-memory representation.

Yosys JSON structure:

```json
{
  "modules": {
    "counter_8bit": {
      "ports": { "CLK": { "direction": "input", "bits": [2] }, ... },
      "cells": {
        "inv_0": {
          "type": "sky130_fd_sc_hd__inv_2",
          "connections": { "A": [3], "Y": [4] }
        }
      },
      "netnames": { "net_1": { "bits": [3] }, ... }
    }
  }
}
```

Data types:

```zig
pub const Port = struct {
    name: []const u8,
    direction: enum { input, output, inout },
    bits: []const u32,
};

pub const CellConn = struct {
    pin: []const u8,
    bits: []const u32,
};

pub const Cell = struct {
    name: []const u8,
    cell_type: []const u8,
    connections: []const CellConn,
};

pub const NetName = struct {
    name: []const u8,
    bits: []const u32,
};

pub const YosysModule = struct {
    name: []const u8,
    ports: []const Port,
    cells: []const Cell,
    net_names: []const NetName,
};

pub fn parse(json_source: []const u8, alloc: Allocator) !YosysModule
```

### 4.2 Gate-Level SPICE Emission

Given a `YosysModule`, emit a `.subckt` body:

1. Map yosys bit numbers to net names using `netnames`
2. For each cell, emit `X<cell_name> <pin_nets...> <cell_type>`
3. Port bits map to the `.subckt` header pin list

---

## 5. HDL Port Parser

### 5.1 New File: `src_new/core/HdlParser.zig`

Pure-Zig targeted parser for Verilog and VHDL port extraction. Not a full language parser — only extracts what's needed for symbol generation.

```zig
pub const HdlPin = struct {
    name: []const u8,
    direction: PinDir,
    width: u16,                  // 1 for scalar, N for [N-1:0]
    param_width: ?[]const u8,   // "{WIDTH}" if parameterized
};

pub const HdlParam = struct {
    name: []const u8,
    default_value: ?[]const u8,
};

pub const HdlModule = struct {
    name: []const u8,
    pins: []const HdlPin,
    params: []const HdlParam,
};

pub fn parseVerilog(source: []const u8, top_module: ?[]const u8, alloc: Allocator) !HdlModule
pub fn parseVhdl(source: []const u8, top_module: ?[]const u8, alloc: Allocator) !HdlModule
```

### 5.2 Verilog Parsing Strategy

Line-by-line scan within `module`...`endmodule`:

1. Strip comments (`//` to EOL, `/* ... */` blocks)
2. Find `module <name>` (match `top_module` if specified, else first module)
3. **ANSI-style:** `module foo(input wire [7:0] data, output reg result);` — parse port list inline
4. **Non-ANSI:** `module foo(data, result);` followed by `input [7:0] data;` declarations
5. Extract `parameter` declarations for parameterized widths
6. Stop at `endmodule`

Direction mapping:

| HDL declaration | `.chn` direction | `.chn` width |
|---|---|---|
| `input` / `input wire` | `in` | from `[N:0]` -> N+1, or 1 |
| `output` / `output reg` | `out` | same |
| `inout` | `inout` | same |

Edge cases:
- `[WIDTH-1:0]` -> `param_width = "{WIDTH}"`, `width = 0`
- Multiple modules per file -> `top_module` disambiguates
- `generate` inside module -> ignored (only top-level ports)

### 5.3 VHDL Parsing Strategy

Scan for `entity <name> is` ... `port(` ... `);` ... `end entity;`:

| VHDL declaration | `.chn` direction | `.chn` width |
|---|---|---|
| `in std_logic` | `in` | 1 |
| `out std_logic_vector(7 downto 0)` | `out` | 8 |
| `inout std_logic` | `inout` | 1 |

### 5.4 `syncSymbolFromHdl`

Method on `Schemify`:

```zig
pub const SyncReport = struct {
    pins_added: []const HdlPin,
    pins_removed: []const []const u8,
    pins_modified: []const PinChange,
    symbol_updated: bool,
};

pub const PinChange = struct {
    name: []const u8,
    change: []const u8,  // "width 4 -> 8", "direction in -> out"
};

pub fn syncSymbolFromHdl(self: *Schemify) !SyncReport  // uses self.alloc()
```

1. Read `self.digital.behavioral.source` (inline or file)
2. Parse with `HdlParser.parseVerilog` or `parseVhdl` based on `self.digital.language`
3. Diff against `self.pins`
4. Update `self.pins` to match
5. Return report of changes

### 5.5 `generateDigitalSymbolDrawing`

Auto-generates `drawing:` geometry for a digital block based on its pin list:

- Bounding rect sized to fit all pins
- Input pins on left edge, spaced at 20-unit intervals
- Output pins on right edge, spaced at 20-unit intervals
- Bus pins drawn with triple-line stub
- Clock pins (name matches `CLK`/`clk`/`clock`) get triangle marker
- `@name` text centered in the box

Writes into `self.lines`, `self.rects`, `self.texts`, updates pin x/y.

### 5.6 `validateHdlPinMatch`

Read-only comparison — SYMBOL pins vs HDL source. Returns mismatches without modifying anything.

---

## 6. Synthesis Integration

### 6.1 New File: `src_new/core/Synthesis.zig`

```zig
pub const SynthOptions = struct {
    liberty_path: []const u8,
    mapping: []const u8,
    output_json: ?[]const u8,
    flatten: bool = true,
};

pub const SynthReport = struct {
    output_path: []const u8,
    cell_count: u32,
    area_estimate: ?f64,
    critical_path_ns: ?f64,
    success: bool,
    log: []const u8,
};

pub fn runSynthesis(self: *Schemify, alloc: Allocator, options: SynthOptions) !SynthReport
```

Steps:
1. Write behavioral source to a temp file (if inline)
2. Generate yosys TCL script: `read_verilog <file>; synth -top <module>; dfflibmap -liberty <lib>; abc -liberty <lib>; stat; write_json <output>`
3. Spawn `yosys` as child process via `std.process.Child`
4. Capture stdout/stderr
5. On success, update `self.digital.synthesized.source` to point to output JSON
6. Parse yosys `stat` output for cell count and area estimate
7. Return report

Errors:
- yosys not installed -> `error.YosysNotFound`
- Synthesis failure -> `SynthReport.success = false`, `.log` contains yosys output
- XSPICE/xyce_digital languages -> `error.NotSynthesizable`

### 6.2 `validateSynthesized`

```zig
pub const ValidationReport = struct {
    ports_match: bool,
    missing_ports: []const []const u8,
    extra_ports: []const []const u8,
    supply_pins: []const []const u8,
};

pub fn validateSynthesized(self: *const Schemify, alloc: Allocator) !ValidationReport
```

Loads synthesized JSON, extracts port list, compares against SYMBOL pins. Supply pins in the synth output that aren't in the behavioral model are classified as `supply_pins` (expected, not errors).

### 6.3 `getSynthesizedCellList`

```zig
pub const CellInfo = struct {
    cell_type: []const u8,
    count: u32,
};

pub fn getSynthesizedCellList(self: *const Schemify, alloc: Allocator) ![]const CellInfo
```

Loads yosys JSON, counts cell types. Useful for area estimation and LVS.

---

## 7. Validation Additions

Extend the existing validation path with three new diagnostics:

| Diagnostic | Level | Condition |
|---|---|---|
| `hdl_pin_mismatch` | warning | SYMBOL pins differ from HDL source ports |
| `no_behavioral_source` | error | `digital:` section present but no behavioral model |
| `no_synthesized_source` | warning | Digital block in a component `.chn` with no synth model (will fail in layout mode) |

`addInstance` validation: when instantiating a `.chn` that has a `digital:` section, verify bus pin widths match between the instantiation and the symbol definition.

---

## 8. Implementation Phases

Bottom-up order, each phase compiles and tests independently:

### Phase 1: Format Extensions
- Add `Generate`/`NetTemplate` types local to `Reader.zig`
- Parse `generate` blocks in `Reader.zig`, expand to flat nets at parse time
- Tests: round-trip a `.chn` with generate blocks

### Phase 2: Netlist Mode Switch
- Add `NetlistMode` to `SpiceIF.zig`
- Plumb through `emitSpice` signature (all call sites get `.sim`)
- Mode-aware `emitDigitalBlock` (sim path unchanged, layout path stubs error)
- CLI `--mode` flag in `commands/Netlist.zig`
- Tests: existing tests pass with `.sim`, layout mode errors gracefully without synth source

### Phase 3: Yosys JSON Parser
- New `YosysJson.zig` with `parse()` function
- Gate-level SPICE emission from parsed module
- Supply pin detection
- Tests: parse a sample yosys JSON, verify SPICE output

### Phase 4: Layout Mode Integration
- Wire `YosysJson` into `emitDigitalBlock` layout path
- Supply pin injection logic
- Tests: end-to-end `.chn` with digital section -> layout mode SPICE

### Phase 5: HDL Port Parser
- New `HdlParser.zig` with `parseVerilog()` and `parseVhdl()`
- Tests: parse various Verilog/VHDL port styles

### Phase 6: Symbol Sync + Drawing Generation
- `syncSymbolFromHdl` on `Schemify`
- `generateDigitalSymbolDrawing`
- `validateHdlPinMatch`
- Tests: sync from inline Verilog, verify pin list matches

### Phase 7: Synthesis Integration
- New `Synthesis.zig` with `runSynthesis()`, `validateSynthesized()`, `getSynthesizedCellList()`
- Tests: mock yosys invocation, verify report parsing

### Phase 8: Validation Additions
- Add three diagnostics to validation path
- Bus pin width checking in `addInstance`
- Tests: trigger each diagnostic

---

## 9. New Files

| File | Purpose |
|---|---|
| `src_new/core/HdlParser.zig` | Verilog/VHDL port extraction |
| `src_new/core/YosysJson.zig` | Yosys JSON netlist parser |
| `src_new/core/Synthesis.zig` | Yosys invocation, validation, cell listing |

## 10. Modified Files

| File | Changes |
|---|---|
| `src_new/core/Schemify.zig` | `syncSymbolFromHdl`, `generateDigitalSymbolDrawing`, `validateHdlPinMatch` methods |
| `src_new/core/Reader.zig` | Parse `generate` blocks, expand to flat nets |
| `src_new/core/Netlist.zig` | `NetlistMode` parameter, mode-aware `emitDigitalBlock`, supply pin injection |
| `src_new/core/SpiceIF.zig` | `NetlistMode` enum |
| `src_new/commands/Netlist.zig` | `--mode sim\|layout` CLI flag |
