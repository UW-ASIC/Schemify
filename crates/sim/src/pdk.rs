//! PDK manifest (schemify-pdk.toml) loading and device mapping.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;

// ====================================================
// PDK manifest (schemify-pdk.toml)
// ====================================================
//
// A PDK is described by a `schemify-pdk.toml` manifest in its root
// directory; the manifest is the single code path that makes any PDK
// (open-source or commercial) work — no per-vendor directory walkers.
// Built-in manifests for the open_pdks distributions (sky130, gf180mcu)
// are embedded so those work with zero setup beyond `$PDK_ROOT`.
//
// Discovery order for the PDK root directory:
//   1. `pdk_path` in Config.toml (explicit, wins)
//   2. `$PDK_ROOT/<name>/` (open_pdks convention)

#[derive(Debug, Clone, Deserialize)]
pub struct PdkManifest {
    pub name: String,
    #[serde(default)]
    pub models: ModelsSection,
    /// Keyed by schemify primitive name ("nmos4", "res", ...).
    #[serde(default)]
    pub devices: HashMap<String, DeviceEntry>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct ModelsSection {
    /// Corner-sectioned .lib file, relative to the PDK root.
    pub lib: Option<PathBuf>,
    #[serde(default)]
    pub corners: Vec<String>,
    pub default_corner: Option<String>,
    /// Plain `.include` files, relative to the PDK root.
    #[serde(default)]
    pub include: Vec<PathBuf>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct DeviceEntry {
    /// PDK model/subcircuit name the primitive maps to.
    pub model: String,
    /// SPICE prefix; PDK devices are usually subcircuits ('X').
    pub prefix: Option<char>,
    #[serde(default)]
    pub pin_order: Vec<String>,
    /// Default parameters merged into instances that don't set them.
    #[serde(default)]
    pub params: HashMap<String, String>,
}

/// One device cell mapping, resolved from a manifest entry.
#[derive(Debug, Clone)]
pub struct PdkCell {
    pub model: String,
    pub prefix: char,
    pub pin_order: Vec<String>,
    /// Sorted for deterministic netlist output.
    pub default_params: Vec<(String, String)>,
}

/// A PDK resolved against the filesystem, ready for netlist injection.
/// Cells stay keyed by primitive name string; mapping a `DeviceKind` to
/// its cell is the caller's one-line lookup.
#[derive(Debug, Clone, Default)]
pub struct LoadedPdk {
    pub name: String,
    pub root: PathBuf,
    /// Absolute path of the corner-sectioned .lib file, if any.
    pub lib_path: Option<PathBuf>,
    pub corners: Vec<String>,
    pub default_corner: String,
    /// Absolute paths of plain includes.
    pub includes: Vec<PathBuf>,
    /// Keyed by schemify primitive name ("nmos4", "res", ...).
    pub cells: HashMap<String, PdkCell>,
}

impl LoadedPdk {
    /// Cell mapping for a primitive name ("nmos4", "res", ...).
    pub fn cell(&self, primitive: &str) -> Option<&PdkCell> {
        self.cells.get(primitive)
    }
}

#[derive(thiserror::Error, Debug)]
pub enum PdkError {
    #[error("PDK '{0}' not found (no pdk_path in Config.toml and no $PDK_ROOT/{0})")]
    NotFound(String),
    #[error("no schemify-pdk.toml in {0} and no built-in manifest for '{1}'")]
    NoManifest(PathBuf, String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error("manifest parse error: {0}")]
    Parse(#[from] toml::de::Error),
}

/// Locate the PDK root: explicit `pdk_path` wins, else `$PDK_ROOT/<name>`.
pub fn find_pdk_dir(name: &str, explicit: Option<&Path>) -> Option<PathBuf> {
    if let Some(p) = explicit {
        if p.is_dir() {
            return Some(p.to_path_buf());
        }
    }
    let root = std::env::var_os("PDK_ROOT")?;
    let dir = PathBuf::from(root).join(name);
    dir.is_dir().then_some(dir)
}

/// Load a PDK by name. Manifest resolution: `<pdk_root>/schemify-pdk.toml`,
/// falling back to the embedded built-in for known PDK names.
pub fn load_pdk(name: &str, explicit_path: Option<&Path>) -> Result<LoadedPdk, PdkError> {
    let root =
        find_pdk_dir(name, explicit_path).ok_or_else(|| PdkError::NotFound(name.to_string()))?;
    let manifest_path = root.join("schemify-pdk.toml");
    let manifest: PdkManifest = if manifest_path.is_file() {
        toml::from_str(&std::fs::read_to_string(&manifest_path)?)?
    } else if let Some(builtin) = builtin_manifest(name) {
        toml::from_str(builtin)?
    } else {
        return Err(PdkError::NoManifest(root, name.to_string()));
    };
    Ok(resolve_pdk(manifest, root))
}

fn resolve_pdk(m: PdkManifest, root: PathBuf) -> LoadedPdk {
    let lib_path = m.models.lib.as_ref().map(|p| root.join(p));

    let mut cells = HashMap::with_capacity(m.devices.len());
    for (key, dev) in m.devices {
        let mut default_params: Vec<(String, String)> = dev.params.into_iter().collect();
        default_params.sort();
        cells.insert(
            key,
            PdkCell {
                model: dev.model,
                prefix: dev.prefix.unwrap_or('X'),
                pin_order: dev.pin_order,
                default_params,
            },
        );
    }

    let default_corner = m
        .models
        .default_corner
        .or_else(|| m.models.corners.first().cloned())
        .unwrap_or_default();

    LoadedPdk {
        name: m.name,
        includes: m.models.include.iter().map(|p| root.join(p)).collect(),
        corners: m.models.corners,
        default_corner,
        lib_path,
        root,
        cells,
    }
}

// ====================================================
// Built-in manifests (open_pdks layouts) => For Testing
// ====================================================

fn builtin_manifest(name: &str) -> Option<&'static str> {
    match name {
        n if n.starts_with("sky130") => Some(SKY130),
        n if n.starts_with("gf180mcu") => Some(GF180MCU),
        n if n.starts_with("ihp-sg13g2") => Some(IHP_SG13G2),
        _ => None,
    }
}

const SKY130: &str = r#"
name = "sky130A"

[models]
lib = "libs.tech/ngspice/sky130.lib.spice"
corners = ["tt", "ss", "ff", "sf", "fs"]
default_corner = "tt"

[devices]
nmos4 = { model = "sky130_fd_pr__nfet_01v8", prefix = "X", pin_order = ["d", "g", "s", "b"], params = { L = "0.15", W = "1", nf = "1" } }
pmos4 = { model = "sky130_fd_pr__pfet_01v8", prefix = "X", pin_order = ["d", "g", "s", "b"], params = { L = "0.15", W = "1", nf = "1" } }
nmoshv4 = { model = "sky130_fd_pr__nfet_g5v0d10v5", prefix = "X", pin_order = ["d", "g", "s", "b"] }
pmoshv4 = { model = "sky130_fd_pr__pfet_g5v0d10v5", prefix = "X", pin_order = ["d", "g", "s", "b"] }
res = { model = "sky130_fd_pr__res_generic_po", prefix = "X" }
capacitor = { model = "sky130_fd_pr__cap_mim_m3_1", prefix = "X" }
diode = { model = "sky130_fd_pr__diode_pw2nd_05v5", prefix = "X" }
npn = { model = "sky130_fd_pr__npn_05v5_W1p00L1p00", prefix = "X" }
pnp = { model = "sky130_fd_pr__pnp_05v5_W0p68L0p68", prefix = "X" }
"#;

const GF180MCU: &str = r#"
name = "gf180mcuD"

[models]
lib = "libs.tech/ngspice/sm141064.ngspice"
corners = ["typical", "ff", "ss", "fs", "sf"]
default_corner = "typical"

[devices]
nmos4 = { model = "nfet_03v3", prefix = "X", pin_order = ["d", "g", "s", "b"], params = { L = "0.28", W = "0.22" } }
pmos4 = { model = "pfet_03v3", prefix = "X", pin_order = ["d", "g", "s", "b"], params = { L = "0.28", W = "0.22" } }
nmoshv4 = { model = "nfet_06v0", prefix = "X", pin_order = ["d", "g", "s", "b"] }
pmoshv4 = { model = "pfet_06v0", prefix = "X", pin_order = ["d", "g", "s", "b"] }
res = { model = "rplus_u", prefix = "X" }
capacitor = { model = "cap_mim_2f0fF", prefix = "X" }
diode = { model = "diode_nd2ps_03v3", prefix = "X" }
"#;

// Keep in sync with plugins/pdk-switcher/manifests/ihp-sg13g2.toml and
// plugins/pdk-mapper/manifests/ihp-sg13g2.toml.
const IHP_SG13G2: &str = r#"
name = "ihp-sg13g2"

[models]
lib = "libs.tech/ngspice/models/cornerMOSlv.lib"
corners = ["mos_tt", "mos_ss", "mos_ff", "mos_sf", "mos_fs"]
default_corner = "mos_tt"

[devices]
nmos4 = { model = "sg13_lv_nmos", prefix = "X", pin_order = ["d", "g", "s", "b"], params = { L = "0.45", W = "1.0" } }
pmos4 = { model = "sg13_lv_pmos", prefix = "X", pin_order = ["d", "g", "s", "b"], params = { L = "0.45", W = "1.0" } }
nmoshv4 = { model = "sg13_hv_nmos", prefix = "X", pin_order = ["d", "g", "s", "b"] }
pmoshv4 = { model = "sg13_hv_pmos", prefix = "X", pin_order = ["d", "g", "s", "b"] }
npn = { model = "npn13G2", prefix = "X" }
"#;


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builtin_sky130_parses_and_resolves() {
        let m: PdkManifest = toml::from_str(SKY130).expect("sky130 manifest parses");
        let loaded = resolve_pdk(m, PathBuf::from("/pdk/sky130A"));
        assert_eq!(loaded.name, "sky130A");
        assert_eq!(loaded.default_corner, "tt");
        assert_eq!(loaded.corners.len(), 5);
        assert_eq!(
            loaded.lib_path.as_deref(),
            Some(Path::new("/pdk/sky130A/libs.tech/ngspice/sky130.lib.spice"))
        );

        let nmos = loaded.cell("nmos4").expect("nmos4 cell");
        assert_eq!(nmos.model, "sky130_fd_pr__nfet_01v8");
        assert_eq!(nmos.prefix, 'X');
        assert_eq!(nmos.pin_order, ["d", "g", "s", "b"]);
        // Params sorted for deterministic output
        assert_eq!(
            nmos.default_params,
            [
                ("L".to_string(), "0.15".to_string()),
                ("W".to_string(), "1".to_string()),
                ("nf".to_string(), "1".to_string()),
            ]
        );
    }

    #[test]
    fn builtin_gf180_parses() {
        let m: PdkManifest = toml::from_str(GF180MCU).expect("gf180 manifest parses");
        let loaded = resolve_pdk(m, PathBuf::from("/pdk/gf180mcuD"));
        assert_eq!(loaded.default_corner, "typical");
        assert!(loaded.cell("pmos4").is_some());
    }

    #[test]
    fn builtin_lookup_covers_variants() {
        assert!(builtin_manifest("sky130A").is_some());
        assert!(builtin_manifest("sky130B").is_some());
        assert!(builtin_manifest("gf180mcuC").is_some());
        assert!(builtin_manifest("ihp-sg13g2").is_some());
        assert!(builtin_manifest("tsmc28").is_none());
    }

    #[test]
    fn builtin_ihp_parses() {
        let m: PdkManifest = toml::from_str(IHP_SG13G2).expect("ihp manifest parses");
        let loaded = resolve_pdk(m, PathBuf::from("/pdk/ihp-sg13g2"));
        assert_eq!(loaded.default_corner, "mos_tt");
        assert_eq!(loaded.corners.len(), 5);
        assert!(loaded.cell("nmos4").is_some());
        assert!(loaded.cell("npn").is_some());
    }

    #[test]
    fn custom_manifest_roundtrip() {
        let src = r#"
name = "acme90"

[models]
lib = "models/acme.lib"
corners = ["tt", "ss"]
include = ["models/extra.spice"]

[devices]
nmos4 = { model = "acme_nch", prefix = "M", params = { L = "0.09" } }
"#;
        let m: PdkManifest = toml::from_str(src).expect("custom manifest parses");
        let loaded = resolve_pdk(m, PathBuf::from("/foundry/acme90"));
        // No default_corner -> first corner
        assert_eq!(loaded.default_corner, "tt");
        assert_eq!(
            loaded.includes,
            [PathBuf::from("/foundry/acme90/models/extra.spice")]
        );
        let cell = loaded.cell("nmos4").expect("mapped");
        assert_eq!(cell.prefix, 'M');
    }
}
