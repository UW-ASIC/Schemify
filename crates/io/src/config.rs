use std::path::PathBuf;

#[cfg(not(target_arch = "wasm32"))]
use std::fs;
#[cfg(not(target_arch = "wasm32"))]
use std::io;
#[cfg(not(target_arch = "wasm32"))]
use std::path::Path;

// ====================================================
// Project Configuration (parsed from Config.toml)
// ====================================================

#[derive(Debug, Clone, Default)]
pub struct ProjectConfig {
    pub name: String,
    pub pdk: Option<String>,
    pub paths: ProjectPaths,
    pub simulation: SimulationOptions,
    pub plugins: PluginOptions,
}

#[derive(Debug, Clone, Default)]
pub struct ProjectPaths {
    pub schematics: Vec<PathBuf>,
    pub primitives: Vec<PathBuf>,
    pub testbenches: Vec<PathBuf>,
}

#[derive(Debug, Clone, Default)]
pub struct SimulationOptions {
    pub spice_include_paths: Vec<PathBuf>,
}

#[derive(Debug, Clone, Default)]
pub struct PluginOptions {
    pub enabled: Vec<String>,
    pub disabled: Vec<String>,
}

// ====================================================
// Parser (minimal TOML subset, matches Zig impl)
// ====================================================

#[cfg(not(target_arch = "wasm32"))]
pub fn parse_from_path(project_dir: &Path) -> io::Result<ProjectConfig> {
    let path = project_dir.join("Config.toml");
    match fs::read_to_string(&path) {
        Ok(content) => {
            let mut config = parse_from_string(&content);
            expand_path_globs(&mut config, project_dir);
            Ok(config)
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(ProjectConfig::default()),
        Err(e) => Err(e),
    }
}

pub fn parse_from_string(content: &str) -> ProjectConfig {
    let mut config = ProjectConfig::default();
    let mut section = TomlSection::Root;
    let mut ml_key = String::new();
    let mut ml_buf = String::new();
    let mut in_ml = false;

    for raw in content.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        // Multiline array accumulation
        if in_ml {
            ml_buf.push_str(line);
            if line.contains(']') {
                in_ml = false;
                dispatch_array(&mut config, section, &ml_key, &ml_buf);
                ml_buf.clear();
            }
            continue;
        }

        // Section header
        if line.starts_with('[') {
            if let Some(end) = line.find(']') {
                let name = line[1..end].trim();
                section = match name {
                    "paths" => TomlSection::Paths,
                    "simulation" => TomlSection::Simulation,
                    "plugins" => TomlSection::Plugins,
                    "pdk_switcher" => TomlSection::PdkSwitcher,
                    _ => TomlSection::Root,
                };
            }
            continue;
        }

        // Key = Value
        let Some(eq) = line.find('=') else { continue };
        let key = line[..eq].trim();
        let val = line[eq + 1..].trim();

        // Multiline array start
        if val.starts_with('[') && !val.contains(']') {
            ml_key = key.to_string();
            ml_buf = val.to_string();
            in_ml = true;
            continue;
        }

        match section {
            TomlSection::Root => {
                if key == "name" {
                    config.name = parse_str(val);
                } else if key == "pdk" {
                    config.pdk = Some(parse_str(val));
                }
            }
            TomlSection::Paths => {
                let arr = parse_str_array(val);
                let paths: Vec<PathBuf> = arr.into_iter().map(PathBuf::from).collect();
                match key {
                    "chn" => config.paths.schematics = paths,
                    "chn_tb" => config.paths.testbenches = paths,
                    "chn_prim" => config.paths.primitives = paths,
                    _ => {}
                }
            }
            TomlSection::Simulation => {
                if key == "spice_include_paths" {
                    config.simulation.spice_include_paths = parse_str_array(val)
                        .into_iter()
                        .map(PathBuf::from)
                        .collect();
                }
            }
            TomlSection::Plugins => {
                if key == "enabled" {
                    config.plugins.enabled = parse_str_array(val);
                } else if key == "disabled" {
                    config.plugins.disabled = parse_str_array(val);
                }
            }
            TomlSection::PdkSwitcher => {
                if key == "active" {
                    config.pdk = Some(parse_str(val));
                }
            }
        }
    }

    config
}

// ====================================================
// TOML Value Parsers
// ====================================================

#[derive(Clone, Copy)]
enum TomlSection {
    Root,
    Paths,
    Simulation,
    Plugins,
    PdkSwitcher,
}

fn parse_str(val: &str) -> String {
    if val.len() >= 2 && val.starts_with('"') && val.ends_with('"') {
        val[1..val.len() - 1].to_string()
    } else {
        val.to_string()
    }
}

fn parse_str_array(val: &str) -> Vec<String> {
    let trimmed = val.trim();
    if !trimmed.starts_with('[') {
        return Vec::new();
    }
    let inner = trimmed.trim_start_matches('[').trim_end_matches(']').trim();
    let mut result = Vec::new();
    let mut i = 0;
    let bytes = inner.as_bytes();
    while i < bytes.len() {
        if bytes[i] == b'"' {
            if let Some(end) = inner[i + 1..].find('"') {
                result.push(inner[i + 1..i + 1 + end].to_string());
                i = i + 1 + end + 1;
            } else {
                break;
            }
        } else {
            i += 1;
        }
    }
    result
}

fn dispatch_array(config: &mut ProjectConfig, section: TomlSection, key: &str, val: &str) {
    let arr = parse_str_array(val);
    match section {
        TomlSection::Paths => {
            let paths: Vec<PathBuf> = arr.into_iter().map(PathBuf::from).collect();
            match key {
                "chn" => config.paths.schematics = paths,
                "chn_tb" => config.paths.testbenches = paths,
                "chn_prim" => config.paths.primitives = paths,
                _ => {}
            }
        }
        TomlSection::Simulation => {
            if key == "spice_include_paths" {
                config.simulation.spice_include_paths =
                    arr.into_iter().map(PathBuf::from).collect();
            }
        }
        TomlSection::Plugins => {
            if key == "enabled" {
                config.plugins.enabled = arr;
            } else if key == "disabled" {
                config.plugins.disabled = arr;
            }
        }
        _ => {}
    }
}

// ====================================================
// Glob Expansion (recursive directory walk)
// ====================================================

#[cfg(not(target_arch = "wasm32"))]
fn expand_path_globs(config: &mut ProjectConfig, project_dir: &Path) {
    config.paths.schematics = expand_globs(project_dir, &config.paths.schematics, ".chn");
    config.paths.testbenches = expand_globs(project_dir, &config.paths.testbenches, ".chn_tb");
    config.paths.primitives = expand_globs(project_dir, &config.paths.primitives, ".chn_prim");
}

#[cfg(not(target_arch = "wasm32"))]
fn expand_globs(project_dir: &Path, raw: &[PathBuf], ext: &str) -> Vec<PathBuf> {
    let mut result = Vec::new();
    for p in raw {
        let p_str = p.to_string_lossy();
        if p_str.contains('*') {
            // Extract directory before the wildcard
            let star = p_str.find('*').unwrap();
            let dir_part = &p_str[..star].trim_end_matches('/');
            let abs_dir = if dir_part.is_empty() {
                project_dir.to_path_buf()
            } else if Path::new(dir_part).is_absolute() {
                PathBuf::from(dir_part)
            } else {
                project_dir.join(dir_part)
            };
            walk_dir(&abs_dir, dir_part, ext, &mut result);
        } else {
            result.push(p.clone());
        }
    }
    result
}

#[cfg(not(target_arch = "wasm32"))]
fn walk_dir(abs_dir: &Path, rel_prefix: &str, ext: &str, out: &mut Vec<PathBuf>) {
    let entries = match fs::read_dir(abs_dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let ft = match entry.file_type() {
            Ok(ft) => ft,
            Err(_) => continue,
        };
        let name = entry.file_name();
        let name_str = name.to_string_lossy();

        if ft.is_dir() {
            let sub_abs = abs_dir.join(&*name_str);
            let sub_rel = if rel_prefix.is_empty() {
                name_str.to_string()
            } else {
                format!("{rel_prefix}/{name_str}")
            };
            walk_dir(&sub_abs, &sub_rel, ext, out);
            continue;
        }

        if !matches_ext(&name_str, ext) {
            continue;
        }

        let rel = if rel_prefix.is_empty() {
            PathBuf::from(&*name_str)
        } else {
            PathBuf::from(format!("{rel_prefix}/{name_str}"))
        };
        out.push(rel);
    }
}

#[cfg(not(target_arch = "wasm32"))]
fn matches_ext(name: &str, ext: &str) -> bool {
    if !name.ends_with(ext) {
        return false;
    }
    // .chn globs should NOT match .chn_tb or .chn_prim
    if ext == ".chn" {
        return !name.ends_with(".chn_tb") && !name.ends_with(".chn_prim");
    }
    true
}
