# Web Bridge Architecture

This directory contains the browser-side bridge between `schemify.wasm` (Zig) and Web APIs.

## Components

- `src/web/schemify_host.js`
  - Defines `window.SchemifyHost`.
  - Exposes the `host` import namespace consumed by Zig WASM.
  - Bridges two domains:
    - **VFS** (`vfs_*` imports): maps file operations to `window.SchemifyVFS.files` and marks touched paths dirty so OPFS persistence can flush.
    - **Platform** (`platform_*` imports): browser-safe shims for URL open, async HTTP polling, and env lookup.

## Integration Flow (Browser <-> WASM)

1. `web/index.html` loads scripts in this order:
   - `vfs.js`
   - `schemify_host.js`
   - `boot.js`
2. `web/boot.js` initializes `window.SchemifyVFS` and instantiates `schemify.wasm` with imports:
   - `dvui: app.imports`
   - `host: window.SchemifyHost.imports`
3. After instantiation, `boot.js` calls:
   - `window.SchemifyHost.setMemory(result.instance.exports.memory)`
4. During runtime, Zig code calls `extern` host functions; JS reads and writes bytes directly in shared WASM memory.

## Host Contract Details

- **String/bytes ABI**
  - All string parameters are passed as `(ptr, len)` UTF-8 slices in WASM linear memory.
  - Binary buffers are copied between JS typed arrays and WASM memory using explicit destination lengths.
- **Directory listing ABI**
  - `vfs_dir_list_len` reports total bytes needed for NUL-terminated names.
  - `vfs_dir_list_read` writes names as `name\0name\0...` and returns bytes written.
  - Return `-1` when no entries are available.
- **HTTP polling ABI**
  - `platform_http_get_start(url_ptr, url_len, req_id)` starts fetch and records request state.
  - `platform_http_get_poll(req_id, buf_ptr, buf_len)` returns:
    - `-1` while pending or unknown id
    - `-2` on request error
    - `>=0` bytes copied on success (request is then cleared)

## Scope and Cleanup Notes

- Removed legacy plugin-host scripts from `src/web`:
  - `src/web/plugin_host.js`
  - `src/web/pyodide_plugin_host.js`
- Verification used before removal:
  - No references in `web/index.html` script load order.
  - No installation step in `build.zig` web asset install list.
  - No runtime references outside their own file pair (checked with repository grep excluding `.claude/**`).

This keeps the web bridge focused on the active Zig WASM host path and reduces maintenance surface.
