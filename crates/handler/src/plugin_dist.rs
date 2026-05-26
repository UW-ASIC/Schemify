use std::collections::HashSet;
use std::path::PathBuf;

use schemify_io::lock::{LockEntry, LockFile};
use schemify_io::paths;

// ====================================================
// Action Types (handler produces, caller executes)
// ====================================================

#[derive(Debug, Clone)]
pub enum PluginAction {
    /// Download registry.db from URL.
    FetchRegistryDb { url: String, dest: PathBuf },
    /// Download plugin tarball from URL.
    DownloadTarball {
        url: String,
        dest: PathBuf,
        expected_sha: String,
    },
    /// Verify cosign signature on tarball.
    VerifyCosign {
        tarball_path: PathBuf,
        identity: String,
    },
    /// Extract tarball to directory.
    Extract { tarball_path: PathBuf, dest: PathBuf },
    /// Validate plugin.toml in extracted directory.
    ValidateManifest { plugin_dir: PathBuf },
    /// Move directory from temp to final location.
    MoveDir { from: PathBuf, to: PathBuf },
    /// Add or update entry in lock file.
    UpdateLock { entry: LockEntry },
    /// Remove entry from lock file by id.
    RemoveLockEntry { id: String },
    /// Remove directory from disk.
    RemoveDir { path: PathBuf },
    /// Remove plugin data blob from app state.
    RemovePluginData { id: String },
    /// Send lifecycle event to running plugin.
    SendLifecycle { plugin_id: String, event: String },
    /// Display message to user.
    Notify { message: String },
}

#[derive(Debug, Clone)]
pub enum ActionResult {
    Success {
        action_idx: usize,
        data: Option<Vec<u8>>,
    },
    Failed {
        action_idx: usize,
        error: String,
    },
}

// ====================================================
// Install Types
// ====================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallTarget {
    Global,
    Project,
}

#[derive(Debug, Clone)]
pub struct ParsedSource {
    pub owner: String,
    pub repo: String,
    pub version: Option<String>,
}

// ====================================================
// Installed Plugin Info
// ====================================================

#[derive(Debug, Clone)]
pub struct InstalledPlugin {
    pub id: String,
    pub version: String,
    pub source: String,
    pub location: String,
}

// ====================================================
// Uninstall Plan (preview before confirm)
// ====================================================

#[derive(Debug, Clone)]
pub struct UninstallPlan {
    pub id: String,
    pub version: String,
    pub plugin_dir: PathBuf,
    pub has_data: bool,
}

// ====================================================
// Source Parsing
// ====================================================

pub fn parse_source(source: &str) -> Result<ParsedSource, String> {
    let rest = source
        .strip_prefix("github:")
        .ok_or_else(|| format!("unsupported source: {source} (expected github:owner/repo)"))?;

    let (path, version) = if let Some(at) = rest.find('@') {
        (&rest[..at], Some(rest[at + 1..].to_string()))
    } else {
        (rest, None)
    };

    let parts: Vec<&str> = path.split('/').collect();
    if parts.len() != 2 || parts[0].is_empty() || parts[1].is_empty() {
        return Err(format!(
            "invalid github source: expected github:owner/repo, got {source}"
        ));
    }

    Ok(ParsedSource {
        owner: parts[0].to_string(),
        repo: parts[1].to_string(),
        version,
    })
}

// ====================================================
// Install Actions
// ====================================================

pub fn install_actions(
    source: &str,
    version: Option<&str>,
    target: InstallTarget,
    project_dir: Option<&std::path::Path>,
) -> Result<Vec<PluginAction>, String> {
    let parsed = parse_source(source)?;

    let version = version
        .map(|v| v.to_string())
        .or(parsed.version.clone())
        .ok_or("version required (use source@version or specify --version)")?;

    let id = &parsed.repo;
    let tarball_name = format!("schemify-plugin-{id}-{version}.tar.gz");
    let download_url = format!(
        "https://github.com/{}/{}/releases/download/v{}/{}",
        parsed.owner, parsed.repo, version, tarball_name
    );

    let cache = paths::cache_dir();
    let tarball_path = cache.join("downloads").join(&tarball_name);
    let temp_dir = cache.join("tmp").join(format!("{id}-{version}"));

    let dest = match target {
        InstallTarget::Global => paths::global_plugins_dir().join(id),
        InstallTarget::Project => {
            let pd = project_dir.ok_or("--project requires a project directory")?;
            pd.join("plugins").join(id)
        }
    };

    let location = match target {
        InstallTarget::Global => "global",
        InstallTarget::Project => "project",
    };

    Ok(vec![
        PluginAction::Notify {
            message: format!("Installing {id}@{version} from {source}"),
        },
        PluginAction::DownloadTarball {
            url: download_url,
            dest: tarball_path.clone(),
            expected_sha: String::new(),
        },
        PluginAction::Extract {
            tarball_path,
            dest: temp_dir.clone(),
        },
        PluginAction::ValidateManifest {
            plugin_dir: temp_dir.clone(),
        },
        PluginAction::MoveDir {
            from: temp_dir,
            to: dest,
        },
        PluginAction::UpdateLock {
            entry: LockEntry {
                id: id.to_string(),
                version: version.clone(),
                source: source.to_string(),
                sha256: String::new(),
                location: location.to_string(),
            },
        },
        PluginAction::Notify {
            message: format!("Installed {id}@{version}"),
        },
    ])
}

// ====================================================
// Uninstall
// ====================================================

pub fn uninstall_preview(
    id: &str,
    lock: &LockFile,
    has_data: bool,
    project_dir: Option<&std::path::Path>,
) -> Result<UninstallPlan, String> {
    let entry = lock
        .installed
        .iter()
        .find(|e| e.id == id)
        .ok_or_else(|| format!("plugin '{id}' not found in lock file"))?;

    let plugin_dir = match entry.location.as_str() {
        "project" => {
            let pd = project_dir.ok_or("project plugin but no project directory set")?;
            pd.join("plugins").join(id)
        }
        _ => paths::global_plugins_dir().join(id),
    };

    Ok(UninstallPlan {
        id: id.to_string(),
        version: entry.version.clone(),
        plugin_dir,
        has_data,
    })
}

pub fn uninstall_actions(
    id: &str,
    lock: &LockFile,
    keep_data: bool,
    project_dir: Option<&std::path::Path>,
) -> Result<Vec<PluginAction>, String> {
    let preview = uninstall_preview(id, lock, false, project_dir)?;

    let mut actions = vec![
        PluginAction::SendLifecycle {
            plugin_id: id.to_string(),
            event: "shutdown".to_string(),
        },
        PluginAction::RemoveDir {
            path: preview.plugin_dir,
        },
        PluginAction::RemoveLockEntry {
            id: id.to_string(),
        },
    ];

    if !keep_data {
        actions.push(PluginAction::RemovePluginData {
            id: id.to_string(),
        });
    }

    actions.push(PluginAction::Notify {
        message: format!("Uninstalled {}@{}", id, preview.version),
    });

    Ok(actions)
}

// ====================================================
// List Installed
// ====================================================

pub fn list_installed(lock: &LockFile) -> Vec<InstalledPlugin> {
    lock.installed
        .iter()
        .map(|e| InstalledPlugin {
            id: e.id.clone(),
            version: e.version.clone(),
            source: e.source.clone(),
            location: e.location.clone(),
        })
        .collect()
}

// ====================================================
// Scan + Precedence (project-local wins on collision)
// ====================================================

pub fn merge_installed(
    lock_entries: &[InstalledPlugin],
    scanned: &[InstalledPlugin],
) -> Vec<InstalledPlugin> {
    let mut result: Vec<InstalledPlugin> = Vec::new();
    let mut seen = HashSet::new();

    // Project-local first (highest precedence)
    for p in lock_entries.iter().chain(scanned.iter()) {
        if p.location == "project" && seen.insert(p.id.clone()) {
            result.push(p.clone());
        }
    }

    // Then global
    for p in lock_entries.iter().chain(scanned.iter()) {
        if p.location == "global" && seen.insert(p.id.clone()) {
            result.push(p.clone());
        }
    }

    result
}

// ====================================================
// Tests
// ====================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_github_source_with_version() {
        let parsed = parse_source("github:user/repo@1.2.0").unwrap();
        assert_eq!(parsed.owner, "user");
        assert_eq!(parsed.repo, "repo");
        assert_eq!(parsed.version.as_deref(), Some("1.2.0"));
    }

    #[test]
    fn parse_github_source_no_version() {
        let parsed = parse_source("github:user/repo").unwrap();
        assert_eq!(parsed.owner, "user");
        assert_eq!(parsed.repo, "repo");
        assert!(parsed.version.is_none());
    }

    #[test]
    fn parse_source_invalid_prefix() {
        assert!(parse_source("npm:user/repo").is_err());
    }

    #[test]
    fn parse_source_invalid_path() {
        assert!(parse_source("github:noslash").is_err());
        assert!(parse_source("github:user/").is_err());
        assert!(parse_source("github:/repo").is_err());
    }

    #[test]
    fn install_actions_with_inline_version() {
        let actions = install_actions(
            "github:user/my-plugin@1.0.0",
            None,
            InstallTarget::Global,
            None,
        )
        .unwrap();

        assert!(actions.len() >= 5);
        assert!(matches!(&actions[0], PluginAction::Notify { .. }));
        assert!(matches!(
            &actions[1],
            PluginAction::DownloadTarball { .. }
        ));
        assert!(matches!(&actions[2], PluginAction::Extract { .. }));
        assert!(matches!(
            &actions[3],
            PluginAction::ValidateManifest { .. }
        ));
        assert!(matches!(&actions[4], PluginAction::MoveDir { .. }));
        assert!(matches!(&actions[5], PluginAction::UpdateLock { .. }));
    }

    #[test]
    fn install_actions_version_from_arg() {
        let actions = install_actions(
            "github:user/repo",
            Some("2.0.0"),
            InstallTarget::Global,
            None,
        );
        assert!(actions.is_ok());
    }

    #[test]
    fn install_actions_version_required() {
        let result = install_actions("github:user/repo", None, InstallTarget::Global, None);
        assert!(result.is_err());
    }

    #[test]
    fn install_actions_project_requires_dir() {
        let result = install_actions(
            "github:user/repo@1.0.0",
            None,
            InstallTarget::Project,
            None,
        );
        assert!(result.is_err());
    }

    #[test]
    fn install_actions_project_with_dir() {
        let result = install_actions(
            "github:user/repo@1.0.0",
            None,
            InstallTarget::Project,
            Some(std::path::Path::new("/tmp/myproject")),
        );
        assert!(result.is_ok());
        let actions = result.unwrap();
        // MoveDir target should be under project dir
        if let PluginAction::MoveDir { to, .. } = &actions[4] {
            assert!(to.starts_with("/tmp/myproject/plugins"));
        } else {
            panic!("expected MoveDir at index 4");
        }
    }

    #[test]
    fn install_download_url_format() {
        let actions = install_actions(
            "github:org/my-tool@3.1.0",
            None,
            InstallTarget::Global,
            None,
        )
        .unwrap();
        if let PluginAction::DownloadTarball { url, .. } = &actions[1] {
            assert_eq!(
                url,
                "https://github.com/org/my-tool/releases/download/v3.1.0/schemify-plugin-my-tool-3.1.0.tar.gz"
            );
        } else {
            panic!("expected DownloadTarball at index 1");
        }
    }

    #[test]
    fn uninstall_not_found() {
        let lock = LockFile::default();
        let result = uninstall_actions("nonexistent", &lock, false, None);
        assert!(result.is_err());
    }

    #[test]
    fn uninstall_produces_plan() {
        let lock = LockFile {
            installed: vec![LockEntry {
                id: "test-plugin".into(),
                version: "1.0.0".into(),
                source: "github:user/test-plugin".into(),
                sha256: String::new(),
                location: "global".into(),
            }],
        };
        let actions = uninstall_actions("test-plugin", &lock, false, None).unwrap();
        assert!(actions
            .iter()
            .any(|a| matches!(a, PluginAction::RemoveDir { .. })));
        assert!(actions
            .iter()
            .any(|a| matches!(a, PluginAction::RemoveLockEntry { .. })));
        assert!(actions
            .iter()
            .any(|a| matches!(a, PluginAction::RemovePluginData { .. })));
    }

    #[test]
    fn uninstall_keep_data() {
        let lock = LockFile {
            installed: vec![LockEntry {
                id: "test-plugin".into(),
                version: "1.0.0".into(),
                source: "github:user/test-plugin".into(),
                sha256: String::new(),
                location: "global".into(),
            }],
        };
        let actions = uninstall_actions("test-plugin", &lock, true, None).unwrap();
        assert!(!actions
            .iter()
            .any(|a| matches!(a, PluginAction::RemovePluginData { .. })));
    }

    #[test]
    fn list_installed_from_lock() {
        let lock = LockFile {
            installed: vec![
                LockEntry {
                    id: "aaa".into(),
                    version: "1.0.0".into(),
                    source: "github:u/aaa".into(),
                    sha256: String::new(),
                    location: "global".into(),
                },
                LockEntry {
                    id: "bbb".into(),
                    version: "2.0.0".into(),
                    source: "github:u/bbb".into(),
                    sha256: String::new(),
                    location: "project".into(),
                },
            ],
        };
        let plugins = list_installed(&lock);
        assert_eq!(plugins.len(), 2);
        assert_eq!(plugins[0].id, "aaa");
        assert_eq!(plugins[1].id, "bbb");
    }

    #[test]
    fn merge_project_wins() {
        let lock_entries = vec![InstalledPlugin {
            id: "x".into(),
            version: "1.0.0".into(),
            source: "github:u/x".into(),
            location: "global".into(),
        }];
        let scanned = vec![InstalledPlugin {
            id: "x".into(),
            version: "2.0.0".into(),
            source: "local".into(),
            location: "project".into(),
        }];
        let merged = merge_installed(&lock_entries, &scanned);
        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0].location, "project");
        assert_eq!(merged[0].version, "2.0.0");
    }

    #[test]
    fn merge_no_duplicates() {
        let entries = vec![
            InstalledPlugin {
                id: "a".into(),
                version: "1.0.0".into(),
                source: "s".into(),
                location: "global".into(),
            },
            InstalledPlugin {
                id: "b".into(),
                version: "1.0.0".into(),
                source: "s".into(),
                location: "project".into(),
            },
        ];
        let merged = merge_installed(&entries, &[]);
        assert_eq!(merged.len(), 2);
    }

    #[test]
    fn uninstall_preview_global() {
        let lock = LockFile {
            installed: vec![LockEntry {
                id: "my-plug".into(),
                version: "1.0.0".into(),
                source: "github:u/my-plug".into(),
                sha256: String::new(),
                location: "global".into(),
            }],
        };
        let plan = uninstall_preview("my-plug", &lock, true, None).unwrap();
        assert_eq!(plan.id, "my-plug");
        assert!(plan.plugin_dir.ends_with("schemify/plugins/my-plug"));
        assert!(plan.has_data);
    }
}
