#!/usr/bin/env python3
"""Counter — the simplest possible Schemify plugin.

Demonstrates: state, buttons, labels, separator, begin_row/end_row.
"""

import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", "sdk", "python"))

from schemify_plugin import Plugin, label, button, separator, begin_row, end_row


class Counter(Plugin):
    def __init__(self):
        super().__init__()
        self.count = 0

    def on_draw_panel(self, panel_id):
        return [
            label(f"Count: {self.count}"),
            separator(),
            begin_row(),
            button("-", widget_id="dec"),
            button("+", widget_id="inc"),
            end_row(),
            button("Reset", widget_id="reset"),
        ]

    def on_button_clicked(self, panel_id, widget_id):
        if widget_id == "inc":
            self.count += 1
        elif widget_id == "dec":
            self.count -= 1
        elif widget_id == "reset":
            self.count = 0
            self.set_status("Counter reset")


if __name__ == "__main__":
    Counter().run()
