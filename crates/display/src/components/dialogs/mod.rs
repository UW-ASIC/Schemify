//! All dialogs. `show_all_dialogs` is THE extension point: a new dialog
//! is one GuiState field + one fn + one line here.

use eframe::egui;

use schemify_editor::handler::{App, ObjectRef};
use schemify_editor::schemify::Command;

use schemify_plugin_host::Marketplace;

use crate::keybinds::KEYBINDS;
use crate::state::GuiState;


// ════════════════════════════════════════════════════════════
// Dialogs
// ════════════════════════════════════════════════════════════

pub fn show_all_dialogs(
    ctx: &egui::Context,
    app: &mut App,
    gui: &mut GuiState,
    marketplace: &mut Marketplace,
) {
    properties_dialog(ctx, app, gui);
    find_dialog(ctx, app, gui);
    settings_dialog(ctx, app, gui);
    import_dialog(ctx, app, gui);
    spice_code_dialog(ctx, app);
    new_primitive_dialog(ctx, app, gui);
    marketplace_dialog(ctx, app, gui, marketplace);
}

pub mod marketplace;
pub mod properties;
pub(crate) use marketplace::*;
pub(crate) use properties::*;

// ── Find ────────────────────────────────────────────────────

fn find_dialog(ctx: &egui::Context, app: &mut App, gui: &mut GuiState) {
    if !app.state.dialogs.find_open {
        return;
    }

    let instance_names: Vec<(usize, String)> = {
        let sch = app.schematic();
        (0..sch.instances.len())
            .map(|i| (i, app.resolve(sch.instances.name[i]).to_string()))
            .collect()
    };

    let find = &mut gui.find;
    let mut open_props_idx: Option<usize> = None;
    let mut is_open = true;

    egui::Window::new("Find")
        .open(&mut is_open)
        .resizable(true)
        .default_width(300.0)
        .show(ctx, |ui| {
            let resp = ui.text_edit_singleline(&mut find.query);
            if resp.changed() {
                find.results.clear();
                let q = find.query.to_lowercase();
                if !q.is_empty() {
                    for (idx, name) in &instance_names {
                        if name.to_lowercase().contains(&q) {
                            find.results.push(crate::state::FindResult {
                                label: name.clone(),
                                index: *idx,
                            });
                        }
                    }
                }
                find.selected = None;
            }

            // Arrow-key navigation + Enter to open.
            let (up, down, enter) = ui.input(|i| {
                (
                    i.key_pressed(egui::Key::ArrowUp),
                    i.key_pressed(egui::Key::ArrowDown),
                    i.key_pressed(egui::Key::Enter),
                )
            });
            if !find.results.is_empty() {
                if down {
                    find.selected = Some(match find.selected {
                        Some(s) => (s + 1).min(find.results.len() - 1),
                        None => 0,
                    });
                }
                if up {
                    find.selected = Some(find.selected.map_or(0, |s| s.saturating_sub(1)));
                }
                if enter {
                    if let Some(r) = find.selected.and_then(|s| find.results.get(s)) {
                        open_props_idx = Some(r.index);
                    }
                }
            }

            if !find.query.is_empty() {
                let count = find.results.len();
                ui.weak(format!("{count} result{}", if count == 1 { "" } else { "s" }));
            }
            ui.separator();

            egui::ScrollArea::vertical().max_height(200.0).show(ui, |ui| {
                for (i, result) in find.results.iter().enumerate() {
                    let resp = ui.selectable_label(
                        find.selected == Some(i),
                        format!("[Instance] {}", result.label),
                    );
                    if resp.clicked() {
                        find.selected = Some(i);
                    }
                    if resp.double_clicked() {
                        open_props_idx = Some(result.index);
                    }
                }
            });

            if find.results.is_empty() && !find.query.is_empty() {
                ui.label("No results.");
            }

            if let Some(r) = find.selected.and_then(|s| find.results.get(s)) {
                ui.separator();
                if ui.button("Open Properties").clicked() {
                    open_props_idx = Some(r.index);
                }
            }
        });

    if !is_open {
        app.state.dialogs.find_open = false;
    }
    if let Some(idx) = open_props_idx {
        // Select the instance and reopen props seeded from it.
        gui.props.inst_idx = idx;
        gui.props.initialized = false;
        app.state.dialogs.props_open = true;
        app.selection_mut().clear();
        app.selection_mut().insert(ObjectRef::Instance(idx as u32));
    }
}

// ── Settings (keybind reference; theme presets killed with ThemeTokens) ──

fn settings_dialog(ctx: &egui::Context, app: &mut App, gui: &mut GuiState) {
    if !app.state.dialogs.settings_open {
        return;
    }
    let mut is_open = true;
    let mut toggle_dark = false;

    egui::Window::new("Settings")
        .open(&mut is_open)
        .resizable(true)
        .default_size([460.0, 440.0])
        .show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.label("Appearance:");
                let mut dark = app.state.view.dark_mode;
                if ui.checkbox(&mut dark, "Dark mode").changed() {
                    toggle_dark = true;
                }
            });
            ui.separator();

            ui.label(egui::RichText::new("Keyboard Shortcuts").strong());
            ui.horizontal(|ui| {
                ui.label("Filter:");
                ui.text_edit_singleline(&mut gui.settings_filter);
            });
            ui.separator();

            let filter = gui.settings_filter.to_lowercase();
            egui::ScrollArea::vertical().show(ui, |ui| {
                egui::Grid::new("keybind_grid")
                    .num_columns(2)
                    .striped(true)
                    .min_col_width(100.0)
                    .show(ui, |ui| {
                        ui.strong("Shortcut");
                        ui.strong("Action");
                        ui.end_row();
                        for kb in KEYBINDS {
                            if !filter.is_empty()
                                && !kb.shortcut.to_lowercase().contains(&filter)
                                && !kb.label.to_lowercase().contains(&filter)
                            {
                                continue;
                            }
                            ui.monospace(kb.shortcut);
                            ui.label(kb.label);
                            ui.end_row();
                        }
                    });
            });
        });

    if toggle_dark {
        app.dispatch(Command::ToggleColorScheme).or_status(app);
    }
    if !is_open {
        app.state.dialogs.settings_open = false;
    }
}

// ── Import ──────────────────────────────────────────────────

fn import_dialog(ctx: &egui::Context, app: &mut App, gui: &mut GuiState) {
    if !app.state.dialogs.import_open {
        return;
    }

    let status = app.state.dialogs.import_status.clone();
    let mut cmds: Vec<Command> = Vec::new();
    let mut browse_clicked = false;
    let mut is_open = true;

    egui::Window::new("Import Netlist")
        .open(&mut is_open)
        .resizable(false)
        .default_width(420.0)
        .show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.label("Netlist:");
                ui.text_edit_singleline(&mut gui.import.path_buf);
                if ui.button("Browse...").clicked() {
                    browse_clicked = true;
                }
            });
            ui.horizontal(|ui| {
                ui.label("PDK:");
                if gui.import.pdk_name.is_empty() {
                    ui.weak("None detected");
                } else {
                    ui.weak(format!("(detected: {})", gui.import.pdk_name));
                }
            });
            if !status.is_empty() {
                ui.colored_label(egui::Color32::YELLOW, &status);
            }
            ui.separator();
            if ui.button("Import").clicked() && !gui.import.path_buf.is_empty() {
                cmds.push(Command::ImportSpice {
                    path: gui.import.path_buf.clone(),
                });
            }
        });

    if browse_clicked {
        if let Some(path) = rfd::FileDialog::new()
            .add_filter("Netlist", &["sp", "spice", "cir", "net", "spi", "cdl"])
            .pick_file()
        {
            gui.import.path_buf = path.display().to_string();
            if let Ok(content) = std::fs::read_to_string(&path) {
                gui.import.pdk_name = detect_pdk(&content).unwrap_or_default();
            }
        }
    }

    if !is_open {
        app.state.dialogs.import_open = false;
    }
    for cmd in cmds {
        app.dispatch(cmd).or_status(app);
    }
}

fn detect_pdk(source: &str) -> Option<String> {
    const KNOWN: &[&str] = &[
        "sky130", "gf180mcu", "asap7", "freepdk45", "freepdk15", "tsmc", "gpdk045", "gpdk090",
    ];
    let lower = source.to_ascii_lowercase();
    KNOWN.iter().find(|p| lower.contains(*p)).map(|p| p.to_string())
}

// ── SPICE code editor (syntax highlighting deferred) ────────

fn spice_code_dialog(ctx: &egui::Context, app: &mut App) {
    if !app.state.dialogs.spice_code_open {
        return;
    }

    let netlist = app.state.last_netlist.clone();
    let mut cmds: Vec<Command> = Vec::new();
    let mut is_open = true;
    let mut buf = std::mem::take(&mut app.state.dialogs.spice_code_buf);

    egui::Window::new("SPICE Code")
        .open(&mut is_open)
        .resizable(true)
        .default_size([700.0, 500.0])
        .show(ctx, |ui| {
            ui.horizontal(|ui| {
                if ui.button("Apply").clicked() {
                    cmds.push(Command::SetSpiceCode(buf.clone()));
                }
                if ui.button("Generate Netlist").clicked() {
                    cmds.push(Command::ExportNetlist);
                }
            });
            ui.separator();

            egui::ScrollArea::vertical().id_salt("spice_editor_scroll").show(ui, |ui| {
                ui.label(egui::RichText::new("Analysis Code").strong().small());
                ui.add(
                    egui::TextEdit::multiline(&mut buf)
                        .font(egui::FontId::monospace(13.0))
                        .desired_width(f32::INFINITY)
                        .desired_rows(16),
                );
                if !netlist.is_empty() {
                    ui.separator();
                    ui.label(egui::RichText::new("Netlist (read-only)").strong().small());
                    let mut display = netlist.clone();
                    ui.add(
                        egui::TextEdit::multiline(&mut display)
                            .font(egui::FontId::monospace(13.0))
                            .desired_width(f32::INFINITY)
                            .desired_rows(12)
                            .interactive(false),
                    );
                }
            });
        });

    app.state.dialogs.spice_code_buf = buf;
    if !is_open {
        app.state.dialogs.spice_code_open = false;
    }
    for cmd in cmds {
        app.dispatch(cmd).or_status(app);
    }
}

// ── New primitive ───────────────────────────────────────────

/// Generate minimal `.chn_prim` file content: a box symbol with the pins
/// distributed vertically.
fn generate_chn_prim(name: &str, pins: &[&str]) -> String {
    use std::fmt::Write;
    let mut out = String::new();
    out.push_str("chn_prim\n");
    let _ = writeln!(out, "SYMBOL {name}");
    out.push_str("spice_prefix: X\n");
    let _ = writeln!(out, "pins [{}]", pins.len());
    for pin in pins {
        let _ = writeln!(out, "  {pin}");
    }
    out.push_str(
        "drawing:\n  lines:\n    (-20, -20) (20, -20)\n    (20, -20) (20, 20)\n    \
         (20, 20) (-20, 20)\n    (-20, 20) (-20, -20)\n  pin_positions:\n",
    );
    let pin_count = pins.len();
    for (i, pin) in pins.iter().enumerate() {
        let y = if pin_count <= 1 {
            0
        } else {
            -30 + (i as i32 * 60) / (pin_count as i32 - 1).max(1)
        };
        let _ = writeln!(out, "    {pin}: (0, {y})");
    }
    out
}

fn new_primitive_dialog(ctx: &egui::Context, app: &mut App, gui: &mut GuiState) {
    if !app.state.dialogs.new_prim_open {
        return;
    }
    let project_dir = app.state.project_dir.clone();
    let state = &mut gui.new_prim;
    let mut is_open = true;

    egui::Window::new("New Primitive")
        .open(&mut is_open)
        .resizable(false)
        .default_width(350.0)
        .show(ctx, |ui| {
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
                } else if project_dir.as_os_str().is_empty() {
                    state.status_msg = "Set project directory first".to_string();
                } else {
                    let pins: Vec<&str> = state
                        .pins_buf
                        .split(',')
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .collect();
                    let file_name = format!("{}.chn_prim", state.name_buf);
                    let path = project_dir.join(&file_name);
                    let content = generate_chn_prim(&state.name_buf, &pins);
                    state.status_msg = match std::fs::write(&path, &content) {
                        Ok(_) => format!("Created {file_name}"),
                        Err(e) => format!("Error: {e}"),
                    };
                }
            }
        });

    if !is_open {
        app.state.dialogs.new_prim_open = false;
        gui.new_prim.status_msg.clear();
    }
}
