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
    #[allow(dead_code)]
    SetViewDoc,
}

pub struct Keybind {
    pub ctrl: bool,
    pub shift: bool,
    pub alt: bool,
    pub key: egui::Key,
    pub command: KeyCommand,
    #[allow(dead_code)]
    pub label: &'static str,
    #[allow(dead_code)]
    pub shortcut: &'static str,
}

/// Full keybind table, ported from Zig reference `keybinds.zig`.
///
/// Ordering: ctrl binds first, then shift, then plain keys.
/// This is a flat scan — the table is small enough that binary
/// search buys nothing over branch-predicted iteration.
pub static KEYBINDS: &[Keybind] = &[
    // ── File ────────────────────────────────────────────
    kb(
        true,
        false,
        false,
        egui::Key::N,
        KeyCommand::Dispatch(Command::FileNew),
        "New file",
        "Ctrl+N",
    ),
    kb(
        true,
        false,
        false,
        egui::Key::O,
        KeyCommand::Dispatch(Command::FileOpen),
        "Open file",
        "Ctrl+O",
    ),
    kb(
        true,
        false,
        false,
        egui::Key::S,
        KeyCommand::Dispatch(Command::FileSave),
        "Save",
        "Ctrl+S",
    ),
    kb(
        true,
        true,
        false,
        egui::Key::S,
        KeyCommand::Dispatch(Command::FileSaveAs),
        "Save as",
        "Ctrl+Shift+S",
    ),
    kb(
        true,
        false,
        false,
        egui::Key::T,
        KeyCommand::Dispatch(Command::NewTab),
        "New tab",
        "Ctrl+T",
    ),
    kb(
        true,
        false,
        false,
        egui::Key::W,
        KeyCommand::Dispatch(Command::CloseTab(0)),
        "Close tab",
        "Ctrl+W",
    ),
    // ── Undo / Redo ─────────────────────────────────────
    kb(
        true,
        false,
        false,
        egui::Key::Z,
        KeyCommand::Dispatch(Command::Undo),
        "Undo",
        "Ctrl+Z",
    ),
    kb(
        true,
        false,
        false,
        egui::Key::Y,
        KeyCommand::Dispatch(Command::Redo),
        "Redo",
        "Ctrl+Y",
    ),
    // ── Clipboard ───────────────────────────────────────
    kb(
        true,
        false,
        false,
        egui::Key::X,
        KeyCommand::Dispatch(Command::Cut),
        "Cut",
        "Ctrl+X",
    ),
    kb(
        true,
        false,
        false,
        egui::Key::C,
        KeyCommand::Dispatch(Command::Copy),
        "Copy",
        "Ctrl+C",
    ),
    kb(
        true,
        false,
        false,
        egui::Key::V,
        KeyCommand::Dispatch(Command::Paste),
        "Paste",
        "Ctrl+V",
    ),
    // ── Selection ───────────────────────────────────────
    kb(
        true,
        false,
        false,
        egui::Key::A,
        KeyCommand::Dispatch(Command::SelectAll),
        "Select all",
        "Ctrl+A",
    ),
    kb(
        true,
        true,
        false,
        egui::Key::A,
        KeyCommand::Dispatch(Command::SelectNone),
        "Select none",
        "Ctrl+Shift+A",
    ),
    kb(
        true,
        false,
        false,
        egui::Key::D,
        KeyCommand::Dispatch(Command::DuplicateSelected),
        "Duplicate",
        "Ctrl+D",
    ),
    // ── Find ────────────────────────────────────────────
    kb(
        true,
        false,
        false,
        egui::Key::F,
        KeyCommand::Dispatch(Command::OpenFindDialog),
        "Find",
        "Ctrl+F",
    ),
    // ── Zoom (Ctrl) ─────────────────────────────────────
    kb(
        true,
        false,
        false,
        egui::Key::Equals,
        KeyCommand::Dispatch(Command::ZoomIn),
        "Zoom in",
        "Ctrl+=",
    ),
    kb(
        true,
        false,
        false,
        egui::Key::Minus,
        KeyCommand::Dispatch(Command::ZoomOut),
        "Zoom out",
        "Ctrl+-",
    ),
    kb(
        true,
        false,
        false,
        egui::Key::Num0,
        KeyCommand::Dispatch(Command::ZoomReset),
        "Zoom reset",
        "Ctrl+0",
    ),
    // ── Tools (no modifiers) ────────────────────────────
    kb(
        false,
        false,
        false,
        egui::Key::W,
        KeyCommand::Dispatch(Command::SetTool(Tool::Wire)),
        "Wire tool",
        "W",
    ),
    kb(
        false,
        false,
        false,
        egui::Key::L,
        KeyCommand::Dispatch(Command::SetTool(Tool::Line)),
        "Line tool",
        "L",
    ),
    kb(
        false,
        false,
        false,
        egui::Key::A,
        KeyCommand::Dispatch(Command::SetTool(Tool::Arc)),
        "Arc tool",
        "A",
    ),
    kb(
        false,
        false,
        false,
        egui::Key::C,
        KeyCommand::Dispatch(Command::SetTool(Tool::Circle)),
        "Circle tool",
        "C",
    ),
    kb(
        false,
        false,
        false,
        egui::Key::P,
        KeyCommand::Dispatch(Command::SetTool(Tool::Polygon)),
        "Polygon tool",
        "P",
    ),
    kb(
        false,
        false,
        false,
        egui::Key::T,
        KeyCommand::Dispatch(Command::SetTool(Tool::Text)),
        "Text tool",
        "T",
    ),
    kb(
        false,
        false,
        false,
        egui::Key::M,
        KeyCommand::Dispatch(Command::SetTool(Tool::Move)),
        "Move tool",
        "M",
    ),
    kb(
        false,
        false,
        false,
        egui::Key::Escape,
        KeyCommand::Dispatch(Command::SetTool(Tool::Select)),
        "Select tool",
        "Esc",
    ),
    // ── Transform (no ctrl) ─────────────────────────────
    kb(
        false,
        false,
        false,
        egui::Key::R,
        KeyCommand::Dispatch(Command::RotateCw),
        "Rotate CW",
        "R",
    ),
    kb(
        false,
        true,
        false,
        egui::Key::R,
        KeyCommand::Dispatch(Command::RotateCcw),
        "Rotate CCW",
        "Shift+R",
    ),
    kb(
        false,
        false,
        false,
        egui::Key::X,
        KeyCommand::Dispatch(Command::FlipHorizontal),
        "Flip horizontal",
        "X",
    ),
    kb(
        false,
        true,
        false,
        egui::Key::X,
        KeyCommand::Dispatch(Command::FlipVertical),
        "Flip vertical",
        "Shift+X",
    ),
    kb(
        false,
        false,
        false,
        egui::Key::D,
        KeyCommand::Dispatch(Command::DuplicateSelected),
        "Duplicate",
        "D",
    ),
    // ── View toggles ────────────────────────────────────
    kb(
        false,
        false,
        false,
        egui::Key::G,
        KeyCommand::Dispatch(Command::ToggleGrid),
        "Toggle grid",
        "G",
    ),
    kb(
        false,
        false,
        false,
        egui::Key::F,
        KeyCommand::Dispatch(Command::ZoomFit),
        "Zoom fit",
        "F",
    ),
    kb(
        false,
        false,
        false,
        egui::Key::Z,
        KeyCommand::Dispatch(Command::ZoomFit),
        "Zoom fit",
        "Z",
    ),
    // ── View mode switches ──────────────────────────────
    kb(
        false,
        false,
        false,
        egui::Key::S,
        KeyCommand::SetViewSchematic,
        "Schematic view",
        "S",
    ),
    kb(
        false,
        true,
        false,
        egui::Key::V,
        KeyCommand::SetViewSymbol,
        "Symbol view",
        "Shift+V",
    ),
    // ── Dialogs ─────────────────────────────────────────
    kb(
        false,
        false,
        false,
        egui::Key::Q,
        KeyCommand::Dispatch(Command::OpenPropsDialog),
        "Properties",
        "Q",
    ),
    // ── Simulation ──────────────────────────────────────
    kb(
        false,
        false,
        false,
        egui::Key::F5,
        KeyCommand::Dispatch(Command::RunSim),
        "Run simulation",
        "F5",
    ),
    kb(
        false,
        false,
        false,
        egui::Key::F6,
        KeyCommand::Dispatch(Command::PluginsRefresh),
        "Refresh plugins",
        "F6",
    ),
    // ── Delete ──────────────────────────────────────────
    kb(
        false,
        false,
        false,
        egui::Key::Delete,
        KeyCommand::Dispatch(Command::DeleteSelected),
        "Delete",
        "Del",
    ),
    kb(
        false,
        false,
        false,
        egui::Key::Backspace,
        KeyCommand::Dispatch(Command::DeleteSelected),
        "Delete",
        "Backspace",
    ),
    // ── Arrow nudge ─────────────────────────────────────
    kb(
        false,
        false,
        false,
        egui::Key::ArrowUp,
        KeyCommand::Dispatch(Command::NudgeUp),
        "Nudge up",
        "Up",
    ),
    kb(
        false,
        false,
        false,
        egui::Key::ArrowDown,
        KeyCommand::Dispatch(Command::NudgeDown),
        "Nudge down",
        "Down",
    ),
    kb(
        false,
        false,
        false,
        egui::Key::ArrowLeft,
        KeyCommand::Dispatch(Command::NudgeLeft),
        "Nudge left",
        "Left",
    ),
    kb(
        false,
        false,
        false,
        egui::Key::ArrowRight,
        KeyCommand::Dispatch(Command::NudgeRight),
        "Nudge right",
        "Right",
    ),
    // ── Command mode ────────────────────────────────────
    kb(
        false,
        true,
        false,
        egui::Key::Semicolon,
        KeyCommand::EnterCommandMode,
        "Command mode",
        ":",
    ),
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

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    /// Helper: find the first keybind matching the given modifiers + key.
    fn find_keybind(
        ctrl: bool,
        shift: bool,
        alt: bool,
        key: egui::Key,
    ) -> Option<&'static Keybind> {
        KEYBINDS
            .iter()
            .find(|kb| kb.ctrl == ctrl && kb.shift == shift && kb.alt == alt && kb.key == key)
    }

    // ── Specific keybind mappings ───────────────────────────────────────────

    #[test]
    fn t_maps_to_text_tool() {
        let kb = find_keybind(false, false, false, egui::Key::T).expect("T keybind not found");
        match &kb.command {
            KeyCommand::Dispatch(Command::SetTool(Tool::Text)) => {}
            other => panic!("T should map to SetTool(Text), got {other:?}"),
        }
    }

    #[test]
    fn r_maps_to_rotate_cw() {
        let kb = find_keybind(false, false, false, egui::Key::R).expect("R keybind not found");
        match &kb.command {
            KeyCommand::Dispatch(Command::RotateCw) => {}
            other => panic!("R should map to RotateCw, got {other:?}"),
        }
    }

    #[test]
    fn shift_r_maps_to_rotate_ccw() {
        let kb = find_keybind(false, true, false, egui::Key::R).expect("Shift+R keybind not found");
        match &kb.command {
            KeyCommand::Dispatch(Command::RotateCcw) => {}
            other => panic!("Shift+R should map to RotateCcw, got {other:?}"),
        }
    }

    #[test]
    fn w_maps_to_wire_tool() {
        let kb = find_keybind(false, false, false, egui::Key::W).expect("W keybind not found");
        match &kb.command {
            KeyCommand::Dispatch(Command::SetTool(Tool::Wire)) => {}
            other => panic!("W should map to SetTool(Wire), got {other:?}"),
        }
    }

    #[test]
    fn escape_maps_to_select_tool() {
        let kb =
            find_keybind(false, false, false, egui::Key::Escape).expect("Esc keybind not found");
        match &kb.command {
            KeyCommand::Dispatch(Command::SetTool(Tool::Select)) => {}
            other => panic!("Escape should map to SetTool(Select), got {other:?}"),
        }
    }

    #[test]
    fn ctrl_z_maps_to_undo() {
        let kb = find_keybind(true, false, false, egui::Key::Z).expect("Ctrl+Z keybind not found");
        match &kb.command {
            KeyCommand::Dispatch(Command::Undo) => {}
            other => panic!("Ctrl+Z should map to Undo, got {other:?}"),
        }
    }

    #[test]
    fn ctrl_y_maps_to_redo() {
        let kb = find_keybind(true, false, false, egui::Key::Y).expect("Ctrl+Y keybind not found");
        match &kb.command {
            KeyCommand::Dispatch(Command::Redo) => {}
            other => panic!("Ctrl+Y should map to Redo, got {other:?}"),
        }
    }

    #[test]
    fn ctrl_s_maps_to_save() {
        let kb = find_keybind(true, false, false, egui::Key::S).expect("Ctrl+S keybind not found");
        match &kb.command {
            KeyCommand::Dispatch(Command::FileSave) => {}
            other => panic!("Ctrl+S should map to FileSave, got {other:?}"),
        }
    }

    #[test]
    fn delete_maps_to_delete_selected() {
        let kb =
            find_keybind(false, false, false, egui::Key::Delete).expect("Del keybind not found");
        match &kb.command {
            KeyCommand::Dispatch(Command::DeleteSelected) => {}
            other => panic!("Delete should map to DeleteSelected, got {other:?}"),
        }
    }

    #[test]
    fn x_maps_to_flip_horizontal() {
        let kb = find_keybind(false, false, false, egui::Key::X).expect("X keybind not found");
        match &kb.command {
            KeyCommand::Dispatch(Command::FlipHorizontal) => {}
            other => panic!("X should map to FlipHorizontal, got {other:?}"),
        }
    }

    #[test]
    fn m_maps_to_move_tool() {
        let kb = find_keybind(false, false, false, egui::Key::M).expect("M keybind not found");
        match &kb.command {
            KeyCommand::Dispatch(Command::SetTool(Tool::Move)) => {}
            other => panic!("M should map to SetTool(Move), got {other:?}"),
        }
    }

    #[test]
    fn arrow_keys_map_to_nudge() {
        let up = find_keybind(false, false, false, egui::Key::ArrowUp).expect("Up not found");
        let down = find_keybind(false, false, false, egui::Key::ArrowDown).expect("Down not found");
        let left = find_keybind(false, false, false, egui::Key::ArrowLeft).expect("Left not found");
        let right =
            find_keybind(false, false, false, egui::Key::ArrowRight).expect("Right not found");

        assert!(matches!(
            &up.command,
            KeyCommand::Dispatch(Command::NudgeUp)
        ));
        assert!(matches!(
            &down.command,
            KeyCommand::Dispatch(Command::NudgeDown)
        ));
        assert!(matches!(
            &left.command,
            KeyCommand::Dispatch(Command::NudgeLeft)
        ));
        assert!(matches!(
            &right.command,
            KeyCommand::Dispatch(Command::NudgeRight)
        ));
    }

    // ── Table integrity ─────────────────────────────────────────────────────

    #[test]
    fn no_duplicate_keybinds_for_same_combo() {
        // With modifier-differentiated binds, the same (ctrl, shift, alt, key)
        // tuple should not appear more than once (first match wins, so duplicates
        // are dead code).
        let mut seen = HashSet::new();
        for kb in KEYBINDS {
            let combo = (kb.ctrl, kb.shift, kb.alt, kb.key);
            assert!(
                seen.insert(combo),
                "Duplicate keybind for {:?} (ctrl={}, shift={}, alt={})",
                kb.key,
                kb.ctrl,
                kb.shift,
                kb.alt,
            );
        }
    }

    #[test]
    fn every_keybind_has_nonempty_label() {
        for kb in KEYBINDS {
            assert!(
                !kb.label.is_empty(),
                "Keybind for {:?} has empty label",
                kb.key
            );
        }
    }

    #[test]
    fn every_keybind_has_nonempty_shortcut_string() {
        for kb in KEYBINDS {
            assert!(
                !kb.shortcut.is_empty(),
                "Keybind for {:?} has empty shortcut string",
                kb.key
            );
        }
    }

    #[test]
    fn keybind_table_is_not_empty() {
        assert!(
            KEYBINDS.len() > 20,
            "Expected at least 20 keybinds, got {}",
            KEYBINDS.len()
        );
    }
}
