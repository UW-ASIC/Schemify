use eframe::egui;
use schemify_handler::App;

pub fn show(ctx: &egui::Context, app: &App) {
    let status = app.status_msg();
    let cursor = app.gui().canvas.cursor_world;
    let tool = app.active_tool();
    let zoom = app.zoom();

    egui::TopBottomPanel::bottom("status_bar").show(ctx, |ui| {
        ui.horizontal(|ui| {
            if !status.is_empty() {
                ui.label(status);
                ui.separator();
            }
            ui.label(format!("({}, {})", cursor[0], cursor[1]));
            ui.separator();
            ui.label(format!("{:?}", tool));
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                ui.label(format!("{:.0}%", zoom * 100.0));
            });
        });
    });
}
