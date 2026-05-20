use eframe::egui;
use schemify_core::commands::{Command, Tool};
use schemify_handler::state::ViewMode;
use schemify_handler::App;

// ====================================================
// Status bar — normal mode + vim command mode.
// ====================================================

pub fn show(ctx: &egui::Context, app: &mut App) {
    let in_command_mode = app.editor().command_mode;

    egui::TopBottomPanel::bottom("status_bar").show(ctx, |ui| {
        ui.horizontal(|ui| {
            if in_command_mode {
                show_command_mode(ui, app);
            } else {
                show_normal(ui, app);
            }
        });
    });
}

// ── Normal mode ─────────────────────────────────────────────────────────────

fn show_normal(ui: &mut egui::Ui, app: &App) {
    let status = app.status_msg();
    let cursor = app.canvas().cursor_world;
    let tool = app.active_tool();
    let snap = app.tool_state().snap_size;
    let view_mode = app.view().view_mode;
    let zoom = app.zoom();

    if !status.is_empty() {
        ui.label(status);
        ui.separator();
    }

    ui.label(format!("({}, {})", cursor[0], cursor[1]));
    ui.separator();
    ui.label(format!("{:?}", tool));
    ui.separator();
    ui.label(format!("snap: {}", snap as i32));
    ui.separator();

    let mode_str = match view_mode {
        ViewMode::Schematic => "SCH",
        ViewMode::Symbol => "SYM",
        ViewMode::Documentation => "DOC",
    };
    ui.label(mode_str);
    ui.separator();
    ui.weak(": for commands");

    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
        ui.label(format!("{:.0}%", zoom * 100.0));
    });
}

// ── Command mode ────────────────────────────────────────────────────────────

fn show_command_mode(ui: &mut egui::Ui, app: &mut App) {
    ui.label(":");

    let buf = &mut app.editor_mut().command_buf;
    let response = ui.add(
        egui::TextEdit::singleline(buf)
            .desired_width(ui.available_width() - 180.0)
            .hint_text("command"),
    );

    // Auto-focus on the first frame we enter command mode.
    if !response.has_focus() {
        response.request_focus();
    }
    app.editor_mut().text_entry_focused = true;

    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
        ui.weak("Enter to run | Esc to cancel");
    });

    // Handle Enter / Escape via the input system so we catch them
    // even when the text field consumed the key event.
    let (enter, escape) = ui.ctx().input(|i| {
        (
            i.key_pressed(egui::Key::Enter),
            i.key_pressed(egui::Key::Escape),
        )
    });

    if enter {
        let line = app.editor().command_buf.clone();
        exit_command_mode(app);
        execute_vim_command(&line, app);
    } else if escape {
        exit_command_mode(app);
    }
}

fn exit_command_mode(app: &mut App) {
    let editor = app.editor_mut();
    editor.command_mode = false;
    editor.command_buf.clear();
    editor.text_entry_focused = false;
}

// ── Vim command parser & executor ───────────────────────────────────────────

/// Result of parsing a vim command line.
enum VimResult {
    /// Dispatch through the normal command pipeline.
    Dispatch(Command),
    /// GUI-only: set view mode directly.
    SetView(ViewMode),
    /// Nothing matched.
    Unknown,
}

fn parse_vim_command(input: &str) -> VimResult {
    let cmd = input.trim().to_ascii_lowercase();
    let cmd = cmd.strip_prefix(':').unwrap_or(&cmd);
    let cmd = cmd.trim();

    match cmd {
        // File
        "w" | "save" => VimResult::Dispatch(Command::FileSave),
        "wq" => VimResult::Dispatch(Command::FileSave), // quit handled separately if needed
        "q" | "quit" | "close" | "tabclose" => VimResult::Dispatch(Command::CloseTab(0)),
        "e" | "open" => VimResult::Dispatch(Command::FileOpen),
        "saveas" => VimResult::Dispatch(Command::FileSaveAs),
        "new" | "tabnew" => VimResult::Dispatch(Command::FileNew),
        "newtab" => VimResult::Dispatch(Command::NewTab),
        "reload" | "e!" => VimResult::Dispatch(Command::ReloadFromDisk),

        // Undo / Redo
        "undo" => VimResult::Dispatch(Command::Undo),
        "redo" => VimResult::Dispatch(Command::Redo),

        // Zoom
        "zoomin" => VimResult::Dispatch(Command::ZoomIn),
        "zoomout" => VimResult::Dispatch(Command::ZoomOut),
        "zoomfit" | "fit" => VimResult::Dispatch(Command::ZoomFit),
        "zoomreset" => VimResult::Dispatch(Command::ZoomReset),

        // Grid
        "grid" => VimResult::Dispatch(Command::ToggleGrid),

        // Tools
        "wire" => VimResult::Dispatch(Command::SetTool(Tool::Wire)),
        "select" => VimResult::Dispatch(Command::SetTool(Tool::Select)),
        "line" => VimResult::Dispatch(Command::SetTool(Tool::Line)),
        "rect" => VimResult::Dispatch(Command::SetTool(Tool::Rect)),
        "circle" => VimResult::Dispatch(Command::SetTool(Tool::Circle)),
        "arc" => VimResult::Dispatch(Command::SetTool(Tool::Arc)),
        "polygon" => VimResult::Dispatch(Command::SetTool(Tool::Polygon)),
        "text" => VimResult::Dispatch(Command::SetTool(Tool::Text)),
        "move" => VimResult::Dispatch(Command::SetTool(Tool::Move)),

        // Dialogs
        "props" | "properties" => VimResult::Dispatch(Command::OpenPropsDialog),
        "find" => VimResult::Dispatch(Command::OpenFindDialog),
        "settings" | "preferences" => VimResult::Dispatch(Command::OpenSettings),
        "spicecode" => VimResult::Dispatch(Command::OpenSpiceCodeEditor),
        "newprim" => VimResult::Dispatch(Command::OpenNewPrimDialog),
        "marketplace" => VimResult::Dispatch(Command::OpenMarketplace),
        "import" => VimResult::Dispatch(Command::OpenImportDialog),

        // Simulation
        "sim" | "simulate" => VimResult::Dispatch(Command::RunSim),

        // View toggles
        "fullscreen" => VimResult::Dispatch(Command::ToggleFullscreen),
        "darkmode" => VimResult::Dispatch(Command::ToggleColorScheme),

        // Plugins
        "pluginsreload" | "pluginsrefresh" => VimResult::Dispatch(Command::PluginsRefresh),

        // Selection & editing
        "delete" | "del" => VimResult::Dispatch(Command::DeleteSelected),
        "selectall" => VimResult::Dispatch(Command::SelectAll),
        "selectnone" => VimResult::Dispatch(Command::SelectNone),
        "duplicate" | "dup" => VimResult::Dispatch(Command::DuplicateSelected),

        // Transform
        "rotatecw" | "rotcw" => VimResult::Dispatch(Command::RotateCw),
        "rotateccw" | "rotccw" => VimResult::Dispatch(Command::RotateCcw),
        "fliph" => VimResult::Dispatch(Command::FlipHorizontal),
        "flipv" => VimResult::Dispatch(Command::FlipVertical),
        "align" => VimResult::Dispatch(Command::AlignToGrid),

        // Clipboard
        "copy" | "clipcopy" => VimResult::Dispatch(Command::Copy),
        "cut" | "clipcut" => VimResult::Dispatch(Command::Cut),
        "paste" | "clippaste" => VimResult::Dispatch(Command::Paste),

        // Auto-layout
        "autolayout" | "layout" => VimResult::Dispatch(Command::AutoLayout),

        // View mode (GUI-only, not dispatch)
        "schematic" | "sch" => VimResult::SetView(ViewMode::Schematic),
        "symbol" | "sym" => VimResult::SetView(ViewMode::Symbol),
        "doc" | "documentation" => VimResult::SetView(ViewMode::Documentation),

        _ => VimResult::Unknown,
    }
}

fn execute_vim_command(line: &str, app: &mut App) {
    if line.trim().is_empty() {
        return;
    }

    match parse_vim_command(line) {
        VimResult::Dispatch(cmd) => app.dispatch(cmd),
        VimResult::SetView(mode) => {
            app.view_mut().view_mode = mode;
        }
        VimResult::Unknown => {
            // Could set a status message; for now just ignore.
        }
    }
}
