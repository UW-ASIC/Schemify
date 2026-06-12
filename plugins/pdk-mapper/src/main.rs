//! PDK Mapper plugin: retarget the current schematic onto another PDK.
//!
//! Pipeline (each step a button):
//!   1. Extract — `.op` the source netlist, per-device {Id, gm, gds, …}
//!   2. Map     — Stage A LUT inversion onto the target PDK (needs `.glut`
//!                tables from the gm/Id plugin for the target)
//!   3. Refine  — Stage B sim-in-the-loop on the candidate netlist
//!   4. Apply   — SetInstanceProp per device (model, W, L) + undoable

mod lut;
mod mapper;
mod ngspice;

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use schemify_plugins::sdk::{
    AlertLevel, CommandInvocation, InitializeEvent, InstanceRecord, PanelLayout, Plugin,
    PluginRuntime, RuntimeError, UiAction, WidgetNode,
};
use serde_json::json;

use mapper::{BiasPolicy, Mapping};
use ngspice::{DeviceOp, Probe};

const PANEL: &str = "PDK Mapper";

/// MOSFET primitive names (matches DeviceKind symbol names).
const MOS_PRIMS: [&str; 8] = [
    "nmos3", "nmos4", "pmos3", "pmos4", "nmoshv4", "pmoshv4", "nmos4_depl", "rnmos4",
];

/// Known nominal supplies for bias scaling.
fn nominal_vdd(variant: &str) -> f64 {
    if variant.starts_with("sky130") {
        1.8
    } else if variant.starts_with("gf180") {
        3.3
    } else if variant.starts_with("ihp") {
        1.5
    } else {
        1.8
    }
}

#[derive(Default)]
struct Model {
    source_pdk: String,
    source_root: String,
    source_lib: Option<String>,
    /// Target PDK variants found under $PDK_ROOT.
    targets: Vec<String>,
    target_sel: usize,
    target_corners: Vec<String>,
    corner_sel: usize,
    policy: BiasPolicy,
    tolerance: f64,
    netlist: String,
    instance_map: HashMap<usize, String>,
    instances: Vec<InstanceRecord>,
    ops: HashMap<usize, DeviceOp>,
    mappings: Vec<Mapping>,
    refined: bool,
    error: Option<String>,
    status: String,
}

impl Default for BiasPolicy {
    fn default() -> Self {
        BiasPolicy::Preserve
    }
}

impl Model {
    fn target_variant(&self) -> Option<&str> {
        self.targets.get(self.target_sel).map(String::as_str)
    }

    fn target_corner(&self) -> Option<&str> {
        self.target_corners.get(self.corner_sel).map(String::as_str)
    }

    fn render(&self) -> Vec<WidgetNode> {
        let mut w = vec![WidgetNode::Heading("PDK Mapper".into())];

        w.push(WidgetNode::KeyValue {
            entries: vec![["Source PDK".into(), self.source_pdk.clone()]],
        });
        if self.targets.is_empty() {
            w.push(WidgetNode::Alert {
                level: AlertLevel::Warn,
                message: "No target PDKs under $PDK_ROOT — install one with the \
                          PDK Switcher."
                    .into(),
            });
        } else {
            w.push(WidgetNode::Dropdown {
                label: "Target PDK".into(),
                options: self.targets.clone(),
                selected: self.target_sel,
                action: "target".into(),
            });
            w.push(WidgetNode::Dropdown {
                label: "Corner".into(),
                options: self.target_corners.clone(),
                selected: self.corner_sel,
                action: "corner".into(),
            });
        }
        w.push(WidgetNode::RadioGroup {
            label: "Bias mapping".into(),
            options: vec![
                "Preserve absolute VDS".into(),
                "Scale VDS by Vdd ratio".into(),
            ],
            selected: if self.policy == BiasPolicy::Preserve { 0 } else { 1 },
            action: "policy".into(),
        });
        w.push(WidgetNode::NumberInput {
            label: "Refine tolerance (%)".into(),
            value: self.tolerance,
            min: Some(0.1),
            max: Some(20.0),
            step: Some(0.1),
            action: "tolerance".into(),
        });

        w.push(WidgetNode::Horizontal {
            children: vec![
                WidgetNode::Button {
                    label: "1· Extract op".into(),
                    action: "extract".into(),
                },
                WidgetNode::Button {
                    label: "2· Map".into(),
                    action: "map".into(),
                },
                WidgetNode::Button {
                    label: "3· Refine".into(),
                    action: "refine".into(),
                },
            ],
        });

        if let Some(err) = &self.error {
            w.push(WidgetNode::Alert {
                level: AlertLevel::Error,
                message: err.clone(),
            });
        }
        if !self.status.is_empty() {
            w.push(WidgetNode::Label(self.status.clone()));
        }

        // Extraction table.
        if !self.ops.is_empty() && self.mappings.is_empty() {
            let mut rows: Vec<Vec<String>> = Vec::new();
            for inst in &self.instances {
                if let Some(op) = self.ops.get(&inst.idx) {
                    rows.push(vec![
                        inst.name.clone(),
                        format!("{:.2e}", op.id),
                        format!("{:.1}", (op.gm / op.id.max(1e-18)).abs()),
                        format!("{:.0}", (op.gm / op.gds.max(1e-18)).abs()),
                    ]);
                }
            }
            w.push(WidgetNode::Table {
                headers: vec!["Dev".into(), "Id".into(), "gm/Id".into(), "gm/gds".into()],
                rows,
                action: None,
            });
        }

        // Mapping table.
        if !self.mappings.is_empty() {
            let rows: Vec<Vec<String>> = self
                .mappings
                .iter()
                .map(|m| {
                    let res = m
                        .residual
                        .map(|r| format!("{:.1}/{:.1}", r[0], r[1]))
                        .unwrap_or_else(|| "—".into());
                    let warn = if m.warnings.is_empty() {
                        String::new()
                    } else {
                        format!("⚠{}", m.warnings.len())
                    };
                    vec![
                        m.name.clone(),
                        format!("{} {:.2}/{:.2}", m.src_model, m.src_w, m.src_l),
                        format!("{:.1}", m.gm_id),
                        format!("{} {:.2}/{:.2}", m.tgt_model, m.tgt_w, m.tgt_l),
                        res,
                        warn,
                    ]
                })
                .collect();
            w.push(WidgetNode::Table {
                headers: vec![
                    "Dev".into(),
                    "Source W/L".into(),
                    "gm/Id".into(),
                    "Target W/L".into(),
                    "Δgm/Δgds %".into(),
                    "".into(),
                ],
                rows,
                action: Some("show_warnings".into()),
            });
            for m in &self.mappings {
                for warn in &m.warnings {
                    w.push(WidgetNode::Alert {
                        level: AlertLevel::Warn,
                        message: format!("{}: {warn}", m.name),
                    });
                }
            }
            w.push(WidgetNode::Button {
                label: "Apply to schematic".into(),
                action: "apply".into(),
            });
        }
        w
    }
}

struct PdkMapper {
    model: Model,
}

impl PdkMapper {
    fn new() -> Self {
        Self {
            model: Model {
                tolerance: 1.0,
                ..Model::default()
            },
        }
    }

    fn render(&self, rt: &mut PluginRuntime) -> Result<(), RuntimeError> {
        rt.update_widgets(PANEL, self.model.render())
    }

    fn pdk_root() -> PathBuf {
        std::env::var("PDK_ROOT")
            .ok()
            .filter(|s| !s.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                dirs::home_dir()
                    .unwrap_or_else(std::env::temp_dir)
                    .join(".ciel")
            })
    }

    fn scan_targets(&mut self) {
        let root = Self::pdk_root();
        let mut targets = Vec::new();
        if let Ok(entries) = std::fs::read_dir(&root) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                if name == "ciel" || name.starts_with('.') {
                    continue;
                }
                if entry.path().join("libs.tech").is_dir()
                    || entry.path().join("schemify-pdk.toml").is_file()
                {
                    targets.push(name);
                }
            }
        }
        targets.sort();
        self.model.targets = targets;
        self.reload_corners();
    }

    fn reload_corners(&mut self) {
        let Some(variant) = self.model.target_variant().map(str::to_owned) else {
            return;
        };
        let dir = Self::pdk_root().join(&variant);
        let (corners, default) = mapper::load_target_corners(&dir, &variant);
        self.model.corner_sel = corners.iter().position(|c| *c == default).unwrap_or(0);
        self.model.target_corners = corners;
    }

    fn work_dir() -> PathBuf {
        dirs::cache_dir()
            .unwrap_or_else(std::env::temp_dir)
            .join("schemify/cache/pdk-mapper")
    }

    // ── Step 1: extract source operating points ─────────────────────────

    fn extract(&mut self, rt: &mut PluginRuntime) -> Result<(), RuntimeError> {
        self.model.error = None;
        self.model.mappings.clear();
        self.model.refined = false;

        let project = rt.query_pdk()?;
        let netlist = rt.query_netlist()?;
        let instances = rt.query_instances()?;

        let Some(pdk) = project else {
            self.model.error = Some("no source PDK loaded".into());
            return self.render(rt);
        };
        self.model.source_pdk = pdk.name.clone();
        self.model.source_root = pdk.root.clone();
        self.model.source_lib = pdk.lib_path.clone();
        self.model.netlist = netlist.spice.clone();
        self.model.instance_map = netlist
            .instance_map
            .iter()
            .map(|r| (r.idx, r.refdes.clone()))
            .collect();

        // Probes: every MOS primitive instance.
        let mut probes = Vec::new();
        let mut internals: HashMap<String, String> = HashMap::new();
        for inst in &instances {
            if !MOS_PRIMS.contains(&inst.kind.as_str()) {
                continue;
            }
            let Some(refdes) = self.model.instance_map.get(&inst.idx) else {
                continue;
            };
            let Some(cell) = pdk.cells.get(&inst.kind) else {
                continue;
            };
            let subckt = cell.prefix == Some('X');
            if subckt && !internals.contains_key(&cell.model) {
                if let Some(internal) = ngspice::subckt_internal_name(
                    Path::new(&pdk.root),
                    pdk.lib_path.as_deref().map(Path::new),
                    &cell.model,
                ) {
                    internals.insert(cell.model.clone(), internal);
                }
            }
            probes.push(Probe {
                idx: inst.idx,
                refdes: refdes.clone(),
                model: cell.model.clone(),
                subckt,
            });
        }
        if probes.is_empty() {
            self.model.error = Some("no MOS devices found in the schematic".into());
            return self.render(rt);
        }

        match ngspice::run_op(
            &self.model.netlist,
            &probes,
            &internals,
            &Self::work_dir().join("src"),
        ) {
            Ok(ops) => {
                self.model.status = format!("extracted {} device op points", ops.len());
                self.model.ops = ops;
                self.model.instances = instances;
            }
            Err(e) => self.model.error = Some(e),
        }
        self.render(rt)
    }

    // ── Step 2: Stage A LUT inversion ────────────────────────────────────

    fn map(&mut self, rt: &mut PluginRuntime) -> Result<(), RuntimeError> {
        self.model.error = None;
        if self.model.ops.is_empty() {
            self.model.error = Some("run Extract first".into());
            return self.render(rt);
        }
        let Some(variant) = self.model.target_variant().map(str::to_owned) else {
            self.model.error = Some("no target PDK selected".into());
            return self.render(rt);
        };
        let Some(corner) = self.model.target_corner().map(str::to_owned) else {
            self.model.error = Some("no target corner".into());
            return self.render(rt);
        };
        let cells = mapper::load_target_cells(&Self::pdk_root().join(&variant), &variant);
        if cells.is_empty() {
            self.model.error = Some(format!("{variant}: no schemify-pdk.toml device map"));
            return self.render(rt);
        }

        let vdd_ratio = nominal_vdd(&variant) / nominal_vdd(&self.model.source_pdk);
        let mut mappings = Vec::new();
        let mut luts: HashMap<String, lut::Lut> = HashMap::new();

        for inst in &self.model.instances {
            let Some(op) = self.model.ops.get(&inst.idx) else {
                continue;
            };
            let prop = |key: &str| -> Option<String> {
                inst.props
                    .iter()
                    .find(|p| p[0].eq_ignore_ascii_case(key))
                    .map(|p| p[1].clone())
            };
            let src_model = prop("model").unwrap_or_default();
            let src_w: f64 = prop("W").and_then(|v| v.parse().ok()).unwrap_or(0.0);
            let src_l: f64 = prop("L").and_then(|v| v.parse().ok()).unwrap_or(0.0);

            let Some(cell) = cells.get(&inst.kind) else {
                mappings.push(Mapping {
                    idx: inst.idx,
                    name: inst.name.clone(),
                    primitive: inst.kind.clone(),
                    src_model,
                    src_w,
                    src_l,
                    op: op.clone(),
                    gm_id: (op.gm / op.id.max(1e-18)).abs(),
                    tgt_model: String::new(),
                    tgt_w: 0.0,
                    tgt_l: 0.0,
                    warnings: vec![format!(
                        "no equivalent device for '{}' in {variant}",
                        inst.kind
                    )],
                    residual: None,
                });
                continue;
            };

            // Target LUT: characterize-on-demand is the gm/Id plugin's job.
            let lut = match luts.entry(inst.kind.clone()) {
                std::collections::hash_map::Entry::Occupied(e) => e.into_mut(),
                std::collections::hash_map::Entry::Vacant(e) => {
                    let path = lut::glut_path(&variant, &inst.kind, &corner, 0.0);
                    match lut::Lut::load(&path) {
                        Ok(l) => e.insert(l),
                        Err(_) => {
                            self.model.error = Some(format!(
                                "no LUT for {variant}/{}/{corner} — characterize the \
                                 target device in the gm/Id panel first \
                                 (expected {})",
                                inst.kind,
                                path.display()
                            ));
                            return self.render(rt);
                        }
                    }
                }
            };

            let vds_target = match self.model.policy {
                BiasPolicy::Preserve => op.vds,
                BiasPolicy::Scale => op.vds * vdd_ratio,
            };
            let (tgt_w, tgt_l, warnings) = match mapper::invert_lut(lut, op, vds_target) {
                Ok(v) => v,
                Err(e) => {
                    mappings.push(Mapping {
                        idx: inst.idx,
                        name: inst.name.clone(),
                        primitive: inst.kind.clone(),
                        src_model,
                        src_w,
                        src_l,
                        op: op.clone(),
                        gm_id: (op.gm / op.id.max(1e-18)).abs(),
                        tgt_model: cell.model.clone(),
                        tgt_w: 0.0,
                        tgt_l: 0.0,
                        warnings: vec![e],
                        residual: None,
                    });
                    continue;
                }
            };
            mappings.push(Mapping {
                idx: inst.idx,
                name: inst.name.clone(),
                primitive: inst.kind.clone(),
                src_model,
                src_w,
                src_l,
                op: op.clone(),
                gm_id: (op.gm / op.id.max(1e-18)).abs(),
                tgt_model: cell.model.clone(),
                tgt_w,
                tgt_l,
                warnings,
                residual: None,
            });
        }

        self.model.status = format!(
            "mapped {} devices onto {variant} {corner} (Stage A)",
            mappings.iter().filter(|m| m.tgt_w > 0.0).count()
        );
        self.model.mappings = mappings;
        self.render(rt)
    }

    // ── Step 3: Stage B refinement ──────────────────────────────────────

    /// Build the candidate netlist: swap .lib to the target, then per device
    /// rewrite model + W/L on its card.
    fn candidate_netlist(&self, variant: &str, corner: &str) -> String {
        let target_lib = self.target_lib_path(variant);
        let mut out = String::new();
        for line in self.model.netlist.lines() {
            let lower = line.trim().to_ascii_lowercase();
            if lower.starts_with(".lib") {
                if let Some(lib) = &target_lib {
                    out.push_str(&format!(".lib \"{}\" {corner}\n", lib.display()));
                    continue;
                }
            }
            let mut replaced = false;
            for m in &self.model.mappings {
                if m.tgt_w <= 0.0 {
                    continue;
                }
                let Some(refdes) = self.model.instance_map.get(&m.idx) else {
                    continue;
                };
                let first = line.split_whitespace().next().unwrap_or("");
                if !first.eq_ignore_ascii_case(refdes) {
                    continue;
                }
                out.push_str(&rewrite_card(line, &m.src_model, &m.tgt_model, m.tgt_w, m.tgt_l));
                out.push('\n');
                replaced = true;
                break;
            }
            if !replaced {
                out.push_str(line);
                out.push('\n');
            }
        }
        out
    }

    fn target_lib_path(&self, variant: &str) -> Option<PathBuf> {
        let dir = Self::pdk_root().join(variant);
        let manifest = std::fs::read_to_string(dir.join("schemify-pdk.toml"))
            .ok()
            .or_else(|| mapper::builtin_manifest(variant).map(str::to_owned))?;
        let value = manifest.parse::<toml::Value>().ok()?;
        let lib = value.get("models")?.get("lib")?.as_str()?;
        Some(dir.join(lib))
    }

    fn refine(&mut self, rt: &mut PluginRuntime) -> Result<(), RuntimeError> {
        self.model.error = None;
        if self.model.mappings.iter().all(|m| m.tgt_w <= 0.0) {
            self.model.error = Some("run Map first".into());
            return self.render(rt);
        }
        let variant = self.model.target_variant().unwrap_or_default().to_owned();
        let corner = self.model.target_corner().unwrap_or_default().to_owned();
        let root = Self::pdk_root().join(&variant);
        let target_lib = self.target_lib_path(&variant);
        let cells = mapper::load_target_cells(&root, &variant);

        // Internal M names for the target models.
        let mut internals: HashMap<String, String> = HashMap::new();
        for cell in cells.values() {
            if cell.subckt && !internals.contains_key(&cell.model) {
                if let Some(internal) = ngspice::subckt_internal_name(
                    &root,
                    target_lib.as_deref(),
                    &cell.model,
                ) {
                    internals.insert(cell.model.clone(), internal);
                }
            }
        }

        let tol = self.model.tolerance;
        let max_iter = 8;
        for iter in 0..max_iter {
            let netlist = self.candidate_netlist(&variant, &corner);
            let probes: Vec<Probe> = self
                .model
                .mappings
                .iter()
                .filter(|m| m.tgt_w > 0.0)
                .filter_map(|m| {
                    Some(Probe {
                        idx: m.idx,
                        refdes: self.model.instance_map.get(&m.idx)?.clone(),
                        model: m.tgt_model.clone(),
                        subckt: cells.get(&m.primitive).map(|c| c.subckt).unwrap_or(true),
                    })
                })
                .collect();

            let measured = match ngspice::run_op(
                &netlist,
                &probes,
                &internals,
                &Self::work_dir().join("tgt"),
            ) {
                Ok(ops) => ops,
                Err(e) => {
                    self.model.error = Some(format!("refine iteration {iter}: {e}"));
                    return self.render(rt);
                }
            };

            let mut worst: f64 = 0.0;
            for m in self.model.mappings.iter_mut().filter(|m| m.tgt_w > 0.0) {
                let Some(meas) = measured.get(&m.idx) else {
                    continue;
                };
                let r = mapper::residuals(meas, &m.op);
                worst = worst.max(r[0]).max(r[1]);
                m.residual = Some(r);
                if r[0] > tol || r[1] > tol {
                    let (w, l) = mapper::refine_step(m.tgt_w, m.tgt_l, meas, &m.op, 0.7);
                    m.tgt_w = w;
                    m.tgt_l = l;
                }
            }
            if worst <= tol {
                self.model.status =
                    format!("refined: all residuals ≤ {tol}% after {} iterations", iter + 1);
                self.model.refined = true;
                return self.render(rt);
            }
        }
        self.model.status = format!(
            "refinement stopped after {max_iter} iterations — residual matrix in table"
        );
        self.model.refined = true;
        self.render(rt)
    }

    // ── Step 4: apply ────────────────────────────────────────────────────

    fn apply(&mut self, rt: &mut PluginRuntime) -> Result<(), RuntimeError> {
        let mut applied = 0;
        for m in &self.model.mappings {
            if m.tgt_w <= 0.0 {
                continue;
            }
            for (key, value) in [
                ("model", m.tgt_model.clone()),
                ("W", format!("{:.4}", m.tgt_w)),
                ("L", format!("{:.4}", m.tgt_l)),
            ] {
                rt.dispatch_command(json!({
                    "SetInstanceProp": {"idx": m.idx, "key": key, "value": value}
                }))?;
            }
            applied += 1;
        }
        rt.set_status(format!(
            "PDK Mapper: applied {applied} devices — switch the project PDK to \
             the target (PDK Switcher) to simulate"
        ))
    }
}

/// Rewrite one SPICE card: swap the model token and the W=/L= params.
/// Values are in µm to match schematic property conventions.
fn rewrite_card(line: &str, src_model: &str, tgt_model: &str, w_um: f64, l_um: f64) -> String {
    line.split_whitespace()
        .map(|tok| {
            let lower = tok.to_ascii_lowercase();
            if !src_model.is_empty() && tok.eq_ignore_ascii_case(src_model) {
                tgt_model.to_owned()
            } else if lower.starts_with("w=") {
                format!("W={w_um:.4}u")
            } else if lower.starts_with("l=") {
                format!("L={l_um:.4}u")
            } else {
                tok.to_owned()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

impl Plugin for PdkMapper {
    fn on_initialize(
        &mut self,
        rt: &mut PluginRuntime,
        _event: InitializeEvent,
    ) -> Result<(), RuntimeError> {
        rt.register_panel(PANEL, PanelLayout::RightSidebar, 11, true)?;
        rt.register_command(
            "map_to_target_pdk",
            "Map the current schematic onto the selected target PDK",
            None,
        )?;
        if let Ok(Some(pdk)) = rt.query_pdk() {
            self.model.source_pdk = pdk.name;
        }
        self.scan_targets();
        self.render(rt)
    }

    fn on_ui_action(&mut self, rt: &mut PluginRuntime, action: UiAction) -> Result<(), RuntimeError> {
        let as_usize =
            |a: &UiAction| a.payload.as_ref().and_then(|v| v.as_u64()).unwrap_or(0) as usize;
        match action.action.as_str() {
            "target" => {
                self.model.target_sel = as_usize(&action);
                self.reload_corners();
            }
            "corner" => self.model.corner_sel = as_usize(&action),
            "policy" => {
                self.model.policy = if as_usize(&action) == 0 {
                    BiasPolicy::Preserve
                } else {
                    BiasPolicy::Scale
                }
            }
            "tolerance" => {
                self.model.tolerance = action
                    .payload
                    .as_ref()
                    .and_then(|v| v.as_f64())
                    .unwrap_or(1.0)
            }
            "extract" => return self.extract(rt),
            "map" => return self.map(rt),
            "refine" => return self.refine(rt),
            "apply" => return self.apply(rt),
            "show_warnings" => return Ok(()),
            _ => return Ok(()),
        }
        self.render(rt)
    }

    fn on_command(
        &mut self,
        rt: &mut PluginRuntime,
        command: CommandInvocation,
    ) -> Result<(), RuntimeError> {
        if command.command == "map_to_target_pdk" {
            self.extract(rt)?;
            self.map(rt)?;
        }
        Ok(())
    }
}

fn main() -> Result<(), RuntimeError> {
    PluginRuntime::stdio().run(&mut PdkMapper::new())
}
