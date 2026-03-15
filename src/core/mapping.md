XSchem Library:

```zig
const device_kind_map = std.StaticStringMap(sch.DeviceKind).initComptime(.{
    // ── Passives ──
    .{ "res.sym", .resistor },            .{ "res3.sym", .resistor },                 .{ "res_ac.sym", .resistor },
    .{ "var_res.sym", .resistor },        .{ "capa.sym", .capacitor },                .{ "capa-2.sym", .capacitor },
    .{ "ind.sym", .inductor },

    // ── Semiconductors ──
               .{ "diode.sym", .diode },                   .{ "zener.sym", .diode },
    .{ "nmos.sym", .mosfet },             .{ "pmos.sym", .mosfet },                   .{ "nmos3.sym", .mosfet },
    .{ "pmos3.sym", .mosfet },            .{ "nmos4.sym", .mosfet },                  .{ "pmos4.sym", .mosfet },
    .{ "nmos-sub.sym", .mosfet },         .{ "pmos-sub.sym", .mosfet },               .{ "nmoshv4.sym", .mosfet },
    .{ "pmoshv4.sym", .mosfet },          .{ "npn.sym", .bjt },                       .{ "pnp.sym", .bjt },
    .{ "njfet.sym", .jfet },              .{ "pjfet.sym", .jfet },                    .{ "mesfet.sym", .mesfet },

    // ── Sources ──
    .{ "vsource.sym", .vsource },         .{ "vsource_arith.sym", .vsource },         .{ "vsource_pwl.sym", .vsource },
    .{ "isource.sym", .isource },         .{ "isource_arith.sym", .isource },         .{ "isource_pwl.sym", .isource },
    .{ "ammeter.sym", .ammeter },         .{ "bsource.sym", .behavioral },            .{ "asrc.sym", .behavioral },
    .{ "behavioral.sym", .behavioral },

    // ── Specialized ──
      .{ "vcvs.sym", .vcvs },                     .{ "vccs.sym", .vccs },
    .{ "ccvs.sym", .ccvs },               .{ "cccs.sym", .cccs },                     .{ "k.sym", .coupling },
    .{ "tline.sym", .tline },             .{ "tline_lossy.sym", .tline_lossy },       .{ "switch.sym", .vswitch },
    .{ "vswitch.sym", .vswitch },         .{ "sw.sym", .vswitch },                    .{ "switch_ngspice.sym", .vswitch },
    .{ "switch_v_xyce.sym", .vswitch },   .{ "iswitch.sym", .iswitch },               .{ "csw.sym", .iswitch },

    // ── Non-electrical / UI ──
    .{ "gnd.sym", .gnd },                 .{ "vdd.sym", .vdd },                       .{ "lab_pin.sym", .lab_pin },
    .{ "lab_wire.sym", .lab_pin },        .{ "ipin.sym", .lab_pin },                  .{ "opin.sym", .lab_pin },
    .{ "iopin.sym", .lab_pin },           .{ "code.sym", .code },                     .{ "code_shown.sym", .code },
    .{ "simulator_commands.sym", .code }, .{ "simulator_commands_shown.sym", .code }, .{ "graph.sym", .graph },
    .{ "launcher.sym", .graph },          .{ "noconn.sym", .graph },                  .{ "title.sym", .graph },
    .{ "ngspice_probe.sym", .graph },     .{ "verilog_timescale.sym", .graph },       .{ "lab_show.sym", .graph },
});
```

### Minimalist Device Philosophy
To keep the core system lean, we classify XSchem symbols into three tiers:

1.  **Atomic Primitives**: Direct 1:1 mappings to fundamental SPICE types.
2.  **Primitive Decorators**: Symbols that add a parameter to an atomic kind (e.g., `res_ac` is just a `resistor` + `ac` property).
3.  **Composite Components**: Devices that require multiple primitives or specialized models. These map to `.subckt`.

---

### Detailed Device Mapping

| XSchem Categories | Symbols | Mapping | NGSpice Component |
| :--- | :--- | :--- | :--- |
| **Resistors** | `res`, `res_ac` | `.resistor` | `R<name> n1 n2 <value> [ac=...]` |
| | `res3`, `var_res` | `.subckt` | `X<name> n1 n2 n3 <model>` |
| **Capacitors** | `capa`, `capa-2` | `.capacitor` | `C<name> n1 n2 <value>` |
| **Diodes** | `diode`, `zener` | `.diode` | `D<name> n1 n2 <model>` |
| **MOSFETs** | `nmos/pmos` (3/4 pin) | `.mosfet` | `M<name> d g s b <model> w=... l=...` |
| | `nmos-sub` | `.mosfet` | MOSFET + implicit substrate tie-off. |
| **Switches** | `switch` | `.vswitch` | Voltage-controlled resistor (VCR). |
| | `switch_v_xyce`| `.vswitch` | Standard `S` device (V-controlled). |
| | `iswitch`, `csw`| `.iswitch` | Standard `W` device (I-controlled). |
| **Pins / Labels** | `ipin`, `opin`, `iopin`| `.lab_pin` | **None** (Net labels only). |
| **UI / Meta** | `code`, `simulator`| `.code` | Literal text injection. |
| | `graph`, `launcher`| `.graph` | **None** (GUI control elements). |

# XSchem Symbol Mapping & Comparison

This document provides a deep dive into how standard XSchem library symbols map to Schemify internal `DeviceKind` types.

---

### 1. The Multi-Variant Families: "Same yet Different"

Some symbols share a building block but differ in their **parameterization** or **modeling depth**.

#### Diodes
*   **Family**: `diode.sym`, `zener.sym`
*   **Sameness**: Both are 2-terminal semiconductor devices using the SPICE `D` prefix.
*   **Difference**: 
    *   `diode.sym` points to a standard model (e.g., `1N4148`) focusing on forward conduction.
    *   `zener.sym` points to a model containing **breakdown voltage** parameters (`BV`, `IBV`). 
*   **Strategy**: Map both to `.diode`. The unique behavior is captured via the `model` property.

#### MOSFETs (The 6 variants)
MOSFETs are categorized by their **terminal count** and **substrate handling**:

| Symbol | Description | Terminal Count | SPICE Prefix |
| :--- | :--- | :--- | :--- |
| `nmos/pmos` | Standard discrete MOSFET (Discrete). | 3 (Bulk tied to S) | `M` |
| `nmos3/pmos3` | Simplified model for early design. | 3 | `M` |
| `nmos4/pmos4` | Full 4-terminal bulk-exposed device. | 4 (D, G, S, B) | `M` |
| `nmos-sub` | 3-terminal UI with a global bulk net. | 3 + `substrate` prop | `M` |
| `nmoshv4` | High-voltage variant. | 4 | `M` |
| `nmos4_depl` | Depletion-mode (usually-on). | 4 | `M` |

*   **Strategy**: Map all to `.mosfet`. The netlister distinguishes them by checking if the `B` (Bulk) pin is provided or if a `substrate` property exists.

---

### 2. Functional Pins: Input, Output, In-out
In pure SPICE, a wire is just a node. However, for **SystemVerilog/VHDL generation** or **DRC (Design Rule Checking)**, directionality matters.

*   **`ipin.sym`**: Input Pin. Maps to `.input_pin`. Used to define a module input port.
*   **`opin.sym`**: Output Pin. Maps to `.output_pin`. Used for driven signals.
*   **`iopin.sym`**: In-Out Pin. Maps to `.inout_pin`. Used for shared busses/buffers.

#### Why separate?
By treating these as distinct built-ins rather than generic `lab_pin` (labels), Schemify can:
1. Generate valid Verilog headers (`input wire clk`).
2. Warn users if two outputs are shorted together.
3. Highlight high-impedance inputs that aren't driven.

---

### 3. Non-Electrical Meta Elements
Not every symbol is a circuit component. Some are just for the designer.

*   **`title.sym`**: **Not a graph**. This is an `.annotation` or `.title_block`. It contains metadata like Author, Revision, and Date. Treating it as a "device" allows us to parse and display it in the Schemify UI as a formal drawing title.
*   **`code.sym` / `simulator_commands`**: Literal `.code`. These are the "glue" that tells SPICE which analysis to run (`.tran`, `.ac`).
*   **`graph.sym`**: A placeholder for the simulator to draw a waveform window.

---

### 4. Property Extraction Strategy
Every symbol attribute is preserved:
1.  **Value Parameters**: `value`, `ac`, `disto`.
2.  **Geometric Parameters**: `w`, `l`, `area`, `ad`, `as`.
3.  **Multiplicity**: `m` (parallel devices).
4.  **Metadata**: `lab`, `label`, `author`, `revision`.

---

### 5. Mixed-Signal Architecture (Digital <-> Analog)

To port digital blocks that can switch between **Functional (Verilog)** and **Synthesized (Structural)** views, we adopt a "Multi-View" wrapper strategy.

#### The "View" Toggle
A digital device (e.g., `and2.sym`, `counter.sch`) in Schemify should have a `view` property:

| View | Action | Output Format |
| :--- | :--- | :--- |
| **Sim (Behavioral)** | NGSpice XSPICE primitives or A/D bridges. | `.model d1 d_and(...)` or `.include "behavioral.v"` |
| **Real (Structural)** | Path to a synthesized netlist of standard cells. | `.subckt counter_struct ...` |
| **Logic (Digital)** | Pure Verilog instantiation for FPGA/ASIC flow. | `counter u1 (.clk(c), .out(q));` |

#### Porting XSchem Digital Blocks
XSchem uses attributes like `verilog_format` and `vhdl_format`. We capture these as properties:
*   **Logic Mode**: If emitting Verilog, Schemify uses the `verilog_format` string directly.
*   **Analog Mode**: If netlisting for SPICE, Schemify automatically inserts **A/D and D/A Bridges** (`a_to_d`, `d_to_a`) at the boundaries where a digital block meets an analog wire. This prevents "Voltage vs Logic" conflicts in the simulator.

#### Digital Device Kind
To keep the built-in system minimal, we use a single unified type for digital/logic blocks:
*   `.digital_instance`: This kind acts as a universal bridge for all non-analog behavioral or structural logic. Whether it is a simple `AND` gate or a multi-core `CPU`, it is treated as a digital entity that maps to an external description (Verilog, XSPICE model, or subcircuit).

### 6. Summary of Builtin Evolution
Based on our migration strategy, we will expand `DeviceKind` with:
- `annotation` (for Title Blocks, non-electrical info)
- `input_pin`, `output_pin`, `inout_pin` (for Port Directionality)
- `digital_instance` (Unified bridge for all logic/Verilog/HDL wrappers)
