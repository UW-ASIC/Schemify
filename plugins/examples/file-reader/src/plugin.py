#!/usr/bin/env python3
"""File Reader — demonstrates the host request-response API.

Shows how to use read_file, write_file, and query_state to interact
with the Schemify host from a plugin.
"""

import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", "sdk", "python"))

from schemify_plugin import (
    Plugin, label, button, separator, text_input, text_area,
)


class FileReader(Plugin):
    def __init__(self):
        super().__init__()
        self.file_path = ""
        self.file_contents = ""
        self.status_msg = "Enter a file path and click Read."
        self.state_key = "project_name"
        self.state_value = ""

    def on_draw_panel(self, panel_id):
        return [
            # -- File Read -------------------------------------------------
            label("-- Read File --"),
            text_input("path/to/file.sch", "path"),
            button("Read", widget_id="read"),
            separator(),
            label(f"Status: {self.status_msg}"),
            label(self.file_contents[:200] if self.file_contents else "(no content)"),

            separator(),

            # -- File Write ------------------------------------------------
            label("-- Write File --"),
            button("Write test file", widget_id="write"),

            separator(),

            # -- Query State -----------------------------------------------
            label("-- Query State --"),
            text_input("state key...", "state_key"),
            button("Query", widget_id="query"),
            label(f"Key: {self.state_key}"),
            label(f"Value: {self.state_value or '(none)'}"),
        ]

    def on_text_changed(self, panel_id, widget_id, text):
        if widget_id == "path":
            self.file_path = text
        elif widget_id == "state_key":
            self.state_key = text

    def on_button_clicked(self, panel_id, widget_id):
        if widget_id == "read":
            if not self.file_path:
                self.status_msg = "No path entered."
                return
            data = self.read_file(self.file_path)
            if data is not None:
                self.file_contents = data
                self.status_msg = f"Read {len(data)} bytes from {self.file_path}"
                self.log(f"Read file: {self.file_path}")
            else:
                self.file_contents = ""
                self.status_msg = f"Failed to read {self.file_path}"

        elif widget_id == "write":
            ok = self.write_file("plugin_test_output.txt",
                                 "Hello from the File Reader plugin!\n")
            if ok:
                self.status_msg = "Wrote plugin_test_output.txt"
                self.set_status("File written successfully")
            else:
                self.status_msg = "Write failed (permission denied?)"

        elif widget_id == "query":
            value = self.query_state(self.state_key)
            self.state_value = value or ""
            self.set_status(f"Queried '{self.state_key}' = '{self.state_value}'")


if __name__ == "__main__":
    FileReader().run()
