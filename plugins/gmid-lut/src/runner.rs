//! Drive the vendored GmIDVisualizer CLI (`gmid_runner`) and assemble the
//! per-L CSV grids into a [`Lut`].

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::lut::{Lut, LutMeta};

pub const W_REF_UM: f64 = 10.0;

/// One characterization request.
#[derive(Debug, Clone)]
pub struct SweepRequest {
    pub pdk: String,
    pub device: String,
    pub model: String,
    /// X-card instantiation (PDK subcircuit devices).
    pub subckt: bool,
    /// Absolute path of the corner-sectioned .lib (wrapper deck input).
    pub lib_path: String,
    pub corner: String,
    pub vdd: f64,
    pub vsb: f64,
    pub temp_c: f64,
    pub l_um: Vec<f64>,
    pub vgs_steps: u32,
    pub vds_steps: u32,
}

/// Locate the gmid_runner binary: $GMID_RUNNER, then the copy compiled by
/// build.rs, then a manual in-tree cmake build (cwd = plugin dir per host
/// contract).
pub fn runner_bin() -> Result<PathBuf, String> {
    if let Ok(p) = std::env::var("GMID_RUNNER") {
        let p = PathBuf::from(p);
        if p.is_file() {
            return Ok(p);
        }
    }
    if let Some(built) = option_env!("GMID_RUNNER_BUILT") {
        let p = PathBuf::from(built);
        if p.is_file() {
            return Ok(p);
        }
    }
    let vendored = PathBuf::from("GmIDVisualizer/build/gmid_runner");
    if vendored.is_file() {
        return Ok(vendored);
    }
    Err("gmid_runner not found — install a C++ compiler and `cargo build`, \
         or set $GMID_RUNNER"
        .into())
}

/// Output directory for one (pdk, device, corner) run.
pub fn out_dir(req: &SweepRequest) -> PathBuf {
    out_dir_for(&req.pdk, &req.device, &req.corner)
}

pub fn out_dir_for(pdk: &str, device: &str, corner: &str) -> PathBuf {
    dirs::cache_dir()
        .unwrap_or_else(std::env::temp_dir)
        .join("schemify/cache/gmid-luts")
        .join(pdk)
        .join(format!("{device}__{corner}"))
}

/// Write the 2-line wrapper deck selecting the corner section.
fn write_wrapper(dir: &Path, req: &SweepRequest) -> Result<PathBuf, String> {
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let path = dir.join("wrapper.spice");
    let content = format!(
        "* schemify gm/id corner wrapper\n.lib \"{}\" {}\n",
        req.lib_path, req.corner
    );
    std::fs::write(&path, content).map_err(|e| e.to_string())?;
    Ok(path)
}

/// Run the full sweep set; `progress(l_index)` fires before each L run.
/// Returns the assembled LUT plus the SVG paths of the last L run.
pub fn characterize(
    req: &SweepRequest,
    mut progress: impl FnMut(usize),
) -> Result<(Lut, Vec<PathBuf>), String> {
    let bin = runner_bin()?;
    let dir = out_dir(req);
    let wrapper = write_wrapper(&dir, req)?;

    let mut grids: Vec<Vec<f64>> = Vec::with_capacity(req.l_um.len());
    let mut svgs: Vec<PathBuf> = Vec::new();
    let mut vds_axis: Vec<f64> = Vec::new();
    let mut vgs_axis: Vec<f64> = Vec::new();

    for (li, l) in req.l_um.iter().enumerate() {
        progress(li);
        let run_dir = dir.join(format!("L{l:.4}"));
        std::fs::create_dir_all(&run_dir).map_err(|e| e.to_string())?;
        let csv = run_dir.join("data.csv");

        let mut cmd = Command::new(&bin);
        cmd.arg("--model-file")
            .arg(&wrapper)
            .arg("--kind")
            .arg("mosfet")
            .arg("--out-dir")
            .arg(&run_dir)
            .arg("--device-name")
            .arg(&req.model)
            .arg("--emit-data")
            .arg(&csv)
            .arg("--width")
            .arg(W_REF_UM.to_string())
            .arg("--length")
            .arg(l.to_string())
            .arg("--temp")
            .arg(req.temp_c.to_string())
            .arg("--vgs-stop")
            .arg(req.vdd.to_string())
            .arg("--vds-stop")
            .arg(req.vdd.to_string())
            .arg("--vgs-steps")
            .arg(req.vgs_steps.to_string())
            .arg("--vds-steps")
            .arg(req.vds_steps.to_string());
        if req.vsb != 0.0 {
            cmd.arg("--vsb").arg(req.vsb.to_string());
        }
        if req.subckt {
            cmd.arg("--subckt");
        }

        let output = cmd.output().map_err(|e| format!("spawn gmid_runner: {e}"))?;
        if !output.status.success() {
            let err = String::from_utf8_lossy(&output.stderr);
            return Err(format!(
                "gmid_runner failed for L={l}: {}",
                err.lines().last().unwrap_or("unknown error")
            ));
        }

        let (vds, vgs, id) = parse_csv(&csv)?;
        if li == 0 {
            vds_axis = vds;
            vgs_axis = vgs;
        } else if vds.len() != vds_axis.len() || vgs.len() != vgs_axis.len() {
            return Err("inconsistent grid across L runs".into());
        }
        grids.push(id);

        // SVG paths from stdout ("SVG:<path>" lines); keep the last run's.
        svgs = String::from_utf8_lossy(&output.stdout)
            .lines()
            .filter_map(|l| l.strip_prefix("SVG:"))
            .map(PathBuf::from)
            .collect();
    }

    let lut = Lut::from_grids(
        LutMeta {
            pdk: req.pdk.clone(),
            device: req.device.clone(),
            model: req.model.clone(),
            corner: req.corner.clone(),
            vsb: req.vsb,
            temp_c: req.temp_c,
            w_ref_um: W_REF_UM,
        },
        req.l_um.clone(),
        vds_axis,
        vgs_axis,
        &grids,
        W_REF_UM,
    )?;
    Ok((lut, svgs))
}

/// Parse the `--emit-data` CSV (`vgs,vds,vbs,id`, vds-outer / vgs-inner)
/// into (vds axis, vgs axis, id grid).
fn parse_csv(path: &Path) -> Result<(Vec<f64>, Vec<f64>, Vec<f64>), String> {
    let content = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    let mut vds_axis: Vec<f64> = Vec::new();
    let mut vgs_axis: Vec<f64> = Vec::new();
    let mut id: Vec<f64> = Vec::new();

    for (ln, line) in content.lines().enumerate() {
        if ln == 0 || line.is_empty() {
            continue; // header
        }
        let mut cols = line.split(',');
        let vgs: f64 = cols
            .next()
            .and_then(|s| s.parse().ok())
            .ok_or_else(|| format!("csv line {ln}: bad vgs"))?;
        let vds: f64 = cols
            .next()
            .and_then(|s| s.parse().ok())
            .ok_or_else(|| format!("csv line {ln}: bad vds"))?;
        let _vbs = cols.next();
        let id_val: f64 = cols
            .next()
            .and_then(|s| s.parse().ok())
            .ok_or_else(|| format!("csv line {ln}: bad id"))?;

        if vds_axis.last().map(|&v| (v - vds).abs() > 1e-12).unwrap_or(true)
            && !vds_axis.contains(&vds)
        {
            vds_axis.push(vds);
        }
        if vds_axis.len() == 1 {
            vgs_axis.push(vgs);
        }
        id.push(id_val);
    }

    if vds_axis.is_empty() || vgs_axis.is_empty() {
        return Err("empty sweep CSV".into());
    }
    if id.len() != vds_axis.len() * vgs_axis.len() {
        return Err(format!(
            "csv grid mismatch: {} points vs {}×{}",
            id.len(),
            vds_axis.len(),
            vgs_axis.len()
        ));
    }
    Ok((vds_axis, vgs_axis, id))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_grid_csv() {
        let path = std::env::temp_dir().join(format!("gmid-csv-{}.csv", std::process::id()));
        let mut s = String::from("vgs,vds,vbs,id\n");
        for d in [0.05, 0.9] {
            for g in [0.0, 0.5, 1.0] {
                s.push_str(&format!("{g},{d},0,1e-6\n"));
            }
        }
        std::fs::write(&path, s).unwrap();
        let (vds, vgs, id) = parse_csv(&path).unwrap();
        assert_eq!(vds, vec![0.05, 0.9]);
        assert_eq!(vgs, vec![0.0, 0.5, 1.0]);
        assert_eq!(id.len(), 6);
        let _ = std::fs::remove_file(path);
    }
}
