// plugin_host.js — Schemify WASM plugin host (ABI v6).
//
// Loaded by index.html before the main Schemify WASM module.
// Reads plugins/plugins.json, instantiates each listed .wasm file,
// and drives the v6 binary message protocol.
//
// ABI v6 plugins export only one symbol:
//   schemify_process(in_ptr: i32, in_len: i32, out_ptr: i32, out_cap: i32) → i32
//
// Zero host imports.  No named draw exports.

(() => {
  // ── Wire-format encoder ────────────────────────────────────────────────── //

  const _ENC = new TextEncoder();
  const _DEC = new TextDecoder();

  class MsgWriter {
    constructor(capacity = 64 * 1024) {
      this._buf = new ArrayBuffer(capacity);
      this._view = new DataView(this._buf);
      this._u8   = new Uint8Array(this._buf);
      this._pos  = 0;
    }

    _grow(need) {
      if (this._pos + need <= this._buf.byteLength) return;
      let cap = this._buf.byteLength;
      while (cap < this._pos + need) cap *= 2;
      const next = new ArrayBuffer(cap);
      new Uint8Array(next).set(this._u8.subarray(0, this._pos));
      this._buf  = next;
      this._view = new DataView(next);
      this._u8   = new Uint8Array(next);
    }

    writeU8(v)    { this._grow(1); this._view.setUint8(this._pos, v & 0xFF);          this._pos += 1; }
    writeU16le(v) { this._grow(2); this._view.setUint16(this._pos, v, true);           this._pos += 2; }
    writeU32le(v) { this._grow(4); this._view.setUint32(this._pos, v >>> 0, true);     this._pos += 4; }
    writeI32le(v) { this._grow(4); this._view.setInt32(this._pos, v, true);            this._pos += 4; }
    writeF32le(v) { this._grow(4); this._view.setFloat32(this._pos, v, true);          this._pos += 4; }

    writeStr(s) {
      const bytes = _ENC.encode(s);
      this._grow(2 + bytes.length);
      this._view.setUint16(this._pos, bytes.length, true);
      this._pos += 2;
      this._u8.set(bytes, this._pos);
      this._pos += bytes.length;
    }

    writeF32Arr(arr) {
      this._grow(4 + arr.length * 4);
      this._view.setUint32(this._pos, arr.length, true);
      this._pos += 4;
      for (let i = 0; i < arr.length; i++) {
        this._view.setFloat32(this._pos, arr[i], true);
        this._pos += 4;
      }
    }

    writeU8Arr(arr) {
      this._grow(4 + arr.length);
      this._view.setUint32(this._pos, arr.length, true);
      this._pos += 4;
      this._u8.set(arr, this._pos);
      this._pos += arr.length;
    }

    // Writes [tag u8][payload_sz u16 LE][payload], patching payload_sz after fn runs.
    msg(tag, fn) {
      this.writeU8(tag);
      const szOffset = this._pos;
      this.writeU16le(0); // placeholder
      const payloadStart = this._pos;
      fn();
      const payloadLen = this._pos - payloadStart;
      this._view.setUint16(szOffset, payloadLen, true);
    }

    bytes() { return new Uint8Array(this._buf, 0, this._pos); }
    reset() { this._pos = 0; }
  }

  // ── Wire-format decoder ────────────────────────────────────────────────── //

  class MsgReader {
    constructor(bytes) {
      // bytes may be a view into WASM memory; copy it so the buffer outlives the call.
      this._bytes = bytes instanceof Uint8Array ? bytes.slice() : new Uint8Array(bytes);
      this._view  = new DataView(this._bytes.buffer, this._bytes.byteOffset);
      this._pos   = 0;
    }

    hasMore() { return this._pos < this._bytes.length; }
    readU8()    { const v = this._view.getUint8(this._pos);               this._pos += 1; return v; }
    readU16le() { const v = this._view.getUint16(this._pos, true);        this._pos += 2; return v; }
    readU32le() { const v = this._view.getUint32(this._pos, true);        this._pos += 4; return v; }
    readI32le() { const v = this._view.getInt32(this._pos, true);         this._pos += 4; return v; }
    readF32le() { const v = this._view.getFloat32(this._pos, true);       this._pos += 4; return v; }

    readStr() {
      const len = this.readU16le();
      const s = _DEC.decode(this._bytes.subarray(this._pos, this._pos + len));
      this._pos += len;
      return s;
    }

    readF32Arr() {
      const count = this.readU32le();
      const arr   = new Float32Array(count);
      for (let i = 0; i < count; i++) { arr[i] = this.readF32le(); }
      return arr;
    }

    readU8Arr() {
      const count = this.readU32le();
      const arr   = this._bytes.slice(this._pos, this._pos + count);
      this._pos += count;
      return arr;
    }

    // Parse one message, advancing position.  Returns null on truncation / unknown.
    // On unknown tag, skips the entire payload using payload_sz.
    _readOne() {
      if (this._pos + 3 > this._bytes.length) return null; // not enough for header
      const tag        = this.readU8();
      const payloadSz  = this.readU16le();
      const payloadEnd = this._pos + payloadSz;

      if (payloadEnd > this._bytes.length) return null; // truncated

      let msg = null;
      try {
        msg = this._parsePayload(tag, payloadSz);
      } catch (_e) {
        // parse error — skip this message
      }
      // Always advance past the declared payload, regardless of parse result.
      this._pos = payloadEnd;
      return msg;
    }

    _parsePayload(tag, _sz) {
      switch (tag) {
        // ── Host→plugin ──────────────────────────────────────────────────── //
        case 0x01: return { tag: 0x01, name: "Load" };
        case 0x02: return { tag: 0x02, name: "Unload" };
        case 0x03: return { tag: 0x03, name: "Tick",              dt: this.readF32le() };
        case 0x04: return { tag: 0x04, name: "DrawPanel",         panel_id: this.readU16le() };
        case 0x05: return { tag: 0x05, name: "ButtonClicked",     panel_id: this.readU16le(), widget_id: this.readU32le() };
        case 0x06: return { tag: 0x06, name: "SliderChanged",     panel_id: this.readU16le(), widget_id: this.readU32le(), val: this.readF32le() };
        case 0x07: return { tag: 0x07, name: "TextChanged",       panel_id: this.readU16le(), widget_id: this.readU32le(), text: this.readStr() };
        case 0x08: return { tag: 0x08, name: "CheckboxChanged",   panel_id: this.readU16le(), widget_id: this.readU32le(), val: this.readU8() };
        case 0x09: return { tag: 0x09, name: "Command",           tag_str: this.readStr(), payload: this.readStr() };
        case 0x0A: return { tag: 0x0A, name: "StateResponse",     key: this.readStr(), val: this.readStr() };
        case 0x0B: return { tag: 0x0B, name: "ConfigResponse",    key: this.readStr(), val: this.readStr() };
        case 0x0C: return { tag: 0x0C, name: "SchematicChanged" };
        case 0x0D: return { tag: 0x0D, name: "SelectionChanged",  instance_idx: this.readI32le() };
        case 0x0E: return { tag: 0x0E, name: "SchematicSnapshot", instance_count: this.readU32le(), wire_count: this.readU32le(), net_count: this.readU32le() };
        case 0x0F: return { tag: 0x0F, name: "InstanceData",      idx: this.readU32le(), name: this.readStr(), symbol: this.readStr() };
        case 0x10: return { tag: 0x10, name: "InstanceProp",      idx: this.readU32le(), key: this.readStr(), val: this.readStr() };
        case 0x11: return { tag: 0x11, name: "NetData",           idx: this.readU32le(), name: this.readStr() };
        // ── Plugin→host: commands ────────────────────────────────────────── //
        case 0x80: return { tag: 0x80, name: "RegisterPanel",     id: this.readStr(), title: this.readStr(), vim_cmd: this.readStr(), layout: this.readU8(), keybind: this.readU8() };
        case 0x81: return { tag: 0x81, name: "SetStatus",         msg: this.readStr() };
        case 0x82: return { tag: 0x82, name: "Log",               level: this.readU8(), tag_str: this.readStr(), msg: this.readStr() };
        case 0x83: return { tag: 0x83, name: "PushCommand",       tag_str: this.readStr(), payload: this.readStr() };
        case 0x84: return { tag: 0x84, name: "SetState",          key: this.readStr(), val: this.readStr() };
        case 0x85: return { tag: 0x85, name: "GetState",          key: this.readStr() };
        case 0x86: return { tag: 0x86, name: "SetConfig",         plugin_id: this.readStr(), key: this.readStr(), val: this.readStr() };
        case 0x87: return { tag: 0x87, name: "GetConfig",         plugin_id: this.readStr(), key: this.readStr() };
        case 0x88: return { tag: 0x88, name: "RequestRefresh" };
        case 0x89: return { tag: 0x89, name: "RegisterKeybind",   key: this.readU8(), mods: this.readU8(), cmd_tag: this.readStr() };
        case 0x8A: return { tag: 0x8A, name: "PlaceDevice",       sym: this.readStr(), device_name: this.readStr(), x: this.readI32le(), y: this.readI32le() };
        case 0x8B: return { tag: 0x8B, name: "AddWire",           x0: this.readI32le(), y0: this.readI32le(), x1: this.readI32le(), y1: this.readI32le() };
        case 0x8C: return { tag: 0x8C, name: "SetInstanceProp",   idx: this.readU32le(), key: this.readStr(), val: this.readStr() };
        case 0x8D: return { tag: 0x8D, name: "QueryInstances" };
        case 0x8E: return { tag: 0x8E, name: "QueryNets" };
        // ── Plugin→host: UI widgets ──────────────────────────────────────── //
        case 0xA0: return { tag: 0xA0, name: "UiLabel",            text: this.readStr(), id: this.readU32le() };
        case 0xA1: return { tag: 0xA1, name: "UiButton",           text: this.readStr(), id: this.readU32le() };
        case 0xA2: return { tag: 0xA2, name: "UiSeparator",        id: this.readU32le() };
        case 0xA3: return { tag: 0xA3, name: "UiBeginRow",         id: this.readU32le() };
        case 0xA4: return { tag: 0xA4, name: "UiEndRow",           id: this.readU32le() };
        case 0xA5: return { tag: 0xA5, name: "UiSlider",           val: this.readF32le(), min: this.readF32le(), max: this.readF32le(), id: this.readU32le() };
        case 0xA6: return { tag: 0xA6, name: "UiCheckbox",         val: this.readU8(), text: this.readStr(), id: this.readU32le() };
        case 0xA7: return { tag: 0xA7, name: "UiProgress",         fraction: this.readF32le(), id: this.readU32le() };
        case 0xA8: return { tag: 0xA8, name: "UiPlot",             title: this.readStr(), x_data: this.readF32Arr(), y_data: this.readF32Arr(), id: this.readU32le() };
        case 0xA9: return { tag: 0xA9, name: "UiImage",            width: this.readU32le(), height: this.readU32le(), pixels: this.readU8Arr(), id: this.readU32le() };
        case 0xAA: return { tag: 0xAA, name: "UiCollapsibleStart", label: this.readStr(), open: this.readU8(), id: this.readU32le() };
        case 0xAB: return { tag: 0xAB, name: "UiCollapsibleEnd",   id: this.readU32le() };
        default:   return null; // unknown — caller will skip via payloadEnd
      }
    }

    // Returns an array of all successfully parsed messages in the buffer.
    readAll() {
      const out = [];
      while (this.hasMore()) {
        const msg = this._readOne();
        if (msg !== null) out.push(msg);
      }
      return out;
    }
  }

  // ── Per-plugin state ───────────────────────────────────────────────────── //
  //
  // Each entry:
  //   { inst, url, name, version, panels: Map<panelId, panelInfo>,
  //     pendingStateResponses, pendingConfigResponses,
  //     queryInstancesPending, queryNetsPending,
  //     _currentWidgets }

  const _plugins = [];

  // ── App state (set by main WASM glue) ─────────────────────────────────── //

  let _app = {
    statusFn:         (msg) => console.info("[plugin] status:", msg),
    // registerPanelFn returns the numeric panelId assigned by the host.
    registerPanelFn:  (id, title, vim, layout, keybind) => {
      console.debug("[plugin] register_panel", { id, title, vim, layout, keybind });
      return 1;
    },
    projectDir:           ".",
    activeSchematicName:  null,
    requestRefreshFn:     () => {},
    onPluginCommand:      null,    // (tag, payload) => void
    registerKeybindFn:    null,    // (key, mods, cmd_tag) => void
    placeDevice:          null,    // (sym, name, x, y) => void
    addWire:              null,    // (x0, y0, x1, y1) => void
    setInstancePropFn:    null,    // (idx, key, val) => void
    // Called by host to supply data requested via QueryInstances / QueryNets.
    getSchematicSnapshot: () => ({ instance_count: 0, wire_count: 0, net_count: 0 }),
    getInstanceData:      null,    // () => [{idx, name, symbol}]
    getNetData:           null,    // () => [{idx, name}]
    getInstanceProps:     null,    // (idx) => [{key, val}]
  };

  // ── In-memory VFS ─────────────────────────────────────────────────────── //

  const _vfs = {
    _store: new Map(),
    _dirs:  new Set([""]),

    read(path)   { return this._store.get(path) ?? null; },
    write(path, data) {
      const bytes = data instanceof Uint8Array ? data : _ENC.encode(data);
      this._store.set(path, bytes);
      let p = path;
      while (p.includes("/")) {
        p = p.substring(0, p.lastIndexOf("/"));
        this._dirs.add(p);
      }
    },
    mkdir(path)  { this._dirs.add(path); },
    del(path)    { this._store.delete(path); },
    list(dirPath) {
      const prefix  = dirPath === "" ? "" : dirPath + "/";
      const entries = [];
      for (const k of this._store.keys()) {
        if (k.startsWith(prefix)) {
          const rest = k.slice(prefix.length);
          if (!rest.includes("/")) entries.push(rest);
        }
      }
      for (const d of this._dirs) {
        if (d !== dirPath && d.startsWith(prefix)) {
          const rest = d.slice(prefix.length);
          if (!rest.includes("/")) entries.push(rest + "/");
        }
      }
      return entries;
    },
  };

  // ── Plugin state store (key-value, persisted in sessionStorage) ─────────── //

  const _STATE_PREFIX = "schemify:state:";
  const _CONFIG_PREFIX = "schemify:config:";

  function _stateGet(key)            { return sessionStorage.getItem(_STATE_PREFIX + key) ?? ""; }
  function _stateSet(key, val)       { sessionStorage.setItem(_STATE_PREFIX + key, val); }
  function _configGet(pid, key)      { return sessionStorage.getItem(_CONFIG_PREFIX + pid + ":" + key) ?? ""; }
  function _configSet(pid, key, val) { sessionStorage.setItem(_CONFIG_PREFIX + pid + ":" + key, val); }

  // ── callProcess ───────────────────────────────────────────────────────── //
  //
  // Calls plugin.inst.exports.schemify_process(inOff, inLen, outOff, outCap)
  // and returns a Uint8Array of the output bytes (copied from WASM memory).
  //
  // Memory layout: the last N pages of WASM linear memory are reserved as a
  // scratch region.  We keep a minimum of 4MB total and use:
  //   [SCRATCH_BASE .. SCRATCH_BASE+IN_CAP)    → input buffer
  //   [SCRATCH_BASE+IN_CAP .. end)             → output buffer
  //
  // SCRATCH_BASE is placed at 2MB so it does not overlap a typical plugin
  // heap, which starts at __heap_base (usually ≤ 64 KB) and grows up.
  // Plugins that use a large heap will have allocated pages below our scratch
  // region; if a plugin's heap ever extends into our scratch area its output
  // would be corrupted — that is acceptable for the WASM host which is a
  // thin preview/demo target, not a production runtime.

  const IN_OFF   = 2 * 1024 * 1024;       // 2 MB
  const IN_CAP   = 256 * 1024;            // 256 KB for input
  const OUT_OFF  = IN_OFF + IN_CAP;        // 2 MB + 256 KB
  const OUT_CAP  = 1024 * 1024;           // 1 MB for output
  const MIN_MEM  = OUT_OFF + OUT_CAP;     // ~3.25 MB minimum

  function _ensureMemory(plugin) {
    const mem = plugin.inst.exports.memory;
    const cur = mem.buffer.byteLength;
    if (cur < MIN_MEM) {
      const delta = Math.ceil((MIN_MEM - cur) / 65536);
      try { mem.grow(delta); } catch (e) {
        console.error("[plugin-host] memory.grow failed for", plugin.url, e);
        return false;
      }
    }
    return true;
  }

  function callProcess(plugin, inBytes) {
    const process = plugin.inst.exports.schemify_process;
    if (typeof process !== "function") {
      console.warn("[plugin-host] no schemify_process export in", plugin.url);
      return null;
    }
    if (!_ensureMemory(plugin)) return null;
    if (inBytes.length > IN_CAP) {
      console.error("[plugin-host] input batch too large for", plugin.url, inBytes.length);
      return null;
    }

    const mem  = plugin.inst.exports.memory;
    const view = new Uint8Array(mem.buffer);
    view.set(inBytes, IN_OFF);

    let outLen = process(IN_OFF, inBytes.length, OUT_OFF, OUT_CAP);

    // Overflow: plugin returned usize_max (or 0xFFFFFFFF from i32).
    if (outLen === 0xFFFFFFFF || outLen >>> 0 === 0xFFFFFFFF) {
      // Per spec: double buffer and retry (we have a fixed layout so just log).
      console.warn("[plugin-host] schemify_process overflow for", plugin.url, "— output too large for 1 MB buffer");
      return null;
    }

    if (outLen > OUT_CAP) {
      console.error("[plugin-host] schemify_process returned invalid length", outLen, "for", plugin.url);
      return null;
    }

    // Copy output bytes out of WASM memory before parsing (memory may move on next call).
    return new Uint8Array(mem.buffer, OUT_OFF, outLen).slice();
  }

  // ── parseOutput ──────────────────────────────────────────────────────── //

  const _LOG_METHODS = ["info", "warn", "error"];

  function parseOutput(plugin, bytes) {
    const reader = new MsgReader(bytes);
    for (const msg of reader.readAll()) {
      switch (msg.tag) {
        case 0x80: { // RegisterPanel
          const panelId = _app.registerPanelFn(msg.id, msg.title, msg.vim_cmd, msg.layout, msg.keybind);
          plugin.panels.set(panelId, { id: msg.id, title: msg.title, vim_cmd: msg.vim_cmd });
          break;
        }
        case 0x81: // SetStatus
          _app.statusFn(msg.msg);
          break;
        case 0x82: { // Log
          const fn = console[_LOG_METHODS[msg.level]] ?? console.log;
          fn.call(console, `[plugin:${plugin.name}][${msg.tag_str}] ${msg.msg}`);
          break;
        }
        case 0x83: // PushCommand
          _app.onPluginCommand?.(msg.tag_str, msg.payload);
          break;
        case 0x84: // SetState
          _stateSet(msg.key, msg.val);
          break;
        case 0x85: // GetState — queue response for next process call
          (plugin.pendingStateResponses ??= []).push({ key: msg.key, val: _stateGet(msg.key) });
          break;
        case 0x86: // SetConfig
          _configSet(msg.plugin_id, msg.key, msg.val);
          break;
        case 0x87: // GetConfig — queue response
          (plugin.pendingConfigResponses ??= []).push({ plugin_id: msg.plugin_id, key: msg.key, val: _configGet(msg.plugin_id, msg.key) });
          break;
        case 0x88: // RequestRefresh
          _app.requestRefreshFn();
          break;
        case 0x89: // RegisterKeybind
          _app.registerKeybindFn?.(msg.key, msg.mods, msg.cmd_tag);
          break;
        case 0x8A: // PlaceDevice
          _app.placeDevice?.(msg.sym, msg.device_name, msg.x, msg.y);
          break;
        case 0x8B: // AddWire
          _app.addWire?.(msg.x0, msg.y0, msg.x1, msg.y1);
          break;
        case 0x8C: // SetInstanceProp
          _app.setInstancePropFn?.(msg.idx, msg.key, msg.val);
          break;
        case 0x8D: // QueryInstances — flag; host will prepend data next tick
          plugin.queryInstancesPending = true;
          break;
        case 0x8E: // QueryNets
          plugin.queryNetsPending = true;
          break;
        default:
          // UI widgets (0xA0–0xAB) — collect for drawPanel return value.
          if (msg.tag >= 0xA0 && msg.tag <= 0xAB) {
            (plugin._currentWidgets ??= []).push(msg);
          }
          break;
      }
    }
  }

  // ── buildInputBatch ───────────────────────────────────────────────────── //
  //
  // Helper shared between tick() and drawPanel().  Writes the standard prefix
  // messages (pending state/config responses, instance/net data if requested)
  // into the supplied MsgWriter.

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

  // ── loadPlugin ────────────────────────────────────────────────────────── //

  async function loadPlugin(url) {
    try {
      // v6 plugins have zero host imports — instantiate with empty imports object.
      const response = await fetch(url, { cache: "no-store" });
      if (!response.ok) throw new Error(`HTTP ${response.status} fetching ${url}`);
      const wasm = await response.arrayBuffer();
      const { instance } = await WebAssembly.instantiate(wasm, {});

      const plugin = {
        inst: instance,
        url,
        name: url.split("/").pop(),
        version: "?",
        panels: new Map(),
        pendingStateResponses:  [],
        pendingConfigResponses: [],
        queryInstancesPending:  false,
        queryNetsPending:       false,
        _currentWidgets:        null,
      };

      if (!_ensureMemory(plugin)) {
        console.warn("[plugin-host] could not ensure memory for", url);
        return;
      }

      _plugins.push(plugin);

      // Send Load message.
      const w = new MsgWriter();
      w.msg(0x01, () => {});
      const out = callProcess(plugin, w.bytes());
      if (out) parseOutput(plugin, out);

      console.info("[plugin-host] loaded", url);
    } catch (e) {
      console.warn("[plugin-host] failed to load", url, e);
    }
  }

  // ── tick ─────────────────────────────────────────────────────────────── //
  //
  // Called every animation frame by the host.  Sends [Tick][SchematicSnapshot]
  // plus any pending responses to each plugin.

  function tick(dt) {
    const snap = _app.getSchematicSnapshot();

    for (const plugin of _plugins) {
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
  //
  // Sends [DrawPanel][interaction events...] to the plugin that owns panelId.
  // Returns the list of UI widget messages emitted by the plugin.
  //
  // interactions: array of objects, each with a .type:
  //   { type: "button",   panel_id, widget_id }
  //   { type: "slider",   panel_id, widget_id, val }
  //   { type: "text",     panel_id, widget_id, text }
  //   { type: "checkbox", panel_id, widget_id, val }

  function drawPanel(panelId, interactions) {
    const plugin = _plugins.find(p => p.panels.has(panelId));
    if (!plugin) return [];

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
      const json = await res.json();
      const entries = Array.isArray(json) ? json : (json.plugins ?? []);
      const urls = entries.map(e => {
        const u = typeof e === "string" ? e : (e.url ?? e);
        return u.startsWith("http") ? u : `plugins/${u}`;
      }).filter(u => u.endsWith(".wasm"));
      for (const url of urls) await loadPlugin(url);
    } catch (e) {
      console.warn("[plugin-host] loadFromJson failed", e);
    }
  }

  // ── Public API ────────────────────────────────────────────────────────── //

  window.schemifyPluginHost = {
    /** Wire up app callbacks from the main WASM glue. */
    setAppState(app) { Object.assign(_app, app); },

    /** Load a single .wasm plugin by URL. */
    loadPlugin,

    /** Load plugins listed in a plugins.json manifest. */
    loadFromJson,

    /**
     * Drive all loaded plugins for one frame.
     * @param {number} dt  Delta time in seconds.
     */
    tick,

    /**
     * Draw a plugin panel, returning the widget list.
     * @param {number}   panelId       Numeric panel ID assigned at RegisterPanel time.
     * @param {Array}    interactions  Interaction events from the previous frame.
     * @returns {Array}  Widget message objects (tag, name, text/val/…, id).
     */
    drawPanel,

    /** Send Unload to all plugins, then clear the list. */
    unloadAll() {
      for (const plugin of _plugins) {
        try {
          const w = new MsgWriter();
          w.msg(0x02, () => {});
          callProcess(plugin, w.bytes());
        } catch (_e) {}
      }
      _plugins.length = 0;
    },

    /**
     * In-memory virtual filesystem — same interface as the v5 host.
     * Seed files before loading plugins so they can read them via Vfs.
     */
    vfs: _vfs,

    /** Read-only view of loaded plugins. */
    get plugins() { return _plugins; },

    // Expose codec classes for use by pyodide_plugin_host.js.
    MsgWriter,
    MsgReader,
  };

  // Auto-boot from the default manifest.
  void loadFromJson();
})();
