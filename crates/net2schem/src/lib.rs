//! SPICE netlist → schematic pipeline (s2s).
//!
//! Pipeline stages: parse (`parser`) → annotate (`annotation`) → recognize
//! (`recognition`) → place (`place`) → route (`route`) → output (`emit`).
//! The hypergraph IR shared by all stages lives in `ir`.

pub mod emit;
pub mod parser;
pub mod place;
pub mod route;

// ===========================================================================
// crate::ir — hypergraph IR + typed IDs
// ===========================================================================

pub mod ir {
    use std::collections::HashMap;
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

    /// Classification of a parse-phase diagnostic.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum DiagnosticKind {
        UnknownDevicePrefix(char),
        UnknownDotCommand(String),
    }

    /// A diagnostic emitted during SPICE parsing (not post-parse validation).
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct ParseDiagnostic {
        pub line_no: usize,
        pub kind: DiagnosticKind,
    }

    impl fmt::Display for ParseDiagnostic {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            match &self.kind {
                DiagnosticKind::UnknownDevicePrefix(ch) => {
                    write!(f, "line {}: unknown device prefix '{}'", self.line_no, ch)
                }
                DiagnosticKind::UnknownDotCommand(cmd) => {
                    write!(f, "line {}: unknown dot command '{}'", self.line_no, cmd)
                }
            }
        }
    }

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
        Jfet,
        BehavioralSource,
        Subcircuit,
    }

    impl Primitive {
        pub fn is_mosfet(self) -> bool {
            matches!(self, Primitive::Nmos | Primitive::Pmos)
        }

        pub fn is_bjt(self) -> bool {
            matches!(self, Primitive::Npn | Primitive::Pnp)
        }

        pub fn is_jfet(self) -> bool {
            matches!(self, Primitive::Jfet)
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
        pub fn pin_net(&self, pin_idx: usize) -> Option<NetId> {
            self.pins.get(pin_idx).and_then(|p| p.net_idx)
        }
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

    impl std::ops::Index<NetId> for Subcircuit {
        type Output = Net;
        fn index(&self, id: NetId) -> &Net {
            &self.nets[id.index()]
        }
    }

    impl std::ops::IndexMut<NetId> for Subcircuit {
        fn index_mut(&mut self, id: NetId) -> &mut Net {
            &mut self.nets[id.index()]
        }
    }

    impl std::ops::Index<InstId> for Subcircuit {
        type Output = Instance;
        fn index(&self, id: InstId) -> &Instance {
            &self.instances[id.index()]
        }
    }

    impl std::ops::IndexMut<InstId> for Subcircuit {
        fn index_mut(&mut self, id: InstId) -> &mut Instance {
            &mut self.instances[id.index()]
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
        /// Diagnostics collected during parsing (unknown cards, etc.).
        pub diagnostics: Vec<ParseDiagnostic>,
    }

    impl Circuit {
        pub fn new(name: &str) -> Self {
            Self {
                top: Subcircuit::new(name),
                subcircuits: HashMap::new(),
                models: HashMap::new(),
                analysis: AnalysisBlock::default(),
                diagnostics: Vec::new(),
            }
        }

        pub fn add_instance(&mut self, inst: Instance) -> InstId {
            let idx = InstId(self.top.instances.len() as u32);
            self.top.instances.push(inst);
            idx
        }

        pub fn add_net(&mut self, net: Net) -> NetId {
            let idx = NetId(self.top.nets.len() as u32);
            self.top.nets.push(net);
            idx
        }

        /// Find or create net by name.
        pub fn get_or_create_net(&mut self, name: &str) -> NetId {
            for (i, net) in self.top.nets.iter().enumerate() {
                if net.name == name {
                    return NetId(i as u32);
                }
            }
            self.add_net(Net::new(name))
        }

        /// Connect a pin to a net.
        pub fn connect(&mut self, net_idx: NetId, pin_ref: PinRef) {
            self.top[net_idx].pins.push(pin_ref);
            self.top[pin_ref.instance_idx].pins[pin_ref.pin_idx.index()].net_idx = Some(net_idx);
        }
    }
}

// ===========================================================================
// crate::shared — constants and Primitive <-> DeviceKind mappings
// ===========================================================================

pub mod shared {
    //! Shared constants and mappings used across the s2s pipeline.

    use schemify_core::schemify::DeviceKind;

    use crate::ir::Primitive;

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
}

// ===========================================================================
// crate::annotation — power/ground detection, port directions, diff pairs
// ===========================================================================

pub mod annotation {
    //! Annotation pass: enriches the IR with metadata needed for placement and routing.
    //!
    //! Detects power/ground nets, infers port directions, and tags differential pairs.

    use crate::ir::{Circuit, NetClass, NetId, PinDir, PinIdx, Primitive, Subcircuit};

    /// Run all annotation passes on the circuit.
    ///
    /// Child port directions are inferred FIRST: `annotate_power_nets` uses
    /// them as evidence that a Vsource-driven net actually powers something.
    pub fn annotate(circuit: &mut Circuit) {
        for sub in circuit.subcircuits.values_mut() {
            infer_port_directions(sub);
        }
        annotate_power_nets(circuit);
        infer_port_directions(&mut circuit.top);
        detect_differential_nets(circuit);
    }

    /// Classify nets as `Power` or `Ground` based on name, globals, voltage
    /// sources, and high-fanout heuristics.
    pub fn annotate_power_nets(circuit: &mut Circuit) {
        // Rule 1 & 2: .global flag + name matching (globals with power names get
        // priority, but we also match non-global nets by name).
        for net in &mut circuit.top.nets {
            if let Some(class) = classify_power_name(&net.name) {
                net.classification = class;
            }
        }

        // Also classify subcircuit nets by name (needed for diff pair rejection etc.)
        for subckt in circuit.subcircuits.values_mut() {
            for net in &mut subckt.nets {
                if let Some(class) = classify_power_name(&net.name) {
                    net.classification = class;
                }
            }
        }

        // Rule 3: Nets connected to a DC voltage source whose other terminal is
        // on net "0". The positive terminal net becomes Power.
        //
        // Two guards keep stimulus/measurement sources from minting fake rails:
        // - Only *pure DC* sources qualify: a transient/AC spec (PULSE/SIN/...)
        //   means stimulus (tb_cmos_inverter `Vin vin 0 0 PULSE(...)`).
        // - The candidate net must actually POWER something: a MOSFET
        //   source/bulk pin or a power/ground-named subcircuit port
        //   (tb `Vin vin 0 900m` DC bias and `Vout iout 0 900m` measurement
        //   sources drive signals, not rails).
        //
        // Voltage sources have pins: 0=p (plus), 1=n (minus).
        let net_zero_idx = circuit
            .top
            .nets
            .iter()
            .position(|n| n.name == "0")
            .map(|i| NetId(i as u32));

        let mut reclass: Vec<(NetId, NetClass)> = Vec::new();
        for inst in &circuit.top.instances {
            if inst.primitive != Primitive::Vsource || !is_dc_supply_value(inst) {
                continue;
            }
            let plus_net = inst.pins.first().and_then(|p| p.net_idx);
            let minus_net = inst.pins.get(1).and_then(|p| p.net_idx);

            if let Some(zero_idx) = net_zero_idx {
                // If minus terminal is on "0", plus terminal is a power net.
                if minus_net == Some(zero_idx) {
                    if let Some(p_idx) = plus_net {
                        if net_powers_something(circuit, p_idx, PinDir::Power) {
                            reclass.push((p_idx, NetClass::Power));
                        }
                    }
                }
                // If plus terminal is on "0", minus terminal is a ground net.
                if plus_net == Some(zero_idx) {
                    if let Some(m_idx) = minus_net {
                        if net_powers_something(circuit, m_idx, PinDir::Ground) {
                            reclass.push((m_idx, NetClass::Ground));
                        }
                    }
                }
            }
        }
        for (idx, class) in reclass {
            let net = &mut circuit.top.nets[idx.index()];
            if net.classification == NetClass::Signal {
                net.classification = class;
            }
        }

        // Rule 4: High-fanout nets (>10 pins) where all connected pins are
        // MOSFET bulk (pin_idx 3) or source (pin_idx 2).
        for net in &mut circuit.top.nets {
            if net.classification != NetClass::Signal {
                continue;
            }
            if net.pins.len() <= 10 {
                continue;
            }

            let all_bulk_or_source = net.pins.iter().all(|pref| {
                let inst = &circuit.top.instances[pref.instance_idx.index()];
                if inst.primitive.is_mosfet() {
                    // pin 2 = source, pin 3 = bulk
                    pref.pin_idx == PinIdx(2) || pref.pin_idx == PinIdx(3)
                } else {
                    false
                }
            });

            if all_bulk_or_source {
                net.classification = NetClass::Power;
            }
        }
    }

    /// Rail evidence for Rule 3: the net feeds a pin that consumes rail
    /// current — a MOSFET source (2) / bulk (3) pin, or a subcircuit port
    /// whose inferred direction matches `want` (Power or Ground).
    fn net_powers_something(circuit: &Circuit, net_idx: NetId, want: PinDir) -> bool {
        let Some(net) = circuit.top.nets.get(net_idx.index()) else {
            return false;
        };
        net.pins.iter().any(|pref| {
            let Some(inst) = circuit.top.instances.get(pref.instance_idx.index()) else {
                return false;
            };
            if inst.primitive.is_mosfet() {
                return pref.pin_idx == PinIdx(2) || pref.pin_idx == PinIdx(3);
            }
            if inst.primitive == Primitive::Subcircuit {
                if let Some(child) = circuit.subcircuits.get(&inst.symbol) {
                    return child.port_directions.get(pref.pin_idx.index()) == Some(&want);
                }
            }
            false
        })
    }

    /// True if a Vsource's `value` param is a pure DC spec (a rail supply).
    /// Stimulus specs (PULSE/SIN/PWL/EXP/SFFM/AC sweeps) disqualify — those
    /// sources drive signals, not power rails. Parser lowercases `value`.
    fn is_dc_supply_value(inst: &crate::ir::Instance) -> bool {
        const STIMULUS: &[&str] = &["pulse", "sin", "pwl", "exp", "sffm", "am", "ac"];
        let Some(value) = inst.params.get("value") else {
            return true; // no spec at all — treat as DC
        };
        !value
            .split(|c: char| c.is_whitespace() || c == '(')
            .any(|tok| STIMULUS.contains(&tok))
    }

    /// Classify a net name as Power, Ground, or None based on known patterns.
    ///
    /// Builds on `shared::is_power_name`/`shared::is_ground_name` and extends
    /// them with bang-suffixed, PDK-prefixed, and analog-domain variants.
    fn classify_power_name(name: &str) -> Option<NetClass> {
        let lower = name.to_ascii_lowercase();

        // Ground patterns (checked first so "0" matches ground). "vssa" sounds
        // like power-domain naming but has the "vss" prefix, so it is ground.
        if crate::shared::is_ground_name(&lower)
            || matches!(lower.as_str(), "gnd!" | "vss!" | "vssa")
            || lower.ends_with("_gnd")
            || lower.ends_with("_vss")
        {
            return Some(NetClass::Ground);
        }

        // Power patterns (incl. PDK-prefixed, e.g. sky130_vdd).
        if crate::shared::is_power_name(&lower)
            || matches!(lower.as_str(), "vbat" | "vdda" | "vdd!")
            || lower.ends_with("_vdd")
            || lower.ends_with("_vcc")
        {
            return Some(NetClass::Power);
        }

        None
    }

    /// Infer I/O directions for each port of a subcircuit.
    ///
    /// Rules:
    /// 1. Port connects only to gate pins -> Input
    /// 2. Port connects to drain pins and never gates -> Output
    /// 3. Port name matches power/ground pattern -> Inout (power)
    /// 4. Otherwise -> Inout
    pub fn infer_port_directions(subckt: &mut Subcircuit) {
        let mut directions: Vec<PinDir> = Vec::with_capacity(subckt.ports.len());

        for port_name in &subckt.ports {
            // Rule 3: power/ground name -> Power/Ground (place.rs power DAG
            // uses these to give X-instances producer/consumer roles, and
            // annotate_power_nets uses them as rail evidence at the top level).
            match classify_power_name(port_name) {
                Some(NetClass::Power) => {
                    directions.push(PinDir::Power);
                    continue;
                }
                Some(NetClass::Ground) => {
                    directions.push(PinDir::Ground);
                    continue;
                }
                _ => {}
            }

            // Find the net for this port.
            let net = match subckt.nets.iter().find(|n| n.name == *port_name) {
                Some(n) => n,
                None => {
                    directions.push(PinDir::Inout);
                    continue;
                }
            };

            let mut has_gate = false;
            let mut has_drain = false;
            let mut has_other = false;

            for pref in &net.pins {
                let inst = match subckt.instances.get(pref.instance_idx.index()) {
                    Some(i) => i,
                    None => {
                        has_other = true;
                        continue;
                    }
                };

                if inst.primitive.is_mosfet() {
                    match pref.pin_idx {
                        PinIdx(1) => has_gate = true,  // G
                        PinIdx(0) => has_drain = true, // D
                        _ => has_other = true,         // S or B
                    }
                } else {
                    has_other = true;
                }
            }

            if has_gate && !has_drain && !has_other {
                // Rule 1: only gate connections.
                directions.push(PinDir::Input);
            } else if has_drain && !has_gate {
                // Rule 2: drain connections, no gates.
                directions.push(PinDir::Output);
            } else {
                // Rule 4: mixed or unknown.
                directions.push(PinDir::Inout);
            }
        }

        subckt.port_directions = directions;
    }

    /// Gate-polarity compatibility for differential candidates: the MOSFET
    /// gates driven by each side must share at least one device polarity
    /// (both sides reach NMOS gates, or both reach PMOS gates). Sides that
    /// drive no gates at all are compatible (passive/port nets).
    fn gate_polarity_compatible(sub: &Subcircuit, net_a: usize, net_b: usize) -> bool {
        let gate_kinds = |ni: usize| -> (bool, bool) {
            let mut nmos = false;
            let mut pmos = false;
            for pref in &sub.nets[ni].pins {
                if pref.pin_idx != PinIdx(1) {
                    continue;
                }
                match sub.instances.get(pref.instance_idx.index()).map(|i| i.primitive) {
                    Some(Primitive::Nmos) => nmos = true,
                    Some(Primitive::Pmos) => pmos = true,
                    _ => {}
                }
            }
            (nmos, pmos)
        };
        let (a_n, a_p) = gate_kinds(net_a);
        let (b_n, b_p) = gate_kinds(net_b);
        // No gate involvement on either side — nothing to contradict.
        if (!a_n && !a_p) || (!b_n && !b_p) {
            return true;
        }
        (a_n && b_n) || (a_p && b_p)
    }

    /// Tag net pairs that look like differential signals.
    ///
    /// Recognised suffix patterns:
    /// - `<base>_p` / `<base>_n`
    /// - `<base>p`  / `<base>n`
    /// - `<base>+`  / `<base>-`
    /// - `<base>_ip` / `<base>_in`
    ///
    /// Nets already classified as Power or Ground are skipped (false-positive
    /// rejection).
    pub fn detect_differential_nets(circuit: &mut Circuit) {
        // Build a name -> index map for quick lookup.
        let name_to_idx: std::collections::HashMap<String, usize> = circuit
            .top
            .nets
            .iter()
            .enumerate()
            .map(|(i, n)| (n.name.to_ascii_lowercase(), i))
            .collect();

        // Collect pairs first to avoid double-borrow issues.
        let mut pairs: Vec<(usize, usize)> = Vec::new();

        for (i, net) in circuit.top.nets.iter().enumerate() {
            // Skip already classified power/ground nets.
            if matches!(net.classification, NetClass::Power | NetClass::Ground) {
                continue;
            }

            let lower = net.name.to_ascii_lowercase();

            // Try each pattern for the positive side.
            let candidates: &[(&str, &str)] =
                &[("_p", "_n"), ("p", "n"), ("+", "-"), ("_ip", "_in")];

            for &(pos_suffix, neg_suffix) in candidates {
                if let Some(base) = lower.strip_suffix(pos_suffix) {
                    // Avoid empty base.
                    if base.is_empty() {
                        continue;
                    }

                    let neg_name = format!("{}{}", base, neg_suffix);
                    if let Some(&j) = name_to_idx.get(&neg_name) {
                        // Check the negative net isn't power/ground.
                        if matches!(
                            circuit.top.nets[j].classification,
                            NetClass::Power | NetClass::Ground
                        ) {
                            continue;
                        }
                        // Bias-rail rejection: a true differential pair drives
                        // gates of SAME-polarity devices. vbp/vbn-style bias
                        // nets drive PMOS gates on one side and NMOS gates on
                        // the other — suffix match alone is a false positive.
                        if !gate_polarity_compatible(&circuit.top, i, j) {
                            continue;
                        }
                        pairs.push((i, j));
                        break; // Don't match multiple patterns for the same net.
                    }
                }
            }
        }

        // Apply classifications.
        for (p_idx, n_idx) in pairs {
            circuit.top.nets[p_idx].classification = NetClass::DifferentialP;
            circuit.top.nets[n_idx].classification = NetClass::DifferentialN;
        }
    }
}

// ===========================================================================
// crate::recognition — VF2-based analog block recognition
// ===========================================================================

pub mod recognition {
    //! Analog block recognition using VF2 subgraph isomorphism.
    //!
    //! Matches declarative pattern templates against the circuit IR and returns
    //! recognized analog building blocks. Patterns are tried most-specific first
    //! (most nodes) and instances are claimed greedily — once an instance belongs
    //! to a block it cannot be reused by a less-specific pattern.

    pub mod vf2 {
        //! VF2 subgraph isomorphism engine for analog block recognition.
        //!
        //! Implements the VF2 algorithm (Cordella et al., 2004) adapted for
        //! circuit graphs where nodes are device instances and edges represent
        //! pin-connectivity constraints (same-net or different-net).

        use crate::ir::{NetId, Primitive, Subcircuit};

        /// Unique identifier for a pattern.
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
        pub enum PatternId {
            DiffPair,
            CurrentMirror,
            CascodeStack,
            CascodeMirror,
            PushPull,
            CommonSource,
            SourceFollower,
            RcCompensation,
            WilsonMirror,
            WidlarMirror,
            ResistorDivider,
        }

        /// A node in the pattern graph (represents a device in the template).
        #[derive(Debug, Clone)]
        pub struct PatternNode {
            pub id: u32,
            /// Required device type, or `None` for wildcard.
            pub device_type: Option<Primitive>,
            /// Constraint relating this node's type to another node.
            pub type_constraint: Option<TypeConstraint>,
        }

        /// Constraint on the device type of a pattern node relative to another node.
        #[derive(Debug, Clone, Copy, PartialEq, Eq)]
        pub enum TypeConstraint {
            /// Must be the same Primitive as the referenced node.
            SameAsNode(u32),
            /// Must be complementary: NMOS<->PMOS or NPN<->PNP.
            Complementary(u32),
        }

        /// An edge in the pattern graph (a pin-connectivity constraint between two nodes).
        #[derive(Debug, Clone)]
        pub struct PatternEdge {
            pub from_node: u32,
            pub from_pin: u32,
            pub to_node: u32,
            pub to_pin: u32,
            pub constraint: EdgeConstraint,
        }

        /// Constraint on the net relationship between two pins.
        #[derive(Debug, Clone, Copy, PartialEq, Eq)]
        pub enum EdgeConstraint {
            /// The two pins must be connected to the same net.
            SameNet,
            /// The two pins must be on different nets.
            DifferentNet,
        }

        /// A complete pattern graph used for VF2 matching.
        #[derive(Debug, Clone)]
        pub struct PatternGraph {
            pub id: PatternId,
            pub nodes: Vec<PatternNode>,
            pub edges: Vec<PatternEdge>,
        }

        impl PatternGraph {
            /// Number of nodes in this pattern (its "specificity").
            pub fn node_count(&self) -> usize {
                self.nodes.len()
            }
        }

        /// Internal state for the VF2 recursive matching algorithm.
        struct Vf2State<'a> {
            pattern: &'a PatternGraph,
            subckt: &'a Subcircuit,
            /// core_1[pattern_node] = Some(circuit_instance_idx) if mapped.
            core_1: Vec<Option<u32>>,
            /// core_2[circuit_instance] = Some(pattern_node_idx) if mapped.
            core_2: Vec<Option<u32>>,
            /// Current depth (number of matched pairs).
            depth: usize,
            /// Collected complete mappings.
            results: Vec<Vec<u32>>,
        }

        impl<'a> Vf2State<'a> {
            fn new(pattern: &'a PatternGraph, subckt: &'a Subcircuit) -> Self {
                let n_pattern = pattern.nodes.len();
                let n_circuit = subckt.instances.len();
                Self {
                    pattern,
                    subckt,
                    core_1: vec![None; n_pattern],
                    core_2: vec![None; n_circuit],
                    depth: 0,
                    results: Vec::new(),
                }
            }

            /// Run VF2 matching, collecting all valid mappings.
            fn run(&mut self) {
                self.match_recursive();
            }

            fn match_recursive(&mut self) {
                if self.depth == self.pattern.nodes.len() {
                    // Complete match found — record the mapping.
                    let mapping: Vec<u32> = self
                        .core_1
                        .iter()
                        .map(|o| o.expect("complete mapping must have all nodes"))
                        .collect();
                    self.results.push(mapping);
                    return;
                }

                // Pick the next unmapped pattern node (lowest index).
                let p_node = self
                    .core_1
                    .iter()
                    .position(|o| o.is_none())
                    .expect("depth < node_count implies an unmapped node exists");

                // Try to map it to each unmapped circuit instance.
                let n_circuit = self.subckt.instances.len();
                for c_inst in 0..n_circuit {
                    if self.core_2[c_inst].is_some() {
                        continue; // already mapped
                    }

                    if self.is_feasible(p_node, c_inst as u32) {
                        // Extend the mapping.
                        self.core_1[p_node] = Some(c_inst as u32);
                        self.core_2[c_inst] = Some(p_node as u32);
                        self.depth += 1;

                        self.match_recursive();

                        // Backtrack.
                        self.depth -= 1;
                        self.core_1[p_node] = None;
                        self.core_2[c_inst] = None;
                    }
                }
            }

            /// Check whether mapping pattern node `p` to circuit instance `c` is feasible.
            fn is_feasible(&self, p: usize, c: u32) -> bool {
                let p_node = &self.pattern.nodes[p];
                let c_inst = &self.subckt.instances[c as usize];

                // 1. Device type check.
                if let Some(required_type) = p_node.device_type {
                    if c_inst.primitive != required_type {
                        return false;
                    }
                }

                // 2. Type constraint check (relative to already-mapped nodes).
                if let Some(ref tc) = p_node.type_constraint {
                    match tc {
                        TypeConstraint::SameAsNode(ref_node) => {
                            if let Some(ref_c) = self.core_1[*ref_node as usize] {
                                let ref_prim = self.subckt.instances[ref_c as usize].primitive;
                                if c_inst.primitive != ref_prim {
                                    return false;
                                }
                            }
                            // If ref node not yet mapped, we can't check — allow for now,
                            // it will be checked when the ref node is mapped.
                        }
                        TypeConstraint::Complementary(ref_node) => {
                            if let Some(ref_c) = self.core_1[*ref_node as usize] {
                                let ref_prim = self.subckt.instances[ref_c as usize].primitive;
                                if !is_complementary(ref_prim, c_inst.primitive) {
                                    return false;
                                }
                            }
                        }
                    }
                }

                // 2b. Check type constraints of already-mapped nodes that reference `p`.
                for (other_p, node) in self.pattern.nodes.iter().enumerate() {
                    if other_p == p {
                        continue;
                    }
                    if let Some(ref tc) = node.type_constraint {
                        let refers_to_p = match tc {
                            TypeConstraint::SameAsNode(ref_node) => *ref_node == p as u32,
                            TypeConstraint::Complementary(ref_node) => *ref_node == p as u32,
                        };
                        if refers_to_p {
                            if let Some(other_c) = self.core_1[other_p] {
                                let other_prim =
                                    self.subckt.instances[other_c as usize].primitive;
                                match tc {
                                    TypeConstraint::SameAsNode(_) => {
                                        if other_prim != c_inst.primitive {
                                            return false;
                                        }
                                    }
                                    TypeConstraint::Complementary(_) => {
                                        if !is_complementary(other_prim, c_inst.primitive) {
                                            return false;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // 3. Edge constraint check: for every pattern edge involving `p` where
                //    the other endpoint is already mapped (or is `p` itself for self-edges),
                //    verify the net constraint.
                for edge in &self.pattern.edges {
                    // Self-edge: both endpoints are the current node `p`.
                    // Check the constraint between two pins on the same circuit instance.
                    if edge.from_node == p as u32 && edge.to_node == p as u32 {
                        let net_a = self.pin_net(c, edge.from_pin);
                        let net_b = self.pin_net(c, edge.to_pin);
                        match edge.constraint {
                            EdgeConstraint::SameNet => match (net_a, net_b) {
                                (Some(a), Some(b)) if a == b => {}
                                _ => return false,
                            },
                            EdgeConstraint::DifferentNet => match (net_a, net_b) {
                                (Some(a), Some(b)) if a != b => {}
                                _ => return false,
                            },
                        }
                        continue;
                    }

                    let (this_pin, other_node, other_pin) = if edge.from_node == p as u32 {
                        (edge.from_pin, edge.to_node, edge.to_pin)
                    } else if edge.to_node == p as u32 {
                        (edge.to_pin, edge.from_node, edge.from_pin)
                    } else {
                        continue; // edge doesn't involve this pattern node
                    };

                    // Only check if the other node is already mapped.
                    if let Some(other_c) = self.core_1[other_node as usize] {
                        let c_net = self.pin_net(c, this_pin);
                        let other_net = self.pin_net(other_c, other_pin);

                        match edge.constraint {
                            EdgeConstraint::SameNet => {
                                match (c_net, other_net) {
                                    (Some(a), Some(b)) if a == b => {} // OK
                                    _ => return false,
                                }
                            }
                            EdgeConstraint::DifferentNet => {
                                match (c_net, other_net) {
                                    (Some(a), Some(b)) if a != b => {} // OK
                                    _ => return false,
                                }
                            }
                        }
                    }
                }

                true
            }

            /// Get the net index for a pin on a circuit instance.
            fn pin_net(&self, inst_idx: u32, pin_idx: u32) -> Option<NetId> {
                self.subckt
                    .instances
                    .get(inst_idx as usize)?
                    .pins
                    .get(pin_idx as usize)?
                    .net_idx
            }
        }

        /// Check if two primitives are complementary (NMOS<->PMOS or NPN<->PNP).
        fn is_complementary(a: Primitive, b: Primitive) -> bool {
            matches!(
                (a, b),
                (Primitive::Nmos, Primitive::Pmos)
                    | (Primitive::Pmos, Primitive::Nmos)
                    | (Primitive::Npn, Primitive::Pnp)
                    | (Primitive::Pnp, Primitive::Npn)
            )
        }

        /// Find all matches of `pattern` in `subckt`.
        ///
        /// Returns a vector of mappings. Each mapping is a `Vec<u32>` of length
        /// `pattern.nodes.len()`, where `mapping[pattern_node_idx]` gives the
        /// circuit instance index it maps to.
        pub fn find_matches(pattern: &PatternGraph, subckt: &Subcircuit) -> Vec<Vec<u32>> {
            if pattern.nodes.is_empty() || subckt.instances.is_empty() {
                return Vec::new();
            }
            let mut state = Vf2State::new(pattern, subckt);
            state.run();
            state.results
        }
    }

    pub mod patterns {
        //! Declarative pattern library for analog block recognition.
        //!
        //! Each function builds a `PatternGraph` describing the topology of an analog
        //! building block. The VF2 engine matches these against the circuit IR.
        //!
        //! Pin index conventions (must match the parser):
        //!   MOSFET: 0=Drain, 1=Gate, 2=Source, 3=Bulk
        //!   Two-terminal (R, C, L, V, I): 0=Plus(p), 1=Minus(n)

        use super::vf2::*;
        use crate::ir::Primitive;

        /// Shorthand for a pattern node with a concrete device type.
        fn node(id: u32, device_type: Primitive) -> PatternNode {
            PatternNode {
                id,
                device_type: Some(device_type),
                type_constraint: None,
            }
        }

        /// Shorthand for a wildcard node constrained to be same-type as `ref_node`.
        fn node_same_as(id: u32, ref_node: u32) -> PatternNode {
            PatternNode {
                id,
                device_type: None,
                type_constraint: Some(TypeConstraint::SameAsNode(ref_node)),
            }
        }

        /// Wildcard node constrained to be complementary to `ref_node`.
        fn node_complementary(id: u32, ref_node: u32) -> PatternNode {
            PatternNode {
                id,
                device_type: None,
                type_constraint: Some(TypeConstraint::Complementary(ref_node)),
            }
        }

        /// Wildcard node: any device type, no constraint.
        fn node_any(id: u32) -> PatternNode {
            PatternNode {
                id,
                device_type: None,
                type_constraint: None,
            }
        }

        fn edge(
            from_node: u32,
            from_pin: u32,
            to_node: u32,
            to_pin: u32,
            constraint: EdgeConstraint,
        ) -> PatternEdge {
            PatternEdge {
                from_node,
                from_pin,
                to_node,
                to_pin,
                constraint,
            }
        }

        fn same_net(from_node: u32, from_pin: u32, to_node: u32, to_pin: u32) -> PatternEdge {
            edge(from_node, from_pin, to_node, to_pin, EdgeConstraint::SameNet)
        }

        fn diff_net(from_node: u32, from_pin: u32, to_node: u32, to_pin: u32) -> PatternEdge {
            edge(
                from_node,
                from_pin,
                to_node,
                to_pin,
                EdgeConstraint::DifferentNet,
            )
        }

        // MOSFET pin indices
        const DRAIN: u32 = 0;
        const GATE: u32 = 1;
        const SOURCE: u32 = 2;

        // Two-terminal pin indices
        const PLUS: u32 = 0;
        const MINUS: u32 = 1;

        /// Return all patterns sorted by specificity (most nodes first).
        pub fn all_patterns() -> Vec<PatternGraph> {
            let mut patterns = vec![
                cascode_mirror(),
                wilson_mirror(),
                widlar_mirror(),
                diff_pair(),
                current_mirror(),
                cascode_stack(),
                push_pull(),
                common_source(),
                source_follower(),
                rc_compensation(),
                resistor_divider(),
            ];
            // Sort by node count descending (most specific first).
            patterns.sort_by_key(|b| std::cmp::Reverse(b.node_count()));
            patterns
        }

        /// **1. Differential pair** — 2 same-type MOSFETs.
        ///
        /// Constraints:
        ///   - Source(0) -- Source(1): SameNet (shared tail)
        ///   - Gate(0) -- Gate(1): DifferentNet
        ///   - Drain(0) -- Drain(1): DifferentNet
        pub fn diff_pair() -> PatternGraph {
            PatternGraph {
                id: PatternId::DiffPair,
                nodes: vec![node_any(0), node_same_as(1, 0)],
                edges: vec![
                    same_net(0, SOURCE, 1, SOURCE), // shared tail
                    diff_net(0, GATE, 1, GATE),     // different inputs
                    diff_net(0, DRAIN, 1, DRAIN),   // different outputs
                ],
            }
        }

        /// **2. Simple current mirror** — 2 same-type MOSFETs.
        ///
        /// Node 0: reference (diode-connected). Node 1: mirror copy.
        pub fn current_mirror() -> PatternGraph {
            PatternGraph {
                id: PatternId::CurrentMirror,
                nodes: vec![
                    node_any(0),        // reference (diode-connected)
                    node_same_as(1, 0), // mirror output
                ],
                edges: vec![
                    same_net(0, GATE, 1, GATE),     // shared gate bias
                    same_net(0, SOURCE, 1, SOURCE), // shared rail
                    same_net(0, GATE, 0, DRAIN),    // diode-connected ref
                ],
            }
        }

        /// **3. Cascode stack** — 2 same-type MOSFETs stacked.
        ///
        /// Node 0: bottom. Node 1: top.
        pub fn cascode_stack() -> PatternGraph {
            PatternGraph {
                id: PatternId::CascodeStack,
                nodes: vec![
                    node_any(0),        // bottom
                    node_same_as(1, 0), // top
                ],
                edges: vec![
                    same_net(0, DRAIN, 1, SOURCE), // stacked
                    diff_net(0, GATE, 1, GATE),    // different bias
                ],
            }
        }

        /// **4. Cascode current mirror** — 4 same-type MOSFETs.
        ///
        /// Nodes 0,1: bottom pair (simple mirror). Nodes 2,3: top pair.
        /// Bottom drains connect to top sources.
        pub fn cascode_mirror() -> PatternGraph {
            PatternGraph {
                id: PatternId::CascodeMirror,
                nodes: vec![
                    node_any(0),        // bottom-ref
                    node_same_as(1, 0), // bottom-mirror
                    node_same_as(2, 0), // top-ref
                    node_same_as(3, 0), // top-mirror
                ],
                edges: vec![
                    // Bottom mirror
                    same_net(0, GATE, 1, GATE),
                    same_net(0, SOURCE, 1, SOURCE),
                    same_net(0, GATE, 0, DRAIN), // bottom-ref diode
                    // Top mirror
                    same_net(2, GATE, 3, GATE),
                    same_net(2, GATE, 2, DRAIN), // top-ref diode
                    // Stacking
                    same_net(0, DRAIN, 2, SOURCE),
                    same_net(1, DRAIN, 3, SOURCE),
                ],
            }
        }

        /// **5. Push-pull output stage** — 1 NMOS + 1 PMOS.
        pub fn push_pull() -> PatternGraph {
            PatternGraph {
                id: PatternId::PushPull,
                nodes: vec![node_any(0), node_complementary(1, 0)],
                edges: vec![
                    same_net(0, GATE, 1, GATE),   // common input
                    same_net(0, DRAIN, 1, DRAIN), // common output
                ],
            }
        }

        /// **6. Common-source amplifier** — 1 MOSFET + 1 resistor load.
        pub fn common_source() -> PatternGraph {
            PatternGraph {
                id: PatternId::CommonSource,
                nodes: vec![node_any(0), node(1, Primitive::Resistor)],
                edges: vec![
                    same_net(0, DRAIN, 1, PLUS), // drain tied to resistor
                ],
            }
        }

        /// **7. Source follower** — 1 MOSFET + 1 current source (Isource).
        pub fn source_follower() -> PatternGraph {
            PatternGraph {
                id: PatternId::SourceFollower,
                nodes: vec![node_any(0), node(1, Primitive::Isource)],
                edges: vec![
                    same_net(0, SOURCE, 1, PLUS), // source to isource
                ],
            }
        }

        /// **8. RC compensation network** — 1 resistor + 1 capacitor in series.
        pub fn rc_compensation() -> PatternGraph {
            PatternGraph {
                id: PatternId::RcCompensation,
                nodes: vec![node(0, Primitive::Resistor), node(1, Primitive::Capacitor)],
                edges: vec![
                    same_net(0, MINUS, 1, PLUS), // series connection
                ],
            }
        }

        /// **9. Wilson current mirror** — 3 same-type MOSFETs.
        ///
        /// Node 0 (M_ref), Node 1 (M_out), Node 2 (M_fb: feedback device).
        pub fn wilson_mirror() -> PatternGraph {
            PatternGraph {
                id: PatternId::WilsonMirror,
                nodes: vec![
                    node_any(0),        // M_ref
                    node_same_as(1, 0), // M_out
                    node_same_as(2, 0), // M_fb
                ],
                edges: vec![
                    same_net(0, GATE, 1, GATE),     // shared gate bias
                    same_net(0, SOURCE, 1, SOURCE), // shared rail
                    same_net(2, SOURCE, 1, DRAIN),  // feedback: M_fb source = M_out drain
                    same_net(2, DRAIN, 0, DRAIN),   // feedback: M_fb drain = M_ref drain
                ],
            }
        }

        /// **10. Widlar current mirror** — 2 same-type MOSFETs + 1 resistor.
        ///
        /// Node 0 (M_ref, diode-connected), Node 1 (M_out), Node 2 (R_deg).
        pub fn widlar_mirror() -> PatternGraph {
            PatternGraph {
                id: PatternId::WidlarMirror,
                nodes: vec![
                    node_any(0),                  // M_ref
                    node_same_as(1, 0),           // M_out
                    node(2, Primitive::Resistor), // R_deg
                ],
                edges: vec![
                    same_net(0, GATE, 0, DRAIN),   // M_ref diode-connected
                    same_net(0, GATE, 1, GATE),    // shared gate bias
                    same_net(1, SOURCE, 2, PLUS),  // M_out source to R degeneration
                    same_net(0, SOURCE, 2, MINUS), // R other end to shared rail
                ],
            }
        }

        /// **11. Resistor voltage divider** — 2 resistors in series.
        pub fn resistor_divider() -> PatternGraph {
            PatternGraph {
                id: PatternId::ResistorDivider,
                nodes: vec![node(0, Primitive::Resistor), node(1, Primitive::Resistor)],
                edges: vec![
                    same_net(0, MINUS, 1, PLUS), // series midpoint
                    diff_net(0, PLUS, 1, MINUS), // different end nets
                ],
            }
        }
    }

    use std::collections::HashSet;

    use crate::ir::{Circuit, NetClass, NetId, Primitive, Subcircuit};
    use vf2::{find_matches, PatternId};

    /// Recognized analog block type.
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub enum BlockType {
        DiffPair,
        CurrentMirror,
        CascodeStack,
        CascodeMirror,
        PushPull,
        CommonSource,
        SourceFollower,
        RcCompensation,
        WilsonMirror,
        WidlarMirror,
        ResistorDivider,
    }

    /// A recognized analog building block.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct Block {
        pub block_type: BlockType,
        pub instance_indices: Vec<u32>,
        pub hint: PlacementHint,
    }

    /// Placement hint computed at recognition time.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct PlacementHint {
        pub h_spacing: i32,
        pub v_spacing: i32,
        pub ordering: DeviceOrdering,
    }

    /// Device ordering within a block.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum DeviceOrdering {
        Unordered,
        RefFirst,
        BottomFirst,
        PmosFirst,
    }

    impl PlacementHint {
        /// Get the default hint for a block type.
        pub fn for_type(bt: BlockType) -> Self {
            hint_for(bt)
        }
    }

    /// Convert a VF2 PatternId to the public BlockType.
    fn pattern_id_to_block_type(id: PatternId) -> BlockType {
        match id {
            PatternId::DiffPair => BlockType::DiffPair,
            PatternId::CurrentMirror => BlockType::CurrentMirror,
            PatternId::CascodeStack => BlockType::CascodeStack,
            PatternId::CascodeMirror => BlockType::CascodeMirror,
            PatternId::PushPull => BlockType::PushPull,
            PatternId::CommonSource => BlockType::CommonSource,
            PatternId::SourceFollower => BlockType::SourceFollower,
            PatternId::RcCompensation => BlockType::RcCompensation,
            PatternId::WilsonMirror => BlockType::WilsonMirror,
            PatternId::WidlarMirror => BlockType::WidlarMirror,
            PatternId::ResistorDivider => BlockType::ResistorDivider,
        }
    }

    fn hint_for(block_type: BlockType) -> PlacementHint {
        match block_type {
            BlockType::DiffPair => PlacementHint {
                h_spacing: 160,
                v_spacing: 0,
                ordering: DeviceOrdering::Unordered,
            },
            BlockType::CurrentMirror => PlacementHint {
                h_spacing: 160,
                v_spacing: 0,
                ordering: DeviceOrdering::RefFirst,
            },
            BlockType::CascodeStack => PlacementHint {
                h_spacing: 0,
                v_spacing: 160,
                ordering: DeviceOrdering::BottomFirst,
            },
            BlockType::CascodeMirror => PlacementHint {
                h_spacing: 160,
                v_spacing: 160,
                ordering: DeviceOrdering::RefFirst,
            },
            BlockType::PushPull => PlacementHint {
                h_spacing: 0,
                v_spacing: 160,
                ordering: DeviceOrdering::PmosFirst,
            },
            BlockType::CommonSource => PlacementHint {
                h_spacing: 0,
                v_spacing: 160,
                ordering: DeviceOrdering::Unordered,
            },
            BlockType::SourceFollower => PlacementHint {
                h_spacing: 0,
                v_spacing: 160,
                ordering: DeviceOrdering::Unordered,
            },
            BlockType::RcCompensation => PlacementHint {
                h_spacing: 160,
                v_spacing: 0,
                ordering: DeviceOrdering::Unordered,
            },
            BlockType::WilsonMirror => PlacementHint {
                h_spacing: 160,
                v_spacing: 160,
                ordering: DeviceOrdering::RefFirst,
            },
            BlockType::WidlarMirror => PlacementHint {
                h_spacing: 160,
                v_spacing: 80,
                ordering: DeviceOrdering::RefFirst,
            },
            BlockType::ResistorDivider => PlacementHint {
                h_spacing: 0,
                v_spacing: 160,
                ordering: DeviceOrdering::Unordered,
            },
        }
    }

    /// For current mirror matches, reorder so the diode-connected device is first.
    /// The diode-connected device is pattern node 0 by definition (see `patterns`).
    fn maybe_reorder_mirror_sub(
        block_type: BlockType,
        mapping: &[u32],
        subckt: &Subcircuit,
    ) -> Vec<u32> {
        if block_type != BlockType::CurrentMirror || mapping.len() < 2 {
            return mapping.to_vec();
        }

        // Pattern node 0 = diode-connected ref. Check which mapping actually has
        // gate == drain (the VF2 match ensures this, but we verify for ordering).
        let idx0 = mapping[0] as usize;
        let inst0 = &subckt.instances[idx0];
        let gate0 = inst0.pins.get(1).and_then(|p| p.net_idx);
        let drain0 = inst0.pins.first().and_then(|p| p.net_idx);

        if gate0.is_some() && gate0 == drain0 {
            // Already correct: node 0 is the diode-connected ref
            mapping.to_vec()
        } else {
            // Swap: node 1 is actually the diode-connected one
            let mut reordered = mapping.to_vec();
            reordered.swap(0, 1);
            reordered
        }
    }

    /// Recognize analog blocks in the circuit's top-level subcircuit.
    ///
    /// Patterns are tried most-specific first (most nodes). Once an instance is
    /// claimed by a block it is excluded from subsequent matches.
    pub fn recognize(circuit: &Circuit) -> Vec<Block> {
        recognize_subcircuit(&circuit.top)
    }

    /// Recognize analog blocks in a subcircuit using VF2 subgraph isomorphism.
    ///
    /// Patterns are tried most-specific first (most nodes). Once an instance is
    /// claimed by a block it is excluded from subsequent matches.
    pub fn recognize_subcircuit(subckt: &Subcircuit) -> Vec<Block> {
        let patterns = patterns::all_patterns();
        let mut blocks = Vec::new();
        let mut claimed: HashSet<u32> = HashSet::new();

        for pattern in &patterns {
            let matches = find_matches(pattern, subckt);
            let block_type = pattern_id_to_block_type(pattern.id);

            for mapping in &matches {
                // Skip if any instance in this match is already claimed.
                if mapping.iter().any(|idx| claimed.contains(idx)) {
                    continue;
                }

                // Reject matches containing voltage sources — they are stimulus
                // elements, not functional circuit blocks.
                if mapping
                    .iter()
                    .any(|&idx| subckt.instances[idx as usize].primitive == Primitive::Vsource)
                {
                    continue;
                }

                // CommonSource/SourceFollower patterns require at least one MOSFET.
                // Without this, two resistors sharing a net can spuriously match.
                if matches!(
                    block_type,
                    BlockType::CommonSource | BlockType::SourceFollower
                ) && !mapping
                    .iter()
                    .any(|&idx| subckt.instances[idx as usize].primitive.is_mosfet())
                {
                    continue;
                }

                // Reject diff-pair matches where the shared source is a power/ground
                // net. Two MOSFETs on the same supply rail with different gates/drains
                // are extremely common but almost never actual differential pairs.
                if block_type == BlockType::DiffPair && is_power_rail_diff_pair(mapping, subckt) {
                    continue;
                }

                // For current mirrors, ensure the diode-connected device is first.
                let ordered = maybe_reorder_mirror_sub(block_type, mapping, subckt);

                // For cascode stacks, ensure bottom device is first.
                let ordered = if block_type == BlockType::CascodeStack {
                    maybe_reorder_cascode_sub(&ordered, subckt)
                } else {
                    ordered
                };

                // Claim all instances in this match.
                for &idx in &ordered {
                    claimed.insert(idx);
                }

                blocks.push(Block {
                    block_type,
                    instance_indices: ordered,
                    hint: hint_for(block_type),
                });
            }
        }

        blocks
    }

    /// Check if a diff-pair match has its shared source on a power/ground rail.
    ///
    /// The diff pair pattern requires Source(0)==Source(1) (shared tail). If that
    /// shared net is classified as Power or Ground, the match is almost certainly
    /// a false positive (two independent transistors on the same supply).
    fn is_power_rail_diff_pair(mapping: &[u32], subckt: &Subcircuit) -> bool {
        if mapping.len() < 2 {
            return false;
        }
        // Source pin index for MOSFETs is 2.
        let source_net = subckt.instances[mapping[0] as usize]
            .pins
            .get(2)
            .and_then(|p| p.net_idx);
        let source_is_power = match source_net {
            Some(net_idx) => subckt.nets.get(net_idx.index()).map_or(false, |net| {
                matches!(net.classification, NetClass::Power | NetClass::Ground)
            }),
            None => false,
        };

        if !source_is_power {
            return false;
        }

        // If drains are on DIFFERENT nets, this is a real diff pair (e.g. PMOS pair
        // with Source=VDD in a folded-cascode OTA) — keep it.
        let inst0 = &subckt.instances[mapping[0] as usize];
        let inst1 = &subckt.instances[mapping[1] as usize];
        let drain0 = inst0.pins.first().and_then(|p| p.net_idx);
        let drain1 = inst1.pins.first().and_then(|p| p.net_idx);

        match (drain0, drain1) {
            (Some(d0), Some(d1)) if d0 != d1 => false, // Different drains = real diff pair
            _ => true, // Same drains or unknown = reject as false positive
        }
    }

    /// For cascode stacks, ensure the bottom device (whose drain connects to the
    /// top's source) is listed first.
    fn maybe_reorder_cascode_sub(mapping: &[u32], subckt: &Subcircuit) -> Vec<u32> {
        if mapping.len() != 2 {
            return mapping.to_vec();
        }

        let idx0 = mapping[0] as usize;
        let idx1 = mapping[1] as usize;

        // Check if inst0's drain == inst1's source (inst0 is bottom)
        let drain0 = subckt.instances[idx0].pins.first().and_then(|p| p.net_idx);
        let source1 = subckt.instances[idx1].pins.get(2).and_then(|p| p.net_idx);

        let ordered = if drain0.is_some() && drain0 == source1 {
            // Already correct: idx0 is bottom
            mapping.to_vec()
        } else {
            // Swap: idx1 is actually the bottom
            vec![mapping[1], mapping[0]]
        };

        // Drain/source chaining assumes the NMOS-to-ground convention
        // (current flows top→bottom through the stack). A charge-pump diode
        // chain inverts it: the device whose source sits on a POWER net hangs
        // from the rail and belongs on TOP; a top device draining into a
        // GROUND net belongs on the bottom. Rail evidence wins (Q2).
        let net_class = |idx: Option<NetId>| {
            idx.and_then(|ni| subckt.nets.get(ni.index()))
                .map(|n| n.classification)
        };
        let bottom_source = net_class(
            subckt.instances[ordered[0] as usize]
                .pins
                .get(2)
                .and_then(|p| p.net_idx),
        );
        let top_drain = net_class(
            subckt.instances[ordered[1] as usize]
                .pins
                .first()
                .and_then(|p| p.net_idx),
        );
        if bottom_source == Some(NetClass::Power) || top_drain == Some(NetClass::Ground) {
            return vec![ordered[1], ordered[0]];
        }
        ordered
    }
}

// ===========================================================================
// Pipeline orchestration
// ===========================================================================

use crate::ir::Circuit;

/// Run annotate → recognize → place → route on an already-parsed circuit,
/// laying out subcircuits bottom-up and then the top level.
pub fn layout_circuit(circuit: &mut Circuit) {
    // Annotate (power/ground classification, port directions, diff pairs).
    annotation::annotate(circuit);

    // Pin geometry needed by placer/router.
    let backend = emit::SchemifyBackend::new("");

    // Stage timing, enabled via N2S_TRACE=1 (perf debugging).
    let trace = std::env::var_os("N2S_TRACE").is_some();
    macro_rules! stage {
        ($label:expr, $body:expr) => {{
            let t = std::time::Instant::now();
            let out = $body;
            if trace {
                eprintln!("[n2s] {}: {:?}", $label, t.elapsed());
            }
            out
        }};
    }

    // Recognize + place + route subcircuits bottom-up.
    for (name, subckt) in circuit.subcircuits.iter_mut() {
        let n = subckt.instances.len();
        let blocks = stage!(
            format!("recognize {name} ({n} insts)"),
            recognition::recognize_subcircuit(subckt)
        );
        stage!(
            format!("place {name}"),
            place::place(subckt, &blocks, &backend)
        );
        stage!(
            format!("route {name}"),
            route::Router::new().route_with_blocks(subckt, &backend, &blocks)
        );
    }

    // Top-level recognize + place + route (pass subcircuit defs for
    // hierarchical placement).
    let n = circuit.top.instances.len();
    let blocks = stage!(
        format!("recognize top ({n} insts)"),
        recognition::recognize(circuit)
    );
    stage!(
        "place top".to_string(),
        place::place_with_children(&mut circuit.top, &blocks, &backend, &circuit.subcircuits)
    );
    stage!(
        "route top".to_string(),
        route::Router::new().route_with_blocks(&mut circuit.top, &backend, &blocks)
    );
}

/// Parse a SPICE netlist and run the full layout pipeline
/// (parse → annotate → recognize → place → route).
///
/// The returned `Circuit` has placement coordinates, wires, and labels filled
/// in; pass it to `emit` for schematic conversion or file output.
pub fn netlist_to_circuit(source: &str) -> anyhow::Result<Circuit> {
    let mut parser = parser::SpiceParser::new();
    let mut circuit = parser
        .parse(source)
        .map_err(|e| anyhow::anyhow!("SPICE parse error: {e}"))?;
    layout_circuit(&mut circuit);
    Ok(circuit)
}

/// Full pipeline: netlist text → laid-out circuit → output files written by
/// the Schemify backend into `output_dir`. Returns the laid-out circuit.
pub fn netlist_to_schem(source: &str, output_dir: &str) -> anyhow::Result<Circuit> {
    let circuit = netlist_to_circuit(source)?;
    let backend = emit::SchemifyBackend::new(output_dir);
    backend.write_all(&circuit)?;
    Ok(circuit)
}

// ===========================================================================
// Tests
// ===========================================================================

#[cfg(test)]
mod tests {
    use crate::annotation::{annotate_power_nets, detect_differential_nets, infer_port_directions};
    use crate::ir::*;
    use crate::recognition::{recognize, BlockType};
    use std::collections::HashMap;

    fn make_pin(name: &str, dir: PinDir) -> Pin {
        Pin {
            name: name.into(),
            dir,
            net_idx: None,
        }
    }

    fn make_mosfet(name: &str, prim: Primitive) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: prim,
            symbol: String::new(),
            pins: vec![
                make_pin("D", PinDir::Inout),
                make_pin("G", PinDir::Input),
                make_pin("S", PinDir::Inout),
                make_pin("B", PinDir::Bulk),
            ],
            params: HashMap::new(),
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        }
    }

    fn make_vsource(name: &str) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: Primitive::Vsource,
            symbol: String::new(),
            pins: vec![make_pin("p", PinDir::Inout), make_pin("n", PinDir::Inout)],
            params: HashMap::new(),
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        }
    }

    fn connect(c: &mut Circuit, net: NetId, inst: InstId, pin: u16) {
        c.connect(
            net,
            PinRef {
                instance_idx: inst,
                pin_idx: PinIdx(pin),
            },
        );
    }

    // -- Annotation: name-based power/ground classification ----------------

    #[test]
    fn power_ground_name_classification() {
        let mut c = Circuit::new("top");
        let vdd = c.add_net(Net::new("vdd"));
        let vss = c.add_net(Net::new("vss"));
        let zero = c.add_net(Net::new("0"));
        let sig = c.add_net(Net::new("out"));

        annotate_power_nets(&mut c);

        assert_eq!(c.top[vdd].classification, NetClass::Power);
        assert_eq!(c.top[vss].classification, NetClass::Ground);
        assert_eq!(c.top[zero].classification, NetClass::Ground);
        assert_eq!(c.top[sig].classification, NetClass::Signal);
    }

    // -- Annotation: vsource topology rule ----------------------------------

    #[test]
    fn vsource_promotes_supply_net_to_power() {
        let mut c = Circuit::new("top");
        let supply = c.add_net(Net::new("supply"));
        let zero = c.add_net(Net::new("0"));
        let v1 = c.add_instance(make_vsource("V1"));

        connect(&mut c, supply, v1, 0); // plus -> supply
        connect(&mut c, zero, v1, 1); // minus -> 0

        // Rail evidence: the net must power something (here a MOSFET source).
        let m1 = c.add_instance(make_mosfet("M1", Primitive::Pmos));
        connect(&mut c, supply, m1, 2);

        annotate_power_nets(&mut c);
        assert_eq!(c.top[supply].classification, NetClass::Power);
    }

    #[test]
    fn vsource_without_rail_evidence_stays_signal() {
        let mut c = Circuit::new("top");
        let bias = c.add_net(Net::new("bias"));
        let zero = c.add_net(Net::new("0"));
        let v1 = c.add_instance(make_vsource("V1"));

        connect(&mut c, bias, v1, 0); // plus -> bias
        connect(&mut c, zero, v1, 1); // minus -> 0

        // Only a gate hangs on the net — a DC bias, not a rail.
        let m1 = c.add_instance(make_mosfet("M1", Primitive::Nmos));
        connect(&mut c, bias, m1, 1);

        annotate_power_nets(&mut c);
        assert_eq!(c.top[bias].classification, NetClass::Signal);
    }

    // -- Annotation: high-fanout bulk/source rule ----------------------------

    #[test]
    fn high_fanout_bulk_net_is_power() {
        let mut c = Circuit::new("top");
        let hf = c.add_net(Net::new("substrate"));
        for i in 0..11 {
            let m = c.add_instance(make_mosfet(&format!("M{i}"), Primitive::Nmos));
            connect(&mut c, hf, m, 3); // bulk pin
        }
        annotate_power_nets(&mut c);
        assert_eq!(c.top[hf].classification, NetClass::Power);
    }

    // -- Annotation: differential suffix detection ----------------------------

    #[test]
    fn differential_suffix_detection() {
        let mut c = Circuit::new("top");
        let _inp = c.add_net(Net::new("inp"));
        let _inn = c.add_net(Net::new("inn"));
        // Power nets must be skipped (false-positive rejection).
        let _vdd = c.add_net(Net::new("vdd"));
        let _vddn = c.add_net(Net::new("vddn"));

        annotate_power_nets(&mut c);
        detect_differential_nets(&mut c);

        assert_eq!(c.top.nets[0].classification, NetClass::DifferentialP);
        assert_eq!(c.top.nets[1].classification, NetClass::DifferentialN);
        assert_eq!(c.top.nets[2].classification, NetClass::Power);
        assert_eq!(c.top.nets[3].classification, NetClass::Signal);
    }

    // -- Annotation: port direction inference ----------------------------------

    #[test]
    fn port_direction_inference() {
        let mut sub = Subcircuit::new("amp");
        sub.ports = vec!["in".to_string(), "out".to_string(), "vdd".to_string()];

        sub.instances.push(make_mosfet("M1", Primitive::Nmos));

        // "in" -> gate only (pin 1), "out" -> drain only (pin 0).
        let mut in_net = Net::new("in");
        in_net.pins.push(PinRef {
            instance_idx: InstId(0),
            pin_idx: PinIdx(1),
        });
        sub.instances[0].pins[1].net_idx = Some(NetId(0));
        sub.nets.push(in_net);

        let mut out_net = Net::new("out");
        out_net.pins.push(PinRef {
            instance_idx: InstId(0),
            pin_idx: PinIdx(0),
        });
        sub.instances[0].pins[0].net_idx = Some(NetId(1));
        sub.nets.push(out_net);

        infer_port_directions(&mut sub);

        assert_eq!(
            sub.port_directions,
            vec![PinDir::Input, PinDir::Output, PinDir::Power]
        );
    }

    // -- Recognition: VF2 diff pair match --------------------------------------

    #[test]
    fn vf2_diff_pair_recognized() {
        let mut c = Circuit::new("test");
        c.add_instance(make_mosfet("M1", Primitive::Nmos));
        c.add_instance(make_mosfet("M2", Primitive::Nmos));
        for &(net, inst, pin) in &[
            ("outm", 0u32, 0u16),
            ("inp", 0, 1),
            ("tail", 0, 2),
            ("outp", 1, 0),
            ("inn", 1, 1),
            ("tail", 1, 2),
        ] {
            let idx = c.get_or_create_net(net);
            connect(&mut c, idx, InstId(inst), pin);
        }

        let blocks = recognize(&c);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].block_type, BlockType::DiffPair);
        let mut indices = blocks[0].instance_indices.clone();
        indices.sort();
        assert_eq!(indices, vec![0, 1]);
    }

    // -- Recognition: VF2 negative case ------------------------------------------

    #[test]
    fn vf2_shared_gate_is_not_diff_pair() {
        let mut c = Circuit::new("test");
        c.add_instance(make_mosfet("M1", Primitive::Nmos));
        c.add_instance(make_mosfet("M2", Primitive::Nmos));
        for &(net, inst, pin) in &[
            ("outm", 0u32, 0u16),
            ("vin", 0, 1),
            ("tail", 0, 2),
            ("outp", 1, 0),
            ("vin", 1, 1),
            ("tail", 1, 2),
        ] {
            let idx = c.get_or_create_net(net);
            connect(&mut c, idx, InstId(inst), pin);
        }

        let matches = crate::recognition::vf2::find_matches(
            &crate::recognition::patterns::diff_pair(),
            &c.top,
        );
        assert!(matches.is_empty(), "shared gate must not match diff pair");
    }
}
