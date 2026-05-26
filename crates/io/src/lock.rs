use serde::{Deserialize, Serialize};

/// Plugin lock file: tracks installed plugins with versions and hashes.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct LockFile {
    #[serde(default)]
    pub installed: Vec<LockEntry>,
}

/// A single installed plugin entry in the lock file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LockEntry {
    pub id: String,
    pub version: String,
    pub source: String,
    pub sha256: String,
    /// "global" or "project"
    pub location: String,
}

#[cfg(not(target_arch = "wasm32"))]
pub fn read_lock_file(path: &std::path::Path) -> Result<LockFile, std::io::Error> {
    match std::fs::read_to_string(path) {
        Ok(content) => toml::from_str(&content).map_err(|e| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string())
        }),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(LockFile::default()),
        Err(e) => Err(e),
    }
}

#[cfg(not(target_arch = "wasm32"))]
pub fn write_lock_file(path: &std::path::Path, lock: &LockFile) -> Result<(), std::io::Error> {
    let content = toml::to_string_pretty(lock).map_err(|e| {
        std::io::Error::new(std::io::ErrorKind::Other, e.to_string())
    })?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, content)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lock_file_roundtrip() {
        let lock = LockFile {
            installed: vec![
                LockEntry {
                    id: "test-plugin".into(),
                    version: "1.0.0".into(),
                    source: "github:user/test-plugin".into(),
                    sha256: "abc123".into(),
                    location: "global".into(),
                },
                LockEntry {
                    id: "dev-tool".into(),
                    version: "0.2.0".into(),
                    source: "github:org/dev-tool".into(),
                    sha256: "def456".into(),
                    location: "project".into(),
                },
            ],
        };
        let serialized = toml::to_string_pretty(&lock).unwrap();
        let deserialized: LockFile = toml::from_str(&serialized).unwrap();
        assert_eq!(deserialized.installed.len(), 2);
        assert_eq!(deserialized.installed[0].id, "test-plugin");
        assert_eq!(deserialized.installed[1].location, "project");
    }

    #[test]
    fn empty_lock_file() {
        let lock = LockFile::default();
        let serialized = toml::to_string_pretty(&lock).unwrap();
        let deserialized: LockFile = toml::from_str(&serialized).unwrap();
        assert!(deserialized.installed.is_empty());
    }

    #[test]
    fn parse_lock_toml() {
        let toml_str = r#"
[[installed]]
id = "my-plugin"
version = "2.0.0"
source = "github:me/my-plugin"
sha256 = "deadbeef"
location = "global"
"#;
        let lock: LockFile = toml::from_str(toml_str).unwrap();
        assert_eq!(lock.installed.len(), 1);
        assert_eq!(lock.installed[0].id, "my-plugin");
        assert_eq!(lock.installed[0].version, "2.0.0");
    }

    #[cfg(not(target_arch = "wasm32"))]
    #[test]
    fn read_missing_returns_default() {
        let path = std::path::Path::new("/tmp/schemify_test_nonexistent_lock.toml");
        let lock = read_lock_file(path).unwrap();
        assert!(lock.installed.is_empty());
    }

    #[cfg(not(target_arch = "wasm32"))]
    #[test]
    fn write_and_read_back() {
        let path = std::env::temp_dir().join("schemify_test_lock_rw.toml");
        let lock = LockFile {
            installed: vec![LockEntry {
                id: "rw-test".into(),
                version: "1.0.0".into(),
                source: "github:u/rw-test".into(),
                sha256: "aaa".into(),
                location: "global".into(),
            }],
        };
        write_lock_file(&path, &lock).unwrap();
        let read_back = read_lock_file(&path).unwrap();
        assert_eq!(read_back.installed.len(), 1);
        assert_eq!(read_back.installed[0].id, "rw-test");
        let _ = std::fs::remove_file(&path);
    }
}
