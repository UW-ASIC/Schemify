use std::path::PathBuf;

/// Global plugin install directory (platform-native via dirs crate).
pub fn global_plugins_dir() -> PathBuf {
    let base = dirs::data_dir().unwrap_or_else(|| PathBuf::from(".local/share"));
    base.join("schemify").join("plugins")
}

/// Cache directory for registry.db, downloads, temp files.
pub fn cache_dir() -> PathBuf {
    let base = dirs::cache_dir().unwrap_or_else(|| PathBuf::from(".cache"));
    base.join("schemify").join("cache")
}

/// Config directory for lock file, settings.
pub fn config_dir() -> PathBuf {
    let base = dirs::config_dir().unwrap_or_else(|| PathBuf::from(".config"));
    base.join("schemify")
}

/// Path to the plugin lock file.
pub fn lock_file_path() -> PathBuf {
    config_dir().join("plugin-lock.toml")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_end_with_schemify() {
        let gp = global_plugins_dir();
        assert!(gp.ends_with("schemify/plugins"));

        let cd = cache_dir();
        assert!(cd.ends_with("schemify/cache"));

        let cfg = config_dir();
        assert!(cfg.ends_with("schemify"));
    }

    #[test]
    fn lock_file_under_config() {
        let lf = lock_file_path();
        assert!(lf.ends_with("schemify/plugin-lock.toml"));
    }
}
