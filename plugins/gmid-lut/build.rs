//! Build the vendored GmIDVisualizer `gmid_runner` CLI so the plugin works
//! straight from `cargo build` — no separate cmake/nix step required.
//!
//! Compiles main.cpp + src/**/*.cpp with the first C++ compiler found
//! ($CXX, c++, clang++, g++) into OUT_DIR and exposes the path to the
//! crate via the GMID_RUNNER_BUILT compile-time env var. If no compiler
//! is available the build still succeeds (warning only) — runner.rs then
//! falls back to $GMID_RUNNER or the in-tree cmake build.

use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("GmIDVisualizer");
    println!("cargo:rerun-if-changed={}", root.join("main.cpp").display());
    println!("cargo:rerun-if-changed={}", root.join("src").display());
    println!("cargo:rerun-if-changed={}", root.join("include").display());
    println!("cargo:rerun-if-env-changed=CXX");

    let Some(cxx) = find_cxx() else {
        println!(
            "cargo:warning=no C++ compiler found (set $CXX); gmid_runner not built — \
             plugin will use $GMID_RUNNER or GmIDVisualizer/build/gmid_runner"
        );
        return;
    };

    let mut sources = vec![root.join("main.cpp")];
    collect_cpp(&root.join("src"), &mut sources);
    sources.sort();

    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("gmid_runner");
    let status = Command::new(&cxx)
        .args(["-std=c++23", "-O2", "-fno-rtti", "-Wall", "-Wextra"])
        .arg("-I")
        .arg(root.join("include"))
        .args(&sources)
        .arg("-o")
        .arg(&out)
        .status();

    match status {
        Ok(s) if s.success() => {
            println!("cargo:rustc-env=GMID_RUNNER_BUILT={}", out.display());
        }
        Ok(s) => panic!("{cxx} failed building gmid_runner (exit {s})"),
        Err(e) => panic!("failed to spawn {cxx}: {e}"),
    }
}

/// First working C++ compiler: $CXX, then the usual suspects.
fn find_cxx() -> Option<String> {
    let candidates = std::env::var("CXX")
        .into_iter()
        .chain(["c++", "clang++", "g++"].map(String::from));
    candidates.into_iter().find(|c| {
        Command::new(c)
            .arg("--version")
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    })
}

/// Recursively collect .cpp files under `dir`.
fn collect_cpp(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_cpp(&path, out);
        } else if path.extension().is_some_and(|e| e == "cpp") {
            out.push(path);
        }
    }
}
