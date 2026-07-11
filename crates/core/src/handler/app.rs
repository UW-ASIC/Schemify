//! App/document/selection state: the data every other handler module operates on.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};

use lasso::Rodeo;
use rustc_hash::FxHashSet;

use crate::config::{LoadedPdk, ProjectConfig};
use crate::schemify::{
    Arc, Circle, Command, Connectivity, Instance, Line, Polygon, Rect, Schematic,
    Sym, Text, Tool, Wire,
};

use super::*;

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
    pub(crate) connectivity: Option<(u64, Connectivity)>,
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
            self.dispatch(Command::AddPolygon { points: pts }).or_status(self);
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
            })
            .or_status(self);
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

