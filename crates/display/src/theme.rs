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

#[allow(dead_code)]
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
    pub text_label: Color32,
    pub geometry_line: Color32,
    pub geometry_fill: Color32,
}

#[allow(dead_code)]
impl CanvasPalette {
    /// Dark palette — canvas rendering defaults.
    pub fn dark() -> Self {
        Self {
            canvas_bg: Color32::from_rgb(30, 30, 36),
            grid_dot: Color32::from_rgba_premultiplied(80, 80, 90, 120),
            wire: Color32::from_rgb(100, 200, 100),
            wire_selected: Color32::from_rgb(255, 200, 50),
            wire_endpoint: Color32::from_rgb(130, 220, 130),
            bus: Color32::from_rgb(80, 140, 220),
            inst_body: Color32::from_rgb(200, 200, 210),
            inst_selected: Color32::from_rgb(255, 200, 50),
            inst_pin: Color32::from_rgb(200, 80, 80),
            symbol_line: Color32::from_rgb(200, 200, 210),
            symbol_pin: Color32::from_rgb(253, 216, 53),
            wire_preview: Color32::from_rgb(255, 140, 40),
            origin: Color32::from_rgba_premultiplied(100, 100, 120, 80),
            rubber_band: Color32::from_rgba_premultiplied(80, 140, 255, 40),
            selection_rect: Color32::from_rgba_premultiplied(80, 140, 255, 60),
            text_label: Color32::from_rgba_premultiplied(180, 180, 195, 200),
            geometry_line: Color32::from_rgb(180, 180, 195),
            geometry_fill: Color32::from_rgba_premultiplied(60, 60, 80, 40),
        }
    }

    /// Light palette — inverted for light backgrounds.
    pub fn light() -> Self {
        Self {
            canvas_bg: Color32::from_rgb(245, 245, 248),
            grid_dot: Color32::from_rgba_premultiplied(160, 160, 170, 120),
            wire: Color32::from_rgb(30, 140, 30),
            wire_selected: Color32::from_rgb(200, 140, 0),
            wire_endpoint: Color32::from_rgb(40, 160, 40),
            bus: Color32::from_rgb(40, 80, 180),
            inst_body: Color32::from_rgb(50, 50, 60),
            inst_selected: Color32::from_rgb(200, 140, 0),
            inst_pin: Color32::from_rgb(180, 40, 40),
            symbol_line: Color32::from_rgb(50, 50, 60),
            symbol_pin: Color32::from_rgb(180, 150, 20),
            wire_preview: Color32::from_rgb(220, 100, 20),
            origin: Color32::from_rgba_premultiplied(140, 140, 160, 80),
            rubber_band: Color32::from_rgba_premultiplied(40, 100, 220, 30),
            selection_rect: Color32::from_rgba_premultiplied(40, 100, 220, 60),
            text_label: Color32::from_rgba_premultiplied(60, 60, 70, 200),
            geometry_line: Color32::from_rgb(60, 60, 70),
            geometry_fill: Color32::from_rgba_premultiplied(200, 200, 220, 40),
        }
    }

    /// Build palette from theme tokens, falling back to dark/light defaults.
    pub fn from_tokens(tokens: &ThemeTokens) -> Self {
        let dark = token_bool(tokens, "dark_mode").unwrap_or(true);
        let base = if dark { Self::dark() } else { Self::light() };

        Self {
            canvas_bg: token_color(tokens, "canvas_bg").unwrap_or(base.canvas_bg),
            grid_dot: token_color(tokens, "grid_color").unwrap_or(base.grid_dot),
            wire: token_color(tokens, "wire_default").unwrap_or(base.wire),
            wire_selected: token_color(tokens, "wire_selected").unwrap_or(base.wire_selected),
            wire_endpoint: token_color(tokens, "ghost_color").unwrap_or(base.wire_endpoint),
            bus: token_color(tokens, "wire_bus").unwrap_or(base.bus),
            inst_body: token_color(tokens, "symbol_fill").unwrap_or(base.inst_body),
            inst_selected: token_color(tokens, "wire_selected").unwrap_or(base.inst_selected),
            inst_pin: token_color(tokens, "pin_color").unwrap_or(base.inst_pin),
            symbol_line: token_color(tokens, "symbol_stroke").unwrap_or(base.symbol_line),
            symbol_pin: token_color(tokens, "pin_color").unwrap_or(base.symbol_pin),
            wire_preview: token_color(tokens, "ghost_color").unwrap_or(base.wire_preview),
            origin: token_color(tokens, "crosshair_color").unwrap_or(base.origin),
            rubber_band: token_color(tokens, "selection_stroke").unwrap_or(base.rubber_band),
            selection_rect: token_color(tokens, "selection_fill").unwrap_or(base.selection_rect),
            text_label: token_color(tokens, "label_color").unwrap_or(base.text_label),
            geometry_line: token_color(tokens, "symbol_stroke").unwrap_or(base.geometry_line),
            geometry_fill: base.geometry_fill,
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
#[allow(dead_code)]
pub fn resolve_theme_color(tc: &ThemeColor, tokens: &ThemeTokens, fallback: Color32) -> Color32 {
    match tc {
        ThemeColor::Literal([r, g, b, a]) => Color32::from_rgba_unmultiplied(*r, *g, *b, *a),
        ThemeColor::Token(key) => token_color(tokens, key).unwrap_or(fallback),
    }
}

/// Convenience: get the right default palette for a dark/light mode flag.
#[allow(dead_code)]
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

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use schemify_core::theme::{ThemeTokens, ThemeValue};

    // ── CanvasPalette construction ──────────────────────────────────────────

    #[test]
    fn dark_palette_has_dark_canvas_bg() {
        let p = CanvasPalette::dark();
        assert!(p.canvas_bg.r() < 80);
        assert!(p.canvas_bg.g() < 80);
        assert!(p.canvas_bg.b() < 80);
    }

    #[test]
    fn light_palette_has_light_canvas_bg() {
        let p = CanvasPalette::light();
        assert!(p.canvas_bg.r() > 200);
        assert!(p.canvas_bg.g() > 200);
        assert!(p.canvas_bg.b() > 200);
    }

    #[test]
    fn dark_and_light_theme_palettes_differ() {
        let d = CanvasPalette::dark();
        let l = CanvasPalette::light();
        assert_ne!(d.canvas_bg, l.canvas_bg);
        assert_ne!(d.wire, l.wire);
        assert_ne!(d.text_label, l.text_label);
    }

    // ── palette_for_visuals ─────────────────────────────────────────────────

    #[test]
    fn palette_for_visuals_dark_true() {
        let p = palette_for_visuals(true);
        let d = CanvasPalette::dark();
        assert_eq!(p.canvas_bg, d.canvas_bg);
    }

    #[test]
    fn palette_for_visuals_dark_false() {
        let p = palette_for_visuals(false);
        let l = CanvasPalette::light();
        assert_eq!(p.canvas_bg, l.canvas_bg);
    }

    // ── from_tokens with defaults ───────────────────────────────────────────

    #[test]
    fn from_tokens_dark_uses_token_overrides() {
        let tokens = ThemeTokens::dark();
        let p = CanvasPalette::from_tokens(&tokens);
        // ThemeTokens::dark() provides a canvas_bg token [22,22,28,255],
        // which overrides the hardcoded dark() default.
        assert_eq!(
            p.canvas_bg,
            Color32::from_rgba_premultiplied(22, 22, 28, 255)
        );
    }

    #[test]
    fn from_tokens_light_uses_token_overrides() {
        let tokens = ThemeTokens::light();
        let p = CanvasPalette::from_tokens(&tokens);
        // ThemeTokens::light() provides a canvas_bg token [250,250,252,255].
        assert_eq!(
            p.canvas_bg,
            Color32::from_rgba_premultiplied(250, 250, 252, 255)
        );
    }

    #[test]
    fn from_tokens_empty_falls_back_to_dark() {
        // Empty tokens with no dark_mode key -> defaults to dark.
        let tokens = ThemeTokens {
            tokens: std::collections::HashMap::new(),
        };
        let p = CanvasPalette::from_tokens(&tokens);
        let d = CanvasPalette::dark();
        assert_eq!(p.canvas_bg, d.canvas_bg);
    }

    // ── from_tokens with custom override ────────────────────────────────────

    #[test]
    fn from_tokens_canvas_bg_override() {
        let mut tokens = ThemeTokens::dark();
        tokens
            .tokens
            .insert("canvas_bg".to_string(), ThemeValue::Color([255, 0, 0, 255]));
        let p = CanvasPalette::from_tokens(&tokens);
        assert_eq!(
            p.canvas_bg,
            Color32::from_rgba_premultiplied(255, 0, 0, 255)
        );
    }

    // ── token_color / token_bool helpers ────────────────────────────────────

    #[test]
    fn token_color_returns_none_for_missing_key() {
        let tokens = ThemeTokens::dark();
        assert!(token_color(&tokens, "nonexistent_key_xyz").is_none());
    }

    #[test]
    fn token_color_returns_none_for_wrong_type() {
        let mut tokens = ThemeTokens::dark();
        tokens
            .tokens
            .insert("test_key".to_string(), ThemeValue::Bool(true));
        assert!(token_color(&tokens, "test_key").is_none());
    }

    #[test]
    fn token_bool_returns_none_for_missing_key() {
        let tokens = ThemeTokens::dark();
        assert!(token_bool(&tokens, "nonexistent_key_xyz").is_none());
    }

    #[test]
    fn token_bool_returns_none_for_wrong_type() {
        let mut tokens = ThemeTokens::dark();
        tokens
            .tokens
            .insert("test_key".to_string(), ThemeValue::Color([0, 0, 0, 0]));
        assert!(token_bool(&tokens, "test_key").is_none());
    }

    #[test]
    fn token_bool_extracts_value() {
        let mut tokens = ThemeTokens::dark();
        tokens
            .tokens
            .insert("my_flag".to_string(), ThemeValue::Bool(false));
        assert_eq!(token_bool(&tokens, "my_flag"), Some(false));
    }

    // ── resolve_theme_color ─────────────────────────────────────────────────

    #[test]
    fn resolve_literal_color() {
        let tokens = ThemeTokens::dark();
        let tc = ThemeColor::Literal([10, 20, 30, 200]);
        let result = resolve_theme_color(&tc, &tokens, Color32::WHITE);
        assert_eq!(result, Color32::from_rgba_unmultiplied(10, 20, 30, 200));
    }

    #[test]
    fn resolve_token_color_found() {
        let mut tokens = ThemeTokens::dark();
        tokens.tokens.insert(
            "my_color".to_string(),
            ThemeValue::Color([50, 100, 150, 255]),
        );
        let tc = ThemeColor::Token("my_color".to_string());
        let result = resolve_theme_color(&tc, &tokens, Color32::WHITE);
        assert_eq!(result, Color32::from_rgba_premultiplied(50, 100, 150, 255));
    }

    #[test]
    fn resolve_token_color_missing_uses_fallback() {
        let tokens = ThemeTokens::dark();
        let tc = ThemeColor::Token("no_such_token".to_string());
        let fallback = Color32::from_rgb(42, 42, 42);
        let result = resolve_theme_color(&tc, &tokens, fallback);
        assert_eq!(result, fallback);
    }

    // ── WidgetPalette ───────────────────────────────────────────────────────

    #[test]
    fn widget_palette_dark_and_light_differ() {
        let d = WidgetPalette::dark();
        let l = WidgetPalette::light();
        assert_ne!(d.text_primary, l.text_primary);
        assert_ne!(d.accent, l.accent);
    }

    #[test]
    fn widget_palette_from_tokens_defaults() {
        let tokens = ThemeTokens::dark();
        let p = WidgetPalette::from_tokens(&tokens);
        // accent token exists in ThemeTokens::dark(), so it should be resolved.
        // The key point is that from_tokens doesn't panic.
        assert_ne!(p.text_primary, Color32::TRANSPARENT);
    }
}
