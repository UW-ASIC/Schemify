use eframe::egui;
use schemify_core::commands::Command;
use schemify_handler::App;

pub fn show(ctx: &egui::Context, app: &mut App) {
    if !app.dialogs().spice_code.is_open {
        return;
    }

    let current_body = app.schematic().spice_body.clone();
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
            .default_size([500.0, 400.0])
            .show(ctx, |ui| {
                egui::ScrollArea::vertical().show(ui, |ui| {
                    ui.add(
                        egui::TextEdit::multiline(&mut state.buf)
                            .code_editor()
                            .desired_width(f32::INFINITY),
                    );
                });

                ui.separator();
                if ui.button("Apply").clicked() {
                    cmds.push(Command::SetSpiceCode(state.buf.clone()));
                }
            });
    }

    for cmd in cmds {
        app.dispatch(cmd);
    }
}
