//! Circuit IR types mirroring PySpice-rs's `CircuitIR` schema.
//!
//! SchemifyRS serializes these to JSON; PySpice-rs deserializes and runs.
//! No Rust crate dependency — JSON is the contract.

use std::collections::HashMap;
use serde::{Serialize, Deserialize};

// ── Top-level ──

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CircuitIR {
    pub top: Subcircuit,
    pub testbench: Option<Testbench>,
    pub subcircuit_defs: Vec<Subcircuit>,
    pub model_libraries: Vec<ModelLibrary>,
}

// ── Subcircuit ──

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
    #[serde(default)]
    pub verilog_blocks: Vec<VerilogBlock>,
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

// ── Verilog blocks ──

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VerilogBlock {
    pub source: String,
    pub mode: VerilogMode,
    pub instance_name: String,
    pub connections: HashMap<String, VerilogConnection>,
    pub pdk: Option<String>,
    pub liberty: Option<String>,
    pub spice_models: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum VerilogMode {
    Simulate,
    Synthesize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum VerilogConnection {
    Single(String),
    Bus(Vec<String>),
}

// ── Components ──

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

// ── Values & waveforms ──

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

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SimOptions {
    pub portable: Vec<(String, String)>,
    pub backend_specific: HashMap<String, Vec<(String, String)>>,
}

// ── Analysis ──

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Analysis {
    Op,
    Dc { sweeps: Vec<DcSweep> },
    Ac { variation: String, points: u32, start: f64, stop: f64 },
    Transient { step: f64, stop: f64, start: Option<f64>, max_step: Option<f64>, uic: bool },
    Noise {
        output: String, reference: String, source: String,
        variation: String, points: u32, start: f64, stop: f64,
        points_per_summary: Option<u32>,
    },
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
    // Vendor-specific
    XyceSampling { num_samples: u32, distributions: Vec<(String, String)> },
    XyceEmbeddedSampling { num_samples: u32, distributions: Vec<(String, String)> },
    XycePce { num_samples: u32, distributions: Vec<(String, String)>, order: u32 },
    XyceFft { signal: String, np: u32, start: f64, stop: f64, window: String, format: String },
    SpectreSweep { param: String, start: f64, stop: f64, step: f64, inner: String, inner_type: String },
    SpectreMonteCarlo { iterations: u32, inner: String, inner_type: String, seed: Option<u64> },
    SpectrePac {
        pss_fundamental: f64, pss_stabilization: f64, pss_harmonics: u32,
        variation: String, points: u32, start: f64, stop: f64, sweep_type: String,
    },
    SpectrePnoise {
        pss_fundamental: f64, pss_stabilization: f64, pss_harmonics: u32,
        output: String, reference: String,
        variation: String, points: u32, start: f64, stop: f64,
    },
    SpectrePxf {
        pss_fundamental: f64, pss_stabilization: f64, pss_harmonics: u32,
        output: String, source: String,
        variation: String, points: u32, start: f64, stop: f64,
    },
    SpectrePstb {
        pss_fundamental: f64, pss_stabilization: f64, pss_harmonics: u32,
        probe: String, variation: String, points: u32, start: f64, stop: f64,
    },
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

// ── Model libraries ──

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelLibrary {
    pub name: String,
    pub path: String,
    pub corner: Option<String>,
    pub backend_paths: HashMap<String, String>,
}

// ── Convenience constructors ──

impl Subcircuit {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            ports: Vec::new(),
            parameters: Vec::new(),
            components: Vec::new(),
            instances: Vec::new(),
            models: Vec::new(),
            raw_spice: Vec::new(),
            includes: Vec::new(),
            libs: Vec::new(),
            osdi_loads: Vec::new(),
            verilog_blocks: Vec::new(),
        }
    }
}

impl CircuitIR {
    pub fn new(top: Subcircuit) -> Self {
        Self {
            top,
            testbench: None,
            subcircuit_defs: Vec::new(),
            model_libraries: Vec::new(),
        }
    }
}

impl IrValue {
    pub fn numeric(v: f64) -> Self { Self::Numeric { value: v } }
    pub fn expr(e: impl Into<String>) -> Self { Self::Expression { expr: e.into() } }
    pub fn raw(t: impl Into<String>) -> Self { Self::Raw { text: t.into() } }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resistor_roundtrip() {
        let comp = Component::Resistor {
            name: "R1".into(),
            n1: "a".into(),
            n2: "b".into(),
            value: IrValue::numeric(10_000.0),
            params: vec![],
        };
        let json = serde_json::to_string(&comp).unwrap();
        assert!(json.contains(r#""type":"Resistor"#));
        let back: Component = serde_json::from_str(&json).unwrap();
        assert_eq!(comp, back);
    }

    #[test]
    fn mosfet_with_params() {
        let comp = Component::Mosfet {
            name: "M1".into(),
            nd: "drain".into(),
            ng: "gate".into(),
            ns: "source".into(),
            nb: "bulk".into(),
            model: "nmos_3p3".into(),
            params: vec![
                ("W".into(), "1u".into()),
                ("L".into(), "180n".into()),
            ],
        };
        let json = serde_json::to_string(&comp).unwrap();
        let back: Component = serde_json::from_str(&json).unwrap();
        assert_eq!(comp, back);
    }

    #[test]
    fn voltage_source_with_pulse() {
        let comp = Component::VoltageSource {
            name: "V1".into(),
            np: "vdd".into(),
            nm: "0".into(),
            value: IrValue::numeric(0.0),
            waveform: Some(IrWaveform::Pulse {
                initial: 0.0,
                pulsed: 3.3,
                delay: 0.0,
                rise_time: 1e-9,
                fall_time: 1e-9,
                pulse_width: 5e-6,
                period: 10e-6,
            }),
        };
        let json = serde_json::to_string(&comp).unwrap();
        assert!(json.contains(r#""type":"Pulse"#));
        let back: Component = serde_json::from_str(&json).unwrap();
        assert_eq!(comp, back);
    }

    #[test]
    fn full_circuit_ir() {
        let mut top = Subcircuit::new("voltage_divider");
        top.components.push(Component::Resistor {
            name: "R1".into(),
            n1: "in".into(),
            n2: "out".into(),
            value: IrValue::numeric(10_000.0),
            params: vec![],
        });
        top.components.push(Component::Resistor {
            name: "R2".into(),
            n1: "out".into(),
            n2: "0".into(),
            value: IrValue::numeric(10_000.0),
            params: vec![],
        });
        top.components.push(Component::VoltageSource {
            name: "V1".into(),
            np: "in".into(),
            nm: "0".into(),
            value: IrValue::numeric(5.0),
            waveform: None,
        });

        let mut ir = CircuitIR::new(top);
        ir.testbench = Some(Testbench {
            dut: "voltage_divider".into(),
            stimulus: vec![],
            analyses: vec![
                Analysis::Op,
                Analysis::Dc {
                    sweeps: vec![DcSweep {
                        source: "V1".into(),
                        start: 0.0,
                        stop: 5.0,
                        step: 0.1,
                    }],
                },
                Analysis::Ac {
                    variation: "dec".into(),
                    points: 100,
                    start: 1.0,
                    stop: 1e9,
                },
            ],
            options: SimOptions::default(),
            saves: vec!["V(out)".into()],
            measures: vec![],
            temperature: Some(27.0),
            nominal_temperature: None,
            initial_conditions: vec![],
            node_sets: vec![],
            step_params: vec![],
            extra_lines: vec![],
        });

        let json = serde_json::to_string_pretty(&ir).unwrap();
        let back: CircuitIR = serde_json::from_str(&json).unwrap();
        assert_eq!(ir, back);
        assert_eq!(back.top.components.len(), 3);
        assert_eq!(back.testbench.unwrap().analyses.len(), 3);
    }

    #[test]
    fn subcircuit_instance() {
        let mut top = Subcircuit::new("top");
        top.instances.push(Instance {
            name: "X1".into(),
            subcircuit: "opamp".into(),
            port_mapping: vec!["inp".into(), "inn".into(), "out".into(), "vdd".into(), "vss".into()],
            parameters: vec![("gain".into(), "1000".into())],
        });

        let sub = Subcircuit {
            name: "opamp".into(),
            ports: vec![
                Port { name: "inp".into(), direction: PortDirection::Input },
                Port { name: "inn".into(), direction: PortDirection::Input },
                Port { name: "out".into(), direction: PortDirection::Output },
                Port { name: "vdd".into(), direction: PortDirection::InOut },
                Port { name: "vss".into(), direction: PortDirection::InOut },
            ],
            parameters: vec![ParamDef { name: "gain".into(), default: Some("100".into()) }],
            components: vec![],
            instances: vec![],
            models: vec![],
            raw_spice: vec![],
            includes: vec![],
            libs: vec![],
            osdi_loads: vec![],
            verilog_blocks: vec![],
        };

        let ir = CircuitIR {
            top,
            testbench: None,
            subcircuit_defs: vec![sub],
            model_libraries: vec![],
        };

        let json = serde_json::to_string(&ir).unwrap();
        let back: CircuitIR = serde_json::from_str(&json).unwrap();
        assert_eq!(ir, back);
    }

    #[test]
    fn analysis_variants_serialize() {
        let analyses = vec![
            Analysis::Op,
            Analysis::Transient { step: 1e-9, stop: 1e-3, start: None, max_step: None, uic: false },
            Analysis::Noise {
                output: "out".into(), reference: "0".into(), source: "V1".into(),
                variation: "dec".into(), points: 100, start: 1.0, stop: 1e9,
                points_per_summary: None,
            },
            Analysis::HarmonicBalance { frequencies: vec![1e9], harmonics: vec![7] },
        ];
        for a in &analyses {
            let json = serde_json::to_string(a).unwrap();
            let back: Analysis = serde_json::from_str(&json).unwrap();
            assert_eq!(*a, back);
        }
    }

    #[test]
    fn ir_value_tagged() {
        let v = IrValue::numeric(42.0);
        let json = serde_json::to_string(&v).unwrap();
        assert!(json.contains(r#""type":"Numeric"#));

        let v = IrValue::expr("gm * 2");
        let json = serde_json::to_string(&v).unwrap();
        assert!(json.contains(r#""type":"Expression"#));
    }
}
