use eframe::egui;
use schemify_core::commands::{Command, Tool};
use schemify_handler::App;

pub fn show(ctx: &egui::Context, app: &mut App) {
    let gui = app.gui_mut();
    if !gui.command_mode {
        return;
    }

    let mut cmd = None;
    let mut close = false;

    egui::Area::new(egui::Id::new("command_bar"))
        .anchor(egui::Align2::CENTER_TOP, [0.0, 60.0])
        .show(ctx, |ui| {
            egui::Frame::popup(ui.style()).show(ui, |ui| {
                ui.set_min_width(400.0);
                let resp = ui.text_edit_singleline(&mut gui.command_buf);
                if resp.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) {
                    cmd = parse_command(&gui.command_buf);
                    gui.command_buf.clear();
                    close = true;
                }
                if ui.input(|i| i.key_pressed(egui::Key::Escape)) {
                    gui.command_buf.clear();
                    close = true;
                }
                resp.request_focus();
            });
        });

    if close {
        gui.command_mode = false;
    }

    // gui borrow ends above (gui is a local &mut); dispatch below is fine
    // because gui_mut() returned a temporary borrow that's now dropped.
    // Actually gui is still live here — so collect cmd first, drop gui, then dispatch.
    // The borrow checker handles this because gui is reborrowed from app.gui_mut().
    if let Some(c) = cmd {
        app.dispatch(c);
    }
}

fn parse_command(input: &str) -> Option<Command> {
    let parts: Vec<&str> = input.trim().split_whitespace().collect();
    let first = *parts.first()?;
    match first {
        "zoom" => match parts.get(1).copied() {
            Some("in") => Some(Command::ZoomIn),
            Some("out") => Some(Command::ZoomOut),
            Some("fit") => Some(Command::ZoomFit),
            Some("reset") => Some(Command::ZoomReset),
            _ => None,
        },
        "undo" => Some(Command::Undo),
        "redo" => Some(Command::Redo),
        "grid" => Some(Command::ToggleGrid),
        "new" => Some(Command::NewTab),
        "find" => Some(Command::OpenFindDialog),
        "props" | "properties" => Some(Command::OpenPropsDialog),
        "settings" => Some(Command::OpenSettings),
        "import" => Some(Command::OpenImportDialog),
        "delete" => Some(Command::DeleteSelected),
        "select" => match parts.get(1).copied() {
            Some("all") => Some(Command::SelectAll),
            Some("none") => Some(Command::SelectNone),
            Some("invert") => Some(Command::InvertSelection),
            _ => None,
        },
        "tool" => match parts.get(1).copied() {
            Some("select") => Some(Command::SetTool(Tool::Select)),
            Some("wire") => Some(Command::SetTool(Tool::Wire)),
            Some("move") => Some(Command::SetTool(Tool::Move)),
            Some("pan") => Some(Command::SetTool(Tool::Pan)),
            Some("line") => Some(Command::SetTool(Tool::Line)),
            Some("rect") => Some(Command::SetTool(Tool::Rect)),
            Some("circle") => Some(Command::SetTool(Tool::Circle)),
            Some("arc") => Some(Command::SetTool(Tool::Arc)),
            Some("text") => Some(Command::SetTool(Tool::Text)),
            _ => None,
        },
        _ => None,
    }
}
