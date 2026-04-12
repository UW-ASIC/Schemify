//! Schemify Plugin SDK — Rust demo
//!
//! Registers four panels and draws a widget gallery on every on_draw call.
//!
//! Build:  zig build        (invokes cargo build --release internally)
//! Run:    zig build run

use schemify_plugin::{InMsg, PanelDef, PanelLayout, Plugin, Writer};

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
        w.register_panel(&PanelDef { id: "rust-demo-overlay", title: "Properties",   vim_cmd: "rdprop",   layout: PanelLayout::Overlay,      keybind: 0 });
        w.register_panel(&PanelDef { id: "rust-demo-left",    title: "Components",   vim_cmd: "rdcomp",   layout: PanelLayout::LeftSidebar,  keybind: 0 });
        w.register_panel(&PanelDef { id: "rust-demo-right",   title: "Design Stats", vim_cmd: "rdstats",  layout: PanelLayout::RightSidebar, keybind: 0 });
        w.register_panel(&PanelDef { id: "rust-demo-bottom",  title: "Status",       vim_cmd: "rdstatus", layout: PanelLayout::BottomBar,    keybind: 0 });
        w.set_status("Rust Demo loaded!");
    }

    fn on_tick(&mut self, _dt: f32, _w: &mut Writer) {
        self.tick_count = self.tick_count.wrapping_add(1);
    }

    fn on_draw(&mut self, _panel_id: u16, w: &mut Writer) {
        // panel_id identifies which panel to draw; switch on it when the
        // host assigns distinct IDs per registration. Currently always 0.
        w.label("Selected: R1", 0);
        w.separator(1);
        w.label("Value (kOhm)", 2);
        w.slider(self.slider_val, 0.0, 100.0, 3);
        w.checkbox(self.checkbox_val, "Show in netlist", 4);
        w.button("Apply", 5);
        w.separator(6);
        w.collapsible_start("Component Browser", true, 7);
        w.label("  Resistors: R1, R2, R3", 8);
        w.label("  Capacitors: C1", 9);
        w.label("  Transistors: M1, M2", 10);
        w.collapsible_end(7);
        w.separator(11);
        w.label("Design Stats", 12);
        w.progress(0.75, 13);
        w.begin_row(14);
        w.label("Nets: 12", 15);
        w.label("Comps: 8", 16);
        w.button("Simulate", 17);
        w.end_row(14);
    }

    fn on_event(&mut self, ev: InMsg, _w: &mut Writer) {
        match ev {
            InMsg::SliderChanged   { widget_id: 3, val, .. } => self.slider_val   = val,
            InMsg::CheckboxChanged { widget_id: 4, val, .. } => self.checkbox_val = val,
            _ => {}
        }
    }
}

schemify_plugin::export_plugin!(RustDemo, "rust-demo", "0.1.0");
