# PRD: SPICE → Schematic (s2s) — gaps & enhancements

Status: ready-for-agent

## Important context — the importer already exists

The "spice-to-schematic module is missing" premise is **incorrect**. A complete
importer already ships:

- `crates/handler/src/spice_import.rs` — `import_spice(source, interner) ->
  Result<Schematic, String>` orchestrator, plus `import_pyspice` (runs `python3`,
  captures the emitted netlist).
- `crates/handler/src/s2s/` — ~13.5k lines across the full pipeline:
  - `parser/` — ngspice-compatible parser (continuation lines, `.param` expr
    eval, `.subckt` nesting, `.global`, X-card PDK reclassification). Device
    cards handled: M, Q, R, C, L, V, I, D, E/G/F/H, X (`parser/mod.rs:265-283`).
  - `annotation/` — power/ground classification, port-direction inference,
    diff-pair tagging.
  - `recognition/` — VF2 subgraph isomorphism (DiffPair, CurrentMirror,
    Cascode, PushPull, CommonSource, Wilson/Widlar, etc.).
  - `placement/` — constraint-based placement + simulated annealing.
  - `routing/` — A* orthogonal router with net-label fallback.
  - `validation/` — name/grid/rotation/orthogonality checks.
  - `output/` — pin geometry backends (`schemify.rs`, `xschem.rs`).
- Wired into: `Command::ImportSpice` (`dispatch.rs:523-577`), CLI
  `schemify import-spice` (`engine/src/main.rs:255-257`), and the build-time
  generation of ~90 example `.chn` files (`handler/build.rs:142-217`).
- Tests: 5 integration suites (~2.5k lines) in `crates/handler/tests/`.

So this folder tracks **enhancements and real gaps**, not a greenfield module.
Confirm with the user whether their intent was the gaps below or something else.

## Issues

- `01-device-card-coverage.md`   — J/K/S/W/B/T cards silently dropped
- `02-hierarchical-subckt-import.md` — child subckts not emitted as sheets
- `03-relayout-adapter.md`       — Schematic↔s2s-IR pure adapter (+ enables AutoLayout)
- `04-surface-validation.md`     — validation results not shown to user
- `05-ignored-card-diagnostics.md` — silent data loss on unknown cards
- `06-wasm-import-smoke-test.md` — raw-SPICE import under wasm; PySpice UX
- `07-document-s2s-and-fix-context-map.md` — docs + CONTEXT-MAP corrections
