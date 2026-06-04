# Quick Start

This guide walks you through creating your first circuit in Schemify.

## Launch the GUI

```sh
schemify
# or, from the repo:
cargo run
```

Schemify opens with an empty schematic canvas and a grid.

## Place Your First Components

1. Open the component browser -- use the sidebar or press **Q** to open the properties dialog
2. Type a device name in the search (e.g., `resistor`, `capacitor`, `gnd`)
3. Click on the canvas to place the device
4. Press **Esc** to return to the select tool

Alternatively, use the CLI to place devices:

```sh
schemify --file my_circuit.chn place-device \
  --symbol-path resistor --name R1 --x 100 --y 200 --save
```

## Draw Wires

1. Press **W** to activate the wire tool
2. Click on a component pin to start a wire
3. Click again to place a corner or end the wire on another pin
4. Press **Esc** to stop drawing

## Edit Component Properties

1. Select a component by clicking on it
2. Press **Q** to open the properties dialog
3. Change values (e.g., resistance, capacitance) and close the dialog

## Save Your Work

Press **Ctrl+S** to save. Schemify uses `.chn` files -- a human-readable, git-friendly format.

## Run a Simulation

1. Create a testbench (`.chn_tb` file) that instantiates your circuit and defines stimulus
2. Press **F5** to run the simulation
3. View results in the simulation output panel

See [Simulation Overview](./simulation.md) for details.

## What's Next?

- [User Interface](./user-interface.md) -- learn the layout and panels
- [Drawing Tools](./drawing-tools.md) -- master all the drawing tools
- [Keyboard Shortcuts](./keybindings.md) -- speed up your workflow
- [Components](./components.md) -- explore the built-in component library
