# Primitives

How to create and use primitive device symbols in Schemify.

---

## What Is a Primitive?

A primitive (`.chn_prim` file) defines a device symbol — its pins, drawing, and netlist format. Unlike a hierarchical schematic, a primitive does not descend further; it maps directly to a SPICE element.

---

## Built-in Primitives

Schemify includes built-in primitive types you can place immediately:

| Category | Devices |
| --- | --- |
| MOSFET | NMOS, PMOS, NMOS3, PMOS3 |
| BJT | NPN, PNP |
| JFET | NJFET, PJFET |
| Passive | Resistor, Capacitor, Inductor |
| Diode | Diode, Zener |
| Source | VSource, ISource |
| Power | GND, VDD |
| Controlled | VCVS, VCCS, CCVS, CCCS |
| Misc | Transmission line, Switches, Probe, Ammeter |
| Pins | Input pin, Output pin, Inout pin, Label pin |

Place from the **Place** menu or use the `:insert-primitive <type>` command.

---

## Creating a New Primitive

### Using the Dialog

Go to **File > New Primitive** to open the creation dialog:

1. **Name** — the device name (becomes the filename)
2. **Type** — choose one:
   - **SPICE** — subcircuit with `.SUBCKT` template
   - **Behavioral** — B-element with expression
   - **Digital** — Verilog/VHDL HDL wrapper
3. **Pins** — comma-separated pin names (e.g., `in,out,vdd,gnd`)
4. Click **Create**

This generates a `.chn_prim` file in the working directory.

### Primitive File Format

```
chn_prim 1.0

SYMBOL my_resistor
  desc: Simple resistor
  pins [2]:
    p  i
    n  o
  params [1]:
    R = 1k
  spice_prefix: R
  spice_format: "@name @pins @R"
  drawing:
    rect: (-12,-20) (12,20)
    text: (0,0) "R"
    pin_positions:
      p: (0,-30)
      n: (0,30)
```

### Key Fields

| Field | Description |
| --- | --- |
| `desc` | Human-readable description |
| `pins` | Pin names with direction (`i`=input, `o`=output, `io`=bidirectional) |
| `params` | Default parameter values |
| `spice_prefix` | SPICE device letter (R, C, M, Q, etc.) |
| `spice_format` | Netlist format string with `@name`, `@pins`, `@param` substitution |
| `drawing` | Symbol graphics (rect, text, line) |
| `pin_positions` | Pin placement coordinates |

---

## SPICE Prefix Convention

The first letter of the instance name determines the SPICE device type:

| Prefix | Device |
| --- | --- |
| R | Resistor |
| C | Capacitor |
| L | Inductor |
| D | Diode |
| M | MOSFET |
| Q | BJT |
| J | JFET |
| V | Voltage source |
| I | Current source |
| E | VCVS |
| G | VCCS |
| H | CCVS |
| F | CCCS |
| T | Transmission line |
| S | Switch |
| X | Subcircuit |
| B | Behavioral source |
