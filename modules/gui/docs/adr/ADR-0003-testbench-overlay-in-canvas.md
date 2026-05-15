# ADR-0003: Testbench Overlay Rendered as Canvas Geometry

## Status: accepted

## Context

The testbench overlay shows buttons and ghost wires inside the schematic canvas. Two implementation options:

1. **dvui widgets** (buttons, floating windows) positioned over the canvas.
2. **Canvas-native rendering** using `LineBatch` and `drawLabel`, with manual hit-testing.

## Decision

Option 2: render the overlay entirely through `LineBatch` (backgrounds, borders) and `drawLabel` (button text), with manual `hitButton()` point-in-rect tests during the pre-input pass.

The overlay processes dvui events *before* `interaction.handleInput()` so button clicks are consumed before the canvas pan/select logic sees them.

## Consequences

- The overlay is visually consistent with canvas elements — same font rendering, same coordinate system, same clipping.
- No z-order fighting with dvui widget windows.
- Manual hit-testing is simple (point-in-rect) but must be maintained alongside the layout constants. Adding rounded corners or animations would require significant manual work.
- The overlay cannot receive keyboard focus or participate in dvui's tab-order system.
- Ghost wires are cached in a fixed-size array (`MAX_CACHED_WIRES = 512`) with an arena allocator that resets on hover change, avoiding per-frame allocation.
