"""
Schemify Plugin SDK — Python demo

Registers four panels and draws a widget gallery on every on_draw call.

Deploy:  zig build run   (copies to ~/.config/Schemify/SchemifyPython/scripts/)
"""

import schemify


class PythonDemo(schemify.Plugin):
    def __init__(self) -> None:
        self.slider_val   = 0.5
        self.checkbox_val = True
        self.tick_count   = 0

    def on_load(self, w: schemify.Writer) -> None:
        w.register_panel("py-demo-overlay", "Properties",   "pydprop",   schemify.LAYOUT_OVERLAY,       0)
        w.register_panel("py-demo-left",    "Components",   "pydcomp",   schemify.LAYOUT_LEFT_SIDEBAR,  0)
        w.register_panel("py-demo-right",   "Design Stats", "pydstats",  schemify.LAYOUT_RIGHT_SIDEBAR, 0)
        w.register_panel("py-demo-bottom",  "Status",       "pydstatus", schemify.LAYOUT_BOTTOM_BAR,    0)
        w.set_status("Python Demo loaded")

    def on_tick(self, dt: float, w: schemify.Writer) -> None:
        self.tick_count += 1

    def on_draw(self, panel_id: int, w: schemify.Writer) -> None:
        # panel_id identifies which panel to draw; switch on it when the
        # host assigns distinct IDs per registration. Currently always 0.
        self._draw_widgets(w)

    def on_event(self, msg: dict, w: schemify.Writer) -> None:
        tag = msg.get("tag")
        if tag == schemify.TAG_SLIDER_CHANGED and msg.get("widget_id") == 3:
            self.slider_val = msg["val"]
        elif tag == schemify.TAG_CHECKBOX_CHANGED and msg.get("widget_id") == 4:
            self.checkbox_val = msg["val"]

    def _draw_widgets(self, w: schemify.Writer) -> None:
        w.label("Selected: R1", id=0)
        w.separator(id=1)
        w.label("Value (kOhm)", id=2)
        w.slider(self.slider_val, 0.0, 100.0, id=3)
        w.checkbox(self.checkbox_val, "Show in netlist", id=4)
        w.button("Apply", id=5)
        w.separator(id=6)
        w.collapsible_start("Component Browser", open=True, id=7)
        w.label("  Resistors: R1, R2, R3", id=8)
        w.label("  Capacitors: C1", id=9)
        w.label("  Transistors: M1, M2", id=10)
        w.collapsible_end(id=7)
        w.separator(id=11)
        w.label("Design Stats", id=12)
        w.progress(0.75, id=13)
        w.begin_row(id=14)
        w.label("Nets: 12", id=15)
        w.label("Comps: 8", id=16)
        w.button("Simulate", id=17)
        w.end_row(id=14)


_plugin = PythonDemo()


def schemify_process(in_bytes: bytes) -> bytes:
    return schemify.run_plugin(_plugin, in_bytes)
