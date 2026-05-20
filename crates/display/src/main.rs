mod command_bar;
mod dialogs;
mod file_explorer;
mod library_browser;
mod slot_renderer;
mod status_bar;
mod tab_bar;
mod theme_bridge;
mod toolbar;

use eframe::egui;
use schemify_core::theme::ThemeTokens;
use schemify_handler::state::LeftPanelTab;
use schemify_handler::App;

use theme_bridge::apply_theme;

struct SchemifyApp {
    app: App,
    #[allow(dead_code)]
    theme: ThemeTokens,
}

impl SchemifyApp {
    fn new(cc: &eframe::CreationContext<'_>) -> Self {
        let theme = ThemeTokens::dark();
        apply_theme(&cc.egui_ctx, &theme);
        Self {
            app: App::new(),
            theme,
        }
    }
}

impl eframe::App for SchemifyApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        // Top panels (order matters: first panel = topmost)
        tab_bar::show(ctx, &mut self.app);
        toolbar::show(ctx, &mut self.app);

        // Bottom panel
        status_bar::show(ctx, &self.app);

        // Left sidebar
        let left_tab = self.app.gui().left_panel_tab;
        let mut new_tab = left_tab;

        egui::SidePanel::left("left_panel")
            .default_width(200.0)
            .resizable(true)
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    if ui
                        .selectable_label(left_tab == LeftPanelTab::FileExplorer, "Files")
                        .clicked()
                    {
                        new_tab = LeftPanelTab::FileExplorer;
                    }
                    if ui
                        .selectable_label(left_tab == LeftPanelTab::Library, "Library")
                        .clicked()
                    {
                        new_tab = LeftPanelTab::Library;
                    }
                });
                ui.separator();

                match left_tab {
                    LeftPanelTab::FileExplorer => file_explorer::show(ui, &mut self.app),
                    LeftPanelTab::Library => library_browser::show(ui, &mut self.app),
                }

                // Plugin panels in left slot
                slot_renderer::show_left(ui, &self.app);
            });

        if new_tab != left_tab {
            self.app.gui_mut().left_panel_tab = new_tab;
        }

        // Central panel (canvas placeholder)
        egui::CentralPanel::default().show(ctx, |ui| {
            let rect = ui.available_rect_before_wrap();
            self.app.set_canvas_size(rect.width(), rect.height());

            ui.painter()
                .rect_filled(rect, 0.0, ui.visuals().extreme_bg_color);

            ui.put(rect, |ui: &mut egui::Ui| {
                ui.centered_and_justified(|ui| {
                    ui.label("SchemifyRS \u{2014} canvas placeholder");
                })
                .response
            });
        });

        // Floating dialogs
        dialogs::show_all(ctx, &mut self.app);

        // Command bar overlay
        command_bar::show(ctx, &mut self.app);
    }
}

fn main() -> eframe::Result<()> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([1280.0, 800.0])
            .with_title("SchemifyRS"),
        ..Default::default()
    };
    eframe::run_native(
        "SchemifyRS",
        options,
        Box::new(|cc| Ok(Box::new(SchemifyApp::new(cc)))),
    )
}
