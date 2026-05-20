use crate::manifest::ManifestCapabilities;
use std::path::Path;

/// Runtime capability flags (what a plugin is allowed to do).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Capability {
    pub panels: bool,
    pub commands: bool,
    pub overlays: bool,
    pub theme: bool,
    pub file_read_project: bool,
    pub file_write_plugin_data: bool,
    pub schematic_mutate: bool,
}

/// What the host supports (sent during initialize).
#[derive(Debug, Clone, serde::Serialize)]
pub struct HostCapabilities {
    pub panels: bool,
    pub commands: bool,
    pub overlays: bool,
    pub theme: bool,
    pub query_instances: bool,
    pub query_nets: bool,
}

impl Default for HostCapabilities {
    fn default() -> Self {
        Self {
            panels: true,
            commands: true,
            overlays: true,
            theme: true,
            query_instances: true,
            query_nets: true,
        }
    }
}

impl Capability {
    /// Build capabilities from manifest declarations.
    pub fn from_manifest(caps: &ManifestCapabilities) -> Self {
        Self {
            panels: caps.panels,
            commands: caps.commands,
            overlays: caps.overlays,
            theme: caps.theme,
            ..Default::default()
        }
    }

    /// Merge two capability sets (union).
    pub fn merge(self, other: Self) -> Self {
        Self {
            panels: self.panels || other.panels,
            commands: self.commands || other.commands,
            overlays: self.overlays || other.overlays,
            theme: self.theme || other.theme,
            file_read_project: self.file_read_project || other.file_read_project,
            file_write_plugin_data: self.file_write_plugin_data || other.file_write_plugin_data,
            schematic_mutate: self.schematic_mutate || other.schematic_mutate,
        }
    }
}

/// Check if `path` is under `allowed_dir`.
pub fn is_path_under(path: &Path, allowed_dir: &Path) -> bool {
    match (path.canonicalize(), allowed_dir.canonicalize()) {
        (Ok(p), Ok(d)) => p.starts_with(&d),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_manifest_caps() {
        let mc = ManifestCapabilities {
            panels: true,
            commands: false,
            overlays: true,
            theme: false,
        };
        let cap = Capability::from_manifest(&mc);
        assert!(cap.panels);
        assert!(!cap.commands);
        assert!(cap.overlays);
        assert!(!cap.theme);
    }

    #[test]
    fn merge_union() {
        let a = Capability {
            panels: true,
            ..Default::default()
        };
        let b = Capability {
            commands: true,
            theme: true,
            ..Default::default()
        };
        let merged = a.merge(b);
        assert!(merged.panels);
        assert!(merged.commands);
        assert!(merged.theme);
        assert!(!merged.overlays);
    }
}
