# Plugin Architecture

## The ABI boundary

Plugins communicate with the host through a single `extern struct` exported
as the symbol `schemify_plugin`.  Using `extern struct` means the layout is
defined by the C ABI — not Zig's internal layout — so every language that
can call into C can implement a plugin.

```zig
// src/PluginIF.zig (abridged)
pub const ABI_VERSION: u32 = 2;

pub const Descriptor = extern struct {
    abi_version: u32,         // must equal ABI_VERSION
    name:        [*:0]const u8,
    version_str: [*:0]const u8,
    set_ctx:     SetCtxFn,    // always Plugin.setCtx
    on_load:     OnLoadFn,
    on_unload:   OnUnloadFn,
    on_tick:     ?OnTickFn,   // null if the plugin has no per-frame work
};
```

The runtime (`src/plugins/runtime.zig`) does `dlopen` → `dlsym("schemify_plugin")`
→ checks `abi_version` → calls `set_ctx` + `on_load`.  If the version does not
match, the library is closed and a warning is logged.

## Native target: VTable + Ctx

On native builds the host passes a `*Ctx` to the plugin before every lifecycle
call via `set_ctx`.  `Ctx` wraps a `*VTable` — a pointer to a single
comptime-constant table of function pointers that lives inside the host binary.

```
Plugin .so              Host binary
  │                        │
  │  _g_ctx ────────────►  Ctx { _vtable ──────► VTable { set_status, log, … }
  │                               _state ──────► AppState { … }
  │                        }
```

Plugins never allocate or write to `VTable` or `Ctx`.  They call the
module-level wrappers (`Plugin.setStatus(…)`) which look up `_g_ctx` and
dispatch through the vtable.

## WASM target: extern "host" imports

On WASM builds there is no `Ctx` and no vtable.  Instead `PluginIF.zig`
declares `extern "host"` function imports which the JavaScript `plugin_host.js`
provides when instantiating the `.wasm` module:

```
plugin.wasm                 plugin_host.js
  │                              │
  │── set_status(ptr, len) ─────►│  reads str from WASM memory, forwards to UI
  │── register_panel(…) ────────►│  registers panel with the WASM app state
  │── vfs_file_read(…) ─────────►│  reads from in-memory VFS Map
```

Zig's `comptime is_wasm` guards every call site so the compiler emits either
the vtable path or the extern-import path — never both.  A single plugin
source file therefore works on both targets with no `#ifdef`s.

## Filesystem: Vfs

Both targets expose an identical Zig API through `Plugin.Vfs` (defined in
`src/core/Vfs.zig`):

- **Native** — thin wrappers around `std.fs.cwd()`
- **WASM** — calls `host.vfs_file_*` / `host.vfs_dir_*` extern imports;
  the JS host holds an in-memory `Map<string, Uint8Array>` that can optionally
  be backed by IndexedDB / OPFS.

See [FileIO & VFS](./wasm#vfs) for usage patterns.

## Panel rendering

Plugins draw their UI by registering a **draw callback** with `registerPanel`.
The callback is called by the host during its dvui rendering pass — inside
`dvui.Window.begin()` / `dvui.Window.end()`, so all dvui widgets are
available.

```zig
fn drawPanel() callconv(.c) void {
    // dvui widgets are available here
    var lbl = dvui.label(@src(), "Hello from my plugin!", .{});
    _ = lbl;
}
```

The callback has `callconv(.c)` so it is callable through the vtable on native
and through WASM table indirection on web.

## Memory

`Plugin.allocator()` returns the host's allocator on native (`std.mem.Allocator`
backed by the VTable `host_alloc` / `host_realloc` / `host_free` calls) and
`std.heap.wasm_allocator` on WASM.  You do not need to create your own arena
for general allocations.
