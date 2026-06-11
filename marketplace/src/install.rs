use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::{DownloadEntry, InstalledPlugin, MarketplaceError};

pub fn download_and_verify(
    entry: &DownloadEntry,
    cache_dir: &Path,
    id: &str,
    version: &str,
    triple: &str,
) -> Result<PathBuf, MarketplaceError> {
    let downloads_dir = cache_dir.join("downloads");
    std::fs::create_dir_all(&downloads_dir)?;

    let filename = format!("{id}-{version}-{triple}.tar.gz");
    let dest = downloads_dir.join(&filename);

    let mut response = ureq::get(&entry.url)
        .call()
        .map_err(|e| MarketplaceError::Network(e.to_string()))?;

    let body = response
        .body_mut()
        .read_to_vec()
        .map_err(|e| MarketplaceError::Network(e.to_string()))?;

    let actual_hash = hex_sha256(&body);
    if actual_hash != entry.sha256 {
        return Err(MarketplaceError::ChecksumMismatch {
            expected: entry.sha256.clone(),
            actual: actual_hash,
        });
    }

    std::fs::write(&dest, &body)?;
    Ok(dest)
}

pub fn extract_tarball(
    tarball_path: &Path,
    cache_dir: &Path,
) -> Result<PathBuf, MarketplaceError> {
    let tmp_dir = cache_dir.join("tmp");
    std::fs::create_dir_all(&tmp_dir)?;

    let extract_dir = tmp_dir.join(format!(
        "extract-{}",
        std::process::id()
    ));
    if extract_dir.exists() {
        std::fs::remove_dir_all(&extract_dir)?;
    }
    std::fs::create_dir_all(&extract_dir)?;

    let file = std::fs::File::open(tarball_path)?;
    let decoder = flate2::read::GzDecoder::new(file);
    let mut archive = tar::Archive::new(decoder);
    archive
        .unpack(&extract_dir)
        .map_err(|e| MarketplaceError::Extract(e.to_string()))?;

    Ok(extract_dir)
}

pub fn find_plugin_root(extract_dir: &Path) -> Result<PathBuf, MarketplaceError> {
    if extract_dir.join("plugin.toml").exists() {
        return Ok(extract_dir.to_owned());
    }

    for entry in std::fs::read_dir(extract_dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() && path.join("plugin.toml").exists() {
            return Ok(path);
        }
    }

    Err(MarketplaceError::InvalidPlugin(
        "tarball does not contain plugin.toml".into(),
    ))
}

pub fn validate_extracted(
    plugin_root: &Path,
    expected_id: Option<&str>,
) -> Result<String, MarketplaceError> {
    let manifest_path = plugin_root.join("plugin.toml");
    let manifest = schemify_plugins::PluginManifest::load(&manifest_path)?;

    if let Some(expected) = expected_id {
        if manifest.plugin.id != expected {
            return Err(MarketplaceError::InvalidPlugin(format!(
                "manifest id '{}' does not match expected '{expected}'",
                manifest.plugin.id
            )));
        }
    }

    Ok(manifest.plugin.id)
}

pub fn place_plugin(
    plugin_root: &Path,
    plugins_dir: &Path,
    id: &str,
) -> Result<(), MarketplaceError> {
    let dest = plugins_dir.join(id);

    if dest.exists() {
        std::fs::remove_dir_all(&dest)?;
    }

    if std::fs::rename(plugin_root, &dest).is_err() {
        copy_dir_recursive(plugin_root, &dest)?;
        let _ = std::fs::remove_dir_all(plugin_root);
    }

    crate::platform::make_bin_dir_executable(&dest)?;
    Ok(())
}

pub fn remove_plugin(plugins_dir: &Path, id: &str) -> Result<(), MarketplaceError> {
    let dir = plugins_dir.join(id);
    if !dir.exists() {
        return Err(MarketplaceError::NotInstalled(id.to_owned()));
    }
    std::fs::remove_dir_all(&dir)?;
    Ok(())
}

pub fn make_installed_record(
    id: &str,
    name: &str,
    version: &str,
    sha256: &str,
) -> InstalledPlugin {
    InstalledPlugin {
        id: id.to_owned(),
        name: name.to_owned(),
        version: version.to_owned(),
        tarball_sha256: sha256.to_owned(),
    }
}

fn hex_sha256(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    let result = hasher.finalize();
    result.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn sha256_file(path: &Path) -> Result<String, MarketplaceError> {
    let data = std::fs::read(path)?;
    Ok(hex_sha256(&data))
}

fn copy_dir_recursive(src: &Path, dst: &Path) -> Result<(), MarketplaceError> {
    std::fs::create_dir_all(dst)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let src_path = entry.path();
        let dst_path = dst.join(entry.file_name());
        if src_path.is_dir() {
            copy_dir_recursive(&src_path, &dst_path)?;
        } else {
            std::fs::copy(&src_path, &dst_path)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_consistent() {
        let data = b"hello world";
        let hash = hex_sha256(data);
        assert_eq!(hash.len(), 64);
        assert_eq!(hex_sha256(data), hash);
    }

    #[test]
    fn sha256_known_value() {
        let hash = hex_sha256(b"");
        assert_eq!(
            hash,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }
}
