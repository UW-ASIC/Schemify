/// Named locations where plugins can insert content.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
pub enum SlotId {
    LeftSidebar,
    RightSidebar,
    BottomBar,
    Toolbar,
    MenuBar,
    CanvasOverlay,
    StatusBar,
}

/// A plugin-registered panel.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct PanelRegistration {
    pub plugin_id: String,
    pub name: String,
    pub slot: SlotId,
    pub priority: i32,
    pub default_visible: bool,
}

/// A plugin-registered command.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CommandRegistration {
    pub plugin_id: String,
    pub name: String,
    pub description: String,
    pub keybind: Option<String>,
}

/// Serializable overlay shape (no egui dependency).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub enum OverlayShape {
    Line {
        x0: f32, y0: f32,
        x1: f32, y1: f32,
        color: [u8; 4],
        width: f32,
    },
    Circle {
        cx: f32, cy: f32,
        radius: f32,
        stroke: [u8; 4],
        fill: Option<[u8; 4]>,
        width: f32,
    },
    Rect {
        x: f32, y: f32,
        w: f32, h: f32,
        stroke: [u8; 4],
        fill: Option<[u8; 4]>,
        width: f32,
    },
    Text {
        x: f32, y: f32,
        content: String,
        color: [u8; 4],
        size: f32,
    },
    Marker {
        x: f32, y: f32,
        kind: MarkerKind,
        color: [u8; 4],
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum MarkerKind {
    Error,
    Warning,
    Info,
    Pin,
}

/// A named overlay layer from a plugin.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct OverlayLayer {
    pub plugin_id: String,
    pub name: String,
    pub z_order: i32,
    pub visible: bool,
    pub shapes: Vec<OverlayShape>,
}

