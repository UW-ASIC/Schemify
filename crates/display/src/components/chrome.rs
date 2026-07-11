//! Per-frame chrome: tab bar, status bar (normal + vim command mode),
//! label-conflict overlay, welcome screen.

use eframe::egui;

use schemify_editor::handler::{App, ViewMode};
use schemify_editor::schemify::Command;


use crate::handler::execute_vim_command;
use crate::state::GuiState;

use super::*;

// ════════════════════════════════════════════════════════════
// Tab bar
// ════════════════════════════════════════════════════════════

pub fn tab_bar(ui: &mut egui::Ui, app: &mut App) {
    let doc_info: Vec<(String, bool)> = app
        .state
        .documents
        .iter()
        .map(|d| (d.display_name(), d.dirty))
        .collect();
    let active = app.state.active_doc;
    let tab_count = doc_info.len();
    let view_mode = app.state.view.view_mode;

    let mut cmd = None;
    let mut new_view_mode: Option<ViewMode> = None;

    egui::Panel::top("tab_bar").show(ui, |ui| {
        ui.horizontal(|ui| {
            let tab_h = ui.spacing().interact_size.y;
            let slant = tab_h * 0.4; // chevron tip depth

            // Reserve room on the right for "+" and the SCH/SYM/DOC toggle so
            // tabs always compress before reaching them.
            let reserved_right = 160.0;
            let avail = (ui.available_width() - reserved_right - slant).max(0.0);
            let tab_w = (avail / tab_count.max(1) as f32).clamp(24.0, 180.0);

            // Tabs interlock: each chevron tip fills the next tab's notch.
            ui.spacing_mut().item_spacing.x = 0.0;

            for (i, (name, dirty)) in doc_info.iter().enumerate() {
                let is_active = i == active;

                let (rect, response) =
                    ui.allocate_exact_size(egui::vec2(tab_w, tab_h), egui::Sense::click());

                // Close button (left side, hover-only). Hit-test it before
                // painting so the tab can react to its hover state.
                let can_close = tab_count > 1;
                let close_size = 12.0;
                let lslant = if i > 0 { slant } else { 0.0 };
                let close_center =
                    egui::pos2(rect.min.x + lslant + close_size * 0.5 + 4.0, rect.center().y);
                let close_rect =
                    egui::Rect::from_center_size(close_center, egui::vec2(close_size, close_size));
                let close_resp = can_close.then(|| {
                    ui.interact(close_rect, response.id.with("close"), egui::Sense::click())
                });
                let close_hovered = close_resp.as_ref().is_some_and(|r| r.hovered());

                // Chevron outline: straight left edge on the first tab, a
                // notch on the rest; arrow tip on the right of every tab.
                let (top, bottom, mid) = (rect.min.y, rect.max.y, rect.center().y);
                let (x0, x1) = (rect.min.x, rect.max.x);
                let bg = if is_active {
                    ui.visuals().selection.bg_fill
                } else if response.hovered() {
                    ui.visuals().widgets.hovered.bg_fill
                } else {
                    ui.visuals().widgets.noninteractive.weak_bg_fill
                };
                // Fill as two convex quads (the notch makes the full outline
                // concave, which egui's tessellator can't fill directly).
                let stroke = egui::Stroke::NONE;
                ui.painter().add(egui::Shape::convex_polygon(
                    vec![
                        egui::pos2(x0, top),
                        egui::pos2(x1, top),
                        egui::pos2(x1 + slant, mid),
                        egui::pos2(x0 + lslant, mid),
                    ],
                    bg,
                    stroke,
                ));
                ui.painter().add(egui::Shape::convex_polygon(
                    vec![
                        egui::pos2(x0 + lslant, mid - 0.5),
                        egui::pos2(x1 + slant, mid - 0.5),
                        egui::pos2(x1, bottom),
                        egui::pos2(x0, bottom),
                    ],
                    bg,
                    stroke,
                ));
                // Right-edge seam between tabs.
                let edge = ui.visuals().widgets.noninteractive.bg_stroke;
                ui.painter().add(egui::Shape::line(
                    vec![
                        egui::pos2(x1, top),
                        egui::pos2(x1 + slant, mid),
                        egui::pos2(x1, bottom),
                    ],
                    edge,
                ));

                // Left slot: red close cross when hovered, dirty dot otherwise.
                let text_color = if is_active {
                    ui.visuals().strong_text_color()
                } else {
                    ui.visuals().text_color()
                };
                if can_close && (response.hovered() || close_hovered) {
                    let red = if close_hovered {
                        egui::Color32::from_rgb(230, 60, 60)
                    } else {
                        egui::Color32::from_rgb(190, 80, 80)
                    };
                    if close_hovered {
                        ui.painter().circle_filled(
                            close_center,
                            close_size * 0.7,
                            red.gamma_multiply(0.25),
                        );
                    }
                    let r = close_size * 0.3;
                    let cross = egui::Stroke::new(1.5_f32, red);
                    ui.painter().line_segment(
                        [close_center + egui::vec2(-r, -r), close_center + egui::vec2(r, r)],
                        cross,
                    );
                    ui.painter().line_segment(
                        [close_center + egui::vec2(-r, r), close_center + egui::vec2(r, -r)],
                        cross,
                    );
                } else if *dirty {
                    ui.painter().circle_filled(close_center, 3.0, text_color);
                }

                // Title, clipped to the body of the chevron.
                let text_left = if can_close || *dirty {
                    close_rect.max.x + 4.0
                } else {
                    x0 + lslant + 6.0
                };
                let text_rect = egui::Rect::from_min_max(
                    egui::pos2(text_left, top),
                    egui::pos2(x1 - 2.0, bottom),
                );
                ui.painter().with_clip_rect(text_rect).text(
                    text_rect.left_center(),
                    egui::Align2::LEFT_CENTER,
                    name,
                    egui::FontId::proportional(13.0),
                    text_color,
                );
                response.clone().on_hover_text(name);

                if close_resp.is_some_and(|r| r.clicked()) {
                    cmd = Some(Command::CloseTab(i));
                } else if response.clicked() && !is_active {
                    cmd = Some(Command::SwitchTab(i));
                }
            }

            ui.add_space(slant + 6.0);
            if ui.small_button("+").on_hover_text("New Tab").clicked() {
                cmd = Some(Command::NewTab);
            }

            // View mode toggle (right-aligned).
            ui.spacing_mut().item_spacing.x = 4.0;
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                for (label, mode) in [
                    ("DOC", ViewMode::Documentation),
                    ("SYM", ViewMode::Symbol),
                    ("SCH", ViewMode::Schematic),
                ] {
                    if ui.selectable_label(view_mode == mode, label).clicked() {
                        new_view_mode = Some(mode);
                    }
                }
            });
        });
    });

    if let Some(c) = cmd {
        app.dispatch(c).or_status(app);
    }
    if let Some(mode) = new_view_mode {
        app.state.view.view_mode = mode;
    }
}

// ════════════════════════════════════════════════════════════
// Status bar (normal + vim command mode)
// ════════════════════════════════════════════════════════════

pub fn status_bar(ui: &mut egui::Ui, app: &mut App, gui: &mut GuiState) {
    egui::Panel::bottom("status_bar").show(ui, |ui| {
        ui.horizontal(|ui| {
            if gui.command_mode {
                show_command_mode(ui, app, gui);
            } else {
                show_normal_status(ui, app);
            }
        });
    });
}

fn show_normal_status(ui: &mut egui::Ui, app: &App) {
    let cursor = app.state.canvas.cursor_world;
    let zoom = app.active_doc().viewport.zoom;

    if !app.state.status_msg.is_empty() {
        ui.label(&app.state.status_msg);
        ui.separator();
    }
    ui.label(format!("({}, {})", cursor[0], cursor[1]));
    ui.separator();
    ui.label(format!("{:?}", app.state.tool.active));
    ui.separator();
    ui.label(format!("snap: {}", app.state.tool.snap_size as i32));
    ui.separator();
    ui.label(match app.state.view.view_mode {
        ViewMode::Schematic => "SCH",
        ViewMode::Symbol => "SYM",
        ViewMode::Documentation => "DOC",
    });
    ui.separator();
    ui.weak(": for commands");
    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
        ui.label(format!("{:.0}%", zoom * 100.0));
    });
}

fn show_command_mode(ui: &mut egui::Ui, app: &mut App, gui: &mut GuiState) {
    ui.label(":");
    let response = ui.add(
        egui::TextEdit::singleline(&mut gui.command_buf)
            .desired_width(ui.available_width() - 180.0)
            .hint_text("command"),
    );
    if !response.has_focus() {
        response.request_focus();
    }
    gui.text_entry_focused = true;

    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
        ui.weak("Enter to run | Esc to cancel");
    });

    // Read keys via the input system: the TextEdit consumes the key events.
    let (enter, escape) = ui.ctx().input(|i| {
        (i.key_pressed(egui::Key::Enter), i.key_pressed(egui::Key::Escape))
    });

    if enter {
        let line = std::mem::take(&mut gui.command_buf);
        gui.command_mode = false;
        gui.text_entry_focused = false;
        execute_vim_command(&line, app, gui);
    } else if escape {
        gui.command_buf.clear();
        gui.command_mode = false;
        gui.text_entry_focused = false;
    }
}

// ════════════════════════════════════════════════════════════
// Label conflict overlay
// ════════════════════════════════════════════════════════════

pub fn label_conflict_overlay(ctx: &egui::Context, app: &mut App) {
    let conflicts: Vec<usize> = app.connectivity().label_conflicts.iter().copied().collect();
    if conflicts.is_empty() {
        return;
    }

    let sch = app.schematic();
    let mut names: Vec<&str> = conflicts
        .iter()
        .filter(|&&idx| idx < sch.instances.len())
        .map(|&idx| app.resolve(sch.instances.name[idx]))
        .collect();
    names.sort_unstable();
    names.dedup();
    let label_list = names.join(", ");

    let screen = ctx.input(|i| i.viewport_rect());
    egui::Area::new(egui::Id::new("label_conflict_warn"))
        .fixed_pos(egui::pos2(screen.right() - 340.0, screen.bottom() - 60.0))
        .order(egui::Order::Foreground)
        .show(ctx, |ui| {
            egui::Frame::new()
                .fill(egui::Color32::from_rgba_premultiplied(80, 20, 20, 220))
                .corner_radius(6.0)
                .inner_margin(egui::Margin::same(8))
                .show(ui, |ui| {
                    ui.label(
                        egui::RichText::new(format!(
                            "\u{26A0} Conflicting net labels: {label_list}"
                        ))
                        .color(egui::Color32::from_rgb(255, 200, 200))
                        .size(13.0),
                    );
                });
        });
}

// ════════════════════════════════════════════════════════════
// Welcome screen
// ════════════════════════════════════════════════════════════

pub fn welcome(ui: &mut egui::Ui, app: &mut App) {
    let mut cmds: Vec<Command> = Vec::new();
    let mut open_file = false;
    let avail = ui.available_size();

    ui.vertical_centered(|ui| {
        ui.add_space((avail.y * 0.25).max(40.0));
        ui.label(egui::RichText::new("Schemify").size(32.0).strong());
        ui.add_space(4.0);
        ui.weak("Schematic Editor");
        ui.add_space(32.0);
        ui.weak("Quick Actions");
        ui.add_space(8.0);

        ui.horizontal(|ui| {
            ui.add_space((avail.x * 0.5 - 200.0).max(0.0));
            if ui.button("  New Schematic  Ctrl+N  ").clicked() {
                cmds.push(Command::FileNew);
            }
            if ui.button("  Open File  Ctrl+O  ").clicked() {
                open_file = true;
            }
            if ui.button("  Import Netlist  ").clicked() {
                cmds.push(Command::OpenImportDialog);
            }
        });

        ui.add_space(32.0);
        ui.separator();
        ui.add_space(32.0);
        ui.weak("Press : for command mode  |  Ctrl+O to open  |  Ctrl+N for new schematic");
    });

    if open_file {
        open_file_dialog(app);
    }
    for cmd in cmds {
        app.dispatch(cmd).or_status(app);
    }
}
