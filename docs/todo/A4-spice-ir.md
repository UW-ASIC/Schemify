# A4: SPICE IR

## Goal
Backend-agnostic SPICE intermediate representation. Tagged union of components + value types + emit functions per backend dialect. Foundation for netlist generation (wave 2).

## Branch
`feat/spice-ir`

## Decisions (resolved)
- Lives in `sim` crate
- Pure data types + emit logic (no connectivity, no schematic access)
- Sim receives `&Connectivity` from handler as arg (wave 2 netlist gen)
- Backend dialects: ngspice, Xyce, LTspice, Spectre
- Core `SimResult` types already exist — IR complements them

## Zig Reference Files
- `../Schemify/src/simulation/SpiceIF.zig` — SpiceComponent union, Value enum, emit logic
- `../Schemify/src/simulation/Netlist.zig` — netlist structure (for understanding what IR serves)
- `../Schemify/src/simulation/results.zig` — result parsing (context only)

## Crate/File Map

### sim (`crates/sim/src/`)
- `lib.rs` — module declarations
- NEW `ir.rs` — `SpiceComponent`, `Value`, `SpiceNetlist` types
- NEW `emit.rs` — `emit_component()`, `emit_netlist()` per backend
- NEW `dialect.rs` — backend-specific formatting rules

### sim Cargo.toml additions
```toml
[dependencies]
schemify-core = { path = "../core" }
```
No additional deps needed — pure string formatting.

## SPICE Component IR

```rust
// sim/src/ir.rs

#[derive(Debug, Clone)]
pub enum SpiceComponent {
    Resistor { name: String, nodes: [String; 2], value: Value },
    Capacitor { name: String, nodes: [String; 2], value: Value },
    Inductor { name: String, nodes: [String; 2], value: Value },
    Diode { name: String, nodes: [String; 2], model: String },
    Mosfet { name: String, nodes: [String; 4], model: String, params: Vec<Param> },
    Bjt { name: String, nodes: [String; 3], model: String, params: Vec<Param> },
    Jfet { name: String, nodes: [String; 3], model: String, params: Vec<Param> },
    Vsource { name: String, nodes: [String; 2], value: Value },
    Isource { name: String, nodes: [String; 2], value: Value },
    Vcvs { name: String, nodes: [String; 4], gain: Value },
    Vccs { name: String, nodes: [String; 4], gain: Value },
    Ccvs { name: String, nodes: [String; 4], gain: Value },
    Cccs { name: String, nodes: [String; 4], gain: Value },
    Subcircuit { name: String, nodes: Vec<String>, subckt_name: String, params: Vec<Param> },
    Raw { text: String },  // escape hatch for unsupported components
}

#[derive(Debug, Clone)]
pub enum Value {
    Literal(f64),
    Param(String),           // parameter reference
    Expr(String),            // expression: {gm * 2}
    SiLiteral(String),       // "10k", "1u", "100n" — human-readable
}

#[derive(Debug, Clone)]
pub struct Param {
    pub key: String,
    pub value: Value,
}

#[derive(Debug, Clone)]
pub struct SpiceNetlist {
    pub title: String,
    pub includes: Vec<String>,
    pub params: Vec<Param>,
    pub models: Vec<ModelStatement>,
    pub subcircuits: Vec<SubcircuitDef>,
    pub components: Vec<SpiceComponent>,
    pub analyses: Vec<Analysis>,
    pub measurements: Vec<Measurement>,
    pub options: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct ModelStatement {
    pub name: String,
    pub model_type: String,
    pub params: Vec<Param>,
}

#[derive(Debug, Clone)]
pub struct SubcircuitDef {
    pub name: String,
    pub ports: Vec<String>,
    pub params: Vec<Param>,
    pub components: Vec<SpiceComponent>,
    pub models: Vec<ModelStatement>,
}

#[derive(Debug, Clone)]
pub enum Analysis {
    Op,
    Dc { source: String, start: f64, stop: f64, step: f64 },
    Ac { variation: AcVariation, points: u32, start: f64, stop: f64 },
    Tran { step: f64, stop: f64, start: f64 },
    Noise { output: String, source: String, variation: AcVariation, points: u32, start: f64, stop: f64 },
}

#[derive(Debug, Clone, Copy)]
pub enum AcVariation { Dec, Oct, Lin }

#[derive(Debug, Clone)]
pub struct Measurement {
    pub name: String,
    pub analysis: String,
    pub expr: String,
}
```

## Backend Dialects

```rust
// sim/src/dialect.rs

#[derive(Debug, Clone, Copy)]
pub enum Dialect {
    NgSpice,
    Xyce,
    LtSpice,
    Spectre,
}
```

Key differences per dialect:
- **NgSpice**: `.param`, `.model`, `.meas`, standard SPICE
- **Xyce**: `.PARAM`, case-insensitive, different `.MEASURE` syntax
- **LTSpice**: `.param`, `.meas`, some proprietary extensions
- **Spectre**: completely different syntax (`resistor r0 (a b) r=10k`)

## Emit Functions

```rust
// sim/src/emit.rs

/// Emit a single component line
pub fn emit_component(comp: &SpiceComponent, dialect: Dialect) -> String;

/// Emit full netlist to string
pub fn emit_netlist(netlist: &SpiceNetlist, dialect: Dialect) -> String;

/// Emit value with SI suffix
pub fn emit_value(val: &Value, dialect: Dialect) -> String;
```

## Checklist
- [ ] Create `sim/src/ir.rs` with all IR types
- [ ] Create `sim/src/dialect.rs` with `Dialect` enum
- [ ] Create `sim/src/emit.rs` with `emit_value()` for ngspice
- [ ] `emit_component()` for all component types (ngspice first)
- [ ] `emit_netlist()` full netlist emission (ngspice)
- [ ] Tests: resistor emit `R0 a b 10k`
- [ ] Tests: MOSFET emit with model + params
- [ ] Tests: subcircuit def + instantiation
- [ ] Tests: full netlist round-trip (build IR → emit → verify string)
- [ ] Tests: Value::SiLiteral formatting (10k, 1u, 100n, 1.5meg)
- [ ] Add Xyce dialect differences
- [ ] Add LTSpice dialect differences
- [ ] Add Spectre dialect (different syntax family)
- [ ] Tests: same circuit emitted in all 4 dialects
- [ ] Commit after each meaningful change

## Do NOT Touch
- `core/` — types already defined (SimResult, SpiceBackend)
- `handler/` — not your crate
- `display/` — not your crate
- Don't implement netlist generation from schematic (that's wave 2, needs connectivity)
- Don't implement result parsing (that's wave 2 backend integration)
- Don't add connectivity or schematic deps — IR is standalone
