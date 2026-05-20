use eframe::egui;
use schemify_core::primitives::PRIMITIVES;
use schemify_handler::App;

pub fn show(ui: &mut egui::Ui, app: &mut App) {
    let selected = app.panels().library_browser.selected_prim;

    let mut new_selected = selected;
    let mut place: Option<(String, String)> = None;

    egui::ScrollArea::vertical().show(ui, |ui| {
        for (i, prim) in PRIMITIVES.iter().enumerate() {
            let sel = selected == Some(i);
            let resp = ui.selectable_label(sel, prim.kind_name);
            if resp.clicked() {
                new_selected = Some(i);
            }
            if resp.double_clicked() {
                let prefix = if prim.prefix > 0 {
                    prim.prefix as char
                } else {
                    'X'
                };
                place = Some((prim.kind_name.to_string(), format!("{}1", prefix)));
            }
        }
    });

    if new_selected != selected {
        app.panels_mut().library_browser.selected_prim = new_selected;
    }
    if let Some((path, name)) = place {
        app.start_placement(path, name);
    }
}
