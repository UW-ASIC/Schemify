# Publish Your Circuit to GitHub Pages

Every Schemify project can be deployed as a live, interactive web viewer with one workflow file.
Visitors get a full read-only schematic editor in their browser — no install required.

---

## Quick Start (2 steps)

### 1 — Enable GitHub Pages

In your circuit repo: **Settings → Pages → Source → GitHub Actions**

### 2 — Add the workflow

Create `.github/workflows/schemify-pages.yml` in your repo:

```yaml
name: View on Schemify

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

jobs:
  deploy:
    uses: UWASIC/Schemify/.github/workflows/deploy-pages.yml@main
    permissions:
      pages: write
      id-token: write
    with:
      project_dir: '.'        # directory containing Config.toml
      schemify_version: 'latest'
```

Push to `main`. The workflow posts the live URL to the **Actions summary** when it completes.

> Copy the full template from [`scripts/templates/schemify-pages.yml`](https://github.com/UWASIC/Schemify/blob/main/scripts/templates/schemify-pages.yml).

---

## What gets deployed

The workflow reads your `Config.toml` and bundles:

| File type | Included |
|-----------|----------|
| `.chn` schematics | ✓ |
| `.chn_tb` testbenches | ✓ |
| `.sch` / `.sym` (xschem) | ✓ |
| `.cir` / `.spice` models | ✓ |
| `Config.toml` | ✓ |
| Simulation output / generated files | ✗ |

---

## Options

### Schematics in a subdirectory

```yaml
    with:
      project_dir: 'hardware'   # reads hardware/Config.toml
```

### Pin a specific Schemify version

```yaml
    with:
      schemify_version: 'v0.3.0'
```

### Embed alongside a VitePress / MkDocs site

Build your docs site first, then pass the built output directory as `embed_in`.
The Schemify viewer lands at `<your-site>/schematic/`.

```yaml
jobs:
  build-docs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm ci && npm run docs:build    # or mkdocs build, etc.
      - uses: actions/upload-artifact@v4
        with:
          name: docs
          path: docs/.vitepress/dist

  deploy:
    needs: build-docs
    uses: UWASIC/Schemify/.github/workflows/deploy-pages.yml@main
    permissions:
      pages: write
      id-token: write
    with:
      embed_in: docs/.vitepress/dist
```

---

## How it works

```
push to main
    │
    ▼
Checkout your repo
    │
    ▼
Download schemify.wasm + web.js  (from latest Schemify release)
    │
    ▼
build-viewer.mjs
  ├─ reads Config.toml  →  project name, file list
  ├─ copies .chn / .sch / .sym / Config.toml → schemify-out/
  ├─ writes files.json  (file manifest)
  └─ generates index.html (VFS loader + WASM shell)
    │
    ▼
Deploy schemify-out/  →  github-pages environment
    │
    ▼
https://<user>.github.io/<repo>/   ← posted to workflow summary
```

The viewer uses an **in-memory VFS**: on load it fetches every project file listed in `files.json` and populates a JavaScript `Map` that the WASM runtime reads through the `host.vfs_*` imports defined in `Vfs.zig`.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Workflow fails: `gh release download: no assets` | Schemify hasn't cut a WASM release yet — pin `schemify_version: main` to build from source |
| Blank page / console errors about `web.js` | Check that `project_dir` points to the directory containing `Config.toml`, not a parent |
| Files not loading in viewer | Filenames are case-sensitive on Linux — check `Config.toml` paths match exactly |
| Pages shows old content | GitHub Pages CDN caches aggressively — hard-refresh with `Ctrl+Shift+R` |
