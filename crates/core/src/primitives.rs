//! Embedded `.chn_prim` parser — built-in symbol geometry + pin positions.
//!
//! Ports `../Schemify/src/schematic/devices/primitives.zig`.
//! Each `.chn_prim` file is embedded via `include_str!` and parsed once
//! at first access via `LazyLock`.

use std::sync::LazyLock;

use crate::types::DeviceKind;

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

pub static PRIMITIVES: LazyLock<Vec<PrimEntry>> = LazyLock::new(build_table);

pub fn find_by_name(name: &str) -> Option<&'static PrimEntry> {
    PRIMITIVES.iter().find(|p| p.kind_name == name)
}

pub fn find_by_kind(kind: DeviceKind) -> Option<&'static PrimEntry> {
    PRIMITIVES.iter().find(|p| p.kind == kind)
}

pub fn prim_count() -> usize {
    PRIMITIVES.len()
}

// ── Embedded sources ────────────────────────────────────────────────────────

struct EmbeddedPrim {
    src: &'static str,
    kind_override: Option<&'static str>,
    non_electrical: bool,
    injected_net: Option<&'static str>,
}

fn build_table() -> Vec<PrimEntry> {
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
        ep_special(include_str!("../primitives/gnd.chn_prim"), true, Some("0")),
        ep_special(include_str!("../primitives/vdd.chn_prim"), true, Some("VDD")),
        ep_special(include_str!("../primitives/lab_pin.chn_prim"), true, None),
        ep_special(include_str!("../primitives/input_pin.chn_prim"), true, None),
        ep_special(include_str!("../primitives/output_pin.chn_prim"), true, None),
        ep_special(include_str!("../primitives/inout_pin.chn_prim"), true, None),
        ep_special(include_str!("../primitives/probe.chn_prim"), true, None),
        // Digital / HDL blocks
        ep(include_str!("../primitives/digital_block.chn_prim")),
        ep(include_str!("../primitives/verilog_a_block.chn_prim")),
        ep(include_str!("../primitives/spice_block.chn_prim")),
    ];

    embedded.iter().map(|e| parse_prim(e)).collect()
}

fn ep(src: &'static str) -> EmbeddedPrim {
    EmbeddedPrim { src, kind_override: None, non_electrical: false, injected_net: None }
}

fn ep_override(src: &'static str, kind: &'static str) -> EmbeddedPrim {
    EmbeddedPrim { src, kind_override: Some(kind), non_electrical: false, injected_net: None }
}

fn ep_special(
    src: &'static str,
    non_electrical: bool,
    injected_net: Option<&'static str>,
) -> EmbeddedPrim {
    EmbeddedPrim { src, kind_override: None, non_electrical, injected_net }
}

// ── Parser ──────────────────────────────────────────────────────────────────

#[derive(PartialEq)]
enum State {
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

    let mut state = State::Top;

    for raw_line in src.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        // Global keyword transitions
        if line.starts_with("chn_prim") {
            state = State::Top;
            continue;
        }
        if let Some(rest) = line.strip_prefix("SYMBOL ") {
            state = State::Top;
            entry.kind_name = meta.kind_override.unwrap_or(rest.trim());
            continue;
        }
        if line.starts_with("desc:") {
            continue;
        }
        if line.starts_with("pins ") || line.starts_with("pins[") {
            state = State::Pins;
            continue;
        }
        if line.starts_with("params ") || line.starts_with("params[") {
            state = State::Params;
            continue;
        }
        if let Some(rest) = line.strip_prefix("spice_prefix:") {
            state = State::Top;
            let v = rest.trim();
            if let Some(&ch) = v.as_bytes().first() {
                entry.prefix = ch;
            }
            continue;
        }
        if let Some(rest) = line.strip_prefix("spice_format:") {
            state = State::Top;
            entry.spice_format = Some(rest.trim());
            continue;
        }
        if let Some(rest) = line.strip_prefix("block_type:") {
            state = State::Top;
            entry.block_type = rest.trim();
            continue;
        }
        if line.starts_with("spice_lib:") {
            state = State::Top;
            continue;
        }
        if line.starts_with("drawing:") {
            state = State::Drawing;
            continue;
        }

        // Drawing sub-section keywords
        if state == State::Drawing
            || state == State::DrawingLines
            || state == State::DrawingPinPos
        {
            if line.starts_with("lines:") {
                state = State::DrawingLines;
                continue;
            }
            if line.starts_with("pin_positions:") {
                state = State::DrawingPinPos;
                continue;
            }
            if let Some(rest) = line.strip_prefix("circle:") {
                if let Some(c) = parse_circle(rest.trim()) {
                    entry.circles.push(c);
                }
                state = State::Drawing;
                continue;
            }
            if let Some(rest) = line.strip_prefix("arc:") {
                if let Some(a) = parse_arc(rest.trim()) {
                    entry.arcs.push(a);
                }
                state = State::Drawing;
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
                state = State::Drawing;
                continue;
            }
            if let Some(rest) = line.strip_prefix("text:") {
                if let Some(t) = parse_text(rest.trim()) {
                    entry.texts.push(t);
                }
                state = State::Drawing;
                continue;
            }
        }

        // Data item parsing
        match state {
            State::Top | State::Drawing => {}
            State::Pins => {
                let tok = first_token(line);
                if !tok.is_empty() {
                    entry.pins.push(tok);
                }
            }
            State::Params => {
                if let Some(eq) = line.find('=') {
                    let k = line[..eq].trim();
                    let v = line[eq + 1..].trim();
                    if !k.is_empty() {
                        entry.params.push((k, v));
                    }
                }
            }
            State::DrawingLines => {
                if let Some(pts) = parse_two_points(line) {
                    entry.segments.push(DrawSeg {
                        x0: pts[0],
                        y0: pts[1],
                        x1: pts[2],
                        y1: pts[3],
                    });
                }
            }
            State::DrawingPinPos => {
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

    entry.kind = DeviceKind::from_name(entry.kind_name);
    entry
}

// ── Coordinate parsers ──────────────────────────────────────────────────────

fn parse_i16(s: &'static str) -> Option<(i16, &'static str)> {
    let s = s.trim_start();
    if s.is_empty() {
        return None;
    }
    let (neg, s) = if s.starts_with('-') {
        (true, &s[1..])
    } else if s.starts_with('+') {
        (false, &s[1..])
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

fn parse_circle(s: &'static str) -> Option<DrawCircle> {
    let pt = parse_one_point(s)?;
    let r = find_named_i16(s, "r=")?;
    Some(DrawCircle { cx: pt[0], cy: pt[1], r })
}

fn parse_arc(s: &'static str) -> Option<DrawArc> {
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

fn parse_text(s: &'static str) -> Option<DrawText> {
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
    Some(DrawText { x: pt[0], y: pt[1], content })
}

fn first_token(s: &'static str) -> &'static str {
    let end = s
        .bytes()
        .position(|b| b == b' ' || b == b'\t')
        .unwrap_or(s.len());
    &s[..end]
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prim_count_matches() {
        assert_eq!(prim_count(), 36);
    }

    #[test]
    fn nmos4_parsed() {
        let nmos = find_by_name("nmos4").expect("nmos4 not found");
        assert_eq!(nmos.prefix, b'M');
        assert_eq!(nmos.pins.len(), 4);
        assert_eq!(nmos.pins[0], "d");
        assert!(nmos.model_keyword.is_some());
        assert_eq!(nmos.model_keyword.unwrap(), "nch");
    }

    #[test]
    fn resistor_parsed() {
        let r = find_by_name("resistor").expect("resistor not found");
        assert_eq!(r.prefix, b'R');
        assert_eq!(r.pins.len(), 2);
        assert_eq!(r.pins[0], "p");
    }

    #[test]
    fn gnd_non_electrical_with_injected_net() {
        let g = find_by_name("gnd").expect("gnd not found");
        assert!(g.non_electrical);
        assert_eq!(g.injected_net, Some("0"));
    }

    #[test]
    fn resistor_has_drawing() {
        let r = find_by_name("resistor").expect("resistor not found");
        assert!(r.segments.len() >= 7);
        assert!(r.has_drawing());
        assert_eq!(r.pin_positions.len(), 2);
    }

    #[test]
    fn all_prims_have_kind_name() {
        for p in PRIMITIVES.iter() {
            assert!(!p.kind_name.is_empty(), "prim missing kind_name");
        }
    }

    #[test]
    fn all_prims_have_drawing() {
        for p in PRIMITIVES.iter() {
            assert!(p.has_drawing(), "{} has no drawing", p.kind_name);
        }
    }

    #[test]
    fn resistor_texts() {
        let r = find_by_name("resistor").expect("resistor not found");
        assert_eq!(r.texts.len(), 2);
        assert_eq!(r.texts[0].x, 15);
        assert_eq!(r.texts[0].y, 0);
        assert_eq!(r.texts[0].content, "@name");
        assert_eq!(r.texts[1].x, 15);
        assert_eq!(r.texts[1].y, 10);
        assert_eq!(r.texts[1].content, "@r");
    }
}
