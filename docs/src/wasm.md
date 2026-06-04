# WASM / Web Build

Schemify compiles to WebAssembly, so it runs in the browser with no installation needed.

## Live Demo

<iframe
  src="../demo/"
  style="width: 100%; height: 600px; border: 1px solid #444; border-radius: 4px;"
  allow="clipboard-read; clipboard-write"
  loading="lazy"
  title="Schemify WASM Demo">
</iframe>

<noscript>The live demo requires JavaScript. <a href="https://uw-asic.github.io/Schemify/demo/">Open Schemify in a new tab</a>.</noscript>

> **Tip:** [Open in full screen](https://uw-asic.github.io/Schemify/demo/) for the best experience.

## Building for the Web

### Prerequisites

```sh
# Install trunk (the WASM build tool for Rust)
cargo install trunk

# Install wasm-bindgen-cli
cargo install wasm-bindgen-cli

# Add the WASM target
rustup target add wasm32-unknown-unknown
```

Or with Nix:
```sh
nix develop   # trunk, wasm-bindgen-cli, and binaryen are included
```

### Build & Serve

```sh
trunk serve
```

This compiles the project to WASM, bundles it with the HTML template in `web/index.html`, and starts a local dev server. Open `http://localhost:8080` in your browser.

### Production Build

```sh
trunk build --release
```

The output goes to `dist/`. Deploy the contents to any static file host.

## Limitations

The WASM build has a few differences from native:

| Feature | Native | WASM |
|---|---|---|
| File dialogs | System native (rfd) | Browser file picker |
| Subprocess plugins | Yes | No (use WASM plugins) |
| WASM plugins | Optional feature | Not supported (no nested WASM) |
| Simulation | Full (spawns Python) | Not available |
| Clipboard | System clipboard | Browser clipboard API |
| Performance | Full native speed | ~70-80% of native |

The WASM build is best suited for viewing and editing schematics. For simulation, use the native build.

## Hosting

The WASM build is a static site -- just HTML, JS, and `.wasm` files. Host it on:

- GitHub Pages
- Netlify / Vercel
- Any static file server

Make sure the server serves `.wasm` files with the `application/wasm` MIME type.
