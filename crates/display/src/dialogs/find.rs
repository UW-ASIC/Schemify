use eframe::egui;
use schemify_handler::state::FindResult;
use schemify_handler::App;

pub fn show(ctx: &egui::Context, app: &mut App) {
    if !app.gui().dialogs.find.is_open {
        return;
    }

    // Collect searchable names
    let instance_names: Vec<(usize, String)> = {
        let sch = app.schematic();
        (0..sch.instances.len())
            .map(|i| {
                let name = app.resolve(sch.instances.name[i]);
                (i, name.to_string())
            })
            .collect()
    };

    let find = &mut app.gui_mut().dialogs.find;

    egui::Window::new("Find")
        .open(&mut find.is_open)
        .resizable(true)
        .default_width(300.0)
        .show(ctx, |ui| {
            let resp = ui.text_edit_singleline(&mut find.query);
            if resp.changed() {
                find.results.clear();
                let query_lower = find.query.to_lowercase();
                if !query_lower.is_empty() {
                    for (idx, name) in &instance_names {
                        if name.to_lowercase().contains(&query_lower) {
                            find.results.push(FindResult {
                                label: name.clone(),
                                object_type: "Instance".to_string(),
                                index: *idx,
                            });
                        }
                    }
                }
                find.selected = None;
            }

            ui.separator();

            egui::ScrollArea::vertical().max_height(200.0).show(ui, |ui| {
                for (i, result) in find.results.iter().enumerate() {
                    let selected = find.selected == Some(i);
                    let label = format!("[{}] {}", result.object_type, result.label);
                    if ui.selectable_label(selected, &label).clicked() {
                        find.selected = Some(i);
                    }
                }
            });

            if find.results.is_empty() && !find.query.is_empty() {
                ui.label("No results.");
            }
        });
}
