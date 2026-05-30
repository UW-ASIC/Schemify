mod canvas;
mod chrome;
mod dialogs;
mod highlight;
mod keybinds;
mod math_render;
mod panels;
mod theme;

use eframe::egui;
use schemify_core::theme::ThemeTokens;
use schemify_handler::state::ViewMode;
use schemify_handler::App;

use keybinds::KeyCommand;
use theme::apply_theme;

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

    fn should_show_welcome(&self) -> bool {
        let docs = self.app.documents();
        docs.is_empty()
            || (docs.len() == 1
                && docs[0].name.is_empty()
                && docs[0].schematic.instances.is_empty()
                && docs[0].schematic.wires.is_empty())
    }
}

impl eframe::App for SchemifyApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        chrome::menu_bar(ctx, &mut self.app);
        chrome::tab_bar(ctx, &mut self.app);
        chrome::status_bar(ctx, &mut self.app);

        panels::plugin_right_panel(ctx, &self.app, &self.theme);

        egui::CentralPanel::default().show(ctx, |ui| {
            if self.should_show_welcome() {
                panels::welcome(ui, &mut self.app);
            } else {
                let view_mode = self.app.view().view_mode;
                match view_mode {
                    ViewMode::Documentation => {
                        panels::doc_view(ui, &mut self.app);
                    }
                    _ => {
                        let rect = ui.available_rect_before_wrap();
                        self.app.set_canvas_size(rect.width(), rect.height());
                        canvas::show(ui, &mut self.app);
                        panels::plugin_bottom(ui, &self.app, &self.theme);
                    }
                }
            }
        });

        // Hamburger button (top-left canvas overlay) — toggles file explorer window
        if !self.should_show_welcome() {
            egui::Area::new(egui::Id::new("hamburger_btn"))
                .fixed_pos(egui::pos2(8.0, 60.0))
                .order(egui::Order::Foreground)
                .show(ctx, |ui| {
                    let btn = egui::Button::new(egui::RichText::new("\u{2630}").size(18.0))
                        .min_size(egui::vec2(28.0, 28.0));
                    if ui.add(btn).on_hover_text("File Explorer").clicked() {
                        let open = &mut self.app.panels_mut().left_panel_open;
                        *open = !*open;
                    }
                });
        }

        // Floating file explorer window
        panels::file_explorer_window(ctx, &mut self.app, &self.theme);

        // Floating library browser window
        panels::library_window(ctx, &mut self.app);

        // "Generate Symbol" button (top-right overlay, schematic mode, saved files only)
        if self.app.view().view_mode == ViewMode::Schematic && !self.should_show_welcome() {
            let screen = ctx.screen_rect();
            let btn_w = 130.0;
            egui::Area::new(egui::Id::new("gen_symbol_btn"))
                .fixed_pos(egui::pos2(screen.right() - btn_w - 16.0, 64.0))
                .order(egui::Order::Foreground)
                .show(ctx, |ui| {
                    if ui.button("Generate Symbol").clicked() {
                        self.app.dispatch(
                            schemify_core::commands::Command::GenerateSymbolFromSchematic,
                        );
                    }
                });
        }

        dialogs::show_all(ctx, &mut self.app);
        panels::context_menu(ctx, &mut self.app);
        panels::plugin_overlays(ctx, &mut self.app, &self.theme);

        handle_shortcuts(ctx, &mut self.app);
    }
}

// ── Keyboard shortcuts (driven by keybinds table) ───────────────────────────

fn handle_shortcuts(ctx: &egui::Context, app: &mut App) {
    if app.editor().text_entry_focused || app.editor().command_mode {
        return;
    }

    if let Some(kb) = keybinds::lookup(ctx) {
        match &kb.command {
            KeyCommand::Dispatch(cmd) => app.dispatch(cmd.clone()),
            KeyCommand::EnterCommandMode => {
                app.editor_mut().command_mode = true;
            }
            KeyCommand::SetViewSchematic => {
                app.view_mut().view_mode = ViewMode::Schematic;
            }
            KeyCommand::SetViewSymbol => {
                app.view_mut().view_mode = ViewMode::Symbol;
            }
            KeyCommand::SetViewDoc => {
                app.view_mut().view_mode = ViewMode::Documentation;
            }
        }
    }
}

// ── Native entry (called by root `schemify` binary) ─────────────────────────

#[cfg(not(target_arch = "wasm32"))]
pub fn run_gui() -> eframe::Result<()> {
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

// ── WASM entry ──────────────────────────────────────────────────────────────

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

#[cfg(target_arch = "wasm32")]
#[wasm_bindgen(start)]
pub async fn wasm_start() -> Result<(), JsValue> {
    use wasm_bindgen::JsCast as _;

    let document = web_sys::window()
        .ok_or("no window")?
        .document()
        .ok_or("no document")?;
    let canvas = document
        .get_element_by_id("schemify_canvas")
        .ok_or("no canvas element with id 'schemify_canvas'")?
        .dyn_into::<web_sys::HtmlCanvasElement>()
        .map_err(|_| "element is not a canvas")?;

    // Fetch project data before starting the app
    let bundle = fetch_project_bundle().await.ok();

    let web_options = eframe::WebOptions::default();
    eframe::WebRunner::new()
        .start(
            canvas,
            web_options,
            Box::new(move |cc| {
                let mut schemify_app = SchemifyApp::new(cc);

                if let Some(b) = bundle {
                    for (path, content) in &b.files {
                        let name = path
                            .rsplit('/')
                            .next()
                            .unwrap_or(path)
                            .strip_suffix(".chn")
                            .unwrap_or(path);
                        schemify_app.app.open_from_content(name, content);
                    }
                }

                Ok(Box::new(schemify_app))
            }),
        )
        .await
        .map_err(|e| JsValue::from_str(&format!("{e}")))?;

    Ok(())
}

// ── Web helpers (WASM only) ──────────────────────────────────────────────────

#[cfg(target_arch = "wasm32")]
use serde::Deserialize;
#[cfg(target_arch = "wasm32")]
use std::collections::HashMap;

/// Bundled project data fetched from project.json at startup.
#[cfg(target_arch = "wasm32")]
#[derive(Debug, Deserialize)]
struct ProjectBundle {
    pub name: String,
    #[serde(default)]
    pub pdk: Option<String>,
    #[serde(default)]
    pub plugins: Vec<String>,
    /// Map of relative path -> file content.
    pub files: HashMap<String, String>,
}

/// Fetch and parse project.json from the same origin as the WASM app.
#[cfg(target_arch = "wasm32")]
async fn fetch_project_bundle() -> Result<ProjectBundle, String> {
    use wasm_bindgen::JsCast;
    use wasm_bindgen_futures::JsFuture;

    let window = web_sys::window().ok_or("no window")?;
    let resp_value = JsFuture::from(window.fetch_with_str("project.json"))
        .await
        .map_err(|e| format!("fetch failed: {e:?}"))?;
    let resp: web_sys::Response = resp_value.dyn_into().map_err(|_| "response cast failed")?;

    if !resp.ok() {
        return Err(format!("HTTP {}", resp.status()));
    }

    let text = JsFuture::from(resp.text().map_err(|_| "text() failed")?)
        .await
        .map_err(|e| format!("text await failed: {e:?}"))?;

    let json_str = text.as_string().ok_or("response not a string")?;

    serde_json::from_str(&json_str).map_err(|e| format!("JSON parse error: {e}"))
}
