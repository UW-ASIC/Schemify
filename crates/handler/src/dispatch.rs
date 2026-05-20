use schemify_core::commands::Command;
use schemify_core::schematic::{
    Arc, Circle, Instance, InstanceVec, Line, Rect, Schematic, Text, Wire, WireVec,
};
use schemify_core::types::{Color, DeviceKind, InstanceFlags};

use crate::state::*;
use crate::App;

// ════════════════════════════════════════════════════════════
// Public dispatch entry point
// ════════════════════════════════════════════════════════════

impl App {
    /// Single entry point for all mutations. Handles undo, execution,
    /// and connectivity invalidation per command variant.
    pub fn dispatch(&mut self, cmd: Command) {
        use Command::*;
        match cmd {
            // ── Meta ──
            Undo => self.handle_undo(),
            Redo => self.handle_redo(),

            // ── View (immediate, no undo) ──
            ZoomIn => self.state.active_document_mut().viewport.zoom_in(),
            ZoomOut => self.state.active_document_mut().viewport.zoom_out(),
            ZoomReset => self.state.active_document_mut().viewport.zoom_reset(),
            ZoomFit => self.handle_zoom_fit(),
            ToggleFullscreen => {
                self.state.view.view_flags.fullscreen = !self.state.view.view_flags.fullscreen;
            }
            ToggleColorScheme => {
                self.state.view.view_flags.dark_mode = !self.state.view.view_flags.dark_mode;
            }
            ToggleGrid => {
                self.state.view.show_grid = !self.state.view.show_grid;
            }

            // ── File (immediate, no undo) ──
            FileNew | NewTab => {
                self.state.documents.push(Document::default());
                self.state.active_doc = self.state.documents.len() - 1;
            }
            FileOpen => {
                // Display crate shows file dialog, then calls app.open_file(path)
            }
            FileSave => self.handle_file_save(),
            FileSaveAs => {
                // Display crate shows save dialog, then calls app.save_to_path(path)
            }
            CloseTab(idx) => {
                if self.state.documents.len() > 1 && idx < self.state.documents.len() {
                    self.state.documents.remove(idx);
                    if self.state.active_doc >= self.state.documents.len() {
                        self.state.active_doc = self.state.documents.len() - 1;
                    } else if self.state.active_doc > idx {
                        self.state.active_doc -= 1;
                    }
                }
            }
            SwitchTab(idx) => {
                if idx < self.state.documents.len() {
                    self.state.active_doc = idx;
                }
            }
            ReloadFromDisk => self.handle_reload(),

            // ── Selection (immediate, no undo) ──
            SelectAll => {
                let doc = self.state.active_document_mut();
                let sch = &doc.schematic;
                doc.selection.instances = (0..sch.instances.len()).collect();
                doc.selection.wires = (0..sch.wires.len()).collect();
                doc.selection.lines = (0..sch.lines.len()).collect();
                doc.selection.rects = (0..sch.rects.len()).collect();
                doc.selection.circles = (0..sch.circles.len()).collect();
                doc.selection.arcs = (0..sch.arcs.len()).collect();
                doc.selection.texts = (0..sch.texts.len()).collect();
                doc.selection.polygons = (0..sch.polygons.len()).collect();
            }
            SelectNone => self.state.active_document_mut().selection.clear(),
            InvertSelection => {
                let doc = self.state.active_document_mut();
                invert_set(&mut doc.selection.instances, doc.schematic.instances.len());
                invert_set(&mut doc.selection.wires, doc.schematic.wires.len());
                invert_set(&mut doc.selection.lines, doc.schematic.lines.len());
                invert_set(&mut doc.selection.rects, doc.schematic.rects.len());
                invert_set(&mut doc.selection.circles, doc.schematic.circles.len());
                invert_set(&mut doc.selection.arcs, doc.schematic.arcs.len());
                invert_set(&mut doc.selection.texts, doc.schematic.texts.len());
                invert_set(&mut doc.selection.polygons, doc.schematic.polygons.len());
            }

            // ── Clipboard (immediate for copy, undoable for cut/paste) ──
            Copy => self.copy_to_clipboard(),
            Cut => {
                self.push_undo_snapshot();
                self.copy_to_clipboard();
                self.exec_delete_selected();
                self.invalidate_connectivity();
            }
            Paste => {
                if !self.state.clipboard.is_empty() {
                    self.push_undo_snapshot();
                    self.paste_from_clipboard();
                    self.invalidate_connectivity();
                }
            }

            // ── Tool (immediate) ──
            SetTool(t) => {
                self.state.tool.active = t;
                self.state.tool.wire_start = None;
                self.state.tool.placement = None;
                self.state.tool.draw = DrawState::default();
            }

            // ── Dialogs (immediate) ──
            OpenFindDialog => self.state.dialogs.find.is_open = true,
            OpenPropsDialog => self.state.dialogs.props.is_open = true,
            OpenSettings => self.state.dialogs.settings.is_open = true,
            OpenSpiceCodeEditor => {
                self.state.dialogs.spice_code.is_open = true;
                self.state.dialogs.spice_code.buf =
                    self.state.active_document().schematic.spice_body.clone();
            }
            OpenNewPrimDialog => self.state.dialogs.new_prim.is_open = true,
            OpenMarketplace => self.state.dialogs.marketplace.is_open = true,
            OpenImportDialog => self.state.dialogs.import.is_open = true,

            // ── Movement (invertible, push inverse) ──
            MoveInstance { idx, dx, dy } => {
                self.push_undo(UndoEntry::Inverse(MoveInstance {
                    idx,
                    dx: -dx,
                    dy: -dy,
                }));
                let doc = self.state.active_document_mut();
                if idx < doc.schematic.instances.len() {
                    doc.schematic.instances.x[idx] += dx;
                    doc.schematic.instances.y[idx] += dy;
                }
                self.invalidate_connectivity();
            }
            MoveWire { idx, dx, dy } => {
                self.push_undo(UndoEntry::Inverse(MoveWire {
                    idx,
                    dx: -dx,
                    dy: -dy,
                }));
                let doc = self.state.active_document_mut();
                if idx < doc.schematic.wires.len() {
                    doc.schematic.wires.x0[idx] += dx;
                    doc.schematic.wires.y0[idx] += dy;
                    doc.schematic.wires.x1[idx] += dx;
                    doc.schematic.wires.y1[idx] += dy;
                }
                self.invalidate_connectivity();
            }
            MoveSelected { dx, dy } => {
                self.push_undo(UndoEntry::Inverse(MoveSelected { dx: -dx, dy: -dy }));
                self.move_selected(dx, dy);
                self.invalidate_connectivity();
            }

            // ── Nudge (invertible via opposite direction) ──
            NudgeUp => {
                self.push_undo(UndoEntry::Inverse(NudgeDown));
                let s = self.state.tool.snap_size as i32;
                self.move_selected(0, -s);
                self.invalidate_connectivity();
            }
            NudgeDown => {
                self.push_undo(UndoEntry::Inverse(NudgeUp));
                let s = self.state.tool.snap_size as i32;
                self.move_selected(0, s);
                self.invalidate_connectivity();
            }
            NudgeLeft => {
                self.push_undo(UndoEntry::Inverse(NudgeRight));
                let s = self.state.tool.snap_size as i32;
                self.move_selected(-s, 0);
                self.invalidate_connectivity();
            }
            NudgeRight => {
                self.push_undo(UndoEntry::Inverse(NudgeLeft));
                let s = self.state.tool.snap_size as i32;
                self.move_selected(s, 0);
                self.invalidate_connectivity();
            }

            // ── Transform (invertible) ──
            RotateCw => {
                self.push_undo(UndoEntry::Inverse(RotateCcw));
                self.rotate_selected(true);
                self.invalidate_connectivity();
            }
            RotateCcw => {
                self.push_undo(UndoEntry::Inverse(RotateCw));
                self.rotate_selected(false);
                self.invalidate_connectivity();
            }
            FlipHorizontal => {
                self.push_undo(UndoEntry::Inverse(FlipHorizontal));
                self.flip_selected(true);
                self.invalidate_connectivity();
            }
            FlipVertical => {
                self.push_undo(UndoEntry::Inverse(FlipVertical));
                self.flip_selected(false);
                self.invalidate_connectivity();
            }

            // ── Align (snapshot — not trivially invertible) ──
            AlignToGrid => {
                self.push_undo_snapshot();
                self.align_selected_to_grid();
                self.invalidate_connectivity();
            }

            // ── Deletion (snapshot) ──
            DeleteSelected => {
                self.push_undo_snapshot();
                self.exec_delete_selected();
                self.invalidate_connectivity();
            }
            DeleteInstance(idx) => {
                let doc = self.state.active_document_mut();
                if idx < doc.schematic.instances.len() {
                    self.push_undo_snapshot();
                    self.state.active_document_mut().schematic.instances.remove(idx);
                    self.state.active_document_mut().selection.instances.remove(&idx);
                    self.invalidate_connectivity();
                }
            }
            DeleteWire(idx) => {
                let doc = self.state.active_document_mut();
                if idx < doc.schematic.wires.len() {
                    self.push_undo_snapshot();
                    self.state.active_document_mut().schematic.wires.remove(idx);
                    self.state.active_document_mut().selection.wires.remove(&idx);
                    self.invalidate_connectivity();
                }
            }

            // ── Duplication (snapshot) ──
            DuplicateSelected => {
                self.push_undo_snapshot();
                self.exec_duplicate_selected();
                self.invalidate_connectivity();
            }

            // ── Placement (snapshot) ──
            PlaceDevice {
                symbol_path,
                name,
                x,
                y,
                rotation,
                flip,
            } => {
                self.push_undo_snapshot();
                let sym = self.state.interner.get_or_intern(&symbol_path);
                let name_sym = self.state.interner.get_or_intern(&name);
                let empty = self.state.interner.get_or_intern("");
                let doc = self.state.active_document_mut();
                doc.schematic.instances.push(Instance {
                    name: name_sym,
                    symbol: sym,
                    spice_line: empty,
                    x,
                    y,
                    kind: DeviceKind::Unknown,
                    flags: InstanceFlags::new(rotation, flip, false),
                    prop_start: 0,
                    prop_count: 0,
                    name_offset: [0, 0],
                    param_offset: [0, 0],
                });
                self.invalidate_connectivity();
            }

            // ── Wiring (snapshot) ──
            AddWire {
                x0,
                y0,
                x1,
                y1,
                net_name,
                bus,
            } => {
                self.push_undo_snapshot();
                let net_sym = match net_name {
                    Some(ref n) => self.state.interner.get_or_intern(n),
                    None => self.state.interner.get_or_intern(""),
                };
                let doc = self.state.active_document_mut();
                doc.schematic.wires.push(Wire {
                    net_name: net_sym,
                    x0,
                    y0,
                    x1,
                    y1,
                    color: Color::NONE,
                    thickness: 10,
                    bus,
                });
                self.invalidate_connectivity();
            }

            // ── Geometry (snapshot) ──
            AddLine { x0, y0, x1, y1 } => {
                self.push_undo_snapshot();
                let doc = self.state.active_document_mut();
                doc.schematic.lines.push(Line {
                    x0,
                    y0,
                    x1,
                    y1,
                    color: Color::NONE,
                    thickness: 1,
                });
                self.invalidate_connectivity();
            }
            AddRect { x, y, w, h } => {
                self.push_undo_snapshot();
                let doc = self.state.active_document_mut();
                doc.schematic.rects.push(Rect {
                    x,
                    y,
                    width: w,
                    height: h,
                    fill: Color::NONE,
                    stroke: Color::NONE,
                    thickness: 1,
                });
            }
            AddCircle { cx, cy, radius } => {
                self.push_undo_snapshot();
                let doc = self.state.active_document_mut();
                doc.schematic.circles.push(Circle {
                    cx,
                    cy,
                    radius,
                    fill: Color::NONE,
                    stroke: Color::NONE,
                    thickness: 1,
                });
            }
            AddArc {
                cx,
                cy,
                radius,
                start,
                sweep,
            } => {
                self.push_undo_snapshot();
                let doc = self.state.active_document_mut();
                doc.schematic.arcs.push(Arc {
                    cx,
                    cy,
                    radius,
                    start_angle: start,
                    sweep_angle: sweep,
                    stroke: Color::NONE,
                    thickness: 1,
                });
            }
            AddText { x, y, content } => {
                self.push_undo_snapshot();
                let sym = self.state.interner.get_or_intern(&content);
                let doc = self.state.active_document_mut();
                doc.schematic.texts.push(Text {
                    x,
                    y,
                    content: sym,
                    font_size: 10.0,
                    color: Color::NONE,
                    rotation: 0,
                });
            }

            // ── Properties (snapshot) ──
            SetInstanceProp { idx, key, value } => {
                self.push_undo_snapshot();
                let key_sym = self.state.interner.get_or_intern(&key);
                let value_sym = self.state.interner.get_or_intern(&value);
                set_instance_prop(
                    &mut self.state.documents[self.state.active_doc].schematic,
                    idx,
                    key_sym,
                    value_sym,
                );
            }
            RenameInstance { idx, new_name } => {
                self.push_undo_snapshot();
                let sym = self.state.interner.get_or_intern(&new_name);
                let doc = self.state.active_document_mut();
                if idx < doc.schematic.instances.len() {
                    doc.schematic.instances.name[idx] = sym;
                }
            }
            RenameNet {
                old_name,
                new_name,
            } => {
                self.push_undo_snapshot();
                let old_sym = self.state.interner.get_or_intern(&old_name);
                let new_sym = self.state.interner.get_or_intern(&new_name);
                let doc = self.state.active_document_mut();
                for i in 0..doc.schematic.wires.len() {
                    if doc.schematic.wires.net_name[i] == old_sym {
                        doc.schematic.wires.net_name[i] = new_sym;
                    }
                }
                self.invalidate_connectivity();
            }
            SetSpiceCode(code) => {
                self.push_undo_snapshot();
                self.state.active_document_mut().schematic.spice_body = code;
            }
            SetDocumentation(text) => {
                self.push_undo_snapshot();
                self.state.active_document_mut().schematic.documentation = text;
            }
            SetWireColor { idx, color } => {
                self.push_undo_snapshot();
                let doc = self.state.active_document_mut();
                if idx < doc.schematic.wires.len() {
                    doc.schematic.wires.color[idx] = color;
                }
            }

            // ── Simulation (placeholder — sim crate not implemented) ──
            RunSim => {
                self.state.status_msg = "Simulation not yet implemented".into();
            }

            // ── Layout (placeholder) ──
            AutoLayout => {
                self.state.status_msg = "Auto-layout not yet implemented".into();
            }

            // ── Import ──
            ImportSpice { path } => {
                match std::fs::read_to_string(&path) {
                    Ok(source) => {
                        match crate::spice_import::import_spice(
                            &source,
                            &mut self.state.interner,
                        ) {
                            Ok(schematic) => {
                                let name = std::path::Path::new(&path)
                                    .file_stem()
                                    .unwrap_or_default()
                                    .to_string_lossy()
                                    .into_owned();
                                let doc = Document {
                                    schematic,
                                    name,
                                    origin: Origin::File(path.into()),
                                    ..Default::default()
                                };
                                self.state.documents.push(doc);
                                self.state.active_doc = self.state.documents.len() - 1;
                                self.state.status_msg = "SPICE import complete".into();
                                self.state.dialogs.import.is_open = false;
                            }
                            Err(e) => {
                                self.state.status_msg = format!("SPICE import failed: {e}");
                                self.state.dialogs.import.status_msg =
                                    format!("Error: {e}");
                            }
                        }
                    }
                    Err(e) => {
                        self.state.status_msg = format!("Cannot read file: {e}");
                        self.state.dialogs.import.status_msg = format!("Error: {e}");
                    }
                }
            }

            // ── Plugins ──
            PluginsRefresh => {
                self.state.plugin_refresh_requested = true;
            }
            PluginCommand { .. } | PluginMutation { .. } => {
                // Plugin system not yet implemented
            }
        }
    }
}

// ════════════════════════════════════════════════════════════
// Undo / Redo
// ════════════════════════════════════════════════════════════

impl App {
    fn push_undo(&mut self, entry: UndoEntry) {
        let doc = self.state.active_document_mut();
        doc.redo_history.clear();
        if doc.undo_history.len() >= MAX_UNDO_HISTORY {
            doc.undo_history.pop_front();
        }
        doc.undo_history.push_back(entry);
        doc.dirty = true;
    }

    fn push_undo_snapshot(&mut self) {
        let sch = self.state.active_document().schematic.clone();
        self.push_undo(UndoEntry::Snapshot(sch));
    }

    fn handle_undo(&mut self) {
        let entry = self.state.active_document_mut().undo_history.pop_back();
        let Some(entry) = entry else { return };
        match entry {
            UndoEntry::Inverse(inv_cmd) => {
                let redo_entry = UndoEntry::Inverse(invert_command(&inv_cmd));
                // Execute the inverse without pushing undo
                self.exec_invertible(&inv_cmd);
                let doc = self.state.active_document_mut();
                doc.redo_history.push_back(redo_entry);
                doc.connectivity = None;
            }
            UndoEntry::Snapshot(old_schematic) => {
                let doc = self.state.active_document_mut();
                let current = std::mem::replace(&mut doc.schematic, old_schematic);
                doc.redo_history.push_back(UndoEntry::Snapshot(current));
                doc.connectivity = None;
            }
        }
    }

    fn handle_redo(&mut self) {
        let entry = self.state.active_document_mut().redo_history.pop_back();
        let Some(entry) = entry else { return };
        match entry {
            UndoEntry::Inverse(cmd) => {
                let undo_entry = UndoEntry::Inverse(invert_command(&cmd));
                self.exec_invertible(&cmd);
                let doc = self.state.active_document_mut();
                doc.undo_history.push_back(undo_entry);
                doc.connectivity = None;
            }
            UndoEntry::Snapshot(old_schematic) => {
                let doc = self.state.active_document_mut();
                let current = std::mem::replace(&mut doc.schematic, old_schematic);
                doc.undo_history.push_back(UndoEntry::Snapshot(current));
                doc.connectivity = None;
            }
        }
    }

    /// Execute an invertible command directly (used by undo/redo, no undo push).
    fn exec_invertible(&mut self, cmd: &Command) {
        use Command::*;
        match cmd {
            MoveInstance { idx, dx, dy } => {
                let doc = self.state.active_document_mut();
                if *idx < doc.schematic.instances.len() {
                    doc.schematic.instances.x[*idx] += dx;
                    doc.schematic.instances.y[*idx] += dy;
                }
            }
            MoveWire { idx, dx, dy } => {
                let doc = self.state.active_document_mut();
                if *idx < doc.schematic.wires.len() {
                    doc.schematic.wires.x0[*idx] += dx;
                    doc.schematic.wires.y0[*idx] += dy;
                    doc.schematic.wires.x1[*idx] += dx;
                    doc.schematic.wires.y1[*idx] += dy;
                }
            }
            MoveSelected { dx, dy } => self.move_selected(*dx, *dy),
            NudgeUp => {
                let s = self.state.tool.snap_size as i32;
                self.move_selected(0, -s);
            }
            NudgeDown => {
                let s = self.state.tool.snap_size as i32;
                self.move_selected(0, s);
            }
            NudgeLeft => {
                let s = self.state.tool.snap_size as i32;
                self.move_selected(-s, 0);
            }
            NudgeRight => {
                let s = self.state.tool.snap_size as i32;
                self.move_selected(s, 0);
            }
            RotateCw => self.rotate_selected(true),
            RotateCcw => self.rotate_selected(false),
            FlipHorizontal => self.flip_selected(true),
            FlipVertical => self.flip_selected(false),
            _ => {}
        }
    }

    fn invalidate_connectivity(&mut self) {
        self.state.active_document_mut().connectivity = None;
    }
}

// ════════════════════════════════════════════════════════════
// Movement & Transform helpers
// ════════════════════════════════════════════════════════════

impl App {
    fn move_selected(&mut self, dx: i32, dy: i32) {
        let doc = self.state.active_document_mut();
        let indices: Vec<usize> = doc.selection.instances.iter().copied().collect();
        for idx in indices {
            doc.schematic.instances.x[idx] += dx;
            doc.schematic.instances.y[idx] += dy;
        }
        let indices: Vec<usize> = doc.selection.wires.iter().copied().collect();
        for idx in indices {
            doc.schematic.wires.x0[idx] += dx;
            doc.schematic.wires.y0[idx] += dy;
            doc.schematic.wires.x1[idx] += dx;
            doc.schematic.wires.y1[idx] += dy;
        }
        let indices: Vec<usize> = doc.selection.lines.iter().copied().collect();
        for idx in indices {
            doc.schematic.lines[idx].x0 += dx;
            doc.schematic.lines[idx].y0 += dy;
            doc.schematic.lines[idx].x1 += dx;
            doc.schematic.lines[idx].y1 += dy;
        }
        let indices: Vec<usize> = doc.selection.rects.iter().copied().collect();
        for idx in indices {
            doc.schematic.rects[idx].x += dx;
            doc.schematic.rects[idx].y += dy;
        }
        let indices: Vec<usize> = doc.selection.circles.iter().copied().collect();
        for idx in indices {
            doc.schematic.circles[idx].cx += dx;
            doc.schematic.circles[idx].cy += dy;
        }
        let indices: Vec<usize> = doc.selection.arcs.iter().copied().collect();
        for idx in indices {
            doc.schematic.arcs[idx].cx += dx;
            doc.schematic.arcs[idx].cy += dy;
        }
        let indices: Vec<usize> = doc.selection.texts.iter().copied().collect();
        for idx in indices {
            doc.schematic.texts[idx].x += dx;
            doc.schematic.texts[idx].y += dy;
        }
        let indices: Vec<usize> = doc.selection.polygons.iter().copied().collect();
        for idx in indices {
            for pt in &mut doc.schematic.polygons[idx].points {
                pt[0] += dx;
                pt[1] += dy;
            }
        }
    }

    fn rotate_selected(&mut self, clockwise: bool) {
        let doc = self.state.active_document_mut();
        let indices: Vec<usize> = doc.selection.instances.iter().copied().collect();
        for idx in indices {
            let flags = doc.schematic.instances.flags[idx];
            let rot = if clockwise {
                (flags.rotation() + 1) & 0x03
            } else {
                (flags.rotation() + 3) & 0x03
            };
            doc.schematic.instances.flags[idx] =
                InstanceFlags::new(rot, flags.flip(), flags.bus());
        }
    }

    fn flip_selected(&mut self, horizontal: bool) {
        let doc = self.state.active_document_mut();
        let indices: Vec<usize> = doc.selection.instances.iter().copied().collect();
        for idx in indices {
            let flags = doc.schematic.instances.flags[idx];
            if horizontal {
                doc.schematic.instances.flags[idx] =
                    InstanceFlags::new(flags.rotation(), !flags.flip(), flags.bus());
            } else {
                // Vertical flip = flip + rotate 180
                let rot = (flags.rotation() + 2) & 0x03;
                doc.schematic.instances.flags[idx] =
                    InstanceFlags::new(rot, !flags.flip(), flags.bus());
            }
        }
    }

    fn align_selected_to_grid(&mut self) {
        let grid = self.state.tool.snap_size as i32;
        if grid <= 0 {
            return;
        }
        let doc = self.state.active_document_mut();
        let indices: Vec<usize> = doc.selection.instances.iter().copied().collect();
        for idx in indices {
            doc.schematic.instances.x[idx] = snap(doc.schematic.instances.x[idx], grid);
            doc.schematic.instances.y[idx] = snap(doc.schematic.instances.y[idx], grid);
        }
        let indices: Vec<usize> = doc.selection.wires.iter().copied().collect();
        for idx in indices {
            doc.schematic.wires.x0[idx] = snap(doc.schematic.wires.x0[idx], grid);
            doc.schematic.wires.y0[idx] = snap(doc.schematic.wires.y0[idx], grid);
            doc.schematic.wires.x1[idx] = snap(doc.schematic.wires.x1[idx], grid);
            doc.schematic.wires.y1[idx] = snap(doc.schematic.wires.y1[idx], grid);
        }
        let indices: Vec<usize> = doc.selection.lines.iter().copied().collect();
        for idx in indices {
            doc.schematic.lines[idx].x0 = snap(doc.schematic.lines[idx].x0, grid);
            doc.schematic.lines[idx].y0 = snap(doc.schematic.lines[idx].y0, grid);
            doc.schematic.lines[idx].x1 = snap(doc.schematic.lines[idx].x1, grid);
            doc.schematic.lines[idx].y1 = snap(doc.schematic.lines[idx].y1, grid);
        }
        let indices: Vec<usize> = doc.selection.rects.iter().copied().collect();
        for idx in indices {
            doc.schematic.rects[idx].x = snap(doc.schematic.rects[idx].x, grid);
            doc.schematic.rects[idx].y = snap(doc.schematic.rects[idx].y, grid);
        }
        let indices: Vec<usize> = doc.selection.circles.iter().copied().collect();
        for idx in indices {
            doc.schematic.circles[idx].cx = snap(doc.schematic.circles[idx].cx, grid);
            doc.schematic.circles[idx].cy = snap(doc.schematic.circles[idx].cy, grid);
        }
        let indices: Vec<usize> = doc.selection.arcs.iter().copied().collect();
        for idx in indices {
            doc.schematic.arcs[idx].cx = snap(doc.schematic.arcs[idx].cx, grid);
            doc.schematic.arcs[idx].cy = snap(doc.schematic.arcs[idx].cy, grid);
        }
        let indices: Vec<usize> = doc.selection.texts.iter().copied().collect();
        for idx in indices {
            doc.schematic.texts[idx].x = snap(doc.schematic.texts[idx].x, grid);
            doc.schematic.texts[idx].y = snap(doc.schematic.texts[idx].y, grid);
        }
        let indices: Vec<usize> = doc.selection.polygons.iter().copied().collect();
        for idx in indices {
            for pt in &mut doc.schematic.polygons[idx].points {
                pt[0] = snap(pt[0], grid);
                pt[1] = snap(pt[1], grid);
            }
        }
    }
}

// ════════════════════════════════════════════════════════════
// Clipboard
// ════════════════════════════════════════════════════════════

impl App {
    fn copy_to_clipboard(&mut self) {
        let doc_idx = self.state.active_doc;
        let doc = &self.state.documents[doc_idx];
        let mut clip = Clipboard::default();

        for &idx in &doc.selection.instances {
            clip.instances.push(extract_instance(&doc.schematic.instances, idx));
        }
        for &idx in &doc.selection.wires {
            clip.wires.push(extract_wire(&doc.schematic.wires, idx));
        }
        for &idx in &doc.selection.lines {
            clip.lines.push(doc.schematic.lines[idx].clone());
        }
        for &idx in &doc.selection.rects {
            clip.rects.push(doc.schematic.rects[idx].clone());
        }
        for &idx in &doc.selection.circles {
            clip.circles.push(doc.schematic.circles[idx].clone());
        }
        for &idx in &doc.selection.arcs {
            clip.arcs.push(doc.schematic.arcs[idx].clone());
        }
        for &idx in &doc.selection.texts {
            clip.texts.push(doc.schematic.texts[idx].clone());
        }
        for &idx in &doc.selection.polygons {
            clip.polygons.push(doc.schematic.polygons[idx].clone());
        }

        self.state.clipboard = clip;
    }

    fn paste_from_clipboard(&mut self) {
        let offset = 20i32;
        let clip = self.state.clipboard.clone();
        let doc = self.state.active_document_mut();
        doc.selection.clear();

        let base = doc.schematic.instances.len();
        for mut inst in clip.instances {
            inst.x += offset;
            inst.y += offset;
            inst.prop_start = 0;
            inst.prop_count = 0;
            doc.schematic.instances.push(inst);
        }
        for i in base..doc.schematic.instances.len() {
            doc.selection.instances.insert(i);
        }

        let base = doc.schematic.wires.len();
        for mut wire in clip.wires {
            wire.x0 += offset;
            wire.y0 += offset;
            wire.x1 += offset;
            wire.y1 += offset;
            doc.schematic.wires.push(wire);
        }
        for i in base..doc.schematic.wires.len() {
            doc.selection.wires.insert(i);
        }

        let base = doc.schematic.lines.len();
        for mut line in clip.lines {
            line.x0 += offset;
            line.y0 += offset;
            line.x1 += offset;
            line.y1 += offset;
            doc.schematic.lines.push(line);
        }
        for i in base..doc.schematic.lines.len() {
            doc.selection.lines.insert(i);
        }

        let base = doc.schematic.rects.len();
        for mut r in clip.rects {
            r.x += offset;
            r.y += offset;
            doc.schematic.rects.push(r);
        }
        for i in base..doc.schematic.rects.len() {
            doc.selection.rects.insert(i);
        }

        let base = doc.schematic.circles.len();
        for mut c in clip.circles {
            c.cx += offset;
            c.cy += offset;
            doc.schematic.circles.push(c);
        }
        for i in base..doc.schematic.circles.len() {
            doc.selection.circles.insert(i);
        }

        let base = doc.schematic.arcs.len();
        for mut a in clip.arcs {
            a.cx += offset;
            a.cy += offset;
            doc.schematic.arcs.push(a);
        }
        for i in base..doc.schematic.arcs.len() {
            doc.selection.arcs.insert(i);
        }

        let base = doc.schematic.texts.len();
        for mut t in clip.texts {
            t.x += offset;
            t.y += offset;
            doc.schematic.texts.push(t);
        }
        for i in base..doc.schematic.texts.len() {
            doc.selection.texts.insert(i);
        }

        let base = doc.schematic.polygons.len();
        for mut p in clip.polygons {
            for pt in &mut p.points {
                pt[0] += offset;
                pt[1] += offset;
            }
            doc.schematic.polygons.push(p);
        }
        for i in base..doc.schematic.polygons.len() {
            doc.selection.polygons.insert(i);
        }
    }
}

// ════════════════════════════════════════════════════════════
// Delete / Duplicate
// ════════════════════════════════════════════════════════════

impl App {
    fn exec_delete_selected(&mut self) {
        let doc = self.state.active_document_mut();

        // Remove in descending index order so earlier indices stay valid
        remove_selected_soa(&mut doc.schematic.instances, &doc.selection.instances);
        remove_selected_soa(&mut doc.schematic.wires, &doc.selection.wires);
        remove_selected_aos(&mut doc.schematic.lines, &doc.selection.lines);
        remove_selected_aos(&mut doc.schematic.rects, &doc.selection.rects);
        remove_selected_aos(&mut doc.schematic.circles, &doc.selection.circles);
        remove_selected_aos(&mut doc.schematic.arcs, &doc.selection.arcs);
        remove_selected_aos(&mut doc.schematic.texts, &doc.selection.texts);
        remove_selected_aos(&mut doc.schematic.polygons, &doc.selection.polygons);

        doc.selection.clear();
    }

    fn exec_duplicate_selected(&mut self) {
        let offset = 20i32;
        let doc_idx = self.state.active_doc;

        // Collect items to duplicate
        let inst_indices: Vec<usize> = self.state.documents[doc_idx]
            .selection
            .instances
            .iter()
            .copied()
            .collect();
        let wire_indices: Vec<usize> = self.state.documents[doc_idx]
            .selection
            .wires
            .iter()
            .copied()
            .collect();
        let line_indices: Vec<usize> = self.state.documents[doc_idx]
            .selection
            .lines
            .iter()
            .copied()
            .collect();
        let rect_indices: Vec<usize> = self.state.documents[doc_idx]
            .selection
            .rects
            .iter()
            .copied()
            .collect();
        let circle_indices: Vec<usize> = self.state.documents[doc_idx]
            .selection
            .circles
            .iter()
            .copied()
            .collect();
        let arc_indices: Vec<usize> = self.state.documents[doc_idx]
            .selection
            .arcs
            .iter()
            .copied()
            .collect();
        let text_indices: Vec<usize> = self.state.documents[doc_idx]
            .selection
            .texts
            .iter()
            .copied()
            .collect();
        let polygon_indices: Vec<usize> = self.state.documents[doc_idx]
            .selection
            .polygons
            .iter()
            .copied()
            .collect();

        let doc = &mut self.state.documents[doc_idx];
        doc.selection.clear();

        for idx in inst_indices {
            let mut inst = extract_instance(&doc.schematic.instances, idx);
            inst.x += offset;
            inst.y += offset;
            inst.prop_start = 0;
            inst.prop_count = 0;
            let new_idx = doc.schematic.instances.len();
            doc.schematic.instances.push(inst);
            doc.selection.instances.insert(new_idx);
        }
        for idx in wire_indices {
            let mut wire = extract_wire(&doc.schematic.wires, idx);
            wire.x0 += offset;
            wire.y0 += offset;
            wire.x1 += offset;
            wire.y1 += offset;
            let new_idx = doc.schematic.wires.len();
            doc.schematic.wires.push(wire);
            doc.selection.wires.insert(new_idx);
        }
        for idx in line_indices {
            let mut line = doc.schematic.lines[idx].clone();
            line.x0 += offset;
            line.y0 += offset;
            line.x1 += offset;
            line.y1 += offset;
            let new_idx = doc.schematic.lines.len();
            doc.schematic.lines.push(line);
            doc.selection.lines.insert(new_idx);
        }
        for idx in rect_indices {
            let mut r = doc.schematic.rects[idx].clone();
            r.x += offset;
            r.y += offset;
            let new_idx = doc.schematic.rects.len();
            doc.schematic.rects.push(r);
            doc.selection.rects.insert(new_idx);
        }
        for idx in circle_indices {
            let mut c = doc.schematic.circles[idx].clone();
            c.cx += offset;
            c.cy += offset;
            let new_idx = doc.schematic.circles.len();
            doc.schematic.circles.push(c);
            doc.selection.circles.insert(new_idx);
        }
        for idx in arc_indices {
            let mut a = doc.schematic.arcs[idx].clone();
            a.cx += offset;
            a.cy += offset;
            let new_idx = doc.schematic.arcs.len();
            doc.schematic.arcs.push(a);
            doc.selection.arcs.insert(new_idx);
        }
        for idx in text_indices {
            let mut t = doc.schematic.texts[idx].clone();
            t.x += offset;
            t.y += offset;
            let new_idx = doc.schematic.texts.len();
            doc.schematic.texts.push(t);
            doc.selection.texts.insert(new_idx);
        }
        for idx in polygon_indices {
            let mut p = doc.schematic.polygons[idx].clone();
            for pt in &mut p.points {
                pt[0] += offset;
                pt[1] += offset;
            }
            let new_idx = doc.schematic.polygons.len();
            doc.schematic.polygons.push(p);
            doc.selection.polygons.insert(new_idx);
        }
    }
}

// ════════════════════════════════════════════════════════════
// File handlers
// ════════════════════════════════════════════════════════════

impl App {
    fn handle_file_save(&mut self) {
        let doc_idx = self.state.active_doc;
        let path = match &self.state.documents[doc_idx].origin {
            Origin::File(p) => Some(p.clone()),
            _ => None,
        };
        if let Some(path) = path {
            if let Some(content) =
                schemify_io::writer::write_chn(
                    &self.state.documents[doc_idx].schematic,
                    &self.state.interner,
                )
            {
                if std::fs::write(&path, &content).is_ok() {
                    self.state.documents[doc_idx].dirty = false;
                    self.state.status_msg = format!("Saved {}", path.display());
                } else {
                    self.state.status_msg = format!("Failed to write {}", path.display());
                }
            }
        }
        // If no file origin, display crate should show save-as dialog
    }

    fn handle_reload(&mut self) {
        let doc_idx = self.state.active_doc;
        let path = match &self.state.documents[doc_idx].origin {
            Origin::File(p) => Some(p.clone()),
            _ => None,
        };
        if let Some(path) = path {
            if let Ok(content) = std::fs::read_to_string(&path) {
                let schematic =
                    schemify_io::reader::read_chn(&content, &mut self.state.interner);
                let doc = &mut self.state.documents[doc_idx];
                doc.schematic = schematic;
                doc.dirty = false;
                doc.undo_history.clear();
                doc.redo_history.clear();
                doc.connectivity = None;
                doc.selection.clear();
                self.state.status_msg = format!("Reloaded {}", path.display());
            }
        }
    }

    fn handle_zoom_fit(&mut self) {
        let bounds = compute_bounds(&self.state.active_document().schematic);
        if let Some((min_x, min_y, max_x, max_y)) = bounds {
            let [cw, ch] = self.state.view.canvas_size;
            let w = (max_x - min_x) as f32;
            let h = (max_y - min_y) as f32;
            if w > 0.0 && h > 0.0 {
                let margin = 1.1;
                let zoom = (cw / (w * margin)).min(ch / (h * margin));
                let zoom = zoom.clamp(Viewport::MIN_ZOOM, Viewport::MAX_ZOOM);
                let cx = (min_x + max_x) as f32 / 2.0;
                let cy = (min_y + max_y) as f32 / 2.0;
                let doc = self.state.active_document_mut();
                doc.viewport.zoom = zoom;
                doc.viewport.pan = [cw / 2.0 - cx * zoom, ch / 2.0 - cy * zoom];
            }
        }
    }
}

// ════════════════════════════════════════════════════════════
// Free functions
// ════════════════════════════════════════════════════════════

fn invert_command(cmd: &Command) -> Command {
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
        MoveSelected { dx, dy } => MoveSelected {
            dx: -*dx,
            dy: -*dy,
        },
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

fn extract_instance(v: &InstanceVec, i: usize) -> Instance {
    Instance {
        name: v.name[i],
        symbol: v.symbol[i],
        spice_line: v.spice_line[i],
        x: v.x[i],
        y: v.y[i],
        kind: v.kind[i],
        flags: v.flags[i],
        prop_start: v.prop_start[i],
        prop_count: v.prop_count[i],
        name_offset: v.name_offset[i],
        param_offset: v.param_offset[i],
    }
}

fn extract_wire(v: &WireVec, i: usize) -> Wire {
    Wire {
        net_name: v.net_name[i],
        x0: v.x0[i],
        y0: v.y0[i],
        x1: v.x1[i],
        y1: v.y1[i],
        color: v.color[i],
        thickness: v.thickness[i],
        bus: v.bus[i],
    }
}

fn set_instance_prop(
    sch: &mut Schematic,
    idx: usize,
    key: lasso::Spur,
    value: lasso::Spur,
) {
    if idx >= sch.instances.len() {
        return;
    }
    let start = sch.instances.prop_start[idx] as usize;
    let count = sch.instances.prop_count[idx] as usize;

    // Update existing property if key matches
    for i in start..start + count {
        if i < sch.properties.len() && sch.properties[i].key == key {
            sch.properties[i].value = value;
            return;
        }
    }

    // Key not found — relocate props to end of pool and append new one
    let new_start = sch.properties.len();
    for i in start..start + count {
        if i < sch.properties.len() {
            sch.properties.push(sch.properties[i].clone());
        }
    }
    sch.properties.push(schemify_core::schematic::Property { key, value });
    sch.instances.prop_start[idx] = new_start as u32;
    sch.instances.prop_count[idx] = (count + 1) as u16;
}

/// Remove selected indices from an SoA vec (InstanceVec / WireVec).
/// Uses `remove()` in descending order to keep indices stable.
fn remove_selected_soa<T: SoaRemovable>(vec: &mut T, selected: &std::collections::HashSet<usize>) {
    let mut indices: Vec<usize> = selected.iter().copied().collect();
    indices.sort_unstable_by(|a, b| b.cmp(a));
    for idx in indices {
        if idx < vec.soa_len() {
            vec.soa_remove(idx);
        }
    }
}

fn remove_selected_aos<T>(vec: &mut Vec<T>, selected: &std::collections::HashSet<usize>) {
    let mut indices: Vec<usize> = selected.iter().copied().collect();
    indices.sort_unstable_by(|a, b| b.cmp(a));
    for idx in indices {
        if idx < vec.len() {
            vec.remove(idx);
        }
    }
}

/// Invert a selection set: toggle every index in [0..total).
fn invert_set(set: &mut std::collections::HashSet<usize>, total: usize) {
    let old: std::collections::HashSet<usize> = set.clone();
    set.clear();
    for i in 0..total {
        if !old.contains(&i) {
            set.insert(i);
        }
    }
}

fn snap(val: i32, grid: i32) -> i32 {
    if grid <= 0 {
        return val;
    }
    ((val as f64 / grid as f64).round() as i32) * grid
}

fn compute_bounds(sch: &Schematic) -> Option<(i32, i32, i32, i32)> {
    let mut min_x = i32::MAX;
    let mut min_y = i32::MAX;
    let mut max_x = i32::MIN;
    let mut max_y = i32::MIN;
    let mut any = false;

    for i in 0..sch.instances.len() {
        any = true;
        min_x = min_x.min(sch.instances.x[i]);
        min_y = min_y.min(sch.instances.y[i]);
        max_x = max_x.max(sch.instances.x[i]);
        max_y = max_y.max(sch.instances.y[i]);
    }
    for i in 0..sch.wires.len() {
        any = true;
        min_x = min_x.min(sch.wires.x0[i]).min(sch.wires.x1[i]);
        min_y = min_y.min(sch.wires.y0[i]).min(sch.wires.y1[i]);
        max_x = max_x.max(sch.wires.x0[i]).max(sch.wires.x1[i]);
        max_y = max_y.max(sch.wires.y0[i]).max(sch.wires.y1[i]);
    }
    for line in &sch.lines {
        any = true;
        min_x = min_x.min(line.x0).min(line.x1);
        min_y = min_y.min(line.y0).min(line.y1);
        max_x = max_x.max(line.x0).max(line.x1);
        max_y = max_y.max(line.y0).max(line.y1);
    }
    for r in &sch.rects {
        any = true;
        min_x = min_x.min(r.x);
        min_y = min_y.min(r.y);
        max_x = max_x.max(r.x + r.width);
        max_y = max_y.max(r.y + r.height);
    }
    for c in &sch.circles {
        any = true;
        min_x = min_x.min(c.cx - c.radius);
        min_y = min_y.min(c.cy - c.radius);
        max_x = max_x.max(c.cx + c.radius);
        max_y = max_y.max(c.cy + c.radius);
    }
    for a in &sch.arcs {
        any = true;
        min_x = min_x.min(a.cx - a.radius);
        min_y = min_y.min(a.cy - a.radius);
        max_x = max_x.max(a.cx + a.radius);
        max_y = max_y.max(a.cy + a.radius);
    }
    for t in &sch.texts {
        any = true;
        min_x = min_x.min(t.x);
        min_y = min_y.min(t.y);
        max_x = max_x.max(t.x);
        max_y = max_y.max(t.y);
    }
    for poly in &sch.polygons {
        for pt in &poly.points {
            any = true;
            min_x = min_x.min(pt[0]);
            min_y = min_y.min(pt[1]);
            max_x = max_x.max(pt[0]);
            max_y = max_y.max(pt[1]);
        }
    }

    if any {
        Some((min_x, min_y, max_x, max_y))
    } else {
        None
    }
}

// ════════════════════════════════════════════════════════════
// Trait for SoA remove abstraction
// ════════════════════════════════════════════════════════════

trait SoaRemovable {
    fn soa_len(&self) -> usize;
    fn soa_remove(&mut self, idx: usize);
}

impl SoaRemovable for InstanceVec {
    fn soa_len(&self) -> usize {
        self.len()
    }
    fn soa_remove(&mut self, idx: usize) {
        self.remove(idx);
    }
}

impl SoaRemovable for WireVec {
    fn soa_len(&self) -> usize {
        self.len()
    }
    fn soa_remove(&mut self, idx: usize) {
        self.remove(idx);
    }
}
