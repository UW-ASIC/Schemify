use eframe::egui;
use schemify_handler::state::PanelLayout;
use schemify_handler::App;

pub fn show_left(ui: &mut egui::Ui, app: &App) {
    for panel in &app.gui().plugins_ui.panels {
        if panel.layout == PanelLayout::LeftSidebar && panel.visible {
            ui.collapsing(&panel.name, |ui| {
                ui.label("(plugin content)");
            });
        }
    }
}

pub fn show_right(ui: &mut egui::Ui, app: &App) {
    for panel in &app.gui().plugins_ui.panels {
        if panel.layout == PanelLayout::RightSidebar && panel.visible {
            ui.collapsing(&panel.name, |ui| {
                ui.label("(plugin content)");
            });
        }
    }
}
