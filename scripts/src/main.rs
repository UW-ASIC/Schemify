use std::path::{Path, PathBuf};
use std::process::{self, Command};
use std::{env, fs};

fn project_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf()
}

fn main() {
    let args: Vec<String> = env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("gen-examples") => gen_examples(),
        _ => {
            eprintln!("usage: cargo xtask gen-examples");
            process::exit(1);
        }
    }
}

fn gen_examples() {
    let root = project_root();
    let pyspice_dir = root.join("examples/pyspice");
    let out_dir = root.join("examples");
    let schemify_bin = find_schemify(&root);

    let mut imported = 0u32;
    let mut failed = 0u32;

    let categories: &[(&str, &[&str], &str)] = &[
        ("component", &["basic", "mosfet", "bjt", "opamp", "digital", "power", "mixed_signal", "bus"], ".chn"),
        ("testbench", &["testbench"], ".chn_tb"),
    ];

    for (kind, dirs, _ext) in categories {
        for dir_name in *dirs {
            let dir = pyspice_dir.join(dir_name);
            if !dir.is_dir() {
                continue;
            }
            let mut py_files: Vec<_> = fs::read_dir(&dir)
                .unwrap()
                .flatten()
                .filter(|e| {
                    e.path().extension().map_or(false, |ext| ext == "py")
                        && !e.file_name().to_string_lossy().starts_with("__")
                })
                .collect();
            py_files.sort_by_key(|e| e.file_name());

            for entry in &py_files {
                let py_path = entry.path();
                let rel = py_path.strip_prefix(&pyspice_dir).unwrap();
                print!("  {:<50} ", rel.display());

                let output = Command::new(&schemify_bin)
                    .args(["import-spice", "--import", "-o"])
                    .arg(&out_dir)
                    .arg(&py_path)
                    .arg(kind)
                    .output();

                match output {
                    Ok(o) if o.status.success() => {
                        println!("OK");
                        imported += 1;
                    }
                    Ok(o) => {
                        println!("FAIL");
                        let stderr = String::from_utf8_lossy(&o.stderr);
                        if !stderr.is_empty() {
                            eprintln!("    {}", stderr.lines().next().unwrap_or(""));
                        }
                        failed += 1;
                    }
                    Err(e) => {
                        println!("FAIL ({e})");
                        failed += 1;
                    }
                }
            }
        }
    }

    println!("\nImported: {imported}  Failed: {failed}");
    if failed > 0 {
        process::exit(1);
    }
}

fn find_schemify(root: &Path) -> PathBuf {
    // Check env override
    if let Ok(p) = env::var("SCHEMIFY") {
        return PathBuf::from(p);
    }
    // Check target/debug and target/release
    for profile in ["release", "debug"] {
        let p = root.join(format!("target/{profile}/schemify"));
        if p.exists() {
            return p;
        }
    }
    // Check PATH
    if Command::new("schemify").arg("--help").output().is_ok() {
        return PathBuf::from("schemify");
    }
    eprintln!("error: schemify binary not found.");
    eprintln!("  Build with: cargo build");
    eprintln!("  Or set SCHEMIFY=/path/to/schemify");
    process::exit(1);
}
