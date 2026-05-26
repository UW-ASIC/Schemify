#!/usr/bin/env bash
# generate.sh — Import all PySpice examples into .chn files in examples/
#
# Usage:
#   cd examples/pyspice && bash generate.sh
#
# Requires: schemify binary in PATH (or ../../zig-out/bin/schemify)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXAMPLES_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$EXAMPLES_DIR")"

# Find schemify binary
SCHEMIFY="${SCHEMIFY:-}"
if [ -z "$SCHEMIFY" ]; then
    if command -v schemify &>/dev/null; then
        SCHEMIFY="schemify"
    elif [ -x "$PROJECT_ROOT/zig-out/bin/Schemify" ]; then
        SCHEMIFY="$PROJECT_ROOT/zig-out/bin/Schemify"
    else
        echo "error: schemify binary not found."
        echo "  Build with: cd $PROJECT_ROOT && zig build"
        echo "  Or set SCHEMIFY=/path/to/schemify"
        exit 1
    fi
fi

echo "Using schemify: $SCHEMIFY"
echo "Output directory: $EXAMPLES_DIR"
echo ""

imported=0
failed=0

import_file() {
    local py_file="$1"
    local kind="${2:-}"
    local rel_path="${py_file#$SCRIPT_DIR/}"
    local base_name="$(basename "$py_file" .py)"

    [[ "$base_name" == __* ]] && return

    printf "  %-50s " "$rel_path"

    local args=("--import" "-o" "$EXAMPLES_DIR" "$py_file")
    if [ -n "$kind" ]; then
        args+=("$kind")
    fi

    output=$("$SCHEMIFY" "${args[@]}" 2>&1) || true

    if echo "$output" | grep -q "^imported:"; then
        echo "OK"
        ((imported++)) || true
    else
        echo "FAIL"
        local err=$(echo "$output" | grep "error:" | head -1)
        [ -n "$err" ] && echo "    $err"
        ((failed++)) || true
    fi
}

# PDK primitives (import as primitive → .chn_prim)
echo "=== PDK Primitives ==="
if [ -d "$SCRIPT_DIR/pdk" ]; then
    for py_file in "$SCRIPT_DIR/pdk"/*_primitives.py; do
        [ -f "$py_file" ] || continue
        import_file "$py_file" "primitive"
    done
fi

# PDK circuits (import as component → .chn, references primitives above)
echo ""
echo "=== PDK Circuits ==="
if [ -d "$SCRIPT_DIR/pdk" ]; then
    for py_file in "$SCRIPT_DIR/pdk"/*.py; do
        [ -f "$py_file" ] || continue
        [[ "$(basename "$py_file")" == *_primitives.py ]] && continue
        import_file "$py_file" "component"
    done
fi

# Components
echo ""
echo "=== Components ==="
for dir in basic mosfet bjt opamp digital power mixed_signal bus; do
    if [ -d "$SCRIPT_DIR/$dir" ]; then
        echo "--- $dir ---"
        for py_file in "$SCRIPT_DIR/$dir"/*.py; do
            [ -f "$py_file" ] || continue
            import_file "$py_file" "component"
        done
    fi
done

# Testbenches
echo ""
echo "=== Testbenches ==="
if [ -d "$SCRIPT_DIR/testbench" ]; then
    for py_file in "$SCRIPT_DIR/testbench"/*.py; do
        [ -f "$py_file" ] || continue
        import_file "$py_file" "testbench"
    done
fi

# Summary
echo ""
echo "=== Summary ==="
echo "  Imported: $imported"
echo "  Failed:   $failed"

if [ "$failed" -gt 0 ]; then
    echo ""
    echo "Some imports failed."
    exit 1
fi

echo ""
echo "Done! .chn files in $EXAMPLES_DIR/"
