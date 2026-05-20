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

    // Track actions to perform after the window closure
    let mut open_props_idx: Option<usize> = None;

    egui::Window::new("Find")
        .open(&mut find.is_open)
        .resizable(true)
        .default_width(300.0)
        .show(ctx, |ui| {
            // Search field
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

            // Arrow key navigation
            let up = ui.input(|i| i.key_pressed(egui::Key::ArrowUp));
            let down = ui.input(|i| i.key_pressed(egui::Key::ArrowDown));
            let enter = ui.input(|i| i.key_pressed(egui::Key::Enter));

            if !find.results.is_empty() {
                if down {
                    find.selected = Some(match find.selected {
                        Some(s) => (s + 1).min(find.results.len() - 1),
                        None => 0,
                    });
                }
                if up {
                    find.selected = Some(match find.selected {
                        Some(s) => s.saturating_sub(1),
                        None => 0,
                    });
                }
                if enter {
                    if let Some(sel) = find.selected {
                        if let Some(result) = find.results.get(sel) {
                            if result.object_type == "Instance" {
                                open_props_idx = Some(result.index);
                            }
                        }
                    }
                }
            }

            // Result count
            if !find.query.is_empty() {
                ui.horizontal(|ui| {
                    let count = find.results.len();
                    ui.weak(format!(
                        "{} result{}",
                        count,
                        if count == 1 { "" } else { "s" }
                    ));
                });
            }

            ui.separator();

            // Results list
            egui::ScrollArea::vertical().max_height(200.0).show(ui, |ui| {
                for (i, result) in find.results.iter().enumerate() {
                    let selected = find.selected == Some(i);
                    let label = format!("[{}] {}", result.object_type, result.label);
                    let resp = ui.selectable_label(selected, &label);
                    if resp.clicked() {
                        find.selected = Some(i);
                    }
                    if resp.double_clicked() && result.object_type == "Instance" {
                        open_props_idx = Some(result.index);
                    }
                }
            });

            if find.results.is_empty() && !find.query.is_empty() {
                ui.label("No results.");
            }

            // "Open Properties" button for selected result
            if let Some(sel) = find.selected {
                if let Some(result) = find.results.get(sel) {
                    if result.object_type == "Instance" {
                        ui.separator();
                        if ui.button("Open Properties").clicked() {
                            open_props_idx = Some(result.index);
                        }
                    }
                }
            }
        });

    // Open properties dialog for the selected instance
    if let Some(idx) = open_props_idx {
        let props = &mut app.gui_mut().dialogs.props;
        props.is_open = true;
        props.inst_idx = idx;
        props.initialized = false;
    }
}
