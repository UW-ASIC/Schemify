/**
 * schemify-plugin — Bun/TypeScript SDK (ABI v7)
 *
 * Copy this file into your plugin project (no npm install needed).
 * Requires Bun runtime (https://bun.sh) for the subprocess runner.
 *
 * Usage:
 *
 *   import { Plugin, Writer, Layout, run } from "./lib";
 *
 *   class MyPlugin extends Plugin {
 *     onLoad(w: Writer) {
 *       w.registerPanel("hello", "Hello", "hello", Layout.LeftSidebar);
 *     }
 *     onDrawPanel(_panelId: number, w: Writer) {
 *       w.label("Hello from TypeScript!", 1);
 *     }
 *   }
 *
 *   run(new MyPlugin());
 */

export const ABI_VERSION = 7;

export const EVENT_HOVER = 0x01;
export const EVENT_KEYS  = 0x02;

// ── Layout ────────────────────────────────────────────────────────────────

export const enum Layout {
  Overlay      = 0,
  LeftSidebar  = 1,
  RightSidebar = 2,
  BottomBar    = 3,
}

// ── Message tags ──────────────────────────────────────────────────────────

const enum Tag {
  Load              = 0x01,
  Unload            = 0x02,
  Tick              = 0x03,
  DrawPanel         = 0x04,
  ButtonClicked     = 0x05,
  SliderChanged     = 0x06,
  TextChanged       = 0x07,
  CheckboxChanged   = 0x08,
  Command           = 0x09,
  StateResponse     = 0x0A,
  ConfigResponse    = 0x0B,
  SchematicChanged  = 0x0C,
  SelectionChanged  = 0x0D,
  SchematicSnapshot = 0x0E,
  InstanceData      = 0x0F,
  InstanceProp      = 0x10,
  NetData           = 0x11,
  Hover             = 0x13,
  KeyEvent          = 0x14,
}

// ── Incoming message types ────────────────────────────────────────────────

export type Msg =
  | { tag: "load" }
  | { tag: "unload" }
  | { tag: "tick"; dt: number }
  | { tag: "draw_panel"; panelId: number }
  | { tag: "button_clicked"; panelId: number; widgetId: number }
  | { tag: "slider_changed"; panelId: number; widgetId: number; val: number }
  | { tag: "text_changed"; panelId: number; widgetId: number; text: string }
  | { tag: "checkbox_changed"; panelId: number; widgetId: number; val: boolean }
  | { tag: "command"; cmdTag: string; payload: string }
  | { tag: "state_response"; key: string; val: string }
  | { tag: "config_response"; key: string; val: string }
  | { tag: "schematic_changed" }
  | { tag: "selection_changed"; instanceIdx: number }
  | { tag: "schematic_snapshot"; instanceCount: number; wireCount: number; netCount: number }
  | { tag: "instance_data"; idx: number; name: string; symbol: string }
  | { tag: "instance_prop"; idx: number; key: string; val: string }
  | { tag: "net_data"; idx: number; name: string }
  | { tag: "hover"; worldX: number; worldY: number; elementType: number; elementIdx: number; elementName: string }
  | { tag: "key_event"; key: number; mods: number; action: number };

// ── Reader ────────────────────────────────────────────────────────────────

export class Reader {
  private buf: DataView;
  private pos = 0;

  constructor(data: Uint8Array) {
    this.buf = new DataView(data.buffer, data.byteOffset, data.byteLength);
  }

  next(): Msg | null {
    const dv = this.buf;
    while (true) {
      if (this.pos + 3 > dv.byteLength) return null;
      const tag = dv.getUint8(this.pos);
      const psz = dv.getUint16(this.pos + 1, true);
      const hdr = this.pos + 3;
      const end = hdr + psz;
      if (end > dv.byteLength) return null;
      this.pos = end;
      const p = new DataView(dv.buffer, dv.byteOffset + hdr, psz);

      try {
        switch (tag) {
          case Tag.Load:             return { tag: "load" };
          case Tag.Unload:           return { tag: "unload" };
          case Tag.SchematicChanged: return { tag: "schematic_changed" };
          case Tag.Tick:             return { tag: "tick", dt: p.getFloat32(0, true) };
          case Tag.DrawPanel:        return { tag: "draw_panel", panelId: p.getUint16(0, true) };
          case Tag.ButtonClicked:    return { tag: "button_clicked", panelId: p.getUint16(0,true), widgetId: p.getUint32(2,true) };
          case Tag.SliderChanged:    return { tag: "slider_changed", panelId: p.getUint16(0,true), widgetId: p.getUint32(2,true), val: p.getFloat32(6,true) };
          case Tag.TextChanged: {
            let off = 6;
            const [text, off2] = rdStr(p, off);
            return { tag: "text_changed", panelId: p.getUint16(0,true), widgetId: p.getUint32(2,true), text };
          }
          case Tag.CheckboxChanged:  return { tag: "checkbox_changed", panelId: p.getUint16(0,true), widgetId: p.getUint32(2,true), val: p.getUint8(6) !== 0 };
          case Tag.Command: {
            let off = 0;
            const [cmdTag, o1] = rdStr(p, off);
            const [payload]    = rdStr(p, o1);
            return { tag: "command", cmdTag, payload };
          }
          case Tag.StateResponse: {
            let off = 0;
            const [key, o1] = rdStr(p, off); const [val] = rdStr(p, o1);
            return { tag: "state_response", key, val };
          }
          case Tag.ConfigResponse: {
            let off = 0;
            const [key, o1] = rdStr(p, off); const [val] = rdStr(p, o1);
            return { tag: "config_response", key, val };
          }
          case Tag.SelectionChanged: return { tag: "selection_changed", instanceIdx: p.getInt32(0, true) };
          case Tag.SchematicSnapshot: return { tag: "schematic_snapshot", instanceCount: p.getUint32(0,true), wireCount: p.getUint32(4,true), netCount: p.getUint32(8,true) };
          case Tag.InstanceData: {
            const idx = p.getUint32(0, true);
            const [name, o1] = rdStr(p, 4); const [symbol] = rdStr(p, o1);
            return { tag: "instance_data", idx, name, symbol };
          }
          case Tag.InstanceProp: {
            const idx = p.getUint32(0, true);
            const [key, o1] = rdStr(p, 4); const [val] = rdStr(p, o1);
            return { tag: "instance_prop", idx, key, val };
          }
          case Tag.NetData: {
            const idx = p.getUint32(0, true);
            const [name] = rdStr(p, 4);
            return { tag: "net_data", idx, name };
          }
          case Tag.Hover: {
            const worldX = p.getInt32(0, true);
            const worldY = p.getInt32(4, true);
            const elementType = p.getUint8(8);
            const elementIdx = p.getInt32(9, true);
            const [elementName] = rdStr(p, 13);
            return { tag: "hover", worldX, worldY, elementType, elementIdx, elementName };
          }
          case Tag.KeyEvent:
            return { tag: "key_event", key: p.getUint8(0), mods: p.getUint8(1), action: p.getUint8(2) };
          default: continue;
        }
      } catch { continue; }
    }
  }

  [Symbol.iterator]() {
    return { next: () => { const v = this.next(); return v ? { value: v, done: false } : { value: null as unknown as Msg, done: true }; } };
  }
}

// ── Writer ────────────────────────────────────────────────────────────────

export class Writer {
  private chunks: Uint8Array[] = [];

  getBytes(): Uint8Array {
    const total = this.chunks.reduce((n, c) => n + c.byteLength, 0);
    const out = new Uint8Array(total);
    let off = 0;
    for (const c of this.chunks) { out.set(c, off); off += c.byteLength; }
    return out;
  }

  private hdr(tag: number, payload: Uint8Array) {
    const h = new Uint8Array(3);
    h[0] = tag; h[1] = payload.byteLength & 0xFF; h[2] = (payload.byteLength >> 8) & 0xFF;
    this.chunks.push(h, payload);
  }

  private sp(s: string): Uint8Array {
    const enc = new TextEncoder().encode(s);
    const out = new Uint8Array(2 + enc.byteLength);
    new DataView(out.buffer).setUint16(0, enc.byteLength, true);
    out.set(enc, 2);
    return out;
  }
  private u32(v: number): Uint8Array {
    const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, v, true); return b;
  }

  setStatus(msg: string) { this.hdr(0x81, this.sp(msg)); }
  registerPanel(id: string, title: string, vim: string, layout: Layout, keybind = 0) {
    const p = concat(this.sp(id), this.sp(title), this.sp(vim), new Uint8Array([layout, keybind]));
    this.hdr(0x80, p);
  }
  requestRefresh()                          { this.hdr(0x88, new Uint8Array(0)); }
  getState(key: string)                     { this.hdr(0x85, this.sp(key)); }
  setState(key: string, val: string)        { this.hdr(0x84, concat(this.sp(key), this.sp(val))); }
  getConfig(id: string, key: string)        { this.hdr(0x87, concat(this.sp(id), this.sp(key))); }
  setConfig(id: string, k: string, v: string) { this.hdr(0x86, concat(this.sp(id), this.sp(k), this.sp(v))); }
  queryInstances()                          { this.hdr(0x8D, new Uint8Array(0)); }
  queryNets()                               { this.hdr(0x8E, new Uint8Array(0)); }
  placeDevice(sym: string, name: string, x: number, y: number) {
    const xy = new Uint8Array(8);
    const dv = new DataView(xy.buffer); dv.setInt32(0, x, true); dv.setInt32(4, y, true);
    this.hdr(0x8A, concat(this.sp(sym), this.sp(name), xy));
  }
  setInstanceProp(idx: number, k: string, v: string) {
    this.hdr(0x8C, concat(this.u32(idx), this.sp(k), this.sp(v)));
  }
  // UI
  label(text: string, id = 0)                { this.hdr(0xA0, concat(this.sp(text), this.u32(id))); }
  button(text: string, id: number)           { this.hdr(0xA1, concat(this.sp(text), this.u32(id))); }
  separator(id = 0)                          { this.hdr(0xA2, this.u32(id)); }
  beginRow(id = 0)                           { this.hdr(0xA3, this.u32(id)); }
  endRow(id = 0)                             { this.hdr(0xA4, this.u32(id)); }
  slider(val: number, min: number, max: number, id: number) {
    const b = new Uint8Array(16); const dv = new DataView(b.buffer);
    dv.setFloat32(0,val,true); dv.setFloat32(4,min,true); dv.setFloat32(8,max,true); dv.setUint32(12,id,true);
    this.hdr(0xA5, b);
  }
  checkbox(val: boolean, text: string, id: number) {
    this.hdr(0xA6, concat(new Uint8Array([val ? 1 : 0]), this.sp(text), this.u32(id)));
  }
  progress(f: number, id = 0) {
    const b = new Uint8Array(8); const dv = new DataView(b.buffer);
    dv.setFloat32(0,f,true); dv.setUint32(4,id,true); this.hdr(0xA7, b);
  }
  collapsibleStart(lbl: string, open: boolean, id: number) {
    this.hdr(0xAA, concat(this.sp(lbl), new Uint8Array([open ? 1 : 0]), this.u32(id)));
  }
  collapsibleEnd(id: number) { this.hdr(0xAB, this.u32(id)); }
  tooltip(text: string, id = 0)              { this.hdr(0xAC, concat(this.sp(text), this.u32(id))); }
  subscribeEvents(mask: number)              { this.hdr(0x92, new Uint8Array([mask])); }
  consumeEvent()                             { this.hdr(0x93, new Uint8Array(0)); }
  overrideKeybind(key: number, mods: number, cmdTag: string) {
    this.hdr(0x94, concat(new Uint8Array([key, mods]), this.sp(cmdTag)));
  }
}

// ── Plugin base class ─────────────────────────────────────────────────────

export abstract class Plugin {
  onLoad(_w: Writer): void {}
  onUnload(_w: Writer): void {}
  onTick(_dt: number, _w: Writer): void {}
  onDrawPanel(_panelId: number, _w: Writer): void {}
  onButtonClicked(_panelId: number, _widgetId: number, _w: Writer): void {}
  onSliderChanged(_panelId: number, _widgetId: number, _val: number, _w: Writer): void {}
  onCheckboxChanged(_panelId: number, _widgetId: number, _val: boolean, _w: Writer): void {}
  onCommand(_tag: string, _payload: string, _w: Writer): void {}
  onStateResponse(_key: string, _val: string, _w: Writer): void {}
  onSelectionChanged(_idx: number, _w: Writer): void {}
  onSchematicChanged(_w: Writer): void {}
  onInstanceData(_idx: number, _name: string, _symbol: string, _w: Writer): void {}
  onHover(_worldX: number, _worldY: number, _elementType: number, _elementIdx: number, _elementName: string, _w: Writer): void {}
  onKeyEvent(_key: number, _mods: number, _action: number, _w: Writer): void {}

  process(data: Uint8Array): Uint8Array {
    const r = new Reader(data);
    const w = new Writer();
    for (const msg of r) {
      switch (msg.tag) {
        case "load":               this.onLoad(w); break;
        case "unload":             this.onUnload(w); break;
        case "tick":               this.onTick(msg.dt, w); break;
        case "draw_panel":         this.onDrawPanel(msg.panelId, w); break;
        case "button_clicked":     this.onButtonClicked(msg.panelId, msg.widgetId, w); break;
        case "slider_changed":     this.onSliderChanged(msg.panelId, msg.widgetId, msg.val, w); break;
        case "checkbox_changed":   this.onCheckboxChanged(msg.panelId, msg.widgetId, msg.val, w); break;
        case "command":            this.onCommand(msg.cmdTag, msg.payload, w); break;
        case "state_response":     this.onStateResponse(msg.key, msg.val, w); break;
        case "selection_changed":  this.onSelectionChanged(msg.instanceIdx, w); break;
        case "schematic_changed":  this.onSchematicChanged(w); break;
        case "instance_data":      this.onInstanceData(msg.idx, msg.name, msg.symbol, w); break;
        case "hover":              this.onHover(msg.worldX, msg.worldY, msg.elementType, msg.elementIdx, msg.elementName, w); break;
        case "key_event":          this.onKeyEvent(msg.key, msg.mods, msg.action, w); break;
      }
    }
    return w.getBytes();
  }
}

// ── Subprocess runner ─────────────────────────────────────────────────────

/** Run as a Schemify subprocess plugin (stdin/stdout framing). */
export async function run(plugin: Plugin): Promise<void> {
  const stdin = Bun.stdin.stream();
  const stdout = Bun.stdout;
  const reader = stdin.getReader();

  async function readBytes(n: number): Promise<Uint8Array | null> {
    const buf = new Uint8Array(n); let off = 0;
    while (off < n) {
      const { value, done } = await reader.read();
      if (done || !value) return null;
      const take = Math.min(value.byteLength, n - off);
      buf.set(value.subarray(0, take), off); off += take;
    }
    return buf;
  }

  while (true) {
    const lenBuf = await readBytes(4); if (!lenBuf) break;
    const inLen  = new DataView(lenBuf.buffer).getUint32(0, true);
    const inData = await readBytes(inLen); if (!inData) break;
    const outData = plugin.process(inData);
    const outLen  = new Uint8Array(4);
    new DataView(outLen.buffer).setUint32(0, outData.byteLength, true);
    await stdout.write(outLen);
    await stdout.write(outData);
  }
}

// ── Internal helpers ──────────────────────────────────────────────────────

function rdStr(dv: DataView, off: number): [string, number] {
  const len = dv.getUint16(off, true); off += 2;
  const bytes = new Uint8Array(dv.buffer, dv.byteOffset + off, len);
  return [new TextDecoder().decode(bytes), off + len];
}

function concat(...arrays: Uint8Array[]): Uint8Array {
  const total = arrays.reduce((n, a) => n + a.byteLength, 0);
  const out = new Uint8Array(total); let off = 0;
  for (const a of arrays) { out.set(a, off); off += a.byteLength; }
  return out;
}
