# Schemify Export

`circuit.export.schemify()` converts a CCreator circuit into component data for Schemify schematics. It generates SPICE from the circuit and then parses it into component dicts.

**Note:** For full-fidelity SPICE import with BFS placement, Manhattan routing, and power symbol insertion, use the core Schemify host API (`spiceImport` command). The built-in export here uses a minimal parser suitable for basic component extraction.

## Quick Start

```python
from ccreator import realistic, Port

@realistic.analog
class TwoStageOTA:
    ports = [Port('inp', 'input', 'analog'), Port('inn', 'input', 'analog'),
             Port('out', 'output', 'analog'),
             Port('vdd', 'inout', 'voltage'), Port('vss', 'inout', 'voltage')]

    def build(self, n):
        # First stage
        n.MOSFET('M1', 'd1', 'inp', 'vs', 'vss', 'nch', W='5u', L='0.5u')
        n.MOSFET('M2', 'd2', 'inn', 'vs', 'vss', 'nch', W='5u', L='0.5u')
        n.MOSFET('M3', 'd1', 'd1',  'vdd', 'vdd', 'pch', W='10u', L='0.5u')
        n.MOSFET('M4', 'd2', 'd1',  'vdd', 'vdd', 'pch', W='10u', L='0.5u')
        n.MOSFET('M5', 'vs', 'vbias', 'vss', 'vss', 'nch', W='20u', L='1u')
        # Second stage
        n.MOSFET('M6', 'out', 'd2', 'vdd', 'vdd', 'pch', W='40u', L='0.5u')
        n.MOSFET('M7', 'out', 'vbias2', 'vss', 'vss', 'nch', W='20u', L='0.5u')
        # Compensation
        n.R('Rc', 'd2', 'comp', 1e3)
        n.C('Cc', 'comp', 'out', 2e-12)

ota = TwoStageOTA()

# Export to directory — writes JSON file
components = ota.export.schemify('./output/')

# Or get component dicts without writing
components = ota.export.schemify()
for comp in components:
    print(f"{comp['name']} ({comp['symbol']})")
```

## API

```python
circuit.export.schemify(
    path: str | None = None,   # Output directory. None = don't write, just return dicts.
) -> list[dict]
```

Returns a list of component dicts. If `path` is provided, also writes a JSON file to that directory.

## Pipeline

The export pipeline has two stages:

```
  Python circuit
       |
       v
  [1. SPICE Generation]    circuit.build(n) -> PySpice -> .subckt string
       |
       v
  [2. Parsing]             Minimal parser extracts component names, symbols, and properties
       |
       v
  Component dicts (JSON)
```

### Stage 1: SPICE Generation

The circuit's `build(n)` method is called with a `NetlistBuilder`. The builder collects all component calls into a PySpice `Circuit` object, which is rendered as a `.subckt` string:

```spice
.subckt TwoStageOTA inp inn out vdd vss
M1 d1 inp vs vss nch W=5u L=0.5u
M2 d2 inn vs vss nch W=5u L=0.5u
...
Rc d2 comp 1k
Cc comp out 2p
.ends TwoStageOTA
```

### Stage 2: Parsing

The built-in minimal parser extracts basic component information:

| Prefix | Device | Symbol |
|--------|--------|--------|
| R | Resistor | `res` |
| C | Capacitor | `capa` |
| L | Inductor | `ind` |
| M | MOSFET | `nmos4` |
| V | Voltage source | `vsource` |
| I | Current source | `isource` |
| X | Subcircuit | `subckt` |

Components are placed on a simple grid (5 columns, spaced 200 units apart).

## Component Dict Format

Each component dict contains:

```python
{
    "name": "M1",           # instance name
    "symbol": "nmos4",      # Schemify symbol
    "kind": "m",            # SPICE prefix
    "x": 100,              # grid x coordinate
    "y": -100,             # grid y coordinate
    "props": [             # properties
        {"key": "model", "val": "nch"},
    ],
}
```

## Other Export Formats

CCreator also supports direct export to other formats:

```python
# SPICE netlist
circuit.export.spice('./output/my_circuit.sp')

# Verilog-A (behavioral circuits)
circuit.export.veriloga('./output/my_circuit.va')

# Verilog RTL (digital circuits)
circuit.export.verilog('./output/my_circuit.v')

# Yosys synthesis
circuit.export.synthesize('./output/my_circuit_synth.v', liberty='cells.lib')
```

## Full Workflow with Schemify

For the complete pipeline (SPICE generation + full placement/routing), use the
Schemify plugin panel or the `:ccreator import` command, which invokes the core
SPICE import engine via the host API for proper schematic generation.
