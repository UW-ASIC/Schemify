use eframe::egui;
use schemify_core::commands::Command;
use schemify_core::primitives::PRIMITIVES;
use schemify_core::theme::ThemeTokens;
use schemify_core::types::Color;
use schemify_handler::state::{DocEditorMode, PanelLayout, PluginLoadState};
use schemify_handler::App;

use crate::theme::WidgetPalette;

// ── File Explorer ────────────────────────────────────────────────────────────

pub fn file_explorer(ui: &mut egui::Ui, app: &mut App) {
    #[cfg(not(target_arch = "wasm32"))]
    file_explorer_native(ui, app);

    #[cfg(target_arch = "wasm32")]
    file_explorer_web(ui, app);

    ui.separator();
    file_explorer_examples(ui, app);
}

fn file_explorer_examples(ui: &mut egui::Ui, app: &mut App) {
    use schemify_handler::examples::{self, ExampleKind};

    let examples = examples::all();

    egui::CollapsingHeader::new("Examples")
        .default_open(false)
        .show(ui, |ui| {
            for kind in [ExampleKind::Schematic, ExampleKind::Testbench, ExampleKind::Primitive] {
                let filtered: Vec<_> = examples.iter().filter(|e| e.kind == kind).collect();
                if filtered.is_empty() {
                    continue;
                }
                egui::CollapsingHeader::new(kind.label())
                    .default_open(kind == ExampleKind::Schematic)
                    .show(ui, |ui| {
                        for ex in &filtered {
                            if ui.selectable_label(false, ex.name).clicked() {
                                app.open_from_content(ex.name, ex.content);
                            }
                        }
                    });
            }
        });
}

#[cfg(not(target_arch = "wasm32"))]
fn file_explorer_native(ui: &mut egui::Ui, app: &mut App) {
    let project_dir = app.project_dir().to_path_buf();

    if project_dir.as_os_str().is_empty() {
        ui.label("No project directory set.");
        if ui.button("Set Project Directory").clicked() {
            if let Some(dir) = rfd::FileDialog::new().pick_folder() {
                app.set_project_dir(dir);
            }
        }
    } else {
        ui.horizontal(|ui| {
            ui.label("\u{1f4c1}");
            ui.label(project_dir.display().to_string());
        });
        ui.separator();

        if let Ok(entries) = std::fs::read_dir(&project_dir) {
            egui::ScrollArea::vertical().show(ui, |ui| {
                let mut files: Vec<_> = entries
                    .filter_map(|e| e.ok())
                    .filter(|e| {
                        e.path()
                            .extension()
                            .map_or(false, |ext| ext == "chn")
                    })
                    .collect();
                files.sort_by_key(|e| e.file_name());

                if files.is_empty() {
                    ui.label("No .chn files found.");
                }
                for entry in &files {
                    let name = entry.file_name();
                    let name_str = name.to_string_lossy();
                    if ui
                        .selectable_label(false, name_str.as_ref())
                        .double_clicked()
                    {
                        let _ = app.open_file(&entry.path());
                    }
                }
            });
        }

        ui.separator();
        if ui.button("Change Directory").clicked() {
            if let Some(dir) = rfd::FileDialog::new().pick_folder() {
                app.set_project_dir(dir);
            }
        }
    }
}

#[cfg(target_arch = "wasm32")]
fn file_explorer_web(ui: &mut egui::Ui, app: &mut App) {
    ui.label("Project files (read-only)");
    ui.separator();

    let docs = app.documents();
    if docs.is_empty() {
        ui.weak("No schematics loaded.");
    } else {
        egui::ScrollArea::vertical().show(ui, |ui| {
            let active = app.active_doc_idx();
            for (i, doc) in docs.iter().enumerate() {
                let label = if doc.name.is_empty() {
                    "(untitled)"
                } else {
                    &doc.name
                };
                if ui.selectable_label(i == active, label).clicked() {
                    app.dispatch(schemify_core::commands::Command::SwitchTab(i));
                }
            }
        });
    }
}

// ── Library Browser ──────────────────────────────────────────────────────────

pub fn library_browser(ui: &mut egui::Ui, app: &mut App) {
    let selected = app.panels().library_browser.selected_prim;

    let mut new_selected = selected;
    let mut place: Option<(String, String)> = None;

    egui::ScrollArea::vertical().show(ui, |ui| {
        for (i, prim) in PRIMITIVES.iter().enumerate() {
            let sel = selected == Some(i);
            let resp = ui.selectable_label(sel, prim.kind_name);
            if resp.clicked() {
                new_selected = Some(i);
            }
            if resp.double_clicked() {
                let prefix = if prim.prefix > 0 {
                    prim.prefix as char
                } else {
                    'X'
                };
                place = Some((prim.kind_name.to_string(), format!("{}1", prefix)));
            }
        }
    });

    if new_selected != selected {
        app.panels_mut().library_browser.selected_prim = new_selected;
    }
    if let Some((path, name)) = place {
        app.start_placement(path, name);
    }
}

// ── Welcome ──────────────────────────────────────────────────────────────────

/// Render the welcome screen (centered, shown when no documents are open).
pub fn welcome(ui: &mut egui::Ui, app: &mut App) {
    let mut cmds: Vec<Command> = Vec::new();
    #[cfg(not(target_arch = "wasm32"))]
    let mut open_file = false;
    let mut import = false;

    let avail = ui.available_size();

    ui.vertical_centered(|ui| {
        // Vertical centering: top spacer
        ui.add_space((avail.y * 0.25).max(40.0));

        // Title
        ui.label(egui::RichText::new("SchemifyRS").size(32.0).strong());
        ui.add_space(4.0);
        ui.weak("Schematic Editor");
        ui.add_space(32.0);

        // Quick Actions
        ui.weak("Quick Actions");
        ui.add_space(8.0);

        ui.horizontal(|ui| {
            ui.add_space((avail.x * 0.5 - 200.0).max(0.0));
            #[cfg(not(target_arch = "wasm32"))]
            {
                if ui.button("  New Schematic  Ctrl+N  ").clicked() {
                    cmds.push(Command::FileNew);
                }
                if ui.button("  Open File  Ctrl+O  ").clicked() {
                    open_file = true;
                }
                if ui.button("  Import Project  ").clicked() {
                    import = true;
                }
            }
            #[cfg(target_arch = "wasm32")]
            {
                ui.weak("Loading project data...");
            }
        });

        ui.add_space(32.0);
        ui.separator();
        ui.add_space(32.0);

        #[cfg(not(target_arch = "wasm32"))]
        ui.weak("Press : for command mode  |  Ctrl+O to open  |  Ctrl+N for new schematic");
        #[cfg(target_arch = "wasm32")]
        ui.weak("Read-only web viewer  |  Simulation available via F5");
    });

    // Post-frame file dialog (native only)
    #[cfg(not(target_arch = "wasm32"))]
    if open_file {
        if let Some(path) = rfd::FileDialog::new()
            .add_filter("Schematic", &["chn"])
            .pick_file()
        {
            let _ = app.open_file(&path);
        }
    }
    if import {
        cmds.push(Command::OpenImportDialog);
    }

    for cmd in cmds {
        app.dispatch(cmd);
    }
}

// ── Doc View ─────────────────────────────────────────────────────────────────

/// Show the documentation editor view (when ViewMode::Documentation is active).
pub fn doc_view(ui: &mut egui::Ui, app: &mut App) {
    let mode = app.editor().doc_editor.mode;
    let mut new_mode = mode;

    // Load doc content on first show
    if !app.editor().doc_editor.loaded {
        let doc_text = app.schematic().documentation.clone();
        app.editor_mut().doc_editor.buf = doc_text;
        app.editor_mut().doc_editor.loaded = true;
    }

    let mut save_requested = false;

    // Toolbar
    ui.horizontal(|ui| {
        if ui
            .selectable_label(mode == DocEditorMode::Edit, "Edit")
            .clicked()
        {
            new_mode = DocEditorMode::Edit;
        }
        if ui
            .selectable_label(mode == DocEditorMode::Preview, "Preview")
            .clicked()
        {
            new_mode = DocEditorMode::Preview;
        }
        ui.separator();
        if ui.button("Save").clicked() {
            save_requested = true;
        }
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            let word_count = app.editor().doc_editor.buf.split_whitespace().count();
            ui.weak(format!("{} words", word_count));
        });
    });
    ui.separator();

    if new_mode != mode {
        app.editor_mut().doc_editor.mode = new_mode;
    }

    match app.editor().doc_editor.mode {
        DocEditorMode::Edit => {
            let dark = ui.ctx().style().visuals.dark_mode;
            let mut latex_layouter = |ui: &egui::Ui, text: &str, wrap_width: f32| {
                let font = egui::FontId::monospace(14.0);
                let mut job = crate::highlight::highlight_latex(text, font, dark);
                job.wrap.max_width = wrap_width;
                ui.fonts(|f| f.layout_job(job))
            };
            egui::ScrollArea::vertical().show(ui, |ui| {
                ui.add(
                    egui::TextEdit::multiline(&mut app.editor_mut().doc_editor.buf)
                        .font(egui::FontId::monospace(14.0))
                        .layouter(&mut latex_layouter)
                        .desired_width(f32::INFINITY)
                        .desired_rows(30),
                );
            });
        }
        DocEditorMode::Preview => {
            egui::ScrollArea::vertical().show(ui, |ui| {
                let text = app.editor().doc_editor.buf.clone();
                render_simple_markdown(ui, &text);
            });
        }
    }

    if save_requested {
        let text = app.editor().doc_editor.buf.clone();
        app.dispatch(Command::SetDocumentation(text));
    }
}

/// Markdown renderer with LaTeX math support ($...$ inline, $$...$$ display).
fn render_simple_markdown(ui: &mut egui::Ui, text: &str) {
    let mut in_code_block = false;
    let mut in_math_block = false;
    let mut math_buf = String::new();

    for line in text.lines() {
        let trimmed = line.trim();

        // Display math block: $$...$$
        if trimmed.starts_with("$$") {
            if in_math_block {
                // Closing $$ — render accumulated math.
                crate::math_render::render_display(ui, &math_buf);
                math_buf.clear();
                in_math_block = false;
            } else if trimmed.ends_with("$$") && trimmed.len() > 2 {
                // Single-line $$content$$
                let content = &trimmed[2..trimmed.len() - 2];
                crate::math_render::render_display(ui, content);
            } else {
                // Opening $$
                in_math_block = true;
                let after = &trimmed[2..];
                if !after.is_empty() {
                    math_buf.push_str(after);
                }
            }
            continue;
        }
        if in_math_block {
            if !math_buf.is_empty() {
                math_buf.push(' ');
            }
            math_buf.push_str(trimmed);
            continue;
        }

        // Toggle code block state on fences
        if trimmed.starts_with("```") {
            in_code_block = !in_code_block;
            ui.add_space(4.0);
            continue;
        }

        if in_code_block {
            ui.label(egui::RichText::new(line).monospace());
            continue;
        }

        if trimmed.is_empty() {
            ui.add_space(8.0);
        } else if let Some(heading) = trimmed.strip_prefix("### ") {
            ui.label(egui::RichText::new(heading).strong().size(15.0));
        } else if let Some(heading) = trimmed.strip_prefix("## ") {
            ui.label(egui::RichText::new(heading).strong().size(18.0));
        } else if let Some(heading) = trimmed.strip_prefix("# ") {
            ui.heading(heading);
        } else if let Some(item) = trimmed.strip_prefix("- ") {
            render_text_line(ui, item, true);
        } else if let Some(item) = trimmed.strip_prefix("* ") {
            render_text_line(ui, item, true);
        } else {
            render_text_line(ui, line, false);
        }
    }
}

/// Render a text line, detecting inline $math$ spans.
fn render_text_line(ui: &mut egui::Ui, line: &str, is_list_item: bool) {
    if is_list_item {
        if line.contains('$') {
            ui.horizontal(|ui| {
                ui.label("  \u{2022}");
                if !crate::math_render::render_text_with_math(ui, line) {
                    ui.label(line);
                }
            });
        } else {
            ui.horizontal(|ui| {
                ui.label("  \u{2022}");
                ui.label(line);
            });
        }
    } else if line.contains('$') {
        if !crate::math_render::render_text_with_math(ui, line) {
            ui.label(line);
        }
    } else {
        ui.label(line);
    }
}

// ── Floating File Explorer Window ────────────────────────────────────────────

pub fn file_explorer_window(ctx: &egui::Context, app: &mut App, theme: &ThemeTokens) {
    let mut open = app.panels().left_panel_open;
    if !open {
        return;
    }

    egui::Window::new("File Explorer")
        .open(&mut open)
        .default_size([240.0, 400.0])
        .resizable(true)
        .collapsible(true)
        .show(ctx, |ui| {
            file_explorer(ui, app);
            ui.add_space(8.0);
            plugin_sidebar(ui, app, schemify_handler::state::PanelLayout::LeftSidebar, theme);
        });

    if !open {
        app.panels_mut().left_panel_open = false;
    }
}

// ── Floating Library Browser Window ─────────────────────────────────────────

pub fn library_window(ctx: &egui::Context, app: &mut App) {
    let mut open = app.panels().library_open;
    if !open {
        return;
    }

    egui::Window::new("Library Browser")
        .open(&mut open)
        .default_size([260.0, 450.0])
        .resizable(true)
        .collapsible(true)
        .show(ctx, |ui| {
            library_browser(ui, app);
        });

    if !open {
        app.panels_mut().library_open = false;
    }
}

// ── Context Menu ─────────────────────────────────────────────────────────────

/// Show right-click context menu (floating overlay).
pub fn context_menu(ctx: &egui::Context, app: &mut App) {
    let cm = app.ctx_menu().clone();
    if !cm.open {
        return;
    }

    let mut cmds: Vec<Command> = Vec::new();
    let mut close = false;
    let sel_count = app.selection().count();
    let has_selection = sel_count > 0;
    let has_instance = matches!(cm.hit, schemify_handler::state::ContextHit::Instance(_));
    let has_wire = matches!(cm.hit, schemify_handler::state::ContextHit::Wire(_));
    let has_hit = !matches!(cm.hit, schemify_handler::state::ContextHit::None);
    let is_group = sel_count > 1;
    let is_canvas = !has_selection && !has_hit;

    egui::Area::new(egui::Id::new("context_menu"))
        .fixed_pos(egui::pos2(cm.pixel_pos[0], cm.pixel_pos[1]))
        .order(egui::Order::Foreground)
        .show(ctx, |ui| {
            egui::Frame::menu(ui.style()).show(ui, |ui| {
                ui.set_min_width(160.0);

                if is_canvas {
                    // ── Canvas context (no selection, no hit) ────────────────
                    if ui.button("Paste").clicked() {
                        cmds.push(Command::Paste);
                        close = true;
                    }
                    if ui
                        .add_enabled(false, egui::Button::new("Insert from Library..."))
                        .clicked()
                    {
                        close = true;
                    }
                    ui.separator();
                    if ui.button("Select All").clicked() {
                        cmds.push(Command::SelectAll);
                        close = true;
                    }
                } else if is_group {
                    // ── Group context (multiple items selected) ──────────────
                    ui.label(
                        egui::RichText::new(format!("{sel_count} items selected"))
                            .strong()
                            .small(),
                    );
                    ui.separator();
                    if ui.button("Delete All").clicked() {
                        cmds.push(Command::DeleteSelected);
                        close = true;
                    }
                    if ui.button("Rotate All CW").clicked() {
                        cmds.push(Command::RotateCw);
                        close = true;
                    }
                    if ui.button("Flip All Horizontal").clicked() {
                        cmds.push(Command::FlipHorizontal);
                        close = true;
                    }
                    if ui.button("Duplicate All").clicked() {
                        cmds.push(Command::DuplicateSelected);
                        close = true;
                    }
                } else {
                    // ── Single-item context (instance or wire) ──────────────
                    if ui
                        .add_enabled(has_selection, egui::Button::new("Cut"))
                        .clicked()
                    {
                        cmds.push(Command::Cut);
                        close = true;
                    }
                    if ui
                        .add_enabled(has_selection, egui::Button::new("Copy"))
                        .clicked()
                    {
                        cmds.push(Command::Copy);
                        close = true;
                    }
                    if ui.button("Paste").clicked() {
                        cmds.push(Command::Paste);
                        close = true;
                    }
                    if ui
                        .add_enabled(has_selection, egui::Button::new("Delete"))
                        .clicked()
                    {
                        cmds.push(Command::DeleteSelected);
                        close = true;
                    }
                    if ui
                        .add_enabled(has_selection, egui::Button::new("Duplicate"))
                        .clicked()
                    {
                        cmds.push(Command::DuplicateSelected);
                        close = true;
                    }

                    ui.separator();

                    if ui
                        .add_enabled(has_selection, egui::Button::new("Rotate CW"))
                        .clicked()
                    {
                        cmds.push(Command::RotateCw);
                        close = true;
                    }
                    if ui
                        .add_enabled(has_selection, egui::Button::new("Flip Horizontal"))
                        .clicked()
                    {
                        cmds.push(Command::FlipHorizontal);
                        close = true;
                    }

                    if has_instance {
                        ui.separator();
                        if ui.button("Properties...").clicked() {
                            cmds.push(Command::OpenPropsDialog);
                            close = true;
                        }
                        // Hierarchy placeholders (disabled until handler support)
                        ui.add_enabled(false, egui::Button::new("Descend Schematic"));
                        ui.add_enabled(false, egui::Button::new("Descend Symbol"));
                    }
                }

                // ── Wire context (always shown when wire is hit) ────────────
                if let schemify_handler::state::ContextHit::Wire(wire_idx) = cm.hit {
                    ui.separator();
                    ui.label(egui::RichText::new("Wire").strong().small());
                    if ui.button("Delete Wire").clicked() {
                        cmds.push(Command::DeleteWire(wire_idx));
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
                                cmds.push(Command::SetWireColor {
                                    idx: wire_idx,
                                    color,
                                });
                                close = true;
                                ui.close_menu();
                            }
                        }
                    });
                }
            });

            // Close on click outside
            if ui.input(|i| i.pointer.any_click()) && !ui.rect_contains_pointer(ui.min_rect()) {
                close = true;
            }
        });

    // Close on Escape
    if ctx.input(|i| i.key_pressed(egui::Key::Escape)) {
        close = true;
    }

    if close {
        app.ctx_menu_mut().open = false;
    }
    for cmd in cmds {
        app.dispatch(cmd);
    }
}

// ── Plugin Panels ────────────────────────────────────────────────────────────

// ── Widget Protocol ──────────────────────────────────────────────────────────

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
pub fn plugin_sidebar(ui: &mut egui::Ui, app: &App, layout: PanelLayout, tokens: &ThemeTokens) {
    let palette = WidgetPalette::from_tokens(tokens);
    let panels = &app.panels().plugins_ui.panels;
    for panel in panels {
        if panel.layout != layout || !panel.visible {
            continue;
        }
        ui.collapsing(&panel.name, |ui| {
            draw_panel_body(ui, panel.load_state, &palette);
        });
    }
}

/// Show a right side panel if any right-sidebar plugin panels are visible.
pub fn plugin_right_panel(ctx: &egui::Context, app: &App, tokens: &ThemeTokens) {
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
            plugin_sidebar(ui, app, PanelLayout::RightSidebar, tokens);
        });
}

// ── Bottom Bar ───────────────────────────────────────────────────────────────

/// Render plugin panels in the bottom bar area (below canvas).
pub fn plugin_bottom(ui: &mut egui::Ui, app: &App, tokens: &ThemeTokens) {
    let palette = WidgetPalette::from_tokens(tokens);
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
                    draw_panel_body(ui, panel.load_state, &palette);
                });
            }
        },
    );
}

// ── Overlays ─────────────────────────────────────────────────────────────────

/// Render plugin panels as floating overlay windows.
pub fn plugin_overlays(ctx: &egui::Context, app: &mut App, tokens: &ThemeTokens) {
    let palette = WidgetPalette::from_tokens(tokens);
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
                draw_panel_body(ui, *load_state, &palette);
            });

        if !open {
            if let Some(p) = app.panels_mut().plugins_ui.panels.get_mut(*idx) {
                p.visible = false;
            }
        }
    }
}

// ── Panel body renderer ──────────────────────────────────────────────────────

fn draw_panel_body(ui: &mut egui::Ui, load_state: PluginLoadState, palette: &WidgetPalette) {
    match load_state {
        PluginLoadState::LazyPending | PluginLoadState::Loading => {
            ui.spinner();
            ui.weak("Loading...");
        }
        PluginLoadState::Failed => {
            ui.colored_label(
                palette.alert_error,
                "Plugin failed to load.",
            );
        }
        PluginLoadState::Loaded => {
            ui.weak("Plugin loaded \u{2014} no widgets received");
        }
    }
}
