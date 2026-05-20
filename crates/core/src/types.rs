/// Interned string handle. Resolve via handler's interner.
pub type Sym = lasso::Spur;

// ====================================================
// Device & Component Classification
// Matches Zig reference: ../Schemify/src/schematic/types.zig
// ====================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum DeviceKind {
    #[default]
    Unknown = 0,
    // Passives
    Resistor,
    Resistor3,
    VarResistor,
    Capacitor,
    Inductor,
    // Diodes
    Diode,
    Zener,
    // MOSFETs
    Nmos3,
    Pmos3,
    Nmos4,
    Pmos4,
    Nmos4Depl,
    NmosSub,
    PmosSub,
    Nmoshv4,
    Pmoshv4,
    Rnmos4,
    // BJTs
    Npn,
    Pnp,
    // JFETs / MESFET
    Njfet,
    Pjfet,
    Mesfet,
    // Sources
    Vsource,
    Isource,
    Sqwsource,
    Ammeter,
    Behavioral,
    // Controlled sources
    Vcvs,
    Vccs,
    Ccvs,
    Cccs,
    // Transmission / coupling
    Coupling,
    Tline,
    TlineLossy,
    // Switches
    Vswitch,
    Iswitch,
    // Simulation / probes
    Param,
    Probe,
    ProbeDiff,
    Code,
    Graph,
    // HDL
    Hdl,
    // Connectors / labels
    Gnd,
    Vdd,
    LabPin,
    InputPin,
    OutputPin,
    InoutPin,
    // Non-electrical
    Annotation,
    Noconn,
    Title,
    Launcher,
    RgbLed,
    Generic,
    // Hierarchical
    DigitalInstance,
    Subckt,
}

impl DeviceKind {
    pub fn from_name(s: &str) -> Self {
        match s {
            "unknown" => Self::Unknown,
            "resistor" | "res" => Self::Resistor,
            "resistor3" => Self::Resistor3,
            "var_resistor" => Self::VarResistor,
            "capacitor" | "cap" => Self::Capacitor,
            "inductor" | "ind" => Self::Inductor,
            "diode" => Self::Diode,
            "zener" => Self::Zener,
            "nmos3" => Self::Nmos3,
            "pmos3" => Self::Pmos3,
            "nmos4" | "nmos" => Self::Nmos4,
            "pmos4" | "pmos" => Self::Pmos4,
            "nmos4_depl" => Self::Nmos4Depl,
            "nmos_sub" => Self::NmosSub,
            "pmos_sub" => Self::PmosSub,
            "nmoshv4" => Self::Nmoshv4,
            "pmoshv4" => Self::Pmoshv4,
            "rnmos4" => Self::Rnmos4,
            "npn" | "npn2" => Self::Npn,
            "pnp" | "pnp2" => Self::Pnp,
            "njfet" => Self::Njfet,
            "pjfet" => Self::Pjfet,
            "mesfet" => Self::Mesfet,
            "vsource" | "voltage_source" => Self::Vsource,
            "isource" | "current_source" => Self::Isource,
            "sqwsource" => Self::Sqwsource,
            "ammeter" => Self::Ammeter,
            "behavioral" => Self::Behavioral,
            "vcvs" => Self::Vcvs,
            "vccs" => Self::Vccs,
            "ccvs" => Self::Ccvs,
            "cccs" => Self::Cccs,
            "coupling" => Self::Coupling,
            "tline" => Self::Tline,
            "tline_lossy" => Self::TlineLossy,
            "vswitch" => Self::Vswitch,
            "iswitch" => Self::Iswitch,
            "param" => Self::Param,
            "probe" => Self::Probe,
            "probe_diff" => Self::ProbeDiff,
            "code" => Self::Code,
            "graph" => Self::Graph,
            "hdl" => Self::Hdl,
            "gnd" => Self::Gnd,
            "vdd" => Self::Vdd,
            "lab_pin" => Self::LabPin,
            "input_pin" => Self::InputPin,
            "output_pin" => Self::OutputPin,
            "inout_pin" => Self::InoutPin,
            "annotation" => Self::Annotation,
            "noconn" => Self::Noconn,
            "title" => Self::Title,
            "launcher" => Self::Launcher,
            "rgb_led" => Self::RgbLed,
            "generic" => Self::Generic,
            "digital_instance" | "digital_block" => Self::DigitalInstance,
            "subckt" | "subcircuit" => Self::Subckt,
            "spice_block" => Self::Subckt,
            "verilog_a_block" => Self::Hdl,
            _ => Self::Unknown,
        }
    }

    pub fn is_non_electrical(self) -> bool {
        matches!(
            self,
            Self::Annotation
                | Self::Title
                | Self::Param
                | Self::Code
                | Self::Graph
                | Self::Hdl
                | Self::Gnd
                | Self::Vdd
                | Self::LabPin
                | Self::InputPin
                | Self::OutputPin
                | Self::InoutPin
                | Self::Probe
                | Self::ProbeDiff
                | Self::Noconn
                | Self::Launcher
                | Self::RgbLed
                | Self::Generic
        )
    }

    pub fn is_label(self) -> bool {
        matches!(
            self,
            Self::LabPin | Self::InputPin | Self::OutputPin | Self::InoutPin
        )
    }

    pub fn is_power(self) -> bool {
        self == Self::Gnd || self == Self::Vdd
    }

    pub fn prefix(self) -> u8 {
        match self {
            Self::Resistor | Self::Resistor3 | Self::VarResistor => b'R',
            Self::Capacitor => b'C',
            Self::Inductor => b'L',
            Self::Diode | Self::Zener => b'D',
            Self::Nmos3 | Self::Nmos4 | Self::Nmos4Depl | Self::NmosSub
            | Self::Nmoshv4 | Self::Rnmos4 | Self::Pmos3 | Self::Pmos4
            | Self::PmosSub | Self::Pmoshv4 => b'M',
            Self::Npn | Self::Pnp => b'Q',
            Self::Njfet | Self::Pjfet => b'J',
            Self::Mesfet => b'Z',
            Self::Vsource | Self::Sqwsource | Self::Behavioral => b'V',
            Self::Isource | Self::Ammeter => b'I',
            Self::Vcvs => b'E',
            Self::Vccs => b'G',
            Self::Ccvs => b'H',
            Self::Cccs => b'F',
            Self::Coupling => b'K',
            Self::Tline => b'T',
            Self::TlineLossy => b'O',
            Self::Vswitch | Self::Iswitch => b'S',
            Self::DigitalInstance | Self::Subckt => b'X',
            _ => 0,
        }
    }

    pub fn default_pins(self) -> &'static [&'static str] {
        match self {
            Self::Resistor | Self::Capacitor | Self::Inductor
            | Self::Vsource | Self::Isource | Self::Ammeter
            | Self::Behavioral | Self::Sqwsource
            | Self::Vswitch | Self::Iswitch => &["p", "n"],
            Self::Resistor3 => &["p", "n", "t"],
            Self::Diode | Self::Zener => &["p", "n"],
            Self::Nmos3 | Self::Pmos3 | Self::NmosSub | Self::PmosSub
            | Self::Mesfet => &["d", "g", "s"],
            Self::Nmos4 | Self::Pmos4 | Self::Nmos4Depl | Self::Nmoshv4
            | Self::Pmoshv4 | Self::Rnmos4 => &["d", "g", "s", "b"],
            Self::Npn | Self::Pnp => &["c", "b", "e"],
            Self::Njfet | Self::Pjfet => &["d", "g", "s"],
            Self::Vcvs | Self::Vccs | Self::Ccvs | Self::Cccs => &["p", "n", "cp", "cn"],
            Self::Coupling => &["l1", "l2"],
            Self::Tline => &["p1p", "p1n", "p2p", "p2n"],
            Self::TlineLossy => &["p1p", "p1n", "p2p", "p2n"],
            Self::Gnd => &["gnd"],
            Self::Vdd => &["vdd"],
            Self::LabPin | Self::InputPin | Self::OutputPin | Self::InoutPin => &["pin"],
            Self::Probe => &["p"],
            _ => &[],
        }
    }

    pub fn model_keyword(self) -> Option<&'static str> {
        match self {
            Self::Nmos3 | Self::Nmos4 | Self::Nmos4Depl
            | Self::NmosSub | Self::Nmoshv4 | Self::Rnmos4 => Some("nch"),
            Self::Pmos3 | Self::Pmos4 | Self::PmosSub | Self::Pmoshv4 => Some("pch"),
            Self::Npn => Some("npn"),
            Self::Pnp => Some("pnp"),
            Self::Njfet => Some("njf"),
            Self::Pjfet => Some("pjf"),
            Self::Mesfet => Some("NMF"),
            Self::Diode => Some("d"),
            Self::Zener => Some("d"),
            Self::Vswitch => Some("SW"),
            Self::Iswitch => Some("CSW"),
            Self::TlineLossy => Some("LTRA"),
            _ => None,
        }
    }

    pub fn injected_net(self) -> Option<&'static str> {
        match self {
            Self::Gnd => Some("0"),
            Self::Vdd => Some("VDD"),
            _ => None,
        }
    }

    pub fn symbol_name(self) -> &'static str {
        match self {
            Self::Resistor | Self::Resistor3 | Self::VarResistor => "resistor",
            Self::Capacitor => "capacitor",
            Self::Inductor => "inductor",
            Self::Diode => "diode",
            Self::Zener => "zener",
            Self::Nmos3 | Self::Nmos4 | Self::Nmos4Depl
            | Self::NmosSub | Self::Nmoshv4 | Self::Rnmos4 => "nmos",
            Self::Pmos3 | Self::Pmos4 | Self::PmosSub | Self::Pmoshv4 => "pmos",
            Self::Npn => "npn",
            Self::Pnp => "pnp",
            Self::Njfet => "njfet",
            Self::Pjfet => "pjfet",
            Self::Vsource | Self::Behavioral | Self::Sqwsource => "vsource",
            Self::Isource => "isource",
            Self::Ammeter => "ammeter",
            Self::Vcvs => "vcvs",
            Self::Vccs => "vccs",
            Self::Ccvs => "ccvs",
            Self::Cccs => "cccs",
            Self::Coupling => "coupling",
            Self::Tline | Self::TlineLossy => "tline",
            Self::Vswitch => "vswitch",
            Self::Iswitch => "iswitch",
            Self::Probe | Self::ProbeDiff => "probe",
            Self::Gnd => "gnd",
            Self::Vdd => "vdd",
            Self::LabPin => "lab_pin",
            Self::InputPin => "input_pin",
            Self::OutputPin => "output_pin",
            Self::InoutPin => "inout_pin",
            Self::Noconn => "noconn",
            Self::Generic => "generic",
            Self::Subckt => "subckt",
            _ => "vsource",
        }
    }
}

// ====================================================
// Schematic Document Classification
// ====================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum SchematicType {
    #[default]
    Schematic = 0,
    Symbol,
    Testbench,
    Primitive,
}

// ====================================================
// Pin Direction
// ====================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum PinDirection {
    #[default]
    Input = 0,
    Output,
    InOut,
    Power,
    Ground,
}

// ====================================================
// Instance Flags (packed into 1 byte)
// Bits [0:1] = rotation (0-3), bit 2 = flip, bit 3 = bus
// ====================================================

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct InstanceFlags(pub u8);

impl InstanceFlags {
    const FLIP_BIT: u8 = 1 << 2;
    const BUS_BIT: u8 = 1 << 3;

    pub fn new(rotation: u8, flip: bool, bus: bool) -> Self {
        let mut f = rotation & 0x03;
        if flip { f |= Self::FLIP_BIT; }
        if bus { f |= Self::BUS_BIT; }
        Self(f)
    }

    pub fn rotation(self) -> u8 { self.0 & 0x03 }
    pub fn flip(self) -> bool { self.0 & Self::FLIP_BIT != 0 }
    pub fn bus(self) -> bool { self.0 & Self::BUS_BIT != 0 }
}

// ====================================================
// Color (4 bytes, NONE sentinel = alpha 0)
// Color::NONE means "use theme default"
// ====================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Color {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Color {
    pub const NONE: Self = Self { r: 0, g: 0, b: 0, a: 0 };

    pub const fn rgba(r: u8, g: u8, b: u8, a: u8) -> Self {
        Self { r, g, b, a }
    }

    pub const fn rgb(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b, a: 255 }
    }

    pub fn is_none(self) -> bool {
        self.a == 0
    }
}

impl Default for Color {
    fn default() -> Self {
        Self::NONE
    }
}
