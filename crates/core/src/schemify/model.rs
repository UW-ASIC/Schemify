//! Schematic document model: SoA instance/wire/bus tables, geometry
//! primitives, property pool, connectivity result types.

use std::collections::{HashMap, HashSet};

use soa_derive::StructOfArray;

use super::*;

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
