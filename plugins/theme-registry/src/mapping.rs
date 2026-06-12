//! base16 palette → Schemify theme tokens.
//!
//! Semantic slots (base16 styling guidelines):
//! base00 bg · base03 comments · base05 fg · base08 red · base09 orange ·
//! base0A yellow · base0B green · base0D blue.

use schemify_plugins::sdk::ThemeValue;

use crate::registry::Scheme;

fn color(rgb: [u8; 3], alpha: u8) -> ThemeValue {
    ThemeValue::Color([rgb[0], rgb[1], rgb[2], alpha])
}

/// Token set applied via `theme/override`.
pub fn map_scheme(s: &Scheme) -> Vec<(String, ThemeValue)> {
    let p = &s.palette;
    let pairs: &[(&str, ThemeValue)] = &[
        ("dark", ThemeValue::Bool(s.dark)),
        ("canvas_bg", color(p[0x00], 255)),
        ("grid_dot", color(p[0x03], 120)),
        ("symbol_line", color(p[0x05], 255)),
        ("geometry_line", color(p[0x05], 255)),
        ("geometry_fill", color(p[0x02], 40)),
        ("text_label", color(p[0x05], 200)),
        ("wire", color(p[0x0B], 255)),
        ("wire_endpoint", color(p[0x0B], 255)),
        ("wire_selected", color(p[0x0A], 255)),
        ("inst_selected", color(p[0x0A], 255)),
        ("warn", color(p[0x0A], 255)),
        ("wire_preview", color(p[0x09], 255)),
        ("bus", color(p[0x0D], 255)),
        ("accent", color(p[0x0D], 255)),
        ("rubber_band", color(p[0x0D], 40)),
        ("selection_rect", color(p[0x0D], 60)),
        ("inst_pin", color(p[0x08], 255)),
        ("inst_error", color(p[0x08], 255)),
        ("error", color(p[0x08], 255)),
        ("origin", color(p[0x03], 80)),
    ];
    pairs
        .iter()
        .map(|(k, v)| ((*k).to_owned(), v.clone()))
        .collect()
}
