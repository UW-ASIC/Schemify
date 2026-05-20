use eframe::egui;
use schemify_core::commands::Command;
use schemify_handler::App;

pub fn show(ctx: &egui::Context, app: &mut App) {
    if !app.gui().dialogs.props.is_open {
        return;
    }

    // Pre-collect instance data while we have immutable access
    let inst_idx = app.gui().dialogs.props.inst_idx;
    let sch = app.schematic();
    if inst_idx >= sch.instances.len() {
        return;
    }

    let inst_name = app.resolve(sch.instances.name[inst_idx]).to_string();
    let kind = sch.instances.kind[inst_idx];
    let prop_start = sch.instances.prop_start[inst_idx] as usize;
    let prop_count = sch.instances.prop_count[inst_idx] as usize;

    let props: Vec<(String, String)> = (prop_start..prop_start + prop_count)
        .filter_map(|pi| {
            sch.properties.get(pi).map(|p| {
                (
                    app.resolve(p.key).to_string(),
                    app.resolve(p.value).to_string(),
                )
            })
        })
        .collect();

    // Initialize buffers on first frame
    let state = &mut app.gui_mut().dialogs.props;
    if !state.initialized {
        state.name_buf = inst_name.clone();
        state.prop_values = props.iter().map(|(_, v)| v.clone()).collect();
        state.initialized = true;
    }

    let mut cmds: Vec<Command> = Vec::new();

    egui::Window::new("Properties")
        .open(&mut state.is_open)
        .resizable(true)
        .default_width(350.0)
        .show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.label("Name:");
                ui.text_edit_singleline(&mut state.name_buf);
            });
            ui.label(format!("Type: {:?}", kind));
            ui.separator();

            egui::ScrollArea::vertical().show(ui, |ui| {
                for (i, (key, _)) in props.iter().enumerate() {
                    ui.horizontal(|ui| {
                        ui.label(format!("{}:", key));
                        if let Some(val) = state.prop_values.get_mut(i) {
                            ui.text_edit_singleline(val);
                        }
                    });
                }
            });

            ui.separator();
            if ui.button("Apply").clicked() {
                if state.name_buf != inst_name {
                    cmds.push(Command::RenameInstance {
                        idx: inst_idx,
                        new_name: state.name_buf.clone(),
                    });
                }
                for (i, (key, orig_val)) in props.iter().enumerate() {
                    if let Some(new_val) = state.prop_values.get(i) {
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

    if !state.is_open {
        state.initialized = false;
    }

    // Drop gui borrow, dispatch
    for cmd in cmds {
        app.dispatch(cmd);
    }
}
