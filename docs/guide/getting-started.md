# Getting Started

## Prerequisites

Schemify is built with [Zig 0.15](https://ziglang.org/download/) and uses
[Nix](https://nixos.org/) for a reproducible development environment.

| Tool | Minimum version | Notes |
|------|----------------|-------|
| Zig | 0.15.2 | included in the Nix shell |
| Verilator | 5.x | for digital co-simulation |
| Yosys | 0.38+ | for RTL synthesis |
| ngspice | 42+ | for analog simulation |

## Quick start (Nix)

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

## Quick start (manual)

If you prefer not to use Nix, install Zig 0.15.2 manually and ensure
`verilator` and `yosys` are on your `$PATH`.

```bash
zig build        # build only
zig build run    # build + run
zig build test   # run all tests
```

## Opening a project

Schemify looks for a `Config.toml` in the directory passed as the first argument
(or the current directory if none is given):

```bash
# Opens the project defined in ~/designs/inverter/Config.toml
schemify ~/designs/inverter
```

See [Config.toml reference](/guide/config) for all available keys.
