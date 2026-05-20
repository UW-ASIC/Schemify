//! XSchem intermediate representation types.
//!
//! These mirror the on-disk format of `.sch` and `.sym` files before
//! conversion into `ImportResult`.

/// A single parsed element from an XSchem `.sch` or `.sym` file.
#[derive(Debug, Clone)]
pub enum XSchemElement {
    /// `v {xschem version=X.Y.Z ...}`
    Version(String),

    /// `C {symbol} x y rotation flip {props}`
    Component {
        symbol: String,
        x: i32,
        y: i32,
        rotation: u8,
        flip: bool,
        props: String,
    },

    /// `N x0 y0 x1 y1 {props}`
    Wire {
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
        props: String,
    },

    /// `T {content} x y rotation flip size ... {props}`
    Text {
        content: String,
        x: i32,
        y: i32,
        rotation: u8,
        flip: bool,
        size: f32,
        props: String,
    },

    /// `L layer x0 y0 x1 y1 ...`
    Line {
        layer: u8,
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
    },

    /// `B layer x0 y0 x1 y1 ...`
    Box {
        layer: u8,
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
    },

    /// `A layer cx cy r start_angle sweep_angle ...`
    Arc {
        layer: u8,
        cx: i32,
        cy: i32,
        r: i32,
        start: f32,
        sweep: f32,
    },

    /// `P layer npins ...` (in .sym files)
    Pin {
        layer: u8,
        x: i32,
        y: i32,
        direction: String,
        props: String,
    },

    /// Global net declaration
    Global(String),

    /// Raw SPICE block content
    Spice(String),
}

/// Parsed XSchem document: version string + ordered elements.
#[derive(Debug, Clone, Default)]
pub struct XSchemDoc {
    pub version: Option<String>,
    pub elements: Vec<XSchemElement>,
    /// Raw metadata blocks (G, K, V, S, E lines) stored for round-trip.
    pub metadata: Vec<(char, String)>,
}
