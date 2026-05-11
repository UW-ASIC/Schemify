# WASM Plugin Guide

WASM plugins run in a sandboxed wasm3 runtime. They use the exact same API as native plugins (11 exports, SchemifyHost callbacks) but gain automatic security approval and universal binary compatibility.

---

## Why WASM?

- **Sandboxed by default**: No filesystem, no network, no syscalls. Only `schemify_host_*` functions.
- **Auto-approved**: No trust prompt. WASM plugins cannot escape the sandbox.
- **Universal binary**: One `.wasm` file runs on Linux, macOS, Windows.
- **Any language**: C, C++, Rust, Zig, Go, AssemblyScript -- anything that compiles to wasm32.

Trade-off: ~3-10x slower than native. Fine for UI plugins, not for heavy computation.

---

## Required Exports

WASM plugins export the same symbols as native plugins:

```
schemify_activate(host_ptr: i32) -> void        [REQUIRED]
schemify_alloc(size: i32) -> i32                 [REQUIRED for WASM]
schemify_deactivate() -> void
schemify_render(panel_id_ptr: i32) -> i32
schemify_on_html_event(panel_id_ptr: i32, event_json_ptr: i32) -> void
schemify_on_command(name_ptr: i32, args_ptr: i32) -> void
schemify_on_schematic_changed() -> void
schemify_on_selection_changed(json_ptr: i32) -> void
schemify_on_key_event(json_ptr: i32) -> void
schemify_on_hover(json_ptr: i32) -> void
schemify_provide(type_ptr: i32, ctx_ptr: i32) -> i32
schemify_on_message(sender_ptr: i32, topic_ptr: i32, payload_ptr: i32) -> void
```

**`schemify_alloc` is required for WASM.** The host calls it to allocate space in the plugin's linear memory for passing string arguments.

---

## Memory Model

WASM plugins have their own linear memory. The host and plugin exchange strings through this memory:

**Host -> Plugin (string arguments):**
1. Host calls `schemify_alloc(len + 1)` to get a pointer in WASM memory
2. Host writes the null-terminated string at that pointer
3. Host calls the export with the pointer as argument

**Plugin -> Host (return values):**
1. Plugin writes string into its own linear memory
2. Plugin returns the pointer (i32 offset)
3. Host reads the string from WASM memory
4. Host copies it immediately

**Implementing `schemify_alloc`:**

```c
// C example -- simple bump allocator
static char alloc_buf[65536];
static int alloc_pos = 0;

__attribute__((export_name("schemify_alloc")))
int schemify_alloc(int size) {
    if (alloc_pos + size > sizeof(alloc_buf)) {
        alloc_pos = 0;  // wrap around (fine -- host copies immediately)
    }
    int ptr = (int)(alloc_buf + alloc_pos);
    alloc_pos += size;
    return ptr;
}
```

```rust
// Rust example
static mut ALLOC_BUF: [u8; 65536] = [0; 65536];
static mut ALLOC_POS: usize = 0;

#[no_mangle]
pub extern "C" fn schemify_alloc(size: i32) -> i32 {
    unsafe {
        if ALLOC_POS + size as usize > ALLOC_BUF.len() {
            ALLOC_POS = 0;
        }
        let ptr = ALLOC_BUF.as_ptr().add(ALLOC_POS) as i32;
        ALLOC_POS += size as usize;
        ptr
    }
}
```

---

## Import Validation

The host parses the WASM import section before instantiation. Only these imports are allowed:

```
schemify_host_log(level_ptr: i32, msg_ptr: i32) -> void
schemify_host_set_status(msg_ptr: i32) -> void
schemify_host_push_command(cmd_ptr: i32) -> i32
schemify_host_request_refresh() -> void
schemify_host_read_file(path_ptr: i32) -> i32
schemify_host_write_file(path_ptr: i32, data_ptr: i32) -> i32
schemify_host_project_dir() -> i32
schemify_host_plugin_data_dir() -> i32
schemify_host_register_panel(json_ptr: i32) -> void
schemify_host_unregister_panel(id_ptr: i32) -> void
schemify_host_register_command(json_ptr: i32) -> void
schemify_host_register_keybind(json_ptr: i32) -> void
schemify_host_register_provider(type_ptr: i32) -> void
schemify_host_publish(topic_ptr: i32, payload_ptr: i32) -> void
schemify_host_canvas_*  (9 canvas functions)
schemify_host_schematic_* (8 schematic functions)
```

If the WASM module imports WASI functions (`fd_write`, `proc_exit`, etc.), `env` functions, or anything not matching `schemify_host_*`, the load fails with `UntrustedImports`.

---

## Compiling to WASM

### From C

```sh
clang --target=wasm32 -O2 -nostdlib \
    -Wl,--no-entry -Wl,--export-dynamic -Wl,--allow-undefined \
    -Iinc -o plugin.wasm src/plugin.c
```

Key flags:
- `--target=wasm32`: Compile for WASM
- `-nostdlib`: No libc (you provide `schemify_alloc` instead of malloc)
- `--no-entry`: No `_start`/`main` function
- `--export-dynamic`: Export all non-static functions
- `--allow-undefined`: Host-provided imports resolved at runtime

### From Rust

```toml
# Cargo.toml
[lib]
crate-type = ["cdylib"]

[profile.release]
opt-level = "s"
lto = true
```

```sh
cargo build --release --target wasm32-unknown-unknown
# Output: target/wasm32-unknown-unknown/release/plugin.wasm
```

### From Zig

```sh
zig build-lib -target wasm32-freestanding -O ReleaseFast src/plugin.zig
```

### From Go (TinyGo)

```sh
tinygo build -o plugin.wasm -target wasi -no-debug ./plugin.go
```

Note: TinyGo WASI target imports `fd_write` etc. -- these will fail import validation. Use TinyGo's `wasm` target or a custom linker script.

---

## Complete C Example (WASM)

```c
/* plugin.c -- minimal WASM plugin */

typedef unsigned int uint32_t;

/* Host imports (provided at runtime) */
extern void schemify_host_log(const char* level, const char* msg);
extern void schemify_host_set_status(const char* msg);
extern void schemify_host_register_panel(const char* json);
extern void schemify_host_request_refresh(void);

/* Required: allocator for host->plugin string passing */
static char alloc_buf[32768];
static int alloc_pos = 0;

__attribute__((export_name("schemify_alloc")))
int schemify_alloc(int size) {
    if (alloc_pos + size > (int)sizeof(alloc_buf)) alloc_pos = 0;
    int ptr = (int)&alloc_buf[alloc_pos];
    alloc_pos += size;
    return ptr;
}

/* Plugin state */
static int counter = 0;
static char html_buf[2048];

/* String length (no libc) */
static int slen(const char* s) {
    int n = 0;
    while (s[n]) n++;
    return n;
}

/* Simple int-to-string */
static int itoa_simple(int val, char* buf) {
    if (val == 0) { buf[0] = '0'; buf[1] = 0; return 1; }
    int neg = 0, n = 0;
    char tmp[16];
    if (val < 0) { neg = 1; val = -val; }
    while (val > 0) { tmp[n++] = '0' + (val % 10); val /= 10; }
    int pos = 0;
    if (neg) buf[pos++] = '-';
    for (int i = n - 1; i >= 0; i--) buf[pos++] = tmp[i];
    buf[pos] = 0;
    return pos;
}

/* Metadata */
__attribute__((export_name("schemify_api_version")))
const uint32_t schemify_api_version = 1;

/* Exports */
__attribute__((export_name("schemify_activate")))
void schemify_activate(void* host) {
    (void)host;  /* WASM uses imports, not function pointers */
    schemify_host_log("info", "WASM counter plugin activated");
    schemify_host_register_panel(
        "{\"id\":\"counter\",\"title\":\"Counter\",\"layout\":\"right_sidebar\"}");
}

__attribute__((export_name("schemify_render")))
const char* schemify_render(const char* panel_id) {
    /* Build HTML with counter value */
    char num[16];
    itoa_simple(counter, num);

    char* p = html_buf;
    const char* pre = "<div style='padding:12px;'><h2>Counter</h2>"
                      "<p style='font-size:24px;text-align:center;'>";
    const char* mid = "</p><div style='display:flex;gap:8px;'>"
                      "<button id='dec'>-</button>"
                      "<button id='inc'>+</button>"
                      "<button id='reset'>Reset</button>"
                      "</div></div>";

    int i;
    for (i = 0; pre[i]; i++) *p++ = pre[i];
    for (i = 0; num[i]; i++) *p++ = num[i];
    for (i = 0; mid[i]; i++) *p++ = mid[i];
    *p = 0;

    return html_buf;
}

__attribute__((export_name("schemify_on_html_event")))
void schemify_on_html_event(const char* panel_id, const char* event_json) {
    /* Minimal string search (no strstr in nostdlib) */
    const char* p = event_json;
    while (*p) {
        if (p[0] == 'i' && p[1] == 'n' && p[2] == 'c') { counter++; break; }
        if (p[0] == 'd' && p[1] == 'e' && p[2] == 'c') { counter--; break; }
        if (p[0] == 'r' && p[1] == 'e' && p[2] == 's') { counter = 0; break; }
        p++;
    }
    schemify_host_request_refresh();
}
```

Build:
```sh
clang --target=wasm32 -O2 -nostdlib \
    -Wl,--no-entry -Wl,--export-dynamic -Wl,--allow-undefined \
    -o counter.wasm plugin.c
```

---

## WASM vs Native

| Aspect | WASM | Native |
|--------|------|--------|
| Host functions | Called as imports (`schemify_host_*`) | Called via function pointer table |
| String passing | Through linear memory + `schemify_alloc` | Direct `const char*` pointers |
| Activate arg | Not used (imports are the API) | `const SchemifyHost*` pointer |
| Security | Sandboxed, auto-approved | TOFU trust model |
| Performance | ~3-10x slower | Full native speed |
| Portability | Single binary, all platforms | Per-platform .so/.dylib/.dll |
| Stdlib | None (unless you bundle it) | Full access |

---

## Limitations

- **No standard library** unless you bundle one (increases binary size).
- **No filesystem** except through `schemify_host_read_file` / `schemify_host_write_file`.
- **No network access.**
- **No threads** -- single-threaded execution only.
- **Linear memory limit** -- 64KB pages, typically 1-16MB usable.
- **No WASI** -- WASI imports fail validation. Use `schemify_host_*` exclusively.
- **No fuel metering yet** -- infinite loops block the worker thread (timeout planned).

---

## Security Model

WASM plugins are auto-approved because:
1. They run in isolated linear memory (no access to host address space)
2. Import validation ensures only `schemify_host_*` functions are callable
3. They cannot perform syscalls, access the filesystem, or open network connections
4. The host mediates all I/O through its function table

Users never see a trust prompt for WASM plugins.

---

## plugin.toml for WASM

```toml
[plugin]
name = "My WASM Plugin"
version = "1.0.0"
author = "Your Name"
description = "A sandboxed WASM plugin"
api = 1

[activation]
events = ["on_startup"]

[[panels]]
id = "demo"
title = "Demo"
layout = "right_sidebar"

[build]
binary = "plugin.wasm"    # <-- .wasm extension triggers WASM loader
```

The host checks the file extension in the `binary` field to select the loader (dlopen vs wasm3).
