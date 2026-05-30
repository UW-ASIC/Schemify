use eframe::egui;
use schemify_core::commands::{Command, Tool};
use schemify_handler::state::ViewMode;
use schemify_handler::App;

// ── Menu Bar ─────────────────────────────────────────────────────────────────

pub fn menu_bar(ctx: &egui::Context, app: &mut App) {
    let can_undo = app.can_undo();
    let can_redo = app.can_redo();
    let grid_on = app.show_grid();
    let view_mode = app.view().view_mode;
    #[cfg(not(target_arch = "wasm32"))]
    let active_idx = app.active_doc_idx();

    // Snapshot plugin info before entering egui closures (avoids borrow conflicts)
    let plugin_info: Vec<(usize, String, bool)> = app
        .panels()
        .plugins_ui
        .panels
        .iter()
        .enumerate()
        .map(|(i, p)| (i, p.name.clone(), p.visible))
        .collect();
    let plugin_cmds: Vec<(String, String)> = app
        .panels()
        .plugins_ui
        .commands
        .iter()
        .map(|c| (c.name.clone(), c.description.clone()))
        .collect();

    let view_flags = app.view().view_flags.clone();
    let bus_mode = app.tool_state().bus_mode;
    let sim_backend = app.schematic().sim_backend;

    let mut cmds: Vec<Command> = Vec::new();
    #[cfg(not(target_arch = "wasm32"))]
    let mut open_file = false;
    #[cfg(not(target_arch = "wasm32"))]
    let mut save_file = false;
    #[cfg(not(target_arch = "wasm32"))]
    let mut save_as = false;
    let mut toggle_panel: Option<usize> = None;
    let mut new_view_mode: Option<ViewMode> = None;
    let mut toggle_crosshair = false;
    let mut toggle_netlist = false;
    let mut toggle_fill_rects = false;
    let mut toggle_bus = false;
    #[cfg(not(target_arch = "wasm32"))]
    let mut save_all = false;

    egui::TopBottomPanel::top("menu_bar").show(ctx, |ui| {
        egui::menu::bar(ui, |ui| {
            #[cfg(not(target_arch = "wasm32"))]
            file_menu(
                ui,
                &mut cmds,
                &mut open_file,
                &mut save_file,
                &mut save_as,
                &mut save_all,
                active_idx,
            );
            #[cfg(target_arch = "wasm32")]
            file_menu_web(ui, &mut cmds);
            edit_menu(ui, &mut cmds, can_undo, can_redo);
            view_menu(
                ui,
                &mut cmds,
                &mut new_view_mode,
                grid_on,
                view_mode,
                &view_flags,
                &mut toggle_crosshair,
                &mut toggle_netlist,
                &mut toggle_fill_rects,
            );
            place_menu(ui, &mut cmds, bus_mode, &mut toggle_bus);
            hierarchy_menu(ui, &mut cmds);
            simulate_menu(ui, &mut cmds, sim_backend);
            plugins_menu(ui, &mut cmds, &plugin_info, &plugin_cmds, &mut toggle_panel);
            help_menu(ui, &mut cmds);
        });
    });

    // File dialogs (blocking, native only)
    #[cfg(not(target_arch = "wasm32"))]
    {
        if open_file {
            if let Some(path) = rfd::FileDialog::new()
                .add_filter("Schematic", &["chn"])
                .pick_file()
            {
                let _ = app.open_file(&path);
            }
        }
        if save_file {
            let has_path = matches!(
                app.documents().get(active_idx).map(|d| &d.origin),
                Some(schemify_handler::state::Origin::File(_))
            );
            if has_path {
                if let schemify_handler::state::Origin::File(p) =
                    &app.documents()[active_idx].origin
                {
                    let path = p.clone();
                    let _ = app.save_to_path(&path);
                }
            } else {
                save_as = true;
            }
        }
        if save_as {
            if let Some(path) = rfd::FileDialog::new()
                .add_filter("Schematic", &["chn"])
                .save_file()
            {
                let _ = app.save_to_path(&path);
            }
        }
    }

    if let Some(mode) = new_view_mode {
        app.view_mut().view_mode = mode;
    }
    if toggle_crosshair {
        app.view_mut().view_flags.crosshair = !view_flags.crosshair;
    }
    if toggle_netlist {
        app.view_mut().view_flags.show_netlist = !view_flags.show_netlist;
    }
    if toggle_fill_rects {
        app.view_mut().view_flags.fill_rects = !view_flags.fill_rects;
    }
    if let Some(idx) = toggle_panel {
        if let Some(p) = app.panels_mut().plugins_ui.panels.get_mut(idx) {
            p.visible = !p.visible;
        }
    }
    if toggle_bus {
        app.toggle_bus_mode();
    }

    #[cfg(not(target_arch = "wasm32"))]
    if save_all {
        let paths: Vec<std::path::PathBuf> = app
            .documents()
            .iter()
            .filter_map(|d| {
                if let schemify_handler::state::Origin::File(p) = &d.origin {
                    Some(p.clone())
                } else {
                    None
                }
            })
            .collect();
        for path in paths {
            let _ = app.save_to_path(&path);
        }
    }

    for cmd in cmds {
        app.dispatch(cmd);
    }
}

// ── File (native) ────────────────────────────────────────────────────────────

#[cfg(not(target_arch = "wasm32"))]
fn file_menu(
    ui: &mut egui::Ui,
    cmds: &mut Vec<Command>,
    open_file: &mut bool,
    save_file: &mut bool,
    save_as: &mut bool,
    save_all: &mut bool,
    active_idx: usize,
) {
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
            *open_file = true;
            ui.close_menu();
        }
        if sc(ui, "Import Project...", "") {
            cmds.push(Command::OpenImportDialog);
            ui.close_menu();
        }
        if sc(ui, "Reload from Disk", "") {
            cmds.push(Command::ReloadFromDisk);
            ui.close_menu();
        }
        ui.separator();
        if sc(ui, "Save", "Ctrl+S") {
            *save_file = true;
            ui.close_menu();
        }
        if sc(ui, "Save As...", "") {
            *save_as = true;
            ui.close_menu();
        }
        if sc(ui, "Save All", "") {
            *save_all = true;
            ui.close_menu();
        }
        ui.separator();
        ui.menu_button("Export", |ui| {
            if en(ui, "Export SVG...", "", false) {
                ui.close_menu();
            }
            if en(ui, "Export Netlist...", "", false) {
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
}

// ── File (web: read-only) ────────────────────────────────────────────────────

#[cfg(target_arch = "wasm32")]
fn file_menu_web(ui: &mut egui::Ui, cmds: &mut Vec<Command>) {
    ui.menu_button("File", |ui| {
        ui.weak("(read-only mode)");
        ui.separator();
        let active_idx = 0; // simplified for web
        if sc(ui, "New Tab", "Ctrl+T") {
            cmds.push(Command::NewTab);
            ui.close_menu();
        }
        if sc(ui, "Close Tab", "Ctrl+W") {
            cmds.push(Command::CloseTab(active_idx));
            ui.close_menu();
        }
    });
}

// ── Edit ─────────────────────────────────────────────────────────────────────

fn edit_menu(ui: &mut egui::Ui, cmds: &mut Vec<Command>, can_undo: bool, can_redo: bool) {
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
        if sc(ui, "Cut", "Ctrl+X") {
            cmds.push(Command::Cut);
            ui.close_menu();
        }
        if sc(ui, "Copy", "Ctrl+C") {
            cmds.push(Command::Copy);
            ui.close_menu();
        }
        if sc(ui, "Paste", "Ctrl+V") {
            cmds.push(Command::Paste);
            ui.close_menu();
        }
        if sc(ui, "Delete", "Del") {
            cmds.push(Command::DeleteSelected);
            ui.close_menu();
        }
        if sc(ui, "Duplicate", "Ctrl+D") {
            cmds.push(Command::DuplicateSelected);
            ui.close_menu();
        }
        ui.separator();
        if sc(ui, "Select All", "Ctrl+A") {
            cmds.push(Command::SelectAll);
            ui.close_menu();
        }
        if sc(ui, "Select None", "") {
            cmds.push(Command::SelectNone);
            ui.close_menu();
        }
        if sc(ui, "Invert Selection", "") {
            cmds.push(Command::InvertSelection);
            ui.close_menu();
        }
        if sc(ui, "Find...", "Ctrl+F") {
            cmds.push(Command::OpenFindDialog);
            ui.close_menu();
        }
        ui.separator();
        if sc(ui, "Rotate CW", "R") {
            cmds.push(Command::RotateCw);
            ui.close_menu();
        }
        if sc(ui, "Rotate CCW", "Shift+R") {
            cmds.push(Command::RotateCcw);
            ui.close_menu();
        }
        if sc(ui, "Flip Horizontal", "X") {
            cmds.push(Command::FlipHorizontal);
            ui.close_menu();
        }
        if sc(ui, "Flip Vertical", "Shift+X") {
            cmds.push(Command::FlipVertical);
            ui.close_menu();
        }
        if sc(ui, "Align to Grid", "") {
            cmds.push(Command::AlignToGrid);
            ui.close_menu();
        }
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
}

// ── View ─────────────────────────────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
fn view_menu(
    ui: &mut egui::Ui,
    cmds: &mut Vec<Command>,
    new_view_mode: &mut Option<ViewMode>,
    grid_on: bool,
    view_mode: ViewMode,
    view_flags: &schemify_handler::state::ViewFlags,
    toggle_crosshair: &mut bool,
    toggle_netlist: &mut bool,
    toggle_fill_rects: &mut bool,
) {
    ui.menu_button("View", |ui| {
        if sc(ui, "Zoom In", "Ctrl+=") {
            cmds.push(Command::ZoomIn);
            ui.close_menu();
        }
        if sc(ui, "Zoom Out", "Ctrl+-") {
            cmds.push(Command::ZoomOut);
            ui.close_menu();
        }
        if sc(ui, "Zoom to Fit", "F") {
            cmds.push(Command::ZoomFit);
            ui.close_menu();
        }
        if sc(ui, "Zoom Reset", "Ctrl+0") {
            cmds.push(Command::ZoomReset);
            ui.close_menu();
        }
        ui.separator();
        if tog(ui, "Grid", "G", grid_on) {
            cmds.push(Command::ToggleGrid);
            ui.close_menu();
        }
        if tog(ui, "Crosshair", "", view_flags.crosshair) {
            *toggle_crosshair = true;
            ui.close_menu();
        }
        if tog(ui, "Netlist View", "", view_flags.show_netlist) {
            *toggle_netlist = true;
            ui.close_menu();
        }
        if tog(ui, "Fill Shapes", "", view_flags.fill_rects) {
            *toggle_fill_rects = true;
            ui.close_menu();
        }
        ui.separator();
        if tog(ui, "Schematic View", "", view_mode == ViewMode::Schematic) {
            *new_view_mode = Some(ViewMode::Schematic);
            ui.close_menu();
        }
        if tog(ui, "Symbol View", "", view_mode == ViewMode::Symbol) {
            *new_view_mode = Some(ViewMode::Symbol);
            ui.close_menu();
        }
        if tog(
            ui,
            "Documentation View",
            "",
            view_mode == ViewMode::Documentation,
        ) {
            *new_view_mode = Some(ViewMode::Documentation);
            ui.close_menu();
        }
        ui.separator();
        if sc(ui, "Library Browser", "Ins") {
            cmds.push(Command::OpenLibraryBrowser);
            ui.close_menu();
        }
        if sc(ui, "File Explorer", "") {
            cmds.push(Command::OpenFileExplorer);
            ui.close_menu();
        }
    });
}

// ── Place ────────────────────────────────────────────────────────────────────

fn place_menu(ui: &mut egui::Ui, cmds: &mut Vec<Command>, bus_mode: bool, toggle_bus: &mut bool) {
    ui.menu_button("Place", |ui| {
        if sc(ui, "Wire", "W") {
            cmds.push(Command::SetTool(Tool::Wire));
            ui.close_menu();
        }
        let bus_label = if bus_mode {
            "\u{2713} Bus Mode"
        } else {
            "  Bus Mode"
        };
        if sc(ui, bus_label, "B") {
            *toggle_bus = true;
            ui.close_menu();
        }
        ui.separator();
        if sc(ui, "Line", "") {
            cmds.push(Command::SetTool(Tool::Line));
            ui.close_menu();
        }
        if sc(ui, "Rectangle", "") {
            cmds.push(Command::SetTool(Tool::Rect));
            ui.close_menu();
        }
        if sc(ui, "Arc", "") {
            cmds.push(Command::SetTool(Tool::Arc));
            ui.close_menu();
        }
        if sc(ui, "Circle", "") {
            cmds.push(Command::SetTool(Tool::Circle));
            ui.close_menu();
        }
        if sc(ui, "Polygon", "") {
            cmds.push(Command::SetTool(Tool::Polygon));
            ui.close_menu();
        }
        if sc(ui, "Text", "") {
            cmds.push(Command::SetTool(Tool::Text));
            ui.close_menu();
        }
        ui.separator();
        if sc(ui, "Insert from Library...", "Ins") {
            cmds.push(Command::OpenMarketplace);
            ui.close_menu();
        }
    });
}

// ── Hierarchy ────────────────────────────────────────────────────────────────

fn hierarchy_menu(ui: &mut egui::Ui, _cmds: &mut Vec<Command>) {
    ui.menu_button("Hierarchy", |ui| {
        // Hierarchy navigation needs handler support — disabled stubs for now
        if en(ui, "Descend Schematic", "H", false) {
            ui.close_menu();
        }
        if en(ui, "Descend Symbol", "Shift+H", false) {
            ui.close_menu();
        }
        if en(ui, "Ascend", "Backspace", false) {
            ui.close_menu();
        }
        ui.separator();
        if en(ui, "Edit in New Tab", "", false) {
            ui.close_menu();
        }
    });
}

// ── Simulate ─────────────────────────────────────────────────────────────────

fn simulate_menu(
    ui: &mut egui::Ui,
    cmds: &mut Vec<Command>,
    sim_backend: schemify_core::simulation::SpiceBackend,
) {
    ui.menu_button("Simulate", |ui| {
        if sc(ui, "Run Simulation", "F5") {
            cmds.push(Command::RunSim);
            ui.close_menu();
        }
        ui.menu_button("Backend", |ui| {
            use schemify_core::simulation::SpiceBackend;
            let backends = [
                (SpiceBackend::NgSpice, "ngspice"),
                (SpiceBackend::Xyce, "Xyce"),
                (SpiceBackend::LtSpice, "LTSpice"),
                (SpiceBackend::Spectre, "Spectre"),
            ];
            for (variant, label) in &backends {
                let prefix = if sim_backend == *variant {
                    "\u{2713} "
                } else {
                    "  "
                };
                if sc(ui, &format!("{prefix}{label}"), "") {
                    cmds.push(Command::SetSimBackend(variant.as_str().to_string()));
                    ui.close_menu();
                }
            }
        });
        ui.separator();
        if sc(ui, "Spice Code...", "") {
            cmds.push(Command::OpenSpiceCodeEditor);
            ui.close_menu();
        }
        if en(ui, "Highlight Selected Nets", "K", false) {
            ui.close_menu();
        }
        if en(ui, "Unhighlight All", "Ctrl+K", false) {
            ui.close_menu();
        }
        ui.separator();
        if en(ui, "Export Netlist...", "", false) {
            ui.close_menu();
        }
        if en(ui, "Clear Sim Cache", "", false) {
            ui.close_menu();
        }
    });
}

// ── Plugins ──────────────────────────────────────────────────────────────────

fn plugins_menu(
    ui: &mut egui::Ui,
    cmds: &mut Vec<Command>,
    panels: &[(usize, String, bool)],
    plugin_cmds: &[(String, String)],
    toggle_panel: &mut Option<usize>,
) {
    ui.menu_button("Plugins", |ui| {
        if panels.is_empty() {
            ui.weak("(no plugins loaded)");
        } else {
            for (i, name, vis) in panels {
                let prefix = if *vis { "\u{2713} " } else { "  " };
                if ui.button(format!("{prefix}{name}")).clicked() {
                    *toggle_panel = Some(*i);
                    ui.close_menu();
                }
            }
        }

        if !plugin_cmds.is_empty() {
            ui.separator();
            for (name, _desc) in plugin_cmds {
                if ui.button(name).clicked() {
                    cmds.push(Command::PluginCommand {
                        tag: name.clone(),
                        payload: Vec::new(),
                    });
                    ui.close_menu();
                }
            }
        }

        ui.separator();
        if sc(ui, "Reload Plugins", "") {
            cmds.push(Command::PluginsRefresh);
            ui.close_menu();
        }
        if sc(ui, "Marketplace...", "") {
            cmds.push(Command::OpenMarketplace);
            ui.close_menu();
        }
    });
}

// ── Help ─────────────────────────────────────────────────────────────────────

fn help_menu(ui: &mut egui::Ui, cmds: &mut Vec<Command>) {
    ui.menu_button("Help", |ui| {
        if sc(ui, "Keyboard Shortcuts...", "") {
            cmds.push(Command::OpenSettings);
            ui.close_menu();
        }
        if en(ui, "Reload Config", "", false) {
            ui.close_menu();
        }
        ui.separator();
        if sc(ui, "Settings...", "") {
            cmds.push(Command::OpenSettings);
            ui.close_menu();
        }
    });
}

// ── Menu item helpers ────────────────────────────────────────────────────────

fn sc(ui: &mut egui::Ui, label: &str, shortcut: &str) -> bool {
    if shortcut.is_empty() {
        return ui.button(label).clicked();
    }
    ui.horizontal(|ui| {
        let r = ui.button(label);
        ui.weak(shortcut);
        r.clicked()
    })
    .inner
}

fn en(ui: &mut egui::Ui, label: &str, shortcut: &str, enabled: bool) -> bool {
    if shortcut.is_empty() {
        return ui.add_enabled(enabled, egui::Button::new(label)).clicked();
    }
    ui.horizontal(|ui| {
        let r = ui.add_enabled(enabled, egui::Button::new(label));
        ui.weak(shortcut);
        r.clicked()
    })
    .inner
}

fn tog(ui: &mut egui::Ui, label: &str, shortcut: &str, active: bool) -> bool {
    let prefix = if active { "\u{2713} " } else { "  " };
    sc(ui, &format!("{prefix}{label}"), shortcut)
}

// ── Tab Bar ──────────────────────────────────────────────────────────────────

pub fn tab_bar(ctx: &egui::Context, app: &mut App) {
    let doc_info: Vec<(String, bool)> = app
        .documents()
        .iter()
        .map(|d| (d.name.clone(), d.dirty))
        .collect();
    let active = app.active_doc_idx();
    let tab_count = doc_info.len();
    let view_mode = app.view().view_mode;

    let mut cmd = None;
    let mut new_view_mode: Option<ViewMode> = None;

    egui::TopBottomPanel::top("tab_bar").show(ctx, |ui| {
        ui.horizontal(|ui| {
            // Cap each tab width so they compress when many are open
            let max_tab_w = if tab_count <= 1 {
                200.0
            } else {
                (600.0 / tab_count as f32).clamp(60.0, 200.0)
            };

            for (i, (name, dirty)) in doc_info.iter().enumerate() {
                let is_active = i == active;
                let display = if name.is_empty() {
                    "Untitled"
                } else {
                    name.as_str()
                };

                let basename = display.rsplit(&['/', '\\'][..]).next().unwrap_or(display);

                let label = if *dirty {
                    format!("\u{25cf} {basename}")
                } else {
                    basename.to_string()
                };

                // Tab with embedded close button
                let tab_h = ui.spacing().interact_size.y;
                let (rect, response) =
                    ui.allocate_exact_size(egui::vec2(max_tab_w, tab_h), egui::Sense::click());

                // Background
                let bg = if is_active {
                    ui.visuals().selection.bg_fill
                } else if response.hovered() {
                    ui.visuals().widgets.hovered.bg_fill
                } else {
                    egui::Color32::TRANSPARENT
                };
                ui.painter().rect_filled(rect, 3.0, bg);

                // Text (left-aligned, leave room for close btn)
                let close_w = if tab_count > 1 { 18.0 } else { 0.0 };
                let text_rect = rect.shrink2(egui::vec2(4.0, 0.0));
                let text_rect = egui::Rect::from_min_max(
                    text_rect.min,
                    egui::pos2(text_rect.max.x - close_w, text_rect.max.y),
                );
                let text_color = if is_active {
                    ui.visuals().strong_text_color()
                } else {
                    ui.visuals().text_color()
                };
                ui.painter().text(
                    text_rect.left_center(),
                    egui::Align2::LEFT_CENTER,
                    &label,
                    egui::FontId::proportional(13.0),
                    text_color,
                );

                // Close button (embedded, right side of tab)
                let mut close_clicked = false;
                if tab_count > 1 {
                    let close_size = 14.0;
                    let close_center =
                        egui::pos2(rect.max.x - close_size * 0.5 - 3.0, rect.center().y);
                    let close_rect = egui::Rect::from_center_size(
                        close_center,
                        egui::vec2(close_size, close_size),
                    );
                    let close_id = response.id.with("close");
                    let close_resp = ui.interact(close_rect, close_id, egui::Sense::click());

                    // Only show on tab hover or close hover
                    if response.hovered() || close_resp.hovered() {
                        let close_color = if close_resp.hovered() {
                            ui.visuals().strong_text_color()
                        } else {
                            ui.visuals().weak_text_color()
                        };
                        ui.painter().text(
                            close_center,
                            egui::Align2::CENTER_CENTER,
                            "\u{2715}",
                            egui::FontId::proportional(10.0),
                            close_color,
                        );
                    }

                    if close_resp.clicked() {
                        close_clicked = true;
                    }
                }

                if close_clicked {
                    cmd = Some(Command::CloseTab(i));
                } else if response.clicked() && !is_active {
                    cmd = Some(Command::SwitchTab(i));
                }

                if i + 1 < tab_count {
                    ui.separator();
                }
            }

            // New tab button
            ui.add_space(4.0);
            if ui.small_button("+").on_hover_text("New Tab").clicked() {
                cmd = Some(Command::NewTab);
            }

            // Push view mode toggle to the right
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let sch = view_mode == ViewMode::Schematic;
                let sym = view_mode == ViewMode::Symbol;
                let doc = view_mode == ViewMode::Documentation;

                if ui.selectable_label(doc, "DOC").clicked() {
                    new_view_mode = Some(ViewMode::Documentation);
                }
                if ui.selectable_label(sym, "SYM").clicked() {
                    new_view_mode = Some(ViewMode::Symbol);
                }
                if ui.selectable_label(sch, "SCH").clicked() {
                    new_view_mode = Some(ViewMode::Schematic);
                }
            });
        });
    });

    if let Some(c) = cmd {
        app.dispatch(c);
    }
    if let Some(mode) = new_view_mode {
        app.view_mut().view_mode = mode;
    }
}

// ── Status Bar ───────────────────────────────────────────────────────────────

pub fn status_bar(ctx: &egui::Context, app: &mut App) {
    let in_command_mode = app.editor().command_mode;

    egui::TopBottomPanel::bottom("status_bar").show(ctx, |ui| {
        ui.horizontal(|ui| {
            if in_command_mode {
                show_command_mode(ui, app);
            } else {
                show_normal(ui, app);
            }
        });
    });
}

// ── Normal mode ──────────────────────────────────────────────────────────────

fn show_normal(ui: &mut egui::Ui, app: &App) {
    let status = app.status_msg();
    let cursor = app.canvas().cursor_world;
    let tool = app.active_tool();
    let snap = app.tool_state().snap_size;
    let view_mode = app.view().view_mode;
    let zoom = app.zoom();

    if !status.is_empty() {
        ui.label(status);
        ui.separator();
    }

    ui.label(format!("({}, {})", cursor[0], cursor[1]));
    ui.separator();
    ui.label(format!("{:?}", tool));
    ui.separator();
    ui.label(format!("snap: {}", snap as i32));
    ui.separator();

    let mode_str = match view_mode {
        ViewMode::Schematic => "SCH",
        ViewMode::Symbol => "SYM",
        ViewMode::Documentation => "DOC",
    };
    ui.label(mode_str);
    ui.separator();
    ui.weak(": for commands");

    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
        ui.label(format!("{:.0}%", zoom * 100.0));
    });
}

// ── Command mode ─────────────────────────────────────────────────────────────

fn show_command_mode(ui: &mut egui::Ui, app: &mut App) {
    ui.label(":");

    let buf = &mut app.editor_mut().command_buf;
    let response = ui.add(
        egui::TextEdit::singleline(buf)
            .desired_width(ui.available_width() - 180.0)
            .hint_text("command"),
    );

    // Auto-focus on the first frame we enter command mode.
    if !response.has_focus() {
        response.request_focus();
    }
    app.editor_mut().text_entry_focused = true;

    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
        ui.weak("Enter to run | Esc to cancel");
    });

    // Handle Enter / Escape via the input system so we catch them
    // even when the text field consumed the key event.
    let (enter, escape) = ui.ctx().input(|i| {
        (
            i.key_pressed(egui::Key::Enter),
            i.key_pressed(egui::Key::Escape),
        )
    });

    if enter {
        let line = app.editor().command_buf.clone();
        exit_command_mode(app);
        execute_vim_command(&line, app);
    } else if escape {
        exit_command_mode(app);
    }
}

fn exit_command_mode(app: &mut App) {
    let editor = app.editor_mut();
    editor.command_mode = false;
    editor.command_buf.clear();
    editor.text_entry_focused = false;
}

// ── Vim command parser & executor ────────────────────────────────────────────

/// Result of parsing a vim command line.
enum VimResult {
    /// Dispatch through the normal command pipeline.
    Dispatch(Command),
    /// GUI-only: set view mode directly.
    SetView(ViewMode),
    /// Nothing matched.
    Unknown,
}

fn parse_vim_command(input: &str) -> VimResult {
    let cmd = input.trim().to_ascii_lowercase();
    let cmd = cmd.strip_prefix(':').unwrap_or(&cmd);
    let cmd = cmd.trim();

    match cmd {
        // File
        "w" | "save" => VimResult::Dispatch(Command::FileSave),
        "wq" => VimResult::Dispatch(Command::FileSave), // quit handled separately if needed
        "q" | "quit" | "close" | "tabclose" => VimResult::Dispatch(Command::CloseTab(0)),
        "e" | "open" => VimResult::Dispatch(Command::FileOpen),
        "saveas" => VimResult::Dispatch(Command::FileSaveAs),
        "new" | "tabnew" => VimResult::Dispatch(Command::FileNew),
        "newtab" => VimResult::Dispatch(Command::NewTab),
        "reload" | "e!" => VimResult::Dispatch(Command::ReloadFromDisk),

        // Undo / Redo
        "undo" => VimResult::Dispatch(Command::Undo),
        "redo" => VimResult::Dispatch(Command::Redo),

        // Zoom
        "zoomin" => VimResult::Dispatch(Command::ZoomIn),
        "zoomout" => VimResult::Dispatch(Command::ZoomOut),
        "zoomfit" | "fit" => VimResult::Dispatch(Command::ZoomFit),
        "zoomreset" => VimResult::Dispatch(Command::ZoomReset),

        // Grid
        "grid" => VimResult::Dispatch(Command::ToggleGrid),

        // Tools
        "wire" => VimResult::Dispatch(Command::SetTool(Tool::Wire)),
        "select" => VimResult::Dispatch(Command::SetTool(Tool::Select)),
        "line" => VimResult::Dispatch(Command::SetTool(Tool::Line)),
        "rect" => VimResult::Dispatch(Command::SetTool(Tool::Rect)),
        "circle" => VimResult::Dispatch(Command::SetTool(Tool::Circle)),
        "arc" => VimResult::Dispatch(Command::SetTool(Tool::Arc)),
        "polygon" => VimResult::Dispatch(Command::SetTool(Tool::Polygon)),
        "text" => VimResult::Dispatch(Command::SetTool(Tool::Text)),
        "move" => VimResult::Dispatch(Command::SetTool(Tool::Move)),

        // Dialogs
        "props" | "properties" => VimResult::Dispatch(Command::OpenPropsDialog),
        "find" => VimResult::Dispatch(Command::OpenFindDialog),
        "settings" | "preferences" => VimResult::Dispatch(Command::OpenSettings),
        "spicecode" => VimResult::Dispatch(Command::OpenSpiceCodeEditor),
        "newprim" => VimResult::Dispatch(Command::OpenNewPrimDialog),
        "marketplace" => VimResult::Dispatch(Command::OpenMarketplace),
        "import" => VimResult::Dispatch(Command::OpenImportDialog),

        // Simulation
        "sim" | "simulate" => VimResult::Dispatch(Command::RunSim),

        // View toggles
        "fullscreen" => VimResult::Dispatch(Command::ToggleFullscreen),
        "darkmode" => VimResult::Dispatch(Command::ToggleColorScheme),

        // Plugins
        "pluginsreload" | "pluginsrefresh" => VimResult::Dispatch(Command::PluginsRefresh),

        // Selection & editing
        "delete" | "del" => VimResult::Dispatch(Command::DeleteSelected),
        "selectall" => VimResult::Dispatch(Command::SelectAll),
        "selectnone" => VimResult::Dispatch(Command::SelectNone),
        "duplicate" | "dup" => VimResult::Dispatch(Command::DuplicateSelected),

        // Transform
        "rotatecw" | "rotcw" => VimResult::Dispatch(Command::RotateCw),
        "rotateccw" | "rotccw" => VimResult::Dispatch(Command::RotateCcw),
        "fliph" => VimResult::Dispatch(Command::FlipHorizontal),
        "flipv" => VimResult::Dispatch(Command::FlipVertical),
        "align" => VimResult::Dispatch(Command::AlignToGrid),

        // Clipboard
        "copy" | "clipcopy" => VimResult::Dispatch(Command::Copy),
        "cut" | "clipcut" => VimResult::Dispatch(Command::Cut),
        "paste" | "clippaste" => VimResult::Dispatch(Command::Paste),

        // Auto-layout
        "autolayout" | "layout" => VimResult::Dispatch(Command::AutoLayout),

        // Symbol generation
        "gensym" | "gensymbol" | "makesymbol" => {
            VimResult::Dispatch(Command::GenerateSymbolFromSchematic)
        }

        // View mode (GUI-only, not dispatch)
        "schematic" | "sch" => VimResult::SetView(ViewMode::Schematic),
        "symbol" | "sym" => VimResult::SetView(ViewMode::Symbol),
        "doc" | "documentation" => VimResult::SetView(ViewMode::Documentation),

        _ => VimResult::Unknown,
    }
}

fn execute_vim_command(line: &str, app: &mut App) {
    if line.trim().is_empty() {
        return;
    }

    match parse_vim_command(line) {
        VimResult::Dispatch(cmd) => app.dispatch(cmd),
        VimResult::SetView(mode) => {
            app.view_mut().view_mode = mode;
        }
        VimResult::Unknown => {
            // Could set a status message; for now just ignore.
        }
    }
}
