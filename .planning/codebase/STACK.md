# Technology Stack

**Analysis Date:** 2026-04-04

## Languages

**Primary:**
- Zig 0.15.x (minimum 0.15.0, installed 0.15.2) - All application code, build system, plugin ABI, test harness

**Secondary:**
- JavaScript (ES2020+) - WASM host bridge, VFS worker, boot loader (`web/`, `src/web/`)
- C - NGSpice bindings via `@cImport` of `sharedspice.h` (`deps/ngspice.zig`)
- C++ - Xyce bindings via C shim `xyce_c_api.cpp` (`deps/xyce.zig`, `deps/Xyce/xyce_c_api.cpp`)

**Plugin SDK Languages (tools/sdk/):**
- Zig - `src/plugins/lib.zig` (Reader/Writer/Framework)
- C/C++ - `tools/sdk/schemify_plugin.h` (header-only C99 SDK)
- Rust - `tools/sdk/bindings/rust/schemify-plugin/` (crate with `Plugin` trait + `export_plugin!` macro)
- TinyGo/Go - `tools/sdk/bindings/tinygo/schemify/plugin.go`
- Python - `tools/sdk/bindings/python/schemify/__init__.py` (runs via SchemifyPython embedder)

## Runtime

**Environment:**
- Native: Linux/macOS/Windows host OS, linked against system libc
- Web: wasm32-freestanding target, runs in browser via WebAssembly

**Package Manager:**
- Zig Build System (built-in, `build.zig` + `build.zig.zon`)
- Lockfile: `build.zig.zon` contains dependency hashes (acts as lockfile)
- No npm/cargo/pip for the main project (only for plugin SDK bindings)

## Frameworks

**Core:**
- dvui 0.4.0-dev - Immediate-mode GUI toolkit (fetched from GitHub `david-vanderson/dvui`)
  - Native backend: dvui + raylib (module `dvui_raylib`)
  - Web backend: dvui + WASM canvas (module `dvui_web_wasm`)
  - Dependency declared in `build.zig.zon`

**GUI/Rendering:**
- raylib - Native windowing, OpenGL rendering, input handling (pulled transitively via dvui)
- HTML5 Canvas - Web rendering target via dvui web backend

**Testing:**
- Zig built-in test framework (`std.testing`)
- Custom test runner: `test/test_runner.zig` (prints pass/fail/skip/leak per test)
- Custom size runner: `test/size_runner.zig` (prints `@sizeOf` for structs)

**Build/Dev:**
- Zig Build System - `build.zig` orchestrates everything
- Python 3 `http.server` - Local web dev server (`zig build run_local -Dbackend=web`)
- Shell lint step - Bans `std.fs.*` / `std.posix.getenv` outside `utility/` and `cli/`

## Key Dependencies

**Critical:**
- dvui 0.4.0-dev - The entire GUI layer; both native and web rendering depend on it
  - Source: `https://github.com/david-vanderson/dvui/archive/refs/heads/main.tar.gz`
  - Hash: `dvui-0.4.0-dev-AQFJmS--3wANx5NhfSO0dzJ2ylKV5zLY89nKnK3KnJf7`
  - Configured in: `build.zig.zon`

**Infrastructure:**
- raylib (transitive via dvui) - Native window creation, OpenGL context, input
- libngspice - SPICE circuit simulation (optional, linked dynamically via `deps/ngspice.zig`)
- libxyce + Trilinos - Xyce circuit simulation (optional, linked dynamically via `deps/xyce.zig`)

**No other external Zig dependencies.** The project is deliberately minimal in its dependency tree.

## Module Graph

The build system defines these internal modules with explicit dependency wiring:

```
utility     (no deps)              → Logger, Vfs, Platform, Simd, UnionFind
core        (utility)              → Schemify data model, Reader/Writer, Netlist, TOML, HDL
commands    (state, core, utility, dvui) → Command dispatch, undo/redo, all editor commands
state       (utility, commands, core)    → AppState, Document, Viewport, Selection, Tool
plugins     (utility, state, theme_config, commands) → Plugin runtime, installer, ABI v6
theme_config (dvui)                → Theme.zig color palette + JSON overrides
```

Two-pass module creation in `build.zig` allows circular references (commands <-> state).

## Configuration

**Environment:**
- `HOME` env var - Used to locate plugin directory (`~/.config/Schemify/`)
- No `.env` files; no secrets required for the application itself
- Build-time options passed via `-D` flags to `zig build`

**Build Options (build.zig):**
- `-Dbackend=native|web` - Selects GUI backend (default: `native`)
- `-Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall` - Standard Zig optimize
- `-Dtarget=...` - Cross-compilation target (native default)

**Project Configuration:**
- `Config.toml` in project root - Parsed by `src/core/Toml.zig`
- Sections: `name`, `[paths]`, `[legacy_paths]`, `[simulation]`, `[plugins]`
- Supports glob patterns in path arrays (e.g., `chn = ["examples/*"]`)

**Build Configuration Files:**
- `build.zig` - Main build script
- `build.zig.zon` - Dependency manifest (dvui)
- `tools/build_dep.zig` - SPICE backend build helper (ngspice + Xyce paths)
- `tools/sdk/build_plugin_helper.zig` - Plugin SDK build helper for external repos

## Platform Requirements

**Development:**
- Zig >= 0.15.0 (tested with 0.15.2)
- Linux: X11 display backend (hardcoded in `build.zig`: `.linux_display_backend = .X11`)
- Optional: ngspice source tree at `deps/ngspice/` (for SPICE simulation)
- Optional: Xyce + Trilinos at `deps/Xyce/` (for Xyce simulation)
- Optional: Python 3 (for `zig build run_local` web dev server)

**Production (Native):**
- Linux: libraylib (linked), X11 libraries
- macOS: raylib framework
- Windows: raylib.dll

**Production (Web):**
- Modern browser with WebAssembly support
- OPFS (Origin Private File System) for persistent VFS storage
- Web Worker support (for VFS persistence worker)
- Static file hosting (no server-side logic needed)

## File Formats

**Native to Schemify:**
- `.chn` - Schematic files
- `.chn_tb` - Testbench files
- `.chn_prim` - Primitive/symbol files
- `Config.toml` - Project configuration

**Import/Export:**
- Verilog/VHDL - HDL parsing (`src/core/HdlParser.zig`)
- Yosys JSON - Synthesis results (`src/core/YosysJson.zig`)
- SVG - Export via CLI (`src/cli.zig` `--export-svg`)
- SPICE netlist - Generation via CLI (`src/cli.zig` `--netlist`)

**Plugin Artifacts:**
- `.so` / `.dylib` / `.dll` - Native plugin shared libraries
- `.wasm` - WebAssembly plugin modules
- `plugins.json` - Web plugin registry

---

*Stack analysis: 2026-04-04*
