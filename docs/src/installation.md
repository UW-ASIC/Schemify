# Installation

## From Source (Recommended)

Schemify is built with Rust. You need a nightly Rust toolchain.

### Prerequisites

**Rust nightly**

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup default nightly
```

**System libraries (Linux)**

Schemify uses egui/eframe with OpenGL. Install the following:

Debian / Ubuntu:
```sh
sudo apt install -y \
  pkg-config libxkbcommon-dev libgl-dev \
  libx11-dev libxcursor-dev libxrandr-dev libxi-dev \
  libfontconfig-dev libssl-dev
```

Fedora:
```sh
sudo dnf install -y \
  pkg-config libxkbcommon-devel mesa-libGL-devel \
  libX11-devel libXcursor-devel libXrandr-devel libXi-devel \
  fontconfig-devel openssl-devel
```

Arch:
```sh
sudo pacman -S --needed \
  pkgconf libxkbcommon mesa \
  libx11 libxcursor libxrandr libxi \
  fontconfig openssl
```

### Build & Install

```sh
git clone https://github.com/OmarSiwy/Schemify.git
cd Schemify
cargo build --release
```

The binary lands at `target/release/schemify-engine`. Copy it to your PATH:

```sh
cp target/release/schemify-engine ~/.local/bin/schemify
```

### With WASM Plugin Support

To enable loading WebAssembly plugins:

```sh
cargo build --release --features schemify-plugins/wasm
```

## Using Nix

If you use Nix with flakes, the repository includes a `flake.nix` that sets up the full development environment including PySpice:

```sh
nix develop
cargo build --release
```

This gives you:
- Nightly Rust with the `wasm32-unknown-unknown` target
- All native GUI dependencies
- PySpice (bundled automatically via `PYSPICE_MODULE_DIR`)
- `trunk` and `wasm-bindgen-cli` for WASM builds
- `xschem` for netlist roundtrip testing

## Verifying the Install

```sh
schemify --help
```

You should see:

```
SchemifyRS — schematic editor

Usage: schemify [OPTIONS] [COMMAND]

Options:
  -f, --file <FILE>  Schematic file to operate on
      --save         Save file after command execution
  -h, --help         Print help

Commands:
  zoom-in, zoom-out, place-device, add-wire, run-sim, ...
```

## Dependencies

| Dependency | Version | Purpose |
|---|---|---|
| [egui](https://github.com/emilk/egui) | 0.31 | Immediate-mode GUI framework |
| [eframe](https://github.com/emilk/egui/tree/master/crates/eframe) | 0.31 | Native + WASM window backend |
| [clap](https://github.com/clap-rs/clap) | 4 | CLI argument parsing |
| [serde](https://serde.rs/) | 1 | Serialization (JSON, TOML) |
| [lasso](https://github.com/Kixiron/lasso) | 0.7 | String interning for performance |
| [wasmtime](https://wasmtime.dev/) | 30 | WASM plugin runtime (optional) |
| [rfd](https://github.com/PolyMeilex/rfd) | 0.15 | Native file dialogs |

### Simulation Dependencies (Optional)

To run simulations, you need at least one SPICE backend installed:

- **NgSpice** -- `sudo apt install ngspice` (most common)
- **Xyce** -- [install from Sandia](https://xyce.sandia.gov/)
- **LTspice** -- [download from Analog Devices](https://www.analog.com/en/design-center/design-tools-and-calculators/ltspice-simulator.html) (Wine on Linux)
- **Spectre** -- part of Cadence tools (commercial)

Python 3 is also needed for PySpice integration.
