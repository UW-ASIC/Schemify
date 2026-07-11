//! Embedded `.chn_prim` primitive table: symbol drawings + pin positions,
//! plus the runtime-registered primitive extension point.

use std::sync::{LazyLock, RwLock};

use crate::*;

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
        ep(include_str!("../primitives/resistor.chn_prim")),
        ep(include_str!("../primitives/resistor3.chn_prim")),
        ep(include_str!("../primitives/capacitor.chn_prim")),
        ep(include_str!("../primitives/inductor.chn_prim")),
        // Diodes
        ep(include_str!("../primitives/diode.chn_prim")),
        ep(include_str!("../primitives/zener.chn_prim")),
        // MOSFETs
        ep(include_str!("../primitives/nmos3.chn_prim")),
        ep(include_str!("../primitives/pmos3.chn_prim")),
        ep_override(include_str!("../primitives/nmos.chn_prim"), "nmos4"),
        ep_override(include_str!("../primitives/pmos.chn_prim"), "pmos4"),
        // BJTs
        ep(include_str!("../primitives/npn.chn_prim")),
        ep(include_str!("../primitives/pnp.chn_prim")),
        // JFETs
        ep(include_str!("../primitives/njfet.chn_prim")),
        ep(include_str!("../primitives/pjfet.chn_prim")),
        // Independent sources
        ep(include_str!("../primitives/vsource.chn_prim")),
        ep(include_str!("../primitives/isource.chn_prim")),
        ep(include_str!("../primitives/ammeter.chn_prim")),
        ep(include_str!("../primitives/behavioral.chn_prim")),
        // Controlled sources
        ep(include_str!("../primitives/vcvs.chn_prim")),
        ep(include_str!("../primitives/vccs.chn_prim")),
        ep(include_str!("../primitives/ccvs.chn_prim")),
        ep(include_str!("../primitives/cccs.chn_prim")),
        // Switches
        ep(include_str!("../primitives/vswitch.chn_prim")),
        ep(include_str!("../primitives/iswitch.chn_prim")),
        // Transmission line / coupling
        ep(include_str!("../primitives/tline.chn_prim")),
        ep(include_str!("../primitives/coupling.chn_prim")),
        // Non-electrical / UI
        ep_special(
            include_str!("../primitives/gnd.chn_prim"),
            true,
            Some("0"),
        ),
        ep_special(
            include_str!("../primitives/vdd.chn_prim"),
            true,
            Some("VDD"),
        ),
        ep_special(
            include_str!("../primitives/lab_pin.chn_prim"),
            true,
            None,
        ),
        ep_special(
            include_str!("../primitives/input_pin.chn_prim"),
            true,
            None,
        ),
        ep_special(
            include_str!("../primitives/output_pin.chn_prim"),
            true,
            None,
        ),
        ep_special(
            include_str!("../primitives/inout_pin.chn_prim"),
            true,
            None,
        ),
        ep_special(
            include_str!("../primitives/probe.chn_prim"),
            true,
            None,
        ),
        // Digital / HDL blocks
        ep(include_str!("../primitives/digital_block.chn_prim")),
        ep(include_str!("../primitives/verilog_a_block.chn_prim")),
        ep(include_str!("../primitives/spice_block.chn_prim")),
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

#[cfg(test)]
mod tests {
    use super::*;

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
}
