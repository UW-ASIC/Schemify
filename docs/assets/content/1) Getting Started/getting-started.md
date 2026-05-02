# Getting Started

## Prerequisites

| Tool | Minimum version | Notes |
|------|----------------|-------|
| Zig | 0.15.2 | included in the Nix shell |
| Verilator | 5.x | for digital co-simulation |
| Yosys | 0.38+ | for RTL synthesis |
| ngspice | 42+ | for analog simulation |

## Quick Start (Nix)

```bash
# Clone the repository
git clone https://github.com/UWASIC/Schemify.git
cd Schemify

# Enter the development shell (provides Zig, Verilator, Yosys, …)
nix develop

# Build and run
zig build run

# Run with a project directory
zig build run -- /path/to/my-project
```

## Quick Start (Manual)

If you prefer not to use Nix, install Zig 0.15.2 manually and ensure `verilator` and `yosys` are on your `$PATH`.

```bash
zig build        # build only
zig build run    # build + run
zig build test   # run all tests
```

## Web Build

```bash
zig build -Dbackend=web
# Output: zig-out/web/
# Serve with any static file server
```

## Opening a Project

Schemify looks for a `Config.toml` in the directory passed as the first argument (or the current directory if none is given):

```bash
# Opens the project defined in ~/designs/inverter/Config.toml
schemify ~/designs/inverter
```

## CLI Usage

Schemify has a first-class headless CLI — no display, no Tcl, no virtual framebuffer.

```bash
# Generate SPICE netlist
schemify --netlist output.spice schematic.chn

# Generate Xyce-compatible netlist
schemify --netlist --xyce output.spice schematic.chn

# Export SVG render
schemify --export-svg render.svg schematic.chn

# Install a plugin
schemify --plugin-install https://example.com/plugin.wasm
```

## First Project

Create a directory with a `Config.toml`:

```toml
name = "My First Design"
pdk  = "sky130"

[paths]
chn    = ["top.chn"]
chn_tb = ["tb.chn_tb"]
```

Then run `schemify .` inside that directory.
