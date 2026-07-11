//! Keybind table with linear-scan lookup. No rendering — exports the table,
//! the lookup fn, and `KeyCommand` (superset of `Command` for GUI-only
//! actions like file dialogs and view-mode switches).

use eframe::egui;

use schemify_editor::handler::ViewMode;
use schemify_editor::schemify::{Command, Tool};

/// Commands that can originate from a keybind. GUI-only variants are
/// executed by the display crate; `Dispatch` goes straight to the core.
#[derive(Debug, Clone)]
pub enum KeyCommand {
    Dispatch(Command),
    EnterCommandMode,
    SetView(ViewMode),
    /// Native file dialogs (core FileOpen/FileSave are display-driven).
    OpenFileDialog,
    SaveFile,
    SaveFileAs,
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

const fn kb(
    ctrl: bool,
    shift: bool,
    alt: bool,
    key: egui::Key,
    command: KeyCommand,
    label: &'static str,
    shortcut: &'static str,
) -> Keybind {
    Keybind {
        ctrl,
        shift,
        alt,
        key,
        command,
        label,
        shortcut,
    }
}

use egui::Key as K;
use KeyCommand as KC;

macro_rules! d {
    ($cmd:expr) => {
        KC::Dispatch($cmd)
    };
}

/// Full keybind table. Flat scan — small enough that ordering only matters
/// for readability (first match wins on identical combos, which the tests
/// forbid anyway).
#[rustfmt::skip]
pub static KEYBINDS: &[Keybind] = &[
    // ── File ──
    kb(true,  false, false, K::N,      d!(Command::FileNew),            "New file",        "Ctrl+N"),
    kb(true,  false, false, K::O,      KC::OpenFileDialog,              "Open file",       "Ctrl+O"),
    kb(true,  false, false, K::S,      KC::SaveFile,                    "Save",            "Ctrl+S"),
    kb(true,  true,  false, K::S,      KC::SaveFileAs,                  "Save as",         "Ctrl+Shift+S"),
    kb(true,  false, false, K::T,      d!(Command::NewTab),             "New tab",         "Ctrl+T"),
    kb(true,  false, false, K::W,      d!(Command::CloseActiveTab),     "Close tab",       "Ctrl+W"),
    // ── Undo / Redo ──
    kb(true,  false, false, K::Z,      d!(Command::Undo),               "Undo",            "Ctrl+Z"),
    kb(true,  false, false, K::Y,      d!(Command::Redo),               "Redo",            "Ctrl+Y"),
    // ── Clipboard ──
    kb(true,  false, false, K::X,      d!(Command::Cut),                "Cut",             "Ctrl+X"),
    kb(true,  false, false, K::C,      d!(Command::Copy),               "Copy",            "Ctrl+C"),
    kb(true,  false, false, K::V,      d!(Command::Paste),              "Paste",           "Ctrl+V"),
    // ── Selection ──
    kb(true,  false, false, K::A,      d!(Command::SelectAll),          "Select all",      "Ctrl+A"),
    kb(true,  true,  false, K::A,      d!(Command::SelectNone),         "Select none",     "Ctrl+Shift+A"),
    kb(true,  false, false, K::D,      d!(Command::DuplicateSelected),  "Duplicate",       "Ctrl+D"),
    kb(true,  false, false, K::I,      d!(Command::InvertSelection),    "Invert selection","Ctrl+I"),
    // ── Find ──
    kb(true,  false, false, K::F,      d!(Command::OpenFindDialog),     "Find",            "Ctrl+F"),
    // ── Zoom (Ctrl) ──
    kb(true,  false, false, K::Equals, d!(Command::ZoomIn),             "Zoom in",         "Ctrl+="),
    kb(true,  false, false, K::Minus,  d!(Command::ZoomOut),            "Zoom out",        "Ctrl+-"),
    kb(true,  false, false, K::Num0,   d!(Command::ZoomReset),          "Zoom reset",      "Ctrl+0"),
    // ── Tools (no modifiers) ──
    kb(false, false, false, K::W,      d!(Command::SetTool(Tool::Wire)),    "Wire tool",    "W"),
    kb(false, false, false, K::B,      d!(Command::SetTool(Tool::Bus)),     "Bus tool",     "B"),
    kb(false, false, false, K::L,      d!(Command::SetTool(Tool::Line)),    "Line tool",    "L"),
    kb(false, false, false, K::A,      d!(Command::SetTool(Tool::Arc)),     "Arc tool",     "A"),
    kb(false, false, false, K::C,      d!(Command::SetTool(Tool::Circle)),  "Circle tool",  "C"),
    kb(false, false, false, K::P,      d!(Command::SetTool(Tool::Polygon)), "Polygon tool", "P"),
    kb(false, false, false, K::T,      d!(Command::SetTool(Tool::Text)),    "Text tool",    "T"),
    kb(false, false, false, K::M,      d!(Command::SetTool(Tool::Move)),    "Move tool",    "M"),
    kb(false, false, false, K::Escape, d!(Command::SetTool(Tool::Select)),  "Select tool",  "Esc"),
    // ── Alignment (Alt) ──
    kb(false, false, true,  K::L,      d!(Command::AlignLeft),          "Align left",      "Alt+L"),
    kb(false, false, true,  K::R,      d!(Command::AlignRight),         "Align right",     "Alt+R"),
    kb(false, false, true,  K::T,      d!(Command::AlignTop),           "Align top",       "Alt+T"),
    kb(false, false, true,  K::B,      d!(Command::AlignBottom),        "Align bottom",    "Alt+B"),
    kb(false, false, true,  K::H,      d!(Command::DistributeH),        "Distribute horiz","Alt+H"),
    kb(false, false, true,  K::V,      d!(Command::DistributeV),        "Distribute vert", "Alt+V"),
    // ── Transform ──
    kb(false, false, false, K::R,      d!(Command::RotateCw),           "Rotate CW",       "R"),
    kb(false, true,  false, K::R,      d!(Command::RotateCcw),          "Rotate CCW",      "Shift+R"),
    kb(false, false, false, K::X,      d!(Command::FlipHorizontal),     "Flip horizontal", "X"),
    kb(false, true,  false, K::X,      d!(Command::FlipVertical),       "Flip vertical",   "Shift+X"),
    kb(false, false, false, K::D,      d!(Command::DuplicateSelected),  "Duplicate",       "D"),
    // ── View toggles ──
    kb(false, false, false, K::G,      d!(Command::ToggleGrid),         "Toggle grid",     "G"),
    kb(false, false, false, K::F,      d!(Command::ZoomFit),            "Zoom fit",        "F"),
    kb(false, false, false, K::Z,      d!(Command::ZoomFit),            "Zoom fit",        "Z"),
    kb(false, false, false, K::F11,    d!(Command::ToggleFullscreen),   "Fullscreen",      "F11"),
    // ── View mode switches ──
    kb(false, false, false, K::S,      KC::SetView(ViewMode::Schematic),     "Schematic view", "S"),
    kb(false, true,  false, K::V,      KC::SetView(ViewMode::Symbol),        "Symbol view",    "Shift+V"),
    kb(false, true,  false, K::D,      KC::SetView(ViewMode::Documentation), "Doc view",       "Shift+D"),
    // ── Dialogs ──
    kb(false, false, false, K::Q,      d!(Command::OpenPropsDialog),    "Properties",      "Q"),
    kb(false, false, false, K::I,      d!(Command::OpenLibraryBrowser), "Library browser", "I"),
    // ── Simulation ──
    kb(false, false, false, K::F5,     d!(Command::RunSim),             "Run simulation",  "F5"),
    kb(false, false, false, K::F6,     d!(Command::PluginsRefresh),     "Refresh plugins", "F6"),
    // ── Delete ──
    kb(false, false, false, K::Delete,    d!(Command::DeleteSelected),  "Delete",          "Del"),
    kb(false, false, false, K::Backspace, d!(Command::DeleteSelected),  "Delete",          "Backspace"),
    // ── Arrow nudge ──
    kb(false, false, false, K::ArrowUp,    d!(Command::NudgeUp),        "Nudge up",        "Up"),
    kb(false, false, false, K::ArrowDown,  d!(Command::NudgeDown),      "Nudge down",      "Down"),
    kb(false, false, false, K::ArrowLeft,  d!(Command::NudgeLeft),      "Nudge left",      "Left"),
    kb(false, false, false, K::ArrowRight, d!(Command::NudgeRight),     "Nudge right",     "Right"),
    // ── Command mode ──
    kb(false, true,  false, K::Semicolon, KC::EnterCommandMode,         "Command mode",    ":"),
];

/// Look up the first matching keybind for the current frame's input.
pub fn lookup(ctx: &egui::Context) -> Option<&'static Keybind> {
    ctx.input(|i| {
        let ctrl = i.modifiers.ctrl || i.modifiers.mac_cmd;
        let (shift, alt) = (i.modifiers.shift, i.modifiers.alt);
        KEYBINDS.iter().find(|kb| {
            kb.ctrl == ctrl && kb.shift == shift && kb.alt == alt && i.key_pressed(kb.key)
        })
    })
}

/// Pure-logic lookup against the table (testable without an egui context).
pub fn find_keybind(ctrl: bool, shift: bool, alt: bool, key: egui::Key) -> Option<&'static Keybind> {
    KEYBINDS
        .iter()
        .find(|kb| kb.ctrl == ctrl && kb.shift == shift && kb.alt == alt && kb.key == key)
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn basic_lookups() {
        assert!(matches!(
            find_keybind(false, false, false, K::W).unwrap().command,
            KC::Dispatch(Command::SetTool(Tool::Wire))
        ));
        assert!(matches!(
            find_keybind(true, false, false, K::Z).unwrap().command,
            KC::Dispatch(Command::Undo)
        ));
        assert!(matches!(
            find_keybind(false, true, false, K::R).unwrap().command,
            KC::Dispatch(Command::RotateCcw)
        ));
        assert!(matches!(
            find_keybind(true, false, false, K::S).unwrap().command,
            KC::SaveFile
        ));
        assert!(matches!(
            find_keybind(false, true, false, K::Semicolon).unwrap().command,
            KC::EnterCommandMode
        ));
        assert!(find_keybind(true, true, true, K::Q).is_none());
    }

    #[test]
    fn nudges_and_delete() {
        for (key, want) in [
            (K::ArrowUp, "Nudge up"),
            (K::ArrowDown, "Nudge down"),
            (K::ArrowLeft, "Nudge left"),
            (K::ArrowRight, "Nudge right"),
            (K::Delete, "Delete"),
        ] {
            assert_eq!(find_keybind(false, false, false, key).unwrap().label, want);
        }
    }

    #[test]
    fn no_duplicate_combos() {
        let mut seen = HashSet::new();
        for kb in KEYBINDS {
            assert!(
                seen.insert((kb.ctrl, kb.shift, kb.alt, kb.key)),
                "duplicate keybind for {:?} (ctrl={}, shift={}, alt={})",
                kb.key,
                kb.ctrl,
                kb.shift,
                kb.alt
            );
        }
    }

    #[test]
    fn table_integrity() {
        assert!(KEYBINDS.len() > 40, "expected a full table, got {}", KEYBINDS.len());
        for kb in KEYBINDS {
            assert!(!kb.label.is_empty());
            assert!(!kb.shortcut.is_empty());
        }
    }
}
