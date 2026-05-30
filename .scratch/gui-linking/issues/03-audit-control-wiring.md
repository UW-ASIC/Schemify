# 03 — Audit every GUI control → Command wiring

Status: needs-info
Labels: audit
Crate: schemify-display
Complexity: M
Depends on: gui-linking/01 (crate must compile before a meaningful audit)

## Problem

Background: the automated GUI-linking research pass could not complete (its
shell calls errored in a loop), so the full inventory of unwired controls is
**not yet established**. This issue is the deliberate follow-up to do that audit
once `display` compiles again.

## Tasks

1. After gui-linking/01 lands, `cargo build -p schemify-display` and fix any
   remaining references to non-existent `Command` variants or removed handler
   accessors (compiler will list them).
2. Enumerate every interactive control and confirm each constructs a dispatched
   `Command`:
   - Tools: select, wire, place, pan, etc. (`Command::SetTool(Tool::*)`).
   - File: New/Open/Save/Import (`NewDocument`, `OpenDocument`, `SaveDocument`,
     `ImportSpice`).
   - Edit: Undo/Redo/Cut/Copy/Paste/Delete/Group/Ungroup/Align/Distribute/
     Rotate/Flip/Mirror.
   - View: ToggleGrid, AutoLayout, Connectivity rebuild.
   - Properties dialog → `UpdateProperty`.
   - Library browser → `PlaceComponent`.
3. Cross-check: are these dispatch-handled variants ever **constructed** by
   display? `DeselectAll`, `SelectInstance`, `SelectWire`, `SelectInRect`,
   `Connectivity`, `Ungroup`, `ToggleGrid`. (dispatch.rs handles them; confirm
   the GUI actually emits them — a handled-but-never-emitted Command is a dead
   UI link.)
4. For each gap found, append a concrete sub-task to this file (control name,
   file:line, missing Command).

## Acceptance criteria

1. `display` compiles and the GUI launches (`cargo run`).
2. A checklist in this file marks every control as ✅ wired or ❌ + follow-up.
3. No `Command` variant is constructed in display that core does not define
   (`grep` clean), and no obviously user-facing control is a no-op.
