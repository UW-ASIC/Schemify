//! Circuit IR types mirroring PySpice-rs's `CircuitIR` schema.
//!
//! SchemifyRS serializes these to JSON; PySpice-rs deserializes and runs.
//! No Rust crate dependency — JSON is the contract. Field names, order, and
//! serde attributes must NOT change without updating the Python side.

use serde::{Deserialize, Serialize};

// ── Top-level ──

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CircuitIR {
    pub top: Subcircuit,
    pub subcircuit_defs: Vec<Subcircuit>,
}

// ── Subcircuit ──

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
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
    /// Verilog-A source files (`.va`/`.vams`) behind `osdi_loads` entries.
    /// Codegen hint only — `serde(skip)` keeps the JSON wire format
    /// byte-identical to pyspice_rs's `Subcircuit` (which has no such
    /// field). The PySpice emitter uses it to call `veriloga(source)`
    /// (openvaf compile, mtime-cached) instead of loading a possibly
    /// stale/missing pre-compiled `.osdi`.
    #[serde(skip)]
    pub veriloga_sources: Vec<String>,
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

// ── Components ──

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Component {
    /// Verilog-A (OSDI) device: `N<name> <nodes> <model>` referencing a
    /// compiled module recorded in `Subcircuit::osdi_loads`.
    VerilogA {
        name: String,
        nodes: Vec<String>,
        model: String,
        params: Vec<(String, String)>,
    },
    Resistor {
        name: String,
        n1: String,
        n2: String,
        value: IrValue,
        params: Vec<(String, String)>,
    },
    Capacitor {
        name: String,
        n1: String,
        n2: String,
        value: IrValue,
        params: Vec<(String, String)>,
    },
    Inductor {
        name: String,
        n1: String,
        n2: String,
        value: IrValue,
        params: Vec<(String, String)>,
    },
    MutualInductor {
        name: String,
        inductor1: String,
        inductor2: String,
        coupling: f64,
    },
    VoltageSource {
        name: String,
        np: String,
        nm: String,
        value: IrValue,
    },
    CurrentSource {
        name: String,
        np: String,
        nm: String,
        value: IrValue,
    },
    BehavioralVoltage {
        name: String,
        np: String,
        nm: String,
        expression: String,
    },
    Vcvs {
        name: String,
        np: String,
        nm: String,
        ncp: String,
        ncm: String,
        gain: f64,
    },
    Vccs {
        name: String,
        np: String,
        nm: String,
        ncp: String,
        ncm: String,
        transconductance: f64,
    },
    Cccs {
        name: String,
        np: String,
        nm: String,
        vsense: String,
        gain: f64,
    },
    Ccvs {
        name: String,
        np: String,
        nm: String,
        vsense: String,
        transresistance: f64,
    },
    Diode {
        name: String,
        np: String,
        nm: String,
        model: String,
        params: Vec<(String, String)>,
    },
    Bjt {
        name: String,
        nc: String,
        nb: String,
        ne: String,
        model: String,
        params: Vec<(String, String)>,
    },
    Mosfet {
        name: String,
        nd: String,
        ng: String,
        ns: String,
        nb: String,
        model: String,
        params: Vec<(String, String)>,
    },
    Jfet {
        name: String,
        nd: String,
        ng: String,
        ns: String,
        model: String,
        params: Vec<(String, String)>,
    },
    Mesfet {
        name: String,
        nd: String,
        ng: String,
        ns: String,
        model: String,
        params: Vec<(String, String)>,
    },
    VSwitch {
        name: String,
        np: String,
        nm: String,
        ncp: String,
        ncm: String,
        model: String,
    },
    ISwitch {
        name: String,
        np: String,
        nm: String,
        vcontrol: String,
        model: String,
    },
    TLine {
        name: String,
        inp: String,
        inm: String,
        outp: String,
        outm: String,
        z0: f64,
        td: f64,
    },
    RawSpice {
        line: String,
    },
}

// ── Values & waveforms ──

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum IrValue {
    Numeric { value: f64 },
    Expression { expr: String },
    Raw { text: String },
}

// ── Constructors ──

impl Subcircuit {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            ..Self::default()
        }
    }
}

impl CircuitIR {
    pub fn new(name: impl Into<String>) -> Self {
        Self::with_top(Subcircuit::new(name))
    }

    pub fn with_top(top: Subcircuit) -> Self {
        Self {
            top,
            subcircuit_defs: Vec::new(),
        }
    }
}

impl IrValue {
    pub fn numeric(v: f64) -> Self {
        Self::Numeric { value: v }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// JSON shape contract: field names AND order must match what the
    /// pyspice_rs Python deserializer expects. Exact-string snapshot.
    #[test]
    fn json_field_order_snapshot() {
        let ir = CircuitIR::new("t");
        let json = serde_json::to_string(&ir).unwrap();
        assert_eq!(
            json,
            r#"{"top":{"name":"t","ports":[],"parameters":[],"components":[],"instances":[],"models":[],"raw_spice":[],"includes":[],"libs":[],"osdi_loads":[]},"subcircuit_defs":[]}"#
        );
    }

    #[test]
    fn component_tagged_snapshot() {
        let comp = Component::Resistor {
            name: "R1".into(),
            n1: "a".into(),
            n2: "b".into(),
            value: IrValue::numeric(10_000.0),
            params: vec![],
        };
        let json = serde_json::to_string(&comp).unwrap();
        assert_eq!(
            json,
            r#"{"type":"Resistor","name":"R1","n1":"a","n2":"b","value":{"type":"Numeric","value":10000.0},"params":[]}"#
        );
        let back: Component = serde_json::from_str(&json).unwrap();
        assert_eq!(comp, back);
    }

    #[test]
    fn full_circuit_ir_roundtrip() {
        let mut top = Subcircuit::new("voltage_divider");
        top.components.push(Component::Resistor {
            name: "R1".into(),
            n1: "in".into(),
            n2: "out".into(),
            value: IrValue::numeric(10_000.0),
            params: vec![],
        });
        top.components.push(Component::VoltageSource {
            name: "V1".into(),
            np: "in".into(),
            nm: "0".into(),
            value: IrValue::numeric(5.0),
        });

        let ir = CircuitIR::with_top(top);
        let json = serde_json::to_string_pretty(&ir).unwrap();
        let back: CircuitIR = serde_json::from_str(&json).unwrap();
        assert_eq!(ir, back);
        assert_eq!(back.top.components.len(), 2);
    }

    #[test]
    fn ir_value_tagged() {
        let json = serde_json::to_string(&IrValue::numeric(42.0)).unwrap();
        assert!(json.contains(r#""type":"Numeric"#));
        let json = serde_json::to_string(&IrValue::Expression {
            expr: "gm * 2".into(),
        })
        .unwrap();
        assert!(json.contains(r#""type":"Expression"#));
    }

    #[test]
    fn subcircuit_instance_roundtrip() {
        let mut top = Subcircuit::new("top");
        top.instances.push(Instance {
            name: "X1".into(),
            subcircuit: "opamp".into(),
            port_mapping: vec!["inp".into(), "inn".into(), "out".into()],
            parameters: vec![("gain".into(), "1000".into())],
        });
        let sub = Subcircuit {
            name: "opamp".into(),
            ports: vec![
                Port {
                    name: "inp".into(),
                    direction: PortDirection::Input,
                },
                Port {
                    name: "inn".into(),
                    direction: PortDirection::Input,
                },
                Port {
                    name: "out".into(),
                    direction: PortDirection::Output,
                },
            ],
            parameters: vec![ParamDef {
                name: "gain".into(),
                default: Some("100".into()),
            }],
            ..Subcircuit::default()
        };
        let ir = CircuitIR {
            top,
            subcircuit_defs: vec![sub],
        };
        let json = serde_json::to_string(&ir).unwrap();
        let back: CircuitIR = serde_json::from_str(&json).unwrap();
        assert_eq!(ir, back);
        // Port order is semantic: instance port_mapping is positional.
        assert_eq!(back.subcircuit_defs[0].ports[0].name, "inp");
        assert_eq!(back.subcircuit_defs[0].ports[2].name, "out");
    }
}
