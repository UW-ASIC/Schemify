#!/usr/bin/env python3
"""Plugin registry generator.

Scans every subdirectory of plugins/ that contains both plugin.toml and
build.zig, then emits a registry descriptor.

Usage
-----
  # Regenerate plugins/registry.json in-place
  python3 tools/scripts/gen_registry.py

  # Print a JSON array of buildable plugins (for GitHub Actions matrix)
  python3 tools/scripts/gen_registry.py --list-buildable

  # Override the release tag used for download URLs
  python3 tools/scripts/gen_registry.py --release-tag plugins-latest

Environment variables (override CLI flags)
-------------------------------------------
  REGISTRY_REPO          GitHub repo  e.g. "UWASIC/Schemify"
  REGISTRY_BRANCH        branch       e.g. "main"
  REGISTRY_RELEASE_TAG   release tag  e.g. "plugins-latest"
"""

from __future__ import annotations
import argparse, json, os, sys, textwrap
from pathlib import Path

try:
    import tomllib          # Python 3.11+
except ModuleNotFoundError:
    try:
        import tomli as tomllib  # pip install tomli
    except ModuleNotFoundError:
        sys.exit("error: tomllib not found – run 'pip install tomli' or use Python 3.11+")

# ── Defaults ──────────────────────────────────────────────────────────────────

REPO_ROOT    = Path(__file__).resolve().parent.parent.parent
PLUGINS_DIR  = REPO_ROOT / "plugins"
REGISTRY_OUT = PLUGINS_DIR / "registry.json"

DEFAULT_REPO        = "UWASIC/Schemify"
DEFAULT_BRANCH      = "main"
DEFAULT_RELEASE_TAG = "plugins-latest"

# ── Helpers ───────────────────────────────────────────────────────────────────

def repo_raw_url(repo: str, branch: str, rel_path: str) -> str:
    encoded = rel_path.replace(" ", "%20")
    return f"https://raw.githubusercontent.com/{repo}/{branch}/{encoded}"


def release_download_url(repo: str, tag: str, filename: str) -> str:
    return f"https://github.com/{repo}/releases/download/{tag}/{filename}"


def first_paragraph_of_readme(readme: Path, max_len: int = 260) -> str:
    """Return the first non-blank, non-heading paragraph of a README."""
    text: list[str] = []
    in_code = False
    for raw_line in readme.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if line.startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            continue
        if line.startswith("#") or line.startswith("---"):
            if text:
                break
            continue
        if not line:
            if text:
                break
            continue
        text.append(line)
        if len(" ".join(text)) >= max_len:
            break
    result = " ".join(text)
    return (result[:max_len] + "…") if len(result) > max_len else result


# ── Discovery ─────────────────────────────────────────────────────────────────

def discover_plugins(
    repo: str,
    branch: str,
    release_tag: str,
    require_build_zig: bool = True,
) -> list[dict]:
    """Return one dict per discoverable plugin, sorted by name."""
    plugins: list[dict] = []

    for plugin_dir in sorted(PLUGINS_DIR.iterdir()):
        if not plugin_dir.is_dir():
            continue

        toml_path = plugin_dir / "plugin.toml"
        build_zig = plugin_dir / "build.zig"

        if not toml_path.exists():
            continue
        if require_build_zig and not build_zig.exists():
            continue

        with open(toml_path, "rb") as fh:
            raw = tomllib.load(fh)

        p = raw.get("plugin", {})
        b = raw.get("build", {})

        plugin_id  = p.get("name", plugin_dir.name).replace(" ", "")
        display    = plugin_dir.name              # human-friendly directory name
        entry_so   = p.get("entry", f"lib{plugin_id}.so")
        entry_base = Path(entry_so).stem          # e.g. "libMyPlugin"
        if entry_base.startswith("lib"):
            entry_base = entry_base[3:]           # → "MyPlugin"
        rel_dir    = plugin_dir.relative_to(REPO_ROOT).as_posix()

        # Description: toml > README > empty
        description = p.get("description", "")
        if not description:
            readme = plugin_dir / "README.md"
            if readme.exists():
                description = first_paragraph_of_readme(readme)

        plugins.append({
            # Registry fields
            "id":          plugin_id,
            "name":        display,
            "author":      p.get("author", "UWASIC"),
            "version":     p.get("version", "0.1.0"),
            "description": description,
            "tags":        p.get("tags", []),
            "repo":        f"https://github.com/{repo}",
            "readme_url":  repo_raw_url(repo, branch, f"{rel_dir}/README.md"),
            "download": {
                "linux": release_download_url(repo, release_tag, entry_base + ".so"),
                "macos": release_download_url(repo, release_tag, entry_base + ".dylib"),
                "wasm":  release_download_url(repo, release_tag, entry_base + ".wasm"),
            },
            # Build metadata (used by workflow, not stored in registry.json)
            "_dir":       str(plugin_dir.relative_to(REPO_ROOT)),
            "_entry":     entry_base,
            "_apt_deps":  b.get("apt_deps", []),
            "_has_build": build_zig.exists(),
        })

    return plugins


# ── Modes ─────────────────────────────────────────────────────────────────────

def mode_registry(plugins: list[dict], output_path: Path) -> None:
    """Write registry.json, stripping build-only private fields."""
    registry_plugins = [
        {k: v for k, v in p.items() if not k.startswith("_")}
        for p in plugins
    ]
    registry = {"version": 1, "plugins": registry_plugins}
    output_path.write_text(json.dumps(registry, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {output_path} ({len(registry_plugins)} plugin(s))", file=sys.stderr)


def mode_list_buildable(plugins: list[dict]) -> None:
    """Print a JSON array suitable for a GitHub Actions matrix."""
    buildable = [
        {
            "id":       p["id"],
            "dir":      p["_dir"],
            "entry":    p["_entry"],
            "apt_deps": p["_apt_deps"],
        }
        for p in plugins
        if p.get("_has_build")
    ]
    print(json.dumps(buildable))


# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(
        description=textwrap.dedent(__doc__ or ""),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--list-buildable", action="store_true",
                    help="Print JSON matrix array instead of updating registry.json")
    ap.add_argument("--repo",        default=os.getenv("REGISTRY_REPO",        DEFAULT_REPO))
    ap.add_argument("--branch",      default=os.getenv("REGISTRY_BRANCH",      DEFAULT_BRANCH))
    ap.add_argument("--release-tag", default=os.getenv("REGISTRY_RELEASE_TAG", DEFAULT_RELEASE_TAG))
    ap.add_argument("--output",      default=str(REGISTRY_OUT),
                    help="Output path for registry.json (default mode only)")
    args = ap.parse_args()

    plugins = discover_plugins(args.repo, args.branch, args.release_tag)

    if args.list_buildable:
        mode_list_buildable(plugins)
    else:
        mode_registry(plugins, Path(args.output))


if __name__ == "__main__":
    main()
