use eframe::egui;
use schemify_core::commands::Command;
use schemify_handler::state::DocEditorMode;
use schemify_handler::App;

/// Show the documentation editor view (when ViewMode::Documentation is active).
pub fn show(ui: &mut egui::Ui, app: &mut App) {
    let mode = app.gui().doc_editor.mode;
    let mut new_mode = mode;

    // Load doc content on first show
    if !app.gui().doc_editor.loaded {
        let doc_text = app.schematic().documentation.clone();
        app.gui_mut().doc_editor.buf = doc_text;
        app.gui_mut().doc_editor.loaded = true;
    }

    let mut save_requested = false;

    // Toolbar
    ui.horizontal(|ui| {
        if ui
            .selectable_label(mode == DocEditorMode::Edit, "Edit")
            .clicked()
        {
            new_mode = DocEditorMode::Edit;
        }
        if ui
            .selectable_label(mode == DocEditorMode::Preview, "Preview")
            .clicked()
        {
            new_mode = DocEditorMode::Preview;
        }
        ui.separator();
        if ui.button("Save").clicked() {
            save_requested = true;
        }
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            let word_count = app.gui().doc_editor.buf.split_whitespace().count();
            ui.weak(format!("{} words", word_count));
        });
    });
    ui.separator();

    if new_mode != mode {
        app.gui_mut().doc_editor.mode = new_mode;
    }

    match app.gui().doc_editor.mode {
        DocEditorMode::Edit => {
            egui::ScrollArea::vertical().show(ui, |ui| {
                ui.add(
                    egui::TextEdit::multiline(&mut app.gui_mut().doc_editor.buf)
                        .code_editor()
                        .desired_width(f32::INFINITY)
                        .desired_rows(30),
                );
            });
        }
        DocEditorMode::Preview => {
            egui::ScrollArea::vertical().show(ui, |ui| {
                let text = app.gui().doc_editor.buf.clone();
                render_simple_markdown(ui, &text);
            });
        }
    }

    if save_requested {
        let text = app.gui().doc_editor.buf.clone();
        app.dispatch(Command::SetDocumentation(text));
    }
}

/// Very simple markdown renderer (headers, bold, lists, code block markers).
fn render_simple_markdown(ui: &mut egui::Ui, text: &str) {
    let mut in_code_block = false;

    for line in text.lines() {
        let trimmed = line.trim();

        // Toggle code block state on fences
        if trimmed.starts_with("```") {
            in_code_block = !in_code_block;
            if in_code_block {
                ui.add_space(4.0);
            } else {
                ui.add_space(4.0);
            }
            continue;
        }

        if in_code_block {
            ui.label(egui::RichText::new(line).monospace());
            continue;
        }

        if trimmed.is_empty() {
            ui.add_space(8.0);
        } else if let Some(heading) = trimmed.strip_prefix("### ") {
            ui.label(egui::RichText::new(heading).strong().size(15.0));
        } else if let Some(heading) = trimmed.strip_prefix("## ") {
            ui.label(egui::RichText::new(heading).strong().size(18.0));
        } else if let Some(heading) = trimmed.strip_prefix("# ") {
            ui.heading(heading);
        } else if let Some(item) = trimmed.strip_prefix("- ") {
            ui.horizontal(|ui| {
                ui.label("  \u{2022}");
                ui.label(item);
            });
        } else if let Some(item) = trimmed.strip_prefix("* ") {
            ui.horizontal(|ui| {
                ui.label("  \u{2022}");
                ui.label(item);
            });
        } else {
            ui.label(line);
        }
    }
}
