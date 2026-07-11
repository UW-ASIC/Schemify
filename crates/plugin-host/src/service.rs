//! [`PluginService`]: single owner of the plugin runtime + marketplace.
//!
//! Constructed once at the composition root (`src/main.rs`) and shared by
//! every frontend, so gui and mcp never race two `PluginManager`s over the
//! same plugin processes.

use std::path::PathBuf;

use crate::manager::PluginManager;
use crate::marketplace::Marketplace;

/// One `PluginManager` + one `Marketplace`, wired to the same plugins dir.
///
/// Fields are public: both members already expose deliberate APIs, and
/// wrapping every call in a delegating method would only add indirection.
/// The service exists to unify *ownership*, not to re-abstract behavior.
pub struct PluginService {
    pub manager: PluginManager,
    pub marketplace: Marketplace,
}

impl PluginService {
    /// `plugins_dir`: where installed plugins live (scanned + install target).
    /// `cache_dir`: registry cache + download scratch.
    pub fn new(plugins_dir: PathBuf, cache_dir: PathBuf) -> Self {
        let marketplace = Marketplace::new(plugins_dir.clone(), cache_dir);
        let mut manager = PluginManager::new();
        manager.add_scan_dir(plugins_dir);
        Self { manager, marketplace }
    }
}
