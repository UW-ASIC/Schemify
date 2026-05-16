# simulation

Backend-agnostic circuit simulation via PySpice-rs. Turns a Schematic into a PySpice circuit definition, manages testbench lifecycle, parses normalized results, and provides gm/Id MOSFET sizing optimization with simulation-in-the-loop.

## Language

### Netlist generation

**Netlist**:
A text representation of a Schematic's electrical connectivity and component values, suitable for simulation. Generated from a Schematic as PySpice Python code (circuit definition), consumed by PySpice-rs which handles backend-specific emission internally.
_Avoid_: SPICE file (format-specific — PySpice abstracts this), circuit description

**Circuit Definition**:
The auto-generated top section of a Testbench File. Contains PySpice-rs `circuit.*` calls that mirror the Schematic's instances, nets, and properties. Regenerated on every schematic change. Users must not edit this section.
_Avoid_: netlist (overloaded), template (too generic)

### Testbench

**Testbench File**:
A `.py` file with two sections separated by a marker comment. The top section is the auto-generated Circuit Definition (non-editable). The bottom section is user-written PySpice-rs code: stimulus, analysis commands, measurement extraction. One Testbench File per simulation scenario. Lives alongside the `.chn` schematic file.
_Avoid_: analysis script (too vague), simulation file

**Testbench Overlay**:
A read-only visual projection of a Testbench's stimulus circuitry onto the schematic canvas. The Testbench File's Python code emits SPICE (via PySpice-rs); the import module's spice parser converts that SPICE into schematic geometry; the canvas renders it as a ghost overlay. Not real schematic data — purely visual.
_Avoid_: testbench schematic (it's not a schematic, it's a projection)

### Simulation

**Backend**:
The SPICE simulator engine that PySpice-rs drives: ngspice (default), Xyce, LTspice, Spectre, or VacaSk. Selected at runtime via toolbar dropdown. PySpice-rs handles all backend-specific netlist syntax, option mapping, and result normalization.
_Avoid_: simulator (too broad — a Backend is the specific engine PySpice-rs delegates to)

**Analysis**:
A simulation type the user writes in the Testbench File using PySpice-rs Python API: `sim.operating_point()`, `sim.ac(...)`, `sim.transient(...)`, etc. Tier 1 analyses (op, dc, ac, tran, noise, tf, sens, pz, disto) are portable across all Backends. Tier 2 (pss, hb, s-param) work on 2+ Backends. Tier 3 are vendor-specific (`sim.spectre.*`, `sim.xyce.*`).
_Avoid_: simulation (too broad), test

**Waveform**:
A series of data points from a simulation: an independent variable (time, frequency) paired with a dependent variable (voltage, current). May be complex-valued for AC Analysis. PySpice-rs normalizes node naming and current conventions across Backends before returning Waveforms.
_Avoid_: trace, signal, curve, plot

**Simulation Result**:
The complete output of running a Testbench File: status, Waveforms, operating point values, scalar Measurements, and errors. Returned as JSON on stdout, parsed by Schemify into the `SimResult` type.
_Avoid_: output, response

**Measurement**:
A scalar quantity extracted from simulation results in the Testbench File's Python code. The user's script prints Measurements as JSON to stdout. For optimizer-linked Testbenches, each Measurement is a named scalar that the optimizer reads per iteration.
_Avoid_: metric (used by the optimizer internally), extraction

### Optimizer

**Specification**:
A performance target for the optimizer. Defines what the design must achieve — minimize power, gain greater than 40 dB, bandwidth above 1 MHz. Has a kind (minimize, maximize, greater_equal, less_equal, equal, range).
_Avoid_: constraint (a Specification *produces* constraints), goal, objective (internal term)

**Observation**:
A single evaluated design point in the optimizer. Contains the design variables, computed objectives, and constraint values. Can be feasible or infeasible.
_Avoid_: sample, trial, evaluation

**gm/Id**:
The design methodology used by the optimizer. Relates transconductance efficiency (gm/Id) to transistor sizing. Uses lookup tables built from characterization data or analytical EKV models.
_Avoid_: sizing methodology (too vague)

**Linked Testbench**:
A Testbench File associated with a specific component for optimizer use. Each Linked Testbench prints named scalar Measurements as JSON. The optimizer automatically discovers all Linked Testbenches for a component, runs them per iteration with updated parameters, and reads back the scalar outputs to evaluate Specifications.
_Avoid_: optimization script (it's a regular Testbench with scalar outputs)

## Relationships

- A **Circuit Definition** is generated from a Schematic (defined in the schematic module) as PySpice-rs Python code
- A **Testbench File** contains one **Circuit Definition** (auto-generated, top) and user-written **Analysis** code (bottom)
- A **Testbench File** is executed by spawning `python3`; PySpice-rs selects the **Backend** at runtime
- A **Backend** is selected via toolbar dropdown; PySpice-rs handles all backend-specific netlist emission and result parsing
- A **Simulation Result** is returned as JSON on stdout and contains zero or more **Waveforms**, operating point values, **Measurements**, and errors
- A **Measurement** is a named scalar extracted in the Testbench File's Python code
- A **Testbench Overlay** is produced by: Testbench emits SPICE (PySpice-rs) -> spice parses it -> canvas renders as ghost geometry
- A **Linked Testbench** is a Testbench File associated with a component; the optimizer runs all Linked Testbenches per iteration
- A **Specification** defines a target for the optimizer; evaluated against scalar **Measurements** from **Linked Testbenches**
- An **Observation** is one point in a **gm/Id** sweep, containing Measurements for all design variables

## Example dialogue

> **Dev:** "When I click 'Simulate', what happens?"
> **Domain expert:** "Schemify regenerates the **Circuit Definition** at the top of the **Testbench File** from the current Schematic. Then it spawns `python3 testbench.py`. The user's code in the bottom half creates a simulator, picks a **Backend** (or uses the toolbar default), runs **Analyses**, and prints a **Simulation Result** as JSON to stdout. Schemify parses that JSON into **Waveforms** and **Measurements**."

> **Dev:** "What if I change the backend?"
> **Domain expert:** "The toolbar dropdown sets the **Backend** — ngspice, Xyce, LTspice, Spectre, or VacaSk. PySpice-rs handles all the differences: netlist syntax, option names, result format normalization. Tier 1 **Analyses** work on any **Backend**. If the user's code uses vendor-specific features (`sim.spectre.*`), PySpice-rs validates compatibility before spawning the simulator."

> **Dev:** "How does the testbench overlay work?"
> **Domain expert:** "When you hover a testbench pill in the canvas, Schemify asks PySpice-rs to emit the SPICE netlist for that **Testbench File**. The `spice` importer parses that SPICE into schematic geometry — instances, wires, placement. The canvas renders it as a ghost **Testbench Overlay** on top of the real schematic. It's read-only — not actual schematic data."

> **Dev:** "How does the optimizer use simulation?"
> **Domain expert:** "You define **Specifications** — 'gain > 40 dB', 'power < 1 mW'. Each component has **Linked Testbenches** — regular Testbench Files that print named scalar **Measurements** as JSON. The optimizer sweeps the **gm/Id** space, runs all **Linked Testbenches** per iteration with updated parameters, collects the scalar outputs, and evaluates the **Specifications**. The best feasible **Observation** gives you the transistor sizes."

## Flagged ambiguities

- **"Netlist"** is used for three things: `Netlist.zig` (generation namespace with `emitPySpice`), `SpiceIF.Netlist` (IR builder struct for netlist preview), and the conceptual output text. The domain concept is the PySpice Circuit Definition, not the IR builder.
- **"Metric"** is used in the optimizer (`DeviceMetrics`, `matchMetric`) but overlaps with **Measurement** in the simulation sense. The glossary reserves Measurement for post-simulation scalar extraction and avoids "metric" as a synonym.
- **Testbench Overlay** currently reads `.chn_tb` schematic files and ghost-draws their wires (TbOverlay.zig). The new model would instead have PySpice-rs emit SPICE from the Python testbench code, then spice converts that to geometry. This is a significant change from the current wire-cache approach.
- **Results contract**: The JSON schema for stdout is not yet defined. Need to specify exact format for Waveforms, Measurements, and errors that the Python script must produce.
