//! eframe App impl and the native entry point.
//!
//! The GUI owns an `Arc<Mutex<App>>` so a headful MCP server (or any other
//! driver) can share the same core App: queries read it through the mutex,
//! mutations arrive over an external `mpsc::Receiver<Command>` pumped into
//! `App::dispatch` each frame (with an optional non-blocking step-delay).

use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use eframe::egui;

use schemify_core::config;
use schemify_core::handler::{App, ViewMode};
use schemify_core::schemify::Command;
use schemify_marketplace::Marketplace;

use crate::components;
use crate::handler::{self, CommandPump};
use crate::plugin_host::PluginHost;
use crate::state::{GuiState, Theme};

// ════════════════════════════════════════════════════════════
// eframe app
// ════════════════════════════════════════════════════════════

pub struct SchemifyGui {
    app: Arc<Mutex<App>>,
    gui: GuiState,
    pump: Option<CommandPump>,
    /// Dark-mode flag last applied to egui visuals (re-applied on change).
    applied_dark: Option<bool>,
    pub marketplace: Marketplace,
    pub plugins: PluginHost,
}

impl SchemifyGui {
    pub fn new(app: Arc<Mutex<App>>, pump: Option<CommandPump>) -> Self {
        let plugins_dir = config::global_plugins_dir();
        let cache_dir = config::cache_dir();
        // Discover + start plugins once at launch (F6 rescans later).
        let mut plugins = PluginHost::new();
        if let Ok(guard) = app.lock() {
            plugins.refresh(&guard.state.project_dir);
        }
        Self {
            app,
            gui: GuiState::default(),
            pump,
            applied_dark: None,
            marketplace: Marketplace::new(plugins_dir, cache_dir),
            plugins,
        }
    }

    /// Welcome screen iff the flag is set and the placeholder is untouched
    /// (external drivers like MCP may populate it without dispatching
    /// New/Open).
    fn should_show_welcome(app: &App) -> bool {
        let docs = &app.state.documents;
        app.state.view.show_welcome
            && docs.len() == 1
            && docs[0].schematic.instances.is_empty()
            && docs[0].schematic.wires.is_empty()
    }
}

impl eframe::App for SchemifyGui {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let mut guard = match self.app.lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };
        let app: &mut App = &mut guard;

        // External command channel (CLI / MCP driving).
        if let Some(pump) = &mut self.pump {
            pump.pump(app, ui.ctx());
        }

        // Plugin host: drain plugin messages, answer queries, broadcast
        // schematic/selection changes, flush widget interactions.
        self.plugins.pump(app, &self.gui.theme);

        // Theme follows the core dark-mode flag (ToggleColorScheme) plus
        // plugin theme overrides (highest priority wins).
        let dark = app.state.view.dark_mode;
        if self.applied_dark != Some(dark) || self.plugins.theme_dirty {
            self.gui.theme = self.plugins.resolve_theme(dark);
            self.gui.theme.apply(ui.ctx());
            self.applied_dark = Some(dark);
            self.plugins.theme_dirty = false;
            self.plugins
                .manager
                .notify_theme_changed(&self.gui.theme.to_tokens());
        }

        let welcome = Self::should_show_welcome(app);

        // Chrome.
        components::menu_bar(ui, app, &mut self.gui, &mut self.plugins);
        if !welcome {
            components::tab_bar(ui, app);
        }
        components::status_bar(ui, app, &mut self.gui);

        // Plugin panels claim side/bottom space before the CentralPanel.
        components::plugin_panels::show_panels(ui, &mut self.plugins, &self.gui.theme);

        // Central region: welcome / doc view / canvas.
        egui::CentralPanel::default().show(ui, |ui| {
            if welcome {
                components::welcome(ui, app);
            } else if app.state.view.view_mode == ViewMode::Documentation {
                components::doc_view(ui, app, &mut self.gui);
            } else {
                let rect = ui.available_rect_before_wrap();
                app.state.view.canvas_size = [rect.width(), rect.height()];
                crate::canvas::show(ui, app, &mut self.gui, &self.plugins.overlays);
            }
        });

        if !welcome {
            // Symbol mode: auto-generate button (top-right overlay).
            if app.state.view.view_mode == ViewMode::Symbol {
                let screen = ui.ctx().input(|i| i.viewport_rect());
                egui::Area::new(egui::Id::new("gen_symbol_btn"))
                    .fixed_pos(egui::pos2(screen.right() - 44.0, 64.0))
                    .order(egui::Order::Foreground)
                    .show(ui.ctx(), |ui| {
                        let btn = egui::Button::new(egui::RichText::new("\u{2728}").size(18.0))
                            .min_size(egui::vec2(28.0, 28.0));
                        if ui
                            .add(btn)
                            .on_hover_text("Auto-generate symbol from schematic")
                            .clicked()
                        {
                            app.dispatch(Command::GenerateSymbolFromSchematic);
                        }
                    });
            }
        }

        // Floating windows + dialogs + overlays.
        components::file_explorer_window(ui.ctx(), app);
        components::library_window(ui.ctx(), app, &mut self.gui);
        components::show_all_dialogs(ui.ctx(), app, &mut self.gui, &mut self.marketplace);
        components::context_menu(ui.ctx(), app, &mut self.gui);
        if !welcome && app.state.view.view_mode == ViewMode::Schematic {
            components::label_conflict_overlay(ui.ctx(), app);
        }

        // Waveform viewer — its own native window (immediate viewport).
        crate::wave_view::wave_window(ui.ctx(), app, &mut self.gui);

        // Optimizer windows — one native window per open instance.
        crate::optimizer_view::optimizer_windows(ui.ctx(), app, &mut self.gui);

        // Keyboard shortcuts (after UI so focused text edits win).
        handler::handle_shortcuts(ui.ctx(), app, &mut self.gui);

        // Plugin pushes (panel updates, overlays) arrive without input
        // events; keep polling while any plugin runs.
        if self.plugins.any_running() {
            ui.ctx().request_repaint_after(Duration::from_millis(250));
        }

        if app.state.quit_requested {
            ui.ctx().send_viewport_cmd(egui::ViewportCommand::Close);
        }
    }

    fn on_exit(&mut self, _gl: Option<&eframe::glow::Context>) {
        self.plugins.manager.shutdown_all();
    }
}

// ════════════════════════════════════════════════════════════
// Native entry point
// ════════════════════════════════════════════════════════════

/// Run the GUI on a shared core App.
///
#[cfg(target_os = "linux")]
fn is_wsl() -> bool {
    std::env::var_os("WSL_DISTRO_NAME").is_some()
        || std::path::Path::new("/proc/sys/fs/binfmt_misc/WSLInterop").exists()
}

#[cfg(not(target_os = "linux"))]
fn is_wsl() -> bool {
    false
}

/// * `rx` — optional external Command channel (headful CLI/MCP driving;
///   matches `schemify_mcp::Sink::Channel`'s `Sender<Command>`). Commands
///   are pumped into `App::dispatch` each frame.
/// * `step_delay` — optional pause between externally-queued commands
///   (visual stepping). Scheduled via `request_repaint_after`; the UI
///   thread never blocks.
pub fn run_gui(
    app: Arc<Mutex<App>>,
    rx: Option<Receiver<Command>>,
    step_delay: Option<Duration>,
) -> eframe::Result<()> {
    // WSL: wgpu can't create surfaces on WSLg (bugs #2641, #2762, #6841).
    // Use glow (glutin OpenGL) instead, and force X11 to avoid EGL mismatch.
    if is_wsl() {
        std::env::remove_var("WAYLAND_DISPLAY");
        log::info!("WSL detected: using glow renderer over X11");
    }
    let pump = rx.map(|rx| CommandPump::new(rx, step_delay));
    let options = eframe::NativeOptions {
        renderer: if is_wsl() {
            eframe::Renderer::Glow
        } else {
            eframe::Renderer::Wgpu
        },
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([1280.0, 800.0])
            .with_title("Schemify"),
        ..Default::default()
    };
    eframe::run_native(
        "Schemify",
        options,
        Box::new(move |cc| {
            Theme::dark().apply(&cc.egui_ctx);
            egui_extras::install_image_loaders(&cc.egui_ctx);
            Ok(Box::new(SchemifyGui::new(app, pump)))
        }),
    )
}

/// Convenience: run a standalone GUI owning a fresh App (no external driver).
pub fn run_gui_standalone() -> eframe::Result<()> {
    run_gui(Arc::new(Mutex::new(App::new())), None, None)
}
