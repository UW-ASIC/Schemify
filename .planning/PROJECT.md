# EasyImport — XSchem Project Converter

## What This Is

EasyImport is a Schemify plugin + CLI tool that converts XSchem projects into Schemify's native `.chn` format. It parses `xschemrc` configuration, resolves library paths and PDK references, builds a dependency tree from `.sch`/`.sym` files, and converts them into `.chn` (component), `.chn_tb` (testbench), and `.chn_prim` (primitive) files — placed alongside the originals. The result is a complete Schemify project with its own `Config.toml`.

## Core Value

**Lossless XSchem → Schemify conversion that produces identical SPICE netlists from both the original and converted project.**

## Requirements

### Validated

- ✓ XSchem `.sch`/`.sym` text format parser (DOD struct-of-arrays) — Validated in Phase 1
- ✓ `xschemrc` Tcl-subset parser with variable expansion — Validated in Phase 1
- ✓ Full Tcl expression evaluator for xschemrc (variable substitution, `[file dirname]`, `$env()`, nested expressions) — Validated in Phase 1
- ✓ Schemify core data model (`Schemify.zig`, `Types.zig`) — existing core

### Active
- [ ] Dependency tree builder — parse project, find all referenced `.sch`/`.sym`, determine conversion order (leaves first)
- [ ] File classification: `.sch` + `.sym` pair → `.chn`, `.sch` alone → `.chn_tb`, `.sym` alone → `.chn_prim`
- [ ] XSchem → Schemify IR translation (instances, wires, pins, properties, shapes)
- [ ] PDK library conversion — walk PDK `xschem/` dir, convert all `.sym` → `.chn_prim`, maintain directory structure
- [ ] In-place output — create `.chn` files alongside original `.sch` files
- [ ] `Config.toml` generation with glob patterns for converted files
- [ ] Symbol data loading — resolve instance symbols from search paths, extract pin/format info
- [ ] Companion `.sym` geometry merge into component `.chn` files
- [ ] ABI v6 plugin entry point with GUI panel for triggering conversion
- [ ] CLI interface for batch conversion (`zig build run -- --convert-xschem <path>`)
- [ ] Structural validation — verify instances/wires/pins match between original and converted
- [ ] Netlist roundtrip test — XSchem netlist vs Schemify netlist from converted project must match

### Out of Scope

- Cadence Virtuoso backend — deferred to future milestone, stub only
- Incremental re-conversion (watch mode) — not needed for v1
- GUI preview of conversion diff — future enhancement
- Reverse conversion (Schemify → XSchem) — different tool

## Context

- **Existing code**: Old EasyImport in `.cache/src_old/` has useful XSchemRC.zig and XSchem.zig parsers but impl.zig is over-abstracted (Runtime union, Backend trait, too many layers). Needs a ground-up rewrite with DOD principles.
- **Core types**: Schemify IR lives in `src/core/Schemify.zig` — flat struct-of-arrays (`Line`, `Rect`, `Wire`, `Pin`, `Instance` with indexed `Prop`/`Conn` arrays).
- **Plugin ABI**: v6 binary protocol (`schemify_process` entry point). Plugin communicates via `Reader`/`Writer` message batches.
- **XSchem format**: Text-based `.sch`/`.sym` files with `v {}` version block, `K {}` symbol blocks, `C {}` component instances, `N` wires, `T` text, `L` lines, `B` boxes, `A` arcs.
- **PDK**: Sky130A via volare. PDK root at `$HOME/.volare`. XSchem symbols in `<PDK_ROOT>/sky130A/libs.tech/xschem/`.
- **Build**: Plugin builds as shared library via `build.zig`, imports `schemify_sdk` dependency for core types.

## Constraints

- **Language**: Zig 0.15 — must match main Schemify build
- **Design**: Data-oriented design — struct-of-arrays, no OOP method chains, minimal abstraction layers
- **ABI**: Must conform to ABI v6 plugin protocol (single `schemify_process` entry point)
- **Compatibility**: Must handle real-world xschemrc files with Tcl variable expansion
- **Dependencies**: Only `core` and `PluginIF` from Schemify SDK. No external Tcl library — pure Zig Tcl evaluator.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| XSchem-only for v1 | Virtuoso is WIP, focus on getting one backend right | — Pending |
| Full Tcl evaluator | Real xschemrc files use nested Tcl expressions, minimal won't cut it | — Pending |
| In-place output | Users want converted files next to originals, not in a temp dir | — Pending |
| Rewrite impl.zig from scratch | Old code has too many layers (Runtime union, Backend trait, 1000+ line impl) | — Pending |
| Keep XSchemRC.zig + XSchem.zig | These parsers are solid, just need cleanup to match DOD style | — Pending |
| Both CLI + Plugin | CLI for automation/CI, Plugin for interactive use in Schemify | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd:transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd:complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-03-26 after Phase 1 completion*
