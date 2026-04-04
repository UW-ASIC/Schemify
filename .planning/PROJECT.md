# Schemify GUI Redesign

## What This Is

Schemify is a Zig-based EDA schematic editor with dual native (raylib) and web (WASM) backends, an ABI v6 plugin system, and a command-queue architecture. The GUI is currently mostly broken — it renders a visual shell but most interactions don't work. This project rebuilds the entire `gui/` module with a clean component architecture, minimal toolbar, and full editor functionality across both backends.

## Core Value

A functional schematic editor where users can place components, draw wires, edit properties, run simulations, and manage files — all through a clean, minimal GUI that works identically on native and web.

## Requirements

### Validated

<!-- Inferred from existing working code -->

- ✓ Command-queue architecture with typed Command unions — existing
- ✓ Dual backend (native raylib / WASM web canvas) via dvui — existing
- ✓ Plugin ABI v6 binary wire protocol with Reader/Writer — existing
- ✓ Core data model (Schemify) with SoA MultiArrayList storage — existing
- ✓ .chn file format reading/writing — existing
- ✓ Netlist generation (SPICE) — existing
- ✓ CLI subcommands (plugin install, SVG export, netlist) — existing
- ✓ Module structure (utility, core, commands, state, plugins) — existing
- ✓ Comptime keybind/command dispatch tables — existing
- ✓ Platform abstraction (Vfs, Platform) — existing
- ✓ Undo system (forward direction; redo not yet implemented) — existing
- ✓ Plugin runtime (load, tick, unload, widget rendering) — existing
- ✓ Theme system with JSON overrides — existing
- ✓ TOML project config parsing — existing

### Active

<!-- GUI Redesign scope -->

- [ ] Rebuild gui/ module with components/ subfolder for reusable widgets
- [ ] Minimal toolbar: File, Edit, View menus only — strip all stubs
- [ ] Canvas rendering: pan, zoom, grid, component/wire display
- [ ] Component placement: place from library, move, rotate, mirror, delete
- [ ] Wire drawing: click-to-route wires between pins
- [ ] Selection: click-select, rubber-band multi-select, select-connected
- [ ] Property editing: view/edit instance properties via dialog
- [ ] File operations: new, open, save, save-as, close tab, multi-tab
- [ ] Undo/redo: full bidirectional undo/redo
- [ ] Simulation: trigger SPICE sim from GUI, view results
- [ ] Plugin panels: render plugin widgets, dispatch events
- [ ] Find dialog: search instances/nets by name
- [ ] Unsaved-changes warning on close/quit
- [ ] Reusable component library (themed buttons, panels, splitters, floating windows)
- [ ] Command bar: vim-style command input + status line
- [ ] Context menus: right-click actions on canvas/components
- [ ] Keybinds dialog: view/customize keyboard shortcuts
- [ ] File explorer: browse and open schematic files
- [ ] Library browser: browse component library for placement
- [ ] Both native and WASM backends must work identically
- [ ] Merge state.zig into types.zig (stop treating state as separate)
- [ ] Remove all Arch.md files

### Out of Scope

- Marketplace plugin installation (dvui text entry unstable, install logic is stub) — defer to future
- Move stretch/insert modes (rubber-band wire tracking) — complex, defer
- Screenshot area selection — nice-to-have, not essential
- Cross-document copy/paste testing — clipboard already shared, edge case
- HDL synthesis GUI — CLI-only is sufficient for now
- Mobile/touch input — desktop-first

## Context

- **GUI state**: Mostly broken. Layout renders but interactions are stubs or non-functional. Renderer.zig (1152 LOC) is the single largest GUI file, handles too many concerns.
- **dvui dependency**: Text entry API is unstable — FindDialog, Marketplace search, PropsDialog are blocked by this. Must work around or use command-bar input as fallback.
- **Module structure rules**: Every module must be a folder with lib.zig + types.zig. One pub struct per file. Data-oriented design required.
- **Existing components pattern**: FloatingWindow and HorizontalBar exist in gui/Components/ — good starting point for the component library.
- **Performance concerns**: page_allocator used in hot paths (Renderer, FileExplorer, Theme), subcircuit cache never evicts, History uses O(n) eviction. These should be addressed during rebuild.
- **Test coverage**: GUI has zero test coverage. Command handlers have no integration tests. Core behavioral tests missing.
- **Silent error swallowing**: 90+ `catch {}` across codebase — a systemic issue to address incrementally.

## Constraints

- **Tech stack**: Zig 0.15.x + dvui 0.4.0-dev + raylib (native) / WASM canvas (web). No new dependencies.
- **Module rules**: Must follow CLAUDE.md module structure (lib.zig, types.zig, one pub struct per file)
- **Dual backend**: All GUI code must work on both native and web. No platform-specific GUI code.
- **Plugin contract**: ParsedWidget rendering must stay stable — plugins depend on the ABI v6 protocol
- **Frame z-order**: Rendering order in gui/lib.zig matters — must preserve strict layering
- **Lint rules**: No std.fs.* or std.posix.getenv outside utility/ and cli/

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Minimal toolbar (File/Edit/View only) | Remove stubs and unimplemented menu items — clean over feature-rich | — Pending |
| Reusable component library in gui/Components/ | Extract repeated dvui patterns + themed widget abstractions to minimize LOC | — Pending |
| Both backends must work | Web demo is important for the project — can't let it rot | — Pending |
| Merge state.zig into types.zig | State shouldn't be a separate concept — it's just types used by AppState | — Pending |
| Use command-bar as text input fallback | dvui text entry is unstable — command bar already works for vim commands | — Pending |

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
*Last updated: 2026-04-04 after initialization*
