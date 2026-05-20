use eframe::egui;
use schemify_core::commands::Command;
use schemify_handler::state::ImportFormat;
use schemify_handler::App;

pub fn show(ctx: &egui::Context, app: &mut App) {
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
                            ui.selectable_value(
                                &mut state.format,
                                ImportFormat::Xschem,
                                "Xschem",
                            );
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
