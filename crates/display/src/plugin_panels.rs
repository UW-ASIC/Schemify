use eframe::egui;
use schemify_core::commands::Command;
use schemify_handler::state::{PanelLayout, PluginLoadState};
use schemify_handler::App;

// ── Widget Protocol ─────────────────────────────────────────────────────────

/// Widget types that plugins can send for rendering.
/// Matches the Zig PluginPanels widget tags.
#[derive(Debug, Clone)]
pub enum ParsedWidget {
    Label(String),
    Button {
        label: String,
        action: String,
    },
    Toggle {
        label: String,
        value: bool,
        action: String,
    },
    Slider {
        label: String,
        min: f32,
        max: f32,
        value: f32,
        action: String,
    },
    TextInput {
        label: String,
        value: String,
        action: String,
    },
    Dropdown {
        label: String,
        options: Vec<String>,
        selected: usize,
        action: String,
    },
    Separator,
    Section {
        label: String,
        collapsed: bool,
        children: Vec<ParsedWidget>,
    },
}

/// Render a single plugin widget. Returns a command if the widget triggered an action.
fn render_widget(ui: &mut egui::Ui, widget: &ParsedWidget) -> Option<Command> {
    match widget {
        ParsedWidget::Label(text) => {
            ui.label(text);
            None
        }
        ParsedWidget::Button { label, action } => {
            if ui.button(label).clicked() {
                Some(Command::PluginCommand {
                    tag: action.clone(),
                    payload: Vec::new(),
                })
            } else {
                None
            }
        }
        ParsedWidget::Toggle {
            label,
            value,
            action,
        } => {
            let mut v = *value;
            if ui.checkbox(&mut v, label).changed() {
                Some(Command::PluginCommand {
                    tag: action.clone(),
                    payload: vec![v as u8],
                })
            } else {
                None
            }
        }
        ParsedWidget::Slider {
            label,
            min,
            max,
            value,
            action: _,
        } => {
            let mut v = *value;
            ui.horizontal(|ui| {
                ui.label(label);
                ui.add(egui::Slider::new(&mut v, *min..=*max));
            });
            None // slider changes would be sent on release in a real implementation
        }
        ParsedWidget::TextInput {
            label,
            value,
            action: _,
        } => {
            let mut buf = value.clone();
            ui.horizontal(|ui| {
                ui.label(label);
                ui.text_edit_singleline(&mut buf);
            });
            None
        }
        ParsedWidget::Dropdown {
            label,
            options,
            selected,
            action: _,
        } => {
            let mut sel = *selected;
            ui.horizontal(|ui| {
                ui.label(label);
                egui::ComboBox::from_id_salt(label)
                    .selected_text(options.get(sel).map(|s| s.as_str()).unwrap_or(""))
                    .show_ui(ui, |ui| {
                        for (i, opt) in options.iter().enumerate() {
                            ui.selectable_value(&mut sel, i, opt);
                        }
                    });
            });
            None
        }
        ParsedWidget::Separator => {
            ui.separator();
            None
        }
        ParsedWidget::Section {
            label,
            collapsed,
            children,
        } => {
            let mut cmd = None;
            egui::CollapsingHeader::new(label)
                .default_open(!collapsed)
                .show(ui, |ui| {
                    for child in children {
                        if let Some(c) = render_widget(ui, child) {
                            cmd = Some(c);
                        }
                    }
                });
            cmd
        }
    }
}

/// Render a list of plugin widgets, collecting any triggered commands.
pub fn render_widget_list(ui: &mut egui::Ui, widgets: &[ParsedWidget]) -> Vec<Command> {
    let mut cmds = Vec::new();
    for widget in widgets {
        if let Some(cmd) = render_widget(ui, widget) {
            cmds.push(cmd);
        }
    }
    cmds
}

// ── Left / Right Sidebar ─────────────────────────────────────────────────────

/// Render plugin panels assigned to the given sidebar layout.
pub fn show_sidebar(ui: &mut egui::Ui, app: &App, layout: PanelLayout) {
    let panels = &app.panels().plugins_ui.panels;
    for panel in panels {
        if panel.layout != layout || !panel.visible {
            continue;
        }
        ui.collapsing(&panel.name, |ui| {
            draw_panel_body(ui, panel.load_state);
        });
    }
}

/// Show a right side panel if any right-sidebar plugin panels are visible.
pub fn show_right_panel(ctx: &egui::Context, app: &App) {
    let has_right = app
        .panels()
        .plugins_ui
        .panels
        .iter()
        .any(|p| p.layout == PanelLayout::RightSidebar && p.visible);

    if !has_right {
        return;
    }

    egui::SidePanel::right("right_plugin_panel")
        .default_width(220.0)
        .resizable(true)
        .show(ctx, |ui| {
            show_sidebar(ui, app, PanelLayout::RightSidebar);
        });
}

// ── Bottom Bar ───────────────────────────────────────────────────────────────

/// Render plugin panels in the bottom bar area (below canvas).
pub fn show_bottom(ui: &mut egui::Ui, app: &App) {
    let panels = &app.panels().plugins_ui.panels;
    let has_bottom = panels
        .iter()
        .any(|p| p.layout == PanelLayout::BottomBar && p.visible);

    if !has_bottom {
        return;
    }

    ui.separator();
    ui.allocate_ui_with_layout(
        egui::vec2(ui.available_width(), 150.0),
        egui::Layout::left_to_right(egui::Align::Min),
        |ui| {
            for panel in panels {
                if panel.layout != PanelLayout::BottomBar || !panel.visible {
                    continue;
                }
                ui.group(|ui| {
                    ui.label(egui::RichText::new(&panel.name).strong());
                    draw_panel_body(ui, panel.load_state);
                });
            }
        },
    );
}

// ── Overlays ─────────────────────────────────────────────────────────────────

/// Render plugin panels as floating overlay windows.
pub fn show_overlays(ctx: &egui::Context, app: &mut App) {
    // Collect overlay panel info to avoid borrow conflicts
    let overlay_info: Vec<(usize, String, PluginLoadState)> = app
        .panels()
        .plugins_ui
        .panels
        .iter()
        .enumerate()
        .filter(|(_, p)| p.layout == PanelLayout::Overlay && p.visible)
        .map(|(i, p)| (i, p.name.clone(), p.load_state))
        .collect();

    for (idx, name, load_state) in &overlay_info {
        let mut open = true;
        egui::Window::new(name)
            .id(egui::Id::new("plugin_overlay").with(*idx))
            .open(&mut open)
            .resizable(true)
            .default_size([360.0, 220.0])
            .show(ctx, |ui| {
                draw_panel_body(ui, *load_state);
            });

        if !open {
            if let Some(p) = app.panels_mut().plugins_ui.panels.get_mut(*idx) {
                p.visible = false;
            }
        }
    }
}

// ── Panel body renderer ──────────────────────────────────────────────────────

fn draw_panel_body(ui: &mut egui::Ui, load_state: PluginLoadState) {
    match load_state {
        PluginLoadState::LazyPending | PluginLoadState::Loading => {
            ui.spinner();
            ui.weak("Loading...");
        }
        PluginLoadState::Failed => {
            ui.colored_label(
                egui::Color32::from_rgb(232, 120, 136),
                "Plugin failed to load.",
            );
        }
        PluginLoadState::Loaded => {
            ui.weak("Plugin loaded \u{2014} no widgets received");
        }
    }
}
