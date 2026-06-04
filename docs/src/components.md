# Working with Components

Schemify ships with 50+ built-in component primitives covering analog, digital, and mixed-signal design.

## Component Library

### Passive Devices

| Device | Symbol | Pins | Key Parameters |
|---|---|---|---|
| Resistor | `resistor` | 2 | value (e.g., `10k`) |
| Capacitor | `capacitor` | 2 | value (e.g., `1p`) |
| Inductor | `inductor` | 2 | value (e.g., `10u`) |

### Transistors

| Device | Symbol | Pins | Key Parameters |
|---|---|---|---|
| NMOS | `nmos` | 3 or 4 | W, L, model |
| PMOS | `pmos` | 3 or 4 | W, L, model |
| NPN BJT | `npn` | 3 | model |
| PNP BJT | `pnp` | 3 | model |

### Diodes

| Device | Symbol | Pins | Key Parameters |
|---|---|---|---|
| Diode | `diode` | 2 | model |

### Sources

| Device | Symbol | Pins | Description |
|---|---|---|---|
| Voltage source | `vsource` | 2 | DC, AC, pulse, sine, etc. |
| Current source | `isource` | 2 | DC, AC, pulse, sine, etc. |
| VCVS | `vcvs` | 4 | Voltage-controlled voltage source |
| VCCS | `vccs` | 4 | Voltage-controlled current source |
| CCVS | `ccvs` | 4 | Current-controlled voltage source |
| CCCS | `cccs` | 4 | Current-controlled current source |

### Power & Ground

| Device | Symbol | Pins | Description |
|---|---|---|---|
| Ground | `gnd` | 1 | Ground reference node |
| VDD | `vdd` | 1 | Positive supply |
| Power flag | `power_flag` | 1 | Generic named power net |

### Probes & Labels

| Device | Symbol | Pins | Description |
|---|---|---|---|
| Net label | `lab_pin` | 1 | Names a net for connectivity |
| Voltage probe | `vprobe` | 1 | Marks a node for simulation output |
| Current probe | `iprobe` | 2 | Measures current through a branch |

## Placing Components

1. Open the component browser in the sidebar
2. Search or browse for the device you need
3. Click on the canvas to place it
4. Use **R** to rotate and **X** to flip before placing

Or from the CLI:

```sh
schemify --file circuit.chn place-device \
  --symbol-path resistor --name R1 \
  --x 200 --y 300 --save
```

## Editing Properties

Select a component and press **Q** to open the properties dialog. Each component has:

- **Name** -- unique instance identifier (e.g., R1, M1, V1)
- **Parameters** -- device-specific values (resistance, W/L, model name, etc.)
- **Position** -- X/Y coordinates on the grid
- **Orientation** -- rotation (0-3) and flip state

## Hierarchical Design

Any `.chn` schematic can be instantiated as a subcircuit inside another schematic. This enables hierarchical design:

1. Create a sub-block as its own `.chn` file
2. In the parent schematic, place it using the `subckt` device kind
3. The sub-block's ports become pins on the parent instance

This is how you build complex designs from reusable building blocks -- an op-amp, a bias network, or a digital cell can each be a self-contained schematic.

## Custom Primitives

Define your own symbols in `.chn_prim` files. A primitive definition includes:

- Pin positions and names
- Drawing geometry (lines, arcs, circles, text)
- SPICE format string with parameter substitution
- Default parameter values

See [File Formats](./file-formats.md) for the `.chn_prim` specification.
