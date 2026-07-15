//! Undo/redo ring: UndoEntry, push/pop, command inversion.



use crate::schemify::{
    Command, Schematic,
};

use super::*;

#[derive(Debug, Clone)]
pub enum UndoEntry {
    Inverse(Command),
    Snapshot(Box<Schematic>),
}

impl App {
    pub(crate) fn push_undo(&mut self, entry: UndoEntry) {
        let doc = self.state.active_document_mut();
        doc.redo_history.clear();
        if doc.undo_history.len() >= MAX_UNDO_HISTORY {
            doc.undo_history.pop_front();
        }
        doc.undo_history.push_back(entry);
        doc.dirty = true;
    }

    pub(crate) fn push_undo_snapshot(&mut self) {
        let sch = self.state.active_document().schematic.clone();
        self.push_undo(UndoEntry::Snapshot(Box::new(sch)));
    }

    pub(crate) fn handle_undo(&mut self) {
        let Some(entry) = self.state.active_document_mut().undo_history.pop_back() else {
            return;
        };
        match entry {
            UndoEntry::Inverse(inv_cmd) => {
                let redo_entry = UndoEntry::Inverse(invert_command(&inv_cmd));
                // Execute the inverse without pushing undo.
                self.exec_invertible(&inv_cmd);
                self.state
                    .active_document_mut()
                    .redo_history
                    .push_back(redo_entry);
            }
            UndoEntry::Snapshot(old_schematic) => {
                let doc = self.state.active_document_mut();
                let current = std::mem::replace(&mut doc.schematic, *old_schematic);
                doc.redo_history
                    .push_back(UndoEntry::Snapshot(Box::new(current)));
            }
        }
        self.touch();
    }

    pub(crate) fn handle_redo(&mut self) {
        let Some(entry) = self.state.active_document_mut().redo_history.pop_back() else {
            return;
        };
        match entry {
            UndoEntry::Inverse(cmd) => {
                let undo_entry = UndoEntry::Inverse(invert_command(&cmd));
                self.exec_invertible(&cmd);
                self.state
                    .active_document_mut()
                    .undo_history
                    .push_back(undo_entry);
            }
            UndoEntry::Snapshot(old_schematic) => {
                let doc = self.state.active_document_mut();
                let current = std::mem::replace(&mut doc.schematic, *old_schematic);
                doc.undo_history
                    .push_back(UndoEntry::Snapshot(Box::new(current)));
            }
        }
        self.touch();
    }

    /// Execute an invertible command directly (used by undo/redo, no undo push).
    pub(crate) fn exec_invertible(&mut self, cmd: &Command) {
        use Command::*;
        let s = self.state.tool.snap_size as i32;
        match cmd {
            MoveInstance { idx, dx, dy } => {
                self.state
                    .active_document_mut()
                    .schematic
                    .translate_instance(*idx, *dx, *dy);
            }
            MoveWire { idx, dx, dy } => {
                self.state
                    .active_document_mut()
                    .schematic
                    .translate_wire(*idx, *dx, *dy);
            }
            MoveSelected { dx, dy } => self.move_selected(*dx, *dy),
            NudgeUp => self.move_selected(0, -s),
            NudgeDown => self.move_selected(0, s),
            NudgeLeft => self.move_selected(-s, 0),
            NudgeRight => self.move_selected(s, 0),
            RotateCw => self.rotate_selected(true),
            RotateCcw => self.rotate_selected(false),
            FlipHorizontal => self.flip_selected(true),
            FlipVertical => self.flip_selected(false),
            _ => {}
        }
    }

    /// Bump the active document's mutation generation; the connectivity
    /// cache compares generations and recomputes lazily.
    pub(crate) fn touch(&mut self) {
        self.state.active_document_mut().generation += 1;
    }
}

pub(crate) fn invert_command(cmd: &Command) -> Command {
    use Command::*;
    match cmd {
        MoveInstance { idx, dx, dy } => MoveInstance {
            idx: *idx,
            dx: -*dx,
            dy: -*dy,
        },
        MoveWire { idx, dx, dy } => MoveWire {
            idx: *idx,
            dx: -*dx,
            dy: -*dy,
        },
        MoveSelected { dx, dy } => MoveSelected { dx: -*dx, dy: -*dy },
        RotateCw => RotateCcw,
        RotateCcw => RotateCw,
        FlipHorizontal => FlipHorizontal,
        FlipVertical => FlipVertical,
        NudgeUp => NudgeDown,
        NudgeDown => NudgeUp,
        NudgeLeft => NudgeRight,
        NudgeRight => NudgeLeft,
        _ => unreachable!("invert_command called on non-invertible command"),
    }
}

// ════════════════════════════════════════════════════════════
// Movement & transform helpers (App side)
// ════════════════════════════════════════════════════════════

