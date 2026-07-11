//! Menu bar + the file-dialog actions it (and keybinds) trigger.

use eframe::egui;

use schemify_editor::handler::{App, Origin, ViewMode};
use schemify_editor::schemify::{Command, SpiceBackend, StimulusLang, Tool};

use schemify_plugins::PluginLifecycle;

use crate::plugin_host::PluginHost;
use crate::state::GuiState;


// ════════════════════════════════════════════════════════════
// Native file dialogs (core FileOpen/FileSave are display-driven)
// ════════════════════════════════════════════════════════════

pub fn open_file_dialog(app: &mut App) {
    if let Some(path) = rfd::FileDialog::new()
        .add_filter("Schemify", &["chn", "chn_prim", "chn_tb"])
        .add_filter("Schematic", &["chn"])
        .add_filter("Primitive", &["chn_prim"])
        .add_filter("Testbench", &["chn_tb"])
        .pick_file()
    {
        if let Err(e) = app.open_file(&path) {
            app.state.status_msg = format!("Open failed: {e}");
        }
    }
}

/// Save the active document: to its file if it has one, else Save-As.
pub fn save_active(app: &mut App) {
    let origin = app.active_doc().origin.clone();
    match origin {
        Origin::File(path) => {
            app.state.status_msg = match app.save_to_path(&path) {
                Ok(()) => format!("Saved {}", path.display()),
                Err(e) => format!("Save failed: {e}"),
            };
        }
        _ => save_as_dialog(app),
    }
}

pub fn save_as_dialog(app: &mut App) {
    let doc = app.active_doc();
    let default_name = doc.display_name();
    let kind = doc.kind;
    if let Some(path) = rfd::FileDialog::new()
        .add_filter("Schematic", &["chn"])
        .add_filter("Primitive", &["chn_prim"])
        .add_filter("Testbench", &["chn_tb"])
        .set_file_name(&default_name)
        .save_file()
    {
        // The GTK/portal dialog doesn't always append the filter
        // extension; default it from the doc kind.
        let path = if path.extension().is_none() {
            path.with_extension(kind.ext_no_dot())
        } else {
            path
        };
        app.state.status_msg = match app.save_to_path(&path) {
            Ok(()) => format!("Saved {}", path.display()),
            Err(e) => format!("Save failed: {e}"),
        };
    }
}

fn export_spice_dialog(app: &mut App) {
    if let Some(path) = rfd::FileDialog::new()
        .add_filter("SPICE netlist", &["spice", "cir", "sp"])
        .save_file()
    {
        app.dispatch(Command::ExportSpice {
            path: path.to_string_lossy().into_owned(),
        }).or_status(app);
    }
}

// ════════════════════════════════════════════════════════════
// Menu bar
// ════════════════════════════════════════════════════════════

/// Menu item with a right-aligned shortcut hint. Returns clicked.
fn sc(ui: &mut egui::Ui, label: &str, shortcut: &str) -> bool {
    let w = ui.available_width().max(180.0);
    let resp = ui.add(egui::Button::new(label).min_size(egui::vec2(w, 0.0)));
    if !shortcut.is_empty() {
        ui.painter().text(
            resp.rect.right_center() - egui::vec2(8.0, 0.0),
            egui::Align2::RIGHT_CENTER,
            shortcut,
            egui::FontId::proportional(12.0),
            ui.visuals().weak_text_color(),
        );
    }
    resp.clicked()
}

fn en(ui: &mut egui::Ui, label: &str, shortcut: &str, enabled: bool) -> bool {
    let w = ui.available_width().max(180.0);
    let resp = ui.add_enabled(enabled, egui::Button::new(label).min_size(egui::vec2(w, 0.0)));
    if !shortcut.is_empty() {
        ui.painter().text(
            resp.rect.right_center() - egui::vec2(8.0, 0.0),
            egui::Align2::RIGHT_CENTER,
            shortcut,
            egui::FontId::proportional(12.0),
            ui.visuals().weak_text_color(),
        );
    }
    resp.clicked()
}

fn tog(ui: &mut egui::Ui, label: &str, shortcut: &str, active: bool) -> bool {
    let prefix = if active { "\u{2713} " } else { "  " };
    sc(ui, &format!("{prefix}{label}"), shortcut)
}

pub fn menu_bar(
    ui: &mut egui::Ui,
    app: &mut App,
    gui: &mut GuiState,
    plugins: &mut PluginHost,
) {
    let can_undo = !app.active_doc().undo_history.is_empty();
    let can_redo = !app.active_doc().redo_history.is_empty();
    let grid_on = app.state.view.show_grid;
    let view_mode = app.state.view.view_mode;
    let active_idx = app.state.active_doc;
    let bus_active = app.state.tool.active == Tool::Bus;
    let sim_backend = app.schematic().sim_backend;
    let stimulus_lang = app.schematic().stimulus_lang;
    let corner_info = app.state.pdk.as_ref().map(|p| {
        (
            p.corners.clone(),
            app.schematic().sim_corner.clone(),
            p.default_corner.clone(),
        )
    });

    let mut cmds: Vec<Command> = Vec::new();
    let (mut open_file, mut save_file, mut save_as, mut save_all, mut export_spice) =
        (false, false, false, false, false);
    let mut open_wave = false;
    let mut new_optimizer = false;
    let mut new_view_mode: Option<ViewMode> = None;

    egui::Panel::top("menu_bar").show(ui, |ui| {
        egui::MenuBar::new().ui(ui, |ui| {
            // ── File ──
            ui.menu_button("File", |ui| {
                if sc(ui, "New Schematic", "Ctrl+N") {
                    cmds.push(Command::FileNew);

                }
                if sc(ui, "New Primitive...", "") {
                    cmds.push(Command::OpenNewPrimDialog);

                }
                if sc(ui, "Open...", "Ctrl+O") {
                    open_file = true;

                }
                if sc(ui, "Import Netlist...", "") {
                    cmds.push(Command::OpenImportDialog);

                }
                if sc(ui, "Reload from Disk", "") {
                    cmds.push(Command::ReloadFromDisk);

                }
                ui.separator();
                if sc(ui, "Save", "Ctrl+S") {
                    save_file = true;

                }
                if sc(ui, "Save As...", "Ctrl+Shift+S") {
                    save_as = true;

                }
                if sc(ui, "Save All", "") {
                    save_all = true;

                }
                ui.separator();
                ui.menu_button("Export", |ui| {
                    if sc(ui, "Export SPICE...", "") {
                        export_spice = true;
    
                    }
                    if sc(ui, "Export Netlist", "") {
                        cmds.push(Command::ExportNetlist);
    
                    }
                });
                ui.separator();
                if sc(ui, "New Tab", "Ctrl+T") {
                    cmds.push(Command::NewTab);

                }
                if sc(ui, "Close Tab", "Ctrl+W") {
                    cmds.push(Command::CloseTab(active_idx));

                }
            });

            // ── Edit ──
            ui.menu_button("Edit", |ui| {
                if en(ui, "Undo", "Ctrl+Z", can_undo) {
                    cmds.push(Command::Undo);

                }
                if en(ui, "Redo", "Ctrl+Y", can_redo) {
                    cmds.push(Command::Redo);

                }
                ui.separator();
                for (label, shortcut, cmd) in [
                    ("Cut", "Ctrl+X", Command::Cut),
                    ("Copy", "Ctrl+C", Command::Copy),
                    ("Paste", "Ctrl+V", Command::Paste),
                    ("Delete", "Del", Command::DeleteSelected),
                    ("Duplicate", "Ctrl+D", Command::DuplicateSelected),
                ] {
                    if sc(ui, label, shortcut) {
                        cmds.push(cmd);
    
                    }
                }
                ui.separator();
                for (label, shortcut, cmd) in [
                    ("Select All", "Ctrl+A", Command::SelectAll),
                    ("Select None", "Ctrl+Shift+A", Command::SelectNone),
                    ("Invert Selection", "Ctrl+I", Command::InvertSelection),
                    ("Find...", "Ctrl+F", Command::OpenFindDialog),
                ] {
                    if sc(ui, label, shortcut) {
                        cmds.push(cmd);
    
                    }
                }
                ui.separator();
                for (label, shortcut, cmd) in [
                    ("Rotate CW", "R", Command::RotateCw),
                    ("Rotate CCW", "Shift+R", Command::RotateCcw),
                    ("Flip Horizontal", "X", Command::FlipHorizontal),
                    ("Flip Vertical", "Shift+X", Command::FlipVertical),
                    ("Align to Grid", "", Command::AlignToGrid),
                ] {
                    if sc(ui, label, shortcut) {
                        cmds.push(cmd);
    
                    }
                }
                ui.menu_button("Align", |ui| {
                    for (label, shortcut, cmd) in [
                        ("Left", "Alt+L", Command::AlignLeft),
                        ("Right", "Alt+R", Command::AlignRight),
                        ("Top", "Alt+T", Command::AlignTop),
                        ("Bottom", "Alt+B", Command::AlignBottom),
                        ("Center Horizontal", "", Command::AlignCenterH),
                        ("Center Vertical", "", Command::AlignCenterV),
                        ("Distribute Horizontally", "Alt+H", Command::DistributeH),
                        ("Distribute Vertically", "Alt+V", Command::DistributeV),
                    ] {
                        if sc(ui, label, shortcut) {
                            cmds.push(cmd);
        
                        }
                    }
                });
                ui.separator();
                if sc(ui, "Properties...", "Q") {
                    cmds.push(Command::OpenPropsDialog);

                }
                if sc(ui, "Spice Code...", "") {
                    cmds.push(Command::OpenSpiceCodeEditor);

                }
            });

            // ── View ──
            ui.menu_button("View", |ui| {
                for (label, shortcut, cmd) in [
                    ("Zoom In", "Ctrl+=", Command::ZoomIn),
                    ("Zoom Out", "Ctrl+-", Command::ZoomOut),
                    ("Zoom to Fit", "F", Command::ZoomFit),
                    ("Zoom Reset", "Ctrl+0", Command::ZoomReset),
                ] {
                    if sc(ui, label, shortcut) {
                        cmds.push(cmd);
    
                    }
                }
                ui.separator();
                if tog(ui, "Grid", "G", grid_on) {
                    cmds.push(Command::ToggleGrid);

                }
                if tog(ui, "Crosshair", "", gui.crosshair) {
                    gui.crosshair = !gui.crosshair;

                }
                if tog(ui, "Fill Shapes", "", gui.fill_rects) {
                    gui.fill_rects = !gui.fill_rects;

                }
                if tog(ui, "Dark Mode", "", app.state.view.dark_mode) {
                    cmds.push(Command::ToggleColorScheme);

                }
                ui.separator();
                for (label, mode) in [
                    ("Schematic View", ViewMode::Schematic),
                    ("Symbol View", ViewMode::Symbol),
                    ("Documentation View", ViewMode::Documentation),
                ] {
                    if tog(ui, label, "", view_mode == mode) {
                        new_view_mode = Some(mode);
    
                    }
                }
                ui.separator();
                if sc(ui, "Library Browser", "I") {
                    cmds.push(Command::OpenLibraryBrowser);

                }
                if sc(ui, "File Explorer", "") {
                    cmds.push(Command::OpenFileExplorer);

                }
            });

            // ── Place ──
            ui.menu_button("Place", |ui| {
                for (label, shortcut, tool) in [
                    ("Select", "Esc", Tool::Select),
                    ("Move", "M", Tool::Move),
                    ("Pan", "", Tool::Pan),
                ] {
                    if sc(ui, label, shortcut) {
                        cmds.push(Command::SetTool(tool));
    
                    }
                }
                ui.separator();
                if sc(ui, "Wire", "W") {
                    cmds.push(Command::SetTool(Tool::Wire));

                }
                if tog(ui, "Bus", "B", bus_active) {
                    cmds.push(Command::SetTool(Tool::Bus));

                }
                if sc(ui, "Bus Ripper", "") {
                    cmds.push(Command::SetTool(Tool::BusRipper));

                }
                ui.separator();
                for (label, shortcut, tool) in [
                    ("Line", "L", Tool::Line),
                    ("Rectangle", "", Tool::Rect),
                    ("Arc", "A", Tool::Arc),
                    ("Circle", "C", Tool::Circle),
                    ("Polygon", "P", Tool::Polygon),
                    ("Text", "T", Tool::Text),
                ] {
                    if sc(ui, label, shortcut) {
                        cmds.push(Command::SetTool(tool));
    
                    }
                }
                ui.separator();
                if sc(ui, "Insert from Library...", "I") {
                    cmds.push(Command::OpenLibraryBrowser);

                }
            });

            // ── Simulate ──
            ui.menu_button("Simulate", |ui| {
                if sc(ui, "Run Simulation", "F5") {
                    cmds.push(Command::RunSim);

                }
                ui.menu_button("Backend", |ui| {
                    for be in [SpiceBackend::NgSpice, SpiceBackend::Xyce] {
                        if tog(ui, be.as_str(), "", sim_backend == be) {
                            cmds.push(Command::SetSimBackend(be.as_str().to_string()));
        
                        }
                    }
                });
                ui.menu_button("Stimulus Language", |ui| {
                    for lang in StimulusLang::ALL {
                        if tog(ui, lang.as_str(), "", stimulus_lang == *lang) {
                            cmds.push(Command::SetStimulusLang(lang.as_str().to_string()));
        
                        }
                    }
                });
                if let Some((corners, current, default)) = &corner_info {
                    ui.menu_button("Corner", |ui| {
                        for c in corners {
                            let active = if current.is_empty() { c == default } else { c == current };
                            if tog(ui, c, "", active) {
                                cmds.push(Command::SetSimCorner(c.clone()));
            
                            }
                        }
                    });
                }
                ui.separator();
                if sc(ui, "Waveform Viewer", "") {
                    open_wave = true;

                }
                if sc(ui, "New Optimizer", "") {
                    // Every activation opens a NEW instance (own window).
                    new_optimizer = true;

                }
                if sc(ui, "Spice Code...", "") {
                    cmds.push(Command::OpenSpiceCodeEditor);

                }
                if sc(ui, "Export Netlist", "") {
                    cmds.push(Command::ExportNetlist);

                }
            });

            // ── Plugins ──
            ui.menu_button("Plugins", |ui| {
                if sc(ui, "Marketplace...", "") {
                    cmds.push(Command::OpenMarketplace);

                }
                if sc(ui, "Refresh Plugins", "F6") {
                    cmds.push(Command::PluginsRefresh);

                }
                ui.separator();

                let ids: Vec<String> =
                    plugins.manager.plugin_ids().map(str::to_owned).collect();
                if ids.is_empty() {
                    ui.weak("No plugins found");
                }
                for id in &ids {
                    let state = plugins.manager.state(id);
                    let name = plugins
                        .manager
                        .manifest(id)
                        .map(|m| m.plugin.name.clone())
                        .unwrap_or_else(|| id.clone());
                    let label = match state {
                        Some(PluginLifecycle::Running) => format!("{name} \u{25CF}"),
                        Some(PluginLifecycle::Error) => format!("{name} \u{26A0}"),
                        _ => name.clone(),
                    };
                    ui.menu_button(label, |ui| {
                        match state {
                            Some(PluginLifecycle::Running) => {
                                if sc(ui, "Stop", "") {
                                    let _ = plugins.manager.stop(id);
                
                                }
                            }
                            _ => {
                                if sc(ui, "Start", "") {
                                    if let Err(e) = plugins.manager.start(id) {
                                        app.state.status_msg = e.to_string();
                                    }
                
                                }
                            }
                        }
                        if let Some(err) = plugins.manager.error_msg(id) {
                            ui.colored_label(gui.theme.error, err);
                        }
                        // Panel visibility toggles.
                        let mut any_panel = false;
                        for p in plugins
                            .panels
                            .iter_mut()
                            .filter(|p| p.reg.plugin_id == *id)
                        {
                            any_panel = true;
                            ui.checkbox(&mut p.visible, &p.reg.name);
                        }
                        if any_panel {
                            ui.separator();
                        }
                        // Registered commands.
                        for c in plugins.commands.iter().filter(|c| c.plugin_id == *id) {
                            let key = c.keybind.as_deref().unwrap_or("");
                            if sc(ui, &c.name, key) {
                                // Route through core so CLI/MCP share the
                                // same path: tag = "plugin-id:command".
                                cmds.push(Command::PluginCommand {
                                    tag: format!("{id}:{}", c.name),
                                    payload: Vec::new(),
                                });
            
                            }
                        }
                    });
                }
            });

            // ── Help ──
            ui.menu_button("Help", |ui| {
                if sc(ui, "Keyboard Shortcuts...", "") {
                    cmds.push(Command::OpenSettings);

                }
            });
        });
    });

    if open_file {
        open_file_dialog(app);
    }
    if save_file {
        save_active(app);
    }
    if save_as {
        save_as_dialog(app);
    }
    if save_all {
        let paths: Vec<(usize, std::path::PathBuf)> = app
            .state
            .documents
            .iter()
            .enumerate()
            .filter_map(|(i, d)| match &d.origin {
                Origin::File(p) => Some((i, p.clone())),
                _ => None,
            })
            .collect();
        let prev_active = app.state.active_doc;
        for (i, path) in paths {
            app.state.active_doc = i;
            let _ = app.save_to_path(&path);
        }
        app.state.active_doc = prev_active;
    }
    if export_spice {
        export_spice_dialog(app);
    }
    if open_wave {
        crate::wave_view::open_viewer(app);
    }
    if new_optimizer {
        crate::optimizer_view::open_new(app);
    }
    if let Some(mode) = new_view_mode {
        app.state.view.view_mode = mode;
    }
    for cmd in cmds {
        app.dispatch(cmd).or_status(app);
    }
}
