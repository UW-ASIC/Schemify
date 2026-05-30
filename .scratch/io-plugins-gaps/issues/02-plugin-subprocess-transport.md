---
id: io/02
title: Plugin subprocess transport stubbed
status: wontfix
priority: medium
labels: [plugins, transport]
---

# Plugin subprocess transport — RESOLVED

## Status

**Fully implemented.** Prior HANDOFF was stale.

`crates/plugins/src/transport/subprocess.rs` (307 lines) has:
- `SubprocessTransport::new()` — creates idle transport
- `spawn()` — spawns child process with stdin/stdout pipes
- `send()` — writes newline-delimited JSON to stdin
- `recv()` — reads lines non-blocking from stdout
- `stop()` — kills process and cleans up
- Comprehensive tests (lines 147–307)

No work needed. Closing as wontfix (already done).
