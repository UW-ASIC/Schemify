#!/usr/bin/env bash
# Package the first-party plugins (plugins/) into marketplace tarballs.
#
# Per docs/plugins/publishing.md: each tarball holds
#   <id>/plugin.toml   (entry rewritten to bin/<id>)
#   <id>/bin/<id>      (release binary; .exe on windows)
# gmid-lut additionally ships its vendored gmid_runner at the path
# runner.rs probes relative to the plugin dir (the host's cwd contract).
# Off-linux the runner is best-effort: if build.rs found no C++ compiler
# the plugin still works via $GMID_RUNNER.
#
# Build the binaries first:
#   cargo build --release --manifest-path plugins/<id>/Cargo.toml
#
# Usage: [TARGET=<triple>] [VERSION=x.y.z] scripts/package-plugins.sh [out_dir]
#   TARGET  defaults to x86_64-unknown-linux-gnu
#   out_dir defaults to dist/plugins
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
TARGET="${TARGET:-x86_64-unknown-linux-gnu}"
OUT="${1:-dist/plugins}"
PLUGINS=(theme-registry pdk-switcher gmid-lut pdk-mapper)

EXE=""
case "$TARGET" in *windows*) EXE=".exe" ;; esac

rm -rf "$OUT"
mkdir -p "$OUT"

for id in "${PLUGINS[@]}"; do
    bin="plugins/$id/target/release/$id$EXE"
    [ -f "$bin" ] || { echo "missing $bin — build it first" >&2; exit 1; }

    stage="$OUT/$id"
    mkdir -p "$stage/bin"
    cp "$bin" "$stage/bin/$id$EXE"
    sed "s|^entry = .*|entry = \"bin/$id$EXE\"|" "plugins/$id/plugin.toml" \
        > "$stage/plugin.toml"

    if [ "$id" = gmid-lut ]; then
        runner=$(ls -t plugins/gmid-lut/target/release/build/*/out/gmid_runner$EXE \
            2>/dev/null | head -1 || true)
        if [ -n "$runner" ]; then
            mkdir -p "$stage/GmIDVisualizer/build"
            cp "$runner" "$stage/GmIDVisualizer/build/gmid_runner$EXE"
            chmod +x "$stage/GmIDVisualizer/build/gmid_runner$EXE"
        elif [ "$TARGET" = x86_64-unknown-linux-gnu ]; then
            echo "gmid_runner not built" >&2; exit 1
        else
            echo "warning: gmid_runner not built for $TARGET — plugin falls back to \$GMID_RUNNER" >&2
        fi
    fi

    tarball="$OUT/$id-$VERSION-$TARGET.tar.gz"
    tar czf "$tarball" -C "$OUT" "$id"
    rm -rf "$stage"
done

# SHA256SUMS-<target>.txt: macos has shasum, linux/git-bash have sha256sum.
cd "$OUT"
if command -v sha256sum >/dev/null; then
    sha256sum -- *.tar.gz | tee "SHA256SUMS-$TARGET.txt"
else
    shasum -a 256 -- *.tar.gz | tee "SHA256SUMS-$TARGET.txt"
fi
