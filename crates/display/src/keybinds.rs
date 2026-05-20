use eframe::egui;
use schemify_core::commands::{Command, Tool};

// ====================================================
// Keybind table with O(1) linear-scan lookup.
// No rendering — exports the table + lookup fn only.
// ====================================================

/// Commands that can originate from a keybind.
/// Superset of `Command` to cover GUI-only actions that
/// go through `gui_mut()` rather than `dispatch()`.
#[derive(Debug, Clone)]
pub enum KeyCommand {
    Dispatch(Command),
    EnterCommandMode,
    SetViewSchematic,
    SetViewSymbol,
    SetViewDoc,
}

pub struct Keybind {
    pub ctrl: bool,
    pub shift: bool,
    pub alt: bool,
    pub key: egui::Key,
    pub command: KeyCommand,
    pub label: &'static str,
    pub shortcut: &'static str,
}

/// Full keybind table, ported from Zig reference `keybinds.zig`.
///
/// Ordering: ctrl binds first, then shift, then plain keys.
/// This is a flat scan — the table is small enough that binary
/// search buys nothing over branch-predicted iteration.
pub static KEYBINDS: &[Keybind] = &[
    // ── File ────────────────────────────────────────────
    kb(true, false, false, egui::Key::N, KeyCommand::Dispatch(Command::FileNew), "New file", "Ctrl+N"),
    kb(true, false, false, egui::Key::O, KeyCommand::Dispatch(Command::FileOpen), "Open file", "Ctrl+O"),
    kb(true, false, false, egui::Key::S, KeyCommand::Dispatch(Command::FileSave), "Save", "Ctrl+S"),
    kb(true, true, false, egui::Key::S, KeyCommand::Dispatch(Command::FileSaveAs), "Save as", "Ctrl+Shift+S"),
    kb(true, false, false, egui::Key::T, KeyCommand::Dispatch(Command::NewTab), "New tab", "Ctrl+T"),
    kb(true, false, false, egui::Key::W, KeyCommand::Dispatch(Command::CloseTab(0)), "Close tab", "Ctrl+W"),

    // ── Undo / Redo ─────────────────────────────────────
    kb(true, false, false, egui::Key::Z, KeyCommand::Dispatch(Command::Undo), "Undo", "Ctrl+Z"),
    kb(true, false, false, egui::Key::Y, KeyCommand::Dispatch(Command::Redo), "Redo", "Ctrl+Y"),

    // ── Clipboard ───────────────────────────────────────
    kb(true, false, false, egui::Key::X, KeyCommand::Dispatch(Command::Cut), "Cut", "Ctrl+X"),
    kb(true, false, false, egui::Key::C, KeyCommand::Dispatch(Command::Copy), "Copy", "Ctrl+C"),
    kb(true, false, false, egui::Key::V, KeyCommand::Dispatch(Command::Paste), "Paste", "Ctrl+V"),

    // ── Selection ───────────────────────────────────────
    kb(true, false, false, egui::Key::A, KeyCommand::Dispatch(Command::SelectAll), "Select all", "Ctrl+A"),
    kb(true, true, false, egui::Key::A, KeyCommand::Dispatch(Command::SelectNone), "Select none", "Ctrl+Shift+A"),
    kb(true, false, false, egui::Key::D, KeyCommand::Dispatch(Command::DuplicateSelected), "Duplicate", "Ctrl+D"),

    // ── Find ────────────────────────────────────────────
    kb(true, false, false, egui::Key::F, KeyCommand::Dispatch(Command::OpenFindDialog), "Find", "Ctrl+F"),

    // ── Zoom (Ctrl) ─────────────────────────────────────
    kb(true, false, false, egui::Key::Equals, KeyCommand::Dispatch(Command::ZoomIn), "Zoom in", "Ctrl+="),
    kb(true, false, false, egui::Key::Minus, KeyCommand::Dispatch(Command::ZoomOut), "Zoom out", "Ctrl+-"),
    kb(true, false, false, egui::Key::Num0, KeyCommand::Dispatch(Command::ZoomReset), "Zoom reset", "Ctrl+0"),

    // ── Tools (no modifiers) ────────────────────────────
    kb(false, false, false, egui::Key::W, KeyCommand::Dispatch(Command::SetTool(Tool::Wire)), "Wire tool", "W"),
    kb(false, false, false, egui::Key::L, KeyCommand::Dispatch(Command::SetTool(Tool::Line)), "Line tool", "L"),
    kb(false, false, false, egui::Key::A, KeyCommand::Dispatch(Command::SetTool(Tool::Arc)), "Arc tool", "A"),
    kb(false, false, false, egui::Key::C, KeyCommand::Dispatch(Command::SetTool(Tool::Circle)), "Circle tool", "C"),
    kb(false, false, false, egui::Key::P, KeyCommand::Dispatch(Command::SetTool(Tool::Polygon)), "Polygon tool", "P"),
    kb(false, false, false, egui::Key::T, KeyCommand::Dispatch(Command::SetTool(Tool::Text)), "Text tool", "T"),
    kb(false, false, false, egui::Key::M, KeyCommand::Dispatch(Command::SetTool(Tool::Move)), "Move tool", "M"),
    kb(false, false, false, egui::Key::Escape, KeyCommand::Dispatch(Command::SetTool(Tool::Select)), "Select tool", "Esc"),

    // ── Transform (no ctrl) ─────────────────────────────
    kb(false, false, false, egui::Key::R, KeyCommand::Dispatch(Command::RotateCw), "Rotate CW", "R"),
    kb(false, true, false, egui::Key::R, KeyCommand::Dispatch(Command::RotateCcw), "Rotate CCW", "Shift+R"),
    kb(false, false, false, egui::Key::X, KeyCommand::Dispatch(Command::FlipHorizontal), "Flip horizontal", "X"),
    kb(false, true, false, egui::Key::X, KeyCommand::Dispatch(Command::FlipVertical), "Flip vertical", "Shift+X"),
    kb(false, false, false, egui::Key::D, KeyCommand::Dispatch(Command::DuplicateSelected), "Duplicate", "D"),

    // ── View toggles ────────────────────────────────────
    kb(false, false, false, egui::Key::G, KeyCommand::Dispatch(Command::ToggleGrid), "Toggle grid", "G"),
    kb(false, false, false, egui::Key::F, KeyCommand::Dispatch(Command::ZoomFit), "Zoom fit", "F"),
    kb(false, false, false, egui::Key::Z, KeyCommand::Dispatch(Command::ZoomFit), "Zoom fit", "Z"),

    // ── View mode switches ──────────────────────────────
    kb(false, false, false, egui::Key::S, KeyCommand::SetViewSchematic, "Schematic view", "S"),
    kb(false, true, false, egui::Key::V, KeyCommand::SetViewSymbol, "Symbol view", "Shift+V"),

    // ── Dialogs ─────────────────────────────────────────
    kb(false, false, false, egui::Key::Q, KeyCommand::Dispatch(Command::OpenPropsDialog), "Properties", "Q"),

    // ── Simulation ──────────────────────────────────────
    kb(false, false, false, egui::Key::F5, KeyCommand::Dispatch(Command::RunSim), "Run simulation", "F5"),
    kb(false, false, false, egui::Key::F6, KeyCommand::Dispatch(Command::PluginsRefresh), "Refresh plugins", "F6"),

    // ── Delete ──────────────────────────────────────────
    kb(false, false, false, egui::Key::Delete, KeyCommand::Dispatch(Command::DeleteSelected), "Delete", "Del"),
    kb(false, false, false, egui::Key::Backspace, KeyCommand::Dispatch(Command::DeleteSelected), "Delete", "Backspace"),

    // ── Arrow nudge ─────────────────────────────────────
    kb(false, false, false, egui::Key::ArrowUp, KeyCommand::Dispatch(Command::NudgeUp), "Nudge up", "Up"),
    kb(false, false, false, egui::Key::ArrowDown, KeyCommand::Dispatch(Command::NudgeDown), "Nudge down", "Down"),
    kb(false, false, false, egui::Key::ArrowLeft, KeyCommand::Dispatch(Command::NudgeLeft), "Nudge left", "Left"),
    kb(false, false, false, egui::Key::ArrowRight, KeyCommand::Dispatch(Command::NudgeRight), "Nudge right", "Right"),

    // ── Command mode ────────────────────────────────────
    kb(false, true, false, egui::Key::Semicolon, KeyCommand::EnterCommandMode, "Command mode", ":"),
];

/// Look up the first matching keybind for the current frame's input.
/// Returns `None` if nothing matched.
pub fn lookup(ctx: &egui::Context) -> Option<&'static Keybind> {
    ctx.input(|i| {
        let ctrl = i.modifiers.ctrl || i.modifiers.mac_cmd;
        let shift = i.modifiers.shift;
        let alt = i.modifiers.alt;

        for kb in KEYBINDS {
            if kb.ctrl != ctrl || kb.shift != shift || kb.alt != alt {
                continue;
            }
            if i.key_pressed(kb.key) {
                return Some(kb);
            }
        }
        None
    })
}

// Helper to build a Keybind in const context.
const fn kb(
    ctrl: bool,
    shift: bool,
    alt: bool,
    key: egui::Key,
    command: KeyCommand,
    label: &'static str,
    shortcut: &'static str,
) -> Keybind {
    Keybind { ctrl, shift, alt, key, command, label, shortcut }
}
