use eframe::egui;
use schemify_handler::state::SettingsTab;
use schemify_handler::App;

pub fn show(ctx: &egui::Context, app: &mut App) {
    let state = &mut app.gui_mut().dialogs.settings;
    if !state.is_open {
        return;
    }

    egui::Window::new("Settings")
        .open(&mut state.is_open)
        .resizable(true)
        .default_size([500.0, 400.0])
        .show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.selectable_value(&mut state.active_tab, SettingsTab::Theme, "Theme");
                ui.selectable_value(&mut state.active_tab, SettingsTab::Keybinds, "Keybinds");
            });
            ui.separator();

            match state.active_tab {
                SettingsTab::Theme => {
                    ui.label("Theme JSON:");
                    egui::ScrollArea::vertical().show(ui, |ui| {
                        ui.add(
                            egui::TextEdit::multiline(&mut state.json_edit_buf)
                                .code_editor()
                                .desired_width(f32::INFINITY),
                        );
                    });
                    if !state.status_msg.is_empty() {
                        ui.colored_label(egui::Color32::YELLOW, &state.status_msg);
                    }
                }
                SettingsTab::Keybinds => {
                    ui.label("Keybind editor (coming soon)");
                }
            }
        });
}
