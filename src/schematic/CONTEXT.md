# schematic

Domain model for a schematic editor. Owns every type that represents a circuit document: instances, wires, pins, nets, connectivity, geometry, device catalog, and file serialization.

## Language

### Circuit structure

**Schematic**:
A single-page circuit drawing containing Instances, Wires, and geometry. The central document type. Stored as `.chn` files.
_Avoid_: design, circuit (too broad), diagram

**Instance**:
A placed component on a Schematic. Has identity (name), position, properties, and connections. "R1 at (200, 300)" is an Instance.
_Avoid_: component, element, part, symbol

**Wire**:
A drawn segment connecting two points on a Schematic. Geometry, not electrical identity. Has two endpoints and an optional Net name.
_Avoid_: trace, route, connection

**Net**:
An electrical node: all points in the Schematic that are electrically connected. Derived from Wire topology and Pin positions via union-find resolution.
_Avoid_: signal, node (too generic), connection

**Pin**:
A named electrical connection point on a Symbol. Has a direction (input, output, inout, power, ground) and a position relative to the Symbol origin.
_Avoid_: terminal, port

**Connection**:
A binding between a Pin and a Net on a specific Instance. "Pin A of R1 is on net VDD" is a Connection.
_Avoid_: conn, net-pin pair, terminal assignment

**Property**:
A named parameter on an Instance that affects its electrical behavior or annotation. Key-value pair. Examples: `W=1u`, `L=180n`, `R=10k`.
_Avoid_: attribute, parameter (overloaded with SPICE `.param`), field

### Devices and symbols

**Device**:
The electrical identity of an Instance: what Pins it has, how it emits to SPICE, what prefix it uses. Resolved from the Instance's symbol name via the device catalog or PDK.
_Avoid_: cell, primitive (more specific)

**Primitive**:
A built-in Device with embedded geometry and Pin definitions. Always available, not user-editable. Schemify ships with 36 Primitives.
_Avoid_: built-in, standard cell

**Symbol**:
The visual definition of a Device: geometry and Pin layout. Every Instance references one. Primitives have implicit Symbols; Subcircuits and custom Devices have explicit `.chn` symbol files.
_Avoid_: shape, icon, cell

**Subcircuit**:
An Instance whose internals are defined by another Schematic. Supports hierarchy — you can descend into it to see its contents. Emits an `X` line in SPICE.
_Avoid_: hierarchical block, module, macro

### Organization

**Project**:
A directory of related Schematics sharing a PDK and configuration. Defined by a `Config.toml` file. Contains schematics, testbenches, and primitives.
_Avoid_: workspace, library, design (too overloaded)

**Testbench**:
A Schematic that wraps a design-under-test with stimulus, analysis directives, and measurements for simulation. Has file extension `.chn_tb`.
_Avoid_: test harness, simulation setup, stimulus file

**PDK** (Process Design Kit):
A foundry-specific library of Devices available in a manufacturing process. Maps cell names to electrical identities, provides SPICE models, and defines device parameters. A Schematic targets one PDK.
_Avoid_: process, technology, cell library (too narrow)

## Relationships

- A **Schematic** contains zero or more **Instances**, **Wires**, and geometry
- An **Instance** references one **Symbol** and has zero or more **Properties** and **Connections**
- An **Instance** is resolved to a **Device** via the device catalog or the active **PDK**
- A **Wire** contributes to exactly one **Net** (determined by connectivity resolution)
- A **Net** spans one or more **Wires** and **Pin** endpoints
- A **Connection** binds one **Pin** on one **Instance** to one **Net**
- A **Primitive** is a **Device** with an embedded **Symbol** — built-in, always available
- A **Subcircuit** is an **Instance** backed by another **Schematic**
- A **Testbench** is a **Schematic** that wraps another **Schematic** for simulation
- A **Project** contains one or more **Schematics** and **Testbenches**, targeting one **PDK**

## Example dialogue

> **Dev:** "When I place a resistor, is that an Instance or a Device?"
> **Domain expert:** "You place an **Instance**. The **Instance** references a **Symbol** (the resistor shape) and resolves to a **Device** (how it emits to SPICE). The **Instance** is what lives on the **Schematic** — the **Device** is the electrical knowledge behind it."

> **Dev:** "What's the difference between a Primitive and a Symbol?"
> **Domain expert:** "A **Primitive** is a built-in **Device** that ships with Schemify — it has its geometry and Pins baked in. A **Symbol** is the visual definition any **Instance** references. Every **Primitive** has an implicit **Symbol**, but you can also create custom **Symbols** as `.chn` files."

> **Dev:** "When are Nets created?"
> **Domain expert:** "**Nets** don't exist until you run net resolution. You draw **Wires** and place **Instances** with **Pins** — then the resolver walks the **Wire** topology using union-find and determines which points are electrically connected. That's when **Nets** and **Connections** are established."

## Flagged ambiguities

- **"Schemify"** is both the product name and the central struct in code. In domain language, the concept is **Schematic** — "Schemify" is the application, not the document.
- **"Property"** is overloaded in the codebase: it stores electrical parameters, structural metadata (name, position — duplicated from Instance fields), symbol-level metadata (`ann.*`, `spice_format`), and plugin data blocks. The glossary definition covers only the domain-meaningful sense: electrical parameters and annotations.
- **"Cell"** appears in PDK code (`CellRef`, `CellTier`) but is not a separate domain concept — it's a Device as defined by a specific PDK.
- **"Port"** appears during file reading (port instance synthesis) — a Pin promoted to the interface of a Subcircuit, visible to the parent Schematic. Not yet a first-class domain concept.
