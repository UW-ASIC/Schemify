use egui::{Color32, Visuals};
use schemify_core::theme::{ThemeTokens, ThemeValue};

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
    }

    ctx.set_visuals(visuals);
}
