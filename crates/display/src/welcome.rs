use eframe::egui;
use schemify_core::commands::Command;
use schemify_handler::App;

/// Render the welcome screen (centered, shown when no documents are open).
pub fn show(ui: &mut egui::Ui, app: &mut App) {
    let mut cmds: Vec<Command> = Vec::new();
    #[cfg(not(target_arch = "wasm32"))]
    let mut open_file = false;
    let mut import = false;

    let avail = ui.available_size();

    ui.vertical_centered(|ui| {
        // Vertical centering: top spacer
        ui.add_space((avail.y * 0.25).max(40.0));

        // Title
        ui.label(egui::RichText::new("SchemifyRS").size(32.0).strong());
        ui.add_space(4.0);
        ui.weak("Schematic Editor");
        ui.add_space(32.0);

        // Quick Actions
        ui.weak("Quick Actions");
        ui.add_space(8.0);

        ui.horizontal(|ui| {
            ui.add_space((avail.x * 0.5 - 200.0).max(0.0));
            #[cfg(not(target_arch = "wasm32"))]
            {
                if ui.button("  New Schematic  Ctrl+N  ").clicked() {
                    cmds.push(Command::FileNew);
                }
                if ui.button("  Open File  Ctrl+O  ").clicked() {
                    open_file = true;
                }
                if ui.button("  Import Project  ").clicked() {
                    import = true;
                }
            }
            #[cfg(target_arch = "wasm32")]
            {
                ui.weak("Loading project data...");
            }
        });

        ui.add_space(32.0);
        ui.separator();
        ui.add_space(32.0);

        #[cfg(not(target_arch = "wasm32"))]
        ui.weak("Press : for command mode  |  Ctrl+O to open  |  Ctrl+N for new schematic");
        #[cfg(target_arch = "wasm32")]
        ui.weak("Read-only web viewer  |  Simulation available via F5");
    });

    // Post-frame file dialog (native only)
    #[cfg(not(target_arch = "wasm32"))]
    if open_file {
        if let Some(path) = rfd::FileDialog::new()
            .add_filter("Schematic", &["chn"])
            .pick_file()
        {
            let _ = app.open_file(&path);
        }
    }
    if import {
        cmds.push(Command::OpenImportDialog);
    }

    for cmd in cmds {
        app.dispatch(cmd);
    }
}
