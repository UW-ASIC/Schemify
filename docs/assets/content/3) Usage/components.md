# Built-in Components Reference

Schemify ships with a standard library of primitive components. All primitives are `.chn_prim` files.

## Passive Components

### Resistor (`res`)

```
R1  resistor  value=10k  footprint=0402
```

SPICE: `R<name> <n+> <n-> <value>`

Parameters: `value`, `tc1`, `tc2`, `m` (multiplicity), `footprint`

### Capacitor (`capa`)

```
C1  capacitor  value=100n  footprint=0402
```

SPICE: `C<name> <n+> <n-> <value> [IC=<initial>]`

Parameters: `value`, `ic`, `m`, `footprint`

### Inductor (`ind`)

```
L1  inductor  value=10u
```

SPICE: `L<name> <n+> <n-> <value>`

Parameters: `value`, `ic`, `m`

## MOSFETs

### NMOS (`nmos4`)

```
M1  nmos  model=nch  w=2u  l=100n  nf=1  m=1
```

SPICE: `M<name> <d> <g> <s> <b> <model> w=<w> l=<l> nf=<nf> m=<m>`

Parameters: `model`, `w`, `l`, `nf`, `m`, `ad`, `as`, `pd`, `ps`

### PMOS (`pmos4`)

```
M2  pmos  model=pch  w=4u  l=100n  nf=1  m=1
```

Same format as NMOS.

## Bipolar Transistors

### NPN (`npn`)

```
Q1  npn  model=2N3904  m=1
```

SPICE: `Q<name> <c> <b> <e> [<sub>] <model> [m=<m>]`

### PNP (`pnp`)

```
Q2  pnp  model=2N3906  m=1
```

## Diodes

```
D1  diode  model=1N4148  m=1
```

SPICE: `D<name> <a> <k> <model> [m=<m>]`

## Sources

### Voltage Source (`vsource`)

```
V1  vsource  value=1.8
```

SPICE: `V<name> <n+> <n-> <value>`

Supports: DC, AC, transient (PULSE, SIN, PWL, etc.)

Parameters: `value` (DC), `ac`, `type`, `pulse_params`...

### Current Source (`isource`)

```
I1  isource  value=100u
```

### Behavioral Sources

| Kind   | SPICE | Description                       |
| ------ | ----- | --------------------------------- |
| `vcvs` | E     | Voltage-controlled voltage source |
| `vccs` | G     | Voltage-controlled current source |
| `ccvs` | H     | Current-controlled voltage source |
| `cccs` | F     | Current-controlled current source |

## Connectivity Symbols

| Symbol    | Description                                |
| --------- | ------------------------------------------ |
| `vdd`     | Power rail label (connects to VDD net)     |
| `gnd`     | Ground label (connects to 0/GND net)       |
| `lab_pin` | Net label (names a wire net)               |
| `ipin`    | Input port (for subcircuits)               |
| `opin`    | Output port (for subcircuits)              |
| `iopin`   | Bidirectional port                         |
| `noconn`  | No-connect marker (suppresses DRC warning) |

## Simulation Primitives

| Symbol               | Description                                             |
| -------------------- | ------------------------------------------------------- |
| `code`               | SPICE code block (`.model`, `.param`, `.include`, etc.) |
| `code_shown`         | SPICE code block, visible in schematic                  |
| `simulator_commands` | Simulation analysis commands (`.tran`, `.ac`, etc.)     |
| `probe`              | Voltage/current measurement probe                       |
| `ammeter`            | Current measurement (zero-volt voltage source)          |

## PDK-Specific Components

PDK components are installed via Volare and appear under the PDK namespace:

```
sky130_fd_pr__nfet_01v8     # SKY130 1.8V NFET
sky130_fd_pr__pfet_01v8     # SKY130 1.8V PFET
sky130_fd_pr__res_xhigh_po  # SKY130 high-resistance poly resistor
```

```

```
