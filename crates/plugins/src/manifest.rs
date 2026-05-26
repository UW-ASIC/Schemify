use serde::Deserialize;
use std::path::Path;

/// Plugin runtime type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PluginRuntime {
    Native,
    Subprocess,
    Wasm,
}

impl PluginRuntime {
    /// Return the transport string used by `create_transport()`.
    pub fn as_transport_str(&self) -> &'static str {
        match self {
            Self::Native => "native",
            Self::Subprocess => "subprocess",
            Self::Wasm => "wasm",
        }
    }
}

impl Default for PluginRuntime {
    fn default() -> Self {
        Self::Subprocess
    }
}

/// Capability flags declared in manifest.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct ManifestCapabilities {
    #[serde(default)]
    pub panels: bool,
    #[serde(default)]
    pub commands: bool,
    #[serde(default)]
    pub overlays: bool,
    #[serde(default)]
    pub theme: bool,
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

/// Sandbox path permission entry.
#[derive(Debug, Clone, Deserialize)]
pub struct SandboxPath {
    pub path: String,
    pub access: String,
}

/// [sandbox] section — plugin-declared permissions.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct ManifestSandbox {
    #[serde(default)]
    pub network: bool,
    #[serde(default)]
    pub paths: Vec<SandboxPath>,
}

/// [events] section — lifecycle event subscriptions.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct ManifestEvents {
    #[serde(default)]
    pub listen: Vec<String>,
}

/// Top-level [plugin] section.
#[derive(Debug, Clone, Deserialize)]
pub struct ManifestPlugin {
    #[serde(default)]
    pub id: Option<String>,
    pub name: String,
    pub version: String,
    #[serde(default)]
    pub description: String,
    pub entry: String,
    #[serde(default)]
    pub runtime: PluginRuntime,
    #[serde(default)]
    pub api_version: Option<u32>,
}

/// Full plugin.toml manifest.
#[derive(Debug, Clone, Deserialize)]
pub struct PluginManifest {
    pub plugin: ManifestPlugin,
    #[serde(default)]
    pub capabilities: ManifestCapabilities,
    #[serde(default)]
    pub panels: ManifestPanels,
    #[serde(default)]
    pub commands: ManifestCommands,
    #[serde(default)]
    pub sandbox: ManifestSandbox,
    #[serde(default)]
    pub events: ManifestEvents,
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

/// Validate a plugin id: `[a-z0-9][a-z0-9-]*[a-z0-9]`, 3-64 chars.
pub fn validate_plugin_id(id: &str) -> Result<(), String> {
    let len = id.len();
    if len < 3 || len > 64 {
        return Err(format!("plugin id must be 3-64 chars, got {len}"));
    }
    let bytes = id.as_bytes();
    if !bytes[0].is_ascii_lowercase() && !bytes[0].is_ascii_digit() {
        return Err("plugin id must start with [a-z0-9]".into());
    }
    let last = bytes[len - 1];
    if !last.is_ascii_lowercase() && !last.is_ascii_digit() {
        return Err("plugin id must end with [a-z0-9]".into());
    }
    for &b in bytes {
        if !b.is_ascii_lowercase() && !b.is_ascii_digit() && b != b'-' {
            return Err(format!(
                "plugin id contains invalid char '{}'",
                b as char
            ));
        }
    }
    Ok(())
}

impl PluginManifest {
    /// Parse a plugin.toml from string content.
    pub fn parse(content: &str) -> Result<Self, toml::de::Error> {
        toml::from_str(content)
    }

    /// Load a plugin.toml from a file path.
    pub fn load(path: &Path) -> Result<Self, ManifestError> {
        let content = std::fs::read_to_string(path)
            .map_err(|e| ManifestError::Io(path.to_owned(), e))?;
        Self::parse(&content).map_err(|e| ManifestError::Parse(path.to_owned(), e))
    }

    /// Validate manifest fields (id format, api_version range).
    pub fn validate(&self) -> Result<(), String> {
        if let Some(ref id) = self.plugin.id {
            validate_plugin_id(id)?;
        }
        Ok(())
    }
}

#[derive(Debug)]
pub enum ManifestError {
    Io(std::path::PathBuf, std::io::Error),
    Parse(std::path::PathBuf, toml::de::Error),
}

impl std::fmt::Display for ManifestError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(p, e) => write!(f, "reading {}: {e}", p.display()),
            Self::Parse(p, e) => write!(f, "parsing {}: {e}", p.display()),
        }
    }
}

impl std::error::Error for ManifestError {}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"
[plugin]
id = "pdk-switcher"
name = "PDKSwitcher"
version = "1.0.0"
description = "Switch between PDK configurations"
entry = "plugin.py"
runtime = "subprocess"
api_version = 1

[capabilities]
panels = true
commands = true
overlays = false
theme = true

[sandbox]
network = false
paths = [
    { path = "$PLUGIN_DIR", access = "read" },
]

[events]
listen = ["project_opened", "pre_save"]

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
        assert_eq!(m.plugin.id.as_deref(), Some("pdk-switcher"));
        assert_eq!(m.plugin.name, "PDKSwitcher");
        assert_eq!(m.plugin.version, "1.0.0");
        assert_eq!(m.plugin.runtime, PluginRuntime::Subprocess);
        assert_eq!(m.plugin.api_version, Some(1));
        assert!(m.capabilities.panels);
        assert!(m.capabilities.commands);
        assert!(!m.capabilities.overlays);
        assert!(m.capabilities.theme);
        assert!(!m.sandbox.network);
        assert_eq!(m.sandbox.paths.len(), 1);
        assert_eq!(m.sandbox.paths[0].path, "$PLUGIN_DIR");
        assert_eq!(m.events.listen, vec!["project_opened", "pre_save"]);
    }

    #[test]
    fn parse_panels() {
        let m = PluginManifest::parse(SAMPLE).unwrap();
        assert_eq!(m.panels.panel.len(), 1);
        assert_eq!(m.panels.panel[0].name, "PDK Config");
        assert_eq!(m.panels.panel[0].slot, "RightSidebar");
        assert_eq!(m.panels.panel[0].priority, 10);
    }

    #[test]
    fn parse_commands() {
        let m = PluginManifest::parse(SAMPLE).unwrap();
        assert_eq!(m.commands.command.len(), 1);
        assert_eq!(m.commands.command[0].name, "switch_pdk");
        assert_eq!(
            m.commands.command[0].keybind.as_deref(),
            Some("Ctrl+Shift+P")
        );
    }

    #[test]
    fn minimal_manifest() {
        let toml = r#"
[plugin]
name = "Bare"
version = "0.1.0"
entry = "bare.py"
"#;
        let m = PluginManifest::parse(toml).unwrap();
        assert_eq!(m.plugin.name, "Bare");
        assert!(!m.capabilities.panels);
        assert!(m.panels.panel.is_empty());
    }

    #[test]
    fn missing_optional_fields_default() {
        let toml = r#"
[plugin]
name = "Defaults"
version = "0.1.0"
entry = "run.sh"
"#;
        let m = PluginManifest::parse(toml).unwrap();
        assert_eq!(m.plugin.description, "");
        assert_eq!(m.plugin.runtime, PluginRuntime::Subprocess);
        assert!(!m.capabilities.panels);
        assert!(!m.capabilities.commands);
        assert!(!m.capabilities.overlays);
        assert!(!m.capabilities.theme);
        assert!(m.panels.panel.is_empty());
        assert!(m.commands.command.is_empty());
    }

    #[test]
    fn runtime_native_variant() {
        let toml = r#"
[plugin]
name = "Native"
version = "1.0.0"
entry = "libplugin.so"
runtime = "native"
"#;
        let m = PluginManifest::parse(toml).unwrap();
        assert_eq!(m.plugin.runtime, PluginRuntime::Native);
    }

    #[test]
    fn runtime_wasm_variant() {
        let toml = r#"
[plugin]
name = "WasmPlugin"
version = "1.0.0"
entry = "plugin.wasm"
runtime = "wasm"
"#;
        let m = PluginManifest::parse(toml).unwrap();
        assert_eq!(m.plugin.runtime, PluginRuntime::Wasm);
    }

    #[test]
    fn runtime_transport_str() {
        assert_eq!(PluginRuntime::Native.as_transport_str(), "native");
        assert_eq!(PluginRuntime::Subprocess.as_transport_str(), "subprocess");
        assert_eq!(PluginRuntime::Wasm.as_transport_str(), "wasm");
    }

    #[test]
    fn multiple_panels_and_commands() {
        let toml = r#"
[plugin]
name = "Multi"
version = "1.0.0"
entry = "multi.py"

[capabilities]
panels = true
commands = true

[[panels.panel]]
name = "Panel A"
slot = "LeftSidebar"
priority = 1

[[panels.panel]]
name = "Panel B"
slot = "RightSidebar"
priority = 2

[[commands.command]]
name = "cmd_a"
description = "Command A"

[[commands.command]]
name = "cmd_b"
keybind = "Ctrl+B"
"#;
        let m = PluginManifest::parse(toml).unwrap();
        assert_eq!(m.panels.panel.len(), 2);
        assert_eq!(m.panels.panel[0].name, "Panel A");
        assert_eq!(m.panels.panel[1].priority, 2);
        assert_eq!(m.commands.command.len(), 2);
        assert_eq!(m.commands.command[0].description, "Command A");
        assert_eq!(m.commands.command[1].keybind.as_deref(), Some("Ctrl+B"));
        assert!(m.commands.command[0].keybind.is_none());
    }

    #[test]
    fn manifest_error_display() {
        let err = ManifestError::Io(
            std::path::PathBuf::from("/tmp/test.toml"),
            std::io::Error::new(std::io::ErrorKind::NotFound, "not found"),
        );
        let msg = format!("{err}");
        assert!(msg.contains("/tmp/test.toml"));
        assert!(msg.contains("not found"));
    }

    #[test]
    fn invalid_toml_returns_error() {
        let result = PluginManifest::parse("this is not valid toml {{{}}}");
        assert!(result.is_err());
    }

    #[test]
    fn missing_required_field() {
        // Missing entry field
        let toml = r#"
[plugin]
name = "NoEntry"
version = "1.0.0"
"#;
        let result = PluginManifest::parse(toml);
        assert!(result.is_err());
    }

    #[test]
    fn validate_id_valid() {
        assert!(validate_plugin_id("abc").is_ok());
        assert!(validate_plugin_id("pdk-switcher").is_ok());
        assert!(validate_plugin_id("my-plugin-123").is_ok());
        assert!(validate_plugin_id("a0b").is_ok());
        assert!(validate_plugin_id("x".repeat(64).as_str()).is_ok());
    }

    #[test]
    fn validate_id_too_short() {
        assert!(validate_plugin_id("ab").is_err());
        assert!(validate_plugin_id("a").is_err());
        assert!(validate_plugin_id("").is_err());
    }

    #[test]
    fn validate_id_too_long() {
        assert!(validate_plugin_id(&"x".repeat(65)).is_err());
    }

    #[test]
    fn validate_id_bad_chars() {
        assert!(validate_plugin_id("has_underscore").is_err());
        assert!(validate_plugin_id("HAS-CAPS").is_err());
        assert!(validate_plugin_id("has space").is_err());
        assert!(validate_plugin_id("has.dot").is_err());
    }

    #[test]
    fn validate_id_bad_edges() {
        assert!(validate_plugin_id("-leading").is_err());
        assert!(validate_plugin_id("trailing-").is_err());
        assert!(validate_plugin_id("-both-").is_err());
    }

    #[test]
    fn validate_manifest_with_valid_id() {
        let m = PluginManifest::parse(SAMPLE).unwrap();
        assert!(m.validate().is_ok());
    }

    #[test]
    fn validate_manifest_with_invalid_id() {
        let toml = r#"
[plugin]
id = "BAD_ID"
name = "Bad"
version = "1.0.0"
entry = "run.sh"
"#;
        let m = PluginManifest::parse(toml).unwrap();
        assert!(m.validate().is_err());
    }

    #[test]
    fn id_and_api_version_optional() {
        let toml = r#"
[plugin]
name = "NoId"
version = "1.0.0"
entry = "run.sh"
"#;
        let m = PluginManifest::parse(toml).unwrap();
        assert!(m.plugin.id.is_none());
        assert!(m.plugin.api_version.is_none());
        assert!(m.validate().is_ok());
    }
}
