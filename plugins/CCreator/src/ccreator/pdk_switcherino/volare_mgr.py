"""Volare PDK manager — fetch, list, and locate installed PDKs."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from .pdk import PDK

VOLARE_ROOT = Path.home() / ".volare"


def detect_volare() -> str | None:
    """Find a working volare invocation. Returns command string or None."""
    candidates = [
        ["volare", "--version"],
        ["python3", "-m", "volare", "--version"],
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


def _run_volare(*args: str, timeout: int = 60) -> subprocess.CompletedProcess[str]:
    """Run a volare command, trying multiple invocation methods."""
    for base in (["volare"], ["python3", "-m", "volare"]):
        try:
            return subprocess.run(
                [*base, *args],
                capture_output=True, text=True, timeout=timeout, check=True,
            )
        except (FileNotFoundError, subprocess.SubprocessError):
            continue
    raise RuntimeError(
        "volare not found. Install with: pip install volare"
    )


def list_versions(pdk_family: str) -> list[str]:
    """List available versions for a PDK family (e.g. 'sky130')."""
    result = _run_volare("ls", "--pdk", pdk_family)
    versions = []
    for line in result.stdout.splitlines():
        token = line.strip().split()[0] if line.strip() else ""
        if token and not token.startswith(("-", "=", "Name")):
            versions.append(token)
    return versions


def fetch(pdk_family: str, version: str | None = None) -> None:
    """Fetch a PDK version into ~/.volare/."""
    args = ["fetch", "--pdk", pdk_family]
    if version:
        args.append(version)
    _run_volare(*args, timeout=300)


def pdk_root(pdk_name: str) -> Path | None:
    """Get installed PDK root directory, or None if not installed.

    Checks ~/.volare/<pdk_name> (symlink or directory).
    """
    candidate = VOLARE_ROOT / pdk_name
    if candidate.exists():
        return candidate.resolve()
    return None


def auto_root(pdk: PDK) -> PDK:
    """Return a copy of the PDK with root auto-detected from ~/.volare/."""
    root = pdk_root(pdk.name)
    if root:
        return pdk.with_root(root)
    return pdk


def installed_pdks() -> list[str]:
    """List PDK names installed in ~/.volare/."""
    if not VOLARE_ROOT.exists():
        return []
    skip = {"volare"}
    return sorted(
        p.name for p in VOLARE_ROOT.iterdir()
        if p.name not in skip and not p.name.startswith(".")
    )
