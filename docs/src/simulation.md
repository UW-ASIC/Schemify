# Simulation Overview

Schemify integrates SPICE simulation directly into the schematic editor. Draw your circuit, press **F5**, and see results.

## Simulation Pipeline

```
Schematic (.chn)        Testbench (.chn_tb)
       │                        │
       └──────────┬─────────────┘
                  ▼
          Connectivity Analysis
                  │
                  ▼
          CircuitIR (JSON)
                  │
                  ▼
          PySpice (Python)
                  │
                  ▼
     ┌────────────┼────────────┐
     ▼            ▼            ▼
  NgSpice       Xyce       Spectre ...
     │            │            │
     └────────────┼────────────┘
                  ▼
          Waveform Results
```

1. **Connectivity Analysis** -- Schemify resolves nets from wires and labels
2. **CircuitIR** -- the circuit is serialized to a backend-agnostic JSON intermediate representation
3. **PySpice** -- the bundled Python module converts CircuitIR to the target SPICE dialect and drives the simulator
4. **Results** -- waveforms, measurements, and operating points come back as structured data

## Supported Backends

| Backend | Status | Notes |
|---|---|---|
| NgSpice | Primary | Open-source, most widely tested |
| Xyce | Supported | Parallel SPICE from Sandia National Labs |
| LTspice | Supported | Analog Devices' free simulator |
| Spectre | Supported | Cadence commercial simulator |

## Analysis Types

| Analysis | Description |
|---|---|
| **OP** | DC operating point -- quiescent voltages and currents |
| **DC** | DC sweep -- sweep a source and plot the response |
| **AC** | Small-signal frequency response (Bode plots) |
| **Transient** | Time-domain simulation |
| **Noise** | Noise figure and spectral density |
| **Transfer Function** | Small-signal transfer function |
| **Sensitivity** | Parameter sensitivity analysis |
| **Fourier** | Frequency decomposition of a transient signal |
| **PSS** | Periodic steady-state (for oscillators, PLLs) |
| **Harmonic Balance** | Nonlinear frequency-domain analysis |
| **S-Parameters** | Scattering parameters for RF circuits |

## Running a Simulation

### From the GUI

1. Open or create a testbench (`.chn_tb`) that references your circuit
2. Press **F5** (or menu: Simulation > Run)
3. Results appear in the output panel

### From the CLI

```sh
schemify --file my_testbench.chn_tb run-sim
```

## Stimulus Languages

Schemify supports multiple stimulus definition dialects:

- **NgSpice** -- standard SPICE syntax
- **Xyce** -- Xyce-native syntax
- **PySpice** -- Python-based stimulus via the PySpice library
- **LTspice** -- LTspice-compatible syntax
- **Spectre** -- Spectre-native syntax
- **Vacask** -- custom stimulus language

Switch the active dialect in the stimulus language selector.

## Simulation Output

Results are returned as structured JSON containing:

- **Waveforms** -- voltage/current traces over time or frequency
- **Measurements** -- extracted scalar values
- **Operating points** -- DC bias conditions
- **Diagnostics** -- warnings and errors from the simulator

## Prerequisites

You need:
1. Python 3 installed
2. At least one SPICE backend (NgSpice recommended: `sudo apt install ngspice`)
3. PySpice module (bundled automatically when building with Nix, or set `PYSPICE_MODULE_DIR`)

See also: [PySpice Integration](./pyspice.md) and [Testbenches](./testbenches.md).
