//! plugin.toml manifests: schema, loading, id validation.

use std::path::{Path, PathBuf};

use serde::Deserialize;

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

/// Full plugin.toml manifest.
///
/// Unknown keys (legacy `[sandbox]`, `[events]`, `runtime`, `api_version`,
/// declarative `[panels]`/`[commands]` — panels and commands register at
/// runtime via RPC) are ignored by serde, so old manifests still parse.
#[derive(Debug, Clone, Deserialize)]
pub struct PluginManifest {
    pub plugin: ManifestPlugin,
    #[serde(default)]
    pub capabilities: ManifestCapabilities,
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
