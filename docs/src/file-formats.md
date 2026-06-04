# File Formats

Schemify uses three plain-text file formats. They are human-readable, line-oriented, and diff cleanly in version control.

## .chn -- Schematic

The primary schematic format. Each `.chn` file is a circuit that can also be instantiated as a subcircuit in another schematic.

```
chn 1

SCHEMATIC voltage_divider
  instances:
    R1  resistor  x=200  y=0  sym=resistor
      .parameters{  value=10k  }
    R2  resistor  x=200  y=200  sym=resistor
      .parameters{  value=10k  }
    V1  vsource  x=0  y=100  sym=vsource
      .parameters{  value=5  }
  wires:
    0 0 200 0
    200 100 200 200
```

### Structure

- **Header** -- `chn 1` (format version)
- **SCHEMATIC block** -- contains the circuit name
  - **instances** -- one line per component: `name  device_kind  x=N  y=N  sym=symbol  [rot=N] [flip=1]`
    - `.parameters{ key=value ... }` -- component parameters on a continuation line
  - **wires** -- one line per wire segment: `X0 Y0 X1 Y1  [bus=1] [color=#RRGGBB] [net_name]`

### Why Plain Text?

- `git diff` shows exactly which components changed
- Merge conflicts are resolvable by hand
- Grep for component names, net labels, or parameter values
- Scriptable with standard text tools

## .chn_prim -- Primitive Definition

Defines a component symbol with its graphical shape, pins, and SPICE mapping.

```
chn_prim 1

PRIMITIVE resistor
  pins:
    p  x=0  y=-40
    n  x=0  y=40
  parameters:
    value  default=1k
  spice_format: R@name @p @n @value
  drawing:
    line  0 -40  0 -30
    rect  -8 -30  8 30
    line  0 30  0 40
```

### Structure

- **pins** -- named connection points with relative positions
- **parameters** -- configurable values with defaults
- **spice_format** -- SPICE netlist template with `@`-substitution for name, pins, and parameters
- **drawing** -- graphical primitives: `line`, `rect`, `circle`, `arc`, `text`, `pin_position`

## .chn_tb -- Testbench

Identical in structure to `.chn`, but signals intent: this file instantiates a DUT and adds stimulus for simulation.

```
chn_testbench 1

TESTBENCH tb_inverter_vtc
  instances:
    INV  subckt  x=200  y=200  sym=cmos_inverter
    V1   vsource  x=0  y=200  sym=vsource
      .parameters{  dc=0  }
    VDD  vsource  x=200  y=0  sym=vsource
      .parameters{  dc=1.8  }
  wires:
    0 200 200 200
    200 0 200 100
```

The `subckt` device kind references another `.chn` file, making it the device under test.

## Config.toml

Project-level configuration lives in `Config.toml` alongside your schematics:

```toml
[project]
name = "my_circuits"

[simulation]
backend = "ngspice"
```
