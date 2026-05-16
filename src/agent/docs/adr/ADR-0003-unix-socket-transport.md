# ADR-0003: Unix domain socket transport

## Status: accepted

## Context

MCP defines three transports: stdio, HTTP+SSE, and "streamable HTTP". Stdio is simplest but requires the MCP client to be a child process of Schemify (or vice versa). HTTP+SSE requires an HTTP stack. The agent needs to serve multiple concurrent LLM clients while Schemify runs as a desktop GUI application.

## Decision

Use a Unix domain socket at `$XDG_RUNTIME_DIR/schemify.sock` (fallback: `~/.config/Schemify/schemify.sock`, then `/tmp/schemify.sock`). Messages are newline-delimited JSON (NDJSON). The server runs an accept loop on a background thread and spawns a detached thread per client. Client threads read into a 64KB buffer, accumulate lines, and process complete messages.

## Consequences

- Any local process can connect: Claude Code, custom scripts, other editors, multiple simultaneous clients.
- No HTTP dependency. No TLS. No CORS. Implementation is ~100 lines of posix socket code.
- Linux/macOS only. Windows would need named pipes or TCP. No Windows support currently.
- No authentication. Any process with filesystem access to the socket can read/mutate the schematic. Acceptable for single-user desktop use; insufficient for shared or remote environments.
- NDJSON is not the standard MCP framing (MCP uses HTTP or stdio with Content-Length headers). MCP clients need a thin adapter to speak NDJSON over Unix sockets. This is a nonstandard transport.
- Stale socket files are deleted on startup. If Schemify crashes, the socket file persists and is cleaned up on next launch.
