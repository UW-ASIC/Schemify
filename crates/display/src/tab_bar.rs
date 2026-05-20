use eframe::egui;
use schemify_core::commands::Command;
use schemify_handler::state::ViewMode;
use schemify_handler::App;

pub fn show(ctx: &egui::Context, app: &mut App) {
    let doc_info: Vec<(String, bool)> = app
        .documents()
        .iter()
        .map(|d| (d.name.clone(), d.dirty))
        .collect();
    let active = app.active_doc_idx();
    let tab_count = doc_info.len();
    let view_mode = app.view().view_mode;

    let mut cmd = None;
    let mut new_view_mode: Option<ViewMode> = None;

    egui::TopBottomPanel::top("tab_bar").show(ctx, |ui| {
        ui.horizontal(|ui| {
            // Cap each tab width so they compress when many are open
            let max_tab_w = if tab_count <= 1 {
                200.0
            } else {
                (600.0 / tab_count as f32).clamp(60.0, 200.0)
            };

            for (i, (name, dirty)) in doc_info.iter().enumerate() {
                let is_active = i == active;
                let display = if name.is_empty() { "Untitled" } else { name.as_str() };

                // Extract just the filename (basename)
                let basename = display
                    .rsplit(&['/', '\\'][..])
                    .next()
                    .unwrap_or(display);

                let label = if *dirty {
                    format!("\u{25cf} {basename}")
                } else {
                    basename.to_string()
                };

                // Tab button (width-constrained)
                let resp = ui.add_sized(
                    [max_tab_w, ui.spacing().interact_size.y],
                    egui::SelectableLabel::new(is_active, &label),
                );
                if resp.clicked() && !is_active {
                    cmd = Some(Command::SwitchTab(i));
                }

                // Close button (only when multiple tabs)
                if tab_count > 1 {
                    let close = ui.small_button("\u{2715}");
                    if close.clicked() {
                        cmd = Some(Command::CloseTab(i));
                    }
                }

                if i + 1 < tab_count {
                    ui.separator();
                }
            }

            // New tab button
            ui.add_space(4.0);
            if ui.small_button("+").on_hover_text("New Tab").clicked() {
                cmd = Some(Command::NewTab);
            }

            // Push view mode toggle to the right
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let sch = view_mode == ViewMode::Schematic;
                let sym = view_mode == ViewMode::Symbol;
                let doc = view_mode == ViewMode::Documentation;

                if ui.selectable_label(doc, "DOC").clicked() {
                    new_view_mode = Some(ViewMode::Documentation);
                }
                if ui.selectable_label(sym, "SYM").clicked() {
                    new_view_mode = Some(ViewMode::Symbol);
                }
                if ui.selectable_label(sch, "SCH").clicked() {
                    new_view_mode = Some(ViewMode::Schematic);
                }
            });
        });
    });

    if let Some(c) = cmd {
        app.dispatch(c);
    }
    if let Some(mode) = new_view_mode {
        app.view_mut().view_mode = mode;
    }
}
