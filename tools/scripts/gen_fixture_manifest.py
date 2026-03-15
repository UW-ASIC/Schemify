#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    examples_dir = repo_root / "test" / "examples"
    manifest_path = repo_root / "test" / "core" / "fixture_manifest.zig"

    pairs: list[tuple[str, str]] = []
    for sch in sorted(examples_dir.rglob("*.sch")):
        sym = sch.with_suffix(".sym")
        if not sym.is_file():
            continue
        sch_rel = sch.relative_to(repo_root).as_posix()
        sym_rel = sym.relative_to(repo_root).as_posix()
        pairs.append((sch_rel, sym_rel))

    lines: list[str] = [
        "pub const Case = struct {",
        "    sch_path: []const u8,",
        "    sym_path: []const u8,",
        "};",
        "",
        "pub const cases = [_]Case{",
    ]
    for sch_rel, sym_rel in pairs:
        lines.append(
            f'    .{{ .sch_path = "{sch_rel}", .sym_path = "{sym_rel}" }},'
        )
    lines.append("};")
    lines.append("")

    manifest_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {len(pairs)} fixture pairs to {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
