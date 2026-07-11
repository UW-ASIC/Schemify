//! Side panels: file explorer and library browser.

use eframe::egui;

use schemify_editor::handler::App;
use schemify_editor::schemify::PRIMITIVES;


use crate::state::{GuiState, LibrarySection};


// ════════════════════════════════════════════════════════════
// File explorer (floating window, native)
// ════════════════════════════════════════════════════════════

pub fn file_explorer_window(ctx: &egui::Context, app: &mut App) {
    let mut open = app.state.dialogs.file_explorer_open;
    if !open {
        return;
    }

    egui::Window::new("File Explorer")
        .open(&mut open)
        .default_size([240.0, 400.0])
        .resizable(true)
        .collapsible(true)
        .show(ctx, |ui| {
            egui::ScrollArea::vertical()
                .auto_shrink([false; 2])
                .show(ui, |ui| file_explorer(ui, app));
        });

    app.state.dialogs.file_explorer_open = open;
}

fn file_explorer(ui: &mut egui::Ui, app: &mut App) {
    let project_dir = app.state.project_dir.clone();

    if project_dir.as_os_str().is_empty() {
        ui.label("No project directory set.");
        if ui.button("Set Project Directory").clicked() {
            if let Some(dir) = rfd::FileDialog::new().pick_folder() {
                app.set_project_dir(dir);
            }
        }
        return;
    }

    ui.horizontal(|ui| {
        ui.label("\u{1f4c1}");
        ui.label(project_dir.display().to_string());
    });
    ui.separator();

    if let Ok(entries) = std::fs::read_dir(&project_dir) {
        let mut files: Vec<_> = entries
            .filter_map(|e| e.ok())
            .filter(|e| e.path().extension().is_some_and(|ext| ext == "chn"))
            .collect();
        files.sort_by_key(|e| e.file_name());

        if files.is_empty() {
            ui.label("No .chn files found.");
        }
        for entry in &files {
            let name = entry.file_name();
            if ui
                .selectable_label(false, name.to_string_lossy().as_ref())
                .double_clicked()
            {
                let _ = app.open_file(&entry.path());
            }
        }
    }

    ui.separator();
    if ui.button("Change Directory").clicked() {
        if let Some(dir) = rfd::FileDialog::new().pick_folder() {
            app.set_project_dir(dir);
        }
    }
}

// ════════════════════════════════════════════════════════════
// Library browser (floating window, fed from the primitives registry
// + project library index)
// ════════════════════════════════════════════════════════════

pub fn library_window(ctx: &egui::Context, app: &mut App, gui: &mut GuiState) {
    let mut open = app.state.dialogs.library_open;
    if !open {
        return;
    }

    egui::Window::new("Library Browser")
        .open(&mut open)
        .default_size([260.0, 450.0])
        .resizable(true)
        .collapsible(true)
        .show(ctx, |ui| library_browser(ui, app, gui));

    app.state.dialogs.library_open = open;
}

fn library_browser(ui: &mut egui::Ui, app: &mut App, gui: &mut GuiState) {
    let selected = gui.library_selected;
    let mut new_selected = selected;
    let mut place: Option<(String, String)> = None;

    // Single click selects; double click starts placement.
    let mut row = |ui: &mut egui::Ui,
                   sec: LibrarySection,
                   i: usize,
                   label: &str,
                   symbol: &str,
                   prefix: char,
                   detail: Option<&str>| {
        let resp = ui.selectable_label(selected == Some((sec, i)), label);
        let resp = match detail {
            Some(d) => resp.on_hover_text(d),
            None => resp,
        };
        if resp.clicked() {
            new_selected = Some((sec, i));
        }
        if resp.double_clicked() {
            place = Some((symbol.to_owned(), format!("{prefix}1")));
        }
    };

    egui::ScrollArea::vertical().auto_shrink(false).show(ui, |ui| {
        egui::CollapsingHeader::new("Simulation Devices")
            .default_open(true)
            .show(ui, |ui| {
                for (i, p) in PRIMITIVES.iter().enumerate() {
                    let prefix = if p.prefix > 0 { p.prefix as char } else { 'X' };
                    row(ui, LibrarySection::Builtin, i, p.kind_name, p.kind_name, prefix, None);
                }
            });

        // PDK manifest cells: placing the mapped primitive is enough — the
        // netlist swaps in the PDK subcircuit automatically.
        if let Some(pdk_name) = app.state.pdk.as_ref().map(|p| p.name.clone()) {
            let cells = app.state.library.pdk_cells.clone();
            egui::CollapsingHeader::new(format!("PDK: {pdk_name}"))
                .default_open(true)
                .show(ui, |ui| {
                    if cells.is_empty() {
                        ui.weak("manifest maps no devices");
                    }
                    for (i, (key, model)) in cells.iter().enumerate() {
                        row(ui, LibrarySection::Pdk, i, key, key, 'X', Some(model));
                    }
                });
        }

        let prims = app.state.library.project_prims.clone();
        if !prims.is_empty() {
            egui::CollapsingHeader::new("Project Primitives")
                .default_open(true)
                .show(ui, |ui| {
                    for (i, name) in prims.iter().enumerate() {
                        row(ui, LibrarySection::ProjectPrims, i, name, name, 'X', None);
                    }
                });
        }

        let symbols = app.state.library.project_symbols.clone();
        if !symbols.is_empty() {
            let current = app.schematic().name.clone();
            egui::CollapsingHeader::new("Project Symbols")
                .default_open(true)
                .show(ui, |ui| {
                    for (i, (name, pin_count)) in symbols.iter().enumerate() {
                        if *name == current {
                            // A schematic can't instance itself.
                            ui.add_enabled(false, egui::Button::selectable(false, name.as_str()))
                                .on_disabled_hover_text("open schematic");
                            continue;
                        }
                        let detail = format!("{pin_count} pins");
                        row(ui, LibrarySection::ProjectSymbols, i, name, name, 'X', Some(&detail));
                    }
                });
        }
    });

    gui.library_selected = new_selected;
    if let Some((path, name)) = place {
        app.start_placement(path, name);
    }
}
