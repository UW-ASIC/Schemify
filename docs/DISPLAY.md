# Schemify Web Display

Deploy an interactive, read-only schematic viewer for your Schemify project to GitHub Pages. The viewer runs entirely in the browser via WebAssembly — no backend required.

## Quick Start

### 1. Enable GitHub Pages

In your repo: **Settings > Pages > Source** → set to **GitHub Actions**.

### 2. Add the workflow

Create `.github/workflows/display.yml` in your repo:

```yaml
name: Deploy Schematic Viewer

on:
  push:
    branches: [main]

permissions:
  contents: read
  pages: write
  id-token: write

jobs:
  deploy:
    uses: OmarSiwy/SchemifyRS/.github/workflows/deploy-web.yml@main
```

That's it. Push to `main` and your schematics are live on GitHub Pages.

### 3. (Optional) Pin a specific SchemifyRS version

```yaml
jobs:
  deploy:
    uses: OmarSiwy/SchemifyRS/.github/workflows/deploy-web.yml@main
    with:
      schemify_ref: "v0.2.0" # tag, branch, or commit SHA
```

## Project Structure

The workflow reads your project's `Config.toml` and bundles all schematic files it finds. A typical Schemify project looks like:

```
my-project/
  Config.toml
  schematics/
    inverter.chn
    nand2.chn
    top.chn
  primitives/
    nmos4.chn_prim
    pmos4.chn_prim
  testbenches/
    tb_inverter.chn_tb
  plugins/
    my-plugin/
      plugin.toml
```

### Config.toml

```toml
name = "my-project"
pdk = "sky130"

[paths]
chn = ["schematics/*"]
chn_prim = ["primitives/*"]
chn_tb = ["testbenches/*"]

[plugins]
enabled = ["my-plugin"]
```

If `Config.toml` is missing, the workflow still works — it discovers `.chn`, `.chn_tb`, and `.chn_prim` files recursively from the repo root.

## Nested Projects

If your schematics live in a subdirectory:

```yaml
jobs:
  deploy:
    uses: OmarSiwy/SchemifyRS/.github/workflows/deploy-web.yml@main
    with:
      project_path: "designs/amplifier"
```

## What the Viewer Can Do

- Browse all schematics in your project (left sidebar)
- Switch between schematic, symbol, and documentation views
- Zoom, pan, and inspect components
- Run simulations (F5)
- View component properties

## What the Viewer Cannot Do

The web viewer is **read-only**:

- No creating or editing schematics
- No saving files
- No file dialogs (Open, Save, Save As are disabled)
- No native plugin execution (subprocess/native plugins are skipped)

## How It Works

1. The workflow builds SchemifyRS's display crate as a WebAssembly module
2. `bundle-project.sh` reads your `Config.toml`, collects all schematic files, and packs them into a `project.json`
3. On page load, the WASM app fetches `project.json` and opens all schematics into the viewer
4. Everything runs client-side — no server needed after deployment

### Bundle Format

The generated `project.json` contains:

```json
{
  "name": "my-project",
  "pdk": "sky130",
  "plugins": ["my-plugin"],
  "files": {
    "schematics/inverter.chn": "chn 1\n  instances:\n    ...",
    "schematics/nand2.chn": "..."
  }
}
```

## Local Preview

To test the viewer locally before deploying:

```bash
# From the SchemifyRS repo
cargo build -p schemify-display --lib --target wasm32-unknown-unknown --release
wasm-bindgen --target web --out-dir dist --no-typescript \
  target/wasm32-unknown-unknown/release/schemify_display.wasm

cp web/index.html dist/
./scripts/bundle-project.sh /path/to/your/project > dist/project.json

# Serve (any static file server works)
python3 -m http.server -d dist 8080
```

Then open `http://localhost:8080`.

## Requirements

Your repo needs:

- At least one `.chn` file (or the viewer shows the welcome screen)
- GitHub Pages enabled with Actions as the source
- The workflow file described above

No Rust toolchain, no WASM tools, no build dependencies in your repo. The reusable workflow handles everything.
