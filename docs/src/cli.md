# Command Line Interface

Every GUI action in Schemify is available as a CLI subcommand. This makes Schemify fully scriptable.

## Basic Usage

```sh
schemify [OPTIONS] [COMMAND]
```

**Options:**
- `--file <PATH>` / `-f <PATH>` -- schematic file to operate on
- `--save` -- write changes back to the file after executing the command

## Common Commands

### File Operations

```sh
# Create and save a new schematic (starts empty)
schemify --file new_circuit.chn file-save

# Reload from disk
schemify --file circuit.chn reload-from-disk
```

### Placing Components

```sh
# Place a resistor
schemify --file circuit.chn place-device \
  --symbol-path resistor --name R1 \
  --x 100 --y 200 --save

# Place a MOSFET with rotation
schemify --file circuit.chn place-device \
  --symbol-path nmos --name M1 \
  --x 300 --y 400 --rotation 1 --save

# Place a ground symbol
schemify --file circuit.chn place-device \
  --symbol-path gnd --name GND1 \
  --x 100 --y 300 --save
```

### Wiring

```sh
# Add a wire from (0,0) to (100,0)
schemify --file circuit.chn add-wire \
  --x0 0 --y0 0 --x1 100 --y1 0 --save

# Add a bus wire
schemify --file circuit.chn add-wire \
  --x0 0 --y0 0 --x1 200 --y1 0 --bus --save
```

### Editing

```sh
# Set a component property
schemify --file circuit.chn set-instance-prop \
  --idx 0 --key value --value 10k --save

# Rename a component
schemify --file circuit.chn set-instance-prop \
  --idx 0 --key name --value R_feedback --save
```

### Transforms

```sh
# Rotate, flip, nudge (operates on selection)
schemify --file circuit.chn rotate-cw --save
schemify --file circuit.chn flip-horizontal --save
schemify --file circuit.chn nudge-right --save
schemify --file circuit.chn align-to-grid --save
```

### Simulation

```sh
# Run simulation on a testbench
schemify --file testbench.chn_tb run-sim
```

### SPICE Import

```sh
# Import a SPICE netlist into a schematic
schemify --file output.chn import-spice my_circuit.spice --save
```

## Scripting Example

Build a voltage divider entirely from the command line:

```sh
#!/bin/sh
FILE=divider.chn

# Place components
schemify -f $FILE place-device --symbol-path vsource --name V1 --x 0 --y 100 --save
schemify -f $FILE place-device --symbol-path resistor --name R1 --x 200 --y 0 --save
schemify -f $FILE place-device --symbol-path resistor --name R2 --x 200 --y 200 --save
schemify -f $FILE place-device --symbol-path gnd --name GND1 --x 100 --y 300 --save

# Set values
schemify -f $FILE set-instance-prop --idx 0 --key value --value 5 --save
schemify -f $FILE set-instance-prop --idx 1 --key value --value 10k --save
schemify -f $FILE set-instance-prop --idx 2 --key value --value 10k --save

# Wire them up
schemify -f $FILE add-wire --x0 0 --y0 0 --x1 200 --y1 0 --save
schemify -f $FILE add-wire --x0 200 --y0 100 --x1 200 --y1 200 --save

echo "Voltage divider created: $FILE"
```

## Full Command List

Run `schemify --help` for the complete list. Every `Command` variant in the engine is exposed as a subcommand:

```sh
schemify help
```

Categories include: view, file, selection, clipboard, tool, dialogs, undo/redo, deletion, duplication, transform, placement, wiring, properties, and simulation.
