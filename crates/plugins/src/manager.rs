use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde_json::{json, Value};

use crate::capability::{self, Capability, HostCapabilities, NegotiatedCapabilities};
use crate::host::HostAction;
use crate::jsonrpc::{self, IncomingMessage};
use crate::manifest::{ManifestError, PluginManifest};
use crate::transport::{self, PluginTransport};

/// Plugin lifecycle state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PluginState {
    Discovered,
    Starting,
    Running,
    Stopping,
    Stopped,
    Error,
}

impl PluginState {
    /// Whether a transition to the given target state is valid.
    pub fn can_transition_to(self, target: PluginState) -> bool {
        matches!(
            (self, target),
            // Discovered -> Starting (begin launch)
            (PluginState::Discovered, PluginState::Starting)
            // Discovered -> Error (manifest issue detected late)
            | (PluginState::Discovered, PluginState::Error)
            // Starting -> Running (spawn succeeded)
            | (PluginState::Starting, PluginState::Running)
            // Starting -> Error (spawn failed)
            | (PluginState::Starting, PluginState::Error)
            // Running -> Stopping (shutdown requested)
            | (PluginState::Running, PluginState::Stopping)
            // Running -> Error (process crashed)
            | (PluginState::Running, PluginState::Error)
            // Stopping -> Stopped (clean shutdown)
            | (PluginState::Stopping, PluginState::Stopped)
            // Stopping -> Error (shutdown failed)
            | (PluginState::Stopping, PluginState::Error)
            // Stopped -> Starting (restart)
            | (PluginState::Stopped, PluginState::Starting)
            // Error -> Starting (retry)
            | (PluginState::Error, PluginState::Starting)
        )
    }
}

/// Per-plugin runtime slot.
pub(crate) struct PluginSlot {
    pub(crate) manifest: PluginManifest,
    pub(crate) dir: PathBuf,
    pub(crate) state: PluginState,
    pub(crate) capability: Capability,
    pub(crate) negotiated: Option<NegotiatedCapabilities>,
    pub(crate) transport: Option<Box<dyn PluginTransport>>,
    pub(crate) error_msg: Option<String>,
}

/// Manages discovery, lifecycle, and IPC for all plugins.
pub struct PluginManager {
    pub(crate) plugins: HashMap<String, PluginSlot>,
    next_rpc_id: u32,
    host_caps: HostCapabilities,
    scan_dirs: Vec<PathBuf>,
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

    /// Add a directory to be scanned for plugins.
    pub fn add_scan_dir(&mut self, dir: PathBuf) {
        if !self.scan_dirs.contains(&dir) {
            self.scan_dirs.push(dir);
        }
    }

    /// Scan all registered directories for plugin subdirectories containing plugin.toml.
    pub fn scan_directories(&mut self) -> Vec<ManifestError> {
        let dirs: Vec<PathBuf> = self.scan_dirs.clone();
        let mut errors = Vec::new();
        for dir in &dirs {
            errors.extend(self.discover(dir));
        }
        errors
    }

    /// Scan a single directory for plugin subdirectories containing plugin.toml.
    pub fn discover(&mut self, plugins_dir: &Path) -> Vec<ManifestError> {
        let mut errors = Vec::new();
        let entries = match std::fs::read_dir(plugins_dir) {
            Ok(e) => e,
            Err(_) => return errors,
        };

        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let manifest_path = path.join("plugin.toml");
            if !manifest_path.exists() {
                continue;
            }
            match PluginManifest::load(&manifest_path) {
                Ok(manifest) => {
                    let name = manifest.plugin.name.clone();
                    if self.plugins.contains_key(&name) {
                        continue;
                    }
                    let capability =
                        Capability::from_manifest(&manifest.capabilities);
                    let negotiated = Some(capability::negotiate(
                        &self.host_caps,
                        &manifest.capabilities,
                    ));
                    self.plugins.insert(
                        name,
                        PluginSlot {
                            manifest,
                            dir: path,
                            state: PluginState::Discovered,
                            capability,
                            negotiated,
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

    /// List all discovered plugin names.
    pub fn plugin_names(&self) -> Vec<&str> {
        self.plugins.keys().map(|s| s.as_str()).collect()
    }

    /// Number of discovered plugins.
    pub fn plugin_count(&self) -> usize {
        self.plugins.len()
    }

    /// Get the state of a plugin.
    pub fn plugin_state(&self, name: &str) -> Option<PluginState> {
        self.plugins.get(name).map(|s| s.state)
    }

    /// Get the manifest of a plugin.
    pub fn manifest(&self, name: &str) -> Option<&PluginManifest> {
        self.plugins.get(name).map(|s| &s.manifest)
    }

    /// Get error message for a plugin in Error state.
    pub fn error_msg(&self, name: &str) -> Option<&str> {
        self.plugins
            .get(name)
            .and_then(|s| s.error_msg.as_deref())
    }

    /// Get negotiated capabilities for a plugin.
    pub fn negotiated_caps(&self, name: &str) -> Option<&NegotiatedCapabilities> {
        self.plugins.get(name).and_then(|s| s.negotiated.as_ref())
    }

    /// Start a discovered plugin: create transport, spawn, send initialize.
    pub fn start_plugin(&mut self, name: &str) -> Result<(), String> {
        let slot = self
            .plugins
            .get_mut(name)
            .ok_or_else(|| format!("unknown plugin: {name}"))?;

        match slot.state {
            PluginState::Discovered | PluginState::Stopped | PluginState::Error => {}
            PluginState::Running | PluginState::Starting => {
                return Err(format!("{name} already running"));
            }
            PluginState::Stopping => {
                return Err(format!("{name} is stopping"));
            }
        }

        slot.state = PluginState::Starting;
        slot.error_msg = None;

        let runtime_str = slot.manifest.plugin.runtime.as_transport_str();
        let mut new_transport = transport::create_transport(runtime_str);

        match new_transport.spawn(&slot.manifest, &slot.dir) {
            Ok(()) => {
                let init_params = json!({
                    "host_capabilities": self.host_caps,
                    "plugin_name": name,
                });
                let init_msg = jsonrpc::encode_notification(
                    "lifecycle/initialize",
                    Some(init_params),
                );
                if let Err(e) = new_transport.send(&init_msg) {
                    slot.state = PluginState::Error;
                    slot.error_msg = Some(format!("send initialize failed: {e}"));
                    return Err(slot.error_msg.clone().unwrap());
                }
                slot.transport = Some(new_transport);
                slot.state = PluginState::Running;
                Ok(())
            }
            Err(e) => {
                slot.state = PluginState::Error;
                slot.error_msg = Some(format!("spawn failed: {e}"));
                Err(slot.error_msg.clone().unwrap())
            }
        }
    }

    /// Stop a running plugin: send shutdown + stop transport.
    pub fn stop_plugin(&mut self, name: &str) -> Result<(), String> {
        let slot = self
            .plugins
            .get_mut(name)
            .ok_or_else(|| format!("unknown plugin: {name}"))?;

        if slot.state != PluginState::Running {
            return Err(format!("{name} not running"));
        }

        slot.state = PluginState::Stopping;

        if let Some(ref mut t) = slot.transport {
            let shutdown_msg = jsonrpc::encode_notification("lifecycle/shutdown", None);
            let _ = t.send(&shutdown_msg);
            let _ = t.stop();
        }
        slot.transport = None;
        slot.state = PluginState::Stopped;
        Ok(())
    }

    /// Stop all running plugins.
    pub fn stop_all(&mut self) {
        let names: Vec<String> = self
            .plugins
            .iter()
            .filter(|(_, s)| s.state == PluginState::Running)
            .map(|(n, _)| n.clone())
            .collect();
        for name in names {
            let _ = self.stop_plugin(&name);
        }
    }

    /// Shutdown all plugins (stop running ones, clear state).
    pub fn shutdown_all(&mut self) {
        self.stop_all();
        // Clear all transports to ensure cleanup
        for slot in self.plugins.values_mut() {
            if let Some(ref mut t) = slot.transport {
                let _ = t.stop();
            }
            slot.transport = None;
            match slot.state {
                PluginState::Running | PluginState::Starting => {
                    slot.state = PluginState::Stopped;
                }
                _ => {}
            }
        }
    }

    /// Tick: drain messages from all running plugins, return host actions.
    pub fn tick(&mut self) -> Vec<HostAction> {
        let mut actions = Vec::new();
        let names: Vec<String> = self
            .plugins
            .iter()
            .filter(|(_, s)| s.state == PluginState::Running)
            .map(|(n, _)| n.clone())
            .collect();

        for name in names {
            let slot = self.plugins.get_mut(&name).unwrap();
            let t = match slot.transport.as_mut() {
                Some(t) => t,
                None => continue,
            };

            // Check alive
            if !t.is_running() {
                slot.state = PluginState::Error;
                slot.error_msg = Some("process exited unexpectedly".into());
                slot.transport = None;
                continue;
            }

            // Drain messages
            for _ in 0..self.max_drain {
                match t.recv() {
                    Ok(Some(line)) => {
                        match jsonrpc::parse_line(&line) {
                            Ok(msg) => match msg {
                                IncomingMessage::Request { id, method, params } => {
                                    let action = crate::host::handle_request(
                                        &name,
                                        &slot.capability,
                                        id,
                                        &method,
                                        params,
                                    );
                                    actions.push(action);
                                }
                                IncomingMessage::Notification { method, params } => {
                                    if let Some(action) = crate::host::handle_notification(
                                        &name,
                                        &slot.capability,
                                        &method,
                                        params,
                                    ) {
                                        actions.push(action);
                                    }
                                }
                                IncomingMessage::Response { .. } => {
                                    // Response to our request -- currently no pending request tracking
                                }
                            },
                            Err(_) => {
                                // Malformed JSON line, skip
                            }
                        }
                    }
                    Ok(None) => break,
                    Err(_) => break,
                }
            }
        }

        actions
    }

    /// Send a notification to a specific plugin.
    pub fn notify_plugin(
        &mut self,
        name: &str,
        method: &str,
        params: Option<Value>,
    ) -> Result<(), String> {
        let slot = self
            .plugins
            .get_mut(name)
            .ok_or_else(|| format!("unknown plugin: {name}"))?;
        let t = slot
            .transport
            .as_mut()
            .ok_or_else(|| format!("{name} not running"))?;
        let msg = jsonrpc::encode_notification(method, params);
        t.send(&msg).map_err(|e| format!("send failed: {e}"))
    }

    /// Broadcast a notification to all running plugins.
    pub fn broadcast(&mut self, method: &str, params: Option<Value>) {
        let names: Vec<String> = self
            .plugins
            .iter()
            .filter(|(_, s)| s.state == PluginState::Running)
            .map(|(n, _)| n.clone())
            .collect();
        for name in names {
            let _ = self.notify_plugin(&name, method, params.clone());
        }
    }

    /// Notify all plugins of schematic change.
    pub fn notify_schematic_changed(&mut self) {
        self.broadcast("state/schematic_changed", None);
    }

    /// Notify all plugins of selection change.
    pub fn notify_selection_changed(&mut self) {
        self.broadcast("state/selection_changed", None);
    }

    /// Notify all plugins of theme change.
    pub fn notify_theme_changed(&mut self) {
        self.broadcast("state/theme_changed", None);
    }

    /// Send a response back to a plugin.
    pub fn send_response(
        &mut self,
        plugin_name: &str,
        id: u32,
        result: Value,
    ) -> Result<(), String> {
        let slot = self
            .plugins
            .get_mut(plugin_name)
            .ok_or_else(|| format!("unknown plugin: {plugin_name}"))?;
        let t = slot
            .transport
            .as_mut()
            .ok_or_else(|| format!("{plugin_name} not running"))?;
        let msg = jsonrpc::encode_response(id, result);
        t.send(&msg).map_err(|e| format!("send response failed: {e}"))
    }

    /// Send an error response back to a plugin.
    pub fn send_error_response(
        &mut self,
        plugin_name: &str,
        id: u32,
        code: i32,
        message: &str,
    ) -> Result<(), String> {
        let slot = self
            .plugins
            .get_mut(plugin_name)
            .ok_or_else(|| format!("unknown plugin: {plugin_name}"))?;
        let t = slot
            .transport
            .as_mut()
            .ok_or_else(|| format!("{plugin_name} not running"))?;
        let msg = jsonrpc::encode_error(id, code, message);
        t.send(&msg).map_err(|e| format!("send error failed: {e}"))
    }

    fn next_id(&mut self) -> u32 {
        let id = self.next_rpc_id;
        self.next_rpc_id = self.next_rpc_id.wrapping_add(1);
        id
    }

    /// Send a request to a plugin and return the request id.
    pub fn send_request(
        &mut self,
        plugin_name: &str,
        method: &str,
        params: Option<Value>,
    ) -> Result<u32, String> {
        let id = self.next_id();
        let slot = self
            .plugins
            .get_mut(plugin_name)
            .ok_or_else(|| format!("unknown plugin: {plugin_name}"))?;
        let t = slot
            .transport
            .as_mut()
            .ok_or_else(|| format!("{plugin_name} not running"))?;
        let msg = jsonrpc::encode_request(id, method, params);
        t.send(&msg).map_err(|e| format!("send request failed: {e}"))?;
        Ok(id)
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
    use std::fs;

    fn setup_plugin_dir(tmp: &Path, name: &str, toml_content: &str) {
        let dir = tmp.join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("plugin.toml"), toml_content).unwrap();
    }

    #[test]
    fn discover_plugins() {
        let tmp = std::env::temp_dir().join("schemify_test_discover");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();

        setup_plugin_dir(
            &tmp,
            "test_plugin",
            r#"
[plugin]
name = "TestPlugin"
version = "1.0.0"
entry = "echo hello"
"#,
        );

        let mut mgr = PluginManager::new();
        let errors = mgr.discover(&tmp);
        assert!(errors.is_empty(), "errors: {errors:?}");
        assert!(mgr.plugin_names().contains(&"TestPlugin"));
        assert_eq!(
            mgr.plugin_state("TestPlugin"),
            Some(PluginState::Discovered)
        );

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn discover_skips_invalid() {
        let tmp = std::env::temp_dir().join("schemify_test_skip");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();

        let bad_dir = tmp.join("bad");
        fs::create_dir_all(&bad_dir).unwrap();
        fs::write(bad_dir.join("plugin.toml"), "garbage").unwrap();

        let mut mgr = PluginManager::new();
        let errors = mgr.discover(&tmp);
        assert_eq!(errors.len(), 1);
        assert!(mgr.plugin_names().is_empty());

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn lifecycle_states() {
        let mut mgr = PluginManager::new();

        // Manually insert a "fake" discovered plugin
        let manifest = PluginManifest::parse(
            r#"
[plugin]
name = "Fake"
version = "0.1.0"
entry = "nonexistent_binary_xyz"
"#,
        )
        .unwrap();

        mgr.plugins.insert(
            "Fake".into(),
            PluginSlot {
                manifest,
                dir: std::env::temp_dir(),
                state: PluginState::Discovered,
                capability: Capability::default(),
                negotiated: None,
                transport: None,
                error_msg: None,
            },
        );

        // Start should fail (binary doesn't exist) -> Error state
        let result = mgr.start_plugin("Fake");
        assert!(result.is_err());
        assert_eq!(mgr.plugin_state("Fake"), Some(PluginState::Error));
        assert!(mgr.error_msg("Fake").is_some());
    }

    #[test]
    fn scan_directories_multiple() {
        let base = std::env::temp_dir().join("schemify_test_scan_multi");
        let _ = fs::remove_dir_all(&base);

        let dir_a = base.join("dir_a");
        let dir_b = base.join("dir_b");
        fs::create_dir_all(&dir_a).unwrap();
        fs::create_dir_all(&dir_b).unwrap();

        setup_plugin_dir(
            &dir_a,
            "plug_a",
            r#"
[plugin]
name = "PlugA"
version = "1.0.0"
entry = "echo a"
"#,
        );
        setup_plugin_dir(
            &dir_b,
            "plug_b",
            r#"
[plugin]
name = "PlugB"
version = "2.0.0"
entry = "echo b"
"#,
        );

        let mut mgr = PluginManager::new();
        mgr.add_scan_dir(dir_a);
        mgr.add_scan_dir(dir_b);
        let errors = mgr.scan_directories();
        assert!(errors.is_empty());
        assert_eq!(mgr.plugin_count(), 2);
        assert!(mgr.plugin_names().contains(&"PlugA"));
        assert!(mgr.plugin_names().contains(&"PlugB"));

        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn state_transitions_valid() {
        assert!(PluginState::Discovered.can_transition_to(PluginState::Starting));
        assert!(PluginState::Starting.can_transition_to(PluginState::Running));
        assert!(PluginState::Starting.can_transition_to(PluginState::Error));
        assert!(PluginState::Running.can_transition_to(PluginState::Stopping));
        assert!(PluginState::Running.can_transition_to(PluginState::Error));
        assert!(PluginState::Stopping.can_transition_to(PluginState::Stopped));
        assert!(PluginState::Stopping.can_transition_to(PluginState::Error));
        assert!(PluginState::Stopped.can_transition_to(PluginState::Starting));
        assert!(PluginState::Error.can_transition_to(PluginState::Starting));
    }

    #[test]
    fn state_transitions_invalid() {
        assert!(!PluginState::Discovered.can_transition_to(PluginState::Running));
        assert!(!PluginState::Discovered.can_transition_to(PluginState::Stopping));
        assert!(!PluginState::Discovered.can_transition_to(PluginState::Stopped));
        assert!(!PluginState::Running.can_transition_to(PluginState::Starting));
        assert!(!PluginState::Running.can_transition_to(PluginState::Discovered));
        assert!(!PluginState::Stopped.can_transition_to(PluginState::Running));
        assert!(!PluginState::Error.can_transition_to(PluginState::Running));
    }

    #[test]
    fn stop_not_running_returns_error() {
        let mut mgr = PluginManager::new();
        let manifest = PluginManifest::parse(
            r#"
[plugin]
name = "Idle"
version = "0.1.0"
entry = "echo"
"#,
        )
        .unwrap();

        mgr.plugins.insert(
            "Idle".into(),
            PluginSlot {
                manifest,
                dir: std::env::temp_dir(),
                state: PluginState::Discovered,
                capability: Capability::default(),
                negotiated: None,
                transport: None,
                error_msg: None,
            },
        );

        let result = mgr.stop_plugin("Idle");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("not running"));
    }

    #[test]
    fn start_unknown_returns_error() {
        let mut mgr = PluginManager::new();
        let result = mgr.start_plugin("DoesNotExist");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("unknown plugin"));
    }

    #[test]
    fn shutdown_all_clears_state() {
        let mut mgr = PluginManager::new();
        let manifest = PluginManifest::parse(
            r#"
[plugin]
name = "ShutTest"
version = "0.1.0"
entry = "echo"
"#,
        )
        .unwrap();

        mgr.plugins.insert(
            "ShutTest".into(),
            PluginSlot {
                manifest,
                dir: std::env::temp_dir(),
                state: PluginState::Discovered,
                capability: Capability::default(),
                negotiated: None,
                transport: None,
                error_msg: None,
            },
        );

        mgr.shutdown_all();
        // Discovered plugins stay discovered (no transport to clean)
        assert_eq!(
            mgr.plugin_state("ShutTest"),
            Some(PluginState::Discovered)
        );
    }

    #[test]
    fn negotiated_caps_set_on_discover() {
        let tmp = std::env::temp_dir().join("schemify_test_neg_caps");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();

        setup_plugin_dir(
            &tmp,
            "neg_test",
            r#"
[plugin]
name = "NegTest"
version = "1.0.0"
entry = "echo"

[capabilities]
panels = true
commands = false
overlays = true
theme = false
"#,
        );

        let mut mgr = PluginManager::new();
        mgr.discover(&tmp);

        let neg = mgr.negotiated_caps("NegTest").unwrap();
        assert!(neg.panels);
        assert!(!neg.commands);
        assert!(neg.overlays);
        assert!(!neg.theme);
        assert!(neg.query_instances);
        assert!(neg.query_nets);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn add_scan_dir_deduplicates() {
        let mut mgr = PluginManager::new();
        let dir = PathBuf::from("/tmp/test_dedup");
        mgr.add_scan_dir(dir.clone());
        mgr.add_scan_dir(dir.clone());
        assert_eq!(mgr.scan_dirs.len(), 1);
    }

    #[test]
    fn default_impl() {
        let mgr = PluginManager::default();
        assert_eq!(mgr.plugin_count(), 0);
    }
}
