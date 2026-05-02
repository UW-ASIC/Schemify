"""
Schemify Plugin SDK — Python demo

Registers four panels and draws a widget gallery on every draw_panel call.

Run:  python plugin.py   (started by host automatically)

The SDK file (schemify_plugin) is at tools/api/python/src/lib.py.
Copy it as schemify_plugin.py next to this file for standalone use.
"""

import sys
import os

# For in-tree examples, add SDK to path.
_sdk = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    "..", "..", "..", "tools", "api", "python", "src")
sys.path.insert(0, _sdk)

from lib import Plugin, Writer, Layout, run  # noqa: E402


class PythonDemo(Plugin):
    def __init__(self) -> None:
        self.slider_val = 0.5
        self.checkbox_val = True
        self.tick_count = 0

    def on_load(self, w: Writer) -> None:
        w.register_panel("py-demo-overlay", "Properties",   "pydprop",   Layout.OVERLAY)
        w.register_panel("py-demo-left",    "Components",   "pydcomp",   Layout.LEFT_SIDEBAR)
        w.register_panel("py-demo-right",   "Design Stats", "pydstats",  Layout.RIGHT_SIDEBAR)
        w.register_panel("py-demo-bottom",  "Status",       "pydstatus", Layout.BOTTOM_BAR)
        w.set_status("Python Demo loaded")

    def on_tick(self, dt: float, w: Writer) -> None:
        self.tick_count += 1

    def on_draw_panel(self, panel_id: int, w: Writer) -> None:
        w.label("Selected: R1", 0)
        w.separator(1)
        w.label("Value (kOhm)", 2)
        w.slider(self.slider_val, 0.0, 100.0, 3)
        w.checkbox(self.checkbox_val, "Show in netlist", 4)
        w.button("Apply", 5)
        w.separator(6)
        w.collapsible_start("Component Browser", True, 7)
        w.label("  Resistors: R1, R2, R3", 8)
        w.label("  Capacitors: C1", 9)
        w.label("  Transistors: M1, M2", 10)
        w.collapsible_end(7)
        w.separator(11)
        w.label("Design Stats", 12)
        w.progress(0.75, 13)
        w.begin_row(14)
        w.label("Nets: 12", 15)
        w.label("Comps: 8", 16)
        w.button("Simulate", 17)
        w.end_row(14)

    def on_slider_changed(self, panel_id: int, widget_id: int,
                          val: float, w: Writer) -> None:
        if widget_id == 3:
            self.slider_val = val

    def on_checkbox_changed(self, panel_id: int, widget_id: int,
                            val: bool, w: Writer) -> None:
        if widget_id == 4:
            self.checkbox_val = val


_plugin = PythonDemo()


def schemify_process(in_bytes: bytes) -> bytes:
    """Entry point for native .so bridge (tools/api/python/bridge.c)."""
    return _plugin.process(in_bytes)


if __name__ == "__main__":
    run(PythonDemo())
