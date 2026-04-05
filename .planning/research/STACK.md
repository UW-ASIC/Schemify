# Technology Stack

**Project:** Schemify GUI Redesign
**Researched:** 2026-04-04

## Recommended Stack

No new dependencies. The GUI redesign uses the existing stack. This is a constraint (see PROJECT.md), and the right call -- the stack is appropriate for the domain.

### Core Framework

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Zig | 0.15.x | Language, build system | Already in use. Data-oriented design is ideal for EDA (SoA layouts for instance/wire arrays). Comptime tables for keybinds/commands are fast and correct. |
| dvui | 0.4.0-dev | Immediate-mode GUI framework | Already in use. Provides both native (raylib) and web (WASM/canvas) backends from the same Zig code. The dual-backend capability is a core differentiator. |
| raylib | (bundled) | Native rendering backend | Already in use via dvui. Hardware-accelerated 2D rendering. Good enough for schematic rendering performance. |

### Infrastructure

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| WASM (via Zig) | - | Web deployment target | Already in use. Enables browser-based usage without install. Zig's WASM target is mature. |
| ngspice | (system) | SPICE simulation | Already integrated. External dependency invoked via process spawn. No GUI change needed. |
| rsvg-convert | (system) | PNG/PDF export from SVG | Already used. External dependency. Consider documenting as optional. |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| std.heap.ArenaAllocator | (stdlib) | Per-frame / per-operation allocation | Use for temporary allocations during rendering, file parsing. Reset each frame or operation. |
| std.StringHashMap | (stdlib) | Subcircuit cache, lookup tables | Already used in Renderer.zig subcircuit cache. Add eviction policy. |

## Key Stack Constraints for GUI Redesign

### dvui Text Entry Instability

dvui's text entry widget API is noted as "not yet stable" in CLAUDE.md. This blocks:
- FindDialog search input
- PropsDialog free-form property editing
- Marketplace search

**Workaround:** Use the existing command bar (CommandBar.zig) for all text input. This aligns with the vim-style differentiator. Commands like `:set refdes R1`, `:find R1`, `:saveas path/to/file.chn` route through the command bar which already has working text input.

### Dual Backend Requirement

All GUI code must work identically on native (raylib) and web (WASM). This means:
- No platform-specific GUI code
- No system dialogs (file picker must be custom -- FileExplorer.zig)
- No threading (WASM is single-threaded)
- Performance must be acceptable on both targets

### Module Structure Rules

Every GUI module must follow the folder structure:
```
gui/<module>/
  lib.zig      -- public API
  types.zig    -- shared types
  SomeStruct.zig -- one pub struct per file
```

This constrains how Renderer.zig is decomposed.

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| GUI framework | dvui (keep) | Dear ImGui (via cimgui) | Would require rewriting all GUI code. dvui already works on both backends. Switching frameworks is not in scope. |
| GUI framework | dvui (keep) | Raw raylib drawing | Loses widget library (buttons, dialogs, layout). Would massively increase GUI code. |
| Rendering | raylib (keep) | OpenGL directly | raylib abstracts OpenGL nicely. Direct OpenGL adds complexity for no benefit in a 2D schematic editor. |
| Web backend | WASM+dvui (keep) | Electron/Tauri | Defeats the purpose of Zig. Adds massive dependency. WASM is lighter and already works. |
| Text input | Command bar workaround | Wait for dvui fix | Unpredictable timeline. Command bar works now and is a differentiator. |

## Installation

No new installation steps. The existing build commands work:

```bash
# Native build
zig build
zig build run

# Web build
zig build -Dbackend=web
zig build run_local -Dbackend=web

# Tests
zig build test
```

## Sources

- Schemify CLAUDE.md -- build commands, module structure, GUI architecture
- Schemify PROJECT.md -- constraints ("No new dependencies")
- dvui upstream -- text entry instability noted in CLAUDE.md
