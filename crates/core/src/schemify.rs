//! Schemify data model — single-file port of the old core + io crates.
//!
//! Contents: device taxonomy, schematic document (SoA via `soa_derive`),
//! command/tool enums, embedded `.chn_prim` primitive table, and the `.chn`
//! reader/writer (line format round-trip compatible with old files).

use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;
use std::sync::{LazyLock, RwLock};

use lasso::Rodeo;
use soa_derive::StructOfArray;

/// Interned string handle. Resolve via the owning `Rodeo`.
pub type Sym = lasso::Spur;

// ====================================================
// Device & Component Classification
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
            "capacitor" | "cap" | "capa" => Self::Capacitor,
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
            "njfet" | "jfet" => Self::Njfet,
            "pjfet" => Self::Pjfet,
            "mesfet" => Self::Mesfet,
            "vsource" | "voltage_source" => Self::Vsource,
            "isource" | "current_source" => Self::Isource,
            "sqwsource" => Self::Sqwsource,
            "ammeter" => Self::Ammeter,
            "behavioral" | "bsource" => Self::Behavioral,
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

    pub fn is_electrical(self) -> bool {
        !self.is_non_electrical() && self != Self::Unknown && self != Self::Sqwsource
    }

    /// SPICE element letter; 0 = no netlist line of its own.
    pub fn prefix(self) -> u8 {
        match self {
            Self::Resistor | Self::Resistor3 | Self::VarResistor => b'R',
            Self::Capacitor => b'C',
            Self::Inductor => b'L',
            Self::Diode | Self::Zener => b'D',
            Self::Nmos3
            | Self::Nmos4
            | Self::Nmos4Depl
            | Self::NmosSub
            | Self::Nmoshv4
            | Self::Rnmos4
            | Self::Pmos3
            | Self::Pmos4
            | Self::PmosSub
            | Self::Pmoshv4 => b'M',
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
            // OSDI (Verilog-A) device letter in ngspice.
            Self::Hdl => b'N',
            _ => 0,
        }
    }

    pub fn default_pins(self) -> &'static [&'static str] {
        match self {
            Self::Resistor
            | Self::Capacitor
            | Self::Inductor
            | Self::Vsource
            | Self::Isource
            | Self::Ammeter
            | Self::Behavioral
            | Self::Sqwsource
            | Self::Vswitch
            | Self::Iswitch => &["p", "n"],
            Self::Resistor3 => &["p", "n", "t"],
            Self::Diode | Self::Zener => &["p", "n"],
            Self::Nmos3 | Self::Pmos3 | Self::NmosSub | Self::PmosSub | Self::Mesfet => {
                &["d", "g", "s"]
            }
            Self::Nmos4
            | Self::Pmos4
            | Self::Nmos4Depl
            | Self::Nmoshv4
            | Self::Pmoshv4
            | Self::Rnmos4 => &["d", "g", "s", "b"],
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
            Self::Nmos3
            | Self::Nmos4
            | Self::Nmos4Depl
            | Self::NmosSub
            | Self::Nmoshv4
            | Self::Rnmos4 => Some("nch"),
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

    /// Net name a connector injects at its pin position (gnd -> "0").
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
            Self::Nmos3
            | Self::Nmos4
            | Self::Nmos4Depl
            | Self::NmosSub
            | Self::Nmoshv4
            | Self::Rnmos4 => "nmos",
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
            Self::Mesfet => "mesfet",
            Self::Param => "param",
            Self::Code => "code",
            Self::Graph => "graph",
            Self::Hdl => "hdl",
            Self::Gnd => "gnd",
            Self::Vdd => "vdd",
            Self::LabPin => "lab_pin",
            Self::InputPin => "input_pin",
            Self::OutputPin => "output_pin",
            Self::InoutPin => "inout_pin",
            Self::Annotation => "annotation",
            Self::Noconn => "noconn",
            Self::Title => "title",
            Self::Launcher => "launcher",
            Self::RgbLed => "rgb_led",
            Self::Generic => "generic",
            Self::DigitalInstance => "digital_instance",
            Self::Subckt => "subckt",
            Self::Unknown => "generic",
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
// Bits [0:1] = rotation (0-3), bit 2 = flip
// ====================================================

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct InstanceFlags(pub u8);

impl InstanceFlags {
    const ROTATION_MASK: u8 = 0x03;
    const FLIP_BIT: u8 = 1 << 2;

    pub fn new(rotation: u8, flip: bool) -> Self {
        let mut f = rotation & Self::ROTATION_MASK;
        if flip {
            f |= Self::FLIP_BIT;
        }
        Self(f)
    }

    pub fn rotation(self) -> u8 {
        self.0 & Self::ROTATION_MASK
    }

    pub fn flip(self) -> bool {
        self.0 & Self::FLIP_BIT != 0
    }

    /// Apply rotation + flip to a local pin offset.
    /// Flip is applied first (negate x), then rotation.
    /// Caller adds instance (x, y) to get absolute position.
    pub fn transform_point(self, px: i32, py: i32) -> (i32, i32) {
        let fx = if self.flip() { -px } else { px };
        match self.rotation() {
            0 => (fx, py),
            1 => (-py, fx),
            2 => (-fx, -py),
            3 => (py, -fx),
            _ => unreachable!(),
        }
    }
}

// ====================================================
// Color (4 bytes, NONE sentinel = alpha 0 = "use theme default")
// ====================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Color {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Color {
    pub const NONE: Self = Self {
        r: 0,
        g: 0,
        b: 0,
        a: 0,
    };

    pub const fn rgba(r: u8, g: u8, b: u8, a: u8) -> Self {
        Self { r, g, b, a }
    }

    pub const fn rgb(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b, a: 255 }
    }

    pub fn is_none(self) -> bool {
        self.a == 0
    }

    pub fn from_hex(s: &str) -> Result<Self, String> {
        let hex = s.strip_prefix('#').unwrap_or(s);
        let bytes = u32::from_str_radix(hex, 16).map_err(|e| format!("bad color hex: {e}"))?;
        match hex.len() {
            6 => Ok(Self {
                r: ((bytes >> 16) & 0xFF) as u8,
                g: ((bytes >> 8) & 0xFF) as u8,
                b: (bytes & 0xFF) as u8,
                a: 255,
            }),
            8 => Ok(Self {
                r: ((bytes >> 24) & 0xFF) as u8,
                g: ((bytes >> 16) & 0xFF) as u8,
                b: ((bytes >> 8) & 0xFF) as u8,
                a: (bytes & 0xFF) as u8,
            }),
            _ => Err(format!("color hex must be 6 or 8 chars, got {}", hex.len())),
        }
    }
}

impl Default for Color {
    fn default() -> Self {
        Self::NONE
    }
}

// ====================================================
// Connectivity (handler computes, display/sim read)
// ====================================================

#[derive(Debug, Clone, Default)]
pub struct Connectivity {
    /// All resolved nets
    pub nets: Vec<Net>,
    /// Point (x,y) -> net index
    pub point_to_net: HashMap<(i32, i32), usize>,
    /// Per-instance: pin connections (instance_idx -> connections)
    pub instance_connections: Vec<Vec<PinConnection>>,
    /// Net index -> resolved name (parallel to nets)
    pub net_names: Vec<String>,
    /// Instance indices of LabPins with conflicting net names on the same net
    pub label_conflicts: HashSet<usize>,
}

/// A resolved net. Its name lives in `Connectivity::net_names` at the same
/// index (single owned copy; avoids duplicating name strings per net).
#[derive(Debug, Clone)]
pub struct Net {
    pub connections: Vec<NetEndpoint>,
}

#[derive(Debug, Clone)]
pub struct NetEndpoint {
    pub x: i32,
    pub y: i32,
    pub kind: NetConnKind,
}

#[derive(Debug, Clone)]
pub enum NetConnKind {
    WireEndpoint {
        wire_idx: usize,
    },
    InstancePin {
        instance_idx: usize,
        /// Borrowed from the static primitive pin tables (`PinPos::name`).
        pin_name: &'static str,
    },
    Label {
        /// Interned label name; resolve via the interner at display/export time.
        name: Sym,
    },
}

#[derive(Debug, Clone)]
pub struct PinConnection {
    /// Borrowed from the static primitive pin tables (`PinPos::name`).
    pub pin_name: &'static str,
    pub net_idx: usize,
    pub x: i32,
    pub y: i32,
}

// ====================================================
// Simulation backend / stimulus language (minimal: what the .chn format
// stores; the sim module owns the rest when it lands)
// ====================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum SpiceBackend {
    #[default]
    NgSpice = 0,
    Xyce,
}

impl SpiceBackend {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NgSpice => "ngspice",
            Self::Xyce => "xyce",
        }
    }

    pub fn from_name(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "ngspice" => Some(Self::NgSpice),
            "xyce" => Some(Self::Xyce),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum StimulusLang {
    #[default]
    NgSpice = 0,
    Xyce,
    Vacask,
    LtSpice,
    Spectre,
    PySpice,
}

impl StimulusLang {
    /// All variants in declaration order, for UI iteration.
    pub const ALL: &[StimulusLang] = &[
        StimulusLang::NgSpice,
        StimulusLang::Xyce,
        StimulusLang::Vacask,
        StimulusLang::LtSpice,
        StimulusLang::Spectre,
        StimulusLang::PySpice,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::NgSpice => "ngspice",
            Self::Xyce => "xyce",
            Self::Vacask => "vacask",
            Self::LtSpice => "ltspice",
            Self::Spectre => "spectre",
            Self::PySpice => "pyspice",
        }
    }

    pub fn from_name(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "ngspice" => Some(Self::NgSpice),
            "xyce" => Some(Self::Xyce),
            "vacask" => Some(Self::Vacask),
            "ltspice" => Some(Self::LtSpice),
            "spectre" => Some(Self::Spectre),
            "pyspice" => Some(Self::PySpice),
            _ => None,
        }
    }
}

// ====================================================
// Top-Level Schematic Document
// ====================================================

#[derive(Debug, Clone, Default)]
pub struct Schematic {
    pub name: String,
    pub stype: SchematicType,

    // Electrical (SoA — iterated every frame by renderer)
    pub instances: InstanceVec,
    pub wires: WireVec,
    pub buses: BusVec,
    pub bus_rippers: Vec<BusRipper>,

    // Electrical (AoS — per-symbol, moderate count)
    pub pins: Vec<Pin>,

    // Geometric (AoS — fewer objects, accessed individually)
    pub lines: Vec<Line>,
    pub rects: Vec<Rect>,
    pub circles: Vec<Circle>,
    pub arcs: Vec<Arc>,
    pub texts: Vec<Text>,
    pub polygons: Vec<Polygon>,

    // Shared property pool (instances index into this via prop_start/prop_count)
    pub properties: Vec<Property>,
    pub model_defs: Vec<ModelDef>,
    pub globals: Vec<String>,

    // Symbol-level properties (params, annotations, metadata)
    pub sym_properties: Vec<Property>,

    // Plugin data (preserved for round-trip)
    pub plugin_blocks: Vec<PluginBlock>,

    // Code blocks (one per document, not hot path)
    pub spice_body: String,
    pub pyspice_source: String,
    pub documentation: String,
    pub measurements_decl: String,

    pub skip_toplevel_code: bool,

    // Testbench stimulus config (zero-cost defaults for non-testbench)
    pub stimulus_lang: StimulusLang,
    pub sim_backend: SpiceBackend,
    /// PDK process corner ("tt", "ss", ...). Empty = PDK default.
    pub sim_corner: String,
}

impl Schematic {
    pub fn instance_props(&self, idx: usize) -> &[Property] {
        let start = self.instances.prop_start[idx] as usize;
        let count = self.instances.prop_count[idx] as usize;
        &self.properties[start..start + count]
    }

    pub fn translate_instance(&mut self, idx: usize, dx: i32, dy: i32) {
        if idx < self.instances.len() {
            self.instances.x[idx] += dx;
            self.instances.y[idx] += dy;
        }
    }

    pub fn translate_wire(&mut self, idx: usize, dx: i32, dy: i32) {
        if idx < self.wires.len() {
            self.wires.x0[idx] += dx;
            self.wires.y0[idx] += dy;
            self.wires.x1[idx] += dx;
            self.wires.y1[idx] += dy;
        }
    }

    pub fn set_instance_prop(&mut self, idx: usize, key: Sym, value: Sym) {
        if idx >= self.instances.len() {
            return;
        }
        let start = self.instances.prop_start[idx] as usize;
        let count = self.instances.prop_count[idx] as usize;
        let end = (start + count).min(self.properties.len());

        for i in start..end {
            if self.properties[i].key == key {
                self.properties[i].value = value;
                return;
            }
        }

        // Append. Fast path: this instance's props already terminate the pool,
        // so the new property can be pushed in place — no relocation.
        if end == self.properties.len() && count > 0 {
            self.properties.push(Property { key, value });
            self.instances.prop_count[idx] = (end - start + 1) as u16;
            return;
        }

        // Relocate the block to the pool end (one contiguous copy), then append.
        let new_start = self.properties.len();
        self.properties.extend_from_within(start..end);
        self.properties.push(Property { key, value });
        self.instances.prop_start[idx] = new_start as u32;
        self.instances.prop_count[idx] = (end - start + 1) as u16;
    }
}

// ====================================================
// Instance (SoA via soa_derive)
// ~36 bytes per instance, positions iterable without touching props
// ====================================================

#[derive(Debug, Clone, StructOfArray)]
#[soa_derive(Debug, Clone, Default)]
pub struct Instance {
    pub name: Sym,
    pub symbol: Sym,
    pub spice_line: Sym,
    pub x: i32,
    pub y: i32,
    pub kind: DeviceKind,
    pub flags: InstanceFlags,
    /// Start index into Schematic.properties
    pub prop_start: u32,
    /// Number of properties for this instance
    pub prop_count: u16,
    /// Label offset from position
    pub name_offset: [i16; 2],
    /// Parameter display offset
    pub param_offset: [i16; 2],
}

// ====================================================
// Wire (SoA via soa_derive)
// ~26 bytes per wire, positions iterable without touching color
// ====================================================

#[derive(Debug, Clone, StructOfArray)]
#[soa_derive(Debug, Clone, Default)]
pub struct Wire {
    /// Explicit net name, if any. `None` = unnamed (auto-named by the
    /// connectivity engine). Option<Spur> is niche-optimized: same 4 bytes.
    pub net_name: Option<Sym>,
    pub x0: i32,
    pub y0: i32,
    pub x1: i32,
    pub y1: i32,
    /// Color::NONE = use theme default
    pub color: Color,
    /// Thickness in tenths (20 = 2.0x)
    pub thickness: u8,
}

// ====================================================
// Bus (SoA via soa_derive) — first-class multi-signal bus
// ====================================================

#[derive(Debug, Clone, StructOfArray)]
#[soa_derive(Debug, Clone, Default)]
pub struct Bus {
    pub label: Sym,
    pub width: u16,
    pub start_bit: u16,
    pub x0: i32,
    pub y0: i32,
    pub x1: i32,
    pub y1: i32,
    pub color: Color,
    pub thickness: u8,
}

#[derive(Debug, Clone)]
pub struct BusRipper {
    pub bus_idx: u32,
    pub bit: u16,
    pub x: i32,
    pub y: i32,
    pub direction: u8,
    pub stub_len: i16,
}

impl Default for BusRipper {
    fn default() -> Self {
        Self {
            bus_idx: 0,
            bit: 0,
            x: 0,
            y: 0,
            direction: 0,
            stub_len: 20,
        }
    }
}

// ====================================================
// Pin (AoS — per-symbol, moderate count)
// ====================================================

#[derive(Debug, Clone)]
pub struct Pin {
    pub name: Sym,
    pub x: i32,
    pub y: i32,
    pub number: u32,
    pub width: u8,
    pub direction: PinDirection,
}

// ====================================================
// Geometric Primitives (AoS — fewer objects)
// ====================================================

#[derive(Debug, Clone)]
pub struct Line {
    pub x0: i32,
    pub y0: i32,
    pub x1: i32,
    pub y1: i32,
    pub color: Color,
    pub thickness: u8,
}

#[derive(Debug, Clone)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
    pub fill: Color,
    pub stroke: Color,
    pub thickness: u8,
}

#[derive(Debug, Clone)]
pub struct Circle {
    pub cx: i32,
    pub cy: i32,
    pub radius: i32,
    pub fill: Color,
    pub stroke: Color,
    pub thickness: u8,
}

#[derive(Debug, Clone)]
pub struct Arc {
    pub cx: i32,
    pub cy: i32,
    pub radius: i32,
    pub start_angle: f32,
    pub sweep_angle: f32,
    pub stroke: Color,
    pub thickness: u8,
}

#[derive(Debug, Clone)]
pub struct Text {
    pub x: i32,
    pub y: i32,
    pub content: Sym,
    pub font_size: f32,
    pub color: Color,
    pub rotation: u8,
}

#[derive(Debug, Clone)]
pub struct Polygon {
    pub points: Vec<[i32; 2]>,
    pub fill: Color,
    pub stroke: Color,
    pub thickness: u8,
}

// ====================================================
// Properties (shared pool, indexed by Instance.prop_start/prop_count)
// 8 bytes per property (two Sym handles)
// ====================================================

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Property {
    pub key: Sym,
    pub value: Sym,
}

#[derive(Debug, Clone)]
pub struct ModelDef {
    pub name: String,
    pub body: String,
}

// ====================================================
// Plugin Block (round-trip preserved from CHN files)
// ====================================================

#[derive(Debug, Clone, Default)]
pub struct PluginBlock {
    pub name: Sym,
    pub entries: Vec<Property>,
}

// ====================================================
// Single flat Command enum. All commands are undoable.
// String fields (not Sym) — handler interns on receipt.
// ====================================================

#[derive(Debug, Clone)]
pub enum Command {
    // === View ===
    ZoomIn,
    ZoomOut,
    ZoomFit,
    ZoomReset,
    ToggleFullscreen,
    ToggleColorScheme,
    ToggleGrid,

    // === File ===
    FileNew,
    FileOpen,
    FileSave,
    FileSaveAs,
    NewTab,
    CloseTab(usize),
    CloseActiveTab,
    SwitchTab(usize),
    ReloadFromDisk,

    // === Selection ===
    SelectAll,
    SelectNone,
    InvertSelection,

    // === Clipboard ===
    Copy,
    Cut,
    Paste,

    // === Tool ===
    SetTool(Tool),

    // === Dialogs ===
    OpenFindDialog,
    OpenPropsDialog,
    OpenSettings,
    OpenSpiceCodeEditor,
    OpenNewPrimDialog,
    OpenMarketplace,
    OpenImportDialog,
    OpenLibraryBrowser,
    OpenFileExplorer,

    // === Undo/Redo ===
    Undo,
    Redo,

    // === Deletion ===
    DeleteSelected,
    DeleteInstance(usize),
    DeleteWire(usize),

    // === Duplication ===
    DuplicateSelected,

    // === Transform ===
    RotateCw,
    RotateCcw,
    FlipHorizontal,
    FlipVertical,
    NudgeUp,
    NudgeDown,
    NudgeLeft,
    NudgeRight,
    AlignToGrid,

    // === Placement ===
    PlaceDevice {
        symbol_path: String,
        name: String,
        x: i32,
        y: i32,
        rotation: u8,
        flip: bool,
    },

    // === Wiring ===
    AddWire {
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
    },

    // === Geometry ===
    AddLine {
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
    },
    AddRect {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
    },
    AddCircle {
        cx: i32,
        cy: i32,
        radius: i32,
    },
    AddArc {
        cx: i32,
        cy: i32,
        radius: i32,
        start: f32,
        sweep: f32,
    },
    AddText {
        x: i32,
        y: i32,
        content: String,
    },
    AddPolygon {
        points: Vec<[i32; 2]>,
    },

    // === Movement ===
    MoveInstance {
        idx: usize,
        dx: i32,
        dy: i32,
    },
    MoveWire {
        idx: usize,
        dx: i32,
        dy: i32,
    },
    MoveSelected {
        dx: i32,
        dy: i32,
    },

    // === Properties ===
    SetInstanceProp {
        idx: usize,
        key: String,
        value: String,
    },
    RenameInstance {
        idx: usize,
        new_name: String,
    },
    SetSpiceCode(String),
    SetDocumentation(String),
    SetWireColor {
        idx: usize,
        color: Color,
    },

    // === Simulation ===
    RunSim,
    ExportNetlist,
    SetStimulusLang(String),
    SetSimBackend(String),
    SetSimCorner(String),

    // === Symbol ===
    GenerateSymbolFromSchematic,

    // === Bus ===
    AddBus {
        label: String,
        width: u16,
        start_bit: u16,
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
    },
    DeleteBus(usize),
    SetBusWidth {
        idx: usize,
        width: u16,
    },
    RenameBus {
        idx: usize,
        new_name: String,
    },
    AddBusRipper {
        bus_idx: u32,
        bit: u16,
        x: i32,
        y: i32,
        direction: u8,
    },
    DeleteBusRipper(usize),

    // === Wire Editing ===
    SplitWire {
        idx: usize,
        x: i32,
        y: i32,
    },

    // === Alignment ===
    AlignLeft,
    AlignRight,
    AlignTop,
    AlignBottom,
    AlignCenterH,
    AlignCenterV,
    DistributeH,
    DistributeV,

    // === Export ===
    ExportSpice {
        path: String,
    },

    // === Import ===
    ImportSpice {
        path: String,
    },

    // === Marketplace ===
    MarketplaceFetch,
    MarketplaceInstall {
        name: String,
    },
    MarketplaceUninstall {
        name: String,
    },

    // === Plugins ===
    PluginsRefresh,
    PluginCommand {
        tag: String,
        payload: Vec<u8>,
    },
    /// Re-read Config.toml and re-resolve the PDK (after a plugin or
    /// external tool edited it).
    ReloadProjectConfig,

    // === Waveform viewer (tab with doc.wave = Some) ===
    /// Open a `.raw` file: into the active wave tab if there is one,
    /// otherwise creates a new wave tab.
    WaveOpen {
        path: String,
    },
    /// Re-read all loaded `.raw` files of the active wave tab.
    WaveReload,
    /// Plot an expression (`v(out)`, `db(v(out)/v(in))`, …). `file`/`pane`
    /// default to the last-opened file and the active pane.
    WaveAddTrace {
        expr: String,
        file: Option<u16>,
        block: u16,
        pane: Option<u16>,
    },
    WaveRemoveTrace(u32),
    WaveClearTraces,
    WaveSetTraceStyle {
        idx: u32,
        color: Color,
        width: f32,
        /// 0 = solid, 1 = dash, 2 = dot.
        line_style: u8,
        visible: bool,
    },
    WaveAddPane,
    WaveRemovePane(u16),
    WaveSetActivePane(u16),
    /// cursor: 0 = A, 1 = B.
    WaveSetCursor {
        cursor: u8,
        x: f64,
        visible: bool,
    },
    WaveSetXLog(bool),
    WaveSetXRange {
        min: f64,
        max: f64,
    },
    WaveSetYRange {
        pane: u16,
        min: f64,
        max: f64,
    },
    WaveZoomFit,
    WaveExportCsv {
        path: String,
    },

    // === Optimizer (each instance is its own native window; any number
    // may be open at once) ===
    /// Create a new optimizer instance and open its window. Empty name
    /// gets a default ("Optimizer N").
    OptimizerNew {
        name: String,
    },
    /// Close the window and drop the instance.
    OptimizerClose {
        id: u32,
    },
    /// Show/hide the window without dropping the instance state.
    OptimizerSetWindowOpen {
        id: u32,
        open: bool,
    },
    OptimizerAddParam {
        id: u32,
        name: String,
        min: f64,
        max: f64,
        init: f64,
    },
    OptimizerRemoveParam {
        id: u32,
        name: String,
    },
    /// `target`: "min", "max", or a number to approach.
    OptimizerAddObjective {
        id: u32,
        name: String,
        target: String,
        weight: f64,
    },
    OptimizerRemoveObjective {
        id: u32,
        name: String,
    },
    /// `algorithm`: "random" or "nelder-mead".
    OptimizerSetAlgorithm {
        id: u32,
        algorithm: String,
    },
    /// Record measured objective values. `params` = None evaluates the
    /// pending suggested candidate; Some(p) records an external point.
    OptimizerReport {
        id: u32,
        params: Option<Vec<f64>>,
        measured: Vec<f64>,
    },
    /// Clear history + algorithm state, keep params/objectives.
    OptimizerReset {
        id: u32,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum Tool {
    #[default]
    Select = 0,
    Wire,
    Bus,
    BusRipper,
    Move,
    Pan,
    Line,
    Rect,
    Polygon,
    Arc,
    Circle,
    Text,
}

// ====================================================
// Embedded `.chn_prim` primitives — built-in symbol geometry + pin positions.
// Each file is embedded via include_str! (repo-root primitives/) and parsed
// once at first access via LazyLock.
// ====================================================

// ── Drawing primitives (compact i16, used by display for symbol rendering) ──

#[derive(Debug, Clone, Copy)]
pub struct DrawSeg {
    pub x0: i16,
    pub y0: i16,
    pub x1: i16,
    pub y1: i16,
}

#[derive(Debug, Clone, Copy)]
pub struct DrawCircle {
    pub cx: i16,
    pub cy: i16,
    pub r: i16,
}

#[derive(Debug, Clone, Copy)]
pub struct DrawArc {
    pub cx: i16,
    pub cy: i16,
    pub r: i16,
    pub start: i16,
    pub sweep: i16,
}

#[derive(Debug, Clone, Copy)]
pub struct DrawRect {
    pub x0: i16,
    pub y0: i16,
    pub x1: i16,
    pub y1: i16,
}

#[derive(Debug, Clone)]
pub struct DrawText {
    pub x: i16,
    pub y: i16,
    pub content: &'static str,
}

#[derive(Debug, Clone)]
pub struct PinPos {
    pub name: &'static str,
    pub x: i16,
    pub y: i16,
}

// ── Primitive entry ─────────────────────────────────────────────────────────

pub struct PrimEntry {
    pub kind_name: &'static str,
    pub kind: DeviceKind,
    pub prefix: u8,
    pub pins: Vec<&'static str>,
    pub params: Vec<(&'static str, &'static str)>,
    pub model_keyword: Option<&'static str>,
    pub spice_format: Option<&'static str>,
    pub block_type: &'static str,
    pub non_electrical: bool,
    pub injected_net: Option<&'static str>,
    // Drawing geometry
    pub segments: Vec<DrawSeg>,
    pub circles: Vec<DrawCircle>,
    pub arcs: Vec<DrawArc>,
    pub rects: Vec<DrawRect>,
    pub texts: Vec<DrawText>,
    pub pin_positions: Vec<PinPos>,
}

impl PrimEntry {
    pub fn has_drawing(&self) -> bool {
        !self.segments.is_empty()
            || !self.circles.is_empty()
            || !self.arcs.is_empty()
            || !self.rects.is_empty()
    }
}

// ── Public API ──────────────────────────────────────────────────────────────

pub static PRIMITIVES: LazyLock<Vec<PrimEntry>> = LazyLock::new(build_prim_table);

/// Runtime-registered prims: project `.chn_prim` files and generated box
/// symbols for project `.chn` subcircuits. Entries are leaked to `'static`
/// so the same lookup paths serve built-in and runtime symbols; a project
/// reload leaks the previous slice (a few KB, lifetime = program).
static RUNTIME: RwLock<&'static [PrimEntry]> = RwLock::new(&[]);

/// Replace the runtime prim set (called on project config reload).
pub fn register_runtime(entries: Vec<PrimEntry>) {
    *RUNTIME.write().unwrap() = Box::leak(entries.into_boxed_slice());
}

pub fn runtime_prims() -> &'static [PrimEntry] {
    *RUNTIME.read().unwrap()
}

pub fn find_by_name(name: &str) -> Option<&'static PrimEntry> {
    runtime_prims()
        .iter()
        .find(|p| p.kind_name == name)
        .or_else(|| PRIMITIVES.iter().find(|p| p.kind_name == name))
}

pub fn find_by_kind(kind: DeviceKind) -> Option<&'static PrimEntry> {
    PRIMITIVES.iter().find(|p| p.kind == kind)
}

/// Symbol lookup for an instance: its symbol name wins (runtime prims and
/// project symbols carry their own geometry/pins), falling back to the
/// built-in entry for the device kind.
pub fn find_symbol(symbol: &str, kind: DeviceKind) -> Option<&'static PrimEntry> {
    if !symbol.is_empty() {
        if let Some(p) = find_by_name(symbol) {
            return Some(p);
        }
    }
    find_by_kind(kind)
}

pub fn prim_count() -> usize {
    PRIMITIVES.len()
}

/// Parse a runtime `.chn_prim` source. The caller leaks the file content to
/// `'static` (registry entries live for the program). Names that don't match
/// a built-in [`DeviceKind`] netlist as subcircuit instances.
pub fn parse_chn_prim(src: &'static str) -> Option<PrimEntry> {
    let mut entry = parse_prim(&EmbeddedPrim {
        src,
        kind_override: None,
        non_electrical: false,
        injected_net: None,
    });
    if entry.kind_name.is_empty() {
        return None;
    }
    if entry.kind == DeviceKind::Unknown {
        entry.kind = DeviceKind::Subckt;
    }
    Some(entry)
}

/// Generated box symbol for a subcircuit cell. `pins` preserves the
/// subcircuit's port order (it drives netlist pin order); `left` routes a
/// pin to the left edge (inputs), the rest go right. Grid pitch 20 to match
/// the built-in symbols.
pub fn box_symbol(name: &'static str, pins: &[(&'static str, bool)]) -> PrimEntry {
    const PITCH: i16 = 20;
    const HALF_W: i16 = 40;

    let n_left = pins.iter().filter(|(_, left)| *left).count() as i16;
    let n_right = pins.len() as i16 - n_left;
    let rows = n_left.max(n_right).max(1);
    let half_h = (rows * PITCH) / 2 + PITCH / 2;

    // Slots centered on the box: y = slot*PITCH - (count-1)*PITCH/2
    let y_for = |slot: i16, count: i16| slot * PITCH - ((count - 1) * PITCH) / 2;

    let mut pin_positions = Vec::with_capacity(pins.len());
    let mut segments = Vec::with_capacity(pins.len());
    let (mut li, mut ri) = (0i16, 0i16);
    for &(pname, left) in pins {
        let (x, y) = if left {
            let y = y_for(li, n_left.max(1));
            li += 1;
            (-HALF_W, y)
        } else {
            let y = y_for(ri, n_right.max(1));
            ri += 1;
            (HALF_W, y)
        };
        pin_positions.push(PinPos { name: pname, x, y });
        // Stub from box edge to pin.
        let edge = if x < 0 {
            -HALF_W + PITCH / 2
        } else {
            HALF_W - PITCH / 2
        };
        segments.push(DrawSeg {
            x0: edge,
            y0: y,
            x1: x,
            y1: y,
        });
    }

    PrimEntry {
        kind_name: name,
        kind: DeviceKind::Subckt,
        prefix: b'X',
        pins: pins.iter().map(|&(p, _)| p).collect(),
        params: Vec::new(),
        model_keyword: None,
        spice_format: None,
        block_type: "subckt",
        non_electrical: false,
        injected_net: None,
        segments,
        circles: Vec::new(),
        arcs: Vec::new(),
        rects: vec![DrawRect {
            x0: -HALF_W + PITCH / 2,
            y0: -half_h,
            x1: HALF_W - PITCH / 2,
            y1: half_h,
        }],
        texts: vec![DrawText {
            x: 0,
            y: 0,
            content: name,
        }],
        pin_positions,
    }
}

// ── Embedded sources ────────────────────────────────────────────────────────

struct EmbeddedPrim {
    src: &'static str,
    kind_override: Option<&'static str>,
    non_electrical: bool,
    injected_net: Option<&'static str>,
}

fn build_prim_table() -> Vec<PrimEntry> {
    let embedded: &[EmbeddedPrim] = &[
        // Passives
        ep(include_str!("../../../primitives/resistor.chn_prim")),
        ep(include_str!("../../../primitives/resistor3.chn_prim")),
        ep(include_str!("../../../primitives/capacitor.chn_prim")),
        ep(include_str!("../../../primitives/inductor.chn_prim")),
        // Diodes
        ep(include_str!("../../../primitives/diode.chn_prim")),
        ep(include_str!("../../../primitives/zener.chn_prim")),
        // MOSFETs
        ep(include_str!("../../../primitives/nmos3.chn_prim")),
        ep(include_str!("../../../primitives/pmos3.chn_prim")),
        ep_override(include_str!("../../../primitives/nmos.chn_prim"), "nmos4"),
        ep_override(include_str!("../../../primitives/pmos.chn_prim"), "pmos4"),
        // BJTs
        ep(include_str!("../../../primitives/npn.chn_prim")),
        ep(include_str!("../../../primitives/pnp.chn_prim")),
        // JFETs
        ep(include_str!("../../../primitives/njfet.chn_prim")),
        ep(include_str!("../../../primitives/pjfet.chn_prim")),
        // Independent sources
        ep(include_str!("../../../primitives/vsource.chn_prim")),
        ep(include_str!("../../../primitives/isource.chn_prim")),
        ep(include_str!("../../../primitives/ammeter.chn_prim")),
        ep(include_str!("../../../primitives/behavioral.chn_prim")),
        // Controlled sources
        ep(include_str!("../../../primitives/vcvs.chn_prim")),
        ep(include_str!("../../../primitives/vccs.chn_prim")),
        ep(include_str!("../../../primitives/ccvs.chn_prim")),
        ep(include_str!("../../../primitives/cccs.chn_prim")),
        // Switches
        ep(include_str!("../../../primitives/vswitch.chn_prim")),
        ep(include_str!("../../../primitives/iswitch.chn_prim")),
        // Transmission line / coupling
        ep(include_str!("../../../primitives/tline.chn_prim")),
        ep(include_str!("../../../primitives/coupling.chn_prim")),
        // Non-electrical / UI
        ep_special(
            include_str!("../../../primitives/gnd.chn_prim"),
            true,
            Some("0"),
        ),
        ep_special(
            include_str!("../../../primitives/vdd.chn_prim"),
            true,
            Some("VDD"),
        ),
        ep_special(
            include_str!("../../../primitives/lab_pin.chn_prim"),
            true,
            None,
        ),
        ep_special(
            include_str!("../../../primitives/input_pin.chn_prim"),
            true,
            None,
        ),
        ep_special(
            include_str!("../../../primitives/output_pin.chn_prim"),
            true,
            None,
        ),
        ep_special(
            include_str!("../../../primitives/inout_pin.chn_prim"),
            true,
            None,
        ),
        ep_special(
            include_str!("../../../primitives/probe.chn_prim"),
            true,
            None,
        ),
        // Digital / HDL blocks
        ep(include_str!("../../../primitives/digital_block.chn_prim")),
        ep(include_str!("../../../primitives/verilog_a_block.chn_prim")),
        ep(include_str!("../../../primitives/spice_block.chn_prim")),
    ];

    embedded.iter().map(parse_prim).collect()
}

fn ep(src: &'static str) -> EmbeddedPrim {
    EmbeddedPrim {
        src,
        kind_override: None,
        non_electrical: false,
        injected_net: None,
    }
}

fn ep_override(src: &'static str, kind: &'static str) -> EmbeddedPrim {
    EmbeddedPrim {
        src,
        kind_override: Some(kind),
        non_electrical: false,
        injected_net: None,
    }
}

fn ep_special(
    src: &'static str,
    non_electrical: bool,
    injected_net: Option<&'static str>,
) -> EmbeddedPrim {
    EmbeddedPrim {
        src,
        kind_override: None,
        non_electrical,
        injected_net,
    }
}

// ── .chn_prim parser ────────────────────────────────────────────────────────

#[derive(PartialEq)]
enum PrimState {
    Top,
    Pins,
    Params,
    Drawing,
    DrawingLines,
    DrawingPinPos,
}

fn parse_prim(meta: &EmbeddedPrim) -> PrimEntry {
    let src = meta.src;
    let mut entry = PrimEntry {
        kind_name: "",
        kind: DeviceKind::Unknown,
        prefix: 0,
        pins: Vec::new(),
        params: Vec::new(),
        model_keyword: None,
        spice_format: None,
        block_type: "",
        non_electrical: meta.non_electrical,
        injected_net: meta.injected_net,
        segments: Vec::new(),
        circles: Vec::new(),
        arcs: Vec::new(),
        rects: Vec::new(),
        texts: Vec::new(),
        pin_positions: Vec::new(),
    };

    let mut state = PrimState::Top;

    for raw_line in src.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        // Global keyword transitions
        if line.starts_with("chn_prim") {
            state = PrimState::Top;
            continue;
        }
        if let Some(rest) = line.strip_prefix("SYMBOL ") {
            state = PrimState::Top;
            entry.kind_name = meta.kind_override.unwrap_or(rest.trim());
            continue;
        }
        if line.starts_with("desc:") {
            continue;
        }
        if line.starts_with("pins ") || line.starts_with("pins[") {
            state = PrimState::Pins;
            continue;
        }
        if line.starts_with("params ") || line.starts_with("params[") {
            state = PrimState::Params;
            continue;
        }
        if let Some(rest) = line.strip_prefix("spice_prefix:") {
            state = PrimState::Top;
            let v = rest.trim();
            if let Some(&ch) = v.as_bytes().first() {
                entry.prefix = ch;
            }
            continue;
        }
        if let Some(rest) = line.strip_prefix("spice_format:") {
            state = PrimState::Top;
            entry.spice_format = Some(rest.trim());
            continue;
        }
        if let Some(rest) = line.strip_prefix("block_type:") {
            state = PrimState::Top;
            entry.block_type = rest.trim();
            continue;
        }
        if line.starts_with("spice_lib:") {
            state = PrimState::Top;
            continue;
        }
        if line.starts_with("drawing:") {
            state = PrimState::Drawing;
            continue;
        }

        // Drawing sub-section keywords
        if state == PrimState::Drawing
            || state == PrimState::DrawingLines
            || state == PrimState::DrawingPinPos
        {
            if line.starts_with("lines:") {
                state = PrimState::DrawingLines;
                continue;
            }
            if line.starts_with("pin_positions:") {
                state = PrimState::DrawingPinPos;
                continue;
            }
            if let Some(rest) = line.strip_prefix("circle:") {
                if let Some(c) = parse_prim_circle(rest.trim()) {
                    entry.circles.push(c);
                }
                state = PrimState::Drawing;
                continue;
            }
            if let Some(rest) = line.strip_prefix("arc:") {
                if let Some(a) = parse_prim_arc(rest.trim()) {
                    entry.arcs.push(a);
                }
                state = PrimState::Drawing;
                continue;
            }
            if let Some(rest) = line.strip_prefix("rect:") {
                if let Some(pts) = parse_two_points(rest.trim()) {
                    entry.rects.push(DrawRect {
                        x0: pts[0],
                        y0: pts[1],
                        x1: pts[2],
                        y1: pts[3],
                    });
                }
                state = PrimState::Drawing;
                continue;
            }
            if let Some(rest) = line.strip_prefix("text:") {
                if let Some(t) = parse_prim_text(rest.trim()) {
                    entry.texts.push(t);
                }
                state = PrimState::Drawing;
                continue;
            }
        }

        // Data item parsing
        match state {
            PrimState::Top | PrimState::Drawing => {}
            PrimState::Pins => {
                let tok = first_token(line);
                if !tok.is_empty() {
                    entry.pins.push(tok);
                }
            }
            PrimState::Params => {
                if let Some(eq) = line.find('=') {
                    let k = line[..eq].trim();
                    let v = line[eq + 1..].trim();
                    if !k.is_empty() {
                        entry.params.push((k, v));
                    }
                }
            }
            PrimState::DrawingLines => {
                if let Some(pts) = parse_two_points(line) {
                    entry.segments.push(DrawSeg {
                        x0: pts[0],
                        y0: pts[1],
                        x1: pts[2],
                        y1: pts[3],
                    });
                }
            }
            PrimState::DrawingPinPos => {
                if let Some(colon) = line.find(':') {
                    let name = line[..colon].trim();
                    if let Some(pt) = parse_one_point(line[colon + 1..].trim()) {
                        if !name.is_empty() {
                            entry.pin_positions.push(PinPos {
                                name,
                                x: pt[0],
                                y: pt[1],
                            });
                        }
                    }
                }
            }
        }
    }

    // Derive model_keyword from "model" param
    for &(k, v) in &entry.params {
        if k == "model" {
            entry.model_keyword = Some(v);
            break;
        }
    }

    // block_type names the netlist role directly and wins over name-based
    // detection, so user prims dispatch correctly whatever their SYMBOL name.
    entry.kind = match entry.block_type {
        "verilog_a" => DeviceKind::Hdl,
        "digital" => DeviceKind::DigitalInstance,
        "lib" | "subckt" => DeviceKind::Subckt,
        _ => DeviceKind::from_name(entry.kind_name),
    };
    entry
}

// ── Coordinate parsers (borrow from the embedded 'static sources) ──────────

fn parse_i16(s: &'static str) -> Option<(i16, &'static str)> {
    let s = s.trim_start();
    if s.is_empty() {
        return None;
    }
    let (neg, s) = if let Some(rest) = s.strip_prefix('-') {
        (true, rest)
    } else if let Some(rest) = s.strip_prefix('+') {
        (false, rest)
    } else {
        (false, s)
    };
    let end = s
        .bytes()
        .position(|b| !b.is_ascii_digit())
        .unwrap_or(s.len());
    if end == 0 {
        return None;
    }
    let v: i32 = s[..end].parse().ok()?;
    let v = if neg { -v } else { v } as i16;
    Some((v, &s[end..]))
}

fn skip_separators(s: &'static str) -> &'static str {
    let n = s.bytes().take_while(|&b| b == b',' || b == b' ').count();
    &s[n..]
}

fn parse_one_point(s: &'static str) -> Option<[i16; 2]> {
    let paren = s.find('(')?;
    let rest = &s[paren + 1..];
    let (x, rest) = parse_i16(rest)?;
    let rest = skip_separators(rest);
    let (y, _) = parse_i16(rest)?;
    Some([x, y])
}

fn parse_two_points(s: &'static str) -> Option<[i16; 4]> {
    let p1 = s.find('(')?;
    let rest = &s[p1 + 1..];
    let (x0, rest) = parse_i16(rest)?;
    let rest = skip_separators(rest);
    let (y0, rest) = parse_i16(rest)?;
    let p2 = rest.find('(')?;
    let rest = &rest[p2 + 1..];
    let (x1, rest) = parse_i16(rest)?;
    let rest = skip_separators(rest);
    let (y1, _) = parse_i16(rest)?;
    Some([x0, y0, x1, y1])
}

fn parse_prim_circle(s: &'static str) -> Option<DrawCircle> {
    let pt = parse_one_point(s)?;
    let r = find_named_i16(s, "r=")?;
    Some(DrawCircle {
        cx: pt[0],
        cy: pt[1],
        r,
    })
}

fn parse_prim_arc(s: &'static str) -> Option<DrawArc> {
    let pt = parse_one_point(s)?;
    Some(DrawArc {
        cx: pt[0],
        cy: pt[1],
        r: find_named_i16(s, "r=")?,
        start: find_named_i16(s, "start=")?,
        sweep: find_named_i16(s, "sweep=")?,
    })
}

fn find_named_i16(s: &'static str, key: &str) -> Option<i16> {
    let pos = s.find(key)?;
    let rest = &s[pos + key.len()..];
    let (val, _) = parse_i16(rest)?;
    Some(val)
}

fn parse_prim_text(s: &'static str) -> Option<DrawText> {
    let pt = parse_one_point(s)?;
    let close = s.find(')')?;
    let after = s[close + 1..].trim();
    let content = if after.len() >= 2 && after.starts_with('"') && after.ends_with('"') {
        &after[1..after.len() - 1]
    } else {
        after
    };
    if content.is_empty() {
        return None;
    }
    Some(DrawText {
        x: pt[0],
        y: pt[1],
        content,
    })
}

fn first_token(s: &'static str) -> &'static str {
    let end = s
        .bytes()
        .position(|b| b == b' ' || b == b'\t')
        .unwrap_or(s.len());
    &s[..end]
}

// ====================================================
// .chn Reader (line-by-line state machine; graceful degrade —
// malformed fields fall back to defaults and are reported as warnings)
// ====================================================

/// Parse a CHN file into a Schematic.
/// All strings are interned via the provided `Rodeo`.
pub fn read_chn(data: &str, interner: &mut Rodeo) -> Schematic {
    read_chn_report(data, interner).0
}

/// Parse a CHN file, also returning non-fatal warnings (malformed values,
/// skipped sections) with 1-based line numbers. Parsing never fails outright:
/// malformed fields fall back to defaults, but each fallback is reported here
/// instead of being silently swallowed.
pub fn read_chn_report(data: &str, interner: &mut Rodeo) -> (Schematic, Vec<ParseWarning>) {
    let mut sch = Schematic::default();
    let mut w = Warnings::default();
    parse_chn(&mut sch, data, interner, &mut w);
    (sch, w.list)
}

/// A non-fatal problem found while parsing a CHN file.
#[derive(Debug, Clone)]
pub struct ParseWarning {
    /// 1-based source line.
    pub line: u32,
    pub msg: String,
}

impl std::fmt::Display for ParseWarning {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "line {}: {}", self.line, self.msg)
    }
}

/// Warning accumulator threaded through the section parsers.
/// `line` is kept current by the main parse loop.
#[derive(Default)]
struct Warnings {
    list: Vec<ParseWarning>,
    line: u32,
}

impl Warnings {
    fn warn(&mut self, msg: String) {
        self.list.push(ParseWarning {
            line: self.line,
            msg,
        });
    }

    /// Parse a present token; warn and fall back to `default` if malformed.
    fn num<T: std::str::FromStr + Copy>(&mut self, field: &str, v: &str, default: T) -> T {
        v.parse().unwrap_or_else(|_| {
            self.warn(format!("invalid {field} '{v}'"));
            default
        })
    }

    /// Optional positional token: absent is fine (silent default, the format
    /// allows omission); present-but-malformed warns.
    fn opt_num<T: std::str::FromStr + Copy>(
        &mut self,
        field: &str,
        v: Option<&str>,
        default: T,
    ) -> T {
        match v {
            None => default,
            Some(s) => self.num(field, s, default),
        }
    }

    /// Required positional token: warns when absent or malformed.
    fn req_num<T: std::str::FromStr + Copy>(
        &mut self,
        field: &str,
        v: Option<&str>,
        default: T,
    ) -> T {
        match v {
            None => {
                self.warn(format!("missing {field}"));
                default
            }
            Some(s) => self.num(field, s, default),
        }
    }

    fn hex_color(&mut self, hex: &str) -> Color {
        Color::from_hex(hex).unwrap_or_else(|_| {
            self.warn(format!("invalid color '#{hex}'"));
            Color::NONE
        })
    }
}

#[derive(Default, PartialEq)]
enum Section {
    #[default]
    None,
    Pins,
    Params,
    Instances,
    TypeTable,
    Nets,
    Wires,
    Buses,
    BusRippers,
    Drawing,
    Includes,
    Analyses,
    Measures,
    CodeBlock,
    Annotations,
    Generate,
    Plugin,
    PluginMultiline,
    Pyspice,
    Documentation,
    /// Unknown section -- skip lines for forward compatibility.
    Skip,
}

#[derive(Default)]
struct TypeTableState {
    symbol: String,
    columns: Vec<String>,
    kind: DeviceKind,
}

#[derive(Default)]
struct GenState {
    var_name: String,
    range_start: i32,
    range_end: i32,
    lines: Vec<String>,
}

#[derive(Default)]
struct PluginMLState {
    plugin_idx: usize,
    key: String,
    lines: Vec<String>,
}

fn parse_chn(s: &mut Schematic, data: &str, int: &mut Rodeo, w: &mut Warnings) {
    let mut section = Section::None;
    let mut tt = TypeTableState::default();
    let mut gen = GenState::default();
    let mut pml = PluginMLState::default();
    let mut pyspice_buf = String::new();
    let mut doc_buf = String::new();
    let mut code_buf = String::new();
    let mut _version: u8 = 1;

    for (lineno, raw) in data.lines().enumerate() {
        w.line = lineno as u32 + 1;
        let full = raw.trim_end();
        let line = strip_comment(full);
        if line.is_empty() {
            continue;
        }
        let trimmed = line.trim_start();
        let indent = indent_level(line);

        // --- Multiline accumulators ---
        match section {
            Section::Pyspice if indent >= 1 => {
                accumulate(&mut pyspice_buf, trimmed);
                continue;
            }
            Section::Pyspice => {
                s.pyspice_source = std::mem::take(&mut pyspice_buf);
                section = Section::None;
            }
            Section::Documentation if indent >= 1 => {
                accumulate(&mut doc_buf, trimmed);
                continue;
            }
            Section::Documentation => {
                s.documentation = std::mem::take(&mut doc_buf);
                section = Section::None;
            }
            Section::CodeBlock if indent >= 2 => {
                accumulate(&mut code_buf, trimmed);
                continue;
            }
            Section::CodeBlock => {
                s.spice_body = std::mem::take(&mut code_buf);
                section = Section::None;
            }
            Section::PluginMultiline if indent >= 2 => {
                pml.lines.push(trimmed.to_string());
                continue;
            }
            Section::PluginMultiline => {
                flush_plugin_ml(s, &mut pml, int);
                section = Section::Plugin;
            }
            Section::Generate if indent >= 2 => {
                gen.lines.push(trimmed.to_string());
                continue;
            }
            Section::Generate => {
                expand_generate(s, &gen, int, w);
                gen = GenState::default();
                section = Section::None;
            }
            _ => {}
        }

        // --- Indent 0: top-level declarations ---
        if indent == 0 {
            if trimmed.starts_with("chn_prim") {
                s.stype = SchematicType::Primitive;
                _version = parse_header_version(trimmed);
            } else if trimmed.starts_with("chn_testbench") {
                s.stype = SchematicType::Testbench;
                _version = parse_header_version(trimmed);
            } else if trimmed.starts_with("chn ") || trimmed == "chn" {
                _version = parse_header_version(trimmed);
            } else if let Some(rest) = trimmed.strip_prefix("SYMBOL ") {
                s.name = rest.trim().to_string();
                s.stype = SchematicType::Symbol;
            } else if let Some(rest) = trimmed.strip_prefix("TESTBENCH ") {
                s.name = rest.trim().to_string();
                s.stype = SchematicType::Testbench;
            } else if let Some(rest) = trimmed.strip_prefix("SCHEMATIC ") {
                s.name = rest.trim().to_string();
                s.stype = SchematicType::Schematic;
            } else if trimmed == "SCHEMATIC" {
                s.stype = SchematicType::Schematic;
            } else if let Some(rest) = trimmed.strip_prefix("PLUGIN ") {
                let name = rest.trim();
                s.plugin_blocks.push(PluginBlock {
                    name: int.get_or_intern(name),
                    entries: Vec::new(),
                });
                section = Section::Plugin;
                continue;
            } else if trimmed == "PYSPICE" {
                section = Section::Pyspice;
                continue;
            } else if trimmed == "DOCUMENTATION" {
                section = Section::Documentation;
                continue;
            }
            section = Section::None;
            continue;
        }

        // --- Indent 1: section headers or plugin entries ---
        if indent == 1 {
            // Plugin entries at indent 1
            if section == Section::Plugin {
                parse_plugin_entry(s, trimmed, &mut pml, &mut section, int);
                continue;
            }

            // Symbol metadata
            if let Some(rest) = trimmed.strip_prefix("desc: ") {
                s.sym_properties.push(Property {
                    key: int.get_or_intern("description"),
                    value: int.get_or_intern(rest.trim()),
                });
                continue;
            }
            if let Some(rest) = trimmed.strip_prefix("type: ") {
                s.sym_properties.push(Property {
                    key: int.get_or_intern("type"),
                    value: int.get_or_intern(rest.trim()),
                });
                continue;
            }
            if let Some(rest) = trimmed.strip_prefix("stimulus_lang: ") {
                if let Some(lang) = StimulusLang::from_name(rest.trim()) {
                    s.stimulus_lang = lang;
                }
                continue;
            }
            if let Some(rest) = trimmed.strip_prefix("sim_backend: ") {
                if let Some(be) = SpiceBackend::from_name(rest.trim()) {
                    s.sim_backend = be;
                }
                continue;
            }
            if let Some(rest) = trimmed.strip_prefix("sim_corner: ") {
                s.sim_corner = rest.trim().to_string();
                continue;
            }

            let sec_name = trimmed.trim_end_matches(':');
            section = match sec_name {
                "pins" => Section::Pins,
                "params" | "parameters" => Section::Params,
                "instances" => Section::Instances,
                "nets" | "connections" => Section::Nets,
                "wires" => Section::Wires,
                "buses" => Section::Buses,
                "bus_rippers" => Section::BusRippers,
                "drawing" => Section::Drawing,
                "includes" => Section::Includes,
                "analyses" => Section::Analyses,
                "measures" | "measurements" => Section::Measures,
                "code" | "code_block" | "spice_code" => Section::CodeBlock,
                "annotations" => Section::Annotations,
                _ => {
                    if trimmed.contains('{') && trimmed.contains('}') {
                        if let Some(parsed) = parse_type_table_header(trimmed) {
                            tt = parsed;
                            Section::TypeTable
                        } else {
                            w.warn(format!(
                                "malformed type table header '{trimmed}', section skipped"
                            ));
                            Section::Skip
                        }
                    } else if trimmed.starts_with("generate ") {
                        if let Some(g) = parse_generate_header(trimmed) {
                            gen = g;
                            Section::Generate
                        } else {
                            w.warn(format!(
                                "malformed generate header '{trimmed}', section skipped"
                            ));
                            Section::Skip
                        }
                    } else {
                        w.warn(format!("unknown section '{sec_name}', contents skipped"));
                        Section::Skip
                    }
                }
            };
            continue;
        }

        // --- Indent 2+: section content ---
        match section {
            Section::Pins => parse_pin(s, trimmed, int, w),
            Section::Params => parse_param(s, trimmed, int),
            Section::Instances => parse_instance(s, trimmed, int, w),
            Section::TypeTable => parse_type_table_row(s, &tt, trimmed, int, w),
            Section::Wires => parse_wire(s, trimmed, int, w),
            Section::Buses => parse_bus(s, trimmed, int, w),
            Section::BusRippers => parse_bus_ripper(s, trimmed, w),
            Section::Drawing => parse_drawing(s, trimmed, int, w),
            Section::Analyses => parse_prefixed(s, "analysis.", trimmed, int),
            Section::Measures => parse_prefixed(s, "measure.", trimmed, int),
            Section::Annotations => parse_prefixed(s, "ann.", trimmed, int),
            Section::Plugin => parse_plugin_entry(s, trimmed, &mut pml, &mut section, int),
            Section::Skip => {} // silently ignore content in unknown sections
            _ => {}
        }
    }

    // Flush remaining accumulators
    if !pyspice_buf.is_empty() {
        s.pyspice_source = pyspice_buf;
    }
    if !doc_buf.is_empty() {
        s.documentation = doc_buf;
    }
    if !code_buf.is_empty() {
        s.spice_body = code_buf;
    }
    if !pml.lines.is_empty() {
        flush_plugin_ml(s, &mut pml, int);
    }
    if !gen.lines.is_empty() {
        expand_generate(s, &gen, int, w);
    }
}

// ── Section parsers ─────────────────────────────────────────────────────────

/// Pin: `name dir [x=X] [y=Y] [width=N]`
fn parse_pin(s: &mut Schematic, line: &str, int: &mut Rodeo, w: &mut Warnings) {
    let mut tok = line.split_whitespace();
    let name = match tok.next() {
        Some(n) => n,
        None => return,
    };
    let dir_str = tok.next().unwrap_or("inout");
    let direction = match dir_str {
        "in" | "input" => PinDirection::Input,
        "out" | "output" => PinDirection::Output,
        "inout" => PinDirection::InOut,
        "power" => PinDirection::Power,
        "ground" | "gnd" => PinDirection::Ground,
        other => {
            w.warn(format!("unknown pin direction '{other}', using inout"));
            PinDirection::InOut
        }
    };
    let mut x = 0i32;
    let mut y = 0i32;
    let mut width = 1u8;
    for attr in tok {
        if let Some(v) = attr.strip_prefix("x=") {
            x = w.num("pin x", v, 0);
        } else if let Some(v) = attr.strip_prefix("y=") {
            y = w.num("pin y", v, 0);
        } else if let Some(v) = attr.strip_prefix("width=") {
            width = w.num("pin width", v, 1);
        }
    }
    s.pins.push(Pin {
        name: int.get_or_intern(name),
        x,
        y,
        number: s.pins.len() as u32,
        width,
        direction,
    });
}

/// Param: `key = value`
fn parse_param(s: &mut Schematic, line: &str, int: &mut Rodeo) {
    let Some(eq) = line.find('=') else { return };
    let key = line[..eq].trim();
    let val = line[eq + 1..].trim();
    if key.is_empty() {
        return;
    }
    s.sym_properties.push(Property {
        key: int.get_or_intern(key),
        value: int.get_or_intern(val),
    });
}

/// Instance: `name symbol [x=X] [y=Y] [rot=R] [flip=1] [key=val...]`
fn parse_instance(s: &mut Schematic, line: &str, int: &mut Rodeo, w: &mut Warnings) {
    let mut tok = line.split_whitespace();
    let name = match tok.next() {
        Some(n) => n,
        None => return,
    };
    let symbol = match tok.next() {
        Some(sym) => sym,
        None => return,
    };

    let mut x = 0i32;
    let mut y = 0i32;
    let mut rotation = 0u8;
    let mut flip = false;
    let prop_start = s.properties.len() as u32;

    // Check for .parameters{} block
    let rest: String = tok.collect::<Vec<_>>().join(" ");
    let (attrs, params_block) = if let Some(start) = rest.find(".parameters{") {
        let end = rest[start..]
            .find('}')
            .map(|e| start + e + 1)
            .unwrap_or(rest.len());
        let block = &rest[start + 12..end.saturating_sub(1)];
        let before = rest[..start].to_string();
        (before, Some(block.to_string()))
    } else {
        (rest, None)
    };

    for attr in split_kv_attrs(&attrs) {
        if let Some(v) = attr.strip_prefix("x=") {
            x = w.num("instance x", v, 0);
        } else if let Some(v) = attr.strip_prefix("y=") {
            y = w.num("instance y", v, 0);
        } else if let Some(v) = attr.strip_prefix("rot=") {
            rotation = w.num("instance rot", v, 0);
        } else if attr == "flip=1" {
            flip = true;
        } else if attr.starts_with("sym=") {
            // Symbol override -- skip, already have symbol
        } else if let Some(eq) = attr.find('=') {
            let k = &attr[..eq];
            let v = attr[eq + 1..].trim_matches('"');
            s.properties.push(Property {
                key: int.get_or_intern(k),
                value: int.get_or_intern(v),
            });
        }
    }

    // Parse .parameters{} block
    if let Some(block) = params_block {
        for param in block.split_whitespace() {
            if let Some(eq) = param.find('=') {
                let k = &param[..eq];
                let v = &param[eq + 1..];
                s.properties.push(Property {
                    key: int.get_or_intern(k),
                    value: int.get_or_intern(v),
                });
            }
        }
    }

    let prop_count = (s.properties.len() as u32 - prop_start) as u16;
    let kind = symbol_to_kind(symbol);

    s.instances.push(Instance {
        name: int.get_or_intern(name),
        symbol: int.get_or_intern(symbol),
        spice_line: int.get_or_intern(""),
        x,
        y,
        kind,
        flags: InstanceFlags::new(rotation, flip),
        prop_start,
        prop_count,
        name_offset: [0, 0],
        param_offset: [0, 0],
    });
}

/// Type table row: values matched to column headers
fn parse_type_table_row(
    s: &mut Schematic,
    tt: &TypeTableState,
    line: &str,
    int: &mut Rodeo,
    w: &mut Warnings,
) {
    let vals: Vec<&str> = line.split_whitespace().collect();
    if vals.is_empty() {
        return;
    }

    let mut x = 0i32;
    let mut y = 0i32;
    let mut rotation = 0u8;
    let mut flip = false;
    let mut name = "";
    let prop_start = s.properties.len() as u32;

    for (i, col) in tt.columns.iter().enumerate() {
        let val = vals.get(i).copied().unwrap_or("");
        match col.as_str() {
            "name" => name = val,
            "x" => x = w.num("x", val, 0),
            "y" => y = w.num("y", val, 0),
            "rot" => rotation = w.num("rot", val, 0),
            "flip" => flip = val == "1",
            _ => {
                s.properties.push(Property {
                    key: int.get_or_intern(col),
                    value: int.get_or_intern(val),
                });
            }
        }
    }

    let prop_count = (s.properties.len() as u32 - prop_start) as u16;

    s.instances.push(Instance {
        name: int.get_or_intern(name),
        symbol: int.get_or_intern(&tt.symbol),
        spice_line: int.get_or_intern(""),
        x,
        y,
        kind: tt.kind,
        flags: InstanceFlags::new(rotation, flip),
        prop_start,
        prop_count,
        name_offset: [0, 0],
        param_offset: [0, 0],
    });
}

/// Wire: `x0 y0 x1 y1 [net_name] [bus=1] [color=#RRGGBB]`
fn parse_wire(s: &mut Schematic, line: &str, int: &mut Rodeo, w: &mut Warnings) {
    let mut tok = line.split_whitespace();
    let x0: i32 = w.req_num("wire x0", tok.next(), 0);
    let y0: i32 = w.req_num("wire y0", tok.next(), 0);
    let x1: i32 = w.req_num("wire x1", tok.next(), 0);
    let y1: i32 = w.req_num("wire y1", tok.next(), 0);

    // Skip zero-length wires
    if x0 == x1 && y0 == y1 {
        return;
    }

    let mut color = Color::NONE;

    for attr in tok {
        if attr == "bus=1" {
            // bus field removed -- ignore for backward compat
        } else if let Some(hex) = attr.strip_prefix("color=#") {
            color = w.hex_color(hex);
        }
    }

    // Net name: bare word after coordinates, before key=value attrs.
    let net_sym: Option<Sym> = line
        .split_whitespace()
        .nth(4)
        .filter(|attr| !attr.contains('='))
        .map(|attr| int.get_or_intern(attr));

    s.wires.push(Wire {
        net_name: net_sym,
        x0,
        y0,
        x1,
        y1,
        color,
        thickness: 0,
    });
}

/// Bus: `label width start_bit x0 y0 x1 y1 [color=#RRGGBB]`
fn parse_bus(s: &mut Schematic, line: &str, int: &mut Rodeo, w: &mut Warnings) {
    let mut tok = line.split_whitespace();
    let label = match tok.next() {
        Some(l) => l,
        None => return,
    };
    let width: u16 = w.req_num("bus width", tok.next(), 1);
    let start_bit: u16 = w.req_num("bus start_bit", tok.next(), 0);
    let x0: i32 = w.req_num("bus x0", tok.next(), 0);
    let y0: i32 = w.req_num("bus y0", tok.next(), 0);
    let x1: i32 = w.req_num("bus x1", tok.next(), 0);
    let y1: i32 = w.req_num("bus y1", tok.next(), 0);

    let mut color = Color::NONE;
    for attr in tok {
        if let Some(hex) = attr.strip_prefix("color=#") {
            color = w.hex_color(hex);
        }
    }

    s.buses.push(Bus {
        label: int.get_or_intern(label),
        width,
        start_bit,
        x0,
        y0,
        x1,
        y1,
        color,
        thickness: 0,
    });
}

/// BusRipper: `bus_idx bit x y dir=D stub=S`
fn parse_bus_ripper(s: &mut Schematic, line: &str, w: &mut Warnings) {
    let mut tok = line.split_whitespace();
    let bus_idx: u32 = w.req_num("ripper bus_idx", tok.next(), 0);
    let bit: u16 = w.req_num("ripper bit", tok.next(), 0);
    let x: i32 = w.req_num("ripper x", tok.next(), 0);
    let y: i32 = w.req_num("ripper y", tok.next(), 0);

    let mut direction: u8 = 0;
    let mut stub_len: i16 = 20;
    for attr in tok {
        if let Some(v) = attr.strip_prefix("dir=") {
            direction = w.num("ripper dir", v, 0);
        } else if let Some(v) = attr.strip_prefix("stub=") {
            stub_len = w.num("ripper stub", v, 20);
        }
    }

    s.bus_rippers.push(BusRipper {
        bus_idx,
        bit,
        x,
        y,
        direction,
        stub_len,
    });
}

/// Drawing: `line|rect|circle|arc|text|polygon ...`
fn parse_drawing(s: &mut Schematic, line: &str, int: &mut Rodeo, w: &mut Warnings) {
    let mut tok = line.split_whitespace();
    let shape = match tok.next() {
        Some(s) => s,
        None => return,
    };

    match shape {
        "text" => parse_text_item(s, line, int, w),
        "polygon" => parse_polygon_item(s, line, w),
        _ => {
            let nums: Vec<i32> = tok.filter_map(|v| v.parse().ok()).collect();
            match shape {
                "line" if nums.len() >= 4 => {
                    s.lines.push(Line {
                        x0: nums[0],
                        y0: nums[1],
                        x1: nums[2],
                        y1: nums[3],
                        color: Color::NONE,
                        thickness: 0,
                    });
                }
                "rect" if nums.len() >= 4 => {
                    s.rects.push(Rect {
                        x: nums[0],
                        y: nums[1],
                        width: nums[2] - nums[0],
                        height: nums[3] - nums[1],
                        fill: Color::NONE,
                        stroke: Color::NONE,
                        thickness: 0,
                    });
                }
                "circle" if nums.len() >= 3 => {
                    s.circles.push(Circle {
                        cx: nums[0],
                        cy: nums[1],
                        radius: nums[2],
                        fill: Color::NONE,
                        stroke: Color::NONE,
                        thickness: 0,
                    });
                }
                "arc" if nums.len() >= 5 => {
                    s.arcs.push(Arc {
                        cx: nums[0],
                        cy: nums[1],
                        radius: nums[2],
                        start_angle: nums[3] as f32,
                        sweep_angle: nums[4] as f32,
                        stroke: Color::NONE,
                        thickness: 0,
                    });
                }
                "line" | "rect" | "circle" | "arc" => {
                    w.warn(format!("{shape} needs more coordinates, skipped"));
                }
                other => {
                    w.warn(format!("unknown drawing shape '{other}', skipped"));
                }
            }
        }
    }
}

/// Text: `text x y font_size rotation "content" [color=#RRGGBB]`
fn parse_text_item(s: &mut Schematic, line: &str, int: &mut Rodeo, w: &mut Warnings) {
    let rest = match line.strip_prefix("text ") {
        Some(r) => r.trim_start(),
        None => return,
    };

    let mut tok = rest.split_whitespace();
    let x: i32 = w.req_num("text x", tok.next(), 0);
    let y: i32 = w.req_num("text y", tok.next(), 0);
    let font_size_i: i32 = w.opt_num("text font size", tok.next(), 12);
    let rotation: u8 = w.opt_num("text rotation", tok.next(), 0);

    // Extract quoted content from the rest of the line
    let after_rotation = rest
        .splitn(5, char::is_whitespace)
        .nth(4)
        .unwrap_or("")
        .trim_start();

    let (content, trailing) = if let Some(after_quote) = after_rotation.strip_prefix('"') {
        // Find the closing quote
        if let Some(end) = after_quote.find('"') {
            (&after_quote[..end], &after_quote[end + 1..])
        } else {
            // No closing quote -- take everything
            (after_quote, "")
        }
    } else {
        // No quotes -- take the next token
        let end = after_rotation
            .find(char::is_whitespace)
            .unwrap_or(after_rotation.len());
        (&after_rotation[..end], &after_rotation[end..])
    };

    let mut color = Color::NONE;
    for attr in trailing.split_whitespace() {
        if let Some(hex) = attr.strip_prefix("color=#") {
            color = w.hex_color(hex);
        }
    }

    s.texts.push(Text {
        x,
        y,
        content: int.get_or_intern(content),
        font_size: font_size_i as f32,
        color,
        rotation,
    });
}

/// Polygon: `polygon x0,y0 x1,y1 ... [thickness=N] [fill=#RRGGBB] [stroke=#RRGGBB]`
fn parse_polygon_item(s: &mut Schematic, line: &str, w: &mut Warnings) {
    let rest = match line.strip_prefix("polygon ") {
        Some(r) => r.trim_start(),
        None => return,
    };

    let mut points = Vec::new();
    let mut thickness: u8 = 0;
    let mut fill = Color::NONE;
    let mut stroke = Color::NONE;

    for tok in rest.split_whitespace() {
        if let Some(v) = tok.strip_prefix("thickness=") {
            thickness = w.num("polygon thickness", v, 0);
        } else if let Some(hex) = tok.strip_prefix("fill=#") {
            fill = w.hex_color(hex);
        } else if let Some(hex) = tok.strip_prefix("stroke=#") {
            stroke = w.hex_color(hex);
        } else if let Some(comma) = tok.find(',') {
            let xv: i32 = w.num("polygon x", &tok[..comma], 0);
            let yv: i32 = w.num("polygon y", &tok[comma + 1..], 0);
            points.push([xv, yv]);
        }
    }

    if points.len() >= 3 {
        s.polygons.push(Polygon {
            points,
            fill,
            stroke,
            thickness,
        });
    } else if !points.is_empty() {
        w.warn(format!(
            "polygon needs >= 3 points, got {}, skipped",
            points.len()
        ));
    }
}

/// Prefixed property: `key: value` -> stored with prefix in sym_properties
fn parse_prefixed(s: &mut Schematic, prefix: &str, line: &str, int: &mut Rodeo) {
    let sep = if line.contains(": ") { ": " } else { ":" };
    let Some(idx) = line.find(sep) else { return };
    let key = line[..idx].trim();
    let val = line[idx + sep.len()..].trim();
    if key.is_empty() {
        return;
    }
    let full_key = format!("{prefix}{key}");
    s.sym_properties.push(Property {
        key: int.get_or_intern(&full_key),
        value: int.get_or_intern(val),
    });
}

/// Plugin entry: `key: value` or `key: |` (start multiline)
fn parse_plugin_entry(
    s: &mut Schematic,
    line: &str,
    pml: &mut PluginMLState,
    section: &mut Section,
    int: &mut Rodeo,
) {
    let Some(colon) = line.find(':') else { return };
    let key = line[..colon].trim();
    let val = line[colon + 1..].trim();

    let plugin_idx = s.plugin_blocks.len().saturating_sub(1);

    if val == "|" {
        // Start multiline
        pml.plugin_idx = plugin_idx;
        pml.key = key.to_string();
        pml.lines.clear();
        *section = Section::PluginMultiline;
        return;
    }

    if let Some(block) = s.plugin_blocks.get_mut(plugin_idx) {
        block.entries.push(Property {
            key: int.get_or_intern(key),
            value: int.get_or_intern(val),
        });
    }
}

// ── Generate block expansion ────────────────────────────────────────────────

fn parse_generate_header(line: &str) -> Option<GenState> {
    // `generate i: range 0..3`
    let rest = line.strip_prefix("generate ")?.trim();
    let colon = rest.find(':')?;
    let var_name = rest[..colon].trim().to_string();
    let range_part = rest[colon + 1..].trim().strip_prefix("range ")?.trim();
    let dots = range_part.find("..")?;
    let start: i32 = range_part[..dots].trim().parse().ok()?;
    let end: i32 = range_part[dots + 2..].trim().parse().ok()?;
    Some(GenState {
        var_name,
        range_start: start,
        range_end: end,
        lines: Vec::new(),
    })
}

fn expand_generate(s: &mut Schematic, gen: &GenState, int: &mut Rodeo, w: &mut Warnings) {
    let placeholder = format!("{{{}}}", gen.var_name);
    for i in gen.range_start..=gen.range_end {
        let i_str = i.to_string();
        for line in &gen.lines {
            let expanded = line.replace(&placeholder, &i_str);
            let trimmed = expanded.trim();
            // Route expanded lines through the instance parser
            if trimmed.contains(" x=") || trimmed.contains(" y=") {
                parse_instance(s, trimmed, int, w);
            }
        }
    }
}

// ── Type table header parser ────────────────────────────────────────────────

fn parse_type_table_header(line: &str) -> Option<TypeTableState> {
    // `nmos4 [5] {name x y rot flip W L}:`
    let open_brace = line.find('{')?;
    let close_brace = line.find('}')?;
    let symbol = line[..open_brace].trim();
    // Strip optional count: `nmos4 [5]` -> `nmos4`
    let symbol = symbol.split('[').next()?.trim();
    let cols_str = &line[open_brace + 1..close_brace];
    let columns: Vec<String> = cols_str.split_whitespace().map(String::from).collect();
    if columns.is_empty() {
        return None;
    }
    Some(TypeTableState {
        kind: symbol_to_kind(symbol),
        symbol: symbol.to_string(),
        columns,
    })
}

fn flush_plugin_ml(s: &mut Schematic, pml: &mut PluginMLState, int: &mut Rodeo) {
    let joined = pml.lines.join("\n");
    if let Some(block) = s.plugin_blocks.get_mut(pml.plugin_idx) {
        block.entries.push(Property {
            key: int.get_or_intern(&pml.key),
            value: int.get_or_intern(&joined),
        });
    }
    pml.lines.clear();
}

// ── Reader helpers ──────────────────────────────────────────────────────────

/// Extract the version number from a header line like "chn 2" or "chn_prim 1".
fn parse_header_version(line: &str) -> u8 {
    line.split_whitespace()
        .last()
        .and_then(|v| v.parse().ok())
        .unwrap_or(1)
}

fn indent_level(line: &str) -> usize {
    let spaces = line.len() - line.trim_start().len();
    spaces / 2
}

fn strip_comment(line: &str) -> &str {
    for (i, c) in line.char_indices() {
        if c == '#' && (i == 0 || line.as_bytes()[i - 1] == b' ' || line.as_bytes()[i - 1] == b'\t')
        {
            return line[..i].trim_end();
        }
    }
    line
}

fn accumulate(buf: &mut String, content: &str) {
    if !buf.is_empty() {
        buf.push('\n');
    }
    buf.push_str(content);
}

fn split_kv_attrs(s: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut current = String::new();
    let mut in_quote = false;
    for ch in s.chars() {
        if ch == '"' {
            in_quote = !in_quote;
            current.push(ch);
        } else if ch.is_whitespace() && !in_quote {
            if !current.is_empty() {
                result.push(std::mem::take(&mut current));
            }
        } else {
            current.push(ch);
        }
    }
    if !current.is_empty() {
        result.push(current);
    }
    result
}

fn symbol_to_kind(name: &str) -> DeviceKind {
    match DeviceKind::from_name(name) {
        // Not a built-in name: runtime-registered symbols (project prims /
        // project subcircuits) carry their own kind.
        DeviceKind::Unknown => find_by_name(name)
            .map(|p| p.kind)
            .unwrap_or(DeviceKind::Unknown),
        k => k,
    }
}

// ====================================================
// .chn Writer (sections mirror the reader exactly)
// ====================================================

/// File format version written by this build.
const CHN_VERSION: u8 = 2;

/// Serialize a Schematic to CHN format.
/// Returns None on write error (should not happen with String buffer).
pub fn write_chn(sch: &Schematic, int: &Rodeo) -> Option<String> {
    let mut buf = String::with_capacity(4096);
    write_chn_impl(&mut buf, sch, int).ok()?;
    Some(buf)
}

fn write_chn_impl(w: &mut String, s: &Schematic, int: &Rodeo) -> std::fmt::Result {
    // Header
    match s.stype {
        SchematicType::Primitive => writeln!(w, "chn_prim {CHN_VERSION}")?,
        SchematicType::Testbench => writeln!(w, "chn_testbench {CHN_VERSION}")?,
        _ => writeln!(w, "chn {CHN_VERSION}")?,
    }

    // Top-level declaration
    match s.stype {
        SchematicType::Symbol | SchematicType::Primitive => {
            let name = if s.name.is_empty() {
                "untitled"
            } else {
                &s.name
            };
            writeln!(w, "\nSYMBOL {name}")?;
            write_sym_metadata(w, s, int)?;
        }
        SchematicType::Testbench => {
            let name = if s.name.is_empty() {
                "untitled"
            } else {
                &s.name
            };
            writeln!(w, "\nTESTBENCH {name}")?;
            write_testbench_metadata(w, s)?;
        }
        SchematicType::Schematic => {
            writeln!(w, "\nSCHEMATIC")?;
        }
    }

    write_pins(w, s, int)?;
    write_params(w, s, int)?;
    write_instances(w, s, int)?;
    write_wires(w, s, int)?;
    write_buses(w, s, int)?;
    write_bus_rippers(w, s)?;
    write_drawing(w, s, int)?;
    write_code_block(w, s)?;
    write_plugin_blocks(w, s, int)?;
    write_pyspice(w, s)?;
    write_documentation(w, s)?;

    Ok(())
}

fn write_sym_metadata(w: &mut String, s: &Schematic, int: &Rodeo) -> std::fmt::Result {
    for prop in &s.sym_properties {
        let key = int.resolve(&prop.key);
        let val = int.resolve(&prop.value);
        if key == "description" {
            writeln!(w, "  desc: {val}")?;
        } else if key == "type" {
            writeln!(w, "  type: {val}")?;
        }
    }
    Ok(())
}

fn write_testbench_metadata(w: &mut String, s: &Schematic) -> std::fmt::Result {
    if s.stimulus_lang != StimulusLang::default() {
        writeln!(w, "  stimulus_lang: {}", s.stimulus_lang.as_str())?;
    }
    if s.sim_backend != SpiceBackend::default() {
        writeln!(w, "  sim_backend: {}", s.sim_backend.as_str())?;
    }
    if !s.sim_corner.is_empty() {
        writeln!(w, "  sim_corner: {}", s.sim_corner)?;
    }
    Ok(())
}

fn write_pins(w: &mut String, s: &Schematic, int: &Rodeo) -> std::fmt::Result {
    if s.pins.is_empty() {
        return Ok(());
    }
    writeln!(w, "  pins:")?;
    for pin in &s.pins {
        let name = int.resolve(&pin.name);
        let dir = pin_dir_str(pin.direction);
        write!(w, "    {name}  {dir}")?;
        if pin.x != 0 || pin.y != 0 {
            write!(w, "  x={}  y={}", pin.x, pin.y)?;
        }
        if pin.width > 1 {
            write!(w, "  width={}", pin.width)?;
        }
        writeln!(w)?;
    }
    Ok(())
}

fn write_params(w: &mut String, s: &Schematic, int: &Rodeo) -> std::fmt::Result {
    let params: Vec<_> = s
        .sym_properties
        .iter()
        .filter(|p| !is_metadata(int.resolve(&p.key)))
        .collect();
    if params.is_empty() {
        return Ok(());
    }
    writeln!(w, "  params:")?;
    for p in params {
        let key = int.resolve(&p.key);
        let val = int.resolve(&p.value);
        writeln!(w, "    {key} = {val}")?;
    }
    Ok(())
}

fn write_instances(w: &mut String, s: &Schematic, int: &Rodeo) -> std::fmt::Result {
    if s.instances.is_empty() {
        return Ok(());
    }
    writeln!(w, "  instances:")?;

    for i in 0..s.instances.len() {
        let name = int.resolve(&s.instances.name[i]);
        let kind = s.instances.kind[i];
        let x = s.instances.x[i];
        let y = s.instances.y[i];
        let flags = s.instances.flags[i];
        let symbol = int.resolve(&s.instances.symbol[i]);
        let ps = s.instances.prop_start[i] as usize;
        let pc = s.instances.prop_count[i] as usize;

        let kind_name = kind_to_name(kind, symbol);
        write!(w, "    {name}  {kind_name}  x={x}  y={y}")?;

        let rot = flags.rotation();
        if rot != 0 {
            write!(w, "  rot={rot}")?;
        }
        if flags.flip() {
            write!(w, "  flip=1")?;
        }
        // Symbol override if kind_name differs
        if kind_name != symbol && !symbol.is_empty() {
            write!(w, "  sym={symbol}")?;
        }

        // Properties
        if pc > 0 {
            let props = &s.properties[ps..ps + pc];
            let non_structural: Vec<_> = props
                .iter()
                .filter(|p| !is_structural(int.resolve(&p.key)))
                .collect();
            if non_structural.len() > 3 {
                write!(w, "  .parameters{{ ")?;
                for (j, p) in non_structural.iter().enumerate() {
                    if j > 0 {
                        write!(w, "  ")?;
                    }
                    let k = int.resolve(&p.key);
                    let v = int.resolve(&p.value);
                    write!(w, "{k}={v}")?;
                }
                write!(w, " }}")?;
            } else {
                for p in &non_structural {
                    let k = int.resolve(&p.key);
                    let v = int.resolve(&p.value);
                    if v.contains(' ') || v.contains('(') {
                        write!(w, "  {k}=\"{v}\"")?;
                    } else {
                        write!(w, "  {k}={v}")?;
                    }
                }
            }
        }
        writeln!(w)?;
    }
    Ok(())
}

fn write_wires(w: &mut String, s: &Schematic, int: &Rodeo) -> std::fmt::Result {
    if s.wires.is_empty() {
        return Ok(());
    }
    writeln!(w, "\n  wires:")?;
    for i in 0..s.wires.len() {
        let x0 = s.wires.x0[i];
        let y0 = s.wires.y0[i];
        let x1 = s.wires.x1[i];
        let y1 = s.wires.y1[i];

        // Skip zero-length
        if x0 == x1 && y0 == y1 {
            continue;
        }

        write!(w, "    {x0} {y0} {x1} {y1}")?;

        if let Some(sym) = s.wires.net_name[i] {
            let net_name = int.resolve(&sym);
            if !net_name.is_empty() {
                write!(w, " {net_name}")?;
            }
        }

        let color = s.wires.color[i];
        if !color.is_none() {
            write!(w, " color=#{:02X}{:02X}{:02X}", color.r, color.g, color.b)?;
        }
        writeln!(w)?;
    }
    Ok(())
}

fn write_buses(w: &mut String, s: &Schematic, int: &Rodeo) -> std::fmt::Result {
    if s.buses.is_empty() {
        return Ok(());
    }
    writeln!(w, "  buses:")?;
    for i in 0..s.buses.len() {
        let label = int.resolve(&s.buses.label[i]);
        let width = s.buses.width[i];
        let start_bit = s.buses.start_bit[i];
        let x0 = s.buses.x0[i];
        let y0 = s.buses.y0[i];
        let x1 = s.buses.x1[i];
        let y1 = s.buses.y1[i];

        write!(w, "    {label} {width} {start_bit} {x0} {y0} {x1} {y1}")?;

        let color = s.buses.color[i];
        if !color.is_none() {
            write!(w, " color=#{:02X}{:02X}{:02X}", color.r, color.g, color.b)?;
        }
        writeln!(w)?;
    }
    Ok(())
}

fn write_bus_rippers(w: &mut String, s: &Schematic) -> std::fmt::Result {
    if s.bus_rippers.is_empty() {
        return Ok(());
    }
    writeln!(w, "  bus_rippers:")?;
    for r in &s.bus_rippers {
        writeln!(
            w,
            "    {} {} {} {} dir={} stub={}",
            r.bus_idx, r.bit, r.x, r.y, r.direction, r.stub_len
        )?;
    }
    Ok(())
}

fn write_drawing(w: &mut String, s: &Schematic, int: &Rodeo) -> std::fmt::Result {
    let has_any = !s.lines.is_empty()
        || !s.rects.is_empty()
        || !s.circles.is_empty()
        || !s.arcs.is_empty()
        || !s.texts.is_empty()
        || !s.polygons.is_empty();
    if !has_any {
        return Ok(());
    }
    writeln!(w, "  drawing:")?;
    for l in &s.lines {
        writeln!(w, "    line {} {} {} {}", l.x0, l.y0, l.x1, l.y1)?;
    }
    for r in &s.rects {
        writeln!(
            w,
            "    rect {} {} {} {}",
            r.x,
            r.y,
            r.x + r.width,
            r.y + r.height
        )?;
    }
    for c in &s.circles {
        writeln!(w, "    circle {} {} {}", c.cx, c.cy, c.radius)?;
    }
    for a in &s.arcs {
        writeln!(
            w,
            "    arc {} {} {} {} {}",
            a.cx, a.cy, a.radius, a.start_angle as i32, a.sweep_angle as i32
        )?;
    }
    for t in &s.texts {
        let content = int.resolve(&t.content);
        write!(
            w,
            "    text {} {} {} {} \"{}\"",
            t.x, t.y, t.font_size as i32, t.rotation, content
        )?;
        if !t.color.is_none() {
            write!(
                w,
                " color=#{:02X}{:02X}{:02X}",
                t.color.r, t.color.g, t.color.b
            )?;
        }
        writeln!(w)?;
    }
    for p in &s.polygons {
        write!(w, "    polygon")?;
        for pt in &p.points {
            write!(w, " {},{}", pt[0], pt[1])?;
        }
        if p.thickness > 0 {
            write!(w, " thickness={}", p.thickness)?;
        }
        if !p.fill.is_none() {
            write!(w, " fill=#{:02X}{:02X}{:02X}", p.fill.r, p.fill.g, p.fill.b)?;
        }
        if !p.stroke.is_none() {
            write!(
                w,
                " stroke=#{:02X}{:02X}{:02X}",
                p.stroke.r, p.stroke.g, p.stroke.b
            )?;
        }
        writeln!(w)?;
    }
    Ok(())
}

fn write_code_block(w: &mut String, s: &Schematic) -> std::fmt::Result {
    if s.spice_body.is_empty() {
        return Ok(());
    }
    writeln!(w, "  code:")?;
    for line in s.spice_body.lines() {
        writeln!(w, "    {line}")?;
    }
    Ok(())
}

fn write_plugin_blocks(w: &mut String, s: &Schematic, int: &Rodeo) -> std::fmt::Result {
    for pb in &s.plugin_blocks {
        let name = int.resolve(&pb.name);
        writeln!(w, "\nPLUGIN {name}")?;
        for e in &pb.entries {
            let key = int.resolve(&e.key);
            let val = int.resolve(&e.value);
            if val.contains('\n') {
                writeln!(w, "  {key}: |")?;
                for line in val.lines() {
                    writeln!(w, "    {line}")?;
                }
            } else {
                writeln!(w, "  {key}: {val}")?;
            }
        }
    }
    Ok(())
}

fn write_pyspice(w: &mut String, s: &Schematic) -> std::fmt::Result {
    if s.pyspice_source.is_empty() {
        return Ok(());
    }
    writeln!(w, "\nPYSPICE")?;
    for line in s.pyspice_source.lines() {
        writeln!(w, "  {line}")?;
    }
    Ok(())
}

fn write_documentation(w: &mut String, s: &Schematic) -> std::fmt::Result {
    if s.documentation.is_empty() {
        return Ok(());
    }
    writeln!(w, "\nDOCUMENTATION")?;
    for line in s.documentation.lines() {
        writeln!(w, "  {line}")?;
    }
    Ok(())
}

// ── Writer helpers ──────────────────────────────────────────────────────────

fn pin_dir_str(dir: PinDirection) -> &'static str {
    match dir {
        PinDirection::Input => "in",
        PinDirection::Output => "out",
        PinDirection::InOut => "inout",
        PinDirection::Power => "power",
        PinDirection::Ground => "ground",
    }
}

fn kind_to_name(kind: DeviceKind, symbol: &str) -> &str {
    // Preserve the specific symbol name (nmos3, nmos4, ...) if already set;
    // otherwise fall back to the canonical symbol name.
    if symbol.is_empty() {
        kind.symbol_name()
    } else {
        symbol
    }
}

fn is_metadata(key: &str) -> bool {
    matches!(
        key,
        "description" | "type" | "spice_body" | "include" | "spice_prefix"
    ) || key.starts_with("ann.")
        || key.starts_with("analysis.")
        || key.starts_with("measure.")
}

fn is_structural(key: &str) -> bool {
    matches!(key, "x" | "y" | "rot" | "flip" | "sym" | "name")
}

// ====================================================
// Tests
// ====================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_kind_from_name() {
        assert_eq!(DeviceKind::from_name("resistor"), DeviceKind::Resistor);
        assert_eq!(DeviceKind::from_name("res"), DeviceKind::Resistor);
        assert_eq!(DeviceKind::from_name("nmos"), DeviceKind::Nmos4);
        assert_eq!(DeviceKind::from_name("nmos4"), DeviceKind::Nmos4);
        assert_eq!(DeviceKind::from_name("spice_block"), DeviceKind::Subckt);
        assert_eq!(DeviceKind::from_name("verilog_a_block"), DeviceKind::Hdl);
        assert_eq!(DeviceKind::from_name("no_such_device"), DeviceKind::Unknown);
        // round-trip: every kind's symbol_name parses back to a kind with the
        // same SPICE prefix (symbol_name collapses MOSFET variants).
        assert_eq!(
            DeviceKind::from_name(DeviceKind::Capacitor.symbol_name()),
            DeviceKind::Capacitor
        );
        assert_eq!(DeviceKind::Nmos4.prefix(), b'M');
        assert_eq!(DeviceKind::Subckt.prefix(), b'X');
        assert_eq!(DeviceKind::Nmos4.default_pins(), ["d", "g", "s", "b"]);
        assert_eq!(DeviceKind::Nmos4.model_keyword(), Some("nch"));
    }

    #[test]
    fn primitives_load_count() {
        assert_eq!(prim_count(), 36);
        for p in PRIMITIVES.iter() {
            assert!(!p.kind_name.is_empty(), "prim missing kind_name");
            assert!(p.has_drawing(), "{} has no drawing", p.kind_name);
        }
        let nmos = find_by_name("nmos4").expect("nmos4 not found");
        assert_eq!(nmos.prefix, b'M');
        assert_eq!(nmos.pins, ["d", "g", "s", "b"]);
        assert_eq!(nmos.model_keyword, Some("nch"));
        let g = find_by_name("gnd").expect("gnd not found");
        assert!(g.non_electrical);
        assert_eq!(g.injected_net, Some("0"));
    }

    #[test]
    fn chn_round_trip() {
        let mut int = Rodeo::default();
        let mut sch = Schematic {
            stype: SchematicType::Schematic,
            ..Default::default()
        };

        // Instance with properties
        let prop_start = sch.properties.len() as u32;
        sch.properties.push(Property {
            key: int.get_or_intern("W"),
            value: int.get_or_intern("1u"),
        });
        sch.properties.push(Property {
            key: int.get_or_intern("L"),
            value: int.get_or_intern("150n"),
        });
        sch.instances.push(Instance {
            name: int.get_or_intern("M1"),
            symbol: int.get_or_intern("nmos4"),
            spice_line: int.get_or_intern(""),
            x: 100,
            y: -40,
            kind: DeviceKind::Nmos4,
            flags: InstanceFlags::new(1, true),
            prop_start,
            prop_count: 2,
            name_offset: [0, 0],
            param_offset: [0, 0],
        });

        // Named + colored wire, plain wire
        sch.wires.push(Wire {
            net_name: Some(int.get_or_intern("vout")),
            x0: 0,
            y0: 0,
            x1: 100,
            y1: 0,
            color: Color::rgb(255, 0, 128),
            thickness: 0,
        });
        sch.wires.push(Wire {
            net_name: None,
            x0: 100,
            y0: 0,
            x1: 100,
            y1: -40,
            color: Color::NONE,
            thickness: 0,
        });

        // Bus + ripper
        sch.buses.push(Bus {
            label: int.get_or_intern("data"),
            width: 8,
            start_bit: 0,
            x0: 10,
            y0: 20,
            x1: 200,
            y1: 20,
            color: Color::rgb(0, 0, 255),
            thickness: 0,
        });
        sch.bus_rippers.push(BusRipper {
            bus_idx: 0,
            bit: 3,
            x: 50,
            y: 20,
            direction: 1,
            stub_len: 15,
        });

        // Drawing items
        sch.lines.push(Line {
            x0: 0,
            y0: 0,
            x1: 10,
            y1: 10,
            color: Color::NONE,
            thickness: 0,
        });
        sch.texts.push(Text {
            x: 5,
            y: -3,
            content: int.get_or_intern("Hello World"),
            font_size: 14.0,
            color: Color::rgb(1, 2, 3),
            rotation: 1,
        });
        sch.polygons.push(Polygon {
            points: vec![[0, 0], [10, 0], [10, 10]],
            fill: Color::rgb(100, 200, 50),
            stroke: Color::rgb(0, 0, 0),
            thickness: 3,
        });

        sch.spice_body = ".tran 1n 1u\n.ic v(vout)=0".to_string();

        let chn = write_chn(&sch, &int).expect("write_chn failed");

        let mut int2 = Rodeo::default();
        let (sch2, warnings) = read_chn_report(&chn, &mut int2);
        assert!(warnings.is_empty(), "round-trip warnings: {warnings:?}");

        // Instance
        assert_eq!(sch2.instances.len(), 1);
        assert_eq!(int2.resolve(&sch2.instances.name[0]), "M1");
        assert_eq!(int2.resolve(&sch2.instances.symbol[0]), "nmos4");
        assert_eq!(sch2.instances.kind[0], DeviceKind::Nmos4);
        assert_eq!(sch2.instances.x[0], 100);
        assert_eq!(sch2.instances.y[0], -40);
        assert_eq!(sch2.instances.flags[0].rotation(), 1);
        assert!(sch2.instances.flags[0].flip());
        let props = sch2.instance_props(0);
        assert_eq!(props.len(), 2);
        assert_eq!(int2.resolve(&props[0].key), "W");
        assert_eq!(int2.resolve(&props[0].value), "1u");

        // Wires
        assert_eq!(sch2.wires.len(), 2);
        assert_eq!(
            sch2.wires.net_name[0].map(|s| int2.resolve(&s)),
            Some("vout")
        );
        assert_eq!(sch2.wires.color[0], Color::rgb(255, 0, 128));
        assert_eq!(sch2.wires.net_name[1], None);
        assert_eq!(
            (
                sch2.wires.x0[1],
                sch2.wires.y0[1],
                sch2.wires.x1[1],
                sch2.wires.y1[1]
            ),
            (100, 0, 100, -40)
        );

        // Bus + ripper
        assert_eq!(sch2.buses.len(), 1);
        assert_eq!(int2.resolve(&sch2.buses.label[0]), "data");
        assert_eq!(sch2.buses.width[0], 8);
        assert_eq!(sch2.buses.color[0], Color::rgb(0, 0, 255));
        assert_eq!(sch2.bus_rippers.len(), 1);
        assert_eq!(sch2.bus_rippers[0].bit, 3);
        assert_eq!(sch2.bus_rippers[0].stub_len, 15);

        // Drawing
        assert_eq!(sch2.lines.len(), 1);
        assert_eq!(sch2.texts.len(), 1);
        assert_eq!(int2.resolve(&sch2.texts[0].content), "Hello World");
        assert_eq!(sch2.texts[0].color, Color::rgb(1, 2, 3));
        assert_eq!(sch2.polygons.len(), 1);
        assert_eq!(sch2.polygons[0].points, vec![[0, 0], [10, 0], [10, 10]]);
        assert_eq!(sch2.polygons[0].thickness, 3);

        // Code block
        assert_eq!(sch2.spice_body, ".tran 1n 1u\n.ic v(vout)=0");

        // Second pass is a fixpoint: write(read(x)) == x.
        let chn2 = write_chn(&sch2, &int2).expect("second write failed");
        assert_eq!(chn, chn2, "writer is not a fixpoint of the reader");
    }

    #[test]
    fn reader_degrades_gracefully() {
        let input = "chn 3\n\nSCHEMATIC\n  future_stuff:\n    foo bar\n  wires:\n    0 0 bad 10\n    0 0 10 10\n";
        let mut int = Rodeo::default();
        let (sch, warnings) = read_chn_report(input, &mut int);
        // Unknown section skipped, malformed coordinate defaulted — both warned.
        assert!(warnings.iter().any(|w| w.msg.contains("unknown section")));
        assert!(warnings.iter().any(|w| w.msg.contains("invalid wire x1")));
        assert_eq!(sch.wires.len(), 2); // bad wire kept with defaulted coord
    }

    #[test]
    fn testbench_metadata_round_trip() {
        let int = Rodeo::default();
        let sch = Schematic {
            stype: SchematicType::Testbench,
            name: "tb_amp".to_string(),
            stimulus_lang: StimulusLang::Xyce,
            sim_backend: SpiceBackend::Xyce,
            sim_corner: "ss".to_string(),
            ..Default::default()
        };
        let chn = write_chn(&sch, &int).expect("write failed");
        let mut int2 = Rodeo::default();
        let sch2 = read_chn(&chn, &mut int2);
        assert_eq!(sch2.stype, SchematicType::Testbench);
        assert_eq!(sch2.name, "tb_amp");
        assert_eq!(sch2.stimulus_lang, StimulusLang::Xyce);
        assert_eq!(sch2.sim_backend, SpiceBackend::Xyce);
        assert_eq!(sch2.sim_corner, "ss");
    }
}
