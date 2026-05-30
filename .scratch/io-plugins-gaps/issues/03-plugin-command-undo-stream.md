---
id: io/03
title: Plugin Command/undo stream
status: needs-info
priority: medium
labels: [plugins, commands, undo]
deps: []
---

# Plugin Command/undo stream

## Problem

`PluginMutation` command variant exists but dispatch handler is a no-op. Plugins can send `PluginCommand` (queued to `pending_plugin_commands`) but cannot mutate schematic state with undo support.

## Current state

**Command definition** (`crates/core/src/commands.rs:187–194`):
```rust
PluginCommand { tag: String, payload: Vec<u8> },
PluginMutation { tag: String, payload: Option<Vec<u8>> },
```

**Dispatch** (`crates/handler/src/dispatch.rs:586–591`):
```rust
PluginMutation { .. } => {
    // Plugin mutations not yet implemented
}
```

**UI integration exists** — panels and chrome can dispatch `PluginCommand`. Plugin host can dispatch via `DispatchCommand` HostAction.

## Needs info

- What mutations should plugins be allowed to make? (add instances? modify properties? arbitrary schematic edits?)
- Should mutations go through existing Command variants or have a separate plugin-specific mutation path?
- Undo granularity: one undo entry per plugin action, or batched?

## Acceptance criteria (draft — pending triage)

- [ ] `PluginMutation` handler applies changes to schematic state
- [ ] Undo snapshot pushed before mutation
- [ ] Plugin host can roundtrip: send mutation → see state change → undo restores

## Files

- `crates/handler/src/dispatch.rs` — PluginMutation handler
- `crates/core/src/commands.rs` — Command variants
- `crates/plugins/src/host.rs` — HostAction::DispatchCommand
