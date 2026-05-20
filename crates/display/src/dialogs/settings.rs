use eframe::egui;
use schemify_core::theme::ThemeTokens;
use schemify_handler::state::SettingsTab;
use schemify_handler::App;

use crate::theme_bridge::apply_theme;

// ── Theme presets ───────────────────────────────────────────────────────────

const PRESET_NAMES: &[&str] = &["Dark", "Light", "Custom"];

fn preset_label(idx: usize) -> &'static str {
    PRESET_NAMES.get(idx).copied().unwrap_or("Dark")
}

fn tokens_for_preset(idx: usize) -> ThemeTokens {
    match idx {
        1 => ThemeTokens::light(),
        _ => ThemeTokens::dark(),
    }
}

/// Format ThemeTokens as a human-readable string for the editor buffer.
/// Avoids serde_json dependency on native; produces a simple key=value list.
fn format_tokens(tokens: &ThemeTokens) -> String {
    use std::fmt::Write;
    let mut out = String::with_capacity(2048);
    let mut keys: Vec<&String> = tokens.tokens.keys().collect();
    keys.sort();
    for key in keys {
        let val = &tokens.tokens[key];
        let _ = match val {
            schemify_core::theme::ThemeValue::Color([r, g, b, a]) => {
                writeln!(out, "{key} = color({r}, {g}, {b}, {a})")
            }
            schemify_core::theme::ThemeValue::Float(f) => writeln!(out, "{key} = {f}"),
            schemify_core::theme::ThemeValue::Bool(b) => writeln!(out, "{key} = {b}"),
            schemify_core::theme::ThemeValue::Int(i) => writeln!(out, "{key} = {i}"),
        };
    }
    out
}

/// Try to parse the editor buffer back into ThemeTokens.
/// Accepts the `key = value` format produced by `format_tokens`.
fn parse_tokens(text: &str) -> Result<ThemeTokens, String> {
    use schemify_core::theme::ThemeValue;
    use std::collections::HashMap;

    let mut map = HashMap::new();

    for (line_no, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with("//") {
            continue;
        }
        let Some((key, rest)) = line.split_once('=') else {
            return Err(format!("line {}: missing '='", line_no + 1));
        };
        let key = key.trim().to_string();
        let rest = rest.trim();

        let value = if rest.starts_with("color(") && rest.ends_with(')') {
            let inner = &rest[6..rest.len() - 1];
            let parts: Vec<&str> = inner.split(',').map(|s| s.trim()).collect();
            if parts.len() != 4 {
                return Err(format!("line {}: color needs 4 components", line_no + 1));
            }
            let nums: Result<Vec<u8>, _> = parts.iter().map(|p| p.parse::<u8>()).collect();
            match nums {
                Ok(n) => ThemeValue::Color([n[0], n[1], n[2], n[3]]),
                Err(e) => return Err(format!("line {}: bad color value: {e}", line_no + 1)),
            }
        } else if rest == "true" {
            ThemeValue::Bool(true)
        } else if rest == "false" {
            ThemeValue::Bool(false)
        } else if let Ok(i) = rest.parse::<i32>() {
            // Disambiguate: if it contains a dot it's float, otherwise int.
            ThemeValue::Int(i)
        } else if let Ok(f) = rest.parse::<f32>() {
            ThemeValue::Float(f)
        } else {
            return Err(format!("line {}: unrecognized value: {rest}", line_no + 1));
        };

        map.insert(key, value);
    }

    if map.is_empty() {
        return Err("empty theme".into());
    }
    Ok(ThemeTokens { tokens: map })
}

// ── Keybind reference table (placeholder until keybinds module) ─────────────

const KEYBIND_TABLE: &[(&str, &str)] = &[
    ("Ctrl+N", "New Schematic"),
    ("Ctrl+S", "Save"),
    ("Ctrl+Z", "Undo"),
    ("Ctrl+Y", "Redo"),
    ("Ctrl+X", "Cut"),
    ("Ctrl+C", "Copy"),
    ("Ctrl+V", "Paste"),
    ("Ctrl+A", "Select All"),
    ("Ctrl+D", "Duplicate"),
    ("Ctrl+F", "Find"),
    ("Delete", "Delete Selected"),
    ("W", "Wire Tool"),
    ("Escape", "Select Tool"),
    ("G", "Toggle Grid"),
    ("R", "Rotate CW"),
    ("Shift+R", "Rotate CCW"),
    ("X", "Flip Horizontal"),
    ("Shift+X", "Flip Vertical"),
    ("Ctrl++", "Zoom In"),
    ("Ctrl+-", "Zoom Out"),
    ("Ctrl+0", "Zoom Reset"),
    ("F", "Zoom Fit"),
    ("Q", "Properties Dialog"),
    ("F5", "Run Simulation"),
    ("Shift+;", "Command Mode"),
];

// ── Main entry point ────────────────────────────────────────────────────────

pub fn show(ctx: &egui::Context, app: &mut App) {
    if !app.gui().dialogs.settings.is_open {
        return;
    }

    // Seed the JSON buffer on first open if empty.
    if app.gui().dialogs.settings.json_edit_buf.is_empty() {
        let text = format_tokens(&ThemeTokens::dark());
        let state = &mut app.gui_mut().dialogs.settings;
        state.json_edit_buf = text;
        state.status_msg.clear();
    }

    let mut is_open = true;
    let mut apply_tokens: Option<ThemeTokens> = None;

    egui::Window::new("Settings")
        .open(&mut is_open)
        .resizable(true)
        .default_size([540.0, 440.0])
        .show(ctx, |ui| {
            let state = &mut app.gui_mut().dialogs.settings;

            // Tab bar
            ui.horizontal(|ui| {
                ui.selectable_value(&mut state.active_tab, SettingsTab::Theme, "Theme");
                ui.selectable_value(&mut state.active_tab, SettingsTab::Keybinds, "Keybinds");
            });
            ui.separator();

            match state.active_tab {
                SettingsTab::Theme => {
                    show_theme_tab(ui, state, &mut apply_tokens);
                }
                SettingsTab::Keybinds => {
                    show_keybinds_tab(ui, state);
                }
            }
        });

    // Apply theme outside the window closure (needs &egui::Context).
    if let Some(tokens) = apply_tokens {
        apply_theme(ctx, &tokens);
        app.gui_mut().dialogs.settings.status_msg = "Theme applied.".into();
        app.gui_mut().dialogs.settings.dirty = false;
    }

    if !is_open {
        app.gui_mut().dialogs.settings.is_open = false;
    }
}

// ── Theme tab ───────────────────────────────────────────────────────────────

fn show_theme_tab(
    ui: &mut egui::Ui,
    state: &mut schemify_handler::state::SettingsDialogState,
    apply_tokens: &mut Option<ThemeTokens>,
) {
    // Preset selector
    let mut sel = state.selected_preset.unwrap_or(0) as usize;

    ui.horizontal(|ui| {
        ui.label("Preset:");
        egui::ComboBox::from_id_salt("theme_preset")
            .selected_text(preset_label(sel))
            .show_ui(ui, |ui| {
                for (i, name) in PRESET_NAMES.iter().enumerate() {
                    if ui.selectable_value(&mut sel, i, *name).changed() {
                        state.selected_preset = Some(sel as u16);
                        if sel < 2 {
                            // Dark or Light: replace buffer with preset defaults
                            state.json_edit_buf = format_tokens(&tokens_for_preset(sel));
                            state.dirty = true;
                            state.status_msg.clear();
                        }
                    }
                }
            });
    });

    ui.add_space(4.0);

    // Theme token editor
    ui.label("Theme tokens:");
    let scroll_height = ui.available_height() - 60.0;
    egui::ScrollArea::vertical()
        .max_height(scroll_height.max(100.0))
        .show(ui, |ui| {
            let response = ui.add(
                egui::TextEdit::multiline(&mut state.json_edit_buf)
                    .code_editor()
                    .desired_width(f32::INFINITY),
            );
            if response.changed() {
                state.dirty = true;
                state.selected_preset = Some(2); // switch to Custom on edit
            }
        });

    ui.add_space(4.0);

    // Buttons row
    ui.horizontal(|ui| {
        if ui.button("Apply").clicked() {
            match parse_tokens(&state.json_edit_buf) {
                Ok(tokens) => {
                    *apply_tokens = Some(tokens);
                }
                Err(e) => {
                    state.status_msg = format!("Parse error: {e}");
                }
            }
        }

        if ui.button("Reset to Default").clicked() {
            let base = if state.selected_preset == Some(1) { 1 } else { 0 };
            state.json_edit_buf = format_tokens(&tokens_for_preset(base));
            state.selected_preset = Some(base as u16);
            state.dirty = true;
            state.status_msg = "Reset to defaults.".into();
        }
    });

    // Status message
    if !state.status_msg.is_empty() {
        let color = if state.status_msg.starts_with("Parse error") {
            egui::Color32::from_rgb(0xff, 0x50, 0x50)
        } else {
            egui::Color32::YELLOW
        };
        ui.colored_label(color, &state.status_msg);
    }
}

// ── Keybinds tab ────────────────────────────────────────────────────────────

fn show_keybinds_tab(
    ui: &mut egui::Ui,
    _state: &mut schemify_handler::state::SettingsDialogState,
) {
    // Store filter in egui's frame-persistent temp storage to avoid
    // colliding with the theme tab's json_edit_buf.
    let filter_id = ui.id().with("kb_filter");
    let mut filter: String = ui
        .data_mut(|d| d.get_temp::<String>(filter_id).unwrap_or_default());

    ui.horizontal(|ui| {
        ui.label("Filter:");
        ui.text_edit_singleline(&mut filter);
    });
    ui.separator();

    let filter_lower = filter.to_lowercase();

    egui::ScrollArea::vertical().show(ui, |ui| {
        egui::Grid::new("keybind_grid")
            .num_columns(2)
            .striped(true)
            .min_col_width(100.0)
            .show(ui, |ui| {
                ui.strong("Shortcut");
                ui.strong("Action");
                ui.end_row();

                for &(shortcut, action) in KEYBIND_TABLE {
                    if !filter_lower.is_empty()
                        && !shortcut.to_lowercase().contains(&filter_lower)
                        && !action.to_lowercase().contains(&filter_lower)
                    {
                        continue;
                    }
                    ui.monospace(shortcut);
                    ui.label(action);
                    ui.end_row();
                }
            });
    });

    ui.data_mut(|d| d.insert_temp(filter_id, filter));
}
