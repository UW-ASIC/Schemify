//! Fetch + cache the tinted-theming scheme registry.
//!
//! One HTTP GET of the repo tarball, extracted to a local cache of small
//! YAML files; every later run is fully offline until the user refreshes.

use std::io::Read;
use std::path::PathBuf;

/// One base16/base24 scheme. `palette[0..16]` are base00–base0F; base24
/// extras are ignored by the mapping.
#[derive(Debug, Clone)]
pub struct Scheme {
    pub slug: String,
    pub name: String,
    pub dark: bool,
    pub palette: Vec<[u8; 3]>,
}

/// `HEAD` resolves the repo's default branch (currently `spec-0.11`).
const TARBALL_URL: &str = "https://github.com/tinted-theming/schemes/archive/HEAD.tar.gz";

pub fn cache_dir() -> PathBuf {
    dirs::cache_dir()
        .unwrap_or_else(std::env::temp_dir)
        .join("schemify/cache/theme-registry/schemes")
}

/// Load schemes from cache; on a cold cache, download first.
pub fn ensure_schemes() -> Result<Vec<Scheme>, String> {
    let dir = cache_dir();
    let cached = load_dir(&dir);
    if !cached.is_empty() {
        return Ok(cached);
    }
    download(&dir)?;
    let schemes = load_dir(&dir);
    if schemes.is_empty() {
        return Err("registry downloaded but no schemes parsed".into());
    }
    Ok(schemes)
}

/// Wipe the cache and re-download.
pub fn refresh() -> Result<Vec<Scheme>, String> {
    let dir = cache_dir();
    let _ = std::fs::remove_dir_all(&dir);
    ensure_schemes()
}

fn download(dir: &std::path::Path) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;

    let mut response = ureq::get(TARBALL_URL)
        .call()
        .map_err(|e| format!("registry fetch failed: {e}"))?;
    let body = response
        .body_mut()
        .read_to_vec()
        .map_err(|e| format!("registry read failed: {e}"))?;

    let gz = flate2::read::GzDecoder::new(body.as_slice());
    let mut archive = tar::Archive::new(gz);
    for entry in archive.entries().map_err(|e| e.to_string())? {
        let mut entry = entry.map_err(|e| e.to_string())?;
        let path = entry.path().map_err(|e| e.to_string())?;
        // Entries look like `schemes-main/base16/<slug>.yaml`.
        let mut comps = path.components().skip(1);
        let (Some(kind), Some(file)) = (comps.next(), comps.next()) else {
            continue;
        };
        let kind = kind.as_os_str().to_string_lossy();
        if kind != "base16" && kind != "base24" {
            continue;
        }
        let file = file.as_os_str().to_string_lossy().to_string();
        if !file.ends_with(".yaml") && !file.ends_with(".yml") {
            continue;
        }
        let mut content = String::new();
        if entry.read_to_string(&mut content).is_err() {
            continue;
        }
        let _ = std::fs::write(dir.join(&file), content);
    }
    Ok(())
}

fn load_dir(dir: &std::path::Path) -> Vec<Scheme> {
    let mut schemes = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return schemes;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        let Ok(content) = std::fs::read_to_string(&path) else {
            continue;
        };
        if let Some(s) = parse_scheme(stem, &content) {
            schemes.push(s);
        }
    }
    schemes.sort_by(|a, b| a.slug.cmp(&b.slug));
    schemes
}

/// Hand parser for the flat tinted-theming scheme YAML:
/// `name: "..."`, `variant: dark|light`, `palette:` block of
/// `baseXX: "RRGGBB"` lines (optionally `#`-prefixed).
pub fn parse_scheme(slug: &str, content: &str) -> Option<Scheme> {
    let mut name = String::new();
    let mut variant = String::new();
    // base00..base17 (base24); fixed slots so order never depends on the file.
    let mut palette: [Option<[u8; 3]>; 24] = [None; 24];
    let mut in_palette = false;

    for raw in content.lines() {
        let line = raw.trim_end();
        if line.starts_with('#') || line.is_empty() {
            continue;
        }
        if !raw.starts_with(' ') && !raw.starts_with('\t') {
            in_palette = false;
        }
        let trimmed = line.trim();
        let Some((key, value)) = trimmed.split_once(':') else {
            continue;
        };
        let key = key.trim();
        let value = clean_value(value);
        match key {
            "name" | "scheme" if name.is_empty() => name = value.to_owned(),
            "variant" => variant = value.to_owned(),
            "palette" => in_palette = true,
            _ if in_palette || key.starts_with("base") => {
                if let Some(slot) = base_slot(key) {
                    palette[slot] = parse_hex(value);
                }
            }
            _ => {}
        }
    }

    // All 16 base16 slots required.
    let mut colors = Vec::with_capacity(16);
    for c in palette.iter().take(16) {
        colors.push((*c)?);
    }
    if name.is_empty() {
        name = slug.to_owned();
    }
    // Old-format files have no `variant`; guess from background luma.
    let dark = match variant.as_str() {
        "dark" => true,
        "light" => false,
        _ => {
            let [r, g, b] = colors[0];
            (r as u32 * 299 + g as u32 * 587 + b as u32 * 114) / 1000 < 128
        }
    };
    Some(Scheme {
        slug: slug.to_owned(),
        name,
        dark,
        palette: colors,
    })
}

/// Strip quotes and trailing inline comments: `"#1e1e2e" # base` → `#1e1e2e`.
fn clean_value(v: &str) -> &str {
    let v = v.trim();
    for quote in ['"', '\''] {
        if let Some(rest) = v.strip_prefix(quote) {
            if let Some(end) = rest.find(quote) {
                return &rest[..end];
            }
        }
    }
    v.split_whitespace().next().unwrap_or("")
}

/// `"base0A"` → 10; `"base10"`.. for base24 extras.
fn base_slot(key: &str) -> Option<usize> {
    let hex = key.strip_prefix("base")?;
    if hex.len() != 2 {
        return None;
    }
    usize::from_str_radix(hex, 16).ok().filter(|&n| n < 24)
}

fn parse_hex(value: &str) -> Option<[u8; 3]> {
    let hex = value.trim_start_matches('#');
    if hex.len() != 6 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let n = u32::from_str_radix(hex, 16).ok()?;
    Some([(n >> 16) as u8, (n >> 8) as u8, n as u8])
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r##"
system: "base16"
name: "Catppuccin Mocha"
author: "https://github.com/catppuccin/catppuccin"
variant: "dark"
palette:
  base00: "#1e1e2e" # base
  base01: "#181825" # mantle
  base02: "#313244" # surface0
  base03: "#45475a" # surface1
  base04: "#585b70" # surface2
  base05: "#cdd6f4" # text
  base06: "#f5e0dc" # rosewater
  base07: "#b4befe" # lavender
  base08: "#f38ba8" # red
  base09: "#fab387" # peach
  base0A: "#f9e2af" # yellow
  base0B: "#a6e3a1" # green
  base0C: "#94e2d5" # teal
  base0D: "#89b4fa" # blue
  base0E: "#cba6f7" # mauve
  base0F: "#f2cdcd" # flamingo
"##;

    #[test]
    fn parses_spec_011_scheme() {
        let s = parse_scheme("catppuccin-mocha", SAMPLE).unwrap();
        assert_eq!(s.name, "Catppuccin Mocha");
        assert!(s.dark);
        assert_eq!(s.palette[0], [0x1e, 0x1e, 0x2e]);
        assert_eq!(s.palette[0x0D], [0x89, 0xb4, 0xfa]);
    }

    #[test]
    fn missing_slot_rejected() {
        let broken = SAMPLE.replace("  base0F: \"#f2cdcd\" # flamingo\n", "");
        assert!(parse_scheme("x", &broken).is_none());
    }

    #[test]
    fn variant_guessed_from_luma() {
        let no_variant = SAMPLE.replace("variant: \"dark\"\n", "");
        assert!(parse_scheme("x", &no_variant).unwrap().dark);
    }
}
