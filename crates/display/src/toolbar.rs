use eframe::egui;
use schemify_core::commands::{Command, Tool};
use schemify_handler::App;

pub fn show(ctx: &egui::Context, app: &mut App) {
    let active_tool = app.active_tool();
    let can_undo = app.can_undo();
    let can_redo = app.can_redo();

    let mut cmds: Vec<Command> = Vec::new();
    let mut open_file = false;
    let mut save_file = false;

    egui::TopBottomPanel::top("toolbar").show(ctx, |ui| {
        ui.horizontal(|ui| {
            // File
            if ui.button("\u{1f4c2}").on_hover_text("Open file").clicked() {
                open_file = true;
            }
            if ui.button("\u{1f4be}").on_hover_text("Save").clicked() {
                save_file = true;
            }

            ui.separator();

            // Undo / Redo
            if ui
                .add_enabled(can_undo, egui::Button::new("\u{21a9}"))
                .on_hover_text("Undo")
                .clicked()
            {
                cmds.push(Command::Undo);
            }
            if ui
                .add_enabled(can_redo, egui::Button::new("\u{21aa}"))
                .on_hover_text("Redo")
                .clicked()
            {
                cmds.push(Command::Redo);
            }

            ui.separator();

            // Tools
            let tools: &[(Tool, &str, &str)] = &[
                (Tool::Select, "\u{25a2}", "Select"),
                (Tool::Wire, "\u{301c}", "Wire"),
                (Tool::Move, "\u{271d}", "Move"),
                (Tool::Pan, "\u{270b}", "Pan"),
                (Tool::Line, "/", "Line"),
                (Tool::Rect, "\u{25ad}", "Rectangle"),
                (Tool::Circle, "\u{25cb}", "Circle"),
                (Tool::Arc, "\u{25dc}", "Arc"),
                (Tool::Text, "A", "Text"),
            ];

            for &(tool, icon, tooltip) in tools {
                if ui
                    .selectable_label(active_tool == tool, icon)
                    .on_hover_text(tooltip)
                    .clicked()
                {
                    cmds.push(Command::SetTool(tool));
                }
            }

            ui.separator();

            // Zoom
            if ui.button("+").on_hover_text("Zoom In").clicked() {
                cmds.push(Command::ZoomIn);
            }
            if ui.button("\u{2212}").on_hover_text("Zoom Out").clicked() {
                cmds.push(Command::ZoomOut);
            }
            if ui.button("Fit").on_hover_text("Zoom Fit").clicked() {
                cmds.push(Command::ZoomFit);
            }
            if ui.button("1:1").on_hover_text("Zoom Reset").clicked() {
                cmds.push(Command::ZoomReset);
            }
        });
    });

    // File dialogs (blocking, outside egui closure)
    if open_file {
        if let Some(path) = rfd::FileDialog::new()
            .add_filter("Schematic", &["chn"])
            .pick_file()
        {
            let _ = app.open_file(&path);
        }
    }
    if save_file {
        if let Some(path) = rfd::FileDialog::new()
            .add_filter("Schematic", &["chn"])
            .save_file()
        {
            let _ = app.save_to_path(&path);
        }
    }

    for cmd in cmds {
        app.dispatch(cmd);
    }
}
