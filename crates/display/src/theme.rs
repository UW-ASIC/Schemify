use egui::{Color32, Visuals};
use schemify_core::plugin_types::ThemeColor;
use schemify_core::theme::{ThemeTokens, ThemeValue};

// ── Token extraction helpers ────────────────────────────────────────────────

fn token_color(tokens: &ThemeTokens, key: &str) -> Option<Color32> {
    match tokens.tokens.get(key)? {
        ThemeValue::Color([r, g, b, a]) => Some(Color32::from_rgba_premultiplied(*r, *g, *b, *a)),
        _ => None,
    }
}

fn token_bool(tokens: &ThemeTokens, key: &str) -> Option<bool> {
    match tokens.tokens.get(key)? {
        ThemeValue::Bool(v) => Some(*v),
        _ => None,
    }
}

// ── Canvas Palette ──────────────────────────────────────────────────────────
//
// All colors the canvas renderer needs, resolved once per theme change.
// Matches Zig `Palette.zig` structure + rubber_band / selection_rect / text.

#[derive(Debug, Clone)]
pub struct CanvasPalette {
    pub canvas_bg: Color32,
    pub grid_dot: Color32,
    pub wire: Color32,
    pub wire_selected: Color32,
    pub wire_endpoint: Color32,
    pub bus: Color32,
    pub inst_body: Color32,
    pub inst_selected: Color32,
    pub inst_pin: Color32,
    pub symbol_line: Color32,
    pub symbol_pin: Color32,
    pub wire_preview: Color32,
    pub origin: Color32,
    pub rubber_band: Color32,
    pub selection_rect: Color32,
    pub text: Color32,
}

impl CanvasPalette {
    /// Dark palette — matches Zig reference `Palette.zig` dark-mode values.
    pub fn dark() -> Self {
        Self {
            canvas_bg:      Color32::from_rgb(0x1a, 0x1a, 0x2e),
            grid_dot:       Color32::from_rgb(0x3a, 0x3a, 0x4e),
            wire:           Color32::from_rgb(0x4f, 0xc3, 0xf7),
            wire_selected:  Color32::from_rgb(0xff, 0xeb, 0x3b),
            wire_endpoint:  Color32::from_rgb(0x66, 0xbb, 0x6a),
            bus:            Color32::from_rgb(0x42, 0xa5, 0xf5),
            inst_body:      Color32::from_rgb(0xb0, 0xbe, 0xc5),
            inst_selected:  Color32::from_rgb(0xff, 0xeb, 0x3b),
            inst_pin:       Color32::from_rgb(0xfd, 0xd8, 0x35),
            symbol_line:    Color32::from_rgb(0x90, 0xa4, 0xae),
            symbol_pin:     Color32::from_rgb(0xfd, 0xd8, 0x35),
            wire_preview:   Color32::from_rgb(0x80, 0xcb, 0xc4),
            origin:         Color32::from_rgb(0xef, 0x53, 0x50),
            rubber_band:    Color32::from_rgba_unmultiplied(0x42, 0xa5, 0xf5, 80),
            selection_rect: Color32::from_rgba_unmultiplied(0xff, 0xeb, 0x3b, 40),
            text:           Color32::from_rgb(0xe0, 0xe0, 0xe0),
        }
    }

    /// Light palette — inverted for light backgrounds.
    pub fn light() -> Self {
        Self {
            canvas_bg:      Color32::from_rgb(0xfa, 0xfa, 0xfc),
            grid_dot:       Color32::from_rgb(0xc8, 0xc8, 0xd2),
            wire:           Color32::from_rgb(0x00, 0x28, 0x78),
            wire_selected:  Color32::from_rgb(0xc8, 0x5a, 0x00),
            wire_endpoint:  Color32::from_rgb(0x2e, 0x7d, 0x32),
            bus:            Color32::from_rgb(0x1e, 0x78, 0x73),
            inst_body:      Color32::from_rgb(0x54, 0x6e, 0x7a),
            inst_selected:  Color32::from_rgb(0xc8, 0x5a, 0x00),
            inst_pin:       Color32::from_rgb(0xb4, 0x96, 0x14),
            symbol_line:    Color32::from_rgb(0x28, 0x28, 0x28),
            symbol_pin:     Color32::from_rgb(0xb4, 0x96, 0x14),
            wire_preview:   Color32::from_rgb(0x28, 0xb4, 0x50),
            origin:         Color32::from_rgb(0xc6, 0x28, 0x28),
            rubber_band:    Color32::from_rgba_unmultiplied(0x1e, 0x64, 0xc8, 80),
            selection_rect: Color32::from_rgba_unmultiplied(0xc8, 0x5a, 0x00, 40),
            text:           Color32::from_rgb(0x1e, 0x1e, 0x1e),
        }
    }

    /// Build palette from theme tokens, falling back to dark/light defaults.
    pub fn from_tokens(tokens: &ThemeTokens) -> Self {
        let dark = token_bool(tokens, "dark_mode").unwrap_or(true);
        let base = if dark { Self::dark() } else { Self::light() };

        Self {
            canvas_bg:      token_color(tokens, "canvas_bg").unwrap_or(base.canvas_bg),
            grid_dot:       token_color(tokens, "grid_color").unwrap_or(base.grid_dot),
            wire:           token_color(tokens, "wire_default").unwrap_or(base.wire),
            wire_selected:  token_color(tokens, "wire_selected").unwrap_or(base.wire_selected),
            wire_endpoint:  token_color(tokens, "ghost_color").unwrap_or(base.wire_endpoint),
            bus:            token_color(tokens, "wire_bus").unwrap_or(base.bus),
            inst_body:      token_color(tokens, "symbol_fill").unwrap_or(base.inst_body),
            inst_selected:  token_color(tokens, "wire_selected").unwrap_or(base.inst_selected),
            inst_pin:       token_color(tokens, "pin_color").unwrap_or(base.inst_pin),
            symbol_line:    token_color(tokens, "symbol_stroke").unwrap_or(base.symbol_line),
            symbol_pin:     token_color(tokens, "pin_color").unwrap_or(base.symbol_pin),
            wire_preview:   token_color(tokens, "ghost_color").unwrap_or(base.wire_preview),
            origin:         token_color(tokens, "crosshair_color").unwrap_or(base.origin),
            rubber_band:    token_color(tokens, "selection_stroke").unwrap_or(base.rubber_band),
            selection_rect: token_color(tokens, "selection_fill").unwrap_or(base.selection_rect),
            text:           token_color(tokens, "label_color").unwrap_or(base.text),
        }
    }
}

// ── Widget Palette ─────────────────────────────────────────────────────────
//
// Colors for plugin widget rendering, resolved from theme tokens.

/// Colors for plugin widget rendering, resolved from theme tokens.
#[derive(Debug, Clone)]
pub struct WidgetPalette {
    pub alert_info: Color32,
    pub alert_warn: Color32,
    pub alert_error: Color32,
    pub alert_success: Color32,
    pub badge_default: Color32,
    pub text_primary: Color32,
    pub accent: Color32,
}

impl WidgetPalette {
    pub fn dark() -> Self {
        Self {
            alert_info: Color32::from_rgb(100, 160, 255),
            alert_warn: Color32::from_rgb(240, 200, 60),
            alert_error: Color32::from_rgb(232, 100, 100),
            alert_success: Color32::from_rgb(100, 220, 120),
            badge_default: Color32::from_rgb(120, 120, 200),
            text_primary: Color32::from_rgb(230, 230, 230),
            accent: Color32::from_rgb(88, 166, 255),
        }
    }

    pub fn light() -> Self {
        Self {
            alert_info: Color32::from_rgb(30, 100, 200),
            alert_warn: Color32::from_rgb(180, 140, 20),
            alert_error: Color32::from_rgb(200, 40, 40),
            alert_success: Color32::from_rgb(30, 160, 60),
            badge_default: Color32::from_rgb(80, 80, 160),
            text_primary: Color32::from_rgb(30, 30, 30),
            accent: Color32::from_rgb(30, 100, 200),
        }
    }

    pub fn from_tokens(tokens: &ThemeTokens) -> Self {
        let dark = token_bool(tokens, "dark_mode").unwrap_or(true);
        let base = if dark { Self::dark() } else { Self::light() };
        Self {
            alert_info: token_color(tokens, "accent").unwrap_or(base.alert_info),
            alert_warn: token_color(tokens, "warning").unwrap_or(base.alert_warn),
            alert_error: token_color(tokens, "error").unwrap_or(base.alert_error),
            alert_success: token_color(tokens, "success").unwrap_or(base.alert_success),
            badge_default: token_color(tokens, "accent").unwrap_or(base.badge_default),
            text_primary: token_color(tokens, "text_primary").unwrap_or(base.text_primary),
            accent: token_color(tokens, "accent").unwrap_or(base.accent),
        }
    }
}

/// Resolve a ThemeColor to a concrete Color32.
pub fn resolve_theme_color(tc: &ThemeColor, tokens: &ThemeTokens, fallback: Color32) -> Color32 {
    match tc {
        ThemeColor::Literal([r, g, b, a]) => Color32::from_rgba_unmultiplied(*r, *g, *b, *a),
        ThemeColor::Token(key) => token_color(tokens, key).unwrap_or(fallback),
    }
}

/// Convenience: get the right default palette for a dark/light mode flag.
pub fn palette_for_visuals(dark: bool) -> CanvasPalette {
    if dark {
        CanvasPalette::dark()
    } else {
        CanvasPalette::light()
    }
}

// ── Apply theme to egui Visuals ─────────────────────────────────────────────

/// Apply `ThemeTokens` to egui's `Visuals`.
pub fn apply_theme(ctx: &egui::Context, tokens: &ThemeTokens) {
    let dark = token_bool(tokens, "dark_mode").unwrap_or(true);
    let mut visuals = if dark {
        Visuals::dark()
    } else {
        Visuals::light()
    };

    if let Some(c) = token_color(tokens, "bg_primary") {
        visuals.panel_fill = c;
        visuals.window_fill = c;
    }
    if let Some(c) = token_color(tokens, "bg_secondary") {
        visuals.extreme_bg_color = c;
    }
    if let Some(c) = token_color(tokens, "bg_panel") {
        visuals.faint_bg_color = c;
    }
    if let Some(c) = token_color(tokens, "text_primary") {
        visuals.override_text_color = Some(c);
    }
    if let Some(c) = token_color(tokens, "accent") {
        visuals.hyperlink_color = c;
        visuals.selection.bg_fill = c.linear_multiply(0.3);
        visuals.selection.stroke.color = c;
    }
    if let Some(c) = token_color(tokens, "border") {
        visuals.widgets.noninteractive.bg_stroke.color = c;
        visuals.widgets.inactive.bg_stroke.color = c;
    }
    if let Some(c) = token_color(tokens, "error") {
        visuals.error_fg_color = c;
    }
    if let Some(c) = token_color(tokens, "warning") {
        visuals.warn_fg_color = c;
    }

    ctx.set_visuals(visuals);
}
