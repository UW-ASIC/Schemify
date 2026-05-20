# A8: Vendor spice-to-schematic

**Wave**: 2
**Depends on**: nothing (can start anytime, low priority)

## Goal
Copy `spice-to-schematic` Rust source into `handler/src/import/`, eliminate external path dep. Strip CLI + pyo3 deps. Keep anyhow/thiserror/serde_json.

## Branch
`feat/vendor-spice-import`

## Source
- External: `/home/omare/Documents/Projects/Active/SpiceToSchematic/rust-src/`
- Current integration: `handler/src/spice_import.rs` (thin conversion layer)

## Crate/File Map

### handler (`crates/handler/src/`)
- `spice_import.rs` → rename to `import/mod.rs` (conversion layer stays)
- NEW `import/` directory — vendored spice-to-schematic source
- Copy from `SpiceToSchematic/rust-src/`:
  - `parser/` — SPICE netlist parser
  - `ir/` — intermediate representation (Circuit, Subcircuit, Net, Instance)
  - `annotation/` — power/ground classification
  - `recognition/` — device/block recognition
  - `placement/` — grid-based component placement
  - `routing/` — Manhattan wire routing
  - `output/` — SchemifyBackend (pin geometry)
  - `validation/` — netlist validation
  - `config/` — parser config
  - `lib.rs` → becomes `import/spice/mod.rs` or similar

### handler Cargo.toml changes
- REMOVE: `spice-to-schematic = { path = "../../../SpiceToSchematic", default-features = false }`
- ADD (to handler deps): `anyhow = "1"`, `thiserror = "2"`, `serde_json = "1"`
- DO NOT ADD: `clap`, `pyo3`

## Steps
1. Copy `rust-src/` contents into `handler/src/import/spice/`
2. Remove `main.rs` (CLI entry point — not needed)
3. Remove `python.rs` (pyo3 bindings — not needed)
4. Update module paths (lib.rs exports → mod.rs re-exports)
5. Update `spice_import.rs` → `import/mod.rs` to use local paths instead of `spice_to_schematic::*`
6. Remove `spice-to-schematic` from handler Cargo.toml
7. Add `anyhow`, `thiserror`, `serde_json` to handler Cargo.toml
8. `cargo check` passes
9. Existing tests still pass

## Checklist
- [ ] Create `handler/src/import/` directory
- [ ] Copy spice-to-schematic rust-src into `import/spice/`
- [ ] Remove main.rs, python.rs from copied source
- [ ] Fix module paths and imports
- [ ] Move `spice_import.rs` to `import/mod.rs`
- [ ] Update handler Cargo.toml deps
- [ ] Update `handler/src/lib.rs` module declaration
- [ ] `cargo check` passes
- [ ] `cargo test` passes
- [ ] Commit

## Do NOT Touch
- `core/` — not your crate
- `display/` — not your crate
- `sim/` — not your crate
- Don't refactor the vendored code — just make it compile as a module
