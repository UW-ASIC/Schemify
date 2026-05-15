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
  6. Apply: update instance properties via set_instance_prop()

Vim command: :pdkswitch [source] [target]
             :pdkswitch list-pdks
             :pdkswitch install <pdk_key>
"""

from __future__ import annotations

import importlib.util as _ilu
import os
import re
import traceback
from dataclasses import dataclass, field
from typing import Any, Optional

# ---------------------------------------------------------------------------
# SDK bootstrap -- load tools/api/python/src/lib.py by path
# ---------------------------------------------------------------------------

_PLUGIN_SRC_DIR = os.path.dirname(os.path.abspath(__file__))
_SDK_CANDIDATES = [
    os.path.join(_PLUGIN_SRC_DIR, "schemify_sdk.py"),                           # installed
    os.path.normpath(
        os.path.join(_PLUGIN_SRC_DIR, "..", "..", "..", "tools", "api", "python", "src", "lib.py")
    ),                                                                           # source tree
]
_SDK_LIB = next((p for p in _SDK_CANDIDATES if os.path.isfile(p)), _SDK_CANDIDATES[-1])
_spec = _ilu.spec_from_file_location("schemify_plugin", _SDK_LIB)
schemify_plugin = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(schemify_plugin)  # type: ignore

Plugin = schemify_plugin.Plugin
Writer = schemify_plugin.Writer
Reader = schemify_plugin.Reader
Layout = schemify_plugin.Layout
_Tag = schemify_plugin._Tag

TAG = "PDKSwitcher"

# ---------------------------------------------------------------------------
# Widget ID allocation
# ---------------------------------------------------------------------------

# Source PDK buttons: 100..119
WID_SRC_BASE = 100
# Target PDK buttons: 120..139
WID_TGT_BASE = 120
# Options
WID_CB_USE_LUT = 200
# Actions
WID_REMAP = 300
WID_APPLY = 301
WID_REFRESH = 302
WID_INSTALL_BASE = 310  # install buttons per PDK: 310..319
# Preview table rows: 400..599
WID_PREVIEW_BASE = 400
# Mapping table rows: 600..699
WID_MAP_BASE = 600
# Error rows: 700..799
WID_ERR_BASE = 700
# Misc labels
WID_STATUS = 900
WID_PDK_STATUS = 901

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


def _scale_wl_in_line(line: str, vdd_ratio: float, lmin_ratio: float) -> str:
    """Scale W= and L= values in a line using VDD and Lmin ratios."""

    def scale_match(match: re.Match, scale: float) -> str:
        val_str = match.group(1)
        parsed = _parse_spice_value(val_str)
        if parsed is not None:
            new_val = parsed * scale
            return match.group(0).replace(val_str, _format_spice_value(new_val))
        return match.group(0)

    # Scale W values: W *= vdd_ratio * lmin_ratio
    line = re.sub(
        r'\bW\s*=\s*([^\s,]+)',
        lambda m: scale_match(m, vdd_ratio * lmin_ratio),
        line, flags=re.IGNORECASE,
    )
    # Scale L values: L *= lmin_ratio
    line = re.sub(
        r'\bL\s*=\s*([^\s,]+)',
        lambda m: scale_match(m, lmin_ratio),
        line, flags=re.IGNORECASE,
    )
    return line


# ---------------------------------------------------------------------------
# Plugin
# ---------------------------------------------------------------------------

class PDKSwitcherPlugin(Plugin):
    """PDK management and cross-PDK circuit remapping."""

    def __init__(self) -> None:
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
    # Override process() to handle tags the base class doesn't dispatch
    # ------------------------------------------------------------------

    def process(self, in_data: bytes) -> bytes:
        r = Reader(in_data)
        w = Writer()
        for msg in r:
            t = msg["tag"]
            if t == "load":
                self.on_load(w)
            elif t == "unload":
                self.on_unload(w)
            elif t == "tick":
                self.on_tick(msg["dt"], w)
            elif t == "draw_panel":
                self.on_draw_panel(msg["panel_id"], w)
            elif t == "button_clicked":
                self.on_button_clicked(msg["panel_id"], msg["widget_id"], w)
            elif t == "slider_changed":
                self.on_slider_changed(msg["panel_id"], msg["widget_id"], msg["val"], w)
            elif t == "checkbox_changed":
                self.on_checkbox_changed(msg["panel_id"], msg["widget_id"], msg["val"], w)
            elif t == "command":
                self.on_command(msg["cmd_tag"], msg["payload"], w)
            elif t == "state_response":
                self.on_state_response(msg["key"], msg["val"], w)
            elif t == "config_response":
                self._on_config_response(msg["key"], msg["val"], w)
            elif t == "selection_changed":
                self.on_selection_changed(msg["instance_idx"], w)
            elif t == "schematic_changed":
                self.on_schematic_changed(w)
            elif t == "schematic_snapshot":
                self._on_schematic_snapshot(
                    msg["instance_count"], msg["wire_count"], msg["net_count"], w
                )
            elif t == "instance_data":
                self.on_instance_data(msg["idx"], msg["name"], msg["symbol"], w)
            elif t == "instance_prop":
                self._on_instance_prop(msg["idx"], msg["key"], msg["val"], w)
            elif t == "hover":
                self.on_hover(
                    msg["world_x"], msg["world_y"], msg["element_type"],
                    msg["element_idx"], msg["element_name"], w
                )
            elif t == "key_event":
                self.on_key_event(msg["key"], msg["mods"], msg["action"], w)
        return w.get_bytes()

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def on_load(self, w: Writer) -> None:
        w.register_panel(
            "pdk-switch", "PDK Switcher", "pdkswitch", Layout.OVERLAY, 0
        )
        w.set_status("PDKSwitcher loaded")
        w.log(0, TAG, "PDKSwitcher plugin loaded (api=1)")

        self._discover_backends(w)

    def on_unload(self, w: Writer) -> None:
        w.log(0, TAG, "PDKSwitcher unloaded")

    # ------------------------------------------------------------------
    # Backend discovery
    # ------------------------------------------------------------------

    def _discover_backends(self, w: Writer) -> None:
        """Probe CIEL and LambdaPDK availability and merge discovered PDKs."""
        self._ciel_ok = _probe_ciel()
        self._lambdapdk_ok = _probe_lambdapdk()

        if self._ciel_ok:
            w.log(0, TAG, "CIEL backend available")
            ciel_pdks = _ciel_list_pdks()
            if ciel_pdks:
                _merge_external_pdks(ciel_pdks)
                w.log(0, TAG, f"CIEL: discovered {len(ciel_pdks)} PDK(s)")
        else:
            w.log(0, TAG, f"CIEL not available: {_CIEL_ERROR}")

        if self._lambdapdk_ok:
            w.log(0, TAG, "LambdaPDK backend available")
            lambda_pdks = _lambdapdk_list_pdks()
            if lambda_pdks:
                _merge_external_pdks(lambda_pdks)
                w.log(0, TAG, f"LambdaPDK: discovered {len(lambda_pdks)} PDK(s)")
        else:
            w.log(0, TAG, f"LambdaPDK not available: {_LAMBDAPDK_ERROR}")

        # Try to detect installed PDKs by checking common paths
        self._detect_installed_pdks(w)
        self._discovery_done = True

    def _detect_installed_pdks(self, w: Writer) -> None:
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
                    w.log(0, TAG, f"Found installed PDK: {key} at {pdk_path}")
                    break

    # ------------------------------------------------------------------
    # Drawing
    # ------------------------------------------------------------------

    def on_draw_panel(self, panel_id: int, w: Writer) -> None:
        w.label("PDK Switcher", 1)
        w.separator(2)

        # Backend status (compact)
        self._draw_backend_status(w)
        w.separator(8)

        self._draw_source_section(w)
        w.separator(19)
        self._draw_target_section(w)
        w.separator(39)
        self._draw_comparison(w)
        w.separator(49)
        self._draw_options(w)
        w.separator(59)
        self._draw_mapping_table(w)
        w.separator(69)
        self._draw_actions(w)
        w.separator(79)
        self._draw_errors(w)
        self._draw_preview(w)
        w.separator(89)

        w.label(f"Status: {self._status}", WID_STATUS)

    def _draw_backend_status(self, w: Writer) -> None:
        """Draw a compact status line showing CIEL/LambdaPDK availability."""
        ciel_str = "CIEL: available" if self._ciel_ok else "CIEL: not installed"
        lambda_str = "LambdaPDK: available" if self._lambdapdk_ok else "LambdaPDK: not installed"
        w.label(f"{ciel_str}  |  {lambda_str}", 3)

        installed_count = sum(1 for p in BUILTIN_PDKS if p.get("installed"))
        total_count = len(BUILTIN_PDKS)
        w.label(f"PDKs: {installed_count}/{total_count} installed", 4)

        if not self._ciel_ok and not self._lambdapdk_ok:
            w.collapsible_start("Install Instructions", False, 5)
            w.label("CIEL and LambdaPDK provide automated PDK management.", 6)
            w.label("Without them, manual PDK path setup is required.", 7)
            w.label("", 8)
            w.label("Install CIEL:", 9)
            w.label("  pip install ciel", 10)
            w.label("", 11)
            w.label("Install LambdaPDK:", 12)
            w.label("  pip install lambdapdk", 13)
            w.label("", 14)
            w.label("Or install both:", 15)
            w.label("  pip install ciel lambdapdk", 16)
            w.label("", 17)
            w.label("After installing, restart Schemify or use :pdkswitch refresh.", 18)
            w.collapsible_end(5)

    def _draw_source_section(self, w: Writer) -> None:
        w.label("Source PDK:", 20)
        w.tooltip("Auto-detected from schematic model names, or select manually.", 20)
        for i, pdk in enumerate(BUILTIN_PDKS):
            marker = "> " if i == self._src_idx else "  "
            installed = " [installed]" if pdk.get("installed") else ""
            source_tag = f" ({pdk['source']})" if pdk.get("source", "builtin") != "builtin" else ""
            w.button(
                f"{marker}{pdk['display']} ({pdk['vdd']}V){installed}{source_tag}",
                WID_SRC_BASE + i,
            )

    def _draw_target_section(self, w: Writer) -> None:
        w.label("Target PDK:", 30)
        for i, pdk in enumerate(BUILTIN_PDKS):
            if i == self._src_idx:
                continue
            marker = "> " if i == self._tgt_idx else "  "
            installed = " [installed]" if pdk.get("installed") else ""
            source_tag = f" ({pdk['source']})" if pdk.get("source", "builtin") != "builtin" else ""
            w.button(
                f"{marker}{pdk['display']} ({pdk['vdd']}V){installed}{source_tag}",
                WID_TGT_BASE + i,
            )

    def _draw_comparison(self, w: Writer) -> None:
        src = BUILTIN_PDKS[self._src_idx]
        tgt = BUILTIN_PDKS[self._tgt_idx]

        src_vdd = src["vdd"]
        tgt_vdd = tgt["vdd"]
        src_lmin = src["lmin_um"]
        tgt_lmin = tgt["lmin_um"]

        # Guard against zero division
        vdd_ratio = src_vdd / tgt_vdd if tgt_vdd != 0 else 0
        lmin_ratio = tgt_lmin / src_lmin if src_lmin != 0 else 0

        w.collapsible_start("PDK Comparison", True, 40)
        w.label(f"  VDD:     {src_vdd}V  ->  {tgt_vdd}V", 41)
        w.label(f"  L_min:   {src_lmin}um  ->  {tgt_lmin}um", 42)
        w.label(f"  VDD ratio:   {vdd_ratio:.2f}x", 43)
        w.label(f"  L_min ratio: {lmin_ratio:.2f}x", 44)
        w.collapsible_end(40)

    def _draw_options(self, w: Writer) -> None:
        lut_label = "Use gm/Id LUT (higher accuracy)"
        if self._use_lut and self._luts_available:
            lut_label += " -- LUTs loaded"
        elif self._use_lut:
            lut_label += " -- will use linear scaling if LUTs unavailable"
        w.checkbox(self._use_lut, lut_label, WID_CB_USE_LUT)

    def _draw_mapping_table(self, w: Writer) -> None:
        """Draw the model mapping table between source and target PDKs."""
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
            return

        w.collapsible_start("Model Mapping", True, WID_MAP_BASE)
        wid = WID_MAP_BASE + 1
        w.label(f"  {'Source (' + src_key + ')':<36s}  ->  Target ({tgt_key})", wid)
        wid += 1
        w.label("  " + "-" * 60, wid)
        wid += 1

        for generic in sorted(src_generics):
            src_model = src_generics[generic]
            if generic in tgt_generics:
                tgt_model = tgt_generics[generic]
                w.label(f"  {src_model:<36s}  ->  {tgt_model}", wid)
            else:
                w.label(f"  {src_model:<36s}  ->  [no mapping]", wid)
            wid += 1

        w.collapsible_end(WID_MAP_BASE)

    def _draw_actions(self, w: Writer) -> None:
        w.begin_row(70)
        w.button("Remap Schematic", WID_REMAP)
        w.button("Refresh PDKs", WID_REFRESH)
        w.end_row(70)

    def _draw_errors(self, w: Writer) -> None:
        """Draw errors section if any models are unmapped -- blocks apply."""
        preview = self._preview
        if preview is None:
            return
        if not preview.unmapped_models:
            return

        w.separator(WID_ERR_BASE)
        w.label("ERRORS -- cannot apply remap:", WID_ERR_BASE + 1)
        wid = WID_ERR_BASE + 2
        for model in preview.unmapped_models:
            w.label(f"  [ERROR] No target mapping for: {model}", wid)
            wid += 1
        w.label(
            f"  {len(preview.unmapped_models)} unmapped model(s) -- resolve before applying.",
            wid,
        )

    def _draw_preview(self, w: Writer) -> None:
        """Draw the before/after preview table and apply button."""
        preview = self._preview
        if preview is None:
            return

        devices = preview.devices
        if not devices:
            w.label("No MOSFETs found in schematic.", WID_PREVIEW_BASE)
            return

        mode_str = "gm/Id LUT" if preview.mode == "lut" else "linear scaling"
        w.collapsible_start(
            f"Preview ({len(devices)} devices, {mode_str})", True, WID_PREVIEW_BASE
        )

        wid = WID_PREVIEW_BASE + 1
        # Header
        w.label(
            f"  {'Instance':<14s} {'Model (src)':<32s} {'W':>8s} {'L':>8s} {'nf':>4s}"
            f"  ->  {'Model (tgt)':<32s} {'W':>8s} {'L':>8s} {'nf':>4s}",
            wid,
        )
        wid += 1
        w.label("  " + "-" * 120, wid)
        wid += 1

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

            w.label(
                f"  {dev.name:<14s} {dev.model:<32s} {src_w:>8s} {src_l:>8s} {src_nf:>4s}"
                f"  ->  {tgt_model:<32s} {tgt_w:>8s} {tgt_l:>8s} {tgt_nf:>4s}",
                wid,
            )
            wid += 1

        w.collapsible_end(WID_PREVIEW_BASE)

        # Warnings
        for warn in preview.warnings:
            w.label(f"  [warn] {warn}", wid)
            wid += 1

        # Apply button -- only if no unmapped errors
        if preview.has_errors:
            w.label(
                "Apply blocked: fix unmapped model errors above.",
                WID_APPLY,
            )
        else:
            w.button(
                f"Apply Remap ({len(devices)} devices)", WID_APPLY
            )

    # ------------------------------------------------------------------
    # Event handlers
    # ------------------------------------------------------------------

    def on_button_clicked(self, panel_id: int, widget_id: int, w: Writer) -> None:
        # Source PDK selection
        src_idx = widget_id - WID_SRC_BASE
        if 0 <= src_idx < len(BUILTIN_PDKS):
            self._src_idx = src_idx
            if self._tgt_idx == self._src_idx:
                self._tgt_idx = (self._src_idx + 1) % len(BUILTIN_PDKS)
            self._preview = None
            self._phase = _Phase.IDLE
            w.request_refresh()
            return

        # Target PDK selection
        tgt_idx = widget_id - WID_TGT_BASE
        if 0 <= tgt_idx < len(BUILTIN_PDKS):
            if tgt_idx != self._src_idx:
                self._tgt_idx = tgt_idx
                self._preview = None
                self._phase = _Phase.IDLE
            w.request_refresh()
            return

        if widget_id == WID_REMAP:
            self._start_remap(w)
            return

        if widget_id == WID_APPLY:
            self._apply_remap(w)
            return

        if widget_id == WID_REFRESH:
            self._refresh_pdks(w)
            w.request_refresh()
            return

        # PDK install buttons
        install_idx = widget_id - WID_INSTALL_BASE
        if 0 <= install_idx < len(BUILTIN_PDKS):
            pdk_key = BUILTIN_PDKS[install_idx]["key"]
            self._install_pdk(pdk_key, w)
            w.request_refresh()
            return

    def on_checkbox_changed(self, panel_id: int, widget_id: int, val: bool, w: Writer) -> None:
        if widget_id == WID_CB_USE_LUT:
            self._use_lut = val
            if self._preview is not None:
                self._preview = None
                self._phase = _Phase.IDLE
            w.request_refresh()

    def on_command(self, cmd_tag: str, payload: str, w: Writer) -> None:
        """Handle :pdkswitch [source] [target] vim command."""
        if cmd_tag != "pdkswitch":
            return

        parts = payload.strip().split()

        # --- Subcommands ---

        if parts and parts[0] == "list-pdks":
            lines = []
            for i, pdk in enumerate(BUILTIN_PDKS):
                installed = "[installed]" if pdk.get("installed") else "[not installed]"
                source = pdk.get("source", "builtin")
                marker = "*" if i == self._src_idx else " "
                lines.append(
                    f"{marker} {pdk['key']}: {pdk['display']} "
                    f"VDD={pdk['vdd']}V Lmin={pdk['lmin_um']}um "
                    f"{installed} ({source})"
                )
            self._status = " | ".join(lines)
            w.set_status(self._status)
            w.request_refresh()
            return

        if parts and parts[0] == "refresh":
            self._refresh_pdks(w)
            w.request_refresh()
            return

        if parts and parts[0] == "install":
            if len(parts) < 2:
                self._status = "Usage: :pdkswitch install <pdk_key>"
                w.set_status(self._status)
                w.request_refresh()
                return
            self._install_pdk(parts[1], w)
            w.request_refresh()
            return

        if parts and parts[0] == "add-pdk":
            arg = " ".join(parts[1:])
            add_parts = arg.split()
            if len(add_parts) < 4:
                self._status = "Usage: :pdkswitch add-pdk <key> <display> <vdd> <lmin_um>"
                w.set_status(self._status)
                w.request_refresh()
                return
            key = add_parts[0]
            display = add_parts[1]
            try:
                vdd = float(add_parts[2])
                lmin = float(add_parts[3])
            except ValueError:
                self._status = "Error: vdd and lmin_um must be numbers"
                w.set_status(self._status)
                w.request_refresh()
                return
            if _pdk_index(key) is not None:
                self._status = f"PDK {key} already exists"
                w.set_status(self._status)
                w.request_refresh()
                return
            BUILTIN_PDKS.append({
                "key": key, "display": display, "vdd": vdd, "lmin_um": lmin,
                "source": "user", "installed": False,
            })
            self._status = f"Added PDK: {key} ({display}) VDD={vdd}V Lmin={lmin}um"
            w.set_status(self._status)
            w.log(0, TAG, self._status)
            w.request_refresh()
            return

        # :pdkswitch <source> <target>
        if len(parts) >= 2:
            src_name, tgt_name = parts[0], parts[1]
            src_i = _pdk_index(src_name)
            tgt_i = _pdk_index(tgt_name)
            if src_i is None:
                self._status = f"Unknown source PDK: {src_name}"
                w.set_status(self._status)
                w.request_refresh()
                return
            if tgt_i is None:
                self._status = f"Unknown target PDK: {tgt_name}"
                w.set_status(self._status)
                w.request_refresh()
                return
            if src_i == tgt_i:
                self._status = "Source and target PDK cannot be the same"
                w.set_status(self._status)
                w.request_refresh()
                return
            self._src_idx = src_i
            self._tgt_idx = tgt_i
            self._preview = None
            self._start_remap(w)
            return

        # :pdkswitch <target>
        if len(parts) == 1:
            tgt_name = parts[0]
            tgt_i = _pdk_index(tgt_name)
            if tgt_i is None:
                self._status = f"Unknown target PDK: {tgt_name}"
                w.set_status(self._status)
                w.request_refresh()
                return
            if tgt_i == self._src_idx:
                self._status = "Target cannot be the same as source"
                w.set_status(self._status)
                w.request_refresh()
                return
            self._tgt_idx = tgt_i
            self._preview = None
            self._start_remap(w)
            return

        # No args: start remap with current selections
        self._start_remap(w)

    def on_schematic_changed(self, w: Writer) -> None:
        """Schematic changed externally -- invalidate everything."""
        self._instances.clear()
        self._preview = None
        self._phase = _Phase.IDLE
        self._status = "Schematic changed -- re-remap needed"

    def on_instance_data(self, idx: int, name: str, symbol: str, w: Writer) -> None:
        """Receive instance data from query_instances(). Collect MOSFETs."""
        if self._phase != _Phase.QUERYING:
            return
        if symbol in _MOSFET_SYMBOLS:
            self._instances[idx] = InstanceInfo(idx=idx, name=name, symbol=symbol)

    def _on_schematic_snapshot(self, instance_count: int, wire_count: int,
                               net_count: int, w: Writer) -> None:
        """Received after query_instances(), before instance_data messages."""
        if self._phase == _Phase.QUERYING:
            self._instance_count = instance_count

    def _on_instance_prop(self, idx: int, key: str, val: str, w: Writer) -> None:
        """Receive property for an instance we're tracking."""
        if self._phase != _Phase.COLLECTING_PROPS:
            return

        inst = self._instances.get(idx)
        if inst is None:
            return

        if key == "model":
            inst.model = val
        elif key in ("W", "w"):
            inst.w = val
        elif key in ("L", "l"):
            inst.l = val
        elif key in ("nf", "NF", "mult"):
            inst.nf = val

        self._pending_props -= 1

        # When all properties collected, compute remap preview
        if self._pending_props <= 0:
            self._compute_preview(w)

    def _on_config_response(self, key: str, val: str, w: Writer) -> None:
        """Handle config responses."""
        pass

    # ------------------------------------------------------------------
    # PDK management
    # ------------------------------------------------------------------

    def _refresh_pdks(self, w: Writer) -> None:
        """Re-probe backends and re-scan installed PDKs."""
        self._discover_backends(w)
        installed_count = sum(1 for p in BUILTIN_PDKS if p.get("installed"))
        self._status = f"Refreshed: {len(BUILTIN_PDKS)} PDK(s) known, {installed_count} installed"
        w.set_status(self._status)

    def _install_pdk(self, pdk_key: str, w: Writer) -> None:
        """Install a PDK via CIEL."""
        success, message = _ciel_install_pdk(pdk_key)
        if success:
            self._status = message
            w.log(0, TAG, message)
            # Re-detect installed PDKs
            self._detect_installed_pdks(w)
        else:
            self._status = message
            w.log(2, TAG, message)
        w.set_status(self._status)

    # ------------------------------------------------------------------
    # Remap logic
    # ------------------------------------------------------------------

    def _start_remap(self, w: Writer) -> None:
        """Begin remap: query all instances from the schematic."""
        self._instances.clear()
        self._preview = None
        self._phase = _Phase.QUERYING
        self._status = "Querying schematic instances..."
        w.query_instances()
        w.set_status(self._status)
        w.request_refresh()

    def _compute_preview(self, w: Writer) -> None:
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

        w.set_status(self._status)
        w.log(0, TAG, self._status)
        w.request_refresh()

    def _apply_remap(self, w: Writer) -> None:
        """Apply the computed remap to the schematic."""
        preview = self._preview
        if preview is None:
            self._status = "No remap preview -- run Remap first"
            w.set_status(self._status)
            w.request_refresh()
            return

        # BLOCK if any unmapped models
        if preview.has_errors:
            self._status = (
                f"BLOCKED: {len(preview.unmapped_models)} unmapped model(s). "
                "Cannot apply remap with unmapped devices."
            )
            w.set_status(self._status)
            w.log(2, TAG, self._status)
            w.request_refresh()
            return

        self._phase = _Phase.APPLYING
        applied = 0

        for dev in preview.devices:
            if not dev.new_model:
                continue

            idx = dev.idx

            if dev.new_model != dev.model:
                w.set_instance_prop(idx, "model", dev.new_model)
            if dev.new_w and dev.new_w != dev.w:
                w.set_instance_prop(idx, "W", dev.new_w)
            if dev.new_l and dev.new_l != dev.l:
                w.set_instance_prop(idx, "L", dev.new_l)
            if dev.new_nf and dev.new_nf != dev.nf:
                w.set_instance_prop(idx, "nf", dev.new_nf)

            applied += 1

        src_key = BUILTIN_PDKS[self._src_idx]["key"]
        tgt_key = BUILTIN_PDKS[self._tgt_idx]["key"]
        self._status = (
            f"Applied: {applied} device(s) remapped from {src_key} to {tgt_key}"
        )
        w.set_status(self._status)
        w.log(0, TAG, self._status)

        # Set the global PDK to the target
        w.set_state("current_pdk", tgt_key)
        w.log(0, TAG, f"Global PDK set to: {tgt_key}")

        self._preview = None
        self._phase = _Phase.IDLE
        w.request_refresh()


# ---------------------------------------------------------------------------
# Module-level plugin instance + ABI entry point
# ---------------------------------------------------------------------------

_plugin = PDKSwitcherPlugin()


def schemify_process(in_bytes: bytes) -> bytes:
    return _plugin.process(in_bytes)
