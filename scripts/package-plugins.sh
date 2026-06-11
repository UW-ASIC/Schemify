#!/usr/bin/env bash
# Package the first-party plugins (plugins/) into marketplace tarballs.
#
# Per docs/plugins/publishing.md: each tarball holds
#   <id>/plugin.toml   (entry rewritten to bin/<id>)
#   <id>/bin/<id>      (release binary)
# gmid-lut additionally ships its vendored gmid_runner at the path
# runner.rs probes relative to the plugin dir (the host's cwd contract).
#
# Build the binaries first:
#   nix develop -c cargo build --release --manifest-path plugins/<id>/Cargo.toml
#
# Usage: scripts/package-plugins.sh [out_dir]   (default: dist/plugins)
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION=0.1.0
TARGET=x86_64-unknown-linux-gnu
OUT="${1:-dist/plugins}"
PLUGINS=(theme-registry pdk-switcher gmid-lut pdk-mapper)

rm -rf "$OUT"
mkdir -p "$OUT"

for id in "${PLUGINS[@]}"; do
    bin="plugins/$id/target/release/$id"
    [ -f "$bin" ] || { echo "missing $bin — build it first" >&2; exit 1; }

    stage="$OUT/$id"
    mkdir -p "$stage/bin"
    cp "$bin" "$stage/bin/$id"
    sed "s|^entry = .*|entry = \"bin/$id\"|" "plugins/$id/plugin.toml" \
        > "$stage/plugin.toml"

    if [ "$id" = gmid-lut ]; then
        runner=$(ls -t plugins/gmid-lut/target/release/build/*/out/gmid_runner \
            2>/dev/null | head -1)
        [ -n "$runner" ] || { echo "gmid_runner not built" >&2; exit 1; }
        mkdir -p "$stage/GmIDVisualizer/build"
        cp "$runner" "$stage/GmIDVisualizer/build/gmid_runner"
        chmod +x "$stage/GmIDVisualizer/build/gmid_runner"
    fi

    tarball="$OUT/$id-$VERSION-$TARGET.tar.gz"
    tar czf "$tarball" -C "$OUT" "$id"
    rm -rf "$stage"
    sha=$(sha256sum "$tarball" | cut -d' ' -f1)
    echo "$id  $sha"
done
