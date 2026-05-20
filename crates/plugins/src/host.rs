use schemify_core::plugin_types::{
    CommandRegistration, OverlayLayer, OverlayShape, PanelRegistration, SlotId,
};
use schemify_core::theme::ThemeOverride;
use serde_json::Value;

use crate::capability::Capability;
use crate::jsonrpc;

/// Actions the host should take in response to plugin messages.
/// The handler/display layer processes these.
#[derive(Debug)]
pub enum HostAction {
    /// Plugin registered a panel.
    RegisterPanel(PanelRegistration),
    /// Plugin registered a command.
    RegisterCommand(CommandRegistration),
    /// Plugin updated an overlay layer.
    UpdateOverlay(OverlayLayer),
    /// Plugin pushed theme overrides.
    ThemeOverride(ThemeOverride),
    /// Plugin wants to dispatch a Command (as JSON).
    DispatchCommand {
        plugin_id: String,
        command_json: Value,
    },
    /// Plugin set a status message.
    SetStatus {
        plugin_id: String,
        message: String,
    },
    /// Plugin logged a message.
    Log {
        plugin_id: String,
        level: String,
        message: String,
    },
    /// Plugin wants to query instances — needs response.
    QueryInstances {
        plugin_id: String,
        request_id: u32,
    },
    /// Plugin wants to query nets — needs response.
    QueryNets {
        plugin_id: String,
        request_id: u32,
    },
    /// Unknown method — send error response.
    ErrorResponse {
        plugin_id: String,
        request_id: u32,
        code: i32,
        message: String,
    },
}

/// Handle an incoming JSON-RPC request from a plugin (expects response).
pub fn handle_request(
    plugin_id: &str,
    _capability: &Capability,
    id: u32,
    method: &str,
    _params: Option<Value>,
) -> HostAction {
    match method {
        "state/query_instances" => HostAction::QueryInstances {
            plugin_id: plugin_id.to_owned(),
            request_id: id,
        },
        "state/query_nets" => HostAction::QueryNets {
            plugin_id: plugin_id.to_owned(),
            request_id: id,
        },
        _ => HostAction::ErrorResponse {
            plugin_id: plugin_id.to_owned(),
            request_id: id,
            code: jsonrpc::METHOD_NOT_FOUND,
            message: format!("unknown method: {method}"),
        },
    }
}

/// Handle an incoming JSON-RPC notification from a plugin (no response).
/// Returns None if the notification should be silently ignored.
pub fn handle_notification(
    plugin_id: &str,
    capability: &Capability,
    method: &str,
    params: Option<Value>,
) -> Option<HostAction> {
    match method {
        "panels/register" if capability.panels => {
            let p = params?;
            let name = p.get("name")?.as_str()?.to_owned();
            let slot_str = p.get("slot")?.as_str()?;
            let slot = parse_slot_id(slot_str)?;
            let priority = p.get("priority").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
            let default_visible = p
                .get("default_visible")
                .and_then(|v| v.as_bool())
                .unwrap_or(true);
            Some(HostAction::RegisterPanel(PanelRegistration {
                plugin_id: plugin_id.to_owned(),
                name,
                slot,
                priority,
                default_visible,
            }))
        }
        "commands/register" if capability.commands => {
            let p = params?;
            let name = p.get("name")?.as_str()?.to_owned();
            let description = p
                .get("description")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_owned();
            let keybind = p
                .get("keybind")
                .and_then(|v| v.as_str())
                .map(|s| s.to_owned());
            Some(HostAction::RegisterCommand(CommandRegistration {
                plugin_id: plugin_id.to_owned(),
                name,
                description,
                keybind,
            }))
        }
        "overlay/update" if capability.overlays => {
            let p = params?;
            let name = p.get("name")?.as_str()?.to_owned();
            let z_order = p.get("z_order").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
            let visible = p.get("visible").and_then(|v| v.as_bool()).unwrap_or(true);
            let shapes: Vec<OverlayShape> = p
                .get("shapes")
                .and_then(|v| serde_json::from_value(v.clone()).ok())
                .unwrap_or_default();
            Some(HostAction::UpdateOverlay(OverlayLayer {
                plugin_id: plugin_id.to_owned(),
                name,
                z_order,
                visible,
                shapes,
            }))
        }
        "theme/override" if capability.theme => {
            let p = params?;
            let priority = p.get("priority").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
            let overrides = p
                .get("overrides")
                .and_then(|v| serde_json::from_value(v.clone()).ok())
                .unwrap_or_default();
            Some(HostAction::ThemeOverride(ThemeOverride {
                plugin_id: plugin_id.to_owned(),
                priority,
                overrides,
            }))
        }
        "commands/dispatch" => {
            let p = params?;
            Some(HostAction::DispatchCommand {
                plugin_id: plugin_id.to_owned(),
                command_json: p,
            })
        }
        "host/set_status" => {
            let p = params?;
            let message = p.get("message")?.as_str()?.to_owned();
            Some(HostAction::SetStatus {
                plugin_id: plugin_id.to_owned(),
                message,
            })
        }
        "host/log" => {
            let p = params?;
            let level = p
                .get("level")
                .and_then(|v| v.as_str())
                .unwrap_or("info")
                .to_owned();
            let message = p.get("message")?.as_str()?.to_owned();
            Some(HostAction::Log {
                plugin_id: plugin_id.to_owned(),
                level,
                message,
            })
        }
        _ => None,
    }
}

fn parse_slot_id(s: &str) -> Option<SlotId> {
    match s {
        "LeftSidebar" => Some(SlotId::LeftSidebar),
        "RightSidebar" => Some(SlotId::RightSidebar),
        "BottomBar" => Some(SlotId::BottomBar),
        "Toolbar" => Some(SlotId::Toolbar),
        "MenuBar" => Some(SlotId::MenuBar),
        "CanvasOverlay" => Some(SlotId::CanvasOverlay),
        "StatusBar" => Some(SlotId::StatusBar),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn full_cap() -> Capability {
        Capability {
            panels: true,
            commands: true,
            overlays: true,
            theme: true,
            ..Default::default()
        }
    }

    #[test]
    fn handle_panel_register() {
        let action = handle_notification(
            "test",
            &full_cap(),
            "panels/register",
            Some(json!({
                "name": "MyPanel",
                "slot": "RightSidebar",
                "priority": 5
            })),
        );
        match action {
            Some(HostAction::RegisterPanel(reg)) => {
                assert_eq!(reg.name, "MyPanel");
                assert_eq!(reg.slot, SlotId::RightSidebar);
                assert_eq!(reg.priority, 5);
                assert!(reg.default_visible);
            }
            other => panic!("expected RegisterPanel, got {other:?}"),
        }
    }

    #[test]
    fn handle_command_register() {
        let action = handle_notification(
            "test",
            &full_cap(),
            "commands/register",
            Some(json!({
                "name": "do_thing",
                "description": "Does a thing",
                "keybind": "Ctrl+T"
            })),
        );
        match action {
            Some(HostAction::RegisterCommand(reg)) => {
                assert_eq!(reg.name, "do_thing");
                assert_eq!(reg.keybind.as_deref(), Some("Ctrl+T"));
            }
            other => panic!("expected RegisterCommand, got {other:?}"),
        }
    }

    #[test]
    fn capability_gate_blocks() {
        let no_panels = Capability {
            panels: false,
            ..Default::default()
        };
        let action = handle_notification(
            "test",
            &no_panels,
            "panels/register",
            Some(json!({"name": "X", "slot": "Toolbar"})),
        );
        assert!(action.is_none());
    }

    #[test]
    fn unknown_request_returns_error() {
        let action = handle_request("test", &full_cap(), 99, "bogus/method", None);
        match action {
            HostAction::ErrorResponse { request_id, code, .. } => {
                assert_eq!(request_id, 99);
                assert_eq!(code, jsonrpc::METHOD_NOT_FOUND);
            }
            other => panic!("expected ErrorResponse, got {other:?}"),
        }
    }

    #[test]
    fn handle_set_status() {
        let action = handle_notification(
            "test",
            &full_cap(),
            "host/set_status",
            Some(json!({"message": "Loading..."})),
        );
        match action {
            Some(HostAction::SetStatus { message, .. }) => {
                assert_eq!(message, "Loading...");
            }
            other => panic!("expected SetStatus, got {other:?}"),
        }
    }

    #[test]
    fn query_instances_request() {
        let action = handle_request("test", &full_cap(), 42, "state/query_instances", None);
        match action {
            HostAction::QueryInstances { request_id, .. } => {
                assert_eq!(request_id, 42);
            }
            other => panic!("expected QueryInstances, got {other:?}"),
        }
    }

    #[test]
    fn query_nets_request() {
        let action = handle_request("test", &full_cap(), 7, "state/query_nets", None);
        match action {
            HostAction::QueryNets { request_id, plugin_id } => {
                assert_eq!(request_id, 7);
                assert_eq!(plugin_id, "test");
            }
            other => panic!("expected QueryNets, got {other:?}"),
        }
    }

    #[test]
    fn handle_overlay_update() {
        let action = handle_notification(
            "overlay_plugin",
            &full_cap(),
            "overlay/update",
            Some(json!({
                "name": "drc_errors",
                "z_order": 10,
                "visible": true,
                "shapes": [
                    {
                        "Marker": {
                            "x": 100.0,
                            "y": 200.0,
                            "kind": "Error",
                            "color": [255, 0, 0, 255]
                        }
                    }
                ]
            })),
        );
        match action {
            Some(HostAction::UpdateOverlay(layer)) => {
                assert_eq!(layer.plugin_id, "overlay_plugin");
                assert_eq!(layer.name, "drc_errors");
                assert_eq!(layer.z_order, 10);
                assert!(layer.visible);
                assert_eq!(layer.shapes.len(), 1);
            }
            other => panic!("expected UpdateOverlay, got {other:?}"),
        }
    }

    #[test]
    fn handle_theme_override() {
        let action = handle_notification(
            "theme_plugin",
            &full_cap(),
            "theme/override",
            Some(json!({
                "priority": 5,
                "overrides": {
                    "accent": {"Color": [255, 0, 128, 255]}
                }
            })),
        );
        match action {
            Some(HostAction::ThemeOverride(ov)) => {
                assert_eq!(ov.plugin_id, "theme_plugin");
                assert_eq!(ov.priority, 5);
                assert!(ov.overrides.contains_key("accent"));
            }
            other => panic!("expected ThemeOverride, got {other:?}"),
        }
    }

    #[test]
    fn handle_command_dispatch() {
        let action = handle_notification(
            "test",
            &full_cap(),
            "commands/dispatch",
            Some(json!({"action": "zoom_in"})),
        );
        match action {
            Some(HostAction::DispatchCommand { plugin_id, command_json }) => {
                assert_eq!(plugin_id, "test");
                assert_eq!(command_json["action"], "zoom_in");
            }
            other => panic!("expected DispatchCommand, got {other:?}"),
        }
    }

    #[test]
    fn handle_log() {
        let action = handle_notification(
            "test",
            &full_cap(),
            "host/log",
            Some(json!({"level": "warn", "message": "something happened"})),
        );
        match action {
            Some(HostAction::Log { level, message, .. }) => {
                assert_eq!(level, "warn");
                assert_eq!(message, "something happened");
            }
            other => panic!("expected Log, got {other:?}"),
        }
    }

    #[test]
    fn handle_log_default_level() {
        let action = handle_notification(
            "test",
            &full_cap(),
            "host/log",
            Some(json!({"message": "no level specified"})),
        );
        match action {
            Some(HostAction::Log { level, .. }) => {
                assert_eq!(level, "info");
            }
            other => panic!("expected Log, got {other:?}"),
        }
    }

    #[test]
    fn unknown_notification_returns_none() {
        let action = handle_notification(
            "test",
            &full_cap(),
            "totally/unknown",
            None,
        );
        assert!(action.is_none());
    }

    #[test]
    fn missing_params_returns_none() {
        let action = handle_notification(
            "test",
            &full_cap(),
            "panels/register",
            None,
        );
        assert!(action.is_none());
    }

    #[test]
    fn overlay_without_capability_blocked() {
        let no_overlay = Capability {
            panels: true,
            commands: true,
            overlays: false,
            theme: true,
            ..Default::default()
        };
        let action = handle_notification(
            "test",
            &no_overlay,
            "overlay/update",
            Some(json!({"name": "test", "shapes": []})),
        );
        assert!(action.is_none());
    }

    #[test]
    fn theme_without_capability_blocked() {
        let no_theme = Capability {
            panels: true,
            commands: true,
            overlays: true,
            theme: false,
            ..Default::default()
        };
        let action = handle_notification(
            "test",
            &no_theme,
            "theme/override",
            Some(json!({"overrides": {}})),
        );
        assert!(action.is_none());
    }

    #[test]
    fn parse_all_slot_ids() {
        assert_eq!(parse_slot_id("LeftSidebar"), Some(SlotId::LeftSidebar));
        assert_eq!(parse_slot_id("RightSidebar"), Some(SlotId::RightSidebar));
        assert_eq!(parse_slot_id("BottomBar"), Some(SlotId::BottomBar));
        assert_eq!(parse_slot_id("Toolbar"), Some(SlotId::Toolbar));
        assert_eq!(parse_slot_id("MenuBar"), Some(SlotId::MenuBar));
        assert_eq!(parse_slot_id("CanvasOverlay"), Some(SlotId::CanvasOverlay));
        assert_eq!(parse_slot_id("StatusBar"), Some(SlotId::StatusBar));
        assert_eq!(parse_slot_id("InvalidSlot"), None);
    }
}
