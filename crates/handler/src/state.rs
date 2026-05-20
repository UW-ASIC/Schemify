use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;

use lasso::Rodeo;

use schemify_core::commands::{Command, Tool};
use schemify_core::devices::Pdk;
use schemify_core::schematic::{
    Arc, Circle, Instance, Line, Polygon, Rect, Schematic, Text, Wire,
};
use schemify_core::simulation::{SimResult, SpiceBackend};
use schemify_core::types::{Connectivity, DeviceKind, Sym};
use schemify_io::config::ProjectConfig;

pub const MAX_UNDO_HISTORY: usize = 64;
pub const MAX_COMMAND_QUEUE: usize = 64;

// ====================================================
// Types internal to handler (moved from core per ADR-001)
// ====================================================

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Origin {
    Unsaved,
    Buffer(String),
    File(PathBuf),
    Memory,
}

impl Default for Origin {
    fn default() -> Self {
        Self::Unsaved
    }
}


#[derive(Debug, Clone, Default)]
pub struct BackendAvailability {
    pub ngspice: bool,
    pub xyce: bool,
    pub ltspice: bool,
    pub spectre: bool,
    pub probed: bool,
}

// ====================================================
// Top-Level App State
// Hot  → read every frame (documents, gui, tool)
// Warm → project config, command queue, clipboard
// Cold → PDK, plugins, simulation backend
// ====================================================

pub struct AppState {
    /// String interner (shared across all documents).
    /// All Sym values in schematic data resolve through this.
    pub interner: Rodeo,

    // --- Hot: every frame ---
    pub documents: Vec<Document>,
    pub active_doc: usize,
    pub canvas: CanvasState,
    pub view: ViewState,
    pub tool: ToolState,
    pub status_msg: String,

    // --- Warm: project config + commands ---
    pub project_dir: PathBuf,
    pub config: ProjectConfig,
    pub command_queue: VecDeque<Command>,
    pub clipboard: Clipboard,
    pub highlighted_nets: HashSet<Sym>,

    // --- Panels & dialogs ---
    pub panels: PanelState,
    pub dialogs: DialogStates,
    pub editor: EditorState,
    pub ctx_menu: ContextMenu,

    // --- Cold: infrequent ---
    pub pdk: Option<Pdk>,
    pub hierarchy_stack: Vec<HierEntry>,
    pub last_netlist: String,
    pub sim_backend: SpiceBackend,
    pub backend_avail: BackendAvailability,
    pub settings: PersistentSettings,
    /// Opaque plugin blob storage, keyed by plugin ID
    pub plugin_data: HashMap<String, Vec<u8>>,

    // --- Flags ---
    pub quit_requested: bool,
    pub plugin_refresh_requested: bool,
    pub settings_reload_requested: bool,
}

impl AppState {
    pub fn new() -> Self {
        Self {
            interner: Rodeo::default(),

            documents: vec![Document::default()],
            active_doc: 0,
            canvas: CanvasState::default(),
            view: ViewState::default(),
            tool: ToolState::new(),
            status_msg: String::new(),

            project_dir: PathBuf::new(),
            config: ProjectConfig::default(),
            command_queue: VecDeque::with_capacity(MAX_COMMAND_QUEUE),
            clipboard: Clipboard::default(),
            highlighted_nets: HashSet::new(),

            panels: PanelState::default(),
            dialogs: DialogStates::default(),
            editor: EditorState::default(),
            ctx_menu: ContextMenu::default(),

            pdk: None,
            hierarchy_stack: Vec::new(),
            last_netlist: String::new(),
            sim_backend: SpiceBackend::default(),
            backend_avail: BackendAvailability::default(),
            settings: PersistentSettings::default(),
            plugin_data: HashMap::new(),

            quit_requested: false,
            plugin_refresh_requested: false,
            settings_reload_requested: false,
        }
    }

    pub fn active_document(&self) -> &Document {
        &self.documents[self.active_doc]
    }

    pub fn active_document_mut(&mut self) -> &mut Document {
        &mut self.documents[self.active_doc]
    }
}

// ====================================================
// Document (per open tab)
// ====================================================

#[derive(Debug, Clone, Default)]
pub struct Document {
    pub schematic: Schematic,
    pub name: String,
    pub origin: Origin,
    pub dirty: bool,

    // View
    pub viewport: Viewport,
    pub selection: Selection,

    // Undo/Redo (ring buffer, max 64 deep)
    pub undo_history: VecDeque<UndoEntry>,
    pub redo_history: VecDeque<UndoEntry>,

    // Cached (invalidated on mutation)
    pub connectivity: Option<Connectivity>,
    pub missing_symbols: HashMap<String, ()>,
    pub sim_results: Option<SimResult>,
    pub sim_generation: u32,
}

// ====================================================
// Viewport (pan + zoom per document)
// ====================================================

#[derive(Debug, Clone)]
pub struct Viewport {
    pub pan: [f32; 2],
    pub zoom: f32,
}

impl Viewport {
    pub const MIN_ZOOM: f32 = 0.01;
    pub const MAX_ZOOM: f32 = 50.0;

    pub fn zoom_in(&mut self) {
        self.zoom = (self.zoom * 1.2).min(Self::MAX_ZOOM);
    }

    pub fn zoom_out(&mut self) {
        self.zoom = (self.zoom / 1.2).max(Self::MIN_ZOOM);
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

// ====================================================
// Selection (sparse HashSet per object type)
// ====================================================

#[derive(Debug, Clone, Default)]
pub struct Selection {
    pub instances: HashSet<usize>,
    pub wires: HashSet<usize>,
    pub lines: HashSet<usize>,
    pub rects: HashSet<usize>,
    pub circles: HashSet<usize>,
    pub arcs: HashSet<usize>,
    pub texts: HashSet<usize>,
    pub polygons: HashSet<usize>,
}

impl Selection {
    pub fn clear(&mut self) {
        self.instances.clear();
        self.wires.clear();
        self.lines.clear();
        self.rects.clear();
        self.circles.clear();
        self.arcs.clear();
        self.texts.clear();
        self.polygons.clear();
    }

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

    pub fn count(&self) -> usize {
        self.instances.len()
            + self.wires.len()
            + self.lines.len()
            + self.rects.len()
            + self.circles.len()
            + self.arcs.len()
            + self.texts.len()
            + self.polygons.len()
    }
}

// ====================================================
// Tool & Input State
// ====================================================

#[derive(Debug, Clone)]
pub struct ToolState {
    pub active: Tool,
    pub wire_start: Option<[i32; 2]>,
    pub placement: Option<Placement>,
    pub draw: DrawState,
    pub snap_size: f32,
    pub snap_to_grid: bool,
    pub bus_mode: bool,
}

impl ToolState {
    pub fn new() -> Self {
        Self {
            active: Tool::default(),
            wire_start: None,
            placement: None,
            draw: DrawState::default(),
            snap_size: 10.0,
            snap_to_grid: true,
            bus_mode: false,
        }
    }
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

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum ArcStep {
    #[default]
    Center = 0,
    RadiusStart,
    Sweep,
}

// ====================================================
// View Flags (display toggles)
// ====================================================

#[derive(Debug, Clone)]
pub struct ViewFlags {
    pub fullscreen: bool,
    pub dark_mode: bool,
    pub fill_rects: bool,
    pub text_in_symbols: bool,
    pub symbol_details: bool,
    pub show_all_layers: bool,
    pub show_netlist: bool,
    pub crosshair: bool,
    pub wire_routing: bool,
    pub orthogonal_routing: bool,
    pub flat_netlist: bool,
    pub line_width: i16,
}

impl Default for ViewFlags {
    fn default() -> Self {
        Self {
            fullscreen: false,
            dark_mode: true,
            fill_rects: false,
            text_in_symbols: true,
            symbol_details: true,
            show_all_layers: true,
            show_netlist: true,
            crosshair: false,
            wire_routing: false,
            orthogonal_routing: false,
            flat_netlist: false,
            line_width: 1,
        }
    }
}

// ====================================================
// View State: rendering toggles and mode
// ====================================================

#[derive(Debug, Clone)]
pub struct ViewState {
    pub view_mode: ViewMode,
    pub view_flags: ViewFlags,
    pub show_grid: bool,
    pub canvas_size: [f32; 2],
}

impl Default for ViewState {
    fn default() -> Self {
        Self {
            view_mode: ViewMode::default(),
            view_flags: ViewFlags::default(),
            show_grid: true,
            canvas_size: [800.0, 600.0],
        }
    }
}

// ====================================================
// Panel layout state
// ====================================================

#[derive(Debug, Clone, Default)]
pub struct PanelState {
    pub left_panel_tab: LeftPanelTab,
    pub file_explorer: FileExplorerState,
    pub library_browser: LibraryBrowserState,
    pub plugins_ui: PluginUiState,
    pub optimizer_windows: Vec<OptimizerWindowState>,
}

// ====================================================
// Editor / command bar state
// ====================================================

#[derive(Debug, Clone, Default)]
pub struct EditorState {
    pub command_mode: bool,
    pub command_buf: String,
    pub text_entry_focused: bool,
    pub doc_editor: DocEditorState,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum ViewMode {
    #[default]
    Schematic = 0,
    Symbol,
    Documentation,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum LeftPanelTab {
    #[default]
    FileExplorer = 0,
    Library,
}

// ====================================================
// Canvas Interaction State
// ====================================================

#[derive(Debug, Clone, Default)]
pub struct CanvasState {
    pub last_click_time: f64,
    pub drag_last: [f32; 2],
    pub last_click_pos: [f32; 2],
    pub move_press_pixel: [f32; 2],
    pub move_start_world: [i32; 2],
    pub move_hit_idx: Option<usize>,
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
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum PanMode {
    #[default]
    Off = 0,
    Grab,
}

// ====================================================
// Dialog States
// ====================================================

#[derive(Debug, Clone, Default)]
pub struct DialogStates {
    pub find: FindDialogState,
    pub props: PropsDialogState,
    pub multi_props: MultiPropsDialogState,
    pub keybinds: DialogWindow,
    pub spice_code: SpiceCodeDialogState,
    pub new_prim: NewPrimDialogState,
    pub marketplace: DialogWindow,
    pub settings: SettingsDialogState,
    pub import: ImportDialogState,
}

#[derive(Debug, Clone, Default)]
pub struct DialogWindow {
    pub is_open: bool,
    pub position: Option<[f32; 2]>,
    pub size: Option<[f32; 2]>,
}

#[derive(Debug, Clone, Default)]
pub struct FindDialogState {
    pub is_open: bool,
    pub query: String,
    pub results: Vec<FindResult>,
    pub selected: Option<usize>,
}

#[derive(Debug, Clone)]
pub struct FindResult {
    pub label: String,
    pub object_type: String,
    pub index: usize,
}

#[derive(Debug, Clone, Default)]
pub struct PropsDialogState {
    pub is_open: bool,
    pub view_only: bool,
    pub initialized: bool,
    pub inst_idx: usize,
    pub name_buf: String,
    pub prop_values: Vec<String>,
}

#[derive(Debug, Clone, Default)]
pub struct MultiPropsDialogState {
    pub is_open: bool,
    pub common_props: Vec<(String, String)>,
}

#[derive(Debug, Clone, Default)]
pub struct SpiceCodeDialogState {
    pub is_open: bool,
    pub buf: String,
}

#[derive(Debug, Clone, Default)]
pub struct NewPrimDialogState {
    pub is_open: bool,
    pub prim_type: PrimType,
    pub name_buf: String,
    pub pins_buf: String,
    pub status_msg: String,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum PrimType {
    #[default]
    Behavioral = 0,
    Spice,
    Digital,
}

#[derive(Debug, Clone, Default)]
pub struct SettingsDialogState {
    pub is_open: bool,
    pub active_tab: SettingsTab,
    pub editing_theme_json: bool,
    pub dirty: bool,
    pub selected_preset: Option<u16>,
    pub json_edit_buf: String,
    pub status_msg: String,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum SettingsTab {
    #[default]
    Theme = 0,
    Keybinds,
}

#[derive(Debug, Clone, Default)]
pub struct ImportDialogState {
    pub is_open: bool,
    pub format: ImportFormat,
    pub status_msg: String,
    pub path_buf: String,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum ImportFormat {
    #[default]
    Unknown = 0,
    Xschem,
    Spice,
    Virtuoso,
}

// ====================================================
// File Explorer State
// ====================================================

#[derive(Debug, Clone, Default)]
pub struct FileExplorerState {
    pub query: String,
    pub selected_section: Option<usize>,
    pub selected_file: Option<usize>,
    pub scanned: bool,
    pub sort_order: FileSortOrder,
    pub preview_name: String,
    pub preview_path: PathBuf,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum FileSortOrder {
    #[default]
    DirsFirst = 0,
    NameAsc,
    NameDesc,
    ExtAsc,
}

// ====================================================
// Library Browser State
// ====================================================

#[derive(Debug, Clone, Default)]
pub struct LibraryBrowserState {
    pub selected_prim: Option<usize>,
}

// ====================================================
// Optimizer Window State
// ====================================================

#[derive(Debug, Clone, Default)]
pub struct OptimizerWindowState {
    // Setup
    pub device_entries: Vec<DeviceEntry>,
    pub spec_entries: Vec<SpecEntry>,
    pub match_entries: Vec<MatchEntry>,

    // Run
    pub status: OptimizationStatus,
    pub generation: u32,
    pub max_generations: u32,
    pub feasible_count: u32,
    pub best_summary: String,
    pub log: String,
    pub cancelled: bool,

    // Results
    pub results: Vec<ResultRow>,
    pub selected_result: Option<usize>,
    pub apply_checks: Vec<bool>,

    // Sweep
    pub sweep_device_idx: Option<usize>,
    pub sweep_analytical: bool,
    pub sweep_data: Vec<SweepPoint>,

    // Discovery
    pub discovered_devices: Vec<DiscoveredDevice>,
    pub discovered_measurements: Vec<DiscoveredMeasurement>,
    pub discovery_done: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum OptimizationStatus {
    #[default]
    Idle = 0,
    Running,
    Completed,
    Failed,
}

#[derive(Debug, Clone, Default)]
pub struct DeviceEntry {
    pub name: String,
    pub param: String,
    pub min: f64,
    pub max: f64,
    pub enabled: bool,
}

#[derive(Debug, Clone, Default)]
pub struct SpecEntry {
    pub name: String,
    pub target: f64,
    pub weight: f64,
    pub enabled: bool,
}

#[derive(Debug, Clone, Default)]
pub struct MatchEntry {
    pub device_a: String,
    pub device_b: String,
    pub param: String,
    pub enabled: bool,
}

#[derive(Debug, Clone, Default)]
pub struct ResultRow {
    pub values: Vec<f64>,
    pub feasible: bool,
}

#[derive(Debug, Clone, Default)]
pub struct SweepPoint {
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, Default)]
pub struct DiscoveredDevice {
    pub name: String,
    pub kind: DeviceKind,
    pub params: Vec<String>,
}

#[derive(Debug, Clone, Default)]
pub struct DiscoveredMeasurement {
    pub name: String,
    pub unit: String,
}

// ====================================================
// Context Menu
// ====================================================

#[derive(Debug, Clone, Default)]
pub struct ContextMenu {
    pub open: bool,
    pub pixel_pos: [f32; 2],
    pub inst_idx: Option<usize>,
    pub wire_idx: Option<usize>,
}

// ====================================================
// Plugin UI State
// ====================================================

#[derive(Debug, Clone, Default)]
pub struct PluginUiState {
    pub panels: Vec<PluginPanel>,
    pub keybinds: Vec<PluginKeybind>,
    pub commands: Vec<PluginCommand>,
    pub marketplace: MarketplaceState,
    pub startup_download: StartupDownloadState,
}

#[derive(Debug, Clone)]
pub struct PluginPanel {
    pub id: u16,
    pub name: String,
    pub layout: PanelLayout,
    pub keybind: Option<u8>,
    pub load_state: PluginLoadState,
    pub visible: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum PanelLayout {
    #[default]
    Overlay = 0,
    LeftSidebar,
    RightSidebar,
    BottomBar,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum PluginLoadState {
    #[default]
    LazyPending = 0,
    Loading,
    Failed,
    Loaded,
}

#[derive(Debug, Clone)]
pub struct PluginKeybind {
    pub plugin_id: u16,
    pub key: String,
    pub action: String,
}

#[derive(Debug, Clone)]
pub struct PluginCommand {
    pub plugin_id: u16,
    pub name: String,
    pub description: String,
}

#[derive(Debug, Clone, Default)]
pub struct MarketplaceState {
    pub entries: Vec<MarketplaceEntry>,
    pub readme_text: String,
    pub selected: Option<usize>,
    pub registry_status: LoadStatus,
    pub readme_status: LoadStatus,
    pub install_status: LoadStatus,
    pub custom_url: String,
}

#[derive(Debug, Clone, Default)]
pub struct MarketplaceEntry {
    pub name: String,
    pub description: String,
    pub version: String,
    pub installed: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum LoadStatus {
    #[default]
    Idle = 0,
    Loading,
    Done,
    Failed,
}

#[derive(Debug, Clone, Default)]
pub struct StartupDownloadState {
    pub active: bool,
    pub total: u32,
    pub done: u32,
    pub failed: bool,
    pub current_name: String,
}

// ====================================================
// Documentation Editor State
// ====================================================

#[derive(Debug, Clone, Default)]
pub struct DocEditorState {
    pub buf: String,
    pub cursor_pos: usize,
    pub scroll_y: f32,
    pub mode: DocEditorMode,
    pub pending_sync: bool,
    pub loaded: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum DocEditorMode {
    #[default]
    Edit = 0,
    Preview,
}

// ====================================================
// Clipboard (AoS copies of schematic objects)
// ====================================================

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

    pub fn clear(&mut self) {
        self.instances.clear();
        self.wires.clear();
        self.lines.clear();
        self.rects.clear();
        self.circles.clear();
        self.arcs.clear();
        self.texts.clear();
        self.polygons.clear();
    }
}

// ====================================================
// Undo/Redo Entry
// ====================================================

#[derive(Debug, Clone)]
pub enum UndoEntry {
    /// Lightweight inverse command (for invertible ops: move, rotate, zoom)
    Inverse(Command),
    /// Full schematic snapshot (for non-invertible ops: delete, place)
    Snapshot(Schematic),
}

// ====================================================
// Hierarchy Navigation (breadcrumb stack)
// ====================================================

#[derive(Debug, Clone)]
pub struct HierEntry {
    pub doc_idx: usize,
    pub instance_idx: usize,
}

// ====================================================
// Persistent Settings (loaded from ~/.config/SchemifyRS/)
// ====================================================

#[derive(Debug, Clone)]
pub struct PersistentSettings {
    pub theme_json: String,
    pub keybinds: HashMap<String, String>,
    pub ui_scale: f32,
    pub theme_preset: String,
    pub last_session: LastSessionState,
}

impl Default for PersistentSettings {
    fn default() -> Self {
        Self {
            theme_json: String::new(),
            keybinds: HashMap::new(),
            ui_scale: 1.0,
            theme_preset: String::from("default"),
            last_session: LastSessionState::default(),
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct LastSessionState {
    pub open_files: Vec<PathBuf>,
    pub active_tab: usize,
    pub window_size: [f32; 2],
    pub window_pos: Option<[f32; 2]>,
    pub project_dir: Option<PathBuf>,
}
