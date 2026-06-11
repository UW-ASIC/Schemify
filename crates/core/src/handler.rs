//! App state + command dispatch — single-file port of the old handler crate.
//!
//! Contents: app/document state, selection (`Vec<ObjectRef>`), undo/redo ring,
//! `App::dispatch` (single mutation entry point), object transforms,
//! hit-testing, uniform-grid spatial culling, union-find connectivity
//! resolution, and Schematic -> `crate::sim` CircuitIR netlist conversion.
//!
//! Killed relative to the old crate: the `SchematicCollection` trait (plain
//! fns + `match` over [`ObjectRef`] instead), per-type selection HashSets,
//! the unversioned connectivity cache (now generation-tagged), bus DRC, and
//! the plugin/marketplace/sim-runner machinery (plugins: phase 7).

use std::collections::VecDeque;
use std::io;
use std::path::{Path, PathBuf};

use lasso::Rodeo;
use rustc_hash::{FxHashMap, FxHashSet};

use crate::config::{self, LoadedPdk, PdkCell, ProjectConfig};
use crate::schemify::{
    self as prim, Arc, Bus, BusRipper, Circle, Color, Command, Connectivity, DeviceKind, Instance,
    InstanceFlags, InstanceVec, Line, Net, NetConnKind, NetEndpoint, Pin, PinConnection,
    PinDirection, Polygon, Property, Rect, Schematic, SchematicType, SpiceBackend, StimulusLang,
    Sym, Text, Tool, Wire, WireVec,
};
use crate::sim as ir;
use crate::wave;

pub const MAX_UNDO_HISTORY: usize = 64;
pub const MAX_COMMAND_QUEUE: usize = 64;

// ════════════════════════════════════════════════════════════
// Object references & selection
// ════════════════════════════════════════════════════════════

/// Typed index of a schematic object. 8 bytes (tag + u32 payload).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ObjectRef {
    Instance(u32),
    Wire(u32),
    Bus(u32),
    Line(u32),
    Rect(u32),
    Circle(u32),
    Arc(u32),
    Text(u32),
    Polygon(u32),
}

impl ObjectRef {
    pub fn index(self) -> usize {
        match self {
            Self::Instance(i)
            | Self::Wire(i)
            | Self::Bus(i)
            | Self::Line(i)
            | Self::Rect(i)
            | Self::Circle(i)
            | Self::Arc(i)
            | Self::Text(i)
            | Self::Polygon(i) => i as usize,
        }
    }

    fn idx_mut(&mut self) -> &mut u32 {
        match self {
            Self::Instance(i)
            | Self::Wire(i)
            | Self::Bus(i)
            | Self::Line(i)
            | Self::Rect(i)
            | Self::Circle(i)
            | Self::Arc(i)
            | Self::Text(i)
            | Self::Polygon(i) => i,
        }
    }

    pub fn same_kind(self, other: ObjectRef) -> bool {
        std::mem::discriminant(&self) == std::mem::discriminant(&other)
    }
}

/// Current selection: one flat list of typed indices (deduplicated on insert).
#[derive(Debug, Clone, Default)]
pub struct Selection {
    pub objs: Vec<ObjectRef>,
}

impl Selection {
    pub fn clear(&mut self) {
        self.objs.clear();
    }

    pub fn is_empty(&self) -> bool {
        self.objs.is_empty()
    }

    pub fn len(&self) -> usize {
        self.objs.len()
    }

    pub fn contains(&self, r: ObjectRef) -> bool {
        self.objs.contains(&r)
    }

    pub fn insert(&mut self, r: ObjectRef) {
        if !self.contains(r) {
            self.objs.push(r);
        }
    }

    pub fn remove(&mut self, r: ObjectRef) {
        self.objs.retain(|o| *o != r);
    }

    /// Remove `deleted` and shift down same-kind refs above it (object was
    /// removed from its backing vec, so higher indices moved down by one).
    pub fn remove_deleted(&mut self, deleted: ObjectRef) {
        self.objs.retain(|o| *o != deleted);
        for o in &mut self.objs {
            if o.same_kind(deleted) && o.index() > deleted.index() {
                *o.idx_mut() -= 1;
            }
        }
    }

    /// Indices of selected instances (alignment ops act on instances only).
    pub fn instance_indices(&self) -> impl Iterator<Item = usize> + '_ {
        self.objs.iter().filter_map(|r| match r {
            ObjectRef::Instance(i) => Some(*i as usize),
            _ => None,
        })
    }
}

// ════════════════════════════════════════════════════════════
// State types
// ════════════════════════════════════════════════════════════

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub enum Origin {
    #[default]
    Unsaved,
    Buffer(String),
    File(PathBuf),
    Memory,
}

#[derive(Debug, Clone)]
pub struct Viewport {
    pub pan: [f32; 2],
    pub zoom: f32,
}

impl Viewport {
    pub const MIN_ZOOM: f32 = 0.01;
    pub const MAX_ZOOM: f32 = 50.0;

    pub fn zoom_in(&mut self) {
        self.zoom = (self.zoom * 1.08).min(Self::MAX_ZOOM);
    }

    pub fn zoom_out(&mut self) {
        self.zoom = (self.zoom / 1.08).max(Self::MIN_ZOOM);
    }

    pub fn zoom_reset(&mut self) {
        self.pan = [0.0, 0.0];
        self.zoom = 1.0;
    }
}

impl Default for Viewport {
    fn default() -> Self {
        Self {
            pan: [0.0, 0.0],
            zoom: 1.0,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum ViewMode {
    #[default]
    Schematic = 0,
    Symbol,
    Documentation,
}

#[derive(Debug, Clone)]
pub struct ViewState {
    pub view_mode: ViewMode,
    pub show_grid: bool,
    pub fullscreen: bool,
    pub dark_mode: bool,
    pub canvas_size: [f32; 2],
    /// Welcome screen visibility. Starts true; cleared by New/Open, set
    /// again when the last tab is closed.
    pub show_welcome: bool,
}

impl Default for ViewState {
    fn default() -> Self {
        Self {
            view_mode: ViewMode::default(),
            show_grid: true,
            fullscreen: false,
            dark_mode: true,
            canvas_size: [800.0, 600.0],
            show_welcome: true,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum ArcStep {
    #[default]
    Center = 0,
    RadiusStart,
    Sweep,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum PanMode {
    #[default]
    Off = 0,
    Grab,
}

#[derive(Debug, Clone)]
pub struct Placement {
    pub symbol_path: String,
    pub name: String,
    pub rotation: u8,
    pub flip: bool,
}

#[derive(Debug, Clone, Default)]
pub struct DrawState {
    pub first_point: Option<[i32; 2]>,
    pub arc_second: Option<[i32; 2]>,
    pub arc_step: ArcStep,
    pub polygon_points: Vec<[i32; 2]>,
    pub text_pos: Option<[i32; 2]>,
    pub text_buf: String,
    pub text_input_active: bool,
}

#[derive(Debug, Clone)]
pub struct ToolState {
    pub active: Tool,
    pub wire_start: Option<[i32; 2]>,
    pub placement: Option<Placement>,
    pub draw: DrawState,
    pub snap_size: f32,
    pub snap_to_grid: bool,
}

impl Default for ToolState {
    fn default() -> Self {
        Self {
            active: Tool::default(),
            wire_start: None,
            placement: None,
            draw: DrawState::default(),
            snap_size: 10.0,
            snap_to_grid: true,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct CanvasState {
    pub last_click_time: f64,
    pub drag_last: [f32; 2],
    pub last_click_pos: [f32; 2],
    pub move_press_pixel: [f32; 2],
    pub move_start_world: [i32; 2],
    pub move_hit: Option<ObjectRef>,
    pub rubber_band_start: [i32; 2],
    pub rubber_band_end: [i32; 2],
    pub cursor_world: [i32; 2],
    pub dragging: bool,
    pub drag_is_pan: bool,
    pub space_held: bool,
    pub space_drag_happened: bool,
    pub pan_mode: PanMode,
    pub move_active: bool,
    pub rubber_band_active: bool,
    /// Accumulated delta during a drag-move (coalesced into one undo entry on release).
    pub move_accum: [i32; 2],
}

/// Compact dialog/panel open flags. The full per-dialog scratch state lives
/// in the display crate; the handler only tracks what dispatch toggles.
#[derive(Debug, Clone, Default)]
pub struct Dialogs {
    pub find_open: bool,
    pub props_open: bool,
    pub settings_open: bool,
    pub spice_code_open: bool,
    pub spice_code_buf: String,
    pub new_prim_open: bool,
    pub marketplace_open: bool,
    pub import_open: bool,
    pub import_status: String,
    pub library_open: bool,
    pub file_explorer_open: bool,
}

/// AoS copies of schematic objects (cross-document paste safe; instance
/// property-pool indices are dropped on paste).
#[derive(Debug, Clone, Default)]
pub struct Clipboard {
    pub instances: Vec<Instance>,
    pub wires: Vec<Wire>,
    pub lines: Vec<Line>,
    pub rects: Vec<Rect>,
    pub circles: Vec<Circle>,
    pub arcs: Vec<Arc>,
    pub texts: Vec<Text>,
    pub polygons: Vec<Polygon>,
}

impl Clipboard {
    pub fn is_empty(&self) -> bool {
        self.instances.is_empty()
            && self.wires.is_empty()
            && self.lines.is_empty()
            && self.rects.is_empty()
            && self.circles.is_empty()
            && self.arcs.is_empty()
            && self.texts.is_empty()
            && self.polygons.is_empty()
    }
}

#[derive(Debug, Clone)]
pub enum UndoEntry {
    Inverse(Command),
    Snapshot(Box<Schematic>),
}

#[derive(Debug, Clone)]
pub struct HierEntry {
    pub doc_idx: usize,
    pub instance_idx: usize,
}

/// A testbench found in the project, cached for the canvas overlay that
/// shows where the open schematic is used.
#[derive(Debug, Clone)]
pub struct ProjectTestbench {
    /// File stem; doubles as the display name.
    pub name: String,
    pub path: PathBuf,
    pub schematic: Schematic,
}

/// Library browser sections sourced from the project: PDK manifest cells,
/// user `.chn_prim` primitives, and project `.chn` subcircuit symbols.
/// Rebuilt by `reload_project_config`.
#[derive(Debug, Clone, Default)]
pub struct LibraryIndex {
    /// (schemify primitive name, PDK model name), sorted by primitive name.
    pub pdk_cells: Vec<(String, String)>,
    /// Runtime prim names from project `.chn_prim` files.
    pub project_prims: Vec<String>,
    /// (symbol name, pin count) for project `.chn` schematics with pins.
    pub project_symbols: Vec<(String, usize)>,
}

// ════════════════════════════════════════════════════════════
// Document (per open tab)
// ════════════════════════════════════════════════════════════

/// Document file type — determines the on-disk extension.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum DocKind {
    /// `.chn` schematic.
    #[default]
    Schematic,
    /// `.chn_prim` primitive (symbol geometry + pins).
    Primitive,
    /// `.chn_tb` testbench.
    Testbench,
}

impl DocKind {
    pub fn ext(self) -> &'static str {
        match self {
            DocKind::Schematic => ".chn",
            DocKind::Primitive => ".chn_prim",
            DocKind::Testbench => ".chn_tb",
        }
    }

    /// Extension without the leading dot (for `Path::with_extension`).
    pub fn ext_no_dot(self) -> &'static str {
        &self.ext()[1..]
    }

    /// Split a file name into (stem, kind). Unknown extensions stay part
    /// of the stem and default to Schematic.
    pub fn split_name(name: &str) -> (&str, DocKind) {
        // Longest suffix first: `.chn` is a suffix of neither, but keep
        // the order explicit so `.chn_prim`/`.chn_tb` never lose to `.chn`.
        for kind in [DocKind::Primitive, DocKind::Testbench, DocKind::Schematic] {
            if let Some(stem) = name.strip_suffix(kind.ext()) {
                return (stem, kind);
            }
        }
        (name, DocKind::Schematic)
    }

    pub fn from_path(path: &Path) -> DocKind {
        match path.extension().and_then(|e| e.to_str()) {
            Some("chn_prim") => DocKind::Primitive,
            Some("chn_tb") => DocKind::Testbench,
            _ => DocKind::Schematic,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct Document {
    pub schematic: Schematic,
    /// File stem (no extension); empty for a not-yet-saved document.
    pub name: String,
    /// File type; supplies the extension shown in the tab title.
    pub kind: DocKind,
    pub origin: Origin,
    pub dirty: bool,

    pub viewport: Viewport,
    pub selection: Selection,

    // Undo/Redo (ring buffer, max 64 deep)
    pub undo_history: VecDeque<UndoEntry>,
    pub redo_history: VecDeque<UndoEntry>,

    /// Monotonic mutation counter; bumped by every connectivity-affecting
    /// schematic mutation. The connectivity cache is tagged with the
    /// generation it was computed at, so staleness is a single compare.
    pub generation: u64,
    connectivity: Option<(u64, Connectivity)>,
}

impl Document {
    /// Tab title: `stem.ext` (`untitled.chn` for a not-yet-saved doc).
    pub fn display_name(&self) -> String {
        let stem = if self.name.is_empty() { "untitled" } else { &self.name };
        format!("{stem}{}", self.kind.ext())
    }
}

// ════════════════════════════════════════════════════════════
// Top-level app state
// ════════════════════════════════════════════════════════════

/// One optimizer window: the optimizer state plus its viewport flag.
pub struct OptimizerInstance {
    /// Stable handle (viewport id, MCP id). Never reused.
    pub id: u32,
    /// Display crate shows/hides the window from this flag; the instance
    /// (and its history) survives hiding — only `OptimizerClose` drops it.
    pub window_open: bool,
    pub opt: schemify_optimizer::Optimizer,
}

pub struct AppState {
    /// String interner (shared across all documents).
    pub interner: Rodeo,

    // Hot: every frame
    pub documents: Vec<Document>,
    pub active_doc: usize,
    pub canvas: CanvasState,
    pub view: ViewState,
    pub tool: ToolState,
    pub status_msg: String,

    // Warm: project config + commands
    pub project_dir: PathBuf,
    pub config: ProjectConfig,
    pub command_queue: VecDeque<Command>,
    pub clipboard: Clipboard,
    pub highlighted_nets: FxHashSet<Sym>,
    pub dialogs: Dialogs,

    /// Waveform viewer — one app-wide instance shown in its own native
    /// window (egui viewport), opened from the toolbar or `WaveOpen`.
    /// Boxed + optional: costs one pointer when unused.
    pub wave: Option<Box<crate::wave::WaveState>>,
    /// Display crate shows/hides the viewer window from this flag.
    pub wave_window_open: bool,

    /// Optimizer windows — any number may be open at once; each entry is
    /// one instance with its own native window (egui viewport).
    pub optimizers: Vec<OptimizerInstance>,
    /// Monotonic id source for optimizer instances; ids are never reused
    /// (viewport ids and MCP handles stay stable across closes).
    pub next_optimizer_id: u32,

    // Cold: infrequent
    pub pdk: Option<LoadedPdk>,
    pub library: LibraryIndex,
    /// Project `.chn` schematics registered as placeable symbols; passed as
    /// children at netlist generation so their subckt defs are emitted.
    pub project_symbol_schematics: Vec<Schematic>,
    /// Project testbenches, cached for the canvas usage overlay.
    pub project_testbenches: Vec<ProjectTestbench>,
    pub hierarchy_stack: Vec<HierEntry>,
    pub last_netlist: String,

    // Plugin host requests (drained by the display-side PluginHost each
    // frame; headless modes have no consumer, so both are capped).
    /// Set by `PluginsRefresh`; cleared by the host after a rescan.
    pub plugin_refresh_requested: bool,
    /// `(tag, payload)` from `PluginCommand`, tag = "plugin-id:command".
    pub pending_plugin_commands: Vec<(String, Vec<u8>)>,

    pub quit_requested: bool,
}

impl Default for AppState {
    fn default() -> Self {
        Self::new()
    }
}

impl AppState {
    pub fn new() -> Self {
        Self {
            interner: Rodeo::default(),
            documents: vec![Document::default()],
            active_doc: 0,
            canvas: CanvasState::default(),
            view: ViewState::default(),
            tool: ToolState::default(),
            status_msg: String::new(),
            project_dir: PathBuf::new(),
            config: ProjectConfig::default(),
            command_queue: VecDeque::with_capacity(MAX_COMMAND_QUEUE),
            clipboard: Clipboard::default(),
            highlighted_nets: FxHashSet::default(),
            dialogs: Dialogs::default(),
            wave: None,
            wave_window_open: false,
            optimizers: Vec::new(),
            next_optimizer_id: 0,
            pdk: None,
            library: LibraryIndex::default(),
            project_symbol_schematics: Vec::new(),
            project_testbenches: Vec::new(),
            hierarchy_stack: Vec::new(),
            last_netlist: String::new(),
            plugin_refresh_requested: false,
            pending_plugin_commands: Vec::new(),
            quit_requested: false,
        }
    }

    pub fn active_document(&self) -> &Document {
        &self.documents[self.active_doc]
    }

    pub fn active_document_mut(&mut self) -> &mut Document {
        &mut self.documents[self.active_doc]
    }
}

// ════════════════════════════════════════════════════════════
// App facade
// ════════════════════════════════════════════════════════════

pub struct App {
    pub state: AppState,
}

impl Default for App {
    fn default() -> Self {
        Self::new()
    }
}

impl App {
    pub fn new() -> Self {
        Self {
            state: AppState::new(),
        }
    }

    pub fn schematic(&self) -> &Schematic {
        &self.state.active_document().schematic
    }

    pub fn active_doc(&self) -> &Document {
        self.state.active_document()
    }

    pub fn resolve(&self, sym: Sym) -> &str {
        self.state.interner.resolve(&sym)
    }

    /// Lazily-computed connectivity for the active document, recomputed only
    /// when the document generation has moved past the cached one.
    pub fn connectivity(&mut self) -> &Connectivity {
        let di = self.state.active_doc;
        let doc = &self.state.documents[di];
        let fresh = matches!(&doc.connectivity, Some((g, _)) if *g == doc.generation);
        if !fresh {
            let conn =
                resolve_connectivity(&self.state.documents[di].schematic, &self.state.interner);
            let generation = self.state.documents[di].generation;
            self.state.documents[di].connectivity = Some((generation, conn));
        }
        &self.state.documents[di].connectivity.as_ref().unwrap().1
    }

    pub fn selection_mut(&mut self) -> &mut Selection {
        &mut self.state.active_document_mut().selection
    }

    pub fn start_placement(&mut self, symbol_path: String, name: String) {
        self.state.tool.active = Tool::Select;
        self.state.tool.placement = Some(Placement {
            symbol_path,
            name,
            rotation: 0,
            flip: false,
        });
    }

    pub fn commit_polygon(&mut self) {
        let pts = std::mem::take(&mut self.state.tool.draw.polygon_points);
        if pts.len() >= 3 {
            self.dispatch(Command::AddPolygon { points: pts });
        }
    }

    /// Commit the current text input as an AddText command, then clear all
    /// text draw state. No-op (state preserved) if no position is set.
    pub fn commit_text(&mut self) {
        let Some(pos) = self.state.tool.draw.text_pos else {
            return;
        };
        let content = std::mem::take(&mut self.state.tool.draw.text_buf);
        self.state.tool.draw.text_pos = None;
        self.state.tool.draw.text_input_active = false;
        if !content.is_empty() {
            self.dispatch(Command::AddText {
                x: pos[0],
                y: pos[1],
                content,
            });
        }
    }

    /// Clear all text draw state without committing.
    pub fn clear_text_input(&mut self) {
        self.state.tool.draw.text_pos = None;
        self.state.tool.draw.text_buf.clear();
        self.state.tool.draw.text_input_active = false;
    }

    /// Commit accumulated move delta as a single undo entry (call on drag release).
    pub fn commit_move_drag(&mut self) {
        let [dx, dy] = self.state.canvas.move_accum;
        if dx != 0 || dy != 0 {
            self.push_undo(UndoEntry::Inverse(Command::MoveSelected {
                dx: -dx,
                dy: -dy,
            }));
        }
        self.state.canvas.move_accum = [0, 0];
    }
}

// ════════════════════════════════════════════════════════════
// Dispatch — single entry point for all mutations
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
                self.push_undo_snapshot();
                self.copy_to_clipboard();
                self.exec_delete_selected();
                self.touch();
            }
            Paste => {
                if !self.state.clipboard.is_empty() {
                    self.push_undo_snapshot();
                    self.paste_from_clipboard();
                    self.touch();
                }
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
                self.push_undo(UndoEntry::Inverse(MoveInstance {
                    idx,
                    dx: -dx,
                    dy: -dy,
                }));
                self.state
                    .active_document_mut()
                    .schematic
                    .translate_instance(idx, dx, dy);
                self.touch();
            }
            MoveWire { idx, dx, dy } => {
                self.push_undo(UndoEntry::Inverse(MoveWire {
                    idx,
                    dx: -dx,
                    dy: -dy,
                }));
                self.state
                    .active_document_mut()
                    .schematic
                    .translate_wire(idx, dx, dy);
                self.touch();
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
            RotateCw => {
                self.push_undo(UndoEntry::Inverse(RotateCcw));
                self.rotate_selected(true);
                self.touch();
            }
            RotateCcw => {
                self.push_undo(UndoEntry::Inverse(RotateCw));
                self.rotate_selected(false);
                self.touch();
            }
            FlipHorizontal => {
                self.push_undo(UndoEntry::Inverse(FlipHorizontal));
                self.flip_selected(true);
                self.touch();
            }
            FlipVertical => {
                self.push_undo(UndoEntry::Inverse(FlipVertical));
                self.flip_selected(false);
                self.touch();
            }

            // ── Align (snapshot — not trivially invertible) ──
            AlignToGrid => {
                self.push_undo_snapshot();
                self.align_selected_to_grid();
                self.touch();
            }

            // ── Deletion (snapshot) ──
            DeleteSelected => {
                self.push_undo_snapshot();
                self.exec_delete_selected();
                self.touch();
            }
            DeleteInstance(idx) => {
                if idx < self.state.active_document().schematic.instances.len() {
                    self.push_undo_snapshot();
                    let doc = self.state.active_document_mut();
                    doc.schematic.instances.remove(idx);
                    doc.selection
                        .remove_deleted(ObjectRef::Instance(idx as u32));
                    self.touch();
                }
            }
            DeleteWire(idx) => {
                if idx < self.state.active_document().schematic.wires.len() {
                    self.push_undo_snapshot();
                    let doc = self.state.active_document_mut();
                    doc.schematic.wires.remove(idx);
                    doc.selection.remove_deleted(ObjectRef::Wire(idx as u32));
                    self.touch();
                }
            }

            // ── Duplication (snapshot) ──
            DuplicateSelected => {
                self.push_undo_snapshot();
                self.exec_duplicate_selected();
                self.touch();
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

                // Aliases ("res", "cap", …) have no prim entry of their own;
                // fall back to the kind-name table so live placement agrees
                // with the file loader.
                let entry = prim::find_by_name(&symbol_path);
                let kind = entry
                    .map(|p| p.kind)
                    .unwrap_or_else(|| DeviceKind::from_name(&symbol_path));

                // Power connectors inject their net name as a property so it
                // is user-editable (e.g. multiple supply rails).
                let net_prop = if kind.is_power() {
                    let net_val = entry.and_then(|p| p.injected_net).unwrap_or("0");
                    Some(Property {
                        key: self.state.interner.get_or_intern("net"),
                        value: self.state.interner.get_or_intern(net_val),
                    })
                } else {
                    None
                };

                let doc = self.state.active_document_mut();
                let (prop_start, prop_count) = if let Some(p) = net_prop {
                    let ps = doc.schematic.properties.len() as u32;
                    doc.schematic.properties.push(p);
                    (ps, 1u16)
                } else {
                    (0, 0u16)
                };

                doc.schematic.instances.push(Instance {
                    name: name_sym,
                    symbol: sym,
                    spice_line: empty,
                    x,
                    y,
                    kind,
                    flags: InstanceFlags::new(rotation, flip),
                    prop_start,
                    prop_count,
                    name_offset: [0, 0],
                    param_offset: [0, 0],
                });
                self.touch();
            }

            // ── Wiring (snapshot) ──
            AddWire { x0, y0, x1, y1 } => {
                self.push_undo_snapshot();
                self.state.active_document_mut().schematic.wires.push(Wire {
                    net_name: None,
                    x0,
                    y0,
                    x1,
                    y1,
                    color: Color::NONE,
                    thickness: 10,
                });
                self.touch();
            }

            // ── Geometry (snapshot) ──
            AddLine { x0, y0, x1, y1 } => {
                self.push_undo_snapshot();
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
                self.push_undo_snapshot();
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
                self.push_undo_snapshot();
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
                self.push_undo_snapshot();
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
                self.push_undo_snapshot();
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
                if points.len() >= 3 {
                    self.push_undo_snapshot();
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
            }

            // ── Properties (snapshot) ──
            SetInstanceProp { idx, key, value } => {
                self.push_undo_snapshot();
                let key_sym = self.state.interner.get_or_intern(&key);
                let value_sym = self.state.interner.get_or_intern(&value);
                self.state
                    .active_document_mut()
                    .schematic
                    .set_instance_prop(idx, key_sym, value_sym);
            }
            RenameInstance { idx, new_name } => {
                self.push_undo_snapshot();
                let sym = self.state.interner.get_or_intern(&new_name);
                let doc = self.state.active_document_mut();
                if idx < doc.schematic.instances.len() {
                    doc.schematic.instances.name[idx] = sym;
                }
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

            // ── Simulation ──
            ExportNetlist => {
                self.generate_netlist();
                self.state.status_msg = "Netlist generated".into();
            }
            RunSim => self.run_simulation(),
            SetStimulusLang(lang_str) => {
                if let Some(lang) = StimulusLang::from_name(&lang_str) {
                    self.push_undo_snapshot();
                    self.state.active_document_mut().schematic.stimulus_lang = lang;
                    self.state.status_msg = format!("Stimulus language: {}", lang.as_str());
                } else {
                    self.state.status_msg = format!("Unknown stimulus language: {lang_str}");
                }
            }
            SetSimBackend(backend_str) => {
                if let Some(be) = SpiceBackend::from_name(&backend_str) {
                    self.push_undo_snapshot();
                    self.state.active_document_mut().schematic.sim_backend = be;
                    self.state.status_msg = format!("Sim backend: {}", be.as_str());
                } else {
                    self.state.status_msg = format!("Unknown sim backend: {backend_str}");
                }
            }
            SetSimCorner(corner) => {
                if let Some(p) = &self.state.pdk {
                    if !corner.is_empty() && !p.corners.iter().any(|c| c == &corner) {
                        self.state.status_msg = format!(
                            "Unknown corner '{corner}' for PDK {} (known: {})",
                            p.name,
                            p.corners.join(", ")
                        );
                        return;
                    }
                }
                self.push_undo_snapshot();
                self.state.status_msg = if corner.is_empty() {
                    "Corner: PDK default".to_string()
                } else {
                    format!("Corner: {corner}")
                };
                self.state.active_document_mut().schematic.sim_corner = corner;
            }

            // ── Symbol generation ──
            GenerateSymbolFromSchematic => self.generate_symbol_from_schematic(),

            // ── Import ──
            ImportSpice { path } => {
                // SPICE import: ported in a later phase.
                self.state.status_msg = format!("SPICE import not available yet ({path})");
                self.state.dialogs.import_status = self.state.status_msg.clone();
            }

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
                self.push_undo_snapshot();
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
                self.touch();
            }
            DeleteBus(idx) => {
                if idx < self.state.active_document().schematic.buses.len() {
                    self.push_undo_snapshot();
                    let doc = self.state.active_document_mut();
                    remove_bus(&mut doc.schematic, idx);
                    doc.selection.remove_deleted(ObjectRef::Bus(idx as u32));
                    self.touch();
                }
            }
            SetBusWidth { idx, width } => {
                self.push_undo_snapshot();
                let doc = self.state.active_document_mut();
                if idx < doc.schematic.buses.len() {
                    doc.schematic.buses.width[idx] = width;
                }
                self.touch();
            }
            RenameBus { idx, new_name } => {
                self.push_undo_snapshot();
                let sym = self.state.interner.get_or_intern(&new_name);
                let doc = self.state.active_document_mut();
                if idx < doc.schematic.buses.len() {
                    doc.schematic.buses.label[idx] = sym;
                }
                self.touch();
            }
            AddBusRipper {
                bus_idx,
                bit,
                x,
                y,
                direction,
            } => {
                self.push_undo_snapshot();
                self.state
                    .active_document_mut()
                    .schematic
                    .bus_rippers
                    .push(BusRipper {
                        bus_idx,
                        bit,
                        x,
                        y,
                        direction,
                        stub_len: 20,
                    });
                self.touch();
            }
            DeleteBusRipper(idx) => {
                self.push_undo_snapshot();
                let doc = self.state.active_document_mut();
                if idx < doc.schematic.bus_rippers.len() {
                    doc.schematic.bus_rippers.remove(idx);
                }
                self.touch();
            }

            // ── Wire editing ──
            SplitWire { idx, x, y } => {
                if idx < self.state.active_document().schematic.wires.len() {
                    self.push_undo_snapshot();
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
                    self.touch();
                }
            }

            // ── Alignment commands ──
            AlignLeft => {
                self.push_undo_snapshot();
                self.align_selected(AlignAxis::X, AlignMode::Min);
                self.touch();
            }
            AlignRight => {
                self.push_undo_snapshot();
                self.align_selected(AlignAxis::X, AlignMode::Max);
                self.touch();
            }
            AlignTop => {
                self.push_undo_snapshot();
                self.align_selected(AlignAxis::Y, AlignMode::Min);
                self.touch();
            }
            AlignBottom => {
                self.push_undo_snapshot();
                self.align_selected(AlignAxis::Y, AlignMode::Max);
                self.touch();
            }
            AlignCenterH => {
                self.push_undo_snapshot();
                self.align_selected(AlignAxis::X, AlignMode::Center);
                self.touch();
            }
            AlignCenterV => {
                self.push_undo_snapshot();
                self.align_selected(AlignAxis::Y, AlignMode::Center);
                self.touch();
            }
            DistributeH => {
                self.push_undo_snapshot();
                self.distribute_selected(AlignAxis::X);
                self.touch();
            }
            DistributeV => {
                self.push_undo_snapshot();
                self.distribute_selected(AlignAxis::Y);
                self.touch();
            }

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
            MarketplaceFetch | MarketplaceInstall { .. } | MarketplaceUninstall { .. } => {
                self.state.status_msg = "Marketplace not available yet".into();
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
    }

    /// Run `f` against the app-wide wave state; status bar reports errors
    /// (and "no waveform loaded" when there is none).
    fn with_wave(
        &mut self,
        f: impl FnOnce(&mut wave::WaveState) -> Result<(), wave::WaveError>,
    ) {
        let Some(w) = self.state.wave.as_deref_mut() else {
            self.state.status_msg = "No waveform loaded (WaveOpen first)".into();
            return;
        };
        if let Err(e) = f(w) {
            self.state.status_msg = format!("Wave: {e}");
        }
    }

    /// Open a `.raw` into the viewer (created on first open) and show the
    /// viewer window.
    fn handle_wave_open(&mut self, path: &str) {
        let w = self
            .state
            .wave
            .get_or_insert_with(|| Box::new(wave::WaveState::new()));
        match w.open_file(std::path::Path::new(path)) {
            Ok(_) => {
                self.state.wave_window_open = true;
                self.state.status_msg = format!("Loaded {path}");
            }
            Err(e) => self.state.status_msg = format!("Wave: {e}"),
        }
    }

    /// Create an optimizer instance and open its window. Any number of
    /// instances may exist; ids are monotonic and never reused.
    fn handle_optimizer_new(&mut self, name: String) {
        let id = self.state.next_optimizer_id;
        self.state.next_optimizer_id += 1;
        let name = if name.is_empty() {
            format!("Optimizer {}", id + 1)
        } else {
            name
        };
        let mut opt = schemify_optimizer::Optimizer::new(&*name);
        // Decorrelate concurrent instances without losing determinism.
        opt.set_seed(0x9E37_79B9_7F4A_7C15 ^ u64::from(id));
        self.state.optimizers.push(OptimizerInstance {
            id,
            window_open: true,
            opt,
        });
        self.state.status_msg = format!("{name} opened");
    }

    /// Run `f` against optimizer `id`; status bar reports the outcome.
    fn with_optimizer(
        &mut self,
        id: u32,
        f: impl FnOnce(&mut OptimizerInstance) -> Result<String, schemify_optimizer::OptError>,
    ) {
        let Some(o) = self.state.optimizers.iter_mut().find(|o| o.id == id) else {
            self.state.status_msg = format!("No optimizer with id {id}");
            return;
        };
        match f(o) {
            Ok(msg) if !msg.is_empty() => self.state.status_msg = msg,
            Ok(_) => {}
            Err(e) => self.state.status_msg = format!("Optimizer: {e}"),
        }
    }

    /// Close tab `idx`, keeping at least one document open and
    /// re-pointing `active_doc` past the removal.
    fn close_tab(&mut self, idx: usize) {
        if idx >= self.state.documents.len() {
            return;
        }
        if self.state.documents.len() == 1 {
            // Closing the last tab returns to the welcome screen.
            self.state.documents[0] = Document::default();
            self.state.active_doc = 0;
            self.state.view.show_welcome = true;
            return;
        }
        self.state.documents.remove(idx);
        if self.state.active_doc >= self.state.documents.len() {
            self.state.active_doc = self.state.documents.len() - 1;
        } else if self.state.active_doc > idx {
            self.state.active_doc -= 1;
        }
    }

    /// True while the only document is the pristine startup placeholder
    /// backing the welcome screen.
    fn welcome_placeholder(&self) -> bool {
        let docs = &self.state.documents;
        self.state.view.show_welcome
            && docs.len() == 1
            && !docs[0].dirty
            && docs[0].schematic.instances.is_empty()
            && docs[0].schematic.wires.is_empty()
    }

    /// Install a document: reuse the welcome placeholder slot if present,
    /// otherwise open a new tab. Dismisses the welcome screen either way.
    pub fn adopt_document(&mut self, doc: Document) {
        if self.welcome_placeholder() {
            self.state.documents[0] = doc;
            self.state.active_doc = 0;
        } else {
            self.state.documents.push(doc);
            self.state.active_doc = self.state.documents.len() - 1;
        }
        self.state.view.show_welcome = false;
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
        self.push_undo(UndoEntry::Snapshot(Box::new(sch)));
    }

    fn handle_undo(&mut self) {
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

    fn handle_redo(&mut self) {
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
    fn exec_invertible(&mut self, cmd: &Command) {
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
    fn touch(&mut self) {
        self.state.active_document_mut().generation += 1;
    }
}

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

impl App {
    fn move_selected(&mut self, dx: i32, dy: i32) {
        let doc = self.state.active_document_mut();
        for &r in &doc.selection.objs {
            translate_obj(&mut doc.schematic, r, dx, dy);
        }
    }

    fn rotate_selected(&mut self, clockwise: bool) {
        let doc = self.state.active_document_mut();
        let Some((cx, cy)) = centroid_of_selection(&doc.schematic, &doc.selection) else {
            return;
        };
        for &r in &doc.selection.objs {
            rotate_obj(&mut doc.schematic, r, cx, cy, clockwise);
        }
    }

    fn flip_selected(&mut self, horizontal: bool) {
        let doc = self.state.active_document_mut();
        let Some((cx, cy)) = centroid_of_selection(&doc.schematic, &doc.selection) else {
            return;
        };
        for &r in &doc.selection.objs {
            flip_obj(&mut doc.schematic, r, cx, cy, horizontal);
        }
    }

    fn align_selected_to_grid(&mut self) {
        let grid = self.state.tool.snap_size as i32;
        if grid <= 0 {
            return;
        }
        let doc = self.state.active_document_mut();
        for &r in &doc.selection.objs {
            snap_obj(&mut doc.schematic, r, grid);
        }
    }

    fn align_selected(&mut self, axis: AlignAxis, mode: AlignMode) {
        let doc = self.state.active_document_mut();
        let indices: Vec<usize> = doc
            .selection
            .instance_indices()
            .filter(|&i| i < doc.schematic.instances.len())
            .collect();
        if indices.len() < 2 {
            return;
        }
        let positions: Vec<i32> = indices
            .iter()
            .map(|&i| axis.get(&doc.schematic.instances, i))
            .collect();
        let lo = *positions.iter().min().unwrap();
        let hi = *positions.iter().max().unwrap();
        let target = match mode {
            AlignMode::Min => lo,
            AlignMode::Max => hi,
            AlignMode::Center => (lo + hi) / 2,
        };
        for idx in indices {
            axis.set(&mut doc.schematic.instances, idx, target);
        }
    }

    fn distribute_selected(&mut self, axis: AlignAxis) {
        let doc = self.state.active_document_mut();
        let mut indexed: Vec<(usize, i32)> = doc
            .selection
            .instance_indices()
            .filter(|&i| i < doc.schematic.instances.len())
            .map(|i| (i, axis.get(&doc.schematic.instances, i)))
            .collect();
        if indexed.len() < 3 {
            return;
        }
        indexed.sort_unstable_by_key(|&(_, v)| v);
        let n = indexed.len();
        let lo = indexed[0].1;
        let hi = indexed[n - 1].1;
        let step = (hi - lo) as f64 / (n - 1) as f64;
        for (rank, &(idx, _)) in indexed.iter().enumerate() {
            axis.set(
                &mut doc.schematic.instances,
                idx,
                lo + (step * rank as f64).round() as i32,
            );
        }
    }
}

enum AlignAxis {
    X,
    Y,
}

enum AlignMode {
    Min,
    Max,
    Center,
}

impl AlignAxis {
    fn get(&self, instances: &InstanceVec, idx: usize) -> i32 {
        match self {
            Self::X => instances.x[idx],
            Self::Y => instances.y[idx],
        }
    }

    fn set(&self, instances: &mut InstanceVec, idx: usize, val: i32) {
        match self {
            Self::X => instances.x[idx] = val,
            Self::Y => instances.y[idx] = val,
        }
    }
}

// ════════════════════════════════════════════════════════════
// Clipboard / delete / duplicate
// ════════════════════════════════════════════════════════════

impl App {
    fn copy_to_clipboard(&mut self) {
        let doc = &self.state.documents[self.state.active_doc];
        let sch = &doc.schematic;
        let mut clip = Clipboard::default();
        for &r in &doc.selection.objs {
            let i = r.index();
            match r {
                ObjectRef::Instance(_) if i < sch.instances.len() => {
                    clip.instances.push(instance_at(sch, i));
                }
                ObjectRef::Wire(_) if i < sch.wires.len() => clip.wires.push(wire_at(sch, i)),
                ObjectRef::Line(_) if i < sch.lines.len() => clip.lines.push(sch.lines[i].clone()),
                ObjectRef::Rect(_) if i < sch.rects.len() => clip.rects.push(sch.rects[i].clone()),
                ObjectRef::Circle(_) if i < sch.circles.len() => {
                    clip.circles.push(sch.circles[i].clone());
                }
                ObjectRef::Arc(_) if i < sch.arcs.len() => clip.arcs.push(sch.arcs[i].clone()),
                ObjectRef::Text(_) if i < sch.texts.len() => clip.texts.push(sch.texts[i].clone()),
                ObjectRef::Polygon(_) if i < sch.polygons.len() => {
                    clip.polygons.push(sch.polygons[i].clone());
                }
                _ => {} // buses are not clipboard objects; out-of-range refs skipped
            }
        }
        self.state.clipboard = clip;
    }

    fn paste_from_clipboard(&mut self) {
        let (dx, dy) = self.paste_offset();
        // Split borrows: clipboard shared, active document mut — no clone needed.
        let state = &mut self.state;
        let clip = &state.clipboard;
        let doc = &mut state.documents[state.active_doc];
        let sch = &mut doc.schematic;
        let sel = &mut doc.selection;
        sel.clear();
        sel.objs.reserve(
            clip.instances.len()
                + clip.wires.len()
                + clip.lines.len()
                + clip.rects.len()
                + clip.circles.len()
                + clip.arcs.len()
                + clip.texts.len()
                + clip.polygons.len(),
        );

        for it in &clip.instances {
            let mut it = it.clone();
            it.x += dx;
            it.y += dy;
            // Property-pool indices belong to the source document.
            it.prop_start = 0;
            it.prop_count = 0;
            sel.objs
                .push(ObjectRef::Instance(sch.instances.len() as u32));
            sch.instances.push(it);
        }
        for it in &clip.wires {
            let mut it = it.clone();
            it.x0 += dx;
            it.y0 += dy;
            it.x1 += dx;
            it.y1 += dy;
            sel.objs.push(ObjectRef::Wire(sch.wires.len() as u32));
            sch.wires.push(it);
        }
        for it in &clip.lines {
            let mut it = it.clone();
            it.x0 += dx;
            it.y0 += dy;
            it.x1 += dx;
            it.y1 += dy;
            sel.objs.push(ObjectRef::Line(sch.lines.len() as u32));
            sch.lines.push(it);
        }
        for it in &clip.rects {
            let mut it = it.clone();
            it.x += dx;
            it.y += dy;
            sel.objs.push(ObjectRef::Rect(sch.rects.len() as u32));
            sch.rects.push(it);
        }
        for it in &clip.circles {
            let mut it = it.clone();
            it.cx += dx;
            it.cy += dy;
            sel.objs.push(ObjectRef::Circle(sch.circles.len() as u32));
            sch.circles.push(it);
        }
        for it in &clip.arcs {
            let mut it = it.clone();
            it.cx += dx;
            it.cy += dy;
            sel.objs.push(ObjectRef::Arc(sch.arcs.len() as u32));
            sch.arcs.push(it);
        }
        for it in &clip.texts {
            let mut it = it.clone();
            it.x += dx;
            it.y += dy;
            sel.objs.push(ObjectRef::Text(sch.texts.len() as u32));
            sch.texts.push(it);
        }
        for it in &clip.polygons {
            let mut it = it.clone();
            for pt in &mut it.points {
                pt[0] += dx;
                pt[1] += dy;
            }
            sel.objs.push(ObjectRef::Polygon(sch.polygons.len() as u32));
            sch.polygons.push(it);
        }
    }

    fn paste_offset(&self) -> (i32, i32) {
        let Some((cx, cy)) = centroid_of_clipboard(&self.state.clipboard) else {
            return (20, 20);
        };
        let cursor = self.state.canvas.cursor_world;
        let mut dx = cursor[0] - cx;
        let mut dy = cursor[1] - cy;
        if self.state.tool.snap_to_grid {
            let grid = self.state.tool.snap_size as i32;
            if grid > 0 {
                dx = ((dx as f64 / grid as f64).round() as i32) * grid;
                dy = ((dy as f64 / grid as f64).round() as i32) * grid;
            }
        }
        (dx, dy)
    }

    fn exec_delete_selected(&mut self) {
        let doc = self.state.active_document_mut();
        remove_selected_objects(&mut doc.schematic, &doc.selection);
        doc.selection.clear();
    }

    fn exec_duplicate_selected(&mut self) {
        const D: i32 = 20;
        let doc = self.state.active_document_mut();
        let sch = &mut doc.schematic;
        let old_sel = std::mem::take(&mut doc.selection.objs);
        doc.selection.objs.reserve(old_sel.len());
        for r in old_sel {
            let i = r.index();
            let new_ref = match r {
                ObjectRef::Instance(_) if i < sch.instances.len() => {
                    let mut it = instance_at(sch, i);
                    it.x += D;
                    it.y += D;
                    it.prop_start = 0;
                    it.prop_count = 0;
                    let n = sch.instances.len() as u32;
                    sch.instances.push(it);
                    Some(ObjectRef::Instance(n))
                }
                ObjectRef::Wire(_) if i < sch.wires.len() => {
                    let mut it = wire_at(sch, i);
                    it.x0 += D;
                    it.y0 += D;
                    it.x1 += D;
                    it.y1 += D;
                    let n = sch.wires.len() as u32;
                    sch.wires.push(it);
                    Some(ObjectRef::Wire(n))
                }
                ObjectRef::Line(_) if i < sch.lines.len() => {
                    let mut it = sch.lines[i].clone();
                    it.x0 += D;
                    it.y0 += D;
                    it.x1 += D;
                    it.y1 += D;
                    sch.lines.push(it);
                    Some(ObjectRef::Line(sch.lines.len() as u32 - 1))
                }
                ObjectRef::Rect(_) if i < sch.rects.len() => {
                    let mut it = sch.rects[i].clone();
                    it.x += D;
                    it.y += D;
                    sch.rects.push(it);
                    Some(ObjectRef::Rect(sch.rects.len() as u32 - 1))
                }
                ObjectRef::Circle(_) if i < sch.circles.len() => {
                    let mut it = sch.circles[i].clone();
                    it.cx += D;
                    it.cy += D;
                    sch.circles.push(it);
                    Some(ObjectRef::Circle(sch.circles.len() as u32 - 1))
                }
                ObjectRef::Arc(_) if i < sch.arcs.len() => {
                    let mut it = sch.arcs[i].clone();
                    it.cx += D;
                    it.cy += D;
                    sch.arcs.push(it);
                    Some(ObjectRef::Arc(sch.arcs.len() as u32 - 1))
                }
                ObjectRef::Text(_) if i < sch.texts.len() => {
                    let mut it = sch.texts[i].clone();
                    it.x += D;
                    it.y += D;
                    sch.texts.push(it);
                    Some(ObjectRef::Text(sch.texts.len() as u32 - 1))
                }
                ObjectRef::Polygon(_) if i < sch.polygons.len() => {
                    let mut it = sch.polygons[i].clone();
                    for pt in &mut it.points {
                        pt[0] += D;
                        pt[1] += D;
                    }
                    sch.polygons.push(it);
                    Some(ObjectRef::Polygon(sch.polygons.len() as u32 - 1))
                }
                _ => None, // buses are not duplicated
            };
            if let Some(nr) = new_ref {
                doc.selection.objs.push(nr);
            }
        }
    }
}

// ════════════════════════════════════════════════════════════
// File handlers
// ════════════════════════════════════════════════════════════

impl App {
    /// Parse CHN content, logging parse warnings to stderr and the status
    /// bar. Returns the schematic and the warning count.
    fn read_chn_reported(&mut self, content: &str) -> (Schematic, usize) {
        let (schematic, warnings) = prim::read_chn_report(content, &mut self.state.interner);
        if !warnings.is_empty() {
            for warn in &warnings {
                eprintln!("chn parse warning: {warn:?}");
            }
            self.state.status_msg = format!(
                "{} parse warning(s) — see console for details",
                warnings.len()
            );
        }
        (schematic, warnings.len())
    }

    pub fn open_file(&mut self, path: &Path) -> io::Result<()> {
        let content = std::fs::read_to_string(path)?;
        let (schematic, _) = self.read_chn_reported(&content);
        let name = path
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        self.adopt_document(Document {
            schematic,
            name,
            kind: DocKind::from_path(path),
            origin: Origin::File(path.to_owned()),
            ..Default::default()
        });
        Ok(())
    }

    pub fn save_to_path(&mut self, path: &Path) -> io::Result<()> {
        let doc = &self.state.documents[self.state.active_doc];
        // Default the extension from the doc kind when the dialog/caller
        // omitted one ("foo" -> "foo.chn").
        let path = if path.extension().is_none() {
            path.with_extension(doc.kind.ext_no_dot())
        } else {
            path.to_owned()
        };
        match prim::write_chn(&doc.schematic, &self.state.interner) {
            Some(content) => {
                std::fs::write(&path, &content)?;
                let kind = DocKind::from_path(&path);
                let doc = self.state.active_document_mut();
                doc.origin = Origin::File(path.clone());
                doc.dirty = false;
                doc.kind = kind;
                doc.name = path
                    .file_stem()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .into_owned();
                Ok(())
            }
            None => Err(io::Error::other("serialization failed")),
        }
    }

    pub fn open_from_content(&mut self, name: &str, content: &str) {
        let (schematic, _) = self.read_chn_reported(content);
        let (stem, kind) = DocKind::split_name(name);
        self.adopt_document(Document {
            schematic,
            name: stem.to_string(),
            kind,
            origin: Origin::Memory,
            ..Default::default()
        });
    }

    fn handle_file_save(&mut self) {
        let doc_idx = self.state.active_doc;
        let path = match &self.state.documents[doc_idx].origin {
            Origin::File(p) => Some(p.clone()),
            _ => None, // no file origin: display crate shows save-as dialog
        };
        if let Some(path) = path {
            if let Some(content) = prim::write_chn(
                &self.state.documents[doc_idx].schematic,
                &self.state.interner,
            ) {
                if std::fs::write(&path, &content).is_ok() {
                    self.state.documents[doc_idx].dirty = false;
                    self.state.status_msg = format!("Saved {}", path.display());
                } else {
                    self.state.status_msg = format!("Failed to write {}", path.display());
                }
            }
        }
    }

    fn handle_reload(&mut self) {
        let doc_idx = self.state.active_doc;
        let path = match &self.state.documents[doc_idx].origin {
            Origin::File(p) => Some(p.clone()),
            _ => None,
        };
        if let Some(path) = path {
            if let Ok(content) = std::fs::read_to_string(&path) {
                let (schematic, nwarn) = self.read_chn_reported(&content);
                let doc = &mut self.state.documents[doc_idx];
                doc.schematic = schematic;
                doc.dirty = false;
                doc.undo_history.clear();
                doc.redo_history.clear();
                doc.generation += 1;
                doc.selection.clear();
                if nwarn == 0 {
                    self.state.status_msg = format!("Reloaded {}", path.display());
                }
            }
        }
    }

    fn handle_zoom_fit(&mut self) {
        let Some((min_x, min_y, max_x, max_y)) =
            compute_bounds(&self.state.active_document().schematic)
        else {
            return;
        };
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

// ════════════════════════════════════════════════════════════
// Symbol generation
// ════════════════════════════════════════════════════════════

impl App {
    fn generate_symbol_from_schematic(&mut self) {
        // Collect label data (name sym, position, direction) from the schematic.
        let label_data: Vec<(Sym, i32, i32, PinDirection)> = {
            let sch = &self.state.active_document().schematic;
            (0..sch.instances.len())
                .filter_map(|i| {
                    let kind = sch.instances.kind[i];
                    if !kind.is_label() {
                        return None;
                    }
                    let dir = match kind {
                        DeviceKind::InputPin => PinDirection::Input,
                        DeviceKind::OutputPin => PinDirection::Output,
                        _ => PinDirection::InOut,
                    };
                    Some((
                        sch.instances.name[i],
                        sch.instances.x[i],
                        sch.instances.y[i],
                        dir,
                    ))
                })
                .collect()
        };

        if label_data.is_empty() {
            self.state.status_msg = "No I/O pins found in schematic".into();
            return;
        }

        self.push_undo_snapshot();

        // Bounding box from label positions with 40px padding.
        let mut lo_x = i32::MAX;
        let mut lo_y = i32::MAX;
        let mut hi_x = i32::MIN;
        let mut hi_y = i32::MIN;
        for &(_, x, y, _) in &label_data {
            lo_x = lo_x.min(x);
            lo_y = lo_y.min(y);
            hi_x = hi_x.max(x);
            hi_y = hi_y.max(y);
        }
        lo_x -= 40;
        lo_y -= 40;
        hi_x += 40;
        hi_y += 40;

        let doc = self.state.active_document_mut();

        // Replace existing pins.
        doc.schematic.pins.clear();
        doc.schematic.pins.reserve(label_data.len());
        for (i, &(name, x, y, dir)) in label_data.iter().enumerate() {
            doc.schematic.pins.push(Pin {
                name,
                x,
                y,
                number: i as u32,
                width: 1,
                direction: dir,
            });
        }

        // Add a bounding rectangle only if no symbol geometry exists yet.
        let has_geometry = !doc.schematic.lines.is_empty()
            || !doc.schematic.rects.is_empty()
            || !doc.schematic.circles.is_empty()
            || !doc.schematic.arcs.is_empty();
        if !has_geometry {
            doc.schematic.rects.push(Rect {
                x: lo_x,
                y: lo_y,
                width: hi_x - lo_x,
                height: hi_y - lo_y,
                fill: Color::NONE,
                stroke: Color::NONE,
                thickness: 15, // 1.5 in tenths
            });
        }

        doc.dirty = true;
        self.state.status_msg = format!("Symbol generated: {} pins", doc.schematic.pins.len());
    }
}

// ════════════════════════════════════════════════════════════
// Project config / library reload
// ════════════════════════════════════════════════════════════

impl App {
    pub fn set_project_dir(&mut self, path: PathBuf) {
        self.state.project_dir = path;
        self.reload_project_config();
    }

    /// (Re)load Config.toml from the project dir and resolve its PDK.
    pub fn reload_project_config(&mut self) {
        match ProjectConfig::load(&self.state.project_dir) {
            Ok(cfg) => self.state.config = cfg,
            Err(e) => {
                self.state.status_msg = format!("Config.toml error: {e}");
                return;
            }
        }
        self.state.pdk = None;
        if let Some(name) = self.state.config.pdk.clone() {
            match config::load_pdk(&name, self.state.config.pdk_path.as_deref()) {
                Ok(p) => {
                    self.state.status_msg = format!(
                        "PDK {}: {} cells, corners [{}]",
                        p.name,
                        p.cells.len(),
                        p.corners.join(", ")
                    );
                    self.state.pdk = Some(p);
                }
                Err(e) => self.state.status_msg = format!("PDK load failed: {e}"),
            }
        }
        self.reload_project_library();
    }

    /// Rebuild the library browser sections sourced from the project: PDK
    /// manifest cells, `.chn_prim` primitives, and `.chn` subcircuit symbols.
    /// Runtime prims are registered globally so rendering/connectivity resolve
    /// them by symbol name; sources are leaked (lifetime = program, a reload
    /// leaks a few KB).
    fn reload_project_library(&mut self) {
        let mut lib = LibraryIndex::default();
        let mut runtime: Vec<prim::PrimEntry> = Vec::new();
        let mut symbol_schematics: Vec<Schematic> = Vec::new();
        let mut testbenches: Vec<ProjectTestbench> = Vec::new();

        if let Some(p) = &self.state.pdk {
            lib.pdk_cells = p
                .cells
                .iter()
                .filter(|(k, _)| DeviceKind::from_name(k) != DeviceKind::Unknown)
                .map(|(k, c)| (k.clone(), c.model.clone()))
                .collect();
            lib.pdk_cells.sort();
        }

        // Project .chn_prim primitives (globbed by Config.toml paths).
        for path in self.state.config.paths.primitives.clone() {
            let Ok(content) = std::fs::read_to_string(&path) else {
                continue;
            };
            let src: &'static str = Box::leak(content.into_boxed_str());
            if let Some(entry) = prim::parse_chn_prim(src) {
                lib.project_prims.push(entry.kind_name.to_owned());
                runtime.push(entry);
            }
        }
        lib.project_prims.sort();

        // Project .chn schematics with pins become placeable subckt symbols.
        let chn_paths: Vec<PathBuf> = if self.state.config.paths.schematics.is_empty() {
            std::fs::read_dir(&self.state.project_dir)
                .map(|rd| {
                    rd.filter_map(|e| e.ok().map(|e| e.path()))
                        .filter(|p| p.extension().is_some_and(|e| e == "chn"))
                        .collect()
                })
                .unwrap_or_default()
        } else {
            self.state.config.paths.schematics.clone()
        };
        for path in chn_paths {
            let Ok(content) = std::fs::read_to_string(&path) else {
                continue;
            };
            let mut sch = prim::read_chn(&content, &mut self.state.interner);
            let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            // Testbenches are sim entry points, not instanceable cells —
            // cache them for the "used in" canvas overlay instead.
            if sch.stype == SchematicType::Testbench {
                sch.name = stem.to_owned();
                testbenches.push(ProjectTestbench {
                    name: stem.to_owned(),
                    path: path.clone(),
                    schematic: sch,
                });
                continue;
            }
            // A schematic without pins has no ports to connect.
            if sch.stype != SchematicType::Schematic || sch.pins.is_empty() {
                continue;
            }
            // Subckt def name must match the instance's symbol name.
            sch.name = stem.to_owned();
            let stem: &'static str = Box::leak(stem.to_owned().into_boxed_str());

            let pins: Vec<(&'static str, bool)> = sch
                .pins
                .iter()
                .map(|p| {
                    let name: &'static str = Box::leak(
                        self.state
                            .interner
                            .resolve(&p.name)
                            .to_owned()
                            .into_boxed_str(),
                    );
                    (name, p.direction == PinDirection::Input)
                })
                .collect();

            lib.project_symbols.push((stem.to_owned(), pins.len()));
            runtime.push(prim::box_symbol(stem, &pins));
            symbol_schematics.push(sch);
        }
        lib.project_symbols.sort();

        prim::register_runtime(runtime);

        // Instances referencing runtime symbols parse as Unknown when their
        // file was read before registration (cached children above, or
        // documents opened before the project dir was set). Re-derive.
        let fixup = |interner: &Rodeo, sch: &mut Schematic| {
            for i in 0..sch.instances.len() {
                if sch.instances.kind[i] == DeviceKind::Unknown {
                    let sym = interner.resolve(&sch.instances.symbol[i]);
                    if let Some(p) = prim::find_by_name(sym) {
                        sch.instances.kind[i] = p.kind;
                    }
                }
            }
        };
        for sch in &mut symbol_schematics {
            fixup(&self.state.interner, sch);
        }
        for tb in &mut testbenches {
            fixup(&self.state.interner, &mut tb.schematic);
        }
        for doc in &mut self.state.documents {
            fixup(&self.state.interner, &mut doc.schematic);
            doc.generation += 1;
        }

        self.state.library = lib;
        self.state.project_symbol_schematics = symbol_schematics;
        self.state.project_testbenches = testbenches;
    }

    /// Indices of project testbenches that instance `symbol`.
    pub fn testbenches_using(&self, symbol: &str) -> Vec<usize> {
        if symbol.is_empty() {
            return Vec::new();
        }
        self.state
            .project_testbenches
            .iter()
            .enumerate()
            .filter(|(_, tb)| {
                let insts = &tb.schematic.instances;
                (0..insts.len()).any(|i| self.state.interner.resolve(&insts.symbol[i]) == symbol)
            })
            .map(|(i, _)| i)
            .collect()
    }

    /// Open a cached project testbench as a document (canvas overlay click).
    pub fn open_project_testbench(&mut self, idx: usize) {
        let Some(path) = self
            .state
            .project_testbenches
            .get(idx)
            .map(|t| t.path.clone())
        else {
            return;
        };
        // Already open → just focus it.
        if let Some(di) = self.state.documents.iter().position(|d| match &d.origin {
            Origin::File(p) => *p == path,
            _ => false,
        }) {
            self.state.active_doc = di;
            return;
        }
        if let Err(e) = self.open_file(&path) {
            self.state.status_msg = format!("Failed to open {}: {e}", path.display());
        }
    }
}

// ════════════════════════════════════════════════════════════
// Object transforms — plain fns + match (replaces SchematicCollection)
// ════════════════════════════════════════════════════════════

/// Rotate (x, y) 90° around (cx, cy).
pub fn rot_point(x: i32, y: i32, cx: i32, cy: i32, clockwise: bool) -> (i32, i32) {
    if clockwise {
        (cy - y + cx, x - cx + cy)
    } else {
        (y - cy + cx, cx - x + cy)
    }
}

/// Mirror (x, y) across the vertical (horizontal=true) or horizontal axis
/// through (cx, cy).
pub fn mirror_point(x: i32, y: i32, cx: i32, cy: i32, horizontal: bool) -> (i32, i32) {
    if horizontal {
        (2 * cx - x, y)
    } else {
        (x, 2 * cy - y)
    }
}

pub fn snap(val: i32, grid: i32) -> i32 {
    if grid <= 0 {
        return val;
    }
    ((val as f64 / grid as f64).round() as i32) * grid
}

/// Extract an AoS copy of instance `i` from the SoA storage.
fn instance_at(sch: &Schematic, i: usize) -> Instance {
    let v = &sch.instances;
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

/// Extract an AoS copy of wire `i` from the SoA storage.
fn wire_at(sch: &Schematic, i: usize) -> Wire {
    let v = &sch.wires;
    Wire {
        net_name: v.net_name[i],
        x0: v.x0[i],
        y0: v.y0[i],
        x1: v.x1[i],
        y1: v.y1[i],
        color: v.color[i],
        thickness: v.thickness[i],
    }
}

pub fn translate_obj(sch: &mut Schematic, r: ObjectRef, dx: i32, dy: i32) {
    let i = r.index();
    match r {
        ObjectRef::Instance(_) => sch.translate_instance(i, dx, dy),
        ObjectRef::Wire(_) => sch.translate_wire(i, dx, dy),
        ObjectRef::Bus(_) => {
            if i < sch.buses.len() {
                sch.buses.x0[i] += dx;
                sch.buses.y0[i] += dy;
                sch.buses.x1[i] += dx;
                sch.buses.y1[i] += dy;
            }
        }
        ObjectRef::Line(_) => {
            if let Some(l) = sch.lines.get_mut(i) {
                l.x0 += dx;
                l.y0 += dy;
                l.x1 += dx;
                l.y1 += dy;
            }
        }
        ObjectRef::Rect(_) => {
            if let Some(rc) = sch.rects.get_mut(i) {
                rc.x += dx;
                rc.y += dy;
            }
        }
        ObjectRef::Circle(_) => {
            if let Some(c) = sch.circles.get_mut(i) {
                c.cx += dx;
                c.cy += dy;
            }
        }
        ObjectRef::Arc(_) => {
            if let Some(a) = sch.arcs.get_mut(i) {
                a.cx += dx;
                a.cy += dy;
            }
        }
        ObjectRef::Text(_) => {
            if let Some(t) = sch.texts.get_mut(i) {
                t.x += dx;
                t.y += dy;
            }
        }
        ObjectRef::Polygon(_) => {
            if let Some(p) = sch.polygons.get_mut(i) {
                for pt in &mut p.points {
                    pt[0] += dx;
                    pt[1] += dy;
                }
            }
        }
    }
}

pub fn snap_obj(sch: &mut Schematic, r: ObjectRef, grid: i32) {
    let i = r.index();
    match r {
        ObjectRef::Instance(_) => {
            if i < sch.instances.len() {
                sch.instances.x[i] = snap(sch.instances.x[i], grid);
                sch.instances.y[i] = snap(sch.instances.y[i], grid);
            }
        }
        ObjectRef::Wire(_) => {
            if i < sch.wires.len() {
                sch.wires.x0[i] = snap(sch.wires.x0[i], grid);
                sch.wires.y0[i] = snap(sch.wires.y0[i], grid);
                sch.wires.x1[i] = snap(sch.wires.x1[i], grid);
                sch.wires.y1[i] = snap(sch.wires.y1[i], grid);
            }
        }
        ObjectRef::Bus(_) => {
            if i < sch.buses.len() {
                sch.buses.x0[i] = snap(sch.buses.x0[i], grid);
                sch.buses.y0[i] = snap(sch.buses.y0[i], grid);
                sch.buses.x1[i] = snap(sch.buses.x1[i], grid);
                sch.buses.y1[i] = snap(sch.buses.y1[i], grid);
            }
        }
        ObjectRef::Line(_) => {
            if let Some(l) = sch.lines.get_mut(i) {
                l.x0 = snap(l.x0, grid);
                l.y0 = snap(l.y0, grid);
                l.x1 = snap(l.x1, grid);
                l.y1 = snap(l.y1, grid);
            }
        }
        ObjectRef::Rect(_) => {
            if let Some(rc) = sch.rects.get_mut(i) {
                rc.x = snap(rc.x, grid);
                rc.y = snap(rc.y, grid);
            }
        }
        ObjectRef::Circle(_) => {
            if let Some(c) = sch.circles.get_mut(i) {
                c.cx = snap(c.cx, grid);
                c.cy = snap(c.cy, grid);
            }
        }
        ObjectRef::Arc(_) => {
            if let Some(a) = sch.arcs.get_mut(i) {
                a.cx = snap(a.cx, grid);
                a.cy = snap(a.cy, grid);
            }
        }
        ObjectRef::Text(_) => {
            if let Some(t) = sch.texts.get_mut(i) {
                t.x = snap(t.x, grid);
                t.y = snap(t.y, grid);
            }
        }
        ObjectRef::Polygon(_) => {
            if let Some(p) = sch.polygons.get_mut(i) {
                for pt in &mut p.points {
                    pt[0] = snap(pt[0], grid);
                    pt[1] = snap(pt[1], grid);
                }
            }
        }
    }
}

pub fn rotate_obj(sch: &mut Schematic, r: ObjectRef, cx: i32, cy: i32, cw: bool) {
    let i = r.index();
    match r {
        ObjectRef::Instance(_) => {
            if i < sch.instances.len() {
                let flags = sch.instances.flags[i];
                let rot = if cw {
                    (flags.rotation() + 1) & 0x03
                } else {
                    (flags.rotation() + 3) & 0x03
                };
                sch.instances.flags[i] = InstanceFlags::new(rot, flags.flip());
                let (nx, ny) = rot_point(sch.instances.x[i], sch.instances.y[i], cx, cy, cw);
                sch.instances.x[i] = nx;
                sch.instances.y[i] = ny;
            }
        }
        ObjectRef::Wire(_) => {
            if i < sch.wires.len() {
                let (nx0, ny0) = rot_point(sch.wires.x0[i], sch.wires.y0[i], cx, cy, cw);
                let (nx1, ny1) = rot_point(sch.wires.x1[i], sch.wires.y1[i], cx, cy, cw);
                (sch.wires.x0[i], sch.wires.y0[i]) = (nx0, ny0);
                (sch.wires.x1[i], sch.wires.y1[i]) = (nx1, ny1);
            }
        }
        ObjectRef::Bus(_) => {
            if i < sch.buses.len() {
                let (nx0, ny0) = rot_point(sch.buses.x0[i], sch.buses.y0[i], cx, cy, cw);
                let (nx1, ny1) = rot_point(sch.buses.x1[i], sch.buses.y1[i], cx, cy, cw);
                (sch.buses.x0[i], sch.buses.y0[i]) = (nx0, ny0);
                (sch.buses.x1[i], sch.buses.y1[i]) = (nx1, ny1);
            }
        }
        ObjectRef::Line(_) => {
            if let Some(l) = sch.lines.get_mut(i) {
                let (nx0, ny0) = rot_point(l.x0, l.y0, cx, cy, cw);
                let (nx1, ny1) = rot_point(l.x1, l.y1, cx, cy, cw);
                (l.x0, l.y0, l.x1, l.y1) = (nx0, ny0, nx1, ny1);
            }
        }
        ObjectRef::Rect(_) => {
            if let Some(rc) = sch.rects.get_mut(i) {
                let (x0, y0) = rot_point(rc.x, rc.y, cx, cy, cw);
                let (x1, y1) = rot_point(rc.x + rc.width, rc.y + rc.height, cx, cy, cw);
                rc.x = x0.min(x1);
                rc.y = y0.min(y1);
                rc.width = (x1 - x0).abs();
                rc.height = (y1 - y0).abs();
            }
        }
        ObjectRef::Circle(_) => {
            if let Some(c) = sch.circles.get_mut(i) {
                (c.cx, c.cy) = rot_point(c.cx, c.cy, cx, cy, cw);
            }
        }
        ObjectRef::Arc(_) => {
            if let Some(a) = sch.arcs.get_mut(i) {
                (a.cx, a.cy) = rot_point(a.cx, a.cy, cx, cy, cw);
                let delta = if cw {
                    -std::f32::consts::FRAC_PI_2
                } else {
                    std::f32::consts::FRAC_PI_2
                };
                a.start_angle += delta;
            }
        }
        ObjectRef::Text(_) => {
            if let Some(t) = sch.texts.get_mut(i) {
                (t.x, t.y) = rot_point(t.x, t.y, cx, cy, cw);
                let delta: u8 = if cw { 1 } else { 3 };
                t.rotation = (t.rotation + delta) & 0x03;
            }
        }
        ObjectRef::Polygon(_) => {
            if let Some(p) = sch.polygons.get_mut(i) {
                for pt in &mut p.points {
                    let (nx, ny) = rot_point(pt[0], pt[1], cx, cy, cw);
                    pt[0] = nx;
                    pt[1] = ny;
                }
            }
        }
    }
}

pub fn flip_obj(sch: &mut Schematic, r: ObjectRef, cx: i32, cy: i32, horizontal: bool) {
    let i = r.index();
    match r {
        ObjectRef::Instance(_) => {
            if i < sch.instances.len() {
                let flags = sch.instances.flags[i];
                sch.instances.flags[i] = if horizontal {
                    InstanceFlags::new(flags.rotation(), !flags.flip())
                } else {
                    InstanceFlags::new((flags.rotation() + 2) & 0x03, !flags.flip())
                };
                let (nx, ny) =
                    mirror_point(sch.instances.x[i], sch.instances.y[i], cx, cy, horizontal);
                sch.instances.x[i] = nx;
                sch.instances.y[i] = ny;
            }
        }
        ObjectRef::Wire(_) => {
            if i < sch.wires.len() {
                let (nx0, ny0) = mirror_point(sch.wires.x0[i], sch.wires.y0[i], cx, cy, horizontal);
                let (nx1, ny1) = mirror_point(sch.wires.x1[i], sch.wires.y1[i], cx, cy, horizontal);
                (sch.wires.x0[i], sch.wires.y0[i]) = (nx0, ny0);
                (sch.wires.x1[i], sch.wires.y1[i]) = (nx1, ny1);
            }
        }
        ObjectRef::Bus(_) => {
            if i < sch.buses.len() {
                let (nx0, ny0) = mirror_point(sch.buses.x0[i], sch.buses.y0[i], cx, cy, horizontal);
                let (nx1, ny1) = mirror_point(sch.buses.x1[i], sch.buses.y1[i], cx, cy, horizontal);
                (sch.buses.x0[i], sch.buses.y0[i]) = (nx0, ny0);
                (sch.buses.x1[i], sch.buses.y1[i]) = (nx1, ny1);
            }
        }
        ObjectRef::Line(_) => {
            if let Some(l) = sch.lines.get_mut(i) {
                let (nx0, ny0) = mirror_point(l.x0, l.y0, cx, cy, horizontal);
                let (nx1, ny1) = mirror_point(l.x1, l.y1, cx, cy, horizontal);
                (l.x0, l.y0, l.x1, l.y1) = (nx0, ny0, nx1, ny1);
            }
        }
        ObjectRef::Rect(_) => {
            if let Some(rc) = sch.rects.get_mut(i) {
                let (x0, y0) = mirror_point(rc.x, rc.y, cx, cy, horizontal);
                let (x1, y1) = mirror_point(rc.x + rc.width, rc.y + rc.height, cx, cy, horizontal);
                rc.x = x0.min(x1);
                rc.y = y0.min(y1);
                rc.width = (x1 - x0).abs();
                rc.height = (y1 - y0).abs();
            }
        }
        ObjectRef::Circle(_) => {
            if let Some(c) = sch.circles.get_mut(i) {
                (c.cx, c.cy) = mirror_point(c.cx, c.cy, cx, cy, horizontal);
            }
        }
        ObjectRef::Arc(_) => {
            if let Some(a) = sch.arcs.get_mut(i) {
                (a.cx, a.cy) = mirror_point(a.cx, a.cy, cx, cy, horizontal);
                if horizontal {
                    a.start_angle = std::f32::consts::PI - a.start_angle - a.sweep_angle;
                } else {
                    a.start_angle = -a.start_angle - a.sweep_angle;
                }
            }
        }
        ObjectRef::Text(_) => {
            if let Some(t) = sch.texts.get_mut(i) {
                (t.x, t.y) = mirror_point(t.x, t.y, cx, cy, horizontal);
            }
        }
        ObjectRef::Polygon(_) => {
            if let Some(p) = sch.polygons.get_mut(i) {
                for pt in &mut p.points {
                    let (nx, ny) = mirror_point(pt[0], pt[1], cx, cy, horizontal);
                    pt[0] = nx;
                    pt[1] = ny;
                }
            }
        }
    }
}

/// Representative point of an object (for centroid computation).
/// `None` if the index is out of range.
fn centroid_obj(sch: &Schematic, r: ObjectRef) -> Option<(i64, i64)> {
    let i = r.index();
    match r {
        ObjectRef::Instance(_) => (i < sch.instances.len())
            .then(|| (sch.instances.x[i] as i64, sch.instances.y[i] as i64)),
        ObjectRef::Wire(_) => (i < sch.wires.len()).then(|| {
            (
                (sch.wires.x0[i] as i64 + sch.wires.x1[i] as i64) / 2,
                (sch.wires.y0[i] as i64 + sch.wires.y1[i] as i64) / 2,
            )
        }),
        ObjectRef::Bus(_) => (i < sch.buses.len()).then(|| {
            (
                (sch.buses.x0[i] as i64 + sch.buses.x1[i] as i64) / 2,
                (sch.buses.y0[i] as i64 + sch.buses.y1[i] as i64) / 2,
            )
        }),
        ObjectRef::Line(_) => sch.lines.get(i).map(|l| {
            (
                (l.x0 as i64 + l.x1 as i64) / 2,
                (l.y0 as i64 + l.y1 as i64) / 2,
            )
        }),
        ObjectRef::Rect(_) => sch.rects.get(i).map(|rc| {
            (
                rc.x as i64 + rc.width as i64 / 2,
                rc.y as i64 + rc.height as i64 / 2,
            )
        }),
        ObjectRef::Circle(_) => sch.circles.get(i).map(|c| (c.cx as i64, c.cy as i64)),
        ObjectRef::Arc(_) => sch.arcs.get(i).map(|a| (a.cx as i64, a.cy as i64)),
        ObjectRef::Text(_) => sch.texts.get(i).map(|t| (t.x as i64, t.y as i64)),
        ObjectRef::Polygon(_) => sch
            .polygons
            .get(i)
            .and_then(|p| p.points.first())
            .map(|pt| (pt[0] as i64, pt[1] as i64)),
    }
}

pub fn centroid_of_selection(sch: &Schematic, sel: &Selection) -> Option<(i32, i32)> {
    let mut sum = (0i64, 0i64, 0i64);
    for &r in &sel.objs {
        if let Some((x, y)) = centroid_obj(sch, r) {
            sum.0 += x;
            sum.1 += y;
            sum.2 += 1;
        }
    }
    (sum.2 > 0).then(|| ((sum.0 / sum.2) as i32, (sum.1 / sum.2) as i32))
}

fn centroid_of_clipboard(clip: &Clipboard) -> Option<(i32, i32)> {
    let mut sum = (0i64, 0i64, 0i64);
    let mut add = |x: i64, y: i64| {
        sum.0 += x;
        sum.1 += y;
        sum.2 += 1;
    };
    for it in &clip.instances {
        add(it.x as i64, it.y as i64);
    }
    for it in &clip.wires {
        add(
            (it.x0 as i64 + it.x1 as i64) / 2,
            (it.y0 as i64 + it.y1 as i64) / 2,
        );
    }
    for it in &clip.lines {
        add(
            (it.x0 as i64 + it.x1 as i64) / 2,
            (it.y0 as i64 + it.y1 as i64) / 2,
        );
    }
    for it in &clip.rects {
        add(
            it.x as i64 + it.width as i64 / 2,
            it.y as i64 + it.height as i64 / 2,
        );
    }
    for it in &clip.circles {
        add(it.cx as i64, it.cy as i64);
    }
    for it in &clip.arcs {
        add(it.cx as i64, it.cy as i64);
    }
    for it in &clip.texts {
        add(it.x as i64, it.y as i64);
    }
    for it in &clip.polygons {
        if let Some(pt) = it.points.first() {
            add(pt[0] as i64, pt[1] as i64);
        }
    }
    (sum.2 > 0).then(|| ((sum.0 / sum.2) as i32, (sum.1 / sum.2) as i32))
}

/// Whole-schematic bounding box (used by zoom-fit).
pub fn compute_bounds(sch: &Schematic) -> Option<(i32, i32, i32, i32)> {
    let mut min_x = i32::MAX;
    let mut min_y = i32::MAX;
    let mut max_x = i32::MIN;
    let mut max_y = i32::MIN;
    let mut any = false;
    let mut add = |x: i32, y: i32| {
        any = true;
        min_x = min_x.min(x);
        min_y = min_y.min(y);
        max_x = max_x.max(x);
        max_y = max_y.max(y);
    };
    for i in 0..sch.instances.len() {
        add(sch.instances.x[i], sch.instances.y[i]);
    }
    for i in 0..sch.wires.len() {
        add(sch.wires.x0[i], sch.wires.y0[i]);
        add(sch.wires.x1[i], sch.wires.y1[i]);
    }
    for i in 0..sch.buses.len() {
        add(sch.buses.x0[i], sch.buses.y0[i]);
        add(sch.buses.x1[i], sch.buses.y1[i]);
    }
    for l in &sch.lines {
        add(l.x0, l.y0);
        add(l.x1, l.y1);
    }
    for r in &sch.rects {
        add(r.x, r.y);
        add(r.x + r.width, r.y + r.height);
    }
    for c in &sch.circles {
        add(c.cx - c.radius, c.cy - c.radius);
        add(c.cx + c.radius, c.cy + c.radius);
    }
    for a in &sch.arcs {
        add(a.cx - a.radius, a.cy - a.radius);
        add(a.cx + a.radius, a.cy + a.radius);
    }
    for t in &sch.texts {
        add(t.x, t.y);
    }
    for p in &sch.polygons {
        for pt in &p.points {
            add(pt[0], pt[1]);
        }
    }
    any.then_some((min_x, min_y, max_x, max_y))
}

/// Remove a bus, deleting its rippers and re-pointing rippers of later buses.
fn remove_bus(sch: &mut Schematic, idx: usize) {
    sch.buses.remove(idx);
    let idx32 = idx as u32;
    sch.bus_rippers.retain(|r| r.bus_idx != idx32);
    for r in &mut sch.bus_rippers {
        if r.bus_idx > idx32 {
            r.bus_idx -= 1;
        }
    }
}

/// Remove every selected object, per kind in descending index order so
/// earlier removals don't shift later ones.
fn remove_selected_objects(sch: &mut Schematic, sel: &Selection) {
    let mut instances: Vec<usize> = Vec::new();
    let mut wires: Vec<usize> = Vec::new();
    let mut buses: Vec<usize> = Vec::new();
    let mut lines: Vec<usize> = Vec::new();
    let mut rects: Vec<usize> = Vec::new();
    let mut circles: Vec<usize> = Vec::new();
    let mut arcs: Vec<usize> = Vec::new();
    let mut texts: Vec<usize> = Vec::new();
    let mut polygons: Vec<usize> = Vec::new();
    for &r in &sel.objs {
        let i = r.index();
        match r {
            ObjectRef::Instance(_) => instances.push(i),
            ObjectRef::Wire(_) => wires.push(i),
            ObjectRef::Bus(_) => buses.push(i),
            ObjectRef::Line(_) => lines.push(i),
            ObjectRef::Rect(_) => rects.push(i),
            ObjectRef::Circle(_) => circles.push(i),
            ObjectRef::Arc(_) => arcs.push(i),
            ObjectRef::Text(_) => texts.push(i),
            ObjectRef::Polygon(_) => polygons.push(i),
        }
    }
    let desc = |v: &mut Vec<usize>| v.sort_unstable_by(|a, b| b.cmp(a));

    desc(&mut instances);
    for i in instances {
        if i < sch.instances.len() {
            sch.instances.remove(i);
        }
    }
    desc(&mut wires);
    for i in wires {
        if i < sch.wires.len() {
            sch.wires.remove(i);
        }
    }
    desc(&mut buses);
    for i in buses {
        if i < sch.buses.len() {
            remove_bus(sch, i);
        }
    }
    desc(&mut lines);
    for i in lines {
        if i < sch.lines.len() {
            sch.lines.remove(i);
        }
    }
    desc(&mut rects);
    for i in rects {
        if i < sch.rects.len() {
            sch.rects.remove(i);
        }
    }
    desc(&mut circles);
    for i in circles {
        if i < sch.circles.len() {
            sch.circles.remove(i);
        }
    }
    desc(&mut arcs);
    for i in arcs {
        if i < sch.arcs.len() {
            sch.arcs.remove(i);
        }
    }
    desc(&mut texts);
    for i in texts {
        if i < sch.texts.len() {
            sch.texts.remove(i);
        }
    }
    desc(&mut polygons);
    for i in polygons {
        if i < sch.polygons.len() {
            sch.polygons.remove(i);
        }
    }
}

// ════════════════════════════════════════════════════════════
// Hit testing & canvas geometry
// ════════════════════════════════════════════════════════════

pub const SELECT_HIT_RADIUS_SQ: f64 = 400.0;
const HIT_TOL: f64 = 20.0; // sqrt of SELECT_HIT_RADIUS_SQ

/// Squared distance from point (px,py) to line segment (ax,ay)-(bx,by).
pub fn point_to_segment_dist_sq(px: f64, py: f64, ax: f64, ay: f64, bx: f64, by: f64) -> f64 {
    let abx = bx - ax;
    let aby = by - ay;
    let len2 = abx * abx + aby * aby;
    if len2 <= 0.0 {
        let dx = px - ax;
        let dy = py - ay;
        return dx * dx + dy * dy;
    }
    let t = (((px - ax) * abx + (py - ay) * aby) / len2).clamp(0.0, 1.0);
    let dx = px - (ax + t * abx);
    let dy = py - (ay + t * aby);
    dx * dx + dy * dy
}

/// Normalize an angle (in radians) into [0, 2π).
fn normalize_angle(a: f64) -> f64 {
    let twopi = std::f64::consts::TAU;
    ((a % twopi) + twopi) % twopi
}

/// Check if angle `a` falls within the arc from `start` sweeping `sweep` radians.
fn angle_in_arc(a: f64, start: f64, sweep: f64) -> bool {
    if sweep.abs() >= std::f64::consts::TAU {
        return true; // full circle
    }
    let a = normalize_angle(a - start);
    if sweep >= 0.0 {
        a <= sweep
    } else {
        // Negative sweep: arc goes clockwise
        normalize_angle(-a) <= normalize_angle(-sweep)
    }
}

/// Ray-cast point-in-polygon test.
fn point_in_polygon(px: f64, py: f64, pts: &[[i32; 2]]) -> bool {
    let n = pts.len();
    if n < 3 {
        return false;
    }
    let mut inside = false;
    let mut j = n - 1;
    for i in 0..n {
        let (yi, yj) = (pts[i][1] as f64, pts[j][1] as f64);
        let (xi, xj) = (pts[i][0] as f64, pts[j][0] as f64);
        if ((yi > py) != (yj > py)) && (px < (xj - xi) * (py - yi) / (yj - yi) + xi) {
            inside = !inside;
        }
        j = i;
    }
    inside
}

impl App {
    pub fn hit_test_instance(&self, wx: i32, wy: i32) -> Option<usize> {
        let insts = &self.schematic().instances;
        for i in 0..insts.len() {
            let dx = wx as f64 - insts.x[i] as f64;
            let dy = wy as f64 - insts.y[i] as f64;

            let entry =
                prim::find_symbol(self.state.interner.resolve(&insts.symbol[i]), insts.kind[i]);
            let tol_sq = if let Some(entry) = entry {
                let mut max_ext: f64 = 14.0;
                for seg in &entry.segments {
                    max_ext = max_ext
                        .max(seg.x0.unsigned_abs() as f64)
                        .max(seg.y0.unsigned_abs() as f64)
                        .max(seg.x1.unsigned_abs() as f64)
                        .max(seg.y1.unsigned_abs() as f64);
                }
                for pp in &entry.pin_positions {
                    max_ext = max_ext
                        .max(pp.x.unsigned_abs() as f64)
                        .max(pp.y.unsigned_abs() as f64);
                }
                (max_ext + 5.0) * (max_ext + 5.0)
            } else {
                25.0 * 25.0
            };

            if dx * dx + dy * dy < tol_sq {
                return Some(i);
            }
        }
        None
    }

    pub fn hit_test_wire(&self, wx: i32, wy: i32, tol_sq: f64) -> Option<usize> {
        let wires = &self.schematic().wires;
        let (wpx, wpy) = (wx as f64, wy as f64);
        (0..wires.len()).find(|&i| {
            point_to_segment_dist_sq(
                wpx,
                wpy,
                wires.x0[i] as f64,
                wires.y0[i] as f64,
                wires.x1[i] as f64,
                wires.y1[i] as f64,
            ) < tol_sq
        })
    }

    pub fn hit_test_bus(&self, wx: i32, wy: i32, tol_sq: f64) -> Option<usize> {
        let buses = &self.schematic().buses;
        let (wpx, wpy) = (wx as f64, wy as f64);
        (0..buses.len()).find(|&i| {
            point_to_segment_dist_sq(
                wpx,
                wpy,
                buses.x0[i] as f64,
                buses.y0[i] as f64,
                buses.x1[i] as f64,
                buses.y1[i] as f64,
            ) < tol_sq
        })
    }

    pub fn hit_test_bus_ripper(&self, wx: i32, wy: i32) -> Option<usize> {
        self.schematic().bus_rippers.iter().position(|r| {
            let dx = (wx - r.x) as f64;
            let dy = (wy - r.y) as f64;
            dx * dx + dy * dy < SELECT_HIT_RADIUS_SQ
        })
    }

    pub fn hit_test_line(&self, wx: i32, wy: i32) -> Option<usize> {
        let (wpx, wpy) = (wx as f64, wy as f64);
        self.schematic().lines.iter().position(|l| {
            point_to_segment_dist_sq(wpx, wpy, l.x0 as f64, l.y0 as f64, l.x1 as f64, l.y1 as f64)
                < SELECT_HIT_RADIUS_SQ
        })
    }

    pub fn hit_test_rect(&self, wx: i32, wy: i32) -> Option<usize> {
        let tol = HIT_TOL as i32;
        self.schematic().rects.iter().position(|r| {
            wx >= r.x - tol
                && wx <= r.x + r.width + tol
                && wy >= r.y - tol
                && wy <= r.y + r.height + tol
        })
    }

    pub fn hit_test_circle(&self, wx: i32, wy: i32) -> Option<usize> {
        self.schematic().circles.iter().position(|c| {
            let dx = wx as f64 - c.cx as f64;
            let dy = wy as f64 - c.cy as f64;
            let dist = (dx * dx + dy * dy).sqrt();
            let radius = c.radius as f64;
            // Hit if inside (for filled) or near the stroke.
            (c.fill != Color::NONE && dist <= radius + HIT_TOL) || (dist - radius).abs() < HIT_TOL
        })
    }

    pub fn hit_test_arc(&self, wx: i32, wy: i32) -> Option<usize> {
        self.schematic().arcs.iter().position(|a| {
            let dx = wx as f64 - a.cx as f64;
            let dy = wy as f64 - a.cy as f64;
            let dist = (dx * dx + dy * dy).sqrt();
            if (dist - a.radius as f64).abs() >= HIT_TOL {
                return false;
            }
            angle_in_arc(dy.atan2(dx), a.start_angle as f64, a.sweep_angle as f64)
        })
    }

    pub fn hit_test_text(&self, wx: i32, wy: i32) -> Option<usize> {
        let tol = HIT_TOL as i32;
        for (i, t) in self.schematic().texts.iter().enumerate() {
            let content = self.resolve(t.content);
            let approx_w = (content.len() as f32 * t.font_size * 0.6) as i32;
            let approx_h = t.font_size as i32;
            if wx >= t.x - tol
                && wx <= t.x + approx_w + tol
                && wy >= t.y - tol
                && wy <= t.y + approx_h + tol
            {
                return Some(i);
            }
        }
        None
    }

    pub fn hit_test_polygon(&self, wx: i32, wy: i32) -> Option<usize> {
        let (wpx, wpy) = (wx as f64, wy as f64);
        for (i, p) in self.schematic().polygons.iter().enumerate() {
            if p.points.len() < 2 {
                continue;
            }
            // Edge proximity
            for win in p.points.windows(2) {
                let d2 = point_to_segment_dist_sq(
                    wpx,
                    wpy,
                    win[0][0] as f64,
                    win[0][1] as f64,
                    win[1][0] as f64,
                    win[1][1] as f64,
                );
                if d2 < SELECT_HIT_RADIUS_SQ {
                    return Some(i);
                }
            }
            // Closing edge + interior (filled)
            if p.points.len() >= 3 {
                let first = p.points.first().unwrap();
                let last = p.points.last().unwrap();
                let d2 = point_to_segment_dist_sq(
                    wpx,
                    wpy,
                    last[0] as f64,
                    last[1] as f64,
                    first[0] as f64,
                    first[1] as f64,
                );
                if d2 < SELECT_HIT_RADIUS_SQ {
                    return Some(i);
                }
                if p.fill != Color::NONE && point_in_polygon(wpx, wpy, &p.points) {
                    return Some(i);
                }
            }
        }
        None
    }

    /// Combined hit test: tries all types in priority order.
    pub fn hit_test(&self, wx: i32, wy: i32) -> Option<ObjectRef> {
        if let Some(i) = self.hit_test_instance(wx, wy) {
            return Some(ObjectRef::Instance(i as u32));
        }
        if let Some(i) = self.hit_test_wire(wx, wy, SELECT_HIT_RADIUS_SQ) {
            return Some(ObjectRef::Wire(i as u32));
        }
        if let Some(i) = self.hit_test_rect(wx, wy) {
            return Some(ObjectRef::Rect(i as u32));
        }
        if let Some(i) = self.hit_test_circle(wx, wy) {
            return Some(ObjectRef::Circle(i as u32));
        }
        if let Some(i) = self.hit_test_arc(wx, wy) {
            return Some(ObjectRef::Arc(i as u32));
        }
        if let Some(i) = self.hit_test_line(wx, wy) {
            return Some(ObjectRef::Line(i as u32));
        }
        if let Some(i) = self.hit_test_text(wx, wy) {
            return Some(ObjectRef::Text(i as u32));
        }
        if let Some(i) = self.hit_test_polygon(wx, wy) {
            return Some(ObjectRef::Polygon(i as u32));
        }
        None
    }

    /// Select all objects fully contained in the given rectangle.
    pub fn select_in_rect(&mut self, min_x: i32, min_y: i32, max_x: i32, max_y: i32) {
        let doc = self.state.active_document_mut();
        let sch = &doc.schematic;
        let mut objs: Vec<ObjectRef> = Vec::new();

        let in_rect = |x: i32, y: i32| x >= min_x && x <= max_x && y >= min_y && y <= max_y;

        for i in 0..sch.instances.len() {
            if in_rect(sch.instances.x[i], sch.instances.y[i]) {
                objs.push(ObjectRef::Instance(i as u32));
            }
        }
        for i in 0..sch.wires.len() {
            if in_rect(sch.wires.x0[i], sch.wires.y0[i])
                && in_rect(sch.wires.x1[i], sch.wires.y1[i])
            {
                objs.push(ObjectRef::Wire(i as u32));
            }
        }
        for i in 0..sch.buses.len() {
            if in_rect(sch.buses.x0[i], sch.buses.y0[i])
                && in_rect(sch.buses.x1[i], sch.buses.y1[i])
            {
                objs.push(ObjectRef::Bus(i as u32));
            }
        }
        for (i, l) in sch.lines.iter().enumerate() {
            if in_rect(l.x0, l.y0) && in_rect(l.x1, l.y1) {
                objs.push(ObjectRef::Line(i as u32));
            }
        }
        for (i, r) in sch.rects.iter().enumerate() {
            if in_rect(r.x, r.y) && in_rect(r.x + r.width, r.y + r.height) {
                objs.push(ObjectRef::Rect(i as u32));
            }
        }
        for (i, c) in sch.circles.iter().enumerate() {
            if in_rect(c.cx - c.radius, c.cy - c.radius)
                && in_rect(c.cx + c.radius, c.cy + c.radius)
            {
                objs.push(ObjectRef::Circle(i as u32));
            }
        }
        for (i, a) in sch.arcs.iter().enumerate() {
            if in_rect(a.cx - a.radius, a.cy - a.radius)
                && in_rect(a.cx + a.radius, a.cy + a.radius)
            {
                objs.push(ObjectRef::Arc(i as u32));
            }
        }
        for (i, t) in sch.texts.iter().enumerate() {
            if in_rect(t.x, t.y) {
                objs.push(ObjectRef::Text(i as u32));
            }
        }
        for (i, p) in sch.polygons.iter().enumerate() {
            if !p.points.is_empty() && p.points.iter().all(|pt| in_rect(pt[0], pt[1])) {
                objs.push(ObjectRef::Polygon(i as u32));
            }
        }

        doc.selection.objs = objs;
    }

    /// Manhattan routing helper: pick the corner of the L-route.
    pub fn manhattan_route(&self, start: [i32; 2], end: [i32; 2]) -> [i32; 2] {
        let dx = end[0] - start[0];
        let dy = end[1] - start[1];
        if dx.unsigned_abs() >= dy.unsigned_abs() {
            [end[0], start[1]]
        } else {
            [start[0], end[1]]
        }
    }
}

// ════════════════════════════════════════════════════════════
// Spatial index — uniform grid for viewport culling
// ════════════════════════════════════════════════════════════

/// Side length (in schematic units) of each spatial grid cell.
const CELL_SIZE: i32 = 200;

/// Uniform-grid spatial index over schematic objects. Each object is
/// inserted into every cell its AABB overlaps; a viewport query collects
/// entries from the touched cells, deduplicating via a hash set.
pub struct SpatialIndex {
    cells: FxHashMap<(i32, i32), Vec<ObjectRef>>,
}

impl SpatialIndex {
    /// Build a fresh spatial index from the given schematic.
    pub fn rebuild(sch: &Schematic) -> Self {
        let mut cells: FxHashMap<(i32, i32), Vec<ObjectRef>> = FxHashMap::default();

        for i in 0..sch.instances.len() {
            let (x, y) = (sch.instances.x[i], sch.instances.y[i]);
            let half = instance_half_extent(sch.instances.kind[i]);
            insert_aabb(
                &mut cells,
                ObjectRef::Instance(i as u32),
                x - half,
                y - half,
                x + half,
                y + half,
            );
        }
        for i in 0..sch.wires.len() {
            let (x0, y0, x1, y1) = (
                sch.wires.x0[i],
                sch.wires.y0[i],
                sch.wires.x1[i],
                sch.wires.y1[i],
            );
            insert_aabb(
                &mut cells,
                ObjectRef::Wire(i as u32),
                x0.min(x1),
                y0.min(y1),
                x0.max(x1),
                y0.max(y1),
            );
        }
        for i in 0..sch.buses.len() {
            let (x0, y0, x1, y1) = (
                sch.buses.x0[i],
                sch.buses.y0[i],
                sch.buses.x1[i],
                sch.buses.y1[i],
            );
            insert_aabb(
                &mut cells,
                ObjectRef::Bus(i as u32),
                x0.min(x1),
                y0.min(y1),
                x0.max(x1),
                y0.max(y1),
            );
        }
        for (i, l) in sch.lines.iter().enumerate() {
            insert_aabb(
                &mut cells,
                ObjectRef::Line(i as u32),
                l.x0.min(l.x1),
                l.y0.min(l.y1),
                l.x0.max(l.x1),
                l.y0.max(l.y1),
            );
        }
        for (i, r) in sch.rects.iter().enumerate() {
            insert_aabb(
                &mut cells,
                ObjectRef::Rect(i as u32),
                r.x,
                r.y,
                r.x + r.width,
                r.y + r.height,
            );
        }
        for (i, c) in sch.circles.iter().enumerate() {
            insert_aabb(
                &mut cells,
                ObjectRef::Circle(i as u32),
                c.cx - c.radius,
                c.cy - c.radius,
                c.cx + c.radius,
                c.cy + c.radius,
            );
        }
        for (i, a) in sch.arcs.iter().enumerate() {
            // Conservative AABB: full circle bounding box.
            insert_aabb(
                &mut cells,
                ObjectRef::Arc(i as u32),
                a.cx - a.radius,
                a.cy - a.radius,
                a.cx + a.radius,
                a.cy + a.radius,
            );
        }
        for (i, t) in sch.texts.iter().enumerate() {
            // Approximate extents; precise glyph metrics are unavailable here.
            let approx_w = (10.0 * t.font_size * 0.6) as i32;
            let approx_h = t.font_size as i32;
            insert_aabb(
                &mut cells,
                ObjectRef::Text(i as u32),
                t.x,
                t.y,
                t.x + approx_w,
                t.y + approx_h,
            );
        }
        for (i, p) in sch.polygons.iter().enumerate() {
            if p.points.is_empty() {
                continue;
            }
            let mut min_x = i32::MAX;
            let mut min_y = i32::MAX;
            let mut max_x = i32::MIN;
            let mut max_y = i32::MIN;
            for pt in &p.points {
                min_x = min_x.min(pt[0]);
                min_y = min_y.min(pt[1]);
                max_x = max_x.max(pt[0]);
                max_y = max_y.max(pt[1]);
            }
            insert_aabb(
                &mut cells,
                ObjectRef::Polygon(i as u32),
                min_x,
                min_y,
                max_x,
                max_y,
            );
        }

        Self { cells }
    }

    /// All entries whose cells overlap the query rectangle (deduplicated).
    /// Convenience wrapper; hot paths should reuse buffers with
    /// [`SpatialIndex::query_rect_into`].
    pub fn query_rect(&self, min_x: i32, min_y: i32, max_x: i32, max_y: i32) -> Vec<ObjectRef> {
        let mut out = Vec::new();
        let mut seen = FxHashSet::default();
        self.query_rect_into(min_x, min_y, max_x, max_y, &mut out, &mut seen);
        out
    }

    /// Allocation-free variant: both buffers are cleared (capacity retained)
    /// before use, so steady-state queries do not reallocate.
    pub fn query_rect_into(
        &self,
        min_x: i32,
        min_y: i32,
        max_x: i32,
        max_y: i32,
        out: &mut Vec<ObjectRef>,
        seen: &mut FxHashSet<ObjectRef>,
    ) {
        out.clear();
        seen.clear();

        let cx0 = cell_coord(min_x);
        let cy0 = cell_coord(min_y);
        let cx1 = cell_coord(max_x);
        let cy1 = cell_coord(max_y);

        for cy in cy0..=cy1 {
            for cx in cx0..=cx1 {
                if let Some(bucket) = self.cells.get(&(cx, cy)) {
                    out.reserve(bucket.len());
                    seen.reserve(bucket.len());
                    for entry in bucket {
                        if seen.insert(*entry) {
                            out.push(*entry);
                        }
                    }
                }
            }
        }
    }
}

/// Map a world coordinate to a cell index.
#[inline]
fn cell_coord(v: i32) -> i32 {
    v.div_euclid(CELL_SIZE)
}

/// Insert `entry` into every cell that the AABB overlaps.
fn insert_aabb(
    cells: &mut FxHashMap<(i32, i32), Vec<ObjectRef>>,
    entry: ObjectRef,
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,
) {
    let cx0 = cell_coord(min_x);
    let cy0 = cell_coord(min_y);
    let cx1 = cell_coord(max_x);
    let cy1 = cell_coord(max_y);
    for cy in cy0..=cy1 {
        for cx in cx0..=cx1 {
            cells.entry((cx, cy)).or_default().push(entry);
        }
    }
}

/// Conservative half-extent of an instance from its primitive geometry.
/// Falls back to 30 units when no primitive data is available.
fn instance_half_extent(kind: DeviceKind) -> i32 {
    let Some(entry) = prim::find_by_kind(kind) else {
        return 30;
    };
    let mut max_ext: i32 = 14;
    for seg in &entry.segments {
        max_ext = max_ext
            .max(seg.x0.unsigned_abs() as i32)
            .max(seg.y0.unsigned_abs() as i32)
            .max(seg.x1.unsigned_abs() as i32)
            .max(seg.y1.unsigned_abs() as i32);
    }
    for pp in &entry.pin_positions {
        max_ext = max_ext
            .max(pp.x.unsigned_abs() as i32)
            .max(pp.y.unsigned_abs() as i32);
    }
    for c in &entry.circles {
        max_ext = max_ext.max((c.cx.unsigned_abs() + c.r.unsigned_abs()) as i32);
        max_ext = max_ext.max((c.cy.unsigned_abs() + c.r.unsigned_abs()) as i32);
    }
    for a in &entry.arcs {
        max_ext = max_ext.max((a.cx.unsigned_abs() + a.r.unsigned_abs()) as i32);
        max_ext = max_ext.max((a.cy.unsigned_abs() + a.r.unsigned_abs()) as i32);
    }
    for r in &entry.rects {
        max_ext = max_ext
            .max(r.x0.unsigned_abs() as i32)
            .max(r.y0.unsigned_abs() as i32)
            .max(r.x1.unsigned_abs() as i32)
            .max(r.y1.unsigned_abs() as i32);
    }
    // Small padding for label offsets / stroke.
    max_ext + 5
}

// ════════════════════════════════════════════════════════════
// Connectivity resolution — pure function over schematic data
// ════════════════════════════════════════════════════════════

/// Resolve connectivity from schematic data: nets, point-to-net map,
/// per-instance pin connections, resolved net names, label conflicts.
pub fn resolve_connectivity(sch: &Schematic, interner: &Rodeo) -> Connectivity {
    let wires = &sch.wires;
    let instances = &sch.instances;

    if wires.is_empty() && instances.is_empty() {
        return Connectivity::default();
    }

    let mut uf = UnionFind::new();

    // Step 1: connect each wire's two endpoints.
    for i in 0..wires.len() {
        let p0 = (wires.x0[i], wires.y0[i]);
        let p1 = (wires.x1[i], wires.y1[i]);
        uf.make_set(p0);
        uf.make_set(p1);
        uf.unite(p0, p1);
    }

    // Step 1b: bus expansion — synthetic net points for each bus bit.
    if !sch.buses.is_empty() {
        expand_buses(sch, &mut uf);
    }

    // Step 2: T-junction detection — wire endpoint touching the interior of
    // another wire. Spatial index avoids the O(W²) pairwise comparison.
    let wire_idx = WireIndex::build(wires);
    for i in 0..wires.len() {
        for pt in [(wires.x0[i], wires.y0[i]), (wires.x1[i], wires.y1[i])] {
            for j in wire_idx.find_interior_hits(pt.0, pt.1) {
                if j == i {
                    continue;
                }
                uf.unite(pt, (wires.x0[j], wires.y0[j]));
            }
        }
    }

    // Step 3: instance pin positions — merge with touching wires.
    for i in 0..instances.len() {
        let kind = instances.kind[i];
        let entry = match prim::find_symbol(interner.resolve(&instances.symbol[i]), kind) {
            Some(p) if !p.pin_positions.is_empty() => p,
            _ => continue,
        };

        let flags = instances.flags[i];
        let inst_x = instances.x[i];
        let inst_y = instances.y[i];

        for pin in &entry.pin_positions {
            let (tx, ty) = flags.transform_point(pin.x as i32, pin.y as i32);
            let abs = (inst_x + tx, inst_y + ty);
            uf.make_set(abs);

            for wi in 0..wires.len() {
                let w0 = (wires.x0[wi], wires.y0[wi]);
                let w1 = (wires.x1[wi], wires.y1[wi]);
                if abs == w0 || abs == w1 || on_wire_interior(abs, w0, w1) {
                    uf.unite(abs, w0);
                    break;
                }
            }
        }
    }

    // Step 4: collect net names from label pins and power instances; track
    // LabPin instances per root for conflict detection. root_names keeps
    // insertion order (net ids must be stable across resolves); root_to_id
    // provides O(1) root -> position lookup and doubles as the net-id map.
    let mut root_names: Vec<(u32, String)> = Vec::new();
    let mut root_to_id: FxHashMap<u32, usize> = FxHashMap::default();
    let mut labpin_per_root: FxHashMap<u32, Vec<(usize, Sym)>> = FxHashMap::default();

    for i in 0..instances.len() {
        let kind = instances.kind[i];
        // Borrow from the interner; allocate only if the name is stored.
        let name_str: &str = if kind.is_label() {
            interner.resolve(&instances.name[i])
        } else if kind.is_power() {
            let net_prop = sch
                .instance_props(i)
                .iter()
                .find(|p| interner.resolve(&p.key) == "net");
            match net_prop {
                Some(p) => interner.resolve(&p.value),
                None => kind.injected_net().unwrap_or("0"),
            }
        } else {
            continue;
        };

        let entry = match prim::find_symbol(interner.resolve(&instances.symbol[i]), kind) {
            Some(p) if !p.pin_positions.is_empty() => p,
            _ => continue,
        };

        let flags = instances.flags[i];
        let (tx, ty) = flags.transform_point(
            entry.pin_positions[0].x as i32,
            entry.pin_positions[0].y as i32,
        );
        let abs = (instances.x[i] + tx, instances.y[i] + ty);
        let root = uf.find(abs);
        upsert_root_name(&mut root_names, &mut root_to_id, root, name_str);

        if kind == DeviceKind::LabPin {
            // The label name is already interned on the instance; carry the
            // Sym instead of cloning the resolved string.
            labpin_per_root
                .entry(root)
                .or_default()
                .push((i, instances.name[i]));
        }
    }

    // Detect conflicting LabPins: same root, different names.
    let mut label_conflicts: std::collections::HashSet<usize> = Default::default();
    for entries in labpin_per_root.values() {
        if entries.len() < 2 {
            continue;
        }
        // Sym equality == string equality (single interner).
        let first_name = entries[0].1;
        if entries.iter().any(|&(_, n)| n != first_name) {
            for (idx, _) in entries {
                label_conflicts.insert(*idx);
            }
        }
    }

    // Auto-name unnamed nets: find the highest existing auto index.
    let mut auto_idx: u32 = 1;
    for (_, name) in &root_names {
        if let Some(n) = parse_auto_net_idx(name) {
            if n >= auto_idx {
                auto_idx = n + 1;
            }
        }
    }

    // Assign auto names to unnamed roots.
    for i in 0..wires.len() {
        for k in [(wires.x0[i], wires.y0[i]), (wires.x1[i], wires.y1[i])] {
            let root = uf.find(k);
            if let std::collections::hash_map::Entry::Vacant(e) = root_to_id.entry(root) {
                e.insert(root_names.len());
                root_names.push((root, format!("net{auto_idx}")));
                auto_idx += 1;
            }
        }
    }

    // Build the net list. root_to_id already maps each root to its position
    // in root_names — exactly the net id. Names move out of root_names into
    // net_names (single owned copy); Net itself carries only connections.
    let mut nets: Vec<Net> = (0..root_names.len())
        .map(|_| Net {
            connections: Vec::new(),
        })
        .collect();
    let net_names: Vec<String> = root_names.into_iter().map(|(_, name)| name).collect();

    // Wire endpoint connections + point_to_net.
    let mut point_to_net: std::collections::HashMap<(i32, i32), usize> = Default::default();
    point_to_net.reserve(wires.len() * 2);

    for i in 0..wires.len() {
        for (ep_x, ep_y) in [(wires.x0[i], wires.y0[i]), (wires.x1[i], wires.y1[i])] {
            let root = uf.find((ep_x, ep_y));
            if let Some(&nid) = root_to_id.get(&root) {
                point_to_net.insert((ep_x, ep_y), nid);
                nets[nid].connections.push(NetEndpoint {
                    x: ep_x,
                    y: ep_y,
                    kind: NetConnKind::WireEndpoint { wire_idx: i },
                });
            }
        }
    }

    // Instance connections.
    let mut instance_connections: Vec<Vec<PinConnection>> = vec![Vec::new(); instances.len()];

    #[allow(clippy::needless_range_loop)] // indexes multiple SoA parallel arrays
    for i in 0..instances.len() {
        let kind = instances.kind[i];
        let entry = match prim::find_symbol(interner.resolve(&instances.symbol[i]), kind) {
            Some(p) if !p.pin_positions.is_empty() => p,
            _ => continue,
        };

        let flags = instances.flags[i];
        let inst_x = instances.x[i];
        let inst_y = instances.y[i];

        instance_connections[i].reserve(entry.pin_positions.len());
        for pin in &entry.pin_positions {
            let (tx, ty) = flags.transform_point(pin.x as i32, pin.y as i32);
            let abs = (inst_x + tx, inst_y + ty);
            let root = uf.find(abs);
            let net_idx = root_to_id.get(&root).copied().unwrap_or(usize::MAX);

            instance_connections[i].push(PinConnection {
                pin_name: pin.name,
                net_idx,
                x: abs.0,
                y: abs.1,
            });

            if net_idx != usize::MAX {
                point_to_net.insert(abs, net_idx);
                nets[net_idx].connections.push(NetEndpoint {
                    x: abs.0,
                    y: abs.1,
                    kind: NetConnKind::InstancePin {
                        instance_idx: i,
                        pin_name: pin.name,
                    },
                });
            }
        }
    }

    // Label connections (for display).
    for i in 0..instances.len() {
        let kind = instances.kind[i];
        if !kind.is_label() {
            continue;
        }
        let label_sym = instances.name[i];
        if interner.resolve(&label_sym).is_empty() {
            continue;
        }

        let entry = match prim::find_symbol(interner.resolve(&instances.symbol[i]), kind) {
            Some(p) if !p.pin_positions.is_empty() => p,
            _ => continue,
        };

        let flags = instances.flags[i];
        let (tx, ty) = flags.transform_point(
            entry.pin_positions[0].x as i32,
            entry.pin_positions[0].y as i32,
        );
        let abs = (instances.x[i] + tx, instances.y[i] + ty);
        let root = uf.find(abs);

        if let Some(&nid) = root_to_id.get(&root) {
            nets[nid].connections.push(NetEndpoint {
                x: abs.0,
                y: abs.1,
                kind: NetConnKind::Label { name: label_sym },
            });
        }
    }

    Connectivity {
        nets,
        point_to_net,
        instance_connections,
        net_names,
        label_conflicts,
    }
}

// ── Union-find with path compression + union by rank ──
//
// Points are interned once into dense u32 indices; parent/rank live in flat
// Vecs so find/unite are array walks (one hash lookup per point, not per hop).

struct UnionFind {
    idx: FxHashMap<(i32, i32), u32>,
    parent: Vec<u32>,
    rank: Vec<u8>,
}

impl UnionFind {
    fn new() -> Self {
        Self {
            idx: FxHashMap::default(),
            parent: Vec::new(),
            rank: Vec::new(),
        }
    }

    /// Intern a point, returning its dense index.
    fn make_set(&mut self, k: (i32, i32)) -> u32 {
        match self.idx.entry(k) {
            std::collections::hash_map::Entry::Occupied(e) => *e.get(),
            std::collections::hash_map::Entry::Vacant(e) => {
                let i = self.parent.len() as u32;
                e.insert(i);
                self.parent.push(i);
                self.rank.push(0);
                i
            }
        }
    }

    /// Root index of the point's set. Interns the point if unseen.
    fn find(&mut self, k: (i32, i32)) -> u32 {
        let i = self.make_set(k);
        self.find_idx(i)
    }

    fn find_idx(&mut self, start: u32) -> u32 {
        let mut root = start;
        while self.parent[root as usize] != root {
            root = self.parent[root as usize];
        }
        // Path compression
        let mut cur = start;
        while cur != root {
            let next = self.parent[cur as usize];
            self.parent[cur as usize] = root;
            cur = next;
        }
        root
    }

    fn unite(&mut self, x: (i32, i32), y: (i32, i32)) {
        let rx = self.find(x);
        let ry = self.find(y);
        if rx == ry {
            return;
        }
        let (rx, ry) = (rx as usize, ry as usize);
        if self.rank[rx] < self.rank[ry] {
            self.parent[rx] = ry as u32;
        } else if self.rank[rx] > self.rank[ry] {
            self.parent[ry] = rx as u32;
        } else {
            self.parent[ry] = rx as u32;
            self.rank[rx] += 1;
        }
    }
}

// ── Spatial index for T-junction detection ──

struct WireIndex {
    /// y -> (wire_idx, x_min, x_max) for horizontal wires
    horiz: FxHashMap<i32, Vec<(usize, i32, i32)>>,
    /// x -> (wire_idx, y_min, y_max) for vertical wires
    vert: FxHashMap<i32, Vec<(usize, i32, i32)>>,
}

impl WireIndex {
    fn build(wires: &WireVec) -> Self {
        let mut horiz: FxHashMap<i32, Vec<(usize, i32, i32)>> = FxHashMap::default();
        let mut vert: FxHashMap<i32, Vec<(usize, i32, i32)>> = FxHashMap::default();

        for i in 0..wires.len() {
            let (x0, y0, x1, y1) = (wires.x0[i], wires.y0[i], wires.x1[i], wires.y1[i]);
            if y0 == y1 {
                horiz
                    .entry(y0)
                    .or_default()
                    .push((i, x0.min(x1), x0.max(x1)));
            } else if x0 == x1 {
                vert.entry(x0)
                    .or_default()
                    .push((i, y0.min(y1), y0.max(y1)));
            }
            // Diagonal wires (rare) are ignored — they cannot form
            // axis-aligned T-junctions anyway.
        }

        Self { horiz, vert }
    }

    /// Indices of wires whose *interior* contains the point (px, py).
    fn find_interior_hits(&self, px: i32, py: i32) -> Vec<usize> {
        let mut hits = Vec::new();
        if let Some(segs) = self.horiz.get(&py) {
            for &(idx, min_x, max_x) in segs {
                if min_x < px && px < max_x {
                    hits.push(idx);
                }
            }
        }
        if let Some(segs) = self.vert.get(&px) {
            for &(idx, min_y, max_y) in segs {
                if min_y < py && py < max_y {
                    hits.push(idx);
                }
            }
        }
        hits
    }
}

// ── Bus expansion ──

/// Expand buses into synthetic net points and connect rippers.
///
/// Each bus bit gets a synthetic coordinate at `(i32::MIN/2 + bus_idx, bit)`
/// to avoid collisions with real schematic coordinates. Rippers connect
/// their physical (x, y) position to the synthetic point of their bus bit.
fn expand_buses(sch: &Schematic, uf: &mut UnionFind) {
    const BASE_X: i32 = i32::MIN / 2;
    let buses = &sch.buses;

    for bus_i in 0..buses.len() {
        let width = buses.width[bus_i];
        let start = buses.start_bit[bus_i];
        for bit in start..start + width {
            uf.make_set((BASE_X + bus_i as i32, bit as i32));
        }
    }

    for rip in &sch.bus_rippers {
        let bus_i = rip.bus_idx as usize;
        if bus_i >= buses.len() {
            continue;
        }
        let synthetic = (BASE_X + bus_i as i32, rip.bit as i32);
        let physical = (rip.x, rip.y);
        uf.make_set(physical);
        uf.unite(physical, synthetic);
    }
}

// ── Connectivity helpers ──

fn on_wire_interior(pt: (i32, i32), w0: (i32, i32), w1: (i32, i32)) -> bool {
    if w0.1 == w1.1 && pt.1 == w0.1 {
        // Horizontal wire
        let (min_x, max_x) = (w0.0.min(w1.0), w0.0.max(w1.0));
        min_x < pt.0 && pt.0 < max_x
    } else if w0.0 == w1.0 && pt.0 == w0.0 {
        // Vertical wire
        let (min_y, max_y) = (w0.1.min(w1.1), w0.1.max(w1.1));
        min_y < pt.1 && pt.1 < max_y
    } else {
        false
    }
}

fn upsert_root_name(
    root_names: &mut Vec<(u32, String)>,
    root_to_id: &mut FxHashMap<u32, usize>,
    root: u32,
    name: &str,
) {
    match root_to_id.entry(root) {
        std::collections::hash_map::Entry::Occupied(e) => {
            let existing = &mut root_names[*e.get()];
            if net_name_rank(name) > net_name_rank(&existing.1) {
                existing.1 = name.to_owned();
            }
        }
        std::collections::hash_map::Entry::Vacant(e) => {
            e.insert(root_names.len());
            root_names.push((root, name.to_owned()));
        }
    }
}

fn is_auto_net_name(name: &str) -> bool {
    name.len() > 3 && name.starts_with("net") && name.as_bytes()[3].is_ascii_digit()
}

fn parse_auto_net_idx(name: &str) -> Option<u32> {
    if is_auto_net_name(name) {
        name[3..].parse().ok()
    } else {
        None
    }
}

/// Priority when several names land on one net: user names > "0" > auto > empty.
fn net_name_rank(name: &str) -> u8 {
    if name.is_empty() {
        return 0;
    }
    if is_auto_net_name(name) {
        return 1;
    }
    if name == "0" {
        return 2;
    }
    3
}

// ════════════════════════════════════════════════════════════
// Netlist — Schematic + Connectivity -> crate::sim CircuitIR
// ════════════════════════════════════════════════════════════

impl App {
    /// Project symbols instanced by `top` (transitively), cloned so their
    /// subcircuit defs can be emitted alongside the top-level circuit.
    fn project_symbol_children(&self, top: &Schematic) -> Vec<Schematic> {
        let pool = &self.state.project_symbol_schematics;
        if pool.is_empty() {
            return Vec::new();
        }
        let mut included: Vec<Schematic> = Vec::new();
        let mut seen: FxHashSet<&str> = FxHashSet::default();
        let mut work: Vec<&Schematic> = vec![top];
        while let Some(sch) = work.pop() {
            for i in 0..sch.instances.len() {
                if sch.instances.kind[i] != DeviceKind::Subckt {
                    continue;
                }
                let sym = self.state.interner.resolve(&sch.instances.symbol[i]);
                if seen.contains(sym) {
                    continue;
                }
                if let Some(child) = pool.iter().find(|c| c.name == sym) {
                    seen.insert(&child.name);
                    included.push(child.clone());
                    work.push(child);
                }
            }
        }
        included
    }

    pub fn build_circuit_ir(&self) -> ir::CircuitIR {
        let sch = &self.state.active_document().schematic;
        let children = self.project_symbol_children(sch);
        if children.is_empty() {
            to_circuit_ir(sch, &self.state.interner, self.state.pdk.as_ref())
        } else {
            to_circuit_ir_with_children(
                sch,
                &children,
                &self.state.interner,
                self.state.pdk.as_ref(),
            )
        }
    }

    fn generate_netlist(&mut self) {
        let circuit = self.build_circuit_ir();
        self.state.last_netlist = match serde_json::to_string_pretty(&circuit) {
            Ok(json) => json,
            Err(e) => format!("Failed to serialize circuit IR: {e}"),
        };
    }

    /// Run a simulation: Python (pyspice_rs) renders the netlist from the
    /// circuit IR, the schematic's analysis directives (`spice_body`) are
    /// spliced in before `.end`, the selected SPICE backend runs it in batch
    /// mode, and the resulting `.raw` opens in the waveform viewer.
    #[cfg(not(target_arch = "wasm32"))]
    fn run_simulation(&mut self) {
        use std::process::Command as Proc;

        let sch = &self.state.active_document().schematic;
        let spice_body = sch.spice_body.clone();
        let backend = sch.sim_backend;

        if spice_body.trim().is_empty() {
            self.state.status_msg = "No analysis directives. Open the SPICE Code editor and add e.g. `.tran 1n 1u`.".into();
            return;
        }

        let ir = self.build_circuit_ir();
        self.state.last_netlist = match serde_json::to_string_pretty(&ir) {
            Ok(json) => json,
            Err(e) => format!("Failed to serialize circuit IR: {e}"),
        };

        // Relative paths (Verilog-A sources, includes, .osdi cards) resolve
        // against the schematic's directory: both the netlist-gen python
        // (which runs openvaf via veriloga()) and the SPICE backend get it
        // as cwd. Unsaved documents fall back to the process cwd.
        let work_dir = match &self.state.active_document().origin {
            Origin::File(p) => p.parent().map(std::path::Path::to_path_buf),
            _ => None,
        };

        // 1. Python renders the netlist — pyspice_rs owns PDK resolution
        //    and backend dialect quirks, so we don't emit SPICE directly.
        let Some(pypath) = ir::pyspice::python_path() else {
            self.state.status_msg =
                "PySpice not available (build inside the nix devshell so it gets bundled)".into();
            return;
        };
        let dir = std::env::temp_dir().join("schemify_sim");
        if let Err(e) = std::fs::create_dir_all(&dir) {
            self.state.status_msg = format!("Sim: cannot create {}: {e}", dir.display());
            return;
        }
        let script_path = dir.join("netlist_gen.py");
        if let Err(e) = std::fs::write(&script_path, ir::codegen::emit_netlist_script(&ir)) {
            self.state.status_msg = format!("Sim: cannot write netlist script: {e}");
            return;
        }
        let mut py_cmd = Proc::new(ir::pyspice::python_bin());
        py_cmd.arg(&script_path).env("PYTHONPATH", &pypath);
        if let Some(d) = &work_dir {
            py_cmd.current_dir(d);
        }
        let netlist = match py_cmd.output() {
            Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).into_owned(),
            Ok(out) => {
                let stderr = String::from_utf8_lossy(&out.stderr);
                // Tracebacks bury the message (e.g. openvaf compile errors
                // from veriloga()): prefer a line mentioning an error, keep
                // the full log inspectable next to the netlist JSON.
                let msg = stderr
                    .lines()
                    .find(|l| l.contains("Error") || l.contains("error"))
                    .or_else(|| stderr.lines().rev().find(|l| !l.trim().is_empty()))
                    .unwrap_or("unknown error");
                self.state.status_msg = format!("Netlist generation failed: {msg}");
                self.state.last_netlist = format!(
                    "{}\n\n* === Netlist generation log ===\n{stderr}",
                    self.state.last_netlist
                );
                return;
            }
            Err(e) => {
                self.state.status_msg = format!("Failed to run python: {e}");
                return;
            }
        };

        // 2. Splice the analysis directives in before `.end`.
        let mut deck = netlist.trim_end().to_string();
        if let Some(stripped) = deck.strip_suffix(".end") {
            deck.truncate(stripped.trim_end().len());
        }
        deck.push_str("\n\n");
        for line in spice_body.lines() {
            deck.push_str(line);
            deck.push('\n');
        }
        deck.push_str(".end\n");

        // 3. Batch-run the selected backend, writing a rawfile.
        let cir_path = dir.join("circuit.cir");
        let raw_path = dir.join("circuit.raw");
        let _ = std::fs::remove_file(&raw_path);
        if let Err(e) = std::fs::write(&cir_path, &deck) {
            self.state.status_msg = format!("Sim: cannot write netlist: {e}");
            return;
        }
        let mut cmd = match backend {
            SpiceBackend::NgSpice => {
                let mut c = Proc::new("ngspice");
                c.arg("-b").arg("-r").arg(&raw_path).arg(&cir_path);
                c
            }
            SpiceBackend::Xyce => {
                let mut c = Proc::new("Xyce");
                c.arg("-r").arg(&raw_path).arg(&cir_path);
                c
            }
        };
        if let Some(d) = &work_dir {
            cmd.current_dir(d);
        }
        self.state.status_msg = "Running simulation...".into();
        match cmd.output() {
            Ok(out) => {
                let stdout = String::from_utf8_lossy(&out.stdout);
                let stderr = String::from_utf8_lossy(&out.stderr);
                // Keep the full log inspectable next to the netlist JSON.
                self.state.last_netlist = format!(
                    "{}\n\n* === Netlist ===\n{deck}\n* === Simulation log ===\n{stdout}\n{stderr}",
                    self.state.last_netlist
                );
                if !out.status.success() {
                    let err = stdout
                        .lines()
                        .chain(stderr.lines())
                        .find(|l| l.to_ascii_lowercase().contains("error"))
                        .unwrap_or("unknown error");
                    self.state.status_msg = format!("Simulation failed: {err}");
                    return;
                }
            }
            Err(e) => {
                self.state.status_msg =
                    format!("Failed to run {}: {e} (is it installed?)", backend.as_str());
                return;
            }
        }

        // 4. Rawfile -> waveform viewer.
        if raw_path.exists() {
            self.handle_wave_open(&raw_path.to_string_lossy());
        } else {
            self.state.status_msg =
                "Simulation finished but produced no rawfile (missing analysis output?)".into();
        }
    }

    #[cfg(target_arch = "wasm32")]
    fn run_simulation(&mut self) {
        self.state.status_msg = "Simulation not available in web mode".into();
    }
}

/// Expand `{{Name.key}}` / `{{Name}}` documentation references to live
/// schematic values (`{{R1}}` reads R1's "value" prop). Unknown references
/// render unchanged so typos stay visible.
pub fn expand_doc_vars(text: &str, sch: &Schematic, interner: &Rodeo) -> String {
    let lookup = |name: &str, key: &str| -> Option<String> {
        let idx = (0..sch.instances.len())
            .find(|&i| interner.resolve(&sch.instances.name[i]) == name)?;
        sch.instance_props(idx)
            .iter()
            .find(|p| interner.resolve(&p.key) == key)
            .map(|p| interner.resolve(&p.value).to_owned())
    };

    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find("{{") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        let Some(end) = after.find("}}") else {
            // Unterminated ref: emit the tail verbatim.
            out.push_str(&rest[start..]);
            return out;
        };
        let inner = after[..end].trim();
        let (name, key) = match inner.split_once('.') {
            Some((n, k)) => (n.trim(), k.trim()),
            None => (inner, "value"),
        };
        match lookup(name, key) {
            Some(v) => out.push_str(&v),
            None => out.push_str(&rest[start..start + 2 + end + 2]),
        }
        rest = &after[end + 2..];
    }
    out.push_str(rest);
    out
}

/// PDK cell for a device kind: the manifest keys cells by primitive name
/// ("nmos4", "res", ...), so map by parsing the key back to a kind.
fn pdk_cell_for_kind(pdk: &LoadedPdk, kind: DeviceKind) -> Option<&PdkCell> {
    pdk.cells
        .iter()
        .find(|(k, _)| DeviceKind::from_name(k) == kind)
        .map(|(_, c)| c)
}

/// Convert a Schematic into a CircuitIR.
///
/// Resolves connectivity (union-find over wires + instance pins), maps each
/// electrical instance to a `Component`, and collects model definitions.
///
/// With a loaded PDK, mapped device kinds get the PDK model name and default
/// parameters; subcircuit devices (prefix 'X') are emitted as X-cards, and
/// the PDK's .lib (with the schematic's corner) and includes are injected
/// into the top subcircuit.
pub fn to_circuit_ir(sch: &Schematic, interner: &Rodeo, pdk: Option<&LoadedPdk>) -> ir::CircuitIR {
    let conn = resolve_connectivity(sch, interner);

    let mut components: Vec<ir::Component> = Vec::new();
    let mut instances: Vec<ir::Instance> = Vec::new();
    let mut osdi_loads: Vec<String> = Vec::new();
    let mut veriloga_sources: Vec<String> = Vec::new();
    let mut va_models: Vec<String> = Vec::new();

    for i in 0..sch.instances.len() {
        let kind = sch.instances.kind[i];
        if !kind.is_electrical() {
            continue;
        }

        let raw_name = interner.resolve(&sch.instances.name[i]);
        // The codegen prepends the SPICE prefix (R, M, V, ...), so strip it
        // from the instance name to avoid doubling.
        let name = strip_spice_prefix(raw_name, kind);
        let pins = &conn.instance_connections[i];
        let props = sch.instance_props(i);

        let get_prop = |key: &str| -> Option<String> {
            props
                .iter()
                .find(|p| interner.resolve(&p.key) == key)
                .map(|p| interner.resolve(&p.value).to_owned())
        };

        let mut params: Vec<(String, String)> = props
            .iter()
            .filter(|p| !matches!(interner.resolve(&p.key), "value" | "model"))
            .map(|p| {
                (
                    interner.resolve(&p.key).to_owned(),
                    interner.resolve(&p.value).to_owned(),
                )
            })
            .collect();

        let pdk_cell = pdk.and_then(|p| pdk_cell_for_kind(p, kind));

        // PDK default params fill in whatever the instance doesn't set.
        if let Some(cell) = pdk_cell {
            for (k, v) in &cell.default_params {
                if !params.iter().any(|(pk, _)| pk.eq_ignore_ascii_case(k)) {
                    params.push((k.clone(), v.clone()));
                }
            }
        }

        let net = |pin_idx: usize| -> String {
            pins.get(pin_idx)
                .and_then(|pc| {
                    if pc.net_idx == usize::MAX {
                        None
                    } else {
                        conn.net_names.get(pc.net_idx)
                    }
                })
                .cloned()
                .unwrap_or_else(|| "?".to_owned())
        };

        let value_or_default = |default: &str| -> ir::IrValue {
            // Parse the default too: "1k" must reach codegen as Numeric(1000)
            // — pyspice_rs's native methods take Float | Unit, not strings.
            match get_prop("value") {
                Some(v) => parse_value(&v),
                None => parse_value(default),
            }
        };

        let model_name = || -> String {
            get_prop("model")
                .or_else(|| pdk_cell.map(|c| c.model.clone()))
                .unwrap_or_else(|| {
                    match kind {
                        DeviceKind::Nmos3
                        | DeviceKind::Nmos4
                        | DeviceKind::Nmos4Depl
                        | DeviceKind::NmosSub
                        | DeviceKind::Nmoshv4
                        | DeviceKind::Rnmos4 => "nmos",
                        DeviceKind::Pmos3
                        | DeviceKind::Pmos4
                        | DeviceKind::PmosSub
                        | DeviceKind::Pmoshv4 => "pmos",
                        DeviceKind::Npn => "npn",
                        DeviceKind::Pnp => "pnp",
                        DeviceKind::Njfet => "njfet",
                        DeviceKind::Pjfet => "pjfet",
                        _ => "unknown",
                    }
                    .to_owned()
                })
        };

        // PDK devices are typically subcircuits: emit an X-card directly
        // (M/R/C-cards would reference the wrong primitive type) and skip
        // the per-kind component mapping.
        if let Some(cell) = pdk_cell {
            if cell.prefix == 'X' {
                let nets: Vec<String> = if cell.pin_order.is_empty() {
                    (0..pins.len()).map(&net).collect()
                } else {
                    // Map manifest pin order onto schematic pins by name.
                    cell.pin_order
                        .iter()
                        .map(|want| {
                            pins.iter()
                                .position(|pc| pc.pin_name.eq_ignore_ascii_case(want))
                                .map(&net)
                                .unwrap_or_else(|| "?".to_owned())
                        })
                        .collect()
                };
                let model = get_prop("model").unwrap_or_else(|| cell.model.clone());
                let mut line = format!("X{name} {} {model}", nets.join(" "));
                for (k, v) in &params {
                    line.push(' ');
                    line.push_str(k);
                    line.push('=');
                    line.push_str(v);
                }
                components.push(ir::Component::RawSpice { line });
                continue;
            }
        }

        match kind {
            // 2-terminal passives
            DeviceKind::Resistor | DeviceKind::VarResistor | DeviceKind::Resistor3 => {
                // Resistor3: pins 0,1 are the terminals, pin 2 is the wiper.
                components.push(ir::Component::Resistor {
                    name,
                    n1: net(0),
                    n2: net(1),
                    value: value_or_default("1k"),
                    params,
                });
            }
            DeviceKind::Capacitor => {
                components.push(ir::Component::Capacitor {
                    name,
                    n1: net(0),
                    n2: net(1),
                    value: value_or_default("1p"),
                    params,
                });
            }
            DeviceKind::Inductor => {
                components.push(ir::Component::Inductor {
                    name,
                    n1: net(0),
                    n2: net(1),
                    value: value_or_default("1n"),
                    params,
                });
            }

            // Diodes
            DeviceKind::Diode | DeviceKind::Zener => {
                components.push(ir::Component::Diode {
                    name,
                    np: net(0),
                    nm: net(1),
                    model: model_name(),
                    params,
                });
            }

            // MOSFETs (4-terminal)
            DeviceKind::Nmos4
            | DeviceKind::Pmos4
            | DeviceKind::Nmos4Depl
            | DeviceKind::NmosSub
            | DeviceKind::PmosSub
            | DeviceKind::Nmoshv4
            | DeviceKind::Pmoshv4
            | DeviceKind::Rnmos4 => {
                components.push(ir::Component::Mosfet {
                    name,
                    nd: net(0),
                    ng: net(1),
                    ns: net(2),
                    nb: net(3),
                    model: model_name(),
                    params,
                });
            }

            // MOSFETs (3-terminal — bulk tied to source)
            DeviceKind::Nmos3 | DeviceKind::Pmos3 => {
                let source = net(2);
                components.push(ir::Component::Mosfet {
                    name,
                    nd: net(0),
                    ng: net(1),
                    ns: source.clone(),
                    nb: source,
                    model: model_name(),
                    params,
                });
            }

            // BJTs
            DeviceKind::Npn | DeviceKind::Pnp => {
                components.push(ir::Component::Bjt {
                    name,
                    nc: net(0),
                    nb: net(1),
                    ne: net(2),
                    model: model_name(),
                    params,
                });
            }

            // JFETs
            DeviceKind::Njfet | DeviceKind::Pjfet => {
                components.push(ir::Component::Jfet {
                    name,
                    nd: net(0),
                    ng: net(1),
                    ns: net(2),
                    model: model_name(),
                    params,
                });
            }

            // MESFET
            DeviceKind::Mesfet => {
                components.push(ir::Component::Mesfet {
                    name,
                    nd: net(0),
                    ng: net(1),
                    ns: net(2),
                    model: model_name(),
                    params,
                });
            }

            // Sources
            DeviceKind::Vsource => {
                components.push(ir::Component::VoltageSource {
                    name,
                    np: net(0),
                    nm: net(1),
                    value: value_or_default("0"),
                    waveform: None,
                });
            }
            DeviceKind::Isource => {
                components.push(ir::Component::CurrentSource {
                    name,
                    np: net(0),
                    nm: net(1),
                    value: value_or_default("0"),
                    waveform: None,
                });
            }

            // Controlled sources
            DeviceKind::Vcvs => {
                let gain: f64 = get_prop("value")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(1.0);
                components.push(ir::Component::Vcvs {
                    name,
                    np: net(0),
                    nm: net(1),
                    ncp: net(2),
                    ncm: net(3),
                    gain,
                });
            }
            DeviceKind::Vccs => {
                let gm: f64 = get_prop("value")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(1e-3);
                components.push(ir::Component::Vccs {
                    name,
                    np: net(0),
                    nm: net(1),
                    ncp: net(2),
                    ncm: net(3),
                    transconductance: gm,
                });
            }
            DeviceKind::Ccvs => {
                let tr: f64 = get_prop("value")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(1.0);
                let vsense = get_prop("vsense").unwrap_or_default();
                components.push(ir::Component::Ccvs {
                    name,
                    np: net(0),
                    nm: net(1),
                    vsense,
                    transresistance: tr,
                });
            }
            DeviceKind::Cccs => {
                let gain: f64 = get_prop("value")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(1.0);
                let vsense = get_prop("vsense").unwrap_or_default();
                components.push(ir::Component::Cccs {
                    name,
                    np: net(0),
                    nm: net(1),
                    vsense,
                    gain,
                });
            }

            // Behavioral source
            DeviceKind::Behavioral => {
                let expr = get_prop("value").unwrap_or_default();
                components.push(ir::Component::BehavioralVoltage {
                    name,
                    np: net(0),
                    nm: net(1),
                    expression: expr,
                });
            }

            // Transmission line
            DeviceKind::Tline | DeviceKind::TlineLossy => {
                let z0: f64 = get_prop("Z0")
                    .or_else(|| get_prop("z0"))
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(50.0);
                let td: f64 = get_prop("TD")
                    .or_else(|| get_prop("td"))
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(1e-9);
                components.push(ir::Component::TLine {
                    name,
                    inp: net(0),
                    inm: net(1),
                    outp: net(2),
                    outm: net(3),
                    z0,
                    td,
                });
            }

            // Switches
            DeviceKind::Vswitch => {
                let model = get_prop("model").unwrap_or_else(|| "sw".to_owned());
                components.push(ir::Component::VSwitch {
                    name,
                    np: net(0),
                    nm: net(1),
                    ncp: net(2),
                    ncm: net(3),
                    model,
                });
            }
            DeviceKind::Iswitch => {
                let model = get_prop("model").unwrap_or_else(|| "csw".to_owned());
                let vcontrol = get_prop("vsense").unwrap_or_default();
                components.push(ir::Component::ISwitch {
                    name,
                    np: net(0),
                    nm: net(1),
                    vcontrol,
                    model,
                });
            }

            // Verilog-A module (OSDI): N-card referencing the compiled
            // module; the .osdi load is recorded once per distinct source.
            DeviceKind::Hdl => {
                let source = get_prop("source_file").unwrap_or_default();
                let model = get_prop("model_name")
                    .filter(|m| !m.is_empty())
                    .or_else(|| {
                        Path::new(&source)
                            .file_stem()
                            .map(|s| s.to_string_lossy().into_owned())
                    })
                    .filter(|m| !m.is_empty())
                    .unwrap_or_else(|| "va_module".to_owned());
                if !source.is_empty() {
                    // openvaf's conventional output is a sibling .osdi.
                    let is_va_source = source.ends_with(".va") || source.ends_with(".vams");
                    let osdi = if is_va_source {
                        Path::new(&source)
                            .with_extension("osdi")
                            .to_string_lossy()
                            .into_owned()
                    } else {
                        source.clone()
                    };
                    if !osdi_loads.contains(&osdi) {
                        osdi_loads.push(osdi);
                    }
                    // Keep the source path as a codegen hint: the PySpice
                    // emitter compiles it via `veriloga()` (openvaf) instead
                    // of loading the .osdi directly.
                    if is_va_source && !veriloga_sources.contains(&source) {
                        veriloga_sources.push(source.clone());
                    }
                }
                if !va_models.contains(&model) {
                    va_models.push(model.clone());
                }
                params.retain(|(k, _)| {
                    !matches!(k.as_str(), "source_file" | "model_name" | "category")
                });
                components.push(ir::Component::VerilogA {
                    name,
                    nodes: (0..pins.len()).map(&net).collect(),
                    model,
                    params,
                });
            }

            // Subcircuit instance
            DeviceKind::Subckt | DeviceKind::DigitalInstance => {
                let symbol = interner.resolve(&sch.instances.symbol[i]);
                instances.push(ir::Instance {
                    name,
                    subcircuit: symbol.to_owned(),
                    port_mapping: (0..pins.len()).map(&net).collect(),
                    parameters: params,
                });
            }

            // Coupling
            DeviceKind::Coupling => {
                let k: f64 = get_prop("value")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(1.0);
                let l1 = get_prop("inductor1").unwrap_or_default();
                let l2 = get_prop("inductor2").unwrap_or_default();
                components.push(ir::Component::MutualInductor {
                    name,
                    inductor1: l1,
                    inductor2: l2,
                    coupling: k,
                });
            }

            // Ammeter = zero-volt source
            DeviceKind::Ammeter => {
                components.push(ir::Component::VoltageSource {
                    name,
                    np: net(0),
                    nm: net(1),
                    value: ir::IrValue::Numeric { value: 0.0 },
                    waveform: None,
                });
            }

            // Everything else: non-electrical (filtered above) or unsupported.
            _ => {}
        }
    }

    // Model definitions: parse ".model name TYPE(params)" into structured defs.
    let mut models: Vec<ir::ModelDef> = Vec::with_capacity(sch.model_defs.len());
    for m in &sch.model_defs {
        let parts: Vec<&str> = m.body.splitn(3, ' ').collect();
        let (model_kind, model_params) = if parts.len() >= 3 {
            let kind_and_params = parts[2];
            if let Some(paren) = kind_and_params.find('(') {
                let kind = kind_and_params[..paren].to_owned();
                let param_str = kind_and_params[paren + 1..].trim_end_matches(')');
                let params: Vec<(String, String)> = param_str
                    .split_whitespace()
                    .filter_map(|kv| {
                        let eq = kv.find('=')?;
                        Some((kv[..eq].to_owned(), kv[eq + 1..].to_owned()))
                    })
                    .collect();
                (kind, params)
            } else {
                (kind_and_params.to_owned(), vec![])
            }
        } else {
            (String::new(), vec![])
        };
        models.push(ir::ModelDef {
            name: m.name.clone(),
            kind: model_kind,
            parameters: model_params,
        });
    }

    // Verilog-A instances need a model card binding the OSDI module
    // (`.model <name> <module>`); auto-emit one per module unless the
    // user already defined a card with that name.
    for va in va_models {
        if !models.iter().any(|m| m.name == va) {
            models.push(ir::ModelDef {
                name: va.clone(),
                kind: va,
                parameters: vec![],
            });
        }
    }

    // PDK model library: corner-sectioned .lib plus plain includes.
    let mut includes = vec![];
    let mut libs = vec![];
    let mut model_libraries = vec![];
    if let Some(p) = pdk {
        let corner = if sch.sim_corner.is_empty() {
            p.default_corner.clone()
        } else {
            sch.sim_corner.clone()
        };
        if let Some(lib) = &p.lib_path {
            let path = lib.to_string_lossy().into_owned();
            libs.push((path.clone(), corner.clone()));
            model_libraries.push(ir::ModelLibrary {
                name: p.name.clone(),
                path,
                corner: Some(corner),
                backend_paths: Default::default(),
            });
        }
        for inc in &p.includes {
            includes.push(inc.to_string_lossy().into_owned());
        }
    }

    let top = ir::Subcircuit {
        name: sch.name.clone(),
        components,
        instances,
        models,
        includes,
        libs,
        osdi_loads,
        veriloga_sources,
        ..Default::default()
    };

    ir::CircuitIR {
        top,
        testbench: None,
        subcircuit_defs: vec![],
        model_libraries,
    }
}

/// Convert a top-level Schematic plus child schematics into a CircuitIR.
/// Each child becomes a subcircuit definition; the child's `pins` field
/// supplies the port list.
pub fn to_circuit_ir_with_children(
    top: &Schematic,
    children: &[Schematic],
    interner: &Rodeo,
    pdk: Option<&LoadedPdk>,
) -> ir::CircuitIR {
    let mut circuit = to_circuit_ir(top, interner, pdk);
    circuit.subcircuit_defs.reserve(children.len());

    for child in children {
        let child_ir = to_circuit_ir(child, interner, pdk);
        let ports: Vec<ir::Port> = child
            .pins
            .iter()
            .map(|p| ir::Port {
                name: interner.resolve(&p.name).to_owned(),
                direction: ir::PortDirection::InOut,
            })
            .collect();

        // OSDI loads are global, not per-.subckt: hoist into the top.
        for osdi in child_ir.top.osdi_loads {
            if !circuit.top.osdi_loads.contains(&osdi) {
                circuit.top.osdi_loads.push(osdi);
            }
        }
        for src in child_ir.top.veriloga_sources {
            if !circuit.top.veriloga_sources.contains(&src) {
                circuit.top.veriloga_sources.push(src);
            }
        }

        circuit.subcircuit_defs.push(ir::Subcircuit {
            name: child.name.clone(),
            ports,
            components: child_ir.top.components,
            instances: child_ir.top.instances,
            models: child_ir.top.models,
            ..Default::default()
        });
    }

    circuit
}

/// Strip the SPICE prefix letter from an instance name if it matches the
/// device kind ("M1" for a MOSFET -> "1"). The codegen prepends the prefix,
/// so it must not be doubled.
fn strip_spice_prefix(name: &str, kind: DeviceKind) -> String {
    let prefix = kind.prefix();
    if prefix == 0 {
        return name.to_owned();
    }
    if let Some(first) = name.chars().next() {
        if first.to_ascii_uppercase() == prefix.to_ascii_uppercase() as char {
            return name[first.len_utf8()..].to_owned();
        }
    }
    name.to_owned()
}

/// Parse a SPICE value literal: plain number, SI suffix (1k, 10u, 1meg, ...),
/// expression, or raw text.
fn parse_value(s: &str) -> ir::IrValue {
    if let Ok(v) = s.parse::<f64>() {
        return ir::IrValue::Numeric { value: v };
    }
    let s_lower = s.to_ascii_lowercase();
    let (num_part, multiplier) = if let Some(n) = s_lower.strip_suffix("meg") {
        (n, 1e6)
    } else if let Some(n) = s_lower.strip_suffix("mil") {
        (n, 25.4e-6)
    } else if s_lower.len() > 1 {
        let last = s_lower.as_bytes()[s_lower.len() - 1];
        let mult = match last {
            b't' => Some(1e12),
            b'g' => Some(1e9),
            b'k' => Some(1e3),
            b'm' => Some(1e-3),
            b'u' => Some(1e-6),
            b'n' => Some(1e-9),
            b'p' => Some(1e-12),
            b'f' => Some(1e-15),
            b'a' => Some(1e-18),
            _ => None,
        };
        match mult {
            Some(m) => (&s[..s.len() - 1], m),
            None => (s, 1.0),
        }
    } else {
        (s, 1.0)
    };

    if multiplier != 1.0 {
        if let Ok(v) = num_part.parse::<f64>() {
            return ir::IrValue::Numeric {
                value: v * multiplier,
            };
        }
    }

    if s.contains('{') || s.contains('+') || s.contains('*') || s.contains('/') {
        ir::IrValue::Expression { expr: s.to_owned() }
    } else {
        ir::IrValue::Raw { text: s.to_owned() }
    }
}

// ════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    fn place_resistor(app: &mut App, x: i32, y: i32) {
        app.dispatch(Command::PlaceDevice {
            symbol_path: "resistor".into(),
            name: "R1".into(),
            x,
            y,
            rotation: 0,
            flip: false,
        });
    }

    #[test]
    fn verilog_a_block_netlists_as_osdi() {
        let mut app = App::new();
        app.dispatch(Command::PlaceDevice {
            symbol_path: "verilog_a_block".into(),
            name: "NVA1".into(),
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        });
        for (key, value) in [("source_file", "models/my_diode.va"), ("model_name", "my_diode")] {
            app.dispatch(Command::SetInstanceProp {
                idx: 0,
                key: key.into(),
                value: value.into(),
            });
        }

        let ir = to_circuit_ir(app.schematic(), &app.state.interner, None);
        // .osdi load recorded once, with openvaf's sibling-output path;
        // the source travels alongside as a codegen hint.
        assert_eq!(ir.top.osdi_loads, vec!["models/my_diode.osdi".to_string()]);
        assert_eq!(ir.top.veriloga_sources, vec!["models/my_diode.va".to_string()]);
        // Auto model card binds the module.
        assert!(ir.top.models.iter().any(|m| m.name == "my_diode" && m.kind == "my_diode"));

        let sp = crate::sim::codegen::emit_spice(&ir);
        assert!(sp.contains(".osdi models/my_diode.osdi\n"), "spice was:\n{sp}");
        assert!(sp.contains(".model my_diode my_diode\n"), "spice was:\n{sp}");
        // N-card: prefix stripped from the instance name, not doubled.
        assert!(sp.contains("NVA1 ? ? my_diode\n"), "spice was:\n{sp}");

        // PySpice path compiles the source via veriloga() (openvaf,
        // mtime-cached) — no duplicate osdi() load for the same module.
        let py = crate::sim::codegen::emit_pyspice(&ir);
        assert!(py.contains(r#"ckt.veriloga("models/my_diode.va")"#), "pyspice was:\n{py}");
        assert!(!py.contains("osdi("), "pyspice was:\n{py}");
    }

    #[test]
    fn file_new_reuses_welcome_placeholder() {
        let mut app = App::new();
        assert_eq!(app.state.documents.len(), 1);
        assert!(app.state.view.show_welcome);

        // New from the welcome screen: still exactly one tab.
        app.dispatch(Command::FileNew);
        assert_eq!(app.state.documents.len(), 1);
        assert!(!app.state.view.show_welcome);

        // New again: now a real second tab.
        app.dispatch(Command::NewTab);
        assert_eq!(app.state.documents.len(), 2);
        assert_eq!(app.state.active_doc, 1);

        // Closing the second tab keeps the first open, no welcome.
        app.dispatch(Command::CloseTab(1));
        assert_eq!(app.state.documents.len(), 1);
        assert!(!app.state.view.show_welcome);

        // Closing the last tab returns to the welcome screen.
        app.dispatch(Command::CloseTab(0));
        assert_eq!(app.state.documents.len(), 1);
        assert!(app.state.view.show_welcome);
    }

    #[test]
    fn doc_kind_names_and_display() {
        assert_eq!(DocKind::split_name("inv.chn"), ("inv", DocKind::Schematic));
        assert_eq!(DocKind::split_name("res.chn_prim"), ("res", DocKind::Primitive));
        assert_eq!(DocKind::split_name("tb_foo.chn_tb"), ("tb_foo", DocKind::Testbench));
        assert_eq!(DocKind::split_name("plain"), ("plain", DocKind::Schematic));

        let doc = Document::default();
        assert_eq!(doc.display_name(), "untitled.chn");
    }

    #[test]
    fn save_defaults_extension_and_updates_doc() {
        let dir = std::env::temp_dir().join("schemify_save_test");
        let _ = std::fs::create_dir_all(&dir);

        let mut app = App::new();
        place_resistor(&mut app, 0, 0);

        // No extension: kind supplies `.chn`.
        app.save_to_path(&dir.join("amp")).unwrap();
        assert!(dir.join("amp.chn").is_file());
        let doc = app.state.active_document();
        assert_eq!(doc.name, "amp");
        assert_eq!(doc.kind, DocKind::Schematic);
        assert!(!doc.dirty);
        assert_eq!(doc.display_name(), "amp.chn");

        // Explicit `.chn_tb` round-trips name + kind.
        app.save_to_path(&dir.join("tb_amp.chn_tb")).unwrap();
        let doc = app.state.active_document();
        assert!(dir.join("tb_amp.chn_tb").is_file());
        assert_eq!(doc.name, "tb_amp");
        assert_eq!(doc.kind, DocKind::Testbench);
        assert_eq!(doc.display_name(), "tb_amp.chn_tb");

        // Saved content re-opens with the same instance count.
        let mut app2 = App::new();
        app2.open_file(&dir.join("amp.chn")).unwrap();
        assert_eq!(app2.state.documents.len(), 1); // reused placeholder
        assert_eq!(app2.schematic().instances.len(), 1);
        assert_eq!(app2.state.active_document().display_name(), "amp.chn");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn doc_vars_expand_to_live_values() {
        let mut app = App::new();
        place_resistor(&mut app, 0, 0);
        app.dispatch(Command::SetInstanceProp {
            idx: 0,
            key: "value".into(),
            value: "10k".into(),
        });

        let doc = "R1 is {{R1}} ({{R1.value}}); missing: {{R9}} {{R1.nope}} {{open";
        let out = expand_doc_vars(doc, app.schematic(), &app.state.interner);
        assert_eq!(out, "R1 is 10k (10k); missing: {{R9}} {{R1.nope}} {{open");

        // Schematic edit propagates on next expansion — no stale copies.
        app.dispatch(Command::SetInstanceProp {
            idx: 0,
            key: "value".into(),
            value: "22k".into(),
        });
        let out = expand_doc_vars("{{R1}}", app.schematic(), &app.state.interner);
        assert_eq!(out, "22k");
    }

    #[test]
    fn place_device_then_undo_restores_count() {
        let mut app = App::new();
        assert_eq!(app.schematic().instances.len(), 0);

        place_resistor(&mut app, 100, 200);
        assert_eq!(app.schematic().instances.len(), 1);
        assert_eq!(app.schematic().instances.x[0], 100);
        assert_eq!(app.schematic().instances.kind[0], DeviceKind::Resistor);

        app.dispatch(Command::Undo);
        assert_eq!(app.schematic().instances.len(), 0);

        app.dispatch(Command::Redo);
        assert_eq!(app.schematic().instances.len(), 1);
    }

    #[test]
    fn add_wires_connectivity_resolves_shared_net() {
        let mut app = App::new();
        app.dispatch(Command::AddWire {
            x0: 0,
            y0: 0,
            x1: 100,
            y1: 0,
        });
        app.dispatch(Command::AddWire {
            x0: 100,
            y0: 0,
            x1: 200,
            y1: 0,
        });

        let conn = app.connectivity();
        assert_eq!(conn.nets.len(), 1);
        assert_eq!(conn.point_to_net.get(&(0, 0)), Some(&0));
        assert_eq!(conn.point_to_net.get(&(200, 0)), Some(&0));
    }

    #[test]
    fn connectivity_cache_invalidated_by_generation() {
        let mut app = App::new();
        app.dispatch(Command::AddWire {
            x0: 0,
            y0: 0,
            x1: 100,
            y1: 0,
        });
        assert_eq!(app.connectivity().nets.len(), 1);

        // Disconnected second wire must show up after the mutation bumps
        // the generation past the cached one.
        app.dispatch(Command::AddWire {
            x0: 500,
            y0: 500,
            x1: 600,
            y1: 500,
        });
        assert_eq!(app.connectivity().nets.len(), 2);
    }

    #[test]
    fn t_junction_merges_nets() {
        let mut app = App::new();
        app.dispatch(Command::AddWire {
            x0: 0,
            y0: 0,
            x1: 200,
            y1: 0,
        });
        app.dispatch(Command::AddWire {
            x0: 100,
            y0: -50,
            x1: 100,
            y1: 0,
        });
        assert_eq!(app.connectivity().nets.len(), 1);
    }

    #[test]
    fn nudge_coalescing_produces_single_undo_entry() {
        let mut app = App::new();
        place_resistor(&mut app, 0, 0);
        app.selection_mut().insert(ObjectRef::Instance(0));

        let before = app.active_doc().undo_history.len(); // snapshot from PlaceDevice
        app.dispatch(Command::NudgeRight);
        app.dispatch(Command::NudgeRight);
        app.dispatch(Command::NudgeDown);

        // All three nudges coalesce into one inverse MoveSelected entry.
        let doc = app.active_doc();
        assert_eq!(doc.undo_history.len(), before + 1);
        let snap_sz = app.state.tool.snap_size as i32;
        match doc.undo_history.back().unwrap() {
            UndoEntry::Inverse(Command::MoveSelected { dx, dy }) => {
                assert_eq!(*dx, -2 * snap_sz);
                assert_eq!(*dy, -snap_sz);
            }
            other => panic!("expected coalesced MoveSelected, got {other:?}"),
        }
        assert_eq!(app.schematic().instances.x[0], 2 * snap_sz);
        assert_eq!(app.schematic().instances.y[0], snap_sz);

        // One undo reverts the whole nudge run.
        app.dispatch(Command::Undo);
        assert_eq!(app.schematic().instances.x[0], 0);
        assert_eq!(app.schematic().instances.y[0], 0);
    }

    #[test]
    fn delete_selected_and_undo_snapshot() {
        let mut app = App::new();
        place_resistor(&mut app, 0, 0);
        app.dispatch(Command::AddWire {
            x0: 0,
            y0: 0,
            x1: 100,
            y1: 0,
        });
        app.selection_mut().insert(ObjectRef::Instance(0));
        app.selection_mut().insert(ObjectRef::Wire(0));

        app.dispatch(Command::DeleteSelected);
        assert_eq!(app.schematic().instances.len(), 0);
        assert_eq!(app.schematic().wires.len(), 0);

        app.dispatch(Command::Undo);
        assert_eq!(app.schematic().instances.len(), 1);
        assert_eq!(app.schematic().wires.len(), 1);
    }

    #[test]
    fn selection_remove_deleted_shifts_indices() {
        let mut sel = Selection::default();
        sel.insert(ObjectRef::Wire(0));
        sel.insert(ObjectRef::Wire(2));
        sel.insert(ObjectRef::Instance(2));
        sel.remove_deleted(ObjectRef::Wire(1));
        assert!(sel.contains(ObjectRef::Wire(0)));
        assert!(sel.contains(ObjectRef::Wire(1))); // was Wire(2)
        assert!(sel.contains(ObjectRef::Instance(2))); // other kind untouched
    }

    #[test]
    fn spatial_index_cell_coords_and_query() {
        assert_eq!(cell_coord(0), 0);
        assert_eq!(cell_coord(199), 0);
        assert_eq!(cell_coord(200), 1);
        assert_eq!(cell_coord(-1), -1);
        assert_eq!(cell_coord(-200), -1);
        assert_eq!(cell_coord(-201), -2);

        let mut sch = Schematic::default();
        sch.wires.push(Wire {
            net_name: None,
            x0: 10,
            y0: 20,
            x1: 500,
            y1: 20,
            color: Color::NONE,
            thickness: 1,
        });
        let idx = SpatialIndex::rebuild(&sch);
        // Spans multiple cells but deduplicates to one hit.
        let hits = idx.query_rect(-100, -100, 600, 100);
        assert_eq!(hits, vec![ObjectRef::Wire(0)]);
        assert!(idx.query_rect(1000, 1000, 2000, 2000).is_empty());
    }

    #[test]
    fn label_pin_names_net() {
        let mut app = App::new();
        app.dispatch(Command::AddWire {
            x0: 0,
            y0: 0,
            x1: 100,
            y1: 0,
        });
        app.dispatch(Command::PlaceDevice {
            symbol_path: "lab_pin".into(),
            name: "VOUT".into(),
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        });
        let conn = app.connectivity();
        assert_eq!(conn.nets.len(), 1);
        assert_eq!(conn.net_names[0], "VOUT");
    }

    #[test]
    fn rotate_and_flip_roundtrip_via_undo() {
        let mut app = App::new();
        place_resistor(&mut app, 40, 60);
        app.selection_mut().insert(ObjectRef::Instance(0));

        app.dispatch(Command::RotateCw);
        assert_eq!(app.schematic().instances.flags[0].rotation(), 1);
        app.dispatch(Command::Undo);
        assert_eq!(app.schematic().instances.flags[0].rotation(), 0);

        app.dispatch(Command::FlipHorizontal);
        assert!(app.schematic().instances.flags[0].flip());
        app.dispatch(Command::Undo);
        assert!(!app.schematic().instances.flags[0].flip());
    }

    #[test]
    fn net_naming_helpers() {
        assert!(is_auto_net_name("net1"));
        assert!(is_auto_net_name("net42"));
        assert!(!is_auto_net_name("VDD"));
        assert!(!is_auto_net_name("net"));

        assert_eq!(net_name_rank(""), 0);
        assert_eq!(net_name_rank("net1"), 1);
        assert_eq!(net_name_rank("0"), 2);
        assert_eq!(net_name_rank("VDD"), 3);
    }

    #[test]
    fn stimulus_lang_dispatch() {
        let mut app = App::new();
        assert_eq!(app.schematic().stimulus_lang, StimulusLang::NgSpice);
        app.dispatch(Command::SetStimulusLang("xyce".into()));
        assert_eq!(app.schematic().stimulus_lang, StimulusLang::Xyce);
        app.dispatch(Command::SetStimulusLang("bogus".into()));
        assert_eq!(app.schematic().stimulus_lang, StimulusLang::Xyce);
    }
}
