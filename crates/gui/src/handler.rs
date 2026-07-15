//! Input → Command translation: the external command channel pump (headful
//! CLI/MCP driving), keyboard shortcut handling, and the vim command-line
//! parser. Execution of GUI-only actions (file dialogs, view modes) calls
//! into `components`.

use std::sync::mpsc::{Receiver, TryRecvError};
use std::time::{Duration, Instant};

use eframe::egui;

use schemify_editor::handler::{App, ViewMode};
use schemify_editor::schemify::{Command, Tool};

use crate::components;
use crate::keybinds::{self, KeyCommand};
use crate::state::GuiState;

// ════════════════════════════════════════════════════════════
// External command pump
// ════════════════════════════════════════════════════════════

/// Pumps externally-queued [`Command`]s (from the MCP server or a CLI
/// driver) into `App::dispatch` each frame.
///
/// With a `step_delay`, exactly one command is dispatched per delay tick —
/// the wait is scheduled via `request_repaint_after`, never by blocking the
/// UI thread. Without one, up to [`Self::MAX_PER_FRAME`] commands drain per
/// frame.
pub struct CommandPump {
    rx: Receiver<Command>,
    step_delay: Option<Duration>,
    next_ready: Option<Instant>,
}

impl CommandPump {
    /// Max commands drained per frame in undelayed mode (keeps a flooded
    /// channel from starving rendering).
    pub const MAX_PER_FRAME: usize = 32;

    /// Idle poll interval: how soon to repaint to check for new commands
    /// when the channel is empty (egui frames are otherwise event-driven).
    const POLL: Duration = Duration::from_millis(100);

    pub fn new(rx: Receiver<Command>, step_delay: Option<Duration>) -> Self {
        Self {
            rx,
            step_delay,
            next_ready: None,
        }
    }

    /// Drain queued commands into the app. Returns the number dispatched.
    pub fn pump(&mut self, app: &mut App, ctx: &egui::Context) -> usize {
        let mut dispatched = 0;

        if let Some(delay) = self.step_delay {
            // Honor the inter-command delay without blocking.
            if let Some(t) = self.next_ready {
                let now = Instant::now();
                if now < t {
                    ctx.request_repaint_after(t - now);
                    return 0;
                }
            }
            match self.rx.try_recv() {
                Ok(cmd) => {
                    app.dispatch(cmd).or_status(app);
                    dispatched = 1;
                    self.next_ready = Some(Instant::now() + delay);
                    ctx.request_repaint_after(delay);
                }
                Err(TryRecvError::Empty) => {
                    self.next_ready = None;
                    ctx.request_repaint_after(Self::POLL);
                }
                Err(TryRecvError::Disconnected) => {}
            }
        } else {
            loop {
                match self.rx.try_recv() {
                    Ok(cmd) => {
                        app.dispatch(cmd).or_status(app);
                        dispatched += 1;
                        if dispatched >= Self::MAX_PER_FRAME {
                            ctx.request_repaint(); // more queued — next frame
                            break;
                        }
                    }
                    Err(TryRecvError::Empty) => {
                        ctx.request_repaint_after(Self::POLL);
                        break;
                    }
                    Err(TryRecvError::Disconnected) => break,
                }
            }
        }
        dispatched
    }
}

// ════════════════════════════════════════════════════════════
// Keyboard shortcuts
// ════════════════════════════════════════════════════════════

/// Run the keybind table against this frame's input and execute the match.
pub fn handle_shortcuts(ctx: &egui::Context, app: &mut App, gui: &mut GuiState) {
    // Suppress single-key binds while typing anywhere (command line, dialog
    // text fields, canvas text tool).
    if gui.command_mode || gui.text_entry_focused || ctx.egui_wants_keyboard_input() {
        return;
    }

    let Some(kb) = keybinds::lookup(ctx) else {
        return;
    };
    match &kb.command {
        KeyCommand::Dispatch(cmd) => app.dispatch(cmd.clone()).or_status(app),
        KeyCommand::EnterCommandMode => gui.command_mode = true,
        KeyCommand::SetView(mode) => app.state.view.view_mode = *mode,
        KeyCommand::OpenFileDialog => components::open_file_dialog(app),
        KeyCommand::SaveFile => components::save_active(app),
        KeyCommand::SaveFileAs => components::save_as_dialog(app),
    }
}

// ════════════════════════════════════════════════════════════
// Vim command line (":w", ":q", ":wire", ...)
// ════════════════════════════════════════════════════════════

/// Parsed action for a vim command line. GUI-only actions get their own
/// variants; everything else flows through the normal dispatch pipeline.
#[derive(Debug, Clone)]
pub enum VimAction {
    Dispatch(Command),
    SetView(ViewMode),
    Save,
    SaveAndClose,
    SaveAs,
    OpenDialog,
    Unknown,
}

pub fn parse_vim_command(input: &str) -> VimAction {
    use VimAction as V;
    let cmd = input.trim().to_ascii_lowercase();
    let cmd = cmd.strip_prefix(':').unwrap_or(&cmd).trim();

    match cmd {
        // File
        "w" | "save" => V::Save,
        "wq" => V::SaveAndClose,
        "saveas" => V::SaveAs,
        "e" | "open" => V::OpenDialog,
        "q" | "quit" | "close" | "tabclose" => V::Dispatch(Command::CloseActiveTab),
        "new" | "tabnew" => V::Dispatch(Command::FileNew),
        "newtab" => V::Dispatch(Command::NewTab),
        "reload" | "e!" => V::Dispatch(Command::ReloadFromDisk),

        // Undo / redo
        "undo" => V::Dispatch(Command::Undo),
        "redo" => V::Dispatch(Command::Redo),

        // Zoom / grid
        "zoomin" => V::Dispatch(Command::ZoomIn),
        "zoomout" => V::Dispatch(Command::ZoomOut),
        "zoomfit" | "fit" => V::Dispatch(Command::ZoomFit),
        "zoomreset" => V::Dispatch(Command::ZoomReset),
        "grid" => V::Dispatch(Command::ToggleGrid),

        // Tools
        "wire" => V::Dispatch(Command::SetTool(Tool::Wire)),
        "bus" => V::Dispatch(Command::SetTool(Tool::Bus)),
        "ripper" | "busripper" => V::Dispatch(Command::SetTool(Tool::BusRipper)),
        "move" => V::Dispatch(Command::SetTool(Tool::Move)),
        "pan" => V::Dispatch(Command::SetTool(Tool::Pan)),
        "select" => V::Dispatch(Command::SetTool(Tool::Select)),
        "line" => V::Dispatch(Command::SetTool(Tool::Line)),
        "rect" => V::Dispatch(Command::SetTool(Tool::Rect)),
        "circle" => V::Dispatch(Command::SetTool(Tool::Circle)),
        "arc" => V::Dispatch(Command::SetTool(Tool::Arc)),
        "polygon" => V::Dispatch(Command::SetTool(Tool::Polygon)),
        "text" => V::Dispatch(Command::SetTool(Tool::Text)),

        // Dialogs
        "props" | "properties" => V::Dispatch(Command::OpenPropsDialog),
        "find" => V::Dispatch(Command::OpenFindDialog),
        "settings" | "preferences" => V::Dispatch(Command::OpenSettings),
        "spicecode" => V::Dispatch(Command::OpenSpiceCodeEditor),
        "newprim" => V::Dispatch(Command::OpenNewPrimDialog),
        "import" => V::Dispatch(Command::OpenImportDialog),
        "lib" | "library" => V::Dispatch(Command::OpenLibraryBrowser),

        // Simulation
        "sim" | "simulate" => V::Dispatch(Command::RunSim),
        "netlist" => V::Dispatch(Command::ExportNetlist),

        // View toggles
        "fullscreen" => V::Dispatch(Command::ToggleFullscreen),
        "darkmode" => V::Dispatch(Command::ToggleColorScheme),

        // Selection & editing
        "delete" | "del" => V::Dispatch(Command::DeleteSelected),
        "selectall" => V::Dispatch(Command::SelectAll),
        "selectnone" => V::Dispatch(Command::SelectNone),
        "duplicate" | "dup" => V::Dispatch(Command::DuplicateSelected),

        // Transform
        "rotatecw" | "rotcw" => V::Dispatch(Command::RotateCw),
        "rotateccw" | "rotccw" => V::Dispatch(Command::RotateCcw),
        "fliph" => V::Dispatch(Command::FlipHorizontal),
        "flipv" => V::Dispatch(Command::FlipVertical),
        "align" => V::Dispatch(Command::AlignToGrid),

        // Clipboard
        "copy" => V::Dispatch(Command::Copy),
        "cut" => V::Dispatch(Command::Cut),
        "paste" => V::Dispatch(Command::Paste),

        // Symbol generation
        "gensym" | "gensymbol" | "makesymbol" => {
            V::Dispatch(Command::GenerateSymbolFromSchematic)
        }

        // View modes
        "schematic" | "sch" => V::SetView(ViewMode::Schematic),
        "symbol" | "sym" => V::SetView(ViewMode::Symbol),
        "doc" | "documentation" => V::SetView(ViewMode::Documentation),

        _ => V::Unknown,
    }
}

/// Execute a parsed vim command line.
pub fn execute_vim_command(line: &str, app: &mut App, gui: &mut GuiState) {
    if line.trim().is_empty() {
        return;
    }
    match parse_vim_command(line) {
        VimAction::Dispatch(cmd) => app.dispatch(cmd).or_status(app),
        VimAction::SetView(mode) => app.state.view.view_mode = mode,
        VimAction::Save => components::save_active(app),
        VimAction::SaveAndClose => {
            components::save_active(app);
            app.dispatch(Command::CloseActiveTab).or_status(app);
        }
        VimAction::SaveAs => components::save_as_dialog(app),
        VimAction::OpenDialog => components::open_file_dialog(app),
        VimAction::Unknown => {
            app.state.status_msg = format!("Unknown command: {}", line.trim());
        }
    }
    let _ = gui;
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vim_file_commands() {
        assert!(matches!(parse_vim_command(":w"), VimAction::Save));
        assert!(matches!(parse_vim_command("w"), VimAction::Save));
        assert!(matches!(parse_vim_command(":wq"), VimAction::SaveAndClose));
        assert!(matches!(
            parse_vim_command(":q"),
            VimAction::Dispatch(Command::CloseActiveTab)
        ));
        assert!(matches!(parse_vim_command(":e"), VimAction::OpenDialog));
    }

    #[test]
    fn vim_tools_and_views() {
        assert!(matches!(
            parse_vim_command(":wire"),
            VimAction::Dispatch(Command::SetTool(Tool::Wire))
        ));
        assert!(matches!(
            parse_vim_command("  :SYM  "),
            VimAction::SetView(ViewMode::Symbol)
        ));
        assert!(matches!(
            parse_vim_command("grid"),
            VimAction::Dispatch(Command::ToggleGrid)
        ));
    }

    #[test]
    fn vim_unknown() {
        assert!(matches!(parse_vim_command(":frobnicate"), VimAction::Unknown));
    }
}
