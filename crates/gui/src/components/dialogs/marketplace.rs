//! Marketplace browser dialog.

use eframe::egui;

use schemify_editor::handler::App;

use schemify_plugin_host::Marketplace;

use crate::state::GuiState;


// ── Marketplace ────────────────────────────────────────────

pub(crate) fn marketplace_dialog(
    ctx: &egui::Context,
    app: &mut App,
    gui: &mut GuiState,
    marketplace: &mut Marketplace,
) {
    if !app.state.dialogs.marketplace_open {
        return;
    }

    let mkt = &mut gui.marketplace;

    if !mkt.fetched {
        match marketplace.fetch_index() {
            Ok(_) => {
                mkt.results = marketplace.search("");
                mkt.status = format!("{} plugins available", mkt.results.len());
            }
            Err(e) => {
                mkt.status = format!("Failed to fetch registry: {e}");
            }
        }
        mkt.fetched = true;
    }

    let mut is_open = true;

    egui::Window::new("\u{1f4e6} Marketplace")
        .open(&mut is_open)
        .resizable(true)
        .default_size([720.0, 520.0])
        .min_size([480.0, 320.0])
        .show(ctx, |ui| {
            // Search bar
            ui.horizontal(|ui| {
                ui.label("Search:");
                let resp = ui.text_edit_singleline(&mut mkt.search_query);
                if resp.changed() {
                    mkt.results = marketplace.search(&mkt.search_query);
                    mkt.selected = None;
                }
                if ui.button("\u{21bb} Refresh").clicked() {
                    mkt.fetched = false;
                }
            });

            ui.add_space(4.0);

            // Status line
            ui.horizontal(|ui| {
                ui.label(
                    egui::RichText::new(&mkt.status)
                        .small()
                        .color(egui::Color32::GRAY),
                );
            });

            ui.separator();

            // Two-panel layout: list on left, detail on right
            let available = ui.available_size();
            let list_width = (available.x * 0.4).max(200.0).min(320.0);

            ui.horizontal(|ui| {
                // ── Left: plugin list ──
                ui.vertical(|ui| {
                    ui.set_width(list_width);
                    egui::ScrollArea::vertical()
                        .max_height(available.y - 8.0)
                        .show(ui, |ui| {
                            for (i, result) in mkt.results.iter().enumerate() {
                                let is_selected = mkt.selected == Some(i);
                                let entry = &result.entry;

                                let label = if result.installed {
                                    format!(
                                        "{}\n{}",
                                        entry.name,
                                        truncate_desc(&entry.description, 50),
                                    )
                                } else {
                                    format!(
                                        "{}\n{}",
                                        entry.name,
                                        truncate_desc(&entry.description, 50),
                                    )
                                };

                                let resp = ui.selectable_label(
                                    is_selected,
                                    egui::RichText::new(&label),
                                );

                                // Paint an "installed" badge on the right
                                if result.installed {
                                    ui.painter().text(
                                        resp.rect.right_center() - egui::vec2(8.0, 0.0),
                                        egui::Align2::RIGHT_CENTER,
                                        "\u{2713}",
                                        egui::FontId::proportional(14.0),
                                        egui::Color32::from_rgb(80, 200, 120),
                                    );
                                }

                                if resp.clicked() {
                                    mkt.selected = Some(i);
                                }
                            }

                            if mkt.results.is_empty() {
                                ui.label(
                                    egui::RichText::new("No plugins found")
                                        .color(egui::Color32::GRAY)
                                        .italics(),
                                );
                            }
                        });
                });

                ui.separator();

                // ── Right: detail pane ──
                ui.vertical(|ui| {
                    if let Some(idx) = mkt.selected {
                        if let Some(result) = mkt.results.get(idx).cloned() {
                            let entry = &result.entry;

                            // Header
                            ui.heading(&entry.name);
                            ui.horizontal(|ui| {
                                ui.label(
                                    egui::RichText::new(format!("v{}", entry.version))
                                        .color(egui::Color32::GRAY),
                                );
                                if !entry.author.is_empty() {
                                    ui.label("\u{2022}");
                                    ui.label(&entry.author);
                                }
                                if !entry.license.is_empty() {
                                    ui.label("\u{2022}");
                                    ui.label(
                                        egui::RichText::new(&entry.license)
                                            .color(egui::Color32::GRAY),
                                    );
                                }
                            });

                            ui.add_space(8.0);

                            // Description
                            ui.label(&entry.description);

                            ui.add_space(12.0);

                            // Capabilities
                            if !entry.capabilities.is_empty() {
                                ui.label(egui::RichText::new("Capabilities").strong());
                                ui.horizontal_wrapped(|ui| {
                                    for cap in &entry.capabilities {
                                        ui.label(
                                            egui::RichText::new(format!(" {cap} "))
                                                .background_color(egui::Color32::from_rgb(
                                                    50, 50, 70,
                                                ))
                                                .color(egui::Color32::from_rgb(180, 180, 220)),
                                        );
                                    }
                                });
                                ui.add_space(8.0);
                            }

                            // Platform availability
                            if !entry.downloads.is_empty() {
                                ui.label(egui::RichText::new("Platforms").strong());
                                ui.horizontal_wrapped(|ui| {
                                    let triple = marketplace.target_triple();
                                    for platform in entry.downloads.keys() {
                                        let is_current = platform == triple;
                                        let color = if is_current {
                                            egui::Color32::from_rgb(80, 200, 120)
                                        } else {
                                            egui::Color32::GRAY
                                        };
                                        let mut text =
                                            egui::RichText::new(platform).small().color(color);
                                        if is_current {
                                            text = text.strong();
                                        }
                                        ui.label(text);
                                    }
                                });
                                ui.add_space(12.0);
                            }

                            // Homepage link
                            if let Some(homepage) = &entry.homepage {
                                ui.horizontal(|ui| {
                                    ui.label("Homepage:");
                                    ui.label(
                                        egui::RichText::new(homepage)
                                            .color(egui::Color32::from_rgb(100, 149, 237)),
                                    );
                                });
                                ui.add_space(12.0);
                            }

                            // Action buttons
                            ui.separator();
                            ui.add_space(4.0);

                            let id = entry.id.clone();
                            let installed = result.installed;

                            ui.horizontal(|ui| {
                                if installed {
                                    if ui
                                        .button(
                                            egui::RichText::new("\u{2716} Uninstall")
                                                .color(egui::Color32::from_rgb(220, 80, 80)),
                                        )
                                        .clicked()
                                    {
                                        match marketplace.uninstall(&id) {
                                            Ok(()) => {
                                                mkt.status = format!("Uninstalled {id}");
                                                mkt.results = marketplace.search(&mkt.search_query);
                                                mkt.selected = None;
                                            }
                                            Err(e) => mkt.status = format!("Error: {e}"),
                                        }
                                    }

                                    let updates = marketplace.check_updates();
                                    if updates.iter().any(|u| u.id == id) {
                                        if ui
                                            .button(
                                                egui::RichText::new("\u{2b06} Update")
                                                    .color(egui::Color32::from_rgb(100, 180, 255)),
                                            )
                                            .clicked()
                                        {
                                            match marketplace
                                                .uninstall(&id)
                                                .and_then(|()| marketplace.install(&id))
                                            {
                                                Ok(()) => {
                                                    mkt.status = format!("Updated {id}");
                                                    mkt.results =
                                                        marketplace.search(&mkt.search_query);
                                                    mkt.selected = None;
                                                }
                                                Err(e) => mkt.status = format!("Error: {e}"),
                                            }
                                        }
                                    }
                                } else {
                                    let has_platform =
                                        entry.downloads.contains_key(marketplace.target_triple());
                                    if has_platform {
                                        if ui
                                            .button(
                                                egui::RichText::new("\u{2b07} Install")
                                                    .color(egui::Color32::from_rgb(80, 200, 120)),
                                            )
                                            .clicked()
                                        {
                                            match marketplace.install(&id) {
                                                Ok(()) => {
                                                    mkt.status = format!("Installed {id}");
                                                    mkt.results =
                                                        marketplace.search(&mkt.search_query);
                                                    mkt.selected = None;
                                                }
                                                Err(e) => mkt.status = format!("Error: {e}"),
                                            }
                                        }
                                    } else {
                                        ui.label(
                                            egui::RichText::new(format!(
                                                "Not available for {}",
                                                marketplace.target_triple()
                                            ))
                                            .color(egui::Color32::from_rgb(200, 150, 50)),
                                        );
                                    }
                                }
                            });
                        }
                    } else {
                        ui.centered_and_justified(|ui| {
                            ui.label(
                                egui::RichText::new("Select a plugin to view details")
                                    .color(egui::Color32::GRAY)
                                    .italics(),
                            );
                        });
                    }
                });
            });
        });

    if !is_open {
        app.state.dialogs.marketplace_open = false;
        gui.marketplace = Default::default();
    }
}

fn truncate_desc(s: &str, max: usize) -> String {
    if s.len() <= max {
        s.to_string()
    } else {
        let end = s.floor_char_boundary(max);
        format!("{}...", &s[..end])
    }
}
