use eframe::egui;
use schemify_handler::state::PrimType;
use schemify_handler::App;

/// Generate minimal .chn_prim file content.
fn generate_chn_prim(name: &str, prim_type: PrimType, pins: &[&str]) -> String {
    let prefix = match prim_type {
        PrimType::Behavioral => "X",
        PrimType::Spice => "X",
        PrimType::Digital => "U",
    };

    let mut out = String::new();
    out.push_str("chn_prim\n");
    out.push_str(&format!("SYMBOL {}\n", name));
    out.push_str(&format!("spice_prefix: {}\n", prefix));
    out.push_str(&format!("pins [{}]\n", pins.len()));
    for pin in pins {
        out.push_str(&format!("  {}\n", pin));
    }

    // Generate a simple rectangular drawing with pin positions
    out.push_str("drawing:\n");
    out.push_str("  lines:\n");
    out.push_str("    (-20, -20) (20, -20)\n");
    out.push_str("    (20, -20) (20, 20)\n");
    out.push_str("    (20, 20) (-20, 20)\n");
    out.push_str("    (-20, 20) (-20, -20)\n");
    out.push_str("  pin_positions:\n");

    let pin_count = pins.len();
    for (i, pin) in pins.iter().enumerate() {
        // Distribute pins vertically along the symbol
        let y = if pin_count <= 1 {
            0
        } else {
            -30 + (i as i32 * 60) / (pin_count as i32 - 1).max(1)
        };
        out.push_str(&format!("    {}: (0, {})\n", pin, y));
    }

    out
}

pub fn show(ctx: &egui::Context, app: &mut App) {
    // Read project_dir before mutable borrow
    let project_dir = app.project_dir().to_path_buf();

    let state = &mut app.gui_mut().dialogs.new_prim;
    if !state.is_open {
        return;
    }

    egui::Window::new("New Primitive")
        .open(&mut state.is_open)
        .resizable(false)
        .default_width(350.0)
        .show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.label("Type:");
                egui::ComboBox::from_id_salt("prim_type")
                    .selected_text(format!("{:?}", state.prim_type))
                    .show_ui(ui, |ui| {
                        ui.selectable_value(
                            &mut state.prim_type,
                            PrimType::Behavioral,
                            "Behavioral",
                        );
                        ui.selectable_value(&mut state.prim_type, PrimType::Spice, "SPICE");
                        ui.selectable_value(&mut state.prim_type, PrimType::Digital, "Digital");
                    });
            });

            ui.horizontal(|ui| {
                ui.label("Name:");
                ui.text_edit_singleline(&mut state.name_buf);
            });

            ui.label("Pins (comma-separated):");
            ui.text_edit_singleline(&mut state.pins_buf);

            if !state.status_msg.is_empty() {
                ui.colored_label(egui::Color32::YELLOW, &state.status_msg);
            }

            ui.separator();
            if ui.button("Create").clicked() {
                if state.name_buf.is_empty() {
                    state.status_msg = "Name required".to_string();
                } else {
                    let pins_list: Vec<&str> = state
                        .pins_buf
                        .split(',')
                        .map(|s| s.trim())
                        .filter(|s| !s.is_empty())
                        .collect();

                    #[cfg(not(target_arch = "wasm32"))]
                    {
                        if project_dir.as_os_str().is_empty() {
                            state.status_msg = "Set project directory first".to_string();
                        } else {
                            let file_name = format!("{}.chn_prim", state.name_buf);
                            let path = project_dir.join(&file_name);
                            let content =
                                generate_chn_prim(&state.name_buf, state.prim_type, &pins_list);
                            match std::fs::write(&path, &content) {
                                Ok(_) => {
                                    state.status_msg = format!("Created {}", file_name);
                                }
                                Err(e) => {
                                    state.status_msg = format!("Error: {}", e);
                                }
                            }
                        }
                    }

                    #[cfg(target_arch = "wasm32")]
                    {
                        let _ = &pins_list;
                        state.status_msg =
                            format!("Created primitive: {} (no file I/O on web)", state.name_buf);
                    }
                }
            }
        });
}
