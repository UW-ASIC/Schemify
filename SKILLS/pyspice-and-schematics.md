# PySpice Import, Testbenches & Schematics

## Overview

SchemifyRS uses a JSON-based CircuitIR as the bridge between schematic data and simulation. The flow:

```
.chn schematic  -->  CircuitIR (JSON)  -->  PySpice-rs (Python)  -->  ngspice/Xyce
     ^                                           |
     |                                           v
SPICE netlist  -->  s2s parser  -->  .chn file   simulation results
```

---

## 1. CircuitIR JSON Format

CircuitIR is defined in `crates/sim/src/ir.rs`. Serialized as tagged JSON (serde `#[serde(tag = "type")]`).

### Top-Level Structure

```json
{
  "top": { /* Subcircuit */ },
  "testbench": { /* Testbench, optional */ },
  "subcircuit_defs": [ /* Subcircuit[] */ ],
  "model_libraries": [ /* ModelLibrary[] */ ]
}
```

### Subcircuit

```json
{
  "name": "voltage_divider",
  "ports": [
    { "name": "in", "direction": "Input" },
    { "name": "out", "direction": "Output" },
    { "name": "vss", "direction": "InOut" }
  ],
  "parameters": [
    { "name": "R1_val", "default": "10k" }
  ],
  "components": [ /* Component[] */ ],
  "instances": [ /* subcircuit Instance[] */ ],
  "models": [ /* ModelDef[] */ ],
  "raw_spice": [],
  "includes": [],
  "libs": [],
  "osdi_loads": [],
  "verilog_blocks": []
}
```

Port directions: `"Input"`, `"Output"`, `"InOut"`

### Components (tagged enum)

Every component has `"type"` field for discrimination.

#### Two-Terminal Passives

```json
{ "type": "Resistor", "name": "R1", "n1": "in", "n2": "out",
  "value": { "type": "Numeric", "value": 10000.0 },
  "params": [] }

{ "type": "Capacitor", "name": "C1", "n1": "out", "n2": "0",
  "value": { "type": "Numeric", "value": 1e-12 },
  "params": [] }

{ "type": "Inductor", "name": "L1", "n1": "a", "n2": "b",
  "value": { "type": "Numeric", "value": 1e-6 },
  "params": [] }
```

#### Sources

```json
{ "type": "VoltageSource", "name": "V1", "np": "vdd", "nm": "0",
  "value": { "type": "Numeric", "value": 1.8 },
  "waveform": null }

{ "type": "CurrentSource", "name": "I1", "np": "a", "nm": "0",
  "value": { "type": "Numeric", "value": 0.0001 },
  "waveform": null }
```

#### Semiconductors

```json
{ "type": "Mosfet", "name": "M1",
  "nd": "drain", "ng": "gate", "ns": "source", "nb": "bulk",
  "model": "nmos_1v8",
  "params": [["W", "10u"], ["L", "180n"]] }

{ "type": "Bjt", "name": "Q1",
  "nc": "collector", "nb": "base", "ne": "emitter",
  "model": "npn_3p3",
  "params": [] }

{ "type": "Diode", "name": "D1", "np": "anode", "nm": "cathode",
  "model": "d1n4148",
  "params": [] }

{ "type": "Jfet", "name": "J1",
  "nd": "drain", "ng": "gate", "ns": "source",
  "model": "njf",
  "params": [] }
```

#### Controlled Sources

```json
{ "type": "Vcvs", "name": "E1",
  "np": "outp", "nm": "outn", "ncp": "inp", "ncm": "inn",
  "gain": 1000.0 }

{ "type": "Vccs", "name": "G1",
  "np": "outp", "nm": "outn", "ncp": "inp", "ncm": "inn",
  "transconductance": 0.001 }

{ "type": "Cccs", "name": "F1",
  "np": "outp", "nm": "outn", "vsense": "Vsense",
  "gain": 100.0 }

{ "type": "Ccvs", "name": "H1",
  "np": "outp", "nm": "outn", "vsense": "Vsense",
  "transresistance": 1000.0 }
```

#### Behavioral Sources

```json
{ "type": "BehavioralVoltage", "name": "B1",
  "np": "out", "nm": "0",
  "expression": "V(in)*V(in)" }

{ "type": "BehavioralCurrent", "name": "B2",
  "np": "out", "nm": "0",
  "expression": "I(R1)*2" }
```

#### Other

```json
{ "type": "MutualInductor", "name": "K1",
  "inductor1": "L1", "inductor2": "L2", "coupling": 0.99 }

{ "type": "VSwitch", "name": "S1",
  "np": "out", "nm": "0", "ncp": "ctrl", "ncm": "0",
  "model": "smod" }

{ "type": "TLine", "name": "T1",
  "inp": "in_p", "inm": "in_m", "outp": "out_p", "outm": "out_m",
  "z0": 50.0, "td": 1e-9 }

{ "type": "RawSpice", "line": ".global vdd" }
```

### IrValue (tagged)

```json
{ "type": "Numeric", "value": 10000.0 }
{ "type": "Expression", "expr": "R1_val * 2" }
{ "type": "Raw", "text": "1k" }
```

### Waveforms (tagged)

```json
{ "type": "Pulse", "initial": 0.0, "pulsed": 1.8,
  "delay": 0.0, "rise_time": 1e-9, "fall_time": 1e-9,
  "pulse_width": 5e-6, "period": 10e-6 }

{ "type": "Sin", "offset": 0.9, "amplitude": 0.1,
  "frequency": 1e6, "delay": 0.0, "damping": 0.0, "phase": 0.0 }

{ "type": "Pwl", "values": [[0.0, 0.0], [1e-6, 1.8], [2e-6, 0.0]] }

{ "type": "Exp", "initial": 0.0, "pulsed": 1.8,
  "rise_delay": 0.0, "rise_tau": 1e-6, "fall_delay": 5e-6, "fall_tau": 1e-6 }

{ "type": "Sffm", "offset": 0.9, "amplitude": 0.5,
  "carrier_freq": 1e6, "modulation_index": 5.0, "signal_freq": 1e3 }

{ "type": "Am", "amplitude": 0.5, "offset": 0.0,
  "modulating_freq": 1e3, "carrier_freq": 1e6, "delay": 0.0 }
```

---

## 2. Testbench Structure

```json
{
  "dut": "voltage_divider",
  "stimulus": [ /* Component[] - additional sources for test */ ],
  "analyses": [ /* Analysis[] */ ],
  "options": {
    "portable": [["reltol", "1e-4"]],
    "backend_specific": {
      "ngspice": [["method", "gear"]]
    }
  },
  "saves": ["V(out)", "I(R1)"],
  "measures": [
    ".meas tran delay TRIG V(in) VAL=0.9 RISE=1 TARG V(out) VAL=0.9 FALL=1"
  ],
  "temperature": 27.0,
  "nominal_temperature": null,
  "initial_conditions": [["out", 0.0]],
  "node_sets": [],
  "step_params": [
    { "param": "R1_val", "start": 1000.0, "stop": 100000.0,
      "step": 1000.0, "sweep_type": null }
  ],
  "extra_lines": []
}
```

### Analysis Types

```json
{ "type": "Op" }

{ "type": "Dc", "sweeps": [
    { "source": "V1", "start": 0.0, "stop": 5.0, "step": 0.1 }
  ] }

{ "type": "Ac", "variation": "dec", "points": 100,
  "start": 1.0, "stop": 1e9 }

{ "type": "Transient", "step": 1e-9, "stop": 1e-3,
  "start": null, "max_step": null, "uic": false }

{ "type": "Noise",
  "output": "out", "reference": "0", "source": "V1",
  "variation": "dec", "points": 100, "start": 1.0, "stop": 1e9,
  "points_per_summary": null }

{ "type": "Tf", "output": "V(out)", "source": "V1" }

{ "type": "Sensitivity", "output": "V(out)", "ac": null }

{ "type": "Fourier", "fundamental": 1e6,
  "outputs": ["V(out)"], "num_harmonics": 10 }

{ "type": "Pss", "fundamental": 1e9, "stabilization": 1e-6,
  "observe_node": "out", "points_per_period": 128, "harmonics": 8 }

{ "type": "HarmonicBalance",
  "frequencies": [1e9, 2e9], "harmonics": [7, 3] }

{ "type": "SPar", "variation": "dec", "points": 201,
  "start": 1e6, "stop": 10e9 }
```

#### Vendor-Specific Analyses

```json
{ "type": "SpectreSweep", "param": "temp", "start": -40.0,
  "stop": 125.0, "step": 5.0, "inner": "dc1", "inner_type": "dc" }

{ "type": "SpectreMonteCarlo", "iterations": 1000,
  "inner": "ac1", "inner_type": "ac", "seed": null }

{ "type": "XyceSampling", "num_samples": 100,
  "distributions": [["R1", "gaussian 1k 0.1k"]] }
```

### Model Libraries

```json
{
  "name": "sky130",
  "path": "$PDK_ROOT/sky130A/libs.tech/ngspice/sky130.lib.spice",
  "corner": "tt",
  "backend_paths": {
    "xyce": "$PDK_ROOT/sky130A/libs.tech/xyce/sky130.lib.spice"
  }
}
```

---

## 3. Writing a Schematic (.chn)

Schematics are the circuit-under-test, reusable as subcircuits.

### Complete Example: Folded Cascode OTA

```
chn_testbench 1

TESTBENCH Folded Cascode OTA
  instances:
    Vdd  vsource  x=-300  y=0  sym=vsource  value=3.3
    M1  nmos  x=-200  y=120  sym=nmos4
      .parameters{   model=nch  W=50u  L=1u  M=2 }
    M2  nmos  x=-80  y=120  sym=nmos4
      .parameters{   model=nch  W=50u  L=1u  M=2 }
    M3  pmos  x=-200  y=-60  sym=pmos4
      .parameters{   model=pch  W=20u  L=1u  M=2 }
    M4  pmos  x=-80  y=-60  sym=pmos4
      .parameters{   model=pch  W=20u  L=1u  M=2 }
    M5  nmos  x=40  y=120  sym=nmos4
      .parameters{   model=nch  W=100u  L=1u  M=1 }
    M6  nmos  x=40  y=-60  sym=nmos4
      .parameters{   model=nch  W=25u  L=2u  M=2 }
    M7  pmos  x=40  y=-180  sym=pmos4
      .parameters{   model=pch  W=40u  L=1u  M=2 }
    Ibias  isource  x=160  y=0  sym=isource  value=50u
    Cc  capacitor  x=120  y=60  sym=capa  value=3p  device=capacitor
    inp  lab_pin  x=-220  y=50  sym=lab_pin
    inn  lab_pin  x=-100  y=50  sym=lab_pin
    vout  lab_pin  x=60  y=-180  sym=lab_pin
    bias  lab_pin  x=60  y=120  sym=lab_pin
    tail  lab_pin  x=-120  y=150  sym=lab_pin
    gnd0  gnd  x=-300  y=40  sym=gnd
    gnd1  gnd  x=-180  y=160  sym=gnd
    gnd2  gnd  x=-60  y=160  sym=gnd
    gnd3  gnd  x=160  y=-20  sym=gnd
    vdd4  vdd  x=-300  y=-40  sym=vdd
    vdd5  vdd  x=-180  y=-40  sym=vdd
    vdd6  vdd  x=-60  y=-40  sym=vdd
    vdd7  vdd  x=60  y=-160  sym=vdd

  wires:
    -220 50 -220 120
    -100 50 -100 120
    -180 -60 -180 90
    -60 -60 -60 90
    -120 150 60 150
    60 150 60 120
    60 -60 120 -60
    120 -60 120 0
    120 0 120 60
```

### Rules for .chn Schematics

1. **Header**: `chn_testbench 1` (current version)
2. **Section**: `TESTBENCH <name>` (indented 2 spaces for content)
3. **Instances**: `<name>  <kind>  x=<X>  y=<Y>  sym=<symbol>  [key=value...]`
   - MOSFET params use `.parameters{   model=<m>  W=<w>  L=<l>  M=<m> }` on next line
   - Two-terminal params inline: `value=10k  device=resistor`
4. **Wires**: `X0 Y0 X1 Y1` (manhattan segments, space-separated)
5. **Labels**: `lab_pin` instances carry net names (instance name = net name)
6. **Power**: `gnd` and `vdd` instances with sequential suffixes (`gnd0`, `vdd1`, ...)
7. **Coordinates**: integer grid, typically multiples of 10

### Instance Kinds

| Kind | Symbol | Pins | Notes |
|------|--------|------|-------|
| `nmos` | `nmos4` | d,g,s,b | 4-terminal MOSFET |
| `pmos` | `pmos4` | d,g,s,b | 4-terminal MOSFET |
| `nmos3` | `nmos3` | d,g,s | 3-terminal MOSFET |
| `resistor` | `res` | p,n | `value=` and `device=resistor` |
| `capacitor` | `capa` | p,n | `value=` and `device=capacitor` |
| `inductor` | `ind` | p,n | `value=` |
| `vsource` | `vsource` | p,n | `value=` (DC, or with waveform string) |
| `isource` | `isource` | p,n | `value=` |
| `diode` | `diode` | p,n | |
| `npn` | `npn` | c,b,e | |
| `pnp` | `pnp` | c,b,e | |
| `subckt` | `<sym_name>` | varies | subcircuit instantiation |
| `lab_pin` | `lab_pin` | p | net label |
| `gnd` | `gnd` | gnd | ground symbol |
| `vdd` | `vdd` | vdd | power symbol |

---

## 4. Writing a Testbench (.chn_tb)

Testbenches instantiate DUTs and add stimulus/analysis.

### Example: Two-Stage Op-Amp Open-Loop AC

```
chn_testbench 1

TESTBENCH TB Two-Stage Op-Amp Open Loop
  instances:
    Xdut  subckt  x=-290  y=-120  sym=two_stage_opamp
    Vdd  vsource  x=-150  y=0  sym=vsource  value=1.8
    Vcm  vsource  x=-40  y=0  sym=vsource  value=900m
    Vinn  vsource  x=80  y=0  sym=vsource  value=0
    Cload  capacitor  x=190  y=120  sym=capa  value=5p  device=capacitor
    Vinp  vsource  x=290  y=0  sym=vsource  value=DC 0 AC 1
    vcm  lab_pin  x=-40  y=-30  sym=lab_pin
    inn  lab_pin  x=-290  y=-90  sym=lab_pin
    inn  lab_pin  x=80  y=-90  sym=lab_pin
    inp  lab_pin  x=-290  y=-150  sym=lab_pin
    inp  lab_pin  x=290  y=-150  sym=lab_pin
    gnd0  gnd  x=-150  y=40  sym=gnd
    gnd1  gnd  x=-40  y=40  sym=gnd
    gnd2  gnd  x=190  y=160  sym=gnd
    vdd3  vdd  x=-150  y=-40  sym=vdd

  wires:
    -40 -30 20 -30
    20 -30 20 30
    20 30 80 30
    80 30 290 30
    -290 -90 80 -90
    80 -90 80 -30
    -290 -150 290 -150
    290 -150 290 -30
```

### Testbench Patterns

**DUT instantiation**: Use `subckt` kind with `sym=<schematic_name>`
```
Xdut  subckt  x=-290  y=-120  sym=cmos_inverter
```

**DC source**: Simple value
```
Vdd  vsource  x=0  y=0  sym=vsource  value=1.8
```

**AC stimulus**: DC + AC spec in value string
```
Vin  vsource  x=0  y=0  sym=vsource  value=DC 0 AC 1
```

**Pulse stimulus**: SPICE-style inline
```
Vin  vsource  x=0  y=0  sym=vsource  value=0 PULSE(0 1.8 0 20p 20p 500p 1n)
```

**Net connectivity**: Multiple `lab_pin` instances with same name = same net
```
inn  lab_pin  x=-290  y=-90  sym=lab_pin
inn  lab_pin  x=80  y=-90  sym=lab_pin
```

---

## 5. CircuitIR Testbench Example (Full JSON)

```json
{
  "top": {
    "name": "common_source_amp",
    "ports": [
      { "name": "inp", "direction": "Input" },
      { "name": "out", "direction": "Output" },
      { "name": "vdd", "direction": "InOut" },
      { "name": "vss", "direction": "InOut" }
    ],
    "parameters": [],
    "components": [
      { "type": "Mosfet", "name": "M1",
        "nd": "out", "ng": "inp", "ns": "vss", "nb": "vss",
        "model": "nmos_1v8",
        "params": [["W", "10u"], ["L", "180n"]] },
      { "type": "Resistor", "name": "Rd",
        "n1": "vdd", "n2": "out",
        "value": { "type": "Numeric", "value": 5000.0 },
        "params": [] }
    ],
    "instances": [],
    "models": [],
    "raw_spice": [],
    "includes": [],
    "libs": [],
    "osdi_loads": [],
    "verilog_blocks": []
  },
  "testbench": {
    "dut": "common_source_amp",
    "stimulus": [
      { "type": "VoltageSource", "name": "Vdd", "np": "vdd", "nm": "0",
        "value": { "type": "Numeric", "value": 1.8 }, "waveform": null },
      { "type": "VoltageSource", "name": "Vin", "np": "inp", "nm": "0",
        "value": { "type": "Numeric", "value": 0.0 },
        "waveform": { "type": "Sin", "offset": 0.9, "amplitude": 0.01,
          "frequency": 1000000.0, "delay": 0.0, "damping": 0.0, "phase": 0.0 } }
    ],
    "analyses": [
      { "type": "Op" },
      { "type": "Dc", "sweeps": [
          { "source": "Vin", "start": 0.0, "stop": 1.8, "step": 0.001 }
        ] },
      { "type": "Ac", "variation": "dec", "points": 100,
        "start": 1.0, "stop": 10000000000.0 },
      { "type": "Transient", "step": 1e-9, "stop": 0.00001,
        "start": null, "max_step": null, "uic": false }
    ],
    "options": {
      "portable": [["reltol", "1e-4"]],
      "backend_specific": {}
    },
    "saves": ["V(out)", "V(inp)", "I(Rd)"],
    "measures": [],
    "temperature": 27.0,
    "nominal_temperature": null,
    "initial_conditions": [],
    "node_sets": [],
    "step_params": [],
    "extra_lines": []
  },
  "subcircuit_defs": [],
  "model_libraries": [
    {
      "name": "sky130",
      "path": "$PDK_ROOT/sky130A/libs.tech/ngspice/sky130.lib.spice",
      "corner": "tt",
      "backend_paths": {}
    }
  ]
}
```

---

## 6. PySpice-rs Python Side

SchemifyRS bundles a `pyspice_rs` Python module (`crates/sim/src/pyspice.rs` sets up paths). The Python side:

1. Reads CircuitIR JSON from stdin or file
2. Builds ngspice/Xyce netlist
3. Runs simulation
4. Returns results as JSON

### Runtime setup

```rust
// Rust side — crates/sim/src/pyspice.rs
pub fn module_dir() -> &'static Path      // bundled Python module path
pub fn python_path() -> String             // PYTHONPATH with bundled dir prepended
pub fn python_bin() -> PathBuf             // PYTHON env var or "python3"
```

### Env vars

| Variable | Purpose |
|----------|---------|
| `PYTHON` | Override Python interpreter path |
| `PYTHONPATH` | Extended with bundled module dir |
| `PDK_ROOT` | PDK installation root for model libraries |

---

## 7. Practical Recipes

### Recipe: Voltage Divider with DC Sweep

CircuitIR JSON for sweeping input voltage and measuring output:

```json
{
  "top": {
    "name": "vdiv",
    "ports": [],
    "parameters": [],
    "components": [
      { "type": "Resistor", "name": "R1", "n1": "in", "n2": "out",
        "value": { "type": "Numeric", "value": 10000.0 }, "params": [] },
      { "type": "Resistor", "name": "R2", "n1": "out", "n2": "0",
        "value": { "type": "Numeric", "value": 10000.0 }, "params": [] },
      { "type": "VoltageSource", "name": "V1", "np": "in", "nm": "0",
        "value": { "type": "Numeric", "value": 5.0 }, "waveform": null }
    ],
    "instances": [], "models": [], "raw_spice": [],
    "includes": [], "libs": [], "osdi_loads": [], "verilog_blocks": []
  },
  "testbench": {
    "dut": "vdiv",
    "stimulus": [],
    "analyses": [
      { "type": "Op" },
      { "type": "Dc", "sweeps": [
          { "source": "V1", "start": 0.0, "stop": 10.0, "step": 0.1 }
      ]}
    ],
    "options": { "portable": [], "backend_specific": {} },
    "saves": ["V(out)", "V(in)"],
    "measures": [], "temperature": 27.0, "nominal_temperature": null,
    "initial_conditions": [], "node_sets": [], "step_params": [],
    "extra_lines": []
  },
  "subcircuit_defs": [],
  "model_libraries": []
}
```

### Recipe: CMOS Inverter with Transient + VTC

```json
{
  "top": {
    "name": "inv",
    "ports": [
      { "name": "in", "direction": "Input" },
      { "name": "out", "direction": "Output" }
    ],
    "parameters": [],
    "components": [
      { "type": "Mosfet", "name": "Mp", "nd": "out", "ng": "in", "ns": "vdd", "nb": "vdd",
        "model": "pmos_1v8", "params": [["W", "2u"], ["L", "180n"]] },
      { "type": "Mosfet", "name": "Mn", "nd": "out", "ng": "in", "ns": "0", "nb": "0",
        "model": "nmos_1v8", "params": [["W", "1u"], ["L", "180n"]] }
    ],
    "instances": [], "models": [], "raw_spice": [],
    "includes": [], "libs": [], "osdi_loads": [], "verilog_blocks": []
  },
  "testbench": {
    "dut": "inv",
    "stimulus": [
      { "type": "VoltageSource", "name": "Vdd", "np": "vdd", "nm": "0",
        "value": { "type": "Numeric", "value": 1.8 }, "waveform": null },
      { "type": "VoltageSource", "name": "Vin", "np": "in", "nm": "0",
        "value": { "type": "Numeric", "value": 0.0 },
        "waveform": { "type": "Pulse", "initial": 0.0, "pulsed": 1.8,
          "delay": 0.0, "rise_time": 1e-10, "fall_time": 1e-10,
          "pulse_width": 5e-9, "period": 1e-8 } }
    ],
    "analyses": [
      { "type": "Dc", "sweeps": [
          { "source": "Vin", "start": 0.0, "stop": 1.8, "step": 0.001 }
      ]},
      { "type": "Transient", "step": 1e-11, "stop": 2e-8,
        "start": null, "max_step": null, "uic": false }
    ],
    "options": { "portable": [], "backend_specific": {} },
    "saves": ["V(out)", "V(in)"],
    "measures": [
      ".meas dc vth FIND V(in) WHEN V(out)=0.9"
    ],
    "temperature": 27.0, "nominal_temperature": null,
    "initial_conditions": [], "node_sets": [], "step_params": [],
    "extra_lines": []
  },
  "subcircuit_defs": [],
  "model_libraries": []
}
```

### Recipe: Parametric Sweep

Sweep a resistor value across a range:

```json
"step_params": [
  { "param": "Rload", "start": 100.0, "stop": 100000.0,
    "step": 100.0, "sweep_type": "lin" }
]
```

Sweep types: `"lin"`, `"dec"`, `"oct"`, `"list"`, or `null` (default linear).
