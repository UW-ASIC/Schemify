# PySpice Integration

Schemify uses [PySpice](https://github.com/OmarSiwy/PySpice) as the bridge between schematics and SPICE simulators. PySpice is a Python module that translates Schemify's circuit representation into simulator-specific netlists and drives the simulation.

## How It Works

```
Schemify (Rust)                      PySpice (Python)
─────────────                        ────────────────
CircuitIR JSON  ──── subprocess ───►  Parse JSON
                                      │
                                      ▼
                                    Generate SPICE netlist
                                    (NgSpice / Xyce / LTspice / Spectre)
                                      │
                                      ▼
                                    Run simulator
                                      │
                                      ▼
Results JSON    ◄─── subprocess ────  Collect waveforms
```

Schemify spawns PySpice as a subprocess, passes the circuit as JSON (CircuitIR format), and receives results back as JSON. This keeps the Rust side simulator-agnostic.

## CircuitIR Format

The intermediate representation includes:

- **Subcircuits** -- hierarchical circuit blocks
- **Components** -- 40+ device types with parameters
- **Analyses** -- which simulations to run (DC, AC, transient, etc.)
- **Model libraries** -- SPICE model references
- **Waveform data** -- simulation results

Example CircuitIR for a simple voltage divider:

```json
{
  "subcircuits": [{
    "name": "voltage_divider",
    "ports": ["in", "out", "gnd"],
    "components": [
      {"type": "resistor", "name": "R1", "nodes": ["in", "out"], "value": "10k"},
      {"type": "resistor", "name": "R2", "nodes": ["out", "gnd"], "value": "10k"}
    ]
  }],
  "analyses": [
    {"type": "op"}
  ]
}
```

## Setup

### With Nix (Recommended)

The `flake.nix` bundles PySpice automatically. Just run:

```sh
nix develop
cargo build --release
```

The `PYSPICE_MODULE_DIR` environment variable is set by the flake to point at the bundled PySpice.

### Manual Setup

1. Clone PySpice:
   ```sh
   git clone https://github.com/OmarSiwy/PySpice.git
   ```

2. Set the environment variable before building:
   ```sh
   export PYSPICE_MODULE_DIR=/path/to/PySpice/PySpice
   cargo build --release
   ```

3. Make sure you have a SPICE backend installed:
   ```sh
   sudo apt install ngspice    # Debian/Ubuntu
   sudo pacman -S ngspice      # Arch
   ```

## Multi-Backend Support

PySpice generates netlists for different simulators:

| Backend | Dialect | Notes |
|---|---|---|
| NgSpice | Standard SPICE3 | Default, best-tested |
| Xyce | Xyce-native | Parallel simulation, digital support |
| LTspice | LTspice-compatible | Good MOSFET model support |
| Spectre | Spectre-native | Cadence commercial flows |

The backend is selected in the testbench configuration. PySpice handles the dialect conversion automatically.

## Error Handling

Simulation diagnostics are returned with severity levels:

- **Warning** -- non-fatal issues (e.g., convergence nudged)
- **Error** -- simulation completed but results may be unreliable
- **Fatal** -- simulation could not complete

Errors appear in the bottom panel with source location and suggested fixes where possible.
