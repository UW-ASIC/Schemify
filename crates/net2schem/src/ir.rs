//! Hypergraph IR shared by all pipeline stages, plus the shared
//! rail-name / primitive↔DeviceKind tables (the old `shared` module,
//! folded in — it changes with the IR).

use std::fmt;

pub mod ids {
    //! Typed indices into the IR arenas. Raw-integer mixups become compile errors.

    /// Index of a net within a subcircuit's `nets` vec.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
    pub struct NetId(pub u32);

    /// Index of an instance within a subcircuit's `instances` vec.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
    pub struct InstId(pub u32);

    /// Index of a pin on an instance.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
    pub struct PinIdx(pub u16);

    impl NetId {
        pub fn index(self) -> usize {
            self.0 as usize
        }
    }

    impl InstId {
        pub fn index(self) -> usize {
            self.0 as usize
        }
    }

    impl PinIdx {
        pub fn index(self) -> usize {
            self.0 as usize
        }
    }
}
pub use ids::{InstId, NetId, PinIdx};

/// A diagnostic emitted during SPICE parsing (not post-parse validation) —
/// a netlist line cktimg ignored or skipped, with its reason.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseDiagnostic {
    pub line_no: usize,
    pub message: String,
}

impl fmt::Display for ParseDiagnostic {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "line {}: {}", self.line_no, self.message)
    }
}

/// Pin direction/role.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PinDir {
    Input,
    Output,
    Inout,
}

/// SPICE primitive device type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Primitive {
    Nmos,
    Pmos,
    Npn,
    Pnp,
    Resistor,
    Capacitor,
    Inductor,
    Diode,
    Vsource,
    Isource,
    Vcvs,
    Vccs,
    Ccvs,
    Cccs,
    Jfet,
    BehavioralSource,
    Subcircuit,
}

impl Primitive {
    pub fn is_mosfet(self) -> bool {
        matches!(self, Primitive::Nmos | Primitive::Pmos)
    }
}

/// Net classification, derived from the rail devices cktimg attaches.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum NetClass {
    Power,
    Ground,
    #[default]
    Signal,
}

/// Reference to a pin on an instance (by index).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PinRef {
    pub instance_idx: InstId,
    pub pin_idx: PinIdx,
}

/// A net (hyperedge connecting >= 1 pin).
#[derive(Debug, Clone)]
pub struct Net {
    pub name: String,
    pub pins: Vec<PinRef>,
    pub is_global: bool,
    pub classification: NetClass,
}

impl Net {
    pub fn new(name: &str) -> Self {
        Self {
            name: name.to_string(),
            pins: Vec::new(),
            is_global: false,
            classification: NetClass::Signal,
        }
    }
}

/// A pin on a component instance.
#[derive(Debug, Clone)]
pub struct Pin {
    pub name: String,
    pub dir: PinDir,
    pub net_idx: Option<NetId>,
}

/// A component instance in the circuit.
#[derive(Debug, Clone)]
pub struct Instance {
    pub name: String,
    pub primitive: Primitive,
    pub symbol: String,
    pub pins: Vec<Pin>,
    /// Parameters, kept sorted by key at construction.
    pub params: Vec<(String, String)>,
    /// Placement coordinates (set by placer).
    pub x: i32,
    pub y: i32,
    /// Rotation + mirror (0..=3 by construction).
    pub flags: InstanceFlags,
}

/// A wire segment (set by router).
#[derive(Debug, Clone, Copy)]
pub struct Wire {
    pub net_idx: NetId,
    pub x1: i32,
    pub y1: i32,
    pub x2: i32,
    pub y2: i32,
}

/// A net label — used instead of wires for distant connections.
#[derive(Debug, Clone, Copy)]
pub struct Label {
    pub net_idx: NetId,
    pub x: i32,
    pub y: i32,
    /// Rotation: 0=right, 1=up, 2=left, 3=down (flip unused).
    pub flags: InstanceFlags,
}

/// A subcircuit definition.
#[derive(Debug, Clone)]
pub struct Subcircuit {
    pub name: String,
    pub ports: Vec<String>,
    /// Direction for each port (used by the SYMBOL section on emit).
    pub port_directions: Vec<PinDir>,
    pub instances: Vec<Instance>,
    pub nets: Vec<Net>,
    pub wires: Vec<Wire>,
    pub labels: Vec<Label>,
}

impl Subcircuit {
    pub fn new(name: &str) -> Self {
        Self {
            name: name.to_string(),
            ports: Vec::new(),
            port_directions: Vec::new(),
            instances: Vec::new(),
            nets: Vec::new(),
            wires: Vec::new(),
            labels: Vec::new(),
        }
    }
}

impl std::ops::Index<NetId> for Subcircuit {
    type Output = Net;
    fn index(&self, id: NetId) -> &Net {
        &self.nets[id.index()]
    }
}

impl std::ops::Index<InstId> for Subcircuit {
    type Output = Instance;
    fn index(&self, id: InstId) -> &Instance {
        &self.instances[id.index()]
    }
}

/// Top-level circuit representation (hypergraph IR).
#[derive(Debug, Clone)]
pub struct Circuit {
    pub top: Subcircuit,
    /// Diagnostics collected during parsing (unknown cards, etc.).
    pub diagnostics: Vec<ParseDiagnostic>,
}

impl Circuit {
    pub fn new(name: &str) -> Self {
        Self {
            top: Subcircuit::new(name),
            diagnostics: Vec::new(),
        }
    }
}

// ── Shared constants + Primitive <-> DeviceKind mappings (was `crate::shared`) ──

// Shared constants and mappings used across the s2s pipeline.

use schemify_schematic::DeviceKind;
pub use schemify_schematic::InstanceFlags;


// Power / ground name constants
pub const POWER_NAMES: &[&str] = &["vdd", "vcc", "avdd", "dvdd"];
pub const GROUND_NAMES: &[&str] = &["vss", "gnd", "0", "avss", "dvss"];

pub fn is_power_name(name: &str) -> bool {
    POWER_NAMES.iter().any(|&p| name.eq_ignore_ascii_case(p))
}

pub fn is_ground_name(name: &str) -> bool {
    GROUND_NAMES.iter().any(|&g| name.eq_ignore_ascii_case(g))
}

// Primitive <-> DeviceKind mapping

pub fn map_device_kind(p: Primitive) -> DeviceKind {
    match p {
        Primitive::Nmos => DeviceKind::Nmos4,
        Primitive::Pmos => DeviceKind::Pmos4,
        Primitive::Npn => DeviceKind::Npn,
        Primitive::Pnp => DeviceKind::Pnp,
        Primitive::Resistor => DeviceKind::Resistor,
        Primitive::Capacitor => DeviceKind::Capacitor,
        Primitive::Inductor => DeviceKind::Inductor,
        Primitive::Diode => DeviceKind::Diode,
        Primitive::Vsource => DeviceKind::Vsource,
        Primitive::Isource => DeviceKind::Isource,
        Primitive::Vcvs => DeviceKind::Vcvs,
        Primitive::Vccs => DeviceKind::Vccs,
        Primitive::Ccvs => DeviceKind::Ccvs,
        Primitive::Cccs => DeviceKind::Cccs,
        Primitive::Jfet => DeviceKind::Njfet,
        Primitive::BehavioralSource => DeviceKind::Behavioral,
        Primitive::Subcircuit => DeviceKind::Subckt,
    }
}

pub fn map_primitive(kind: DeviceKind) -> Option<Primitive> {
    match kind {
        DeviceKind::Nmos4
        | DeviceKind::Nmos3
        | DeviceKind::Nmos4Depl
        | DeviceKind::NmosSub
        | DeviceKind::Nmoshv4
        | DeviceKind::Rnmos4 => Some(Primitive::Nmos),
        DeviceKind::Pmos4 | DeviceKind::Pmos3 | DeviceKind::PmosSub | DeviceKind::Pmoshv4 => {
            Some(Primitive::Pmos)
        }
        DeviceKind::Npn => Some(Primitive::Npn),
        DeviceKind::Pnp => Some(Primitive::Pnp),
        DeviceKind::Resistor | DeviceKind::Resistor3 | DeviceKind::VarResistor => {
            Some(Primitive::Resistor)
        }
        DeviceKind::Capacitor => Some(Primitive::Capacitor),
        DeviceKind::Inductor => Some(Primitive::Inductor),
        DeviceKind::Diode | DeviceKind::Zener => Some(Primitive::Diode),
        DeviceKind::Vsource => Some(Primitive::Vsource),
        DeviceKind::Isource => Some(Primitive::Isource),
        DeviceKind::Vcvs => Some(Primitive::Vcvs),
        DeviceKind::Vccs => Some(Primitive::Vccs),
        DeviceKind::Ccvs => Some(Primitive::Ccvs),
        DeviceKind::Cccs => Some(Primitive::Cccs),
        DeviceKind::Njfet | DeviceKind::Pjfet => Some(Primitive::Jfet),
        DeviceKind::Behavioral => Some(Primitive::BehavioralSource),
        DeviceKind::Subckt | DeviceKind::DigitalInstance => Some(Primitive::Subcircuit),
        _ => None,
    }
}

pub fn primitive_sym(p: Primitive) -> &'static str {
    match p {
        Primitive::Nmos => "nmos4",
        Primitive::Pmos => "pmos4",
        Primitive::Npn => "npn",
        Primitive::Pnp => "pnp",
        Primitive::Resistor => "res",
        Primitive::Capacitor => "capa",
        Primitive::Inductor => "ind",
        Primitive::Diode => "diode",
        Primitive::Vsource => "vsource",
        Primitive::Isource => "isource",
        Primitive::Vcvs => "vcvs",
        Primitive::Vccs => "vccs",
        Primitive::Ccvs => "ccvs",
        Primitive::Cccs => "cccs",
        Primitive::Jfet => "jfet",
        Primitive::BehavioralSource => "bsource",
        Primitive::Subcircuit => "subckt",
    }
}
