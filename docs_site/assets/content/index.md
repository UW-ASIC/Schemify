# Schemify Documentation

**Schemify** is an open-source schematic editor written in [Zig](https://ziglang.org/), targeting mixed-signal IC design workflows where analog schematics coexist with digital RTL blocks.

---

## What makes Schemify different?

| | xschem | **Schemify** |
|---|---|---|
| Core language | C + Tcl | Zig |
| Plugin languages | Tcl only | Zig, C, C++, Rust, Go, Python, WASM |
| Web deployment | Impossible | `zig build -Dbackend=web` |
| Build | 14+ apt packages | `zig build` |
| Simulator backends | ngspice | ngspice + Xyce |
| Undo model | Full snapshot copy | Command inverses (fast) |
| File format | `.sch` / `.sym` (X11 geometry) | `.chn` (LLM-optimized, lossless) |

Schemify keeps xschem's design philosophy — keyboard-driven, hierarchy-first, SPICE-native — while replacing the 1988 deployment stack.

---

## Quick Start

```bash
# Clone the repo
git clone https://github.com/UWASIC/Schemify.git
cd Schemify

# Enter Nix dev shell (provides Zig, Verilator, Yosys, ngspice)
nix develop

# Build and run
zig build run

# Run with a project directory
zig build run -- /path/to/my-project
```

No Nix? Install [Zig 0.15.2](https://ziglang.org/download/) manually and run `zig build run`.

---

## Documentation Sections

- **[Getting Started](/1) Getting Started/introduction)** — What Schemify is, installation, configuration
- **[File Format](/2) File Format/overview)** — The `.chn` format specification
- **[Usage](/3) Usage/keyboard-shortcuts)** — Keyboard shortcuts and editor usage
- **[Live Demo](/3) Usage/live-demo)** — Browse example schematics in your browser
- **[GitHub Pages](/3) Usage/github-pages)** — Publish your circuit as a live web viewer
- **[Developer Guide](/4) Developer Guide/architecture)** — Architecture, conventions, contributing
- **[Plugin System](/5) Plugins/overview)** — Building and deploying plugins

---

> [!TIP]
> Already using xschem? See [Schemify vs xschem](/1) Getting Started/schemify-vs-xschem) for a detailed comparison and migration guide.
