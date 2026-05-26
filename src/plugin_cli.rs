use std::path::{Path, PathBuf};
use std::process;

use clap::Subcommand;
use schemify_handler::plugin_dist::{
    self, InstallTarget, PluginAction,
};
use schemify_io::lock::{self, LockEntry};
use schemify_io::paths;

#[derive(Subcommand)]
pub enum PluginCommand {
    /// Install a plugin from a source
    Install {
        /// Plugin source (github:owner/repo or github:owner/repo@version)
        source: String,
        /// Install to project-local plugins/ directory
        #[arg(long)]
        project: bool,
        /// Install from local tarball file
        #[arg(long)]
        from_file: bool,
    },
    /// Uninstall a plugin by id
    Uninstall {
        /// Plugin ID
        id: String,
        /// Keep plugin state data
        #[arg(long)]
        keep_data: bool,
    },
    /// List installed plugins
    List,
}

pub fn run_plugin_command(cmd: PluginCommand, project_dir: Option<&Path>) {
    match cmd {
        PluginCommand::Install {
            source,
            project,
            from_file,
        } => {
            if from_file {
                run_install_from_file(&source, project, project_dir);
            } else {
                run_install(&source, project, project_dir);
            }
        }
        PluginCommand::Uninstall { id, keep_data } => {
            run_uninstall(&id, keep_data, project_dir);
        }
        PluginCommand::List => {
            run_list();
        }
    }
}

fn run_install(source: &str, project: bool, project_dir: Option<&Path>) {
    let target = if project {
        InstallTarget::Project
    } else {
        InstallTarget::Global
    };

    let actions = match plugin_dist::install_actions(source, None, target, project_dir) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("error: {e}");
            process::exit(1);
        }
    };

    if let Err(e) = execute_actions(&actions) {
        eprintln!("error: {e}");
        // Clean up temp files on failure
        cleanup_temp();
        process::exit(1);
    }
}

fn run_install_from_file(file_path: &str, project: bool, project_dir: Option<&Path>) {
    let path = PathBuf::from(file_path);
    if !path.exists() {
        eprintln!("error: file not found: {file_path}");
        process::exit(1);
    }

    let cache = paths::cache_dir();
    let temp_dir = cache.join("tmp").join("from-file");

    // Extract to temp
    println!("Extracting {file_path}...");
    if let Err(e) = extract_tarball(&path, &temp_dir) {
        eprintln!("error: {e}");
        process::exit(1);
    }

    // Find and read plugin.toml
    let manifest_path = find_manifest(&temp_dir);
    let manifest_path = match manifest_path {
        Some(p) => p,
        None => {
            eprintln!("error: plugin.toml not found in tarball");
            let _ = std::fs::remove_dir_all(&temp_dir);
            process::exit(1);
        }
    };

    let content = match std::fs::read_to_string(&manifest_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error reading plugin.toml: {e}");
            let _ = std::fs::remove_dir_all(&temp_dir);
            process::exit(1);
        }
    };

    // Parse manifest to get id and version
    let parsed: toml::Value = match toml::from_str(&content) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("error: invalid plugin.toml: {e}");
            let _ = std::fs::remove_dir_all(&temp_dir);
            process::exit(1);
        }
    };

    let plugin_section = parsed.get("plugin").unwrap_or(&parsed);
    let id = plugin_section
        .get("id")
        .and_then(|v| v.as_str())
        .or_else(|| plugin_section.get("name").and_then(|v| v.as_str()));
    let version = plugin_section
        .get("version")
        .and_then(|v| v.as_str());

    let id = match id {
        Some(id) => id.to_string(),
        None => {
            eprintln!("error: plugin.toml missing id/name field");
            let _ = std::fs::remove_dir_all(&temp_dir);
            process::exit(1);
        }
    };
    let version = match version {
        Some(v) => v.to_string(),
        None => {
            eprintln!("error: plugin.toml missing version field");
            let _ = std::fs::remove_dir_all(&temp_dir);
            process::exit(1);
        }
    };

    // Determine destination
    let dest = if project {
        let pd = match project_dir {
            Some(pd) => pd,
            None => {
                eprintln!("error: --project requires a project directory");
                let _ = std::fs::remove_dir_all(&temp_dir);
                process::exit(1);
            }
        };
        pd.join("plugins").join(&id)
    } else {
        paths::global_plugins_dir().join(&id)
    };

    let location = if project { "project" } else { "global" };

    // Move to destination
    let plugin_source_dir = manifest_path.parent().unwrap();
    let actions = vec![
        PluginAction::MoveDir {
            from: plugin_source_dir.to_path_buf(),
            to: dest,
        },
        PluginAction::UpdateLock {
            entry: LockEntry {
                id: id.clone(),
                version: version.clone(),
                source: format!("file:{file_path}"),
                sha256: String::new(),
                location: location.to_string(),
            },
        },
        PluginAction::Notify {
            message: format!("Installed {id}@{version} from {file_path}"),
        },
    ];

    if let Err(e) = execute_actions(&actions) {
        eprintln!("error: {e}");
        let _ = std::fs::remove_dir_all(&temp_dir);
        process::exit(1);
    }
}

fn run_uninstall(id: &str, keep_data: bool, project_dir: Option<&Path>) {
    let lock_path = paths::lock_file_path();
    let lock_file = match lock::read_lock_file(&lock_path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("error reading lock file: {e}");
            process::exit(1);
        }
    };

    // Show preview
    let preview = match plugin_dist::uninstall_preview(id, &lock_file, false, project_dir) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("error: {e}");
            process::exit(1);
        }
    };

    println!("Will remove:");
    println!("  Plugin dir:  {}", preview.plugin_dir.display());
    println!("  Lock entry:  {}@{}", preview.id, preview.version);
    if !keep_data {
        println!("  Plugin data: (stored state)");
    }

    let actions =
        match plugin_dist::uninstall_actions(id, &lock_file, keep_data, project_dir) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("error: {e}");
                process::exit(1);
            }
        };

    if let Err(e) = execute_actions(&actions) {
        eprintln!("error: {e}");
        process::exit(1);
    }
}

fn run_list() {
    let lock_path = paths::lock_file_path();
    let lock_file = match lock::read_lock_file(&lock_path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("error reading lock file: {e}");
            process::exit(1);
        }
    };

    let plugins = plugin_dist::list_installed(&lock_file);
    if plugins.is_empty() {
        println!("No plugins installed.");
        return;
    }

    println!("{:<20} {:<10} {:<8} {}", "ID", "VERSION", "SCOPE", "SOURCE");
    println!("{}", "-".repeat(60));
    for p in &plugins {
        println!("{:<20} {:<10} {:<8} {}", p.id, p.version, p.location, p.source);
    }
}

// ====================================================
// Action Executor
// ====================================================

fn execute_actions(actions: &[PluginAction]) -> Result<(), String> {
    for action in actions {
        match action {
            PluginAction::Notify { message } => {
                println!("{message}");
            }
            PluginAction::DownloadTarball { url, dest, .. } => {
                if let Some(parent) = dest.parent() {
                    std::fs::create_dir_all(parent)
                        .map_err(|e| format!("creating dir: {e}"))?;
                }
                download_with_retry(url, dest, 3)?;
            }
            PluginAction::Extract { tarball_path, dest } => {
                extract_tarball(tarball_path, dest)?;
            }
            PluginAction::ValidateManifest { plugin_dir } => {
                let manifest_path = find_manifest(plugin_dir);
                match manifest_path {
                    Some(p) => {
                        let content = std::fs::read_to_string(&p)
                            .map_err(|e| format!("reading plugin.toml: {e}"))?;
                        let _: toml::Value = toml::from_str(&content)
                            .map_err(|e| format!("invalid plugin.toml: {e}"))?;
                    }
                    None => return Err("plugin.toml not found in extracted archive".into()),
                }
            }
            PluginAction::MoveDir { from, to } => {
                if to.exists() {
                    std::fs::remove_dir_all(to)
                        .map_err(|e| format!("removing existing dir: {e}"))?;
                }
                if let Some(parent) = to.parent() {
                    std::fs::create_dir_all(parent)
                        .map_err(|e| format!("creating parent dir: {e}"))?;
                }
                // Try rename first (same filesystem), fall back to copy+delete
                if std::fs::rename(from, to).is_err() {
                    copy_dir_recursive(from, to)?;
                    std::fs::remove_dir_all(from)
                        .map_err(|e| format!("cleaning temp dir: {e}"))?;
                }
            }
            PluginAction::UpdateLock { entry } => {
                let lock_path = paths::lock_file_path();
                let mut lock_file = lock::read_lock_file(&lock_path)
                    .map_err(|e| format!("reading lock file: {e}"))?;
                lock_file.installed.retain(|e| e.id != entry.id);
                lock_file.installed.push(entry.clone());
                lock::write_lock_file(&lock_path, &lock_file)
                    .map_err(|e| format!("writing lock file: {e}"))?;
            }
            PluginAction::RemoveLockEntry { id } => {
                let lock_path = paths::lock_file_path();
                let mut lock_file = lock::read_lock_file(&lock_path)
                    .map_err(|e| format!("reading lock file: {e}"))?;
                lock_file.installed.retain(|e| e.id != *id);
                lock::write_lock_file(&lock_path, &lock_file)
                    .map_err(|e| format!("writing lock file: {e}"))?;
            }
            PluginAction::RemoveDir { path } => {
                if path.exists() {
                    std::fs::remove_dir_all(path)
                        .map_err(|e| format!("removing dir: {e}"))?;
                }
            }
            PluginAction::RemovePluginData { .. } => {
                // In CLI context, plugin data lives in AppState (runtime only).
                // No persistent data to remove from CLI.
            }
            PluginAction::SendLifecycle { .. } => {
                // CLI has no running plugin processes to notify.
            }
            PluginAction::FetchRegistryDb { .. } | PluginAction::VerifyCosign { .. } => {
                // Phase 2/3 — not yet implemented
            }
        }
    }
    Ok(())
}

fn download_with_retry(url: &str, dest: &Path, max_retries: u32) -> Result<(), String> {
    for attempt in 0..max_retries {
        let status = process::Command::new("curl")
            .args(["-fsSL", "-o"])
            .arg(dest)
            .arg(url)
            .status();

        match status {
            Ok(s) if s.success() => return Ok(()),
            Ok(_) if attempt < max_retries - 1 => {
                eprintln!("  Download failed, retrying ({}/{max_retries})...", attempt + 1);
                let delay = 1u64 << attempt;
                std::thread::sleep(std::time::Duration::from_secs(delay));
            }
            Ok(_) => {
                return Err(format!(
                    "download failed after {max_retries} attempts: {url}"
                ))
            }
            Err(e) => return Err(format!("curl not found or failed to run: {e}")),
        }
    }
    unreachable!()
}

fn extract_tarball(tarball: &Path, dest: &Path) -> Result<(), String> {
    std::fs::create_dir_all(dest).map_err(|e| format!("creating extract dir: {e}"))?;
    let status = process::Command::new("tar")
        .args(["-xzf"])
        .arg(tarball)
        .arg("-C")
        .arg(dest)
        .status()
        .map_err(|e| format!("running tar: {e}"))?;
    if !status.success() {
        return Err("tar extraction failed".into());
    }
    Ok(())
}

/// Find plugin.toml in extracted dir (at root or one level deep).
fn find_manifest(dir: &Path) -> Option<PathBuf> {
    let direct = dir.join("plugin.toml");
    if direct.exists() {
        return Some(direct);
    }
    // Check one level of subdirectories (GitHub tarballs often have a top-level dir)
    if let Ok(entries) = std::fs::read_dir(dir) {
        let subdirs: Vec<_> = entries
            .filter_map(|e| e.ok())
            .filter(|e| e.path().is_dir())
            .collect();
        if subdirs.len() == 1 {
            let nested = subdirs[0].path().join("plugin.toml");
            if nested.exists() {
                return Some(nested);
            }
        }
    }
    None
}

fn copy_dir_recursive(src: &Path, dst: &Path) -> Result<(), String> {
    std::fs::create_dir_all(dst).map_err(|e| format!("creating {}: {e}", dst.display()))?;
    let entries =
        std::fs::read_dir(src).map_err(|e| format!("reading {}: {e}", src.display()))?;
    for entry in entries {
        let entry = entry.map_err(|e| format!("reading entry: {e}"))?;
        let src_path = entry.path();
        let dst_path = dst.join(entry.file_name());
        if src_path.is_dir() {
            copy_dir_recursive(&src_path, &dst_path)?;
        } else {
            std::fs::copy(&src_path, &dst_path)
                .map_err(|e| format!("copying {}: {e}", src_path.display()))?;
        }
    }
    Ok(())
}

fn cleanup_temp() {
    let tmp = paths::cache_dir().join("tmp");
    let _ = std::fs::remove_dir_all(&tmp);
}
