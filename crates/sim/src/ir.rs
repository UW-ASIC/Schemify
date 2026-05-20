use std::collections::HashMap;
use serde::{Serialize, Deserialize};

// ── Core IR types (mirrors PySpice circuit-ir.schema.json) ──

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CircuitIR {
    pub top: Subcircuit,
    pub testbench: Option<Testbench>,
    pub subcircuit_defs: Vec<Subcircuit>,
    pub model_libraries: Vec<ModelLibrary>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Subcircuit {
    pub name: String,
    pub ports: Vec<Port>,
    pub parameters: Vec<ParamDef>,
    pub components: Vec<Component>,
    pub instances: Vec<Instance>,
    pub models: Vec<ModelDef>,
    pub raw_spice: Vec<String>,
    pub includes: Vec<String>,
    pub libs: Vec<(String, String)>,
    pub osdi_loads: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Port {
    pub name: String,
    pub direction: PortDirection,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum PortDirection {
    InOut,
    Input,
    Output,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ParamDef {
    pub name: String,
    pub default: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Instance {
    pub name: String,
    pub subcircuit: String,
    pub port_mapping: Vec<String>,
    pub parameters: Vec<(String, String)>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelDef {
    pub name: String,
    pub kind: String,
    pub parameters: Vec<(String, String)>,
}

// ── Component types ──

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Component {
    Resistor { name: String, n1: String, n2: String, value: IrValue, params: Vec<(String, String)> },
    Capacitor { name: String, n1: String, n2: String, value: IrValue, params: Vec<(String, String)> },
    Inductor { name: String, n1: String, n2: String, value: IrValue, params: Vec<(String, String)> },
    MutualInductor { name: String, inductor1: String, inductor2: String, coupling: f64 },
    VoltageSource { name: String, np: String, nm: String, value: IrValue, waveform: Option<IrWaveform> },
    CurrentSource { name: String, np: String, nm: String, value: IrValue, waveform: Option<IrWaveform> },
    BehavioralVoltage { name: String, np: String, nm: String, expression: String },
    BehavioralCurrent { name: String, np: String, nm: String, expression: String },
    Vcvs { name: String, np: String, nm: String, ncp: String, ncm: String, gain: f64 },
    Vccs { name: String, np: String, nm: String, ncp: String, ncm: String, transconductance: f64 },
    Cccs { name: String, np: String, nm: String, vsense: String, gain: f64 },
    Ccvs { name: String, np: String, nm: String, vsense: String, transresistance: f64 },
    Diode { name: String, np: String, nm: String, model: String, params: Vec<(String, String)> },
    Bjt { name: String, nc: String, nb: String, ne: String, model: String, params: Vec<(String, String)> },
    Mosfet { name: String, nd: String, ng: String, ns: String, nb: String, model: String, params: Vec<(String, String)> },
    Jfet { name: String, nd: String, ng: String, ns: String, model: String, params: Vec<(String, String)> },
    Mesfet { name: String, nd: String, ng: String, ns: String, model: String, params: Vec<(String, String)> },
    VSwitch { name: String, np: String, nm: String, ncp: String, ncm: String, model: String },
    ISwitch { name: String, np: String, nm: String, vcontrol: String, model: String },
    TLine { name: String, inp: String, inm: String, outp: String, outm: String, z0: f64, td: f64 },
    Xspice { name: String, connections: Vec<String>, model: String },
    RawSpice { line: String },
}

// ── Value and waveform types ──

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum IrValue {
    Numeric { value: f64 },
    Expression { expr: String },
    Raw { text: String },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum IrWaveform {
    Sin { offset: f64, amplitude: f64, frequency: f64, delay: f64, damping: f64, phase: f64 },
    Pulse { initial: f64, pulsed: f64, delay: f64, rise_time: f64, fall_time: f64, pulse_width: f64, period: f64 },
    Pwl { values: Vec<(f64, f64)> },
    Exp { initial: f64, pulsed: f64, rise_delay: f64, rise_tau: f64, fall_delay: f64, fall_tau: f64 },
    Sffm { offset: f64, amplitude: f64, carrier_freq: f64, modulation_index: f64, signal_freq: f64 },
    Am { amplitude: f64, offset: f64, modulating_freq: f64, carrier_freq: f64, delay: f64 },
}

// ── Testbench ──

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Testbench {
    pub dut: String,
    pub stimulus: Vec<Component>,
    pub analyses: Vec<Analysis>,
    pub options: SimOptions,
    pub saves: Vec<String>,
    pub measures: Vec<String>,
    pub temperature: Option<f64>,
    pub nominal_temperature: Option<f64>,
    pub initial_conditions: Vec<(String, f64)>,
    pub node_sets: Vec<(String, f64)>,
    pub step_params: Vec<StepParam>,
    pub extra_lines: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StepParam {
    pub param: String,
    pub start: f64,
    pub stop: f64,
    pub step: f64,
    pub sweep_type: Option<String>,
}

// ── Analysis types ──

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Analysis {
    Op,
    Dc { sweeps: Vec<DcSweep> },
    Ac { variation: String, points: u32, start: f64, stop: f64 },
    Transient { step: f64, stop: f64, start: Option<f64>, max_step: Option<f64>, uic: bool },
    Noise { output: String, reference: String, source: String, variation: String, points: u32, start: f64, stop: f64, points_per_summary: Option<u32> },
    Tf { output: String, source: String },
    Sensitivity { output: String, ac: Option<AcSweepParams> },
    PoleZero { node1: String, node2: String, node3: String, node4: String, tf_type: String, pz_type: String },
    Distortion { variation: String, points: u32, start: f64, stop: f64, f2overf1: Option<f64> },
    Pss { fundamental: f64, stabilization: f64, observe_node: String, points_per_period: u32, harmonics: u32 },
    HarmonicBalance { frequencies: Vec<f64>, harmonics: Vec<u32> },
    SPar { variation: String, points: u32, start: f64, stop: f64 },
    Stability { probe: String, variation: String, points: u32, start: f64, stop: f64 },
    TransientNoise { step: f64, stop: f64 },
    Fourier { fundamental: f64, outputs: Vec<String>, num_harmonics: Option<u32> },
    XyceSampling { num_samples: u32, distributions: Vec<(String, String)> },
    XyceEmbeddedSampling { num_samples: u32, distributions: Vec<(String, String)> },
    XycePce { num_samples: u32, distributions: Vec<(String, String)>, order: u32 },
    XyceFft { signal: String, np: u32, start: f64, stop: f64, window: String, format: String },
    SpectreSweep { param: String, start: f64, stop: f64, step: f64, inner: String, inner_type: String },
    SpectreMonteCarlo { iterations: u32, inner: String, inner_type: String, seed: Option<u64> },
    SpectrePac { pss_fundamental: f64, pss_stabilization: f64, pss_harmonics: u32, variation: String, points: u32, start: f64, stop: f64, sweep_type: String },
    SpectrePnoise { pss_fundamental: f64, pss_stabilization: f64, pss_harmonics: u32, output: String, reference: String, variation: String, points: u32, start: f64, stop: f64 },
    SpectrePxf { pss_fundamental: f64, pss_stabilization: f64, pss_harmonics: u32, output: String, source: String, variation: String, points: u32, start: f64, stop: f64 },
    SpectrePstb { pss_fundamental: f64, pss_stabilization: f64, pss_harmonics: u32, probe: String, variation: String, points: u32, start: f64, stop: f64 },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DcSweep {
    pub source: String,
    pub start: f64,
    pub stop: f64,
    pub step: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AcSweepParams {
    pub variation: String,
    pub points: u32,
    pub start: f64,
    pub stop: f64,
}

// ── Simulation options ──

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SimOptions {
    pub portable: Vec<(String, String)>,
    pub backend_specific: HashMap<String, Vec<(String, String)>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelLibrary {
    pub name: String,
    pub path: String,
    pub corner: Option<String>,
    pub backend_paths: HashMap<String, String>,
}

// ── Defaults & constructors ──

impl Default for Subcircuit {
    fn default() -> Self {
        Self {
            name: String::new(),
            ports: Vec::new(),
            parameters: Vec::new(),
            components: Vec::new(),
            instances: Vec::new(),
            models: Vec::new(),
            raw_spice: Vec::new(),
            includes: Vec::new(),
            libs: Vec::new(),
            osdi_loads: Vec::new(),
        }
    }
}

impl Default for Testbench {
    fn default() -> Self {
        Self {
            dut: String::new(),
            stimulus: Vec::new(),
            analyses: Vec::new(),
            options: SimOptions::default(),
            saves: Vec::new(),
            measures: Vec::new(),
            temperature: None,
            nominal_temperature: None,
            initial_conditions: Vec::new(),
            node_sets: Vec::new(),
            step_params: Vec::new(),
            extra_lines: Vec::new(),
        }
    }
}

impl CircuitIR {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            top: Subcircuit { name: name.into(), ..Subcircuit::default() },
            testbench: None,
            subcircuit_defs: Vec::new(),
            model_libraries: Vec::new(),
        }
    }

    pub fn to_json(&self) -> serde_json::Result<String> {
        serde_json::to_string_pretty(self)
    }

    pub fn from_json(json: &str) -> serde_json::Result<Self> {
        serde_json::from_str(json)
    }
}

impl IrValue {
    pub fn numeric(v: f64) -> Self {
        Self::Numeric { value: v }
    }

    pub fn expr(e: impl Into<String>) -> Self {
        Self::Expression { expr: e.into() }
    }

    pub fn raw(t: impl Into<String>) -> Self {
        Self::Raw { text: t.into() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_voltage_divider() {
        let ir = CircuitIR {
            top: Subcircuit {
                name: "Voltage Divider".into(),
                components: vec![
                    Component::VoltageSource {
                        name: "in".into(),
                        np: "input".into(),
                        nm: "0".into(),
                        value: IrValue::numeric(10.0),
                        waveform: None,
                    },
                    Component::Resistor {
                        name: "1".into(),
                        n1: "input".into(),
                        n2: "output".into(),
                        value: IrValue::numeric(10_000.0),
                        params: vec![],
                    },
                    Component::Resistor {
                        name: "2".into(),
                        n1: "output".into(),
                        n2: "0".into(),
                        value: IrValue::numeric(10_000.0),
                        params: vec![],
                    },
                ],
                ..Subcircuit::default()
            },
            testbench: Some(Testbench {
                dut: "Voltage Divider".into(),
                analyses: vec![Analysis::Op],
                ..Testbench::default()
            }),
            subcircuit_defs: vec![],
            model_libraries: vec![],
        };

        let json = ir.to_json().unwrap();
        let parsed: CircuitIR = CircuitIR::from_json(&json).unwrap();
        assert_eq!(ir, parsed);
    }

    #[test]
    fn construct_mosfet() {
        let m = Component::Mosfet {
            name: "M1".into(),
            nd: "d".into(),
            ng: "g".into(),
            ns: "s".into(),
            nb: "b".into(),
            model: "nmos_3p3".into(),
            params: vec![
                ("W".into(), "1u".into()),
                ("L".into(), "180n".into()),
            ],
        };
        let json = serde_json::to_string(&m).unwrap();
        assert!(json.contains("\"type\":\"Mosfet\""));
    }

    #[test]
    fn construct_analyses() {
        let analyses = vec![
            Analysis::Op,
            Analysis::Dc { sweeps: vec![DcSweep { source: "V1".into(), start: 0.0, stop: 5.0, step: 0.1 }] },
            Analysis::Ac { variation: "dec".into(), points: 100, start: 1.0, stop: 1e9 },
            Analysis::Transient { step: 1e-9, stop: 1e-3, start: None, max_step: None, uic: false },
        ];
        for a in &analyses {
            let json = serde_json::to_string(a).unwrap();
            assert!(!json.is_empty());
        }
    }

    #[test]
    fn waveform_sin() {
        let w = IrWaveform::Sin {
            offset: 0.0, amplitude: 1.0, frequency: 1e6,
            delay: 0.0, damping: 0.0, phase: 0.0,
        };
        let json = serde_json::to_string(&w).unwrap();
        assert!(json.contains("\"type\":\"Sin\""));
    }
}
