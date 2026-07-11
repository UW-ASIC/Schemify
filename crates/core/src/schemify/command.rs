//! Command and Tool enums — the full UI/scripting mutation vocabulary.
//! Every state change routes through `App::dispatch(Command)`.

use super::*;

#[derive(Debug, Clone)]
pub enum Command {
    // === View ===
    ZoomIn,
    ZoomOut,
    ZoomFit,
    ZoomReset,
    ToggleFullscreen,
    ToggleColorScheme,
    ToggleGrid,

    // === File ===
    FileNew,
    FileOpen,
    FileSave,
    FileSaveAs,
    NewTab,
    CloseTab(usize),
    CloseActiveTab,
    SwitchTab(usize),
    ReloadFromDisk,

    // === Selection ===
    SelectAll,
    SelectNone,
    InvertSelection,

    // === Clipboard ===
    Copy,
    Cut,
    Paste,

    // === Tool ===
    SetTool(Tool),

    // === Dialogs ===
    OpenFindDialog,
    OpenPropsDialog,
    OpenSettings,
    OpenSpiceCodeEditor,
    OpenNewPrimDialog,
    OpenMarketplace,
    OpenImportDialog,
    OpenLibraryBrowser,
    OpenFileExplorer,

    // === Undo/Redo ===
    Undo,
    Redo,

    // === Deletion ===
    DeleteSelected,
    DeleteInstance(usize),
    DeleteWire(usize),

    // === Duplication ===
    DuplicateSelected,

    // === Transform ===
    RotateCw,
    RotateCcw,
    FlipHorizontal,
    FlipVertical,
    NudgeUp,
    NudgeDown,
    NudgeLeft,
    NudgeRight,
    AlignToGrid,

    // === Placement ===
    PlaceDevice {
        symbol_path: String,
        name: String,
        x: i32,
        y: i32,
        rotation: u8,
        flip: bool,
    },

    // === Wiring ===
    AddWire {
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
    },

    // === Geometry ===
    AddLine {
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
    },
    AddRect {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
    },
    AddCircle {
        cx: i32,
        cy: i32,
        radius: i32,
    },
    AddArc {
        cx: i32,
        cy: i32,
        radius: i32,
        start: f32,
        sweep: f32,
    },
    AddText {
        x: i32,
        y: i32,
        content: String,
    },
    AddPolygon {
        points: Vec<[i32; 2]>,
    },

    // === Movement ===
    MoveInstance {
        idx: usize,
        dx: i32,
        dy: i32,
    },
    MoveWire {
        idx: usize,
        dx: i32,
        dy: i32,
    },
    MoveSelected {
        dx: i32,
        dy: i32,
    },

    // === Properties ===
    SetInstanceProp {
        idx: usize,
        key: String,
        value: String,
    },
    RenameInstance {
        idx: usize,
        new_name: String,
    },
    SetSpiceCode(String),
    SetDocumentation(String),
    SetWireColor {
        idx: usize,
        color: Color,
    },

    // === Simulation ===
    RunSim,
    ExportNetlist,
    SetStimulusLang(String),
    SetSimBackend(String),
    SetSimCorner(String),

    // === Symbol ===
    GenerateSymbolFromSchematic,

    // === Bus ===
    AddBus {
        label: String,
        width: u16,
        start_bit: u16,
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
    },
    DeleteBus(usize),
    SetBusWidth {
        idx: usize,
        width: u16,
    },
    RenameBus {
        idx: usize,
        new_name: String,
    },
    AddBusRipper {
        bus_idx: u32,
        bit: u16,
        x: i32,
        y: i32,
        direction: u8,
    },
    DeleteBusRipper(usize),

    // === Wire Editing ===
    SplitWire {
        idx: usize,
        x: i32,
        y: i32,
    },

    // === Alignment ===
    AlignLeft,
    AlignRight,
    AlignTop,
    AlignBottom,
    AlignCenterH,
    AlignCenterV,
    DistributeH,
    DistributeV,

    // === Export ===
    ExportSpice {
        path: String,
    },

    // === Import ===
    ImportSpice {
        path: String,
    },

    // === Marketplace ===
    MarketplaceFetch,
    MarketplaceInstall {
        name: String,
    },
    MarketplaceUninstall {
        name: String,
    },

    // === Plugins ===
    PluginsRefresh,
    PluginCommand {
        tag: String,
        payload: Vec<u8>,
    },
    /// Re-read Config.toml and re-resolve the PDK (after a plugin or
    /// external tool edited it).
    ReloadProjectConfig,

    // === Waveform viewer (tab with doc.wave = Some) ===
    /// Open a `.raw` file: into the active wave tab if there is one,
    /// otherwise creates a new wave tab.
    WaveOpen {
        path: String,
    },
    /// Re-read all loaded `.raw` files of the active wave tab.
    WaveReload,
    /// Plot an expression (`v(out)`, `db(v(out)/v(in))`, …). `file`/`pane`
    /// default to the last-opened file and the active pane.
    WaveAddTrace {
        expr: String,
        file: Option<u16>,
        block: u16,
        pane: Option<u16>,
    },
    WaveRemoveTrace(u32),
    WaveClearTraces,
    WaveSetTraceStyle {
        idx: u32,
        color: Color,
        width: f32,
        /// 0 = solid, 1 = dash, 2 = dot.
        line_style: u8,
        visible: bool,
    },
    WaveAddPane,
    WaveRemovePane(u16),
    WaveSetActivePane(u16),
    /// cursor: 0 = A, 1 = B.
    WaveSetCursor {
        cursor: u8,
        x: f64,
        visible: bool,
    },
    WaveSetXLog(bool),
    WaveSetXRange {
        min: f64,
        max: f64,
    },
    WaveSetYRange {
        pane: u16,
        min: f64,
        max: f64,
    },
    WaveZoomFit,
    WaveExportCsv {
        path: String,
    },

    // === Optimizer (each instance is its own native window; any number
    // may be open at once) ===
    /// Create a new optimizer instance and open its window. Empty name
    /// gets a default ("Optimizer N").
    OptimizerNew {
        name: String,
    },
    /// Close the window and drop the instance.
    OptimizerClose {
        id: u32,
    },
    /// Show/hide the window without dropping the instance state.
    OptimizerSetWindowOpen {
        id: u32,
        open: bool,
    },
    OptimizerAddParam {
        id: u32,
        name: String,
        min: f64,
        max: f64,
        init: f64,
    },
    OptimizerRemoveParam {
        id: u32,
        name: String,
    },
    /// `target`: "min", "max", or a number to approach.
    OptimizerAddObjective {
        id: u32,
        name: String,
        target: String,
        weight: f64,
    },
    OptimizerRemoveObjective {
        id: u32,
        name: String,
    },
    /// `algorithm`: "random" or "nelder-mead".
    OptimizerSetAlgorithm {
        id: u32,
        algorithm: String,
    },
    /// Record measured objective values. `params` = None evaluates the
    /// pending suggested candidate; Some(p) records an external point.
    OptimizerReport {
        id: u32,
        params: Option<Vec<f64>>,
        measured: Vec<f64>,
    },
    /// Clear history + algorithm state, keep params/objectives.
    OptimizerReset {
        id: u32,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum Tool {
    #[default]
    Select = 0,
    Wire,
    Bus,
    BusRipper,
    Move,
    Pan,
    Line,
    Rect,
    Polygon,
    Arc,
    Circle,
    Text,
}

// ====================================================
// Embedded `.chn_prim` primitives — built-in symbol geometry + pin positions.
// Each file is embedded via include_str! (repo-root primitives/) and parsed
// once at first access via LazyLock.
// ====================================================

// ── Drawing primitives (compact i16, used by display for symbol rendering) ──
