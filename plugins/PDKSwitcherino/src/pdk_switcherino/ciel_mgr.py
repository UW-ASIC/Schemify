"""CIEL PDK manager — fetch, list, and locate installed PDKs.

Replaces the old Volare-based manager. Uses the CIEL CLI
(pip install ciel) to discover, install, and manage open-source PDKs.

PDK root defaults to ~/.ciel, overridable via PDK_ROOT env var.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from .pdk import PDK

# Known CIEL families — matches what CIEL currently supports.
KNOWN_FAMILIES = ("sky130", "gf180mcu", "ihp-sg13g2")

# PDK variant subdirectories within a CIEL family version.
# e.g. ~/.ciel/sky130/versions/<hash>/sky130A/
_FAMILY_VARIANTS: dict[str, list[str]] = {
    "sky130": ["sky130A", "sky130B"],
    "gf180mcu": ["gf180mcuA", "gf180mcuB", "gf180mcuC", "gf180mcuD"],
    "ihp-sg13g2": ["ihp-sg13g2"],
}


def ciel_root() -> Path:
    """Return the CIEL PDK root directory."""
    env = os.environ.get("PDK_ROOT")
    if env:
        return Path(env)
    return Path.home() / ".ciel"


def detect_ciel() -> str | None:
    """Find a working ciel invocation. Returns command string or None."""
    candidates = [
        ["ciel", "--version"],
        ["python3", "-m", "ciel", "--version"],
    ]
    for cmd in candidates:
        try:
            subprocess.run(
                cmd, capture_output=True, text=True, timeout=10, check=True,
            )
            return cmd[0] if len(cmd) == 1 else " ".join(cmd[:2])
        except (FileNotFoundError, subprocess.SubprocessError):
            continue
    return None


def _run_ciel(*args: str, timeout: int = 60) -> subprocess.CompletedProcess[str]:
    """Run a ciel command, trying multiple invocation methods."""
    for base in (["ciel"], ["python3", "-m", "ciel"]):
        try:
            return subprocess.run(
                [*base, *args],
                capture_output=True, text=True, timeout=timeout, check=True,
            )
        except (FileNotFoundError, subprocess.SubprocessError):
            continue
    raise RuntimeError("ciel not found. Install with: pip install ciel")


def list_remote_versions(pdk_family: str) -> list[str]:
    """List available remote versions for a PDK family."""
    result = _run_ciel("ls-remote", "--pdk-family", pdk_family)
    versions = []
    for line in result.stdout.splitlines():
        token = line.strip().split()[0] if line.strip() else ""
        if token and not token.startswith(("-", "=", "Name", "Version")):
            versions.append(token)
    return versions


def list_local_versions(pdk_family: str) -> list[str]:
    """List locally installed versions for a PDK family."""
    try:
        result = _run_ciel("ls", "--pdk-family", pdk_family)
    except RuntimeError:
        return []
    versions = []
    for line in result.stdout.splitlines():
        token = line.strip().split()[0] if line.strip() else ""
        if token and not token.startswith(("-", "=", "Name", "Version")):
            versions.append(token)
    return versions


def enable(pdk_family: str, version: str | None = None) -> None:
    """Enable (download + activate) a PDK version."""
    args = ["enable", "--pdk-family", pdk_family]
    if version:
        args.append(version)
    _run_ciel(*args, timeout=300)


def _find_variant_root(family_dir: Path, family: str) -> Path | None:
    """Find the actual PDK variant directory within a CIEL family install."""
    variants = _FAMILY_VARIANTS.get(family, [family])
    for variant in variants:
        candidate = family_dir / variant
        if candidate.is_dir():
            return candidate
    # Fallback: if family dir itself has libs.tech, use it directly
    if (family_dir / "libs.tech").is_dir():
        return family_dir
    return None


def pdk_root(pdk_name: str) -> Path | None:
    """Get installed PDK root directory for a PDK name (e.g. 'sky130A').

    Searches:
    1. ~/.ciel/<family>/versions/*/  for variant subdirectories
    2. ~/.ciel/<pdk_name>  (direct path, legacy volare compat)
    3. PDK_ROOT/<pdk_name>  (env var override)
    """
    root = ciel_root()

    # Map PDK name back to family
    family = _pdk_name_to_family(pdk_name)

    if family:
        family_dir = root / family
        # Check versions directory for the active/latest version
        versions_dir = family_dir / "versions"
        if versions_dir.is_dir():
            # Look for the most recently modified version
            version_dirs = sorted(
                (d for d in versions_dir.iterdir() if d.is_dir()),
                key=lambda d: d.stat().st_mtime,
                reverse=True,
            )
            for vdir in version_dirs:
                variant = _find_variant_root(vdir, family)
                if variant and variant.name == pdk_name:
                    return variant
                # For ihp-sg13g2, the variant name might differ
                if variant:
                    return variant

        # Check if there's a direct symlink/directory
        if family_dir.is_dir():
            variant = _find_variant_root(family_dir, family)
            if variant:
                return variant

    # Legacy: direct path under root (volare compatibility)
    candidate = root / pdk_name
    if candidate.exists():
        return candidate.resolve()

    # Also check old ~/.volare location for backwards compat
    volare_root = Path.home() / ".volare"
    candidate = volare_root / pdk_name
    if candidate.exists():
        return candidate.resolve()

    return None


def _pdk_name_to_family(pdk_name: str) -> str | None:
    """Map a PDK variant name back to its CIEL family."""
    for family, variants in _FAMILY_VARIANTS.items():
        if pdk_name in variants or pdk_name.startswith(family.replace("-", "")):
            return family
    # Direct match
    if pdk_name in KNOWN_FAMILIES:
        return pdk_name
    return None


def auto_root(pdk: PDK) -> PDK:
    """Return a copy of the PDK with root auto-detected from CIEL."""
    root = pdk_root(pdk.name)
    if root:
        return pdk.with_root(root)
    # Try family-based lookup
    if pdk.ciel_family:
        family_root = ciel_root() / pdk.ciel_family
        if family_root.is_dir():
            variant = _find_variant_root(family_root, pdk.ciel_family)
            if variant:
                return pdk.with_root(variant)
    return pdk


def installed_pdks() -> list[str]:
    """List all PDK variant names installed in CIEL root."""
    root = ciel_root()
    if not root.exists():
        # Fall back to old volare root
        root = Path.home() / ".volare"
        if not root.exists():
            return []

    found: list[str] = []
    skip = {"volare", "ciel", ".cache"}

    for entry in root.iterdir():
        if entry.name in skip or entry.name.startswith("."):
            continue

        # Check if this is a CIEL family directory with versions
        versions_dir = entry / "versions"
        if versions_dir.is_dir():
            family = entry.name
            for vdir in versions_dir.iterdir():
                if not vdir.is_dir():
                    continue
                variant = _find_variant_root(vdir, family)
                if variant and variant.name not in found:
                    found.append(variant.name)
        elif entry.is_dir():
            # Legacy flat structure
            if (entry / "libs.tech").is_dir():
                found.append(entry.name)

    return sorted(found)


def available_families() -> list[str]:
    """List all PDK families available from CIEL (remote + local).

    Tries `ciel ls-remote` for each known family. Falls back to just
    returning KNOWN_FAMILIES if ciel is not available.
    """
    try:
        detect_ciel()
    except Exception:
        return list(KNOWN_FAMILIES)

    families = []
    for family in KNOWN_FAMILIES:
        try:
            versions = list_remote_versions(family)
            if versions:
                families.append(family)
        except Exception:
            # Family might still be locally installed
            local = list_local_versions(family)
            if local:
                families.append(family)

    # Always include known families even if remote check failed
    for family in KNOWN_FAMILIES:
        if family not in families:
            families.append(family)

    return families
