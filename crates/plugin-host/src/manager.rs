//! Plugin lifecycle: discovery, start/stop, and the per-tick pump that
//! drains plugin messages into [`PluginHostAction`]s.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use schemify_plugin_api::protocol::*;

use crate::decode::{handle_notification, handle_request, negotiate, LogLevel, NegotiatedCapabilities};
use crate::manifest::{ManifestError, PluginManifest};
use crate::transport::{SubprocessTransport, TransportError};

/// Lifecycle state of a hosted plugin process.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PluginLifecycle {
    Discovered,
    Running,
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
        level: LogLevel,
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
    /// Plugin is already running.
    #[error("plugin {0} is already running")]
    AlreadyRunning(String),
}

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
    host_caps: HostCapabilities,
    scan_dirs: Vec<PathBuf>,
    /// Max messages drained per plugin per tick.
    max_drain: usize,
}

impl PluginManager {
    pub fn new() -> Self {
        Self {
            plugins: HashMap::new(),
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
            PluginLifecycle::Running => {
                return Err(PluginError::AlreadyRunning(id.to_owned()));
            }
        }

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
            if slot.state == PluginLifecycle::Running {
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
                                level: LogLevel::Error,
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
}

impl Default for PluginManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::manifest::{validate_plugin_id, ManifestCapabilities};
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
    }

    #[test]
    fn minimal_manifest() {
        let m = PluginManifest::parse(
            "[plugin]\nid = \"bare\"\nname = \"Bare\"\nversion = \"0.1.0\"\nentry = \"bare.py\"\n",
        )
        .unwrap();
        assert_eq!(m.plugin.id, "bare");
        assert!(!m.capabilities.panels);
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
            Some(PluginHostAction::Log { level, .. }) => assert_eq!(level, LogLevel::Info),
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
    fn recv_reassembles_line_split_across_polls() {
        // A plugin may write one long JSON line in several chunks; polls in
        // between hit WouldBlock mid-line and must not drop the prefix.
        let dir = std::env::temp_dir().join("schemify_recv_split_test");
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("split.sh"),
            "#!/bin/sh\nprintf aaaa\nsleep 0.2\nprintf 'bbbb\\n'\n",
        )
        .unwrap();
        let mut t = SubprocessTransport::spawn("sh split.sh", &dir).unwrap();

        // Poll until the full line arrives; partial reads must accumulate.
        let mut got = None;
        for _ in 0..50 {
            match t.recv() {
                Ok(Some(line)) => {
                    got = Some(line);
                    break;
                }
                Ok(None) => std::thread::sleep(std::time::Duration::from_millis(20)),
                Err(e) => panic!("recv failed: {e}"),
            }
        }
        assert_eq!(got.as_deref(), Some("aaaabbbb"));
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
        assert_eq!(mgr.plugins.len(), 0);

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
        assert_eq!(mgr.plugins.len(), 2);

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
}
