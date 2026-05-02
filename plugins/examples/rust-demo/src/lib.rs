//! Schemify Plugin SDK — Rust demo
//!
//! Registers four panels and draws a widget gallery on every draw_panel call.
//!
//! Build:  cargo build --release
//! WASM:   cargo build --release --target wasm32-unknown-unknown

use schemify::{Plugin, Writer, Layout};

struct RustDemo {
    slider_val:   f32,
    checkbox_val: bool,
    tick_count:   u32,
}

impl Default for RustDemo {
    fn default() -> Self {
        RustDemo {
            slider_val:   0.5,
            checkbox_val: true,
            tick_count:   0,
        }
    }
}

impl Plugin for RustDemo {
    fn on_load(&mut self, w: &mut Writer) {
        w.register_panel(b"rust-demo-overlay", b"Properties",   b"rdprop",   Layout::Overlay,      0);
        w.register_panel(b"rust-demo-left",    b"Components",   b"rdcomp",   Layout::LeftSidebar,  0);
        w.register_panel(b"rust-demo-right",   b"Design Stats", b"rdstats",  Layout::RightSidebar, 0);
        w.register_panel(b"rust-demo-bottom",  b"Status",       b"rdstatus", Layout::BottomBar,    0);
        w.set_status(b"Rust Demo loaded");
    }

    fn on_tick(&mut self, _dt: f32, _w: &mut Writer) {
        self.tick_count = self.tick_count.wrapping_add(1);
    }

    fn on_draw_panel(&mut self, _panel_id: u16, w: &mut Writer) {
        w.label(b"Selected: R1", 0);
        w.separator(1);
        w.label(b"Value (kOhm)", 2);
        w.slider(self.slider_val, 0.0, 100.0, 3);
        w.checkbox(self.checkbox_val, b"Show in netlist", 4);
        w.button(b"Apply", 5);
        w.separator(6);
        w.collapsible_start(b"Component Browser", true, 7);
        w.label(b"  Resistors: R1, R2, R3", 8);
        w.label(b"  Capacitors: C1", 9);
        w.label(b"  Transistors: M1, M2", 10);
        w.collapsible_end(7);
        w.separator(11);
        w.label(b"Design Stats", 12);
        w.progress(0.75, 13);
        w.begin_row(14);
        w.label(b"Nets: 12", 15);
        w.label(b"Comps: 8", 16);
        w.button(b"Simulate", 17);
        w.end_row(14);
    }

    fn on_slider_changed(&mut self, _panel_id: u16, widget_id: u32, val: f32, _w: &mut Writer) {
        if widget_id == 3 { self.slider_val = val; }
    }

    fn on_checkbox_changed(&mut self, _panel_id: u16, widget_id: u32, val: bool, _w: &mut Writer) {
        if widget_id == 4 { self.checkbox_val = val; }
    }
}

schemify::export_plugin!("rust-demo", "0.1.0", RustDemo);
