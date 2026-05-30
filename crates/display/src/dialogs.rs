use eframe::egui;
use schemify_core::commands::Command;
use schemify_core::theme::ThemeTokens;
use schemify_handler::state::{FindResult, ImportFormat, PrimType, SettingsTab};
use schemify_handler::App;

use crate::theme::apply_theme;

// ── Show All (dispatcher) ────────────────────────────────────────────────────

pub fn show_all(ctx: &egui::Context, app: &mut App) {
    properties(ctx, app);
    find(ctx, app);
    settings(ctx, app);
    import(ctx, app);
    spice_code(ctx, app);
    new_primitive(ctx, app);
}

// ── Properties ───────────────────────────────────────────────────────────────

fn properties(ctx: &egui::Context, app: &mut App) {
    if !app.dialogs().props.is_open {
        return;
    }

    // Pre-collect instance data while we have immutable access
    let inst_idx = app.dialogs().props.inst_idx;
    let sch = app.schematic();
    if inst_idx >= sch.instances.len() {
        return;
    }

    let inst_name = app.resolve(sch.instances.name[inst_idx]).to_string();
    let symbol_name = app.resolve(sch.instances.symbol[inst_idx]).to_string();
    let kind = sch.instances.kind[inst_idx];
    let x = sch.instances.x[inst_idx];
    let y = sch.instances.y[inst_idx];
    let flags = sch.instances.flags[inst_idx];
    let prop_start = sch.instances.prop_start[inst_idx] as usize;
    let prop_count = sch.instances.prop_count[inst_idx] as usize;

    let rotation_deg = match flags.rotation() {
        0 => "0",
        1 => "90",
        2 => "180",
        3 => "270",
        _ => "?",
    };
    let flipped = flags.flip();

    let props: Vec<(String, String)> = (prop_start..prop_start + prop_count)
        .filter_map(|pi| {
            sch.properties.get(pi).map(|p| {
                (
                    app.resolve(p.key).to_string(),
                    app.resolve(p.value).to_string(),
                )
            })
        })
        .collect();

    // Initialize buffers on first frame
    let state = &mut app.dialogs_mut().props;
    if !state.initialized {
        state.name_buf = inst_name.clone();
        state.prop_values = props.iter().map(|(_, v)| v.clone()).collect();
        state.initialized = true;
    }

    let mut cmds: Vec<Command> = Vec::new();

    egui::Window::new("Properties")
        .open(&mut state.is_open)
        .resizable(true)
        .default_width(350.0)
        .show(ctx, |ui| {
            // Instance info section
            ui.heading("Instance");
            egui::Grid::new("props_info_grid")
                .num_columns(2)
                .spacing([12.0, 4.0])
                .show(ui, |ui| {
                    ui.label("Name:");
                    ui.text_edit_singleline(&mut state.name_buf);
                    ui.end_row();

                    ui.label("Symbol:");
                    ui.label(&symbol_name);
                    ui.end_row();

                    ui.label("Kind:");
                    ui.label(format!("{:?}", kind));
                    ui.end_row();
                });

            ui.add_space(4.0);

            // Position info section (read-only)
            ui.separator();
            ui.label(egui::RichText::new("Position").strong());
            egui::Grid::new("props_pos_grid")
                .num_columns(2)
                .spacing([12.0, 4.0])
                .show(ui, |ui| {
                    ui.label("X:");
                    ui.label(format!("{}", x));
                    ui.end_row();

                    ui.label("Y:");
                    ui.label(format!("{}", y));
                    ui.end_row();

                    ui.label("Rotation:");
                    ui.label(format!("{}°", rotation_deg));
                    ui.end_row();

                    ui.label("Flip:");
                    ui.label(if flipped { "Yes" } else { "No" });
                    ui.end_row();
                });

            // Properties section
            if !props.is_empty() {
                ui.add_space(4.0);
                ui.separator();
                ui.label(egui::RichText::new("Properties").strong());

                egui::ScrollArea::vertical().show(ui, |ui| {
                    egui::Grid::new("props_values_grid")
                        .num_columns(2)
                        .spacing([12.0, 4.0])
                        .show(ui, |ui| {
                            for (i, (key, _)) in props.iter().enumerate() {
                                ui.label(format!("{}:", key));
                                if let Some(val) = state.prop_values.get_mut(i) {
                                    ui.text_edit_singleline(val);
                                }
                                ui.end_row();
                            }
                        });
                });
            }

            ui.separator();
            if ui.button("Apply").clicked() {
                if state.name_buf != inst_name {
                    cmds.push(Command::RenameInstance {
                        idx: inst_idx,
                        new_name: state.name_buf.clone(),
                    });
                }
                for (i, (key, orig_val)) in props.iter().enumerate() {
                    if let Some(new_val) = state.prop_values.get(i) {
                        if new_val != orig_val {
                            cmds.push(Command::SetInstanceProp {
                                idx: inst_idx,
                                key: key.clone(),
                                value: new_val.clone(),
                            });
                        }
                    }
                }
            }
        });

    if !state.is_open {
        state.initialized = false;
    }

    // Drop gui borrow, dispatch
    for cmd in cmds {
        app.dispatch(cmd);
    }
}

// ── Find ─────────────────────────────────────────────────────────────────────

fn find(ctx: &egui::Context, app: &mut App) {
    if !app.dialogs().find.is_open {
        return;
    }

    // Collect searchable names
    let instance_names: Vec<(usize, String)> = {
        let sch = app.schematic();
        (0..sch.instances.len())
            .map(|i| {
                let name = app.resolve(sch.instances.name[i]);
                (i, name.to_string())
            })
            .collect()
    };

    let find = &mut app.dialogs_mut().find;

    // Track actions to perform after the window closure
    let mut open_props_idx: Option<usize> = None;

    egui::Window::new("Find")
        .open(&mut find.is_open)
        .resizable(true)
        .default_width(300.0)
        .show(ctx, |ui| {
            // Search field
            let resp = ui.text_edit_singleline(&mut find.query);
            if resp.changed() {
                find.results.clear();
                let query_lower = find.query.to_lowercase();
                if !query_lower.is_empty() {
                    for (idx, name) in &instance_names {
                        if name.to_lowercase().contains(&query_lower) {
                            find.results.push(FindResult {
                                label: name.clone(),
                                object_type: "Instance".to_string(),
                                index: *idx,
                            });
                        }
                    }
                }
                find.selected = None;
            }

            // Arrow key navigation
            let up = ui.input(|i| i.key_pressed(egui::Key::ArrowUp));
            let down = ui.input(|i| i.key_pressed(egui::Key::ArrowDown));
            let enter = ui.input(|i| i.key_pressed(egui::Key::Enter));

            if !find.results.is_empty() {
                if down {
                    find.selected = Some(match find.selected {
                        Some(s) => (s + 1).min(find.results.len() - 1),
                        None => 0,
                    });
                }
                if up {
                    find.selected = Some(match find.selected {
                        Some(s) => s.saturating_sub(1),
                        None => 0,
                    });
                }
                if enter {
                    if let Some(sel) = find.selected {
                        if let Some(result) = find.results.get(sel) {
                            if result.object_type == "Instance" {
                                open_props_idx = Some(result.index);
                            }
                        }
                    }
                }
            }

            // Result count
            if !find.query.is_empty() {
                ui.horizontal(|ui| {
                    let count = find.results.len();
                    ui.weak(format!(
                        "{} result{}",
                        count,
                        if count == 1 { "" } else { "s" }
                    ));
                });
            }

            ui.separator();

            // Results list
            egui::ScrollArea::vertical()
                .max_height(200.0)
                .show(ui, |ui| {
                    for (i, result) in find.results.iter().enumerate() {
                        let selected = find.selected == Some(i);
                        let label = format!("[{}] {}", result.object_type, result.label);
                        let resp = ui.selectable_label(selected, &label);
                        if resp.clicked() {
                            find.selected = Some(i);
                        }
                        if resp.double_clicked() && result.object_type == "Instance" {
                            open_props_idx = Some(result.index);
                        }
                    }
                });

            if find.results.is_empty() && !find.query.is_empty() {
                ui.label("No results.");
            }

            // "Open Properties" button for selected result
            if let Some(sel) = find.selected {
                if let Some(result) = find.results.get(sel) {
                    if result.object_type == "Instance" {
                        ui.separator();
                        if ui.button("Open Properties").clicked() {
                            open_props_idx = Some(result.index);
                        }
                    }
                }
            }
        });

    // Open properties dialog for the selected instance
    if let Some(idx) = open_props_idx {
        let props = &mut app.dialogs_mut().props;
        props.is_open = true;
        props.inst_idx = idx;
        props.initialized = false;
    }
}

// ── Settings ─────────────────────────────────────────────────────────────────

// ── Theme presets ────────────────────────────────────────────────────────────

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

// ── Keybind reference table ──────────────────────────────────────────────────

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

// ── Settings main entry point ────────────────────────────────────────────────

fn settings(ctx: &egui::Context, app: &mut App) {
    if !app.dialogs().settings.is_open {
        return;
    }

    // Seed the JSON buffer on first open if empty.
    if app.dialogs().settings.json_edit_buf.is_empty() {
        let text = format_tokens(&ThemeTokens::dark());
        let state = &mut app.dialogs_mut().settings;
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
            let state = &mut app.dialogs_mut().settings;

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
        app.dialogs_mut().settings.status_msg = "Theme applied.".into();
        app.dialogs_mut().settings.dirty = false;
    }

    if !is_open {
        app.dialogs_mut().settings.is_open = false;
    }
}

// ── Theme tab ────────────────────────────────────────────────────────────────

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
            let base = if state.selected_preset == Some(1) {
                1
            } else {
                0
            };
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

// ── Keybinds tab ─────────────────────────────────────────────────────────────

fn show_keybinds_tab(ui: &mut egui::Ui, _state: &mut schemify_handler::state::SettingsDialogState) {
    // Store filter in egui's frame-persistent temp storage to avoid
    // colliding with the theme tab's json_edit_buf.
    let filter_id = ui.id().with("kb_filter");
    let mut filter: String = ui.data_mut(|d| d.get_temp::<String>(filter_id).unwrap_or_default());

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

// ── Import ───────────────────────────────────────────────────────────────────

fn import(ctx: &egui::Context, app: &mut App) {
    let mut cmds: Vec<Command> = Vec::new();

    {
        let state = &mut app.dialogs_mut().import;
        if !state.is_open {
            return;
        }

        egui::Window::new("Import")
            .open(&mut state.is_open)
            .resizable(false)
            .default_width(400.0)
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    ui.label("Format:");
                    egui::ComboBox::from_id_salt("import_format")
                        .selected_text(format!("{:?}", state.format))
                        .show_ui(ui, |ui| {
                            ui.selectable_value(&mut state.format, ImportFormat::Spice, "SPICE");
                            ui.selectable_value(&mut state.format, ImportFormat::Xschem, "Xschem");
                            ui.selectable_value(
                                &mut state.format,
                                ImportFormat::Virtuoso,
                                "Virtuoso",
                            );
                        });
                });

                ui.horizontal(|ui| {
                    ui.label("Path:");
                    ui.text_edit_singleline(&mut state.path_buf);
                    #[cfg(not(target_arch = "wasm32"))]
                    if ui.button("Browse...").clicked() {
                        if let Some(path) = rfd::FileDialog::new().pick_file() {
                            state.path_buf = path.display().to_string();
                        }
                    }
                });

                if !state.status_msg.is_empty() {
                    ui.colored_label(egui::Color32::YELLOW, &state.status_msg);
                }

                ui.separator();
                if ui.button("Import").clicked() && !state.path_buf.is_empty() {
                    match state.format {
                        ImportFormat::Spice => {
                            cmds.push(Command::ImportSpice {
                                path: state.path_buf.clone(),
                            });
                        }
                        _ => {
                            state.status_msg = "Format not yet supported".to_string();
                        }
                    }
                }
            });
    }

    for cmd in cmds {
        app.dispatch(cmd);
    }
}

// ── Spice Code ───────────────────────────────────────────────────────────────

fn spice_code(ctx: &egui::Context, app: &mut App) {
    if !app.dialogs().spice_code.is_open {
        return;
    }

    let current_body = app.schematic().spice_body.clone();
    let netlist = app.last_netlist().to_string();
    let dark = ctx.style().visuals.dark_mode;
    let mut cmds: Vec<Command> = Vec::new();

    {
        let state = &mut app.dialogs_mut().spice_code;

        // Seed buffer on first open
        if state.buf.is_empty() && !current_body.is_empty() {
            state.buf = current_body;
        }

        egui::Window::new("SPICE Code")
            .open(&mut state.is_open)
            .resizable(true)
            .default_size([900.0, 550.0])
            .show(ctx, |ui| {
                // Toolbar
                ui.horizontal(|ui| {
                    if ui.button("Apply").clicked() {
                        cmds.push(Command::SetSpiceCode(state.buf.clone()));
                    }
                    if ui.button("Generate Netlist").clicked() {
                        cmds.push(Command::ExportNetlist);
                    }
                    ui.separator();
                    ui.selectable_value(&mut state.show_netlist, false, "Editor Only");
                    ui.selectable_value(&mut state.show_netlist, true, "Side-by-Side");
                });
                ui.separator();

                // SPICE syntax highlighter for TextEdit
                let mut spice_layouter = |ui: &egui::Ui, text: &str, wrap_width: f32| {
                    let font = egui::FontId::monospace(13.0);
                    let mut job = crate::highlight::highlight_spice(text, font, dark);
                    job.wrap.max_width = wrap_width;
                    ui.fonts(|f| f.layout_job(job))
                };

                // SPICE highlighter for read-only netlist view
                let mut netlist_layouter = |ui: &egui::Ui, text: &str, wrap_width: f32| {
                    let font = egui::FontId::monospace(13.0);
                    let mut job = crate::highlight::highlight_spice(text, font, dark);
                    job.wrap.max_width = wrap_width;
                    ui.fonts(|f| f.layout_job(job))
                };

                if state.show_netlist {
                    // Side-by-side: editor left, netlist right
                    let avail = ui.available_size();
                    let half_w = (avail.x - 8.0) * 0.5;

                    ui.horizontal_top(|ui| {
                        // Left: SPICE code editor
                        ui.vertical(|ui| {
                            ui.set_width(half_w);
                            ui.label(egui::RichText::new("Analysis Code").strong().small());
                            egui::ScrollArea::vertical()
                                .id_salt("spice_editor_scroll")
                                .show(ui, |ui| {
                                    ui.add(
                                        egui::TextEdit::multiline(&mut state.buf)
                                            .font(egui::FontId::monospace(13.0))
                                            .layouter(&mut spice_layouter)
                                            .desired_width(f32::INFINITY)
                                            .desired_rows(20),
                                    );
                                });
                        });

                        ui.separator();

                        // Right: netlist (read-only, highlighted)
                        ui.vertical(|ui| {
                            ui.set_width(half_w);
                            ui.label(egui::RichText::new("Netlist (read-only)").strong().small());
                            if netlist.is_empty() {
                                ui.weak(
                                    "No netlist generated yet.\nClick \"Generate Netlist\" above.",
                                );
                            } else {
                                egui::ScrollArea::vertical().id_salt("netlist_scroll").show(
                                    ui,
                                    |ui| {
                                        let mut display = netlist.clone();
                                        ui.add(
                                            egui::TextEdit::multiline(&mut display)
                                                .font(egui::FontId::monospace(13.0))
                                                .layouter(&mut netlist_layouter)
                                                .desired_width(f32::INFINITY)
                                                .desired_rows(20)
                                                .interactive(false),
                                        );
                                    },
                                );
                            }
                        });
                    });
                } else {
                    // Editor only (full width)
                    egui::ScrollArea::vertical().show(ui, |ui| {
                        ui.add(
                            egui::TextEdit::multiline(&mut state.buf)
                                .font(egui::FontId::monospace(13.0))
                                .layouter(&mut spice_layouter)
                                .desired_width(f32::INFINITY)
                                .desired_rows(25),
                        );
                    });
                }
            });
    }

    for cmd in cmds {
        app.dispatch(cmd);
    }
}

// ── New Primitive ────────────────────────────────────────────────────────────

/// Generate minimal .chn_prim file content.
fn generate_chn_prim(name: &str, prim_type: PrimType, pins: &[&str]) -> String {
    let prefix = match prim_type {
        PrimType::Behavioral => "X",
        PrimType::Spice => "X",
        PrimType::Digital => "U",
    };

    let mut out = String::new();
    out.push_str("chn_prim\n");
    out.push_str(&format!("SYMBOL {}\n", name));
    out.push_str(&format!("spice_prefix: {}\n", prefix));
    out.push_str(&format!("pins [{}]\n", pins.len()));
    for pin in pins {
        out.push_str(&format!("  {}\n", pin));
    }

    // Generate a simple rectangular drawing with pin positions
    out.push_str("drawing:\n");
    out.push_str("  lines:\n");
    out.push_str("    (-20, -20) (20, -20)\n");
    out.push_str("    (20, -20) (20, 20)\n");
    out.push_str("    (20, 20) (-20, 20)\n");
    out.push_str("    (-20, 20) (-20, -20)\n");
    out.push_str("  pin_positions:\n");

    let pin_count = pins.len();
    for (i, pin) in pins.iter().enumerate() {
        // Distribute pins vertically along the symbol
        let y = if pin_count <= 1 {
            0
        } else {
            -30 + (i as i32 * 60) / (pin_count as i32 - 1).max(1)
        };
        out.push_str(&format!("    {}: (0, {})\n", pin, y));
    }

    out
}

fn new_primitive(ctx: &egui::Context, app: &mut App) {
    // Read project_dir before mutable borrow
    let project_dir = app.project_dir().to_path_buf();

    let state = &mut app.dialogs_mut().new_prim;
    if !state.is_open {
        return;
    }

    egui::Window::new("New Primitive")
        .open(&mut state.is_open)
        .resizable(false)
        .default_width(350.0)
        .show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.label("Type:");
                egui::ComboBox::from_id_salt("prim_type")
                    .selected_text(format!("{:?}", state.prim_type))
                    .show_ui(ui, |ui| {
                        ui.selectable_value(
                            &mut state.prim_type,
                            PrimType::Behavioral,
                            "Behavioral",
                        );
                        ui.selectable_value(&mut state.prim_type, PrimType::Spice, "SPICE");
                        ui.selectable_value(&mut state.prim_type, PrimType::Digital, "Digital");
                    });
            });

            ui.horizontal(|ui| {
                ui.label("Name:");
                ui.text_edit_singleline(&mut state.name_buf);
            });

            ui.label("Pins (comma-separated):");
            ui.text_edit_singleline(&mut state.pins_buf);

            if !state.status_msg.is_empty() {
                ui.colored_label(egui::Color32::YELLOW, &state.status_msg);
            }

            ui.separator();
            if ui.button("Create").clicked() {
                if state.name_buf.is_empty() {
                    state.status_msg = "Name required".to_string();
                } else {
                    let pins_list: Vec<&str> = state
                        .pins_buf
                        .split(',')
                        .map(|s| s.trim())
                        .filter(|s| !s.is_empty())
                        .collect();

                    #[cfg(not(target_arch = "wasm32"))]
                    {
                        if project_dir.as_os_str().is_empty() {
                            state.status_msg = "Set project directory first".to_string();
                        } else {
                            let file_name = format!("{}.chn_prim", state.name_buf);
                            let path = project_dir.join(&file_name);
                            let content =
                                generate_chn_prim(&state.name_buf, state.prim_type, &pins_list);
                            match std::fs::write(&path, &content) {
                                Ok(_) => {
                                    state.status_msg = format!("Created {}", file_name);
                                }
                                Err(e) => {
                                    state.status_msg = format!("Error: {}", e);
                                }
                            }
                        }
                    }

                    #[cfg(target_arch = "wasm32")]
                    {
                        let _ = &pins_list;
                        state.status_msg =
                            format!("Created primitive: {} (no file I/O on web)", state.name_buf);
                    }
                }
            }
        });
}
