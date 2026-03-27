# Schemify

## What This Is

Schemify is a cross-platform EDA schematic editor built in Zig with dvui (native via raylib, web via WASM/canvas). It has a plugin system (ABI v6), DOD core data model (struct-of-arrays), command dispatch architecture, and supports SPICE netlist generation for circuit simulation. The codebase is organized into layers: `core/` (data model, parsing, netlist), `state.zig` (app state container), `commands/` (dispatch + handlers), `gui/` (rendering + UI), `plugins/` (runtime + installer), and `utility/` (reusable data structures).

## Core Value

**A fast, extensible schematic editor with clean DOD architecture, deep plugin customizability, and comprehensive documentation.**

## Current Milestone: v3.0 DOD Refactor + Plugin Ecosystem

**Goal:** Transform Schemify into a properly data-oriented, plugin-first platform through three parallel workstreams.

**Workstream A — DOD Refactor (Phases 1-7):**
- New data structures in utility/ (SlotMap, SparseSet, RingBuffer, Pool, SmallVec, PerfectHash)
- Core data model with generational handles (stable indices across delete)
- O(1) command queue, selection, and undo history
- PluginIF protocol expansion (~20 new tags for lifecycle hooks, event subscriptions, command interception)
- GUI files all under 400 LOC, comptime dispatch tables

**Workstream B — Plugin Fix (Phases 8-13):**
- Fix build_plugin_helper broken reference
- Wire PluginPanels to runtime widget lists
- Fix Theme.applyJson stub and set_config key mismatch
- Build SchemifyPython host for Python plugins
- Get all 6 plugins working end-to-end (EasyImport, Themes, PDKLoader, Optimizer, Circuit Visionary, GmID Visualizer)
- Fix WASM plugin support for web build

**Workstream C — Plugin Docs (Phases 14-18):**
- Quick start guides for all 5 languages
- Architecture, API reference, widget gallery
- Enhanced per-language guides
- User docs (installation, configuration, troubleshooting)
- Examples walkthrough

## Requirements

### Validated

- XSchem `.sch`/`.sym` text format parser (DOD struct-of-arrays) — v1.0 Phase 1
- `xschemrc` Tcl-subset parser with variable expansion — v1.0 Phase 1
- Full Tcl expression evaluator for xschemrc — v1.0 Phase 1
- Schemify core data model (`Schemify.zig`) — existing core
- Plugin ABI v6 binary protocol — existing
- Command dispatch architecture (56 immediate + 18 undoable) — existing
- CHN v2 file format reader/writer — existing core
- SPICE netlist generation with backend selection — existing core

### Active

- [ ] 6 new data structures in utility/ (SlotMap, SparseSet, RingBuffer, Pool, SmallVec, PerfectHash)
- [ ] Generational handles replace raw indices for instances/wires
- [ ] O(1) CommandQueue, History, Selection
- [ ] PluginIF protocol expanded with ~20 new lifecycle/event/interception tags
- [ ] All GUI files under 400 LOC
- [ ] All 6 existing plugins build and run end-to-end
- [ ] Plugin documentation: 18 documents across creator and user audiences
- [ ] Commands layer has no GUI framework imports (dvui)
- [ ] GUI never imports core directly — all access through state

### Out of Scope

- New GUI features (file explorer, marketplace, library browser functionality) — cleanup only
- EasyImport Phases 2-7 (discovery, translation, pipeline) — v1.0 milestone, paused
- Cadence Virtuoso import — separate milestone
- New plugin types (LSP, debugger) — future milestone
- Redo/undo improvements beyond RingBuffer — separate effort

## Context

- **src/**: ~22K lines across 62 Zig files in core/, commands/, gui/, plugins/, utility/
- **Core**: Schemify.zig (1392L), SpiceIF.zig (1391L), HdlParser.zig (1282L), Reader.zig (1087L), Netlist.zig (1056L)
- **GUI**: 24 files, Renderer.zig (844L) is the largest
- **Commands**: 14 files, 56 immediate + 18 undoable
- **Plugins**: 6 real plugins (EasyImport, Themes, PDKLoader, Optimizer, Circuit Visionary, GmID Visualizer) + WASM stub
- **Critical bugs**: build_plugin_helper refs deleted FileIO.zig; PluginPanels shows placeholder; Theme.applyJson is no-op; wasmPlugin.zig uses pre-v6 ABI
- **Performance**: CommandQueue.pop() is O(n), History eviction is O(n), Selection.isEmpty() requires iterator scan

## Constraints

- **Language**: Zig 0.15
- **Design**: Data-oriented design — struct-of-arrays, comptime tables, no OOP
- **Layer rule**: GUI -> state -> core (never GUI -> core directly)
- **ABI**: v6 backward compatible — extend, don't break
- **Build**: Must pass `zig build` after each phase; `nix develop` for dev environment

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Three parallel workstreams | DOD refactor, plugin fix, and docs are independent enough to parallelize | v3.0 roadmap |
| SlotMap for entity storage | Raw indices invalidated by swapRemove break undo system | Phase 2 |
| RingBuffer for queues | orderedRemove(0) is O(n), ring is O(1) with no allocator | Phase 3 |
| SparseSet for Selection | DynamicBitSet requires O(total) scan, SparseSet is O(selected) | Phase 3 |
| ABI v6 extend-only | Existing plugins skip unknown tags — backward compatible | Phase 4 |
| SchemifyPython for Python plugins | CPython embedding needed for 3 plugins; host multiplexes I/O | Phase 10 |
| Data structures in utility/ | Reusable across core/state/commands; no domain dependency | Phase 1 |

## Evolution

This document evolves at phase transitions and milestone boundaries.

---
*Last updated: 2026-03-27 — Milestone v3.0 initialized*
