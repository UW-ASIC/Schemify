//! Schemify plugin marketplace: registry fetching, tarball installation,
//! checksum verification, and installed-plugin tracking.
//!
//! The marketplace is a distribution layer on top of `schemify-plugins`.
//! It does not own plugin lifecycle or IPC — those belong to `PluginManager`.
//! After installing a plugin, the caller re-scans the plugins directory via
//! `PluginManager::discover` to pick up the new plugin.

mod install;
pub mod platform;
mod registry;

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub use registry::Registry;

const DEFAULT_REGISTRY_URL: &str =
    "https://raw.githubusercontent.com/UW-ASIC/Schemify/master/registry/index.json";

const INSTALLED_DB_FILE: &str = "installed.json";

// ═══════════════════════════════════════════════════════════════════════════
// Wire types (deserialized from registry index.json)
// ═══════════════════════════════════════════════════════════════════════════

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadEntry {
    pub url: String,
    pub sha256: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegistryEntry {
    pub id: String,
    pub name: String,
    pub version: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub license: String,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(default)]
    pub min_schemify_version: Option<String>,
    #[serde(default)]
    pub homepage: Option<String>,
    #[serde(default)]
    pub downloads: HashMap<String, DownloadEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegistryIndex {
    pub schema_version: u32,
    pub updated_at: String,
    pub plugins: Vec<RegistryEntry>,
}

// ═══════════════════════════════════════════════════════════════════════════
// Installed plugin tracking
// ═══════════════════════════════════════════════════════════════════════════

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstalledPlugin {
    pub id: String,
    pub name: String,
    pub version: String,
    pub tarball_sha256: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct InstalledDb {
    pub plugins: Vec<InstalledPlugin>,
}

impl InstalledDb {
    fn load(path: &Path) -> Self {
        std::fs::read_to_string(path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    }

    fn save(&self, path: &Path) -> Result<(), MarketplaceError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_string_pretty(self)
            .map_err(|e| MarketplaceError::RegistryParse(e.to_string()))?;
        std::fs::write(path, json)?;
        Ok(())
    }

    fn find(&self, id: &str) -> Option<&InstalledPlugin> {
        self.plugins.iter().find(|p| p.id == id)
    }

    fn remove(&mut self, id: &str) {
        self.plugins.retain(|p| p.id != id);
    }

    fn upsert(&mut self, record: InstalledPlugin) {
        self.remove(&record.id);
        self.plugins.push(record);
    }

    fn ids(&self) -> Vec<String> {
        self.plugins.iter().map(|p| p.id.clone()).collect()
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Search result
// ═══════════════════════════════════════════════════════════════════════════

#[derive(Debug, Clone)]
pub struct SearchResult {
    pub entry: RegistryEntry,
    pub installed: bool,
}

// ═══════════════════════════════════════════════════════════════════════════
// Update check
// ═══════════════════════════════════════════════════════════════════════════

#[derive(Debug, Clone)]
pub struct UpdateAvailable {
    pub id: String,
    pub installed_version: String,
    pub latest_version: String,
}

// ═══════════════════════════════════════════════════════════════════════════
// Errors
// ═══════════════════════════════════════════════════════════════════════════

#[derive(Debug, thiserror::Error)]
pub enum MarketplaceError {
    #[error("network error: {0}")]
    Network(String),
    #[error("registry parse error: {0}")]
    RegistryParse(String),
    #[error("plugin '{0}' not found in registry")]
    NotFound(String),
    #[error("no binary available for platform '{0}'")]
    NoPlatformBinary(String),
    #[error("checksum mismatch: expected {expected}, got {actual}")]
    ChecksumMismatch { expected: String, actual: String },
    #[error("extraction error: {0}")]
    Extract(String),
    #[error("invalid plugin: {0}")]
    InvalidPlugin(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("plugin '{0}' is not installed")]
    NotInstalled(String),
    #[error("manifest error: {0}")]
    Manifest(#[from] crate::manifest::ManifestError),
}

// ═══════════════════════════════════════════════════════════════════════════
// Marketplace
// ═══════════════════════════════════════════════════════════════════════════

pub struct Marketplace {
    registry: Registry,
    installed: InstalledDb,
    target_triple: String,
    plugins_dir: PathBuf,
    cache_dir: PathBuf,
}

impl Marketplace {
    pub fn new(plugins_dir: PathBuf, cache_dir: PathBuf) -> Self {
        let db_path = plugins_dir.join(INSTALLED_DB_FILE);
        let installed = InstalledDb::load(&db_path);
        let registry = Registry::new(DEFAULT_REGISTRY_URL.to_owned(), cache_dir.clone());

        Self {
            registry,
            installed,
            target_triple: platform::detect_target_triple(),
            plugins_dir,
            cache_dir,
        }
    }

    pub fn with_registry_url(mut self, url: String) -> Self {
        self.registry = Registry::new(url, self.cache_dir.clone());
        self
    }

    pub fn target_triple(&self) -> &str {
        &self.target_triple
    }

    // ── Registry ──────────────────────────────────────────────────────────

    pub fn fetch_index(&mut self) -> Result<&RegistryIndex, MarketplaceError> {
        self.registry.fetch()
    }

    pub fn search(&self, query: &str) -> Vec<SearchResult> {
        self.registry.search(query, &self.installed.ids())
    }

    // ── Install ───────────────────────────────────────────────────────────

    pub fn install(&mut self, id: &str) -> Result<(), MarketplaceError> {
        let entry = self
            .registry
            .find_entry(id)
            .ok_or_else(|| MarketplaceError::NotFound(id.to_owned()))?
            .clone();

        let download = entry
            .downloads
            .get(&self.target_triple)
            .ok_or_else(|| MarketplaceError::NoPlatformBinary(self.target_triple.clone()))?
            .clone();

        let tarball = install::download_and_verify(
            &download,
            &self.cache_dir,
            id,
            &entry.version,
            &self.target_triple,
        )?;

        let extract_dir = install::extract_tarball(&tarball, &self.cache_dir)?;
        let plugin_root = install::find_plugin_root(&extract_dir)?;
        install::validate_extracted(&plugin_root, Some(id))?;
        install::place_plugin(&plugin_root, &self.plugins_dir, id)?;

        let record = install::make_installed_record(
            id,
            &entry.name,
            &entry.version,
            &download.sha256,
        );
        self.installed.upsert(record);
        self.save_db()?;

        if extract_dir.exists() {
            let _ = std::fs::remove_dir_all(&extract_dir);
        }

        Ok(())
    }

    pub fn install_from_file(&mut self, path: &Path) -> Result<String, MarketplaceError> {
        let extract_dir = install::extract_tarball(path, &self.cache_dir)?;
        let plugin_root = install::find_plugin_root(&extract_dir)?;
        let id = install::validate_extracted(&plugin_root, None)?;
        install::place_plugin(&plugin_root, &self.plugins_dir, &id)?;

        let sha256 = install::sha256_file(path)?;
        let manifest = crate::manifest::PluginManifest::load(&self.plugins_dir.join(&id).join("plugin.toml"))?;
        let record = install::make_installed_record(
            &id,
            &manifest.plugin.name,
            &manifest.plugin.version,
            &sha256,
        );
        self.installed.upsert(record);
        self.save_db()?;

        if extract_dir.exists() {
            let _ = std::fs::remove_dir_all(&extract_dir);
        }

        Ok(id)
    }

    // ── Uninstall ─────────────────────────────────────────────────────────

    pub fn uninstall(&mut self, id: &str) -> Result<(), MarketplaceError> {
        if self.installed.find(id).is_none() {
            return Err(MarketplaceError::NotInstalled(id.to_owned()));
        }
        install::remove_plugin(&self.plugins_dir, id)?;
        self.installed.remove(id);
        self.save_db()?;
        Ok(())
    }

    // ── Updates ───────────────────────────────────────────────────────────

    pub fn check_updates(&self) -> Vec<UpdateAvailable> {
        let mut updates = Vec::new();
        for installed in &self.installed.plugins {
            let Some(entry) = self.registry.find_entry(&installed.id) else {
                continue;
            };
            let Ok(installed_ver) = semver::Version::parse(&installed.version) else {
                continue;
            };
            let Ok(latest_ver) = semver::Version::parse(&entry.version) else {
                continue;
            };
            if latest_ver > installed_ver {
                updates.push(UpdateAvailable {
                    id: installed.id.clone(),
                    installed_version: installed.version.clone(),
                    latest_version: entry.version.clone(),
                });
            }
        }
        updates
    }

    // ── Queries ───────────────────────────────────────────────────────────

    pub fn installed(&self) -> &InstalledDb {
        &self.installed
    }

    pub fn is_installed(&self, id: &str) -> bool {
        self.installed.find(id).is_some()
    }

    // ── Persistence ───────────────────────────────────────────────────────

    fn save_db(&self) -> Result<(), MarketplaceError> {
        self.installed.save(&self.plugins_dir.join(INSTALLED_DB_FILE))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn tmp_dirs(tag: &str) -> (PathBuf, PathBuf) {
        let base = std::env::temp_dir().join(format!(
            "schemify-mkt-{}-{tag}",
            std::process::id()
        ));
        let plugins = base.join("plugins");
        let cache = base.join("cache");
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(&plugins).unwrap();
        fs::create_dir_all(&cache).unwrap();
        (plugins, cache)
    }

    #[test]
    fn installed_db_round_trip() {
        let (plugins, _cache) = tmp_dirs("db");
        let db_path = plugins.join(INSTALLED_DB_FILE);

        let mut db = InstalledDb::default();
        db.upsert(InstalledPlugin {
            id: "test-plugin".into(),
            name: "Test".into(),
            version: "1.0.0".into(),
            tarball_sha256: "abc".into(),
        });
        db.save(&db_path).unwrap();

        let loaded = InstalledDb::load(&db_path);
        assert_eq!(loaded.plugins.len(), 1);
        assert_eq!(loaded.plugins[0].id, "test-plugin");

        let _ = fs::remove_dir_all(plugins.parent().unwrap());
    }

    #[test]
    fn upsert_replaces() {
        let mut db = InstalledDb::default();
        db.upsert(InstalledPlugin {
            id: "foo".into(),
            name: "Foo".into(),
            version: "1.0.0".into(),
            tarball_sha256: "aaa".into(),
        });
        db.upsert(InstalledPlugin {
            id: "foo".into(),
            name: "Foo".into(),
            version: "2.0.0".into(),
            tarball_sha256: "bbb".into(),
        });
        assert_eq!(db.plugins.len(), 1);
        assert_eq!(db.plugins[0].version, "2.0.0");
    }

    #[test]
    fn not_installed_error() {
        let (plugins, cache) = tmp_dirs("uninstall");
        let mut mkt = Marketplace::new(plugins.clone(), cache);
        let err = mkt.uninstall("nonexistent").unwrap_err();
        assert!(matches!(err, MarketplaceError::NotInstalled(_)));
        let _ = fs::remove_dir_all(plugins.parent().unwrap());
    }
}
