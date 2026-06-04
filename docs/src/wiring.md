# Wiring & Connectivity

Schemify provides several ways to create electrical connections between components.

## Drawing Wires

1. Press **W** to activate the wire tool
2. Click on a component pin to start
3. Click to add corner points (wires route in straight segments)
4. Click on another pin to finish the connection
5. Press **Esc** to cancel the current wire

Wires snap to the grid. Two pins connected by a wire (or chain of wires) are electrically equivalent.

## Net Labels

Use **net labels** (`lab_pin`) to connect nodes without drawing a wire between them. Any two pins with the same net label name are connected:

1. Place a `lab_pin` component near a wire or pin
2. Set its name (e.g., `CLK`, `VIN`, `OUT`)
3. All `lab_pin` instances with the same name form a single net

This keeps schematics clean when signals span large distances across the sheet.

## Power Symbols

Power symbols (`gnd`, `vdd`) are special-purpose net labels:

- **gnd** -- connects to the global ground net (node 0 in SPICE)
- **vdd** -- connects to the global VDD supply net

Place them near supply pins to avoid routing wires across the entire schematic.

## Buses

For multi-bit signals, wires can be marked as bus wires (drawn thicker). Bus wires carry bundled signals and are commonly used in digital and mixed-signal designs.

## Connectivity Analysis

Schemify automatically resolves connectivity:

- Every wire segment and label is assigned to a net
- The properties dialog shows which net each pin belongs to
- The simulation pipeline uses the resolved net-list to generate SPICE

If two pins appear disconnected (no wire path or shared label), they are on separate nets.

## Tips

- Keep wires short and use net labels for long-distance connections
- Name important nets -- it makes simulation output easier to read
- Use `gnd` everywhere instead of wiring to a single ground point
- Check for floating pins before simulating -- unconnected inputs cause simulation errors
