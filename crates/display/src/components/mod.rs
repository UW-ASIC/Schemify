//! Chrome (menu bar, tab bar, status bar with vim command line), floating
//! panels (file explorer, library browser), the right-click context menu,
//! and all dialogs (properties, find, settings, import, SPICE code, new
//! primitive).
//
// deferred: math_render / LaTeX in doc view — later phase
// deferred: highlight.rs (SPICE/LaTeX syntax highlighting) — later phase

pub mod plugin_panels;

use eframe::egui;

use schemify_core::handler::{App, ObjectRef, Origin, ViewMode};
use schemify_core::schemify::{Color, Command, SpiceBackend, StimulusLang, Tool, PRIMITIVES};

use schemify_marketplace::Marketplace;
use schemify_plugins::PluginLifecycle;

use crate::handler::execute_vim_command;
use crate::keybinds::KEYBINDS;
use crate::plugin_host::PluginHost;
use crate::state::{CtxHit, GuiState, LibrarySection};

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
        });
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
    ctx: &egui::Context,
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

    egui::TopBottomPanel::top("menu_bar").show(ctx, |ui| {
        egui::menu::bar(ui, |ui| {
            // ── File ──
            ui.menu_button("File", |ui| {
                if sc(ui, "New Schematic", "Ctrl+N") {
                    cmds.push(Command::FileNew);
                    ui.close_menu();
                }
                if sc(ui, "New Primitive...", "") {
                    cmds.push(Command::OpenNewPrimDialog);
                    ui.close_menu();
                }
                if sc(ui, "Open...", "Ctrl+O") {
                    open_file = true;
                    ui.close_menu();
                }
                if sc(ui, "Import Netlist...", "") {
                    cmds.push(Command::OpenImportDialog);
                    ui.close_menu();
                }
                if sc(ui, "Reload from Disk", "") {
                    cmds.push(Command::ReloadFromDisk);
                    ui.close_menu();
                }
                ui.separator();
                if sc(ui, "Save", "Ctrl+S") {
                    save_file = true;
                    ui.close_menu();
                }
                if sc(ui, "Save As...", "Ctrl+Shift+S") {
                    save_as = true;
                    ui.close_menu();
                }
                if sc(ui, "Save All", "") {
                    save_all = true;
                    ui.close_menu();
                }
                ui.separator();
                ui.menu_button("Export", |ui| {
                    if sc(ui, "Export SPICE...", "") {
                        export_spice = true;
                        ui.close_menu();
                    }
                    if sc(ui, "Export Netlist", "") {
                        cmds.push(Command::ExportNetlist);
                        ui.close_menu();
                    }
                });
                ui.separator();
                if sc(ui, "New Tab", "Ctrl+T") {
                    cmds.push(Command::NewTab);
                    ui.close_menu();
                }
                if sc(ui, "Close Tab", "Ctrl+W") {
                    cmds.push(Command::CloseTab(active_idx));
                    ui.close_menu();
                }
            });

            // ── Edit ──
            ui.menu_button("Edit", |ui| {
                if en(ui, "Undo", "Ctrl+Z", can_undo) {
                    cmds.push(Command::Undo);
                    ui.close_menu();
                }
                if en(ui, "Redo", "Ctrl+Y", can_redo) {
                    cmds.push(Command::Redo);
                    ui.close_menu();
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
                        ui.close_menu();
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
                        ui.close_menu();
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
                        ui.close_menu();
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
                            ui.close_menu();
                        }
                    }
                });
                ui.separator();
                if sc(ui, "Properties...", "Q") {
                    cmds.push(Command::OpenPropsDialog);
                    ui.close_menu();
                }
                if sc(ui, "Spice Code...", "") {
                    cmds.push(Command::OpenSpiceCodeEditor);
                    ui.close_menu();
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
                        ui.close_menu();
                    }
                }
                ui.separator();
                if tog(ui, "Grid", "G", grid_on) {
                    cmds.push(Command::ToggleGrid);
                    ui.close_menu();
                }
                if tog(ui, "Crosshair", "", gui.crosshair) {
                    gui.crosshair = !gui.crosshair;
                    ui.close_menu();
                }
                if tog(ui, "Fill Shapes", "", gui.fill_rects) {
                    gui.fill_rects = !gui.fill_rects;
                    ui.close_menu();
                }
                if tog(ui, "Dark Mode", "", app.state.view.dark_mode) {
                    cmds.push(Command::ToggleColorScheme);
                    ui.close_menu();
                }
                ui.separator();
                for (label, mode) in [
                    ("Schematic View", ViewMode::Schematic),
                    ("Symbol View", ViewMode::Symbol),
                    ("Documentation View", ViewMode::Documentation),
                ] {
                    if tog(ui, label, "", view_mode == mode) {
                        new_view_mode = Some(mode);
                        ui.close_menu();
                    }
                }
                ui.separator();
                if sc(ui, "Library Browser", "I") {
                    cmds.push(Command::OpenLibraryBrowser);
                    ui.close_menu();
                }
                if sc(ui, "File Explorer", "") {
                    cmds.push(Command::OpenFileExplorer);
                    ui.close_menu();
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
                        ui.close_menu();
                    }
                }
                ui.separator();
                if sc(ui, "Wire", "W") {
                    cmds.push(Command::SetTool(Tool::Wire));
                    ui.close_menu();
                }
                if tog(ui, "Bus", "B", bus_active) {
                    cmds.push(Command::SetTool(Tool::Bus));
                    ui.close_menu();
                }
                if sc(ui, "Bus Ripper", "") {
                    cmds.push(Command::SetTool(Tool::BusRipper));
                    ui.close_menu();
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
                        ui.close_menu();
                    }
                }
                ui.separator();
                if sc(ui, "Insert from Library...", "I") {
                    cmds.push(Command::OpenLibraryBrowser);
                    ui.close_menu();
                }
            });

            // ── Simulate ──
            ui.menu_button("Simulate", |ui| {
                if sc(ui, "Run Simulation", "F5") {
                    cmds.push(Command::RunSim);
                    ui.close_menu();
                }
                ui.menu_button("Backend", |ui| {
                    for be in [SpiceBackend::NgSpice, SpiceBackend::Xyce] {
                        if tog(ui, be.as_str(), "", sim_backend == be) {
                            cmds.push(Command::SetSimBackend(be.as_str().to_string()));
                            ui.close_menu();
                        }
                    }
                });
                ui.menu_button("Stimulus Language", |ui| {
                    for lang in StimulusLang::ALL {
                        if tog(ui, lang.as_str(), "", stimulus_lang == *lang) {
                            cmds.push(Command::SetStimulusLang(lang.as_str().to_string()));
                            ui.close_menu();
                        }
                    }
                });
                if let Some((corners, current, default)) = &corner_info {
                    ui.menu_button("Corner", |ui| {
                        for c in corners {
                            let active = if current.is_empty() { c == default } else { c == current };
                            if tog(ui, c, "", active) {
                                cmds.push(Command::SetSimCorner(c.clone()));
                                ui.close_menu();
                            }
                        }
                    });
                }
                ui.separator();
                if sc(ui, "Waveform Viewer", "") {
                    open_wave = true;
                    ui.close_menu();
                }
                if sc(ui, "New Optimizer", "") {
                    // Every activation opens a NEW instance (own window).
                    new_optimizer = true;
                    ui.close_menu();
                }
                if sc(ui, "Spice Code...", "") {
                    cmds.push(Command::OpenSpiceCodeEditor);
                    ui.close_menu();
                }
                if sc(ui, "Export Netlist", "") {
                    cmds.push(Command::ExportNetlist);
                    ui.close_menu();
                }
            });

            // ── Plugins ──
            ui.menu_button("Plugins", |ui| {
                if sc(ui, "Marketplace...", "") {
                    cmds.push(Command::OpenMarketplace);
                    ui.close_menu();
                }
                if sc(ui, "Refresh Plugins", "F6") {
                    cmds.push(Command::PluginsRefresh);
                    ui.close_menu();
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
                                    ui.close_menu();
                                }
                            }
                            _ => {
                                if sc(ui, "Start", "") {
                                    if let Err(e) = plugins.manager.start(id) {
                                        app.state.status_msg = e.to_string();
                                    }
                                    ui.close_menu();
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
                                ui.close_menu();
                            }
                        }
                    });
                }
            });

            // ── Help ──
            ui.menu_button("Help", |ui| {
                if sc(ui, "Keyboard Shortcuts...", "") {
                    cmds.push(Command::OpenSettings);
                    ui.close_menu();
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
        app.dispatch(cmd);
    }
}

// ════════════════════════════════════════════════════════════
// Tab bar
// ════════════════════════════════════════════════════════════

pub fn tab_bar(ctx: &egui::Context, app: &mut App) {
    let doc_info: Vec<(String, bool)> = app
        .state
        .documents
        .iter()
        .map(|d| (d.display_name(), d.dirty))
        .collect();
    let active = app.state.active_doc;
    let tab_count = doc_info.len();
    let view_mode = app.state.view.view_mode;

    let mut cmd = None;
    let mut new_view_mode: Option<ViewMode> = None;

    egui::TopBottomPanel::top("tab_bar").show(ctx, |ui| {
        ui.horizontal(|ui| {
            let tab_h = ui.spacing().interact_size.y;
            let slant = tab_h * 0.4; // chevron tip depth

            // Reserve room on the right for "+" and the SCH/SYM/DOC toggle so
            // tabs always compress before reaching them.
            let reserved_right = 160.0;
            let avail = (ui.available_width() - reserved_right - slant).max(0.0);
            let tab_w = (avail / tab_count.max(1) as f32).clamp(24.0, 180.0);

            // Tabs interlock: each chevron tip fills the next tab's notch.
            ui.spacing_mut().item_spacing.x = 0.0;

            for (i, (name, dirty)) in doc_info.iter().enumerate() {
                let is_active = i == active;

                let (rect, response) =
                    ui.allocate_exact_size(egui::vec2(tab_w, tab_h), egui::Sense::click());

                // Close button (left side, hover-only). Hit-test it before
                // painting so the tab can react to its hover state.
                let can_close = tab_count > 1;
                let close_size = 12.0;
                let lslant = if i > 0 { slant } else { 0.0 };
                let close_center =
                    egui::pos2(rect.min.x + lslant + close_size * 0.5 + 4.0, rect.center().y);
                let close_rect =
                    egui::Rect::from_center_size(close_center, egui::vec2(close_size, close_size));
                let close_resp = can_close.then(|| {
                    ui.interact(close_rect, response.id.with("close"), egui::Sense::click())
                });
                let close_hovered = close_resp.as_ref().is_some_and(|r| r.hovered());

                // Chevron outline: straight left edge on the first tab, a
                // notch on the rest; arrow tip on the right of every tab.
                let (top, bottom, mid) = (rect.min.y, rect.max.y, rect.center().y);
                let (x0, x1) = (rect.min.x, rect.max.x);
                let bg = if is_active {
                    ui.visuals().selection.bg_fill
                } else if response.hovered() {
                    ui.visuals().widgets.hovered.bg_fill
                } else {
                    ui.visuals().widgets.noninteractive.weak_bg_fill
                };
                // Fill as two convex quads (the notch makes the full outline
                // concave, which egui's tessellator can't fill directly).
                let stroke = egui::Stroke::NONE;
                ui.painter().add(egui::Shape::convex_polygon(
                    vec![
                        egui::pos2(x0, top),
                        egui::pos2(x1, top),
                        egui::pos2(x1 + slant, mid),
                        egui::pos2(x0 + lslant, mid),
                    ],
                    bg,
                    stroke,
                ));
                ui.painter().add(egui::Shape::convex_polygon(
                    vec![
                        egui::pos2(x0 + lslant, mid - 0.5),
                        egui::pos2(x1 + slant, mid - 0.5),
                        egui::pos2(x1, bottom),
                        egui::pos2(x0, bottom),
                    ],
                    bg,
                    stroke,
                ));
                // Right-edge seam between tabs.
                let edge = ui.visuals().widgets.noninteractive.bg_stroke;
                ui.painter().add(egui::Shape::line(
                    vec![
                        egui::pos2(x1, top),
                        egui::pos2(x1 + slant, mid),
                        egui::pos2(x1, bottom),
                    ],
                    edge,
                ));

                // Left slot: red close cross when hovered, dirty dot otherwise.
                let text_color = if is_active {
                    ui.visuals().strong_text_color()
                } else {
                    ui.visuals().text_color()
                };
                if can_close && (response.hovered() || close_hovered) {
                    let red = if close_hovered {
                        egui::Color32::from_rgb(230, 60, 60)
                    } else {
                        egui::Color32::from_rgb(190, 80, 80)
                    };
                    if close_hovered {
                        ui.painter().circle_filled(
                            close_center,
                            close_size * 0.7,
                            red.gamma_multiply(0.25),
                        );
                    }
                    let r = close_size * 0.3;
                    let cross = egui::Stroke::new(1.5_f32, red);
                    ui.painter().line_segment(
                        [close_center + egui::vec2(-r, -r), close_center + egui::vec2(r, r)],
                        cross,
                    );
                    ui.painter().line_segment(
                        [close_center + egui::vec2(-r, r), close_center + egui::vec2(r, -r)],
                        cross,
                    );
                } else if *dirty {
                    ui.painter().circle_filled(close_center, 3.0, text_color);
                }

                // Title, clipped to the body of the chevron.
                let text_left = if can_close || *dirty {
                    close_rect.max.x + 4.0
                } else {
                    x0 + lslant + 6.0
                };
                let text_rect = egui::Rect::from_min_max(
                    egui::pos2(text_left, top),
                    egui::pos2(x1 - 2.0, bottom),
                );
                ui.painter().with_clip_rect(text_rect).text(
                    text_rect.left_center(),
                    egui::Align2::LEFT_CENTER,
                    name,
                    egui::FontId::proportional(13.0),
                    text_color,
                );
                response.clone().on_hover_text(name);

                if close_resp.is_some_and(|r| r.clicked()) {
                    cmd = Some(Command::CloseTab(i));
                } else if response.clicked() && !is_active {
                    cmd = Some(Command::SwitchTab(i));
                }
            }

            ui.add_space(slant + 6.0);
            if ui.small_button("+").on_hover_text("New Tab").clicked() {
                cmd = Some(Command::NewTab);
            }

            // View mode toggle (right-aligned).
            ui.spacing_mut().item_spacing.x = 4.0;
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                for (label, mode) in [
                    ("DOC", ViewMode::Documentation),
                    ("SYM", ViewMode::Symbol),
                    ("SCH", ViewMode::Schematic),
                ] {
                    if ui.selectable_label(view_mode == mode, label).clicked() {
                        new_view_mode = Some(mode);
                    }
                }
            });
        });
    });

    if let Some(c) = cmd {
        app.dispatch(c);
    }
    if let Some(mode) = new_view_mode {
        app.state.view.view_mode = mode;
    }
}

// ════════════════════════════════════════════════════════════
// Status bar (normal + vim command mode)
// ════════════════════════════════════════════════════════════

pub fn status_bar(ctx: &egui::Context, app: &mut App, gui: &mut GuiState) {
    egui::TopBottomPanel::bottom("status_bar").show(ctx, |ui| {
        ui.horizontal(|ui| {
            if gui.command_mode {
                show_command_mode(ui, app, gui);
            } else {
                show_normal_status(ui, app);
            }
        });
    });
}

fn show_normal_status(ui: &mut egui::Ui, app: &App) {
    let cursor = app.state.canvas.cursor_world;
    let zoom = app.active_doc().viewport.zoom;

    if !app.state.status_msg.is_empty() {
        ui.label(&app.state.status_msg);
        ui.separator();
    }
    ui.label(format!("({}, {})", cursor[0], cursor[1]));
    ui.separator();
    ui.label(format!("{:?}", app.state.tool.active));
    ui.separator();
    ui.label(format!("snap: {}", app.state.tool.snap_size as i32));
    ui.separator();
    ui.label(match app.state.view.view_mode {
        ViewMode::Schematic => "SCH",
        ViewMode::Symbol => "SYM",
        ViewMode::Documentation => "DOC",
    });
    ui.separator();
    ui.weak(": for commands");
    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
        ui.label(format!("{:.0}%", zoom * 100.0));
    });
}

fn show_command_mode(ui: &mut egui::Ui, app: &mut App, gui: &mut GuiState) {
    ui.label(":");
    let response = ui.add(
        egui::TextEdit::singleline(&mut gui.command_buf)
            .desired_width(ui.available_width() - 180.0)
            .hint_text("command"),
    );
    if !response.has_focus() {
        response.request_focus();
    }
    gui.text_entry_focused = true;

    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
        ui.weak("Enter to run | Esc to cancel");
    });

    // Read keys via the input system: the TextEdit consumes the key events.
    let (enter, escape) = ui.ctx().input(|i| {
        (i.key_pressed(egui::Key::Enter), i.key_pressed(egui::Key::Escape))
    });

    if enter {
        let line = std::mem::take(&mut gui.command_buf);
        gui.command_mode = false;
        gui.text_entry_focused = false;
        execute_vim_command(&line, app, gui);
    } else if escape {
        gui.command_buf.clear();
        gui.command_mode = false;
        gui.text_entry_focused = false;
    }
}

// ════════════════════════════════════════════════════════════
// Label conflict overlay
// ════════════════════════════════════════════════════════════

pub fn label_conflict_overlay(ctx: &egui::Context, app: &mut App) {
    let conflicts: Vec<usize> = app.connectivity().label_conflicts.iter().copied().collect();
    if conflicts.is_empty() {
        return;
    }

    let sch = app.schematic();
    let mut names: Vec<&str> = conflicts
        .iter()
        .filter(|&&idx| idx < sch.instances.len())
        .map(|&idx| app.resolve(sch.instances.name[idx]))
        .collect();
    names.sort_unstable();
    names.dedup();
    let label_list = names.join(", ");

    let screen = ctx.screen_rect();
    egui::Area::new(egui::Id::new("label_conflict_warn"))
        .fixed_pos(egui::pos2(screen.right() - 340.0, screen.bottom() - 60.0))
        .order(egui::Order::Foreground)
        .show(ctx, |ui| {
            egui::Frame::new()
                .fill(egui::Color32::from_rgba_premultiplied(80, 20, 20, 220))
                .corner_radius(6.0)
                .inner_margin(egui::Margin::same(8))
                .show(ui, |ui| {
                    ui.label(
                        egui::RichText::new(format!(
                            "\u{26A0} Conflicting net labels: {label_list}"
                        ))
                        .color(egui::Color32::from_rgb(255, 200, 200))
                        .size(13.0),
                    );
                });
        });
}

// ════════════════════════════════════════════════════════════
// Welcome screen
// ════════════════════════════════════════════════════════════

pub fn welcome(ui: &mut egui::Ui, app: &mut App) {
    let mut cmds: Vec<Command> = Vec::new();
    let mut open_file = false;
    let avail = ui.available_size();

    ui.vertical_centered(|ui| {
        ui.add_space((avail.y * 0.25).max(40.0));
        ui.label(egui::RichText::new("Schemify").size(32.0).strong());
        ui.add_space(4.0);
        ui.weak("Schematic Editor");
        ui.add_space(32.0);
        ui.weak("Quick Actions");
        ui.add_space(8.0);

        ui.horizontal(|ui| {
            ui.add_space((avail.x * 0.5 - 200.0).max(0.0));
            if ui.button("  New Schematic  Ctrl+N  ").clicked() {
                cmds.push(Command::FileNew);
            }
            if ui.button("  Open File  Ctrl+O  ").clicked() {
                open_file = true;
            }
            if ui.button("  Import Netlist  ").clicked() {
                cmds.push(Command::OpenImportDialog);
            }
        });

        ui.add_space(32.0);
        ui.separator();
        ui.add_space(32.0);
        ui.weak("Press : for command mode  |  Ctrl+O to open  |  Ctrl+N for new schematic");
    });

    if open_file {
        open_file_dialog(app);
    }
    for cmd in cmds {
        app.dispatch(cmd);
    }
}

// ════════════════════════════════════════════════════════════
// Documentation view (simple markdown; LaTeX math deferred)
// ════════════════════════════════════════════════════════════

pub fn doc_view(ui: &mut egui::Ui, app: &mut App, gui: &mut GuiState) {
    if !gui.doc_loaded {
        gui.doc_buf = app.schematic().documentation.clone();
        gui.doc_loaded = true;
    }

    let mut save_requested = false;
    ui.horizontal(|ui| {
        if ui.button("Save").clicked() {
            save_requested = true;
        }
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            ui.weak(format!("{} words", gui.doc_buf.split_whitespace().count()));
        });
    });
    ui.separator();

    // Editor on top, rendered view always live in a resizable bottom pane.
    // The bottom panel must be laid out before the central editor fills
    // the rest.
    egui::TopBottomPanel::bottom("doc_preview_pane")
        .resizable(true)
        .default_height(ui.available_height() * 0.45)
        .show_inside(ui, |ui| {
            // Live value refs: {{R1}} / {{R1.value}} re-expand every
            // frame, so schematic edits show up immediately. Expansion
            // runs before math conversion, so refs inside $...$ work.
            let rendered = schemify_core::handler::expand_doc_vars(
                &gui.doc_buf,
                app.schematic(),
                &app.state.interner,
            );
            egui::ScrollArea::vertical()
                .id_salt("doc_preview_scroll")
                .auto_shrink([false, false])
                .show(ui, |ui| {
                    render_simple_markdown(ui, &mut gui.doc_math_cache, &rendered);
                });
        });
    egui::CentralPanel::default().show_inside(ui, |ui| {
        egui::ScrollArea::vertical()
            .id_salt("doc_edit_scroll")
            .auto_shrink([false, false])
            .show(ui, |ui| {
                ui.add(
                    egui::TextEdit::multiline(&mut gui.doc_buf)
                        .font(egui::FontId::monospace(14.0))
                        .desired_width(f32::INFINITY)
                        .desired_rows(30),
                );
            });
    });

    if save_requested {
        app.dispatch(Command::SetDocumentation(gui.doc_buf.clone()));
    }
}

/// LaTeX → PNG render cache; `Err` keeps the parse error for display.
pub type MathCache = std::collections::HashMap<u64, Result<std::sync::Arc<[u8]>, String>>;

fn render_simple_markdown(ui: &mut egui::Ui, cache: &mut MathCache, text: &str) {
    let mut in_code_block = false;
    let mut math_block: Option<String> = None;
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("```") {
            in_code_block = !in_code_block;
            ui.add_space(4.0);
            continue;
        }
        if in_code_block {
            ui.label(egui::RichText::new(line).monospace());
            continue;
        }
        // $$ … $$ display math: single-line or accumulated block.
        if let Some(buf) = &mut math_block {
            if trimmed == "$$" {
                let expr = std::mem::take(buf);
                math_block = None;
                display_math(ui, cache, expr.trim());
            } else {
                buf.push_str(line);
                buf.push(' ');
            }
            continue;
        }
        if trimmed == "$$" {
            math_block = Some(String::new());
            continue;
        }
        if trimmed.len() > 4 && trimmed.starts_with("$$") && trimmed.ends_with("$$") {
            display_math(ui, cache, trimmed[2..trimmed.len() - 2].trim());
            continue;
        }
        if trimmed.is_empty() {
            ui.add_space(8.0);
        } else if let Some(h) = trimmed.strip_prefix("### ") {
            ui.label(egui::RichText::new(h).strong().size(15.0));
        } else if let Some(h) = trimmed.strip_prefix("## ") {
            ui.label(egui::RichText::new(h).strong().size(18.0));
        } else if let Some(h) = trimmed.strip_prefix("# ") {
            ui.heading(h);
        } else if let Some(item) = trimmed.strip_prefix("- ").or(trimmed.strip_prefix("* ")) {
            ui.horizontal_wrapped(|ui| {
                ui.label("  \u{2022}");
                math_line(ui, cache, item);
            });
        } else {
            math_line_wrapped(ui, cache, line);
        }
    }
    if let Some(buf) = math_block {
        // Unterminated $$ block: render what we have.
        display_math(ui, cache, buf.trim());
    }
}

// ── LaTeX math (RaTeX: parse → layout → display list → PNG) ──

/// Render `$…$` segments of a paragraph line inline with the text.
fn math_line_wrapped(ui: &mut egui::Ui, cache: &mut MathCache, line: &str) {
    if !line.contains('$') {
        ui.label(line);
        return;
    }
    ui.horizontal_wrapped(|ui| math_line(ui, cache, line));
}

/// Emit alternating text / inline-math segments split on `$`.
fn math_line(ui: &mut egui::Ui, cache: &mut MathCache, line: &str) {
    let mut rest = line;
    loop {
        let Some(i) = rest.find('$') else {
            if !rest.is_empty() {
                ui.label(rest);
            }
            return;
        };
        let after = &rest[i + 1..];
        let Some(j) = after.find('$') else {
            // Unpaired $: literal.
            ui.label(rest);
            return;
        };
        if i > 0 {
            ui.label(&rest[..i]);
        }
        math_image(ui, cache, after[..j].trim(), false);
        rest = &after[j + 1..];
    }
}

fn display_math(ui: &mut egui::Ui, cache: &mut MathCache, expr: &str) {
    if expr.is_empty() {
        return;
    }
    ui.add_space(4.0);
    ui.vertical_centered(|ui| math_image(ui, cache, expr, true));
    ui.add_space(4.0);
}

/// Cached RaTeX render of one expression, drawn as an egui image.
fn math_image(ui: &mut egui::Ui, cache: &mut MathCache, expr: &str, display: bool) {
    use std::hash::{Hash, Hasher};

    let color = ui.visuals().text_color();
    let dpr = ui.ctx().pixels_per_point().max(1.0) * 2.0; // 2x for crispness
    let mut h = std::collections::hash_map::DefaultHasher::new();
    (expr, display, color.to_array(), dpr.to_bits()).hash(&mut h);
    let key = h.finish();

    let entry = cache
        .entry(key)
        .or_insert_with(|| render_math_png(expr, display, color, dpr).map(Into::into));
    match entry {
        Ok(png) => {
            ui.add(
                egui::Image::from_bytes(
                    format!("bytes://doc-math-{key:016x}.png"),
                    egui::load::Bytes::Shared(png.clone()),
                )
                .fit_to_original_size(1.0 / dpr),
            );
        }
        Err(e) => {
            ui.label(
                egui::RichText::new(format!("${expr}$"))
                    .monospace()
                    .color(egui::Color32::LIGHT_RED),
            )
            .on_hover_text(e.clone());
        }
    }
}

fn render_math_png(
    expr: &str,
    display: bool,
    color: egui::Color32,
    dpr: f32,
) -> Result<Vec<u8>, String> {
    use ratex_types::math_style::MathStyle;

    let ast = ratex_parser::parser::parse(expr).map_err(|e| format!("{e}"))?;
    let style = if display { MathStyle::Display } else { MathStyle::Text };
    let col = ratex_types::color::Color::new(
        color.r() as f32 / 255.0,
        color.g() as f32 / 255.0,
        color.b() as f32 / 255.0,
        1.0,
    );
    let opts = ratex_layout::LayoutOptions::default()
        .with_style(style)
        .with_color(col);
    let lbox = ratex_layout::layout(&ast, &opts);
    let dl = ratex_layout::to_display_list(&lbox);
    ratex_render::render_to_png(
        &dl,
        &ratex_render::RenderOptions {
            font_size: if display { 19.0 } else { 14.0 },
            padding: if display { 4.0 } else { 1.0 },
            background_color: ratex_types::color::Color::new(0.0, 0.0, 0.0, 0.0),
            font_dir: String::new(),
            device_pixel_ratio: dpr,
        },
    )
}

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
                            ui.add_enabled(false, egui::SelectableLabel::new(false, name.as_str()))
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

// ════════════════════════════════════════════════════════════
// Context menu
// ════════════════════════════════════════════════════════════

pub fn context_menu(ctx: &egui::Context, app: &mut App, gui: &mut GuiState) {
    if !gui.ctx_menu.open {
        return;
    }
    let cm = gui.ctx_menu.clone();

    let mut cmds: Vec<Command> = Vec::new();
    let mut close = false;
    let mut bus_rename = cm.bus_rename.clone();
    let mut bus_width = cm.bus_width;

    let sel_count = app.active_doc().selection.len();
    let has_selection = sel_count > 0;
    let has_instance = matches!(cm.hit, CtxHit::Obj(ObjectRef::Instance(_)));
    let has_hit = cm.hit != CtxHit::None;
    let is_group = sel_count > 1;
    let is_canvas = !has_selection && !has_hit;

    egui::Area::new(egui::Id::new("context_menu"))
        .fixed_pos(egui::pos2(cm.pixel_pos[0], cm.pixel_pos[1]))
        .order(egui::Order::Foreground)
        .show(ctx, |ui| {
            egui::Frame::menu(ui.style()).show(ui, |ui| {
                ui.set_min_width(160.0);

                let item = |ui: &mut egui::Ui, label: &str, enabled: bool| -> bool {
                    ui.add_enabled(enabled, egui::Button::new(label)).clicked()
                };

                if is_canvas {
                    if item(ui, "Paste", true) {
                        cmds.push(Command::Paste);
                        close = true;
                    }
                    if item(ui, "Insert from Library...", true) {
                        cmds.push(Command::OpenLibraryBrowser);
                        close = true;
                    }
                    ui.separator();
                    if item(ui, "Select All", true) {
                        cmds.push(Command::SelectAll);
                        close = true;
                    }
                } else if is_group {
                    ui.label(
                        egui::RichText::new(format!("{sel_count} items selected"))
                            .strong()
                            .small(),
                    );
                    ui.separator();
                    for (label, cmd) in [
                        ("Delete All", Command::DeleteSelected),
                        ("Rotate All CW", Command::RotateCw),
                        ("Flip All Horizontal", Command::FlipHorizontal),
                        ("Duplicate All", Command::DuplicateSelected),
                    ] {
                        if item(ui, label, true) {
                            cmds.push(cmd);
                            close = true;
                        }
                    }
                } else {
                    for (label, cmd, need_sel) in [
                        ("Cut", Command::Cut, true),
                        ("Copy", Command::Copy, true),
                        ("Paste", Command::Paste, false),
                        ("Delete", Command::DeleteSelected, true),
                        ("Duplicate", Command::DuplicateSelected, true),
                    ] {
                        if item(ui, label, !need_sel || has_selection) {
                            cmds.push(cmd);
                            close = true;
                        }
                    }
                    ui.separator();
                    for (label, cmd) in [
                        ("Rotate CW", Command::RotateCw),
                        ("Flip Horizontal", Command::FlipHorizontal),
                    ] {
                        if item(ui, label, has_selection) {
                            cmds.push(cmd);
                            close = true;
                        }
                    }
                    if has_instance {
                        ui.separator();
                        if item(ui, "Properties...", true) {
                            cmds.push(Command::OpenPropsDialog);
                            close = true;
                        }
                    }
                }

                // Wire-specific section.
                if let CtxHit::Obj(ObjectRef::Wire(wire_idx)) = cm.hit {
                    let wire_idx = wire_idx as usize;
                    ui.separator();
                    ui.label(egui::RichText::new("Wire").strong().small());
                    if item(ui, "Delete Wire", true) {
                        cmds.push(Command::DeleteWire(wire_idx));
                        close = true;
                    }
                    if item(ui, "Split Wire Here", true) {
                        cmds.push(Command::SplitWire {
                            idx: wire_idx,
                            x: cm.world_pos[0],
                            y: cm.world_pos[1],
                        });
                        close = true;
                    }
                    ui.menu_button("Set Color", |ui| {
                        let colors: &[(&str, Color)] = &[
                            ("Default", Color::NONE),
                            ("Red", Color::rgb(239, 83, 80)),
                            ("Green", Color::rgb(102, 187, 106)),
                            ("Blue", Color::rgb(79, 195, 247)),
                            ("Yellow", Color::rgb(255, 235, 59)),
                            ("Orange", Color::rgb(255, 167, 38)),
                            ("Purple", Color::rgb(171, 71, 188)),
                            ("Cyan", Color::rgb(38, 198, 218)),
                            ("White", Color::rgb(255, 255, 255)),
                        ];
                        for &(name, color) in colors {
                            if ui.button(name).clicked() {
                                cmds.push(Command::SetWireColor { idx: wire_idx, color });
                                close = true;
                                ui.close_menu();
                            }
                        }
                    });
                }

                // Bus-specific section (inline editors).
                if let CtxHit::Obj(ObjectRef::Bus(bus_idx)) = cm.hit {
                    let bus_idx = bus_idx as usize;
                    ui.separator();
                    ui.label(egui::RichText::new("Bus").strong().small());
                    ui.horizontal(|ui| {
                        ui.label("Label");
                        ui.text_edit_singleline(&mut bus_rename);
                    });
                    ui.horizontal(|ui| {
                        ui.label("Width");
                        ui.add(egui::DragValue::new(&mut bus_width).range(1..=512));
                    });
                    if item(ui, "Apply", true) {
                        cmds.push(Command::RenameBus {
                            idx: bus_idx,
                            new_name: bus_rename.clone(),
                        });
                        cmds.push(Command::SetBusWidth {
                            idx: bus_idx,
                            width: bus_width,
                        });
                        close = true;
                    }
                    if item(ui, "Delete Bus", true) {
                        cmds.push(Command::DeleteBus(bus_idx));
                        close = true;
                    }
                }

                if let CtxHit::BusRipper(r_idx) = cm.hit {
                    ui.separator();
                    ui.label(egui::RichText::new("Bus Ripper").strong().small());
                    if item(ui, "Delete Ripper", true) {
                        cmds.push(Command::DeleteBusRipper(r_idx));
                        close = true;
                    }
                }
            });

            // Close on click outside.
            if ui.input(|i| i.pointer.any_click()) && !ui.rect_contains_pointer(ui.min_rect()) {
                close = true;
            }
        });

    if ctx.input(|i| i.key_pressed(egui::Key::Escape)) {
        close = true;
    }

    gui.ctx_menu.bus_rename = bus_rename;
    gui.ctx_menu.bus_width = bus_width;
    if close {
        gui.ctx_menu.open = false;
    }
    for cmd in cmds {
        app.dispatch(cmd);
    }
}

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

// ── Marketplace ────────────────────────────────────────────

fn marketplace_dialog(
    ctx: &egui::Context,
    app: &mut App,
    gui: &mut GuiState,
    marketplace: &mut Marketplace,
) {
    if !app.state.dialogs.marketplace_open {
        return;
    }

    let mkt = &mut gui.marketplace;

    if !mkt.fetched {
        match marketplace.fetch_index() {
            Ok(_) => {
                mkt.results = marketplace.search("");
                mkt.status = format!("{} plugins available", mkt.results.len());
            }
            Err(e) => {
                mkt.status = format!("Failed to fetch registry: {e}");
            }
        }
        mkt.fetched = true;
    }

    let mut is_open = true;

    egui::Window::new("\u{1f4e6} Marketplace")
        .open(&mut is_open)
        .resizable(true)
        .default_size([720.0, 520.0])
        .min_size([480.0, 320.0])
        .show(ctx, |ui| {
            // Search bar
            ui.horizontal(|ui| {
                ui.label("Search:");
                let resp = ui.text_edit_singleline(&mut mkt.search_query);
                if resp.changed() {
                    mkt.results = marketplace.search(&mkt.search_query);
                    mkt.selected = None;
                }
                if ui.button("\u{21bb} Refresh").clicked() {
                    mkt.fetched = false;
                }
            });

            ui.add_space(4.0);

            // Status line
            ui.horizontal(|ui| {
                ui.label(
                    egui::RichText::new(&mkt.status)
                        .small()
                        .color(egui::Color32::GRAY),
                );
            });

            ui.separator();

            // Two-panel layout: list on left, detail on right
            let available = ui.available_size();
            let list_width = (available.x * 0.4).max(200.0).min(320.0);

            ui.horizontal(|ui| {
                // ── Left: plugin list ──
                ui.vertical(|ui| {
                    ui.set_width(list_width);
                    egui::ScrollArea::vertical()
                        .max_height(available.y - 8.0)
                        .show(ui, |ui| {
                            for (i, result) in mkt.results.iter().enumerate() {
                                let is_selected = mkt.selected == Some(i);
                                let entry = &result.entry;

                                let label = if result.installed {
                                    format!(
                                        "{}\n{}",
                                        entry.name,
                                        truncate_desc(&entry.description, 50),
                                    )
                                } else {
                                    format!(
                                        "{}\n{}",
                                        entry.name,
                                        truncate_desc(&entry.description, 50),
                                    )
                                };

                                let resp = ui.selectable_label(
                                    is_selected,
                                    egui::RichText::new(&label),
                                );

                                // Paint an "installed" badge on the right
                                if result.installed {
                                    ui.painter().text(
                                        resp.rect.right_center() - egui::vec2(8.0, 0.0),
                                        egui::Align2::RIGHT_CENTER,
                                        "\u{2713}",
                                        egui::FontId::proportional(14.0),
                                        egui::Color32::from_rgb(80, 200, 120),
                                    );
                                }

                                if resp.clicked() {
                                    mkt.selected = Some(i);
                                }
                            }

                            if mkt.results.is_empty() {
                                ui.label(
                                    egui::RichText::new("No plugins found")
                                        .color(egui::Color32::GRAY)
                                        .italics(),
                                );
                            }
                        });
                });

                ui.separator();

                // ── Right: detail pane ──
                ui.vertical(|ui| {
                    if let Some(idx) = mkt.selected {
                        if let Some(result) = mkt.results.get(idx).cloned() {
                            let entry = &result.entry;

                            // Header
                            ui.heading(&entry.name);
                            ui.horizontal(|ui| {
                                ui.label(
                                    egui::RichText::new(format!("v{}", entry.version))
                                        .color(egui::Color32::GRAY),
                                );
                                if !entry.author.is_empty() {
                                    ui.label("\u{2022}");
                                    ui.label(&entry.author);
                                }
                                if !entry.license.is_empty() {
                                    ui.label("\u{2022}");
                                    ui.label(
                                        egui::RichText::new(&entry.license)
                                            .color(egui::Color32::GRAY),
                                    );
                                }
                            });

                            ui.add_space(8.0);

                            // Description
                            ui.label(&entry.description);

                            ui.add_space(12.0);

                            // Capabilities
                            if !entry.capabilities.is_empty() {
                                ui.label(egui::RichText::new("Capabilities").strong());
                                ui.horizontal_wrapped(|ui| {
                                    for cap in &entry.capabilities {
                                        ui.label(
                                            egui::RichText::new(format!(" {cap} "))
                                                .background_color(egui::Color32::from_rgb(
                                                    50, 50, 70,
                                                ))
                                                .color(egui::Color32::from_rgb(180, 180, 220)),
                                        );
                                    }
                                });
                                ui.add_space(8.0);
                            }

                            // Platform availability
                            if !entry.downloads.is_empty() {
                                ui.label(egui::RichText::new("Platforms").strong());
                                ui.horizontal_wrapped(|ui| {
                                    let triple = marketplace.target_triple();
                                    for platform in entry.downloads.keys() {
                                        let is_current = platform == triple;
                                        let color = if is_current {
                                            egui::Color32::from_rgb(80, 200, 120)
                                        } else {
                                            egui::Color32::GRAY
                                        };
                                        let mut text =
                                            egui::RichText::new(platform).small().color(color);
                                        if is_current {
                                            text = text.strong();
                                        }
                                        ui.label(text);
                                    }
                                });
                                ui.add_space(12.0);
                            }

                            // Homepage link
                            if let Some(homepage) = &entry.homepage {
                                ui.horizontal(|ui| {
                                    ui.label("Homepage:");
                                    ui.label(
                                        egui::RichText::new(homepage)
                                            .color(egui::Color32::from_rgb(100, 149, 237)),
                                    );
                                });
                                ui.add_space(12.0);
                            }

                            // Action buttons
                            ui.separator();
                            ui.add_space(4.0);

                            let id = entry.id.clone();
                            let installed = result.installed;

                            ui.horizontal(|ui| {
                                if installed {
                                    if ui
                                        .button(
                                            egui::RichText::new("\u{2716} Uninstall")
                                                .color(egui::Color32::from_rgb(220, 80, 80)),
                                        )
                                        .clicked()
                                    {
                                        match marketplace.uninstall(&id) {
                                            Ok(()) => {
                                                mkt.status = format!("Uninstalled {id}");
                                                mkt.results = marketplace.search(&mkt.search_query);
                                                mkt.selected = None;
                                            }
                                            Err(e) => mkt.status = format!("Error: {e}"),
                                        }
                                    }

                                    let updates = marketplace.check_updates();
                                    if updates.iter().any(|u| u.id == id) {
                                        if ui
                                            .button(
                                                egui::RichText::new("\u{2b06} Update")
                                                    .color(egui::Color32::from_rgb(100, 180, 255)),
                                            )
                                            .clicked()
                                        {
                                            match marketplace
                                                .uninstall(&id)
                                                .and_then(|()| marketplace.install(&id))
                                            {
                                                Ok(()) => {
                                                    mkt.status = format!("Updated {id}");
                                                    mkt.results =
                                                        marketplace.search(&mkt.search_query);
                                                    mkt.selected = None;
                                                }
                                                Err(e) => mkt.status = format!("Error: {e}"),
                                            }
                                        }
                                    }
                                } else {
                                    let has_platform =
                                        entry.downloads.contains_key(marketplace.target_triple());
                                    if has_platform {
                                        if ui
                                            .button(
                                                egui::RichText::new("\u{2b07} Install")
                                                    .color(egui::Color32::from_rgb(80, 200, 120)),
                                            )
                                            .clicked()
                                        {
                                            match marketplace.install(&id) {
                                                Ok(()) => {
                                                    mkt.status = format!("Installed {id}");
                                                    mkt.results =
                                                        marketplace.search(&mkt.search_query);
                                                    mkt.selected = None;
                                                }
                                                Err(e) => mkt.status = format!("Error: {e}"),
                                            }
                                        }
                                    } else {
                                        ui.label(
                                            egui::RichText::new(format!(
                                                "Not available for {}",
                                                marketplace.target_triple()
                                            ))
                                            .color(egui::Color32::from_rgb(200, 150, 50)),
                                        );
                                    }
                                }
                            });
                        }
                    } else {
                        ui.centered_and_justified(|ui| {
                            ui.label(
                                egui::RichText::new("Select a plugin to view details")
                                    .color(egui::Color32::GRAY)
                                    .italics(),
                            );
                        });
                    }
                });
            });
        });

    if !is_open {
        app.state.dialogs.marketplace_open = false;
        gui.marketplace = Default::default();
    }
}

fn truncate_desc(s: &str, max: usize) -> String {
    if s.len() <= max {
        s.to_string()
    } else {
        let end = s.floor_char_boundary(max);
        format!("{}...", &s[..end])
    }
}

// ── Properties ──────────────────────────────────────────────

fn properties_dialog(ctx: &egui::Context, app: &mut App, gui: &mut GuiState) {
    if !app.state.dialogs.props_open {
        gui.props.initialized = false;
        return;
    }

    // Target: the explicitly-set index (find dialog) or the first selected
    // instance, refreshed on first frame.
    if !gui.props.initialized {
        if let Some(i) = app.active_doc().selection.instance_indices().next() {
            gui.props.inst_idx = i;
        }
    }
    let inst_idx = gui.props.inst_idx;
    let sch = app.schematic();
    if inst_idx >= sch.instances.len() {
        app.state.dialogs.props_open = false;
        return;
    }

    let inst_name = app.resolve(sch.instances.name[inst_idx]).to_string();
    let symbol_name = app.resolve(sch.instances.symbol[inst_idx]).to_string();
    let kind = sch.instances.kind[inst_idx];
    let (x, y) = (sch.instances.x[inst_idx], sch.instances.y[inst_idx]);
    let flags = sch.instances.flags[inst_idx];
    let props: Vec<(String, String)> = sch
        .instance_props(inst_idx)
        .iter()
        .map(|p| (app.resolve(p.key).to_string(), app.resolve(p.value).to_string()))
        .collect();

    if !gui.props.initialized {
        gui.props.name_buf = inst_name.clone();
        gui.props.prop_values = props.iter().map(|(_, v)| v.clone()).collect();
        gui.props.initialized = true;
    }

    let mut cmds: Vec<Command> = Vec::new();
    let mut is_open = true;

    egui::Window::new("Properties")
        .open(&mut is_open)
        .resizable(true)
        .default_width(350.0)
        .show(ctx, |ui| {
            ui.heading("Instance");
            egui::Grid::new("props_info_grid")
                .num_columns(2)
                .spacing([12.0, 4.0])
                .show(ui, |ui| {
                    ui.label("Name:");
                    ui.text_edit_singleline(&mut gui.props.name_buf);
                    ui.end_row();
                    ui.label("Symbol:");
                    ui.label(&symbol_name);
                    ui.end_row();
                    ui.label("Kind:");
                    ui.label(format!("{kind:?}"));
                    ui.end_row();
                });

            ui.separator();
            ui.label(egui::RichText::new("Position").strong());
            egui::Grid::new("props_pos_grid")
                .num_columns(2)
                .spacing([12.0, 4.0])
                .show(ui, |ui| {
                    ui.label("X:");
                    ui.label(format!("{x}"));
                    ui.end_row();
                    ui.label("Y:");
                    ui.label(format!("{y}"));
                    ui.end_row();
                    ui.label("Rotation:");
                    ui.label(format!("{}\u{b0}", flags.rotation() as u32 * 90));
                    ui.end_row();
                    ui.label("Flip:");
                    ui.label(if flags.flip() { "Yes" } else { "No" });
                    ui.end_row();
                });

            if !props.is_empty() {
                ui.separator();
                ui.label(egui::RichText::new("Properties").strong());
                egui::ScrollArea::vertical().show(ui, |ui| {
                    egui::Grid::new("props_values_grid")
                        .num_columns(2)
                        .spacing([12.0, 4.0])
                        .show(ui, |ui| {
                            for (i, (key, _)) in props.iter().enumerate() {
                                ui.label(format!("{key}:"));
                                if let Some(val) = gui.props.prop_values.get_mut(i) {
                                    ui.text_edit_singleline(val);
                                }
                                ui.end_row();
                            }
                        });
                });
            }

            ui.separator();
            if ui.button("Apply").clicked() {
                if gui.props.name_buf != inst_name {
                    cmds.push(Command::RenameInstance {
                        idx: inst_idx,
                        new_name: gui.props.name_buf.clone(),
                    });
                }
                for (i, (key, orig_val)) in props.iter().enumerate() {
                    if let Some(new_val) = gui.props.prop_values.get(i) {
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

    if !is_open {
        app.state.dialogs.props_open = false;
        gui.props.initialized = false;
    }
    for cmd in cmds {
        app.dispatch(cmd);
    }
}

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
        app.dispatch(Command::ToggleColorScheme);
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
        app.dispatch(cmd);
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
        app.dispatch(cmd);
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

#[cfg(test)]
mod doc_math_tests {
    use super::render_math_png;

    #[test]
    fn latex_renders_to_png() {
        let png = render_math_png(
            r"\frac{-b \pm \sqrt{b^2-4ac}}{2a}",
            true,
            egui::Color32::BLACK,
            2.0,
        )
        .expect("quadratic formula renders");
        assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n", "PNG magic");
        assert!(png.len() > 500, "non-trivial image: {} bytes", png.len());

        // Values substituted by expand_doc_vars sit inside math fine.
        let png = render_math_png(r"R_1 = 47k\Omega", false, egui::Color32::WHITE, 2.0)
            .expect("inline with substituted value renders");
        assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");

        // Garbage reports an error instead of panicking.
        assert!(render_math_png(r"\frac{", true, egui::Color32::BLACK, 2.0).is_err());
    }
}
