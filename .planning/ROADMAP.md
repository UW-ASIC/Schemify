# Roadmap: Schemify v3.0 — DOD Refactor + Plugin Ecosystem

## Overview

v3.0 transforms Schemify from a working-but-organically-grown EDA editor into a properly data-oriented, plugin-first platform. Three parallel workstreams: (A) refactor src/ with DOD data structures and minimize overhead, (B) get all existing plugins working end-to-end, (C) create comprehensive plugin documentation. Workstream A is the foundation — B and C can proceed in parallel once Phase 1 completes.

## Workstreams

| Stream | Phases | Focus |
|--------|--------|-------|
| A: DOD Refactor | 1–7 | New data structures, core/state/commands/GUI/PluginIF refactor, performance |
| B: Plugin Fix | 8–13 | Fix runtime, wire UI, get every plugin loading and rendering |
| C: Plugin Docs | 14–18 | Creator docs, user docs, API reference, examples walkthrough |

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3...): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

### Workstream A: DOD Refactor

- [ ] **Phase 1: Foundation Data Structures** - Build SlotMap, SparseSet, RingBuffer, Pool, SmallVec, PerfectHash in utility/ (~720 LOC, 6 new files)
- [ ] **Phase 2: Core Data Model** - Replace MultiArrayList with SlotMap for instances/wires, introduce generational Handles, extract NetResolver.zig (Schemify.zig 1392→400 LOC)
- [ ] **Phase 3: State & Queue Refactor** - CommandQueue→RingBuffer O(1), Selection→SparseSet O(1), History→RingBuffer, hot/cold layout validation
- [ ] **Phase 4: PluginIF Protocol Expansion** - ~20 new tags: lifecycle hooks, event subscriptions, command interception, custom rendering, context menu, status bar widgets
- [ ] **Phase 5: Commands Refactor** - CommandBuffer pattern for batched mutations, pool-allocated undo snapshots, PerfectHash vim dispatch
- [ ] **Phase 6: GUI Refactor** - Wire PluginPanels to runtime, comptime geometry dispatch, every file <400 LOC, split Renderer.zig
- [ ] **Phase 7: Performance Pass** - SIMD batch transforms, SparseSet iteration in Edit.zig, @setCold annotations, struct size validation

### Workstream B: Plugin Fix

- [ ] **Phase 8: Runtime Foundation** - Fix build_plugin_helper (broken FileIO.zig ref), wire PluginPanels→Runtime widgets, fix Theme.applyJson stub, handle missing output tags
- [ ] **Phase 9: EasyImport Plugin** - Create ABI v6 wrapper (currently a library, not a plugin), wire XSchem import UI, test with example .sch files
- [ ] **Phase 10: Themes Plugin** - Build SchemifyPython host (CPython embedder), fix set_config key mismatch, verify theme application end-to-end
- [ ] **Phase 11: PDKLoader & Optimizer** - Fix builds, verify panel rendering, wire PDKLoader to library browser rescan
- [ ] **Phase 12: Python Plugins** - Get Circuit Visionary and GmID Visualizer running via SchemifyPython host
- [ ] **Phase 13: WASM Plugins** - Rewrite wasmPlugin.zig for v6, create JS plugin host, test with wasm-smoke

### Workstream C: Plugin Documentation

- [ ] **Phase 14: Doc Infrastructure & Quick Start** - Create docs/plugins/creating/ and using/ dirs, write 5-minute quick start for all 5 languages
- [ ] **Phase 15: Architecture & API Reference** - Enhance architecture.md, expand API reference with all tags/SDKs/cross-language matrix
- [ ] **Phase 16: Widgets & Advanced Topics** - UI widget reference with gallery, advanced topics (multi-panel, state, file I/O, command interception)
- [ ] **Phase 17: Per-Language Guides & Distribution** - Enhance all 6 language guides, consolidate build & distribution doc
- [ ] **Phase 18: User Docs & Examples** - Installation, configuration, managing, troubleshooting, examples walkthrough

## Phase Details

### Phase 1: Foundation Data Structures
**Goal**: All reusable DOD data structures built, tested, and exported from utility/
**Depends on**: Nothing (first phase)
**Requirements**: DS-01 through DS-06
**Plans:** 3 plans
Plans:
- [ ] 01-01-PLAN.md — Dense SlotMap with generational Handle and SecondaryMap companion
- [ ] 01-02-PLAN.md — SparseSet, RingBuffer, and Pool allocator
- [ ] 01-03-PLAN.md — SmallVec, PerfectHash (gperf + CHD), lib.zig wiring, build.zig test entry
**Success Criteria**:
  1. SlotMap passes generational handle validation (insert, remove, get-after-remove returns null)
  2. SparseSet isEmpty/count/clear are O(1), iteration is O(k) for k selected items
  3. RingBuffer push/pop are O(1), pushOverwrite evicts oldest correctly
  4. Pool alloc/free are O(1), no fragmentation for same-size blocks
  5. SmallVec stores ≤N items inline with zero heap allocation
  6. PerfectHash comptime generates zero-collision lookup for known key sets
  7. All files under 250 LOC with comprehensive test blocks
  8. `zig build test` passes

### Phase 2: Core Data Model
**Goal**: Entity storage uses generational handles, indices are stable across delete operations
**Depends on**: Phase 1
**Requirements**: CORE-01 through CORE-05
**Success Criteria**:
  1. Instances and wires stored in SlotMap with Handle-based access
  2. swapRemove on instance does not invalidate handles held by undo system
  3. Dense iteration over instances is still contiguous (SlotMap.values())
  4. NetResolver.zig extracted, Schemify.zig under 400 LOC
  5. Reader/Writer roundtrip tests still pass

### Phase 3: State & Queue Refactor
**Goal**: All O(n) data structures in state/commands replaced with O(1) alternatives
**Depends on**: Phase 1
**Requirements**: STATE-01 through STATE-04
**Success Criteria**:
  1. CommandQueue uses RingBuffer — push/pop are O(1), no allocator needed
  2. History uses RingBuffer — pushOverwrite evicts oldest in O(1)
  3. Selection uses SparseSet — isEmpty is O(1), iteration is O(selected_count)
  4. Allocator parameter removed from all CommandQueue/History call sites

### Phase 4: PluginIF Protocol Expansion
**Goal**: Plugins can hook into selection, document lifecycle, command interception, custom rendering, and UI extension
**Depends on**: Phase 1
**Requirements**: PLUG-01 through PLUG-08
**Success Criteria**:
  1. All new tags roundtrip through Writer→Reader without data loss
  2. Event subscription bitfield filters delivery (plugins only get events they subscribe to)
  3. Backward compatible — existing plugins that ignore unknown tags continue to work
  4. SDK headers (C, Rust, Python, Go) updated with new tag constants

### Phase 5: Commands Refactor
**Goal**: Batched mutations via CommandBuffer, pool-allocated undo, comptime dispatch
**Depends on**: Phase 2, Phase 4
**Requirements**: CMD-01 through CMD-03
**Success Criteria**:
  1. CommandBuffer collects mutations during iteration, applies atomically
  2. Undo snapshots allocated from Pool, freed on History eviction
  3. delete_selected no longer iterates in reverse — CommandBuffer handles ordering

### Phase 6: GUI Refactor
**Goal**: PluginPanels renders real widgets, Renderer.zig split, all files <400 LOC
**Depends on**: Phase 3, Phase 4
**Requirements**: GUI-01 through GUI-04
**Success Criteria**:
  1. PluginPanels.drawPanelBody reads ParsedWidget list from runtime and renders via dvui
  2. Renderer.zig split into Renderer + PrimLookup + SymbolRenderer (each <400 LOC)
  3. Comptime geometry dispatch table replaces 5 repetitive loops
  4. ToolBar.zig split if >400 LOC

### Phase 7: Performance Pass
**Goal**: Measurable improvement in hot paths via SIMD, SparseSet, and annotation
**Depends on**: Phase 5, Phase 6
**Requirements**: PERF-01 through PERF-04
**Success Criteria**:
  1. Batch SIMD coordinate transforms in Renderer
  2. Edit.zig applyToSelected iterates only selected items (SparseSet dense loop)
  3. @setCold on error/infrequent paths
  4. comptime struct size assertions on Command, Instance, ParsedWidget

### Phase 8: Runtime Foundation
**Goal**: Plugin build system works, runtime renders widgets, theme application functions
**Depends on**: Nothing (can start immediately)
**Requirements**: PFIX-01 through PFIX-05
**Plans:** 3 plans
Plans:
- [x] 08-01-PLAN.md — Fix build_plugin_helper.zig (FileIO.zig ref, utility module) + Theme.applyJson implementation
- [ ] 08-02-PLAN.md — Runtime handler additions (request_refresh, register_keybind, push_command) + set_config key fix
- [ ] 08-03-PLAN.md — PluginPanels.drawPanelBody widget rendering + runtime pointer wiring
**Success Criteria**:
  1. build_plugin_helper.zig compiles (FileIO.zig reference fixed)
  2. PluginPanels.drawPanelBody renders ParsedWidget lists from runtime
  3. Theme.applyJson parses JSON and updates current_overrides
  4. runtime.zig handles request_refresh, register_keybind, push_command tags
  5. set_config key matches between runtime and Themes plugin

### Phase 9: EasyImport Plugin
**Goal**: EasyImport loads as ABI v6 plugin with GUI panel for XSchem import
**Depends on**: Phase 8
**Requirements**: PFIX-06, PFIX-07
**Success Criteria**:
  1. EasyImport exports schemify_process and schemify_plugin descriptor
  2. Plugin registers a right-sidebar panel with Scan/Convert buttons
  3. Converting example .sch files produces valid .chn output

### Phase 10: Themes Plugin
**Goal**: Themes load and apply via SchemifyPython host
**Depends on**: Phase 8
**Requirements**: PFIX-08 through PFIX-10
**Success Criteria**:
  1. SchemifyPython host embeds CPython and discovers .py scripts
  2. Themes plugin registers overlay panel
  3. Clicking a theme button changes editor colors

### Phase 11: PDKLoader & Optimizer
**Goal**: PDKLoader and Optimizer build, load, and render their panels
**Depends on**: Phase 8
**Requirements**: PFIX-11, PFIX-12
**Success Criteria**:
  1. Both plugins build with fixed build_plugin_helper
  2. Panels appear in Schemify with correct widgets
  3. PDKLoader scans and reports installed PDKs

### Phase 12: Python Plugins
**Goal**: Circuit Visionary and GmID Visualizer functional
**Depends on**: Phase 10
**Requirements**: PFIX-13, PFIX-14
**Success Criteria**:
  1. Circuit Visionary overlay panel loads and shows pipeline controls
  2. GmID Visualizer overlay panel loads and shows sweep controls

### Phase 13: WASM Plugins
**Goal**: WASM plugin loading works in web build
**Depends on**: Phase 8
**Requirements**: PFIX-15 through PFIX-17
**Success Criteria**:
  1. wasmPlugin.zig uses ABI v6 message-passing (no extern "host")
  2. JS plugin host can load, tick, and draw WASM plugins
  3. wasm-smoke example loads in web build

### Phase 14: Doc Infrastructure & Quick Start
**Goal**: Documentation directory structure and entry-point guide
**Depends on**: Nothing (can start immediately)
**Requirements**: DOC-01, DOC-02
**Plans:** 2 plans
Plans:
- [x] 14-01-PLAN.md — Directory restructure, file moves, internal link fixes, sidebar config update
- [ ] 14-02-PLAN.md — Quick start guide with 5-language note-taker plugin using VitePress code-group tabs
**Success Criteria**:
  1. docs/plugins/creating/ and docs/plugins/using/ directories exist
  2. Quick start guide shows working 5-minute plugin in all 5 languages
  3. VitePress sidebar updated with new structure

### Phase 15: Architecture & API Reference
**Goal**: Complete technical reference for plugin developers
**Depends on**: Phase 14
**Requirements**: DOC-03, DOC-04
**Success Criteria**:
  1. Architecture doc covers message lifecycle, event dispatch, memory model
  2. API reference lists every tag with payload format and SDK function names
  3. Cross-language matrix table complete

### Phase 16: Widgets & Advanced Topics
**Goal**: Complete widget gallery and advanced development guide
**Depends on**: Phase 15
**Requirements**: DOC-05, DOC-06
**Success Criteria**:
  1. Widget reference shows all 12 widget types with code in all languages
  2. Advanced doc covers multi-panel, file I/O, command registration, WASM constraints

### Phase 17: Per-Language Guides & Distribution
**Goal**: All language guides enhanced and distribution guide complete
**Depends on**: Phase 15
**Requirements**: DOC-07 through DOC-13
**Success Criteria**:
  1. All 6 language guides have file I/O section and Framework approach (Zig)
  2. Rust and Go guides added to VitePress sidebar
  3. Distribution doc covers build helper API, plugin.toml, marketplace

### Phase 18: User Docs & Examples
**Goal**: End-user documentation and example walkthroughs
**Depends on**: Phase 17
**Requirements**: DOC-14 through DOC-18
**Success Criteria**:
  1. Installation, configuration, managing, troubleshooting guides complete
  2. Examples walkthrough covers all 6 real plugins
  3. All internal links valid, no stale ABI version references

## Dependency Graph

```
Phase 1 (utility data structures)
  ├──→ Phase 2 (core: SlotMap entities)
  │     └──→ Phase 5 (commands: CommandBuffer, pool undo)
  │           └──→ Phase 7 (performance pass)
  ├──→ Phase 3 (state: RingBuffer, SparseSet)
  │     └──→ Phase 6 (GUI: split files, wire runtime)
  └──→ Phase 4 (PluginIF: new tags)
        ├──→ Phase 5
        └──→ Phase 6

Phase 8 (runtime fix) — independent, start immediately
  ├──→ Phase 9 (EasyImport)
  ├──→ Phase 10 (Themes/SchemifyPython)
  │     └──→ Phase 12 (Python plugins)
  ├──→ Phase 11 (PDKLoader/Optimizer)
  └──→ Phase 13 (WASM)

Phase 14 (doc infra) — independent, start immediately
  └──→ Phase 15 (arch + API ref)
        ├──→ Phase 16 (widgets + advanced)
        └──→ Phase 17 (language guides)
              └──→ Phase 18 (user docs + examples)
```

## Progress

**Execution Order:**
Phases 1, 8, 14 can start in parallel. Within each workstream, phases execute sequentially.

| Phase | Status | Completed |
|-------|--------|-----------|
| 1. Foundation Data Structures | Planned (3 plans, 2 waves) | - |
| 2. Core Data Model | Not started | - |
| 3. State & Queue Refactor | Not started | - |
| 4. PluginIF Protocol Expansion | Not started | - |
| 5. Commands Refactor | Not started | - |
| 6. GUI Refactor | Not started | - |
| 7. Performance Pass | Not started | - |
| 8. Runtime Foundation | In Progress (1/3 plans) | - |
| 9. EasyImport Plugin | Not started | - |
| 10. Themes Plugin | Not started | - |
| 11. PDKLoader & Optimizer | Not started | - |
| 12. Python Plugins | Not started | - |
| 13. WASM Plugins | Not started | - |
| 14. Doc Infrastructure & Quick Start | In Progress (1/2 plans complete) | - |
| 15. Architecture & API Reference | Not started | - |
| 16. Widgets & Advanced Topics | Not started | - |
| 17. Per-Language Guides & Distribution | Not started | - |
| 18. User Docs & Examples | Not started | - |
