use crate::manifest::ManifestCapabilities;
use std::path::Path;

/// Current host API version.
pub const API_VERSION: &str = "0.1.0";

/// What the host supports (sent during initialize).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct HostCapabilities {
    pub api_version: String,
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
            api_version: API_VERSION.to_owned(),
            panels: true,
            commands: true,
            overlays: true,
            theme: true,
            query_instances: true,
            query_nets: true,
        }
    }
}

/// The result of negotiating host and plugin capabilities.
/// Only capabilities supported by both sides are enabled.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct NegotiatedCapabilities {
    pub panels: bool,
    pub commands: bool,
    pub overlays: bool,
    pub theme: bool,
    pub query_instances: bool,
    pub query_nets: bool,
}

/// Negotiate capabilities between host and plugin.
/// The result is the intersection: only capabilities supported by both
/// the host and the plugin are enabled.
pub fn negotiate(host: &HostCapabilities, plugin: &ManifestCapabilities) -> NegotiatedCapabilities {
    NegotiatedCapabilities {
        panels: host.panels && plugin.panels,
        commands: host.commands && plugin.commands,
        overlays: host.overlays && plugin.overlays,
        theme: host.theme && plugin.theme,
        // Query capabilities are host-only; plugin always has access if host supports them
        query_instances: host.query_instances,
        query_nets: host.query_nets,
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
    fn negotiate_intersection() {
        let host = HostCapabilities {
            api_version: API_VERSION.to_owned(),
            panels: true,
            commands: true,
            overlays: false,
            theme: true,
            query_instances: true,
            query_nets: false,
        };
        let plugin = ManifestCapabilities {
            panels: true,
            commands: false,
            overlays: false,
            theme: true,
        };
        let neg = negotiate(&host, &plugin);
        assert!(neg.panels, "both support panels");
        assert!(!neg.commands, "plugin does not support commands");
        assert!(!neg.overlays, "neither supports overlays");
        assert!(neg.theme, "both support theme");
        assert!(neg.query_instances, "host supports query_instances");
        assert!(!neg.query_nets, "host does not support query_nets");
    }

    #[test]
    fn negotiate_all_enabled() {
        let host = HostCapabilities::default();
        let plugin = ManifestCapabilities {
            panels: true,
            commands: true,
            overlays: true,
            theme: true,
        };
        let neg = negotiate(&host, &plugin);
        assert!(neg.panels);
        assert!(neg.commands);
        assert!(neg.overlays);
        assert!(neg.theme);
        assert!(neg.query_instances);
        assert!(neg.query_nets);
    }

    #[test]
    fn negotiate_all_disabled_plugin() {
        let host = HostCapabilities::default();
        let plugin = ManifestCapabilities::default(); // all false
        let neg = negotiate(&host, &plugin);
        assert!(!neg.panels);
        assert!(!neg.commands);
        assert!(!neg.overlays);
        assert!(!neg.theme);
        // query caps are host-only
        assert!(neg.query_instances);
        assert!(neg.query_nets);
    }

    #[test]
    fn default_host_has_api_version() {
        let host = HostCapabilities::default();
        assert_eq!(host.api_version, API_VERSION);
    }
}
