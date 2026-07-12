//! Simulation support: circuit IR (JSON contract with pyspice_rs),
//! IR emission from schematics, code generation (PySpice scripts and
//! SPICE netlists), PDK manifests, and the external simulator runner.

pub mod codegen;
pub mod ir;
pub mod ir_emit;
pub mod pdk;
#[cfg(not(target_arch = "wasm32"))]
pub mod runner;

pub use ir::*;
pub use ir_emit::{to_circuit_ir, to_circuit_ir_with_children};

/// Discovery of the bundled `pyspice_rs` Python module and interpreter.
pub mod pyspice {
    use std::path::{Path, PathBuf};

    /// Returns the path to the `pyspice_rs` Python module directory:
    /// the dir bundled at build time (`PYSPICE_BUNDLE_DIR`, release nix
    /// builds), else the runtime devshell dir (`PYSPICE_MODULE_DIR`, so
    /// plain `cargo run` inside `nix develop` can simulate too).
    pub fn module_dir() -> Option<PathBuf> {
        if let Some(dir) = option_env!("PYSPICE_BUNDLE_DIR") {
            return Some(Path::new(dir).to_path_buf());
        }
        std::env::var_os("PYSPICE_MODULE_DIR").map(PathBuf::from)
    }

    /// Returns whether PySpice support is available (bundled or devshell).
    pub fn is_available() -> bool {
        module_dir().is_some()
    }

    /// Returns the `PYTHONPATH` value that includes the bundled module.
    /// Prepends the bundled dir to any existing `PYTHONPATH`.
    /// Returns `None` if PySpice is not available.
    pub fn python_path() -> Option<String> {
        let dir = module_dir()?;
        let bundled = dir.to_string_lossy();
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
