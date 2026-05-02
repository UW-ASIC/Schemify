# Schemify Export

`circuit.export.schemify()` converts a CCreator circuit into a Schemify `.chn` schematic. It works by generating SPICE, then parsing, placing, routing, and converting it into Schemify's JSON schematic format.

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
        n.MOSFET('M1', 'd1', 'inp', 'vs', 'vss', 'sky130_fd_pr__nfet_01v8', W='5u', L='0.5u')
        n.MOSFET('M2', 'd2', 'inn', 'vs', 'vss', 'sky130_fd_pr__nfet_01v8', W='5u', L='0.5u')
        n.MOSFET('M3', 'd1', 'd1',  'vdd', 'vdd', 'sky130_fd_pr__pfet_01v8', W='10u', L='0.5u')
        n.MOSFET('M4', 'd2', 'd1',  'vdd', 'vdd', 'sky130_fd_pr__pfet_01v8', W='10u', L='0.5u')
        n.MOSFET('M5', 'vs', 'vbias', 'vss', 'vss', 'sky130_fd_pr__nfet_01v8', W='20u', L='1u')
        # Second stage
        n.MOSFET('M6', 'out', 'd2', 'vdd', 'vdd', 'sky130_fd_pr__pfet_01v8', W='40u', L='0.5u')
        n.MOSFET('M7', 'out', 'vbias2', 'vss', 'vss', 'sky130_fd_pr__nfet_01v8', W='20u', L='0.5u')
        # Compensation
        n.R('Rc', 'd2', 'comp', 1e3)
        n.C('Cc', 'comp', 'out', 2e-12)

ota = TwoStageOTA()

# Export to directory — writes .chn JSON files
outputs = ota.export.schemify('./output/')

# Or get SchematicOutput objects without writing
outputs = ota.export.schemify()
for out in outputs:
    print(f"{out.filename}: {len(out.components)} devices, {len(out.wires)} wires, {len(out.pins)} pins")
```

## API

```python
circuit.export.schemify(
    path: str | None = None,   # Output directory. None = don't write, just return objects.
) -> list[SchematicOutput]
```

Returns a list of `SchematicOutput` objects (one per `.subckt` in the SPICE). If `path` is provided, also writes `.chn` JSON files to that directory.

## Pipeline

The export pipeline has four stages:

```
  Python circuit
       |
       v
  [1. SPICE Generation]    circuit.build(n) -> PySpice -> .subckt string
       |
       v
  [2. Parsing]             Tokenize SPICE into structured Netlist object
       |
       v
  [3. Placement]           BFS topological layout on a grid
       |
       v
  [4. Routing]             Manhattan wire routing + power symbol insertion
       |
       v
  SchematicOutput (.chn JSON)
```

### Stage 1: SPICE Generation

The circuit's `build(n)` method is called with a `NetlistBuilder`. The builder collects all component calls into a PySpice `Circuit` object, which is rendered as a `.subckt` string:

```spice
.subckt TwoStageOTA inp inn out vdd vss
M1 d1 inp vs vss sky130_fd_pr__nfet_01v8 W=5u L=0.5u
M2 d2 inn vs vss sky130_fd_pr__nfet_01v8 W=5u L=0.5u
...
Rc d2 comp 1k
Cc comp out 2p
.ends TwoStageOTA
```

### Stage 2: Parsing

The SPICE parser (`spice2schematic.parser`) tokenizes the netlist into structured objects:

```python
@dataclass
class Netlist:
    title: str
    subckts: list[Subckt]       # .subckt definitions
    top_elements: list[Element]  # top-level instances
    models: list[Model]          # .model definitions
    params: list[Param]          # .param definitions
    globals: list[str]           # .global nets
    analyses: list[Analysis]     # .ac, .tran, .dc, etc.
    measures: list[Measure]      # .meas directives
    control_block: str | None    # .control block
```

Supported element types:

| Prefix | Device | Nodes |
|--------|--------|-------|
| R | Resistor | n1, n2 |
| C | Capacitor | n1, n2 |
| L | Inductor | n1, n2 |
| D | Diode | anode, cathode |
| M | MOSFET | drain, gate, source, bulk |
| Q | BJT | collector, base, emitter |
| J | JFET | drain, gate, source |
| V | Voltage source | n+, n- |
| I | Current source | n+, n- |
| E | VCVS | n+, n-, nc+, nc- |
| G | VCCS | n+, n-, nc+, nc- |
| F | CCCS | n+, n-, Vname |
| H | CCVS | n+, n-, Vname |
| B | Behavioral | n+, n- |
| X | Subcircuit instance | node list |

### Stage 3: Placement

The placer (`spice2schematic.layout`) assigns grid coordinates using BFS topological ordering:

1. **Build adjacency** — map each net to the elements it connects (skip power/ground nets).
2. **Seed BFS** — voltage and current sources start at layer 0.
3. **Propagate** — connected elements are placed in successive layers.
4. **Row assignment** — within each layer, elements are stacked vertically in BFS visit order.
5. **Overlap resolution** — if two elements collide on the same grid cell, the later one shifts down.
6. **Coordinate conversion** — `(layer, row)` maps to `(x, y)` with:
   - Horizontal spacing: 200 units between columns
   - Vertical spacing: 120 units between rows
   - Snap: 10-unit grid

Element-to-symbol mapping:

| SPICE | Schemify symbol | Kind |
|-------|----------------|------|
| R | `res` | `resistor` |
| C | `capa` | `capacitor` |
| L | `ind` | `inductor` |
| M (nmos) | `nmos4` | `nmos` |
| M (pmos) | `pmos4` | `pmos` |
| Q (npn) | `npn` | `npn` |
| Q (pnp) | `pnp` | `pnp` |
| V | `vsource` | `vsource` |
| I | `isource` | `isource` |

MOSFET polarity is inferred from the model name (patterns like `pfet`, `pmos`, `pch` indicate PMOS).

### Stage 4: Routing

The router (`spice2schematic.router`) creates Manhattan-style wire segments:

1. **Collect pins** — for each net, gather absolute pin positions from placed elements.
2. **Power nets** — `gnd`/`0`/`vss` get GND symbols; `vdd`/`vcc` get VDD symbols at pin locations.
3. **Signal nets** — for each net with 2+ pins, route L-shaped wires (horizontal then vertical).

Pin offsets (relative to element center):

```
res/capa/ind/vsource/isource:  p=(0,-30)  n=(0,+30)
nmos4:  d=(+20,-30)  g=(-20,0)  s=(+20,+30)  b=(+20,0)
pmos4:  d=(+20,+30)  g=(-20,0)  s=(+20,-30)  b=(+20,0)
```

## SchematicOutput

The final output is a `SchematicOutput` dataclass:

```python
@dataclass
class SchematicOutput:
    filename: str                      # e.g. "TwoStageOTA.chn"
    stype: str                         # "component" or "testbench"
    name: str                          # circuit name
    pins: list[Pin]                    # symbol pins (ports)
    components: list[Component]        # placed instances
    wires: list[Wire]                  # routed wires
    power_symbols: list[dict]          # VDD/GND symbols
    sym_props: dict[str, str]          # symbol properties (format, type, template)
    globals: list[str]                 # global nets
    plugin_block: dict[str, str]       # metadata
    control_block: str | None

    def to_dict(self) -> dict: ...     # JSON-serializable dict
    def to_json(self, indent=2) -> str: ...
    def write_json(self, output_dir) -> Path: ...
```

Each `Component` contains:

```python
@dataclass
class Component:
    name: str           # instance name ("M1", "R1")
    symbol: str         # Schemify symbol ("nmos4", "res")
    kind: str           # device kind ("nmos", "resistor")
    x: int              # grid x coordinate
    y: int              # grid y coordinate
    rot: int            # rotation (0/90/180/270)
    flip: bool
    props: list[dict]   # [{"key": "model", "val": "sky130_fd_pr__nfet_01v8"}, ...]
    conns: list[dict]   # [{"pin": "d", "net": "out"}, {"pin": "g", "net": "inp"}, ...]
    spice_line: str | None  # raw SPICE for behavioral elements
```

## Full Pipeline Example

Combining all three stages — switch PDK, optimize, then export:

```python
@realistic.analog
class MyAmp:
    ports = [...]
    def build(self, n):
        # sky130 circuit definition
        ...

amp = MyAmp()

# 1. Switch to GF180
gf180_spice = amp.switch_pdk('gf180mcuA')

# 2. Optimize (uses original circuit's testbench)
result = amp.optimize(
    targets=[{'name': 'gain_db', 'kind': 'maximize'}],
    testbench=my_tb,
    model_lib='/path/to/gf180mcu.lib',
    vdd=3.3,
)

# 3. Export the optimized circuit to Schemify
amp.export.schemify('./final_schematic/')
```

The output directory will contain `.chn` JSON files that can be opened directly in Schemify.

## Direct Subpackage Usage

Use the SPICE importer directly for arbitrary SPICE files:

```python
from ccreator.spice2schematic import parse, convert, import_spice

# One-shot: parse + place + route + convert
with open('my_circuit.sp') as f:
    outputs = import_spice(f.read(), source_path='my_circuit.sp')

for out in outputs:
    out.write_json('./output/')

# Or step by step:
netlist = parse(spice_source)
print(f"Found {len(netlist.subckts)} subcircuits, {len(netlist.top_elements)} top-level elements")

from ccreator.spice2schematic.layout import place
from ccreator.spice2schematic.router import route

for subckt in netlist.subckts:
    placed = place(subckt.elements, netlist.models)
    routed = route(subckt.elements, placed)
    print(f"{subckt.name}: {len(placed)} devices, {len(routed.wires)} wires, {len(routed.power)} power symbols")
```

## CLI

The spice2schematic module also provides a command-line interface:

```bash
python -m ccreator.spice2schematic my_circuit.sp -o ./output/
python -m ccreator.spice2schematic my_circuit.sp --stdout | jq .
```
