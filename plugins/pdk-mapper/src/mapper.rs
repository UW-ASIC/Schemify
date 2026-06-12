//! Cross-PDK retargeting.
//!
//! Stage A — LUT inversion: per MOSFET preserve κ = gm/Id and Id exactly as
//! targets; choose L to match intrinsic gain (gm/gds) on the target LUT;
//! W from the per-µm current density at the κ bias point.
//!
//! Stage B — simulation-in-the-loop: re-run `.op` on the mapped netlist in
//! the target PDK and iterate damped log-space updates per device until
//! gm/gds residuals drop under tolerance.
//!
//! Honest equivalence: topology, passives and current ratios are exact;
//! per-device Id/gm/gm-Id match to solver tolerance; gm/gds matches as well
//! as the L axis allows (different CLM/DIBL physics); noise constants,
//! mismatch and corner spread are technology properties no sizing recovers.

use std::collections::HashMap;
use std::path::Path;

use crate::lut::Lut;
use crate::ngspice::DeviceOp;

/// Bias mapping policy when supplies differ.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BiasPolicy {
    /// Keep absolute VDS/VSB (default; correct when both designs run at the
    /// same supply).
    Preserve,
    /// Scale VDS/VSB by Vdd_target / Vdd_source.
    Scale,
}

/// Target-PDK device manifest entry (from schemify-pdk.toml).
#[derive(Debug, Clone, Default)]
pub struct TargetCell {
    pub model: String,
    pub subckt: bool,
}

/// One mapped device row.
#[derive(Debug, Clone)]
pub struct Mapping {
    pub idx: usize,
    pub name: String,
    pub primitive: String,
    pub src_model: String,
    pub src_w: f64,
    pub src_l: f64,
    pub op: DeviceOp,
    /// κ = gm/Id (1/V).
    pub gm_id: f64,
    pub tgt_model: String,
    pub tgt_w: f64,
    pub tgt_l: f64,
    pub warnings: Vec<String>,
    /// Post-refinement residuals in percent (gm, gds, id), if Stage B ran.
    pub residual: Option<[f64; 3]>,
}

/// Stage A for one device: invert the target LUT.
///
/// Returns (W*, L*, warnings).
pub fn invert_lut(
    lut: &Lut,
    op: &DeviceOp,
    vds_target: f64,
) -> Result<(f64, f64, Vec<String>), String> {
    let mut warnings = Vec::new();
    let kappa = if op.id.abs() > 1e-15 {
        (op.gm / op.id).abs()
    } else {
        return Err("device off (Id ≈ 0)".into());
    };
    let d = lut.vds_index(vds_target.abs());

    // Source intrinsic gain to reproduce.
    let av_src = if op.gds.abs() > 1e-15 {
        (op.gm / op.gds).abs()
    } else {
        f64::MAX
    };

    // Pick L on the grid minimizing Δln(gm/gds) at the κ bias point.
    let mut best: Option<(usize, f64, f64)> = None; // (l index, vgs, objective)
    for li in 0..lut.l_um.len() {
        let Some(vgs) = lut.vgs_for_gm_id(li, d, kappa) else {
            continue;
        };
        let gm = lut.at_vgs(li, d, vgs, crate::lut::Quantity::GmW);
        let gds = lut.at_vgs(li, d, vgs, crate::lut::Quantity::GdsW);
        if gm <= 0.0 || gds <= 0.0 {
            continue;
        }
        let av = gm / gds;
        let obj = (av.ln() - av_src.ln()).abs();
        if best.map(|(_, _, b)| obj < b).unwrap_or(true) {
            best = Some((li, vgs, obj));
        }
    }
    let Some((li, vgs, obj)) = best else {
        return Err(format!(
            "gm/Id = {kappa:.1} outside the target LUT range — re-characterize \
             with a wider sweep"
        ));
    };
    if obj > 0.5 {
        warnings.push(format!(
            "intrinsic-gain mismatch {:.0}% even at best L — target process \
             cannot reach the source gain at this bias",
            (obj.exp() - 1.0) * 100.0
        ));
    }

    // W from current density at the κ point.
    let jd = lut.at_vgs(li, d, vgs, crate::lut::Quantity::IdW);
    if jd <= 0.0 {
        return Err("zero current density at the κ bias point".into());
    }
    let w = op.id.abs() / jd;

    // Headroom: vdsat ≈ 2/κ must fit under the target VDS.
    let vdsat_tgt = 2.0 / kappa;
    if vdsat_tgt > vds_target.abs() {
        warnings.push(format!(
            "headroom: estimated vdsat {vdsat_tgt:.2} V exceeds target VDS \
             {:.2} V",
            vds_target.abs()
        ));
    }
    if w < 0.1 {
        warnings.push(format!("very small W = {w:.3} µm — check Id extraction"));
    }
    if w > 10_000.0 {
        warnings.push(format!("very large W = {w:.0} µm — check Id extraction"));
    }

    Ok((w, lut.l_um[li], warnings))
}

/// Stage B step: damped multiplicative log-space update from measured vs
/// source small-signal values. gm responds ∝ W at fixed bias; gds carries
/// the same W factor plus the 1/L CLM trend — solve the pair accordingly.
pub fn refine_step(
    w: f64,
    l: f64,
    measured: &DeviceOp,
    source: &DeviceOp,
    damping: f64,
) -> (f64, f64) {
    let gm_ratio = (source.gm / measured.gm).abs().clamp(0.25, 4.0);
    let gds_ratio = (measured.gds / source.gds).abs().clamp(0.25, 4.0);
    let w_new = w * gm_ratio.powf(damping);
    // gds_new/gds = (W_new/W) / (L_new/L) to first order →
    // L_new = L · gds_ratio · gm_ratio (the W correction feeds through).
    let l_new = l * (gds_ratio * gm_ratio).powf(damping);
    (w_new, l_new.clamp(l * 0.25, l * 4.0))
}

/// Residuals in percent: (gm, gds, id).
pub fn residuals(measured: &DeviceOp, source: &DeviceOp) -> [f64; 3] {
    let pct = |m: f64, s: f64| {
        if s.abs() < 1e-18 {
            0.0
        } else {
            ((m - s) / s * 100.0).abs()
        }
    };
    [
        pct(measured.gm, source.gm),
        pct(measured.gds, source.gds),
        pct(measured.id, source.id),
    ]
}

/// Parse a target PDK's schemify-pdk.toml (or the embedded fallbacks for
/// sky130/gf180mcu, which core also hardcodes) into primitive → cell.
pub fn load_target_cells(variant_dir: &Path, variant: &str) -> HashMap<String, TargetCell> {
    let manifest_path = variant_dir.join("schemify-pdk.toml");
    let content = std::fs::read_to_string(&manifest_path)
        .ok()
        .or_else(|| builtin_manifest(variant).map(str::to_owned));
    let mut cells = HashMap::new();
    let Some(content) = content else {
        return cells;
    };
    let Ok(value) = content.parse::<toml::Value>() else {
        return cells;
    };
    if let Some(devices) = value.get("devices").and_then(|d| d.as_table()) {
        for (prim, entry) in devices {
            let model = entry
                .get("model")
                .and_then(|m| m.as_str())
                .unwrap_or_default()
                .to_owned();
            if model.is_empty() {
                continue;
            }
            let subckt = entry
                .get("prefix")
                .and_then(|p| p.as_str())
                .map(|p| p.eq_ignore_ascii_case("X"))
                .unwrap_or(false);
            cells.insert(prim.clone(), TargetCell { model, subckt });
        }
    }
    cells
}

/// Corner list of a target PDK (manifest or builtin).
pub fn load_target_corners(variant_dir: &Path, variant: &str) -> (Vec<String>, String) {
    let content = std::fs::read_to_string(variant_dir.join("schemify-pdk.toml"))
        .ok()
        .or_else(|| builtin_manifest(variant).map(str::to_owned));
    let mut corners = Vec::new();
    let mut default = String::new();
    if let Some(content) = content {
        if let Ok(value) = content.parse::<toml::Value>() {
            if let Some(models) = value.get("models") {
                if let Some(list) = models.get("corners").and_then(|c| c.as_array()) {
                    corners = list
                        .iter()
                        .filter_map(|c| c.as_str().map(str::to_owned))
                        .collect();
                }
                default = models
                    .get("default_corner")
                    .and_then(|c| c.as_str())
                    .unwrap_or_default()
                    .to_owned();
            }
        }
    }
    if default.is_empty() {
        default = corners.first().cloned().unwrap_or_default();
    }
    (corners, default)
}

/// Mirrors core's builtin manifests (kept in sync with
/// crates/core/src/config.rs).
pub(crate) fn builtin_manifest(variant: &str) -> Option<&'static str> {
    if variant.starts_with("sky130") {
        Some(include_str!("../manifests/sky130.toml"))
    } else if variant.starts_with("gf180mcu") {
        Some(include_str!("../manifests/gf180mcu.toml"))
    } else if variant.starts_with("ihp-sg13g2") {
        Some(include_str!("../manifests/ihp-sg13g2.toml"))
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lut::{Lut, LutMeta};

    fn surrogate(k: f64, lambda: f64) -> Lut {
        let vgs: Vec<f64> = (0..91).map(|i| i as f64 * 0.02).collect();
        let vds: Vec<f64> = (0..10).map(|i| 0.05 + i as f64 * 0.15).collect();
        let l = vec![0.15, 0.3, 0.6, 1.2];
        let w = 10.0;
        let grids: Vec<Vec<f64>> = l
            .iter()
            .map(|li| {
                let mut g = Vec::new();
                // λ shrinks with longer L: λ_eff = λ·(0.15/L).
                let lam = lambda * 0.15 / li;
                for d in &vds {
                    for v in &vgs {
                        let vov = (v - 0.5).max(0.0);
                        g.push(0.5 * k * w * vov * vov * (1.0 + lam * d));
                    }
                }
                g
            })
            .collect();
        Lut::from_grids(
            LutMeta {
                w_ref_um: w,
                ..Default::default()
            },
            l,
            vds,
            vgs,
            &grids,
            w,
        )
        .unwrap()
    }

    #[test]
    fn stage_a_recovers_current_and_kappa() {
        let lut = surrogate(2e-4, 0.3);
        // Source op: κ = 5 (Vov = 0.4), Id = 100 µA, gain 80.
        let op = DeviceOp {
            id: 100e-6,
            gm: 500e-6,
            gds: 500e-6 / 80.0,
            vds: 0.8,
            ..Default::default()
        };
        let (w, l, _warn) = invert_lut(&lut, &op, 0.8).unwrap();
        assert!(w > 0.5 && w < 500.0, "w = {w}");
        assert!(lut.l_um.contains(&l));
        // Check the inversion reproduces Id at κ within a few percent.
        let d = lut.vds_index(0.8);
        let li = lut.l_um.iter().position(|&x| x == l).unwrap();
        let vgs = lut.vgs_for_gm_id(li, d, 5.0).unwrap();
        let id = lut.at_vgs(li, d, vgs, crate::lut::Quantity::IdW) * w;
        assert!(
            (id - 100e-6).abs() / 100e-6 < 0.05,
            "id = {id:.3e}"
        );
    }

    #[test]
    fn refine_converges_on_surrogate() {
        // "Simulator": square law with λ = 0.25·(0.15/L).
        let sim = |w: f64, l: f64, vov: f64, vds: f64| -> DeviceOp {
            let lam = 0.25 * 0.15 / l;
            let id = 0.5 * 2e-4 * w * vov * vov * (1.0 + lam * vds);
            DeviceOp {
                id,
                gm: 2e-4 * w * vov * (1.0 + lam * vds),
                gds: 0.5 * 2e-4 * w * vov * vov * lam,
                ..Default::default()
            }
        };
        let source = sim(20.0, 0.45, 0.4, 0.8);
        let (mut w, mut l) = (10.0, 0.3); // bad initial guess
        for _ in 0..12 {
            let measured = sim(w, l, 0.4, 0.8);
            let r = residuals(&measured, &source);
            if r[0] < 1.0 && r[1] < 1.0 {
                break;
            }
            let (nw, nl) = refine_step(w, l, &measured, &source, 0.7);
            w = nw;
            l = nl;
        }
        let final_op = sim(w, l, 0.4, 0.8);
        let r = residuals(&final_op, &source);
        assert!(r[0] < 1.0 && r[1] < 1.0, "residuals {r:?} (w={w}, l={l})");
    }
}
