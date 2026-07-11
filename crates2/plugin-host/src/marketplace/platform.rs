use std::path::Path;

pub fn detect_target_triple() -> String {
    let arch = if cfg!(target_arch = "x86_64") {
        "x86_64"
    } else if cfg!(target_arch = "aarch64") {
        "aarch64"
    } else {
        "unknown"
    };

    let os = if cfg!(target_os = "linux") {
        "unknown-linux-gnu"
    } else if cfg!(target_os = "macos") {
        "apple-darwin"
    } else if cfg!(target_os = "windows") {
        "pc-windows-msvc"
    } else {
        "unknown"
    };

    format!("{arch}-{os}")
}

#[cfg(unix)]
pub fn set_executable(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let meta = std::fs::metadata(path)?;
    let mut perms = meta.permissions();
    perms.set_mode(perms.mode() | 0o111);
    std::fs::set_permissions(path, perms)
}

#[cfg(not(unix))]
pub fn set_executable(_path: &Path) -> std::io::Result<()> {
    Ok(())
}

pub fn make_bin_dir_executable(plugin_dir: &Path) -> std::io::Result<()> {
    let bin_dir = plugin_dir.join("bin");
    if !bin_dir.is_dir() {
        return Ok(());
    }
    for entry in std::fs::read_dir(&bin_dir)? {
        let entry = entry?;
        if entry.file_type()?.is_file() {
            set_executable(&entry.path())?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn triple_is_not_unknown() {
        let triple = detect_target_triple();
        assert!(!triple.starts_with("unknown"), "arch should be detected: {triple}");
        assert!(!triple.ends_with("unknown"), "os should be detected: {triple}");
    }
}
