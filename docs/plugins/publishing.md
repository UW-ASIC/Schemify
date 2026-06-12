# Publishing a Plugin

## 1. Package your plugin

Build a release binary for each target platform:

```bash
cargo build --release --target x86_64-unknown-linux-gnu
cargo build --release --target aarch64-apple-darwin
cargo build --release --target x86_64-pc-windows-msvc
```

Create a tarball per platform:

```
my-plugin/
  plugin.toml
  bin/
    my-plugin          # the compiled binary
  LICENSE
```

Make sure `plugin.toml` has `entry = "bin/my-plugin"` (not `cargo run`).

```bash
tar czf my-plugin-0.1.0-x86_64-unknown-linux-gnu.tar.gz my-plugin/
```

Naming convention: `{id}-{version}-{target-triple}.tar.gz`

## 2. Host your tarballs

Create a GitHub repo for your plugin and upload tarballs as release assets.

```bash
gh release create v0.1.0 \
  my-plugin-0.1.0-x86_64-unknown-linux-gnu.tar.gz \
  my-plugin-0.1.0-aarch64-apple-darwin.tar.gz \
  my-plugin-0.1.0-x86_64-pc-windows-msvc.tar.gz
```

## 3. Submit to the registry

The Schemify plugin registry lives in the main repo at
[`registry/index.json`](https://github.com/UW-ASIC/Schemify/blob/master/registry/index.json)
(first-party tarballs are packaged by `scripts/package-plugins.sh` and hosted
as release assets on the same repo).

Fork the repo and add your plugin to `registry/index.json`:

```json
{
  "id": "my-plugin",
  "name": "My Plugin",
  "version": "0.1.0",
  "description": "What it does",
  "author": "yourname",
  "license": "MIT",
  "capabilities": ["panels", "commands"],
  "homepage": "https://github.com/yourname/my-plugin",
  "downloads": {
    "x86_64-unknown-linux-gnu": {
      "url": "https://github.com/yourname/my-plugin/releases/download/v0.1.0/my-plugin-0.1.0-x86_64-unknown-linux-gnu.tar.gz",
      "sha256": "..."
    },
    "aarch64-apple-darwin": {
      "url": "...",
      "sha256": "..."
    },
    "x86_64-pc-windows-msvc": {
      "url": "...",
      "sha256": "..."
    }
  }
}
```

Get the SHA-256 of each tarball:

```bash
sha256sum my-plugin-0.1.0-x86_64-unknown-linux-gnu.tar.gz
```

Open a pull request. Once merged, your plugin appears in the Schemify marketplace.

## 4. Update your plugin

1. Build new tarballs, upload a new GitHub release
2. Update `version` and `downloads` in `index.json`
3. Open a PR to the registry

## Local install (no registry)

Users can install plugins directly from a tarball:

```
schemify marketplace install-local /path/to/my-plugin-0.1.0-x86_64-unknown-linux-gnu.tar.gz
```

Or manually extract into `~/.local/share/schemify/plugins/my-plugin/`.
