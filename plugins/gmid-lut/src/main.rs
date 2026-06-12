//! gm/Id Characterization plugin: sweeps PDK devices through the vendored
//! GmIDVisualizer tool, stores `.glut` lookup tables, shows the SVG figures
//! in a panel, and pushes the design curves into Schemify's waveform viewer.

mod lut;
mod raw_out;
mod runner;
mod sink;

use std::sync::{Arc, Mutex};

use schemify_plugins::sdk::{
    AlertLevel, CommandInvocation, InitializeEvent, PanelLayout, PdkRecord, Plugin,
    PluginRuntime, RuntimeError, UiAction, WidgetNode,
};
use serde_json::json;

use lut::{Lut, Quantity};
use runner::SweepRequest;
use sink::HostSink;

const PANEL: &str = "gm/Id";

/// MOSFET-ish primitives worth characterizing.
const MOS_PRIMS: [&str; 6] = ["nmos4", "pmos4", "nmos3", "pmos3", "nmoshv4", "pmoshv4"];

#[derive(Default)]
struct Model {
    pdk: Option<PdkRecord>,
    devices: Vec<String>, // primitive names present in the PDK
    device_sel: usize,
    corner_sel: usize,
    l_text: String, // comma-separated L list in µm
    vdd: f64,
    vsb: f64,
    running: bool,
    progress: Option<(usize, usize)>, // (current L index, total)
    error: Option<String>,
    svgs: Vec<String>,
    svg_tab: usize,
    lut: Option<Lut>,
    cursor_gmid: f64,
    cursor_l: usize,
}

impl Model {
    fn render(&self) -> Vec<WidgetNode> {
        let mut w = vec![WidgetNode::Heading("gm/Id Characterization".into())];

        let Some(pdk) = &self.pdk else {
            w.push(WidgetNode::Alert {
                level: AlertLevel::Warn,
                message: "No PDK loaded. Activate one (PDK Switcher) and reopen.".into(),
            });
            w.push(WidgetNode::Button {
                label: "Reload PDK info".into(),
                action: "reload".into(),
            });
            return w;
        };

        w.push(WidgetNode::KeyValue {
            entries: vec![["PDK".into(), pdk.name.clone()]],
        });
        w.push(WidgetNode::Dropdown {
            label: "Device".into(),
            options: self.devices.clone(),
            selected: self.device_sel,
            action: "device".into(),
        });
        w.push(WidgetNode::Dropdown {
            label: "Corner".into(),
            options: pdk.corners.clone(),
            selected: self.corner_sel,
            action: "corner".into(),
        });
        w.push(WidgetNode::TextInput {
            label: "L (µm)".into(),
            value: self.l_text.clone(),
            placeholder: Some("0.15, 0.3, 0.5, 1.0".into()),
            action: "lengths".into(),
        });
        w.push(WidgetNode::Horizontal {
            children: vec![
                WidgetNode::NumberInput {
                    label: "Vdd".into(),
                    value: self.vdd,
                    min: Some(0.5),
                    max: Some(6.0),
                    step: Some(0.1),
                    action: "vdd".into(),
                },
                WidgetNode::NumberInput {
                    label: "VSB".into(),
                    value: self.vsb,
                    min: Some(-2.0),
                    max: Some(2.0),
                    step: Some(0.1),
                    action: "vsb".into(),
                },
            ],
        });

        if self.running {
            let (cur, total) = self.progress.unwrap_or((0, 1));
            w.push(WidgetNode::ProgressBar {
                label: Some(format!("sweeping L {}/{total}", cur + 1)),
                value: cur as f32 / total.max(1) as f32,
                color: None,
            });
        } else {
            w.push(WidgetNode::Button {
                label: "Characterize".into(),
                action: "characterize".into(),
            });
        }

        if let Some(err) = &self.error {
            w.push(WidgetNode::Alert {
                level: AlertLevel::Error,
                message: err.clone(),
            });
        }

        if let Some(lut) = &self.lut {
            w.push(WidgetNode::Separator);
            w.push(WidgetNode::Button {
                label: "Open curves in Wave Viewer".into(),
                action: "wave".into(),
            });

            // Software cursor: gm/Id target → interpolated design point.
            let mut cursor = vec![
                WidgetNode::Dropdown {
                    label: "L".into(),
                    options: lut.l_um.iter().map(|l| format!("{l} µm")).collect(),
                    selected: self.cursor_l.min(lut.l_um.len() - 1),
                    action: "cursor_l".into(),
                },
                WidgetNode::NumberInput {
                    label: "gm/Id target (1/V)".into(),
                    value: self.cursor_gmid,
                    min: Some(1.0),
                    max: Some(30.0),
                    step: Some(0.5),
                    action: "cursor".into(),
                },
            ];
            let li = self.cursor_l.min(lut.l_um.len() - 1);
            let d = lut.vds_index(self.vdd / 2.0);
            match lut.vgs_for_gm_id(li, d, self.cursor_gmid) {
                Some(vgs) => {
                    let id = lut.at_vgs(li, d, vgs, Quantity::IdW);
                    let gm = lut.at_vgs(li, d, vgs, Quantity::GmW);
                    let gds = lut.at_vgs(li, d, vgs, Quantity::GdsW);
                    cursor.push(WidgetNode::KeyValue {
                        entries: vec![
                            ["VGS".into(), format!("{vgs:.4} V")],
                            ["Jd".into(), format!("{id:.3e} A/µm")],
                            ["gm/W".into(), format!("{gm:.3e} S/µm")],
                            ["gm/gds".into(), format!("{:.1}", gm / gds.max(1e-18))],
                        ],
                    });
                }
                None => cursor.push(WidgetNode::Label("target out of range".into())),
            }
            w.push(WidgetNode::Section {
                label: format!("Cursor @ VDS={:.2}V", lut.vds[d]),
                collapsed: false,
                children: cursor,
            });

            // Figures from the last L run.
            if !self.svgs.is_empty() {
                let labels: Vec<String> = self
                    .svgs
                    .iter()
                    .map(|p| {
                        std::path::Path::new(p)
                            .file_stem()
                            .map(|s| s.to_string_lossy().to_string())
                            .unwrap_or_default()
                    })
                    .collect();
                let children: Vec<Vec<WidgetNode>> = self
                    .svgs
                    .iter()
                    .map(|p| {
                        vec![WidgetNode::Image {
                            path: p.clone(),
                            width: Some(420.0),
                            action: None,
                        }]
                    })
                    .collect();
                w.push(WidgetNode::Section {
                    label: "Figures".into(),
                    collapsed: true,
                    children: vec![WidgetNode::Tabs {
                        labels,
                        selected: self.svg_tab.min(self.svgs.len() - 1),
                        action: "svg_tab".into(),
                        children,
                    }],
                });
            }
        }
        w
    }

    fn parse_lengths(&self) -> Vec<f64> {
        self.l_text
            .split(',')
            .filter_map(|s| s.trim().parse::<f64>().ok())
            .filter(|l| *l > 0.0)
            .collect()
    }

    fn request(&self) -> Option<SweepRequest> {
        let pdk = self.pdk.as_ref()?;
        let device = self.devices.get(self.device_sel)?.clone();
        let cell = pdk.cells.get(&device)?;
        let corner = pdk
            .corners
            .get(self.corner_sel)
            .cloned()
            .or_else(|| pdk.default_corner.clone())?;
        let l_um = self.parse_lengths();
        if l_um.is_empty() {
            return None;
        }
        Some(SweepRequest {
            pdk: pdk.name.clone(),
            device,
            model: cell.model.clone(),
            subckt: cell.prefix == Some('X'),
            lib_path: pdk.lib_path.clone()?,
            corner,
            vdd: self.vdd,
            vsb: self.vsb,
            temp_c: 27.0,
            l_um,
            vgs_steps: 181,
            vds_steps: 18,
        })
    }
}

struct GmIdPlugin {
    model: Arc<Mutex<Model>>,
    sink: HostSink,
    worker: Option<std::thread::JoinHandle<()>>,
}

impl GmIdPlugin {
    fn new() -> Self {
        Self {
            model: Arc::new(Mutex::new(Model {
                l_text: "0.15, 0.3, 0.5, 1.0".into(),
                vdd: 1.8,
                cursor_gmid: 15.0,
                ..Model::default()
            })),
            sink: HostSink,
            worker: None,
        }
    }

    fn render(&self, rt: &mut PluginRuntime) -> Result<(), RuntimeError> {
        let widgets = self.model.lock().unwrap().render();
        rt.update_widgets(PANEL, widgets)
    }

    fn reload_pdk(&self, rt: &mut PluginRuntime) -> Result<(), RuntimeError> {
        let pdk = rt.query_pdk()?;
        let mut m = self.model.lock().unwrap();
        m.devices = pdk
            .as_ref()
            .map(|p| {
                MOS_PRIMS
                    .iter()
                    .filter(|prim| p.cells.contains_key(**prim))
                    .map(|s| (*s).to_owned())
                    .collect()
            })
            .unwrap_or_default();
        m.device_sel = 0;
        m.corner_sel = pdk
            .as_ref()
            .and_then(|p| {
                let def = p.default_corner.clone()?;
                p.corners.iter().position(|c| *c == def)
            })
            .unwrap_or(0);
        m.pdk = pdk;
        Ok(())
    }

    fn characterize(&mut self, rt: &mut PluginRuntime) -> Result<(), RuntimeError> {
        if self.worker.as_ref().is_some_and(|w| !w.is_finished()) {
            return rt.set_status("Characterization already running");
        }
        let Some(req) = self.model.lock().unwrap().request() else {
            return rt.set_status("gm/Id: select a device and give at least one L");
        };
        {
            let mut m = self.model.lock().unwrap();
            m.running = true;
            m.error = None;
            m.progress = Some((0, req.l_um.len()));
        }
        let (model, sink) = (self.model.clone(), self.sink.clone());
        self.worker = Some(std::thread::spawn(move || {
            let total = req.l_um.len();
            let result = runner::characterize(&req, |li| {
                let mut m = model.lock().unwrap();
                m.progress = Some((li, total));
                sink.update_widgets(PANEL, m.render());
            });
            let mut m = model.lock().unwrap();
            m.running = false;
            m.progress = None;
            match result {
                Ok((lut, svgs)) => {
                    let glut = lut::glut_path(&req.pdk, &req.device, &req.corner, req.vsb);
                    if let Err(e) = lut.save(&glut) {
                        sink.log("error", format!("glut save: {e}"));
                    }
                    match raw_out::write_raw(&lut) {
                        Ok(p) => sink.set_status(format!(
                            "gm/Id: {} done — curves at {}",
                            req.model,
                            p.display()
                        )),
                        Err(e) => sink.log("error", format!("raw write: {e}")),
                    }
                    m.svgs = svgs
                        .into_iter()
                        .map(|p| {
                            std::fs::canonicalize(&p)
                                .unwrap_or(p)
                                .display()
                                .to_string()
                        })
                        .collect();
                    m.lut = Some(lut);
                }
                Err(e) => m.error = Some(e),
            }
            sink.update_widgets(PANEL, m.render());
        }));
        self.render(rt)
    }

    /// Open the curves in the waveform viewer: WaveOpen + default traces.
    fn open_in_wave(&self, rt: &mut PluginRuntime) -> Result<(), RuntimeError> {
        let m = self.model.lock().unwrap();
        let Some(lut) = &m.lut else {
            return rt.set_status("Characterize first");
        };
        let path = raw_out::raw_path(lut);
        if !path.exists() {
            return rt.set_status("No curves file yet — characterize first");
        }
        let traces = raw_out::default_traces(lut);
        drop(m);
        rt.dispatch_command(json!({"WaveOpen": {"path": path.display().to_string()}}))?;
        for (expr, block) in traces {
            rt.dispatch_command(json!({
                "WaveAddTrace": {"expr": expr, "block": block}
            }))?;
        }
        rt.set_status("gm/Id curves opened in wave viewer")
    }
}

impl Plugin for GmIdPlugin {
    fn on_initialize(
        &mut self,
        rt: &mut PluginRuntime,
        _event: InitializeEvent,
    ) -> Result<(), RuntimeError> {
        rt.register_panel(PANEL, PanelLayout::RightSidebar, 12, true)?;
        rt.register_command(
            "characterize_device",
            "Run a gm/Id characterization sweep for the selected device",
            None,
        )?;
        self.reload_pdk(rt)?;
        // PDK supply heuristic for the sweep ceiling.
        {
            let mut m = self.model.lock().unwrap();
            if m.pdk.as_ref().map(|p| p.name.starts_with("gf180")) == Some(true) {
                m.vdd = 3.3;
            }
        }
        self.render(rt)
    }

    fn on_ui_action(&mut self, rt: &mut PluginRuntime, action: UiAction) -> Result<(), RuntimeError> {
        let as_usize =
            |a: &UiAction| a.payload.as_ref().and_then(|v| v.as_u64()).unwrap_or(0) as usize;
        let as_f64 = |a: &UiAction| a.payload.as_ref().and_then(|v| v.as_f64()).unwrap_or(0.0);
        match action.action.as_str() {
            "device" => self.model.lock().unwrap().device_sel = as_usize(&action),
            "corner" => self.model.lock().unwrap().corner_sel = as_usize(&action),
            "lengths" => {
                self.model.lock().unwrap().l_text = action
                    .payload
                    .as_ref()
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_owned()
            }
            "vdd" => self.model.lock().unwrap().vdd = as_f64(&action),
            "vsb" => self.model.lock().unwrap().vsb = as_f64(&action),
            "svg_tab" => self.model.lock().unwrap().svg_tab = as_usize(&action),
            "cursor" => self.model.lock().unwrap().cursor_gmid = as_f64(&action),
            "cursor_l" => self.model.lock().unwrap().cursor_l = as_usize(&action),
            "characterize" => return self.characterize(rt),
            "wave" => return self.open_in_wave(rt),
            "reload" => {
                self.reload_pdk(rt)?;
            }
            _ => return Ok(()),
        }
        self.render(rt)
    }

    fn on_command(
        &mut self,
        rt: &mut PluginRuntime,
        command: CommandInvocation,
    ) -> Result<(), RuntimeError> {
        if command.command == "characterize_device" {
            self.characterize(rt)?;
        }
        Ok(())
    }
}

fn main() -> Result<(), RuntimeError> {
    PluginRuntime::stdio().run(&mut GmIdPlugin::new())
}
