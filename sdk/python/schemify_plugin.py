"""schemify_plugin -- Python SDK for Schemify plugins.

JSON-RPC 2.0 over stdin/stdout (NDJSON). Protocol version 1.
Matches the Zig host in modules/plugins/.

Install:
    pip install -e sdk/python/           # editable from repo
    cp schemify_plugin.py your_plugin/   # vendored copy

Usage:
    from schemify_plugin import Plugin, label, button
"""

import json
import sys
import threading
from typing import Any, Callable, Optional

PROTOCOL_VERSION = 1

# Panel layout constants (must match types.zig PanelLayout enum)
LAYOUT_OVERLAY = 0
LAYOUT_LEFT_SIDEBAR = 1
LAYOUT_RIGHT_SIDEBAR = 2
LAYOUT_BOTTOM_BAR = 3

_LAYOUT_NAMES = {
    "overlay": LAYOUT_OVERLAY,
    "left_sidebar": LAYOUT_LEFT_SIDEBAR,
    "right_sidebar": LAYOUT_RIGHT_SIDEBAR,
    "bottom_bar": LAYOUT_BOTTOM_BAR,
}


def _resolve_layout(layout) -> int:
    if isinstance(layout, int):
        return layout
    return _LAYOUT_NAMES.get(layout, LAYOUT_RIGHT_SIDEBAR)


# ---------------------------------------------------------------------------
# Widget helpers
# ---------------------------------------------------------------------------

class Widget:
    """A UI widget emitted by on_draw_panel."""

    __slots__ = ("tag", "text", "widget_id", "val", "min_val", "max_val", "open")

    def __init__(self, tag: str, text: str = "", widget_id: str = "",
                 val: float = 0.0, min_val: float = 0.0, max_val: float = 1.0,
                 open: bool = False):
        self.tag = tag
        self.text = text
        self.widget_id = widget_id
        self.val = val
        self.min_val = min_val
        self.max_val = max_val
        self.open = open

    def to_dict(self) -> dict:
        d: dict[str, Any] = {"tag": self.tag}
        if self.text:
            d["str"] = self.text
        if self.widget_id:
            d["widget_id"] = self.widget_id
        if self.val != 0.0:
            d["val"] = self.val
        if self.min_val != 0.0:
            d["min"] = self.min_val
        if self.max_val != 1.0:
            d["max"] = self.max_val
        if self.open:
            d["open"] = True
        return d


def label(text: str, widget_id: str = "") -> Widget:
    return Widget("label", text=text, widget_id=widget_id)


def button(text: str, widget_id: str = "") -> Widget:
    return Widget("button", text=text, widget_id=widget_id)


def separator() -> Widget:
    return Widget("separator")


def begin_row() -> Widget:
    return Widget("begin_row")


def end_row() -> Widget:
    return Widget("end_row")


def slider(widget_id: str, value: float = 0.0,
           min_val: float = 0.0, max_val: float = 1.0) -> Widget:
    return Widget("slider", widget_id=widget_id, val=value,
                  min_val=min_val, max_val=max_val)


def checkbox(text: str, widget_id: str, checked: bool = False) -> Widget:
    return Widget("checkbox", text=text, widget_id=widget_id,
                  val=1.0 if checked else 0.0)


def text_input(hint: str, widget_id: str) -> Widget:
    return Widget("text_input", text=hint, widget_id=widget_id)


def text_area(hint: str, widget_id: str) -> Widget:
    return Widget("text_area", text=hint, widget_id=widget_id)


def progress(widget_id: str, value: float = 0.0) -> Widget:
    return Widget("progress", widget_id=widget_id, val=value)


def collapsible_start(text: str, widget_id: str, open: bool = False) -> Widget:
    return Widget("collapsible_start", text=text, widget_id=widget_id, open=open)


def collapsible_end() -> Widget:
    return Widget("collapsible_end")


def tooltip(text: str) -> Widget:
    return Widget("tooltip", text=text)


# ---------------------------------------------------------------------------
# Plugin base class
# ---------------------------------------------------------------------------

class Plugin:
    """Base class for Schemify plugins.

    Subclass this and override the on_* methods. Call run() to start.

    Example::

        class MyPlugin(Plugin):
            def on_load(self):
                self.register_panel("my_panel", "My Panel", "right_sidebar")

            def on_draw_panel(self, panel_id: str) -> list[Widget]:
                return [label("Hello from my plugin!")]

            def on_button_clicked(self, panel_id: str, widget_id: str):
                self.set_status("Button clicked!")

        MyPlugin().run()
    """

    def __init__(self):
        self._request_id = 0
        self._panels: dict[str, dict] = {}
        self._pending: dict[int, threading.Event] = {}
        self._results: dict[int, Any] = {}
        self._lock = threading.Lock()
        self._running = True

    # -- Lifecycle hooks (override these) -----------------------------------

    def on_load(self):
        """Called when the plugin is loaded. Register panels here."""

    def on_unload(self):
        """Called when the plugin is being unloaded."""

    def on_tick(self, dt: float):
        """Called every frame with delta time in seconds."""

    def on_draw_panel(self, panel_id: str) -> list[Widget]:
        """Return a list of widgets to draw in the given panel."""
        return []

    def on_button_clicked(self, panel_id: str, widget_id: str):
        """Called when a button is clicked."""

    def on_slider_changed(self, panel_id: str, widget_id: str, value: float):
        """Called when a slider value changes."""

    def on_text_changed(self, panel_id: str, widget_id: str, text: str):
        """Called when text input changes."""

    def on_checkbox_changed(self, panel_id: str, widget_id: str, checked: bool):
        """Called when a checkbox is toggled."""

    # -- Host API (call these from your plugin) -----------------------------

    def register_panel(self, panel_id: str, title: str,
                       layout: str | int = "right_sidebar",
                       vim_cmd: str = "", keybind: int = 0):
        """Register a UI panel.

        Args:
            panel_id: Unique panel identifier.
            title: Display title.
            layout: "overlay", "left_sidebar", "right_sidebar", or "bottom_bar"
                    (or the integer constant directly).
            vim_cmd: Vim command to toggle this panel.
            keybind: Key code for keybind (0 = none).
        """
        layout_int = _resolve_layout(layout)
        self._panels[panel_id] = {
            "id": panel_id, "title": title, "layout": layout_int,
            "vim_cmd": vim_cmd, "keybind": keybind,
        }
        self._send_notification("host/register_panel", {
            "id": panel_id, "title": title, "layout": layout_int,
            "vim_cmd": vim_cmd, "keybind": keybind,
        })

    def register_command(self, tag: str, name: str, description: str = ""):
        """Register a command the user can invoke."""
        self._send_notification("host/register_command", {
            "id": tag, "name": name, "description": description,
        })

    def set_status(self, message: str):
        """Set the status bar message."""
        self._send_notification("host/set_status", {"text": message})

    def log(self, message: str, level: str = "info"):
        """Log a message (info, warn, err)."""
        self._send_notification("host/log", {"message": message, "level": level})

    def push_command(self, command: str):
        """Push a command to the host command queue."""
        self._send_notification("host/push_command", {"command": command})

    def request_refresh(self):
        """Request the host to refresh plugin state."""
        self._send_notification("host/request_refresh", {})

    def emit_widgets(self, panel_id: int, widgets: list[Widget]):
        """Emit widgets for a panel (alternative to returning from on_draw_panel)."""
        self._send_notification("ui/emit_widgets", {
            "panel_id": panel_id,
            "widgets": [w.to_dict() for w in widgets],
        })

    def read_file(self, path: str) -> Optional[str]:
        """Read a file via the host. Returns None if not permitted."""
        result = self._send_request("host/read_file", {"path": path})
        if result and "data" in result:
            return result["data"]
        return None

    def write_file(self, path: str, data: str) -> bool:
        """Write a file via the host."""
        result = self._send_request("host/write_file", {"path": path, "data": data})
        return result.get("success", False) if result else False

    def query_state(self, key: str) -> Optional[str]:
        """Query host state by key."""
        result = self._send_request("host/query_state", {"key": key})
        if result and "value" in result:
            return result["value"]
        return None

    # -- Main loop ----------------------------------------------------------

    def run(self):
        """Start the plugin main loop. Reads NDJSON from stdin, dispatches."""
        try:
            for line in sys.stdin:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue

                self._handle_message(msg)

                if not self._running:
                    break
        except (EOFError, KeyboardInterrupt):
            pass
        finally:
            self.on_unload()

    # -- Internal -----------------------------------------------------------

    def _handle_message(self, msg: dict):
        # Response to our request
        if "result" in msg or "error" in msg:
            msg_id = msg.get("id")
            if msg_id is not None:
                with self._lock:
                    if msg_id in self._pending:
                        self._results[msg_id] = msg.get("result")
                        self._pending[msg_id].set()
            return

        method = msg.get("method", "")
        params = msg.get("params", {})
        msg_id = msg.get("id")  # None for notifications

        result = None

        if method == "lifecycle/initialize":
            self.on_load()
            result = {"ok": True}
        elif method == "lifecycle/shutdown":
            self.on_unload()
            self._running = False
            result = {"ok": True}
        elif method == "lifecycle/tick":
            self.on_tick(params.get("dt", 0.016))
        elif method == "ui/draw_panel":
            panel_id = str(params.get("panel_id", ""))
            widgets = self.on_draw_panel(panel_id)
            if widgets:
                self.emit_widgets(int(params.get("panel_id", 0)), widgets)
        elif method == "ui/button_clicked":
            self.on_button_clicked(
                str(params.get("panel_id", "")),
                str(params.get("widget_id", "")))
        elif method == "ui/slider_changed":
            self.on_slider_changed(
                str(params.get("panel_id", "")),
                str(params.get("widget_id", "")),
                params.get("value", 0.0))
        elif method == "ui/text_changed":
            self.on_text_changed(
                str(params.get("panel_id", "")),
                str(params.get("widget_id", "")),
                params.get("text", ""))
        elif method == "ui/checkbox_changed":
            self.on_checkbox_changed(
                str(params.get("panel_id", "")),
                str(params.get("widget_id", "")),
                bool(params.get("value", False)))

        # Send response for requests (have an id)
        if msg_id is not None:
            self._send_response(msg_id, result or {"ok": True})

    def _send_notification(self, method: str, params: dict):
        msg = {"jsonrpc": "2.0", "method": method, "params": params}
        self._write(msg)

    def _send_request(self, method: str, params: dict,
                      timeout: float = 5.0) -> Optional[dict]:
        with self._lock:
            self._request_id += 1
            req_id = self._request_id
            event = threading.Event()
            self._pending[req_id] = event

        msg = {"jsonrpc": "2.0", "id": req_id, "method": method, "params": params}
        self._write(msg)

        if event.wait(timeout):
            with self._lock:
                result = self._results.pop(req_id, None)
                self._pending.pop(req_id, None)
            return result

        with self._lock:
            self._pending.pop(req_id, None)
        return None

    def _send_response(self, req_id: int, result: Any):
        msg = {"jsonrpc": "2.0", "id": req_id, "result": result}
        self._write(msg)

    def _write(self, msg: dict):
        line = json.dumps(msg, separators=(",", ":"))
        sys.stdout.write(line + "\n")
        sys.stdout.flush()
