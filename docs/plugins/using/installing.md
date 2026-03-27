# Installing Plugins

## Native (Linux / macOS)

Schemify scans `~/.config/Schemify/` at startup. Each subdirectory is treated
as a plugin slot. The runtime looks for a shared library in one of these
locations relative to the slot directory:

```
~/.config/Schemify/
  MyPlugin/
    libMyPlugin.so       ← preferred (zig build output)
    lib/libMyPlugin.so   ← alternative prefix layout
```

### Installing from a release tarball

Download the release archive from the plugin's GitHub releases page, then
extract it into your config directory:

```bash
mkdir -p ~/.config/Schemify/GmIDVisualizer
tar -xzf GmIDVisualizer-linux-x86_64.tar.gz -C ~/.config/Schemify/GmIDVisualizer
```

### Building and installing yourself

If the plugin uses the Schemify SDK the `run` build step installs automatically:

```bash
cd plugins/MyPlugin
zig build run          # native: copies .so + assets to ~/.config/Schemify/MyPlugin/ then launches host
zig build run -Dbackend=web  # web: builds .wasm, updates plugins.json, serves at :8080
```

The `run` step is wired by
`helper.addNativeAutoInstallRunStep(b, "MyPlugin", sdk_dep, "MyPlugin")`.

### Manual install (zig build only)

```bash
zig build
cp -r zig-out/lib/ ~/.config/Schemify/MyPlugin/
```

## Web (WASM)

Place `<Plugin>.wasm` in the `plugins/` directory relative to `index.html`,
then add the filename to `plugins/plugins.json`:

```json
{ "plugins": ["GmIDVisualizer.wasm", "MyPlugin.wasm"] }
```

`plugin_host.js` reads this manifest on page load and instantiates each
listed `.wasm` file.

## `plugin.toml`

Every plugin should ship a `plugin.toml` describing itself:

```toml
[plugin]
name        = "MyPlugin"
version     = "0.1.0"
author      = "Your Name"
description = "A brief description."
entry       = "libMyPlugin.so"
```

This file is not currently parsed by the host at runtime but is used by
package managers and the Schemify plugin registry.

## Verifying installation

Launch Schemify; loaded plugins appear in the log output:

```
[info] [runtime] loaded plugin "MyPlugin" v0.1.0 (ABI 6)
```

If the ABI version does not match, the library is skipped:

```
[warn] [runtime] skipping MyPlugin: ABI version mismatch (got 5, expected 6)
```
