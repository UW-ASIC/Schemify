//! Simulation support: circuit IR (JSON contract with pyspice_rs),
//! code generation (PySpice scripts and SPICE netlists), stimulus files,
//! and bundled-PySpice runtime discovery.

pub mod codegen;
pub mod ir;
pub mod stimulus;

pub use ir::*;

/// Discovery of the bundled `pyspice_rs` Python module and interpreter.
pub mod pyspice {
    use std::path::{Path, PathBuf};

    /// Returns the path to the bundled `pyspice_rs` Python module directory,
    /// or `None` if PySpice was not available at build time
    /// (`PYSPICE_BUNDLE_DIR` unset).
    pub fn module_dir() -> Option<&'static Path> {
        option_env!("PYSPICE_BUNDLE_DIR").map(Path::new)
    }

    /// Returns whether PySpice support was compiled in.
    pub fn is_available() -> bool {
        module_dir().is_some()
    }

    /// Returns the `PYTHONPATH` value that includes the bundled module.
    /// Prepends the bundled dir to any existing `PYTHONPATH`.
    /// Returns `None` if PySpice is not available.
    pub fn python_path() -> Option<String> {
        let bundled = module_dir()?.to_string_lossy();
        Some(match std::env::var("PYTHONPATH") {
            Ok(existing) if !existing.is_empty() => format!("{bundled}:{existing}"),
            _ => bundled.into_owned(),
        })
    }

    /// Resolve the Python interpreter to use. Checks `PYTHON` env var first,
    /// then falls back to `python3`.
    pub fn python_bin() -> PathBuf {
        std::env::var("PYTHON")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("python3"))
    }
}
