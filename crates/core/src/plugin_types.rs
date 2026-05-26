/// A color that can be either a literal RGBA value or a reference to a theme token.
/// When rendering, token references are resolved against the active ThemeTokens.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(untagged)]
pub enum ThemeColor {
    /// Reference a named theme token (e.g. "accent", "error", "text_primary").
    Token(String),
    /// Literal RGBA color.
    Literal([u8; 4]),
}

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

// ── Plugin Widget Tree ─────────────────────────────────────────────────────

/// Severity level for Alert widgets.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AlertLevel {
    Info,
    Warn,
    Error,
    Success,
}

/// A single node in the plugin widget tree.
///
/// Plugins push a `Vec<WidgetNode>` via `panels/update_widgets` to populate
/// their registered panels.  The host renders these each frame using egui.
///
/// JSON encoding uses serde's default externally-tagged format:
/// ```json
/// {"Label": "Hello"}
/// {"Button": {"label": "Run", "action": "run_lint"}}
/// {"Section": {"label": "Options", "children": [...]}}
/// ```
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub enum WidgetNode {
    // ── Text ────────────────────────────────────────────────────────────────

    /// Plain text label.
    Label(String),

    /// Larger heading text.
    Heading(String),

    /// Styled text with optional color, bold, italic, size.
    RichText {
        text: String,
        #[serde(default)]
        color: Option<ThemeColor>,
        #[serde(default)]
        bold: bool,
        #[serde(default)]
        italic: bool,
        #[serde(default)]
        size: Option<f32>,
    },

    /// Monospace code block.
    Code(String),

    // ── Actions ─────────────────────────────────────────────────────────────

    /// Standard button. Dispatches `action` on click.
    Button {
        label: String,
        action: String,
    },

    /// Clickable hyperlink-style text. Dispatches `action` on click.
    LinkButton {
        label: String,
        action: String,
    },

    // ── Toggles & Selection ─────────────────────────────────────────────────

    /// Checkbox toggle. Sends `action` with bool payload.
    Toggle {
        label: String,
        value: bool,
        action: String,
    },

    /// Exclusive radio button group. Sends `action` with selected index.
    RadioGroup {
        label: String,
        options: Vec<String>,
        #[serde(default)]
        selected: usize,
        action: String,
    },

    /// Dropdown / combo box. Sends `action` with selected index.
    Dropdown {
        label: String,
        options: Vec<String>,
        #[serde(default)]
        selected: usize,
        action: String,
    },

    // ── Numeric ─────────────────────────────────────────────────────────────

    /// Horizontal slider. Sends `action` with f64 value.
    Slider {
        label: String,
        min: f64,
        max: f64,
        value: f64,
        #[serde(default)]
        step: Option<f64>,
        action: String,
    },

    /// Numeric drag-value input. Sends `action` with f64 value.
    NumberInput {
        label: String,
        value: f64,
        #[serde(default)]
        min: Option<f64>,
        #[serde(default)]
        max: Option<f64>,
        #[serde(default)]
        step: Option<f64>,
        action: String,
    },

    // ── Text Entry ──────────────────────────────────────────────────────────

    /// Single-line text input. Sends `action` with string payload on change.
    TextInput {
        label: String,
        #[serde(default)]
        value: String,
        #[serde(default)]
        placeholder: Option<String>,
        action: String,
    },

    // ── Color ───────────────────────────────────────────────────────────────

    /// RGBA color picker. Sends `action` with [r,g,b,a] payload.
    ColorPicker {
        label: String,
        color: [u8; 4],
        action: String,
    },

    // ── Display ─────────────────────────────────────────────────────────────

    /// Progress bar (0.0 – 1.0).
    ProgressBar {
        #[serde(default)]
        label: Option<String>,
        value: f32,
        #[serde(default)]
        color: Option<ThemeColor>,
    },

    /// Key-value pairs rendered as a two-column grid.
    KeyValue {
        entries: Vec<[String; 2]>,
    },

    /// Tabular data with headers.  Optional `action` sends row index on click.
    Table {
        headers: Vec<String>,
        rows: Vec<Vec<String>>,
        #[serde(default)]
        action: Option<String>,
    },

    /// Colored alert box (info / warn / error / success).
    Alert {
        level: AlertLevel,
        message: String,
    },

    /// Small inline badge / tag.
    Badge {
        text: String,
        #[serde(default)]
        color: Option<ThemeColor>,
    },

    // ── Layout ──────────────────────────────────────────────────────────────

    /// Horizontal line separator.
    Separator,

    /// Vertical space (height in logical pixels).
    Spacer(f32),

    /// Collapsible section with nested children.
    Section {
        label: String,
        #[serde(default)]
        collapsed: bool,
        #[serde(default)]
        children: Vec<WidgetNode>,
    },

    /// Tabbed pane.  `children[i]` is the widget list for tab `labels[i]`.
    /// Sends `action` with selected tab index on switch.
    Tabs {
        labels: Vec<String>,
        #[serde(default)]
        selected: usize,
        action: String,
        #[serde(default)]
        children: Vec<Vec<WidgetNode>>,
    },

    /// Horizontal layout group.
    Horizontal {
        children: Vec<WidgetNode>,
    },

    /// Boxed group with optional title.
    Group {
        #[serde(default)]
        label: Option<String>,
        children: Vec<WidgetNode>,
    },
}

