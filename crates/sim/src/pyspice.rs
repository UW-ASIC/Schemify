use std::path::{Path, PathBuf};

/// Directory where the bundled pyspice_rs Python module was placed at build time.
const BUNDLED_DIR: &str = env!("PYSPICE_MODULE_DIR");

/// Returns the path to the bundled `pyspice_rs` Python module directory.
///
/// At runtime, add this to `PYTHONPATH` (or `sys.path`) so that user scripts
/// can `import pyspice_rs` without any pip install.
pub fn module_dir() -> &'static Path {
    Path::new(BUNDLED_DIR)
}

/// Returns the `PYTHONPATH` value that includes the bundled module.
/// Prepends the bundled dir to any existing `PYTHONPATH`.
pub fn python_path() -> String {
    let bundled = module_dir().to_string_lossy();
    match std::env::var("PYTHONPATH") {
        Ok(existing) if !existing.is_empty() => {
            format!("{bundled}:{existing}")
        }
        _ => bundled.into_owned(),
    }
}

/// Resolve the Python interpreter to use. Checks `PYTHON` env var first,
/// then falls back to `python3`.
pub fn python_bin() -> PathBuf {
    std::env::var("PYTHON")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("python3"))
}
