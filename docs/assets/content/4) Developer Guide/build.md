# Build System

## Requirements

| Tool | Version | Purpose |
|------|---------|---------|
| Zig | 0.15.2 | Primary compiler |
| Nix | any | Reproducible dev shell (optional but recommended) |
| sass | any | SCSS → CSS compilation |
| wasm-pack | 0.12+ | WASM build (web backend only) |

## Common Commands

```bash
# Native build
zig build

# Native build + run
zig build run

# Web/WASM build
zig build -Dbackend=web

# Run tests
zig build test

# Run specific test file
zig build test -- --test-filter "parseChN"

# Build with optimizations
zig build -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseFast
```

## Build Options

| Option | Default | Description |
|--------|---------|-------------|
| `-Dbackend=native` | default | Build native binary (raylib/OpenGL) |
| `-Dbackend=web` | — | Build WASM module (HTML5 Canvas) |
| `-Doptimize=Debug` | default | No optimizations, debug info |
| `-Doptimize=ReleaseSafe` | — | Optimized, bounds checks retained |
| `-Doptimize=ReleaseFast` | — | Maximum optimization, no safety checks |
| `-Doptimize=ReleaseSmall` | — | Size-optimized (for WASM) |

## Nix Dev Shell

The `flake.nix` provides a fully reproducible development environment:

```bash
nix develop      # enter dev shell
nix build        # build via nix (uses build.zig internally)
```

The shell provides: Zig 0.15.2, Verilator, Yosys, ngspice, sass, wasm-pack, and all system libraries required by raylib.

## build.zig Structure

```zig
pub fn build(b: *std.Build) void {
    const backend = b.option(Backend, "backend", "native or web") orelse .native;

    switch (backend) {
        .native => buildNative(b),
        .web    => buildWeb(b),
    }
}
```

The native build links raylib and dvui. The web build uses the WASM-safe dvui backend and emits `.wasm` + supporting JS.

## Plugin Build

Plugins are built independently using `schemify_sdk`:

```zig
// plugin/build.zig
const helper = @import("schemify_sdk").build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx = helper.setup(b, sdk_dep);
    const lib = helper.addNativePluginLibrary(b, ctx, "MyPlugin", "src/main.zig");
    b.installArtifact(lib);
    helper.addNativeAutoInstallRunStep(b, "MyPlugin", sdk_dep, "MyPlugin");
}
```

```bash
# Build and install plugin to ~/.config/Schemify/MyPlugin/
zig build run
```

## CI/CD

Tests run on every PR via GitHub Actions:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: mlugg/setup-zig@v1
        with: { version: "0.15.2" }
      - run: zig build test

  build-web:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: mlugg/setup-zig@v1
        with: { version: "0.15.2" }
      - run: zig build -Dbackend=web -Doptimize=ReleaseSmall
```

## Dependency Management

Dependencies are declared in `build.zig.zon`:

```zig
.{
    .name = "schemify",
    .version = "0.1.0",
    .dependencies = .{
        .dvui = .{
            .url = "https://github.com/david-vanderson/dvui/archive/...",
            .hash = "...",
        },
    },
}
```

`zig build` fetches and caches all dependencies automatically. No manual `npm install` or `cargo fetch` step needed.
