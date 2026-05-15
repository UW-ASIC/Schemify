# CCreator Overview

CCreator is Schemify's circuit design toolkit for templates, behavioral modeling, and circuit generation. It lets you define circuits in Python, simulate them, and export the result as SPICE, Verilog-A, or Schemify `.chn` schematics.

## The Workflow

```
            define              simulate            export
 Python ──────────> Circuit ──────────> Results ──────────> SPICE / Verilog-A / .chn
  class               (PDK-agnostic)                        (Schemify)
```

```python
import ccreator
from ccreator import realistic, Port, testbench, simulate

# 1. Define a PDK-agnostic circuit
@realistic.analog
class FoldedCascode:
    ports = [
        Port('inp', 'input', 'analog'),
        Port('inn', 'input', 'analog'),
        Port('out', 'output', 'analog'),
        Port('vdd', 'inout', 'voltage'),
        Port('vss', 'inout', 'voltage'),
    ]
    def build(self, n):
        # Diff pair
        n.MOSFET('M1', 'tail1', 'inp', 'vs', 'vss', 'nch', W='5u', L='0.5u')
        n.MOSFET('M2', 'tail2', 'inn', 'vs', 'vss', 'nch', W='5u', L='0.5u')
        # Active load
        n.MOSFET('M3', 'tail1', 'tail1', 'vdd', 'vdd', 'pch', W='10u', L='0.5u')
        n.MOSFET('M4', 'out',   'tail1', 'vdd', 'vdd', 'pch', W='10u', L='0.5u')
        # Tail current
        n.MOSFET('M5', 'vs', 'vbias', 'vss', 'vss', 'nch', W='20u', L='1u')

amp = FoldedCascode()

# 2. Simulate
result = simulate(amp).ac(fstart=1, fstop=1e9, points=200)
print(result.metrics())

# 3. Export to SPICE
amp.export.spice('./output/folded_cascode.sp')

# 4. Export to Verilog-A (behavioral)
amp.export.veriloga('./output/folded_cascode.va')
```

**Note:** PDK switching is handled by the PDKSwitcher plugin.
gm/Id optimization is handled by the core optimizer via the Schemify host API.
SPICE import with full placement/routing is handled by core Schemify (spiceImport command).

## Architecture

```
ccreator/
├── core/                  Base circuit classes, ports, errors, decorators
├── behavioral/            Transfer-function-based circuits (SymPy + SciPy)
│   ├── _analog/           BehavioralAnalogCircuit, Verilog-A codegen
│   └── _digital/          BehavioralDigitalCircuit (Verilog RTL)
├── realistic/             Component-level circuits (PySpice + ngspice)
│   ├── _analog/           RealisticAnalogCircuit, NetlistBuilder, SPICE export
│   └── _digital/          RealisticDigitalCircuit, Yosys synthesis
├── testbench/             Testbench framework and SPICE export
├── simulators/            SciPy, PySpice/ngspice, Verilator backends
├── public/                Built-in circuit library (ADC, DAC, PLL, bandgap, etc.)
└── compare/               Result comparison and metrics
```

## Two Circuit Abstractions

CCreator provides two levels of circuit definition:

| | Behavioral | Realistic |
|---|---|---|
| **Decorator** | `@behavioral.analog` | `@realistic.analog` |
| **Defines** | Transfer function H(s) + ODE | Component netlist (MOSFET, R, C) |
| **Simulator** | SciPy (ODE / `signal.freqs`) | ngspice via PySpice |
| **Speed** | Milliseconds | Seconds |
| **Accuracy** | Ideal, no parasitics | Process-accurate with PDK models |
| **Use case** | Architecture exploration | Final sizing and verification |

Both support `circuit.export.spice()` and `circuit.export.veriloga()`.

## Dependencies

**Core** (always needed):
- Python >= 3.11
- numpy, scipy, sympy, matplotlib
- PySpice >= 1.5

**Schemify Export** (needed for `export.schemify()`):
- No additional dependencies (pure Python)

Dependencies are lazy-loaded. Importing `ccreator` does not pull in heavy libraries.

## Next

- [Circuits](circuits.md) — Defining behavioral and realistic circuits
- [Schemify Export](schemify-export.md) — Exporting circuits to Schemify
- [Testbenches](testbenches.md) — Automated testbench framework
- [Built-in Library](builtin-library.md) — ADC, DAC, PLL, bandgap, oscillator, switch
- [API Reference](api-reference.md) — Complete module reference
