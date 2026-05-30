---
id: gui/08
title: Implement PluginMutation command handler
status: ready-for-agent
priority: low
labels: [gui-linking, handler, plugins]
---

# Implement PluginMutation

## Problem

`dispatch.rs:586-587` is a no-op comment: `PluginMutation { .. } => { // Plugin mutations not yet implemented }`. Plugins cannot mutate schematics.

## Acceptance criteria

- [ ] PluginMutation handler applies mutation to AppState
- [ ] Mutation pushed to undo stack
- [ ] Plugin-originated changes undoable like user changes
