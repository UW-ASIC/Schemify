//! Wire protocol shared by host and plugins: panel/widget/overlay/theme
//! types, JSON-RPC 2.0 framing, method names, and query payload records.
//! This module depends on nothing host-side; both `host` and `sdk` build
//! on it.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;

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
// Tests
// ═══════════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

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
