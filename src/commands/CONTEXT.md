# commands

Command system for the schematic editor. Every user action — keypress, menu click, CLI input, plugin call — is expressed as a Command value, queued, and dispatched to a handler. Separates intent from execution.

## Language

**Command**:
A discrete user action. Queued and dispatched, never executed inline. The GUI, CLI, and plugins all produce the same Command values. Separates what the user wants from how the Schematic is mutated.
_Avoid_: action, event, message, operation

## Relationships

- A **Command** may reference types from the schematic module (Instance index, Wire coordinates, Property key-value)
- A **Command** is produced by the GUI, CLI, or plugins and consumed by dispatch handlers
- A **Command** may mutate a Schematic or only affect the view/UI state

## Example dialogue

> **Dev:** "Can the GUI delete an Instance directly?"
> **Domain expert:** "No. The GUI enqueues a **Command** — specifically a delete command with the Instance index. The command system dispatches it to the handler, which performs the mutation. The GUI never touches the Schematic directly."

> **Dev:** "What about zoom — is that a Command too?"
> **Domain expert:** "Yes. Zoom, pan, toggle grid, open dialog — all **Commands**. The difference is that zoom only affects the view. It never enters undo history."

## Flagged ambiguities

- **"Immediate" vs "Undoable"** are internal categories in the code (how undo interacts with a Command), not domain terms. A domain expert would say "zoom in" or "place a resistor", not "that's an Immediate."
- **"dispatch"** is used as both a noun (the dispatch module) and a verb (dispatching a Command). The domain concept is the verb — routing a Command to its handler.
