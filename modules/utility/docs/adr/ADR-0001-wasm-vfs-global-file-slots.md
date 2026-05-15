# ADR-0001: WASM VFS uses global mutable file slots

## Status: accepted

## Context

WASM has no filesystem. The app needs to create, write, and close files when running in the browser (export, save). The JS host exposes a VFS backed by IndexedDB, but WASM linear memory cannot hold JS file handles. We need a way for `createFile` to return something the Zig side can write to incrementally before flushing to the JS VFS on `close`.

## Decision

Use a fixed array of 4 global `WasmFileSlot` structs, each with a 1 MB write buffer. `createFile` claims a free slot; `close` flushes the buffer to JS via `vfs_file_write` and releases the slot. No heap allocation involved.

## Consequences

- Maximum 4 files open for writing simultaneously. Sufficient for current usage (save + export are sequential) but will break if parallel file writes are ever needed.
- 4 MB of static memory reserved even when no files are open.
- Global mutable state is not thread-safe. Safe today because WASM is single-threaded, but precludes any future multi-threaded WASM target (e.g., wasm32-wasi-threads).
- 1 MB per-file limit. Files larger than 1 MB cannot be written. No streaming flush.
- The `WasmDir.openDir` function has a use-after-return bug: it copies the path into a stack buffer and returns a slice pointing to it. This must be fixed before the WASM backend is exercised in production.
