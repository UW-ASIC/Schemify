// pyodide_plugin_host.js — Python plugin support for Schemify WASM via Pyodide (ABI v6).
//
// Loaded by index.html after plugin_host.js.
// Reads plugins.json for .py entries, loads Pyodide on demand, injects a
// `schemify` Python module backed by the v6 binary message protocol, and
// drives each Python plugin's schemify_process(in_bytes) → bytes entry point.
//
// Python plugin entry point (v6):
//
//   import schemify
//
//   def schemify_process(in_bytes: bytes) -> bytes:
//       r = schemify.Reader(in_bytes)
//       w = schemify.Writer()
//       for msg in r:
//           if msg['tag'] == schemify.TAG_LOAD:
//               w.register_panel("py-hello", "Python Hello", "pyhello")
//               w.set_status("Hello from Python!")
//           elif msg['tag'] == schemify.TAG_TICK:
//               pass
//           elif msg['tag'] == schemify.TAG_DRAW_PANEL:
//               w.label("Hello from Python!")
//               w.button("Click me")
//       return w.bytes()
//
// The schemify Python module also exposes the convenience UiCtx / draw()
// decorator pattern from the v5 SDK for backwards compatibility with existing
// Python plugins.  Those plugins do NOT need to implement schemify_process
// themselves; this host wraps them automatically.
//
// Pyodide CDN URL override (set before DOMContentLoaded):
//   window.schemifyPyodideUrl = "https://cdn.jsdelivr.net/pyodide/v0.27.0/full/";

(() => {
  const DEFAULT_PYODIDE_URL = "https://cdn.jsdelivr.net/pyodide/v0.27.0/full/";

  // ── Codec reference ───────────────────────────────────────────────────── //
  //
  // We re-use the MsgWriter / MsgReader from plugin_host.js which must be
  // loaded first.  If the host is not yet available we fall back to a deferred
  // init at boot time.

  function _codec() {
    const h = window.schemifyPluginHost;
    if (!h) throw new Error("[py-plugin-host] schemifyPluginHost not loaded");
    return { MsgWriter: h.MsgWriter, MsgReader: h.MsgReader };
  }

  // ── App state ─────────────────────────────────────────────────────────── //

  let _app = {
    statusFn:         (msg) => console.info("[py-plugin] status:", msg),
    registerPanelFn:  (id, title, vim, layout, keybind) => {
      console.debug("[py-plugin] register_panel", { id, title, vim, layout, keybind });
      return 1;
    },
    requestRefreshFn:   () => {},
    onPluginCommand:    null,
    registerKeybindFn:  null,
    placeDevice:        null,
    addWire:            null,
    setInstancePropFn:  null,
    getSchematicSnapshot: () => ({ instance_count: 0, wire_count: 0, net_count: 0 }),
    getInstanceData:    null,
    getNetData:         null,
    getInstanceProps:   null,
  };

  // ── Per-plugin state ──────────────────────────────────────────────────── //

  const _pyPlugins = []; // { url, name, ns, hasProcess, panels, pendingStateResponses, pendingConfigResponses, queryInstancesPending, queryNetsPending, _currentWidgets }

  // ── Pyodide state ─────────────────────────────────────────────────────── //

  let _pyodide        = null;
  let _pyodideLoading = null;

  async function _loadPyodide() {
    if (_pyodide) return _pyodide;
    if (_pyodideLoading) return _pyodideLoading;

    const cdnUrl = window.schemifyPyodideUrl ?? DEFAULT_PYODIDE_URL;
    console.info("[py-plugin-host] loading Pyodide from", cdnUrl);

    _pyodideLoading = (async () => {
      await new Promise((resolve, reject) => {
        const s   = document.createElement("script");
        s.src     = cdnUrl + "pyodide.js";
        s.onload  = resolve;
        s.onerror = () => reject(new Error("Failed to load pyodide.js from " + cdnUrl));
        document.head.appendChild(s);
      });
      _pyodide = await window.loadPyodide({ indexURL: cdnUrl });
      console.info("[py-plugin-host] Pyodide ready");
      _injectSchemifyModule(_pyodide);
      return _pyodide;
    })();

    return _pyodideLoading;
  }

  // ── State storage ─────────────────────────────────────────────────────── //

  const _STATE_PREFIX  = "schemify:state:";
  const _CONFIG_PREFIX = "schemify:config:";

  function _stateGet(key)            { return sessionStorage.getItem(_STATE_PREFIX + key) ?? ""; }
  function _stateSet(key, val)       { sessionStorage.setItem(_STATE_PREFIX + key, val); }
  function _configGet(pid, key)      { return sessionStorage.getItem(_CONFIG_PREFIX + pid + ":" + key) ?? ""; }
  function _configSet(pid, key, val) { sessionStorage.setItem(_CONFIG_PREFIX + pid + ":" + key, val); }

  // ── parseOutput (mirrors plugin_host.js) ─────────────────────────────── //

  const _LOG_METHODS = ["info", "warn", "error"];

  function parseOutput(plugin, bytes) {
    const { MsgReader } = _codec();
    const reader = new MsgReader(bytes);
    for (const msg of reader.readAll()) {
      switch (msg.tag) {
        case 0x80: { // RegisterPanel
          const panelId = _app.registerPanelFn(msg.id, msg.title, msg.vim_cmd, msg.layout, msg.keybind);
          plugin.panels.set(panelId, { id: msg.id, title: msg.title, vim_cmd: msg.vim_cmd });
          break;
        }
        case 0x81: _app.statusFn(msg.msg); break;
        case 0x82: {
          const fn = console[_LOG_METHODS[msg.level]] ?? console.log;
          fn.call(console, `[py-plugin:${plugin.name}][${msg.tag_str}] ${msg.msg}`);
          break;
        }
        case 0x83: _app.onPluginCommand?.(msg.tag_str, msg.payload); break;
        case 0x84: _stateSet(msg.key, msg.val); break;
        case 0x85: (plugin.pendingStateResponses ??= []).push({ key: msg.key, val: _stateGet(msg.key) }); break;
        case 0x86: _configSet(msg.plugin_id, msg.key, msg.val); break;
        case 0x87: (plugin.pendingConfigResponses ??= []).push({ plugin_id: msg.plugin_id, key: msg.key, val: _configGet(msg.plugin_id, msg.key) }); break;
        case 0x88: _app.requestRefreshFn(); break;
        case 0x89: _app.registerKeybindFn?.(msg.key, msg.mods, msg.cmd_tag); break;
        case 0x8A: _app.placeDevice?.(msg.sym, msg.device_name, msg.x, msg.y); break;
        case 0x8B: _app.addWire?.(msg.x0, msg.y0, msg.x1, msg.y1); break;
        case 0x8C: _app.setInstancePropFn?.(msg.idx, msg.key, msg.val); break;
        case 0x8D: plugin.queryInstancesPending = true; break;
        case 0x8E: plugin.queryNetsPending      = true; break;
        default:
          if (msg.tag >= 0xA0 && msg.tag <= 0xAB) {
            (plugin._currentWidgets ??= []).push(msg);
          }
          break;
      }
    }
  }

  // ── _writePendingResponses (mirrors plugin_host.js) ────────────────── //

  function _writePendingResponses(w, plugin) {
    for (const sr of (plugin.pendingStateResponses ?? [])) {
      w.msg(0x0A, () => { w.writeStr(sr.key); w.writeStr(sr.val ?? ""); });
    }
    plugin.pendingStateResponses = [];

    for (const cr of (plugin.pendingConfigResponses ?? [])) {
      w.msg(0x0B, () => { w.writeStr(cr.plugin_id + ":" + cr.key); w.writeStr(cr.val ?? ""); });
    }
    plugin.pendingConfigResponses = [];

    if (plugin.queryInstancesPending) {
      plugin.queryInstancesPending = false;
      const instances = _app.getInstanceData?.() ?? [];
      for (const inst of instances) {
        w.msg(0x0F, () => { w.writeU32le(inst.idx); w.writeStr(inst.name); w.writeStr(inst.symbol); });
        const props = _app.getInstanceProps?.(inst.idx) ?? [];
        for (const p of props) {
          w.msg(0x10, () => { w.writeU32le(inst.idx); w.writeStr(p.key); w.writeStr(p.val); });
        }
      }
    }

    if (plugin.queryNetsPending) {
      plugin.queryNetsPending = false;
      const nets = _app.getNetData?.() ?? [];
      for (const n of nets) {
        w.msg(0x11, () => { w.writeU32le(n.idx); w.writeStr(n.name); });
      }
    }
  }

  // ── callProcess ──────────────────────────────────────────────────────── //
  //
  // Calls the Python plugin's schemify_process(in_bytes) → bytes.
  // Returns a Uint8Array of the output, or null on error.

  function callProcess(plugin, inBytes) {
    if (!plugin.hasProcess) return null;
    try {
      const pyProcess = plugin.ns.get("schemify_process");
      if (!pyProcess) return null;
      // Pass a Python bytes object.  Pyodide converts Uint8Array → bytes automatically.
      const result = pyProcess(inBytes);
      if (!result) return null;
      // Convert Python bytes / bytearray → Uint8Array.
      const outBytes = result.toJs?.() ?? result;
      return outBytes instanceof Uint8Array ? outBytes : new Uint8Array(outBytes);
    } catch (e) {
      console.error(`[py-plugin-host] schemify_process error in ${plugin.name}:`, e);
      return null;
    }
  }

  // ── _injectSchemifyModule ─────────────────────────────────────────────── //
  //
  // Installs the `schemify` module into Pyodide.  The module provides:
  //
  //   1. Tag constants (TAG_LOAD, TAG_TICK, …)
  //   2. Reader / Writer classes that operate on Python bytes objects,
  //      delegating encoding/decoding to the JS MsgWriter/MsgReader via
  //      pyodide's JS bridge.
  //   3. Convenience wrappers (set_status, register_panel, draw decorator, UiCtx)
  //      for plugins that use the legacy on_load / draw-callback style.
  //      These plugins are wrapped into a schemify_process implementation
  //      automatically when loaded.

  function _injectSchemifyModule(pyodide) {
    // Expose JS codec to Python via a namespace object.
    pyodide.globals.set("_schemify_js", {
      new_writer:  () => new (_codec().MsgWriter)(),
      new_reader:  (b) => new (_codec().MsgReader)(b instanceof Uint8Array ? b : new Uint8Array(b)),
      writer_msg:  (w, tag, fn) => w.msg(tag, fn),
      writer_u8:   (w, v)      => w.writeU8(v),
      writer_u16:  (w, v)      => w.writeU16le(v),
      writer_u32:  (w, v)      => w.writeU32le(v),
      writer_i32:  (w, v)      => w.writeI32le(v),
      writer_f32:  (w, v)      => w.writeF32le(v),
      writer_str:  (w, s)      => w.writeStr(s),
      writer_f32arr:(w, a)     => w.writeF32Arr(a),
      writer_u8arr: (w, a)     => w.writeU8Arr(a),
      writer_bytes: (w)        => w.bytes(),
      reader_all:  (r)         => r.readAll(),
    });

    pyodide.runPython(`
import sys, types, js as _js

_jsh = _js._schemify_js

# ── Tag constants ──────────────────────────────────────────────────────────
TAG_LOAD              = 0x01
TAG_UNLOAD            = 0x02
TAG_TICK              = 0x03
TAG_DRAW_PANEL        = 0x04
TAG_BUTTON_CLICKED    = 0x05
TAG_SLIDER_CHANGED    = 0x06
TAG_TEXT_CHANGED      = 0x07
TAG_CHECKBOX_CHANGED  = 0x08
TAG_COMMAND           = 0x09
TAG_STATE_RESPONSE    = 0x0A
TAG_CONFIG_RESPONSE   = 0x0B
TAG_SCHEMATIC_CHANGED = 0x0C
TAG_SELECTION_CHANGED = 0x0D
TAG_SCHEMATIC_SNAPSHOT= 0x0E
TAG_INSTANCE_DATA     = 0x0F
TAG_INSTANCE_PROP     = 0x10
TAG_NET_DATA          = 0x11

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

TAG_UI_LABEL            = 0xA0
TAG_UI_BUTTON           = 0xA1
TAG_UI_SEPARATOR        = 0xA2
TAG_UI_BEGIN_ROW        = 0xA3
TAG_UI_END_ROW          = 0xA4
TAG_UI_SLIDER           = 0xA5
TAG_UI_CHECKBOX         = 0xA6
TAG_UI_PROGRESS         = 0xA7
TAG_UI_PLOT             = 0xA8
TAG_UI_IMAGE            = 0xA9
TAG_UI_COLLAPSIBLE_START= 0xAA
TAG_UI_COLLAPSIBLE_END  = 0xAB

LAYOUT_OVERLAY       = 0
LAYOUT_LEFT_SIDEBAR  = 1
LAYOUT_RIGHT_SIDEBAR = 2
LAYOUT_BOTTOM_BAR    = 3

# ── Reader ─────────────────────────────────────────────────────────────────
class Reader:
    """Decodes a batch of host→plugin messages from a bytes object."""
    def __init__(self, data: bytes):
        self._data = bytes(data)
        self._msgs = None

    def _ensure(self):
        if self._msgs is None:
            import js as _js2
            r = _jsh.new_reader(bytearray(self._data))
            js_msgs = _jsh.reader_all(r)
            self._msgs = [dict(m) for m in js_msgs.to_py()]

    def __iter__(self):
        self._ensure()
        return iter(self._msgs)

    def messages(self):
        self._ensure()
        return list(self._msgs)

# ── Writer ─────────────────────────────────────────────────────────────────
class Writer:
    """Encodes plugin→host messages into a bytes buffer."""
    def __init__(self):
        self._w = _jsh.new_writer()

    def _msg(self, tag, fn):
        _jsh.writer_msg(self._w, tag, fn)

    def register_panel(self, id, title, vim_cmd, layout=LAYOUT_LEFT_SIDEBAR, keybind=0):
        def _write():
            _jsh.writer_str(self._w, id)
            _jsh.writer_str(self._w, title)
            _jsh.writer_str(self._w, vim_cmd)
            _jsh.writer_u8(self._w, layout)
            _jsh.writer_u8(self._w, keybind)
        self._msg(TAG_REGISTER_PANEL, _write)

    def set_status(self, msg):
        def _write(): _jsh.writer_str(self._w, str(msg))
        self._msg(TAG_SET_STATUS, _write)

    def log(self, level, tag, msg):
        def _write():
            _jsh.writer_u8(self._w, level)
            _jsh.writer_str(self._w, tag)
            _jsh.writer_str(self._w, msg)
        self._msg(TAG_LOG, _write)

    def push_command(self, tag, payload=""):
        def _write():
            _jsh.writer_str(self._w, tag)
            _jsh.writer_str(self._w, payload)
        self._msg(TAG_PUSH_COMMAND, _write)

    def set_state(self, key, val):
        def _write():
            _jsh.writer_str(self._w, key)
            _jsh.writer_str(self._w, val)
        self._msg(TAG_SET_STATE, _write)

    def get_state(self, key):
        def _write(): _jsh.writer_str(self._w, key)
        self._msg(TAG_GET_STATE, _write)

    def set_config(self, plugin_id, key, val):
        def _write():
            _jsh.writer_str(self._w, plugin_id)
            _jsh.writer_str(self._w, key)
            _jsh.writer_str(self._w, val)
        self._msg(TAG_SET_CONFIG, _write)

    def get_config(self, plugin_id, key):
        def _write():
            _jsh.writer_str(self._w, plugin_id)
            _jsh.writer_str(self._w, key)
        self._msg(TAG_GET_CONFIG, _write)

    def request_refresh(self):
        self._msg(TAG_REQUEST_REFRESH, lambda: None)

    def register_keybind(self, key, mods, cmd_tag):
        def _write():
            _jsh.writer_u8(self._w, key)
            _jsh.writer_u8(self._w, mods)
            _jsh.writer_str(self._w, cmd_tag)
        self._msg(TAG_REGISTER_KEYBIND, _write)

    def place_device(self, sym, name, x, y):
        def _write():
            _jsh.writer_str(self._w, sym)
            _jsh.writer_str(self._w, name)
            _jsh.writer_i32(self._w, int(x))
            _jsh.writer_i32(self._w, int(y))
        self._msg(TAG_PLACE_DEVICE, _write)

    def add_wire(self, x0, y0, x1, y1):
        def _write():
            _jsh.writer_i32(self._w, int(x0)); _jsh.writer_i32(self._w, int(y0))
            _jsh.writer_i32(self._w, int(x1)); _jsh.writer_i32(self._w, int(y1))
        self._msg(TAG_ADD_WIRE, _write)

    def set_instance_prop(self, idx, key, val):
        def _write():
            _jsh.writer_u32(self._w, int(idx))
            _jsh.writer_str(self._w, key)
            _jsh.writer_str(self._w, val)
        self._msg(TAG_SET_INSTANCE_PROP, _write)

    def query_instances(self):
        self._msg(TAG_QUERY_INSTANCES, lambda: None)

    def query_nets(self):
        self._msg(TAG_QUERY_NETS, lambda: None)

    # ── UI widgets ─────────────────────────────────────────────────────────
    def label(self, text, id=0):
        def _write():
            _jsh.writer_str(self._w, str(text)); _jsh.writer_u32(self._w, int(id))
        self._msg(TAG_UI_LABEL, _write)

    def button(self, text, id=0):
        def _write():
            _jsh.writer_str(self._w, str(text)); _jsh.writer_u32(self._w, int(id))
        self._msg(TAG_UI_BUTTON, _write)

    def separator(self, id=0):
        def _write(): _jsh.writer_u32(self._w, int(id))
        self._msg(TAG_UI_SEPARATOR, _write)

    def begin_row(self, id=0):
        def _write(): _jsh.writer_u32(self._w, int(id))
        self._msg(TAG_UI_BEGIN_ROW, _write)

    def end_row(self, id=0):
        def _write(): _jsh.writer_u32(self._w, int(id))
        self._msg(TAG_UI_END_ROW, _write)

    def slider(self, val, min_val, max_val, id=0):
        def _write():
            _jsh.writer_f32(self._w, float(val))
            _jsh.writer_f32(self._w, float(min_val))
            _jsh.writer_f32(self._w, float(max_val))
            _jsh.writer_u32(self._w, int(id))
        self._msg(TAG_UI_SLIDER, _write)

    def checkbox(self, val, text, id=0):
        def _write():
            _jsh.writer_u8(self._w, 1 if val else 0)
            _jsh.writer_str(self._w, str(text))
            _jsh.writer_u32(self._w, int(id))
        self._msg(TAG_UI_CHECKBOX, _write)

    def progress(self, fraction, id=0):
        def _write():
            _jsh.writer_f32(self._w, float(fraction))
            _jsh.writer_u32(self._w, int(id))
        self._msg(TAG_UI_PROGRESS, _write)

    def plot(self, title, x_data, y_data, id=0):
        import js as _js2
        def _write():
            _jsh.writer_str(self._w, str(title))
            _jsh.writer_f32arr(self._w, _js2.Float32Array.from_(list(x_data)))
            _jsh.writer_f32arr(self._w, _js2.Float32Array.from_(list(y_data)))
            _jsh.writer_u32(self._w, int(id))
        self._msg(TAG_UI_PLOT, _write)

    def image(self, width, height, pixels, id=0):
        import js as _js2
        def _write():
            _jsh.writer_u32(self._w, int(width))
            _jsh.writer_u32(self._w, int(height))
            _jsh.writer_u8arr(self._w, _js2.Uint8Array.from_(list(pixels)))
            _jsh.writer_u32(self._w, int(id))
        self._msg(TAG_UI_IMAGE, _write)

    def collapsible_start(self, label, open=True, id=0):
        def _write():
            _jsh.writer_str(self._w, str(label))
            _jsh.writer_u8(self._w, 1 if open else 0)
            _jsh.writer_u32(self._w, int(id))
        self._msg(TAG_UI_COLLAPSIBLE_START, _write)

    def collapsible_end(self, id=0):
        def _write(): _jsh.writer_u32(self._w, int(id))
        self._msg(TAG_UI_COLLAPSIBLE_END, _write)

    def bytes(self):
        js_bytes = _jsh.writer_bytes(self._w)
        return bytes(js_bytes.to_py())

# ── Legacy UiCtx ───────────────────────────────────────────────────────────
#
# Adapts the old draw-callback style to v6 Writer.
# When a plugin registers panels with @schemify.draw() and defines on_load /
# on_tick / on_unload, this host generates a schemify_process wrapper for it.

class UiCtx:
    """Passed to @schemify.draw callbacks; delegates writes to a Writer."""
    def __init__(self, writer: "Writer", button_clicked_ids: set):
        self._w       = writer
        self._clicked = button_clicked_ids
        self._id      = 0

    def _next_id(self):
        i = self._id; self._id += 1; return i

    def label(self, text):
        self._w.label(str(text), self._next_id())

    def button(self, text):
        id = self._next_id()
        self._w.button(str(text), id)
        return id in self._clicked

    def separator(self):
        self._w.separator(self._next_id())

    def begin_row(self):
        self._w.begin_row(self._next_id())

    def end_row(self):
        self._w.end_row(self._next_id())

    def slider(self, val, min_val=0.0, max_val=1.0):
        id = self._next_id()
        self._w.slider(float(val), float(min_val), float(max_val), id)
        # Return the slider's current value — caller tracks changes separately.
        return float(val)

    def checkbox(self, val, text=""):
        id = self._next_id()
        self._w.checkbox(bool(val), str(text), id)
        return bool(val)

    def progress(self, fraction):
        self._w.progress(float(fraction), self._next_id())

    def plot(self, title, x_data, y_data):
        self._w.plot(str(title), x_data, y_data, self._next_id())

    def image(self, width, height, pixels):
        self._w.image(int(width), int(height), pixels, self._next_id())

    def collapsible_start(self, label, open=True):
        self._w.collapsible_start(str(label), bool(open), self._next_id())

    def collapsible_end(self):
        self._w.collapsible_end(self._next_id())

# ── draw decorator & registry ─────────────────────────────────────────────

_draw_registry = {}  # vim_cmd → callable(ctx)
_panel_registry = [] # list of (id, title, vim_cmd, layout, keybind)

def draw(vim_cmd):
    """Decorator: @schemify.draw("my-vim-cmd") def fn(ctx): ..."""
    def decorator(fn):
        _draw_registry[vim_cmd] = fn
        return fn
    return decorator

def register_panel(id, title, vim_cmd, layout=LAYOUT_LEFT_SIDEBAR, keybind=0):
    """Queue a panel for registration; emitted during the next Load message."""
    _panel_registry.append((id, title, vim_cmd, layout, keybind))

def register_overlay(name, keybind=0):
    register_panel(name, name, name, LAYOUT_OVERLAY, keybind)

def set_status(msg):
    # Convenience — only valid during a process call (stash for emission).
    _pending_status.append(str(msg))

def push_command(tag, payload=""):
    _pending_commands.append((tag, payload or ""))

def request_refresh():
    _pending_refresh.append(True)

def log_info(msg):
    print(f"[schemify][INFO] {msg}")

def register_keybind(key, mods, tag):
    _pending_keybinds.append((key, mods, tag))

# ── Pending accumulation buffers (flushed by the wrapper's schemify_process) ─
_pending_status   = []
_pending_commands = []
_pending_refresh  = []
_pending_keybinds = []

# ── Install as schemify module ────────────────────────────────────────────

_mod = types.ModuleType("schemify")
_pub = {k: v for k, v in globals().items()
        if not k.startswith("_") or k in ("__doc__",)}
_pub.update({
    "Reader": Reader, "Writer": Writer, "UiCtx": UiCtx,
    "_draw_registry": _draw_registry,
    "_panel_registry": _panel_registry,
    "_pending_status": _pending_status,
    "_pending_commands": _pending_commands,
    "_pending_refresh": _pending_refresh,
    "_pending_keybinds": _pending_keybinds,
})
_mod.__dict__.update(_pub)
sys.modules["schemify"] = _mod
del _mod, _pub
`);
    console.info("[py-plugin-host] schemify module installed");
  }

  // ── _makeProcessWrapper ───────────────────────────────────────────────── //
  //
  // For Python plugins that use the legacy on_load / @schemify.draw pattern
  // rather than implementing schemify_process directly, we build a
  // schemify_process wrapper in Python and install it into the plugin namespace.

  function _makeProcessWrapper(pyodide, ns) {
    pyodide.runPython(`
import schemify as _sch

def _make_wrapper(ns):
    _on_load    = ns.get("on_load",   None)
    _on_tick    = ns.get("on_tick",   None)
    _on_unload  = ns.get("on_unload", None)

    def schemify_process(in_bytes: bytes) -> bytes:
        r = _sch.Reader(in_bytes)
        w = _sch.Writer()

        # Flush any pending accumulation from legacy helpers.
        for msg in r.messages():
            tag = msg.get("tag")
            if tag == _sch.TAG_LOAD:
                # Emit queued RegisterPanel calls first.
                for (pid, title, vim_cmd, layout, keybind) in list(_sch._panel_registry):
                    w.register_panel(pid, title, vim_cmd, layout, keybind)
                _sch._panel_registry.clear()
                if _on_load:
                    _on_load()
            elif tag == _sch.TAG_UNLOAD:
                if _on_unload:
                    _on_unload()
            elif tag == _sch.TAG_TICK:
                dt = msg.get("dt", 0.0)
                if _on_tick:
                    _on_tick(dt)
            elif tag == _sch.TAG_DRAW_PANEL:
                panel_id = msg.get("panel_id", 0)
                # Find the vim_cmd for this panel_id (we track it via the writer's
                # RegisterPanel calls which are already done).  We need the registry.
                # The draw registry uses vim_cmd keys so look up by panel.
                # Since we have no reverse mapping here, call all registered draws?
                # Better: build a panel_id → vim_cmd map at registration time.
                # For now, call every registered draw function (only one panel per
                # Python plugin is the typical case).
                clicked_ids = set()
                for sub_msg in r.messages():
                    if sub_msg.get("tag") == _sch.TAG_BUTTON_CLICKED:
                        clicked_ids.add(sub_msg.get("widget_id", 0))
                for vim_cmd_key, draw_fn in _sch._draw_registry.items():
                    ctx = _sch.UiCtx(w, clicked_ids)
                    try:
                        draw_fn(ctx)
                    except Exception as e:
                        import traceback
                        w.set_status(f"[py-plugin] draw error: {e}")

        # Flush pending status / commands / refresh / keybinds from legacy helpers.
        for msg in list(_sch._pending_status):
            w.set_status(msg)
        _sch._pending_status.clear()

        for (tag_str, payload) in list(_sch._pending_commands):
            w.push_command(tag_str, payload)
        _sch._pending_commands.clear()

        for _ in list(_sch._pending_refresh):
            w.request_refresh()
        _sch._pending_refresh.clear()

        for (key, mods, cmd_tag) in list(_sch._pending_keybinds):
            w.register_keybind(key, mods, cmd_tag)
        _sch._pending_keybinds.clear()

        return w.bytes()

    return schemify_process

_tmp_wrapper = _make_wrapper
`, { globals: pyodide.globals });

    // Inject the wrapper factory and call it with the plugin's namespace.
    const makeWrapper = pyodide.globals.get("_tmp_wrapper");
    const wrapper     = makeWrapper(ns);
    ns.set("schemify_process", wrapper);
    pyodide.globals.delete("_tmp_wrapper");
  }

  // ── loadPyPlugin ─────────────────────────────────────────────────────── //

  async function loadPyPlugin(url) {
    try {
      const py  = await _loadPyodide();
      const res = await fetch(url, { cache: "no-store" });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const src = await res.text();

      // Clear the legacy accumulation buffers before running the plugin module.
      py.runPython(`
import schemify as _sch
_sch._panel_registry.clear()
_sch._draw_registry.clear()
_sch._pending_status.clear()
_sch._pending_commands.clear()
_sch._pending_refresh.clear()
_sch._pending_keybinds.clear()
`);

      // Run plugin source in a fresh namespace.
      const ns = py.globals.get("dict")();
      py.runPython(src, { globals: ns });

      const hasProcess = !!ns.get("schemify_process");
      if (!hasProcess) {
        // Legacy plugin — generate a schemify_process wrapper.
        _makeProcessWrapper(py, ns);
      }

      const plugin = {
        url,
        name: url.split("/").pop(),
        ns,
        hasProcess: true, // always true after potential wrapper injection
        panels: new Map(),
        pendingStateResponses:  [],
        pendingConfigResponses: [],
        queryInstancesPending:  false,
        queryNetsPending:       false,
        _currentWidgets:        null,
      };

      _pyPlugins.push(plugin);

      // Send Load message.
      const { MsgWriter } = _codec();
      const w = new MsgWriter();
      w.msg(0x01, () => {});
      const out = callProcess(plugin, w.bytes());
      if (out) parseOutput(plugin, out);

      console.info("[py-plugin-host] loaded", url);
    } catch (e) {
      console.warn("[py-plugin-host] failed to load", url, e);
    }
  }

  // ── tick ─────────────────────────────────────────────────────────────── //

  function tick(dt) {
    if (_pyPlugins.length === 0) return;
    const { MsgWriter } = _codec();
    const snap = _app.getSchematicSnapshot();

    for (const plugin of _pyPlugins) {
      const w = new MsgWriter();
      w.msg(0x03, () => { w.writeF32le(dt); });
      w.msg(0x0E, () => {
        w.writeU32le(snap.instance_count >>> 0);
        w.writeU32le(snap.wire_count     >>> 0);
        w.writeU32le(snap.net_count      >>> 0);
      });
      _writePendingResponses(w, plugin);
      const out = callProcess(plugin, w.bytes());
      if (out) parseOutput(plugin, out);
    }
  }

  // ── drawPanel ────────────────────────────────────────────────────────── //

  function drawPanel(panelId, interactions) {
    const plugin = _pyPlugins.find(p => p.panels.has(panelId));
    if (!plugin) return [];

    const { MsgWriter } = _codec();
    const w = new MsgWriter();

    w.msg(0x04, () => { w.writeU16le(panelId); });

    for (const ev of (interactions ?? [])) {
      switch (ev.type) {
        case "button":
          w.msg(0x05, () => { w.writeU16le(panelId); w.writeU32le(ev.widget_id >>> 0); });
          break;
        case "slider":
          w.msg(0x06, () => { w.writeU16le(panelId); w.writeU32le(ev.widget_id >>> 0); w.writeF32le(ev.val); });
          break;
        case "text":
          w.msg(0x07, () => { w.writeU16le(panelId); w.writeU32le(ev.widget_id >>> 0); w.writeStr(ev.text); });
          break;
        case "checkbox":
          w.msg(0x08, () => { w.writeU16le(panelId); w.writeU32le(ev.widget_id >>> 0); w.writeU8(ev.val ? 1 : 0); });
          break;
      }
    }

    plugin._currentWidgets = [];
    const out = callProcess(plugin, w.bytes());
    if (out) parseOutput(plugin, out);
    const widgets = plugin._currentWidgets ?? [];
    plugin._currentWidgets = null;
    return widgets;
  }

  // ── loadFromJson ─────────────────────────────────────────────────────── //

  async function loadFromJson(jsonUrl = "plugins/plugins.json") {
    try {
      const res = await fetch(jsonUrl, { cache: "no-store" });
      if (!res.ok) return;
      const json   = await res.json();
      const entries = Array.isArray(json) ? json : (json.plugins ?? []);
      const pyUrls  = entries
        .map(e => typeof e === "string" ? e : (e.url ?? e))
        .filter(u => typeof u === "string" && u.endsWith(".py"))
        .map(u => u.startsWith("http") ? u : `plugins/${u}`);
      for (const url of pyUrls) await loadPyPlugin(url);
    } catch (_e) { /* no Python plugins */ }
  }

  // ── Public API ────────────────────────────────────────────────────────── //

  window.schemifyPyodideHost = {
    /** Wire up app callbacks (same interface as schemifyPluginHost.setAppState). */
    setAppState(app) { Object.assign(_app, app); },

    /** Load all .py plugins listed in the manifest. */
    loadFromJson,

    /** Load a single Python plugin by URL. */
    loadPlugin: loadPyPlugin,

    /**
     * Drive all Python plugins for one frame.
     * @param {number} dt  Delta time in seconds.
     */
    tick,

    /**
     * Draw a Python plugin panel, returning the widget list.
     * @param {number} panelId       Numeric panel ID.
     * @param {Array}  interactions  Interaction events from the previous frame.
     * @returns {Array} Widget message objects.
     */
    drawPanel,

    /** Send Unload to all Python plugins and clear the list. */
    unloadAll() {
      if (_pyPlugins.length === 0) return;
      const { MsgWriter } = _codec();
      for (const plugin of _pyPlugins) {
        try {
          const w = new MsgWriter();
          w.msg(0x02, () => {});
          callProcess(plugin, w.bytes());
        } catch (_e) {}
      }
      _pyPlugins.length = 0;
    },

    /** True after at least one Python plugin has been loaded. */
    get ready() { return _pyPlugins.length > 0; },

    /** Read-only view of loaded Python plugins. */
    get plugins() { return _pyPlugins; },
  };

  // Auto-boot alongside schemifyPluginHost.
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () =>
      window.schemifyPyodideHost.loadFromJson());
  } else {
    Promise.resolve().then(() => window.schemifyPyodideHost.loadFromJson());
  }
})();
