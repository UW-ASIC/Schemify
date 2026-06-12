//! ngspice batch driver: per-device operating-point extraction via
//! `print @m.x<refdes>.<m_internal>[param]` lines, plus the subcircuit
//! internal-name resolver (never hardcode PDK internals).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Per-device operating point (absolute values, not per-µm).
#[allow(dead_code)] // full op record; verification reads the bias fields
#[derive(Debug, Clone, Default)]
pub struct DeviceOp {
    pub id: f64,
    pub gm: f64,
    pub gds: f64,
    pub vgs: f64,
    pub vds: f64,
    pub vbs: f64,
    pub vth: f64,
    pub vdsat: f64,
}

pub const OP_PARAMS: [&str; 8] = ["id", "gm", "gds", "vgs", "vds", "vbs", "vth", "vdsat"];

/// One MOS device to probe.
#[derive(Debug, Clone)]
pub struct Probe {
    /// Schematic instance index.
    pub idx: usize,
    /// SPICE element name in the netlist (e.g. "XM1" or "M1").
    pub refdes: String,
    /// PDK model/subckt name.
    pub model: String,
    /// X-card (subcircuit) device → needs the internal M name.
    pub subckt: bool,
}

/// Find the internal M-card name of `.subckt <model>` by scanning PDK model
/// text. Searches `lib_path` first, then `*.spice`/`*.ngspice` files under
/// `root` (bounded). Returns e.g. "msky130_fd_pr__nfet_01v8".
pub fn subckt_internal_name(root: &Path, lib_path: Option<&Path>, model: &str) -> Option<String> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(lib) = lib_path {
        candidates.push(lib.to_path_buf());
    }
    collect_spice_files(root, &mut candidates, 0);

    for path in candidates {
        let Ok(content) = std::fs::read_to_string(&path) else {
            continue;
        };
        if let Some(name) = internal_name_in(&content, model) {
            return Some(name);
        }
    }
    None
}

fn collect_spice_files(dir: &Path, out: &mut Vec<PathBuf>, depth: usize) {
    if depth > 6 || out.len() > 4096 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_spice_files(&path, out, depth + 1);
        } else if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            if matches!(ext, "spice" | "ngspice" | "lib" | "mod" | "pm3") {
                out.push(path);
            }
        }
    }
}

/// Scan one file's text for `.subckt <model> ...` and return the first
/// M-card token inside the block.
pub fn internal_name_in(content: &str, model: &str) -> Option<String> {
    let mut in_block = false;
    for line in content.lines() {
        let trimmed = line.trim();
        let lower = trimmed.to_ascii_lowercase();
        if !in_block {
            if let Some(rest) = lower.strip_prefix(".subckt") {
                let mut it = rest.split_whitespace();
                if it.next() == Some(&model.to_ascii_lowercase()) {
                    in_block = true;
                }
            }
        } else {
            if lower.starts_with(".ends") {
                in_block = false;
                continue;
            }
            if (trimmed.starts_with('m') || trimmed.starts_with('M')) && !trimmed.starts_with(".")
            {
                return trimmed.split_whitespace().next().map(str::to_owned);
            }
        }
    }
    None
}

/// ngspice OP vector path for one probe.
pub fn vector_path(probe: &Probe, internal: Option<&str>, param: &str) -> String {
    let refdes = probe.refdes.to_ascii_lowercase();
    if probe.subckt {
        let internal = internal.unwrap_or("m0").to_ascii_lowercase();
        format!("@m.{refdes}.{internal}[{param}]")
    } else {
        format!("@{refdes}[{param}]")
    }
}

/// Run an `.op` on `netlist`, printing every probe parameter, and parse the
/// results. `internals` maps model → internal M name (subckt devices).
pub fn run_op(
    netlist: &str,
    probes: &[Probe],
    internals: &HashMap<String, String>,
    work_dir: &Path,
) -> Result<HashMap<usize, DeviceOp>, String> {
    std::fs::create_dir_all(work_dir).map_err(|e| e.to_string())?;
    let deck_path = work_dir.join("op_extract.sp");

    // Strip any pre-existing .control block / .end, then append ours.
    let mut deck = String::new();
    let mut in_control = false;
    for line in netlist.lines() {
        let lower = line.trim().to_ascii_lowercase();
        if lower.starts_with(".control") {
            in_control = true;
            continue;
        }
        if in_control {
            if lower.starts_with(".endc") {
                in_control = false;
            }
            continue;
        }
        if lower == ".end" {
            continue;
        }
        deck.push_str(line);
        deck.push('\n');
    }
    deck.push_str(".control\nop\n");
    for probe in probes {
        let internal = internals.get(&probe.model).map(String::as_str);
        for param in OP_PARAMS {
            deck.push_str(&format!(
                "print {}\n",
                vector_path(probe, internal, param)
            ));
        }
    }
    deck.push_str("quit\n.endc\n.end\n");
    std::fs::write(&deck_path, &deck).map_err(|e| e.to_string())?;

    let output = Command::new("ngspice")
        .arg("-b")
        .arg(&deck_path)
        .current_dir(work_dir)
        .output()
        .map_err(|e| format!("spawn ngspice: {e}"))?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    // Parse `@m.xm1.msky...[gm] = 1.234e-05` lines.
    let mut values: HashMap<String, f64> = HashMap::new();
    for line in stdout.lines() {
        let Some((lhs, rhs)) = line.split_once('=') else {
            continue;
        };
        let key = lhs.trim().to_ascii_lowercase();
        if !key.starts_with('@') {
            continue;
        }
        if let Ok(v) = rhs.trim().parse::<f64>() {
            values.insert(key, v);
        }
    }

    let mut ops = HashMap::new();
    for probe in probes {
        let internal = internals.get(&probe.model).map(String::as_str);
        let get = |param: &str| -> f64 {
            values
                .get(&vector_path(probe, internal, param).to_ascii_lowercase())
                .copied()
                .unwrap_or(0.0)
        };
        let op = DeviceOp {
            id: get("id"),
            gm: get("gm"),
            gds: get("gds"),
            vgs: get("vgs"),
            vds: get("vds"),
            vbs: get("vbs"),
            vth: get("vth"),
            vdsat: get("vdsat"),
        };
        if op.gm == 0.0 && op.id == 0.0 {
            // Probe failed: surface ngspice's complaint for diagnosis.
            let hint = stderr
                .lines()
                .chain(stdout.lines())
                .find(|l| l.to_ascii_lowercase().contains("error"))
                .unwrap_or("no vector returned");
            return Err(format!(
                "op extraction failed for {} ({}): {hint}",
                probe.refdes, probe.model
            ));
        }
        ops.insert(probe.idx, op);
    }
    Ok(ops)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_internal_m_card() {
        let lib = "\
* models\n\
.subckt sky130_fd_pr__nfet_01v8 d g s b\n\
+ params: w=1 l=0.15\n\
msky130_fd_pr__nfet_01v8 d g s b sky130_fd_pr__nfet_01v8__model w={w} l={l}\n\
.ends\n";
        assert_eq!(
            internal_name_in(lib, "sky130_fd_pr__nfet_01v8").as_deref(),
            Some("msky130_fd_pr__nfet_01v8")
        );
        assert!(internal_name_in(lib, "other_model").is_none());
    }

    #[test]
    fn vector_paths() {
        let sub = Probe {
            idx: 0,
            refdes: "XM1".into(),
            model: "nfet_03v3".into(),
            subckt: true,
        };
        assert_eq!(
            vector_path(&sub, Some("M_nfet"), "gm"),
            "@m.xm1.m_nfet[gm]"
        );
        let flat = Probe {
            idx: 1,
            refdes: "M2".into(),
            model: "nmos".into(),
            subckt: false,
        };
        assert_eq!(vector_path(&flat, None, "id"), "@m2[id]");
    }
}
