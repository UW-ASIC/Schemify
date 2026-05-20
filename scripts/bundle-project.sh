#!/usr/bin/env bash
# bundle-project.sh — Read a Schemify project directory and emit project.json
#
# Usage: ./scripts/bundle-project.sh /path/to/project > dist/project.json
#
# Reads Config.toml, discovers .chn/.chn_tb/.chn_prim files,
# and bundles everything into a single JSON file for the WASM viewer.

set -euo pipefail

PROJECT_DIR="${1:-.}"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: '$PROJECT_DIR' is not a directory" >&2
    exit 1
fi

CONFIG_FILE="$PROJECT_DIR/Config.toml"

# ── Parse Config.toml (minimal) ──────────────────────────────────────────────

PROJECT_NAME=""
PROJECT_PDK=""
PLUGINS_ENABLED=""

if [ -f "$CONFIG_FILE" ]; then
    while IFS= read -r line; do
        # Strip comments and whitespace
        line="${line%%#*}"
        line="$(echo "$line" | xargs 2>/dev/null || true)"
        [ -z "$line" ] && continue

        case "$line" in
            name\ =\ *)
                PROJECT_NAME="$(echo "$line" | sed 's/^name *= *"\{0,1\}//;s/"\{0,1\}$//')"
                ;;
            pdk\ =\ *)
                PROJECT_PDK="$(echo "$line" | sed 's/^pdk *= *"\{0,1\}//;s/"\{0,1\}$//')"
                ;;
        esac
    done < "$CONFIG_FILE"
fi

[ -z "$PROJECT_NAME" ] && PROJECT_NAME="$(basename "$PROJECT_DIR")"

# ── Discover schematic files ─────────────────────────────────────────────────

declare -a FILES=()

find_files() {
    local dir="$1"
    local ext="$2"
    if [ -d "$dir" ]; then
        while IFS= read -r -d '' f; do
            FILES+=("$f")
        done < <(find "$dir" -name "*$ext" -type f -print0 2>/dev/null || true)
    fi
}

# Look for .chn, .chn_tb, .chn_prim in the project directory (recursive)
find_files "$PROJECT_DIR" ".chn"
find_files "$PROJECT_DIR" ".chn_tb"
find_files "$PROJECT_DIR" ".chn_prim"

# ── Discover plugins ─────────────────────────────────────────────────────────

declare -a PLUGINS=()
if [ -d "$PROJECT_DIR/plugins" ]; then
    for pdir in "$PROJECT_DIR/plugins"/*/; do
        [ -f "${pdir}plugin.toml" ] && PLUGINS+=("$(basename "$pdir")")
    done
fi

# ── Emit JSON ────────────────────────────────────────────────────────────────

emit_json_string() {
    # Escape backslash, double quote, newlines, tabs for JSON
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()), end="")'
}

echo "{"
echo "  \"name\": $(emit_json_string "$PROJECT_NAME"),"

if [ -n "$PROJECT_PDK" ]; then
    echo "  \"pdk\": $(emit_json_string "$PROJECT_PDK"),"
else
    echo "  \"pdk\": null,"
fi

# Plugins array
echo -n "  \"plugins\": ["
first=true
for p in "${PLUGINS[@]+"${PLUGINS[@]}"}"; do
    $first || echo -n ","
    echo -n " $(emit_json_string "$p")"
    first=false
done
echo " ],"

# Files object
echo "  \"files\": {"
first=true
for f in "${FILES[@]+"${FILES[@]}"}"; do
    # Relative path from project dir
    rel="${f#"$PROJECT_DIR"/}"
    content="$(cat "$f")"
    $first || echo ","
    echo -n "    $(emit_json_string "$rel"): $(emit_json_string "$content")"
    first=false
done
echo ""
echo "  }"
echo "}"
