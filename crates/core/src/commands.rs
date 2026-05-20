use crate::types::Color;

// ====================================================
// Single flat Command enum. All commands are undoable.
// String fields (not Sym) — handler interns on receipt.
// See ADR-003.
// ====================================================

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
        net_name: Option<String>,
        bus: bool,
    },

    // === Geometry ===
    AddLine { x0: i32, y0: i32, x1: i32, y1: i32 },
    AddRect { x: i32, y: i32, w: i32, h: i32 },
    AddCircle { cx: i32, cy: i32, radius: i32 },
    AddArc { cx: i32, cy: i32, radius: i32, start: f32, sweep: f32 },
    AddText { x: i32, y: i32, content: String },

    // === Movement ===
    MoveInstance { idx: usize, dx: i32, dy: i32 },
    MoveWire { idx: usize, dx: i32, dy: i32 },
    MoveSelected { dx: i32, dy: i32 },

    // === Properties ===
    SetInstanceProp { idx: usize, key: String, value: String },
    RenameInstance { idx: usize, new_name: String },
    RenameNet { old_name: String, new_name: String },
    SetSpiceCode(String),
    SetDocumentation(String),
    SetWireColor { idx: usize, color: Color },

    // === Simulation ===
    RunSim,

    // === Layout ===
    AutoLayout,

    // === Import ===
    ImportSpice { path: String },

    // === Plugins ===
    PluginsRefresh,
    PluginCommand { tag: String, payload: Vec<u8> },
    PluginMutation { tag: String, payload: Option<Vec<u8>> },
}

// ====================================================
// Tool Enum
// ====================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum Tool {
    #[default]
    Select = 0,
    Wire,
    Move,
    Pan,
    Line,
    Rect,
    Polygon,
    Arc,
    Circle,
    Text,
}
