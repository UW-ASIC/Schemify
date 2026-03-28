# Publishing Custom Plugins

This guide explains how to build, distribute, and expose your Schemify plugin so
users can discover and install it through the in-app **Plugin Marketplace** using
your GitHub URL.

---

## 1 — Create your plugin repository

Your plugin can live in its own GitHub repository (recommended) or as a
directory inside the Schemify monorepo.

### `plugin.toml` — the canonical metadata file

Place a `plugin.toml` next to your `build.zig`.  This is the single source of
truth used both by the in-repo registry generator (`tools/scripts/gen_registry.py`) and
by the GitHub CI workflow that builds and publishes your plugin.

```toml
[plugin]
name        = "MyPlugin"           # code identifier (no spaces); also the install dir name
version     = "0.1.0"
author      = "Your Name"
entry       = "libMyPlugin.so"     # output library filename
description = "One-sentence description shown in the Marketplace card."
tags        = ["analog", "simulation"]

[build]
apt_deps = []                      # extra Ubuntu apt packages needed at build time
```

| Field | Required | Notes |
|---|---|---|
| `name` | yes | ASCII identifier, no spaces.  Becomes the `id` in the registry and the directory name under `~/.config/Schemify/`. |
| `version` | no | Semver string; defaults to `0.1.0`. |
| `author` | no | Author or organisation name; defaults to `"UWASIC"`. |
| `entry` | yes | Output `.so` filename, e.g. `libMyPlugin.so`. |
| `description` | no | If omitted, the first paragraph of `README.md` is used. |
| `tags` | no | Array of strings for search filtering in the Marketplace. |
| `[build].apt_deps` | no | Ubuntu packages to `apt-get install` before `zig build`. |

> **registry.json is auto-generated.** The Marketplace reads
> `plugins/registry.json`, which is committed back by CI after every push.
> You never edit it by hand.

### Custom plugin manifest (`schemify-plugin.json`)

For plugins hosted in their **own separate repository** (not the Schemify
monorepo), put a `schemify-plugin.json` at the repo root.  This is what the
Marketplace fetches when a user pastes your GitHub URL into the custom-plugin
field.

```json
{
  "version": 1,
  "plugins": [
    {
      "id": "MyPlugin",
      "name": "My Plugin",
      "author": "Your Name",
      "version": "0.1.0",
      "description": "One-sentence description shown in the Marketplace card.",
      "tags": ["analog", "simulation"],
      "repo": "https://github.com/you/my-schemify-plugin",
      "readme_url": "https://raw.githubusercontent.com/you/my-schemify-plugin/main/README.md",
      "download": {
        "linux": "https://github.com/you/my-schemify-plugin/releases/download/latest/libMyPlugin.so",
        "macos": "https://github.com/you/my-schemify-plugin/releases/download/latest/libMyPlugin.dylib"
      }
    }
  ]
}
```

---

## 2 — Write the plugin

Follow the [Zig plugin guide](zig.md) for the full API walkthrough.  The
minimum skeleton is:

```zig
// src/main.zig
const Plugin = @import("PluginIF");
const std    = @import("std");

export fn schemify_process(
    in_ptr: [*]const u8, in_len: usize,
    out_ptr: [*]u8,      out_cap: usize,
) usize {
    var r = Plugin.Reader.init(in_ptr[0..in_len]);
    var w = Plugin.Writer.init(out_ptr[0..out_cap]);
    while (r.next()) |msg| {
        switch (msg) {
            .load => {
                w.registerPanel(.{
                    .id = "my-plugin", .title = "My Plugin",
                    .vim_cmd = "myplugin", .layout = .overlay, .keybind = 0,
                });
                w.setStatus("My Plugin loaded");
            },
            .draw_panel => w.label("Hello from My Plugin!", 0),
            else => {},
        }
    }
    return if (w.overflow()) std.math.maxInt(usize) else w.pos;
}

export const schemify_plugin: Plugin.Descriptor = .{
    .name        = "my-plugin",
    .version_str = "0.1.0",
    .process     = schemify_process,
};
```

---

## 3 — Set up the GitHub Actions workflow

Copy the template below to `.github/workflows/build.yml` in your repository.
The workflow builds the plugin on every push and uploads the `.so` to a rolling
`latest` release so the download URL stays stable.

```yaml
name: Build plugin

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Zig
        uses: mlugg/setup-zig@v1
        with:
          version: '0.14.1'   # match Schemify's compiler version

      # Add extra apt packages your plugin needs, e.g.:
      # - name: Install dependencies
      #   run: sudo apt-get install -y libngspice0-dev

      - name: Build
        run: zig build -Doptimize=ReleaseSafe

      - name: Create or update 'latest' release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh release view latest --repo "$GITHUB_REPOSITORY" \
            || gh release create latest \
                 --repo "$GITHUB_REPOSITORY" \
                 --title "Latest build" \
                 --notes "Automatically updated on every push." \
                 --prerelease
          find zig-out/ -name '*.so' -o -name '*.dylib' | while read f; do
            gh release upload latest "$f" \
              --repo "$GITHUB_REPOSITORY" \
              --clobber
          done
```

### What the workflow does

| Step | Description |
|---|---|
| **Checkout** | Clones your repo with `submodules: recursive` if needed. |
| **Setup Zig** | Installs the exact compiler version Schemify targets. |
| **Build** | Runs `zig build -Doptimize=ReleaseSafe` in the repo root. |
| **Release** | Creates/updates the `latest` pre-release and uploads every `.so` / `.dylib` found in `zig-out/`.  The `--clobber` flag overwrites stale assets. |

The released binary URL will be:
```
https://github.com/<you>/<repo>/releases/download/latest/lib<YourPlugin>.so
```
Use this as the `download.linux` value in `schemify-plugin.json`.

---

## 4 — Incremental builds (monorepo or multi-plugin repos)

If you ship multiple plugins from one repo, add a path-filter step so only
changed directories are rebuilt:

```yaml
      - name: Detect changes
        uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            plugin-a:
              - 'plugins/PluginA/**'
            plugin-b:
              - 'plugins/PluginB/**'

      - name: Build PluginA
        if: steps.filter.outputs.plugin-a == 'true'
        working-directory: plugins/PluginA
        run: zig build -Doptimize=ReleaseSafe
```

See the [Schemify monorepo workflow](../../.github/workflows/build-plugins.yml)
for a complete reference.

---

## 5 — Install your plugin from the Marketplace

1. Open **Plugins → Plugin Marketplace** in Schemify.
2. Paste your GitHub repository URL into the **Custom plugin** field at the
   bottom of the Marketplace window, e.g.:
   ```
   https://github.com/you/my-schemify-plugin
   ```
3. Click **Add**.  Schemify fetches `schemify-plugin.json` from the `main`
   branch, parses it, and adds your plugin to the list.
4. Click **Install**.  The `.so` is downloaded to
   `~/.config/Schemify/<id>/lib<id>.so`.
5. Open **Plugins → Reload All Plugins** (or press **F6**).  Your plugin panel
   is now available.

---

## 6 — SDK dependency

To depend on the Schemify SDK from an external repo, add it to your
`build.zig.zon`:

```zon
.dependencies = .{
    .schemify_sdk = .{
        .url  = "https://github.com/UWASIC/Schemify/archive/<commit>.tar.gz",
        .hash = "<zig fetch hash>",
    },
},
```

Then in `build.zig`:

```zig
const sdk    = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;
const ctx    = helper.setup(b, b.dependency("schemify_sdk", .{}));
```

---

## 7 — Publishing to the official registry

To have your plugin listed by default in every user's Marketplace (without
requiring them to paste a URL), open a pull request against
[`plugins/registry.json`](../../plugins/registry.json) with your entry appended
to the `plugins` array.  The maintainers will review and merge it.
