use eframe::egui;
use schemify_handler::App;

pub fn show(ui: &mut egui::Ui, app: &mut App) {
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

        // List .chn files in project directory
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
