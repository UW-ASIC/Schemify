//! Host-side decoding: capability negotiation and plugin message →
//! [`PluginHostAction`] translation.

use std::collections::HashMap;

use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::Value;

use schemify_plugin_api::protocol::*;

use crate::manager::PluginHostAction;
use crate::manifest::ManifestCapabilities;

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
