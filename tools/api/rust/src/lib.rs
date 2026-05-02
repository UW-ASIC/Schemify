//! Schemify Plugin SDK — Rust (ABI v7)
//!
//! No external crates. Copy this file (or add this crate) to your plugin project.
//!
//! Usage:
//!
//!   use schemify::{Plugin, Writer, Layout};
//!
//!   #[derive(Default)]
//!   struct MyPlugin { /* state */ }
//!
//!   impl Plugin for MyPlugin {
//!       fn on_load(&mut self, w: &mut Writer) {
//!           w.register_panel(b"hello", b"Hello", b"hello", Layout::LeftSidebar, 0);
//!       }
//!       fn on_draw_panel(&mut self, _panel_id: u16, w: &mut Writer) {
//!           w.label(b"Hello from Rust!", 1);
//!       }
//!   }
//!
//!   schemify::export_plugin!("my-plugin", "0.1.0", MyPlugin);

#![no_std]
use core::mem;

pub const ABI_VERSION: u32 = 7;

// ── Layout ────────────────────────────────────────────────────────────────

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Layout {
    Overlay      = 0,
    LeftSidebar  = 1,
    RightSidebar = 2,
    BottomBar    = 3,
}

// ── Message tags (private) ────────────────────────────────────────────────

mod tag {
    pub const LOAD:               u8 = 0x01;
    pub const UNLOAD:             u8 = 0x02;
    pub const TICK:               u8 = 0x03;
    pub const DRAW_PANEL:         u8 = 0x04;
    pub const BUTTON_CLICKED:     u8 = 0x05;
    pub const SLIDER_CHANGED:     u8 = 0x06;
    pub const TEXT_CHANGED:       u8 = 0x07;
    pub const CHECKBOX_CHANGED:   u8 = 0x08;
    pub const COMMAND:            u8 = 0x09;
    pub const STATE_RESPONSE:     u8 = 0x0A;
    pub const CONFIG_RESPONSE:    u8 = 0x0B;
    pub const SCHEMATIC_CHANGED:  u8 = 0x0C;
    pub const SELECTION_CHANGED:  u8 = 0x0D;
    pub const SCHEMATIC_SNAPSHOT: u8 = 0x0E;
    pub const INSTANCE_DATA:      u8 = 0x0F;
    pub const INSTANCE_PROP:      u8 = 0x10;
    pub const NET_DATA:           u8 = 0x11;
    pub const HOVER:              u8 = 0x13;
    pub const KEY_EVENT:          u8 = 0x14;
}

pub const EVENT_HOVER: u8 = 1 << 0;
pub const EVENT_KEYS:  u8 = 1 << 1;

// ── Incoming message variants ─────────────────────────────────────────────

pub enum Msg<'a> {
    Load,
    Unload,
    Tick(f32),
    DrawPanel(u16),
    ButtonClicked    { panel_id: u16, widget_id: u32 },
    SliderChanged    { panel_id: u16, widget_id: u32, val: f32 },
    TextChanged      { panel_id: u16, widget_id: u32, text: &'a [u8] },
    CheckboxChanged  { panel_id: u16, widget_id: u32, val: bool },
    Command          { tag: &'a [u8], payload: &'a [u8] },
    StateResponse    { key: &'a [u8], val: &'a [u8] },
    ConfigResponse   { key: &'a [u8], val: &'a [u8] },
    SchematicChanged,
    SelectionChanged(i32),
    SchematicSnapshot { instance_count: u32, wire_count: u32, net_count: u32 },
    InstanceData     { idx: u32, name: &'a [u8], symbol: &'a [u8] },
    InstanceProp     { idx: u32, key: &'a [u8], val: &'a [u8] },
    NetData          { idx: u32, name: &'a [u8] },
    Hover            { world_x: i32, world_y: i32, element_type: u8, element_idx: i32, element_name: &'a [u8] },
    KeyEvent         { key: u8, mods: u8, action: u8 },
}

// ── Reader ────────────────────────────────────────────────────────────────

pub struct Reader<'a> { buf: &'a [u8], pos: usize }

impl<'a> Reader<'a> {
    pub fn new(buf: &'a [u8]) -> Self { Self { buf, pos: 0 } }

    pub fn next(&mut self) -> Option<Msg<'a>> {
        loop {
            if self.pos + 3 > self.buf.len() { return None; }
            let t    = self.buf[self.pos];
            let psz  = rd_u16(&self.buf[self.pos + 1..]) as usize;
            let hdr  = self.pos + 3;
            let end  = hdr + psz;
            if end > self.buf.len() { return None; }
            let p    = &self.buf[hdr..end];
            self.pos = end;

            match t {
                tag::LOAD  => return Some(Msg::Load),
                tag::UNLOAD => return Some(Msg::Unload),
                tag::SCHEMATIC_CHANGED => return Some(Msg::SchematicChanged),
                tag::TICK  => { if p.len() < 4 { continue; } return Some(Msg::Tick(rd_f32(p))); }
                tag::DRAW_PANEL => { if p.len() < 2 { continue; } return Some(Msg::DrawPanel(rd_u16(p))); }
                tag::BUTTON_CLICKED => {
                    if p.len() < 6 { continue; }
                    return Some(Msg::ButtonClicked { panel_id: rd_u16(p), widget_id: rd_u32(&p[2..]) });
                }
                tag::SLIDER_CHANGED => {
                    if p.len() < 10 { continue; }
                    return Some(Msg::SliderChanged { panel_id: rd_u16(p), widget_id: rd_u32(&p[2..]), val: rd_f32(&p[6..]) });
                }
                tag::TEXT_CHANGED => {
                    if p.len() < 6 { continue; }
                    let mut off = 6;
                    let text = rd_str(p, &mut off)?;
                    return Some(Msg::TextChanged { panel_id: rd_u16(p), widget_id: rd_u32(&p[2..]), text });
                }
                tag::CHECKBOX_CHANGED => {
                    if p.len() < 7 { continue; }
                    return Some(Msg::CheckboxChanged { panel_id: rd_u16(p), widget_id: rd_u32(&p[2..]), val: p[6] != 0 });
                }
                tag::COMMAND => {
                    let mut off = 0;
                    let t2  = rd_str(p, &mut off)?;
                    let pl  = rd_str(p, &mut off)?;
                    return Some(Msg::Command { tag: t2, payload: pl });
                }
                tag::STATE_RESPONSE => {
                    let mut off = 0;
                    let k = rd_str(p, &mut off)?; let v = rd_str(p, &mut off)?;
                    return Some(Msg::StateResponse { key: k, val: v });
                }
                tag::CONFIG_RESPONSE => {
                    let mut off = 0;
                    let k = rd_str(p, &mut off)?; let v = rd_str(p, &mut off)?;
                    return Some(Msg::ConfigResponse { key: k, val: v });
                }
                tag::SELECTION_CHANGED => {
                    if p.len() < 4 { continue; }
                    return Some(Msg::SelectionChanged(rd_i32(p)));
                }
                tag::SCHEMATIC_SNAPSHOT => {
                    if p.len() < 12 { continue; }
                    return Some(Msg::SchematicSnapshot {
                        instance_count: rd_u32(p),
                        wire_count:     rd_u32(&p[4..]),
                        net_count:      rd_u32(&p[8..]),
                    });
                }
                tag::INSTANCE_DATA => {
                    if p.len() < 4 { continue; }
                    let mut off = 4;
                    let name   = rd_str(p, &mut off)?;
                    let symbol = rd_str(p, &mut off)?;
                    return Some(Msg::InstanceData { idx: rd_u32(p), name, symbol });
                }
                tag::INSTANCE_PROP => {
                    if p.len() < 4 { continue; }
                    let mut off = 4;
                    let k = rd_str(p, &mut off)?; let v = rd_str(p, &mut off)?;
                    return Some(Msg::InstanceProp { idx: rd_u32(p), key: k, val: v });
                }
                tag::NET_DATA => {
                    if p.len() < 4 { continue; }
                    let mut off = 4;
                    let name = rd_str(p, &mut off)?;
                    return Some(Msg::NetData { idx: rd_u32(p), name });
                }
                tag::HOVER => {
                    if p.len() < 13 { continue; }
                    let mut off = 13;
                    let ename = rd_str(p, &mut off).unwrap_or(b"");
                    return Some(Msg::Hover {
                        world_x: rd_i32(p), world_y: rd_i32(&p[4..]),
                        element_type: p[8], element_idx: rd_i32(&p[9..]),
                        element_name: ename,
                    });
                }
                tag::KEY_EVENT => {
                    if p.len() < 3 { continue; }
                    return Some(Msg::KeyEvent { key: p[0], mods: p[1], action: p[2] });
                }
                _ => continue,
            }
        }
    }
}

// ── Writer ────────────────────────────────────────────────────────────────

pub struct Writer<'a> { buf: &'a mut [u8], pub pos: usize, overflow: bool }

impl<'a> Writer<'a> {
    pub fn new(buf: &'a mut [u8]) -> Self { Self { buf, pos: 0, overflow: false } }
    pub fn finish(self) -> Result<usize, ()> { if self.overflow { Err(()) } else { Ok(self.pos) } }

    pub fn set_status(&mut self, msg: &[u8]) {
        let p = 2 + msg.len(); if !self.room(3+p) { return; }
        self.hdr(0x81, p as u16); self.s(msg);
    }
    pub fn register_panel(&mut self, id: &[u8], title: &[u8], vim: &[u8], layout: Layout, keybind: u8) {
        let p = 2+id.len() + 2+title.len() + 2+vim.len() + 1 + 1;
        if !self.room(3+p) { return; }
        self.hdr(0x80, p as u16); self.s(id); self.s(title); self.s(vim);
        self.b(layout as u8); self.b(keybind);
    }
    pub fn request_refresh(&mut self)  { if self.room(3) { self.hdr(0x88, 0); } }
    pub fn get_state(&mut self, k: &[u8]) {
        let p = 2+k.len(); if !self.room(3+p) { return; }
        self.hdr(0x85, p as u16); self.s(k);
    }
    pub fn set_state(&mut self, k: &[u8], v: &[u8]) {
        let p = 2+k.len()+2+v.len(); if !self.room(3+p) { return; }
        self.hdr(0x84, p as u16); self.s(k); self.s(v);
    }
    pub fn get_config(&mut self, id: &[u8], k: &[u8]) {
        let p = 2+id.len()+2+k.len(); if !self.room(3+p) { return; }
        self.hdr(0x87, p as u16); self.s(id); self.s(k);
    }
    pub fn set_config(&mut self, id: &[u8], k: &[u8], v: &[u8]) {
        let p = 2+id.len()+2+k.len()+2+v.len(); if !self.room(3+p) { return; }
        self.hdr(0x86, p as u16); self.s(id); self.s(k); self.s(v);
    }
    pub fn query_instances(&mut self) { if self.room(3) { self.hdr(0x8D, 0); } }
    pub fn query_nets(&mut self)      { if self.room(3) { self.hdr(0x8E, 0); } }
    pub fn place_device(&mut self, sym: &[u8], name: &[u8], x: i32, y: i32) {
        let p = 2+sym.len()+2+name.len()+8; if !self.room(3+p) { return; }
        self.hdr(0x8A, p as u16); self.s(sym); self.s(name); self.i32v(x); self.i32v(y);
    }
    pub fn add_wire(&mut self, x0: i32, y0: i32, x1: i32, y1: i32) {
        if !self.room(3+16) { return; } self.hdr(0x8B, 16);
        self.i32v(x0); self.i32v(y0); self.i32v(x1); self.i32v(y1);
    }
    pub fn set_instance_prop(&mut self, idx: u32, k: &[u8], v: &[u8]) {
        let p = 4+2+k.len()+2+v.len(); if !self.room(3+p) { return; }
        self.hdr(0x8C, p as u16); self.u32v(idx); self.s(k); self.s(v);
    }
    // UI widgets
    pub fn label(&mut self, t: &[u8], id: u32) {
        let p = 2+t.len()+4; if !self.room(3+p) { return; }
        self.hdr(0xA0, p as u16); self.s(t); self.u32v(id);
    }
    pub fn button(&mut self, t: &[u8], id: u32) {
        let p = 2+t.len()+4; if !self.room(3+p) { return; }
        self.hdr(0xA1, p as u16); self.s(t); self.u32v(id);
    }
    pub fn separator(&mut self, id: u32) { if self.room(7) { self.hdr(0xA2,4); self.u32v(id); } }
    pub fn begin_row(&mut self, id: u32) { if self.room(7) { self.hdr(0xA3,4); self.u32v(id); } }
    pub fn end_row(&mut self, id: u32)   { if self.room(7) { self.hdr(0xA4,4); self.u32v(id); } }
    pub fn slider(&mut self, val: f32, min: f32, max: f32, id: u32) {
        if !self.room(3+16) { return; } self.hdr(0xA5,16);
        self.f32v(val); self.f32v(min); self.f32v(max); self.u32v(id);
    }
    pub fn checkbox(&mut self, val: bool, t: &[u8], id: u32) {
        let p = 1+2+t.len()+4; if !self.room(3+p) { return; }
        self.hdr(0xA6,p as u16); self.b(val as u8); self.s(t); self.u32v(id);
    }
    pub fn progress(&mut self, f: f32, id: u32) {
        if !self.room(3+8) { return; } self.hdr(0xA7,8); self.f32v(f); self.u32v(id);
    }
    pub fn collapsible_start(&mut self, lbl: &[u8], open: bool, id: u32) {
        let p = 2+lbl.len()+1+4; if !self.room(3+p) { return; }
        self.hdr(0xAA,p as u16); self.s(lbl); self.b(open as u8); self.u32v(id);
    }
    pub fn collapsible_end(&mut self, id: u32) { if self.room(7) { self.hdr(0xAB,4); self.u32v(id); } }
    pub fn tooltip(&mut self, t: &[u8], id: u32) {
        let p = 2+t.len()+4; if !self.room(3+p) { return; }
        self.hdr(0xAC, p as u16); self.s(t); self.u32v(id);
    }
    pub fn subscribe_events(&mut self, mask: u8) {
        if !self.room(4) { return; } self.hdr(0x92, 1); self.b(mask);
    }
    pub fn consume_event(&mut self) { if self.room(3) { self.hdr(0x93, 0); } }
    pub fn override_keybind(&mut self, key: u8, mods: u8, cmd: &[u8]) {
        let p = 1+1+2+cmd.len(); if !self.room(3+p) { return; }
        self.hdr(0x94, p as u16); self.b(key); self.b(mods); self.s(cmd);
    }

    // Internal
    fn room(&mut self, n: usize) -> bool {
        if self.overflow || self.pos + n > self.buf.len() { self.overflow = true; return false; }
        true
    }
    fn hdr(&mut self, tag: u8, p: u16) {
        self.buf[self.pos]=tag; self.buf[self.pos+1]=(p&0xFF) as u8; self.buf[self.pos+2]=(p>>8) as u8;
        self.pos+=3;
    }
    fn b(&mut self, v: u8)   { self.buf[self.pos]=v; self.pos+=1; }
    fn u32v(&mut self, v: u32) {
        self.buf[self.pos..self.pos+4].copy_from_slice(&v.to_le_bytes()); self.pos+=4;
    }
    fn i32v(&mut self, v: i32) { self.u32v(v as u32); }
    fn f32v(&mut self, v: f32) { self.u32v(v.to_bits()); }
    fn s(&mut self, d: &[u8]) {
        let l = d.len() as u16;
        self.buf[self.pos..self.pos+2].copy_from_slice(&l.to_le_bytes()); self.pos+=2;
        self.buf[self.pos..self.pos+d.len()].copy_from_slice(d); self.pos+=d.len();
    }
}

// ── Plugin trait ──────────────────────────────────────────────────────────

pub trait Plugin {
    fn on_load(&mut self, _w: &mut Writer) {}
    fn on_unload(&mut self, _w: &mut Writer) {}
    fn on_tick(&mut self, _dt: f32, _w: &mut Writer) {}
    fn on_draw_panel(&mut self, _panel_id: u16, _w: &mut Writer) {}
    fn on_button_clicked(&mut self, _panel_id: u16, _widget_id: u32, _w: &mut Writer) {}
    fn on_slider_changed(&mut self, _panel_id: u16, _widget_id: u32, _val: f32, _w: &mut Writer) {}
    fn on_checkbox_changed(&mut self, _panel_id: u16, _widget_id: u32, _val: bool, _w: &mut Writer) {}
    fn on_command(&mut self, _tag: &[u8], _payload: &[u8], _w: &mut Writer) {}
    fn on_state_response(&mut self, _key: &[u8], _val: &[u8], _w: &mut Writer) {}
    fn on_selection_changed(&mut self, _idx: i32, _w: &mut Writer) {}
    fn on_schematic_changed(&mut self, _w: &mut Writer) {}
    fn on_instance_data(&mut self, _idx: u32, _name: &[u8], _symbol: &[u8], _w: &mut Writer) {}
    fn on_hover(&mut self, _wx: i32, _wy: i32, _etype: u8, _eidx: i32, _ename: &[u8], _w: &mut Writer) {}
    fn on_key_event(&mut self, _key: u8, _mods: u8, _action: u8, _w: &mut Writer) {}

    fn process(&mut self, in_buf: &[u8], out_buf: &mut [u8]) -> usize {
        let mut r = Reader::new(in_buf);
        let mut w = Writer::new(out_buf);
        while let Some(msg) = r.next() {
            match msg {
                Msg::Load                          => self.on_load(&mut w),
                Msg::Unload                        => self.on_unload(&mut w),
                Msg::Tick(dt)                      => self.on_tick(dt, &mut w),
                Msg::DrawPanel(pid)                => self.on_draw_panel(pid, &mut w),
                Msg::ButtonClicked{panel_id,widget_id} => self.on_button_clicked(panel_id, widget_id, &mut w),
                Msg::SliderChanged{panel_id,widget_id,val} => self.on_slider_changed(panel_id, widget_id, val, &mut w),
                Msg::CheckboxChanged{panel_id,widget_id,val} => self.on_checkbox_changed(panel_id, widget_id, val, &mut w),
                Msg::Command{tag,payload}          => self.on_command(tag, payload, &mut w),
                Msg::StateResponse{key,val}        => self.on_state_response(key, val, &mut w),
                Msg::SelectionChanged(idx)         => self.on_selection_changed(idx, &mut w),
                Msg::SchematicChanged              => self.on_schematic_changed(&mut w),
                Msg::InstanceData{idx,name,symbol} => self.on_instance_data(idx, name, symbol, &mut w),
                Msg::Hover{world_x,world_y,element_type,element_idx,element_name} =>
                    self.on_hover(world_x, world_y, element_type, element_idx, element_name, &mut w),
                Msg::KeyEvent{key,mods,action} => self.on_key_event(key, mods, action, &mut w),
                _                                  => {}
            }
        }
        w.finish().unwrap_or(usize::MAX)
    }
}

// ── ABI descriptor ────────────────────────────────────────────────────────

#[repr(C)]
pub struct Descriptor {
    pub abi_version: u32,
    pub name:        *const u8,
    pub version_str: *const u8,
    pub process:     unsafe extern "C" fn(*const u8, usize, *mut u8, usize) -> usize,
}
unsafe impl Sync for Descriptor {}
unsafe impl Send for Descriptor {}

// ── Internal read helpers ─────────────────────────────────────────────────

fn rd_u16(b: &[u8]) -> u16 { b[0] as u16 | ((b[1] as u16) << 8) }
fn rd_u32(b: &[u8]) -> u32 { b[0] as u32 | ((b[1] as u32)<<8) | ((b[2] as u32)<<16) | ((b[3] as u32)<<24) }
fn rd_i32(b: &[u8]) -> i32 { rd_u32(b) as i32 }
fn rd_f32(b: &[u8]) -> f32 { f32::from_bits(rd_u32(b)) }
fn rd_str<'a>(b: &'a [u8], off: &mut usize) -> Option<&'a [u8]> {
    if *off + 2 > b.len() { return None; }
    let len = rd_u16(&b[*off..]) as usize; *off += 2;
    if *off + len > b.len() { return None; }
    let s = &b[*off..*off+len]; *off += len; Some(s)
}

// ── Export macro ──────────────────────────────────────────────────────────

/// Register a `Plugin` impl as the shared library entry point.
///
///   #[derive(Default)]
///   struct MyPlugin;
///   impl Plugin for MyPlugin { ... }
///   schemify::export_plugin!("my-plugin", "0.1.0", MyPlugin);
#[macro_export]
macro_rules! export_plugin {
    ($name:literal, $version:literal, $T:ty) => {
        mod _schemify_export {
            use super::*;
            use core::sync::atomic::{AtomicBool, Ordering};
            static INIT: AtomicBool = AtomicBool::new(false);
            static mut PLUGIN: core::mem::MaybeUninit<$T> = core::mem::MaybeUninit::uninit();

            #[no_mangle]
            pub unsafe extern "C" fn _sp_process(
                in_ptr:  *const u8, in_len:  usize,
                out_ptr: *mut   u8, out_cap: usize,
            ) -> usize {
                if !INIT.load(Ordering::Relaxed) {
                    PLUGIN.write(<$T as Default>::default());
                    INIT.store(true, Ordering::Relaxed);
                }
                let plugin  = unsafe { PLUGIN.assume_init_mut() };
                let in_buf  = unsafe { core::slice::from_raw_parts(in_ptr, in_len) };
                let out_buf = unsafe { core::slice::from_raw_parts_mut(out_ptr, out_cap) };
                schemify::Plugin::process(plugin, in_buf, out_buf)
            }

            #[no_mangle]
            #[used]
            pub static schemify_plugin: schemify::Descriptor = schemify::Descriptor {
                abi_version: schemify::ABI_VERSION,
                name:        concat!($name, "\0").as_ptr(),
                version_str: concat!($version, "\0").as_ptr(),
                process:     _sp_process,
            };
        }
    };
}
