//! The dispatch router: undo policy classification, the `#[must_use]`
//! [`DispatchResult`], and the single exhaustive `exec` match. Mutating
//! helpers live in `edit`; shell-facing helpers (tabs, wave, optimizer)
//! in `view`.


use rustc_hash::FxHashSet;

use crate::schemify::{
    self as prim, Arc, Bus, BusRipper, Circle, Color, Command, DeviceKind, Instance,
    InstanceFlags, Line, Polygon, Property, Rect, SpiceBackend, StimulusLang, Text, Tool, Wire,
};
use crate::sim as ir;
use crate::wave;

use super::*;

pub mod edit;
pub mod view;


/// Outcome of a dispatch. `Unhandled` carries commands core deliberately
/// does not implement (SPICE import, marketplace) back to the shell that
/// owns them — `#[must_use]` makes silently dropping one a compile warning.
#[must_use = "Unhandled commands must be routed or surfaced — call or_status() or match"]
#[derive(Debug)]
pub enum DispatchResult {
    Done,
    /// Core has no implementation; the calling shell must handle or surface it.
    Unhandled(Command),
}

impl DispatchResult {
    /// Leaf-site consumption: surface an unhandled command in the status bar.
    pub fn or_status(self, app: &mut App) {
        if let DispatchResult::Unhandled(cmd) = self {
            app.state.status_msg = format!("Command not available here: {cmd:?}");
        }
    }
}

/// Internal execution outcome (see [`App::dispatch`] for the undo wrapper).
enum Exec {
    Done,
    /// Nothing changed (invalid index, empty clipboard, unknown name):
    /// dispatch drops the pre-cloned snapshot, keeps undo/redo untouched.
    NoOp,
    Unhandled(Command),
}

/// Undo/generation policy for a command, declared UP FRONT and exhaustively:
/// a new [`Command`] variant does not compile until it is classified here.
pub(crate) enum UndoPolicy {
    /// No undo, no generation bump: views, files, selection, dialogs,
    /// sim/plugin/wave/optimizer control.
    Ephemeral,
    /// Full pre-mutation snapshot; `touch` = affects connectivity.
    Snapshot { touch: bool },
    /// Cheap precomputed inverse command.
    Inverse(Command),
    /// The arm manages its own undo (Undo/Redo themselves, coalescing
    /// nudges, drag-accumulating MoveSelected, SetTool's polygon commit).
    Custom,
}

pub(crate) fn undo_policy(cmd: &Command) -> UndoPolicy {
    use Command::*;
    match cmd {
        // ── Custom flows ──
        Undo | Redo | SetTool(_) | MoveSelected { .. } | NudgeUp | NudgeDown | NudgeLeft
        | NudgeRight => UndoPolicy::Custom,

        // ── Invertible ──
        MoveInstance { idx, dx, dy } => UndoPolicy::Inverse(MoveInstance {
            idx: *idx,
            dx: -dx,
            dy: -dy,
        }),
        MoveWire { idx, dx, dy } => UndoPolicy::Inverse(MoveWire {
            idx: *idx,
            dx: -dx,
            dy: -dy,
        }),
        RotateCw => UndoPolicy::Inverse(RotateCcw),
        RotateCcw => UndoPolicy::Inverse(RotateCw),
        FlipHorizontal => UndoPolicy::Inverse(FlipHorizontal),
        FlipVertical => UndoPolicy::Inverse(FlipVertical),

        // ── Snapshot, connectivity-affecting ──
        Cut | Paste | PlaceDevice { .. } | AddWire { .. } | AlignToGrid | DeleteSelected
        | DeleteInstance(_) | DeleteWire(_) | DuplicateSelected | AddBus { .. } | DeleteBus(_)
        | SetBusWidth { .. } | RenameBus { .. } | AddBusRipper { .. } | DeleteBusRipper(_)
        | SplitWire { .. } | AlignLeft | AlignRight | AlignTop | AlignBottom | AlignCenterH
        | AlignCenterV | DistributeH | DistributeV => UndoPolicy::Snapshot { touch: true },

        // ── Snapshot, no connectivity impact (drawings, props, sim config) ──
        AddLine { .. } | AddRect { .. } | AddCircle { .. } | AddArc { .. } | AddText { .. }
        | AddPolygon { .. } | SetInstanceProp { .. } | RenameInstance { .. } | SetSpiceCode(_)
        | SetDocumentation(_) | SetWireColor { .. } | SetStimulusLang(_) | SetSimBackend(_)
        | SetSimCorner(_) => UndoPolicy::Snapshot { touch: false },

        // ── Ephemeral (listed explicitly — NO wildcard) ──
        ZoomIn | ZoomOut | ZoomFit | ZoomReset | ToggleFullscreen | ToggleColorScheme
        | ToggleGrid | FileNew | FileOpen | FileSave | FileSaveAs | NewTab | CloseTab(_)
        | CloseActiveTab | SwitchTab(_) | ReloadFromDisk | SelectAll | SelectNone
        | InvertSelection | Copy | OpenFindDialog | OpenPropsDialog | OpenSettings
        | OpenSpiceCodeEditor | OpenNewPrimDialog | OpenMarketplace | OpenImportDialog
        | OpenLibraryBrowser | OpenFileExplorer | RunSim | ExportNetlist
        | GenerateSymbolFromSchematic | ExportSpice { .. } | ImportSpice { .. }
        | MarketplaceFetch | MarketplaceInstall { .. } | MarketplaceUninstall { .. }
        | PluginsRefresh | PluginCommand { .. } | ReloadProjectConfig | WaveOpen { .. }
        | WaveReload | WaveAddTrace { .. } | WaveRemoveTrace(_) | WaveClearTraces
        | WaveSetTraceStyle { .. } | WaveAddPane | WaveRemovePane(_) | WaveSetActivePane(_)
        | WaveSetCursor { .. } | WaveSetXLog(_) | WaveSetXRange { .. } | WaveSetYRange { .. }
        | WaveZoomFit | WaveExportCsv { .. } | OptimizerNew { .. } | OptimizerClose { .. }
        | OptimizerSetWindowOpen { .. } | OptimizerAddParam { .. }
        | OptimizerRemoveParam { .. } | OptimizerAddObjective { .. }
        | OptimizerRemoveObjective { .. } | OptimizerSetAlgorithm { .. }
        | OptimizerReport { .. } | OptimizerReset { .. } => UndoPolicy::Ephemeral,
    }
}


impl App {
    /// Single entry point for all mutations. Classifies the command's
    /// [`UndoPolicy`] first, then executes: undo bookkeeping and
    /// connectivity invalidation happen HERE, uniformly — exec arms only
    /// mutate.
    pub fn dispatch(&mut self, cmd: Command) -> DispatchResult {
        match undo_policy(&cmd) {
            // Arm manages itself (views, dialogs, wave/optimizer, undo/redo,
            // drag accumulation, nudge coalescing).
            UndoPolicy::Ephemeral | UndoPolicy::Custom => match self.exec(cmd) {
                Exec::Unhandled(c) => return DispatchResult::Unhandled(c),
                Exec::Done | Exec::NoOp => {}
            },
            UndoPolicy::Inverse(inv) => {
                self.push_undo(UndoEntry::Inverse(inv));
                let _ = self.exec(cmd);
                self.touch();
            }
            UndoPolicy::Snapshot { touch } => {
                // Clone-before / push-after: a no-op command costs one clone
                // but never leaves a bogus undo entry or clears redo.
                let before = Box::new(self.state.active_document().schematic.clone());
                if !matches!(self.exec(cmd), Exec::NoOp) {
                    self.push_undo(UndoEntry::Snapshot(before));
                    if touch {
                        self.touch();
                    }
                }
            }
        }
        DispatchResult::Done
    }

    /// Execute a command. NO undo/touch bookkeeping here (dispatch owns
    /// that) — except Custom-policy arms, which manage their own.
    fn exec(&mut self, cmd: Command) -> Exec {
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
            ToggleFullscreen => self.state.view.fullscreen = !self.state.view.fullscreen,
            ToggleColorScheme => self.state.view.dark_mode = !self.state.view.dark_mode,
            ToggleGrid => self.state.view.show_grid = !self.state.view.show_grid,

            // ── File (immediate, no undo) ──
            FileNew | NewTab => self.adopt_document(Document::default()),
            FileOpen => {
                // Display crate shows a file dialog, then calls app.open_file(path).
            }
            FileSave => self.handle_file_save(),
            FileSaveAs => {
                // Display crate shows a save dialog, then calls app.save_to_path(path).
            }
            CloseTab(idx) => self.close_tab(idx),
            CloseActiveTab => self.close_tab(self.state.active_doc),
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
                let total = sch.instances.len()
                    + sch.wires.len()
                    + sch.buses.len()
                    + sch.lines.len()
                    + sch.rects.len()
                    + sch.circles.len()
                    + sch.arcs.len()
                    + sch.texts.len()
                    + sch.polygons.len();
                let objs = &mut doc.selection.objs;
                objs.clear();
                objs.reserve(total);
                objs.extend((0..sch.instances.len() as u32).map(ObjectRef::Instance));
                objs.extend((0..sch.wires.len() as u32).map(ObjectRef::Wire));
                objs.extend((0..sch.buses.len() as u32).map(ObjectRef::Bus));
                objs.extend((0..sch.lines.len() as u32).map(ObjectRef::Line));
                objs.extend((0..sch.rects.len() as u32).map(ObjectRef::Rect));
                objs.extend((0..sch.circles.len() as u32).map(ObjectRef::Circle));
                objs.extend((0..sch.arcs.len() as u32).map(ObjectRef::Arc));
                objs.extend((0..sch.texts.len() as u32).map(ObjectRef::Text));
                objs.extend((0..sch.polygons.len() as u32).map(ObjectRef::Polygon));
            }
            SelectNone => self.state.active_document_mut().selection.clear(),
            InvertSelection => {
                let doc = self.state.active_document_mut();
                let old: FxHashSet<ObjectRef> = doc.selection.objs.iter().copied().collect();
                let sch = &doc.schematic;
                let mut objs = Vec::new();
                let mut add = |make: fn(u32) -> ObjectRef, len: usize| {
                    for i in 0..len as u32 {
                        let r = make(i);
                        if !old.contains(&r) {
                            objs.push(r);
                        }
                    }
                };
                add(ObjectRef::Instance, sch.instances.len());
                add(ObjectRef::Wire, sch.wires.len());
                add(ObjectRef::Bus, sch.buses.len());
                add(ObjectRef::Line, sch.lines.len());
                add(ObjectRef::Rect, sch.rects.len());
                add(ObjectRef::Circle, sch.circles.len());
                add(ObjectRef::Arc, sch.arcs.len());
                add(ObjectRef::Text, sch.texts.len());
                add(ObjectRef::Polygon, sch.polygons.len());
                doc.selection.objs = objs;
            }

            // ── Clipboard (immediate for copy, undoable for cut/paste) ──
            Copy => self.copy_to_clipboard(),
            Cut => {
                self.copy_to_clipboard();
                self.exec_delete_selected();
            }
            Paste => {
                if self.state.clipboard.is_empty() {
                    return Exec::NoOp;
                }
                self.paste_from_clipboard();
            }

            // ── Tool (immediate) ──
            SetTool(t) => {
                // Commit any in-progress polygon before switching.
                if self.state.tool.active == Tool::Polygon
                    && self.state.tool.draw.polygon_points.len() >= 3
                {
                    let pts = std::mem::take(&mut self.state.tool.draw.polygon_points);
                    self.push_undo_snapshot();
                    self.state
                        .active_document_mut()
                        .schematic
                        .polygons
                        .push(Polygon {
                            points: pts,
                            fill: Color::NONE,
                            stroke: Color::NONE,
                            thickness: 1,
                        });
                }
                self.state.tool.active = t;
                self.state.tool.wire_start = None;
                self.state.tool.placement = None;
                self.state.tool.draw = DrawState::default();
            }

            // ── Dialogs (immediate) ──
            OpenFindDialog => self.state.dialogs.find_open = true,
            OpenPropsDialog => self.state.dialogs.props_open = true,
            OpenSettings => self.state.dialogs.settings_open = true,
            OpenSpiceCodeEditor => {
                self.state.dialogs.spice_code_open = true;
                self.state.dialogs.spice_code_buf =
                    self.state.active_document().schematic.spice_body.clone();
            }
            OpenNewPrimDialog => self.state.dialogs.new_prim_open = true,
            OpenMarketplace => self.state.dialogs.marketplace_open = true,
            OpenImportDialog => self.state.dialogs.import_open = true,
            OpenLibraryBrowser => {
                self.state.dialogs.library_open = !self.state.dialogs.library_open;
            }
            OpenFileExplorer => self.state.dialogs.file_explorer_open = true,

            // ── Movement (invertible, push inverse) ──
            MoveInstance { idx, dx, dy } => {
                self.state
                    .active_document_mut()
                    .schematic
                    .translate_instance(idx, dx, dy);
            }
            MoveWire { idx, dx, dy } => {
                self.state
                    .active_document_mut()
                    .schematic
                    .translate_wire(idx, dx, dy);
            }
            MoveSelected { dx, dy } => {
                if self.state.canvas.move_active {
                    // During drag: accumulate, defer undo until release.
                    self.state.canvas.move_accum[0] += dx;
                    self.state.canvas.move_accum[1] += dy;
                } else {
                    self.push_undo(UndoEntry::Inverse(MoveSelected { dx: -dx, dy: -dy }));
                }
                self.move_selected(dx, dy);
                self.touch();
            }

            // ── Nudge (coalesced — merges consecutive nudges into one MoveSelected undo) ──
            NudgeUp | NudgeDown | NudgeLeft | NudgeRight => {
                let s = self.state.tool.snap_size as i32;
                let (dx, dy) = match &cmd {
                    NudgeUp => (0, -s),
                    NudgeDown => (0, s),
                    NudgeLeft => (-s, 0),
                    NudgeRight => (s, 0),
                    _ => unreachable!(),
                };

                // Coalesce: if the last undo entry is an inverse MoveSelected, merge deltas.
                let doc = self.state.active_document_mut();
                let merged = if let Some(UndoEntry::Inverse(MoveSelected {
                    dx: ref mut udx,
                    dy: ref mut udy,
                })) = doc.undo_history.back_mut()
                {
                    *udx -= dx;
                    *udy -= dy;
                    true
                } else {
                    false
                };
                if merged {
                    // Still clear redo on mutation.
                    doc.redo_history.clear();
                } else {
                    self.push_undo(UndoEntry::Inverse(MoveSelected { dx: -dx, dy: -dy }));
                }

                self.move_selected(dx, dy);
                self.touch();
            }

            // ── Transform (invertible) ──
            RotateCw => self.rotate_selected(true),
            RotateCcw => self.rotate_selected(false),
            FlipHorizontal => self.flip_selected(true),
            FlipVertical => self.flip_selected(false),

            // ── Align ──
            AlignToGrid => self.align_selected_to_grid(),

            // ── Deletion ──
            DeleteSelected => self.exec_delete_selected(),
            DeleteInstance(idx) => {
                if idx >= self.state.active_document().schematic.instances.len() {
                    return Exec::NoOp;
                }
                let doc = self.state.active_document_mut();
                doc.schematic.instances.remove(idx);
                doc.selection
                    .remove_deleted(ObjectRef::Instance(idx as u32));
            }
            DeleteWire(idx) => {
                if idx >= self.state.active_document().schematic.wires.len() {
                    return Exec::NoOp;
                }
                let doc = self.state.active_document_mut();
                doc.schematic.wires.remove(idx);
                doc.selection.remove_deleted(ObjectRef::Wire(idx as u32));
            }

            // ── Duplication ──
            DuplicateSelected => self.exec_duplicate_selected(),

            // ── Placement (snapshot) ──
            PlaceDevice {
                symbol_path,
                name,
                x,
                y,
                rotation,
                flip,
            } => {
                let sym = self.state.interner.get_or_intern(&symbol_path);
                let name_sym = self.state.interner.get_or_intern(&name);

                // Aliases ("res", "cap", …) have no prim entry of their own;
                // fall back to the kind-name table so live placement agrees
                // with the file loader.
                let entry = prim::find_by_name(&symbol_path);
                let kind = entry
                    .map(|p| p.kind)
                    .unwrap_or_else(|| DeviceKind::from_name(&symbol_path));

                // Intern all property keys/values up front (before borrowing
                // the document mutably).
                let mut init_props: Vec<Property> = Vec::new();
                if kind.is_power() {
                    let net_val = kind.injected_net().unwrap_or("0");
                    init_props.push(Property {
                        key: self.state.interner.get_or_intern("net"),
                        value: self.state.interner.get_or_intern(net_val),
                    });
                }
                if let Some(e) = entry {
                    for &(k, v) in &e.params {
                        init_props.push(Property {
                            key: self.state.interner.get_or_intern(k),
                            value: self.state.interner.get_or_intern(v),
                        });
                    }
                }

                let doc = self.state.active_document_mut();
                let prop_start = doc.schematic.properties.len() as u32;
                doc.schematic.properties.extend(init_props);
                let prop_count =
                    (doc.schematic.properties.len() as u32 - prop_start) as u16;

                doc.schematic.instances.push(Instance {
                    name: name_sym,
                    symbol: sym,
                    x,
                    y,
                    kind,
                    flags: InstanceFlags::new(rotation, flip),
                    prop_start,
                    prop_count,
                });
            }

            // ── Wiring ──
            AddWire { x0, y0, x1, y1 } => {
                self.state.active_document_mut().schematic.wires.push(Wire {
                    net_name: None,
                    x0,
                    y0,
                    x1,
                    y1,
                    color: Color::NONE,
                    thickness: 10,
                });
            }

            // ── Geometry (no touch: drawings don't affect connectivity) ──
            AddLine { x0, y0, x1, y1 } => {
                self.state.active_document_mut().schematic.lines.push(Line {
                    x0,
                    y0,
                    x1,
                    y1,
                    color: Color::NONE,
                    thickness: 1,
                });
            }
            AddRect { x, y, w, h } => {
                self.state.active_document_mut().schematic.rects.push(Rect {
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
                self.state
                    .active_document_mut()
                    .schematic
                    .circles
                    .push(Circle {
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
                self.state.active_document_mut().schematic.arcs.push(Arc {
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
                let sym = self.state.interner.get_or_intern(&content);
                self.state.active_document_mut().schematic.texts.push(Text {
                    x,
                    y,
                    content: sym,
                    font_size: 10.0,
                    color: Color::NONE,
                    rotation: 0,
                });
            }
            AddPolygon { points } => {
                if points.len() < 3 {
                    return Exec::NoOp;
                }
                self.state
                    .active_document_mut()
                    .schematic
                    .polygons
                    .push(Polygon {
                        points,
                        fill: Color::NONE,
                        stroke: Color::NONE,
                        thickness: 1,
                    });
            }

            // ── Properties (snapshot) ──
            SetInstanceProp { idx, key, value } => {
                let key_sym = self.state.interner.get_or_intern(&key);
                let value_sym = self.state.interner.get_or_intern(&value);
                self.state
                    .active_document_mut()
                    .schematic
                    .set_instance_prop(idx, key_sym, value_sym);
            }
            RenameInstance { idx, new_name } => {
                let sym = self.state.interner.get_or_intern(&new_name);
                let doc = self.state.active_document_mut();
                if idx >= doc.schematic.instances.len() {
                    return Exec::NoOp;
                }
                doc.schematic.instances.name[idx] = sym;
            }
            SetSpiceCode(code) => {
                self.state.active_document_mut().schematic.spice_body = code;
            }
            SetDocumentation(text) => {
                self.state.active_document_mut().schematic.documentation = text;
            }
            SetWireColor { idx, color } => {
                let doc = self.state.active_document_mut();
                if idx >= doc.schematic.wires.len() {
                    return Exec::NoOp;
                }
                doc.schematic.wires.color[idx] = color;
            }

            // ── Simulation ──
            ExportNetlist => {
                self.generate_netlist();
                self.state.status_msg = "Netlist generated".into();
            }
            RunSim => self.run_simulation(),
            SetStimulusLang(lang_str) => {
                let Some(lang) = StimulusLang::from_name(&lang_str) else {
                    self.state.status_msg = format!("Unknown stimulus language: {lang_str}");
                    return Exec::NoOp;
                };
                self.state.active_document_mut().schematic.stimulus_lang = lang;
                self.state.status_msg = format!("Stimulus language: {}", lang.as_str());
            }
            SetSimBackend(backend_str) => {
                let Some(be) = SpiceBackend::from_name(&backend_str) else {
                    self.state.status_msg = format!("Unknown sim backend: {backend_str}");
                    return Exec::NoOp;
                };
                self.state.active_document_mut().schematic.sim_backend = be;
                self.state.status_msg = format!("Sim backend: {}", be.as_str());
            }
            SetSimCorner(corner) => {
                if let Some(p) = &self.state.pdk {
                    if !corner.is_empty() && !p.corners.iter().any(|c| c == &corner) {
                        self.state.status_msg = format!(
                            "Unknown corner '{corner}' for PDK {} (known: {})",
                            p.name,
                            p.corners.join(", ")
                        );
                        return Exec::NoOp;
                    }
                }
                self.state.status_msg = if corner.is_empty() {
                    "Corner: PDK default".to_string()
                } else {
                    format!("Corner: {corner}")
                };
                self.state.active_document_mut().schematic.sim_corner = corner;
            }

            // ── Symbol generation ──
            GenerateSymbolFromSchematic => self.generate_symbol_from_schematic(),

            // ── Import: not core's job — the shell (MCP) owns it ──
            ImportSpice { path } => return Exec::Unhandled(ImportSpice { path }),

            // ── Bus commands ──
            AddBus {
                label,
                width,
                start_bit,
                x0,
                y0,
                x1,
                y1,
            } => {
                let label_sym = self.state.interner.get_or_intern(&label);
                self.state.active_document_mut().schematic.buses.push(Bus {
                    label: label_sym,
                    width,
                    start_bit,
                    x0,
                    y0,
                    x1,
                    y1,
                    color: Color::NONE,
                    thickness: 10,
                });
            }
            DeleteBus(idx) => {
                if idx >= self.state.active_document().schematic.buses.len() {
                    return Exec::NoOp;
                }
                let doc = self.state.active_document_mut();
                remove_bus(&mut doc.schematic, idx);
                doc.selection.remove_deleted(ObjectRef::Bus(idx as u32));
            }
            SetBusWidth { idx, width } => {
                let doc = self.state.active_document_mut();
                if idx >= doc.schematic.buses.len() {
                    return Exec::NoOp;
                }
                doc.schematic.buses.width[idx] = width;
            }
            RenameBus { idx, new_name } => {
                let sym = self.state.interner.get_or_intern(&new_name);
                let doc = self.state.active_document_mut();
                if idx >= doc.schematic.buses.len() {
                    return Exec::NoOp;
                }
                doc.schematic.buses.label[idx] = sym;
            }
            AddBusRipper {
                bus_idx,
                bit,
                x,
                y,
                direction,
            } => {
                self.state
                    .active_document_mut()
                    .schematic
                    .bus_rippers
                    .push(BusRipper {
                        bus_idx,
                        bit,
                        x,
                        y,
                        // Valid domain is 0-3; mask at the command boundary.
                        direction: direction & 0x03,
                        stub_len: 20,
                    });
            }
            DeleteBusRipper(idx) => {
                let doc = self.state.active_document_mut();
                if idx >= doc.schematic.bus_rippers.len() {
                    return Exec::NoOp;
                }
                doc.schematic.bus_rippers.remove(idx);
            }

            // ── Wire editing ──
            SplitWire { idx, x, y } => {
                if idx >= self.state.active_document().schematic.wires.len() {
                    return Exec::NoOp;
                }
                {
                    let doc = self.state.active_document_mut();
                    let w = &doc.schematic.wires;
                    let (wx0, wy0, wx1, wy1) = (w.x0[idx], w.y0[idx], w.x1[idx], w.y1[idx]);
                    let col = w.color[idx];
                    let th = w.thickness[idx];

                    // Clamp the split point onto an axis-aligned wire.
                    let (sx, sy) = if wy0 == wy1 {
                        (x.clamp(wx0.min(wx1), wx0.max(wx1)), wy0)
                    } else if wx0 == wx1 {
                        (wx0, y.clamp(wy0.min(wy1), wy0.max(wy1)))
                    } else {
                        (x, y)
                    };

                    doc.schematic.wires.x1[idx] = sx;
                    doc.schematic.wires.y1[idx] = sy;
                    doc.schematic.wires.push(Wire {
                        net_name: doc.schematic.wires.net_name[idx],
                        x0: sx,
                        y0: sy,
                        x1: wx1,
                        y1: wy1,
                        color: col,
                        thickness: th,
                    });
                }
            }

            // ── Alignment commands ──
            AlignLeft => self.align_selected(AlignAxis::X, AlignMode::Min),
            AlignRight => self.align_selected(AlignAxis::X, AlignMode::Max),
            AlignTop => self.align_selected(AlignAxis::Y, AlignMode::Min),
            AlignBottom => self.align_selected(AlignAxis::Y, AlignMode::Max),
            AlignCenterH => self.align_selected(AlignAxis::X, AlignMode::Center),
            AlignCenterV => self.align_selected(AlignAxis::Y, AlignMode::Center),
            DistributeH => self.distribute_selected(AlignAxis::X),
            DistributeV => self.distribute_selected(AlignAxis::Y),

            // ── Export ──
            ExportSpice { path } => {
                self.generate_netlist();
                let circuit = self.build_circuit_ir();
                let spice = ir::codegen::emit_spice(&circuit);
                self.state.status_msg = match std::fs::write(&path, &spice) {
                    Ok(()) => format!("SPICE exported to {path}"),
                    Err(e) => format!("Export failed: {e}"),
                };
            }

            // ── Plugins (display-side PluginHost drains these) ──
            PluginsRefresh => {
                self.state.plugin_refresh_requested = true;
                self.state.status_msg = "Refreshing plugins...".into();
            }
            PluginCommand { tag, payload } => {
                if self.state.pending_plugin_commands.len() < 64 {
                    self.state.pending_plugin_commands.push((tag, payload));
                }
            }
            ReloadProjectConfig => self.reload_project_config(),
            // Marketplace: not core's job — the shell (MCP) owns it.
            c @ (MarketplaceFetch | MarketplaceInstall { .. } | MarketplaceUninstall { .. }) => {
                return Exec::Unhandled(c);
            }

            // ── Waveform viewer ──
            WaveOpen { path } => self.handle_wave_open(&path),
            WaveReload => self.with_wave(|w| w.reload_files().map(|()| w.reeval_traces())),
            WaveAddTrace {
                expr,
                file,
                block,
                pane,
            } => self.with_wave(|w| w.add_trace(&expr, file, block, pane).map(|_| ())),
            WaveRemoveTrace(idx) => self.with_wave(|w| w.remove_trace(idx)),
            WaveClearTraces => self.with_wave(|w| {
                w.traces.clear();
                Ok(())
            }),
            WaveSetTraceStyle {
                idx,
                color,
                width,
                line_style,
                visible,
            } => self.with_wave(|w| {
                let t = w
                    .traces
                    .get_mut(idx as usize)
                    .ok_or(wave::WaveError::BadTrace(idx))?;
                t.style = wave::TraceStyle {
                    color,
                    width,
                    line_style: wave::LineStyle::from_u8(line_style),
                    visible,
                };
                Ok(())
            }),
            WaveAddPane => self.with_wave(|w| {
                w.panes.push(wave::Pane::default());
                w.active_pane = (w.panes.len() - 1) as u16;
                Ok(())
            }),
            WaveRemovePane(idx) => self.with_wave(|w| {
                if w.panes.len() <= 1 || idx as usize >= w.panes.len() {
                    return Err(wave::WaveError::BadPane(idx));
                }
                w.panes.remove(idx as usize);
                // Re-point traces: drop the pane's traces, shift the rest.
                w.traces.retain(|t| t.pane != idx);
                for t in &mut w.traces {
                    if t.pane > idx {
                        t.pane -= 1;
                    }
                }
                w.active_pane = w.active_pane.min((w.panes.len() - 1) as u16);
                Ok(())
            }),
            WaveSetActivePane(idx) => self.with_wave(|w| {
                if (idx as usize) < w.panes.len() {
                    w.active_pane = idx;
                    Ok(())
                } else {
                    Err(wave::WaveError::BadPane(idx))
                }
            }),
            WaveSetCursor { cursor, x, visible } => self.with_wave(|w| {
                let c = if cursor == 0 {
                    &mut w.cursor_a
                } else {
                    &mut w.cursor_b
                };
                c.x = x;
                c.visible = visible;
                Ok(())
            }),
            WaveSetXLog(on) => self.with_wave(|w| {
                w.x_log = on;
                Ok(())
            }),
            WaveSetXRange { min, max } => self.with_wave(|w| {
                w.x_range = [min, max];
                w.x_auto = false;
                Ok(())
            }),
            WaveSetYRange { pane, min, max } => self.with_wave(|w| {
                let p = w
                    .panes
                    .get_mut(pane as usize)
                    .ok_or(wave::WaveError::BadPane(pane))?;
                p.y_range = [min, max];
                p.y_auto = false;
                Ok(())
            }),
            WaveZoomFit => self.with_wave(|w| {
                w.zoom_fit();
                Ok(())
            }),
            WaveExportCsv { path } => self.with_wave(|w| {
                let csv = w.export_csv();
                std::fs::write(&path, csv).map_err(|err| wave::WaveError::Io {
                    path: path.into(),
                    err,
                })
            }),

            // ── Optimizer ──
            OptimizerNew { name } => self.handle_optimizer_new(name),
            OptimizerClose { id } => {
                self.state.optimizers.retain(|o| o.id != id);
            }
            OptimizerSetWindowOpen { id, open } => self.with_optimizer(id, |o| {
                o.window_open = open;
                Ok("".into())
            }),
            OptimizerAddParam {
                id,
                name,
                min,
                max,
                init,
            } => self.with_optimizer(id, move |o| {
                o.opt
                    .add_param(schemify_optimizer::Param {
                        name: name.clone(),
                        min,
                        max,
                        init,
                    })
                    .map(|_| format!("Param {name} added"))
            }),
            OptimizerRemoveParam { id, name } => self.with_optimizer(id, move |o| {
                o.opt.remove_param(&name).map(|_| format!("Param {name} removed"))
            }),
            OptimizerAddObjective {
                id,
                name,
                target,
                weight,
            } => self.with_optimizer(id, move |o| {
                let target = match target.as_str() {
                    "min" => schemify_optimizer::Target::Minimize,
                    "max" => schemify_optimizer::Target::Maximize,
                    t => match t.parse::<f64>() {
                        Ok(v) => schemify_optimizer::Target::Approach(v),
                        Err(_) => {
                            return Err(schemify_optimizer::OptError::UnknownName(format!(
                                "target '{t}' (want min, max, or a number)"
                            )))
                        }
                    },
                };
                o.opt
                    .add_objective(schemify_optimizer::Objective {
                        name: name.clone(),
                        target,
                        weight,
                    })
                    .map(|_| format!("Objective {name} added"))
            }),
            OptimizerRemoveObjective { id, name } => self.with_optimizer(id, move |o| {
                o.opt
                    .remove_objective(&name)
                    .map(|_| format!("Objective {name} removed"))
            }),
            OptimizerSetAlgorithm { id, algorithm } => self.with_optimizer(id, move |o| {
                match schemify_optimizer::Algorithm::from_name(&algorithm) {
                    Some(a) => {
                        o.opt.set_algorithm(a);
                        Ok(format!("Algorithm: {}", a.as_str()))
                    }
                    None => Err(schemify_optimizer::OptError::UnknownName(format!(
                        "algorithm '{algorithm}' (want random or nelder-mead)"
                    ))),
                }
            }),
            OptimizerReport {
                id,
                params,
                measured,
            } => self.with_optimizer(id, move |o| {
                let score = match &params {
                    Some(p) => o.opt.report_at(p, &measured)?,
                    None => o.opt.report(&measured)?,
                };
                Ok(format!("Eval {} recorded, score {score:.6e}", o.opt.n_evals()))
            }),
            OptimizerReset { id } => self.with_optimizer(id, |o| {
                o.opt.reset();
                Ok("Optimizer reset".into())
            }),
        }
        Exec::Done
    }

}
