# ADR-0001: Synchronous binary protocol over shared buffer

## Status: superseded

Superseded by JSON-RPC 2.0 over stdin/stdout subprocess model.

## Original Decision

Single-function synchronous binary protocol. The plugin exported one `process` function with C calling convention. The host owned both buffers. Messages used a `[u8 tag][u16 payload_len][payload]` framing.

## Current Architecture

Plugins are now separate processes communicating via JSON-RPC 2.0 (NDJSON) over stdin/stdout pipes. The host spawns child processes, sends JSON-RPC notifications/requests on stdin, and reads JSON-RPC messages from stdout. This eliminates ABI coupling, enables language-agnostic plugins, and provides natural process isolation.

Key files:
- `jsonrpc.zig` -- JSON-RPC 2.0 encode/decode
- `subprocess.zig` -- child process management with non-blocking stdout reads
- `Runtime.zig` -- orchestrates subprocess plugins
