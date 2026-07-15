//! Right-click context menu on the canvas.

use eframe::egui;

use schemify_editor::handler::{App, ObjectRef};
use schemify_editor::schemify::{Color, Command};


use crate::state::{CtxHit, GuiState};


// ════════════════════════════════════════════════════════════
// Context menu
// ════════════════════════════════════════════════════════════

pub fn context_menu(ctx: &egui::Context, app: &mut App, gui: &mut GuiState) {
    if !gui.ctx_menu.open {
        return;
    }
    let cm = gui.ctx_menu.clone();

    let mut cmds: Vec<Command> = Vec::new();
    let mut close = false;
    let mut bus_rename = cm.bus_rename.clone();
    let mut bus_width = cm.bus_width;

    let sel_count = app.active_doc().selection.len();
    let has_selection = sel_count > 0;
    let has_instance = matches!(cm.hit, CtxHit::Obj(ObjectRef::Instance(_)));
    let has_hit = cm.hit != CtxHit::None;
    let is_group = sel_count > 1;
    let is_canvas = !has_selection && !has_hit;

    egui::Area::new(egui::Id::new("context_menu"))
        .fixed_pos(egui::pos2(cm.pixel_pos[0], cm.pixel_pos[1]))
        .order(egui::Order::Foreground)
        .show(ctx, |ui| {
            egui::Frame::menu(ui.style()).show(ui, |ui| {
                ui.set_min_width(160.0);

                let item = |ui: &mut egui::Ui, label: &str, enabled: bool| -> bool {
                    ui.add_enabled(enabled, egui::Button::new(label)).clicked()
                };

                if is_canvas {
                    if item(ui, "Paste", true) {
                        cmds.push(Command::Paste);
                        close = true;
                    }
                    if item(ui, "Insert from Library...", true) {
                        cmds.push(Command::OpenLibraryBrowser);
                        close = true;
                    }
                    ui.separator();
                    if item(ui, "Select All", true) {
                        cmds.push(Command::SelectAll);
                        close = true;
                    }
                } else if is_group {
                    ui.label(
                        egui::RichText::new(format!("{sel_count} items selected"))
                            .strong()
                            .small(),
                    );
                    ui.separator();
                    for (label, cmd) in [
                        ("Delete All", Command::DeleteSelected),
                        ("Rotate All CW", Command::RotateCw),
                        ("Flip All Horizontal", Command::FlipHorizontal),
                        ("Duplicate All", Command::DuplicateSelected),
                    ] {
                        if item(ui, label, true) {
                            cmds.push(cmd);
                            close = true;
                        }
                    }
                } else {
                    for (label, cmd, need_sel) in [
                        ("Cut", Command::Cut, true),
                        ("Copy", Command::Copy, true),
                        ("Paste", Command::Paste, false),
                        ("Delete", Command::DeleteSelected, true),
                        ("Duplicate", Command::DuplicateSelected, true),
                    ] {
                        if item(ui, label, !need_sel || has_selection) {
                            cmds.push(cmd);
                            close = true;
                        }
                    }
                    ui.separator();
                    for (label, cmd) in [
                        ("Rotate CW", Command::RotateCw),
                        ("Flip Horizontal", Command::FlipHorizontal),
                    ] {
                        if item(ui, label, has_selection) {
                            cmds.push(cmd);
                            close = true;
                        }
                    }
                    if has_instance {
                        ui.separator();
                        if item(ui, "Properties...", true) {
                            cmds.push(Command::OpenPropsDialog);
                            close = true;
                        }
                    }
                }

                // Wire-specific section.
                if let CtxHit::Obj(ObjectRef::Wire(wire_idx)) = cm.hit {
                    let wire_idx = wire_idx as usize;
                    ui.separator();
                    ui.label(egui::RichText::new("Wire").strong().small());
                    if item(ui, "Delete Wire", true) {
                        cmds.push(Command::DeleteWire(wire_idx));
                        close = true;
                    }
                    if item(ui, "Split Wire Here", true) {
                        cmds.push(Command::SplitWire {
                            idx: wire_idx,
                            x: cm.world_pos[0],
                            y: cm.world_pos[1],
                        });
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
                                cmds.push(Command::SetWireColor { idx: wire_idx, color });
                                close = true;
            
                            }
                        }
                    });
                }

                // Bus-specific section (inline editors).
                if let CtxHit::Obj(ObjectRef::Bus(bus_idx)) = cm.hit {
                    let bus_idx = bus_idx as usize;
                    ui.separator();
                    ui.label(egui::RichText::new("Bus").strong().small());
                    ui.horizontal(|ui| {
                        ui.label("Label");
                        ui.text_edit_singleline(&mut bus_rename);
                    });
                    ui.horizontal(|ui| {
                        ui.label("Width");
                        ui.add(egui::DragValue::new(&mut bus_width).range(1..=512));
                    });
                    if item(ui, "Apply", true) {
                        cmds.push(Command::RenameBus {
                            idx: bus_idx,
                            new_name: bus_rename.clone(),
                        });
                        cmds.push(Command::SetBusWidth {
                            idx: bus_idx,
                            width: bus_width,
                        });
                        close = true;
                    }
                    if item(ui, "Delete Bus", true) {
                        cmds.push(Command::DeleteBus(bus_idx));
                        close = true;
                    }
                }

                if let CtxHit::BusRipper(r_idx) = cm.hit {
                    ui.separator();
                    ui.label(egui::RichText::new("Bus Ripper").strong().small());
                    if item(ui, "Delete Ripper", true) {
                        cmds.push(Command::DeleteBusRipper(r_idx));
                        close = true;
                    }
                }
            });

            // Close on click outside.
            if ui.input(|i| i.pointer.any_click()) && !ui.rect_contains_pointer(ui.min_rect()) {
                close = true;
            }
        });

    if ctx.input(|i| i.key_pressed(egui::Key::Escape)) {
        close = true;
    }

    gui.ctx_menu.bus_rename = bus_rename;
    gui.ctx_menu.bus_width = bus_width;
    if close {
        gui.ctx_menu.open = false;
    }
    for cmd in cmds {
        app.dispatch(cmd).or_status(app);
    }
}
