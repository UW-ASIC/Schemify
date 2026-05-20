use soa_derive::StructOfArray;

use crate::types::*;

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
// ~26 bytes per wire, positions iterable without touching color/bus
// ====================================================

#[derive(Debug, Clone, StructOfArray)]
#[soa_derive(Debug, Clone, Default)]
pub struct Wire {
    pub net_name: Sym,
    pub x0: i32,
    pub y0: i32,
    pub x1: i32,
    pub y1: i32,
    /// Color::NONE = use theme default
    pub color: Color,
    /// Thickness in tenths (20 = 2.0x)
    pub thickness: u8,
    pub bus: bool,
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
