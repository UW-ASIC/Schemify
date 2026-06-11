use std::env;
use std::path::{Path, PathBuf};

/// Bundle the `pyspice_rs` Python module (from `PYSPICE_MODULE_DIR`, set by
/// the nix devshell) into the target dir so the binary is self-contained.
/// Exposes the bundle path at compile time as `PYSPICE_BUNDLE_DIR`
/// (read by `sim::pyspice::module_dir`). Absent module -> compiled without
/// simulation support; `option_env!` handles the missing var.
fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=PYSPICE_MODULE_DIR");

    let module_dir = env::var("PYSPICE_MODULE_DIR").ok().and_then(|dir| {
        let p = PathBuf::from(&dir);
        if p.join("pyspice_rs").exists() {
            Some(p)
        } else {
            eprintln!("Warning: PYSPICE_MODULE_DIR set but pyspice_rs not found in {dir}");
            None
        }
    });

    let Some(module_src) = module_dir else {
        return; // PySpice not available — sim runner reports it at runtime.
    };

    let module_src = module_src.join("pyspice_rs");
    let bundle_root = resolve_target_dir().join("pyspice_bundle");
    let bundle_dir = bundle_root.join("pyspice_rs");

    let _ = std::fs::remove_dir_all(&bundle_dir);
    std::fs::create_dir_all(&bundle_dir).unwrap();
    copy_dir_recursive(&module_src, &bundle_dir);

    // PYTHONPATH entries are directories *containing* the module.
    println!("cargo:rustc-env=PYSPICE_BUNDLE_DIR={}", bundle_root.display());
}

fn copy_dir_recursive(src: &Path, dest: &Path) {
    for entry in std::fs::read_dir(src).unwrap().flatten() {
        let name = entry.file_name();
        if name == "__pycache__" {
            continue;
        }
        let path = entry.path();
        let target = dest.join(&name);
        if path.is_dir() {
            std::fs::create_dir_all(&target).unwrap();
            copy_dir_recursive(&path, &target);
        } else {
            std::fs::copy(&path, &target).unwrap_or_else(|e| {
                panic!(
                    "Failed to copy {} -> {}: {e}",
                    path.display(),
                    target.display()
                )
            });
        }
    }
}

/// Resolve target/<profile>/ from OUT_DIR.
fn resolve_target_dir() -> PathBuf {
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let mut dir = out_dir.as_path();
    loop {
        if dir.file_name().is_some_and(|n| n == "build") {
            return dir.parent().unwrap().to_path_buf();
        }
        dir = dir.parent().unwrap_or_else(|| {
            panic!(
                "Could not resolve target dir from OUT_DIR: {}",
                out_dir.display()
            )
        });
    }
}
