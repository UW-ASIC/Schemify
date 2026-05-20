use std::collections::HashMap;

use serde::Deserialize;
use thiserror::Error;

/// Errors that can occur when loading or using symbol configs.
#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("unknown built-in PDK: {0}")]
    UnknownPdk(String),

    #[error("failed to read config file: {0}")]
    Io(#[from] std::io::Error),

    #[error("failed to parse config JSON: {0}")]
    Json(#[from] serde_json::Error),
}

/// Top-level symbol mapping configuration.
#[derive(Debug, Clone, Deserialize)]
pub struct SymbolConfig {
    pub base_path: String,
    pub fallback_path: String,
    pub device_map: HashMap<String, DeviceMapping>,
}

/// Mapping for a single device type (e.g. "nmos").
#[derive(Debug, Clone, Deserialize)]
pub struct DeviceMapping {
    pub default: String,
    #[serde(default)]
    pub generic: Option<String>,
    #[serde(default)]
    pub by_model: HashMap<String, String>,
}

impl SymbolConfig {
    /// Resolve a symbol path for a given primitive type and optional model name.
    ///
    /// Resolution order:
    /// 1. Look up `primitive` in `device_map`.
    /// 2. If `model` is Some, check `by_model` for an override.
    /// 3. Fall back to the mapping's `default`.
    /// 4. Prepend `base_path/` and append `.sym`.
    ///
    /// If the primitive is not found in the device map, returns
    /// `fallback_path/<primitive>.sym`.
    pub fn resolve(&self, primitive: &str, model: Option<&str>) -> String {
        match self.device_map.get(primitive) {
            Some(mapping) => {
                let symbol_name = if let Some(m) = model {
                    mapping
                        .by_model
                        .get(m)
                        .unwrap_or(&mapping.default)
                } else {
                    &mapping.default
                };
                format!("{}/{}.sym", self.base_path, symbol_name)
            }
            None => {
                format!("{}/{}.sym", self.fallback_path, primitive)
            }
        }
    }
}

/// Load a symbol config from a JSON file path.
pub fn load_config(path: &str) -> Result<SymbolConfig, ConfigError> {
    let contents = std::fs::read_to_string(path)?;
    let config: SymbolConfig = serde_json::from_str(&contents)?;
    Ok(config)
}

/// Load a built-in config by PDK name ("generic", "sky130", "ihp_sg13g2").
pub fn builtin_config(pdk: &str) -> Result<SymbolConfig, ConfigError> {
    let json = match pdk {
        "generic" => include_str!("data/generic.json"),
        "sky130" => include_str!("data/sky130.json"),
        "ihp_sg13g2" => include_str!("data/ihp_sg13g2.json"),
        other => return Err(ConfigError::UnknownPdk(other.to_string())),
    };
    let config: SymbolConfig = serde_json::from_str(json)?;
    Ok(config)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generic_resolves_nmos() {
        let config = builtin_config("generic").unwrap();
        assert_eq!(config.resolve("nmos", None), "devices/nmos4.sym");
    }

    #[test]
    fn sky130_resolves_nmos_with_model_nshort() {
        let config = builtin_config("sky130").unwrap();
        assert_eq!(
            config.resolve("nmos", Some("nshort")),
            "sky130_fd_pr/nfet_01v8.sym"
        );
    }

    #[test]
    fn sky130_resolves_nmos_default_no_model() {
        let config = builtin_config("sky130").unwrap();
        assert_eq!(
            config.resolve("nmos", None),
            "sky130_fd_pr/nfet_01v8.sym"
        );
    }

    #[test]
    fn ihp_resolves_nmos() {
        let config = builtin_config("ihp_sg13g2").unwrap();
        assert_eq!(
            config.resolve("nmos", None),
            "sg13g2_pr/sg13_lv_nmos.sym"
        );
    }

    #[test]
    fn unknown_primitive_falls_back_to_fallback_path() {
        let config = builtin_config("generic").unwrap();
        assert_eq!(
            config.resolve("mystery_device", None),
            "devices/mystery_device.sym"
        );
    }

    #[test]
    fn by_model_override_takes_precedence() {
        let config = builtin_config("sky130").unwrap();
        // "nlowvt" model should resolve to the lvt variant, not the default
        assert_eq!(
            config.resolve("nmos", Some("nlowvt")),
            "sky130_fd_pr/nfet_01v8_lvt.sym"
        );
        // An unknown model should fall back to the default
        assert_eq!(
            config.resolve("nmos", Some("nonexistent_model")),
            "sky130_fd_pr/nfet_01v8.sym"
        );
    }

    #[test]
    fn builtin_config_generic_works() {
        let config = builtin_config("generic");
        assert!(config.is_ok());
        let config = config.unwrap();
        assert_eq!(config.base_path, "devices");
        assert_eq!(config.device_map.len(), 10);
    }

    #[test]
    fn builtin_config_unknown_pdk_returns_error() {
        let result = builtin_config("unknown_pdk");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(
            matches!(err, ConfigError::UnknownPdk(_)),
            "expected UnknownPdk error, got: {err}"
        );
    }

    #[test]
    fn resolve_appends_sym_extension() {
        let config = builtin_config("generic").unwrap();
        let resolved = config.resolve("nmos", None);
        assert!(
            resolved.ends_with(".sym"),
            "resolved path should end with .sym, got: {resolved}"
        );
    }
}
