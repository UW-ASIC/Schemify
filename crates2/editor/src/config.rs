//! Project configuration, PDK manifests, and global directories.
//!
//! Three concerns, one file:
//!   1. `Config.toml` in the project root (project name, active PDK, file paths)
//!   2. `schemify-pdk.toml` PDK manifests (device cell mappings, model corners)
//!   3. Platform-native global directories (plugins, cache, config)
//!
//! The config layer is deliberately stringly typed: device keys in a PDK
//! manifest are primitive names ("nmos4", "res", ...) and stay strings here.
//! Resolution to `DeviceKind` happens at the use site (parse, don't validate).

use std::path::{Path, PathBuf};

use serde::Deserialize;

// ====================================================
// Project configuration (Config.toml)
// ====================================================

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct ProjectConfig {
    pub name: String,
    /// Active PDK name. `[pdk_switcher] active` overrides this when set.
    pub pdk: Option<String>,
    /// Explicit PDK root directory; overrides `$PDK_ROOT/<pdk>` discovery.
    pub pdk_path: Option<PathBuf>,
    pub paths: ProjectPaths,
    pub simulation: SimulationOptions,
    #[serde(rename = "pdk_switcher")]
    pdk_switcher: PdkSwitcher,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct ProjectPaths {
    /// Schematic files / globs (`*.chn`).
    #[serde(rename = "chn")]
    pub schematics: Vec<PathBuf>,
    /// Primitive files / globs (`*.chn_prim`).
    #[serde(rename = "chn_prim")]
    pub primitives: Vec<PathBuf>,
    /// Testbench files / globs (`*.chn_tb`).
    #[serde(rename = "chn_tb")]
    pub testbenches: Vec<PathBuf>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct SimulationOptions {
    pub spice_include_paths: Vec<PathBuf>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
struct PdkSwitcher {
    active: Option<String>,
    /// Explicit root of the active PDK (e.g. `~/.ciel/sky130A`); needed
    /// when `$PDK_ROOT` is unset. Wins over the top-level `pdk_path`.
    path: Option<PathBuf>,
}

#[derive(thiserror::Error, Debug)]
pub enum ConfigError {
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error("Config.toml parse error: {0}")]
    Parse(#[from] toml::de::Error),
}

impl ProjectConfig {
    /// Parse a Config.toml string. `[pdk_switcher] active` wins over `pdk`.
    pub fn parse(content: &str) -> Result<Self, toml::de::Error> {
        let mut config: ProjectConfig = toml::from_str(content)?;
        if let Some(active) = config.pdk_switcher.active.take() {
            config.pdk = Some(active);
        }
        if let Some(path) = config.pdk_switcher.path.take() {
            config.pdk_path = Some(path);
        }
        Ok(config)
    }

    /// Load `<project_dir>/Config.toml` and expand path globs.
    /// A missing file yields the default config (a project is not required
    /// to have one); a malformed file is an error.
    pub fn load(project_dir: &Path) -> Result<Self, ConfigError> {
        let path = project_dir.join("Config.toml");
        match std::fs::read_to_string(&path) {
            Ok(content) => {
                let mut config = Self::parse(&content)?;
                config.expand_path_globs(project_dir);
                Ok(config)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(e) => Err(e.into()),
        }
    }

    /// Resolve `*` globs in `[paths]` entries against the project dir.
    /// Plain relative entries become project-dir-relative paths.
    fn expand_path_globs(&mut self, project_dir: &Path) {
        self.paths.schematics = expand_globs(project_dir, &self.paths.schematics, ".chn");
        self.paths.testbenches = expand_globs(project_dir, &self.paths.testbenches, ".chn_tb");
        self.paths.primitives = expand_globs(project_dir, &self.paths.primitives, ".chn_prim");
    }
}

fn expand_globs(project_dir: &Path, raw: &[PathBuf], ext: &str) -> Vec<PathBuf> {
    let mut result = Vec::new();
    for p in raw {
        let p_str = p.to_string_lossy();
        if let Some(star) = p_str.find('*') {
            // Walk the directory before the wildcard, recursively.
            let dir_part = p_str[..star].trim_end_matches('/');
            let abs_dir = if dir_part.is_empty() {
                project_dir.to_path_buf()
            } else if Path::new(dir_part).is_absolute() {
                PathBuf::from(dir_part)
            } else {
                project_dir.join(dir_part)
            };
            walk_dir(&abs_dir, dir_part, ext, &mut result);
        } else if p.is_absolute() {
            result.push(p.clone());
        } else {
            result.push(project_dir.join(p));
        }
    }
    result
}

fn walk_dir(abs_dir: &Path, rel_prefix: &str, ext: &str, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(abs_dir) else {
        return;
    };
    for entry in entries.flatten() {
        let Ok(ft) = entry.file_type() else { continue };
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        let rel = if rel_prefix.is_empty() {
            name_str.to_string()
        } else {
            format!("{rel_prefix}/{name_str}")
        };
        if ft.is_dir() {
            walk_dir(&abs_dir.join(&*name_str), &rel, ext, out);
        } else if matches_ext(&name_str, ext) {
            out.push(PathBuf::from(rel));
        }
    }
}

fn matches_ext(name: &str, ext: &str) -> bool {
    if !name.ends_with(ext) {
        return false;
    }
    // .chn globs must NOT match .chn_tb or .chn_prim
    if ext == ".chn" {
        return !name.ends_with(".chn_tb") && !name.ends_with(".chn_prim");
    }
    true
}

// PDK manifest handling moved to `schemify-sim`; old `config::` paths
// keep working through this re-export.
pub use schemify_sim::pdk::*;

// ====================================================
// Global directories (platform-native via dirs crate)
// ====================================================

/// Global plugin install directory.
pub fn global_plugins_dir() -> PathBuf {
    let base = dirs::data_dir().unwrap_or_else(|| PathBuf::from(".local/share"));
    base.join("schemify").join("plugins")
}

/// Cache directory for registry.db, downloads, temp files.
pub fn cache_dir() -> PathBuf {
    let base = dirs::cache_dir().unwrap_or_else(|| PathBuf::from(".cache"));
    base.join("schemify").join("cache")
}

/// Config directory for settings.
pub fn config_dir() -> PathBuf {
    let base = dirs::config_dir().unwrap_or_else(|| PathBuf::from(".config"));
    base.join("schemify")
}

// ====================================================
// Tests
// ====================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_full_config() {
        let src = r#"
name = "myproj"
pdk = "sky130A"
pdk_path = "/opt/pdks/sky130A"

[paths]
chn = ["src/*.chn", "lib/opamp.chn"]
chn_tb = ["tb/*.chn_tb"]
chn_prim = []

[simulation]
spice_include_paths = ["models/extra.spice"]

[plugins]
something = "ignored"
"#;
        let c = ProjectConfig::parse(src).expect("config parses");
        assert_eq!(c.name, "myproj");
        assert_eq!(c.pdk.as_deref(), Some("sky130A"));
        assert_eq!(c.pdk_path.as_deref(), Some(Path::new("/opt/pdks/sky130A")));
        assert_eq!(c.paths.schematics.len(), 2);
        assert_eq!(c.paths.testbenches, [PathBuf::from("tb/*.chn_tb")]);
        assert!(c.paths.primitives.is_empty());
        assert_eq!(
            c.simulation.spice_include_paths,
            [PathBuf::from("models/extra.spice")]
        );
    }

    #[test]
    fn pdk_switcher_active_wins() {
        let src = r#"
pdk = "sky130A"

[pdk_switcher]
active = "gf180mcuD"
"#;
        let c = ProjectConfig::parse(src).expect("config parses");
        assert_eq!(c.pdk.as_deref(), Some("gf180mcuD"));
    }

    #[test]
    fn empty_config_is_default() {
        let c = ProjectConfig::parse("").expect("empty parses");
        assert!(c.name.is_empty());
        assert!(c.pdk.is_none());
    }

    #[test]
    fn chn_glob_does_not_match_tb_or_prim() {
        assert!(matches_ext("inv.chn", ".chn"));
        assert!(!matches_ext("inv.chn_tb", ".chn"));
        assert!(!matches_ext("inv.chn_prim", ".chn"));
        assert!(matches_ext("inv.chn_tb", ".chn_tb"));
    }

    #[test]
    fn global_dirs_end_with_schemify() {
        assert!(global_plugins_dir().ends_with("schemify/plugins"));
        assert!(cache_dir().ends_with("schemify/cache"));
        assert!(config_dir().ends_with("schemify"));
    }
}
