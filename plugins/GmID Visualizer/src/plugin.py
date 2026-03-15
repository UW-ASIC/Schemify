"""
GmID Visualizer — pure Python plugin for Schemify.

Implements the same panel, state, and runner logic that was previously
split across main.zig / panel.zig / runner.zig / state.zig, using the
Python SDK and the existing gmid_runner.py / lookup.py helpers.
"""

from __future__ import annotations

import os
import subprocess
import sys

# ── SDK path resolution ───────────────────────────────────────────────────────
# When the host copies this script to the install location the relative path
# to the SDK bindings is always three levels up from the plugin's src/ dir.
_PLUGIN_SRC_DIR = os.path.dirname(os.path.abspath(__file__))
_SDK_PYTHON_DIR = os.path.normpath(
    os.path.join(_PLUGIN_SRC_DIR, "..", "..", "..", "tools", "sdk", "bindings", "python")
)
if _SDK_PYTHON_DIR not in sys.path:
    sys.path.insert(0, _SDK_PYTHON_DIR)

# Allow importing gmid_runner and lookup from the same src/ directory.
if _PLUGIN_SRC_DIR not in sys.path:
    sys.path.insert(0, _PLUGIN_SRC_DIR)

import schemify  # noqa: E402 (must follow sys.path setup)

# ── Constants (mirror panel.zig widget IDs) ───────────────────────────────────

WID_MODEL_TOGGLE  = 3
WID_BROWSE        = 4
WID_RUN           = 21
WID_RECENT_BASE   = 100   # 100..107 — up to 8 recent models
WID_OPEN_SVG_BASE = 300   # 300..323 — up to 24 plots

MAX_MODELS = 8
MAX_PLOTS  = 24

TAG = "GmIDVisualizer"

# ── Model kind detection (mirrors runner.zig validateModelFile) ───────────────

_MOS_NEEDLES = (" nmos", " pmos", "mosfet", "level=", "nfet", "pfet", "vth0", "tox")
_BJT_NEEDLES = (" npn", " pnp", " bjt", "is=", "bf=", "br=", "vaf=", "ikf=")


def _validate_model_file(path: str) -> str:
    """Return 'mosfet', 'bjt', or 'unknown'."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            data = fh.read(2 * 1024 * 1024).lower()
    except OSError:
        return "unknown"

    has_mos = any(n in data for n in _MOS_NEEDLES)
    has_bjt = any(n in data for n in _BJT_NEEDLES)

    if has_mos and not has_bjt:
        return "mosfet"
    if has_bjt and not has_mos:
        return "bjt"
    if has_mos and has_bjt:
        return "mosfet"
    return "unknown"


def _pick_model_file() -> str | None:
    """Try zenity then kdialog; return a path string or None."""
    for argv in (
        ["zenity", "--file-selection", "--title=Select MOSFET/BJT model file"],
        [
            "kdialog",
            "--getopenfilename",
            ".",
            "Model files (*.spice *.spi *.lib *.model *.mod *.cir *.scs)",
        ],
    ):
        try:
            res = subprocess.run(
                argv,
                capture_output=True,
                text=True,
                timeout=300,
            )
            if res.returncode == 0:
                path = res.stdout.strip()
                if path:
                    return path
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
    return None


def _open_svg(path: str) -> None:
    """Open an SVG file with the default viewer (xdg-open)."""
    try:
        subprocess.Popen(["xdg-open", path])
    except FileNotFoundError:
        pass


# ── Plugin state ──────────────────────────────────────────────────────────────

class _State:
    """All mutable plugin state, equivalent to state.zig State."""

    def __init__(self) -> None:
        self.selected_model_path: str = ""
        self.selected_model_kind: str = "unknown"  # 'mosfet' | 'bjt' | 'unknown'

        self.recent_models: list[str] = []   # most-recent first, max MAX_MODELS
        self.dropdown_open: bool = False

        # 'idle' | 'running' | 'done' | 'err'
        self.status: str = "idle"
        self.status_msg: str = ""
        self.error_msg: str = ""

        self.plots: list[str] = []           # SVG file paths, max MAX_PLOTS

    # -- helpers ---------------------------------------------------------------

    def set_selected_model(self, path: str, kind: str) -> None:
        self.selected_model_path = path
        self.selected_model_kind = kind

    def add_recent_model(self, path: str) -> None:
        # Move to front if already present; otherwise prepend.
        if path in self.recent_models:
            self.recent_models.remove(path)
        self.recent_models.insert(0, path)
        if len(self.recent_models) > MAX_MODELS:
            self.recent_models = self.recent_models[:MAX_MODELS]

    def set_status(self, msg: str) -> None:
        self.status_msg = msg

    def set_error(self, msg: str) -> None:
        self.error_msg = msg
        self.status = "err"

    def clear_error(self) -> None:
        self.error_msg = ""

    def clear_plots(self) -> None:
        self.plots = []

    def add_plot(self, path: str) -> None:
        if len(self.plots) < MAX_PLOTS:
            self.plots.append(path)

    def reset_all(self) -> None:
        self.selected_model_path = ""
        self.selected_model_kind = "unknown"
        self.dropdown_open = False
        self.status = "idle"
        self.status_msg = ""
        self.error_msg = ""
        self.plots = []


# ── Plugin ────────────────────────────────────────────────────────────────────

class GmIDVisualizer(schemify.Plugin):

    def __init__(self) -> None:
        self._state = _State()
        self._plugin_dir: str = ""

    # ── Lifecycle ──────────────────────────────────────────────────────────────

    def on_load(self, w: schemify.Writer) -> None:
        w.set_status("GmID Visualizer loading...")
        w.log_info(TAG, "on_load")

        home = os.environ.get("HOME", "/tmp")
        self._plugin_dir = os.path.join(home, ".config", "Schemify", "GmIDVisualizer")

        w.register_panel(
            id="gmid",
            title="Gm/Id Visualizer",
            vim_cmd="gmid",
            layout=schemify.LAYOUT_OVERLAY,
            keybind=ord('g'),
        )
        w.set_status("GmID Visualizer ready")
        w.log_info(TAG, "overlay panel registered (keybind: g, cmd: :gmid)")

    def on_unload(self, w: schemify.Writer) -> None:
        w.log_info(TAG, "on_unload")
        self._state.reset_all()

    def on_tick(self, dt: float, w: schemify.Writer) -> None:
        pass

    # ── Draw ───────────────────────────────────────────────────────────────────

    def on_draw(self, panel_id: int, w: schemify.Writer) -> None:
        s = self._state

        w.label("Gm/Id Visualizer", id=0)
        w.separator(id=1)

        self._draw_model_selector(w, s)
        self._draw_validation_status(w, s)
        w.separator(id=20)
        self._draw_run_controls(w, s)
        w.separator(id=30)
        self._draw_outputs(w, s)

    def _draw_model_selector(self, w: schemify.Writer, s: _State) -> None:
        selected_label = self._model_label(s)
        w.begin_row(id=2)
        w.button(selected_label, id=WID_MODEL_TOGGLE)
        w.button("Browse...", id=WID_BROWSE)
        w.end_row(id=2)

        if s.dropdown_open and s.recent_models:
            w.label("Previously selected models", id=5)
            for idx, path in enumerate(s.recent_models):
                w.button(path, id=WID_RECENT_BASE + idx)

    def _draw_validation_status(self, w: schemify.Writer, s: _State) -> None:
        if not s.selected_model_path:
            w.label("No model selected", id=10)
            return
        w.label(f"Validated as {s.selected_model_kind}", id=11)
        w.label(s.selected_model_path, id=12)

    def _draw_run_controls(self, w: schemify.Writer, s: _State) -> None:
        w.button("Run", id=WID_RUN)
        if s.status == "idle":
            if s.status_msg:
                w.label(s.status_msg, id=22)
            else:
                w.label("Select model, then run sweep", id=23)
        elif s.status == "running":
            w.label("Simulation running...", id=24)
        elif s.status == "done":
            w.label(s.status_msg, id=25)
        elif s.status == "err":
            w.label("Error:", id=26)
            w.label(s.error_msg, id=27)

    def _draw_outputs(self, w: schemify.Writer, s: _State) -> None:
        w.label("Generated SVG Graphs", id=31)
        if not s.plots:
            w.label("(none yet)", id=32)
            return
        for idx, plot_path in enumerate(s.plots):
            w.begin_row(id=40 + idx)
            w.label(plot_path, id=200 + idx)
            w.button("Open", id=WID_OPEN_SVG_BASE + idx)
            w.end_row(id=40 + idx)

    @staticmethod
    def _model_label(s: _State) -> str:
        if not s.selected_model_path:
            return "Model"
        base = os.path.basename(s.selected_model_path)
        return base if base else "Model"

    # ── Event handling ─────────────────────────────────────────────────────────

    def on_event(self, msg: dict, w: schemify.Writer) -> None:
        if msg["tag"] != schemify.TAG_BUTTON_CLICKED:
            return
        widget_id: int = msg["widget_id"]
        self._handle_button(widget_id, w)

    def _handle_button(self, widget_id: int, w: schemify.Writer) -> None:
        s = self._state

        if widget_id == WID_MODEL_TOGGLE:
            s.dropdown_open = not s.dropdown_open
            w.request_refresh()
            return

        if widget_id == WID_BROWSE:
            path = _pick_model_file()
            if path:
                kind = _validate_model_file(path)
                if kind == "unknown":
                    s.set_error("Selected file is not recognized as MOSFET or BJT model")
                else:
                    s.clear_error()
                    s.set_selected_model(path, kind)
                    s.add_recent_model(path)
                    s.set_status("Model selected and validated")
                    s.status = "idle"
                    s.dropdown_open = False
            else:
                s.set_status("Browse cancelled")
            w.request_refresh()
            return

        if widget_id == WID_RUN:
            self._run_sweep(w)
            return

        if WID_RECENT_BASE <= widget_id < WID_RECENT_BASE + MAX_MODELS:
            idx = widget_id - WID_RECENT_BASE
            if idx < len(s.recent_models):
                path = s.recent_models[idx]
                kind = _validate_model_file(path)
                s.set_selected_model(path, kind)
                s.dropdown_open = False
                if kind == "unknown":
                    s.set_error("Saved model no longer matches MOSFET/BJT format")
                else:
                    s.clear_error()
                    s.set_status("Model selected from history")
                    s.status = "idle"
            w.request_refresh()
            return

        if WID_OPEN_SVG_BASE <= widget_id < WID_OPEN_SVG_BASE + MAX_PLOTS:
            idx = widget_id - WID_OPEN_SVG_BASE
            if idx < len(s.plots):
                _open_svg(s.plots[idx])
            return

    # ── Sweep runner ───────────────────────────────────────────────────────────

    def _run_sweep(self, w: schemify.Writer) -> None:
        s = self._state

        if not s.selected_model_path:
            s.set_error("No model selected")
            w.request_refresh()
            return
        if s.selected_model_kind == "unknown":
            s.set_error("Selected model format is not recognized")
            w.request_refresh()
            return

        s.status = "running"
        s.clear_error()
        s.clear_plots()
        s.set_status("Running Gm/Id sweep...")
        w.request_refresh()

        # Resolve the runner script path — next to this file in src/.
        script_path = os.path.join(_PLUGIN_SRC_DIR, "gmid_runner.py")

        out_dir = os.path.join(self._plugin_dir, "figures")
        os.makedirs(out_dir, exist_ok=True)

        try:
            result = subprocess.run(
                [
                    "python3",
                    script_path,
                    "--model-file", s.selected_model_path,
                    "--kind",       s.selected_model_kind,
                    "--out-dir",    out_dir,
                ],
                capture_output=True,
                text=True,
                timeout=600,
            )
        except FileNotFoundError:
            s.set_error("Failed to launch python3")
            w.request_refresh()
            return
        except subprocess.TimeoutExpired:
            s.set_error("Sweep timed out after 600 s")
            w.request_refresh()
            return

        if result.returncode != 0:
            err = result.stderr.strip() or "Sweep command failed"
            s.set_error(err)
            w.log_warn(TAG, "python runner exited with failure")
            w.request_refresh()
            return

        # Parse "SVG:<path>" lines from stdout (matches gmid_runner.py output).
        for line in result.stdout.splitlines():
            stripped = line.strip()
            if stripped.startswith("SVG:"):
                path = stripped[4:].strip()
                if path:
                    s.add_plot(path)

        if not s.plots:
            s.set_error("No SVG plots were produced")
            w.request_refresh()
            return

        s.status = "done"
        s.set_status(f"Generated {len(s.plots)} SVG plots")
        w.request_refresh()


# ── Plugin entry point ────────────────────────────────────────────────────────

_plugin = GmIDVisualizer()


def schemify_process(in_bytes: bytes) -> bytes:
    return schemify.run_plugin(_plugin, in_bytes)
