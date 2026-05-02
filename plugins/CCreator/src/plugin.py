"""Schemify CCreator plugin — bidirectional .chn <-> Python circuit generator.

Features:
  - Embed: Write Python generator code into the .chn PLUGIN CCreator block
  - Sync:  Read PLUGIN CCreator block and regenerate schematic from Python
  - Export: Convert current .chn schematic to a CCreator Python generator class
  - Import: Convert a CCreator Python generator to schematic components via SPICE
  - Library: Browse built-in CCreator circuit templates and import them

Panel: LEFT_SIDEBAR, vim_cmd "ccreator"
Commands:
  :ccreator embed               — embed Python generator into .chn PLUGIN block
  :ccreator sync                — regenerate schematic from embedded PLUGIN block
  :ccreator export [path]       — export current schematic as Python generator
  :ccreator import <path>       — import a CCreator Python file into schematic
  :ccreator template <name>     — import a built-in template by class name
"""

from __future__ import annotations

import importlib.util as _ilu
import importlib
import inspect
import json
import os
import sys
import textwrap
import traceback
from pathlib import Path
from typing import Any, Optional

# ---------------------------------------------------------------------------
# SDK path resolution (same pattern as Themes plugin)
# ---------------------------------------------------------------------------
_PLUGIN_SRC_DIR = os.path.dirname(os.path.abspath(__file__))
_SDK_LIB = os.path.normpath(
    os.path.join(_PLUGIN_SRC_DIR, "..", "..", "..", "tools", "api", "python", "src", "lib.py")
)
_spec = _ilu.spec_from_file_location("schemify_plugin", _SDK_LIB)
schemify_plugin = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(schemify_plugin)  # type: ignore

TAG = "CCreator"

# ---------------------------------------------------------------------------
# Ensure ccreator and spice2schematic packages are importable
# ---------------------------------------------------------------------------
_CCREATOR_PKG = os.path.normpath(os.path.join(_PLUGIN_SRC_DIR))
_SPICE2SCHEM_PKG = os.path.normpath(
    os.path.join(_PLUGIN_SRC_DIR, "..", "..", "SpiceImport", "src")
)
for _p in (_CCREATOR_PKG, _SPICE2SCHEM_PKG):
    if _p not in sys.path:
        sys.path.insert(0, _p)


# ---------------------------------------------------------------------------
# Circuit categories and template registry
# ---------------------------------------------------------------------------
CATEGORIES = [
    ("ADC", [
        ("IdealADC", "behavioral"),
        ("ResistiveADCFrontend", "realistic"),
        ("RCADCFrontend", "realistic"),
    ]),
    ("DAC", [
        ("IdealDAC", "behavioral"),
        ("RCReconstructionFilter", "realistic"),
        ("SecondOrderReconstructionFilter", "realistic"),
    ]),
    ("PLL", [
        ("IdealPLL", "behavioral"),
        ("CPPLLLoopFilter", "realistic"),
        ("ThirdOrderLoopFilter", "realistic"),
    ]),
    ("Bandgap", [
        ("IdealBandgap", "behavioral"),
        ("ResistiveDividerRef", "realistic"),
        ("FilteredDividerRef", "realistic"),
    ]),
    ("Oscillator", [
        ("IdealResonator", "behavioral"),
        ("LCTank", "realistic"),
        ("RCOscillatorStage", "realistic"),
    ]),
    ("Switch", [
        ("IdealSwitch", "behavioral"),
        ("ResistiveSwitch", "realistic"),
        ("TransmissionGate", "realistic"),
    ]),
]

# Flat map: class_name -> (category, kind)
_TEMPLATE_MAP: dict[str, tuple[str, str]] = {}
for _cat, _entries in CATEGORIES:
    for _name, _kind in _entries:
        _TEMPLATE_MAP[_name] = (_cat, _kind)

# Testbenches per category
TESTBENCHES: dict[str, list[str]] = {
    "ADC":        ["Static", "Dynamic", "Bandwidth"],
    "DAC":        ["Static", "Dynamic", "Filter"],
    "PLL":        ["LoopFilter", "Lock", "Jitter", "PhaseNoise"],
    "Bandgap":    ["PSRR", "LineReg", "LoadReg", "Transient", "Noise"],
    "Oscillator": ["AC", "Frequency", "Jitter", "PhaseNoise", "Startup", "THD"],
    "Switch":     ["Ron", "Isolation", "Bandwidth", "Transient", "Distortion"],
}


# ---------------------------------------------------------------------------
# Widget ID allocation
# ---------------------------------------------------------------------------

# Tab buttons
WID_TAB_EXPORT  = 1
WID_TAB_IMPORT  = 2
WID_TAB_LIBRARY = 3
WID_TAB_CODE    = 4

# Export tab
WID_EXPORT_INFO_BASE   = 100
WID_EXPORT_BTN         = 120
WID_EXPORT_SPICE_BTN   = 121
WID_EXPORT_VA_BTN      = 122

# Import tab
WID_IMPORT_BTN         = 200
WID_IMPORT_PREVIEW_BASE = 210

# Library tab
WID_LIB_CAT_BASE      = 300   # 300-319: category buttons
WID_LIB_TYPE_BASE     = 320   # 320-359: type buttons within category
WID_LIB_BACK          = 360
WID_LIB_IMPORT_BTN    = 361
WID_LIB_EXPORT_SPICE  = 362
WID_LIB_EXPORT_VA     = 363
WID_LIB_TB_BASE       = 370   # 370-389: testbench buttons

# Code tab
WID_CODE_AREA          = 400
WID_CODE_LINT_BTN      = 401
WID_CODE_SAVE_BTN      = 402
WID_CODE_SYNC_BTN      = 403
WID_CODE_LINT_BASE     = 410   # 410-429: lint result lines

# Misc
WID_STATUS             = 500


# ---------------------------------------------------------------------------
# .chn parser (read schematic file to extract component/net info)
# ---------------------------------------------------------------------------

def _parse_chn_instances(chn_text: str) -> list[dict[str, Any]]:
    """Extract instance info from .chn text for export codegen."""
    instances: list[dict[str, Any]] = []
    in_nmos = False
    in_pmos = False
    in_instances = False
    field_spec: dict[str, str] = {}

    for line in chn_text.split("\n"):
        stripped = line.strip()

        # Detect section headers like: nmos [N]{name, w, l, nf, model}:
        for prefix_key in ("nmos", "pmos"):
            if stripped.startswith(prefix_key + " ") and "{" in stripped:
                brace_start = stripped.index("{")
                brace_end = stripped.index("}")
                fields = [f.strip() for f in stripped[brace_start + 1:brace_end].split(",")]
                field_spec[prefix_key] = fields
                if prefix_key == "nmos":
                    in_nmos = True
                    in_pmos = False
                    in_instances = False
                else:
                    in_pmos = True
                    in_nmos = False
                    in_instances = False
                continue

        if stripped.startswith("instances ") and ":" in stripped:
            in_instances = True
            in_nmos = False
            in_pmos = False
            continue

        # Empty or section-change lines
        if not stripped or stripped.startswith("nets ") or stripped.startswith("wires "):
            in_nmos = False
            in_pmos = False
            in_instances = False
            continue

        # Parse MOSFET lines
        if in_nmos or in_pmos:
            kind = "nmos" if in_nmos else "pmos"
            fields = field_spec.get(kind, ["name", "w", "l", "nf", "model"])
            parts = stripped.split()
            inst: dict[str, Any] = {"type": kind}
            for i, field_name in enumerate(fields):
                if i < len(parts):
                    inst[field_name] = parts[i]
            instances.append(inst)
            continue

        # Parse generic instance lines: inst_name  symbol_path  x=X  y=Y  ...
        if in_instances:
            parts = stripped.split()
            if len(parts) >= 2:
                inst_info: dict[str, Any] = {
                    "type": "instance",
                    "name": parts[0],
                    "symbol": parts[1],
                }
                for p in parts[2:]:
                    if "=" in p:
                        k, v = p.split("=", 1)
                        inst_info[k] = v
                instances.append(inst_info)

    return instances


def _parse_chn_nets(chn_text: str) -> list[dict[str, Any]]:
    """Extract net info from .chn text."""
    nets: list[dict[str, Any]] = []
    in_nets = False

    for line in chn_text.split("\n"):
        stripped = line.strip()
        if stripped.startswith("nets ") and ":" in stripped:
            in_nets = True
            continue
        if not stripped or stripped.startswith("wires "):
            in_nets = False
            continue
        if in_nets and "->" in stripped:
            name, connections = stripped.split("->", 1)
            conns = [c.strip() for c in connections.split(",")]
            nets.append({"name": name.strip(), "connections": conns})

    return nets


# ---------------------------------------------------------------------------
# PLUGIN block read/write helpers
# ---------------------------------------------------------------------------

def _read_plugin_block(chn_text: str, plugin_name: str) -> dict[str, str]:
    """Read entries from a PLUGIN block in .chn text.

    Returns a dict of key -> value.  Multi-line ``|`` values are joined with
    newlines, preserving relative indentation.
    """
    entries: dict[str, str] = {}
    in_block = False
    ml_key = ""
    ml_lines: list[str] = []

    def _flush_ml():
        nonlocal ml_key, ml_lines
        if ml_key and ml_lines:
            entries[ml_key] = "\n".join(ml_lines)
        ml_key = ""
        ml_lines = []

    for line in chn_text.split("\n"):
        stripped = line.strip()

        # Detect top-level blocks (indent 0)
        if line and not line[0].isspace():
            _flush_ml()
            if stripped.startswith("PLUGIN "):
                pname = stripped[len("PLUGIN "):].strip()
                in_block = pname == plugin_name
            else:
                in_block = False
            continue

        if not in_block:
            continue

        # Determine indent level
        indent = len(line) - len(line.lstrip())

        # indent 1 (2 spaces) = key-value entry
        if indent == 2 and ":" in stripped:
            _flush_ml()
            colon = stripped.index(":")
            key = stripped[:colon].strip()
            val = stripped[colon + 1:].strip()
            if val == "|":
                ml_key = key
                ml_lines = []
            else:
                entries[key] = val
        elif indent >= 4 and ml_key:
            # indent 2+ (4+ spaces) = multi-line continuation
            ml_lines.append(line[4:])  # strip base 4-space indent

    _flush_ml()
    return entries


def _write_plugin_block(chn_text: str, plugin_name: str,
                        entries: dict[str, str]) -> str:
    """Write/replace a PLUGIN block in .chn text.

    Returns the modified .chn text.
    """
    lines = chn_text.split("\n")
    result: list[str] = []

    # Remove existing PLUGIN block with this name
    in_old_block = False
    for line in lines:
        stripped = line.strip()
        if line and not line[0].isspace():
            if stripped.startswith("PLUGIN "):
                pname = stripped[len("PLUGIN "):].strip()
                in_old_block = pname == plugin_name
                if in_old_block:
                    continue
            else:
                in_old_block = False
        if in_old_block:
            continue
        result.append(line)

    # Strip trailing empty lines
    while result and result[-1].strip() == "":
        result.pop()

    # Append the new PLUGIN block
    result.append("")
    result.append(f"PLUGIN {plugin_name}")
    for key, val in entries.items():
        if "\n" in val:
            result.append(f"  {key}: |")
            for vline in val.split("\n"):
                result.append(f"    {vline}")
        else:
            result.append(f"  {key}: {val}")
    result.append("")

    return "\n".join(result)


# ---------------------------------------------------------------------------
# Export: .chn -> Python generator codegen
# ---------------------------------------------------------------------------

def _generate_python_class(
    circuit_name: str,
    instances: list[dict[str, Any]],
    nets: list[dict[str, Any]],
    ports: list[str],
) -> str:
    """Generate a CCreator Python class from parsed schematic data."""
    lines: list[str] = []
    lines.append('"""Auto-generated CCreator circuit from Schemify schematic."""')
    lines.append("from ccreator import realistic")
    lines.append("from ccreator.core import Port")
    lines.append("")
    lines.append("")
    lines.append("@realistic.analog")
    lines.append(f"class {circuit_name}:")
    lines.append(f'    """Circuit exported from Schemify .chn schematic."""')
    lines.append("")

    # Ports
    lines.append("    ports = [")
    for port_name in ports:
        # Guess direction from name
        lo = port_name.lower()
        if any(k in lo for k in ("in", "inp", "vin", "clk", "ref", "vdd", "vss")):
            direction = "input"
        elif any(k in lo for k in ("out", "vout")):
            direction = "output"
        else:
            direction = "inout"
        lines.append(f"        Port('{port_name}', '{direction}', 'voltage'),")
    lines.append("    ]")
    lines.append("")

    # Parameters: collect all unique param names from instances
    param_set: dict[str, str] = {}
    for inst in instances:
        if inst["type"] in ("nmos", "pmos"):
            for key in ("w", "l", "nf"):
                val = inst.get(key, "")
                if val:
                    pname = f"{inst.get('name', 'M0')}_{key}"
                    param_set[pname] = repr(val)
        elif inst["type"] == "instance":
            for k, v in inst.items():
                if k not in ("type", "name", "symbol", "x", "y", "rot", "flip"):
                    pname = f"{inst['name']}_{k}"
                    param_set[pname] = repr(v)

    if param_set:
        lines.append("    parameters = {")
        for pname, pval in param_set.items():
            lines.append(f"        '{pname}': {pval},")
        lines.append("    }")
        lines.append("")

    # Build method
    lines.append("    def build(self, n):")
    if not instances:
        lines.append("        pass  # No instances found in schematic")
    else:
        for inst in instances:
            if inst["type"] == "nmos":
                name = inst.get("name", "M0")
                model = inst.get("model", "nch")
                # Find drain/gate/source/bulk from nets
                lines.append(
                    f"        n.MOSFET('{name}', 'drain', 'gate', 'source', 'bulk', "
                    f"'{model}', w={inst.get('w', '1u')!r}, l={inst.get('l', '100n')!r})"
                )
            elif inst["type"] == "pmos":
                name = inst.get("name", "M0")
                model = inst.get("model", "pch")
                lines.append(
                    f"        n.MOSFET('{name}', 'drain', 'gate', 'source', 'bulk', "
                    f"'{model}', w={inst.get('w', '2u')!r}, l={inst.get('l', '100n')!r})"
                )
            elif inst["type"] == "instance":
                sym = inst.get("symbol", "")
                name = inst.get("name", "X0")
                sym_lo = sym.lower()
                if "res" in sym_lo or sym_lo == "r":
                    val = inst.get("value", "1k")
                    lines.append(f"        n.R('{name}', 'n1', 'n2', {val!r})")
                elif "cap" in sym_lo or sym_lo == "c":
                    val = inst.get("value", "1p")
                    lines.append(f"        n.C('{name}', 'n1', 'n2', {val!r})")
                elif "ind" in sym_lo or sym_lo == "l":
                    val = inst.get("value", "1n")
                    lines.append(f"        n.L('{name}', 'n1', 'n2', {val!r})")
                else:
                    lines.append(
                        f"        # Instance: {name} ({sym}) — manual wiring needed"
                    )
                    lines.append(f"        n.raw('.include {sym}')")

    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Import: Python generator -> SPICE -> schematic components
# ---------------------------------------------------------------------------

def _load_circuit_from_file(file_path: str) -> Any:
    """Load a Python file and find the first BaseCircuit subclass instance."""
    spec = _ilu.spec_from_file_location("_user_circuit", file_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot load module from {file_path}")
    mod = _ilu.module_from_spec(spec)

    # Ensure ccreator is importable from the loaded module
    spec.loader.exec_module(mod)

    from ccreator.core.circuit import BaseCircuit

    # Find circuit classes in the module
    for attr_name in dir(mod):
        obj = getattr(mod, attr_name)
        if isinstance(obj, type) and issubclass(obj, BaseCircuit) and obj is not BaseCircuit:
            return obj()

    raise ValueError(f"No CCreator circuit class found in {file_path}")


def _spice_to_components(spice_text: str) -> list[dict[str, Any]]:
    """Convert SPICE netlist text to a list of component dicts via spice2schematic."""
    try:
        from spice2schematic import import_spice
        outputs = import_spice(spice_text, source_path="ccreator")
        components: list[dict[str, Any]] = []
        for out in outputs:
            d = out.to_dict()
            for comp in d.get("components", []):
                components.append(comp)
        return components
    except ImportError:
        # Fallback: basic SPICE line parsing
        return _fallback_parse_spice(spice_text)


def _fallback_parse_spice(spice_text: str) -> list[dict[str, Any]]:
    """Minimal SPICE parser fallback when spice2schematic is unavailable."""
    components: list[dict[str, Any]] = []
    x_offset = 100
    y_offset = -100
    spacing = 200
    idx = 0

    for line in spice_text.split("\n"):
        line = line.strip()
        if not line or line.startswith("*") or line.startswith("."):
            continue
        prefix = line[0].lower()
        parts = line.split()
        if len(parts) < 3:
            continue

        name = parts[0]
        sym_map = {
            "r": "res", "c": "capa", "l": "ind", "m": "nmos4",
            "v": "vsource", "i": "isource", "x": "subckt",
        }
        sym = sym_map.get(prefix, "vsource")
        x = x_offset + (idx % 5) * spacing
        y = y_offset - (idx // 5) * 120

        comp: dict[str, Any] = {
            "name": name,
            "symbol": sym,
            "kind": prefix,
            "x": x,
            "y": y,
            "props": [],
        }

        if prefix in ("r", "c", "l") and len(parts) >= 4:
            comp["props"].append({"key": "value", "val": parts[3]})
        elif prefix == "m" and len(parts) >= 6:
            comp["props"].append({"key": "model", "val": parts[5]})
            comp["symbol"] = "nmos4"  # refined by model later

        components.append(comp)
        idx += 1

    return components


# ---------------------------------------------------------------------------
# Template loader: instantiate a CCreator built-in class
# ---------------------------------------------------------------------------

def _get_template_class(class_name: str) -> Optional[type]:
    """Look up a CCreator public class by name."""
    try:
        from ccreator import public
        return getattr(public, class_name, None)
    except ImportError:
        return None


def _get_template_instance(class_name: str) -> Any:
    """Instantiate a CCreator built-in class."""
    cls = _get_template_class(class_name)
    if cls is None:
        raise ValueError(f"Unknown template: {class_name}")
    return cls()


# ---------------------------------------------------------------------------
# Plugin class
# ---------------------------------------------------------------------------

class CCreatorPlugin(schemify_plugin.Plugin):
    """Bidirectional .chn <-> Python circuit generator with template library."""

    def __init__(self) -> None:
        # Active tab: "export" | "import" | "library"
        self._tab = "export"

        # Export state
        self._current_file = ""
        self._export_path = ""
        self._chn_text = ""
        self._chn_instances: list[dict[str, Any]] = []
        self._chn_nets: list[dict[str, Any]] = []
        self._waiting_for_file = False
        self._pending_subcmd = ""

        # Import state
        self._import_path = ""
        self._import_preview: list[dict[str, Any]] = []
        self._import_done = False

        # Library state
        self._lib_view = "categories"  # "categories" | "types" | "detail"
        self._lib_cat_idx = 0
        self._lib_type_idx = 0
        self._circuit_obj: Any = None
        self._tb_results: list[str] = []

        # Code editor state
        self._code_text = ""         # current text in editor
        self._code_dirty = False     # True if editor text differs from file
        self._code_lint: list[str] = []  # lint diagnostic messages

        # Shared
        self._status = ""
        self._error = ""

    # -- Lifecycle ----------------------------------------------------------

    def on_load(self, w: schemify_plugin.Writer) -> None:
        w.register_panel(
            "ccreator", "Circuit Creator", "ccreator",
            schemify_plugin.Layout.LEFT_SIDEBAR, 0,
        )
        w.set_status("CCreator loaded")
        w.log(0, TAG, "CCreator plugin loaded")

    # -- Panel drawing ------------------------------------------------------

    def on_draw_panel(self, panel_id: int, w: schemify_plugin.Writer) -> None:
        w.label("Circuit Creator", 10)
        w.separator(11)

        # Tab bar
        w.begin_row(12)
        w.button(
            ("> Export" if self._tab == "export" else "  Export"),
            WID_TAB_EXPORT,
        )
        w.button(
            ("> Import" if self._tab == "import" else "  Import"),
            WID_TAB_IMPORT,
        )
        w.button(
            ("> Library" if self._tab == "library" else "  Library"),
            WID_TAB_LIBRARY,
        )
        w.button(
            ("> Code" if self._tab == "code" else "  Code"),
            WID_TAB_CODE,
        )
        w.end_row(12)
        w.separator(13)

        if self._tab == "export":
            self._draw_export(w)
        elif self._tab == "import":
            self._draw_import(w)
        elif self._tab == "library":
            self._draw_library(w)
        elif self._tab == "code":
            self._draw_code(w)

        # Status bar
        w.separator(WID_STATUS)
        if self._error:
            w.label(f"Error: {self._error}", WID_STATUS + 1)
        elif self._status:
            w.label(self._status, WID_STATUS + 1)

    def _draw_export(self, w: schemify_plugin.Writer) -> None:
        w.label("Schematic -> Python Generator", WID_EXPORT_INFO_BASE)
        w.separator(WID_EXPORT_INFO_BASE + 1)

        # Current file info
        if self._current_file:
            w.label(f"File: {os.path.basename(self._current_file)}", WID_EXPORT_INFO_BASE + 2)
            w.tooltip(self._current_file, WID_EXPORT_INFO_BASE + 2)
        else:
            w.label("No .chn file detected", WID_EXPORT_INFO_BASE + 2)
            w.label("Open a schematic first", WID_EXPORT_INFO_BASE + 3)

        # Detected components summary
        if self._chn_instances:
            w.separator(WID_EXPORT_INFO_BASE + 4)
            w.collapsible_start(
                f"Components ({len(self._chn_instances)})", True,
                WID_EXPORT_INFO_BASE + 5,
            )
            mosfets = sum(1 for i in self._chn_instances if i["type"] in ("nmos", "pmos"))
            passives = sum(1 for i in self._chn_instances if i["type"] == "instance")
            if mosfets:
                w.label(f"  MOSFETs: {mosfets}", WID_EXPORT_INFO_BASE + 6)
            if passives:
                w.label(f"  Instances: {passives}", WID_EXPORT_INFO_BASE + 7)
            if self._chn_nets:
                w.label(f"  Nets: {len(self._chn_nets)}", WID_EXPORT_INFO_BASE + 8)
            w.collapsible_end(WID_EXPORT_INFO_BASE + 5)

        # Export output path
        w.separator(WID_EXPORT_INFO_BASE + 10)
        if self._export_path:
            w.label(f"Output: {self._export_path}", WID_EXPORT_INFO_BASE + 11)
        else:
            w.label("Output: (alongside .chn file)", WID_EXPORT_INFO_BASE + 11)

        # Action buttons
        w.separator(WID_EXPORT_INFO_BASE + 12)
        w.button("Export as Python Generator", WID_EXPORT_BTN)
        w.begin_row(WID_EXPORT_INFO_BASE + 13)
        w.button("Export SPICE", WID_EXPORT_SPICE_BTN)
        w.button("Export Verilog-A", WID_EXPORT_VA_BTN)
        w.end_row(WID_EXPORT_INFO_BASE + 13)

    def _draw_import(self, w: schemify_plugin.Writer) -> None:
        w.label("Python Generator -> Schematic", WID_IMPORT_BTN - 10)
        w.separator(WID_IMPORT_BTN - 9)

        # File path display
        if self._import_path:
            w.label(f"File: {os.path.basename(self._import_path)}", WID_IMPORT_BTN - 8)
            w.tooltip(self._import_path, WID_IMPORT_BTN - 8)
        else:
            w.label("No Python file selected", WID_IMPORT_BTN - 8)
            w.label("Use :ccreator import <path>", WID_IMPORT_BTN - 7)

        w.separator(WID_IMPORT_BTN - 6)

        # Import button
        w.button("Import Generator", WID_IMPORT_BTN)

        # Preview of parsed components
        if self._import_preview:
            w.separator(WID_IMPORT_PREVIEW_BASE - 1)
            n = len(self._import_preview)
            placed_tag = " (placed)" if self._import_done else ""
            w.collapsible_start(
                f"Preview ({n} components){placed_tag}", True,
                WID_IMPORT_PREVIEW_BASE,
            )
            for i, comp in enumerate(self._import_preview[:15]):
                name = comp.get("name", "?")
                sym = comp.get("symbol", "?")
                w.label(f"  {name} ({sym})", WID_IMPORT_PREVIEW_BASE + 1 + i)
            if n > 15:
                w.label(f"  ... and {n - 15} more", WID_IMPORT_PREVIEW_BASE + 16)
            w.collapsible_end(WID_IMPORT_PREVIEW_BASE)

    def _draw_library(self, w: schemify_plugin.Writer) -> None:
        if self._lib_view == "categories":
            self._draw_lib_categories(w)
        elif self._lib_view == "types":
            self._draw_lib_types(w)
        elif self._lib_view == "detail":
            self._draw_lib_detail(w)

    def _draw_lib_categories(self, w: schemify_plugin.Writer) -> None:
        w.label("CCreator Template Library", WID_LIB_CAT_BASE - 2)
        w.separator(WID_LIB_CAT_BASE - 1)

        for i, (cat_name, _entries) in enumerate(CATEGORIES):
            n = len(_entries)
            behavioral_n = sum(1 for _, k in _entries if k == "behavioral")
            realistic_n = n - behavioral_n
            desc = f"{behavioral_n}B/{realistic_n}R"
            marker = "> " if i == self._lib_cat_idx else "  "
            w.button(f"{marker}{cat_name} [{desc}]", WID_LIB_CAT_BASE + i)

    def _draw_lib_types(self, w: schemify_plugin.Writer) -> None:
        cat_name, entries = CATEGORIES[self._lib_cat_idx]

        w.button("< Back", WID_LIB_BACK)
        w.separator(WID_LIB_TYPE_BASE - 1)
        w.label(f"{cat_name} Implementations", WID_LIB_TYPE_BASE - 2)
        w.separator(WID_LIB_TYPE_BASE - 3)

        for i, (type_name, kind) in enumerate(entries):
            marker = "> " if i == self._lib_type_idx else "  "
            w.button(f"{marker}{type_name} ({kind})", WID_LIB_TYPE_BASE + i)

    def _draw_lib_detail(self, w: schemify_plugin.Writer) -> None:
        cat_name, entries = CATEGORIES[self._lib_cat_idx]
        type_name, kind = entries[self._lib_type_idx]

        w.button("< Back", WID_LIB_BACK)
        w.separator(WID_LIB_IMPORT_BTN - 9)
        w.label(f"{cat_name}: {type_name}", WID_LIB_IMPORT_BTN - 8)
        w.label(f"Type: {kind}", WID_LIB_IMPORT_BTN - 7)
        w.separator(WID_LIB_IMPORT_BTN - 6)

        # Show circuit parameters if available
        if self._circuit_obj is not None:
            params = getattr(self._circuit_obj, "parameters", None)
            ports = getattr(self._circuit_obj, "ports", [])

            if ports:
                w.collapsible_start(f"Ports ({len(ports)})", True, WID_LIB_IMPORT_BTN - 5)
                for i, port in enumerate(ports):
                    w.label(
                        f"  {port.name} ({port.direction}, {port.kind})",
                        WID_LIB_IMPORT_BTN - 4 + i,  # safe: at most ~5 ports
                    )
                w.collapsible_end(WID_LIB_IMPORT_BTN - 5)

            if params:
                w.collapsible_start(f"Parameters ({len(params)})", True, WID_LIB_IMPORT_BTN + 10)
                for i, (k, v) in enumerate(params.items()):
                    w.label(f"  {k} = {v}", WID_LIB_IMPORT_BTN + 11 + i)
                w.collapsible_end(WID_LIB_IMPORT_BTN + 10)

        # Action buttons
        w.separator(WID_LIB_IMPORT_BTN + 30)
        w.button("Import to Schematic", WID_LIB_IMPORT_BTN)
        w.begin_row(WID_LIB_IMPORT_BTN + 31)
        w.button("Export SPICE", WID_LIB_EXPORT_SPICE)
        w.button("Export Verilog-A", WID_LIB_EXPORT_VA)
        w.end_row(WID_LIB_IMPORT_BTN + 31)

        # Testbenches
        tb_names = TESTBENCHES.get(cat_name, [])
        if tb_names:
            w.separator(WID_LIB_TB_BASE - 1)
            w.collapsible_start("Testbenches", True, WID_LIB_TB_BASE - 2)
            for i, tb_name in enumerate(tb_names):
                w.button(f"Run {tb_name}", WID_LIB_TB_BASE + i)
            w.collapsible_end(WID_LIB_TB_BASE - 2)

        # Results
        if self._tb_results:
            w.separator(WID_LIB_TB_BASE + 20)
            w.collapsible_start("Results", True, WID_LIB_TB_BASE + 21)
            for i, line in enumerate(self._tb_results[-12:]):
                w.label(line, WID_LIB_TB_BASE + 22 + i)
            w.collapsible_end(WID_LIB_TB_BASE + 21)

    # -- Button handling ----------------------------------------------------

    def on_button_clicked(self, panel_id: int, widget_id: int,
                          w: schemify_plugin.Writer) -> None:
        self._error = ""

        # Tab switching
        if widget_id == WID_TAB_EXPORT:
            self._tab = "export"
            if not self._current_file:
                w.get_state("current_file")
                self._waiting_for_file = True
            w.request_refresh()
            return
        if widget_id == WID_TAB_IMPORT:
            self._tab = "import"
            w.request_refresh()
            return
        if widget_id == WID_TAB_LIBRARY:
            self._tab = "library"
            w.request_refresh()
            return
        if widget_id == WID_TAB_CODE:
            self._tab = "code"
            if not self._current_file:
                w.get_state("current_file")
                self._waiting_for_file = True
            elif not self._code_text:
                self._load_code_from_file()
            w.request_refresh()
            return

        # Export tab actions
        if widget_id == WID_EXPORT_BTN:
            self._do_export_python(w)
            w.request_refresh()
            return
        if widget_id == WID_EXPORT_SPICE_BTN:
            self._do_export_format("spice", w)
            w.request_refresh()
            return
        if widget_id == WID_EXPORT_VA_BTN:
            self._do_export_format("veriloga", w)
            w.request_refresh()
            return

        # Code tab actions
        if widget_id == WID_CODE_LINT_BTN:
            self._lint_code()
            w.request_refresh()
            return
        if widget_id == WID_CODE_SAVE_BTN:
            self._save_code_to_file(w)
            w.request_refresh()
            return
        if widget_id == WID_CODE_SYNC_BTN:
            self._save_code_to_file(w)
            self._do_sync(w)
            w.request_refresh()
            return

        # Import tab actions
        if widget_id == WID_IMPORT_BTN:
            self._do_import(w)
            w.request_refresh()
            return

        # Library: Back button
        if widget_id == WID_LIB_BACK:
            if self._lib_view == "detail":
                self._lib_view = "types"
                self._circuit_obj = None
                self._tb_results = []
            elif self._lib_view == "types":
                self._lib_view = "categories"
            self._status = ""
            w.request_refresh()
            return

        # Library: Category selection
        cat_idx = widget_id - WID_LIB_CAT_BASE
        if 0 <= cat_idx < len(CATEGORIES):
            self._lib_cat_idx = cat_idx
            self._lib_type_idx = 0
            self._lib_view = "types"
            self._status = ""
            w.request_refresh()
            return

        # Library: Type selection
        type_idx = widget_id - WID_LIB_TYPE_BASE
        if self._lib_view == "types":
            _cat_name, entries = CATEGORIES[self._lib_cat_idx]
            if 0 <= type_idx < len(entries):
                self._lib_type_idx = type_idx
                self._lib_view = "detail"
                self._tb_results = []
                self._create_template_circuit(w)
                w.request_refresh()
                return

        # Library: Import to schematic
        if widget_id == WID_LIB_IMPORT_BTN:
            self._do_import_template(w)
            w.request_refresh()
            return

        # Library: Export SPICE
        if widget_id == WID_LIB_EXPORT_SPICE:
            self._do_template_export("spice", w)
            w.request_refresh()
            return

        # Library: Export Verilog-A
        if widget_id == WID_LIB_EXPORT_VA:
            self._do_template_export("veriloga", w)
            w.request_refresh()
            return

        # Library: Testbench buttons
        tb_idx = widget_id - WID_LIB_TB_BASE
        if self._lib_view == "detail":
            cat_name = CATEGORIES[self._lib_cat_idx][0]
            tb_names = TESTBENCHES.get(cat_name, [])
            if 0 <= tb_idx < len(tb_names):
                self._run_testbench(tb_names[tb_idx], w)
                w.request_refresh()
                return

    def on_text_changed(self, panel_id: int, widget_id: int,
                         text: str, w: schemify_plugin.Writer) -> None:
        if widget_id == WID_CODE_AREA:
            self._code_text = text
            self._code_dirty = True

    def on_checkbox_changed(self, panel_id: int, widget_id: int,
                            val: bool, w: schemify_plugin.Writer) -> None:
        pass  # No checkboxes currently

    # -- Command handling ---------------------------------------------------

    def on_command(self, cmd_tag: str, payload: str, w: schemify_plugin.Writer) -> None:
        if cmd_tag != "ccreator":
            return

        parts = payload.strip().split(None, 1)
        subcmd = parts[0].lower() if parts else ""
        arg = parts[1].strip() if len(parts) > 1 else ""

        if subcmd == "embed":
            self._tab = "export"
            if not self._current_file:
                w.get_state("current_file")
                self._waiting_for_file = True
                self._pending_subcmd = "embed"
            else:
                self._do_embed(w)
            w.request_refresh()

        elif subcmd == "sync":
            self._tab = "import"
            if not self._current_file:
                w.get_state("current_file")
                self._waiting_for_file = True
                self._pending_subcmd = "sync"
            else:
                self._do_sync(w)
            w.request_refresh()

        elif subcmd == "export":
            self._tab = "export"
            if arg:
                self._export_path = arg
            if not self._current_file:
                w.get_state("current_file")
                self._waiting_for_file = True
            else:
                self._do_export_python(w)
            w.request_refresh()

        elif subcmd == "import":
            self._tab = "import"
            if arg:
                self._import_path = os.path.expanduser(arg)
            self._do_import(w)
            w.request_refresh()

        elif subcmd == "template":
            self._tab = "library"
            if arg:
                self._do_import_template_by_name(arg, w)
            else:
                self._status = "Usage: :ccreator template <ClassName>"
            w.request_refresh()

        elif subcmd == "equivalent":
            # Generate and display Python equivalent of current schematic
            if not self._current_file:
                w.get_state("current_file")
                self._waiting_for_file = True
                self._pending_subcmd = "equivalent"
                self._status = "Requesting file..."
            else:
                self._do_equivalent(w)
            w.request_refresh()

        elif subcmd == "create-circuit" or subcmd == "create_circuit":
            if not arg:
                self._status = "Usage: :ccreator create-circuit <ClassName> [param=val ...]"
            else:
                parts2 = arg.split()
                class_name = parts2[0]
                params = {}
                for p in parts2[1:]:
                    if "=" in p:
                        k, v = p.split("=", 1)
                        params[k] = v
                self._do_create_circuit(class_name, params, w)
            w.request_refresh()

        else:
            self._status = "Commands: embed, sync, export [path], import <path>, template <name>, equivalent, create-circuit <name>"
            w.request_refresh()

    # -- State responses ----------------------------------------------------

    def on_state_response(self, key: str, val: str, w: schemify_plugin.Writer) -> None:
        if key == "current_file":
            self._current_file = val
            if val and os.path.isfile(val):
                try:
                    with open(val, "r", encoding="utf-8") as f:
                        self._chn_text = f.read()
                    self._chn_instances = _parse_chn_instances(self._chn_text)
                    self._chn_nets = _parse_chn_nets(self._chn_text)
                    self._status = f"Loaded {os.path.basename(val)}: {len(self._chn_instances)} components"
                except Exception as e:
                    self._error = f"Failed to read {val}: {e}"

                # If Code tab is active and no code loaded yet, load it
                if self._tab == "code" and not self._code_text:
                    self._load_code_from_file()

                # If we were waiting to do an action, do it now
                if self._waiting_for_file:
                    self._waiting_for_file = False
                    subcmd = self._pending_subcmd
                    self._pending_subcmd = ""
                    if subcmd == "equivalent":
                        self._do_equivalent(w)
                    elif subcmd == "embed":
                        self._do_embed(w)
                    elif subcmd == "sync":
                        self._do_sync(w)
                    else:
                        self._do_export_python(w)
            w.request_refresh()

    def on_schematic_changed(self, w: schemify_plugin.Writer) -> None:
        # Re-read current file info
        w.get_state("current_file")

    def on_instance_data(self, idx: int, name: str, symbol: str,
                         w: schemify_plugin.Writer) -> None:
        # Could be used to track placed instances, but we rely on file parsing
        pass

    # -- Export actions ------------------------------------------------------

    def _do_export_python(self, w: schemify_plugin.Writer) -> None:
        """Export the current .chn schematic as a CCreator Python generator."""
        if not self._current_file:
            self._status = "No schematic file loaded"
            w.get_state("current_file")
            self._waiting_for_file = True
            return

        if not self._chn_text:
            try:
                with open(self._current_file, "r", encoding="utf-8") as f:
                    self._chn_text = f.read()
                self._chn_instances = _parse_chn_instances(self._chn_text)
                self._chn_nets = _parse_chn_nets(self._chn_text)
            except Exception as e:
                self._error = f"Cannot read schematic: {e}"
                return

        # Derive names
        base = os.path.splitext(os.path.basename(self._current_file))[0]
        class_name = "".join(
            word.capitalize() for word in base.replace("-", "_").split("_")
        ) or "MyCircuit"

        # Determine output path
        if self._export_path:
            out_path = self._export_path
        else:
            out_dir = os.path.dirname(self._current_file)
            out_path = os.path.join(out_dir, f"{base}_generator.py")

        # Extract port names from .chn
        ports: list[str] = []
        for line in self._chn_text.split("\n"):
            stripped = line.strip()
            if stripped.startswith("PIN_") or (
                stripped and not stripped.startswith("#") and "direction" not in stripped
            ):
                pass  # Complex parsing needed; use nets as fallback
        # Fallback: use net names that look like ports
        for net in self._chn_nets:
            name = net["name"]
            lo = name.lower()
            if any(k in lo for k in ("in", "out", "vdd", "vss", "gnd", "clk")):
                if name not in ports:
                    ports.append(name)
        if not ports:
            ports = ["in", "out", "gnd"]

        # Generate Python code
        code = _generate_python_class(class_name, self._chn_instances, self._chn_nets, ports)

        try:
            Path(out_path).parent.mkdir(parents=True, exist_ok=True)
            Path(out_path).write_text(code)
            self._status = f"Exported generator to {out_path}"
            w.log(0, TAG, self._status)
            w.set_status(self._status)
        except Exception as e:
            self._error = f"Write failed: {e}"
            w.log(2, TAG, traceback.format_exc())

    def _do_export_format(self, fmt: str, w: schemify_plugin.Writer) -> None:
        """Export current circuit object (from library) as SPICE or Verilog-A."""
        if self._circuit_obj is None:
            # Try to create from current schematic by roundtripping
            self._error = "No circuit object. Select a template from the Library tab first."
            return

        try:
            base = type(self._circuit_obj).__name__
            out_dir = os.path.dirname(self._current_file) if self._current_file else "/tmp"
            if fmt == "spice":
                path = os.path.join(out_dir, f"{base}.sp")
                self._circuit_obj.export.spice(path)
            elif fmt == "veriloga":
                path = os.path.join(out_dir, f"{base}.va")
                self._circuit_obj.export.veriloga(path)
            else:
                self._error = f"Unknown format: {fmt}"
                return
            self._status = f"Exported {fmt} to {path}"
            w.log(0, TAG, self._status)
            w.set_status(self._status)
        except Exception as e:
            self._error = f"Export failed: {e}"
            w.log(2, TAG, traceback.format_exc())

    # -- Import actions -----------------------------------------------------

    def _do_import(self, w: schemify_plugin.Writer) -> None:
        """Import a CCreator Python generator file into the schematic."""
        self._import_preview = []
        self._import_done = False

        if not self._import_path:
            self._status = "No file path. Use :ccreator import <path>"
            return

        if not os.path.isfile(self._import_path):
            self._error = f"File not found: {self._import_path}"
            return

        try:
            self._status = "Loading circuit..."

            # Load the circuit class from the Python file
            circuit = _load_circuit_from_file(self._import_path)

            # Get SPICE netlist from the circuit
            from ccreator.realistic._analog.spice_export import to_spice_string
            from ccreator.realistic._analog.circuit import RealisticAnalogCircuit

            if isinstance(circuit, RealisticAnalogCircuit):
                spice_text = to_spice_string(circuit)
            else:
                # Behavioral circuits: try veriloga export or just get basic info
                self._error = (
                    "Behavioral circuits cannot be directly imported as schematics. "
                    "Only realistic (@realistic.analog) circuits are supported."
                )
                return

            # Convert SPICE to schematic components
            self._import_preview = _spice_to_components(spice_text)

            if not self._import_preview:
                self._status = "No components found in generated SPICE"
                return

            # Place components into the schematic
            placed = 0
            for comp in self._import_preview:
                sym = comp.get("symbol", "")
                name = comp.get("name", "")
                x = comp.get("x", 0)
                y = comp.get("y", 0)
                if sym and name:
                    w.place_device(sym, name, x, y)
                    # Set properties
                    for prop in comp.get("props", []):
                        if isinstance(prop, dict):
                            pk = prop.get("key", "")
                            pv = prop.get("val", "")
                            if pk and pv:
                                w.set_instance_prop(placed, pk, str(pv))
                    placed += 1

            self._import_done = True
            self._status = f"Imported {placed} components from {os.path.basename(self._import_path)}"
            w.log(0, TAG, self._status)
            w.set_status(self._status)

        except Exception as e:
            self._error = f"Import failed: {e}"
            w.log(2, TAG, traceback.format_exc())

    # -- Library actions ----------------------------------------------------

    def _create_template_circuit(self, w: schemify_plugin.Writer) -> None:
        """Instantiate the selected library template."""
        _cat_name, entries = CATEGORIES[self._lib_cat_idx]
        type_name, _kind = entries[self._lib_type_idx]

        try:
            self._circuit_obj = _get_template_instance(type_name)
            self._status = f"Created {type_name}"
            w.log(0, TAG, f"Created circuit: {type_name}")
        except ImportError as e:
            self._error = f"Import error: {e}"
            self._circuit_obj = None
            w.log(2, TAG, f"Import error: {e}")
        except Exception as e:
            self._error = f"Failed to create {type_name}: {e}"
            self._circuit_obj = None
            w.log(2, TAG, traceback.format_exc())

    def _do_import_template(self, w: schemify_plugin.Writer) -> None:
        """Import the current library template into the schematic via SPICE."""
        if self._circuit_obj is None:
            self._error = "No circuit selected"
            return

        try:
            from ccreator.realistic._analog.spice_export import to_spice_string
            from ccreator.realistic._analog.circuit import RealisticAnalogCircuit

            if isinstance(self._circuit_obj, RealisticAnalogCircuit):
                spice_text = to_spice_string(self._circuit_obj)
                components = _spice_to_components(spice_text)
            else:
                # Behavioral circuit: place as a subcircuit symbol
                type_name = type(self._circuit_obj).__name__
                ports = getattr(self._circuit_obj, "ports", [])
                port_str = ", ".join(p.name for p in ports)
                w.place_device("subckt", type_name, 100, -100)
                self._status = f"Placed {type_name} (behavioral, ports: {port_str})"
                w.log(0, TAG, self._status)
                w.set_status(self._status)
                return

            placed = 0
            for comp in components:
                sym = comp.get("symbol", "")
                name = comp.get("name", "")
                x = comp.get("x", 0)
                y = comp.get("y", 0)
                if sym and name:
                    w.place_device(sym, name, x, y)
                    for prop in comp.get("props", []):
                        if isinstance(prop, dict):
                            pk = prop.get("key", "")
                            pv = prop.get("val", "")
                            if pk and pv:
                                w.set_instance_prop(placed, pk, str(pv))
                    placed += 1

            type_name = type(self._circuit_obj).__name__
            self._status = f"Placed {placed} components from {type_name}"
            w.log(0, TAG, self._status)
            w.set_status(self._status)

        except Exception as e:
            self._error = f"Import failed: {e}"
            w.log(2, TAG, traceback.format_exc())

    def _do_import_template_by_name(self, class_name: str, w: schemify_plugin.Writer) -> None:
        """Import a template by class name (from :ccreator template command)."""
        try:
            self._circuit_obj = _get_template_instance(class_name)

            # Navigate to the right library view
            info = _TEMPLATE_MAP.get(class_name)
            if info:
                cat_name, _kind = info
                for i, (cn, _) in enumerate(CATEGORIES):
                    if cn == cat_name:
                        self._lib_cat_idx = i
                        break
                _, entries = CATEGORIES[self._lib_cat_idx]
                for i, (tn, _) in enumerate(entries):
                    if tn == class_name:
                        self._lib_type_idx = i
                        break
                self._lib_view = "detail"

            self._do_import_template(w)
        except Exception as e:
            self._error = f"Template import failed: {e}"
            w.log(2, TAG, traceback.format_exc())

    def _do_template_export(self, fmt: str, w: schemify_plugin.Writer) -> None:
        """Export the selected library template to a file."""
        if self._circuit_obj is None:
            self._error = "No circuit selected"
            return

        try:
            type_name = type(self._circuit_obj).__name__
            out_dir = os.path.dirname(self._current_file) if self._current_file else "/tmp"
            os.makedirs(out_dir, exist_ok=True)

            if fmt == "spice":
                path = os.path.join(out_dir, f"{type_name}.sp")
                self._circuit_obj.export.spice(path)
            elif fmt == "veriloga":
                path = os.path.join(out_dir, f"{type_name}.va")
                self._circuit_obj.export.veriloga(path)
            else:
                self._error = f"Unknown format: {fmt}"
                return

            self._status = f"Exported {fmt} to {path}"
            w.log(0, TAG, self._status)
            w.set_status(self._status)
        except Exception as e:
            self._error = f"Export failed: {e}"
            w.log(2, TAG, traceback.format_exc())

    # -- Equivalent / create-circuit ----------------------------------------

    def _do_equivalent(self, w: schemify_plugin.Writer) -> None:
        """Generate Python CCreator equivalent of the current .chn file."""
        path = self._current_file
        if not path or not os.path.isfile(path):
            self._error = "No .chn file open"
            return
        try:
            with open(path, "r", encoding="utf-8") as f:
                text = f.read()
            instances = _parse_chn_instances(text)
            nets = _parse_chn_nets(text)
            # Determine ports from nets that look like ports (VDD, GND, or single-connection nets)
            ports = []
            for n in nets:
                name = n["name"]
                if name.upper() in ("VDD", "VSS", "GND") or len(n.get("connections", [])) == 1:
                    ports.append(name)
            circuit_name = os.path.splitext(os.path.basename(path))[0].replace("-", "_").replace(" ", "_")
            code = _generate_python_class(circuit_name, instances, nets, ports)
            # Write the .py file alongside the .chn
            out_path = os.path.splitext(path)[0] + "_ccreator.py"
            with open(out_path, "w", encoding="utf-8") as f:
                f.write(code)
            self._status = f"Equivalent saved: {os.path.basename(out_path)} ({len(instances)} components)"
            w.set_status(self._status)
            w.log(0, TAG, f"Generated Python equivalent: {out_path}")
        except Exception as e:
            self._error = str(e)
            w.log(2, TAG, traceback.format_exc())

    def _do_embed(self, w: schemify_plugin.Writer) -> None:
        """Embed Python generator code into the .chn file's PLUGIN CCreator block."""
        path = self._current_file
        if not path or not os.path.isfile(path):
            self._error = "No .chn file open"
            return

        try:
            with open(path, "r", encoding="utf-8") as f:
                chn_text = f.read()

            instances = _parse_chn_instances(chn_text)
            nets = _parse_chn_nets(chn_text)

            # Determine ports from pin declarations or net heuristics
            ports: list[str] = []
            in_pins = False
            for line in chn_text.split("\n"):
                stripped = line.strip()
                if stripped.startswith("pins:"):
                    in_pins = True
                    continue
                if in_pins:
                    if not stripped or not line[0].isspace():
                        in_pins = False
                        continue
                    parts = stripped.split()
                    if parts:
                        ports.append(parts[0])
            if not ports:
                for net in nets:
                    name = net["name"]
                    lo = name.lower()
                    if any(k in lo for k in ("in", "out", "vdd", "vss", "gnd", "clk", "ref")):
                        if name not in ports:
                            ports.append(name)
            if not ports:
                ports = ["in", "out", "gnd"]

            # Derive class name from file
            base = os.path.splitext(os.path.basename(path))[0]
            class_name = "".join(
                word.capitalize() for word in base.replace("-", "_").split("_")
            ) or "MyCircuit"

            # Generate Python code (without module-level boilerplate for embedding)
            code = _generate_python_class(class_name, instances, nets, ports)

            # Write the PLUGIN CCreator block into the .chn file
            entries = _read_plugin_block(chn_text, "CCreator")
            entries["generator"] = code
            entries["mode"] = "bidirectional"
            updated_chn = _write_plugin_block(chn_text, "CCreator", entries)

            with open(path, "w", encoding="utf-8") as f:
                f.write(updated_chn)

            # Reload so Schemify picks up the PLUGIN block in memory
            w.push_command("reload_from_disk", "")

            self._status = f"Embedded Python generator ({len(instances)} components) into {os.path.basename(path)}"
            w.log(0, TAG, self._status)
            w.set_status(self._status)
        except Exception as e:
            self._error = f"Embed failed: {e}"
            w.log(2, TAG, traceback.format_exc())

    def _do_sync(self, w: schemify_plugin.Writer) -> None:
        """Read PLUGIN CCreator block from .chn and regenerate schematic from Python."""
        path = self._current_file
        if not path or not os.path.isfile(path):
            self._error = "No .chn file open"
            return

        try:
            with open(path, "r", encoding="utf-8") as f:
                chn_text = f.read()

            entries = _read_plugin_block(chn_text, "CCreator")
            generator_code = entries.get("generator", "")
            if not generator_code:
                self._error = "No PLUGIN CCreator generator block found in file"
                return

            # Execute the Python code to get a circuit class
            import types as pytypes
            mod = pytypes.ModuleType("_ccreator_embedded")
            mod.__file__ = path

            # Pre-populate the module namespace with common imports
            exec_globals = mod.__dict__.copy()
            exec_globals.update({
                "__name__": "_ccreator_embedded",
                "__file__": path,
            })

            # Try to inject ccreator imports
            try:
                import ccreator
                exec_globals["ccreator"] = ccreator
                from ccreator import realistic, behavioral
                exec_globals["realistic"] = realistic
                exec_globals["behavioral"] = behavioral
                from ccreator.core.port import Port
                exec_globals["Port"] = Port
            except ImportError:
                pass

            exec(generator_code, exec_globals)

            # Find the circuit class
            from ccreator.core.circuit import BaseCircuit
            circuit_obj = None
            for name, obj in exec_globals.items():
                if isinstance(obj, type) and issubclass(obj, BaseCircuit) and obj is not BaseCircuit:
                    circuit_obj = obj()
                    break

            if circuit_obj is None:
                self._error = "No CCreator circuit class found in embedded code"
                return

            # Generate SPICE and place components
            from ccreator.realistic._analog.spice_export import to_spice_string
            from ccreator.realistic._analog.circuit import RealisticAnalogCircuit

            if isinstance(circuit_obj, RealisticAnalogCircuit):
                spice_text = to_spice_string(circuit_obj)
                components = _spice_to_components(spice_text)

                placed = 0
                for comp in components:
                    sym = comp.get("symbol", "")
                    name = comp.get("name", "")
                    x = comp.get("x", 0)
                    y = comp.get("y", 0)
                    if sym and name:
                        w.place_device(sym, name, x, y)
                        for prop in comp.get("props", []):
                            if isinstance(prop, dict):
                                pk = prop.get("key", "")
                                pv = prop.get("val", "")
                                if pk and pv:
                                    w.set_instance_prop(placed, pk, str(pv))
                        placed += 1

                self._status = f"Synced from embedded Python: {placed} components placed"
            else:
                # Behavioral: place as subcircuit
                type_name = type(circuit_obj).__name__
                w.place_device("subckt", type_name, 100, -100)
                self._status = f"Synced {type_name} (behavioral) from embedded code"

            w.log(0, TAG, self._status)
            w.set_status(self._status)
        except Exception as e:
            self._error = f"Sync failed: {e}"
            w.log(2, TAG, traceback.format_exc())

    def _do_create_circuit(self, class_name: str, params: dict[str, str],
                           w: schemify_plugin.Writer) -> None:
        """Instantiate a CCreator class, generate SPICE, and place components."""
        try:
            inst = _get_template_instance(class_name)
            # Apply params if the circuit supports parameters
            if params and hasattr(inst, 'parameters'):
                for k, v in params.items():
                    if k in inst.parameters:
                        inst.parameters[k] = v
            # Generate SPICE
            if hasattr(inst, 'to_spice'):
                spice = inst.to_spice()
            elif hasattr(inst, 'netlist'):
                spice = inst.netlist()
            else:
                self._error = f"{class_name} has no SPICE export"
                return
            # Parse and place
            components = _spice_to_components(spice)
            placed = 0
            for comp in components:
                sym = comp.get("symbol", "")
                name = comp.get("name", "")
                x = comp.get("x", 0)
                y = comp.get("y", 0)
                if sym and name:
                    w.place_device(sym, name, x, y)
                    for prop in comp.get("props", []):
                        key = prop.get("key", "")
                        val = prop.get("val", "")
                        if key and val:
                            w.set_instance_prop(placed, key, str(val))
                    placed += 1
            self._status = f"Created {class_name}: {placed} components placed"
            w.set_status(self._status)
            w.log(0, TAG, self._status)
        except Exception as e:
            self._error = str(e)
            w.log(2, TAG, traceback.format_exc())

    # -- Code editor --------------------------------------------------------

    def _draw_code(self, w: schemify_plugin.Writer) -> None:
        dirty_tag = " *" if self._code_dirty else ""
        if self._current_file:
            w.label(f"PLUGIN CCreator: {os.path.basename(self._current_file)}{dirty_tag}",
                    WID_CODE_AREA - 3)
        else:
            w.label("No .chn file open", WID_CODE_AREA - 3)

        w.separator(WID_CODE_AREA - 2)

        # Multi-line code editor
        w.text_area("# Python generator code...", self._code_text, WID_CODE_AREA)

        # Action buttons
        w.separator(WID_CODE_AREA - 1)
        w.begin_row(WID_CODE_LINT_BTN - 1)
        w.button("Lint", WID_CODE_LINT_BTN)
        w.button("Save", WID_CODE_SAVE_BTN)
        w.button("Save & Sync", WID_CODE_SYNC_BTN)
        w.end_row(WID_CODE_LINT_BTN - 1)

        # Lint results
        if self._code_lint:
            w.separator(WID_CODE_LINT_BASE - 1)
            for i, msg in enumerate(self._code_lint[:20]):
                w.label(msg, WID_CODE_LINT_BASE + i)

    def _load_code_from_file(self) -> None:
        """Load the PLUGIN CCreator generator code from the current .chn file."""
        path = self._current_file
        if not path or not os.path.isfile(path):
            return
        try:
            with open(path, "r", encoding="utf-8") as f:
                chn_text = f.read()
            entries = _read_plugin_block(chn_text, "CCreator")
            self._code_text = entries.get("generator", "")
            self._code_dirty = False
            self._code_lint = []
            if not self._code_text:
                self._status = "No PLUGIN CCreator block found — editor is empty"
            else:
                lines = self._code_text.count("\n") + 1
                self._status = f"Loaded generator code ({lines} lines)"
        except Exception as e:
            self._error = f"Failed to read code: {e}"

    def _lint_code(self) -> None:
        """Run Python syntax check + file-type class restrictions."""
        self._code_lint = []
        code = self._code_text
        if not code.strip():
            self._code_lint.append("(empty — nothing to lint)")
            return
        try:
            compile(code, "<ccreator-editor>", "exec")
            self._code_lint.append("OK: no syntax errors")
        except SyntaxError as e:
            line_info = f"line {e.lineno}" if e.lineno else "unknown line"
            self._code_lint.append(f"SyntaxError ({line_info}): {e.msg}")
            if e.text:
                self._code_lint.append(f"  {e.text.rstrip()}")
                if e.offset:
                    self._code_lint.append(f"  {' ' * (e.offset - 1)}^")

        # File-type class restrictions
        self._lint_file_type_restrictions(code)

    def _lint_file_type_restrictions(self, code: str) -> None:
        """Check that the code uses only the class decorators allowed for this file type."""
        path = self._current_file
        if not path:
            return

        ext = os.path.splitext(path)[1].lower()

        # Decorators/patterns to look for in the code text
        has_testbench = "@testbench" in code
        has_realistic = "@realistic.analog" in code or "@realistic.digital" in code
        has_behavioral = "@behavioral.analog" in code or "@behavioral.digital" in code

        if ext == ".chn_tb":
            # Testbenches: only @testbench allowed
            if has_realistic:
                self._code_lint.append(
                    "WARNING: .chn_tb files should only use @testbench classes, "
                    "not @realistic (use .chn for netlist circuits)"
                )
            if has_behavioral:
                self._code_lint.append(
                    "WARNING: .chn_tb files should only use @testbench classes, "
                    "not @behavioral (use .chn_prim for behavioral/RTL)"
                )
        elif ext == ".chn_prim":
            # Primitives: only @behavioral / RTL allowed
            if has_realistic:
                self._code_lint.append(
                    "WARNING: .chn_prim files should only use @behavioral or RTL classes, "
                    "not @realistic (use .chn for netlist circuits)"
                )
            if has_testbench:
                self._code_lint.append(
                    "WARNING: .chn_prim files should only use @behavioral or RTL classes, "
                    "not @testbench (use .chn_tb for testbenches)"
                )
        elif ext == ".chn":
            # Schematics: only @realistic (netlist-level) allowed
            if has_behavioral:
                self._code_lint.append(
                    "WARNING: .chn files should only use @realistic (netlist) classes, "
                    "not @behavioral (use .chn_prim for behavioral/RTL)"
                )
            if has_testbench:
                self._code_lint.append(
                    "WARNING: .chn files should only use @realistic (netlist) classes, "
                    "not @testbench (use .chn_tb for testbenches)"
                )

    def _save_code_to_file(self, w: schemify_plugin.Writer) -> None:
        """Save the editor code back into the .chn file's PLUGIN CCreator block."""
        path = self._current_file
        if not path or not os.path.isfile(path):
            self._error = "No .chn file open"
            return
        try:
            with open(path, "r", encoding="utf-8") as f:
                chn_text = f.read()
            entries = _read_plugin_block(chn_text, "CCreator")
            entries["generator"] = self._code_text
            if "mode" not in entries:
                entries["mode"] = "bidirectional"
            updated = _write_plugin_block(chn_text, "CCreator", entries)
            with open(path, "w", encoding="utf-8") as f:
                f.write(updated)
            self._code_dirty = False
            w.push_command("reload_from_disk", "")
            self._status = f"Saved generator code to {os.path.basename(path)}"
            w.log(0, TAG, self._status)
            w.set_status(self._status)
        except Exception as e:
            self._error = f"Save failed: {e}"
            w.log(2, TAG, traceback.format_exc())

    # -- Testbench ----------------------------------------------------------

    def _run_testbench(self, tb_name: str, w: schemify_plugin.Writer) -> None:
        """Run a testbench from the library on the current circuit."""
        if self._circuit_obj is None:
            self._error = "No circuit created"
            return

        try:
            from ccreator import simulate as cc_simulate
            self._status = f"Running {tb_name}..."
            self._tb_results.append(f"--- {tb_name} ---")

            proxy = cc_simulate(self._circuit_obj)

            # Choose analysis type based on testbench name
            ac_tbs = {
                "AC", "PSRR", "Noise", "LoopFilter", "PhaseNoise",
                "Bandwidth", "Filter", "Isolation",
            }
            if tb_name in ac_tbs:
                result = proxy.ac(fstart=1, fstop=1e9, points=100)
            else:
                result = proxy.tran(step=1e-6, end=1e-3)

            metrics = result.metrics()
            for k, v in metrics.items():
                line = f"  {k}: {v}"
                self._tb_results.append(line)
            self._status = f"{tb_name} complete ({len(metrics)} metrics)"
            w.log(0, TAG, self._status)
        except Exception as e:
            self._error = f"Testbench failed: {e}"
            self._tb_results.append(f"  ERROR: {e}")
            w.log(2, TAG, traceback.format_exc())


# ---------------------------------------------------------------------------
# Module-level entry point (required by Schemify plugin host)
# ---------------------------------------------------------------------------

_plugin = CCreatorPlugin()


def schemify_process(in_bytes: bytes) -> bytes:
    return _plugin.process(in_bytes)
