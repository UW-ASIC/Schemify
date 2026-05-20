/// SPICE component instance in a netlist.
#[derive(Debug, Clone)]
pub enum SpiceComponent {
    Resistor { name: String, nodes: [String; 2], value: Value },
    Capacitor { name: String, nodes: [String; 2], value: Value },
    Inductor { name: String, nodes: [String; 2], value: Value },
    Diode { name: String, nodes: [String; 2], model: String },
    Mosfet { name: String, nodes: [String; 4], model: String, params: Vec<Param> },
    Bjt { name: String, nodes: [String; 3], model: String, params: Vec<Param> },
    Jfet { name: String, nodes: [String; 3], model: String, params: Vec<Param> },
    Vsource { name: String, nodes: [String; 2], value: Value },
    Isource { name: String, nodes: [String; 2], value: Value },
    Vcvs { name: String, nodes: [String; 4], gain: Value },
    Vccs { name: String, nodes: [String; 4], gain: Value },
    Ccvs { name: String, nodes: [String; 4], gain: Value },
    Cccs { name: String, nodes: [String; 4], gain: Value },
    Subcircuit { name: String, nodes: Vec<String>, subckt_name: String, params: Vec<Param> },
    Raw { text: String },
}

/// A numeric or symbolic value in a SPICE netlist.
#[derive(Debug, Clone)]
pub enum Value {
    /// Bare numeric literal, emitted with SI suffixes.
    Literal(f64),
    /// Parameter reference (e.g. `gm`).
    Param(String),
    /// Expression (e.g. `gm * 2`), wrapped in braces for SPICE dialects.
    Expr(String),
    /// Pre-formatted SI literal passthrough (e.g. `"10k"`, `"1u"`).
    SiLiteral(String),
}

/// A key=value parameter pair.
#[derive(Debug, Clone)]
pub struct Param {
    pub key: String,
    pub value: Value,
}

/// A complete SPICE netlist.
#[derive(Debug, Clone)]
pub struct SpiceNetlist {
    pub title: String,
    pub includes: Vec<String>,
    pub params: Vec<Param>,
    pub models: Vec<ModelStatement>,
    pub subcircuits: Vec<SubcircuitDef>,
    pub components: Vec<SpiceComponent>,
    pub analyses: Vec<Analysis>,
    pub measurements: Vec<Measurement>,
    pub options: Vec<String>,
}

/// `.model` statement.
#[derive(Debug, Clone)]
pub struct ModelStatement {
    pub name: String,
    pub model_type: String,
    pub params: Vec<Param>,
}

/// `.subckt` definition block.
#[derive(Debug, Clone)]
pub struct SubcircuitDef {
    pub name: String,
    pub ports: Vec<String>,
    pub params: Vec<Param>,
    pub components: Vec<SpiceComponent>,
    pub models: Vec<ModelStatement>,
}

/// Simulation analysis command.
#[derive(Debug, Clone)]
pub enum Analysis {
    Op,
    Dc { source: String, start: f64, stop: f64, step: f64 },
    Ac { variation: AcVariation, points: u32, start: f64, stop: f64 },
    Tran { step: f64, stop: f64, start: f64 },
    Noise { output: String, source: String, variation: AcVariation, points: u32, start: f64, stop: f64 },
}

/// AC sweep variation type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AcVariation {
    Dec,
    Oct,
    Lin,
}

/// `.meas` / `.MEASURE` statement.
#[derive(Debug, Clone)]
pub struct Measurement {
    pub name: String,
    pub analysis: String,
    pub expr: String,
}

// ---------------------------------------------------------------------------
// Defaults & convenience constructors
// ---------------------------------------------------------------------------

impl Default for SpiceNetlist {
    fn default() -> Self {
        Self {
            title: String::new(),
            includes: Vec::new(),
            params: Vec::new(),
            models: Vec::new(),
            subcircuits: Vec::new(),
            components: Vec::new(),
            analyses: Vec::new(),
            measurements: Vec::new(),
            options: Vec::new(),
        }
    }
}

impl SpiceNetlist {
    /// Create a netlist with only a title.
    pub fn new(title: impl Into<String>) -> Self {
        Self { title: title.into(), ..Self::default() }
    }
}

impl Param {
    pub fn new(key: impl Into<String>, value: Value) -> Self {
        Self { key: key.into(), value }
    }
}

impl Value {
    /// Shorthand for `Value::Literal`.
    pub fn lit(v: f64) -> Self {
        Self::Literal(v)
    }

    /// Shorthand for `Value::SiLiteral`.
    pub fn si(s: impl Into<String>) -> Self {
        Self::SiLiteral(s.into())
    }
}

impl SpiceComponent {
    /// Create a resistor.
    pub fn resistor(name: impl Into<String>, a: impl Into<String>, b: impl Into<String>, value: Value) -> Self {
        Self::Resistor { name: name.into(), nodes: [a.into(), b.into()], value }
    }

    /// Create a capacitor.
    pub fn capacitor(name: impl Into<String>, a: impl Into<String>, b: impl Into<String>, value: Value) -> Self {
        Self::Capacitor { name: name.into(), nodes: [a.into(), b.into()], value }
    }

    /// Create an inductor.
    pub fn inductor(name: impl Into<String>, a: impl Into<String>, b: impl Into<String>, value: Value) -> Self {
        Self::Inductor { name: name.into(), nodes: [a.into(), b.into()], value }
    }

    /// Create a voltage source.
    pub fn vsource(name: impl Into<String>, p: impl Into<String>, n: impl Into<String>, value: Value) -> Self {
        Self::Vsource { name: name.into(), nodes: [p.into(), n.into()], value }
    }

    /// Create a current source.
    pub fn isource(name: impl Into<String>, p: impl Into<String>, n: impl Into<String>, value: Value) -> Self {
        Self::Isource { name: name.into(), nodes: [p.into(), n.into()], value }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn construct_resistor() {
        let r = SpiceComponent::resistor("R0", "a", "b", Value::lit(10_000.0));
        assert!(format!("{r:?}").contains("Resistor"));
    }

    #[test]
    fn construct_mosfet() {
        let m = SpiceComponent::Mosfet {
            name: "M1".into(),
            nodes: ["d".into(), "g".into(), "s".into(), "b".into()],
            model: "nmos_3p3".into(),
            params: vec![
                Param::new("W", Value::si("1u")),
                Param::new("L", Value::si("180n")),
            ],
        };
        assert!(format!("{m:?}").contains("Mosfet"));
    }

    #[test]
    fn construct_subcircuit_instance() {
        let x = SpiceComponent::Subcircuit {
            name: "X1".into(),
            nodes: vec!["in".into(), "out".into(), "vdd".into(), "vss".into()],
            subckt_name: "opamp".into(),
            params: vec![Param::new("gain", Value::lit(1000.0))],
        };
        assert!(format!("{x:?}").contains("Subcircuit"));
    }

    #[test]
    fn construct_diode() {
        let d = SpiceComponent::Diode {
            name: "D1".into(),
            nodes: ["a".into(), "k".into()],
            model: "1N4148".into(),
        };
        assert!(format!("{d:?}").contains("Diode"));
    }

    #[test]
    fn construct_bjt() {
        let q = SpiceComponent::Bjt {
            name: "Q1".into(),
            nodes: ["c".into(), "b".into(), "e".into()],
            model: "2N2222".into(),
            params: vec![],
        };
        assert!(format!("{q:?}").contains("Bjt"));
    }

    #[test]
    fn construct_jfet() {
        let j = SpiceComponent::Jfet {
            name: "J1".into(),
            nodes: ["d".into(), "g".into(), "s".into()],
            model: "2N5457".into(),
            params: vec![],
        };
        assert!(format!("{j:?}").contains("Jfet"));
    }

    #[test]
    fn construct_controlled_sources() {
        let vcvs = SpiceComponent::Vcvs {
            name: "E1".into(),
            nodes: ["out+".into(), "out-".into(), "in+".into(), "in-".into()],
            gain: Value::lit(10.0),
        };
        assert!(format!("{vcvs:?}").contains("Vcvs"));

        let vccs = SpiceComponent::Vccs {
            name: "G1".into(),
            nodes: ["out+".into(), "out-".into(), "in+".into(), "in-".into()],
            gain: Value::lit(0.001),
        };
        assert!(format!("{vccs:?}").contains("Vccs"));

        let ccvs = SpiceComponent::Ccvs {
            name: "H1".into(),
            nodes: ["out+".into(), "out-".into(), "in+".into(), "in-".into()],
            gain: Value::lit(100.0),
        };
        assert!(format!("{ccvs:?}").contains("Ccvs"));

        let cccs = SpiceComponent::Cccs {
            name: "F1".into(),
            nodes: ["out+".into(), "out-".into(), "in+".into(), "in-".into()],
            gain: Value::lit(5.0),
        };
        assert!(format!("{cccs:?}").contains("Cccs"));
    }

    #[test]
    fn construct_raw() {
        let r = SpiceComponent::Raw { text: ".lib 'models.lib' tt".into() };
        assert!(format!("{r:?}").contains("Raw"));
    }

    #[test]
    fn construct_sources() {
        let v = SpiceComponent::vsource("V1", "vdd", "0", Value::lit(3.3));
        assert!(format!("{v:?}").contains("Vsource"));

        let i = SpiceComponent::isource("I1", "a", "b", Value::si("1m"));
        assert!(format!("{i:?}").contains("Isource"));
    }

    #[test]
    fn construct_analyses() {
        let analyses: Vec<Analysis> = vec![
            Analysis::Op,
            Analysis::Dc { source: "V1".into(), start: 0.0, stop: 5.0, step: 0.1 },
            Analysis::Ac { variation: AcVariation::Dec, points: 100, start: 1.0, stop: 1e9 },
            Analysis::Tran { step: 1e-9, stop: 1e-3, start: 0.0 },
            Analysis::Noise {
                output: "V(out)".into(),
                source: "V1".into(),
                variation: AcVariation::Dec,
                points: 10,
                start: 1.0,
                stop: 1e9,
            },
        ];
        for a in &analyses {
            let dbg = format!("{a:?}");
            assert!(!dbg.is_empty());
        }
    }

    #[test]
    fn construct_model_statement() {
        let m = ModelStatement {
            name: "nmos_3p3".into(),
            model_type: "nmos".into(),
            params: vec![
                Param::new("vth0", Value::lit(0.4)),
                Param::new("tox", Value::lit(7e-9)),
            ],
        };
        assert!(format!("{m:?}").contains("nmos_3p3"));
    }

    #[test]
    fn construct_subcircuit_def() {
        let s = SubcircuitDef {
            name: "opamp".into(),
            ports: vec!["in+".into(), "in-".into(), "out".into(), "vdd".into(), "vss".into()],
            params: vec![Param::new("gain", Value::lit(1000.0))],
            components: vec![
                SpiceComponent::resistor("R1", "in+", "mid", Value::si("10k")),
            ],
            models: vec![],
        };
        assert!(format!("{s:?}").contains("opamp"));
    }

    #[test]
    fn construct_measurement() {
        let m = Measurement {
            name: "vout_avg".into(),
            analysis: "TRAN".into(),
            expr: "AVG V(out)".into(),
        };
        assert!(format!("{m:?}").contains("vout_avg"));
    }

    #[test]
    fn default_netlist() {
        let nl = SpiceNetlist::default();
        assert!(nl.title.is_empty());
        assert!(nl.components.is_empty());
        assert!(nl.analyses.is_empty());
    }

    #[test]
    fn netlist_new_with_title() {
        let nl = SpiceNetlist::new("Test Circuit");
        assert_eq!(nl.title, "Test Circuit");
    }
}
