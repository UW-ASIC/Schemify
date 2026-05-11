# Simulation

Running SPICE simulations, generating netlists, and viewing results.

---

## Supported Backends

| Backend | Description | Key / Menu |
| --- | --- | --- |
| ngspice | Open-source SPICE simulator | F5 / Simulate > Run (ngspice) |
| Xyce | Sandia parallel SPICE simulator | Simulate > Run (Xyce) |

Both simulators must be installed and available in your system PATH. Schemify invokes them as external processes.

### Verifying Installation

```bash
# Check ngspice
ngspice --version

# Check Xyce
Xyce --version
```

If either command fails, install the simulator through your package manager or from source.

---

## Simulation Workflow

1. **Draw your circuit** — place components, draw wires, set device parameters
2. **Add simulation directives** — open **Simulate > Edit Spice Code** to write `.tran`, `.ac`, `.dc`, or other SPICE commands
3. **Generate the netlist** — press **N** (or let the simulator auto-generate)
4. **Run the simulation** — press **F5** for ngspice, or use the Simulate menu for Xyce
5. **View results** — open **Simulate > Waveform Viewer** to plot signals

---

## Netlist Generation

Schemify converts your schematic hierarchy into a SPICE-compatible netlist.

| Key | Command | Mode |
| --- | --- | --- |
| N | `:netlist` | Hierarchical — subcircuits become `.SUBCKT` blocks |
| Shift+N | `:netlist-top-only` | Top-level only — no subcircuit expansion |
| — | `:netlist-flat` | Flat — all subcircuits inlined into one level |

### How Netlisting Works

- Each instance maps to a SPICE element using its primitive's `spice_format` string
- Wire connectivity is extracted from junction analysis
- Pin names become net names in the netlist
- The SPICE code block (if any) is appended at the end
- Instances with `spice_ignore` set are excluded

### Viewing the Netlist

- Press **Shift+A** to toggle the netlist view panel
- Use `:print-netlist` to output the netlist to the terminal
- The generated netlist is also stored temporarily for the simulator to use

---

## SPICE Code (Simulation Directives)

Each schematic can have a SPICE code block containing simulation commands and control statements.

### Editing SPICE Code

- **Simulate > Edit Spice Code** opens the editor dialog
- Command bar: `:set-spice-code`

### Examples

**Transient analysis:**
```spice
.tran 1n 100n
.control
run
plot v(out) v(in)
.endc
```

**AC analysis:**
```spice
.ac dec 100 1 1G
.control
run
plot vdb(out) vp(out)
.endc
```

**DC sweep:**
```spice
.dc V1 0 5 0.01
.control
run
plot i(V1)
.endc
```

**Operating point:**
```spice
.op
.control
run
print all
.endc
```

### Xyce Syntax Differences

Xyce does not support `.control`/`.endc` blocks. Use `.PRINT` statements instead:

```spice
.tran 1n 100n
.PRINT TRAN V(out) V(in)
```

---

## Running a Simulation

| Action | Key / Menu |
| --- | --- |
| Run with ngspice | F5 |
| Run with Xyce | Simulate > Run (Xyce) |

When you run a simulation:

1. Schemify generates the netlist (hierarchical mode)
2. The SPICE code block is appended
3. The simulator is invoked as an external process
4. Output is captured and parsed
5. Results are available in the waveform viewer

The status bar shows simulation progress. Errors from the simulator appear in the status bar and log output.

---

## Waveform Viewer

Open from **Simulate > Waveform Viewer** or the `:open-waveform-viewer` command.

The waveform viewer displays simulation results (raw file data) as plotted signals. You can zoom, pan, and select signals to display.

---

## Simulation Annotation

After running a simulation, annotate the schematic with operating-point data:

| Command | Description |
| --- | --- |
| `:annotate-op` | Show DC operating point values on the schematic (voltages, currents) |
| `:clear-annotations` | Remove all annotations |

Annotations appear as text labels next to instances and nets, showing bias point values from the most recent simulation.

---

## Net Highlighting

Trace signal paths through the hierarchy using net highlighting.

| Key | Action |
| --- | --- |
| K | Highlight nets connected to selected objects (cycles through 8 colors) |
| Shift+K | Unhighlight all nets |
| Ctrl+K | Unhighlight all nets |

Highlights propagate automatically:

- **Downward** — highlighting a net connected to a subcircuit pin highlights the corresponding internal net
- **Upward** — highlighting a port net inside a subcircuit highlights the connected parent net

---

## Design Checks

Run checks before simulation to catch common errors.

| Check | Key / Command | Description |
| --- | --- | --- |
| Duplicate names | # (Shift+3) | Highlights instances with duplicate names |
| Auto-rename | Ctrl+# | Fixes duplicates by appending suffixes |
| Pin mismatch | `:check-pin-mismatch` | Port/net name discrepancies |
| Dangling nets | `:check-dangling-nets` | Unconnected wire endpoints |
| Overlapping | `:check-overlapping-instances` | Stacked instances |
| Run all | `:run-all-checks` | Execute all checks at once |

---

## Verilog Export

Generate a structural Verilog netlist from your schematic:

- **File > Export Netlist** (selects Verilog format)
- Command bar: `:export-verilog`

This produces a `.v` file with module declarations matching your hierarchy.

---

## Export Formats

| Format | Menu / Command | Extension |
| --- | --- | --- |
| SPICE netlist | N / Simulate > Generate Netlist | `.spice` |
| Verilog | File > Export Netlist | `.v` |
| SVG | File > Export SVG / `:export-svg` | `.svg` |
| PNG | File > Export PNG / `:export-png` | `.png` |
| PDF | File > Export PDF / `:export-pdf` | `.pdf` |

PNG and PDF export require `rsvg-convert` or `inkscape` on the system PATH.

---

## Troubleshooting

### "Simulator not found"

The simulator binary is not in your PATH. Install ngspice or Xyce and verify with `ngspice --version` or `Xyce --version`.

### Netlist errors

- Check for duplicate instance names (press **#** to highlight them)
- Verify all instances have valid connections (no floating pins)
- Ensure pin names match between parent and child schematics

### Simulation runs but no output

- Verify your SPICE code block includes analysis commands (`.tran`, `.ac`, `.dc`, or `.op`)
- For ngspice, include a `.control` / `run` / `.endc` block
- For Xyce, include `.PRINT` statements specifying which signals to record
