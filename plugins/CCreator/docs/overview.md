# CCreator Overview

CCreator is Schemify's full-stack circuit design toolkit. It lets you define circuits in Python, switch them between PDKs, optimize transistor sizing against testbench targets, and export the result as Schemify `.chn` schematics — all from a single unified API.

## The Problem

Analog circuit design typically involves four disconnected steps:

1. **Define** the circuit (schematic entry or netlist).
2. **Target a PDK** — manually rewrite model names, rescale W/L for a new process.
3. **Size transistors** — hand-tune or sweep parameters to meet specs.
4. **Import into the editor** — redraw everything in the schematic tool.

Each step uses a different tool, a different format, and a different mental model. CCreator collapses them into one Python API.

## The Unified Workflow

```
            define              switch             optimize           export
 Python ──────────> Circuit ──────────> Circuit' ──────────> Circuit'' ──────────> .chn
  class               (PDK-agnostic)     (target PDK)        (sized)              (Schemify)
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
        n.MOSFET('M1', 'tail1', 'inp', 'vs', 'vss', 'sky130_fd_pr__nfet_01v8', W='5u', L='0.5u')
        n.MOSFET('M2', 'tail2', 'inn', 'vs', 'vss', 'sky130_fd_pr__nfet_01v8', W='5u', L='0.5u')
        # Active load
        n.MOSFET('M3', 'tail1', 'tail1', 'vdd', 'vdd', 'sky130_fd_pr__pfet_01v8', W='10u', L='0.5u')
        n.MOSFET('M4', 'out',   'tail1', 'vdd', 'vdd', 'sky130_fd_pr__pfet_01v8', W='10u', L='0.5u')
        # Tail current
        n.MOSFET('M5', 'vs', 'vbias', 'vss', 'vss', 'sky130_fd_pr__nfet_01v8', W='20u', L='1u')

amp = FoldedCascode()

# 2. Switch to GF180MCU
remapped = amp.switch_pdk('gf180mcuA')

# 3. Optimize against testbench specs
result = amp.optimize(
    targets=[
        {'name': 'gain_db', 'kind': 'maximize'},
        {'name': 'phase_margin', 'kind': '>=', 'target': 60.0},
        {'name': 'power_uw', 'kind': '<=', 'target': 500.0},
    ],
    testbench=my_tb,
    model_lib='/path/to/models.lib',
    vdd=3.3,
    max_iter=100,
)

# 4. Export to Schemify
amp.export.schemify('./output/')
```

## Architecture

CCreator integrates three previously standalone plugins as subpackages:

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
├── compare/               Result comparison and metrics
│
├── pdk_switcherino/       [Integrated] Cross-PDK gm/Id-preserving remap
├── gmid_optimizer/        [Integrated] Bayesian transistor sizing
└── spice2schematic/       [Integrated] SPICE netlist → .chn schematic converter
```

Each integrated subpackage is independently importable:

```python
# Use the PDK switcher directly
from ccreator.pdk_switcherino import PDKSwitcher, get_pdk

# Use the optimizer directly
from ccreator.gmid_optimizer import GMIDOptimizer, Problem

# Use the SPICE importer directly
from ccreator.spice2schematic import parse, import_spice
```

The standalone plugins (PDKSwitcherino, GMIDOptimizer, SpiceImport) also continue to work independently with their own Schemify panel UIs.

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
| **PDK switching** | N/A (PDK-agnostic by nature) | `circuit.switch_pdk()` |
| **Optimization** | N/A (no transistors) | `circuit.optimize()` |

Both support `circuit.export.schemify()` for schematic export.

## Dependencies

**Core** (always needed):
- Python >= 3.11
- numpy, scipy, sympy, matplotlib
- PySpice >= 1.5

**PDK Switching** (needed for `switch_pdk()`):
- ngspice (for characterization sweeps)
- PDK installation (sky130, gf180mcu, or ihp-sg13g2)

**Optimization** (needed for `optimize()`):
- torch, botorch, gpytorch (Bayesian optimization)
- scikit-learn
- ngspice (for testbench evaluation)

**Schemify Export** (needed for `export.schemify()`):
- No additional dependencies (pure Python)

Dependencies are lazy-loaded. Importing `ccreator` does not pull in torch.

## Next

- [Circuits](circuits.md) — Defining behavioral and realistic circuits
- [PDK Switching](pdk-switching.md) — The gm/Id-preserving remap engine
- [Optimization](optimization.md) — Bayesian transistor sizing
- [Schemify Export](schemify-export.md) — The SPICE-to-schematic pipeline
- [Testbenches](testbenches.md) — Automated testbench framework
- [Built-in Library](builtin-library.md) — ADC, DAC, PLL, bandgap, oscillator, switch
- [API Reference](api-reference.md) — Complete module reference
