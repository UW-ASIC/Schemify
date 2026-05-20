use eframe::egui;
use schemify_core::commands::Command;
use schemify_handler::App;

pub fn show(ctx: &egui::Context, app: &mut App) {
    let doc_info: Vec<(String, bool)> = app
        .documents()
        .iter()
        .map(|d| (d.name.clone(), d.dirty))
        .collect();
    let active = app.active_doc_idx();

    let mut cmd = None;

    egui::TopBottomPanel::top("tab_bar").show(ctx, |ui| {
        ui.horizontal(|ui| {
            for (i, (name, dirty)) in doc_info.iter().enumerate() {
                let label = if *dirty {
                    format!("\u{25cf} {}", if name.is_empty() { "Untitled" } else { name })
                } else if name.is_empty() {
                    "Untitled".to_string()
                } else {
                    name.clone()
                };

                if ui.selectable_label(i == active, &label).clicked() {
                    cmd = Some(Command::SwitchTab(i));
                }
                if ui.small_button("\u{2715}").clicked() {
                    cmd = Some(Command::CloseTab(i));
                }
                ui.separator();
            }
            if ui.button("+").clicked() {
                cmd = Some(Command::NewTab);
            }
        });
    });

    if let Some(c) = cmd {
        app.dispatch(c);
    }
}
