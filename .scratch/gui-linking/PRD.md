# PRD: GUI linking — wire `display` back to `handler`

Status: ready-for-agent

## Problem

The `schemify-display` crate is not fully linked to the `schemify-handler` /
`schemify-core` API surface. At least one path (`canvas.rs` drag handling)
constructs `Command` variants that **do not exist** in `core::Command`, which
means the GUI crate does not compile against current core. Other tools/menus
may construct Commands that are never dispatched or read accessors that no
longer exist.

## Scope

- Restore `display` → `core::Command` → `handler::dispatch` compilation.
- Audit every interactive control (toolbar, menu, keyboard shortcut, canvas
  interaction) and confirm it constructs a real, dispatched `Command`.
- One-way data flow stays intact (ADR-001): input → display builds `Command`
  → `dispatch` → accessors → render. No `&mut` leaks out of handler.

## Out of scope

- New editor features beyond restoring existing intended wiring.
- s2s placement/routing (tracked under `.scratch/spice-to-schematic/`).

## Evidence

- `crates/core/src/command.rs:12-59` — `Command` enum; last variant `Redo`. No
  `StartDrag` / `EndDrag`.
- `crates/display/src/canvas.rs:285,401,512,609,617-620` — constructs
  `Command::StartDrag { idx, x, y }` and `Command::EndDrag`.
- `crates/handler/src/dispatch.rs` — match arms cover the enum but have no
  `StartDrag`/`EndDrag` (and `AutoLayout` is a stub, see issue 02).

## Issues

- `01-drag-commands-missing-in-core.md`
- `02-autolayout-stub.md`
- `03-audit-control-wiring.md`
