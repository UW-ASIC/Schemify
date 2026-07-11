//! Instance/wire properties dialog.

use eframe::egui;

use schemify_core::handler::App;
use schemify_core::schemify::Command;


use crate::state::GuiState;


// ── Properties ──────────────────────────────────────────────

pub(crate) fn properties_dialog(ctx: &egui::Context, app: &mut App, gui: &mut GuiState) {
    if !app.state.dialogs.props_open {
        gui.props.initialized = false;
        return;
    }

    // Target: the explicitly-set index (find dialog) or the first selected
    // instance, refreshed on first frame.
    if !gui.props.initialized {
        if let Some(i) = app.active_doc().selection.instance_indices().next() {
            gui.props.inst_idx = i;
        }
    }
    let inst_idx = gui.props.inst_idx;
    let sch = app.schematic();
    if inst_idx >= sch.instances.len() {
        app.state.dialogs.props_open = false;
        return;
    }

    let inst_name = app.resolve(sch.instances.name[inst_idx]).to_string();
    let symbol_name = app.resolve(sch.instances.symbol[inst_idx]).to_string();
    let kind = sch.instances.kind[inst_idx];
    let (x, y) = (sch.instances.x[inst_idx], sch.instances.y[inst_idx]);
    let flags = sch.instances.flags[inst_idx];
    let props: Vec<(String, String)> = sch
        .instance_props(inst_idx)
        .iter()
        .map(|p| (app.resolve(p.key).to_string(), app.resolve(p.value).to_string()))
        .collect();

    if !gui.props.initialized {
        gui.props.name_buf = inst_name.clone();
        gui.props.prop_values = props.iter().map(|(_, v)| v.clone()).collect();
        gui.props.initialized = true;
    }

    let mut cmds: Vec<Command> = Vec::new();
    let mut is_open = true;

    egui::Window::new("Properties")
        .open(&mut is_open)
        .resizable(true)
        .default_width(350.0)
        .show(ctx, |ui| {
            ui.heading("Instance");
            egui::Grid::new("props_info_grid")
                .num_columns(2)
                .spacing([12.0, 4.0])
                .show(ui, |ui| {
                    ui.label("Name:");
                    ui.text_edit_singleline(&mut gui.props.name_buf);
                    ui.end_row();
                    ui.label("Symbol:");
                    ui.label(&symbol_name);
                    ui.end_row();
                    ui.label("Kind:");
                    ui.label(format!("{kind:?}"));
                    ui.end_row();
                });

            ui.separator();
            ui.label(egui::RichText::new("Position").strong());
            egui::Grid::new("props_pos_grid")
                .num_columns(2)
                .spacing([12.0, 4.0])
                .show(ui, |ui| {
                    ui.label("X:");
                    ui.label(format!("{x}"));
                    ui.end_row();
                    ui.label("Y:");
                    ui.label(format!("{y}"));
                    ui.end_row();
                    ui.label("Rotation:");
                    ui.label(format!("{}\u{b0}", flags.rotation() as u32 * 90));
                    ui.end_row();
                    ui.label("Flip:");
                    ui.label(if flags.flip() { "Yes" } else { "No" });
                    ui.end_row();
                });

            if !props.is_empty() {
                ui.separator();
                ui.label(egui::RichText::new("Properties").strong());
                egui::ScrollArea::vertical().show(ui, |ui| {
                    egui::Grid::new("props_values_grid")
                        .num_columns(2)
                        .spacing([12.0, 4.0])
                        .show(ui, |ui| {
                            for (i, (key, _)) in props.iter().enumerate() {
                                ui.label(format!("{key}:"));
                                if let Some(val) = gui.props.prop_values.get_mut(i) {
                                    ui.text_edit_singleline(val);
                                }
                                ui.end_row();
                            }
                        });
                });
            }

            ui.separator();
            if ui.button("Apply").clicked() {
                if gui.props.name_buf != inst_name {
                    cmds.push(Command::RenameInstance {
                        idx: inst_idx,
                        new_name: gui.props.name_buf.clone(),
                    });
                }
                for (i, (key, orig_val)) in props.iter().enumerate() {
                    if let Some(new_val) = gui.props.prop_values.get(i) {
                        if new_val != orig_val {
                            cmds.push(Command::SetInstanceProp {
                                idx: inst_idx,
                                key: key.clone(),
                                value: new_val.clone(),
                            });
                        }
                    }
                }
            }
        });

    if !is_open {
        app.state.dialogs.props_open = false;
        gui.props.initialized = false;
    }
    for cmd in cmds {
        app.dispatch(cmd).or_status(app);
    }
}
