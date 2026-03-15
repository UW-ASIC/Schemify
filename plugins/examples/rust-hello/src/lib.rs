//! rust-hello — minimal Rust plugin example for Schemify ABI v6.
//!
//! Demonstrates the Rust SDK: Plugin trait, PanelDef, PanelLayout, Writer
//! methods, and the export_plugin! macro.

use schemify_plugin::{export_plugin, InMsg, PanelDef, PanelLayout, Plugin, Writer};

#[derive(Default)]
struct RustHello;

impl Plugin for RustHello {
    fn on_load(&mut self, w: &mut Writer) {
        w.register_panel(&PanelDef {
            id:      "rust-hello",
            title:   "Rust Hello",
            vim_cmd: "rhello",
            layout:  PanelLayout::Overlay,
            keybind: b'r',
        });
        w.set_status("Hello from Rust!");
    }

    fn on_draw(&mut self, _panel_id: u16, w: &mut Writer) {
        w.label("Hello from Rust!",        0);
        w.label("Built with the Rust SDK.", 1);
    }

    fn on_event(&mut self, _ev: InMsg, _w: &mut Writer) {}
}

export_plugin!(RustHello, "RustHello", "0.1.0");
