"""
Schemify Plugin SDK for Python — ABI v6

Public API is unchanged from v5 — plugin authors use the same
ctx.label(), ctx.button(), etc. methods. Internally, all output
is now collected as binary messages rather than calling host imports.

Example plugin:
    import schemify

    class MyPlugin(schemify.Plugin):
        def on_load(self, w: schemify.Writer):
            w.register_panel('my-panel', 'My Panel', 'mypanel', schemify.LAYOUT_OVERLAY, 0)
            w.set_status('My plugin loaded')

        def on_draw(self, panel_id: int, w: schemify.Writer):
            w.label('Hello from Python!', id=0)
            w.button('Click me', id=1)

        def on_tick(self, dt: float, w: schemify.Writer):
            pass

        def on_event(self, msg: dict, w: schemify.Writer):
            if msg['tag'] == schemify.TAG_BUTTON_CLICKED and msg['widget_id'] == 1:
                w.set_status('Clicked!')

    _plugin = MyPlugin()
    def schemify_process(in_bytes: bytes) -> bytes:
        return schemify.run_plugin(_plugin, in_bytes)
"""

import struct

# ── Host → Plugin tags (0x01 – 0x7F) ─────────────────────────────────────────

TAG_LOAD               = 0x01
TAG_UNLOAD             = 0x02
TAG_TICK               = 0x03
TAG_DRAW_PANEL         = 0x04
TAG_BUTTON_CLICKED     = 0x05
TAG_SLIDER_CHANGED     = 0x06
TAG_TEXT_CHANGED       = 0x07
TAG_CHECKBOX_CHANGED   = 0x08
TAG_COMMAND            = 0x09
TAG_STATE_RESPONSE     = 0x0A
TAG_CONFIG_RESPONSE    = 0x0B
TAG_SCHEMATIC_CHANGED  = 0x0C
TAG_SELECTION_CHANGED  = 0x0D
TAG_SCHEMATIC_SNAPSHOT = 0x0E
TAG_INSTANCE_DATA      = 0x0F
TAG_INSTANCE_PROP      = 0x10
TAG_NET_DATA           = 0x11

# ── Plugin → Host command tags (0x80 – 0x9F) ─────────────────────────────────

TAG_REGISTER_PANEL    = 0x80
TAG_SET_STATUS        = 0x81
TAG_LOG               = 0x82
TAG_PUSH_COMMAND      = 0x83
TAG_SET_STATE         = 0x84
TAG_GET_STATE         = 0x85
TAG_SET_CONFIG        = 0x86
TAG_GET_CONFIG        = 0x87
TAG_REQUEST_REFRESH   = 0x88
TAG_REGISTER_KEYBIND  = 0x89
TAG_PLACE_DEVICE      = 0x8A
TAG_ADD_WIRE          = 0x8B
TAG_SET_INSTANCE_PROP = 0x8C
TAG_QUERY_INSTANCES   = 0x8D
TAG_QUERY_NETS        = 0x8E

# ── UI widget tags (0xA0 – 0xBF) ─────────────────────────────────────────────

TAG_UI_LABEL             = 0xA0
TAG_UI_BUTTON            = 0xA1
TAG_UI_SEPARATOR         = 0xA2
TAG_UI_BEGIN_ROW         = 0xA3
TAG_UI_END_ROW           = 0xA4
TAG_UI_SLIDER            = 0xA5
TAG_UI_CHECKBOX          = 0xA6
TAG_UI_PROGRESS          = 0xA7
TAG_UI_PLOT              = 0xA8
TAG_UI_IMAGE             = 0xA9
TAG_UI_COLLAPSIBLE_START = 0xAA
TAG_UI_COLLAPSIBLE_END   = 0xAB

# ── Layout constants ──────────────────────────────────────────────────────────

LAYOUT_OVERLAY       = 0
LAYOUT_LEFT_SIDEBAR  = 1
LAYOUT_RIGHT_SIDEBAR = 2
LAYOUT_BOTTOM_BAR    = 3

# ── Log level constants ───────────────────────────────────────────────────────

LOG_INFO = 0
LOG_WARN = 1
LOG_ERR  = 2

# ── Reader (decode host→plugin messages) ─────────────────────────────────────

def _read_str(payload: bytes, offset: int) -> tuple:
    """Read a [u16 len][bytes] string. Returns (string, new_offset)."""
    if offset + 2 > len(payload):
        return ('', offset + 2)
    length = struct.unpack_from('<H', payload, offset)[0]
    offset += 2
    s = payload[offset:offset + length].decode('utf-8', errors='replace')
    return (s, offset + length)

def _read_u32(payload: bytes, offset: int) -> tuple:
    v = struct.unpack_from('<I', payload, offset)[0]
    return (v, offset + 4)

def _read_i32(payload: bytes, offset: int) -> tuple:
    v = struct.unpack_from('<i', payload, offset)[0]
    return (v, offset + 4)

def _read_f32(payload: bytes, offset: int) -> tuple:
    v = struct.unpack_from('<f', payload, offset)[0]
    return (v, offset + 4)

def _read_f32arr(payload: bytes, offset: int) -> tuple:
    count = struct.unpack_from('<I', payload, offset)[0]
    offset += 4
    arr = list(struct.unpack_from(f'<{count}f', payload, offset))
    return (arr, offset + count * 4)

def _decode_payload(tag: int, payload: bytes):
    """Decode a payload into a message dict, or None for unknown tags."""
    try:
        if tag == TAG_LOAD:     return {'tag': tag}
        if tag == TAG_UNLOAD:   return {'tag': tag}
        if tag == TAG_TICK:
            dt, _ = _read_f32(payload, 0)
            return {'tag': tag, 'dt': dt}
        if tag == TAG_DRAW_PANEL:
            panel_id = struct.unpack_from('<H', payload, 0)[0]
            return {'tag': tag, 'panel_id': panel_id}
        if tag == TAG_BUTTON_CLICKED:
            panel_id = struct.unpack_from('<H', payload, 0)[0]
            widget_id = struct.unpack_from('<I', payload, 2)[0]
            return {'tag': tag, 'panel_id': panel_id, 'widget_id': widget_id}
        if tag == TAG_SLIDER_CHANGED:
            panel_id = struct.unpack_from('<H', payload, 0)[0]
            widget_id = struct.unpack_from('<I', payload, 2)[0]
            val = struct.unpack_from('<f', payload, 6)[0]
            return {'tag': tag, 'panel_id': panel_id, 'widget_id': widget_id, 'val': val}
        if tag == TAG_TEXT_CHANGED:
            panel_id = struct.unpack_from('<H', payload, 0)[0]
            widget_id = struct.unpack_from('<I', payload, 2)[0]
            text, _ = _read_str(payload, 6)
            return {'tag': tag, 'panel_id': panel_id, 'widget_id': widget_id, 'text': text}
        if tag == TAG_CHECKBOX_CHANGED:
            panel_id = struct.unpack_from('<H', payload, 0)[0]
            widget_id = struct.unpack_from('<I', payload, 2)[0]
            val = payload[6] != 0 if len(payload) > 6 else False
            return {'tag': tag, 'panel_id': panel_id, 'widget_id': widget_id, 'val': val}
        if tag == TAG_COMMAND:
            tag_str, off = _read_str(payload, 0)
            payload_str, _ = _read_str(payload, off)
            return {'tag': tag, 'cmd_tag': tag_str, 'payload': payload_str}
        if tag == TAG_STATE_RESPONSE:
            key, off = _read_str(payload, 0)
            val, _ = _read_str(payload, off)
            return {'tag': tag, 'key': key, 'val': val}
        if tag == TAG_CONFIG_RESPONSE:
            key, off = _read_str(payload, 0)
            val, _ = _read_str(payload, off)
            return {'tag': tag, 'key': key, 'val': val}
        if tag == TAG_SCHEMATIC_CHANGED: return {'tag': tag}
        if tag == TAG_SELECTION_CHANGED:
            idx, _ = _read_i32(payload, 0)
            return {'tag': tag, 'instance_idx': idx}
        if tag == TAG_SCHEMATIC_SNAPSHOT:
            ic = struct.unpack_from('<I', payload, 0)[0]
            wc = struct.unpack_from('<I', payload, 4)[0]
            nc = struct.unpack_from('<I', payload, 8)[0]
            return {'tag': tag, 'instance_count': ic, 'wire_count': wc, 'net_count': nc}
        if tag == TAG_INSTANCE_DATA:
            idx = struct.unpack_from('<I', payload, 0)[0]
            name, off = _read_str(payload, 4)
            symbol, _ = _read_str(payload, off)
            return {'tag': tag, 'idx': idx, 'name': name, 'symbol': symbol}
        if tag == TAG_INSTANCE_PROP:
            idx = struct.unpack_from('<I', payload, 0)[0]
            key, off = _read_str(payload, 4)
            val, _ = _read_str(payload, off)
            return {'tag': tag, 'idx': idx, 'key': key, 'val': val}
        if tag == TAG_NET_DATA:
            idx = struct.unpack_from('<I', payload, 0)[0]
            name, _ = _read_str(payload, 4)
            return {'tag': tag, 'idx': idx, 'name': name}
        return None  # unknown tag
    except Exception:
        return None

def decode_messages(buf: bytes) -> list:
    """Decode a wire-format buffer into a list of message dicts."""
    messages = []
    pos = 0
    while pos < len(buf):
        if pos + 3 > len(buf):
            break
        tag = buf[pos]
        payload_sz = struct.unpack_from('<H', buf, pos + 1)[0]
        pos += 3
        if pos + payload_sz > len(buf):
            break
        payload = buf[pos:pos + payload_sz]
        pos += payload_sz
        msg = _decode_payload(tag, payload)
        if msg is not None:
            messages.append(msg)
    return messages

# ── Writer (encode plugin→host messages) ─────────────────────────────────────

class Writer:
    """Encodes plugin→host messages into a binary buffer."""

    def __init__(self):
        self._buf = bytearray()

    def _str_bytes(self, s: str) -> bytes:
        b = s.encode('utf-8')
        return struct.pack('<H', len(b)) + b

    def _f32arr_bytes(self, arr: list) -> bytes:
        return struct.pack('<I', len(arr)) + struct.pack(f'<{len(arr)}f', *arr)

    def _u8arr_bytes(self, arr: bytes) -> bytes:
        return struct.pack('<I', len(arr)) + arr

    def _msg(self, tag: int, payload: bytes) -> None:
        assert len(payload) <= 65535
        self._buf += bytes([tag])
        self._buf += struct.pack('<H', len(payload))
        self._buf += payload

    def bytes(self) -> bytes:
        return bytes(self._buf)

    # ── Commands ──────────────────────────────────────────────────────────────

    def register_panel(self, id: str, title: str, vim_cmd: str,
                       layout: int = LAYOUT_OVERLAY, keybind: int = 0) -> None:
        payload = (self._str_bytes(id) + self._str_bytes(title) +
                   self._str_bytes(vim_cmd) + bytes([layout, keybind]))
        self._msg(TAG_REGISTER_PANEL, payload)

    def set_status(self, msg: str) -> None:
        self._msg(TAG_SET_STATUS, self._str_bytes(msg))

    def log(self, level: int, tag: str, msg: str) -> None:
        payload = bytes([level]) + self._str_bytes(tag) + self._str_bytes(msg)
        self._msg(TAG_LOG, payload)

    def log_info(self, tag: str, msg: str) -> None: self.log(LOG_INFO, tag, msg)
    def log_warn(self, tag: str, msg: str) -> None: self.log(LOG_WARN, tag, msg)
    def log_err(self, tag: str, msg: str) -> None: self.log(LOG_ERR, tag, msg)

    def push_command(self, tag: str, payload: str = '') -> None:
        self._msg(TAG_PUSH_COMMAND, self._str_bytes(tag) + self._str_bytes(payload))

    def set_state(self, key: str, val: str) -> None:
        self._msg(TAG_SET_STATE, self._str_bytes(key) + self._str_bytes(val))

    def get_state(self, key: str) -> None:
        self._msg(TAG_GET_STATE, self._str_bytes(key))

    def set_config(self, plugin_id: str, key: str, val: str) -> None:
        self._msg(TAG_SET_CONFIG,
                  self._str_bytes(plugin_id) + self._str_bytes(key) + self._str_bytes(val))

    def get_config(self, plugin_id: str, key: str) -> None:
        self._msg(TAG_GET_CONFIG, self._str_bytes(plugin_id) + self._str_bytes(key))

    def request_refresh(self) -> None:
        self._msg(TAG_REQUEST_REFRESH, b'')

    def register_keybind(self, key: int, mods: int, cmd_tag: str) -> None:
        payload = bytes([key, mods]) + self._str_bytes(cmd_tag)
        self._msg(TAG_REGISTER_KEYBIND, payload)

    def place_device(self, sym: str, name: str, x: int, y: int) -> None:
        payload = self._str_bytes(sym) + self._str_bytes(name) + struct.pack('<ii', x, y)
        self._msg(TAG_PLACE_DEVICE, payload)

    def add_wire(self, x0: int, y0: int, x1: int, y1: int) -> None:
        self._msg(TAG_ADD_WIRE, struct.pack('<iiii', x0, y0, x1, y1))

    def set_instance_prop(self, idx: int, key: str, val: str) -> None:
        payload = struct.pack('<I', idx) + self._str_bytes(key) + self._str_bytes(val)
        self._msg(TAG_SET_INSTANCE_PROP, payload)

    def query_instances(self) -> None:
        self._msg(TAG_QUERY_INSTANCES, b'')

    def query_nets(self) -> None:
        self._msg(TAG_QUERY_NETS, b'')

    # ── UI widgets ────────────────────────────────────────────────────────────

    def label(self, text: str, id: int = 0) -> None:
        self._msg(TAG_UI_LABEL, self._str_bytes(text) + struct.pack('<I', id))

    def button(self, text: str, id: int = 0) -> None:
        self._msg(TAG_UI_BUTTON, self._str_bytes(text) + struct.pack('<I', id))

    def separator(self, id: int = 0) -> None:
        self._msg(TAG_UI_SEPARATOR, struct.pack('<I', id))

    def begin_row(self, id: int = 0) -> None:
        self._msg(TAG_UI_BEGIN_ROW, struct.pack('<I', id))

    def end_row(self, id: int = 0) -> None:
        self._msg(TAG_UI_END_ROW, struct.pack('<I', id))

    def slider(self, val: float, min: float, max: float, id: int = 0) -> None:
        self._msg(TAG_UI_SLIDER, struct.pack('<fffI', val, min, max, id))

    def checkbox(self, val: bool, text: str = '', id: int = 0) -> None:
        payload = bytes([1 if val else 0]) + self._str_bytes(text) + struct.pack('<I', id)
        self._msg(TAG_UI_CHECKBOX, payload)

    def progress(self, fraction: float, id: int = 0) -> None:
        self._msg(TAG_UI_PROGRESS, struct.pack('<fI', fraction, id))

    def plot(self, title: str, xs: list, ys: list, id: int = 0) -> None:
        payload = (self._str_bytes(title) + self._f32arr_bytes(xs) +
                   self._f32arr_bytes(ys) + struct.pack('<I', id))
        self._msg(TAG_UI_PLOT, payload)

    def image(self, pixels: bytes, width: int, height: int, id: int = 0) -> None:
        payload = (struct.pack('<II', width, height) +
                   self._u8arr_bytes(pixels) + struct.pack('<I', id))
        self._msg(TAG_UI_IMAGE, payload)

    def collapsible_start(self, label: str, open: bool = True, id: int = 0) -> None:
        payload = (self._str_bytes(label) + bytes([1 if open else 0]) +
                   struct.pack('<I', id))
        self._msg(TAG_UI_COLLAPSIBLE_START, payload)

    def collapsible_end(self, id: int = 0) -> None:
        self._msg(TAG_UI_COLLAPSIBLE_END, struct.pack('<I', id))

# ── Plugin base class ─────────────────────────────────────────────────────────

class Plugin:
    """Base class for Python plugins. Override the on_* methods."""
    def on_load(self, w: Writer) -> None: pass
    def on_unload(self, w: Writer) -> None: pass
    def on_tick(self, dt: float, w: Writer) -> None: pass
    def on_draw(self, panel_id: int, w: Writer) -> None: pass
    def on_event(self, msg: dict, w: Writer) -> None: pass

def run_plugin(plugin: Plugin, in_bytes: bytes) -> bytes:
    """Dispatch a batch of input messages to a plugin, return output bytes."""
    w = Writer()
    for msg in decode_messages(in_bytes):
        tag = msg['tag']
        if tag == TAG_LOAD:
            plugin.on_load(w)
        elif tag == TAG_UNLOAD:
            plugin.on_unload(w)
        elif tag == TAG_TICK:
            plugin.on_tick(msg['dt'], w)
        elif tag == TAG_DRAW_PANEL:
            plugin.on_draw(msg['panel_id'], w)
        else:
            plugin.on_event(msg, w)
    return w.bytes()

# ── Backward-compatible UiCtx ─────────────────────────────────────────────────

class UiCtx:
    """Backward-compatible UI context wrapper for v5-style plugin scripts.

    In v6, pass a Writer to this class to get the old ctx API.
    Interaction return values (button clicks, slider changes) always return
    False — actual interactions arrive as event messages in the next frame.
    """
    def __init__(self, writer: Writer):
        self._w = writer

    def label(self, text: str, id: int = 0) -> None:
        self._w.label(text, id)

    def button(self, text: str, id: int = 0) -> bool:
        self._w.button(text, id)
        return False  # interaction events come as messages next frame

    def separator(self, id: int = 0) -> None:
        self._w.separator(id)

    def begin_row(self, id: int = 0) -> None:
        self._w.begin_row(id)

    def end_row(self, id: int = 0) -> None:
        self._w.end_row(id)

    def slider(self, val: float, min: float, max: float, id: int = 0) -> bool:
        self._w.slider(val, min, max, id)
        return False  # changes come as SliderChanged events next frame

    def checkbox(self, val: bool, text: str = '', id: int = 0) -> bool:
        self._w.checkbox(val, text, id)
        return False

    def progress(self, fraction: float, id: int = 0) -> None:
        self._w.progress(fraction, id)

    def plot(self, title: str, xs: list, ys: list, id: int = 0) -> bool:
        self._w.plot(title, xs, ys, id)
        return False

    def image(self, pixels: bytes, width: int, height: int, id: int = 0) -> None:
        self._w.image(pixels, width, height, id)

    def collapsible_section(self, label: str, open: bool = True, id: int = 0) -> bool:
        self._w.collapsible_start(label, open, id)
        return open

    def end_collapsible(self, id: int = 0) -> None:
        self._w.collapsible_end(id)

    def set_status(self, msg: str) -> None:
        self._w.set_status(msg)

    def log_info(self, tag: str, msg: str) -> None:
        self._w.log_info(tag, msg)

    def log_warn(self, tag: str, msg: str) -> None:
        self._w.log_warn(tag, msg)

    def log_err(self, tag: str, msg: str) -> None:
        self._w.log_err(tag, msg)
