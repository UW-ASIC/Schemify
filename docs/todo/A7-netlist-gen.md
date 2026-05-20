# A7: Netlist Generation

**Wave**: 2
**Depends on**: A1 (connectivity), A4 (SPICE IR)

## Goal
Generate SPICE netlists from schematic + connectivity. Builds `SpiceNetlist` IR (from A4), resolves nets via `Connectivity` (from A1). Supports hierarchical, flat, and top-only modes.

## Branch
`feat/netlist-gen`

## Zig Reference Files
- `../Schemify/src/simulation/Netlist.zig` — high-level netlist emission
- `../Schemify/src/schematic/pyspice.zig` — PySpice-rs Python script generation
- `../Schemify/src/schematic/types.zig` — DeviceKind → prefix mapping

## Crate/File Map

### sim (`crates/sim/src/`)
- NEW `netlist.rs` — `generate_netlist(&Schematic, &Connectivity, &Rodeo, mode) -> SpiceNetlist`
- NEW `device_map.rs` — `DeviceKind` → `SpiceComponent` mapping, pin order, model lookup
- NEW `pyspice.rs` — PySpice-rs Python script emission (alternative output format)

## API

```rust
pub enum NetlistMode {
    Hierarchical,  // subcircuits as .subckt definitions
    Flat,          // inline all subcircuits
    TopOnly,       // only top-level, subcircuits as black boxes
}

/// Main entry point — handler calls this with pre-resolved connectivity
pub fn generate_netlist(
    schematic: &Schematic,
    connectivity: &Connectivity,
    interner: &Rodeo,
    mode: NetlistMode,
    dialect: Dialect,
) -> SpiceNetlist;

/// Alternative: emit PySpice-rs Python script
pub fn generate_pyspice(
    schematic: &Schematic,
    connectivity: &Connectivity,
    interner: &Rodeo,
    mode: NetlistMode,
) -> String;
```

## Device Mapping

Each `DeviceKind` maps to:
- SPICE prefix letter (R, C, L, M, Q, D, V, I, E, F, G, H, X)
- Pin order (e.g. MOSFET: drain, gate, source, bulk)
- Whether it needs a `.model` reference
- Default spice_line format (from PrimEntry)

```rust
pub struct DeviceMapping {
    pub prefix: char,
    pub pin_order: &'static [&'static str],
    pub needs_model: bool,
}
```

## Netlist Generation Algorithm
1. Walk instances in schematic
2. For each instance, look up DeviceMapping
3. Resolve pin connections via `connectivity.instance_connections[idx]`
4. Map pin names to net names via connectivity
5. Build `SpiceComponent` with resolved node names
6. Collect `.model` definitions from schematic.model_defs
7. Collect `.param` from schematic properties
8. Collect `.include` from PDK config
9. Collect analyses + measurements from testbench (if applicable)
10. Return assembled `SpiceNetlist`

## Checklist
- [ ] `device_map.rs`: DeviceKind → prefix, pin order, needs_model
- [ ] `device_map.rs`: handle all 84 DeviceKind variants (many map to same pattern)
- [ ] `netlist.rs`: top-only mode (simplest — no hierarchy descent)
- [ ] `netlist.rs`: hierarchical mode (emit .subckt defs, instantiate with X)
- [ ] `netlist.rs`: flat mode (inline subcircuits, rename nets to avoid collision)
- [ ] `netlist.rs`: handle power/ground symbols (Gnd, Vdd → global nets)
- [ ] `netlist.rs`: handle lab_pin / port symbols (→ subcircuit ports)
- [ ] `netlist.rs`: include .model defs in output
- [ ] `pyspice.rs`: emit Python script using PySpice-rs library calls
- [ ] Tests: simple RC circuit → netlist string
- [ ] Tests: MOSFET with model → correct pin order + .model
- [ ] Tests: hierarchical subcircuit instantiation
- [ ] Tests: flat mode net renaming
- [ ] Commit after each meaningful change

## Do NOT Touch
- `sim/src/ir.rs` — A4 defined these, consume only
- `sim/src/emit.rs` — A4 defined these, call `emit_netlist()` with your `SpiceNetlist`
- `core/` — types already defined
- `handler/` — handler calls your `generate_netlist()` fn, you don't touch handler
- `display/` — not your crate
