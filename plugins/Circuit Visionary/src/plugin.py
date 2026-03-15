"""CircuitVision Schemify plugin — ABI v6 Python SDK entry point.

Implements the CircuitVision pipeline as a pure Python plugin using the
Plugin class from the Schemify Python SDK. The heavy ML pipeline lives in
circuit_extract.py and is imported lazily on on_load so startup stays fast.
"""

from __future__ import annotations

import os
import sys

_here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_here, "../../../tools/sdk/bindings/python"))
sys.path.insert(0, _here)

from schemify import Plugin, Writer, run_plugin  # noqa: E402
import schemify  # noqa: E402

# ── Widget IDs ─────────────────────────────────────────────────────────────── #

WID_TITLE           = 0
WID_TITLE_SEP       = 1
WID_IMAGE_ROW       = 2
WID_IMAGE_LBL       = 3
WID_IMAGE_PATH      = 4
WID_STYLE_ROW       = 10
WID_STYLE_LBL       = 11
WID_STYLE_AUTO      = 12
WID_STYLE_HANDDRAWN = 13
WID_STYLE_TEXTBOOK  = 14
WID_STYLE_DATASHEET = 15
WID_MID_SEP         = 20
WID_RUN_BTN         = 30
WID_RUNNING_LBL     = 40
WID_RESULTS_ROW     = 50
WID_ACCEPT_BTN      = 51
WID_RUN_AGAIN_BTN   = 52
WID_CANCEL_BTN      = 53
WID_ERROR_LBL       = 60
WID_ERROR_MSG       = 61
WID_DISMISS_BTN     = 62
WID_RES_SEP         = 100
WID_RES_LBL         = 101
WID_RES_COMP_ROW    = 110
WID_RES_COMP_LBL    = 111
WID_RES_NET_LBL     = 112
WID_RES_CONF_ROW    = 120
WID_RES_CONF_LBL    = 121
WID_RES_STYLE_LBL   = 122
WID_RES_WARN_SEP    = 130
WID_RES_WARN_LBL    = 131

TAG = "CircuitVision"

# ── Pipeline status ────────────────────────────────────────────────────────── #

STATUS_IDLE    = "idle"
STATUS_RUNNING = "running"
STATUS_DONE    = "done"
STATUS_ERROR   = "error"

# ── Plugin class ───────────────────────────────────────────────────────────── #

class CircuitVision(Plugin):
    def __init__(self):
        self._pipeline = None
        self._pipeline_error: str = ""
        self._status: str = STATUS_IDLE
        self._image_path: str = ""
        self._selected_style: str | None = None  # None = auto

        # Results
        self._n_components: int = 0
        self._n_nets: int = 0
        self._confidence: float = 0.0
        self._detected_style: str = ""
        self._warning_count: int = 0

        # Error
        self._error_msg: str = ""

    # ── Lifecycle ──────────────────────────────────────────────────────────── #

    def on_load(self, w: Writer) -> None:
        w.set_status("CircuitVision loading...")
        w.log_info(TAG, "on_load")

        # Attempt to load the ML pipeline; failures are non-fatal.
        try:
            from circuit_extract import Pipeline

            model_dir = os.environ.get("CIRCUITVISION_MODEL_DIR")
            self._pipeline = Pipeline(model_dir=model_dir)
            w.log_info(TAG, "pipeline ready")
        except ImportError as exc:
            self._pipeline_error = f"Missing dependency: {exc}"
            w.log_warn(TAG, f"pipeline unavailable — {exc}")
            w.log_warn(TAG, "run `pip install -r requirements.txt`")
        except Exception as exc:
            self._pipeline_error = f"Init error: {exc}"
            w.log_warn(TAG, f"pipeline init failed — {exc}")

        w.register_panel(
            "circuit-vision",
            "Circuit Vision",
            "cvision",
            schemify.LAYOUT_OVERLAY,
            ord('v'),
        )
        w.set_status("CircuitVision ready")
        w.log_info(TAG, "overlay panel registered (keybind: v, cmd: :cvision)")

    def on_unload(self, w: Writer) -> None:
        w.log_info(TAG, "on_unload")
        self._reset()

    def on_tick(self, dt: float, w: Writer) -> None:
        # Future: poll a background thread for async extraction results.
        pass

    # ── Drawing ────────────────────────────────────────────────────────────── #

    def on_draw(self, panel_id: int, w: Writer) -> None:
        w.label("CircuitVision", id=WID_TITLE)
        w.separator(id=WID_TITLE_SEP)

        # Pipeline unavailable banner
        if self._pipeline is None and self._pipeline_error:
            w.label(f"Pipeline not available: {self._pipeline_error}", id=WID_ERROR_LBL)
            w.label("Run: pip install -r requirements.txt", id=WID_ERROR_MSG)
            w.separator(id=WID_MID_SEP)

        # Image path row
        w.begin_row(id=WID_IMAGE_ROW)
        w.label("Image:", id=WID_IMAGE_LBL)
        if self._image_path:
            w.label(self._image_path, id=WID_IMAGE_PATH)
        else:
            w.label("(no image selected)", id=WID_IMAGE_PATH)
        w.end_row(id=WID_IMAGE_ROW)

        # Style selector
        w.begin_row(id=WID_STYLE_ROW)
        w.label("Style:", id=WID_STYLE_LBL)
        w.button("auto",       id=WID_STYLE_AUTO)
        w.button("handdrawn",  id=WID_STYLE_HANDDRAWN)
        w.button("textbook",   id=WID_STYLE_TEXTBOOK)
        w.button("datasheet",  id=WID_STYLE_DATASHEET)
        w.end_row(id=WID_STYLE_ROW)

        w.separator(id=WID_MID_SEP)

        if self._status == STATUS_IDLE:
            if self._image_path:
                w.button("Run Pipeline", id=WID_RUN_BTN)
            else:
                w.label("Set image path to enable pipeline", id=WID_RUN_BTN)

        elif self._status == STATUS_RUNNING:
            w.label("Running pipeline...", id=WID_RUNNING_LBL)

        elif self._status == STATUS_DONE:
            self._draw_results(w)
            w.begin_row(id=WID_RESULTS_ROW)
            w.button("Accept",    id=WID_ACCEPT_BTN)
            w.button("Run Again", id=WID_RUN_AGAIN_BTN)
            w.button("Cancel",    id=WID_CANCEL_BTN)
            w.end_row(id=WID_RESULTS_ROW)

        elif self._status == STATUS_ERROR:
            w.label("Error:", id=WID_ERROR_LBL)
            w.label(self._error_msg, id=WID_ERROR_MSG)
            w.button("Dismiss", id=WID_DISMISS_BTN)

    def _draw_results(self, w: Writer) -> None:
        w.separator(id=WID_RES_SEP)
        w.label("Results", id=WID_RES_LBL)

        w.begin_row(id=WID_RES_COMP_ROW)
        w.label(f"Components: {self._n_components}", id=WID_RES_COMP_LBL)
        w.label(f"Nets: {self._n_nets}",             id=WID_RES_NET_LBL)
        w.end_row(id=WID_RES_COMP_ROW)

        w.begin_row(id=WID_RES_CONF_ROW)
        w.label(f"Confidence: {self._confidence:.2f}", id=WID_RES_CONF_LBL)
        if self._detected_style:
            w.label(f"Style: {self._detected_style}", id=WID_RES_STYLE_LBL)
        w.end_row(id=WID_RES_CONF_ROW)

        if self._warning_count > 0:
            w.separator(id=WID_RES_WARN_SEP)
            w.label(f"Warnings ({self._warning_count})", id=WID_RES_WARN_LBL)

    # ── Events ─────────────────────────────────────────────────────────────── #

    def on_event(self, msg: dict, w: Writer) -> None:
        tag = msg.get("tag")
        if tag == schemify.TAG_BUTTON_CLICKED:
            self._handle_button(msg.get("widget_id", 0), w)

    def _handle_button(self, widget_id: int, w: Writer) -> None:
        if widget_id == WID_STYLE_AUTO:
            self._selected_style = None
        elif widget_id == WID_STYLE_HANDDRAWN:
            self._selected_style = "handdrawn"
        elif widget_id == WID_STYLE_TEXTBOOK:
            self._selected_style = "textbook"
        elif widget_id == WID_STYLE_DATASHEET:
            self._selected_style = "datasheet"
        elif widget_id == WID_RUN_BTN:
            self._run_pipeline(w)
        elif widget_id == WID_ACCEPT_BTN:
            self._reset()
        elif widget_id == WID_RUN_AGAIN_BTN:
            self._reset()
            self._run_pipeline(w)
        elif widget_id == WID_CANCEL_BTN:
            self._reset()
        elif widget_id == WID_DISMISS_BTN:
            self._reset()

    # ── Pipeline execution ─────────────────────────────────────────────────── #

    def _run_pipeline(self, w: Writer) -> None:
        if self._pipeline is None:
            self._status = STATUS_ERROR
            self._error_msg = self._pipeline_error or "Pipeline not loaded"
            return

        if not self._image_path:
            self._status = STATUS_ERROR
            self._error_msg = "No image path set"
            return

        self._status = STATUS_RUNNING
        w.set_status("CircuitVision: extracting...")
        w.log_info(TAG, f"extracting {self._image_path}")

        try:
            graph = self._pipeline.run(self._image_path)
            self._n_components = len(graph.components)
            self._n_nets = len(graph.nets)
            self._confidence = getattr(graph, "overall_confidence", 0.0)
            self._detected_style = str(getattr(graph, "detected_style", ""))
            self._warning_count = len(getattr(graph, "warnings", []))
            self._status = STATUS_DONE
            w.set_status(
                f"CircuitVision: done — {self._n_components} components, "
                f"{self._n_nets} nets"
            )
            w.log_info(
                TAG,
                f"done — {self._n_components} components, {self._n_nets} nets",
            )
        except Exception as exc:
            self._status = STATUS_ERROR
            self._error_msg = str(exc)
            w.log_err(TAG, f"extraction failed — {exc}")
            w.set_status("CircuitVision: extraction failed")

    def _reset(self) -> None:
        self._status = STATUS_IDLE
        self._n_components = 0
        self._n_nets = 0
        self._confidence = 0.0
        self._detected_style = ""
        self._warning_count = 0
        self._error_msg = ""


# ── Plugin export ──────────────────────────────────────────────────────────── #

_plugin = CircuitVision()

def schemify_process(in_bytes: bytes) -> bytes:
    return run_plugin(_plugin, in_bytes)
