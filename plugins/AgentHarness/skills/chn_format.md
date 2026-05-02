# .chn File Format

Schemify's native schematic format. Plain text, indent-driven.

## File Types

| Extension | Header | Description |
|-----------|--------|-------------|
| `.chn` | `chn 1` | Schematic (component) |
| `.chn` | `chn_testbench 1` | Testbench |
| `.chn_prim` | `chn_prim 1` | Primitive symbol definition |

## Structure

```
chn 1

SYMBOL my_component
  desc: A differential amplifier
  type: component
  spice_prefix: X
  pins:
    inp  in   x=-40 y=0
    inn  in   x=-40 y=20
    out  out  x=40  y=10
    vdd  inout x=0  y=-20
    gnd  inout x=0  y=40
  params:
    W = 10u
    L = 180n
  drawing:
    line (-40,0)-(0,0)
    line (-40,20)-(0,20)
    rect (-5,-5)-(35,25)

SCHEMATIC
  instances:
    M1 nmos4 x=100 y=200 rot=0 flip=false W=10u L=180n model=nch
    M2 nmos4 x=200 y=200 rot=0 flip=false W=10u L=180n model=nch
    R1 resistor x=100 y=100 rot=0 flip=false value=10k
  nets:
    VDD -> M1.vdd, M2.vdd, R1.p
    out -> M1.d, R1.n
  wires:
    0 100 0 200 0 VDD
    100 200 100 300
  code_block:
    .include /path/to/models.lib

PLUGIN CCreator
  testbench_code: @realistic.analog\nclass MyAmp:\n    ...
  last_export: /tmp/my_amp.py
```

## Sections

### instances
Each instance line: `name symbol x=N y=N rot=N flip=bool [key=value ...]`

Parameters can also follow on the next line:
```
M1 nmos4 x=100 y=200
  .parameters{ W=10u L=180n model=nch }
```

### wires
Each wire: `x0 y0 x1 y1 [net_name]`

### nets
Each net: `name -> connection1, connection2, ...`

### pins
Each pin: `name direction [x=N] [y=N] [width=N]`
Directions: `in`, `out`, `inout`

### params
Each param: `key = default_value`

### code_block
Raw SPICE code, stored as `spice_body`. Each indented line is appended.
Used for `.include`, `.subckt`, `.control`, etc.

### analyses
Prefixed properties: `analysis.tran: .tran 0 1us 1ns`

### measures
Prefixed properties: `measure.vout_dc: .meas dc vout_dc avg v(out)`

### PLUGIN blocks
Top-level `PLUGIN <name>` followed by indent-1 `key: value` pairs.
Round-tripped through save/load. Plugins use these to persist metadata.

## Coordinate System
- Origin at (0, 0), Y increases downward
- Default grid snap: 10 units
- Instance positions are center-based
- Rotation: 0-3 (0°, 90°, 180°, 270°)
- Flip: horizontal mirror

## Primitive Kinds and SPICE Prefixes

| Kind | Prefix | Pins |
|------|--------|------|
| nmos/pmos | M | d, g, s, b |
| nmos3/pmos3 | M | d, g, s |
| resistor | R | p, n |
| capacitor | C | p, n |
| inductor | L | p, n |
| diode/zener | D | anode, cathode |
| npn/pnp | Q | collector, base, emitter |
| njfet/pjfet | J | d, g, s |
| vsource | V | p, n |
| isource | I | p, n |
| gnd | - | gnd (injected net "0") |
| vdd | - | vdd (injected net "VDD") |
| input_pin | - | pin |
| output_pin | - | pin |
| inout_pin | - | pin |
| lab_pin | - | pin |
| vcvs | E | p, n, cp, cn |
| vccs | G | p, n, cp, cn |
| ccvs | H | p, n, cp, cn |
| cccs | F | p, n, cp, cn |
