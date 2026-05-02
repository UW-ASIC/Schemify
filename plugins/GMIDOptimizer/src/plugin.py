"""Schemify GMIDOptimizer plugin -- Bayesian gm/Id circuit optimizer.

Provides a RIGHT_SIDEBAR panel for configuring and running gm/Id-based
transistor sizing optimization driven by testbench measurements.

Flow:
  1. Detect current .chn file (component schematic)
  2. Scan project directory for linked .chn_tb testbenches
  3. Parse .meas directives from each testbench -> optimization targets
  4. Auto-detect MOSFETs from schematic instances
  5. Run Bayesian optimization (GP surrogate + EI acquisition)
  6. Persist run history in PLUGIN Optimizer block of the .chn file
"""

from __future__ import annotations

import importlib.util as _ilu
import json
import os
import re
import threading
import time
import traceback
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

# ---------------------------------------------------------------------------
# SDK path resolution -- load tools/api/python/src/lib.py by file path
# ---------------------------------------------------------------------------

_PLUGIN_SRC_DIR = os.path.dirname(os.path.abspath(__file__))
_SDK_LIB = os.path.normpath(
    os.path.join(_PLUGIN_SRC_DIR, "..", "..", "..", "tools", "api", "python", "src", "lib.py")
)
_spec = _ilu.spec_from_file_location("schemify_plugin", _SDK_LIB)
schemify_plugin = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(schemify_plugin)  # type: ignore

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

TAG = "GMIDOptimizer"
PLUGIN_ID = "gmid-opt"
PANEL_TITLE = "gm/ID Optimizer"
VIM_CMD = "gmidopt"
CONFIG_PLUGIN_ID = "gmid_optimizer"
CONFIG_HISTORY_KEY = "history"

# Views
VIEW_SETUP = 0
VIEW_RUNNING = 1
VIEW_HISTORY = 2

# Widget ID allocation plan:
#   0-9       : header / view-tab buttons / separators
#   10-19     : settings sliders
#   20-29     : action buttons
#   30-39     : transistor section header / labels
#   100-299   : transistor gmid sliders  (WID_TRANS_GMID_MIN + i*2, +1 for max)
#   300-499   : transistor nf sliders    (WID_TRANS_NF_MIN + i*2, +1 for max)
#   500-699   : transistor enable checkboxes
#   700-999   : target checkboxes        (WID_TARGET_CB + i)
#   1000-1299 : target kind buttons      (WID_TARGET_KIND + i)
#   1300-1599 : target weight sliders    (WID_TARGET_WEIGHT + i)
#   1600-1899 : target value sliders     (WID_TARGET_VAL + i)
#   2000-2099 : running-view widgets
#   3000-3199 : history-view widgets

WID_TAB_SETUP = 1
WID_TAB_RUNNING = 2
WID_TAB_HISTORY = 3

WID_SLIDER_MAX_ITER = 10
WID_SLIDER_LHC = 11
WID_SLIDER_VDD = 12

WID_BTN_START = 20
WID_BTN_STOP = 21
WID_BTN_SCAN = 22
WID_BTN_SCAN_TB = 23
WID_BTN_CLEAR = 24
WID_BTN_APPLY_BEST = 25
WID_BTN_REFRESH_TB = 26

WID_TRANS_GMID_MIN = 100
WID_TRANS_NF_MIN = 300
WID_TRANS_ENABLE = 500

WID_TARGET_CB = 700
WID_TARGET_KIND = 1000
WID_TARGET_WEIGHT = 1300
WID_TARGET_VAL = 1600

WID_RUN_PROGRESS = 2000
WID_RUN_LOG_BASE = 2010

WID_HIST_BASE = 3000

# MOSFET symbol names recognised from schematic instances
MOSFET_SYMBOLS = frozenset({
    "nmos4", "pmos4", "nmos3", "pmos3",
    "nmos", "pmos", "nmos_sub", "pmos_sub",
    "nmos4_depl", "nmoshv4", "pmoshv4", "rnmos4",
})


# ---------------------------------------------------------------------------
# Data classes for plugin state
# ---------------------------------------------------------------------------

@dataclass
class TransistorEntry:
    """A MOSFET from the schematic that can be optimised."""
    instance: str
    symbol: str
    model: str  # inferred from symbol
    kind: str   # "nmos" or "pmos"
    L: float = 180e-9
    gmid_min: float = 5.0
    gmid_max: float = 20.0
    nf_min: int = 1
    nf_max: int = 10
    enabled: bool = True
    # Populated after optimisation
    best_gmid: Optional[float] = None
    best_W: Optional[float] = None
    best_Vgs: Optional[float] = None
    schematic_idx: int = -1  # instance index in schematic


@dataclass
class MeasureTarget:
    """A .meas directive parsed from a testbench."""
    testbench: str       # basename of the .chn_tb file
    tb_path: str         # full path
    name: str            # measure name (e.g. "dc_gain")
    analysis: str        # ac, tran, dc, etc.
    raw_line: str        # the original .meas line
    enabled: bool = True
    kind: str = "maximize"  # minimize, maximize, geq, leq, range
    target: float = 0.0
    target_upper: float = 0.0  # for range
    weight: float = 1.0


@dataclass
class HistoryRun:
    """One optimisation run record."""
    run_id: int
    date: str
    best_obj: float
    feasible: int
    total: int
    iterations: int
    transistors: dict[str, dict[str, Any]]  # instance -> {gmid, W, Vgs}
    targets: dict[str, float]  # measure_name -> best_value


# ---------------------------------------------------------------------------
# .chn_tb file parsing helpers
# ---------------------------------------------------------------------------

_MEAS_RE = re.compile(
    r"^\s*\.meas(?:ure)?\s+(\w+)\s+(\w+)\s+(.*)",
    re.IGNORECASE,
)


def _parse_chn_tb_file(path: str) -> dict:
    """Parse a .chn_tb file, extracting includes, instances, measures, code_block.

    Returns dict with keys:
      - name: testbench name
      - includes: list of include paths (model libs)
      - instances: list of (name, symbol) tuples
      - measures: list of {name, analysis, raw_line}
      - code_lines: list of raw SPICE code_block lines
      - analyses: list of analysis lines
    """
    result: dict[str, Any] = {
        "name": "",
        "includes": [],
        "instances": [],
        "measures": [],
        "code_lines": [],
        "analyses": [],
    }

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except OSError:
        return result

    section = ""
    for raw_line in content.splitlines():
        line = raw_line.rstrip()
        if not line:
            continue

        stripped = line.lstrip()
        indent = len(line) - len(stripped)

        # Top-level blocks (indent 0)
        if indent == 0:
            if stripped.startswith("TESTBENCH "):
                result["name"] = stripped[len("TESTBENCH "):].strip()
            section = ""
            continue

        # Sub-section headers (indent 1, i.e. 2 spaces)
        if indent <= 2 and stripped and not stripped[0].isspace():
            word = stripped.split()[0].rstrip(":")
            if word in ("instances", "includes", "measures", "code_block",
                        "analyses", "nets", "wires", "drawing", "pins", "params"):
                section = word
            else:
                section = ""
            continue

        # Section content (indent 2+)
        if section == "instances":
            parts = stripped.split()
            if len(parts) >= 2:
                inst_name = parts[0]
                inst_symbol = parts[1]
                result["instances"].append((inst_name, inst_symbol))

        elif section == "includes":
            result["includes"].append(stripped.strip())

        elif section == "measures":
            # Format: measure.name: .meas ac ... OR just name: value
            if ":" in stripped:
                _key, _, val = stripped.partition(":")
                val = val.strip()
                m = _MEAS_RE.match(val)
                if m:
                    result["measures"].append({
                        "name": m.group(2),
                        "analysis": m.group(1).lower(),
                        "raw_line": val,
                    })
                else:
                    # Try parsing measure name from key
                    mname = _key.strip()
                    if mname.startswith("measure."):
                        mname = mname[len("measure."):]
                    result["measures"].append({
                        "name": mname,
                        "analysis": "",
                        "raw_line": val,
                    })

        elif section == "code_block":
            result["code_lines"].append(stripped)
            # Also extract .meas from code_block lines
            m = _MEAS_RE.match(stripped)
            if m:
                result["measures"].append({
                    "name": m.group(2),
                    "analysis": m.group(1).lower(),
                    "raw_line": stripped,
                })

        elif section == "analyses":
            result["analyses"].append(stripped)

    return result


def _find_linked_testbenches(project_dir: str, component_name: str) -> list[str]:
    """Find all .chn_tb files in project_dir that reference the given component.

    A testbench references a component if it has an instance whose symbol
    matches the component name (the basename without extension).
    """
    linked = []
    if not project_dir or not os.path.isdir(project_dir):
        return linked

    for root, _dirs, files in os.walk(project_dir):
        for fname in files:
            if not fname.endswith(".chn_tb"):
                continue
            tb_path = os.path.join(root, fname)
            parsed = _parse_chn_tb_file(tb_path)
            # Check if any instance uses the component as its symbol
            for _inst_name, inst_symbol in parsed["instances"]:
                if inst_symbol == component_name or inst_symbol.endswith("/" + component_name):
                    linked.append(tb_path)
                    break
            else:
                # Also check includes for the .chn file
                for inc in parsed["includes"]:
                    base = os.path.splitext(os.path.basename(inc))[0]
                    if base == component_name:
                        linked.append(tb_path)
                        break

    return linked


def _kind_symbol(kind: str) -> str:
    """Short display symbol for target kind."""
    return {
        "maximize": "MAX",
        "minimize": "MIN",
        "geq": ">=",
        "leq": "<=",
        "range": "<=>",
    }.get(kind, kind.upper())


def _next_kind(kind: str) -> str:
    """Cycle through target kinds."""
    cycle = ["maximize", "minimize", "geq", "leq", "range"]
    try:
        idx = cycle.index(kind)
        return cycle[(idx + 1) % len(cycle)]
    except ValueError:
        return "maximize"


def _format_eng(val: float) -> str:
    """Format a float with engineering-style suffix."""
    if val == 0.0:
        return "0"
    abs_val = abs(val)
    if abs_val >= 1e9:
        return f"{val / 1e9:.2f}G"
    if abs_val >= 1e6:
        return f"{val / 1e6:.2f}M"
    if abs_val >= 1e3:
        return f"{val / 1e3:.2f}k"
    if abs_val >= 1:
        return f"{val:.3g}"
    if abs_val >= 1e-3:
        return f"{val * 1e3:.2f}m"
    if abs_val >= 1e-6:
        return f"{val * 1e6:.2f}u"
    if abs_val >= 1e-9:
        return f"{val * 1e9:.2f}n"
    return f"{val:.2e}"


# ---------------------------------------------------------------------------
# Plugin implementation
# ---------------------------------------------------------------------------

class GMIDOptimizerPlugin(schemify_plugin.Plugin):
    """Testbench-driven Bayesian gm/Id optimizer."""

    def __init__(self) -> None:
        # View state
        self._view: int = VIEW_SETUP
        self._status: str = "Ready"

        # Current file info (from state queries)
        self._current_file: str = ""
        self._project_dir: str = ""
        self._component_name: str = ""  # basename without extension
        self._is_chn: bool = False
        self._is_chn_tb: bool = False

        # Transistor entries from schematic
        self._transistors: list[TransistorEntry] = []
        self._pending_instance_query: bool = False

        # Testbench discovery
        self._testbenches: dict[str, dict] = {}  # path -> parsed tb data
        self._targets: list[MeasureTarget] = []

        # Settings
        self._max_iter: float = 50.0
        self._lhc_samples: float = 20.0
        self._vdd: float = 1.8

        # Optimisation state
        self._running: bool = False
        self._iteration: int = 0
        self._best_obj: float = float("inf")
        self._progress: float = 0.0
        self._log_lines: list[str] = []
        self._best_params: dict[str, Any] = {}
        self._opt_thread: Optional[threading.Thread] = None

        # Persistent history
        self._history: list[HistoryRun] = []

        # Pending state queries
        self._waiting_for_file: bool = False
        self._waiting_for_config: bool = False

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def on_load(self, w: schemify_plugin.Writer) -> None:
        w.register_panel(
            PLUGIN_ID, PANEL_TITLE, VIM_CMD,
            schemify_plugin.Layout.RIGHT_SIDEBAR, 0,
        )
        w.set_status("GMIDOptimizer loaded")
        w.log(0, TAG, "GMIDOptimizer plugin loaded (v2)")
        # Request current file info
        self._waiting_for_file = True
        w.get_state("current_file")
        w.get_state("project_dir")
        # Request persisted history
        self._waiting_for_config = True
        w.get_config(CONFIG_PLUGIN_ID, CONFIG_HISTORY_KEY)

    def on_unload(self, w: schemify_plugin.Writer) -> None:
        self._running = False
        w.log(0, TAG, "GMIDOptimizer unloaded")

    # ------------------------------------------------------------------
    # State / config responses
    # ------------------------------------------------------------------

    def on_state_response(self, key: str, val: str, w: schemify_plugin.Writer) -> None:
        if key == "current_file":
            self._current_file = val
            self._is_chn = val.endswith(".chn")
            self._is_chn_tb = val.endswith(".chn_tb")
            if self._is_chn:
                self._component_name = os.path.splitext(os.path.basename(val))[0]
            w.request_refresh()
        elif key == "project_dir":
            self._project_dir = val
            w.request_refresh()

    def _on_config_response(self, key: str, val: str, w: schemify_plugin.Writer) -> None:
        """Handle config_response (called from overridden process)."""
        if key == CONFIG_HISTORY_KEY and val:
            try:
                raw = json.loads(val)
                self._history = [
                    HistoryRun(
                        run_id=r.get("run_id", i),
                        date=r.get("date", ""),
                        best_obj=r.get("best_obj", 0.0),
                        feasible=r.get("feasible", 0),
                        total=r.get("total", 0),
                        iterations=r.get("iterations", 0),
                        transistors=r.get("transistors", {}),
                        targets=r.get("targets", {}),
                    )
                    for i, r in enumerate(raw)
                ]
            except (json.JSONDecodeError, TypeError, KeyError):
                pass
            w.request_refresh()

    def process(self, in_data: bytes) -> bytes:
        """Override process to also handle config_response and instance_prop."""
        r = schemify_plugin.Reader(in_data)
        w = schemify_plugin.Writer()
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
            elif t == "instance_data":
                self.on_instance_data(msg["idx"], msg["name"], msg["symbol"], w)
            elif t == "instance_prop":
                self._on_instance_prop(msg["idx"], msg["key"], msg["val"], w)
            elif t == "hover":
                self.on_hover(
                    msg["world_x"], msg["world_y"], msg["element_type"],
                    msg["element_idx"], msg["element_name"], w,
                )
            elif t == "key_event":
                self.on_key_event(msg["key"], msg["mods"], msg["action"], w)
        return w.get_bytes()

    # ------------------------------------------------------------------
    # Schematic instance callbacks
    # ------------------------------------------------------------------

    def on_instance_data(self, idx: int, name: str, symbol: str,
                         w: schemify_plugin.Writer) -> None:
        if not self._pending_instance_query:
            return
        if symbol in MOSFET_SYMBOLS:
            kind = "pmos" if "pmos" in symbol or "pmoshv" in symbol else "nmos"
            model = "pfet" if kind == "pmos" else "nfet"
            # Check for duplicates
            for t in self._transistors:
                if t.instance == name:
                    t.schematic_idx = idx
                    return
            self._transistors.append(TransistorEntry(
                instance=name,
                symbol=symbol,
                model=model,
                kind=kind,
                L=180e-9,
                schematic_idx=idx,
            ))

    def _on_instance_prop(self, idx: int, key: str, val: str,
                          w: schemify_plugin.Writer) -> None:
        """Update transistor properties from schematic (L, model, etc.)."""
        for t in self._transistors:
            if t.schematic_idx == idx:
                if key.lower() == "l":
                    try:
                        t.L = float(val)
                    except ValueError:
                        pass
                elif key.lower() == "model":
                    t.model = val
                break

    def on_schematic_changed(self, w: schemify_plugin.Writer) -> None:
        # Re-query state on schematic change
        w.get_state("current_file")
        w.get_state("project_dir")

    # ------------------------------------------------------------------
    # Tick -- poll background thread
    # ------------------------------------------------------------------

    def on_tick(self, dt: float, w: schemify_plugin.Writer) -> None:
        if self._opt_thread and not self._opt_thread.is_alive():
            self._opt_thread = None
            if self._view == VIEW_RUNNING:
                self._view = VIEW_HISTORY
                self._status = "Optimization complete"
                w.request_refresh()

    # ------------------------------------------------------------------
    # Drawing
    # ------------------------------------------------------------------

    def on_draw_panel(self, panel_id: int, w: schemify_plugin.Writer) -> None:
        w.label("gm/ID Optimizer", 0)
        w.separator(4)

        # File type check message
        if self._is_chn_tb:
            w.label("Open a .chn component to optimize.", 5)
            w.label("This is a testbench file.", 6)
            return

        if not self._is_chn and self._current_file:
            w.label("Open a .chn component to optimize.", 5)
            return

        # View tabs
        w.begin_row(7)
        tab_labels = {VIEW_SETUP: "Setup", VIEW_RUNNING: "Running", VIEW_HISTORY: "History"}
        for vid, label in tab_labels.items():
            marker = "> " if self._view == vid else "  "
            w.button(f"{marker}{label}", WID_TAB_SETUP + vid)
        w.end_row(7)
        w.separator(8)

        if self._view == VIEW_SETUP:
            self._draw_setup(w)
        elif self._view == VIEW_RUNNING:
            self._draw_running(w)
        elif self._view == VIEW_HISTORY:
            self._draw_history(w)

        # Status bar at bottom
        w.separator(9)
        w.label(f"Status: {self._status}", 9)

    def _draw_setup(self, w: schemify_plugin.Writer) -> None:
        # -- Transistors section --
        n_enabled = sum(1 for t in self._transistors if t.enabled)
        w.collapsible_start(
            f"Transistors ({n_enabled}/{len(self._transistors)})", True, 30,
        )

        if not self._transistors:
            w.label("  No MOSFETs found. Click Scan Schematic.", 31)
        else:
            for i, t in enumerate(self._transistors):
                l_um = t.L * 1e6 if t.L < 1e-3 else t.L
                header = (
                    f"  {t.instance}: {t.kind} L={l_um:.3f}um "
                    f"gm/Id=[{t.gmid_min:.0f},{t.gmid_max:.0f}] "
                    f"nf=[{t.nf_min},{t.nf_max}]"
                )
                w.checkbox(t.enabled, header, WID_TRANS_ENABLE + i)

                if t.enabled and i < 50:  # cap UI elements
                    w.begin_row(WID_TRANS_GMID_MIN + i * 2)
                    w.label(f"    gm/Id: {t.gmid_min:.0f}", WID_TRANS_GMID_MIN + i * 2)
                    w.slider(t.gmid_min, 1.0, 30.0, WID_TRANS_GMID_MIN + i * 2)
                    w.end_row(WID_TRANS_GMID_MIN + i * 2)

                    w.begin_row(WID_TRANS_GMID_MIN + i * 2 + 1)
                    w.label(f"         to {t.gmid_max:.0f}", WID_TRANS_GMID_MIN + i * 2 + 1)
                    w.slider(t.gmid_max, 1.0, 30.0, WID_TRANS_GMID_MIN + i * 2 + 1)
                    w.end_row(WID_TRANS_GMID_MIN + i * 2 + 1)

                    w.begin_row(WID_TRANS_NF_MIN + i * 2)
                    w.label(f"    nf: {t.nf_min}", WID_TRANS_NF_MIN + i * 2)
                    w.slider(float(t.nf_min), 1.0, 50.0, WID_TRANS_NF_MIN + i * 2)
                    w.end_row(WID_TRANS_NF_MIN + i * 2)

                    w.begin_row(WID_TRANS_NF_MIN + i * 2 + 1)
                    w.label(f"       to {t.nf_max}", WID_TRANS_NF_MIN + i * 2 + 1)
                    w.slider(float(t.nf_max), 1.0, 50.0, WID_TRANS_NF_MIN + i * 2 + 1)
                    w.end_row(WID_TRANS_NF_MIN + i * 2 + 1)

        w.collapsible_end(30)

        w.button("Scan Schematic for MOSFETs", WID_BTN_SCAN)
        w.separator(39)

        # -- Testbench targets section --
        w.collapsible_start(
            f"Optimization Targets ({sum(1 for t in self._targets if t.enabled)}"
            f"/{len(self._targets)} enabled)",
            True, 40,
        )

        if not self._targets:
            w.label("  No testbenches found.", 41)
            w.label("  Click Discover Testbenches.", 42)
        else:
            # Table header
            w.label("  TB | Measure | Kind | Target | Weight", 43)
            w.separator(44)

            for i, tgt in enumerate(self._targets):
                if i >= 200:
                    w.label(f"  ... and {len(self._targets) - 200} more", 45)
                    break

                tb_short = os.path.basename(tgt.testbench)
                kind_str = _kind_symbol(tgt.kind)
                tgt_str = _format_eng(tgt.target) if tgt.target != 0.0 else ""
                if tgt.kind == "range" and tgt.target_upper != 0.0:
                    tgt_str = f"{_format_eng(tgt.target)}-{_format_eng(tgt.target_upper)}"

                row_text = (
                    f"  {tb_short} | {tgt.name} | {kind_str} | "
                    f"{tgt_str} | w={tgt.weight:.1f}"
                )
                w.checkbox(tgt.enabled, row_text, WID_TARGET_CB + i)

                if tgt.enabled:
                    w.begin_row(WID_TARGET_KIND + i)
                    w.button(f"Kind: {kind_str}", WID_TARGET_KIND + i)
                    w.slider(tgt.weight, 0.0, 2.0, WID_TARGET_WEIGHT + i)
                    w.end_row(WID_TARGET_KIND + i)

                    if tgt.kind in ("geq", "leq", "range"):
                        w.begin_row(WID_TARGET_VAL + i)
                        w.label(f"    Target: {_format_eng(tgt.target)}", WID_TARGET_VAL + i)
                        w.slider(tgt.target, -1e6, 1e6, WID_TARGET_VAL + i)
                        w.end_row(WID_TARGET_VAL + i)

        w.collapsible_end(40)

        w.button("Discover Testbenches", WID_BTN_SCAN_TB)
        w.separator(49)

        # -- Settings section --
        w.collapsible_start("Settings", True, 50)
        w.label(f"Max iterations: {int(self._max_iter)}", 51)
        w.slider(self._max_iter, 10.0, 500.0, WID_SLIDER_MAX_ITER)
        w.label(f"Initial LHC samples: {int(self._lhc_samples)}", 52)
        w.slider(self._lhc_samples, 5.0, 100.0, WID_SLIDER_LHC)
        w.label(f"VDD: {self._vdd:.2f} V", 53)
        w.slider(self._vdd, 0.6, 5.0, WID_SLIDER_VDD)
        w.collapsible_end(50)

        w.separator(59)

        # -- Action buttons --
        can_start = (
            len([t for t in self._transistors if t.enabled]) > 0
            and len([t for t in self._targets if t.enabled]) > 0
        )
        if can_start:
            w.button("Start Optimization", WID_BTN_START)
        else:
            if not self._transistors:
                w.label("Scan schematic for MOSFETs first.", 60)
            elif not self._targets:
                w.label("Discover testbenches for targets first.", 60)
            else:
                w.label("Enable at least one transistor and target.", 60)

        w.button("Clear All", WID_BTN_CLEAR)

    def _draw_running(self, w: schemify_plugin.Writer) -> None:
        total = int(self._max_iter)
        w.label(f"Iteration {self._iteration}/{total}", WID_RUN_PROGRESS)
        w.progress(self._progress, WID_RUN_PROGRESS + 1)
        w.separator(WID_RUN_PROGRESS + 2)

        best_str = f"{self._best_obj:.4g}" if self._best_obj < 1e9 else "---"
        w.label(f"Best objective: {best_str}", WID_RUN_PROGRESS + 3)
        w.label(
            f"Transistors: {sum(1 for t in self._transistors if t.enabled)} | "
            f"Targets: {sum(1 for t in self._targets if t.enabled)}",
            WID_RUN_PROGRESS + 4,
        )
        w.separator(WID_RUN_PROGRESS + 5)

        # Best params so far
        if self._best_params:
            w.collapsible_start("Best Design So Far", True, WID_RUN_PROGRESS + 6)
            wid = WID_RUN_PROGRESS + 7
            for inst, params in self._best_params.items():
                if isinstance(params, dict):
                    gmid = params.get("gm/Id", 0)
                    w_um = params.get("W_um", 0)
                    vgs = params.get("Vgs", 0)
                    w.label(
                        f"  {inst}: gm/Id={gmid:.1f}  W={w_um:.2f}um  Vgs={vgs:.3f}V",
                        wid,
                    )
                    wid += 1
            w.collapsible_end(WID_RUN_PROGRESS + 6)

        # Live log
        w.collapsible_start("Log", True, WID_RUN_LOG_BASE)
        for i, line in enumerate(self._log_lines[-15:]):
            w.label(f"  {line}", WID_RUN_LOG_BASE + 1 + i)
        w.collapsible_end(WID_RUN_LOG_BASE)

        w.separator(WID_RUN_LOG_BASE + 20)
        if self._running:
            w.button("Stop", WID_BTN_STOP)
        else:
            w.button("Back to Setup", WID_TAB_SETUP + VIEW_SETUP)

    def _draw_history(self, w: schemify_plugin.Writer) -> None:
        if not self._history:
            w.label("No optimization runs yet.", WID_HIST_BASE)
            w.label("Run an optimization to see results here.", WID_HIST_BASE + 1)
            return

        w.label(
            "Run | Date       | Best Obj | Feasible | Iters | Transistors",
            WID_HIST_BASE,
        )
        w.separator(WID_HIST_BASE + 1)

        for i, run in enumerate(reversed(self._history)):
            if i >= 50:
                w.label(f"  ... {len(self._history) - 50} more runs", WID_HIST_BASE + 2 + i)
                break

            # Build transistor summary
            parts = []
            for inst, params in run.transistors.items():
                if isinstance(params, dict):
                    gmid = params.get("gm/Id", params.get("gmid", 0))
                    w_um = params.get("W_um", params.get("W", 0))
                    vgs = params.get("Vgs", params.get("vgs", 0))
                    parts.append(f"{inst}:{gmid:.1f}/{w_um:.2f}um/{vgs:.2f}V")
                else:
                    parts.append(f"{inst}:{params}")
            trans_str = " ".join(parts) if parts else "---"

            best_str = f"{run.best_obj:.3g}" if abs(run.best_obj) < 1e9 else "N/A"
            row = (
                f"{run.run_id:>3} | {run.date:<10} | {best_str:>8} | "
                f"{run.feasible:>3}/{run.total:<3} | {run.iterations:>4} | {trans_str}"
            )
            w.label(row, WID_HIST_BASE + 2 + i)

            # Show target results if available
            if run.targets:
                tgt_parts = [f"{k}={_format_eng(v)}" for k, v in run.targets.items()]
                w.label(f"     Targets: {', '.join(tgt_parts)}", WID_HIST_BASE + 100 + i)

        w.separator(WID_HIST_BASE + 160)

        # Apply best result button
        if self._history:
            w.button("Apply Best to Schematic", WID_BTN_APPLY_BEST)

    # ------------------------------------------------------------------
    # Event handlers
    # ------------------------------------------------------------------

    def on_button_clicked(self, panel_id: int, widget_id: int,
                          w: schemify_plugin.Writer) -> None:
        # View tab buttons
        if widget_id == WID_TAB_SETUP + VIEW_SETUP:
            self._view = VIEW_SETUP
            w.request_refresh()
            return
        if widget_id == WID_TAB_SETUP + VIEW_RUNNING:
            self._view = VIEW_RUNNING
            w.request_refresh()
            return
        if widget_id == WID_TAB_SETUP + VIEW_HISTORY:
            self._view = VIEW_HISTORY
            w.request_refresh()
            return

        # Action buttons
        if widget_id == WID_BTN_START:
            self._start_optimization(w)
            w.request_refresh()
            return
        if widget_id == WID_BTN_STOP:
            self._running = False
            self._status = "Stopping..."
            w.request_refresh()
            return
        if widget_id == WID_BTN_SCAN:
            self._scan_schematic(w)
            w.request_refresh()
            return
        if widget_id == WID_BTN_SCAN_TB:
            self._discover_testbenches(w)
            w.request_refresh()
            return
        if widget_id == WID_BTN_CLEAR:
            self._reset()
            w.request_refresh()
            return
        if widget_id == WID_BTN_APPLY_BEST:
            self._apply_best_to_schematic(w)
            return

        # Target kind cycle buttons
        if WID_TARGET_KIND <= widget_id < WID_TARGET_KIND + 300:
            idx = widget_id - WID_TARGET_KIND
            if 0 <= idx < len(self._targets):
                self._targets[idx].kind = _next_kind(self._targets[idx].kind)
                w.request_refresh()
            return

    def on_slider_changed(self, panel_id: int, widget_id: int,
                          val: float, w: schemify_plugin.Writer) -> None:
        # Settings sliders
        if widget_id == WID_SLIDER_MAX_ITER:
            self._max_iter = val
            return
        if widget_id == WID_SLIDER_LHC:
            self._lhc_samples = val
            return
        if widget_id == WID_SLIDER_VDD:
            self._vdd = val
            return

        # Transistor gmid sliders
        if WID_TRANS_GMID_MIN <= widget_id < WID_TRANS_GMID_MIN + 200:
            offset = widget_id - WID_TRANS_GMID_MIN
            idx = offset // 2
            is_max = (offset % 2) == 1
            if 0 <= idx < len(self._transistors):
                if is_max:
                    self._transistors[idx].gmid_max = max(val, self._transistors[idx].gmid_min + 1)
                else:
                    self._transistors[idx].gmid_min = min(val, self._transistors[idx].gmid_max - 1)
            return

        # Transistor nf sliders
        if WID_TRANS_NF_MIN <= widget_id < WID_TRANS_NF_MIN + 200:
            offset = widget_id - WID_TRANS_NF_MIN
            idx = offset // 2
            is_max = (offset % 2) == 1
            if 0 <= idx < len(self._transistors):
                ival = max(1, int(val))
                if is_max:
                    self._transistors[idx].nf_max = max(ival, self._transistors[idx].nf_min)
                else:
                    self._transistors[idx].nf_min = min(ival, self._transistors[idx].nf_max)
            return

        # Target weight sliders
        if WID_TARGET_WEIGHT <= widget_id < WID_TARGET_WEIGHT + 300:
            idx = widget_id - WID_TARGET_WEIGHT
            if 0 <= idx < len(self._targets):
                self._targets[idx].weight = max(0.0, val)
            return

        # Target value sliders
        if WID_TARGET_VAL <= widget_id < WID_TARGET_VAL + 300:
            idx = widget_id - WID_TARGET_VAL
            if 0 <= idx < len(self._targets):
                self._targets[idx].target = val
            return

    def on_checkbox_changed(self, panel_id: int, widget_id: int,
                            val: bool, w: schemify_plugin.Writer) -> None:
        # Transistor enable checkboxes
        if WID_TRANS_ENABLE <= widget_id < WID_TRANS_ENABLE + 200:
            idx = widget_id - WID_TRANS_ENABLE
            if 0 <= idx < len(self._transistors):
                self._transistors[idx].enabled = val
            w.request_refresh()
            return

        # Target enable checkboxes
        if WID_TARGET_CB <= widget_id < WID_TARGET_CB + 300:
            idx = widget_id - WID_TARGET_CB
            if 0 <= idx < len(self._targets):
                self._targets[idx].enabled = val
            w.request_refresh()
            return

    # ------------------------------------------------------------------
    # Command interface (vim :gmidopt <subcommand>)
    # ------------------------------------------------------------------

    def on_command(self, tag: str, payload: str, w: schemify_plugin.Writer) -> None:
        if tag != VIM_CMD:
            return

        parts = payload.strip().split()
        subcmd = parts[0].lower() if parts else ""
        args = parts[1:]

        if subcmd == "scan":
            self._scan_schematic(w)
            self._discover_testbenches(w)
            w.set_status(
                f"[gmidopt] Scanned: {len(self._transistors)} MOSFET(s), "
                f"{len(self._testbenches)} testbench(es), {len(self._targets)} target(s)"
            )

        elif subcmd == "targets":
            self._cmd_list_targets(w)

        elif subcmd == "set-target":
            self._cmd_set_target(args, w)

        elif subcmd == "transistors":
            self._cmd_list_transistors(w)

        elif subcmd == "start":
            if self._running:
                w.set_status("[gmidopt] Optimization already running")
            else:
                self._start_optimization(w)
                w.set_status("[gmidopt] Optimization started")

        elif subcmd == "stop":
            if not self._running:
                w.set_status("[gmidopt] No optimization running")
            else:
                self._running = False
                self._status = "Stopping..."
                w.set_status("[gmidopt] Stopping optimization...")
                w.request_refresh()

        elif subcmd == "status":
            self._cmd_status(w)

        elif subcmd == "apply-best":
            self._apply_best_to_schematic(w)
            w.set_status(f"[gmidopt] {self._status}")

        elif subcmd == "results":
            self._cmd_results(w)

        else:
            w.set_status(
                "[gmidopt] Unknown subcommand. "
                "Available: scan, targets, set-target, transistors, "
                "start, stop, status, apply-best, results"
            )

    # -- Command helpers ------------------------------------------------

    def _cmd_list_targets(self, w: schemify_plugin.Writer) -> None:
        if not self._targets:
            w.set_status("[gmidopt] No targets discovered. Run :gmidopt scan first, then ensure testbenches exist.")
            return
        lines = [f"[gmidopt] {len(self._targets)} target(s):"]
        for i, tgt in enumerate(self._targets):
            en = "ON" if tgt.enabled else "OFF"
            tgt_str = _format_eng(tgt.target) if tgt.target != 0.0 else "-"
            lines.append(
                f"  [{i}] {tgt.name} ({tgt.testbench}) "
                f"kind={tgt.kind} target={tgt_str} weight={tgt.weight:.2f} [{en}]"
            )
        msg = "\n".join(lines)
        w.set_status(msg)
        w.log(0, TAG, msg)

    def _cmd_set_target(self, args: list[str], w: schemify_plugin.Writer) -> None:
        # Usage: set-target <name> <kind> <value> [weight]
        if len(args) < 3:
            w.set_status(
                "[gmidopt] Usage: :gmidopt set-target <name> <kind> <value> [weight]  "
                "(kind: minimize, maximize, target)"
            )
            return

        name = args[0]
        kind_arg = args[1].lower()
        try:
            value = float(args[2])
        except ValueError:
            w.set_status(f"[gmidopt] Invalid value: {args[2]}")
            return

        weight: Optional[float] = None
        if len(args) >= 4:
            try:
                weight = float(args[3])
                weight = max(0.0, min(1.0, weight))
            except ValueError:
                w.set_status(f"[gmidopt] Invalid weight: {args[3]}")
                return

        # Map 'target' kind to internal representation
        kind_map = {
            "minimize": "minimize",
            "maximize": "maximize",
            "target": "geq",  # 'target' means match a specific value; use geq with target
        }
        internal_kind = kind_map.get(kind_arg)
        if internal_kind is None:
            w.set_status(f"[gmidopt] Invalid kind '{kind_arg}'. Use: minimize, maximize, target")
            return

        # Find the target by name
        matched = [t for t in self._targets if t.name == name]
        if not matched:
            w.set_status(
                f"[gmidopt] Target '{name}' not found. "
                f"Available: {', '.join(t.name for t in self._targets)}"
            )
            return

        for tgt in matched:
            tgt.kind = internal_kind
            tgt.target = value
            tgt.enabled = True
            if weight is not None:
                tgt.weight = weight

        w_str = f" weight={weight:.2f}" if weight is not None else ""
        w.set_status(
            f"[gmidopt] Set target '{name}': kind={kind_arg} value={_format_eng(value)}{w_str}"
        )
        w.request_refresh()

    def _cmd_list_transistors(self, w: schemify_plugin.Writer) -> None:
        if not self._transistors:
            w.set_status("[gmidopt] No transistors found. Run :gmidopt scan first.")
            return
        lines = [f"[gmidopt] {len(self._transistors)} transistor(s):"]
        for i, t in enumerate(self._transistors):
            en = "ON" if t.enabled else "OFF"
            l_um = t.L * 1e6 if t.L < 1e-3 else t.L
            best = ""
            if t.best_gmid is not None:
                best = f" best_gmid={t.best_gmid:.1f}"
            if t.best_W is not None:
                best += f" best_W={t.best_W:.3f}um"
            if t.best_Vgs is not None:
                best += f" best_Vgs={t.best_Vgs:.3f}V"
            lines.append(
                f"  [{i}] {t.instance} ({t.kind}, {t.symbol}) "
                f"L={l_um:.3f}um gm/Id=[{t.gmid_min:.0f},{t.gmid_max:.0f}] "
                f"nf=[{t.nf_min},{t.nf_max}] [{en}]{best}"
            )
        msg = "\n".join(lines)
        w.set_status(msg)
        w.log(0, TAG, msg)

    def _cmd_status(self, w: schemify_plugin.Writer) -> None:
        state = "running" if self._running else "idle"
        best_str = f"{self._best_obj:.4g}" if self._best_obj < 1e9 else "---"
        n_trans = len([t for t in self._transistors if t.enabled])
        n_tgt = len([t for t in self._targets if t.enabled])
        progress = f" iter={self._iteration}/{int(self._max_iter)}" if self._running else ""
        msg = (
            f"[gmidopt] status={state}{progress} best_obj={best_str} "
            f"transistors={n_trans} targets={n_tgt} history_runs={len(self._history)}"
        )
        w.set_status(msg)
        w.log(0, TAG, msg)

    def _cmd_results(self, w: schemify_plugin.Writer) -> None:
        if not self._history:
            w.set_status("[gmidopt] No optimization results yet.")
            return

        latest = self._history[-1]
        lines = [
            f"[gmidopt] Latest run #{latest.run_id} ({latest.date}):",
            f"  objective={latest.best_obj:.4g} feasible={latest.feasible}/{latest.total} "
            f"iterations={latest.iterations}",
        ]

        if latest.transistors:
            lines.append("  Transistors:")
            for inst, params in latest.transistors.items():
                if isinstance(params, dict):
                    gmid = params.get("gm/Id", params.get("gmid", 0))
                    w_um = params.get("W_um", params.get("W", 0))
                    vgs = params.get("Vgs", params.get("vgs", 0))
                    lines.append(f"    {inst}: gm/Id={gmid:.1f} W={w_um:.3f}um Vgs={vgs:.3f}V")

        if latest.targets:
            lines.append("  Targets:")
            for name, val in latest.targets.items():
                lines.append(f"    {name}={_format_eng(val)}")

        msg = "\n".join(lines)
        w.set_status(msg)
        w.log(0, TAG, msg)

    # ------------------------------------------------------------------
    # Actions
    # ------------------------------------------------------------------

    def _scan_schematic(self, w: schemify_plugin.Writer) -> None:
        """Query schematic for MOSFET instances."""
        self._pending_instance_query = True
        w.query_instances()
        self._status = "Scanning schematic for MOSFETs..."
        w.log(0, TAG, "Querying schematic instances")

    def _discover_testbenches(self, w: schemify_plugin.Writer) -> None:
        """Scan project directory for .chn_tb files referencing this component."""
        if not self._component_name:
            self._status = "No component file detected"
            w.log(1, TAG, "Cannot discover testbenches: no .chn file open")
            return

        project_dir = self._project_dir or os.path.dirname(self._current_file) or "."
        w.log(0, TAG, f"Scanning {project_dir} for testbenches referencing {self._component_name}")

        tb_paths = _find_linked_testbenches(project_dir, self._component_name)

        # Also try scanning the directory of the current file
        cur_dir = os.path.dirname(self._current_file) if self._current_file else ""
        if cur_dir and cur_dir != project_dir:
            tb_paths.extend(_find_linked_testbenches(cur_dir, self._component_name))

        # Deduplicate
        seen = set()
        unique_paths = []
        for p in tb_paths:
            rp = os.path.realpath(p)
            if rp not in seen:
                seen.add(rp)
                unique_paths.append(p)

        # If no linked TBs found, try all .chn_tb files in the same directory
        if not unique_paths and cur_dir:
            for fname in os.listdir(cur_dir):
                if fname.endswith(".chn_tb"):
                    p = os.path.join(cur_dir, fname)
                    rp = os.path.realpath(p)
                    if rp not in seen:
                        seen.add(rp)
                        unique_paths.append(p)

        self._testbenches = {}
        self._targets = []

        for tb_path in unique_paths:
            parsed = _parse_chn_tb_file(tb_path)
            self._testbenches[tb_path] = parsed
            tb_name = os.path.basename(tb_path)

            for meas in parsed["measures"]:
                # Deduplicate by (tb_path, measure_name)
                already = any(
                    t.tb_path == tb_path and t.name == meas["name"]
                    for t in self._targets
                )
                if already:
                    continue

                self._targets.append(MeasureTarget(
                    testbench=tb_name,
                    tb_path=tb_path,
                    name=meas["name"],
                    analysis=meas.get("analysis", ""),
                    raw_line=meas.get("raw_line", ""),
                ))

        n_tb = len(self._testbenches)
        n_meas = len(self._targets)
        self._status = f"Found {n_tb} testbench(es), {n_meas} measure(s)"
        w.log(0, TAG, self._status)

    def _reset(self) -> None:
        """Reset all state except history."""
        self._view = VIEW_SETUP
        self._running = False
        self._iteration = 0
        self._best_obj = float("inf")
        self._progress = 0.0
        self._log_lines = []
        self._best_params = {}
        self._transistors = []
        self._targets = []
        self._testbenches = {}
        self._status = "Ready"

    def _apply_best_to_schematic(self, w: schemify_plugin.Writer) -> None:
        """Apply the best result from the latest history run to the schematic."""
        if not self._history:
            self._status = "No results to apply"
            return

        latest = self._history[-1]
        applied = 0

        for t in self._transistors:
            if t.instance in latest.transistors:
                params = latest.transistors[t.instance]
                w_val = params.get("W_um", params.get("W", None))
                if w_val is not None and t.schematic_idx >= 0:
                    # Convert W from um to meters for the schematic property
                    w_m = w_val * 1e-6 if w_val > 1e-3 else w_val
                    w.set_instance_prop(t.schematic_idx, "W", f"{w_m:.4e}")
                    applied += 1

        self._status = f"Applied sizing to {applied} transistor(s)"
        w.log(0, TAG, self._status)
        w.request_refresh()

    # ------------------------------------------------------------------
    # Optimisation
    # ------------------------------------------------------------------

    def _start_optimization(self, w: schemify_plugin.Writer) -> None:
        """Launch optimisation in a background thread."""
        if self._running:
            return

        enabled_trans = [t for t in self._transistors if t.enabled]
        enabled_targets = [t for t in self._targets if t.enabled]

        if not enabled_trans or not enabled_targets:
            self._status = "Need at least one transistor and one target"
            return

        self._view = VIEW_RUNNING
        self._running = True
        self._iteration = 0
        self._progress = 0.0
        self._log_lines = []
        self._best_obj = float("inf")
        self._best_params = {}
        self._status = "Starting optimization..."

        self._opt_thread = threading.Thread(
            target=self._optimization_loop,
            args=(enabled_trans, enabled_targets),
            daemon=True,
        )
        self._opt_thread.start()

    def _optimization_loop(
        self,
        transistors: list[TransistorEntry],
        targets: list[MeasureTarget],
    ) -> None:
        """Background optimisation loop using gmid_optimizer library."""
        try:
            from gmid_optimizer import (
                GMIDOptimizer,
                Problem,
                Transistor,
                Specification,
                SpecKind,
            )
            from gmid_optimizer.problem import Testbench
            from gmid_optimizer.config import OptimizerConfig, build_block

            kind_map = {
                "maximize": SpecKind.MAXIMIZE,
                "minimize": SpecKind.MINIMIZE,
                "geq": SpecKind.GREATER_EQUAL,
                "leq": SpecKind.LESS_EQUAL,
                "range": SpecKind.RANGE,
            }

            # Build Problem from UI state
            prob_transistors = []
            for t in transistors:
                prob_transistors.append(Transistor(
                    instance=t.instance,
                    model=t.model,
                    kind=t.kind,
                    L=t.L,
                    gmid_min=t.gmid_min,
                    gmid_max=t.gmid_max,
                    nf_min=t.nf_min,
                    nf_max=t.nf_max,
                ))

            # Group targets by testbench path
            tb_map: dict[str, list[MeasureTarget]] = {}
            for tgt in targets:
                tb_map.setdefault(tgt.tb_path, []).append(tgt)

            prob_testbenches = []
            for tb_path, tgts in tb_map.items():
                specs = []
                for tgt in tgts:
                    specs.append(Specification(
                        name=tgt.name,
                        kind=kind_map.get(tgt.kind, SpecKind.MAXIMIZE),
                        target=tgt.target,
                        target_upper=tgt.target_upper if tgt.kind == "range" else None,
                        weight=tgt.weight,
                    ))
                prob_testbenches.append(Testbench(
                    path=tb_path,
                    name=os.path.basename(tb_path),
                    specs=specs,
                ))

            problem = Problem(
                transistors=prob_transistors,
                testbenches=prob_testbenches,
            )

            self._log_lines.append(
                f"Problem: {len(prob_transistors)} transistors, "
                f"{len(prob_testbenches)} testbenches, "
                f"{problem.design_variable_count} design vars"
            )

            # Determine model library path from testbench includes
            model_lib = ""
            for tb_path, parsed in self._testbenches.items():
                for inc in parsed.get("includes", []):
                    if any(ext in inc.lower() for ext in (".lib", ".mod", ".spice", ".scs")):
                        model_lib = inc
                        break
                if model_lib:
                    break

            optimizer = GMIDOptimizer(
                problem=problem,
                model_lib_path=model_lib,
                vdd=self._vdd,
                max_iter=int(self._max_iter),
                initial_samples=int(self._lhc_samples),
            )

            self._log_lines.append("Running characterization...")
            try:
                optimizer.characterize()
                self._log_lines.append("Characterization complete")
            except Exception as e:
                self._log_lines.append(f"Characterization failed: {e}")
                self._log_lines.append("Running optimization without lookup tables...")

            # Run with progress callback
            feasible_count = 0

            def progress_cb(iteration: int, obs: Any) -> None:
                if not self._running:
                    raise StopIteration("User stopped optimization")

                self._iteration = iteration + 1
                self._progress = (iteration + 1) / int(self._max_iter)

                status = "OK" if obs.is_feasible else "infeasible"
                if obs.is_feasible:
                    nonlocal feasible_count
                    feasible_count += 1

                obj_str = f"{obs.objectives[0]:.4g}" if len(obs.objectives) > 0 else "---"
                self._log_lines.append(
                    f"  [{iteration + 1}] obj={obj_str} {status} "
                    f"({len(obs.measurements)} meas)"
                )

                # Update best params from optimizer
                best = optimizer._backend.best() if optimizer._backend else None
                if best is not None:
                    decoded = optimizer._decode_params(best["params"])
                    self._best_params = decoded
                    self._best_obj = float(best["objectives"][0])

            try:
                result = optimizer.run(callback=progress_cb)
            except StopIteration:
                self._log_lines.append("Optimization stopped by user.")
                self._running = False
                return

            # Extract final results
            if result.best_params:
                self._best_params = result.best_params
            if result.best_objectives is not None and len(result.best_objectives) > 0:
                self._best_obj = float(result.best_objectives[0])
            self._iteration = result.iterations

            self._log_lines.append(
                f"Done: {result.feasible_count}/{result.iterations} feasible"
            )

            # Update transistor entries with best values
            for t in transistors:
                if t.instance in self._best_params:
                    p = self._best_params[t.instance]
                    if isinstance(p, dict):
                        t.best_gmid = p.get("gm/Id")
                        t.best_W = p.get("W_um")
                        t.best_Vgs = p.get("Vgs")

            # Collect best target measurements from result
            best_measurements: dict[str, float] = {}
            if result.observations:
                # Find the best feasible observation
                best_obs = None
                for obs in result.observations:
                    if obs.is_feasible:
                        if best_obs is None or obs.objectives[0] < best_obs.objectives[0]:
                            best_obs = obs
                if best_obs and best_obs.measurements:
                    best_measurements = {
                        k: float(v) for k, v in best_obs.measurements.items()
                    }

            # Append to history
            run_id = len(self._history) + 1
            run_record = HistoryRun(
                run_id=run_id,
                date=time.strftime("%Y-%m-%d"),
                best_obj=self._best_obj,
                feasible=result.feasible_count,
                total=result.iterations,
                iterations=result.iterations,
                transistors={
                    inst: params
                    for inst, params in self._best_params.items()
                    if isinstance(params, dict)
                },
                targets=best_measurements,
            )
            self._history.append(run_record)
            self._status = f"Complete: {result.feasible_count}/{result.iterations} feasible"

        except ImportError as e:
            self._log_lines.append(f"Missing dependency: {e}")
            self._log_lines.append("Install: pip install gmid-optimizer torch botorch gpytorch scipy")
            self._status = "Missing dependencies"
        except Exception as e:
            self._log_lines.append(f"Error: {e}")
            self._log_lines.append(traceback.format_exc().splitlines()[-1])
            self._status = f"Failed: {e}"
        finally:
            self._running = False
            self._progress = 1.0
            # Persist history (best-effort, done on next draw via on_tick)

    def _persist_history(self, w: schemify_plugin.Writer) -> None:
        """Serialise run history to plugin config."""
        records = []
        for run in self._history:
            # Convert numpy/float values to plain Python for JSON
            trans = {}
            for inst, params in run.transistors.items():
                if isinstance(params, dict):
                    trans[inst] = {
                        k: float(v) if hasattr(v, "__float__") else v
                        for k, v in params.items()
                    }
                else:
                    trans[inst] = params
            tgts = {
                k: float(v) if hasattr(v, "__float__") else v
                for k, v in run.targets.items()
            }
            records.append({
                "run_id": run.run_id,
                "date": run.date,
                "best_obj": float(run.best_obj) if abs(run.best_obj) < 1e15 else 0.0,
                "feasible": run.feasible,
                "total": run.total,
                "iterations": run.iterations,
                "transistors": trans,
                "targets": tgts,
            })
        w.set_config(CONFIG_PLUGIN_ID, CONFIG_HISTORY_KEY, json.dumps(records))


# ---------------------------------------------------------------------------
# Module-level singleton + entry points
# ---------------------------------------------------------------------------

_plugin = GMIDOptimizerPlugin()


def schemify_process(in_bytes: bytes) -> bytes:
    out = _plugin.process(in_bytes)
    # After processing, persist history if optimisation just finished
    # We piggyback on the response: build an extra Writer for the persist call
    if (
        _plugin._history
        and not _plugin._running
        and _plugin._opt_thread is None
        and _plugin._progress >= 1.0
    ):
        pw = schemify_plugin.Writer()
        _plugin._persist_history(pw)
        extra = pw.get_bytes()
        if extra:
            out = out + extra
            # Reset progress so we don't persist again on next tick
            _plugin._progress = 0.99
    return out
