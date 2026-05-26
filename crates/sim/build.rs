use std::env;
use std::path::{Path, PathBuf};

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=PYSPICE_MODULE_DIR");

    // If PYSPICE_MODULE_DIR is set and contains pyspice_rs, bundle it.
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
        // PySpice not available — compile without it.
        println!("cargo:rustc-cfg=no_pyspice");
        return;
    };

    let module_src = module_src.join("pyspice_rs");
    let target_dir = resolve_target_dir();
    let bundle_dir = target_dir.join("pyspice_rs");

    let _ = std::fs::remove_dir_all(&bundle_dir);
    std::fs::create_dir_all(&bundle_dir).unwrap();
    copy_dir_recursive(&module_src, &bundle_dir);

    println!(
        "cargo:rustc-env=PYSPICE_BUNDLE_DIR={}",
        bundle_dir.display()
    );
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
