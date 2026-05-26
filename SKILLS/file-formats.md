# SchemifyRS File Formats: .chn, .chn_prim, .chn_tb

## Overview

SchemifyRS uses three text-based file formats:

| Extension | Purpose | Header | Top-level section |
|-----------|---------|--------|-------------------|
| `.chn` | Schematic / symbol | `chn_testbench 1` | `TESTBENCH <name>` |
| `.chn_prim` | Primitive device definition | `chn_prim 1.0` | `SYMBOL <name>` |
| `.chn_tb` | Testbench (DUT + stimulus) | `chn_testbench 1` | `TESTBENCH <name>` |

All formats are line-oriented, indentation-based, human-readable, and git-friendly.

---

## 1. .chn (Schematic)

A `.chn` file defines a circuit that can be instantiated as a subcircuit in other schematics or testbenches.

### Format

```
chn_testbench 1

TESTBENCH <name>
  instances:
    <name>  <kind>  x=<X>  y=<Y>  sym=<symbol>  [key=value...]
    <name>  <kind>  x=<X>  y=<Y>  sym=<symbol>
      .parameters{   key=value  key=value  ... }

  wires:
    X0 Y0 X1 Y1 [bus=1] [color=#RRGGBB] [<net_name>]
```

### Instance Line Syntax

```
<inst_name>  <device_kind>  x=<int>  y=<int>  sym=<symbol_name>  [rot=<0-3>] [flip=1] [key=value...]
```

- `inst_name`: unique identifier (duplicates for `lab_pin`/`gnd`/`vdd` OK - they're connectivity markers)
- `device_kind`: matches a `.chn_prim` symbol name or `subckt` for subcircuit instances
- `x=`, `y=`: integer grid coordinates (typically multiples of 10)
- `sym=`: display symbol to use
- `rot=`: rotation (0=0, 1=90, 2=180, 3=270 degrees)
- `flip=1`: horizontal mirror

### Parameter Styles

**Inline** (two-terminal devices):
```
R1  resistor  x=10  y=0  sym=res  value=10k  device=resistor
C1  capacitor  x=20  y=60  sym=capa  value=1p  device=capacitor
Vdd  vsource  x=-100  y=0  sym=vsource  value=1.8
```

**Block** (MOSFETs, BJTs, multi-param devices):
```
M1  nmos  x=-200  y=120  sym=nmos4
  .parameters{   model=nmos_1v8  W=10u  L=180n  M=1 }
```

The `.parameters{ ... }` line is indented under its instance. Spaces between key=value pairs.

### Wire Line Syntax

```
X0 Y0 X1 Y1
```

Four space-separated integers. Each wire is a manhattan segment (horizontal or vertical). Optional trailing fields:
- `bus=1` — draw as bus (thick)
- `color=#RRGGBB` — override color
- `<net_name>` — explicit net label on wire

### Connectivity Rules

- **lab_pin**: Instance name IS the net name. Multiple `lab_pin` instances with same name = same net.
- **gnd**: Always net `0`. Suffixed with numbers for uniqueness (`gnd0`, `gnd1`, ...).
- **vdd**: Power rail. Suffixed similarly (`vdd0`, `vdd1`, ...).
- **Wires**: Connect pin positions of instances at the same coordinates.

### Real Example: CMOS Inverter

```
chn_testbench 1

TESTBENCH CMOS Inverter
  instances:
    Vdd  vsource  x=-170  y=0  sym=vsource  value=1.8
    Vin  vsource  x=-60  y=0  sym=vsource  value=900m
    Mp  pmos  x=50  y=-120  sym=pmos4
      .parameters{   model=pmos_1v8  W=2u  L=180n  M=1 }
    Mn  nmos  x=170  y=120  sym=nmos4
      .parameters{   model=nmos_1v8  W=1u  L=180n  M=1 }
    vout  lab_pin  x=30  y=-150  sym=lab_pin
    vin  lab_pin  x=-60  y=-30  sym=lab_pin
    gnd0  gnd  x=-170  y=40  sym=gnd
    gnd1  gnd  x=-60  y=40  sym=gnd
    gnd2  gnd  x=190  y=160  sym=gnd
    gnd3  gnd  x=190  y=130  sym=gnd
    vdd4  vdd  x=-170  y=-40  sym=vdd
    vdd5  vdd  x=30  y=-100  sym=vdd
    vdd6  vdd  x=30  y=-130  sym=vdd

  wires:
    30 -150 190 -150
    190 -150 190 90
    -60 -30 70 -30
    70 -30 70 -120
    70 -120 150 -120
    150 -120 150 120
```

### Real Example: Voltage Divider

```
chn_testbench 1

TESTBENCH Voltage Divider
  instances:
    Vin  vsource  x=-100  y=0  sym=vsource  value=5
    R1  resistor  x=10  y=0  sym=res  value=10k  device=resistor
    R2  resistor  x=100  y=120  sym=res  value=10k  device=resistor
    vin  lab_pin  x=-100  y=-30  sym=lab_pin
    vout  lab_pin  x=-20  y=0  sym=lab_pin
    gnd0  gnd  x=-100  y=40  sym=gnd
    gnd1  gnd  x=100  y=160  sym=gnd

  wires:
    -100 -30 40 -30
    40 -30 40 0
    -20 0 100 0
    100 0 100 90
```

---

## 2. .chn_prim (Primitive Definition)

Defines a device symbol: pins, parameters, SPICE format, and drawing.

### Format

```
chn_prim 1.0

SYMBOL <name>
  desc: <description>

  pins [<count>]:
    <pin_name>  <direction>
    ...

  params [<count>]:
    <param_name> = <default_value>
    ...

  spice_prefix: <char>
  spice_format: "<template>"

  drawing:
    lines:
      # Comment
      (x0,y0) (x1,y1)
      ...
    circle: (cx,cy) r=<radius>
    arc: (cx,cy) r=<radius> start=<deg> sweep=<deg>
    rect: (x0,y0) (x1,y1)
    text: (x,y) "<content>"
    pin_positions:
      <pin_name>: (x,y)
      ...
```

### Pin Directions

| Direction | Meaning |
|-----------|---------|
| `in` | Input only |
| `out` | Output only |
| `inout` | Bidirectional |
| `io` | Alias for inout (used in some primitives) |

### Spice Format Template

`@`-prefixed tokens get substituted:
- `@name` — instance name
- `@<pin>` — net connected to that pin
- `@<param>` — parameter value

Example: `"@name @d @g @s @b @model w=@w l=@l nf=@nf m=@m"` produces `M1 drain gate source bulk nmos_1v8 w=10u l=180n nf=1 m=1`

### Drawing Primitives

**Lines** (polyline segments):
```
lines:
  (x0,y0) (x1,y1)            # Single segment
  (x0,y0) (x1,y1) (x2,y2)   # Connected segments (rare)
```

**Circle**:
```
circle: (cx,cy) r=<radius>
```

**Arc**:
```
arc: (cx,cy) r=<radius> start=<degrees> sweep=<degrees>
```

**Rectangle**:
```
rect: (x0,y0) (x1,y1)
```

**Text**:
```
text: (x,y) "<content>"
```
Content can use `@param` substitution (e.g., `"@name"`, `"@w/@l"`, `"@r"`).

**Pin positions** (required):
```
pin_positions:
  <pin_name>: (x,y)
```

### Complete Primitive Examples

#### Resistor
```
chn_prim 1.0

SYMBOL resistor
  desc: Ideal resistor (2-terminal)

  pins [2]:
    p  inout
    n  inout

  params [2]:
    r = 1k
    m = 1

  spice_prefix: R
  spice_format: "@name @p @n @r m=@m"

  drawing:
    lines:
      (0,-30) (0,-20)
      (0,-20) (8,-18)
      (8,-18) (-8,-13)
      (-8,-13) (8,-8)
      (8,-8) (-8,-3)
      (-8,-3) (8,3)
      (8,3) (-8,8)
      (-8,8) (8,13)
      (8,13) (-8,18)
      (-8,18) (0,20)
      (0,20) (0,30)
    text: (15,0) "@name"
    text: (15,10) "@r"
    pin_positions:
      p: (0,-30)
      n: (0,30)
```

#### NMOS (4-terminal)
```
chn_prim 1.0

SYMBOL nmos
  desc: N-channel MOSFET (4-terminal)

  pins [4]:
    d  inout
    g  in
    s  inout
    b  inout

  params [5]:
    w     = 1u
    l     = 100n
    nf    = 1
    m     = 1
    model = nch

  spice_prefix: M
  spice_format: "@name @d @g @s @b @model w=@w l=@l nf=@nf m=@m"

  drawing:
    lines:
      # Channel body
      (5,-30) (5,30)
      # Drain stub + lead
      (5,-20) (20,-20)
      (20,-30) (20,-20)
      # Source stub + lead
      (5,20) (20,20)
      (20,20) (20,30)
      # Gate plate + lead
      (-5,-15) (-5,15)
      (-20,0) (-5,0)
      # Body lead + arrow
      (10,0) (20,0)
      (5,-5) (10,0)
      (5,5) (10,0)
    text: (25,-15) "@name"
    text: (25,15) "@w/@l"
    pin_positions:
      d: (20,-30)
      g: (-20,0)
      s: (20,30)
      b: (20,0)
```

#### PMOS (4-terminal) — note bubble on gate
```
chn_prim 1.0

SYMBOL pmos
  desc: P-channel MOSFET (4-terminal)

  pins [4]:
    d  inout
    g  in
    s  inout
    b  inout

  params [5]:
    w     = 1u
    l     = 100n
    nf    = 1
    m     = 1
    model = pch

  spice_prefix: M
  spice_format: "@name @d @g @s @b @model w=@w l=@l nf=@nf m=@m"

  drawing:
    lines:
      (5,-30) (5,30)
      (5,-20) (20,-20)
      (20,-30) (20,-20)
      (5,20) (20,20)
      (20,20) (20,30)
      (-5,-15) (-5,15)
      (-20,0) (-13,0)
      (10,0) (20,0)
      (5,-5) (10,0)
      (5,5) (10,0)
    circle: (-9,0) r=4
    text: (25,-15) "@name"
    text: (25,15) "@w/@l"
    pin_positions:
      d: (20,30)
      g: (-20,0)
      s: (20,-30)
      b: (20,0)
```

Note: PMOS has drain/source swapped vs NMOS (d at bottom, s at top).

#### NPN BJT
```
chn_prim 1.0

SYMBOL npn
  desc: NPN bipolar junction transistor

  pins [3]:
    c  inout
    b  in
    e  inout

  params [1]:
    model = NPN

  spice_prefix: Q
  spice_format: "@name @c @b @e @model"

  drawing:
    lines:
      (0,-15) (0,15)
      (-20,0) (0,0)
      (0,-10) (20,-30)
      (0,10) (20,30)
      (14,22) (20,30)
      (12,27) (20,30)
    text: (25,0) "@name"
    pin_positions:
      c: (20,-30)
      b: (-20,0)
      e: (20,30)
```

#### Voltage Source
```
chn_prim 1.0

SYMBOL vsource
  desc: Independent voltage source

  pins [2]:
    p  inout
    n  inout

  params [1]:
    dc = 0

  spice_prefix: V
  spice_format: "@name @p @n dc=@dc"

  drawing:
    lines:
      (0,-30) (0,-15)
      (0,15) (0,30)
      (0,-12) (0,-6)
      (-3,-9) (3,-9)
      (-3,9) (3,9)
    circle: (0,0) r=15
    text: (20,0) "@name"
    text: (20,10) "@dc"
    pin_positions:
      p: (0,-30)
      n: (0,30)
```

#### Ground Symbol
```
chn_prim 1.0

SYMBOL gnd
  desc: Ground symbol (net "0")

  pins [1]:
    gnd  inout

  params [0]:

  drawing:
    lines:
      (0,-10) (0,3)
      (-8,3) (8,3)
      (-8,3) (0,10)
      (8,3) (0,10)
    pin_positions:
      gnd: (0,-10)
```

#### VDD Symbol
```
chn_prim 1.0

SYMBOL vdd
  desc: Power supply symbol

  pins [1]:
    vdd  inout

  params [0]:

  drawing:
    lines:
      (0,10) (0,0)
      (-12,0) (12,0)
    text: (0,-8) "VDD"
    pin_positions:
      vdd: (0,10)
```

#### Lab Pin (Net Label)
```
chn_prim 1.0

SYMBOL lab_pin
  desc: Label / net name pin

  pins [1]:
    p  inout

  params [1]:
    lab = ""

  drawing:
    circle: (0,0) r=1
    circle: (0,0) r=3
    text: (-4,-6) "@lab"
    pin_positions:
      p: (0,0)
```

#### VCVS (4-terminal controlled source)
```
chn_prim 1.0

SYMBOL vcvs
  desc: Voltage-controlled voltage source

  pins [4]:
    p   inout
    n   inout
    cp  in
    cn  in

  params [1]:
    gain = 1

  spice_prefix: E
  spice_format: "@name @p @n @cp @cn @gain"

  drawing:
    lines:
      (0,-30) (0,-15)
      (0,15) (0,30)
      (0,-8) (0,-4)
      (-2,-6) (2,-6)
      (-2,6) (2,6)
      (-30,-10) (-15,-10)
      (-30,10) (-15,10)
    lines:
      (0,-15) (12,0)
      (12,0) (0,15)
      (0,15) (-12,0)
      (-12,0) (0,-15)
    text: (18,0) "@name"
    pin_positions:
      p: (0,-30)
      n: (0,30)
      cp: (-30,-10)
      cn: (-30,10)
```

#### Hierarchical Port Pins
```
chn_prim 1.0

SYMBOL input_pin
  desc: Input port (hierarchical)
  pins [1]:
    p  in
  params [1]:
    lab = ""
  drawing:
    lines:
      (0,0) (-4,0)
      (-4,0) (-10,-6)
      (-10,-6) (-22,-6)
      (-22,-6) (-22,6)
      (-22,6) (-10,6)
      (-10,6) (-4,0)
    text: (-13,0) "@lab"
    pin_positions:
      p: (0,0)
```

```
chn_prim 1.0

SYMBOL output_pin
  desc: Output port (hierarchical)
  pins [1]:
    p  out
  params [1]:
    lab = ""
  drawing:
    lines:
      (0,0) (-4,0)
      (-4,-6) (-4,6)
      (-4,6) (-14,6)
      (-14,6) (-20,0)
      (-20,0) (-14,-6)
      (-14,-6) (-4,-6)
    text: (-12,0) "@lab"
    pin_positions:
      p: (0,0)
```

### Pin Position Conventions

Standard pin offsets (relative to instance origin):

| Device | Pin | Position | Notes |
|--------|-----|----------|-------|
| **NMOS** | d | (20,-30) | Drain at top |
| | g | (-20,0) | Gate at left |
| | s | (20,30) | Source at bottom |
| | b | (20,0) | Body at right-center |
| **PMOS** | d | (20,30) | Drain at bottom (swapped!) |
| | g | (-20,0) | Gate at left |
| | s | (20,-30) | Source at top (swapped!) |
| | b | (20,0) | Body at right-center |
| **NPN** | c | (20,-30) | Collector at top |
| | b | (-20,0) | Base at left |
| | e | (20,30) | Emitter at bottom |
| **PNP** | c | (20,30) | Collector at bottom |
| | b | (-20,0) | Base at left |
| | e | (20,-30) | Emitter at top |
| **Two-terminal** | p | (0,-30) | Positive/first at top |
| | n | (0,30) | Negative/second at bottom |
| **gnd** | gnd | (0,-10) | Connection at top |
| **vdd** | vdd | (0,10) | Connection at bottom |
| **lab_pin** | p | (0,0) | At center |

---

## 3. .chn_tb (Testbench)

Testbenches are functionally identical to `.chn` files. Same header (`chn_testbench 1`), same `TESTBENCH` section. The `.chn_tb` extension signals intent: this file instantiates a DUT and adds stimulus for simulation.

### Testbench Conventions

1. **DUT instantiation**: Use `subckt` kind with `sym=<schematic_name>`
   ```
   Xdut  subckt  x=-290  y=-120  sym=two_stage_opamp
   ```

2. **Voltage sources as stimulus**:
   ```
   Vdd  vsource  x=-150  y=0  sym=vsource  value=1.8
   Vin  vsource  x=70  y=0  sym=vsource  value=0 PULSE(0 1.8 0 20p 20p 500p 1n)
   Vinac  vsource  x=290  y=0  sym=vsource  value=DC 0 AC 1
   ```

3. **Load components**:
   ```
   Cload  capacitor  x=190  y=120  sym=capa  value=5p  device=capacitor
   Rload  resistor  x=130  y=120  sym=res  value=10k  device=resistor
   ```

4. **Net bridging**: Same-named `lab_pin` instances connect DUT ports to stimulus
   ```
   inp  lab_pin  x=-290  y=-150  sym=lab_pin    # at DUT port
   inp  lab_pin  x=290  y=-150  sym=lab_pin     # at stimulus source
   ```

### Real Example: RC Low-Pass Step Response

```
chn_testbench 1

TESTBENCH TB RC Lowpass Step
  instances:
    Xdut  subckt  x=-130  y=0  sym=rc_lowpass
    Vin  vsource  x=20  y=0  sym=vsource  value=0 PULSE(0 1 0 1n 1n 10u 20u)
    vin  lab_pin  x=-130  y=-30  sym=lab_pin
    vin  lab_pin  x=20  y=-30  sym=lab_pin
    vout  lab_pin  x=-130  y=30  sym=lab_pin
    gnd0  gnd  x=20  y=40  sym=gnd

  wires:
    -130 -30 20 -30
    20 -30 20 -30
```

### Real Example: Op-Amp Open-Loop AC

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

---

## 4. Available Primitives

All `.chn_prim` files live in `crates/core/primitives/`. Current set:

### Passives
| File | SPICE Prefix | Pins |
|------|-------------|------|
| `resistor.chn_prim` | R | p, n |
| `resistor3.chn_prim` | R | p, n, tap |
| `capacitor.chn_prim` | C | p, n |
| `inductor.chn_prim` | L | p, n |
| `coupling.chn_prim` | K | (mutual inductor) |
| `tline.chn_prim` | T | inp, inm, outp, outm |

### Sources
| File | SPICE Prefix | Pins |
|------|-------------|------|
| `vsource.chn_prim` | V | p, n |
| `isource.chn_prim` | I | p, n |
| `vcvs.chn_prim` | E | p, n, cp, cn |
| `vccs.chn_prim` | G | p, n, cp, cn |
| `cccs.chn_prim` | F | p, n + vsense |
| `ccvs.chn_prim` | H | p, n + vsense |
| `behavioral.chn_prim` | B | p, n |

### Semiconductors
| File | SPICE Prefix | Pins |
|------|-------------|------|
| `nmos.chn_prim` | M | d, g, s, b |
| `pmos.chn_prim` | M | d, g, s, b |
| `nmos3.chn_prim` | M | d, g, s |
| `pmos3.chn_prim` | M | d, g, s |
| `npn.chn_prim` | Q | c, b, e |
| `pnp.chn_prim` | Q | c, b, e |
| `njfet.chn_prim` | J | d, g, s |
| `pjfet.chn_prim` | J | d, g, s |
| `diode.chn_prim` | D | p, n |
| `zener.chn_prim` | D | p, n |

### Switches
| File | SPICE Prefix | Pins |
|------|-------------|------|
| `vswitch.chn_prim` | S | p, n, cp, cn |
| `iswitch.chn_prim` | W | p, n + vsense |

### Connectivity & Hierarchy
| File | Purpose |
|------|---------|
| `gnd.chn_prim` | Ground (net "0") |
| `vdd.chn_prim` | Power rail |
| `lab_pin.chn_prim` | Net label |
| `input_pin.chn_prim` | Hierarchical input port |
| `output_pin.chn_prim` | Hierarchical output port |
| `inout_pin.chn_prim` | Hierarchical bidirectional port |

### Special
| File | Purpose |
|------|---------|
| `ammeter.chn_prim` | Zero-ohm current probe |
| `probe.chn_prim` | Voltage probe marker |
| `spice_block.chn_prim` | SPICE subcircuit block |
| `digital_block.chn_prim` | Digital/Verilog block |
| `verilog_a_block.chn_prim` | Verilog-A block |

---

## 5. Project Configuration (config.toml)

Tells SchemifyRS where to find files:

```toml
name = "my-project"
pdk = "sky130"

[paths]
chn = ["schematics/*", "blocks/**/*.chn"]
chn_prim = ["primitives/*"]
chn_tb = ["testbenches/*"]

[plugins]
enabled = ["linting"]
disabled = []

[simulation]
spice_include_paths = ["/path/to/pdk/libs"]
```

---

## 6. Parsing Details

Parser in `crates/io/src/reader.rs` — line-oriented state machine:

1. Read header line -> determine file type and version
2. Match top-level section (`SYMBOL`, `TESTBENCH`, `PLUGIN`, `PYSPICE`, `DOCUMENTATION`)
3. Within section, match subsections (`instances:`, `wires:`, `pins [N]:`, `params [N]:`, `drawing:`, etc.)
4. All strings interned via `lasso::Rodeo` -> `Sym` (4-byte handle)
5. Coordinates parsed as `i32`
6. Colors parsed as `#RRGGBB` hex

Writer in `crates/io/src/writer.rs` — emits from `Schematic` struct back to text format.

### Key parsing rules
- Lines starting with `#` inside drawing sections are comments
- Empty lines between sections are ignored
- Indentation is 2 or 4 spaces (parser handles both)
- `.parameters{` must appear on line immediately after instance
- Wire coordinates are always integers
- Pin directions are case-insensitive
