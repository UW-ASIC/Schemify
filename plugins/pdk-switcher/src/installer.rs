//! Download / verify / extract / enable, ciel-compatible on disk:
//!
//! ```text
//! {root}/ciel/{family}/versions/{hash}/   ← all asset tarballs extracted
//! {root}/{variant} → ciel/{family}/versions/{hash}/{variant}   (symlink)
//! {root}/ciel/{family}/current            ← enabled hash (text)
//! ```
//!
//! Runs on a worker thread; progress lands in the shared [`Model`] and is
//! pushed to the host via [`HostSink`] (throttled).

use std::io::{Read, Seek, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use sha2::{Digest, Sha256};

use crate::families::PdkFamily;
use crate::remote::{self, AssetJob};
use crate::sink::HostSink;
use crate::view::{self, Model, Phase};

/// `$PDK_ROOT` or `~/.ciel` (ciel's convention).
pub fn pdk_root() -> PathBuf {
    if let Ok(root) = std::env::var("PDK_ROOT") {
        if !root.is_empty() {
            return PathBuf::from(root);
        }
    }
    dirs::home_dir()
        .unwrap_or_else(std::env::temp_dir)
        .join(".ciel")
}

fn versions_dir(family: PdkFamily) -> PathBuf {
    pdk_root().join("ciel").join(family.name()).join("versions")
}

fn current_file(family: PdkFamily) -> PathBuf {
    pdk_root().join("ciel").join(family.name()).join("current")
}

/// Installed build hashes for one family (directory scan, no network).
pub fn installed_hashes(family: PdkFamily) -> Vec<String> {
    let mut hashes = Vec::new();
    let Ok(entries) = std::fs::read_dir(versions_dir(family)) else {
        return hashes;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if entry.path().is_dir() && !name.ends_with(".partial") {
            hashes.push(name);
        }
    }
    hashes
}

/// Currently enabled hash for one family.
pub fn enabled_hash(family: PdkFamily) -> Option<String> {
    std::fs::read_to_string(current_file(family))
        .ok()
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
}

/// Point the `{root}/{variant}` symlinks at one installed build and record
/// it in `current`. Refuses to replace a real (non-symlink) directory.
pub fn enable(family: PdkFamily, hash: &str) -> Result<(), String> {
    let root = pdk_root();
    let version_dir = versions_dir(family).join(hash);
    if !version_dir.is_dir() {
        return Err(format!("{} is not installed", &hash[..8.min(hash.len())]));
    }

    for variant in family.variants() {
        let target = version_dir.join(variant);
        if !target.is_dir() {
            continue; // partial install (e.g. analog-only IHP) — skip
        }
        let link = root.join(variant);
        match std::fs::symlink_metadata(&link) {
            Ok(meta) if meta.file_type().is_symlink() => {
                std::fs::remove_file(&link).map_err(|e| e.to_string())?;
            }
            Ok(_) => {
                return Err(format!(
                    "{} exists and is not a symlink; refusing to replace it",
                    link.display()
                ));
            }
            Err(_) => {}
        }
        #[cfg(unix)]
        std::os::unix::fs::symlink(&target, &link).map_err(|e| e.to_string())?;
        #[cfg(not(unix))]
        return Err("enable: symlinks unsupported on this platform".into());
    }

    if let Some(parent) = current_file(family).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    std::fs::write(current_file(family), hash).map_err(|e| e.to_string())?;
    Ok(())
}

/// Full install pipeline for one build. Blocking; run on a worker thread.
pub fn install(
    family: PdkFamily,
    hash: String,
    full: bool,
    model: Arc<Mutex<Model>>,
    cancel: Arc<AtomicBool>,
    sink: HostSink,
) {
    let result = install_inner(family, &hash, full, &model, &cancel, &sink);
    {
        let mut m = model.lock().unwrap();
        m.phase = match result {
            Ok(()) => {
                m.refresh_installed();
                Phase::Done(format!(
                    "{} {} installed + enabled",
                    family.name(),
                    &hash[..8.min(hash.len())]
                ))
            }
            Err(e) if cancel.load(Ordering::Relaxed) => Phase::Failed(format!("cancelled: {e}")),
            Err(e) => Phase::Failed(e),
        };
        sink.update_widgets(view::PANEL, view::render(&m));
    }
    let _ = sink.set_status(match &model.lock().unwrap().phase {
        Phase::Done(msg) => format!("PDK: {msg}"),
        Phase::Failed(msg) => format!("PDK install failed: {msg}"),
        _ => String::new(),
    });
}

fn install_inner(
    family: PdkFamily,
    hash: &str,
    full: bool,
    model: &Arc<Mutex<Model>>,
    cancel: &Arc<AtomicBool>,
    sink: &HostSink,
) -> Result<(), String> {
    // 1. Plan assets (release-by-tag carries sizes + digests).
    let mut assets = remote::release_assets(family, hash)?;
    if !full {
        let wanted = family.default_assets();
        assets.retain(|a| {
            let stem = a.filename.trim_end_matches(".tar.zst");
            wanted.contains(&stem)
        });
    }
    if assets.is_empty() {
        return Err("no assets match the selected library set".into());
    }

    let dl_dir = remote::cache_dir()
        .join("dl")
        .join(format!("{}-{hash}", family.name()));
    std::fs::create_dir_all(&dl_dir).map_err(|e| e.to_string())?;

    // 2. Download each (resume + sha256).
    for (i, asset) in assets.iter().enumerate() {
        check_cancel(cancel)?;
        download_asset(asset, &dl_dir, i, assets.len(), model, cancel, sink)?;
    }

    // 3. Extract all into `{hash}.partial`, then atomic rename.
    let final_dir = versions_dir(family).join(hash);
    let partial_dir = versions_dir(family).join(format!("{hash}.partial"));
    let _ = std::fs::remove_dir_all(&partial_dir);
    std::fs::create_dir_all(&partial_dir).map_err(|e| e.to_string())?;

    for asset in &assets {
        check_cancel(cancel)?;
        set_phase(
            model,
            sink,
            Phase::Extracting {
                file: asset.filename.clone(),
            },
        );
        let file = std::fs::File::open(dl_dir.join(&asset.filename)).map_err(|e| e.to_string())?;
        let decoder = zstd::Decoder::new(file).map_err(|e| e.to_string())?;
        let mut archive = tar::Archive::new(decoder);
        // `Archive::unpack` already rejects entries escaping the target dir.
        archive.unpack(&partial_dir).map_err(|e| e.to_string())?;
    }

    let _ = std::fs::remove_dir_all(&final_dir);
    std::fs::rename(&partial_dir, &final_dir).map_err(|e| e.to_string())?;

    // 4. Downloads no longer needed.
    let _ = std::fs::remove_dir_all(&dl_dir);

    // 5. IHP ships no schemify manifest; write one so non-schemify tools and
    // older cores see it on disk (core/pdk-mapper also embed a built-in copy —
    // keep manifests/ihp-sg13g2.toml in sync with both).
    if family == PdkFamily::IhpSg13g2 {
        inject_ihp_manifest(&final_dir);
    }

    // 6. Enable (symlinks + current).
    enable(family, hash)
}

fn check_cancel(cancel: &Arc<AtomicBool>) -> Result<(), String> {
    if cancel.load(Ordering::Relaxed) {
        Err("cancelled by user".into())
    } else {
        Ok(())
    }
}

fn set_phase(model: &Arc<Mutex<Model>>, sink: &HostSink, phase: Phase) {
    let mut m = model.lock().unwrap();
    m.phase = phase;
    sink.update_widgets(view::PANEL, view::render(&m));
}

fn download_asset(
    asset: &AssetJob,
    dl_dir: &Path,
    index: usize,
    count: usize,
    model: &Arc<Mutex<Model>>,
    cancel: &Arc<AtomicBool>,
    sink: &HostSink,
) -> Result<(), String> {
    let part_path = dl_dir.join(format!("{}.part", asset.filename));
    let done_path = dl_dir.join(&asset.filename);

    // Already fully downloaded + verified in a previous attempt.
    if done_path.exists() {
        return Ok(());
    }

    let mut start = std::fs::metadata(&part_path).map(|m| m.len()).unwrap_or(0);
    if asset.size > 0 && start > asset.size {
        let _ = std::fs::remove_file(&part_path);
        start = 0;
    }

    let mut request = ureq::get(&asset.url);
    if start > 0 {
        request = request.header("Range", format!("bytes={start}-"));
    }
    let mut response = request.call().map_err(|e| format!("download: {e}"))?;
    if start > 0 && response.status() != 206 {
        // Server ignored the range; restart from scratch.
        let _ = std::fs::remove_file(&part_path);
        start = 0;
    }

    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&part_path)
        .map_err(|e| e.to_string())?;
    if start == 0 {
        file.set_len(0).map_err(|e| e.to_string())?;
    }

    let mut reader = response.body_mut().as_reader();
    let mut buf = [0u8; 64 * 1024];
    let mut bytes = start;
    let mut last_push = Instant::now();
    loop {
        check_cancel(cancel)?; // .part stays for resume
        let n = reader.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        bytes += n as u64;

        if last_push.elapsed() > Duration::from_millis(250) {
            last_push = Instant::now();
            let mut m = model.lock().unwrap();
            m.phase = Phase::Downloading {
                file: asset.filename.clone(),
                asset_idx: index,
                asset_count: count,
                bytes,
                total: asset.size,
            };
            sink.update_widgets(view::PANEL, view::render(&m));
        }
    }
    file.flush().map_err(|e| e.to_string())?;
    drop(file);

    // Verify (digest is absent on some releases, e.g. ihp — best effort).
    if let Some(expected) = &asset.sha256 {
        let actual = sha256_file(&part_path)?;
        if &actual != expected {
            let _ = std::fs::remove_file(&part_path);
            return Err(format!("{}: sha256 mismatch", asset.filename));
        }
    }
    std::fs::rename(&part_path, &done_path).map_err(|e| e.to_string())?;
    Ok(())
}

/// Selftest hook: download + verify one asset without a real host.
pub fn download_one_for_test(
    asset: &AssetJob,
    dl_dir: &Path,
    model: &Arc<Mutex<Model>>,
    cancel: &Arc<AtomicBool>,
) -> Result<(), String> {
    download_asset(asset, dl_dir, 0, 1, model, cancel, &HostSink)
}

fn sha256_file(path: &Path) -> Result<String, String> {
    let mut file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    file.rewind().map_err(|e| e.to_string())?;
    let mut hasher = Sha256::new();
    std::io::copy(&mut file, &mut hasher).map_err(|e| e.to_string())?;
    Ok(format!("{:x}", hasher.finalize()))
}

/// Write a `schemify-pdk.toml` into each IHP variant dir that lacks one.
fn inject_ihp_manifest(version_dir: &Path) {
    const MANIFEST: &str = include_str!("../manifests/ihp-sg13g2.toml");
    for variant in PdkFamily::IhpSg13g2.variants() {
        let dir = version_dir.join(variant);
        let path = dir.join("schemify-pdk.toml");
        if dir.is_dir() && !path.exists() {
            let _ = std::fs::write(path, MANIFEST);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// PDK_ROOT is process-global; serialize the tests that set it.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn enable_symlinks_in_tempdir() {
        let _guard = ENV_LOCK.lock().unwrap();
        let tmp = std::env::temp_dir().join(format!("pdksw-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::env::set_var("PDK_ROOT", &tmp);

        let family = PdkFamily::Sky130;
        let hash = "abc123";
        let vdir = versions_dir(family).join(hash);
        std::fs::create_dir_all(vdir.join("sky130A")).unwrap();

        enable(family, hash).unwrap();
        assert_eq!(enabled_hash(family).as_deref(), Some(hash));
        let link = pdk_root().join("sky130A");
        assert!(std::fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
        // sky130B not present in the build → no link created.
        assert!(std::fs::symlink_metadata(pdk_root().join("sky130B")).is_err());

        // Real directory at the link path → refuse.
        std::fs::remove_file(&link).unwrap();
        std::fs::create_dir_all(&link).unwrap();
        assert!(enable(family, hash).is_err());

        let _ = std::fs::remove_dir_all(&tmp);
        std::env::remove_var("PDK_ROOT");
    }

    #[test]
    fn installed_scan_skips_partial() {
        let _guard = ENV_LOCK.lock().unwrap();
        let tmp = std::env::temp_dir().join(format!("pdksw-scan-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::env::set_var("PDK_ROOT", &tmp);

        let family = PdkFamily::Gf180mcu;
        std::fs::create_dir_all(versions_dir(family).join("aaa111")).unwrap();
        std::fs::create_dir_all(versions_dir(family).join("bbb222.partial")).unwrap();

        let hashes = installed_hashes(family);
        assert_eq!(hashes, vec!["aaa111".to_owned()]);

        let _ = std::fs::remove_dir_all(&tmp);
        std::env::remove_var("PDK_ROOT");
    }
}
