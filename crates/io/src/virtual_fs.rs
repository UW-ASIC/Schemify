use std::collections::HashMap;

/// In-memory filesystem for WASM builds.
/// Populated from project.json at startup, then used in place of real FS.
#[derive(Default)]
pub struct VirtualFs {
    files: HashMap<String, String>,
}

impl VirtualFs {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn insert(&mut self, path: String, content: String) {
        self.files.insert(path, content);
    }

    pub fn read(&self, path: &str) -> Option<&str> {
        self.files.get(path).map(|s| s.as_str())
    }

    /// List files whose path starts with `dir_prefix`.
    /// Returns relative paths (with prefix stripped).
    pub fn list_dir(&self, dir_prefix: &str) -> Vec<&str> {
        let prefix = if dir_prefix.ends_with('/') {
            dir_prefix.to_string()
        } else if dir_prefix.is_empty() {
            String::new()
        } else {
            format!("{dir_prefix}/")
        };
        self.files
            .keys()
            .filter(|k| k.starts_with(&prefix))
            .map(|k| k.as_str())
            .collect()
    }

    /// List files ending with given extension.
    pub fn list_ext(&self, ext: &str) -> Vec<&str> {
        self.files
            .keys()
            .filter(|k| k.ends_with(ext))
            .map(|k| k.as_str())
            .collect()
    }

    pub fn is_empty(&self) -> bool {
        self.files.is_empty()
    }

    pub fn len(&self) -> usize {
        self.files.len()
    }
}
