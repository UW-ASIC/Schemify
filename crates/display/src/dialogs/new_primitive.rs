use eframe::egui;
use schemify_handler::state::PrimType;
use schemify_handler::App;

pub fn show(ctx: &egui::Context, app: &mut App) {
    let state = &mut app.gui_mut().dialogs.new_prim;
    if !state.is_open {
        return;
    }

    egui::Window::new("New Primitive")
        .open(&mut state.is_open)
        .resizable(false)
        .default_width(350.0)
        .show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.label("Type:");
                egui::ComboBox::from_id_salt("prim_type")
                    .selected_text(format!("{:?}", state.prim_type))
                    .show_ui(ui, |ui| {
                        ui.selectable_value(
                            &mut state.prim_type,
                            PrimType::Behavioral,
                            "Behavioral",
                        );
                        ui.selectable_value(&mut state.prim_type, PrimType::Spice, "SPICE");
                        ui.selectable_value(&mut state.prim_type, PrimType::Digital, "Digital");
                    });
            });

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
                } else {
                    state.status_msg = format!("Created primitive: {}", state.name_buf);
                    // TODO: write .chn_prim file to project dir
                }
            }
        });
}
