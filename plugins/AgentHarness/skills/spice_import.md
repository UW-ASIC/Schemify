# SpiceImport Plugin

Import ngspice netlists into Schemify schematics with automatic placement and wiring.

## Command

```
plugin spiceimport <filepath>
```

Parses the SPICE file, auto-detects type, and imports into the current schematic.

## Supported Syntax

### Elements
`R C L D M Q J V I E G F H B X` (subcircuit instances)

### Directives
`.subckt/.ends`, `.model`, `.param`, `.global`, `.include`, `.lib`

### Analyses
`.ac`, `.dc`, `.tran`, `.op`, `.noise`, `.tf`

### Measures
`.meas` / `.measure`

### Other
`.control/.endc` blocks, line continuation (`+`), comments (`*`, `$`, `;`)

## File Extensions

`.sp`, `.spice`, `.cir`, `.net`, `.spi`

## Type Inference

| Condition | Detected Type |
|-----------|---------------|
| `.subckt` definitions present | Component (`.chn`) |
| Analysis directives / `.control` | Testbench (`.chn_tb`) |
| Both | Component + Testbench pair |

## Options

- **Flatten hierarchy**: Merge all subcircuits into a single flat schematic (set via panel checkbox)

## Panel Features

The SpiceImport panel (OVERLAY) provides:
1. File path display
2. Flatten hierarchy checkbox
3. Parse button — preview before importing
4. Preview: subcircuit list, element counts by type, analyses, measures
5. Import buttons: as Component, as Testbench, or Both

## Auto-Detection

When opening a `.chn` file, SpiceImport checks for a companion SPICE file
with the same base name (e.g., `amp.chn` -> `amp.sp`).

## Workflow

1. Write or obtain a SPICE netlist file
2. Import: `plugin spiceimport /path/to/netlist.sp`
3. The plugin parses, places devices, and wires them automatically
4. Review and adjust placement as needed
