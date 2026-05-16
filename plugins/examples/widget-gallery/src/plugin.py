#!/usr/bin/env python3
"""Widget Gallery — demonstrates every widget type in the Schemify plugin SDK.

Each section shows a widget and its current value updated via callbacks.
"""

import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", "sdk", "python"))

from schemify_plugin import (
    Plugin,
    label, button, separator, begin_row, end_row,
    slider, checkbox, text_input, text_area,
    progress, collapsible_start, collapsible_end, tooltip,
)


class WidgetGallery(Plugin):
    def __init__(self):
        super().__init__()
        self.click_count = 0
        self.slider_val = 0.5
        self.check_a = True
        self.check_b = False
        self.name_text = ""
        self.notes_text = ""
        self.progress_val = 0.0

    def on_tick(self, dt):
        # Animate the progress bar (loops 0 -> 1).
        self.progress_val += dt * 0.1
        if self.progress_val > 1.0:
            self.progress_val = 0.0

    def on_draw_panel(self, panel_id):
        return [
            # -- Buttons & Labels ------------------------------------------
            label("-- Buttons & Labels --"),
            begin_row(),
            button("Click me", widget_id="click"),
            button("Reset", widget_id="reset"),
            end_row(),
            label(f"Clicks: {self.click_count}"),
            tooltip("Buttons send on_button_clicked with the widget_id."),

            separator(),

            # -- Slider ----------------------------------------------------
            label("-- Slider --"),
            slider("vol", value=self.slider_val, min_val=0.0, max_val=1.0),
            label(f"Value: {self.slider_val:.2f}"),
            tooltip("Sliders send on_slider_changed with the new float value."),

            separator(),

            # -- Checkboxes ------------------------------------------------
            label("-- Checkboxes --"),
            checkbox("Enable output", "check_a", checked=self.check_a),
            checkbox("Verbose mode", "check_b", checked=self.check_b),
            label(f"A={self.check_a}, B={self.check_b}"),
            tooltip("Checkboxes send on_checkbox_changed with a bool."),

            separator(),

            # -- Text Input ------------------------------------------------
            label("-- Text Input --"),
            text_input("Enter name...", "name"),
            label(f"Name: {self.name_text or '(empty)'}"),
            tooltip("Single-line text input. on_text_changed fires on edit."),

            separator(),

            # -- Text Area -------------------------------------------------
            label("-- Text Area --"),
            text_area("Notes...", "notes"),
            label(f"Notes length: {len(self.notes_text)} chars"),

            separator(),

            # -- Progress Bar ----------------------------------------------
            label("-- Progress Bar --"),
            progress("prog", value=self.progress_val),
            label(f"Progress: {self.progress_val:.0%}"),

            separator(),

            # -- Collapsible Section ---------------------------------------
            collapsible_start("Advanced Options", "advanced", open=True),
            label("  Option 1: enabled"),
            label("  Option 2: disabled"),
            begin_row(),
            button("Apply All", widget_id="apply"),
            button("Defaults", widget_id="defaults"),
            end_row(),
            collapsible_end(),

            separator(),

            # -- Layout: Row -----------------------------------------------
            label("-- Row Layout --"),
            begin_row(),
            label("Left"),
            label("|"),
            label("Center"),
            label("|"),
            label("Right"),
            end_row(),
        ]

    def on_button_clicked(self, panel_id, widget_id):
        if widget_id == "click":
            self.click_count += 1
            self.set_status(f"Clicked {self.click_count} times")
        elif widget_id == "reset":
            self.click_count = 0
            self.set_status("Reset")
        elif widget_id == "apply":
            self.log("Apply All pressed")
        elif widget_id == "defaults":
            self.slider_val = 0.5
            self.check_a = True
            self.check_b = False
            self.set_status("Defaults restored")

    def on_slider_changed(self, panel_id, widget_id, value):
        if widget_id == "vol":
            self.slider_val = value

    def on_checkbox_changed(self, panel_id, widget_id, checked):
        if widget_id == "check_a":
            self.check_a = checked
        elif widget_id == "check_b":
            self.check_b = checked

    def on_text_changed(self, panel_id, widget_id, text):
        if widget_id == "name":
            self.name_text = text
        elif widget_id == "notes":
            self.notes_text = text


if __name__ == "__main__":
    WidgetGallery().run()
