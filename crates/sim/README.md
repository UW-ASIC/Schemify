# schemify_sim

Simulation intermediate representation and PySpice integration. Defines the `CircuitIR` schema that bridges the schematic model and simulator backends. Simulation runs through PySpice — the IR is serialized to JSON, handed to the bundled `pyspice_rs` Python module, which drives the actual simulator (ngspice, Xyce, etc.).

## How simulation works

```
Schematic → handler/netlist.rs → CircuitIR (Rust)
                                      ↓
                              CircuitIR.to_json()
                                      ↓
                         pyspice_rs Python module
                              (loads JSON, drives simulator)
                                      ↓
                              SimResult back to Rust
```

The `CircuitIR` is serialized to JSON and handed to the bundled `pyspice_rs` Python module. PySpice handles SPICE netlist generation, simulator invocation, result parsing, and waveform extraction.

## Files

### `ir.rs` — Circuit IR types

The complete intermediate representation for circuit simulation, serializable to/from JSON via serde.

**Top-level: `CircuitIR`**
- `top: Subcircuit` — main circuit.
- `testbench: Option<Testbench>` — simulation setup.
- `subcircuit_defs: Vec<Subcircuit>` — reusable subcircuit definitions.
- `model_libraries: Vec<ModelLibrary>` — device model libraries with optional corner and backend-specific paths.

**`Component` enum (22 variants):**

| Variant | Nodes | Extra fields |
|---------|-------|-------------|
| `Resistor` | n1, n2 | value, params |
| `Capacitor` | n1, n2 | value, params |
| `Inductor` | n1, n2 | value, params |
| `MutualInductor` | — | inductor1, inductor2, coupling |
| `VoltageSource` | np, nm | value, waveform |
| `CurrentSource` | np, nm | value, waveform |
| `BehavioralVoltage` | np, nm | expression |
| `BehavioralCurrent` | np, nm | expression |
| `Vcvs` | np, nm, ncp, ncm | gain |
| `Vccs` | np, nm, ncp, ncm | transconductance |
| `Cccs` | np, nm | vsense, gain |
| `Ccvs` | np, nm | vsense, transresistance |
| `Diode` | np, nm | model, params |
| `Bjt` | nc, nb, ne | model, params |
| `Mosfet` | nd, ng, ns, nb | model, params |
| `Jfet` | nd, ng, ns | model, params |
| `Mesfet` | nd, ng, ns | model, params |
| `VSwitch` | np, nm, ncp, ncm | model |
| `ISwitch` | np, nm | vcontrol, model |
| `TLine` | inp, inm, outp, outm | z0, td |
| `Xspice` | connections (vec) | model |
| `RawSpice` | — | line (passthrough) |

**How to add a new component type:**
1. Add a variant to `Component`.
2. Add conversion logic in `handler/src/netlist.rs` `to_circuit_ir()`.
3. Handle the new variant in `pyspice_rs` Python module for netlist generation.

**`IrValue` enum:** `Numeric { value }`, `Expression { expr }`, `Raw { text }`.

**`IrWaveform` enum:** `Sin`, `Pulse`, `Pwl`, `Exp`, `Sffm`, `Am` — each with their standard SPICE parameters.

**How to add a new waveform type:**
1. Add a variant to `IrWaveform` with its parameters.
2. Handle the new variant in `pyspice_rs` Python module for netlist generation.

**`Analysis` enum (25 variants):**

Generic analyses: `Op`, `Dc`, `Ac`, `Transient`, `Noise`, `Tf`, `Sensitivity`, `PoleZero`, `Distortion`, `Pss`, `HarmonicBalance`, `SPar`, `Stability`, `TransientNoise`, `Fourier`.

Xyce-specific: `XyceSampling`, `XyceEmbeddedSampling`, `XycePce`, `XyceFft`.

Spectre-specific: `SpectreSweep`, `SpectreMonteCarlo`, `SpectrePac`, `SpectrePnoise`, `SpectrePxf`, `SpectrePstb`.

**How to add a new analysis type:**
1. Add a variant to `Analysis` with its parameters.
2. Handle the new variant in `pyspice_rs` for the target simulator backend.

**`Testbench`:** DUT name, stimulus components, analyses, sim options, saves, measures, temperature, initial conditions, node sets, parameter sweeps, extra lines.

**`SimOptions`:** Portable options + backend-specific options keyed by backend name (`"ngspice"`, `"xyce"`, `"spectre"`, etc.).

### `pyspice.rs` — PySpice runtime

Utilities for locating and invoking the bundled `pyspice_rs` Python module that actually drives simulation:

| Function | What it does |
|----------|-------------|
| `module_dir()` | Path to bundled `pyspice_rs` module (None if compiled without). |
| `is_available()` | Whether PySpice support was compiled in. |
| `python_path()` | `PYTHONPATH` value prepending the bundled module to any existing `PYTHONPATH`. |
| `python_bin()` | Python interpreter path (`$PYTHON` env var, fallback `python3`). |

Controlled by the `no_pyspice` feature flag at compile time. When the flag is set, `module_dir()` returns `None` and simulation is unavailable.
