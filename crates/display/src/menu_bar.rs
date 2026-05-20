use eframe::egui;
use schemify_core::commands::{Command, Tool};
use schemify_handler::state::ViewMode;
use schemify_handler::App;

pub fn show(ctx: &egui::Context, app: &mut App) {
    let can_undo = app.can_undo();
    let can_redo = app.can_redo();
    let grid_on = app.show_grid();
    let view_mode = app.gui().view_mode;
    #[cfg(not(target_arch = "wasm32"))]
    let active_idx = app.active_doc_idx();

    // Snapshot plugin info before entering egui closures (avoids borrow conflicts)
    let plugin_info: Vec<(usize, String, bool)> = app
        .gui()
        .plugins_ui
        .panels
        .iter()
        .enumerate()
        .map(|(i, p)| (i, p.name.clone(), p.visible))
        .collect();
    let plugin_cmds: Vec<(String, String)> = app
        .gui()
        .plugins_ui
        .commands
        .iter()
        .map(|c| (c.name.clone(), c.description.clone()))
        .collect();

    let view_flags = app.gui().view_flags.clone();

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

    egui::TopBottomPanel::top("menu_bar").show(ctx, |ui| {
        egui::menu::bar(ui, |ui| {
            #[cfg(not(target_arch = "wasm32"))]
            file_menu(ui, &mut cmds, &mut open_file, &mut save_file, &mut save_as, active_idx);
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
            place_menu(ui, &mut cmds);
            hierarchy_menu(ui, &mut cmds);
            simulate_menu(ui, &mut cmds);
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
        app.gui_mut().view_mode = mode;
    }
    if toggle_crosshair {
        app.gui_mut().view_flags.crosshair = !view_flags.crosshair;
    }
    if toggle_netlist {
        app.gui_mut().view_flags.show_netlist = !view_flags.show_netlist;
    }
    if toggle_fill_rects {
        app.gui_mut().view_flags.fill_rects = !view_flags.fill_rects;
    }
    if let Some(idx) = toggle_panel {
        if let Some(p) = app.gui_mut().plugins_ui.panels.get_mut(idx) {
            p.visible = !p.visible;
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
            // Save All: save every document that has a file path
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
        if tog(ui, "Documentation View", "", view_mode == ViewMode::Documentation) {
            *new_view_mode = Some(ViewMode::Documentation);
            ui.close_menu();
        }
        ui.separator();
        if sc(ui, "Library Browser", "Ins") {
            ui.close_menu();
        }
        if sc(ui, "File Explorer", "") {
            ui.close_menu();
        }
    });
}

// ── Place ────────────────────────────────────────────────────────────────────

fn place_menu(ui: &mut egui::Ui, cmds: &mut Vec<Command>) {
    ui.menu_button("Place", |ui| {
        if sc(ui, "Wire", "W") {
            cmds.push(Command::SetTool(Tool::Wire));
            ui.close_menu();
        }
        if en(ui, "Bus Mode", "B", false) {
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

fn simulate_menu(ui: &mut egui::Ui, cmds: &mut Vec<Command>) {
    ui.menu_button("Simulate", |ui| {
        if sc(ui, "Run Simulation", "F5") {
            cmds.push(Command::RunSim);
            ui.close_menu();
        }
        ui.menu_button("Backend", |ui| {
            // Backend selector — placeholder until handler exposes sim backend state
            if en(ui, "\u{2713} ngspice", "", false) {
                ui.close_menu();
            }
            if en(ui, "  Xyce", "", false) {
                ui.close_menu();
            }
            if en(ui, "  LTSpice", "", false) {
                ui.close_menu();
            }
            if en(ui, "  Spectre", "", false) {
                ui.close_menu();
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

// ── Item helpers ─────────────────────────────────────────────────────────────

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
