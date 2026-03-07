# Hosting on GitHub Pages

Schemify ships a reusable GitHub Actions workflow that builds a browser-based
viewer from your schematic files and deploys it to GitHub Pages — no Zig
toolchain required on your side.

The viewer runs the full Schemify editor compiled to WebAssembly. Visitors can
pan, zoom, and edit the schematic. Saves trigger a browser download of the
updated file.

## Quick start

**1.** Add a `config.toml` alongside your schematics (see [Config.toml](/guide/config)):

```toml
name = "My Inverter"
pdk  = "sky130"

[paths]
chn = ["top.chn"]
```

**2.** Enable GitHub Pages for your repo:
- Go to **Settings → Pages**
- Set **Source** to **GitHub Actions**

**3.** Create `.github/workflows/schemify-pages.yml`:

```yaml
name: Schemify Viewer

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    uses: UWASIC/Schemify/.github/workflows/deploy-pages.yml@main
    permissions:
      pages: write
      id-token: write
```

Push to `main` and your viewer will be live at  
`https://<your-username>.github.io/<your-repo>/`.

---

## Configuration

The reusable workflow accepts several optional inputs:

| Input | Default | Description |
|---|---|---|
| `project_dir` | `.` | Directory containing `config.toml` and schematics — bundled as-is |
| `schemify_version` | `latest` | Schemify release tag to use (e.g. `v0.2.0`) |
| `embed_in` | _(empty)_ | Embed the viewer into an existing built site (see below) |

Example with schematics in a subdirectory and a pinned version:

```yaml
jobs:
  deploy:
    uses: UWASIC/Schemify/.github/workflows/deploy-pages.yml@main
    permissions:
      pages: write
      id-token: write
    with:
      project_dir: hardware
      schemify_version: v0.2.0
```

---

## Embedding as a tab in an existing site

If you already deploy a VitePress (or any static-site) to GitHub Pages, you can
add the Schemify viewer as a sub-path (e.g. `/schematic/`) rather than replacing
your existing site.

### VitePress example

```yaml
name: Docs + Schematic Viewer

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      pages: write
      id-token: write

    steps:
      - uses: actions/checkout@v4

      # Build your VitePress docs first
      - uses: oven-sh/setup-bun@v2
      - run: bun install
        working-directory: docs
      - run: bun run build
        working-directory: docs
      # docs/.vitepress/dist/ now contains the built site

    # Hand off to the Schemify reusable workflow (embed mode)
  embed:
    needs: deploy          # wait for the VitePress build step above
    uses: UWASIC/Schemify/.github/workflows/deploy-pages.yml@main
    permissions:
      pages: write
      id-token: write
    with:
      embed_in: docs/.vitepress/dist
```

::: tip Add a nav link
In `docs/.vitepress/config.mts`, add a nav entry to link to the viewer:
```ts
nav: [
  // ... your existing entries ...
  { text: 'Schematic', link: '/schematic/' },
],
```
:::

The viewer is placed at `<embed_in>/schematic/index.html` and is accessible
at `https://<your-org>.github.io/<repo>/schematic/`.

---

## How it works

Each Schemify [release](https://github.com/UWASIC/Schemify/releases) includes
two pre-built assets:

| File | Description |
|---|---|
| `schemify.wasm` | Schemify compiled to WebAssembly (no native deps) |
| `web.js` | dvui WebGL/WASM runtime |

The deploy workflow:

1. Downloads those assets from the requested release tag
2. Copies your entire project directory (the one containing `config.toml` and
   schematics) into the output directory
3. Generates a self-contained `index.html` that:
   - Pre-fetches all project files before booting the WASM (required because
     `wasm_read_file` is a synchronous import)
   - Bridges `wasm_read_file` / `wasm_write_file` calls to `fetch()` / browser downloads
   - The WASM itself reads `config.toml` and resolves all schematic paths
4. Deploys the directory to GitHub Pages via the official `actions/deploy-pages` action

---

## Supported file types

Any file type Schemify can open natively is supported in the viewer:

| Key in `config.toml` | Extension | Description |
|---|---|---|
| `paths.chn` | `.chn` | Native CHN schematics |
| `paths.chn_tb` | `.chn_tb` | Testbench schematics |
| `legacy_paths.schematics` | `.sch` | XSchem schematics |
| `legacy_paths.symbols` | `.sym` | XSchem symbols |

---

## Pinning a specific Schemify version

By default the workflow uses the latest Schemify release. To pin:

```yaml
with:
  schemify_version: v0.1.0
```

This ensures your viewer stays stable even when Schemify releases breaking
changes.

---

## Saving changes

The WASM viewer runs in a read-only static host, so saves cannot write back to
your repository. When a user clicks **Save** in the editor, the browser
downloads the updated file. They can then commit and push it manually to
re-trigger the viewer deployment.

A future version will optionally open a GitHub PR with the saved changes via
the GitHub API.
