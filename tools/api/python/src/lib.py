"""
schemify_plugin — Python SDK (ABI v7)

Copy this file into your plugin project (no pip install required).

Usage:
    from schemify_plugin import Plugin, Writer, Layout, run

    class MyPlugin(Plugin):
        def on_load(self, w: Writer) -> None:
            w.register_panel("hello", "Hello", "hello", Layout.LEFT_SIDEBAR)

        def on_draw_panel(self, panel_id: int, w: Writer) -> None:
            w.label("Hello from Python!", 1)

    if __name__ == "__main__":
        run(MyPlugin())

Host communicates via stdin/stdout binary frames:
    [u32 in_len][in_bytes...][u32 out_cap]
    ← [u32 out_len][out_bytes...]

For native .so plugins (via cffi), see the compile() helper at the bottom.
"""

from __future__ import annotations

import io
import struct
import sys
from abc import ABC, abstractmethod
from enum import IntEnum
from typing import Optional


ABI_VERSION = 7


# ── Layout ────────────────────────────────────────────────────────────────

class Layout(IntEnum):
    OVERLAY       = 0
    LEFT_SIDEBAR  = 1
    RIGHT_SIDEBAR = 2
    BOTTOM_BAR    = 3


# ── Message tags ──────────────────────────────────────────────────────────

class _Tag:
    LOAD               = 0x01
    UNLOAD             = 0x02
    TICK               = 0x03
    DRAW_PANEL         = 0x04
    BUTTON_CLICKED     = 0x05
    SLIDER_CHANGED     = 0x06
    TEXT_CHANGED       = 0x07
    CHECKBOX_CHANGED   = 0x08
    COMMAND            = 0x09
    STATE_RESPONSE     = 0x0A
    CONFIG_RESPONSE    = 0x0B
    SCHEMATIC_CHANGED  = 0x0C
    SELECTION_CHANGED  = 0x0D
    SCHEMATIC_SNAPSHOT = 0x0E
    INSTANCE_DATA      = 0x0F
    INSTANCE_PROP      = 0x10
    NET_DATA           = 0x11
    HOVER              = 0x13
    KEY_EVENT          = 0x14

EVENT_HOVER = 0x01
EVENT_KEYS  = 0x02


# ── Reader ────────────────────────────────────────────────────────────────

class Reader:
    """Decode incoming host→plugin messages from a bytes buffer."""

    def __init__(self, data: bytes) -> None:
        self._buf = data
        self._pos = 0

    def __iter__(self):
        return self

    def __next__(self):
        msg = self.next()
        if msg is None:
            raise StopIteration
        return msg

    def next(self) -> Optional[dict]:
        """Return next decoded message dict or None at end."""
        while True:
            if self._pos + 3 > len(self._buf):
                return None
            tag = self._buf[self._pos]
            psz = struct.unpack_from("<H", self._buf, self._pos + 1)[0]
            hdr = self._pos + 3
            end = hdr + psz
            if end > len(self._buf):
                return None
            p = self._buf[hdr:end]
            self._pos = end

            try:
                if   tag == _Tag.LOAD:               return {"tag": "load"}
                elif tag == _Tag.UNLOAD:             return {"tag": "unload"}
                elif tag == _Tag.SCHEMATIC_CHANGED:  return {"tag": "schematic_changed"}
                elif tag == _Tag.TICK:
                    return {"tag": "tick", "dt": struct.unpack_from("<f", p)[0]}
                elif tag == _Tag.DRAW_PANEL:
                    return {"tag": "draw_panel", "panel_id": struct.unpack_from("<H", p)[0]}
                elif tag == _Tag.BUTTON_CLICKED:
                    pid, wid = struct.unpack_from("<HI", p)
                    return {"tag": "button_clicked", "panel_id": pid, "widget_id": wid}
                elif tag == _Tag.SLIDER_CHANGED:
                    pid, wid, val = struct.unpack_from("<HIf", p)
                    return {"tag": "slider_changed", "panel_id": pid, "widget_id": wid, "val": val}
                elif tag == _Tag.TEXT_CHANGED:
                    pid, wid = struct.unpack_from("<HI", p[:6])
                    off = 6; text, off = _rd_str(p, off)
                    return {"tag": "text_changed", "panel_id": pid, "widget_id": wid, "text": text}
                elif tag == _Tag.CHECKBOX_CHANGED:
                    pid, wid, val = struct.unpack_from("<HIB", p)
                    return {"tag": "checkbox_changed", "panel_id": pid, "widget_id": wid, "val": bool(val)}
                elif tag == _Tag.COMMAND:
                    off = 0; t, off = _rd_str(p, off); pl, _ = _rd_str(p, off)
                    return {"tag": "command", "cmd_tag": t, "payload": pl}
                elif tag == _Tag.STATE_RESPONSE:
                    off = 0; k, off = _rd_str(p, off); v, _ = _rd_str(p, off)
                    return {"tag": "state_response", "key": k, "val": v}
                elif tag == _Tag.CONFIG_RESPONSE:
                    off = 0; k, off = _rd_str(p, off); v, _ = _rd_str(p, off)
                    return {"tag": "config_response", "key": k, "val": v}
                elif tag == _Tag.SELECTION_CHANGED:
                    return {"tag": "selection_changed", "instance_idx": struct.unpack_from("<i", p)[0]}
                elif tag == _Tag.SCHEMATIC_SNAPSHOT:
                    ic, wc, nc = struct.unpack_from("<III", p)
                    return {"tag": "schematic_snapshot", "instance_count": ic, "wire_count": wc, "net_count": nc}
                elif tag == _Tag.INSTANCE_DATA:
                    idx = struct.unpack_from("<I", p)[0]; off = 4
                    name, off = _rd_str(p, off); sym, _ = _rd_str(p, off)
                    return {"tag": "instance_data", "idx": idx, "name": name, "symbol": sym}
                elif tag == _Tag.INSTANCE_PROP:
                    idx = struct.unpack_from("<I", p)[0]; off = 4
                    k, off = _rd_str(p, off); v, _ = _rd_str(p, off)
                    return {"tag": "instance_prop", "idx": idx, "key": k, "val": v}
                elif tag == _Tag.NET_DATA:
                    idx = struct.unpack_from("<I", p)[0]; off = 4
                    name, _ = _rd_str(p, off)
                    return {"tag": "net_data", "idx": idx, "name": name}
                elif tag == _Tag.HOVER:
                    wx, wy = struct.unpack_from("<ii", p)
                    et = p[8]
                    eidx = struct.unpack_from("<i", p, 9)[0]
                    off = 13; ename, _ = _rd_str(p, off)
                    return {"tag": "hover", "world_x": wx, "world_y": wy,
                            "element_type": et, "element_idx": eidx, "element_name": ename}
                elif tag == _Tag.KEY_EVENT:
                    return {"tag": "key_event", "key": p[0], "mods": p[1], "action": p[2]}
                else:
                    continue  # unknown tag, skip
            except (struct.error, IndexError):
                continue


# ── Writer ────────────────────────────────────────────────────────────────

class Writer:
    """Build plugin→host response messages."""

    def __init__(self) -> None:
        self._buf = io.BytesIO()

    def get_bytes(self) -> bytes:
        return self._buf.getvalue()

    def _hdr(self, tag: int, payload: bytes) -> None:
        self._buf.write(struct.pack("<BH", tag, len(payload)))
        self._buf.write(payload)

    def set_status(self, msg: str) -> None:
        s = msg.encode()
        self._hdr(0x81, struct.pack("<H", len(s)) + s)

    def register_panel(self, plugin_id: str, title: str, vim_cmd: str,
                       layout: Layout, keybind: int = 0) -> None:
        def sp(s): b = s.encode(); return struct.pack("<H", len(b)) + b
        self._hdr(0x80, sp(plugin_id) + sp(title) + sp(vim_cmd) +
                  struct.pack("<BB", int(layout), keybind))

    def request_refresh(self) -> None:
        self._hdr(0x88, b"")

    def get_state(self, key: str) -> None:
        b = key.encode(); self._hdr(0x85, struct.pack("<H", len(b)) + b)

    def set_state(self, key: str, val: str) -> None:
        def sp(s): b = s.encode(); return struct.pack("<H", len(b)) + b
        self._hdr(0x84, sp(key) + sp(val))

    def query_instances(self) -> None: self._hdr(0x8D, b"")
    def query_nets(self)      -> None: self._hdr(0x8E, b"")

    def place_device(self, sym: str, name: str, x: int, y: int) -> None:
        def sp(s): b = s.encode(); return struct.pack("<H", len(b)) + b
        self._hdr(0x8A, sp(sym) + sp(name) + struct.pack("<ii", x, y))

    def set_instance_prop(self, idx: int, key: str, val: str) -> None:
        def sp(s): b = s.encode(); return struct.pack("<H", len(b)) + b
        self._hdr(0x8C, struct.pack("<I", idx) + sp(key) + sp(val))

    # UI widgets
    def label(self, text: str, widget_id: int = 0) -> None:
        b = text.encode()
        self._hdr(0xA0, struct.pack("<H", len(b)) + b + struct.pack("<I", widget_id))

    def button(self, text: str, widget_id: int) -> None:
        b = text.encode()
        self._hdr(0xA1, struct.pack("<H", len(b)) + b + struct.pack("<I", widget_id))

    def separator(self, widget_id: int = 0) -> None:
        self._hdr(0xA2, struct.pack("<I", widget_id))

    def begin_row(self, widget_id: int = 0) -> None:
        self._hdr(0xA3, struct.pack("<I", widget_id))

    def end_row(self, widget_id: int = 0) -> None:
        self._hdr(0xA4, struct.pack("<I", widget_id))

    def slider(self, val: float, min_val: float, max_val: float, widget_id: int) -> None:
        self._hdr(0xA5, struct.pack("<fffI", val, min_val, max_val, widget_id))

    def checkbox(self, val: bool, text: str, widget_id: int) -> None:
        b = text.encode()
        self._hdr(0xA6, struct.pack("<BH", int(val), len(b)) + b + struct.pack("<I", widget_id))

    def progress(self, fraction: float, widget_id: int = 0) -> None:
        self._hdr(0xA7, struct.pack("<fI", fraction, widget_id))

    def collapsible_start(self, label: str, open: bool, widget_id: int) -> None:
        b = label.encode()
        self._hdr(0xAA, struct.pack("<H", len(b)) + b +
                  struct.pack("<BI", int(open), widget_id))

    def collapsible_end(self, widget_id: int) -> None:
        self._hdr(0xAB, struct.pack("<I", widget_id))

    def tooltip(self, text: str, widget_id: int = 0) -> None:
        b = text.encode()
        self._hdr(0xAC, struct.pack("<H", len(b)) + b + struct.pack("<I", widget_id))

    def text_input(self, hint: str, text: str, widget_id: int) -> None:
        bh = hint.encode()
        bt = text.encode()
        self._hdr(0xAD, struct.pack("<H", len(bh)) + bh +
                  struct.pack("<H", len(bt)) + bt + struct.pack("<I", widget_id))

    def text_area(self, hint: str, text: str, widget_id: int) -> None:
        bh = hint.encode()
        bt = text.encode()
        self._hdr(0xAE, struct.pack("<H", len(bh)) + bh +
                  struct.pack("<H", len(bt)) + bt + struct.pack("<I", widget_id))

    def push_command(self, cmd_tag: str, payload: str = "") -> None:
        def sp(s): b = s.encode(); return struct.pack("<H", len(b)) + b
        self._hdr(0x83, sp(cmd_tag) + sp(payload))

    def subscribe_events(self, mask: int) -> None:
        self._hdr(0x92, struct.pack("<B", mask))

    def consume_event(self) -> None:
        self._hdr(0x93, b"")

    def override_keybind(self, key: int, mods: int, cmd_tag: str) -> None:
        b = cmd_tag.encode()
        self._hdr(0x94, struct.pack("<BBH", key, mods, len(b)) + b)

    def log(self, level: int, tag: str, msg: str) -> None:
        bt = tag.encode(); bm = msg.encode()
        self._hdr(0x82, struct.pack("<BH", level, len(bt)) + bt + struct.pack("<H", len(bm)) + bm)

    def set_config(self, plugin_id: str, key: str, val: str) -> None:
        def sp(s): b = s.encode(); return struct.pack("<H", len(b)) + b
        self._hdr(0x86, sp(plugin_id) + sp(key) + sp(val))

    def get_config(self, plugin_id: str, key: str) -> None:
        def sp(s): b = s.encode(); return struct.pack("<H", len(b)) + b
        self._hdr(0x87, sp(plugin_id) + sp(key))


# ── Plugin base class ─────────────────────────────────────────────────────

class Plugin(ABC):
    """Base class for Python plugins. Override the on_* methods you need."""

    def on_load(self, w: Writer) -> None: pass
    def on_unload(self, w: Writer) -> None: pass
    def on_tick(self, dt: float, w: Writer) -> None: pass
    def on_draw_panel(self, panel_id: int, w: Writer) -> None: pass
    def on_button_clicked(self, panel_id: int, widget_id: int, w: Writer) -> None: pass
    def on_slider_changed(self, panel_id: int, widget_id: int, val: float, w: Writer) -> None: pass
    def on_checkbox_changed(self, panel_id: int, widget_id: int, val: bool, w: Writer) -> None: pass
    def on_command(self, tag: str, payload: str, w: Writer) -> None: pass
    def on_state_response(self, key: str, val: str, w: Writer) -> None: pass
    def on_selection_changed(self, idx: int, w: Writer) -> None: pass
    def on_schematic_changed(self, w: Writer) -> None: pass
    def on_instance_data(self, idx: int, name: str, symbol: str, w: Writer) -> None: pass
    def on_hover(self, world_x: int, world_y: int, element_type: int,
                 element_idx: int, element_name: str, w: Writer) -> None: pass
    def on_key_event(self, key: int, mods: int, action: int, w: Writer) -> None: pass
    def on_text_changed(self, panel_id: int, widget_id: int, text: str, w: Writer) -> None: pass

    def process(self, in_data: bytes) -> bytes:
        r = Reader(in_data)
        w = Writer()
        for msg in r:
            t = msg["tag"]
            if   t == "load":               self.on_load(w)
            elif t == "unload":             self.on_unload(w)
            elif t == "tick":               self.on_tick(msg["dt"], w)
            elif t == "draw_panel":         self.on_draw_panel(msg["panel_id"], w)
            elif t == "button_clicked":     self.on_button_clicked(msg["panel_id"], msg["widget_id"], w)
            elif t == "slider_changed":     self.on_slider_changed(msg["panel_id"], msg["widget_id"], msg["val"], w)
            elif t == "checkbox_changed":   self.on_checkbox_changed(msg["panel_id"], msg["widget_id"], msg["val"], w)
            elif t == "command":            self.on_command(msg["cmd_tag"], msg["payload"], w)
            elif t == "state_response":     self.on_state_response(msg["key"], msg["val"], w)
            elif t == "selection_changed":  self.on_selection_changed(msg["instance_idx"], w)
            elif t == "schematic_changed":  self.on_schematic_changed(w)
            elif t == "instance_data":      self.on_instance_data(msg["idx"], msg["name"], msg["symbol"], w)
            elif t == "text_changed":      self.on_text_changed(msg["panel_id"], msg["widget_id"], msg["text"], w)
            elif t == "hover":             self.on_hover(msg["world_x"], msg["world_y"], msg["element_type"], msg["element_idx"], msg["element_name"], w)
            elif t == "key_event":         self.on_key_event(msg["key"], msg["mods"], msg["action"], w)
        return w.get_bytes()


# ── Subprocess runner ─────────────────────────────────────────────────────

def run(plugin: Plugin) -> None:
    """
    Run the plugin as a subprocess communicating with Schemify via stdin/stdout.
    Frame format: [u32 in_len][bytes...] → [u32 out_len][bytes...]
    """
    stdin  = sys.stdin.buffer
    stdout = sys.stdout.buffer
    while True:
        hdr = stdin.read(4)
        if len(hdr) < 4:
            break
        in_len  = struct.unpack("<I", hdr)[0]
        in_data = stdin.read(in_len)
        if len(in_data) < in_len:
            break
        out_data = plugin.process(in_data)
        stdout.write(struct.pack("<I", len(out_data)))
        stdout.write(out_data)
        stdout.flush()


# ── Internal helpers ──────────────────────────────────────────────────────

def _rd_str(buf: bytes, off: int) -> tuple[str, int]:
    slen = struct.unpack_from("<H", buf, off)[0]
    off += 2
    return buf[off:off + slen].decode(errors="replace"), off + slen
