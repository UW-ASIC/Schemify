# Device Kinds Reference

All device kinds recognized by Schemify's CHN parser and netlist generator.

## Electrical Devices

| Kind | SPICE Prefix | Description |
|------|-------------|-------------|
| `nmos` | M | N-channel MOSFET (3 or 4 terminal) |
| `pmos` | M | P-channel MOSFET (3 or 4 terminal) |
| `resistor` | R | Resistor |
| `capacitor` | C | Capacitor |
| `inductor` | L | Inductor |
| `npn` | Q | NPN BJT |
| `pnp` | Q | PNP BJT |
| `diode` | D | Diode |
| `vsource` | V | Voltage source |
| `isource` | I | Current source |
| `vcvs` | E | Voltage-controlled voltage source |
| `vccs` | G | Voltage-controlled current source |
| `ccvs` | H | Current-controlled voltage source |
| `cccs` | F | Current-controlled current source |
| `ammeter` | V | Zero-volt source for current measurement |
| `subckt` | X | Subcircuit instance |

## Label / Connectivity Devices

| Kind | Description |
|------|-------------|
| `lab_pin` | Net label (assigns name to a net) |
| `vdd` | Power supply label |
| `gnd` | Ground label |
| `ipin` | Subcircuit input port |
| `opin` | Subcircuit output port |
| `iopin` | Subcircuit bidirectional port |
| `noconn` | No-connect marker |

## Non-Electrical (filtered from netlist)

| Kind | Description |
|------|-------------|
| `title` | Title block / annotation |
| `code` | SPICE code block (`.model`, `.include`, etc.) |
| `launcher` | UI action launcher |
| `probe` | Measurement probe |

## Standard Primitive Library

A standard library of `.chn_prim` files ships with the toolchain:

```
chn_prim/nmos
chn_prim/pmos
chn_prim/resistor
chn_prim/capacitor
chn_prim/inductor
chn_prim/diode
chn_prim/npn
chn_prim/pnp
chn_prim/vsource
chn_prim/isource
chn_prim/vcvs
chn_prim/vccs
chn_prim/ccvs
chn_prim/cccs
```

PDK-specific primitives (e.g., `sky130_prim/nfet_01v8`) are installed separately and reference PDK `.lib` files via Volare.

## Complete Example

### Component (cmos_inv.chn)

```
chn 1

SYMBOL cmos_inv
  pins:
    Z  out  x=40  y=0
    A  in   x=-40 y=0
  params:
    format   = @name @pinlist @symname WN=@WN WP=@WP LLN=@LLN LLP=@LLP m=@m
    template = name=X1 WN=15u WP=45u LLN=3u LLP=3u m=1
    type     = subcircuit

SCHEMATIC
  instances:
    p2  opin  x=370 y=-230  sym=opin  name=p2
    p1  ipin  x=60  y=-230  sym=ipin  name=p1
    l1  vdd   x=140 y=-400  sym=vdd   name=l1
    M2  pmos  x=120 y=-350  sym=pmos4
      .parameters{ name=M2  model=p  w=WP  l=LLP  m=1 }
    M1  nmos  x=120 y=-170  sym=nmos4
      .parameters{ name=M1  model=n  w=WN  l=LLN  m=1 }

  nets:
    A   -> M2.g, M1.g
    VDD -> M2.s, M2.b
    Z   -> M1.d

  wires:
    80 -230 80 -170 A
    140 -400 140 -380 VDD
```

### Primitive (nmos.chn_prim)

```
chn_prim 1

SYMBOL nmos
  pins:
    d  inout  x=20  y=-30
    g  in     x=-20 y=0
    s  inout  x=20  y=30
  params:
    type     = nmos
    format   = @spiceprefix@name @pinlist @model @extra m=@m
    template = name=M1 model=M2N7002 device=2N7002 m=1
```
