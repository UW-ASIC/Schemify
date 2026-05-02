# Schemify vs xschem

> **tl;dr** — xschem is to Schemify as vim is to Neovim.
>
> xschem is a battle-tested, single-developer masterpiece that defined the open-source analog EDA workflow. Schemify keeps that philosophy — keyboard-driven, hierarchy-first, SPICE-native — but rebuilds the foundation for modern deployment targets: browser, GPU rendering, and language-agnostic plugins.

## The Analogy

| | vim | xschem |
|---|---|---|
| **Core language** | C | C + Tcl/Tk |
| **Extension model** | Vimscript | Tcl scripts |
| **Deployment** | Terminal, any Unix | X11, Linux/macOS only |

| | Neovim | Schemify |
|---|---|---|
| **Core language** | C + Lua | Zig |
| **Extension model** | Lua + LSP + any-language plugins | ABI v6: Zig/C/Rust/Go/Python/WASM |
| **Deployment** | Terminal + GUI frontends + web | Native + browser (WASM) |

## Architectural Limits of xschem

These are not missing features — they are architectural impossibilities.

### Browser deployment is impossible

xschem requires X11/Xlib, Tcl/Tk, and POSIX `fork()`/`popen()`. None of these exist in WebAssembly.

Schemify: `zig build -Dbackend=web` ships the full editor in a browser via HTML5 Canvas.

### Language-agnostic plugins don't exist

xschem has no binary plugin ABI. "Plugins" are Tcl scripts or external processes. There is no `.so`/`.dylib`/`.wasm` loading, no versioned protocol, no way to write a plugin in Python, Rust, or Go.

Schemify's ABI v6:
```
schemify_process(in_ptr, in_len, out_ptr, out_cap) -> usize
wire format: [u8 tag][u16 LE payload_sz][payload bytes]
```
Any language that compiles to a shared library or WASM module is a first-class plugin.

### Build dependencies are heavy

xschem on Debian/Ubuntu requires 14+ packages. On macOS it requires XQuartz. On Windows it requires Cygwin + an X server.

Schemify: `zig build`. One command, any platform.

### True headless requires display tricks

xschem's `--no_x` still initializes Tcl/Tk. CI environments need `Xvfb`.

Schemify's CLI compiles out the GUI entirely:
```bash
schemify --netlist output.spice schematic.chn
schemify --export-svg render.svg schematic.chn
```

## Data Model Comparison

**xschem** uses Array-of-Structs:
```c
xWire wires[MAX_WIRES];
// Undo: memcpy of all element arrays on every operation
```

**Schemify** uses Structure-of-Arrays via `std.MultiArrayList`:
```zig
const xs = wires.items(.x1);  // contiguous, cache-friendly
// Undo: command inverses, not full snapshots
```

## Side-by-Side

| | xschem | Schemify |
|---|---|---|
| **Core language** | C (67%) + Tcl (15%) | Zig |
| **GUI framework** | Tcl/Tk | dvui (immediate-mode) |
| **Rendering** | Xlib → X protocol (CPU) | raylib (OpenGL) / HTML5 Canvas |
| **Web deployment** | Impossible | `zig build -Dbackend=web` |
| **Plugin languages** | Tcl only | Any: Zig, C, C++, Rust, Go, Python, WASM |
| **Plugin ABI** | None (Tcl scripts) | ABI v6, versioned binary protocol |
| **Data layout** | Array-of-Structs | MultiArrayList (Structure-of-Arrays) |
| **Undo model** | Full deep-copy snapshot | Command inverses, ring buffer |
| **CLI** | `--no_x` + raw Tcl flags | First-class: `--netlist`, `--export-svg` |
| **Build** | autoconf + 14 apt packages | `zig build` |
| **Windows** | Cygwin + X server required | Native |
| **Simulator backends** | ngspice | ngspice + Xyce |

## Where xschem Is Still Ahead

- **Ecosystem** — 25 years of SKY130 / IHP symbols and community `.sch` files
- **ngspice integration depth** — `spice_netlist.c` is 4000+ lines of edge-case handling
- **Tcl scripting power** — parametric symbol generation, corner sweeps, backannotation pipelines

Schemify addresses the ecosystem gap via **EasyImport** — xschem `.sch`/`.sym` files read natively. Existing designs migrate without conversion.
