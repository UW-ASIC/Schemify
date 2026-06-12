//! Emit gm/Id design curves as an ngspice-ascii `.raw` file so Schemify's
//! waveform viewer plots them natively (cursors, zoom, expressions).
//!
//! Two plot blocks per file:
//!   block 0 — scale `gm_id` (uniform): per-L `jd_*` (A/µm), `av_*` (gm/gds)
//!   block 1 — scale `vgs`: per-L `id_*` (A/µm), `gmid_*` (1/V)
//!
//! Curves are taken at the mid-VDS slice (≈ Vdd/2), matching the SVG figures.

use std::fmt::Write as FmtWrite;
use std::path::PathBuf;

use crate::lut::{Lut, Quantity};

/// `0.15` → `l0p15` (identifier-safe for the expression engine).
fn l_tag(l: f64) -> String {
    format!("l{}", format!("{l}").replace('.', "p").replace('-', "m"))
}

pub fn raw_path(lut: &Lut) -> PathBuf {
    crate::runner::out_dir_for(&lut.meta.pdk, &lut.meta.device, &lut.meta.corner)
        .join("gmid_curves.raw")
}

pub fn write_raw(lut: &Lut) -> Result<PathBuf, String> {
    let path = raw_path(lut);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }

    let d = lut.vds_index(lut.vds.last().copied().unwrap_or(1.8) / 2.0);
    let nl = lut.l_um.len();
    let mut out = String::new();

    // ── Block 0: x = gm/Id, uniform grid spanning all L curves ─────────
    {
        // Range from the data: weak-inversion top to strong-inversion floor.
        let mut lo = f64::MAX;
        let mut hi = f64::MIN;
        for l in 0..nl {
            for g in 0..lut.vgs.len() {
                let v = lut.gm_id(l, d, g);
                if v > 0.05 && v < 50.0 {
                    lo = lo.min(v);
                    hi = hi.max(v);
                }
            }
        }
        if lo >= hi {
            return Err("no usable gm/Id range in LUT".into());
        }
        let n = 200usize;
        let axis: Vec<f64> = (0..n)
            .map(|i| lo + (hi - lo) * i as f64 / (n - 1) as f64)
            .collect();

        let mut vars: Vec<(String, Vec<f64>)> = Vec::new();
        for (li, l) in lut.l_um.iter().enumerate() {
            let tag = l_tag(*l);
            let mut jd = Vec::with_capacity(n);
            let mut av = Vec::with_capacity(n);
            for target in &axis {
                match lut.vgs_for_gm_id(li, d, *target) {
                    Some(vgs) => {
                        let id = lut.at_vgs(li, d, vgs, Quantity::IdW);
                        let gm = lut.at_vgs(li, d, vgs, Quantity::GmW);
                        let gds = lut.at_vgs(li, d, vgs, Quantity::GdsW);
                        jd.push(id);
                        av.push(if gds.abs() > 1e-18 { gm / gds } else { 0.0 });
                    }
                    None => {
                        jd.push(0.0);
                        av.push(0.0);
                    }
                }
            }
            vars.push((format!("jd_{tag}"), jd));
            vars.push((format!("av_{tag}"), av));
        }
        write_block(
            &mut out,
            &format!(
                "gm/Id design curves — {} {} {}",
                lut.meta.pdk, lut.meta.model, lut.meta.corner
            ),
            "gm/Id sweep (x = gm/Id, 1/V)",
            "gm_id",
            &axis,
            &vars,
        );
    }

    // ── Block 1: x = VGS ────────────────────────────────────────────────
    {
        let axis = lut.vgs.clone();
        let mut vars: Vec<(String, Vec<f64>)> = Vec::new();
        for (li, l) in lut.l_um.iter().enumerate() {
            let tag = l_tag(*l);
            let id: Vec<f64> = (0..axis.len())
                .map(|g| lut.id_w[lut.idx(li, d, g)] as f64)
                .collect();
            let gmid: Vec<f64> = (0..axis.len()).map(|g| lut.gm_id(li, d, g)).collect();
            vars.push((format!("id_{tag}"), id));
            vars.push((format!("gmid_{tag}"), gmid));
        }
        write_block(
            &mut out,
            &format!(
                "gm/Id design curves — {} {} {}",
                lut.meta.pdk, lut.meta.model, lut.meta.corner
            ),
            "VGS sweep (x = VGS, V)",
            "vgs",
            &axis,
            &vars,
        );
    }

    std::fs::write(&path, out).map_err(|e| e.to_string())?;
    Ok(path)
}

fn write_block(
    out: &mut String,
    title: &str,
    plotname: &str,
    scale_name: &str,
    axis: &[f64],
    vars: &[(String, Vec<f64>)],
) {
    let n_vars = vars.len() + 1;
    let n = axis.len();
    let _ = writeln!(out, "Title: {title}");
    let _ = writeln!(out, "Date: schemify gmid-lut");
    let _ = writeln!(out, "Plotname: {plotname}");
    let _ = writeln!(out, "Flags: real");
    let _ = writeln!(out, "No. Variables: {n_vars}");
    let _ = writeln!(out, "No. Points: {n}");
    let _ = writeln!(out, "Variables:");
    let _ = writeln!(out, "\t0\t{scale_name}\tvoltage");
    for (i, (name, _)) in vars.iter().enumerate() {
        let _ = writeln!(out, "\t{}\t{name}\tcurrent", i + 1);
    }
    let _ = writeln!(out, "Values:");
    for p in 0..n {
        let _ = writeln!(out, "{p}\t{:e}", axis[p]);
        for (_, col) in vars {
            let _ = writeln!(out, "\t{:e}", col[p]);
        }
    }
}

/// Default traces to add after `WaveOpen` — one per figure family.
pub fn default_traces(lut: &Lut) -> Vec<(String, u16)> {
    let mut traces = Vec::new();
    for l in &lut.l_um {
        let tag = l_tag(*l);
        traces.push((format!("jd_{tag}"), 0)); // block 0: Jd vs gm/Id
        traces.push((format!("av_{tag}"), 0)); // block 0: gain vs gm/Id
        traces.push((format!("gmid_{tag}"), 1)); // block 1: gm/Id vs VGS
    }
    traces
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn l_tags_are_identifier_safe() {
        assert_eq!(l_tag(0.15), "l0p15");
        assert_eq!(l_tag(1.0), "l1");
    }
}
