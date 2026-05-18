"""Schemify PDKSwitcher plugin -- PDK management and cross-PDK circuit remapping.

Manages open-source PDKs via CIEL (Circuit Interchange Exchange Library) and
LambdaPDK (SiliconCompiler's lambda-based PDK collection).  Provides an overlay
panel for switching schematics between PDKs with gm/Id-preserving transistor
resizing.

Supported PDKs:
  - SkyWater SKY130  (1.8 V, 130 nm)
  - GlobalFoundries GF180MCU  (3.3 V, 180 nm)
  - IHP SG13G2  (1.2 V, 130 nm SiGe BiCMOS)

Core flow:
  1. Read Config.toml -> detect required PDK
  2. Auto-install via CIEL if not present
  3. Convert xschem symbols to .chn_prim
  4. Load into Schemify's PDK library
  5. Cross-PDK remapping with gm/Id-preserving transistor resizing

Vim command: :pdkswitch [source] [target]
             :pdkswitch list-pdks
             :pdkswitch install <pdk_key>
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

# Add the SDK directory to sys.path so schemify_plugin is importable.
_THIS_DIR = os.path.dirname(os.path.realpath(__file__))
_SDK_DIR = os.path.normpath(os.path.join(_THIS_DIR, "..", "..", "..", "tools", "sdk", "python"))
if _SDK_DIR not in sys.path:
    sys.path.insert(0, _SDK_DIR)

from schemify_plugin import (
    Plugin,
    Widget,
    label,
    button,
    separator,
    checkbox,
    collapsible_start,
    collapsible_end,
    tooltip,
    begin_row,
    end_row,
    progress,
)

TAG = "PDKSwitcher"

# ---------------------------------------------------------------------------
# Widget ID allocation
# ---------------------------------------------------------------------------

WID_CB_USE_LUT = "cb_use_lut"
WID_REMAP = "remap"
WID_APPLY = "apply"
WID_REFRESH = "refresh"
WID_CONVERT_ALL = "convert_all"
WID_INSTALL_CIEL = "install_ciel"
WID_SETUP_PDK = "setup_pdk"

# ---------------------------------------------------------------------------
# Config.toml reader (minimal TOML parser for pdk field)
# ---------------------------------------------------------------------------


def _read_config_pdk() -> Optional[str]:
    """Read the active PDK from Config.toml in the working directory.

    Supports two formats:
      1. Top-level:          pdk = "sky130A"
      2. Section-based:      [pdk_switcher]  /  active = "sky130A"
    """
    config_path = os.path.join(os.getcwd(), "Config.toml")
    if not os.path.isfile(config_path):
        return None
    try:
        with open(config_path, "r") as f:
            in_pdk_switcher = False
            for line in f:
                stripped = line.strip()
                # Track TOML sections
                if stripped.startswith("["):
                    section = stripped.strip("[] \t")
                    in_pdk_switcher = section == "pdk_switcher"
                    continue
                # Format 1: top-level  pdk = "sky130A"
                if not in_pdk_switcher and stripped.startswith("pdk"):
                    m = re.match(r'^pdk\s*=\s*"([^"]+)"', stripped)
                    if m:
                        return m.group(1)
                # Format 2: [pdk_switcher] / active = "sky130A"
                if in_pdk_switcher and stripped.startswith("active"):
                    m = re.match(r'^active\s*=\s*"([^"]+)"', stripped)
                    if m:
                        return m.group(1)
    except OSError:
        pass
    return None


# ---------------------------------------------------------------------------
# CIEL / LambdaPDK integration layer
# ---------------------------------------------------------------------------

_CIEL_AVAILABLE: bool = False
_LAMBDAPDK_AVAILABLE: bool = False
_CIEL_ERROR: str = ""
_LAMBDAPDK_ERROR: str = ""


def _probe_ciel() -> bool:
    global _CIEL_AVAILABLE, _CIEL_ERROR
    try:
        import ciel  # noqa: F401
        _CIEL_AVAILABLE = True
        _CIEL_ERROR = ""
        return True
    except ImportError as exc:
        _CIEL_AVAILABLE = False
        _CIEL_ERROR = str(exc)
        return False


def _probe_lambdapdk() -> bool:
    global _LAMBDAPDK_AVAILABLE, _LAMBDAPDK_ERROR
    try:
        import lambdapdk  # noqa: F401
        _LAMBDAPDK_AVAILABLE = True
        _LAMBDAPDK_ERROR = ""
        return True
    except ImportError as exc:
        _LAMBDAPDK_AVAILABLE = False
        _LAMBDAPDK_ERROR = str(exc)
        return False


# ---------------------------------------------------------------------------
# PDK xschem symbol discovery + conversion
# ---------------------------------------------------------------------------


def _find_pdk_root() -> Optional[str]:
    """Find PDK installation root (CIEL or volare)."""
    pdk_root = os.environ.get("PDK_ROOT", "")
    if pdk_root and os.path.isdir(pdk_root):
        return pdk_root
    home = os.environ.get("HOME", os.path.expanduser("~"))
    for candidate in [
        os.path.join(home, ".pdk", "ciel"),
        os.path.join(home, ".volare"),
        os.path.join(home, ".local", "share", "pdk"),
        "/usr/local/share/pdk",
    ]:
        if os.path.isdir(candidate):
            return candidate
    return None


def _find_xschem_dir(pdk_root: str, pdk_key: str) -> Optional[str]:
    """Find the xschem symbols directory for a given PDK."""
    if pdk_key == "sky130A":
        sky_dir = os.path.join(pdk_root, "sky130")
        if os.path.isdir(sky_dir):
            for root, dirs, files in os.walk(sky_dir):
                if os.path.basename(root) == "sky130_fd_pr" and any(f.endswith(".sym") for f in files):
                    return root
        volare = os.path.join(pdk_root, "sky130A", "libs.tech", "xschem", "sky130_fd_pr")
        if os.path.isdir(volare):
            return volare

    elif pdk_key == "gf180mcuA":
        gf_dir = os.path.join(pdk_root, "gf180mcu")
        if os.path.isdir(gf_dir):
            for root, dirs, files in os.walk(gf_dir):
                if os.path.basename(root) == "symbols" and "xschem" in root and any(f.endswith(".sym") for f in files):
                    return root
        for variant in ["gf180mcuC", "gf180mcuA", "gf180mcuD"]:
            volare = os.path.join(pdk_root, variant, "libs.tech", "xschem", "symbols")
            if os.path.isdir(volare):
                return volare

    elif pdk_key == "ihp-sg13g2":
        ihp_dir = os.path.join(pdk_root, "ihp-sg13g2")
        if os.path.isdir(ihp_dir):
            for root, dirs, files in os.walk(ihp_dir):
                if os.path.basename(root) == "sg13g2_pr" and any(f.endswith(".sym") for f in files):
                    return root
        volare = os.path.join(pdk_root, "ihp-sg13g2", "libs.tech", "xschem", "sg13g2_pr")
        if os.path.isdir(volare):
            return volare

    return None


def _get_sym_files(xschem_dir: str, pdk_key: str) -> list[str]:
    """Get all .sym file paths in an xschem directory."""
    return sorted(
        os.path.join(xschem_dir, f)
        for f in os.listdir(xschem_dir)
        if f.endswith(".sym")
    )


def _find_schemify_binary() -> Optional[str]:
    """Locate the schemify binary."""
    import shutil
    which = shutil.which("schemify") or shutil.which("Schemify")
    if which:
        return which
    plugin_dir = Path(__file__).resolve().parent.parent.parent.parent
    candidate = plugin_dir / "zig-out" / "bin" / "Schemify"
    if candidate.is_file():
        return str(candidate)
    return None


def _conversion_output_dir(pdk_key: str) -> str:
    """Return output directory for converted primitives: ~/.cache/schemify/pdk/<key>/"""
    home = os.environ.get("HOME", os.path.expanduser("~"))
    return os.path.join(home, ".cache", "schemify", "pdk", pdk_key)


def _is_converted(pdk_key: str) -> bool:
    """Check if a PDK has already been converted."""
    out_dir = _conversion_output_dir(pdk_key)
    if not os.path.isdir(out_dir):
        return False
    return any(f.endswith(".chn_prim") for f in os.listdir(out_dir))


def _ciel_install_pdk(pdk_key: str) -> tuple[bool, str]:
    """Attempt to install a PDK through CIEL."""
    if not _CIEL_AVAILABLE:
        return False, "CIEL is not installed. Run: pip install ciel"
    try:
        import ciel
        if hasattr(ciel, "install"):
            ciel.install(pdk_key)
            return True, f"PDK '{pdk_key}' installed via CIEL"
        elif hasattr(ciel, "Registry"):
            reg = ciel.Registry()
            reg.install(pdk_key)
            return True, f"PDK '{pdk_key}' installed via CIEL"
        return False, "CIEL does not support install() in this version"
    except Exception as exc:
        return False, f"Installation failed: {exc}"


def _install_ciel_subprocess() -> tuple[bool, str]:
    """Install CIEL via pip subprocess."""
    try:
        result = subprocess.run(
            [sys.executable, "-m", "pip", "install", "ciel"],
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode == 0:
            return True, "CIEL installed successfully"
        return False, f"pip install ciel failed: {result.stderr.strip()[:200]}"
    except subprocess.TimeoutExpired:
        return False, "pip install ciel timed out"
    except OSError as e:
        return False, f"Failed to run pip: {e}"


def _install_pdk_subprocess(pdk_key: str) -> tuple[bool, str]:
    """Install a PDK via CIEL CLI subprocess."""
    # Map our keys to CIEL package names
    ciel_names = {
        "sky130A": "sky130",
        "gf180mcuA": "gf180mcu",
        "ihp-sg13g2": "ihp-sg13g2",
    }
    ciel_name = ciel_names.get(pdk_key, pdk_key)
    try:
        result = subprocess.run(
            [sys.executable, "-m", "ciel", "install", ciel_name],
            capture_output=True, text=True, timeout=600,
        )
        if result.returncode == 0:
            return True, f"PDK '{pdk_key}' installed via CIEL"
        # Fallback: try 'ciel' directly
        result2 = subprocess.run(
            ["ciel", "install", ciel_name],
            capture_output=True, text=True, timeout=600,
        )
        if result2.returncode == 0:
            return True, f"PDK '{pdk_key}' installed via CIEL"
        return False, f"ciel install {ciel_name} failed: {result.stderr.strip()[:200]}"
    except subprocess.TimeoutExpired:
        return False, f"ciel install {ciel_name} timed out (>10min)"
    except OSError as e:
        return False, f"Failed to run ciel: {e}"


# ---------------------------------------------------------------------------
# Built-in PDK database
# ---------------------------------------------------------------------------

BUILTIN_PDKS: list[dict[str, Any]] = [
    {
        "key": "sky130A",
        "display": "SkyWater SKY130",
        "vdd": 1.8,
        "lmin_um": 0.15,
        "source": "builtin",
        "installed": False,
    },
    {
        "key": "ihp-sg13g2",
        "display": "IHP SG13G2 (SiGe BiCMOS)",
        "vdd": 1.2,
        "lmin_um": 0.13,
        "source": "builtin",
        "installed": False,
    },
    {
        "key": "gf180mcuA",
        "display": "GlobalFoundries GF180MCU",
        "vdd": 3.3,
        "lmin_um": 0.28,
        "source": "builtin",
        "installed": False,
    },
]


# ---------------------------------------------------------------------------
# Model-to-PDK mapping
# ---------------------------------------------------------------------------

_MODEL_TO_PDK: dict[str, tuple[str, str]] = {
    # SkyWater SKY130
    "sky130_fd_pr__nfet_01v8":     ("sky130A", "nfet"),
    "sky130_fd_pr__pfet_01v8":     ("sky130A", "pfet"),
    "sky130_fd_pr__nfet_01v8_lvt": ("sky130A", "nfet_lvt"),
    "sky130_fd_pr__pfet_01v8_lvt": ("sky130A", "pfet_lvt"),
    "sky130_fd_pr__nfet_01v8_hvt": ("sky130A", "nfet_hvt"),
    "sky130_fd_pr__pfet_01v8_hvt": ("sky130A", "pfet_hvt"),
    # IHP SG13G2
    "sg13_lv_nmos":  ("ihp-sg13g2", "nfet"),
    "sg13_lv_pmos":  ("ihp-sg13g2", "pfet"),
    "sg13_hv_nmos":  ("ihp-sg13g2", "nfet_hv"),
    "sg13_hv_pmos":  ("ihp-sg13g2", "pfet_hv"),
    # GlobalFoundries GF180MCU
    "nfet_03v3": ("gf180mcuA", "nfet"),
    "pfet_03v3": ("gf180mcuA", "pfet"),
    "nfet_05v0": ("gf180mcuA", "nfet_hv"),
    "pfet_05v0": ("gf180mcuA", "pfet_hv"),
    "nfet_06v0": ("gf180mcuA", "nfet_hv6"),
    "pfet_06v0": ("gf180mcuA", "pfet_hv6"),
}

_MOSFET_SYMBOLS = frozenset({"nmos4", "pmos4", "nmos", "pmos"})


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class InstanceInfo:
    idx: int
    name: str
    symbol: str
    model: str = ""
    w: str = ""
    l: str = ""
    nf: str = ""
    new_model: str = ""
    new_w: str = ""
    new_l: str = ""
    new_nf: str = ""


@dataclass
class RemapPreview:
    devices: list[InstanceInfo] = field(default_factory=list)
    unmapped_models: list[str] = field(default_factory=list)
    mapping_table: list[tuple[str, str]] = field(default_factory=list)
    mode: str = "linear"
    warnings: list[str] = field(default_factory=list)
    has_errors: bool = False


class _Phase:
    IDLE = "idle"
    QUERYING = "querying"
    COLLECTING_PROPS = "collecting"
    PREVIEW_READY = "preview"
    APPLYING = "applying"


# ---------------------------------------------------------------------------
# Pipeline state
# ---------------------------------------------------------------------------

@dataclass
class PipelineState:
    """Tracks the automatic PDK setup pipeline."""
    config_pdk: Optional[str] = None       # from Config.toml
    ciel_installed: bool = False            # CIEL Python package present
    pdk_installed: bool = False             # PDK files on disk
    pdk_converted: bool = False             # .chn_prim files exist
    pdk_loaded: bool = False                # load_pdk sent to host
    error: Optional[str] = None            # last pipeline error
    log: list[str] = field(default_factory=list)

    def stage_str(self) -> str:
        if self.error:
            return f"Error: {self.error}"
        if self.pdk_loaded:
            return "Ready"
        if self.pdk_converted:
            return "Loading..."
        if self.pdk_installed:
            return "Converting..."
        if self.ciel_installed:
            return "Installing PDK..."
        return "Setup required"


# ---------------------------------------------------------------------------
# SPICE value parsing / formatting
# ---------------------------------------------------------------------------

def _parse_spice_value(s: str) -> Optional[float]:
    if not s:
        return None
    s = s.strip()
    multipliers = {
        "T": 1e12, "G": 1e9, "MEG": 1e6, "M": 1e6, "k": 1e3, "K": 1e3,
        "m": 1e-3, "u": 1e-6, "n": 1e-9, "p": 1e-12, "f": 1e-15, "a": 1e-18,
    }
    try:
        return float(s)
    except ValueError:
        pass
    for suffix, mult in sorted(multipliers.items(), key=lambda x: -len(x[0])):
        if s.lower().endswith(suffix.lower()):
            num_part = s[: -len(suffix)]
            try:
                return float(num_part) * mult
            except ValueError:
                continue
    if s.endswith("m"):
        try:
            return float(s[:-1]) * 1e-3
        except ValueError:
            pass
    return None


def _format_spice_value(val: float) -> str:
    if val == 0:
        return "0"
    abs_val = abs(val)
    if abs_val >= 1e-3:
        return f"{val:.4g}"
    elif abs_val >= 1e-6:
        return f"{val * 1e6:.3g}u"
    elif abs_val >= 1e-9:
        return f"{val * 1e9:.3g}n"
    elif abs_val >= 1e-12:
        return f"{val * 1e12:.3g}p"
    else:
        return f"{val:.4g}"


def _pdk_index(key: str) -> Optional[int]:
    for i, p in enumerate(BUILTIN_PDKS):
        if p["key"] == key:
            return i
    return None


def _get_mapped_models(src_key: str, tgt_key: str) -> dict[str, str]:
    src_rev: dict[str, str] = {}
    tgt_map: dict[str, str] = {}
    for model, (pdk_key, generic) in _MODEL_TO_PDK.items():
        if pdk_key == src_key:
            src_rev[model] = generic
        elif pdk_key == tgt_key:
            tgt_map[generic] = model
    result: dict[str, str] = {}
    for model, generic in src_rev.items():
        if generic in tgt_map:
            result[model] = tgt_map[generic]
    return result


# ---------------------------------------------------------------------------
# Plugin
# ---------------------------------------------------------------------------

class PDKSwitcherPlugin(Plugin):

    def __init__(self) -> None:
        super().__init__()
        self._src_idx: int = 0
        self._tgt_idx: int = 1
        self._use_lut: bool = False
        self._luts_available: bool = False

        self._phase: str = _Phase.IDLE
        self._status: str = "Ready"

        self._instance_count: int = 0
        self._instances: dict[int, InstanceInfo] = {}
        self._pending_props: int = 0
        self._preview: Optional[RemapPreview] = None

        # Pipeline
        self._pipeline = PipelineState()
        self._schemify_bin: Optional[str] = None
        self._pdk_root: Optional[str] = None
        self._convert_log: list[str] = []

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def on_load(self) -> None:
        self.register_panel("pdk-switch", "PDK Switcher", "overlay")
        self.set_status("PDKSwitcher loaded")
        self.log("PDKSwitcher plugin loaded (api=1)")

        self._schemify_bin = _find_schemify_binary()
        self._pdk_root = _find_pdk_root()

        if self._schemify_bin:
            self.log(f"Schemify binary: {self._schemify_bin}")
        else:
            self.log("Schemify binary not found — conversion disabled", level="warn")

        # Probe backends
        self._pipeline.ciel_installed = _probe_ciel()
        _probe_lambdapdk()

        # Detect installed PDKs
        self._detect_installed_pdks()

        # Read Config.toml -> auto-pipeline
        config_pdk = _read_config_pdk()
        if config_pdk:
            self._pipeline.config_pdk = config_pdk
            self.log(f"Config.toml pdk = \"{config_pdk}\"")
            self._auto_setup(config_pdk)

    def on_unload(self) -> None:
        self.log("PDKSwitcher unloaded")

    # ------------------------------------------------------------------
    # Automatic PDK setup pipeline
    # ------------------------------------------------------------------

    def _auto_setup(self, pdk_key: str) -> None:
        """Full automatic pipeline: install -> convert -> load."""
        pl = self._pipeline

        # 1. Check if PDK files are on disk
        if self._pdk_root:
            xschem_dir = _find_xschem_dir(self._pdk_root, pdk_key)
            pl.pdk_installed = xschem_dir is not None
        else:
            pl.pdk_installed = False

        # 2. If not installed, try to install
        if not pl.pdk_installed:
            pl.log.append(f"PDK '{pdk_key}' not found locally, attempting install...")
            self.log(f"PDK '{pdk_key}' not found, attempting CIEL install...")

            if not pl.ciel_installed:
                # Try installing CIEL first
                ok, msg = _install_ciel_subprocess()
                pl.log.append(msg)
                if ok:
                    pl.ciel_installed = True
                    _probe_ciel()
                else:
                    pl.error = f"CIEL not available: {msg}"
                    self.log(pl.error, level="err")
                    self.set_status(f"PDK setup failed: {pl.error}")
                    return

            # Install PDK via CIEL
            ok, msg = _install_pdk_subprocess(pdk_key)
            pl.log.append(msg)
            if ok:
                pl.pdk_installed = True
                # Re-discover root
                self._pdk_root = _find_pdk_root()
                self._detect_installed_pdks()
                self.log(msg)
            else:
                pl.error = msg
                self.log(msg, level="err")
                self.set_status(f"PDK install failed: {msg}")
                return

        # 3. Check if already converted
        pl.pdk_converted = _is_converted(pdk_key)

        # 4. Convert if needed
        if not pl.pdk_converted:
            if not self._schemify_bin:
                pl.error = "Schemify binary not found — cannot convert"
                self.log(pl.error, level="err")
                return
            self._run_convert_pdk(pdk_key)
            pl.pdk_converted = _is_converted(pdk_key)
            if not pl.pdk_converted:
                pl.error = "Conversion produced no .chn_prim files"
                return

        # 5. Load
        self.push_command(f"load_pdk {pdk_key}")
        pl.pdk_loaded = True
        pl.log.append(f"Loaded PDK: {pdk_key}")
        self.log(f"Auto-setup complete: {pdk_key}")
        self.set_status(f"PDK: {pdk_key} (ready)")

        # Set source PDK index
        idx = _pdk_index(pdk_key)
        if idx is not None:
            self._src_idx = idx
            if self._tgt_idx == self._src_idx:
                self._tgt_idx = (self._src_idx + 1) % len(BUILTIN_PDKS)

    # ------------------------------------------------------------------
    # PDK detection
    # ------------------------------------------------------------------

    def _detect_installed_pdks(self) -> None:
        """Detect locally installed PDKs by checking standard paths."""
        if not self._pdk_root:
            self._pdk_root = _find_pdk_root()
        if not self._pdk_root:
            return

        pdk_key_to_dirs = {
            "sky130A":     ["sky130A", "sky130"],
            "ihp-sg13g2":  ["ihp-sg13g2", "sg13g2", "IHP-Open-PDK"],
            "gf180mcuA":   ["gf180mcuA", "gf180mcu", "gf180mcuC", "gf180mcuD"],
        }

        for pdk_info in BUILTIN_PDKS:
            key = pdk_info["key"]
            dirs_to_check = pdk_key_to_dirs.get(key, [key])
            for dirname in dirs_to_check:
                pdk_path = os.path.join(self._pdk_root, dirname)
                if os.path.isdir(pdk_path):
                    pdk_info["installed"] = True
                    break

    # ------------------------------------------------------------------
    # Drawing
    # ------------------------------------------------------------------

    def on_draw_panel(self, panel_id: str) -> list[Widget]:
        widgets: list[Widget] = []

        widgets.append(label("PDK Switcher"))
        widgets.append(separator())

        # Pipeline status section
        widgets.extend(self._build_pipeline_section())
        widgets.append(separator())

        # Conversion section
        widgets.extend(self._build_convert_section())
        widgets.append(separator())

        # Remap sections
        widgets.extend(self._build_source_section())
        widgets.append(separator())
        widgets.extend(self._build_target_section())
        widgets.append(separator())
        widgets.extend(self._build_comparison())
        widgets.append(separator())
        widgets.extend(self._build_options())
        widgets.append(separator())
        widgets.extend(self._build_mapping_table())
        widgets.append(separator())
        widgets.extend(self._build_actions())
        widgets.extend(self._build_errors())
        widgets.extend(self._build_preview())
        widgets.append(separator())

        widgets.append(label(f"Status: {self._status}", widget_id="status"))
        return widgets

    def _build_pipeline_section(self) -> list[Widget]:
        """Show the automatic PDK setup pipeline status."""
        widgets: list[Widget] = []
        pl = self._pipeline

        widgets.append(label("PDK Setup Pipeline"))

        if pl.config_pdk:
            widgets.append(label(f"  Config.toml: pdk = \"{pl.config_pdk}\""))
        else:
            widgets.append(label("  Config.toml: no pdk field set"))
            widgets.append(tooltip(
                "Add pdk = \"sky130A\" to your project's Config.toml "
                "for automatic PDK setup on load."
            ))

        # Stage indicators
        stages = [
            ("CIEL", pl.ciel_installed),
            ("PDK Installed", pl.pdk_installed),
            ("Converted", pl.pdk_converted),
            ("Loaded", pl.pdk_loaded),
        ]
        stage_line = "  "
        for name, done in stages:
            marker = "[x]" if done else "[ ]"
            stage_line += f"{marker} {name}  "
        widgets.append(label(stage_line))

        if pl.error:
            widgets.append(label(f"  ERROR: {pl.error}"))

        # Action buttons for incomplete stages
        if not pl.ciel_installed:
            widgets.append(button("Install CIEL (pip)", widget_id=WID_INSTALL_CIEL))

        if pl.config_pdk and not pl.pdk_loaded:
            widgets.append(button(f"Setup {pl.config_pdk}", widget_id=WID_SETUP_PDK))

        # Pipeline log
        if pl.log:
            widgets.append(collapsible_start("Pipeline Log", "pipeline_log"))
            for line in pl.log[-15:]:
                widgets.append(label(f"  {line}"))
            widgets.append(collapsible_end())

        return widgets

    def _build_convert_section(self) -> list[Widget]:
        """Build PDK symbol conversion section."""
        widgets: list[Widget] = []
        widgets.append(label("PDK Symbol Conversion"))
        widgets.append(tooltip(
            "Convert xschem .sym files to Schemify .chn_prim format. "
            "Output: ~/.cache/schemify/pdk/<pdk>/"
        ))

        if not self._schemify_bin:
            widgets.append(label("  [!] Schemify binary not found — build first"))
            return widgets

        if not self._pdk_root:
            widgets.append(label("  [!] No PDK installation found"))
            widgets.append(label("  Install: pip install ciel && ciel install sky130"))
            return widgets

        for i, pdk in enumerate(BUILTIN_PDKS):
            if not pdk.get("installed"):
                continue
            key = pdk["key"]
            xschem_dir = _find_xschem_dir(self._pdk_root, key)
            out_dir = _conversion_output_dir(key)
            already_converted = _is_converted(key)
            sym_count = len(_get_sym_files(xschem_dir, key)) if xschem_dir else 0

            if already_converted:
                n_prims = len([f for f in os.listdir(out_dir) if f.endswith(".chn_prim")])
                widgets.append(label(f"  {pdk['display']}: {n_prims} primitives [converted]"))
            elif xschem_dir and sym_count > 0:
                widgets.append(begin_row())
                widgets.append(label(f"  {pdk['display']}: {sym_count} symbols"))
                widgets.append(button("Convert", widget_id=f"convert_{i}"))
                widgets.append(end_row())
            else:
                widgets.append(label(f"  {pdk['display']}: no xschem symbols found"))

        # Show convert all only if there are unconverted installed PDKs
        has_unconverted = any(
            pdk.get("installed") and not _is_converted(pdk["key"])
            for pdk in BUILTIN_PDKS
        )
        if has_unconverted:
            widgets.append(button("Convert All Installed", widget_id=WID_CONVERT_ALL))

        if self._convert_log:
            widgets.append(collapsible_start("Conversion Log", "conv_log"))
            for line in self._convert_log[-20:]:
                widgets.append(label(f"  {line}"))
            widgets.append(collapsible_end())

        return widgets

    def _run_convert_pdk(self, pdk_key: str) -> None:
        """Convert xschem symbols for a single PDK to .chn_prim."""
        if not self._schemify_bin or not self._pdk_root:
            return

        xschem_dir = _find_xschem_dir(self._pdk_root, pdk_key)
        if not xschem_dir:
            msg = f"{pdk_key}: xschem dir not found"
            self._convert_log.append(msg)
            self.log(msg, level="warn")
            return

        sym_files = _get_sym_files(xschem_dir, pdk_key)
        if not sym_files:
            msg = f"{pdk_key}: no .sym files found in {xschem_dir}"
            self._convert_log.append(msg)
            self.log(msg, level="warn")
            return

        out_dir = _conversion_output_dir(pdk_key)
        os.makedirs(out_dir, exist_ok=True)

        imported = 0
        failed = 0
        self._convert_log.append(f"--- {pdk_key}: converting {len(sym_files)} symbols ---")
        self.log(f"{pdk_key}: converting {len(sym_files)} symbols to {out_dir}")

        for sym_path in sym_files:
            base = os.path.splitext(os.path.basename(sym_path))[0]
            try:
                result = subprocess.run(
                    [self._schemify_bin, "--import", "-o", out_dir, sym_path, "primitive"],
                    capture_output=True, text=True, timeout=30,
                )
                if "imported:" in result.stdout:
                    imported += 1
                else:
                    failed += 1
                    err = result.stderr.strip() or result.stdout.strip()
                    self._convert_log.append(f"  FAIL {base}: {err[:80]}")
            except subprocess.TimeoutExpired:
                failed += 1
                self._convert_log.append(f"  TIMEOUT {base}")
            except OSError as e:
                failed += 1
                self._convert_log.append(f"  ERROR {base}: {e}")

        summary = f"{pdk_key}: {imported} OK, {failed} failed"
        self._convert_log.append(summary)
        self.log(summary)
        self._status = summary
        self.set_status(self._status)

        if imported > 0:
            self.push_command(f"load_pdk {pdk_key}")

    def _run_convert_all(self) -> None:
        """Convert all installed PDKs."""
        for pdk in BUILTIN_PDKS:
            if pdk.get("installed") and not _is_converted(pdk["key"]):
                self._run_convert_pdk(pdk["key"])
        self.request_refresh()

    def _build_source_section(self) -> list[Widget]:
        widgets: list[Widget] = []
        widgets.append(label("Source PDK:"))
        for i, pdk in enumerate(BUILTIN_PDKS):
            marker = "> " if i == self._src_idx else "  "
            installed = " [installed]" if pdk.get("installed") else ""
            widgets.append(button(
                f"{marker}{pdk['display']} ({pdk['vdd']}V){installed}",
                widget_id=f"src_{i}",
            ))
        return widgets

    def _build_target_section(self) -> list[Widget]:
        widgets: list[Widget] = []
        widgets.append(label("Target PDK:"))
        for i, pdk in enumerate(BUILTIN_PDKS):
            if i == self._src_idx:
                continue
            marker = "> " if i == self._tgt_idx else "  "
            installed = " [installed]" if pdk.get("installed") else ""
            widgets.append(button(
                f"{marker}{pdk['display']} ({pdk['vdd']}V){installed}",
                widget_id=f"tgt_{i}",
            ))
        return widgets

    def _build_comparison(self) -> list[Widget]:
        widgets: list[Widget] = []
        src = BUILTIN_PDKS[self._src_idx]
        tgt = BUILTIN_PDKS[self._tgt_idx]
        src_vdd = src["vdd"]
        tgt_vdd = tgt["vdd"]
        src_lmin = src["lmin_um"]
        tgt_lmin = tgt["lmin_um"]
        vdd_ratio = src_vdd / tgt_vdd if tgt_vdd != 0 else 0
        lmin_ratio = tgt_lmin / src_lmin if src_lmin != 0 else 0

        widgets.append(collapsible_start("PDK Comparison", "pdk_cmp", open=True))
        widgets.append(label(f"  VDD:     {src_vdd}V  ->  {tgt_vdd}V"))
        widgets.append(label(f"  L_min:   {src_lmin}um  ->  {tgt_lmin}um"))
        widgets.append(label(f"  VDD ratio:   {vdd_ratio:.2f}x"))
        widgets.append(label(f"  L_min ratio: {lmin_ratio:.2f}x"))
        widgets.append(collapsible_end())
        return widgets

    def _build_options(self) -> list[Widget]:
        widgets: list[Widget] = []
        lut_label = "Use gm/Id LUT (higher accuracy)"
        if self._use_lut and self._luts_available:
            lut_label += " -- LUTs loaded"
        elif self._use_lut:
            lut_label += " -- will use linear scaling if LUTs unavailable"
        widgets.append(checkbox(lut_label, WID_CB_USE_LUT, checked=self._use_lut))
        return widgets

    def _build_mapping_table(self) -> list[Widget]:
        widgets: list[Widget] = []
        src_key = BUILTIN_PDKS[self._src_idx]["key"]
        tgt_key = BUILTIN_PDKS[self._tgt_idx]["key"]

        src_generics: dict[str, str] = {}
        tgt_generics: dict[str, str] = {}
        for model, (pdk_key, generic) in _MODEL_TO_PDK.items():
            if pdk_key == src_key:
                src_generics[generic] = model
            elif pdk_key == tgt_key:
                tgt_generics[generic] = model

        if not src_generics:
            return widgets

        widgets.append(collapsible_start("Model Mapping", "model_map", open=True))
        widgets.append(label(f"  {'Source (' + src_key + ')':<36s}  ->  Target ({tgt_key})"))
        widgets.append(label("  " + "-" * 60))

        for generic in sorted(src_generics):
            src_model = src_generics[generic]
            if generic in tgt_generics:
                tgt_model = tgt_generics[generic]
                widgets.append(label(f"  {src_model:<36s}  ->  {tgt_model}"))
            else:
                widgets.append(label(f"  {src_model:<36s}  ->  [no mapping]"))

        widgets.append(collapsible_end())
        return widgets

    def _build_actions(self) -> list[Widget]:
        widgets: list[Widget] = []
        widgets.append(begin_row())
        widgets.append(button("Remap Schematic", widget_id=WID_REMAP))
        widgets.append(button("Refresh PDKs", widget_id=WID_REFRESH))
        widgets.append(end_row())
        return widgets

    def _build_errors(self) -> list[Widget]:
        widgets: list[Widget] = []
        preview = self._preview
        if preview is None or not preview.unmapped_models:
            return widgets
        widgets.append(separator())
        widgets.append(label("ERRORS -- cannot apply remap:"))
        for model in preview.unmapped_models:
            widgets.append(label(f"  [ERROR] No target mapping for: {model}"))
        widgets.append(label(
            f"  {len(preview.unmapped_models)} unmapped model(s) -- resolve before applying."
        ))
        return widgets

    def _build_preview(self) -> list[Widget]:
        widgets: list[Widget] = []
        preview = self._preview
        if preview is None:
            return widgets

        devices = preview.devices
        if not devices:
            widgets.append(label("No MOSFETs found in schematic."))
            return widgets

        mode_str = "gm/Id LUT" if preview.mode == "lut" else "linear scaling"
        widgets.append(collapsible_start(
            f"Preview ({len(devices)} devices, {mode_str})", "preview", open=True
        ))

        widgets.append(label(
            f"  {'Instance':<14s} {'Model (src)':<32s} {'W':>8s} {'L':>8s} {'nf':>4s}"
            f"  ->  {'Model (tgt)':<32s} {'W':>8s} {'L':>8s} {'nf':>4s}"
        ))
        widgets.append(label("  " + "-" * 120))

        for dev in devices:
            src_w = dev.w or "?"
            src_l = dev.l or "?"
            src_nf = dev.nf or "1"

            if dev.new_model:
                tgt_model = dev.new_model
                tgt_w = dev.new_w or "?"
                tgt_l = dev.new_l or "?"
                tgt_nf = dev.new_nf or src_nf
            else:
                tgt_model = "?"
                tgt_w = "?"
                tgt_l = "?"
                tgt_nf = "?"

            widgets.append(label(
                f"  {dev.name:<14s} {dev.model:<32s} {src_w:>8s} {src_l:>8s} {src_nf:>4s}"
                f"  ->  {tgt_model:<32s} {tgt_w:>8s} {tgt_l:>8s} {tgt_nf:>4s}"
            ))

        widgets.append(collapsible_end())

        for warn in preview.warnings:
            widgets.append(label(f"  [warn] {warn}"))

        if preview.has_errors:
            widgets.append(label("Apply blocked: fix unmapped model errors above."))
        else:
            widgets.append(button(
                f"Apply Remap ({len(devices)} devices)", widget_id=WID_APPLY
            ))

        return widgets

    # ------------------------------------------------------------------
    # Event handlers
    # ------------------------------------------------------------------

    def on_button_clicked(self, panel_id: str, widget_id: str) -> None:
        if widget_id.startswith("src_"):
            try:
                src_idx = int(widget_id[4:])
            except ValueError:
                return
            if 0 <= src_idx < len(BUILTIN_PDKS):
                self._src_idx = src_idx
                if self._tgt_idx == self._src_idx:
                    self._tgt_idx = (self._src_idx + 1) % len(BUILTIN_PDKS)
                self._preview = None
                self._phase = _Phase.IDLE
                self.request_refresh()
            return

        if widget_id.startswith("tgt_"):
            try:
                tgt_idx = int(widget_id[4:])
            except ValueError:
                return
            if 0 <= tgt_idx < len(BUILTIN_PDKS) and tgt_idx != self._src_idx:
                self._tgt_idx = tgt_idx
                self._preview = None
                self._phase = _Phase.IDLE
            self.request_refresh()
            return

        if widget_id == WID_REMAP:
            self._start_remap()
            return

        if widget_id == WID_APPLY:
            self._apply_remap()
            return

        if widget_id == WID_REFRESH:
            self._pdk_root = _find_pdk_root()
            self._detect_installed_pdks()
            installed_count = sum(1 for p in BUILTIN_PDKS if p.get("installed"))
            self._status = f"Refreshed: {installed_count}/{len(BUILTIN_PDKS)} installed"
            self.set_status(self._status)
            self.request_refresh()
            return

        if widget_id == WID_CONVERT_ALL:
            self._run_convert_all()
            return

        if widget_id == WID_INSTALL_CIEL:
            self._do_install_ciel()
            return

        if widget_id == WID_SETUP_PDK:
            pdk_key = self._pipeline.config_pdk
            if pdk_key:
                self._pipeline.error = None
                self._pipeline.log.clear()
                self._auto_setup(pdk_key)
            self.request_refresh()
            return

        if widget_id.startswith("convert_"):
            try:
                convert_idx = int(widget_id[8:])
            except ValueError:
                return
            if 0 <= convert_idx < len(BUILTIN_PDKS):
                pdk_key = BUILTIN_PDKS[convert_idx]["key"]
                self._run_convert_pdk(pdk_key)
                self.request_refresh()
            return

        if widget_id.startswith("install_"):
            try:
                install_idx = int(widget_id[8:])
            except ValueError:
                return
            if 0 <= install_idx < len(BUILTIN_PDKS):
                pdk_key = BUILTIN_PDKS[install_idx]["key"]
                ok, msg = _install_pdk_subprocess(pdk_key)
                self._pipeline.log.append(msg)
                if ok:
                    self._pdk_root = _find_pdk_root()
                    self._detect_installed_pdks()
                self._status = msg
                self.set_status(msg)
                self.request_refresh()
            return

    def on_checkbox_changed(self, panel_id: str, widget_id: str, checked: bool) -> None:
        if widget_id == WID_CB_USE_LUT:
            self._use_lut = checked
            if self._preview is not None:
                self._preview = None
                self._phase = _Phase.IDLE
            self.request_refresh()

    # ------------------------------------------------------------------
    # Actions
    # ------------------------------------------------------------------

    def _do_install_ciel(self) -> None:
        """Install CIEL and refresh state."""
        self._status = "Installing CIEL..."
        self.set_status(self._status)
        ok, msg = _install_ciel_subprocess()
        self._pipeline.log.append(msg)
        if ok:
            self._pipeline.ciel_installed = True
            _probe_ciel()
            self._status = "CIEL installed"
        else:
            self._status = f"CIEL install failed: {msg}"
        self.set_status(self._status)
        self.log(self._status)
        self.request_refresh()

    # ------------------------------------------------------------------
    # Remap logic
    # ------------------------------------------------------------------

    def _start_remap(self) -> None:
        self._instances.clear()
        self._preview = None
        self._phase = _Phase.QUERYING
        self._status = "Querying schematic instances..."
        self.push_command("query_instances")
        self.set_status(self._status)
        self.request_refresh()

    def _compute_preview(self) -> None:
        src_key = BUILTIN_PDKS[self._src_idx]["key"]
        tgt_key = BUILTIN_PDKS[self._tgt_idx]["key"]

        preview = RemapPreview()

        # Auto-detect source PDK from model names
        detected_pdks: dict[str, int] = {}
        for inst in self._instances.values():
            if inst.model and inst.model in _MODEL_TO_PDK:
                pdk_key = _MODEL_TO_PDK[inst.model][0]
                detected_pdks[pdk_key] = detected_pdks.get(pdk_key, 0) + 1

        if detected_pdks:
            best_pdk = max(detected_pdks, key=lambda k: detected_pdks[k])
            best_idx = _pdk_index(best_pdk)
            if best_idx is not None and best_idx != self._src_idx:
                self._src_idx = best_idx
                if self._tgt_idx == self._src_idx:
                    self._tgt_idx = (self._src_idx + 1) % len(BUILTIN_PDKS)
                src_key = BUILTIN_PDKS[self._src_idx]["key"]
                tgt_key = BUILTIN_PDKS[self._tgt_idx]["key"]
                preview.warnings.append(
                    f"Auto-detected source PDK: {src_key} ({detected_pdks[best_pdk]} device(s))"
                )

        mapped_src_to_tgt = _get_mapped_models(src_key, tgt_key)

        # Build mapping table for display
        src_generics: dict[str, str] = {}
        tgt_generics: dict[str, str] = {}
        for model, (pdk_key, generic) in _MODEL_TO_PDK.items():
            if pdk_key == src_key:
                src_generics[generic] = model
            elif pdk_key == tgt_key:
                tgt_generics[generic] = model

        for generic in sorted(src_generics):
            src_model = src_generics[generic]
            tgt_model = tgt_generics.get(generic, "")
            preview.mapping_table.append((src_model, tgt_model))

        # Remap each device
        seen_unmapped: set[str] = set()

        for inst in sorted(self._instances.values(), key=lambda d: d.idx):
            model = inst.model
            if not model:
                preview.warnings.append(f"{inst.name}: no model property, skipped")
                continue

            mapped_model = mapped_src_to_tgt.get(model)

            if mapped_model is None:
                if model not in seen_unmapped:
                    preview.unmapped_models.append(model)
                    seen_unmapped.add(model)
                preview.has_errors = True
                inst.new_model = model
                inst.new_w = "?"
                inst.new_l = "?"
                inst.new_nf = inst.nf or "1"
                preview.devices.append(inst)
                continue

            w_val = _parse_spice_value(inst.w)
            l_val = _parse_spice_value(inst.l)
            nf_val = int(inst.nf) if inst.nf and inst.nf.isdigit() else 1

            inst.new_model = mapped_model
            if w_val is not None and l_val is not None:
                src_info = BUILTIN_PDKS[self._src_idx]
                tgt_info = BUILTIN_PDKS[self._tgt_idx]
                vdd_ratio = src_info["vdd"] / tgt_info["vdd"] if tgt_info["vdd"] != 0 else 1
                lmin_ratio = tgt_info["lmin_um"] / src_info["lmin_um"] if src_info["lmin_um"] != 0 else 1
                new_w = w_val * vdd_ratio * lmin_ratio
                new_l = l_val * lmin_ratio
                inst.new_w = _format_spice_value(new_w)
                inst.new_l = _format_spice_value(new_l)
                inst.new_nf = str(nf_val)
                preview.mode = "linear"
            else:
                inst.new_w = inst.w
                inst.new_l = inst.l
                inst.new_nf = inst.nf or "1"
                preview.warnings.append(f"{inst.name}: could not parse W/L, model remapped only")

            preview.devices.append(inst)

        self._preview = preview
        self._phase = _Phase.PREVIEW_READY

        n = len(preview.devices)
        n_err = len(preview.unmapped_models)
        if n_err > 0:
            self._status = f"Preview: {n} device(s), {n_err} UNMAPPED -- cannot apply"
        else:
            self._status = f"Preview: {n} device(s), {preview.mode} mode"

        self.set_status(self._status)
        self.log(self._status)
        self.request_refresh()

    def _apply_remap(self) -> None:
        preview = self._preview
        if preview is None:
            self._status = "No remap preview -- run Remap first"
            self.set_status(self._status)
            self.request_refresh()
            return

        if preview.has_errors:
            self._status = f"BLOCKED: {len(preview.unmapped_models)} unmapped model(s)"
            self.set_status(self._status)
            self.log(self._status, level="err")
            self.request_refresh()
            return

        self._phase = _Phase.APPLYING
        applied = 0

        for dev in preview.devices:
            if not dev.new_model:
                continue
            idx = dev.idx
            if dev.new_model != dev.model:
                self.push_command(f"set_instance_prop {idx} model {dev.new_model}")
            if dev.new_w and dev.new_w != dev.w:
                self.push_command(f"set_instance_prop {idx} W {dev.new_w}")
            if dev.new_l and dev.new_l != dev.l:
                self.push_command(f"set_instance_prop {idx} L {dev.new_l}")
            if dev.new_nf and dev.new_nf != dev.nf:
                self.push_command(f"set_instance_prop {idx} nf {dev.new_nf}")
            applied += 1

        src_key = BUILTIN_PDKS[self._src_idx]["key"]
        tgt_key = BUILTIN_PDKS[self._tgt_idx]["key"]
        self._status = f"Applied: {applied} device(s) remapped {src_key} -> {tgt_key}"
        self.set_status(self._status)
        self.log(self._status)

        self.push_command(f"load_pdk {tgt_key}")

        self._preview = None
        self._phase = _Phase.IDLE
        self.request_refresh()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

PDKSwitcherPlugin().run()
