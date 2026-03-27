# Requirements: Schemify v3.0 — DOD Refactor + Plugin Ecosystem

**Defined:** 2026-03-27
**Core Value:** Transform Schemify into a fast, data-oriented, plugin-first EDA platform with working plugins and comprehensive documentation.

## Workstream A: DOD Refactor

### Data Structures (DS)

- [ ] **DS-01**: SlotMap with generational handles — O(1) insert/remove/lookup, ABA-safe, dense iteration
- [x] **DS-02**: SparseSet — O(1) add/remove/contains, O(k) dense iteration over k active elements
- [x] **DS-03**: RingBuffer — O(1) push/pop, fixed capacity, no allocator needed, pushOverwrite for eviction
- [x] **DS-04**: Pool allocator — O(1) fixed-size block alloc/free, zero fragmentation
- [ ] **DS-05**: SmallVec — inline storage for ≤N elements, spills to heap when exceeded
- [ ] **DS-06**: PerfectHash — comptime-generated zero-collision lookup for static key sets

### Core (CORE)

- [ ] **CORE-01**: Instances stored in SlotMap with Handle-based access (not raw indices)
- [ ] **CORE-02**: Wires stored in SlotMap with Handle-based access
- [ ] **CORE-03**: Command payloads use InstanceHandle/WireHandle instead of u32 idx
- [ ] **CORE-04**: swapRemove on entities does not invalidate handles held by undo system
- [ ] **CORE-05**: NetResolver extracted from Schemify.zig, Schemify.zig under 400 LOC

### State (STATE)

- [ ] **STATE-01**: CommandQueue backed by RingBuffer — O(1) push and pop, no orderedRemove(0)
- [ ] **STATE-02**: History backed by RingBuffer — O(1) push with auto-eviction
- [ ] **STATE-03**: Selection backed by SparseSet — O(1) isEmpty, O(k) iteration
- [ ] **STATE-04**: Allocator parameter removed from CommandQueue.push and History.push call sites

### Plugin Protocol (PLUG)

- [ ] **PLUG-01**: Document lifecycle tags: document_opened, document_closed, document_saved, document_modified
- [ ] **PLUG-02**: Selection event tags: selection_added, selection_removed, selection_cleared
- [ ] **PLUG-03**: Property event tags: prop_changed with handle + key + old_val + new_val
- [ ] **PLUG-04**: Command interception: pre_command / post_command / cancel_command flow
- [ ] **PLUG-05**: Context menu injection: add_context_item / remove_context_item
- [ ] **PLUG-06**: Status bar widgets: set_statusbar_widget with slot_id + text
- [ ] **PLUG-07**: Custom rendering: draw_line, draw_rect, draw_circle, draw_text
- [ ] **PLUG-08**: Event subscription bitfield — plugins only receive events they subscribe to

### Commands (CMD)

- [ ] **CMD-01**: CommandBuffer for deferred batch mutations during iteration
- [ ] **CMD-02**: Pool-allocated undo snapshots with automatic free on History eviction
- [ ] **CMD-03**: delete_selected uses CommandBuffer instead of reverse-iteration hack

### GUI (GUI)

- [ ] **GUI-01**: PluginPanels.drawPanelBody renders ParsedWidget lists from runtime
- [ ] **GUI-02**: Renderer.zig split into 3 files, each under 400 LOC
- [ ] **GUI-03**: Comptime geometry dispatch table replaces repetitive rendering loops
- [ ] **GUI-04**: All GUI files under 400 LOC

### Performance (PERF)

- [ ] **PERF-01**: SIMD batch coordinate transforms in Renderer
- [ ] **PERF-02**: Edit.zig applyToSelected uses SparseSet dense iteration
- [ ] **PERF-03**: @setCold on error and infrequent code paths
- [ ] **PERF-04**: comptime struct size assertions on critical types

## Workstream B: Plugin Fix

### Plugin Runtime (PFIX)

- [x] **PFIX-01**: build_plugin_helper.zig references correct core module (not deleted FileIO.zig)
- [ ] **PFIX-02**: PluginPanels.drawPanelBody renders real widgets from runtime ParsedWidget lists
- [x] **PFIX-03**: Theme.applyJson parses JSON and updates current_overrides (not a no-op)
- [ ] **PFIX-04**: runtime.zig handles request_refresh, register_keybind, push_command output tags
- [ ] **PFIX-05**: set_config key matches between runtime check and Themes plugin ("active_theme")
- [ ] **PFIX-06**: EasyImport exports schemify_process + schemify_plugin descriptor (ABI v6 wrapper)
- [ ] **PFIX-07**: EasyImport registers panel with Scan/Convert buttons, converts .sch to .chn
- [ ] **PFIX-08**: SchemifyPython host embeds CPython, discovers .py scripts, multiplexes I/O
- [ ] **PFIX-09**: SchemifyPython calls PyImport_AppendInittab BEFORE Py_Initialize
- [ ] **PFIX-10**: Themes plugin applies colors end-to-end (Python → set_config → applyJson → UI)
- [ ] **PFIX-11**: PDKLoader builds, loads, and shows installed PDKs in panel
- [ ] **PFIX-12**: Optimizer builds, loads, and shows Run/Stop/Reset UI in panel
- [ ] **PFIX-13**: Circuit Visionary loads via SchemifyPython and shows pipeline controls
- [ ] **PFIX-14**: GmID Visualizer loads via SchemifyPython and shows sweep controls
- [ ] **PFIX-15**: wasmPlugin.zig uses ABI v6 message-passing (no extern "host" imports)
- [ ] **PFIX-16**: JS plugin host loads, ticks, and renders WASM plugins
- [ ] **PFIX-17**: wasm-smoke example loads in web build

## Workstream C: Plugin Documentation

### Documentation (DOC)

- [ ] **DOC-01**: docs/plugins/creating/ and docs/plugins/using/ directories with VitePress sidebar
- [ ] **DOC-02**: Quick start guide: 5-minute plugin in Zig, C, Rust, Python, Go
- [ ] **DOC-03**: Architecture doc: message lifecycle, event dispatch, memory model, Framework
- [ ] **DOC-04**: API reference: every tag, payload format, SDK function names, cross-language matrix
- [ ] **DOC-05**: Widget reference: all 12 widget types with code samples in all languages
- [ ] **DOC-06**: Advanced topics: multi-panel, state, file I/O, command registration, WASM constraints
- [ ] **DOC-07**: Zig guide enhanced with Framework approach and file I/O
- [ ] **DOC-08**: C guide enhanced with file I/O section
- [ ] **DOC-09**: C++ guide enhanced with file I/O section
- [ ] **DOC-10**: Rust guide enhanced, added to VitePress sidebar
- [ ] **DOC-11**: Go guide enhanced, added to VitePress sidebar
- [ ] **DOC-12**: Python guide enhanced with SchemifyPython multiplexer detail
- [ ] **DOC-13**: Build & distribution doc: build helper API, plugin.toml, marketplace publishing
- [ ] **DOC-14**: User installation guide (marketplace, URL, manual, Python scripts)
- [ ] **DOC-15**: User configuration guide (plugin.toml, Config.toml, keybinds, layout)
- [ ] **DOC-16**: User managing plugins guide (enable/disable, update, remove)
- [ ] **DOC-17**: User troubleshooting guide (common errors, diagnostic flowchart)
- [ ] **DOC-18**: Examples walkthrough: annotated breakdown of all 6 real plugins

## Out of Scope

| Feature | Reason |
|---------|--------|
| New GUI features (file explorer, library browser) | Cleanup and refactor only |
| Cadence Virtuoso import backend | Separate milestone |
| EasyImport Phases 2-7 (discovery, translation, etc.) | v1.0 milestone, paused |
| New plugin types (LSP, debugger) | Future milestone |
| Mobile/tablet UI | Not planned |
| Redo system improvements | Separate effort |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| DS-01 | 1 | Pending |
| DS-02 | 1 | Complete (01-02) |
| DS-03 | 1 | Complete (01-02) |
| DS-04 | 1 | Complete (01-02) |
| DS-05 | 1 | Pending |
| DS-06 | 1 | Pending |
| CORE-01 | 2 | Pending |
| CORE-02 | 2 | Pending |
| CORE-03 | 2 | Pending |
| CORE-04 | 2 | Pending |
| CORE-05 | 2 | Pending |
| STATE-01 | 3 | Pending |
| STATE-02 | 3 | Pending |
| STATE-03 | 3 | Pending |
| STATE-04 | 3 | Pending |
| PLUG-01 | 4 | Pending |
| PLUG-02 | 4 | Pending |
| PLUG-03 | 4 | Pending |
| PLUG-04 | 4 | Pending |
| PLUG-05 | 4 | Pending |
| PLUG-06 | 4 | Pending |
| PLUG-07 | 4 | Pending |
| PLUG-08 | 4 | Pending |
| CMD-01 | 5 | Pending |
| CMD-02 | 5 | Pending |
| CMD-03 | 5 | Pending |
| GUI-01 | 6 | Pending |
| GUI-02 | 6 | Pending |
| GUI-03 | 6 | Pending |
| GUI-04 | 6 | Pending |
| PERF-01 | 7 | Pending |
| PERF-02 | 7 | Pending |
| PERF-03 | 7 | Pending |
| PERF-04 | 7 | Pending |
| PFIX-01 | 8 | Complete (08-01) |
| PFIX-02 | 8 | Pending |
| PFIX-03 | 8 | Complete (08-01) |
| PFIX-04 | 8 | Pending |
| PFIX-05 | 8 | Pending |
| PFIX-06 | 9 | Pending |
| PFIX-07 | 9 | Pending |
| PFIX-08 | 10 | Pending |
| PFIX-09 | 10 | Pending |
| PFIX-10 | 10 | Pending |
| PFIX-11 | 11 | Pending |
| PFIX-12 | 11 | Pending |
| PFIX-13 | 12 | Pending |
| PFIX-14 | 12 | Pending |
| PFIX-15 | 13 | Pending |
| PFIX-16 | 13 | Pending |
| PFIX-17 | 13 | Pending |
| DOC-01 | 14 | Pending |
| DOC-02 | 14 | Pending |
| DOC-03 | 15 | Pending |
| DOC-04 | 15 | Pending |
| DOC-05 | 16 | Pending |
| DOC-06 | 16 | Pending |
| DOC-07 | 17 | Pending |
| DOC-08 | 17 | Pending |
| DOC-09 | 17 | Pending |
| DOC-10 | 17 | Pending |
| DOC-11 | 17 | Pending |
| DOC-12 | 17 | Pending |
| DOC-13 | 17 | Pending |
| DOC-14 | 18 | Pending |
| DOC-15 | 18 | Pending |
| DOC-16 | 18 | Pending |
| DOC-17 | 18 | Pending |
| DOC-18 | 18 | Pending |

**Coverage:**
- Total requirements: 63
- Mapped to phases: 63/63
- Unmapped: 0

---
*Requirements defined: 2026-03-27*
*Last updated: 2026-03-27*
