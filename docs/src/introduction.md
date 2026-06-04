# Schemify

**Schemify** is a fast, cross-platform schematic editor for analog, digital, and mixed-signal circuit design. Built in Rust with an immediate-mode GUI, it launches instantly and handles large designs without lag.

## Why Schemify?

- **Fast** -- native performance with a GPU-accelerated canvas. No Electron, no JVM.
- **Simulation-ready** -- integrated PySpice pipeline. Draw a circuit, press F5, see waveforms.
- **Portable** -- runs natively on Linux (X11/Wayland) and compiles to WebAssembly for the browser.
- **Git-friendly files** -- human-readable, line-oriented schematic format that diffs and merges cleanly.
- **Extensible** -- write plugins in Python, JavaScript, Rust, or any language that speaks JSON-RPC.
- **Fully keyboard-driven** -- every action has a shortcut. Mouse optional.

## Features at a Glance

| Category | Highlights |
|---|---|
| **Components** | 50+ built-in primitives: R, C, L, MOSFET, BJT, diode, op-amp, voltage/current sources, controlled sources, switches, probes |
| **Drawing** | Wire, line, arc, circle, polygon, text tools with snap-to-grid |
| **Editing** | Undo/redo, copy/paste, duplicate, rotate, flip, nudge, align-to-grid |
| **Hierarchy** | Schematics are reusable as subcircuits -- build complex designs from smaller blocks |
| **Simulation** | Multi-backend SPICE: NgSpice, Xyce, LTspice, Spectre. DC, AC, transient, noise, and more |
| **Plugins** | Sidebar panels, toolbar commands, canvas overlays, theme customization |
| **CLI** | Every GUI action is available as a CLI subcommand for scripting and automation |

## License

MIT
