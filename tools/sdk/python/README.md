# schemify-plugin

Python SDK for [Schemify](https://github.com/OmarSiwy/Schemify) plugins.

Plugins communicate with the Schemify host over JSON-RPC 2.0 (NDJSON on stdin/stdout).

## Install

```bash
pip install -e tools/sdk/python/    # editable, from repo checkout
```

Or vendor the single file:

```bash
cp tools/sdk/python/schemify_plugin.py your_plugin/
```

## Quick start

```python
from schemify_plugin import Plugin, label, button

class MyPlugin(Plugin):
    def on_load(self):
        self.register_panel("main", "My Panel", "right_sidebar")

    def on_draw_panel(self, panel_id):
        return [label("Hello!"), button("Click me", widget_id="btn")]

    def on_button_clicked(self, panel_id, widget_id):
        if widget_id == "btn":
            self.set_status("Clicked!")

if __name__ == "__main__":
    MyPlugin().run()
```

See `template/` for a complete starter project.
