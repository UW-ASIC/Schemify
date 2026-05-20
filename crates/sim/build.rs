use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

const PYSPICE_REPO: &str = "https://github.com/OmarSiwy/PySpice.git";

fn main() {
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let pyspice_dir = out_dir.join("PySpice");

    // Clone or update repo
    if !pyspice_dir.join(".git").exists() {
        let status = Command::new("git")
            .args(["clone", "--depth", "1", PYSPICE_REPO, pyspice_dir.to_str().unwrap()])
            .status()
            .unwrap_or_else(|e| panic!("Failed to clone PySpice: {e}"));
        assert!(status.success(), "git clone failed");
    } else {
        let status = Command::new("git")
            .args(["pull", "--ff-only"])
            .current_dir(&pyspice_dir)
            .status()
            .unwrap_or_else(|e| panic!("Failed to update PySpice: {e}"));
        if !status.success() {
            eprintln!("Warning: git pull failed, using existing checkout");
        }
    }

    // Try to find an already-built result (nix build output or manual)
    let site_packages = find_existing_build(&pyspice_dir)
        .unwrap_or_else(|| build_with_nix(&pyspice_dir));

    let module_src = site_packages.join("pyspice_rs");
    assert!(
        module_src.exists(),
        "pyspice_rs module not found in {}",
        site_packages.display()
    );

    // Copy the module next to the binary
    let target_dir = resolve_target_dir();
    let bundle_dir = target_dir.join("pyspice_rs");

    // Clean and recreate
    let _ = std::fs::remove_dir_all(&bundle_dir);
    std::fs::create_dir_all(&bundle_dir).unwrap();
    copy_dir_recursive(&module_src, &bundle_dir);

    println!("cargo:rerun-if-changed=build.rs");
    println!(
        "cargo:rustc-env=PYSPICE_MODULE_DIR={}",
        bundle_dir.display()
    );
}

/// Check for an existing `result` symlink from a previous `nix build`.
fn find_existing_build(pyspice_dir: &Path) -> Option<PathBuf> {
    let result_link = pyspice_dir.join("result");
    if !result_link.exists() {
        return None;
    }

    // Walk lib/python*/site-packages/
    let lib = result_link.join("lib");
    if let Ok(entries) = std::fs::read_dir(&lib) {
        for entry in entries.flatten() {
            let sp = entry.path().join("site-packages");
            if sp.join("pyspice_rs").exists() {
                return Some(sp);
            }
        }
    }
    None
}

/// Build PySpice via `nix build` and return the site-packages path.
fn build_with_nix(pyspice_dir: &Path) -> PathBuf {
    eprintln!("Building PySpice via `nix build`...");

    let status = Command::new("nix")
        .args(["build", "--no-link", "--print-out-paths"])
        .current_dir(pyspice_dir)
        .output()
        .unwrap_or_else(|e| panic!("Failed to run `nix build` in {}: {e}", pyspice_dir.display()));

    if !status.status.success() {
        let stderr = String::from_utf8_lossy(&status.stderr);
        panic!("nix build failed:\n{stderr}");
    }

    let store_path = String::from_utf8(status.stdout)
        .unwrap()
        .trim()
        .to_string();

    let store = PathBuf::from(&store_path);
    let lib = store.join("lib");
    if let Ok(entries) = std::fs::read_dir(&lib) {
        for entry in entries.flatten() {
            let sp = entry.path().join("site-packages");
            if sp.join("pyspice_rs").exists() {
                return sp;
            }
        }
    }

    panic!(
        "Could not find pyspice_rs in nix build output: {}",
        store_path
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
