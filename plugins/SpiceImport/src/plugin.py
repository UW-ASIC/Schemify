"""Schemify SpiceImport plugin -- import ngspice netlists as schematics.

Provides a panel (OVERLAY) and a vim command (:spiceimport <filepath>) for
importing SPICE netlists.  The spice2schematic library handles parsing,
topological placement, and Manhattan wire routing.

Supported ngspice syntax
------------------------
  Elements : R C L D M Q J V I E G F H B X (subcircuit instances)
  Directives: .subckt/.ends  .model  .param  .global  .include  .lib
  Analyses : .ac  .dc  .tran  .op  .noise  .tf
  Measures : .meas / .measure
  Other    : .control/.endc blocks, line continuation (+), comments (* $ ;)

Type inference
--------------
  - .subckt definitions present       -> component  (.chn)
  - analysis directives / .control    -> testbench  (.chn_tb)
  - both                              -> component + testbench pair
"""

from __future__ import annotations

import importlib.util as _ilu
import os
import traceback
from collections import Counter
from typing import Any, Optional

# ---------------------------------------------------------------------------
# SDK bootstrap -- load tools/api/python/src/lib.py by path
# ---------------------------------------------------------------------------
_PLUGIN_SRC_DIR = os.path.dirname(os.path.abspath(__file__))
_SDK_LIB = os.path.normpath(
    os.path.join(_PLUGIN_SRC_DIR, "..", "..", "..", "tools", "api", "python", "src", "lib.py")
)
_spec = _ilu.spec_from_file_location("schemify_plugin", _SDK_LIB)
schemify_plugin = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(schemify_plugin)  # type: ignore

TAG = "SpiceImport"
SPICE_EXTS = {".sp", ".spice", ".cir", ".net", ".spi"}

# ---------------------------------------------------------------------------
# Widget IDs  (keep ranges non-overlapping)
# ---------------------------------------------------------------------------
# Header / static labels             0 -   9
# File-path area                    10 -  19
# Options                           30 -  39
# Action buttons                    40 -  49
# Status / errors                   50 -  59
# Preview: subcircuits              100 - 149
# Preview: element counts           150 - 199
# Preview: analyses                 200 - 249
# Preview: type / summary           250 - 259
# Import buttons                    300 - 309
# Result section                    400 - 499
WID_PATH_LABEL      = 10
WID_FORMAT_LABEL     = 12
WID_FLATTEN_CB       = 30
WID_PARSE_BTN        = 40
WID_STATUS_LABEL     = 50
WID_ERROR_LABEL      = 55
WID_PREVIEW_COLL     = 90
WID_SUBCKT_BASE      = 100
WID_ELEM_BASE        = 150
WID_ANALYSIS_BASE    = 200
WID_TYPE_LABEL       = 250
WID_IMPORT_COMP_BTN  = 300
WID_IMPORT_TB_BTN    = 301
WID_IMPORT_BOTH_BTN  = 302
WID_RESULT_COLL      = 400
WID_RESULT_BASE      = 410

# Element prefix -> human name
_ELEM_NAMES = {
    "r": "R (resistor)",
    "c": "C (capacitor)",
    "l": "L (inductor)",
    "d": "D (diode)",
    "m": "M (MOSFET)",
    "q": "Q (BJT)",
    "j": "J (JFET)",
    "v": "V (voltage src)",
    "i": "I (current src)",
    "e": "E (VCVS)",
    "g": "G (VCCS)",
    "f": "F (CCCS)",
    "h": "H (CCVS)",
    "b": "B (behavioral)",
    "x": "X (subcircuit inst)",
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _infer_type(netlist) -> str:
    """Return 'component', 'testbench', or 'both'."""
    has_subckt = len(netlist.subckts) > 0
    has_tb = (
        len(netlist.analyses) > 0
        or netlist.control_block is not None
        or len(netlist.top_elements) > 0
    )
    if has_subckt and has_tb:
        return "both"
    if has_subckt:
        return "component"
    if has_tb:
        return "testbench"
    return "testbench"  # empty but parsed, treat as tb


def _count_elements(elements) -> dict[str, int]:
    """Return {prefix: count} for a flat element list."""
    c: Counter = Counter()
    for e in elements:
        c[e.prefix] += 1
    return dict(c)


def _all_elements(netlist) -> list:
    """Gather every element across subckts and top-level."""
    elems = list(netlist.top_elements)
    for sc in netlist.subckts:
        elems.extend(sc.elements)
    return elems


# ---------------------------------------------------------------------------
# Plugin
# ---------------------------------------------------------------------------

class SpiceImportPlugin(schemify_plugin.Plugin):
    """Import ngspice netlists into Schemify schematics."""

    def __init__(self) -> None:
        self._file_path: str = ""
        self._flatten: bool = False
        self._status: str = "Ready -- use :spiceimport <path> to set file"
        self._error: str = ""

        # After parse
        self._netlist: Any = None          # parser.Netlist
        self._inferred_type: str = ""      # component / testbench / both
        self._elem_counts: dict[str, int] = {}
        self._parsed: bool = False

        # After convert
        self._outputs: list[Any] = []      # list[SchematicOutput]
        self._placed_count: int = 0
        self._warnings: list[str] = []

    # -- lifecycle ----------------------------------------------------------

    def on_load(self, w: schemify_plugin.Writer) -> None:
        w.register_panel(
            "spiceimport", "SPICE Import", "spiceimport",
            schemify_plugin.Layout.OVERLAY, 0,
        )
        w.set_status("SpiceImport loaded")
        w.log(0, TAG, "SpiceImport plugin loaded")

    def on_unload(self, w: schemify_plugin.Writer) -> None:
        w.log(0, TAG, "SpiceImport unloaded")

    # -- draw ---------------------------------------------------------------

    def on_draw_panel(self, panel_id: int, w: schemify_plugin.Writer) -> None:
        w.label("SPICE Import", 0)
        w.separator(1)

        # Format info
        w.label("Supported: ngspice syntax (.sp .cir .net .spice .spi)", WID_FORMAT_LABEL)
        w.label("Elements: R C L D M Q J V I E G F H B X", WID_FORMAT_LABEL + 1)
        w.label("Directives: .subckt .model .param .global .include .lib", WID_FORMAT_LABEL + 2)
        w.label("Analyses: .ac .dc .tran .op .noise .tf  Measures: .meas", WID_FORMAT_LABEL + 3)
        w.separator(WID_FORMAT_LABEL + 4)

        # File path
        w.label("File:", WID_PATH_LABEL)
        if self._file_path:
            w.label(f"  {self._file_path}", WID_PATH_LABEL + 1)
        else:
            w.label("  (none -- use :spiceimport <path>)", WID_PATH_LABEL + 1)

        w.separator(WID_PATH_LABEL + 5)

        # Options
        w.checkbox(self._flatten, "Flatten hierarchy", WID_FLATTEN_CB)

        w.separator(WID_FLATTEN_CB + 1)

        # Parse button
        w.button("Parse SPICE File", WID_PARSE_BTN)

        w.separator(WID_PARSE_BTN + 1)

        # Status
        w.label(f"Status: {self._status}", WID_STATUS_LABEL)

        if self._error:
            w.separator(WID_ERROR_LABEL - 1)
            w.label(f"Error: {self._error}", WID_ERROR_LABEL)

        # Preview section (after parse)
        if self._parsed and self._netlist is not None:
            self._draw_preview(w)

        # Results section (after import)
        if self._outputs:
            self._draw_results(w)

    def _draw_preview(self, w: schemify_plugin.Writer) -> None:
        nl = self._netlist
        w.separator(WID_PREVIEW_COLL - 1)
        w.collapsible_start("Preview", True, WID_PREVIEW_COLL)

        # Detected type
        type_display = {
            "component": "Component (.chn)",
            "testbench": "Testbench (.chn_tb)",
            "both": "Component + Testbench pair",
        }
        w.label(f"Detected type: {type_display.get(self._inferred_type, 'unknown')}", WID_TYPE_LABEL)

        # Subcircuits
        if nl.subckts:
            w.separator(WID_SUBCKT_BASE - 1)
            w.label(f"Subcircuits ({len(nl.subckts)}):", WID_SUBCKT_BASE)
            for i, sc in enumerate(nl.subckts[:20]):
                port_str = ", ".join(sc.ports[:6])
                if len(sc.ports) > 6:
                    port_str += ", ..."
                n_elems = len(sc.elements)
                w.label(
                    f"  {sc.name} ({n_elems} elems, ports: {port_str})",
                    WID_SUBCKT_BASE + 1 + i,
                )

        # Element counts
        if self._elem_counts:
            w.separator(WID_ELEM_BASE - 1)
            w.label("Elements by type:", WID_ELEM_BASE)
            for i, (prefix, count) in enumerate(sorted(self._elem_counts.items())):
                label = _ELEM_NAMES.get(prefix, prefix.upper())
                w.label(f"  {label}: {count}", WID_ELEM_BASE + 1 + i)

        # Analyses
        if nl.analyses:
            w.separator(WID_ANALYSIS_BASE - 1)
            w.label(f"Analyses ({len(nl.analyses)}):", WID_ANALYSIS_BASE)
            for i, an in enumerate(nl.analyses[:10]):
                raw_preview = an.raw[:60] if an.raw else ""
                w.label(f"  .{an.kind.value} {raw_preview}", WID_ANALYSIS_BASE + 1 + i)

        # Measures
        if nl.measures:
            w.label(f"Measures ({len(nl.measures)}):", WID_ANALYSIS_BASE + 20)
            for i, m in enumerate(nl.measures[:10]):
                expr_preview = m.expr[:50] if m.expr else ""
                w.label(f"  {m.name}: {expr_preview}", WID_ANALYSIS_BASE + 21 + i)

        # Control block
        if nl.control_block:
            w.label(".control block: present", WID_ANALYSIS_BASE + 40)

        # Import buttons (context-sensitive)
        w.separator(WID_IMPORT_COMP_BTN - 1)
        if self._inferred_type == "component":
            w.button("Import as Component", WID_IMPORT_COMP_BTN)
        elif self._inferred_type == "testbench":
            w.button("Import as Testbench", WID_IMPORT_TB_BTN)
        elif self._inferred_type == "both":
            w.button("Import as Component", WID_IMPORT_COMP_BTN)
            w.button("Import as Testbench", WID_IMPORT_TB_BTN)
            w.button("Import Both", WID_IMPORT_BOTH_BTN)

        w.collapsible_end(WID_PREVIEW_COLL)

    def _draw_results(self, w: schemify_plugin.Writer) -> None:
        w.separator(WID_RESULT_COLL - 1)
        w.collapsible_start(f"Results ({self._placed_count} devices placed)", True, WID_RESULT_COLL)

        for i, out in enumerate(self._outputs[:10]):
            n_comp = len(out.components)
            n_wire = len(out.wires)
            n_pwr  = len(out.power_symbols)
            w.label(
                f"  {out.filename} [{out.stype}]: {n_comp} devices, {n_wire} wires, {n_pwr} power syms",
                WID_RESULT_BASE + i,
            )

        if self._warnings:
            w.separator(WID_RESULT_BASE + 50)
            w.label(f"Warnings ({len(self._warnings)}):", WID_RESULT_BASE + 51)
            for i, warn in enumerate(self._warnings[:10]):
                w.label(f"  {warn}", WID_RESULT_BASE + 52 + i)

        w.collapsible_end(WID_RESULT_COLL)

    # -- button handling ----------------------------------------------------

    def on_button_clicked(self, panel_id: int, widget_id: int,
                          w: schemify_plugin.Writer) -> None:
        if widget_id == WID_PARSE_BTN:
            self._do_parse(w)
            w.request_refresh()
            return

        if widget_id == WID_IMPORT_COMP_BTN:
            self._do_import("component", w)
            w.request_refresh()
            return

        if widget_id == WID_IMPORT_TB_BTN:
            self._do_import("testbench", w)
            w.request_refresh()
            return

        if widget_id == WID_IMPORT_BOTH_BTN:
            self._do_import("both", w)
            w.request_refresh()
            return

    def on_checkbox_changed(self, panel_id: int, widget_id: int,
                            val: bool, w: schemify_plugin.Writer) -> None:
        if widget_id == WID_FLATTEN_CB:
            self._flatten = val
            # If already parsed, re-parse is not needed -- flatten is a convert-time option

    # -- vim command --------------------------------------------------------

    def on_command(self, cmd_tag: str, payload: str, w: schemify_plugin.Writer) -> None:
        """Handle :spiceimport <filepath> -- parse and auto-import."""
        if cmd_tag != "spiceimport":
            return
        path = payload.strip()
        if not path:
            w.set_status("Usage: :spiceimport <filepath>")
            return

        self._file_path = os.path.expanduser(path)
        self._do_parse(w)
        if self._parsed and not self._error:
            self._do_import(self._inferred_type, w)
        w.request_refresh()

    # -- auto-detect companion SPICE file -----------------------------------

    def on_state_response(self, key: str, val: str,
                          w: schemify_plugin.Writer) -> None:
        if key == "current_file" and not self._file_path:
            base, _ext = os.path.splitext(val)
            for sp_ext in SPICE_EXTS:
                candidate = base + sp_ext
                if os.path.isfile(candidate):
                    self._file_path = candidate
                    self._status = f"Auto-detected: {candidate}"
                    break

    # -- core logic ---------------------------------------------------------

    def _do_parse(self, w: schemify_plugin.Writer) -> None:
        """Parse the SPICE file and populate preview data."""
        self._error = ""
        self._parsed = False
        self._netlist = None
        self._outputs = []
        self._placed_count = 0
        self._warnings = []
        self._elem_counts = {}

        if not self._file_path:
            self._status = "No file path -- use :spiceimport <path>"
            w.get_state("current_file")
            return

        if not os.path.isfile(self._file_path):
            self._error = f"File not found: {self._file_path}"
            self._status = "Error"
            return

        try:
            self._status = "Parsing..."
            with open(self._file_path, "r", encoding="utf-8", errors="replace") as f:
                spice_text = f.read()

            from spice2schematic.parser import parse
            nl = parse(spice_text)
            self._netlist = nl
            self._inferred_type = _infer_type(nl)
            self._elem_counts = _count_elements(_all_elements(nl))
            self._parsed = True

            total_elems = sum(self._elem_counts.values())
            n_sc = len(nl.subckts)
            n_an = len(nl.analyses)
            self._status = (
                f"Parsed: {n_sc} subcircuit(s), {total_elems} element(s), "
                f"{n_an} analysis/analyses"
            )
            w.log(0, TAG, self._status)
            w.set_status(self._status)

        except Exception as exc:
            self._error = str(exc)
            self._status = "Parse failed"
            w.log(2, TAG, traceback.format_exc())

    def _do_import(self, mode: str, w: schemify_plugin.Writer) -> None:
        """Convert parsed netlist and place devices on canvas.

        mode: 'component' | 'testbench' | 'both'
        """
        if self._netlist is None:
            self._error = "Nothing parsed yet"
            self._status = "Error"
            return

        try:
            self._status = "Converting..."
            from spice2schematic.converter import convert

            outputs = convert(self._netlist, source_path=self._file_path)

            # Filter outputs by mode
            if mode == "component":
                outputs = [o for o in outputs if o.stype == "component"]
            elif mode == "testbench":
                outputs = [o for o in outputs if o.stype == "testbench"]
            # else "both" -- keep all

            if not outputs:
                self._error = f"No {mode} outputs from conversion"
                self._status = "Error"
                return

            self._outputs = outputs
            self._warnings = []
            total_placed = 0

            for out in outputs:
                placed_in_output = self._place_output(out, w)
                total_placed += placed_in_output

            self._placed_count = total_placed
            self._status = (
                f"Imported {len(outputs)} schematic(s): "
                f"{total_placed} devices placed"
            )
            w.log(0, TAG, self._status)
            w.set_status(self._status)

        except Exception as exc:
            self._error = str(exc)
            self._status = "Import failed"
            w.log(2, TAG, traceback.format_exc())

    def _place_output(self, out, w: schemify_plugin.Writer) -> int:
        """Place all components and power symbols from one SchematicOutput."""
        placed = 0

        # Place circuit components
        for comp in out.components:
            sym = comp.symbol
            name = comp.name
            x = comp.x
            y = comp.y

            if not sym or not name:
                self._warnings.append(f"Skipped unnamed component at ({x}, {y})")
                continue

            w.place_device(sym, name, x, y)

            # Set properties on the just-placed device
            for prop in comp.props:
                key = prop.get("key", "") if isinstance(prop, dict) else getattr(prop, "key", "")
                val = prop.get("val", "") if isinstance(prop, dict) else getattr(prop, "val", "")
                if key and val:
                    w.set_instance_prop(placed, key, str(val))

            # Set connection info as properties for net tracking
            for conn in comp.conns:
                pin = conn.get("pin", "") if isinstance(conn, dict) else getattr(conn, "pin", "")
                net = conn.get("net", "") if isinstance(conn, dict) else getattr(conn, "net", "")
                if pin and net:
                    w.set_instance_prop(placed, f"net.{pin}", net)

            # Store spice line if present (for controlled sources, behavioral)
            spice_line = comp.spice_line
            if spice_line:
                w.set_instance_prop(placed, "spice_line", spice_line)

            placed += 1

        # Place power symbols (VDD / GND)
        for ps in out.power_symbols:
            ps_sym = ps.get("symbol", "") if isinstance(ps, dict) else getattr(ps, "symbol", "")
            ps_name = ps.get("name", "") if isinstance(ps, dict) else getattr(ps, "name", "")
            ps_x = ps.get("x", 0) if isinstance(ps, dict) else getattr(ps, "x", 0)
            ps_y = ps.get("y", 0) if isinstance(ps, dict) else getattr(ps, "y", 0)
            if ps_sym and ps_name:
                w.place_device(ps_sym, ps_name, ps_x, ps_y)
                placed += 1

        # For testbenches: store analyses and measures as properties on the
        # first placed device (index 0) so the schematic carries them.
        if out.stype == "testbench" and placed > 0:
            for key, val in out.sym_props.items():
                if key and val:
                    w.set_instance_prop(0, key, val)

            if out.control_block:
                w.set_instance_prop(0, "control_block", out.control_block)

        return placed


# ---------------------------------------------------------------------------
# Module-level entry point (called by Schemify host)
# ---------------------------------------------------------------------------

_plugin = SpiceImportPlugin()


def schemify_process(in_bytes: bytes) -> bytes:
    return _plugin.process(in_bytes)
