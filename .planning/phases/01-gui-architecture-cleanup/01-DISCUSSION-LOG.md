# Phase 1: GUI Architecture & Cleanup - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-04
**Phase:** 01-gui-architecture-cleanup
**Areas discussed:** Renderer decomposition, Component library scope, State migration strategy, Toolbar menu stripping
**Mode:** --auto (all decisions auto-selected)

---

## Renderer Decomposition

| Option | Description | Selected |
|--------|-------------|----------|
| Split by responsibility | Separate files for viewport, grid, symbol rendering, wire rendering, selection overlay, interaction | ✓ |
| Split by render pass | One file per z-order layer (background, mid, foreground) | |
| Minimal split | Just extract subcircuit cache, keep rest monolithic | |

**User's choice:** [auto] Split by responsibility (recommended default)
**Notes:** Matches the distinct concerns already tangled in Renderer.zig. Each file maps to a clear z-order layer and a testable unit.

---

## Component Library Scope

| Option | Description | Selected |
|--------|-------------|----------|
| Extract from existing patterns | Only extract widgets that appear 3+ times (themed button, panel, scrollable list) | ✓ |
| Full widget kit | Pre-build all anticipated widgets (tabs, splitters, tooltips, etc.) | |
| Minimal (keep as-is) | Only FloatingWindow and HorizontalBar, add more as needed | |

**User's choice:** [auto] Extract from existing patterns (recommended default)
**Notes:** Avoids over-engineering while establishing the pattern. Scrollable list is the strongest candidate — used in 4+ places.

---

## State Migration Strategy

| Option | Description | Selected |
|--------|-------------|----------|
| Per-feature substruct in GuiState | Group dialog/panel state into named sub-structs (FileExplorerState, etc.) | ✓ |
| Flat fields in GuiState | Add all vars as individual fields on GuiState | |
| Keep module-level vars | Leave as-is, just document the pattern | |

**User's choice:** [auto] Per-feature substruct in GuiState (recommended default)
**Notes:** Sub-structs keep GuiState organized and allow each dialog to own a typed slice of state. Flat fields would make GuiState unwieldy with 25+ new fields.

---

## Toolbar Menu Stripping

| Option | Description | Selected |
|--------|-------------|----------|
| Remove entirely, re-add when features built | Strip to File/Edit/View only, no stubs | ✓ |
| Keep as disabled items | Gray out Draw/Sim/Plugins but keep visible | |
| Reorganize into File/Edit/View | Move useful items from Draw/Sim/Plugins into the three remaining menus | |

**User's choice:** [auto] Remove entirely, re-add when features built (recommended default)
**Notes:** Clean over feature-rich. Matches PROJECT.md key decision on minimal toolbar.

---

## Claude's Discretion

- Canvas/ sub-file exact naming and boundary adjustments
- Whether to create a RenderContext struct vs pass parameters individually
- Internal helper organization within Canvas/ files

## Deferred Ideas

None — discussion stayed within phase scope.
