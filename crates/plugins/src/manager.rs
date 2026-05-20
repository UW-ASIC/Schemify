use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde_json::{json, Value};

use crate::capability::{Capability, HostCapabilities};
use crate::host::HostAction;
use crate::jsonrpc::IncomingMessage;
use crate::manifest::{ManifestError, PluginManifest};
use crate::runtime::Subprocess;

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

/// Per-plugin runtime slot.
struct PluginSlot {
    manifest: PluginManifest,
    dir: PathBuf,
    state: PluginState,
    capability: Capability,
    transport: Option<Subprocess>,
    error_msg: Option<String>,
}

/// Manages discovery, lifecycle, and IPC for all plugins.
pub struct PluginManager {
    plugins: HashMap<String, PluginSlot>,
    #[allow(dead_code)]
    next_rpc_id: u32,
    host_caps: HostCapabilities,
    max_drain: usize,
}

impl PluginManager {
    pub fn new() -> Self {
        Self {
            plugins: HashMap::new(),
            next_rpc_id: 1,
            host_caps: HostCapabilities::default(),
            max_drain: 16,
        }
    }

    /// Scan a directory for plugin subdirectories containing plugin.toml.
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
                    self.plugins.insert(
                        name,
                        PluginSlot {
                            manifest,
                            dir: path,
                            state: PluginState::Discovered,
                            capability,
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

    /// Start a discovered plugin: spawn subprocess + send initialize.
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

        let command = &slot.manifest.plugin.entry;
        let cwd = &slot.dir;

        match Subprocess::spawn(command, cwd) {
            Ok(mut transport) => {
                let init_params = json!({
                    "host_capabilities": self.host_caps,
                    "plugin_name": name,
                });
                if let Err(e) = transport.send_notification(
                    "lifecycle/initialize",
                    Some(init_params),
                ) {
                    slot.state = PluginState::Error;
                    slot.error_msg = Some(format!("send initialize failed: {e}"));
                    return Err(slot.error_msg.clone().unwrap());
                }
                slot.transport = Some(transport);
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

    /// Stop a running plugin: send shutdown + kill.
    pub fn stop_plugin(&mut self, name: &str) -> Result<(), String> {
        let slot = self
            .plugins
            .get_mut(name)
            .ok_or_else(|| format!("unknown plugin: {name}"))?;

        if slot.state != PluginState::Running {
            return Err(format!("{name} not running"));
        }

        slot.state = PluginState::Stopping;

        if let Some(ref mut transport) = slot.transport {
            let _ = transport.send_notification("lifecycle/shutdown", None);
            transport.kill();
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
            let transport = match slot.transport.as_mut() {
                Some(t) => t,
                None => continue,
            };

            // Check alive
            if !transport.is_alive() {
                slot.state = PluginState::Error;
                slot.error_msg = Some("process exited unexpectedly".into());
                slot.transport = None;
                continue;
            }

            // Drain messages
            let msgs = transport.drain_messages(self.max_drain);
            for msg in msgs {
                match msg {
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
                        // Response to our request — currently no pending request tracking
                    }
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
        let transport = slot
            .transport
            .as_mut()
            .ok_or_else(|| format!("{name} not running"))?;
        transport
            .send_notification(method, params)
            .map_err(|e| format!("send failed: {e}"))
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
        let transport = slot
            .transport
            .as_mut()
            .ok_or_else(|| format!("{plugin_name} not running"))?;
        transport
            .send_response(id, result)
            .map_err(|e| format!("send response failed: {e}"))
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
        let transport = slot
            .transport
            .as_mut()
            .ok_or_else(|| format!("{plugin_name} not running"))?;
        transport
            .send_error(id, code, message)
            .map_err(|e| format!("send error failed: {e}"))
    }

    #[allow(dead_code)]
    fn next_id(&mut self) -> u32 {
        let id = self.next_rpc_id;
        self.next_rpc_id = self.next_rpc_id.wrapping_add(1);
        id
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
}
