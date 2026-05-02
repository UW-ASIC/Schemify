"""Command-line interface for Spice2Schematic."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from spice2schematic.converter import import_spice


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="spice2schematic",
        description="Convert ngspice netlists to schematic representations.",
    )
    parser.add_argument("input", help="Input SPICE netlist file (.sp/.cir/.net/.spice)")
    parser.add_argument(
        "-o",
        "--output-dir",
        default=".",
        help="Output directory for JSON files (default: current directory)",
    )
    parser.add_argument(
        "--flatten",
        action="store_true",
        help="Flatten subcircuit hierarchy",
    )
    parser.add_argument(
        "--stdout",
        action="store_true",
        help="Print JSON to stdout instead of writing files",
    )

    args = parser.parse_args()
    input_path = Path(args.input)

    if not input_path.exists():
        print(f"Error: {input_path} not found", file=sys.stderr)
        sys.exit(1)

    source = input_path.read_text()
    outputs = import_spice(source, str(input_path))

    if not outputs:
        print("No outputs generated.", file=sys.stderr)
        sys.exit(1)

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    for out in outputs:
        if args.stdout:
            print(out.to_json())
        else:
            path = out.write_json(output_dir)
            print(f"Wrote {path} ({path.stat().st_size} bytes)")

    print(f"\n{len(outputs)} output(s) generated.")


if __name__ == "__main__":
    main()
