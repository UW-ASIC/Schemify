"""Hello World Schemify plugin — Python example.

Install: zig build run  (copies this file and launches Schemify)
"""
import sys, os
# Make the Python SDK importable when run from install location
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../../../tools/sdk/bindings/python"))

from schemify import Plugin, Writer, run_plugin  # type: ignore

class PythonHello(Plugin):
    def on_load(self, w: Writer) -> None:
        w.register_panel("python-hello", "Python Hello", "phello", 0, ord("p"))
        w.set_status("Hello from Python!")

    def on_draw(self, panel_id: int, w: Writer) -> None:
        w.label("Hello from Python!", 0)
        w.label("Built with the Python SDK.", 1)

_plugin = PythonHello()

def schemify_process(in_bytes: bytes) -> bytes:
    return run_plugin(_plugin, in_bytes)
