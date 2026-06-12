//! Schemify plugin system: subprocess plugins speaking JSON-RPC 2.0 over
//! newline-delimited JSON on stdin/stdout.
//!
//! Host side: [`PluginManifest`] (plugin.toml), [`SubprocessTransport`],
//! capability negotiation ([`negotiate`]), and [`PluginManager`] whose
//! [`PluginManager::tick`] drains plugin messages into [`PluginHostAction`]s.
//!
//! Guest side: [`sdk::PluginRuntime`] for writing plugins in Rust.
//!
//! All plugin-facing wire types (overlay shapes, widget tree, theme values)
//! live in this crate — they are protocol types, owned by the protocol.

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Write as IoWrite};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

// ═══════════════════════════════════════════════════════════════════════════
// Plugin-facing wire types
// ═══════════════════════════════════════════════════════════════════════════

/// Where a panel is placed. Wire type for the `panels/register` slot field.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[repr(u8)]
pub enum PanelLayout {
    #[default]
    Overlay = 0,
    LeftSidebar,
    RightSidebar,
    BottomBar,
}

/// A color: literal RGBA or a named theme-token reference.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ThemeColor {
    /// Reference a named theme token (e.g. "accent", "error").
    Token(String),
    /// Literal RGBA color.
    Literal([u8; 4]),
}

/// A single theme value.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ThemeValue {
    Color([u8; 4]),
    Float(f32),
    Bool(bool),
    Int(i32),
}

/// Flat map of named theme tokens (payload of `state/theme_changed`).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ThemeTokens {
    pub tokens: HashMap<String, ThemeValue>,
}

/// A plugin's theme override set (payload of `theme/override` + plugin id).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ThemeOverride {
    pub plugin_id: String,
    pub priority: i32,
    pub overrides: HashMap<String, ThemeValue>,
}

/// A plugin-registered panel.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PanelRegistration {
    pub plugin_id: String,
    pub name: String,
    pub slot: PanelLayout,
    pub priority: i32,
    pub default_visible: bool,
}

/// A plugin-registered command.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommandRegistration {
    pub plugin_id: String,
    pub name: String,
    pub description: String,
    pub keybind: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MarkerKind {
    Error,
    Warning,
    Info,
    Pin,
}

/// Serializable overlay shape (no renderer dependency).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum OverlayShape {
    Line {
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        color: [u8; 4],
        width: f32,
    },
    Circle {
        cx: f32,
        cy: f32,
        radius: f32,
        stroke: [u8; 4],
        fill: Option<[u8; 4]>,
        width: f32,
    },
    Rect {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        stroke: [u8; 4],
        fill: Option<[u8; 4]>,
        width: f32,
    },
    Text {
        x: f32,
        y: f32,
        content: String,
        color: [u8; 4],
        size: f32,
    },
    Marker {
        x: f32,
        y: f32,
        kind: MarkerKind,
        color: [u8; 4],
    },
}

/// A named overlay layer from a plugin.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OverlayLayer {
    pub plugin_id: String,
    pub name: String,
    pub z_order: i32,
    pub visible: bool,
    pub shapes: Vec<OverlayShape>,
}

/// Severity level for Alert widgets.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
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
/// their registered panels. JSON encoding is serde's default externally-tagged
/// format: `{"Label": "Hello"}`, `{"Button": {"label": "Run", "action": "x"}}`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum WidgetNode {
    // ── Text ──
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

    // ── Actions ──
    /// Standard button. Dispatches `action` on click.
    Button { label: String, action: String },
    /// Clickable hyperlink-style text. Dispatches `action` on click.
    LinkButton { label: String, action: String },

    // ── Toggles & selection ──
    /// Checkbox toggle. Sends `action` with bool payload.
    Toggle {
        label: String,
        value: bool,
        action: String,
    },
    /// Exclusive radio group. Sends `action` with selected index.
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

    // ── Numeric ──
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

    // ── Text entry ──
    /// Single-line text input. Sends `action` with string payload on change.
    TextInput {
        label: String,
        #[serde(default)]
        value: String,
        #[serde(default)]
        placeholder: Option<String>,
        action: String,
    },

    // ── Color ──
    /// RGBA color picker. Sends `action` with [r,g,b,a] payload.
    ColorPicker {
        label: String,
        color: [u8; 4],
        action: String,
    },

    // ── Display ──
    /// Progress bar (0.0 – 1.0).
    ProgressBar {
        #[serde(default)]
        label: Option<String>,
        value: f32,
        #[serde(default)]
        color: Option<ThemeColor>,
    },
    /// Key-value pairs rendered as a two-column grid.
    KeyValue { entries: Vec<[String; 2]> },
    /// Tabular data with headers. Optional `action` sends row index on click.
    Table {
        headers: Vec<String>,
        rows: Vec<Vec<String>>,
        #[serde(default)]
        action: Option<String>,
    },
    /// Colored alert box.
    Alert { level: AlertLevel, message: String },
    /// Small inline badge / tag.
    Badge {
        text: String,
        #[serde(default)]
        color: Option<ThemeColor>,
    },

    // ── Layout ──
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
    /// Tabbed pane. `children[i]` pairs with `labels[i]`. Sends `action` with
    /// selected tab index on switch.
    Tabs {
        labels: Vec<String>,
        #[serde(default)]
        selected: usize,
        action: String,
        #[serde(default)]
        children: Vec<Vec<WidgetNode>>,
    },
    /// Horizontal layout group.
    Horizontal { children: Vec<WidgetNode> },
    /// Boxed group with optional title.
    Group {
        #[serde(default)]
        label: Option<String>,
        children: Vec<WidgetNode>,
    },

    // ── Media ──
    /// Image loaded from a file path (PNG/JPEG/SVG). Optional `action`
    /// fires with `[x, y]` relative click coordinates (0.0–1.0).
    Image {
        path: String,
        #[serde(default)]
        width: Option<f32>,
        #[serde(default)]
        action: Option<String>,
    },
}

/// Lifecycle state of a hosted plugin process.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PluginLifecycle {
    Discovered,
    Starting,
    Running,
    Stopping,
    Stopped,
    Error,
}

/// Action the host app must take in response to a plugin message.
///
/// Emitted by [`PluginManager::tick`]; consumed by the app layer. `Query*` and
/// `ErrorResponse` require a JSON-RPC response sent back via the manager.
#[derive(Debug)]
pub enum PluginHostAction {
    RegisterPanel(PanelRegistration),
    RegisterCommand(CommandRegistration),
    UpdateWidgets {
        plugin_id: String,
        panel_name: String,
        widgets: Vec<WidgetNode>,
    },
    UpdateOverlay(OverlayLayer),
    ThemeOverride(ThemeOverride),
    DispatchCommand {
        plugin_id: String,
        command_json: Value,
    },
    SetStatus {
        plugin_id: String,
        message: String,
    },
    Log {
        plugin_id: String,
        level: String,
        message: String,
    },
    QueryInstances {
        plugin_id: String,
        request_id: u32,
    },
    QueryNets {
        plugin_id: String,
        request_id: u32,
    },
    QueryTheme {
        plugin_id: String,
        request_id: u32,
    },
    QueryProject {
        plugin_id: String,
        request_id: u32,
    },
    QueryPdk {
        plugin_id: String,
        request_id: u32,
    },
    QueryNetlist {
        plugin_id: String,
        request_id: u32,
    },
    QueryOptimizers {
        plugin_id: String,
        request_id: u32,
        /// `Some(id)` = full state of one instance; `None` = summary list.
        id: Option<u32>,
    },
    ErrorResponse {
        plugin_id: String,
        request_id: u32,
        code: i32,
        message: String,
    },
}

// ═══════════════════════════════════════════════════════════════════════════
// Errors
// ═══════════════════════════════════════════════════════════════════════════

/// Errors originating from the plugin host.
#[derive(Debug, thiserror::Error)]
pub enum PluginError {
    /// JSON serialization of an outgoing message failed.
    #[error("encode failed: {0}")]
    Encode(#[from] serde_json::Error),
    /// Transport-level error (spawn, send, recv).
    #[error(transparent)]
    Transport(#[from] TransportError),
    /// No plugin with this id.
    #[error("unknown plugin: {0}")]
    UnknownPlugin(String),
    /// Operation requires the plugin to be running.
    #[error("plugin {0} is not running")]
    NotRunning(String),
    /// Plugin is already running or starting.
    #[error("plugin {0} is already running")]
    AlreadyRunning(String),
    /// Plugin is mid-shutdown.
    #[error("plugin {0} is stopping")]
    Stopping(String),
}

/// Errors arising from plugin transport operations.
#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error("spawn failed: {0}")]
    SpawnFailed(String),
    #[error("send failed: {0}")]
    SendFailed(String),
    #[error("recv failed: {0}")]
    RecvFailed(String),
    #[error("transport not running")]
    NotRunning,
}

/// Errors from manifest loading/validation.
#[derive(Debug, thiserror::Error)]
pub enum ManifestError {
    #[error("reading {path}: {err}")]
    Io { path: PathBuf, err: std::io::Error },
    #[error("parsing {path}: {err}")]
    Parse { path: PathBuf, err: toml::de::Error },
    #[error("invalid plugin id {0:?}: {1}")]
    InvalidId(String, String),
}

// ═══════════════════════════════════════════════════════════════════════════
// Manifest (plugin.toml)
// ═══════════════════════════════════════════════════════════════════════════

/// Capability flags declared in the manifest.
#[derive(Debug, Clone, Copy, Default, Deserialize)]
pub struct ManifestCapabilities {
    #[serde(default)]
    pub panels: bool,
    #[serde(default)]
    pub commands: bool,
    #[serde(default)]
    pub overlays: bool,
    #[serde(default)]
    pub theme: bool,
    /// Access to optimizer instances: `state/query_optimizers` plus the
    /// `Optimizer*` commands via `commands/dispatch`.
    #[serde(default)]
    pub optimizer: bool,
}

/// A panel declared in the manifest.
#[derive(Debug, Clone, Deserialize)]
pub struct ManifestPanel {
    pub name: String,
    pub slot: String,
    #[serde(default)]
    pub priority: i32,
}

/// A command declared in the manifest.
#[derive(Debug, Clone, Deserialize)]
pub struct ManifestCommand {
    pub name: String,
    #[serde(default)]
    pub description: String,
    pub keybind: Option<String>,
}

/// Top-level [plugin] section.
#[derive(Debug, Clone, Deserialize)]
pub struct ManifestPlugin {
    pub id: String,
    pub name: String,
    pub version: String,
    #[serde(default)]
    pub description: String,
    pub entry: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct ManifestPanels {
    #[serde(default)]
    pub panel: Vec<ManifestPanel>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct ManifestCommands {
    #[serde(default)]
    pub command: Vec<ManifestCommand>,
}

/// Full plugin.toml manifest.
///
/// Unknown keys (legacy `[sandbox]`, `[events]`, `runtime`, `api_version`)
/// are ignored by serde, so old manifests still parse.
#[derive(Debug, Clone, Deserialize)]
pub struct PluginManifest {
    pub plugin: ManifestPlugin,
    #[serde(default)]
    pub capabilities: ManifestCapabilities,
    #[serde(default)]
    pub panels: ManifestPanels,
    #[serde(default)]
    pub commands: ManifestCommands,
}

/// Validate a plugin id: `[a-z0-9][a-z0-9-]*[a-z0-9]`, 3-64 chars.
pub fn validate_plugin_id(id: &str) -> Result<(), String> {
    let len = id.len();
    if !(3..=64).contains(&len) {
        return Err(format!("plugin id must be 3-64 chars, got {len}"));
    }
    let bytes = id.as_bytes();
    let edge_ok = |b: u8| b.is_ascii_lowercase() || b.is_ascii_digit();
    if !edge_ok(bytes[0]) || !edge_ok(bytes[len - 1]) {
        return Err("plugin id must start and end with [a-z0-9]".into());
    }
    for &b in bytes {
        if !edge_ok(b) && b != b'-' {
            return Err(format!("plugin id contains invalid char '{}'", b as char));
        }
    }
    Ok(())
}

impl PluginManifest {
    /// Parse and validate a plugin.toml from string content.
    pub fn parse(content: &str) -> Result<Self, ManifestError> {
        let manifest: Self = toml::from_str(content).map_err(|err| ManifestError::Parse {
            path: PathBuf::new(),
            err,
        })?;
        validate_plugin_id(&manifest.plugin.id)
            .map_err(|reason| ManifestError::InvalidId(manifest.plugin.id.clone(), reason))?;
        Ok(manifest)
    }

    /// Load and validate a plugin.toml from a file path.
    pub fn load(path: &Path) -> Result<Self, ManifestError> {
        let content = std::fs::read_to_string(path).map_err(|err| ManifestError::Io {
            path: path.to_owned(),
            err,
        })?;
        Self::parse(&content).map_err(|e| match e {
            ManifestError::Parse { err, .. } => ManifestError::Parse {
                path: path.to_owned(),
                err,
            },
            other => other,
        })
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// JSON-RPC 2.0 wire protocol (newline-delimited)
// ═══════════════════════════════════════════════════════════════════════════

/// Current host API version, sent during initialize.
pub const API_VERSION: &str = "0.1.0";

/// JSON-RPC method names shared by host and guest.
pub mod methods {
    // host → plugin
    pub const INITIALIZE: &str = "lifecycle/initialize";
    pub const SHUTDOWN: &str = "lifecycle/shutdown";
    pub const SCHEMATIC_CHANGED: &str = "state/schematic_changed";
    pub const SELECTION_CHANGED: &str = "state/selection_changed";
    pub const THEME_CHANGED: &str = "state/theme_changed";
    pub const COMMAND_INVOKE: &str = "commands/invoke";
    pub const UI_ACTION: &str = "ui/action";

    // plugin → host (requests, expect response)
    pub const QUERY_INSTANCES: &str = "state/query_instances";
    pub const QUERY_NETS: &str = "state/query_nets";
    pub const QUERY_THEME: &str = "state/query_theme";
    pub const QUERY_PROJECT: &str = "state/query_project";
    pub const QUERY_PDK: &str = "state/query_pdk";
    pub const QUERY_NETLIST: &str = "state/query_netlist";
    /// Params `{id?: u32}` — with id: full state of that optimizer
    /// instance; without: summary list of all instances.
    pub const QUERY_OPTIMIZERS: &str = "state/query_optimizers";

    // plugin → host (notifications)
    pub const PANELS_REGISTER: &str = "panels/register";
    pub const PANELS_UPDATE_WIDGETS: &str = "panels/update_widgets";
    pub const COMMANDS_REGISTER: &str = "commands/register";
    pub const COMMANDS_DISPATCH: &str = "commands/dispatch";
    pub const OVERLAY_UPDATE: &str = "overlay/update";
    pub const THEME_OVERRIDE: &str = "theme/override";
    pub const SET_STATUS: &str = "host/set_status";
    pub const LOG: &str = "host/log";
}

// JSON-RPC 2.0 error codes.
pub const PARSE_ERROR: i32 = -32700;
pub const INVALID_REQUEST: i32 = -32600;
pub const METHOD_NOT_FOUND: i32 = -32601;
pub const INVALID_PARAMS: i32 = -32602;
pub const INTERNAL_ERROR: i32 = -32603;

fn encode(mut value: Value, params: Option<Value>) -> Result<String, serde_json::Error> {
    if let Some(p) = params {
        value["params"] = p;
    }
    let mut s = serde_json::to_string(&value)?;
    s.push('\n');
    Ok(s)
}

/// Encode a notification (no id, no response expected).
pub fn notification(method: &str, params: Option<Value>) -> Result<String, serde_json::Error> {
    encode(json!({"jsonrpc": "2.0", "method": method}), params)
}

/// Encode a request (has id, expects response).
pub fn request(id: u32, method: &str, params: Option<Value>) -> Result<String, serde_json::Error> {
    encode(json!({"jsonrpc": "2.0", "id": id, "method": method}), params)
}

/// Encode a success response.
pub fn response(id: u32, result: Value) -> Result<String, serde_json::Error> {
    encode(json!({"jsonrpc": "2.0", "id": id, "result": result}), None)
}

/// Encode an error response.
pub fn error_response(id: u32, code: i32, message: &str) -> Result<String, serde_json::Error> {
    encode(
        json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}),
        None,
    )
}

/// JSON-RPC error info from an incoming response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorInfo {
    pub code: i32,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

/// Parsed incoming JSON-RPC message.
#[derive(Debug)]
pub enum IncomingMessage {
    Request {
        id: u32,
        method: String,
        params: Option<Value>,
    },
    Notification {
        method: String,
        params: Option<Value>,
    },
    Response {
        id: u32,
        result: Option<Value>,
        error: Option<ErrorInfo>,
    },
}

/// Parse a single newline-delimited JSON-RPC line.
pub fn parse_line(line: &str) -> Result<IncomingMessage, String> {
    let v: Value =
        serde_json::from_str(line.trim()).map_err(|e| format!("JSON parse error: {e}"))?;
    let obj = v.as_object().ok_or("expected JSON object")?;

    // Response: has "id", no "method".
    if obj.contains_key("id") && !obj.contains_key("method") {
        let id = obj["id"].as_u64().ok_or("id must be integer")? as u32;
        return Ok(IncomingMessage::Response {
            id,
            result: obj.get("result").cloned(),
            error: obj
                .get("error")
                .and_then(|e| serde_json::from_value(e.clone()).ok()),
        });
    }

    let method = obj
        .get("method")
        .and_then(|m| m.as_str())
        .ok_or("missing method field")?
        .to_owned();
    let params = obj.get("params").cloned();

    match obj.get("id") {
        Some(id_val) => {
            let id = id_val.as_u64().ok_or("id must be integer")? as u32;
            Ok(IncomingMessage::Request { id, method, params })
        }
        None => Ok(IncomingMessage::Notification { method, params }),
    }
}

// ── Shared payload types ───────────────────────────────────────────────────

/// What the host supports, sent in `lifecycle/initialize`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostCapabilities {
    pub api_version: String,
    pub panels: bool,
    pub commands: bool,
    pub overlays: bool,
    pub theme: bool,
    pub query_instances: bool,
    pub query_nets: bool,
    /// Default keeps older payloads (without the field) deserializable.
    #[serde(default)]
    pub optimizer: bool,
}

impl Default for HostCapabilities {
    fn default() -> Self {
        Self {
            api_version: API_VERSION.to_owned(),
            panels: true,
            commands: true,
            overlays: true,
            theme: true,
            query_instances: true,
            query_nets: true,
            optimizer: true,
        }
    }
}

/// Payload of `lifecycle/initialize`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InitializeEvent {
    pub host_capabilities: HostCapabilities,
    pub plugin_id: String,
    pub plugin_name: String,
}

/// Payload of `commands/invoke`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommandInvocation {
    pub command: String,
    #[serde(default)]
    pub command_id: Option<String>,
}

/// Payload of `ui/action`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UiAction {
    pub action: String,
    #[serde(default)]
    pub payload: Option<Value>,
}

/// One instance row in a `state/query_instances` response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstanceRecord {
    pub idx: usize,
    pub name: String,
    pub symbol: String,
    pub kind: String,
    pub x: i32,
    pub y: i32,
    pub rotation: u8,
    pub flip: bool,
    /// `[key, value]` pairs from the instance property pool (W, L, model…).
    #[serde(default)]
    pub props: Vec<[String; 2]>,
}

/// One net row in a `state/query_nets` response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetRecord {
    pub idx: usize,
    pub name: String,
}

/// `state/query_project` response.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ProjectRecord {
    pub project_dir: String,
    #[serde(default)]
    pub pdk: Option<String>,
    #[serde(default)]
    pub pdk_path: Option<String>,
}

/// One device-cell mapping in a `state/query_pdk` response.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PdkCellRecord {
    /// PDK model/subcircuit name the primitive maps to.
    pub model: String,
    #[serde(default)]
    pub prefix: Option<char>,
    #[serde(default)]
    pub pin_order: Vec<String>,
    #[serde(default)]
    pub params: HashMap<String, String>,
}

/// `state/query_pdk` response (the active PDK, if any).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PdkRecord {
    pub name: String,
    pub root: String,
    #[serde(default)]
    pub lib_path: Option<String>,
    #[serde(default)]
    pub corners: Vec<String>,
    #[serde(default)]
    pub default_corner: Option<String>,
    /// Keyed by schemify primitive name ("nmos4", "res", ...).
    #[serde(default)]
    pub cells: HashMap<String, PdkCellRecord>,
}

/// `state/query_netlist` response.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct NetlistRecord {
    /// Full SPICE netlist of the active schematic.
    pub spice: String,
    /// Schematic instance index → SPICE refdes, for tying netlist
    /// elements back to instances.
    #[serde(default)]
    pub instance_map: Vec<InstanceRef>,
}

/// One instance ↔ refdes pair in a [`NetlistRecord`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstanceRef {
    pub idx: usize,
    pub refdes: String,
}

// ═══════════════════════════════════════════════════════════════════════════
// Subprocess transport (host side)
// ═══════════════════════════════════════════════════════════════════════════
// WASM transport: reintroduce behind feature when needed.

/// Child process with stdin/stdout pipes. Stdout is O_NONBLOCK on unix so
/// `recv()` never blocks the main thread.
pub struct SubprocessTransport {
    child: Option<Child>,
    stdin: Option<io::BufWriter<std::process::ChildStdin>>,
    stdout: Option<BufReader<std::process::ChildStdout>>,
    line_buf: String,
}

impl SubprocessTransport {
    /// Spawn `entry` (whitespace-split command line) inside `plugin_dir`.
    pub fn spawn(entry: &str, plugin_dir: &Path) -> Result<Self, TransportError> {
        let parts: Vec<&str> = entry.split_whitespace().collect();
        if parts.is_empty() {
            return Err(TransportError::SpawnFailed("empty command".into()));
        }

        let mut child = Command::new(parts[0])
            .args(&parts[1..])
            .current_dir(plugin_dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| TransportError::SpawnFailed(e.to_string()))?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| TransportError::SpawnFailed("failed to open stdin".into()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| TransportError::SpawnFailed("failed to open stdout".into()))?;

        // Non-blocking stdout on unix.
        #[cfg(unix)]
        {
            use std::os::unix::io::AsRawFd;
            let fd = stdout.as_raw_fd();
            unsafe {
                let flags = libc::fcntl(fd, libc::F_GETFL);
                libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
            }
        }

        Ok(Self {
            child: Some(child),
            stdin: Some(io::BufWriter::new(stdin)),
            stdout: Some(BufReader::new(stdout)),
            line_buf: String::with_capacity(4096),
        })
    }

    /// Send one newline-terminated JSON line.
    pub fn send(&mut self, msg: &str) -> Result<(), TransportError> {
        let stdin = self.stdin.as_mut().ok_or(TransportError::NotRunning)?;
        stdin
            .write_all(msg.as_bytes())
            .and_then(|()| stdin.flush())
            .map_err(|e| TransportError::SendFailed(e.to_string()))
    }

    /// Try to receive one line (non-blocking). `Ok(None)` = nothing available.
    pub fn recv(&mut self) -> Result<Option<String>, TransportError> {
        let reader = self.stdout.as_mut().ok_or(TransportError::NotRunning)?;
        self.line_buf.clear();
        match reader.read_line(&mut self.line_buf) {
            Ok(0) => Err(TransportError::RecvFailed("subprocess exited".into())),
            Ok(_) => {
                let trimmed = self.line_buf.trim();
                if trimmed.is_empty() {
                    Ok(None)
                } else {
                    Ok(Some(trimmed.to_owned()))
                }
            }
            Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => Ok(None),
            Err(e) => Err(TransportError::RecvFailed(e.to_string())),
        }
    }

    /// Kill the child and release pipes.
    pub fn stop(&mut self) {
        // Drop stdin first to signal EOF to the child.
        self.stdin = None;
        if let Some(ref mut child) = self.child {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.child = None;
        self.stdout = None;
    }

    /// Whether the child process is still alive.
    pub fn is_running(&mut self) -> bool {
        match self.child {
            Some(ref mut child) => matches!(child.try_wait(), Ok(None)),
            None => false,
        }
    }
}

impl Drop for SubprocessTransport {
    fn drop(&mut self) {
        self.stop();
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Host-side decoding: capability negotiation + message → PluginHostAction
// ═══════════════════════════════════════════════════════════════════════════

/// Capabilities enabled for one plugin: the intersection (AND) of what the
/// host and the plugin's manifest support.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct NegotiatedCapabilities {
    pub panels: bool,
    pub commands: bool,
    pub overlays: bool,
    pub theme: bool,
    pub query_instances: bool,
    pub query_nets: bool,
    pub optimizer: bool,
}

/// Intersect host and plugin capabilities.
pub fn negotiate(host: &HostCapabilities, plugin: &ManifestCapabilities) -> NegotiatedCapabilities {
    NegotiatedCapabilities {
        panels: host.panels && plugin.panels,
        commands: host.commands && plugin.commands,
        overlays: host.overlays && plugin.overlays,
        theme: host.theme && plugin.theme,
        // Query capabilities are host-only; available whenever the host
        // supports them.
        query_instances: host.query_instances,
        query_nets: host.query_nets,
        // Optimizer access can mutate state, so the manifest must opt in.
        optimizer: host.optimizer && plugin.optimizer,
    }
}

// ── Param structs (JSON shape minus plugin_id, which the host supplies) ────

fn default_true() -> bool {
    true
}

#[derive(Deserialize)]
struct PanelRegisterParams {
    name: String,
    slot: PanelLayout,
    #[serde(default)]
    priority: i32,
    #[serde(default = "default_true")]
    default_visible: bool,
}

#[derive(Deserialize)]
struct UpdateWidgetsParams {
    panel: String,
    #[serde(default)]
    widgets: Vec<WidgetNode>,
}

#[derive(Deserialize)]
struct CommandRegisterParams {
    name: String,
    #[serde(default)]
    description: String,
    keybind: Option<String>,
}

#[derive(Deserialize)]
struct OverlayUpdateParams {
    name: String,
    #[serde(default)]
    z_order: i32,
    #[serde(default = "default_true")]
    visible: bool,
    #[serde(default)]
    shapes: Vec<OverlayShape>,
}

#[derive(Deserialize)]
struct ThemeOverrideParams {
    #[serde(default)]
    priority: i32,
    #[serde(default)]
    overrides: HashMap<String, ThemeValue>,
}

#[derive(Deserialize)]
struct SetStatusParams {
    message: String,
}

fn default_info() -> String {
    "info".into()
}

#[derive(Deserialize)]
struct LogParams {
    #[serde(default = "default_info")]
    level: String,
    message: String,
}

/// Deserialize JSON params into a typed struct; errors are returned to the
/// caller, never logged here.
fn parse_params<T: DeserializeOwned>(params: Option<Value>, method: &str) -> Result<T, String> {
    let params = params.ok_or_else(|| format!("missing params for {method}"))?;
    serde_json::from_value(params).map_err(|e| format!("malformed params for {method}: {e}"))
}

/// Handle an incoming JSON-RPC request from a plugin (expects a response).
pub fn handle_request(
    plugin_id: &str,
    id: u32,
    method: &str,
    _params: Option<Value>,
) -> PluginHostAction {
    let plugin_id = plugin_id.to_owned();
    match method {
        methods::QUERY_INSTANCES => PluginHostAction::QueryInstances {
            plugin_id,
            request_id: id,
        },
        methods::QUERY_NETS => PluginHostAction::QueryNets {
            plugin_id,
            request_id: id,
        },
        methods::QUERY_THEME => PluginHostAction::QueryTheme {
            plugin_id,
            request_id: id,
        },
        methods::QUERY_PROJECT => PluginHostAction::QueryProject {
            plugin_id,
            request_id: id,
        },
        methods::QUERY_PDK => PluginHostAction::QueryPdk {
            plugin_id,
            request_id: id,
        },
        methods::QUERY_NETLIST => PluginHostAction::QueryNetlist {
            plugin_id,
            request_id: id,
        },
        methods::QUERY_OPTIMIZERS => PluginHostAction::QueryOptimizers {
            plugin_id,
            request_id: id,
            id: _params
                .as_ref()
                .and_then(|p| p.get("id"))
                .and_then(Value::as_u64)
                .map(|v| v as u32),
        },
        _ => PluginHostAction::ErrorResponse {
            plugin_id,
            request_id: id,
            code: METHOD_NOT_FOUND,
            message: format!("unknown method: {method}"),
        },
    }
}

/// Handle an incoming JSON-RPC notification from a plugin.
///
/// `Ok(None)` = unknown method or blocked by capability gate (silently
/// dropped). `Err` = recognized method with missing/malformed params.
pub fn handle_notification(
    plugin_id: &str,
    capability: &NegotiatedCapabilities,
    method: &str,
    params: Option<Value>,
) -> Result<Option<PluginHostAction>, String> {
    let action = match method {
        methods::PANELS_REGISTER if capability.panels => {
            let p: PanelRegisterParams = parse_params(params, method)?;
            PluginHostAction::RegisterPanel(PanelRegistration {
                plugin_id: plugin_id.to_owned(),
                name: p.name,
                slot: p.slot,
                priority: p.priority,
                default_visible: p.default_visible,
            })
        }
        methods::PANELS_UPDATE_WIDGETS if capability.panels => {
            let p: UpdateWidgetsParams = parse_params(params, method)?;
            PluginHostAction::UpdateWidgets {
                plugin_id: plugin_id.to_owned(),
                panel_name: p.panel,
                widgets: p.widgets,
            }
        }
        methods::COMMANDS_REGISTER if capability.commands => {
            let p: CommandRegisterParams = parse_params(params, method)?;
            PluginHostAction::RegisterCommand(CommandRegistration {
                plugin_id: plugin_id.to_owned(),
                name: p.name,
                description: p.description,
                keybind: p.keybind,
            })
        }
        methods::OVERLAY_UPDATE if capability.overlays => {
            let p: OverlayUpdateParams = parse_params(params, method)?;
            PluginHostAction::UpdateOverlay(OverlayLayer {
                plugin_id: plugin_id.to_owned(),
                name: p.name,
                z_order: p.z_order,
                visible: p.visible,
                shapes: p.shapes,
            })
        }
        methods::THEME_OVERRIDE if capability.theme => {
            let p: ThemeOverrideParams = parse_params(params, method)?;
            PluginHostAction::ThemeOverride(ThemeOverride {
                plugin_id: plugin_id.to_owned(),
                priority: p.priority,
                overrides: p.overrides,
            })
        }
        methods::COMMANDS_DISPATCH => PluginHostAction::DispatchCommand {
            plugin_id: plugin_id.to_owned(),
            command_json: params.ok_or_else(|| format!("missing params for {method}"))?,
        },
        methods::SET_STATUS => {
            let p: SetStatusParams = parse_params(params, method)?;
            PluginHostAction::SetStatus {
                plugin_id: plugin_id.to_owned(),
                message: p.message,
            }
        }
        methods::LOG => {
            let p: LogParams = parse_params(params, method)?;
            PluginHostAction::Log {
                plugin_id: plugin_id.to_owned(),
                level: p.level,
                message: p.message,
            }
        }
        _ => return Ok(None),
    };
    Ok(Some(action))
}

// ═══════════════════════════════════════════════════════════════════════════
// Manager: discovery, lifecycle, per-tick pump (host side)
// ═══════════════════════════════════════════════════════════════════════════

/// Per-plugin runtime slot, keyed by plugin id.
struct PluginSlot {
    manifest: PluginManifest,
    dir: PathBuf,
    state: PluginLifecycle,
    caps: NegotiatedCapabilities,
    transport: Option<SubprocessTransport>,
    error_msg: Option<String>,
}

/// Manages discovery, lifecycle, and IPC for all plugins.
pub struct PluginManager {
    plugins: HashMap<String, PluginSlot>,
    next_rpc_id: u32,
    host_caps: HostCapabilities,
    scan_dirs: Vec<PathBuf>,
    /// Max messages drained per plugin per tick.
    max_drain: usize,
}

impl PluginManager {
    pub fn new() -> Self {
        Self {
            plugins: HashMap::new(),
            next_rpc_id: 1,
            host_caps: HostCapabilities::default(),
            scan_dirs: Vec::new(),
            max_drain: 16,
        }
    }

    // ── Discovery ──────────────────────────────────────────────────────────

    /// Add a directory to be scanned for plugins.
    pub fn add_scan_dir(&mut self, dir: PathBuf) {
        if !self.scan_dirs.contains(&dir) {
            self.scan_dirs.push(dir);
        }
    }

    /// Scan all registered directories for subdirectories with plugin.toml.
    pub fn scan_directories(&mut self) -> Vec<ManifestError> {
        let dirs = std::mem::take(&mut self.scan_dirs);
        let mut errors = Vec::new();
        for dir in &dirs {
            errors.extend(self.discover(dir));
        }
        self.scan_dirs = dirs;
        errors
    }

    /// Scan one directory for plugin subdirectories containing plugin.toml.
    pub fn discover(&mut self, plugins_dir: &Path) -> Vec<ManifestError> {
        let mut errors = Vec::new();
        let Ok(entries) = std::fs::read_dir(plugins_dir) else {
            return errors;
        };

        for entry in entries.flatten() {
            let path = entry.path();
            let manifest_path = path.join("plugin.toml");
            if !path.is_dir() || !manifest_path.exists() {
                continue;
            }
            match PluginManifest::load(&manifest_path) {
                Ok(manifest) => {
                    let id = manifest.plugin.id.clone();
                    if self.plugins.contains_key(&id) {
                        continue;
                    }
                    let caps = negotiate(&self.host_caps, &manifest.capabilities);
                    self.plugins.insert(
                        id,
                        PluginSlot {
                            manifest,
                            dir: path,
                            state: PluginLifecycle::Discovered,
                            caps,
                            transport: None,
                            error_msg: None,
                        },
                    );
                }
                Err(e) => errors.push(e),
            }
        }
        errors
    }

    // ── Introspection ──────────────────────────────────────────────────────

    /// All discovered plugin ids.
    pub fn plugin_ids(&self) -> impl Iterator<Item = &str> {
        self.plugins.keys().map(String::as_str)
    }

    pub fn plugin_count(&self) -> usize {
        self.plugins.len()
    }

    pub fn state(&self, id: &str) -> Option<PluginLifecycle> {
        self.plugins.get(id).map(|s| s.state)
    }

    pub fn manifest(&self, id: &str) -> Option<&PluginManifest> {
        self.plugins.get(id).map(|s| &s.manifest)
    }

    /// Error message for a plugin in Error state.
    pub fn error_msg(&self, id: &str) -> Option<&str> {
        self.plugins.get(id).and_then(|s| s.error_msg.as_deref())
    }

    pub fn capabilities(&self, id: &str) -> Option<NegotiatedCapabilities> {
        self.plugins.get(id).map(|s| s.caps)
    }

    /// Remove a plugin from the manager entirely (after uninstall).
    /// Stops the plugin first if it is running.
    pub fn remove(&mut self, id: &str) -> bool {
        if let Some(mut slot) = self.plugins.remove(id) {
            if let Some(ref mut t) = slot.transport {
                if slot.state == PluginLifecycle::Running {
                    if let Ok(msg) = notification(methods::SHUTDOWN, None) {
                        let _ = t.send(&msg);
                    }
                }
                t.stop();
            }
            true
        } else {
            false
        }
    }

    // ── Lifecycle ──────────────────────────────────────────────────────────

    /// Start a discovered/stopped plugin: spawn process, send initialize.
    pub fn start(&mut self, id: &str) -> Result<(), PluginError> {
        let slot = self
            .plugins
            .get_mut(id)
            .ok_or_else(|| PluginError::UnknownPlugin(id.to_owned()))?;

        match slot.state {
            PluginLifecycle::Discovered | PluginLifecycle::Stopped | PluginLifecycle::Error => {}
            PluginLifecycle::Running | PluginLifecycle::Starting => {
                return Err(PluginError::AlreadyRunning(id.to_owned()));
            }
            PluginLifecycle::Stopping => {
                return Err(PluginError::Stopping(id.to_owned()));
            }
        }

        slot.state = PluginLifecycle::Starting;
        slot.error_msg = None;

        let fail = |slot: &mut PluginSlot, err: PluginError| {
            slot.state = PluginLifecycle::Error;
            slot.error_msg = Some(err.to_string());
            Err(err)
        };

        let mut transport = match SubprocessTransport::spawn(&slot.manifest.plugin.entry, &slot.dir)
        {
            Ok(t) => t,
            Err(e) => return fail(slot, e.into()),
        };

        let init = notification(
            methods::INITIALIZE,
            Some(json!({
                "host_capabilities": self.host_caps,
                "plugin_id": id,
                "plugin_name": slot.manifest.plugin.name,
            })),
        )?;
        if let Err(e) = transport.send(&init) {
            return fail(slot, e.into());
        }

        slot.transport = Some(transport);
        slot.state = PluginLifecycle::Running;
        Ok(())
    }

    /// Stop a running plugin: send shutdown, kill transport.
    pub fn stop(&mut self, id: &str) -> Result<(), PluginError> {
        let slot = self
            .plugins
            .get_mut(id)
            .ok_or_else(|| PluginError::UnknownPlugin(id.to_owned()))?;
        if slot.state != PluginLifecycle::Running {
            return Err(PluginError::NotRunning(id.to_owned()));
        }
        slot.state = PluginLifecycle::Stopping;
        if let Some(ref mut t) = slot.transport {
            if let Ok(msg) = notification(methods::SHUTDOWN, None) {
                let _ = t.send(&msg);
            }
            t.stop();
        }
        slot.transport = None;
        slot.state = PluginLifecycle::Stopped;
        Ok(())
    }

    /// Stop all running plugins and clear transports.
    pub fn shutdown_all(&mut self) {
        for slot in self.plugins.values_mut() {
            if let Some(ref mut t) = slot.transport {
                if slot.state == PluginLifecycle::Running {
                    if let Ok(msg) = notification(methods::SHUTDOWN, None) {
                        let _ = t.send(&msg);
                    }
                }
                t.stop();
            }
            slot.transport = None;
            if matches!(
                slot.state,
                PluginLifecycle::Running | PluginLifecycle::Starting | PluginLifecycle::Stopping
            ) {
                slot.state = PluginLifecycle::Stopped;
            }
        }
    }

    // ── Per-tick pump ──────────────────────────────────────────────────────

    /// Drain pending messages (up to 16 per plugin) from all running plugins;
    /// return host actions. Param decode failures surface as
    /// [`PluginHostAction::Log`] at level "error" attributed to the plugin.
    pub fn tick(&mut self) -> Vec<PluginHostAction> {
        let mut actions = Vec::new();
        for (id, slot) in self.plugins.iter_mut() {
            if slot.state != PluginLifecycle::Running {
                continue;
            }
            let Some(t) = slot.transport.as_mut() else {
                continue;
            };

            if !t.is_running() {
                slot.state = PluginLifecycle::Error;
                slot.error_msg = Some("process exited unexpectedly".into());
                slot.transport = None;
                continue;
            }

            for _ in 0..self.max_drain {
                let line = match t.recv() {
                    Ok(Some(line)) => line,
                    Ok(None) | Err(_) => break,
                };
                let Ok(msg) = parse_line(&line) else {
                    continue; // malformed line, skip
                };
                match msg {
                    IncomingMessage::Request {
                        id: rid,
                        method,
                        params,
                    } => actions.push(handle_request(id, rid, &method, params)),
                    IncomingMessage::Notification { method, params } => {
                        match handle_notification(id, &slot.caps, &method, params) {
                            Ok(Some(action)) => actions.push(action),
                            Ok(None) => {}
                            Err(e) => actions.push(PluginHostAction::Log {
                                plugin_id: id.clone(),
                                level: "error".into(),
                                message: e,
                            }),
                        }
                    }
                    IncomingMessage::Response { .. } => {
                        // Host currently sends no requests, so no pending map.
                    }
                }
            }
        }
        actions
    }

    // ── Outgoing messages ──────────────────────────────────────────────────

    fn running_transport(&mut self, id: &str) -> Result<&mut SubprocessTransport, PluginError> {
        let slot = self
            .plugins
            .get_mut(id)
            .ok_or_else(|| PluginError::UnknownPlugin(id.to_owned()))?;
        slot.transport
            .as_mut()
            .ok_or_else(|| PluginError::NotRunning(id.to_owned()))
    }

    fn send_line(&mut self, id: &str, line: String) -> Result<(), PluginError> {
        Ok(self.running_transport(id)?.send(&line)?)
    }

    /// Send a notification to one plugin.
    pub fn notify(
        &mut self,
        id: &str,
        method: &str,
        params: Option<Value>,
    ) -> Result<(), PluginError> {
        let line = notification(method, params)?;
        self.send_line(id, line)
    }

    /// Broadcast a notification to all running plugins.
    pub fn broadcast(&mut self, method: &str, params: Option<Value>) {
        let Ok(line) = notification(method, params) else {
            return;
        };
        for slot in self.plugins.values_mut() {
            if slot.state == PluginLifecycle::Running {
                if let Some(ref mut t) = slot.transport {
                    let _ = t.send(&line);
                }
            }
        }
    }

    pub fn notify_schematic_changed(&mut self) {
        self.broadcast(methods::SCHEMATIC_CHANGED, None);
    }

    pub fn notify_selection_changed(&mut self) {
        self.broadcast(methods::SELECTION_CHANGED, None);
    }

    pub fn notify_theme_changed(&mut self, tokens: &ThemeTokens) {
        let payload = serde_json::to_value(tokens).ok();
        self.broadcast(methods::THEME_CHANGED, payload);
    }

    /// Send a success response for a plugin request.
    pub fn respond(&mut self, id: &str, request_id: u32, result: Value) -> Result<(), PluginError> {
        let line = response(request_id, result)?;
        self.send_line(id, line)
    }

    /// Send an error response for a plugin request.
    pub fn respond_error(
        &mut self,
        id: &str,
        request_id: u32,
        code: i32,
        message: &str,
    ) -> Result<(), PluginError> {
        let line = error_response(request_id, code, message)?;
        self.send_line(id, line)
    }

    /// Send a request to a plugin; returns the request id.
    pub fn request(
        &mut self,
        id: &str,
        method: &str,
        params: Option<Value>,
    ) -> Result<u32, PluginError> {
        let rpc_id = self.next_rpc_id;
        self.next_rpc_id = self.next_rpc_id.wrapping_add(1);
        let line = request(rpc_id, method, params)?;
        self.send_line(id, line)?;
        Ok(rpc_id)
    }
}

impl Default for PluginManager {
    fn default() -> Self {
        Self::new()
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Guest-side SDK
// ═══════════════════════════════════════════════════════════════════════════

/// Guest-side SDK for writing Schemify plugins in Rust.
///
/// A plugin implements [`Plugin`](sdk::Plugin) and drives it with a stdio
/// [`PluginRuntime`](sdk::PluginRuntime):
///
/// ```no_run
/// use schemify_plugins::sdk::{Plugin, PluginRuntime, RuntimeError};
///
/// struct MyPlugin;
/// impl Plugin for MyPlugin {}
///
/// fn main() -> Result<(), RuntimeError> {
///     PluginRuntime::stdio().run(&mut MyPlugin)
/// }
/// ```
pub mod sdk {
    use std::collections::VecDeque;
    use std::io::{self, BufRead, BufReader, Write};

    use serde_json::{json, Value};

    // Re-exports so plugin binaries only need this module.
    pub use crate::{
        AlertLevel, CommandInvocation, ErrorInfo, InitializeEvent, InstanceRecord, InstanceRef,
        MarkerKind, NetRecord, NetlistRecord, OverlayShape, PanelLayout, PdkCellRecord,
        PdkRecord, ProjectRecord, ThemeColor, ThemeTokens, ThemeValue, UiAction, WidgetNode,
    };

    use crate::{methods, IncomingMessage};

    #[derive(Debug, thiserror::Error)]
    pub enum RuntimeError {
        #[error("io failed: {0}")]
        Io(#[from] io::Error),

        #[error("json failed: {0}")]
        Json(#[from] serde_json::Error),

        #[error("host returned error {code}: {message}")]
        HostError { code: i32, message: String },

        #[error("unexpected end of input")]
        EndOfInput,
    }

    /// A response to a request this plugin sent to the host.
    #[derive(Debug, Clone)]
    pub struct ResponseMessage {
        pub id: u32,
        pub result: Option<Value>,
        pub error: Option<ErrorInfo>,
    }

    /// Decoded event from the host.
    #[derive(Debug, Clone)]
    pub enum HostEvent {
        Initialize(InitializeEvent),
        Shutdown,
        SchematicChanged,
        SelectionChanged,
        ThemeChanged(ThemeTokens),
        Command(CommandInvocation),
        UiAction(UiAction),
        Response(ResponseMessage),
        Notification {
            method: String,
            params: Option<Value>,
        },
    }

    /// Plugin event callbacks. All default to no-ops.
    pub trait Plugin {
        fn on_initialize(
            &mut self,
            _runtime: &mut PluginRuntime,
            _event: InitializeEvent,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn on_shutdown(&mut self, _runtime: &mut PluginRuntime) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn on_command(
            &mut self,
            _runtime: &mut PluginRuntime,
            _command: CommandInvocation,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn on_ui_action(
            &mut self,
            _runtime: &mut PluginRuntime,
            _action: UiAction,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn on_schematic_changed(
            &mut self,
            _runtime: &mut PluginRuntime,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn on_selection_changed(
            &mut self,
            _runtime: &mut PluginRuntime,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn on_theme_changed(
            &mut self,
            _runtime: &mut PluginRuntime,
            _theme: ThemeTokens,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn on_response(
            &mut self,
            _runtime: &mut PluginRuntime,
            _response: ResponseMessage,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }

        fn on_notification(
            &mut self,
            _runtime: &mut PluginRuntime,
            _method: String,
            _params: Option<Value>,
        ) -> Result<(), RuntimeError> {
            Ok(())
        }
    }

    /// Guest-side event loop and host API.
    pub struct PluginRuntime {
        reader: Box<dyn BufRead + Send>,
        writer: Box<dyn Write + Send>,
        next_id: u32,
        deferred: VecDeque<IncomingMessage>,
        initialized: Option<InitializeEvent>,
    }

    impl PluginRuntime {
        /// Runtime speaking over stdin/stdout (the standard transport).
        pub fn stdio() -> Self {
            Self {
                reader: Box::new(BufReader::new(io::stdin())),
                writer: Box::new(io::stdout()),
                next_id: 1,
                deferred: VecDeque::new(),
                initialized: None,
            }
        }

        /// Run the event loop until shutdown or EOF.
        pub fn run<P: Plugin>(&mut self, plugin: &mut P) -> Result<(), RuntimeError> {
            loop {
                match self.read_event()? {
                    HostEvent::Initialize(event) => {
                        self.initialized = Some(event.clone());
                        plugin.on_initialize(self, event)?;
                    }
                    HostEvent::Shutdown => {
                        plugin.on_shutdown(self)?;
                        return Ok(());
                    }
                    HostEvent::SchematicChanged => plugin.on_schematic_changed(self)?,
                    HostEvent::SelectionChanged => plugin.on_selection_changed(self)?,
                    HostEvent::ThemeChanged(theme) => plugin.on_theme_changed(self, theme)?,
                    HostEvent::Command(command) => plugin.on_command(self, command)?,
                    HostEvent::UiAction(action) => plugin.on_ui_action(self, action)?,
                    HostEvent::Response(response) => plugin.on_response(self, response)?,
                    HostEvent::Notification { method, params } => {
                        plugin.on_notification(self, method, params)?
                    }
                }
            }
        }

        /// The initialize event, if received.
        pub fn initialized(&self) -> Option<&InitializeEvent> {
            self.initialized.as_ref()
        }

        // ── Host API: notifications ────────────────────────────────────────

        pub fn log(
            &mut self,
            level: &str,
            message: impl Into<String>,
        ) -> Result<(), RuntimeError> {
            self.notify(
                methods::LOG,
                Some(json!({"level": level, "message": message.into()})),
            )
        }

        pub fn info(&mut self, message: impl Into<String>) -> Result<(), RuntimeError> {
            self.log("info", message)
        }

        pub fn set_status(&mut self, message: impl Into<String>) -> Result<(), RuntimeError> {
            self.notify(
                methods::SET_STATUS,
                Some(json!({"message": message.into()})),
            )
        }

        pub fn register_panel(
            &mut self,
            name: impl Into<String>,
            slot: PanelLayout,
            priority: i32,
            default_visible: bool,
        ) -> Result<(), RuntimeError> {
            self.notify(
                methods::PANELS_REGISTER,
                Some(json!({
                    "name": name.into(),
                    "slot": slot,
                    "priority": priority,
                    "default_visible": default_visible,
                })),
            )
        }

        pub fn update_widgets(
            &mut self,
            panel: impl Into<String>,
            widgets: Vec<WidgetNode>,
        ) -> Result<(), RuntimeError> {
            self.notify(
                methods::PANELS_UPDATE_WIDGETS,
                Some(json!({"panel": panel.into(), "widgets": widgets})),
            )
        }

        pub fn register_command(
            &mut self,
            name: impl Into<String>,
            description: impl Into<String>,
            keybind: Option<&str>,
        ) -> Result<(), RuntimeError> {
            self.notify(
                methods::COMMANDS_REGISTER,
                Some(json!({
                    "name": name.into(),
                    "description": description.into(),
                    "keybind": keybind,
                })),
            )
        }

        pub fn update_overlay(
            &mut self,
            name: impl Into<String>,
            z_order: i32,
            visible: bool,
            shapes: Vec<OverlayShape>,
        ) -> Result<(), RuntimeError> {
            self.notify(
                methods::OVERLAY_UPDATE,
                Some(json!({
                    "name": name.into(),
                    "z_order": z_order,
                    "visible": visible,
                    "shapes": shapes,
                })),
            )
        }

        pub fn set_theme_override(
            &mut self,
            priority: i32,
            overrides: impl IntoIterator<Item = (String, ThemeValue)>,
        ) -> Result<(), RuntimeError> {
            let overrides = overrides
                .into_iter()
                .map(|(key, value)| serde_json::to_value(value).map(|value| (key, value)))
                .collect::<Result<serde_json::Map<String, Value>, _>>()?;
            self.notify(
                methods::THEME_OVERRIDE,
                Some(json!({"priority": priority, "overrides": overrides})),
            )
        }

        /// Dispatch a host command by action name (e.g. `"zoom_in"`, `"undo"`).
        /// The host maps known action strings onto editor commands.
        pub fn dispatch_action(&mut self, action: &str) -> Result<(), RuntimeError> {
            self.notify(methods::COMMANDS_DISPATCH, Some(json!({"action": action})))
        }

        /// Dispatch a full externally-tagged editor command, e.g.
        /// `json!({"SetInstanceProp": {"idx": 3, "key": "W", "value": "2u"}})`.
        /// Same JSON shape the CLI and MCP accept.
        pub fn dispatch_command(&mut self, command: Value) -> Result<(), RuntimeError> {
            self.notify(methods::COMMANDS_DISPATCH, Some(command))
        }

        pub fn notify(&mut self, method: &str, params: Option<Value>) -> Result<(), RuntimeError> {
            let msg = crate::notification(method, params)?;
            self.writer.write_all(msg.as_bytes())?;
            self.writer.flush()?;
            Ok(())
        }

        // ── Host API: requests ─────────────────────────────────────────────

        /// Send a request; returns its id. Response arrives via `on_response`
        /// or a blocking `request_json`.
        pub fn request(
            &mut self,
            method: &str,
            params: Option<Value>,
        ) -> Result<u32, RuntimeError> {
            let id = self.next_id;
            self.next_id = self.next_id.wrapping_add(1);
            let msg = crate::request(id, method, params)?;
            self.writer.write_all(msg.as_bytes())?;
            self.writer.flush()?;
            Ok(id)
        }

        /// Send a request and block until its response arrives. Other messages
        /// received meanwhile are deferred and replayed to the event loop.
        pub fn request_json(
            &mut self,
            method: &str,
            params: Option<Value>,
        ) -> Result<Value, RuntimeError> {
            let id = self.request(method, params)?;
            loop {
                match self.read_message()? {
                    IncomingMessage::Response {
                        id: response_id,
                        result,
                        error,
                    } if response_id == id => {
                        if let Some(error) = error {
                            return Err(RuntimeError::HostError {
                                code: error.code,
                                message: error.message,
                            });
                        }
                        return Ok(result.unwrap_or(Value::Null));
                    }
                    other => self.deferred.push_back(other),
                }
            }
        }

        pub fn query_instances(&mut self) -> Result<Vec<InstanceRecord>, RuntimeError> {
            let value = self.request_json(methods::QUERY_INSTANCES, None)?;
            Ok(serde_json::from_value(value)?)
        }

        pub fn query_nets(&mut self) -> Result<Vec<NetRecord>, RuntimeError> {
            let value = self.request_json(methods::QUERY_NETS, None)?;
            Ok(serde_json::from_value(value)?)
        }

        pub fn query_theme(&mut self) -> Result<ThemeTokens, RuntimeError> {
            let value = self.request_json(methods::QUERY_THEME, None)?;
            Ok(serde_json::from_value(value)?)
        }

        pub fn query_project(&mut self) -> Result<ProjectRecord, RuntimeError> {
            let value = self.request_json(methods::QUERY_PROJECT, None)?;
            Ok(serde_json::from_value(value)?)
        }

        /// The active PDK, or `None` if the project has none loaded.
        pub fn query_pdk(&mut self) -> Result<Option<PdkRecord>, RuntimeError> {
            let value = self.request_json(methods::QUERY_PDK, None)?;
            Ok(serde_json::from_value(value)?)
        }

        pub fn query_netlist(&mut self) -> Result<NetlistRecord, RuntimeError> {
            let value = self.request_json(methods::QUERY_NETLIST, None)?;
            Ok(serde_json::from_value(value)?)
        }

        /// Optimizer instances: `Some(id)` = that instance's full state,
        /// `None` = summary list. Raw JSON — the shape is owned by the
        /// host's optimizer state. Requires the `optimizer` capability.
        pub fn query_optimizers(&mut self, id: Option<u32>) -> Result<Value, RuntimeError> {
            let params = id.map(|id| json!({ "id": id }));
            self.request_json(methods::QUERY_OPTIMIZERS, params)
        }

        // ── Incoming ───────────────────────────────────────────────────────

        fn read_event(&mut self) -> Result<HostEvent, RuntimeError> {
            match self.read_message()? {
                // The host currently sends no requests; surface them as raw
                // notifications so a plugin can still observe them.
                IncomingMessage::Request { id, method, params } => Ok(HostEvent::Notification {
                    method,
                    params: Some(json!({"id": id, "params": params})),
                }),
                IncomingMessage::Notification { method, params } => {
                    decode_notification(method, params)
                }
                IncomingMessage::Response { id, result, error } => {
                    Ok(HostEvent::Response(ResponseMessage { id, result, error }))
                }
            }
        }

        fn read_message(&mut self) -> Result<IncomingMessage, RuntimeError> {
            if let Some(message) = self.deferred.pop_front() {
                return Ok(message);
            }
            let mut line = String::new();
            if self.reader.read_line(&mut line)? == 0 {
                return Err(RuntimeError::EndOfInput);
            }
            crate::parse_line(&line).map_err(|err| {
                RuntimeError::Io(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("invalid json-rpc line: {err}"),
                ))
            })
        }
    }

    fn decode_notification(
        method: String,
        params: Option<Value>,
    ) -> Result<HostEvent, RuntimeError> {
        let payload = || params.clone().unwrap_or(Value::Null);
        Ok(match method.as_str() {
            methods::INITIALIZE => HostEvent::Initialize(serde_json::from_value(payload())?),
            methods::SHUTDOWN => HostEvent::Shutdown,
            methods::SCHEMATIC_CHANGED => HostEvent::SchematicChanged,
            methods::SELECTION_CHANGED => HostEvent::SelectionChanged,
            methods::THEME_CHANGED => HostEvent::ThemeChanged(serde_json::from_value(payload())?),
            methods::COMMAND_INVOKE => HostEvent::Command(serde_json::from_value(payload())?),
            methods::UI_ACTION => HostEvent::UiAction(serde_json::from_value(payload())?),
            _ => HostEvent::Notification { method, params },
        })
    }

    impl Default for PluginRuntime {
        fn default() -> Self {
            Self::stdio()
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    // ── Manifest ───────────────────────────────────────────────────────────

    const SAMPLE: &str = r#"
[plugin]
id = "pdk-switcher"
name = "PDKSwitcher"
version = "1.0.0"
description = "Switch between PDK configurations"
entry = "plugin.py"

[capabilities]
panels = true
commands = true
overlays = false
theme = true

[[panels.panel]]
name = "PDK Config"
slot = "RightSidebar"
priority = 10

[[commands.command]]
name = "switch_pdk"
description = "Switch active PDK"
keybind = "Ctrl+Shift+P"
"#;

    #[test]
    fn parse_manifest() {
        let m = PluginManifest::parse(SAMPLE).unwrap();
        assert_eq!(m.plugin.id, "pdk-switcher");
        assert_eq!(m.plugin.name, "PDKSwitcher");
        assert_eq!(m.plugin.version, "1.0.0");
        assert!(m.capabilities.panels);
        assert!(!m.capabilities.overlays);
        assert_eq!(m.panels.panel.len(), 1);
        assert_eq!(m.panels.panel[0].slot, "RightSidebar");
        assert_eq!(m.commands.command.len(), 1);
        assert_eq!(
            m.commands.command[0].keybind.as_deref(),
            Some("Ctrl+Shift+P")
        );
    }

    #[test]
    fn minimal_manifest() {
        let m = PluginManifest::parse(
            "[plugin]\nid = \"bare\"\nname = \"Bare\"\nversion = \"0.1.0\"\nentry = \"bare.py\"\n",
        )
        .unwrap();
        assert_eq!(m.plugin.id, "bare");
        assert!(!m.capabilities.panels);
        assert!(m.panels.panel.is_empty());
        assert!(m.commands.command.is_empty());
    }

    #[test]
    fn legacy_sections_ignored() {
        // Old manifests carry runtime/api_version/[sandbox]/[events]; they
        // must still parse (serde ignores unknown keys).
        let m = PluginManifest::parse(
            r#"
[plugin]
id = "legacy"
name = "Legacy"
version = "1.0.0"
entry = "run.sh"
runtime = "subprocess"
api_version = 1

[sandbox]
network = false

[events]
listen = ["pre_save"]
"#,
        )
        .unwrap();
        assert_eq!(m.plugin.id, "legacy");
    }

    #[test]
    fn missing_id_is_error() {
        let result = PluginManifest::parse(
            "[plugin]\nname = \"NoId\"\nversion = \"1.0.0\"\nentry = \"run.sh\"\n",
        );
        assert!(result.is_err());
    }

    #[test]
    fn invalid_id_is_error() {
        let result = PluginManifest::parse(
            "[plugin]\nid = \"BAD_ID\"\nname = \"Bad\"\nversion = \"1.0.0\"\nentry = \"run.sh\"\n",
        );
        assert!(matches!(result, Err(ManifestError::InvalidId(..))));
    }

    #[test]
    fn validate_id_rules() {
        assert!(validate_plugin_id("abc").is_ok());
        assert!(validate_plugin_id("pdk-switcher").is_ok());
        assert!(validate_plugin_id("my-plugin-123").is_ok());
        assert!(validate_plugin_id(&"x".repeat(64)).is_ok());

        assert!(validate_plugin_id("ab").is_err());
        assert!(validate_plugin_id("").is_err());
        assert!(validate_plugin_id(&"x".repeat(65)).is_err());
        assert!(validate_plugin_id("has_underscore").is_err());
        assert!(validate_plugin_id("HAS-CAPS").is_err());
        assert!(validate_plugin_id("-leading").is_err());
        assert!(validate_plugin_id("trailing-").is_err());
    }

    #[test]
    fn invalid_toml_is_error() {
        assert!(PluginManifest::parse("not toml {{{").is_err());
    }

    // ── JSON-RPC roundtrip ─────────────────────────────────────────────────

    #[test]
    fn roundtrip_notification() {
        let encoded = notification("lifecycle/tick", Some(json!({"dt": 0.016}))).unwrap();
        assert!(encoded.ends_with('\n'));
        match parse_line(&encoded).unwrap() {
            IncomingMessage::Notification { method, params } => {
                assert_eq!(method, "lifecycle/tick");
                let dt = params.unwrap()["dt"].as_f64().unwrap();
                assert!((dt - 0.016).abs() < 1e-6);
            }
            other => panic!("expected notification, got {other:?}"),
        }
    }

    #[test]
    fn notification_without_params_omits_field() {
        let encoded = notification(methods::SHUTDOWN, None).unwrap();
        assert!(!encoded.contains("params"));
        match parse_line(&encoded).unwrap() {
            IncomingMessage::Notification { method, params } => {
                assert_eq!(method, methods::SHUTDOWN);
                assert!(params.is_none());
            }
            other => panic!("expected notification, got {other:?}"),
        }
    }

    #[test]
    fn roundtrip_request() {
        let encoded = request(42, methods::QUERY_INSTANCES, None).unwrap();
        match parse_line(&encoded).unwrap() {
            IncomingMessage::Request { id, method, params } => {
                assert_eq!(id, 42);
                assert_eq!(method, methods::QUERY_INSTANCES);
                assert!(params.is_none());
            }
            other => panic!("expected request, got {other:?}"),
        }
    }

    #[test]
    fn roundtrip_response() {
        let encoded = response(7, json!({"ok": true})).unwrap();
        match parse_line(&encoded).unwrap() {
            IncomingMessage::Response { id, result, error } => {
                assert_eq!(id, 7);
                assert!(result.unwrap()["ok"].as_bool().unwrap());
                assert!(error.is_none());
            }
            other => panic!("expected response, got {other:?}"),
        }
    }

    #[test]
    fn roundtrip_error_response() {
        let encoded = error_response(3, METHOD_NOT_FOUND, "no such method").unwrap();
        match parse_line(&encoded).unwrap() {
            IncomingMessage::Response { id, error, .. } => {
                assert_eq!(id, 3);
                let e = error.unwrap();
                assert_eq!(e.code, METHOD_NOT_FOUND);
                assert_eq!(e.message, "no such method");
            }
            other => panic!("expected error response, got {other:?}"),
        }
    }

    #[test]
    fn parse_rejects_garbage() {
        assert!(parse_line("not json").is_err());
        assert!(parse_line("[1,2,3]").is_err());
        assert!(parse_line(r#"{"jsonrpc":"2.0"}"#).is_err());
        assert!(parse_line(r#"{"jsonrpc":"2.0","id":"abc"}"#).is_err());
        assert!(parse_line(r#"{"jsonrpc":"2.0","id":"abc","method":"x"}"#).is_err());
    }

    // ── Capability negotiation ─────────────────────────────────────────────

    fn full_cap() -> NegotiatedCapabilities {
        NegotiatedCapabilities {
            panels: true,
            commands: true,
            overlays: true,
            theme: true,
            query_instances: true,
            query_nets: true,
            optimizer: true,
        }
    }

    #[test]
    fn negotiate_and_gate() {
        let host = HostCapabilities {
            overlays: false,
            query_nets: false,
            ..Default::default()
        };
        let plugin = ManifestCapabilities {
            panels: true,
            commands: false,
            overlays: false,
            theme: true,
            optimizer: true,
        };
        let neg = negotiate(&host, &plugin);
        assert!(neg.panels); // host && plugin
        assert!(!neg.commands); // plugin says no
        assert!(!neg.overlays); // both say no
        assert!(neg.theme);
        assert!(neg.query_instances); // host-only
        assert!(!neg.query_nets); // host says no
        assert!(neg.optimizer); // host && plugin
    }

    #[test]
    fn query_optimizers_decodes() {
        match handle_request("p", 7, methods::QUERY_OPTIMIZERS, None) {
            PluginHostAction::QueryOptimizers {
                plugin_id,
                request_id,
                id,
            } => {
                assert_eq!(plugin_id, "p");
                assert_eq!(request_id, 7);
                assert_eq!(id, None);
            }
            other => panic!("expected QueryOptimizers, got {other:?}"),
        }
        match handle_request("p", 8, methods::QUERY_OPTIMIZERS, Some(json!({"id": 3}))) {
            PluginHostAction::QueryOptimizers { id, .. } => assert_eq!(id, Some(3)),
            other => panic!("expected QueryOptimizers, got {other:?}"),
        }
    }

    // ── Host action decoding ───────────────────────────────────────────────

    #[test]
    fn panel_register_decodes() {
        let action = handle_notification(
            "test",
            &full_cap(),
            methods::PANELS_REGISTER,
            Some(json!({"name": "MyPanel", "slot": "RightSidebar", "priority": 5})),
        )
        .unwrap();
        match action {
            Some(PluginHostAction::RegisterPanel(reg)) => {
                assert_eq!(reg.plugin_id, "test");
                assert_eq!(reg.name, "MyPanel");
                assert_eq!(reg.slot, PanelLayout::RightSidebar);
                assert_eq!(reg.priority, 5);
                assert!(reg.default_visible);
            }
            other => panic!("expected RegisterPanel, got {other:?}"),
        }
    }

    #[test]
    fn overlay_update_decodes() {
        let action = handle_notification(
            "ovl",
            &full_cap(),
            methods::OVERLAY_UPDATE,
            Some(json!({
                "name": "drc_errors",
                "z_order": 10,
                "shapes": [
                    {"Marker": {"x": 100.0, "y": 200.0, "kind": "Error", "color": [255,0,0,255]}}
                ]
            })),
        )
        .unwrap();
        match action {
            Some(PluginHostAction::UpdateOverlay(layer)) => {
                assert_eq!(layer.plugin_id, "ovl");
                assert_eq!(layer.z_order, 10);
                assert!(layer.visible);
                assert_eq!(layer.shapes.len(), 1);
                assert!(matches!(
                    layer.shapes[0],
                    OverlayShape::Marker {
                        kind: MarkerKind::Error,
                        ..
                    }
                ));
            }
            other => panic!("expected UpdateOverlay, got {other:?}"),
        }
    }

    #[test]
    fn theme_override_decodes() {
        let action = handle_notification(
            "th",
            &full_cap(),
            methods::THEME_OVERRIDE,
            Some(json!({"priority": 5, "overrides": {"accent": {"Color": [255,0,128,255]}}})),
        )
        .unwrap();
        match action {
            Some(PluginHostAction::ThemeOverride(ov)) => {
                assert_eq!(ov.plugin_id, "th");
                assert_eq!(ov.priority, 5);
                assert_eq!(
                    ov.overrides.get("accent"),
                    Some(&ThemeValue::Color([255, 0, 128, 255]))
                );
            }
            other => panic!("expected ThemeOverride, got {other:?}"),
        }
    }

    #[test]
    fn capability_gate_blocks() {
        let no_panels = NegotiatedCapabilities {
            panels: false,
            ..full_cap()
        };
        let action = handle_notification(
            "test",
            &no_panels,
            methods::PANELS_REGISTER,
            Some(json!({"name": "X", "slot": "Overlay"})),
        )
        .unwrap();
        assert!(action.is_none());
    }

    #[test]
    fn unknown_method_is_none_bad_params_is_err() {
        assert!(matches!(
            handle_notification("t", &full_cap(), "totally/unknown", None),
            Ok(None)
        ));
        // Recognized method, missing params → threaded error, not eprintln.
        assert!(handle_notification("t", &full_cap(), methods::PANELS_REGISTER, None).is_err());
        assert!(handle_notification(
            "t",
            &full_cap(),
            methods::LOG,
            Some(json!({"level": 42}))
        )
        .is_err());
    }

    #[test]
    fn log_defaults_level_to_info() {
        let action = handle_notification(
            "test",
            &full_cap(),
            methods::LOG,
            Some(json!({"message": "no level"})),
        )
        .unwrap();
        match action {
            Some(PluginHostAction::Log { level, .. }) => assert_eq!(level, "info"),
            other => panic!("expected Log, got {other:?}"),
        }
    }

    #[test]
    fn unknown_request_returns_error_action() {
        match handle_request("test", 99, "bogus/method", None) {
            PluginHostAction::ErrorResponse {
                request_id, code, ..
            } => {
                assert_eq!(request_id, 99);
                assert_eq!(code, METHOD_NOT_FOUND);
            }
            other => panic!("expected ErrorResponse, got {other:?}"),
        }
    }

    #[test]
    fn query_requests_decode() {
        match handle_request("p", 42, methods::QUERY_INSTANCES, None) {
            PluginHostAction::QueryInstances {
                plugin_id,
                request_id,
            } => {
                assert_eq!(plugin_id, "p");
                assert_eq!(request_id, 42);
            }
            other => panic!("expected QueryInstances, got {other:?}"),
        }
        assert!(matches!(
            handle_request("p", 7, methods::QUERY_NETS, None),
            PluginHostAction::QueryNets { .. }
        ));
        assert!(matches!(
            handle_request("p", 8, methods::QUERY_THEME, None),
            PluginHostAction::QueryTheme { .. }
        ));
    }

    // ── Transport ──────────────────────────────────────────────────────────

    #[test]
    fn spawn_failures() {
        assert!(matches!(
            SubprocessTransport::spawn("", Path::new("/tmp")),
            Err(TransportError::SpawnFailed(_))
        ));
        assert!(matches!(
            SubprocessTransport::spawn("absolutely_nonexistent_binary_xyz_123", Path::new("/tmp")),
            Err(TransportError::SpawnFailed(_))
        ));
    }

    #[test]
    fn spawn_send_recv_stop_with_cat() {
        let mut t = SubprocessTransport::spawn("cat", Path::new("/tmp")).unwrap();
        assert!(t.is_running());

        // cat echoes stdin to stdout.
        t.send("{\"jsonrpc\":\"2.0\",\"method\":\"test\"}\n").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(50));

        let line = t.recv().unwrap().expect("expected echo from cat");
        assert!(line.contains("jsonrpc"));

        t.stop();
        assert!(!t.is_running());
        assert!(matches!(t.send("x\n"), Err(TransportError::NotRunning)));
        assert!(matches!(t.recv(), Err(TransportError::NotRunning)));
    }

    #[test]
    fn recv_is_nonblocking_when_no_data() {
        let mut t = SubprocessTransport::spawn("cat", Path::new("/tmp")).unwrap();
        // Nothing sent: recv must return immediately with Ok(None).
        assert!(matches!(t.recv(), Ok(None)));
        t.stop();
    }

    #[test]
    fn is_running_detects_exit() {
        let mut t = SubprocessTransport::spawn("true", Path::new("/tmp")).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(50));
        assert!(!t.is_running());
    }

    // ── Manager ────────────────────────────────────────────────────────────

    fn manifest_toml(id: &str, name: &str, entry: &str) -> String {
        format!(
            "[plugin]\nid = \"{id}\"\nname = \"{name}\"\nversion = \"0.1.0\"\nentry = \"{entry}\"\n"
        )
    }

    fn setup_plugin_dir(tmp: &Path, dir_name: &str, toml_content: &str) {
        let dir = tmp.join(dir_name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("plugin.toml"), toml_content).unwrap();
    }

    fn insert_fake(mgr: &mut PluginManager, id: &str, entry: &str) {
        let manifest = PluginManifest::parse(&manifest_toml(id, id, entry)).unwrap();
        mgr.plugins.insert(
            id.to_owned(),
            PluginSlot {
                manifest,
                dir: std::env::temp_dir(),
                state: PluginLifecycle::Discovered,
                caps: NegotiatedCapabilities::default(),
                transport: None,
                error_msg: None,
            },
        );
    }

    #[test]
    fn discover_plugins() {
        let tmp = std::env::temp_dir().join("schemifyre_test_discover");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();
        setup_plugin_dir(
            &tmp,
            "tp",
            &manifest_toml("test-plugin", "TestPlugin", "echo hello"),
        );

        let mut mgr = PluginManager::new();
        let errors = mgr.discover(&tmp);
        assert!(errors.is_empty(), "errors: {errors:?}");
        assert!(mgr.plugin_ids().any(|i| i == "test-plugin"));
        assert_eq!(mgr.state("test-plugin"), Some(PluginLifecycle::Discovered));

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn discover_reports_invalid_manifest() {
        let tmp = std::env::temp_dir().join("schemifyre_test_skip");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();
        setup_plugin_dir(&tmp, "bad", "garbage");

        let mut mgr = PluginManager::new();
        let errors = mgr.discover(&tmp);
        assert_eq!(errors.len(), 1);
        assert_eq!(mgr.plugin_count(), 0);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn scan_directories_multiple() {
        let base = std::env::temp_dir().join("schemifyre_test_scan");
        let _ = fs::remove_dir_all(&base);
        let dir_a = base.join("a");
        let dir_b = base.join("b");
        fs::create_dir_all(&dir_a).unwrap();
        fs::create_dir_all(&dir_b).unwrap();
        setup_plugin_dir(&dir_a, "pa", &manifest_toml("plug-a", "PlugA", "echo a"));
        setup_plugin_dir(&dir_b, "pb", &manifest_toml("plug-b", "PlugB", "echo b"));

        let mut mgr = PluginManager::new();
        mgr.add_scan_dir(dir_a.clone());
        mgr.add_scan_dir(dir_a); // dedup
        mgr.add_scan_dir(dir_b);
        let errors = mgr.scan_directories();
        assert!(errors.is_empty());
        assert_eq!(mgr.plugin_count(), 2);

        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn start_failure_sets_error_state() {
        let mut mgr = PluginManager::new();
        insert_fake(&mut mgr, "fake-plugin", "nonexistent_binary_xyz");

        assert!(mgr.start("fake-plugin").is_err());
        assert_eq!(mgr.state("fake-plugin"), Some(PluginLifecycle::Error));
        assert!(mgr.error_msg("fake-plugin").is_some());
    }

    #[test]
    fn unknown_plugin_errors() {
        let mut mgr = PluginManager::new();
        assert!(matches!(
            mgr.start("nope"),
            Err(PluginError::UnknownPlugin(_))
        ));
        assert!(matches!(
            mgr.stop("nope"),
            Err(PluginError::UnknownPlugin(_))
        ));
        assert!(matches!(
            mgr.notify("nope", "m", None),
            Err(PluginError::UnknownPlugin(_))
        ));
        assert!(matches!(
            mgr.respond("nope", 1, json!(null)),
            Err(PluginError::UnknownPlugin(_))
        ));
    }

    #[test]
    fn stop_not_running_errors() {
        let mut mgr = PluginManager::new();
        insert_fake(&mut mgr, "idle-plugin", "echo");
        assert!(matches!(
            mgr.stop("idle-plugin"),
            Err(PluginError::NotRunning(_))
        ));
        assert!(matches!(
            mgr.notify("idle-plugin", "m", None),
            Err(PluginError::NotRunning(_))
        ));
    }

    #[test]
    fn start_stop_cycle() {
        let mut mgr = PluginManager::new();
        insert_fake(&mut mgr, "cat-plugin", "cat");

        mgr.start("cat-plugin").unwrap();
        assert_eq!(mgr.state("cat-plugin"), Some(PluginLifecycle::Running));

        assert!(matches!(
            mgr.start("cat-plugin"),
            Err(PluginError::AlreadyRunning(_))
        ));

        mgr.stop("cat-plugin").unwrap();
        assert_eq!(mgr.state("cat-plugin"), Some(PluginLifecycle::Stopped));

        // Restart works.
        mgr.start("cat-plugin").unwrap();
        mgr.shutdown_all();
        assert_eq!(mgr.state("cat-plugin"), Some(PluginLifecycle::Stopped));
    }

    #[test]
    fn tick_detects_crashed_process() {
        let mut mgr = PluginManager::new();
        insert_fake(&mut mgr, "crash-plugin", "cat");
        mgr.start("crash-plugin").unwrap();

        // Kill the child behind the manager's back.
        if let Some(slot) = mgr.plugins.get_mut("crash-plugin") {
            slot.transport.as_mut().unwrap().stop();
        }

        let actions = mgr.tick();
        assert!(actions.is_empty());
        assert_eq!(mgr.state("crash-plugin"), Some(PluginLifecycle::Error));
        assert!(mgr.error_msg("crash-plugin").is_some());
    }

    #[test]
    fn tick_no_running_plugins_is_empty() {
        let mut mgr = PluginManager::new();
        assert!(mgr.tick().is_empty());
    }

    // ── Wire-type serde compat ─────────────────────────────────────────────

    #[test]
    fn widget_node_external_tagging() {
        let label: WidgetNode = serde_json::from_value(json!({"Label": "Hello"})).unwrap();
        assert!(matches!(label, WidgetNode::Label(s) if s == "Hello"));

        let button: WidgetNode =
            serde_json::from_value(json!({"Button": {"label": "Run", "action": "run_lint"}}))
                .unwrap();
        assert!(matches!(button, WidgetNode::Button { .. }));

        let sep: WidgetNode = serde_json::from_value(json!("Separator")).unwrap();
        assert!(matches!(sep, WidgetNode::Separator));
    }

    #[test]
    fn theme_color_untagged() {
        let token: ThemeColor = serde_json::from_value(json!("accent")).unwrap();
        assert!(matches!(token, ThemeColor::Token(s) if s == "accent"));
        let literal: ThemeColor = serde_json::from_value(json!([1, 2, 3, 4])).unwrap();
        assert!(matches!(literal, ThemeColor::Literal([1, 2, 3, 4])));
    }
}
