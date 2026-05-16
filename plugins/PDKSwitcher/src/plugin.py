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
  1. Detect installed PDKs via CIEL / LambdaPDK
  2. Auto-detect source PDK from model names in the schematic
  3. Select target PDK
  4. Preview remap: model mapping table, before/after W/L/nf
  5. BLOCK apply if any model has no mapping (hard error)
  6. Apply: update instance properties via push_command()

Vim command: :pdkswitch [source] [target]
             :pdkswitch list-pdks
             :pdkswitch install <pdk_key>
"""

from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass, field
from typing import Any, Optional

# Add the SDK directory to sys.path so schemify_plugin is importable.
# The SDK lives at <repo>/sdk/python/schemify_plugin.py; this file lives at
# <repo>/plugins/PDKSwitcher/src/plugin.py.
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_SDK_DIR = os.path.normpath(os.path.join(_THIS_DIR, "..", "..", "..", "sdk", "python"))
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
)

TAG = "PDKSwitcher"

# ---------------------------------------------------------------------------
# Widget ID allocation (string-based for JSON-RPC protocol)
# ---------------------------------------------------------------------------

# Source PDK buttons: src_<index>
# Target PDK buttons: tgt_<index>
# Options
WID_CB_USE_LUT = "cb_use_lut"
# Actions
WID_REMAP = "remap"
WID_APPLY = "apply"
WID_REFRESH = "refresh"
# Install buttons: install_<index>

# ---------------------------------------------------------------------------
# CIEL / LambdaPDK integration layer
#
# We embed the PDK discovery and management logic directly rather than
# depending on external CLI tools.  All imports are lazy so the plugin
# degrades gracefully if the libraries are not installed.
# ---------------------------------------------------------------------------

_CIEL_AVAILABLE: bool = False
_LAMBDAPDK_AVAILABLE: bool = False
_CIEL_ERROR: str = ""
_LAMBDAPDK_ERROR: str = ""


def _probe_ciel() -> bool:
    """Check whether the CIEL Python package is importable."""
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
    """Check whether the LambdaPDK Python package is importable."""
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


def _ciel_list_pdks() -> list[dict[str, Any]]:
    """Query CIEL for available PDK information.

    Returns a list of dicts with keys: key, display, vdd, lmin_um, source.
    Falls back to empty list if CIEL is unavailable.
    """
    if not _CIEL_AVAILABLE:
        return []
    try:
        import ciel
        pdks = []
        # CIEL exposes PDK metadata through its registry
        if hasattr(ciel, "list_pdks"):
            for pdk_info in ciel.list_pdks():
                key = pdk_info.get("name", pdk_info.get("id", ""))
                pdks.append({
                    "key": key,
                    "display": pdk_info.get("display_name", key),
                    "vdd": pdk_info.get("vdd", 0.0),
                    "lmin_um": pdk_info.get("lmin", 0.0) * 1e6 if pdk_info.get("lmin", 0) < 1 else pdk_info.get("lmin", 0.0),
                    "source": "ciel",
                    "installed": pdk_info.get("installed", False),
                })
        elif hasattr(ciel, "Registry"):
            reg = ciel.Registry()
            for name in reg.available():
                meta = reg.metadata(name)
                pdks.append({
                    "key": name,
                    "display": meta.get("display_name", name),
                    "vdd": meta.get("nominal_vdd", 0.0),
                    "lmin_um": meta.get("min_length_um", 0.0),
                    "source": "ciel",
                    "installed": meta.get("installed", False),
                })
        return pdks
    except Exception:
        return []


def _lambdapdk_list_pdks() -> list[dict[str, Any]]:
    """Query LambdaPDK for available PDK information.

    LambdaPDK provides technology-independent (lambda-based) PDKs.
    Returns a list of dicts matching our standard PDK format.
    """
    if not _LAMBDAPDK_AVAILABLE:
        return []
    try:
        import lambdapdk
        pdks = []
        # LambdaPDK organizes PDKs under lambdapdk.asap7, lambdapdk.sky130, etc.
        known_lambdapdk_modules = ["sky130", "gf180", "asap7", "freepdk45"]
        for mod_name in known_lambdapdk_modules:
            try:
                mod = getattr(lambdapdk, mod_name, None)
                if mod is None:
                    mod = __import__(f"lambdapdk.{mod_name}", fromlist=[mod_name])
                if mod is not None:
                    # Extract metadata from the module
                    pdk_key = f"lambdapdk-{mod_name}"
                    display = getattr(mod, "DISPLAY_NAME", mod_name.upper())
                    vdd = getattr(mod, "VDD", 0.0)
                    lmin = getattr(mod, "LMIN", 0.0)
                    pdks.append({
                        "key": pdk_key,
                        "display": f"LambdaPDK {display}",
                        "vdd": vdd,
                        "lmin_um": lmin * 1e6 if lmin < 1e-3 else lmin,
                        "source": "lambdapdk",
                        "installed": True,  # if importable, it's installed
                    })
            except (ImportError, AttributeError):
                continue
        return pdks
    except Exception:
        return []


def _ciel_install_pdk(pdk_key: str) -> tuple[bool, str]:
    """Attempt to install a PDK through CIEL.

    Returns (success, message).
    """
    if not _CIEL_AVAILABLE:
        return False, "CIEL is not installed. Run: pip install ciel"
    try:
        import ciel
        if hasattr(ciel, "install"):
            ciel.install(pdk_key)
            return True, f"PDK '{pdk_key}' installed successfully via CIEL"
        elif hasattr(ciel, "Registry"):
            reg = ciel.Registry()
            reg.install(pdk_key)
            return True, f"PDK '{pdk_key}' installed successfully via CIEL"
        return False, "CIEL does not support install() in this version"
    except Exception as exc:
        return False, f"Installation failed: {exc}"


# ---------------------------------------------------------------------------
# Built-in PDK database (always available, even without CIEL/LambdaPDK)
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
#
# All known MOSFET model names -> (pdk_key, generic_name).
# Used for auto-detection of source PDK from schematic contents and for
# computing remap tables between PDKs.
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

# Schematic symbols representing MOSFETs.
_MOSFET_SYMBOLS = frozenset({"nmos4", "pmos4", "nmos", "pmos"})


# ---------------------------------------------------------------------------
# Passive / misc device mapping across PDKs
# ---------------------------------------------------------------------------

_PASSIVE_MODEL_TO_PDK: dict[str, tuple[str, str]] = {
    # SKY130 resistors/caps
    "sky130_fd_pr__res_generic_nd": ("sky130A", "res_nd"),
    "sky130_fd_pr__res_generic_pd": ("sky130A", "res_pd"),
    "sky130_fd_pr__cap_mim_m3_1":  ("sky130A", "cap_mim"),
    # GF180MCU
    "res_nd":  ("gf180mcuA", "res_nd"),
    "res_pd":  ("gf180mcuA", "res_pd"),
    "cap_mim": ("gf180mcuA", "cap_mim"),
}


def _pdk_index(key: str) -> Optional[int]:
    """Return BUILTIN_PDKS index for a given PDK key, or None."""
    for i, p in enumerate(BUILTIN_PDKS):
        if p["key"] == key:
            return i
    return None


def _merge_external_pdks(external: list[dict[str, Any]]) -> None:
    """Merge externally-discovered PDKs into BUILTIN_PDKS if not already present."""
    existing_keys = {p["key"] for p in BUILTIN_PDKS}
    for ext in external:
        if ext["key"] not in existing_keys:
            BUILTIN_PDKS.append(ext)
            existing_keys.add(ext["key"])
        else:
            # Update installed status and source from external discovery
            idx = _pdk_index(ext["key"])
            if idx is not None:
                BUILTIN_PDKS[idx]["installed"] = ext.get("installed", False)
                if ext.get("source"):
                    BUILTIN_PDKS[idx]["source"] = ext["source"]


# ---------------------------------------------------------------------------
# Data structures for remap state
# ---------------------------------------------------------------------------

@dataclass
class InstanceInfo:
    """Collected info about a single MOSFET instance in the schematic."""
    idx: int
    name: str
    symbol: str
    model: str = ""
    w: str = ""
    l: str = ""
    nf: str = ""
    # Filled after remap:
    new_model: str = ""
    new_w: str = ""
    new_l: str = ""
    new_nf: str = ""


@dataclass
class RemapPreview:
    """Full remap preview result."""
    devices: list[InstanceInfo] = field(default_factory=list)
    unmapped_models: list[str] = field(default_factory=list)
    mapping_table: list[tuple[str, str]] = field(default_factory=list)
    mode: str = "linear"  # "lut" or "linear"
    warnings: list[str] = field(default_factory=list)
    has_errors: bool = False


# ---------------------------------------------------------------------------
# State machine phases
# ---------------------------------------------------------------------------

class _Phase:
    IDLE = "idle"
    QUERYING = "querying"            # waiting for instance_data messages
    COLLECTING_PROPS = "collecting"  # waiting for instance_prop messages
    PREVIEW_READY = "preview"        # preview computed, waiting for user
    APPLYING = "applying"            # writing properties back


# ---------------------------------------------------------------------------
# SPICE value parsing / formatting
# ---------------------------------------------------------------------------

def _parse_spice_value(s: str) -> Optional[float]:
    """Parse a SPICE value string like '2u', '0.15e-6', '280n' to float (SI)."""
    if not s:
        return None
    s = s.strip()
    multipliers = {
        "T": 1e12, "G": 1e9, "MEG": 1e6, "M": 1e6, "k": 1e3, "K": 1e3,
        "m": 1e-3, "u": 1e-6, "n": 1e-9, "p": 1e-12, "f": 1e-15, "a": 1e-18,
    }
    # Try direct float first
    try:
        return float(s)
    except ValueError:
        pass

    # Try suffix-based (longest suffix first to match MEG before M)
    for suffix, mult in sorted(multipliers.items(), key=lambda x: -len(x[0])):
        if s.lower().endswith(suffix.lower()):
            num_part = s[: -len(suffix)]
            try:
                return float(num_part) * mult
            except ValueError:
                continue

    # Try with trailing 'm' for meters
    if s.endswith("m"):
        try:
            return float(s[:-1]) * 1e-3
        except ValueError:
            pass

    return None


def _format_spice_value(val: float) -> str:
    """Format a float to a human-readable SPICE string with SI suffix."""
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


def _get_mapped_models(src_key: str, tgt_key: str) -> dict[str, str]:
    """Build source_model -> target_model map for two PDKs via generic keys.

    Returns only models that have a valid mapping. Models absent from the
    returned dict have NO mapping and must be treated as errors.
    """
    src_rev: dict[str, str] = {}  # model -> generic
    tgt_map: dict[str, str] = {}  # generic -> model

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
    """PDK management and cross-PDK circuit remapping."""

    def __init__(self) -> None:
        super().__init__()
        self._src_idx: int = 0
        self._tgt_idx: int = 1
        self._use_lut: bool = False
        self._luts_available: bool = False

        self._phase: str = _Phase.IDLE
        self._status: str = "Ready"

        # Instance collection during QUERYING / COLLECTING_PROPS
        self._instance_count: int = 0
        self._instances: dict[int, InstanceInfo] = {}
        self._pending_props: int = 0

        # Remap results
        self._preview: Optional[RemapPreview] = None

        # Library availability
        self._ciel_ok: bool = False
        self._lambdapdk_ok: bool = False
        self._discovery_done: bool = False

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def on_load(self) -> None:
        self.register_panel("pdk-switch", "PDK Switcher", "overlay")
        self.set_status("PDKSwitcher loaded")
        self.log("PDKSwitcher plugin loaded (api=1)")

        self._discover_backends()

    def on_unload(self) -> None:
        self.log("PDKSwitcher unloaded")

    # ------------------------------------------------------------------
    # Backend discovery
    # ------------------------------------------------------------------

    def _discover_backends(self) -> None:
        """Probe CIEL and LambdaPDK availability and merge discovered PDKs."""
        self._ciel_ok = _probe_ciel()
        self._lambdapdk_ok = _probe_lambdapdk()

        if self._ciel_ok:
            self.log("CIEL backend available")
            ciel_pdks = _ciel_list_pdks()
            if ciel_pdks:
                _merge_external_pdks(ciel_pdks)
                self.log(f"CIEL: discovered {len(ciel_pdks)} PDK(s)")
        else:
            self.log(f"CIEL not available: {_CIEL_ERROR}")

        if self._lambdapdk_ok:
            self.log("LambdaPDK backend available")
            lambda_pdks = _lambdapdk_list_pdks()
            if lambda_pdks:
                _merge_external_pdks(lambda_pdks)
                self.log(f"LambdaPDK: discovered {len(lambda_pdks)} PDK(s)")
        else:
            self.log(f"LambdaPDK not available: {_LAMBDAPDK_ERROR}")

        # Try to detect installed PDKs by checking common paths
        self._detect_installed_pdks()
        self._discovery_done = True

    def _detect_installed_pdks(self) -> None:
        """Detect locally installed PDKs by checking standard paths."""
        pdk_root = os.environ.get("PDK_ROOT", "")
        if not pdk_root:
            # Check common locations
            home = os.environ.get("HOME", os.path.expanduser("~"))
            candidates = [
                os.path.join(home, ".volare"),
                os.path.join(home, ".local", "share", "pdk"),
                "/usr/local/share/pdk",
                "/opt/pdk",
            ]
            for c in candidates:
                if os.path.isdir(c):
                    pdk_root = c
                    break

        if not pdk_root or not os.path.isdir(pdk_root):
            return

        # Check which built-in PDKs have directories under PDK_ROOT
        pdk_key_to_dirs = {
            "sky130A":     ["sky130A", "sky130"],
            "ihp-sg13g2":  ["ihp-sg13g2", "sg13g2", "IHP-Open-PDK"],
            "gf180mcuA":   ["gf180mcuA", "gf180mcu", "gf180mcuC", "gf180mcuD"],
        }

        for pdk_info in BUILTIN_PDKS:
            key = pdk_info["key"]
            dirs_to_check = pdk_key_to_dirs.get(key, [key])
            for dirname in dirs_to_check:
                pdk_path = os.path.join(pdk_root, dirname)
                if os.path.isdir(pdk_path):
                    pdk_info["installed"] = True
                    self.log(f"Found installed PDK: {key} at {pdk_path}")
                    break

    # ------------------------------------------------------------------
    # Drawing
    # ------------------------------------------------------------------

    def on_draw_panel(self, panel_id: str) -> list[Widget]:
        widgets: list[Widget] = []

        widgets.append(label("PDK Switcher"))
        widgets.append(separator())

        # Backend status (compact)
        widgets.extend(self._build_backend_status())
        widgets.append(separator())

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
        widgets.append(separator())
        widgets.extend(self._build_errors())
        widgets.extend(self._build_preview())
        widgets.append(separator())

        widgets.append(label(f"Status: {self._status}", widget_id="status"))

        return widgets

    def _build_backend_status(self) -> list[Widget]:
        """Build compact status showing CIEL/LambdaPDK availability."""
        widgets: list[Widget] = []
        ciel_str = "CIEL: available" if self._ciel_ok else "CIEL: not installed"
        lambda_str = "LambdaPDK: available" if self._lambdapdk_ok else "LambdaPDK: not installed"
        widgets.append(label(f"{ciel_str}  |  {lambda_str}"))

        installed_count = sum(1 for p in BUILTIN_PDKS if p.get("installed"))
        total_count = len(BUILTIN_PDKS)
        widgets.append(label(f"PDKs: {installed_count}/{total_count} installed"))

        if not self._ciel_ok and not self._lambdapdk_ok:
            widgets.append(collapsible_start("Install Instructions", "install_info"))
            widgets.append(label("CIEL and LambdaPDK provide automated PDK management."))
            widgets.append(label("Without them, manual PDK path setup is required."))
            widgets.append(label(""))
            widgets.append(label("Install CIEL:"))
            widgets.append(label("  pip install ciel"))
            widgets.append(label(""))
            widgets.append(label("Install LambdaPDK:"))
            widgets.append(label("  pip install lambdapdk"))
            widgets.append(label(""))
            widgets.append(label("Or install both:"))
            widgets.append(label("  pip install ciel lambdapdk"))
            widgets.append(label(""))
            widgets.append(label("After installing, restart Schemify or use :pdkswitch refresh."))
            widgets.append(collapsible_end())

        return widgets

    def _build_source_section(self) -> list[Widget]:
        widgets: list[Widget] = []
        widgets.append(label("Source PDK:"))
        widgets.append(tooltip("Auto-detected from schematic model names, or select manually."))
        for i, pdk in enumerate(BUILTIN_PDKS):
            marker = "> " if i == self._src_idx else "  "
            installed = " [installed]" if pdk.get("installed") else ""
            source_tag = f" ({pdk['source']})" if pdk.get("source", "builtin") != "builtin" else ""
            widgets.append(button(
                f"{marker}{pdk['display']} ({pdk['vdd']}V){installed}{source_tag}",
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
            source_tag = f" ({pdk['source']})" if pdk.get("source", "builtin") != "builtin" else ""
            widgets.append(button(
                f"{marker}{pdk['display']} ({pdk['vdd']}V){installed}{source_tag}",
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

        # Guard against zero division
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
        """Build the model mapping table between source and target PDKs."""
        widgets: list[Widget] = []
        src_key = BUILTIN_PDKS[self._src_idx]["key"]
        tgt_key = BUILTIN_PDKS[self._tgt_idx]["key"]

        # Build mapping from known models
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
        """Build errors section if any models are unmapped -- blocks apply."""
        widgets: list[Widget] = []
        preview = self._preview
        if preview is None:
            return widgets
        if not preview.unmapped_models:
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
        """Build the before/after preview table and apply button."""
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

        # Header
        widgets.append(label(
            f"  {'Instance':<14s} {'Model (src)':<32s} {'W':>8s} {'L':>8s} {'nf':>4s}"
            f"  ->  {'Model (tgt)':<32s} {'W':>8s} {'L':>8s} {'nf':>4s}"
        ))
        widgets.append(label("  " + "-" * 120))

        for dev in devices:
            src_w = dev.w if dev.w else "?"
            src_l = dev.l if dev.l else "?"
            src_nf = dev.nf if dev.nf else "1"

            if dev.new_model:
                tgt_model = dev.new_model
                tgt_w = dev.new_w if dev.new_w else "?"
                tgt_l = dev.new_l if dev.new_l else "?"
                tgt_nf = dev.new_nf if dev.new_nf else src_nf

                # Mark unmapped with ERROR
                if tgt_model == dev.model and dev.model not in _get_mapped_models(
                    BUILTIN_PDKS[self._src_idx]["key"],
                    BUILTIN_PDKS[self._tgt_idx]["key"],
                ):
                    tgt_model = f"ERROR: {dev.model}"
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

        # Warnings
        for warn in preview.warnings:
            widgets.append(label(f"  [warn] {warn}"))

        # Apply button -- only if no unmapped errors
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
        # Source PDK selection: "src_0", "src_1", ...
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

        # Target PDK selection: "tgt_0", "tgt_1", ...
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
            self._refresh_pdks()
            self.request_refresh()
            return

        # PDK install buttons: "install_0", "install_1", ...
        if widget_id.startswith("install_"):
            try:
                install_idx = int(widget_id[8:])
            except ValueError:
                return
            if 0 <= install_idx < len(BUILTIN_PDKS):
                pdk_key = BUILTIN_PDKS[install_idx]["key"]
                self._install_pdk(pdk_key)
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
    # PDK management
    # ------------------------------------------------------------------

    def _refresh_pdks(self) -> None:
        """Re-probe backends and re-scan installed PDKs."""
        self._discover_backends()
        installed_count = sum(1 for p in BUILTIN_PDKS if p.get("installed"))
        self._status = f"Refreshed: {len(BUILTIN_PDKS)} PDK(s) known, {installed_count} installed"
        self.set_status(self._status)

    def _install_pdk(self, pdk_key: str) -> None:
        """Install a PDK via CIEL."""
        success, message = _ciel_install_pdk(pdk_key)
        if success:
            self._status = message
            self.log(message)
            # Re-detect installed PDKs
            self._detect_installed_pdks()
        else:
            self._status = message
            self.log(message, level="err")
        self.set_status(self._status)

    # ------------------------------------------------------------------
    # Remap logic
    # ------------------------------------------------------------------

    def _start_remap(self) -> None:
        """Begin remap: query all instances from the schematic."""
        self._instances.clear()
        self._preview = None
        self._phase = _Phase.QUERYING
        self._status = "Querying schematic instances..."
        self.push_command("query_instances")
        self.set_status(self._status)
        self.request_refresh()

    def _compute_preview(self) -> None:
        """Compute the full remap preview after all instance data is collected."""
        src_key = BUILTIN_PDKS[self._src_idx]["key"]
        tgt_key = BUILTIN_PDKS[self._tgt_idx]["key"]

        preview = RemapPreview()

        # Auto-detect source PDK from model names if instances have models
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
                    f"Auto-detected source PDK: {src_key} "
                    f"({detected_pdks[best_pdk]} device(s))"
                )

        # Build the model mapping table
        mapped_src_to_tgt = _get_mapped_models(src_key, tgt_key)

        # Build generic-name mapping for display
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
                # Model has no mapping to target PDK -- ERROR
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

            # Parse numeric values
            w_val = _parse_spice_value(inst.w)
            l_val = _parse_spice_value(inst.l)
            nf_val = int(inst.nf) if inst.nf and inst.nf.isdigit() else 1

            # Linear scaling fallback (always available)
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
                preview.warnings.append(
                    f"{inst.name}: could not parse W/L, model remapped only"
                )

            preview.devices.append(inst)

        self._preview = preview
        self._phase = _Phase.PREVIEW_READY

        n = len(preview.devices)
        n_err = len(preview.unmapped_models)
        if n_err > 0:
            self._status = (
                f"Preview ready: {n} device(s), "
                f"{n_err} UNMAPPED model(s) -- cannot apply"
            )
        else:
            self._status = f"Preview ready: {n} device(s), {preview.mode} mode"

        self.set_status(self._status)
        self.log(self._status)
        self.request_refresh()

    def _apply_remap(self) -> None:
        """Apply the computed remap to the schematic."""
        preview = self._preview
        if preview is None:
            self._status = "No remap preview -- run Remap first"
            self.set_status(self._status)
            self.request_refresh()
            return

        # BLOCK if any unmapped models
        if preview.has_errors:
            self._status = (
                f"BLOCKED: {len(preview.unmapped_models)} unmapped model(s). "
                "Cannot apply remap with unmapped devices."
            )
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
        self._status = (
            f"Applied: {applied} device(s) remapped from {src_key} to {tgt_key}"
        )
        self.set_status(self._status)
        self.log(self._status)

        # Set the global PDK to the target
        self.push_command(f"set_state current_pdk {tgt_key}")
        self.log(f"Global PDK set to: {tgt_key}")

        self._preview = None
        self._phase = _Phase.IDLE
        self.request_refresh()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

PDKSwitcherPlugin().run()
