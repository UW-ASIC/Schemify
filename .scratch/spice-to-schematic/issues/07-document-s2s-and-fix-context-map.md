# 07 — Document the s2s subsystem + fix CONTEXT-MAP drift

Status: ready-for-agent
Labels: docs
Crate: docs / schemify-handler
Complexity: S

## Problem

Repo documentation drifts from reality:
- `CONTEXT-MAP.md` shows a `devices` crate (and `schemify-devices` in CLAUDE.md)
  that is **not** a `Cargo.toml` member. Actual crates: core, handler, io,
  display, sim, plugins, engine.
- `CONTEXT-MAP.md` omits the entire s2s subsystem (the largest piece of handler).
- CLAUDE.md promises per-crate `CONTEXT.md` and `docs/adr/` directories; none
  exist in-tree (only inside `target/` build artifacts).

## Acceptance criteria

1. Add `crates/handler/src/s2s/CONTEXT.md` describing the
   parse → annotate → recognize → place → route → validate → convert pipeline
   and the s2s-IR (`s2s/ir/mod.rs`).
2. Update `CONTEXT-MAP.md`: remove the nonexistent `devices` crate, add the s2s
   subsystem, and reflect that PDK/devices types live in `core::devices`.
3. Either create the promised per-crate `CONTEXT.md` stubs + `docs/adr/`, or
   amend CLAUDE.md to match what actually exists. (Pick one; note the decision.)

## Notes

Pure docs — low risk, good first task to land before the feature work.
