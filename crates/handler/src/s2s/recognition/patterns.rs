//! Declarative pattern library for analog block recognition.
//!
//! Each function builds a `PatternGraph` describing the topology of an analog
//! building block. The VF2 engine matches these against the circuit IR.
//!
//! Pin index conventions (must match the parser):
//!   MOSFET: 0=Drain, 1=Gate, 2=Source, 3=Bulk
//!   Two-terminal (R, C, L, V, I): 0=Plus(p), 1=Minus(n)

use super::vf2::*;
use crate::s2s::ir::Primitive;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Shorthand for a pattern node with a concrete device type.
fn node(id: u32, device_type: Primitive) -> PatternNode {
    PatternNode {
        id,
        device_type: Some(device_type),
        type_constraint: None,
    }
}

/// Shorthand for a wildcard node (any MOSFET) constrained to be same-type as `ref_node`.
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

fn edge(from_node: u32, from_pin: u32, to_node: u32, to_pin: u32, constraint: EdgeConstraint) -> PatternEdge {
    PatternEdge { from_node, from_pin, to_node, to_pin, constraint }
}

fn same_net(from_node: u32, from_pin: u32, to_node: u32, to_pin: u32) -> PatternEdge {
    edge(from_node, from_pin, to_node, to_pin, EdgeConstraint::SameNet)
}

fn diff_net(from_node: u32, from_pin: u32, to_node: u32, to_pin: u32) -> PatternEdge {
    edge(from_node, from_pin, to_node, to_pin, EdgeConstraint::DifferentNet)
}

// ---------------------------------------------------------------------------
// MOSFET pin indices
// ---------------------------------------------------------------------------

const DRAIN: u32 = 0;
const GATE: u32 = 1;
const SOURCE: u32 = 2;

// Two-terminal pin indices
const PLUS: u32 = 0;
const MINUS: u32 = 1;

// ---------------------------------------------------------------------------
// Pattern definitions
// ---------------------------------------------------------------------------

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
    patterns.sort_by(|a, b| b.node_count().cmp(&a.node_count()));
    patterns
}

/// **1. Differential pair** — 2 same-type MOSFETs.
///
/// Node 0: MOSFET (any type). Node 1: same type as node 0.
/// Constraints:
///   - Source(0) -- Source(1): SameNet (shared tail)
///   - Gate(0) -- Gate(1): DifferentNet
///   - Drain(0) -- Drain(1): DifferentNet
pub fn diff_pair() -> PatternGraph {
    PatternGraph {
        id: PatternId::DiffPair,
        nodes: vec![
            node_any(0),
            node_same_as(1, 0),
        ],
        edges: vec![
            same_net(0, SOURCE, 1, SOURCE),  // shared tail
            diff_net(0, GATE, 1, GATE),      // different inputs
            diff_net(0, DRAIN, 1, DRAIN),    // different outputs
        ],
    }
}

/// **2. Simple current mirror** — 2 same-type MOSFETs.
///
/// Node 0: reference (diode-connected). Node 1: mirror copy.
/// Constraints:
///   - Gate(0) -- Gate(1): SameNet
///   - Source(0) -- Source(1): SameNet
///   - Gate(0) -- Drain(0): SameNet (diode-connected reference)
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
/// Constraints:
///   - Drain(0) -- Source(1): SameNet (bottom drain = top source)
///   - Gate(0) -- Gate(1): DifferentNet (separate bias)
pub fn cascode_stack() -> PatternGraph {
    PatternGraph {
        id: PatternId::CascodeStack,
        nodes: vec![
            node_any(0),        // bottom
            node_same_as(1, 0), // top
        ],
        edges: vec![
            same_net(0, DRAIN, 1, SOURCE),  // stacked
            diff_net(0, GATE, 1, GATE),     // different bias
        ],
    }
}

/// **4. Cascode current mirror** — 4 same-type MOSFETs.
///
/// Nodes 0,1: bottom pair (simple mirror). Nodes 2,3: top pair (simple mirror).
/// Bottom drains connect to top sources.
///
/// Layout:
///   Node 0: bottom-ref (diode), Node 1: bottom-mirror
///   Node 2: top-ref, Node 3: top-mirror
///
/// Constraints:
///   - Bottom mirror: Gate(0)--Gate(1) SameNet, Source(0)--Source(1) SameNet, Gate(0)--Drain(0) SameNet
///   - Top mirror: Gate(2)--Gate(3) SameNet, (top sources from bottom drains)
///   - Stacking: Drain(0)--Source(2) SameNet, Drain(1)--Source(3) SameNet
///   - Top ref diode: Gate(2)--Drain(2) SameNet
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
            same_net(0, GATE, 0, DRAIN),   // bottom-ref diode
            // Top mirror
            same_net(2, GATE, 3, GATE),
            same_net(2, GATE, 2, DRAIN),   // top-ref diode
            // Stacking
            same_net(0, DRAIN, 2, SOURCE),
            same_net(1, DRAIN, 3, SOURCE),
        ],
    }
}

/// **5. Push-pull output stage** — 1 NMOS + 1 PMOS.
///
/// Node 0: any MOSFET. Node 1: complementary type.
/// Constraints:
///   - Gate(0) -- Gate(1): SameNet (common input)
///   - Drain(0) -- Drain(1): SameNet (common output)
pub fn push_pull() -> PatternGraph {
    PatternGraph {
        id: PatternId::PushPull,
        nodes: vec![
            node_any(0),
            node_complementary(1, 0),
        ],
        edges: vec![
            same_net(0, GATE, 1, GATE),   // common input
            same_net(0, DRAIN, 1, DRAIN), // common output
        ],
    }
}

/// **6. Common-source amplifier** — 1 MOSFET + 1 resistor load.
///
/// Node 0: MOSFET. Node 1: Resistor.
/// Constraints:
///   - Drain(0) -- Plus(1): SameNet (output node through load)
pub fn common_source() -> PatternGraph {
    PatternGraph {
        id: PatternId::CommonSource,
        nodes: vec![
            node_any(0),
            node(1, Primitive::Resistor),
        ],
        edges: vec![
            same_net(0, DRAIN, 1, PLUS), // drain tied to resistor
        ],
    }
}

/// **7. Source follower** — 1 MOSFET + 1 current source (Isource).
///
/// Node 0: MOSFET. Node 1: Isource.
/// Constraints:
///   - Source(0) -- Plus(1): SameNet (output taken from source, biased by current source)
pub fn source_follower() -> PatternGraph {
    PatternGraph {
        id: PatternId::SourceFollower,
        nodes: vec![
            node_any(0),
            node(1, Primitive::Isource),
        ],
        edges: vec![
            same_net(0, SOURCE, 1, PLUS), // source to isource
        ],
    }
}

/// **8. RC compensation network** — 1 resistor + 1 capacitor in series.
///
/// Node 0: Resistor. Node 1: Capacitor.
/// Constraints:
///   - Minus(0) -- Plus(1): SameNet (series connection at internal node)
pub fn rc_compensation() -> PatternGraph {
    PatternGraph {
        id: PatternId::RcCompensation,
        nodes: vec![
            node(0, Primitive::Resistor),
            node(1, Primitive::Capacitor),
        ],
        edges: vec![
            same_net(0, MINUS, 1, PLUS), // series connection
        ],
    }
}

/// **9. Wilson current mirror** — 3 same-type MOSFETs.
///
/// Node 0 (M_ref): reference, gate shared with output.
/// Node 1 (M_out): output, source shared with reference.
/// Node 2 (M_fb): feedback, source tied to M_out drain, drain tied to M_ref drain.
///
/// Constraints:
///   - Gate(0) -- Gate(1): SameNet (shared gate bias)
///   - Source(0) -- Source(1): SameNet (shared rail)
///   - Source(2) -- Drain(1): SameNet (feedback: M_fb source = M_out drain)
///   - Drain(2) -- Drain(0): SameNet (feedback: M_fb drain = M_ref drain)
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
/// Node 0 (M_ref): diode-connected reference (gate == drain).
/// Node 1 (M_out): output transistor, gate shared with M_ref.
/// Node 2 (R_deg): degeneration resistor on M_out source.
///
/// Constraints:
///   - Gate(0) -- Drain(0): SameNet (M_ref diode-connected)
///   - Gate(0) -- Gate(1): SameNet (shared gate bias)
///   - Source(1) -- Plus(2): SameNet (M_out source to R degeneration)
///   - Source(0) -- Minus(2): SameNet (R other end to shared rail = M_ref source)
pub fn widlar_mirror() -> PatternGraph {
    PatternGraph {
        id: PatternId::WidlarMirror,
        nodes: vec![
            node_any(0),                       // M_ref
            node_same_as(1, 0),                // M_out
            node(2, Primitive::Resistor),       // R_deg
        ],
        edges: vec![
            same_net(0, GATE, 0, DRAIN),     // M_ref diode-connected
            same_net(0, GATE, 1, GATE),      // shared gate bias
            same_net(1, SOURCE, 2, PLUS),    // M_out source to R degeneration
            same_net(0, SOURCE, 2, MINUS),   // R other end to shared rail
        ],
    }
}

/// **11. Resistor voltage divider** — 2 resistors in series.
///
/// Node 0 (R_top): top resistor.
/// Node 1 (R_bot): bottom resistor.
///
/// Constraints:
///   - Minus(0) -- Plus(1): SameNet (series midpoint)
///   - Plus(0) -- Minus(1): DifferentNet (different end nets)
pub fn resistor_divider() -> PatternGraph {
    PatternGraph {
        id: PatternId::ResistorDivider,
        nodes: vec![
            node(0, Primitive::Resistor),
            node(1, Primitive::Resistor),
        ],
        edges: vec![
            same_net(0, MINUS, 1, PLUS),    // series midpoint
            diff_net(0, PLUS, 1, MINUS),    // different end nets
        ],
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::s2s::ir::*;
    use crate::s2s::recognition::vf2::find_matches;
    use std::collections::HashMap;

    // -- Helpers --

    fn make_mosfet(name: &str, prim: Primitive) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: prim,
            symbol: String::new(),
            pins: vec![
                Pin { name: "D".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "G".into(), dir: PinDir::Input, net_idx: None },
                Pin { name: "S".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "B".into(), dir: PinDir::Bulk, net_idx: None },
            ],
            params: HashMap::new(),
            x: 0, y: 0, rotation: 0, flip: false,
        }
    }

    fn make_nmos(name: &str) -> Instance { make_mosfet(name, Primitive::Nmos) }
    fn make_pmos(name: &str) -> Instance { make_mosfet(name, Primitive::Pmos) }

    fn make_two_terminal(name: &str, prim: Primitive) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: prim,
            symbol: String::new(),
            pins: vec![
                Pin { name: "p".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "n".into(), dir: PinDir::Inout, net_idx: None },
            ],
            params: HashMap::new(),
            x: 0, y: 0, rotation: 0, flip: false,
        }
    }

    fn make_resistor(name: &str) -> Instance { make_two_terminal(name, Primitive::Resistor) }
    fn make_capacitor(name: &str) -> Instance { make_two_terminal(name, Primitive::Capacitor) }
    fn make_isource(name: &str) -> Instance { make_two_terminal(name, Primitive::Isource) }

    fn build_circuit(instances: Vec<Instance>, connections: &[(&str, u32, u32)]) -> Circuit {
        let mut c = Circuit::new("test");
        for inst in instances {
            c.add_instance(inst);
        }
        for &(net_name, inst_idx, pin_idx) in connections {
            let net_idx = c.get_or_create_net(net_name);
            c.connect(net_idx, PinRef { instance_idx: inst_idx, pin_idx });
        }
        c
    }

    // ======================================================================
    // 1. Differential pair
    // ======================================================================

    #[test]
    fn diff_pair_nmos_match() {
        let c = build_circuit(
            vec![make_nmos("M1"), make_nmos("M2")],
            &[
                ("outm", 0, 0), ("inp", 0, 1), ("tail", 0, 2),
                ("outp", 1, 0), ("inn", 1, 1), ("tail", 1, 2),
            ],
        );
        let matches = find_matches(&diff_pair(), &c.top);
        assert!(!matches.is_empty(), "NMOS diff pair should match");
    }

    #[test]
    fn diff_pair_pmos_match() {
        let c = build_circuit(
            vec![make_pmos("M1"), make_pmos("M2")],
            &[
                ("outm", 0, 0), ("inp", 0, 1), ("tail", 0, 2),
                ("outp", 1, 0), ("inn", 1, 1), ("tail", 1, 2),
            ],
        );
        let matches = find_matches(&diff_pair(), &c.top);
        assert!(!matches.is_empty(), "PMOS diff pair should match");
    }

    #[test]
    fn diff_pair_no_match_shared_gate() {
        let c = build_circuit(
            vec![make_nmos("M1"), make_nmos("M2")],
            &[
                ("outm", 0, 0), ("vin", 0, 1), ("tail", 0, 2),
                ("outp", 1, 0), ("vin", 1, 1), ("tail", 1, 2),
            ],
        );
        let matches = find_matches(&diff_pair(), &c.top);
        assert!(matches.is_empty(), "Shared gate should not match diff pair");
    }

    // ======================================================================
    // 2. Current mirror
    // ======================================================================

    #[test]
    fn current_mirror_nmos_match() {
        let c = build_circuit(
            vec![make_nmos("M1"), make_nmos("M2")],
            &[
                ("bias", 0, 0), ("bias", 0, 1), ("vss", 0, 2), // M1 diode
                ("out",  1, 0), ("bias", 1, 1), ("vss", 1, 2),
            ],
        );
        let matches = find_matches(&current_mirror(), &c.top);
        assert!(!matches.is_empty(), "NMOS current mirror should match");
    }

    #[test]
    fn current_mirror_pmos_match() {
        let c = build_circuit(
            vec![make_pmos("M1"), make_pmos("M2")],
            &[
                ("bias", 0, 0), ("bias", 0, 1), ("vdd", 0, 2),
                ("out",  1, 0), ("bias", 1, 1), ("vdd", 1, 2),
            ],
        );
        let matches = find_matches(&current_mirror(), &c.top);
        assert!(!matches.is_empty(), "PMOS current mirror should match");
    }

    #[test]
    fn current_mirror_no_match_no_diode() {
        // No diode connection: gate != drain on both
        let c = build_circuit(
            vec![make_nmos("M1"), make_nmos("M2")],
            &[
                ("d1", 0, 0), ("bias", 0, 1), ("vss", 0, 2),
                ("d2", 1, 0), ("bias", 1, 1), ("vss", 1, 2),
            ],
        );
        let matches = find_matches(&current_mirror(), &c.top);
        assert!(matches.is_empty(), "No diode should not match current mirror");
    }

    // ======================================================================
    // 3. Cascode stack
    // ======================================================================

    #[test]
    fn cascode_stack_nmos_match() {
        let c = build_circuit(
            vec![make_nmos("M1"), make_nmos("M2")],
            &[
                ("mid", 0, 0), ("vb1", 0, 1), ("vss", 0, 2),
                ("out", 1, 0), ("vb2", 1, 1), ("mid", 1, 2),
            ],
        );
        let matches = find_matches(&cascode_stack(), &c.top);
        assert!(!matches.is_empty(), "NMOS cascode stack should match");
    }

    #[test]
    fn cascode_stack_pmos_match() {
        let c = build_circuit(
            vec![make_pmos("M1"), make_pmos("M2")],
            &[
                ("mid", 0, 0), ("vb1", 0, 1), ("vdd", 0, 2),
                ("out", 1, 0), ("vb2", 1, 1), ("mid", 1, 2),
            ],
        );
        let matches = find_matches(&cascode_stack(), &c.top);
        assert!(!matches.is_empty(), "PMOS cascode stack should match");
    }

    #[test]
    fn cascode_stack_no_match_same_gate() {
        // Same gate net -> this is more like a mirror-cascode, not a simple cascode
        let c = build_circuit(
            vec![make_nmos("M1"), make_nmos("M2")],
            &[
                ("mid", 0, 0), ("vb", 0, 1), ("vss", 0, 2),
                ("out", 1, 0), ("vb", 1, 1), ("mid", 1, 2),
            ],
        );
        let matches = find_matches(&cascode_stack(), &c.top);
        assert!(matches.is_empty(), "Same gate should not match cascode stack");
    }

    // ======================================================================
    // 4. Cascode current mirror
    // ======================================================================

    #[test]
    fn cascode_mirror_nmos_match() {
        // 4 NMOS: bottom pair (0=ref,1=mirror) + top pair (2=ref,3=mirror)
        let c = build_circuit(
            vec![
                make_nmos("MB_ref"), make_nmos("MB_mir"),
                make_nmos("MT_ref"), make_nmos("MT_mir"),
            ],
            &[
                // Bottom ref (diode): D=mid_ref, G=vb_bot, S=vss, gate=drain not needed
                // Actually for cascode mirror: bottom ref is diode (gate==drain)
                ("vb_bot", 0, 0), ("vb_bot", 0, 1), ("vss", 0, 2), // bottom-ref diode
                ("mid_mir", 1, 0), ("vb_bot", 1, 1), ("vss", 1, 2), // bottom-mirror
                // Top ref (diode): gate==drain
                ("vb_top", 2, 0), ("vb_top", 2, 1), ("vb_bot", 2, 2), // top-ref, source=bottom ref drain
                ("out",    3, 0), ("vb_top", 3, 1), ("mid_mir", 3, 2), // top-mirror, source=bottom mirror drain
            ],
        );
        let matches = find_matches(&cascode_mirror(), &c.top);
        assert!(!matches.is_empty(), "Cascode mirror should match");
    }

    #[test]
    fn cascode_mirror_pmos_match() {
        let c = build_circuit(
            vec![
                make_pmos("MB_ref"), make_pmos("MB_mir"),
                make_pmos("MT_ref"), make_pmos("MT_mir"),
            ],
            &[
                ("vb_bot", 0, 0), ("vb_bot", 0, 1), ("vdd", 0, 2),
                ("mid_mir", 1, 0), ("vb_bot", 1, 1), ("vdd", 1, 2),
                ("vb_top", 2, 0), ("vb_top", 2, 1), ("vb_bot", 2, 2),
                ("out",    3, 0), ("vb_top", 3, 1), ("mid_mir", 3, 2),
            ],
        );
        let matches = find_matches(&cascode_mirror(), &c.top);
        assert!(!matches.is_empty(), "PMOS cascode mirror should match");
    }

    #[test]
    fn cascode_mirror_no_match_only_two_devices() {
        // Only 2 devices: can't match a 4-node pattern
        let c = build_circuit(
            vec![make_nmos("M1"), make_nmos("M2")],
            &[
                ("bias", 0, 0), ("bias", 0, 1), ("vss", 0, 2),
                ("out",  1, 0), ("bias", 1, 1), ("vss", 1, 2),
            ],
        );
        let matches = find_matches(&cascode_mirror(), &c.top);
        assert!(matches.is_empty(), "2 devices cannot match 4-node cascode mirror");
    }

    // ======================================================================
    // 5. Push-pull
    // ======================================================================

    #[test]
    fn push_pull_match() {
        let c = build_circuit(
            vec![make_nmos("MN"), make_pmos("MP")],
            &[
                ("out", 0, 0), ("vin", 0, 1), ("vss", 0, 2),
                ("out", 1, 0), ("vin", 1, 1), ("vdd", 1, 2),
            ],
        );
        let matches = find_matches(&push_pull(), &c.top);
        assert!(!matches.is_empty(), "Push-pull should match");
    }

    #[test]
    fn push_pull_reversed_match() {
        // PMOS first, NMOS second — should still match
        let c = build_circuit(
            vec![make_pmos("MP"), make_nmos("MN")],
            &[
                ("out", 0, 0), ("vin", 0, 1), ("vdd", 0, 2),
                ("out", 1, 0), ("vin", 1, 1), ("vss", 1, 2),
            ],
        );
        let matches = find_matches(&push_pull(), &c.top);
        assert!(!matches.is_empty(), "Reversed push-pull should match");
    }

    #[test]
    fn push_pull_no_match_same_type() {
        // Two NMOS — not complementary
        let c = build_circuit(
            vec![make_nmos("M1"), make_nmos("M2")],
            &[
                ("out", 0, 0), ("vin", 0, 1), ("vss", 0, 2),
                ("out", 1, 0), ("vin", 1, 1), ("vss", 1, 2),
            ],
        );
        let matches = find_matches(&push_pull(), &c.top);
        assert!(matches.is_empty(), "Same type should not match push-pull");
    }

    // ======================================================================
    // 6. Common-source
    // ======================================================================

    #[test]
    fn common_source_nmos_match() {
        // Pattern says Drain(0) -- Plus(1): SameNet.
        // So we need drain="out" and plus of R1 = "out":
        let c2 = build_circuit(
            vec![make_nmos("M1"), make_resistor("R1")],
            &[
                ("out", 0, 0), ("vin", 0, 1), ("vss", 0, 2),
                ("out", 1, 0), ("vdd", 1, 1),
            ],
        );
        let matches = find_matches(&common_source(), &c2.top);
        assert!(!matches.is_empty(), "Common-source with NMOS should match");
    }

    #[test]
    fn common_source_pmos_match() {
        let c = build_circuit(
            vec![make_pmos("M1"), make_resistor("R1")],
            &[
                ("out", 0, 0), ("vin", 0, 1), ("vdd", 0, 2),
                ("out", 1, 0), ("vss", 1, 1),
            ],
        );
        let matches = find_matches(&common_source(), &c.top);
        assert!(!matches.is_empty(), "Common-source with PMOS should match");
    }

    #[test]
    fn common_source_no_match_no_connection() {
        // Resistor not connected to drain
        let c = build_circuit(
            vec![make_nmos("M1"), make_resistor("R1")],
            &[
                ("out", 0, 0), ("vin", 0, 1), ("vss", 0, 2),
                ("vdd", 1, 0), ("other", 1, 1),
            ],
        );
        let matches = find_matches(&common_source(), &c.top);
        assert!(matches.is_empty(), "No drain-resistor connection should not match");
    }

    // ======================================================================
    // 7. Source follower
    // ======================================================================

    #[test]
    fn source_follower_nmos_match() {
        let c = build_circuit(
            vec![make_nmos("M1"), make_isource("I1")],
            &[
                ("vdd", 0, 0), ("vin", 0, 1), ("out", 0, 2),
                ("out", 1, 0), ("vss", 1, 1),
            ],
        );
        let matches = find_matches(&source_follower(), &c.top);
        assert!(!matches.is_empty(), "Source follower with NMOS should match");
    }

    #[test]
    fn source_follower_pmos_match() {
        let c = build_circuit(
            vec![make_pmos("M1"), make_isource("I1")],
            &[
                ("vss", 0, 0), ("vin", 0, 1), ("out", 0, 2),
                ("out", 1, 0), ("vdd", 1, 1),
            ],
        );
        let matches = find_matches(&source_follower(), &c.top);
        assert!(!matches.is_empty(), "Source follower with PMOS should match");
    }

    #[test]
    fn source_follower_no_match_wrong_device() {
        // Resistor instead of Isource
        let c = build_circuit(
            vec![make_nmos("M1"), make_resistor("R1")],
            &[
                ("vdd", 0, 0), ("vin", 0, 1), ("out", 0, 2),
                ("out", 1, 0), ("vss", 1, 1),
            ],
        );
        let matches = find_matches(&source_follower(), &c.top);
        assert!(matches.is_empty(), "Resistor should not match source follower (needs Isource)");
    }

    // ======================================================================
    // 8. RC compensation
    // ======================================================================

    #[test]
    fn rc_compensation_match() {
        let c = build_circuit(
            vec![make_resistor("R1"), make_capacitor("C1")],
            &[
                ("a", 0, 0), ("mid", 0, 1),
                ("mid", 1, 0), ("b", 1, 1),
            ],
        );
        let matches = find_matches(&rc_compensation(), &c.top);
        assert!(!matches.is_empty(), "RC compensation should match");
    }

    #[test]
    fn rc_compensation_reversed_order() {
        // Capacitor first in instance list, resistor second — should still match
        let c = build_circuit(
            vec![make_capacitor("C1"), make_resistor("R1")],
            &[
                ("mid", 0, 0), ("b", 0, 1),
                ("a", 1, 0), ("mid", 1, 1),
            ],
        );
        let matches = find_matches(&rc_compensation(), &c.top);
        assert!(!matches.is_empty(), "RC compensation should match regardless of instance order");
    }

    #[test]
    fn rc_compensation_no_match_not_connected() {
        // R and C not sharing a net at the series junction
        let c = build_circuit(
            vec![make_resistor("R1"), make_capacitor("C1")],
            &[
                ("a", 0, 0), ("b", 0, 1),
                ("c", 1, 0), ("d", 1, 1),
            ],
        );
        let matches = find_matches(&rc_compensation(), &c.top);
        assert!(matches.is_empty(), "Unconnected R and C should not match");
    }

    // ======================================================================
    // 9. Wilson current mirror
    // ======================================================================

    #[test]
    fn wilson_mirror_nmos_match() {
        // 3 NMOS: M_ref(0), M_out(1), M_fb(2)
        // Gates of 0,1 shared; sources of 0,1 shared (rail)
        // M_fb source = M_out drain; M_fb drain = M_ref drain
        let c = build_circuit(
            vec![make_nmos("M_ref"), make_nmos("M_out"), make_nmos("M_fb")],
            &[
                ("ref_d", 0, 0), ("bias", 0, 1), ("vss", 0, 2),   // M_ref
                ("out_d", 1, 0), ("bias", 1, 1), ("vss", 1, 2),   // M_out
                ("ref_d", 2, 0), ("fb_g", 2, 1), ("out_d", 2, 2), // M_fb
            ],
        );
        let matches = find_matches(&wilson_mirror(), &c.top);
        assert!(!matches.is_empty(), "NMOS Wilson mirror should match");
    }

    #[test]
    fn wilson_mirror_pmos_match() {
        let c = build_circuit(
            vec![make_pmos("M_ref"), make_pmos("M_out"), make_pmos("M_fb")],
            &[
                ("ref_d", 0, 0), ("bias", 0, 1), ("vdd", 0, 2),
                ("out_d", 1, 0), ("bias", 1, 1), ("vdd", 1, 2),
                ("ref_d", 2, 0), ("fb_g", 2, 1), ("out_d", 2, 2),
            ],
        );
        let matches = find_matches(&wilson_mirror(), &c.top);
        assert!(!matches.is_empty(), "PMOS Wilson mirror should match");
    }

    #[test]
    fn wilson_mirror_no_match_missing_feedback() {
        // M_fb source not connected to M_out drain
        let c = build_circuit(
            vec![make_nmos("M_ref"), make_nmos("M_out"), make_nmos("M_fb")],
            &[
                ("ref_d", 0, 0), ("bias", 0, 1), ("vss", 0, 2),
                ("out_d", 1, 0), ("bias", 1, 1), ("vss", 1, 2),
                ("ref_d", 2, 0), ("fb_g", 2, 1), ("wrong", 2, 2), // wrong source
            ],
        );
        let matches = find_matches(&wilson_mirror(), &c.top);
        assert!(matches.is_empty(), "Missing feedback should not match Wilson mirror");
    }

    #[test]
    fn wilson_mirror_no_match_mixed_types() {
        // Mixed NMOS + PMOS — should not match (all must be same type)
        let c = build_circuit(
            vec![make_nmos("M_ref"), make_nmos("M_out"), make_pmos("M_fb")],
            &[
                ("ref_d", 0, 0), ("bias", 0, 1), ("vss", 0, 2),
                ("out_d", 1, 0), ("bias", 1, 1), ("vss", 1, 2),
                ("ref_d", 2, 0), ("fb_g", 2, 1), ("out_d", 2, 2),
            ],
        );
        let matches = find_matches(&wilson_mirror(), &c.top);
        assert!(matches.is_empty(), "Mixed types should not match Wilson mirror");
    }

    // ======================================================================
    // 10. Widlar current mirror
    // ======================================================================

    #[test]
    fn widlar_mirror_nmos_match() {
        // M_ref(0) diode-connected, M_out(1) gate shared, R_deg(2) on M_out source
        let c = build_circuit(
            vec![make_nmos("M_ref"), make_nmos("M_out"), make_resistor("R_deg")],
            &[
                ("bias", 0, 0), ("bias", 0, 1), ("vss", 0, 2),     // M_ref diode
                ("out",  1, 0), ("bias", 1, 1), ("mid", 1, 2),     // M_out
                ("mid",  2, 0), ("vss",  2, 1),                     // R_deg: plus=mid, minus=vss
            ],
        );
        let matches = find_matches(&widlar_mirror(), &c.top);
        assert!(!matches.is_empty(), "NMOS Widlar mirror should match");
    }

    #[test]
    fn widlar_mirror_pmos_match() {
        let c = build_circuit(
            vec![make_pmos("M_ref"), make_pmos("M_out"), make_resistor("R_deg")],
            &[
                ("bias", 0, 0), ("bias", 0, 1), ("vdd", 0, 2),
                ("out",  1, 0), ("bias", 1, 1), ("mid", 1, 2),
                ("mid",  2, 0), ("vdd",  2, 1),
            ],
        );
        let matches = find_matches(&widlar_mirror(), &c.top);
        assert!(!matches.is_empty(), "PMOS Widlar mirror should match");
    }

    #[test]
    fn widlar_mirror_no_match_no_diode() {
        // M_ref not diode-connected (gate != drain)
        let c = build_circuit(
            vec![make_nmos("M_ref"), make_nmos("M_out"), make_resistor("R_deg")],
            &[
                ("drain", 0, 0), ("bias", 0, 1), ("vss", 0, 2),   // NOT diode
                ("out",   1, 0), ("bias", 1, 1), ("mid", 1, 2),
                ("mid",   2, 0), ("vss",  2, 1),
            ],
        );
        let matches = find_matches(&widlar_mirror(), &c.top);
        assert!(matches.is_empty(), "No diode should not match Widlar mirror");
    }

    #[test]
    fn widlar_mirror_no_match_no_resistor() {
        // Capacitor instead of resistor
        let c = build_circuit(
            vec![make_nmos("M_ref"), make_nmos("M_out"), make_capacitor("C1")],
            &[
                ("bias", 0, 0), ("bias", 0, 1), ("vss", 0, 2),
                ("out",  1, 0), ("bias", 1, 1), ("mid", 1, 2),
                ("mid",  2, 0), ("vss",  2, 1),
            ],
        );
        let matches = find_matches(&widlar_mirror(), &c.top);
        assert!(matches.is_empty(), "Capacitor should not match Widlar mirror (needs Resistor)");
    }

    // ======================================================================
    // 11. Resistor voltage divider
    // ======================================================================

    #[test]
    fn resistor_divider_match() {
        // Two resistors in series: R_top minus == R_bot plus, different end nets
        let c = build_circuit(
            vec![make_resistor("R_top"), make_resistor("R_bot")],
            &[
                ("vdd", 0, 0), ("mid", 0, 1),  // R_top: plus=vdd, minus=mid
                ("mid", 1, 0), ("vss", 1, 1),  // R_bot: plus=mid, minus=vss
            ],
        );
        let matches = find_matches(&resistor_divider(), &c.top);
        assert!(!matches.is_empty(), "Resistor divider should match");
    }

    #[test]
    fn resistor_divider_reversed_order() {
        // Resistors in reversed instance order — should still match
        let c = build_circuit(
            vec![make_resistor("R_bot"), make_resistor("R_top")],
            &[
                ("mid", 0, 0), ("vss", 0, 1),  // R_bot: plus=mid, minus=vss
                ("vdd", 1, 0), ("mid", 1, 1),  // R_top: plus=vdd, minus=mid
            ],
        );
        let matches = find_matches(&resistor_divider(), &c.top);
        assert!(!matches.is_empty(), "Reversed-order resistor divider should match");
    }

    #[test]
    fn resistor_divider_no_match_not_connected() {
        // Two resistors not sharing a net at the series junction
        let c = build_circuit(
            vec![make_resistor("R1"), make_resistor("R2")],
            &[
                ("a", 0, 0), ("b", 0, 1),
                ("c", 1, 0), ("d", 1, 1),
            ],
        );
        let matches = find_matches(&resistor_divider(), &c.top);
        assert!(matches.is_empty(), "Unconnected resistors should not match divider");
    }

    #[test]
    fn resistor_divider_no_match_same_end_nets() {
        // Both ends on the same net (shorted) — diff_net constraint should reject
        let c = build_circuit(
            vec![make_resistor("R1"), make_resistor("R2")],
            &[
                ("vdd", 0, 0), ("mid", 0, 1),
                ("mid", 1, 0), ("vdd", 1, 1),  // minus=vdd, same as R1 plus
            ],
        );
        let matches = find_matches(&resistor_divider(), &c.top);
        assert!(matches.is_empty(), "Same end nets should not match divider (needs different ends)");
    }

    // ======================================================================
    // Pattern collection
    // ======================================================================

    #[test]
    fn all_patterns_sorted_by_specificity() {
        let patterns = all_patterns();
        for i in 1..patterns.len() {
            assert!(
                patterns[i - 1].node_count() >= patterns[i].node_count(),
                "patterns must be sorted by specificity (most nodes first)"
            );
        }
    }

    #[test]
    fn all_patterns_have_unique_ids() {
        let patterns = all_patterns();
        let ids: Vec<_> = patterns.iter().map(|p| p.id).collect();
        for (i, id) in ids.iter().enumerate() {
            assert!(
                !ids[..i].contains(id),
                "duplicate PatternId found: {:?}",
                id
            );
        }
    }
}
