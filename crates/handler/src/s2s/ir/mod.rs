use std::collections::HashMap;

/// Pin direction/role.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PinDir {
    Input,
    Output,
    Inout,
    Power,
    Ground,
    Bulk,
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
    Subcircuit,
}

impl Primitive {
    pub fn is_mosfet(self) -> bool {
        matches!(self, Primitive::Nmos | Primitive::Pmos)
    }

    pub fn is_bjt(self) -> bool {
        matches!(self, Primitive::Npn | Primitive::Pnp)
    }
}

/// Net classification for routing decisions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum NetClass {
    Power,
    Ground,
    Bias,
    Clock,
    DifferentialP,
    DifferentialN,
    HighFanout,
    LocalSignal,
    #[default]
    Signal,
}

/// Reference to a pin on an instance (by index).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PinRef {
    pub instance_idx: u32,
    pub pin_idx: u32,
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
    pub net_idx: Option<u32>,
}

/// A component instance in the circuit.
#[derive(Debug, Clone)]
pub struct Instance {
    pub name: String,
    pub primitive: Primitive,
    pub symbol: String,
    pub pins: Vec<Pin>,
    pub params: HashMap<String, String>,
    /// Placement coordinates (set by placer).
    pub x: i32,
    pub y: i32,
    /// Rotation: 0=0deg, 1=90, 2=180, 3=270 CCW.
    pub rotation: u8,
    /// Mirror applied before rotation.
    pub flip: bool,
}

impl Instance {
    pub fn pin_net(&self, pin_idx: usize) -> Option<u32> {
        self.pins.get(pin_idx).and_then(|p| p.net_idx)
    }
}

/// A wire segment (set by router).
#[derive(Debug, Clone, Copy)]
pub struct Wire {
    pub net_idx: u32,
    pub x1: i32,
    pub y1: i32,
    pub x2: i32,
    pub y2: i32,
}

/// A net label (lab_pin.sym in XSchem) — used instead of wires for distant connections.
#[derive(Debug, Clone, Copy)]
pub struct Label {
    pub net_idx: u32,
    pub x: i32,
    pub y: i32,
    /// 0=right, 1=up, 2=left, 3=down.
    pub rotation: u8,
}

/// A subcircuit definition.
#[derive(Debug, Clone)]
pub struct Subcircuit {
    pub name: String,
    pub ports: Vec<String>,
    /// Inferred direction for each port (populated by annotation pass).
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

/// A `.model` definition.
#[derive(Debug, Clone)]
pub struct Model {
    pub name: String,
    pub model_type: String, // "NMOS", "PMOS", "NPN", etc.
    pub params: HashMap<String, String>,
}

/// Categorized analysis/stimulus commands from a SPICE netlist.
///
/// Separates netlist-adjacent directives (includes, options) from pure
/// simulation commands (analyses, measurements, output requests).
#[derive(Debug, Clone, Default)]
pub struct AnalysisBlock {
    /// Analysis commands: `.tran`, `.ac`, `.dc`, `.op`, `.noise`, `.pz`, `.sens`, `.tf`
    pub analyses: Vec<String>,
    /// Output requests: `.save`, `.print`, `.plot`, `.probe`
    pub outputs: Vec<String>,
    /// Measurement definitions: `.meas`, `.measure`
    pub measurements: Vec<String>,
    /// Initial conditions: `.ic`, `.nodeset`
    pub initial_conds: Vec<String>,
    /// Simulation options: `.options`, `.option`, `.temp`
    pub options: Vec<String>,
    /// Control blocks: `.control` ... `.endc` (each block joined with newlines)
    pub control_blocks: Vec<String>,
    /// Library/file includes: `.include`, `.lib`
    pub includes: Vec<String>,
    /// Sweep/misc: `.step`, `.four`, `.func`, `.csparam`
    pub other: Vec<String>,
}

impl AnalysisBlock {
    pub fn is_empty(&self) -> bool {
        self.analyses.is_empty()
            && self.outputs.is_empty()
            && self.measurements.is_empty()
            && self.initial_conds.is_empty()
            && self.options.is_empty()
            && self.control_blocks.is_empty()
            && self.includes.is_empty()
            && self.other.is_empty()
    }

    /// Flatten all non-include lines into a single string (analysis + stimulus).
    /// Used to populate `Schematic.spice_body`.
    pub fn to_stimulus_string(&self) -> String {
        let mut lines: Vec<&str> = Vec::new();
        for l in &self.options {
            lines.push(l);
        }
        for l in &self.initial_conds {
            lines.push(l);
        }
        for l in &self.analyses {
            lines.push(l);
        }
        for l in &self.outputs {
            lines.push(l);
        }
        for l in &self.measurements {
            lines.push(l);
        }
        for l in &self.other {
            lines.push(l);
        }
        for l in &self.control_blocks {
            lines.push(l);
        }
        lines.join("\n")
    }

    /// Flatten include directives into a single string.
    pub fn to_includes_string(&self) -> String {
        self.includes.join("\n")
    }
}

/// Top-level circuit representation (hypergraph IR).
#[derive(Debug, Clone)]
pub struct Circuit {
    pub top: Subcircuit,
    pub subcircuits: HashMap<String, Subcircuit>,
    pub models: HashMap<String, Model>,
    /// Structured analysis/stimulus commands parsed from the source SPICE.
    pub analysis: AnalysisBlock,
}

impl Circuit {
    pub fn new(name: &str) -> Self {
        Self {
            top: Subcircuit::new(name),
            subcircuits: HashMap::new(),
            models: HashMap::new(),
            analysis: AnalysisBlock::default(),
        }
    }

    pub fn add_instance(&mut self, inst: Instance) -> u32 {
        let idx = self.top.instances.len() as u32;
        self.top.instances.push(inst);
        idx
    }

    pub fn add_net(&mut self, net: Net) -> u32 {
        let idx = self.top.nets.len() as u32;
        self.top.nets.push(net);
        idx
    }

    /// Find or create net by name.
    pub fn get_or_create_net(&mut self, name: &str) -> u32 {
        for (i, net) in self.top.nets.iter().enumerate() {
            if net.name == name {
                return i as u32;
            }
        }
        self.add_net(Net::new(name))
    }

    /// Connect a pin to a net.
    pub fn connect(&mut self, net_idx: u32, pin_ref: PinRef) {
        self.top.nets[net_idx as usize].pins.push(pin_ref);
        self.top.instances[pin_ref.instance_idx as usize].pins[pin_ref.pin_idx as usize].net_idx =
            Some(net_idx);
    }
}
