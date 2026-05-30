---
id: gen/04
title: Replace plugin host panics with Result propagation
status: ready-for-agent
priority: high
labels: [plugins, robustness]
---

# Harden plugin host error handling

## Problem

33 `panic!()` calls in plugin runtime (host.rs, jsonrpc.rs, transport/subprocess.rs, transport/wasm.rs). Plugin sending unexpected message type → entire app crashes.

## Acceptance criteria

- [ ] All `panic!()` in plugins crate replaced with `Result<T, PluginError>`
- [ ] Malformed plugin response → graceful error, plugin unloaded, app continues
- [ ] Plugin crash (subprocess exit) → error message, not app crash
- [ ] Tests for each error path

## Files

- `crates/plugins/src/host.rs`
- `crates/plugins/src/jsonrpc.rs`
- `crates/plugins/src/transport/subprocess.rs`
- `crates/plugins/src/transport/wasm.rs`
