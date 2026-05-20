use eframe::egui;
use schemify_core::commands::Command;
use schemify_core::types::Color;
use schemify_handler::App;

/// Show right-click context menu (floating overlay).
pub fn show(ctx: &egui::Context, app: &mut App) {
    let cm = app.ctx_menu().clone();
    if !cm.open {
        return;
    }

    let mut cmds: Vec<Command> = Vec::new();
    let mut close = false;
    let sel_count = app.selection().count();
    let has_selection = sel_count > 0;
    let has_instance = cm.inst_idx.is_some();
    let has_wire = cm.wire_idx.is_some();
    let is_group = sel_count > 1;
    let is_canvas = !has_selection && !has_instance && !has_wire;

    egui::Area::new(egui::Id::new("context_menu"))
        .fixed_pos(egui::pos2(cm.pixel_pos[0], cm.pixel_pos[1]))
        .order(egui::Order::Foreground)
        .show(ctx, |ui| {
            egui::Frame::menu(ui.style()).show(ui, |ui| {
                ui.set_min_width(160.0);

                if is_canvas {
                    // ── Canvas context (no selection, no hit) ────────────────
                    if ui.button("Paste").clicked() {
                        cmds.push(Command::Paste);
                        close = true;
                    }
                    if ui
                        .add_enabled(false, egui::Button::new("Insert from Library..."))
                        .clicked()
                    {
                        close = true;
                    }
                    ui.separator();
                    if ui.button("Select All").clicked() {
                        cmds.push(Command::SelectAll);
                        close = true;
                    }
                } else if is_group {
                    // ── Group context (multiple items selected) ──────────────
                    ui.label(
                        egui::RichText::new(format!("{sel_count} items selected"))
                            .strong()
                            .small(),
                    );
                    ui.separator();
                    if ui.button("Delete All").clicked() {
                        cmds.push(Command::DeleteSelected);
                        close = true;
                    }
                    if ui.button("Rotate All CW").clicked() {
                        cmds.push(Command::RotateCw);
                        close = true;
                    }
                    if ui.button("Flip All Horizontal").clicked() {
                        cmds.push(Command::FlipHorizontal);
                        close = true;
                    }
                    if ui.button("Duplicate All").clicked() {
                        cmds.push(Command::DuplicateSelected);
                        close = true;
                    }
                } else {
                    // ── Single-item context (instance or wire) ──────────────
                    if ui
                        .add_enabled(has_selection, egui::Button::new("Cut"))
                        .clicked()
                    {
                        cmds.push(Command::Cut);
                        close = true;
                    }
                    if ui
                        .add_enabled(has_selection, egui::Button::new("Copy"))
                        .clicked()
                    {
                        cmds.push(Command::Copy);
                        close = true;
                    }
                    if ui.button("Paste").clicked() {
                        cmds.push(Command::Paste);
                        close = true;
                    }
                    if ui
                        .add_enabled(has_selection, egui::Button::new("Delete"))
                        .clicked()
                    {
                        cmds.push(Command::DeleteSelected);
                        close = true;
                    }
                    if ui
                        .add_enabled(has_selection, egui::Button::new("Duplicate"))
                        .clicked()
                    {
                        cmds.push(Command::DuplicateSelected);
                        close = true;
                    }

                    ui.separator();

                    if ui
                        .add_enabled(has_selection, egui::Button::new("Rotate CW"))
                        .clicked()
                    {
                        cmds.push(Command::RotateCw);
                        close = true;
                    }
                    if ui
                        .add_enabled(has_selection, egui::Button::new("Flip Horizontal"))
                        .clicked()
                    {
                        cmds.push(Command::FlipHorizontal);
                        close = true;
                    }

                    if has_instance {
                        ui.separator();
                        if ui.button("Properties...").clicked() {
                            cmds.push(Command::OpenPropsDialog);
                            close = true;
                        }
                        // Hierarchy placeholders (disabled until handler support)
                        ui.add_enabled(false, egui::Button::new("Descend Schematic"));
                        ui.add_enabled(false, egui::Button::new("Descend Symbol"));
                    }
                }

                // ── Wire context (always shown when wire is hit) ────────────
                if let Some(wire_idx) = cm.wire_idx {
                    ui.separator();
                    ui.label(egui::RichText::new("Wire").strong().small());
                    if ui.button("Delete Wire").clicked() {
                        cmds.push(Command::DeleteWire(wire_idx));
                        close = true;
                    }
                    ui.menu_button("Set Color", |ui| {
                        let colors: &[(&str, Color)] = &[
                            ("Default", Color::NONE),
                            ("Red", Color::rgb(239, 83, 80)),
                            ("Green", Color::rgb(102, 187, 106)),
                            ("Blue", Color::rgb(79, 195, 247)),
                            ("Yellow", Color::rgb(255, 235, 59)),
                            ("Orange", Color::rgb(255, 167, 38)),
                            ("Purple", Color::rgb(171, 71, 188)),
                            ("Cyan", Color::rgb(38, 198, 218)),
                            ("White", Color::rgb(255, 255, 255)),
                        ];
                        for &(name, color) in colors {
                            if ui.button(name).clicked() {
                                cmds.push(Command::SetWireColor {
                                    idx: wire_idx,
                                    color,
                                });
                                close = true;
                                ui.close_menu();
                            }
                        }
                    });
                }
            });

            // Close on click outside
            if ui.input(|i| i.pointer.any_click()) && !ui.rect_contains_pointer(ui.min_rect()) {
                close = true;
            }
        });

    // Close on Escape
    if ctx.input(|i| i.key_pressed(egui::Key::Escape)) {
        close = true;
    }

    if close {
        app.ctx_menu_mut().open = false;
    }
    for cmd in cmds {
        app.dispatch(cmd);
    }
}
