#!/usr/bin/env python3
"""Schemify plugin template."""

from schemify_plugin import Plugin, label, button, separator


class MyPlugin(Plugin):
    def __init__(self):
        super().__init__()
        self.counter = 0

    def on_load(self):
        self.register_panel("main", "My Plugin", "right_sidebar")
        self.log("Plugin loaded!")

    def on_draw_panel(self, panel_id: str):
        return [
            label(f"Counter: {self.counter}"),
            separator(),
            button("Increment", widget_id="increment"),
            button("Reset", widget_id="reset"),
        ]

    def on_button_clicked(self, panel_id: str, widget_id: str):
        if widget_id == "increment":
            self.counter += 1
            self.set_status(f"Counter: {self.counter}")
        elif widget_id == "reset":
            self.counter = 0
            self.set_status("Counter reset")


if __name__ == "__main__":
    MyPlugin().run()
