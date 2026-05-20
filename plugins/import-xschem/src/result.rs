use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportResult {
    pub name: String,
    pub schematic_type: String, // "schematic", "symbol", "testbench", "primitive"
    pub pins: Vec<PinResult>,
    pub instances: Vec<InstanceResult>,
    pub wires: Vec<WireResult>,
    pub properties: Vec<PropertyResult>,
    pub lines: Vec<LineResult>,
    pub rects: Vec<RectResult>,
    pub arcs: Vec<ArcResult>,
    pub circles: Vec<CircleResult>,
    pub texts: Vec<TextResult>,
}

impl Default for ImportResult {
    fn default() -> Self {
        Self {
            name: String::from("imported"),
            schematic_type: String::from("schematic"),
            pins: Vec::new(),
            instances: Vec::new(),
            wires: Vec::new(),
            properties: Vec::new(),
            lines: Vec::new(),
            rects: Vec::new(),
            arcs: Vec::new(),
            circles: Vec::new(),
            texts: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PinResult {
    pub name: String,
    pub x: i32,
    pub y: i32,
    pub direction: String, // "input", "output", "inout", "power", "ground"
    pub width: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstanceResult {
    pub name: String,
    pub symbol: String,
    pub kind: String, // "resistor", "nmos4", etc.
    pub x: i32,
    pub y: i32,
    pub rotation: u8,
    pub flip: bool,
    pub properties: Vec<PropertyResult>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WireResult {
    pub x0: i32,
    pub y0: i32,
    pub x1: i32,
    pub y1: i32,
    pub net_name: String,
    pub bus: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PropertyResult {
    pub key: String,
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LineResult {
    pub x0: i32,
    pub y0: i32,
    pub x1: i32,
    pub y1: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RectResult {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArcResult {
    pub cx: i32,
    pub cy: i32,
    pub radius: i32,
    pub start_angle: f32,
    pub sweep_angle: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CircleResult {
    pub cx: i32,
    pub cy: i32,
    pub radius: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TextResult {
    pub x: i32,
    pub y: i32,
    pub content: String,
    pub font_size: f32,
    pub rotation: u8,
}
