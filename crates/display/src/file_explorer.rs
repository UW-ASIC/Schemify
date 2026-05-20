use eframe::egui;
use schemify_handler::App;

pub fn show(ui: &mut egui::Ui, app: &mut App) {
    #[cfg(not(target_arch = "wasm32"))]
    show_native(ui, app);

    #[cfg(target_arch = "wasm32")]
    show_web(ui, app);

    ui.separator();
    show_examples(ui, app);
}

fn show_examples(ui: &mut egui::Ui, app: &mut App) {
    use schemify_handler::examples::{self, ExampleKind};

    let examples = examples::all();

    egui::CollapsingHeader::new("Examples")
        .default_open(false)
        .show(ui, |ui| {
            for kind in [ExampleKind::Schematic, ExampleKind::Testbench, ExampleKind::Primitive] {
                let filtered: Vec<_> = examples.iter().filter(|e| e.kind == kind).collect();
                if filtered.is_empty() {
                    continue;
                }
                egui::CollapsingHeader::new(kind.label())
                    .default_open(kind == ExampleKind::Schematic)
                    .show(ui, |ui| {
                        for ex in &filtered {
                            if ui.selectable_label(false, ex.name).clicked() {
                                app.open_from_content(ex.name, ex.content);
                            }
                        }
                    });
            }
        });
}

#[cfg(not(target_arch = "wasm32"))]
fn show_native(ui: &mut egui::Ui, app: &mut App) {
    let project_dir = app.project_dir().to_path_buf();

    if project_dir.as_os_str().is_empty() {
        ui.label("No project directory set.");
        if ui.button("Set Project Directory").clicked() {
            if let Some(dir) = rfd::FileDialog::new().pick_folder() {
                app.set_project_dir(dir);
            }
        }
    } else {
        ui.horizontal(|ui| {
            ui.label("\u{1f4c1}");
            ui.label(project_dir.display().to_string());
        });
        ui.separator();

        if let Ok(entries) = std::fs::read_dir(&project_dir) {
            egui::ScrollArea::vertical().show(ui, |ui| {
                let mut files: Vec<_> = entries
                    .filter_map(|e| e.ok())
                    .filter(|e| {
                        e.path()
                            .extension()
                            .map_or(false, |ext| ext == "chn")
                    })
                    .collect();
                files.sort_by_key(|e| e.file_name());

                if files.is_empty() {
                    ui.label("No .chn files found.");
                }
                for entry in &files {
                    let name = entry.file_name();
                    let name_str = name.to_string_lossy();
                    if ui
                        .selectable_label(false, name_str.as_ref())
                        .double_clicked()
                    {
                        let _ = app.open_file(&entry.path());
                    }
                }
            });
        }

        ui.separator();
        if ui.button("Change Directory").clicked() {
            if let Some(dir) = rfd::FileDialog::new().pick_folder() {
                app.set_project_dir(dir);
            }
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn show_web(ui: &mut egui::Ui, app: &mut App) {
    ui.label("Project files (read-only)");
    ui.separator();

    let docs = app.documents();
    if docs.is_empty() {
        ui.weak("No schematics loaded.");
    } else {
        egui::ScrollArea::vertical().show(ui, |ui| {
            let active = app.active_doc_idx();
            for (i, doc) in docs.iter().enumerate() {
                let label = if doc.name.is_empty() {
                    "(untitled)"
                } else {
                    &doc.name
                };
                if ui.selectable_label(i == active, label).clicked() {
                    app.dispatch(schemify_core::commands::Command::SwitchTab(i));
                }
            }
        });
    }
}
