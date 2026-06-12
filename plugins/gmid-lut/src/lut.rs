//! `.glut` lookup tables: per-µm device quantities on an (L, VDS, VGS) grid.
//!
//! Binary layout (little-endian, SoA):
//!   magic "GLUT1\0" · u32 version · u32 json_len · JSON metadata ·
//!   u32 nL · u32 nVDS · u32 nVGS · f64 axes (L, VDS, VGS) ·
//!   f32 blocks id_w, gm_w, gds_w — each nL·nVDS·nVGS, index
//!   `((l*nVDS)+d)*nVGS + g`.
//!
//! NOTE: this module is duplicated into the pdk-mapper plugin (plugins are
//! standalone crates headed for separate repos — keep both copies in sync).

use std::io::{Read, Write};
use std::path::{Path, PathBuf};

pub const MAGIC: &[u8; 6] = b"GLUT1\0";
pub const VERSION: u32 = 1;

#[derive(Debug, Clone, Default)]
pub struct LutMeta {
    pub pdk: String,
    pub device: String,
    pub model: String,
    pub corner: String,
    pub vsb: f64,
    pub temp_c: f64,
    pub w_ref_um: f64,
}

#[derive(Debug, Clone, Default)]
pub struct Lut {
    pub meta: LutMeta,
    pub l_um: Vec<f64>,
    pub vds: Vec<f64>,
    pub vgs: Vec<f64>,
    /// A/µm at W_ref, normalized.
    pub id_w: Vec<f32>,
    /// S/µm.
    pub gm_w: Vec<f32>,
    /// S/µm.
    pub gds_w: Vec<f32>,
}

impl Lut {
    #[inline]
    pub fn idx(&self, l: usize, d: usize, g: usize) -> usize {
        (l * self.vds.len() + d) * self.vgs.len() + g
    }

    /// Build from one CSV grid per L value (`grids[l] = (id values in
    /// vds-outer/vgs-inner order)`), normalizing by width.
    pub fn from_grids(
        meta: LutMeta,
        l_um: Vec<f64>,
        vds: Vec<f64>,
        vgs: Vec<f64>,
        id_grids: &[Vec<f64>],
        width_um: f64,
    ) -> Result<Self, String> {
        let (nd, ng) = (vds.len(), vgs.len());
        let n = l_um.len() * nd * ng;
        let mut lut = Lut {
            meta,
            l_um,
            vds,
            vgs,
            id_w: vec![0.0; n],
            gm_w: vec![0.0; n],
            gds_w: vec![0.0; n],
        };
        if id_grids.len() != lut.l_um.len() {
            return Err("grid count != L count".into());
        }

        let cell = |l: usize, d: usize, g: usize| (l * nd + d) * ng + g;
        for (l, grid) in id_grids.iter().enumerate() {
            if grid.len() != nd * ng {
                return Err(format!(
                    "L index {l}: {} points, expected {}",
                    grid.len(),
                    nd * ng
                ));
            }
            for d in 0..nd {
                for g in 0..ng {
                    lut.id_w[cell(l, d, g)] = (grid[d * ng + g] / width_um) as f32;
                }
            }
            // gm = ∂Id/∂VGS (central difference along the inner axis).
            for d in 0..nd {
                for g in 0..ng {
                    let (g0, g1) = (g.saturating_sub(1), (g + 1).min(ng - 1));
                    let dv = lut.vgs[g1] - lut.vgs[g0];
                    let di = grid[d * ng + g1] - grid[d * ng + g0];
                    lut.gm_w[cell(l, d, g)] =
                        if dv > 0.0 { (di / dv / width_um) as f32 } else { 0.0 };
                }
            }
            // gds = ∂Id/∂VDS (central difference across blocks).
            for d in 0..nd {
                let (d0, d1) = (d.saturating_sub(1), (d + 1).min(nd - 1));
                let dv = lut.vds[d1] - lut.vds[d0];
                for g in 0..ng {
                    let di = grid[d1 * ng + g] - grid[d0 * ng + g];
                    lut.gds_w[cell(l, d, g)] =
                        if dv > 0.0 { (di / dv / width_um) as f32 } else { 0.0 };
                }
            }
        }
        Ok(lut)
    }

    // ── Queries ──────────────────────────────────────────────────────

    /// Nearest index on the VDS axis.
    pub fn vds_index(&self, vds: f64) -> usize {
        self.vds
            .iter()
            .enumerate()
            .min_by(|a, b| {
                (a.1 - vds).abs().partial_cmp(&(b.1 - vds).abs()).unwrap()
            })
            .map(|(i, _)| i)
            .unwrap_or(0)
    }

    /// gm/Id at one grid point.
    pub fn gm_id(&self, l: usize, d: usize, g: usize) -> f64 {
        let i = self.idx(l, d, g);
        let id = self.id_w[i] as f64;
        if id.abs() < 1e-18 {
            0.0
        } else {
            self.gm_w[i] as f64 / id
        }
    }

    /// Find VGS giving the target gm/Id at (L index, VDS index): scan for
    /// the bracketing grid pair on the strong-inversion side, then
    /// interpolate. gm/Id decreases monotonically with VGS above weak
    /// inversion; the scan starts from the high-VGS end to stay on the
    /// monotone branch.
    pub fn vgs_for_gm_id(&self, l: usize, d: usize, target: f64) -> Option<f64> {
        let ng = self.vgs.len();
        let mut prev: Option<(usize, f64)> = None;
        for g in (0..ng).rev() {
            let v = self.gm_id(l, d, g);
            if v <= 0.0 {
                break; // entered cutoff noise — stop
            }
            if let Some((pg, pv)) = prev {
                if (pv <= target && target <= v) || (v <= target && target <= pv) {
                    let t = if (v - pv).abs() < 1e-12 {
                        0.0
                    } else {
                        (target - pv) / (v - pv)
                    };
                    return Some(self.vgs[pg] + t * (self.vgs[g] - self.vgs[pg]));
                }
            }
            prev = Some((g, v));
        }
        None
    }

    /// Linear interpolation of a quantity along VGS at (L, VDS) indices.
    pub fn at_vgs(&self, l: usize, d: usize, vgs: f64, q: Quantity) -> f64 {
        let ng = self.vgs.len();
        let mut g1 = ng - 1;
        for g in 0..ng {
            if self.vgs[g] >= vgs {
                g1 = g;
                break;
            }
        }
        let g0 = g1.saturating_sub(1);
        let (x0, x1) = (self.vgs[g0], self.vgs[g1]);
        let t = if (x1 - x0).abs() < 1e-12 {
            0.0
        } else {
            ((vgs - x0) / (x1 - x0)).clamp(0.0, 1.0)
        };
        let f = |g: usize| -> f64 {
            let i = self.idx(l, d, g);
            match q {
                Quantity::IdW => self.id_w[i] as f64,
                Quantity::GmW => self.gm_w[i] as f64,
                Quantity::GdsW => self.gds_w[i] as f64,
            }
        };
        f(g0) + t * (f(g1) - f(g0))
    }

    // ── Serialization ────────────────────────────────────────────────

    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let mut out: Vec<u8> = Vec::new();
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&VERSION.to_le_bytes());
        let meta = serde_json::json!({
            "pdk": self.meta.pdk,
            "device": self.meta.device,
            "model": self.meta.model,
            "corner": self.meta.corner,
            "vsb": self.meta.vsb,
            "temp_c": self.meta.temp_c,
            "w_ref_um": self.meta.w_ref_um,
        })
        .to_string();
        out.extend_from_slice(&(meta.len() as u32).to_le_bytes());
        out.extend_from_slice(meta.as_bytes());
        for n in [self.l_um.len(), self.vds.len(), self.vgs.len()] {
            out.extend_from_slice(&(n as u32).to_le_bytes());
        }
        for axis in [&self.l_um, &self.vds, &self.vgs] {
            for v in axis.iter() {
                out.extend_from_slice(&v.to_le_bytes());
            }
        }
        for block in [&self.id_w, &self.gm_w, &self.gds_w] {
            for v in block.iter() {
                out.extend_from_slice(&v.to_le_bytes());
            }
        }
        let mut f = std::fs::File::create(path).map_err(|e| e.to_string())?;
        f.write_all(&out).map_err(|e| e.to_string())
    }

    #[allow(dead_code)] // used by the pdk-mapper copy of this module
    pub fn load(path: &Path) -> Result<Self, String> {
        let mut bytes = Vec::new();
        std::fs::File::open(path)
            .map_err(|e| e.to_string())?
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        let mut pos = 0usize;
        let take = |pos: &mut usize, n: usize| -> Result<&[u8], String> {
            let s = bytes.get(*pos..*pos + n).ok_or("truncated .glut")?;
            *pos += n;
            Ok(s)
        };
        if take(&mut pos, 6)? != MAGIC {
            return Err("bad magic".into());
        }
        let u32_at = |s: &[u8]| u32::from_le_bytes(s.try_into().unwrap());
        if u32_at(take(&mut pos, 4)?) != VERSION {
            return Err("unsupported .glut version".into());
        }
        let meta_len = u32_at(take(&mut pos, 4)?) as usize;
        let meta_json: serde_json::Value =
            serde_json::from_slice(take(&mut pos, meta_len)?).map_err(|e| e.to_string())?;
        let s = |k: &str| {
            meta_json
                .get(k)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_owned()
        };
        let f = |k: &str| meta_json.get(k).and_then(|v| v.as_f64()).unwrap_or(0.0);
        let meta = LutMeta {
            pdk: s("pdk"),
            device: s("device"),
            model: s("model"),
            corner: s("corner"),
            vsb: f("vsb"),
            temp_c: f("temp_c"),
            w_ref_um: f("w_ref_um"),
        };
        let nl = u32_at(take(&mut pos, 4)?) as usize;
        let nd = u32_at(take(&mut pos, 4)?) as usize;
        let ng = u32_at(take(&mut pos, 4)?) as usize;
        let mut axis = |n: usize| -> Result<Vec<f64>, String> {
            let raw = take(&mut pos, n * 8)?;
            Ok(raw
                .chunks_exact(8)
                .map(|c| f64::from_le_bytes(c.try_into().unwrap()))
                .collect())
        };
        let l_um = axis(nl)?;
        let vds = axis(nd)?;
        let vgs = axis(ng)?;
        let total = nl * nd * ng;
        let mut block = |n: usize| -> Result<Vec<f32>, String> {
            let raw = take(&mut pos, n * 4)?;
            Ok(raw
                .chunks_exact(4)
                .map(|c| f32::from_le_bytes(c.try_into().unwrap()))
                .collect())
        };
        let id_w = block(total)?;
        let gm_w = block(total)?;
        let gds_w = block(total)?;
        Ok(Lut {
            meta,
            l_um,
            vds,
            vgs,
            id_w,
            gm_w,
            gds_w,
        })
    }
}

#[derive(Debug, Clone, Copy)]
pub enum Quantity {
    IdW,
    GmW,
    GdsW,
}

/// Cache path for one characterization.
pub fn glut_path(pdk: &str, device: &str, corner: &str, vsb: f64) -> PathBuf {
    dirs::cache_dir()
        .unwrap_or_else(std::env::temp_dir)
        .join("schemify/cache/gmid-luts")
        .join(pdk)
        .join(format!("{device}__{corner}__vsb{vsb:.2}.glut"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Square-law surrogate: Id = K/2·W·(VGS−VT)²·(1+λVDS), VT=0.5, K=1e-4.
    fn surrogate() -> Lut {
        let vgs: Vec<f64> = (0..91).map(|i| i as f64 * 0.02).collect();
        let vds: Vec<f64> = (0..10).map(|i| 0.05 + i as f64 * 0.15).collect();
        let l = vec![0.15, 0.5];
        let w = 10.0;
        let grids: Vec<Vec<f64>> = l
            .iter()
            .map(|_| {
                let mut g = Vec::new();
                for d in &vds {
                    for v in &vgs {
                        let vov = (v - 0.5).max(0.0);
                        g.push(0.5 * 1e-4 * w * vov * vov * (1.0 + 0.05 * d));
                    }
                }
                g
            })
            .collect();
        Lut::from_grids(
            LutMeta {
                pdk: "test".into(),
                device: "nmos4".into(),
                model: "m".into(),
                corner: "tt".into(),
                vsb: 0.0,
                temp_c: 27.0,
                w_ref_um: w,
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
    fn gm_matches_analytic() {
        let lut = surrogate();
        // Square law: gm = K·W·Vov·(1+λVds); at VGS=1.3 (Vov=0.8), VDS≈0.8.
        let d = lut.vds_index(0.8);
        let g = lut.vgs.iter().position(|&v| (v - 1.3).abs() < 1e-9).unwrap();
        let gm = lut.gm_w[lut.idx(0, d, g)] as f64 * 10.0; // de-normalize
        let expected = 1e-4 * 10.0 * 0.8 * (1.0 + 0.05 * lut.vds[d]);
        assert!((gm - expected).abs() / expected < 0.02, "{gm} vs {expected}");
    }

    #[test]
    fn inverse_gmid_lookup() {
        let lut = surrogate();
        let d = lut.vds_index(0.8);
        // Square law: gm/Id = 2/Vov → target 5 ⇒ Vov = 0.4 ⇒ VGS = 0.9.
        let vgs = lut.vgs_for_gm_id(0, d, 5.0).unwrap();
        assert!((vgs - 0.9).abs() < 0.02, "vgs = {vgs}");
    }

    #[test]
    fn roundtrip() {
        let lut = surrogate();
        let path = std::env::temp_dir().join(format!("glut-test-{}.glut", std::process::id()));
        lut.save(&path).unwrap();
        let back = Lut::load(&path).unwrap();
        assert_eq!(back.l_um, lut.l_um);
        assert_eq!(back.vgs.len(), lut.vgs.len());
        assert_eq!(back.id_w, lut.id_w);
        assert_eq!(back.meta.device, "nmos4");
        let _ = std::fs::remove_file(path);
    }
}
