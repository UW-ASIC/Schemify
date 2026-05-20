//! Analog block recognition using VF2 subgraph isomorphism.
//!
//! Matches declarative pattern templates against the circuit IR and returns
//! recognized analog building blocks. Patterns are tried most-specific first
//! (most nodes) and instances are claimed greedily — once an instance belongs
//! to a block it cannot be reused by a less-specific pattern.

pub mod patterns;
pub mod vf2;

use std::collections::HashSet;

use crate::s2s::ir::{Circuit, NetClass, Subcircuit};
use vf2::{PatternId, find_matches};

/// Recognized analog block type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BlockType {
    DiffPair,
    CurrentMirror,
    Cascode,        // kept for backward compat (= CascodeStack)
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
        BlockType::DiffPair => PlacementHint { h_spacing: 160, v_spacing: 0, ordering: DeviceOrdering::Unordered },
        BlockType::CurrentMirror => PlacementHint { h_spacing: 160, v_spacing: 0, ordering: DeviceOrdering::RefFirst },
        BlockType::Cascode | BlockType::CascodeStack => PlacementHint { h_spacing: 0, v_spacing: 160, ordering: DeviceOrdering::BottomFirst },
        BlockType::CascodeMirror => PlacementHint { h_spacing: 160, v_spacing: 160, ordering: DeviceOrdering::RefFirst },
        BlockType::PushPull => PlacementHint { h_spacing: 0, v_spacing: 160, ordering: DeviceOrdering::PmosFirst },
        BlockType::CommonSource => PlacementHint { h_spacing: 0, v_spacing: 160, ordering: DeviceOrdering::Unordered },
        BlockType::SourceFollower => PlacementHint { h_spacing: 0, v_spacing: 160, ordering: DeviceOrdering::Unordered },
        BlockType::RcCompensation => PlacementHint { h_spacing: 160, v_spacing: 0, ordering: DeviceOrdering::Unordered },
        BlockType::WilsonMirror => PlacementHint { h_spacing: 160, v_spacing: 160, ordering: DeviceOrdering::RefFirst },
        BlockType::WidlarMirror => PlacementHint { h_spacing: 160, v_spacing: 80, ordering: DeviceOrdering::RefFirst },
        BlockType::ResistorDivider => PlacementHint { h_spacing: 0, v_spacing: 160, ordering: DeviceOrdering::Unordered },
    }
}

/// For current mirror matches, reorder so the diode-connected device is first.
/// The diode-connected device is pattern node 0 by definition (see patterns.rs).
/// Since node_mapping[0] already maps pattern node 0 (diode-ref) to a circuit
/// instance, the mapping naturally puts the ref first.
fn maybe_reorder_mirror_sub(block_type: BlockType, mapping: &[u32], subckt: &Subcircuit) -> Vec<u32> {
    if block_type != BlockType::CurrentMirror || mapping.len() < 2 {
        return mapping.to_vec();
    }

    // Pattern node 0 = diode-connected ref. Check which mapping actually has
    // gate == drain (the VF2 match ensures this, but we verify for ordering).
    let idx0 = mapping[0] as usize;
    let inst0 = &subckt.instances[idx0];
    let gate0 = inst0.pins.get(1).and_then(|p| p.net_idx);
    let drain0 = inst0.pins.get(0).and_then(|p| p.net_idx);

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

            // Reject diff-pair matches where the shared source is a power/ground
            // net. Two MOSFETs on the same supply rail with different gates/drains
            // are extremely common but almost never actual differential pairs.
            if block_type == BlockType::DiffPair {
                if is_power_rail_diff_pair(mapping, subckt) {
                    continue;
                }
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

/// For cascode stacks, ensure the bottom device (whose drain connects to the
/// top's source) is listed first.
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
    if let Some(net_idx) = source_net {
        if let Some(net) = subckt.nets.get(net_idx as usize) {
            return matches!(net.classification, NetClass::Power | NetClass::Ground);
        }
    }
    false
}

fn maybe_reorder_cascode_sub(mapping: &[u32], subckt: &Subcircuit) -> Vec<u32> {
    if mapping.len() != 2 {
        return mapping.to_vec();
    }

    let idx0 = mapping[0] as usize;
    let idx1 = mapping[1] as usize;

    // Check if inst0's drain == inst1's source (inst0 is bottom)
    let drain0 = subckt.instances[idx0].pins.get(0).and_then(|p| p.net_idx);
    let source1 = subckt.instances[idx1].pins.get(2).and_then(|p| p.net_idx);

    if drain0.is_some() && drain0 == source1 {
        // Already correct: idx0 is bottom
        mapping.to_vec()
    } else {
        // Swap: idx1 is actually the bottom
        vec![mapping[1], mapping[0]]
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::s2s::ir::*;
    /// Helper: create a 4-pin NMOS instance.
    fn make_nmos(name: &str) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: Primitive::Nmos,
            symbol: "nmos4".to_string(),
            pins: vec![
                Pin { name: "D".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "G".into(), dir: PinDir::Input, net_idx: None },
                Pin { name: "S".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "B".into(), dir: PinDir::Bulk, net_idx: None },
            ],
            params: Default::default(),
            x: 0, y: 0, rotation: 0, flip: false,
        }
    }

    fn make_pmos(name: &str) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: Primitive::Pmos,
            symbol: "pmos4".to_string(),
            pins: vec![
                Pin { name: "D".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "G".into(), dir: PinDir::Input, net_idx: None },
                Pin { name: "S".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "B".into(), dir: PinDir::Bulk, net_idx: None },
            ],
            params: Default::default(),
            x: 0, y: 0, rotation: 0, flip: false,
        }
    }

    fn make_resistor(name: &str) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: Primitive::Resistor,
            symbol: String::new(),
            pins: vec![
                Pin { name: "p".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "n".into(), dir: PinDir::Inout, net_idx: None },
            ],
            params: Default::default(),
            x: 0, y: 0, rotation: 0, flip: false,
        }
    }

    fn make_capacitor(name: &str) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: Primitive::Capacitor,
            symbol: String::new(),
            pins: vec![
                Pin { name: "p".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "n".into(), dir: PinDir::Inout, net_idx: None },
            ],
            params: Default::default(),
            x: 0, y: 0, rotation: 0, flip: false,
        }
    }

    fn make_isource(name: &str) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: Primitive::Isource,
            symbol: String::new(),
            pins: vec![
                Pin { name: "p".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "n".into(), dir: PinDir::Inout, net_idx: None },
            ],
            params: Default::default(),
            x: 0, y: 0, rotation: 0, flip: false,
        }
    }

    /// Build a circuit with two NMOS and connect their pins to named nets.
    fn two_nmos_circuit(
        m1_nets: [&str; 3],
        m2_nets: [&str; 3],
    ) -> Circuit {
        let mut c = Circuit::new("test");
        let m1 = make_nmos("M1");
        let m2 = make_nmos("M2");
        c.add_instance(m1);
        c.add_instance(m2);

        for (inst_idx, nets) in [m1_nets, m2_nets].iter().enumerate() {
            for (pin_idx, net_name) in nets.iter().enumerate() {
                let net_idx = c.get_or_create_net(net_name);
                c.connect(
                    net_idx,
                    PinRef {
                        instance_idx: inst_idx as u32,
                        pin_idx: pin_idx as u32,
                    },
                );
            }
        }
        c
    }

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
    // Backward-compatibility tests (same as original)
    // ======================================================================

    #[test]
    fn diff_pair_detected() {
        let circuit = two_nmos_circuit(
            ["outm", "inp", "tail"],
            ["outp", "inn", "tail"],
        );
        let blocks = recognize(&circuit);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].block_type, BlockType::DiffPair);
        // Both instances should be in the block
        let mut indices = blocks[0].instance_indices.clone();
        indices.sort();
        assert_eq!(indices, vec![0, 1]);
    }

    #[test]
    fn current_mirror_detected() {
        let circuit = two_nmos_circuit(
            ["bias", "bias", "vss"],
            ["out", "bias", "vss"],
        );
        let blocks = recognize(&circuit);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].block_type, BlockType::CurrentMirror);
        // Diode-connected device (M1=0) listed first
        assert_eq!(blocks[0].instance_indices, vec![0, 1]);
    }

    #[test]
    fn cascode_detected() {
        let circuit = two_nmos_circuit(
            ["mid", "vb1", "vss"],
            ["out", "vb2", "mid"],
        );
        let blocks = recognize(&circuit);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].block_type, BlockType::CascodeStack);
        // Bottom (M1=0) first, top (M2=1) second
        assert_eq!(blocks[0].instance_indices, vec![0, 1]);
    }

    #[test]
    fn no_false_positive_same_drains() {
        let circuit = two_nmos_circuit(
            ["d", "g", "s"],
            ["d", "g", "s"],
        );
        let blocks = recognize(&circuit);
        // gate==gate and drain==drain => not diff pair.
        // gate != drain => not diode-connected => not mirror.
        // drain != source of other (d != s, different net names) => not cascode.
        assert!(
            blocks.is_empty(),
            "Expected no blocks, got {:?}",
            blocks,
        );
    }

    #[test]
    fn claimed_instances_not_reused() {
        let mut c = Circuit::new("test");
        for name in &["M0", "M1", "M2"] {
            c.add_instance(make_nmos(name));
        }
        let connections: &[(&str, u32, u32)] = &[
            ("outm", 0, 0), ("inp", 0, 1), ("tail", 0, 2),
            ("outp", 1, 0), ("inn", 1, 1), ("tail", 1, 2),
            ("outx", 2, 0), ("inx", 2, 1), ("tail", 2, 2),
        ];
        for &(net_name, inst, pin) in connections {
            let net_idx = c.get_or_create_net(net_name);
            c.connect(net_idx, PinRef { instance_idx: inst, pin_idx: pin });
        }

        let blocks = recognize(&c);
        let diff_pairs: Vec<_> = blocks.iter().filter(|b| b.block_type == BlockType::DiffPair).collect();
        assert_eq!(diff_pairs.len(), 1);
        let mut indices = diff_pairs[0].instance_indices.clone();
        indices.sort();
        assert_eq!(indices, vec![0, 1]);
    }

    #[test]
    fn empty_circuit_no_blocks() {
        let circuit = Circuit::new("empty");
        let blocks = recognize(&circuit);
        assert!(blocks.is_empty());
    }

    // ======================================================================
    // New VF2-based tests
    // ======================================================================

    #[test]
    fn push_pull_detected() {
        let circuit = build_circuit(
            vec![make_nmos("MN"), make_pmos("MP")],
            &[
                ("out", 0, 0), ("vin", 0, 1), ("vss", 0, 2),
                ("out", 1, 0), ("vin", 1, 1), ("vdd", 1, 2),
            ],
        );
        let blocks = recognize(&circuit);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].block_type, BlockType::PushPull);
    }

    #[test]
    fn common_source_detected() {
        let circuit = build_circuit(
            vec![make_nmos("M1"), make_resistor("R1")],
            &[
                ("out", 0, 0), ("vin", 0, 1), ("vss", 0, 2),
                ("out", 1, 0), ("vdd", 1, 1),
            ],
        );
        let blocks = recognize(&circuit);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].block_type, BlockType::CommonSource);
    }

    #[test]
    fn source_follower_detected() {
        let circuit = build_circuit(
            vec![make_nmos("M1"), make_isource("I1")],
            &[
                ("vdd", 0, 0), ("vin", 0, 1), ("out", 0, 2),
                ("out", 1, 0), ("vss", 1, 1),
            ],
        );
        let blocks = recognize(&circuit);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].block_type, BlockType::SourceFollower);
    }

    #[test]
    fn rc_compensation_detected() {
        let circuit = build_circuit(
            vec![make_resistor("R1"), make_capacitor("C1")],
            &[
                ("a", 0, 0), ("mid", 0, 1),
                ("mid", 1, 0), ("b", 1, 1),
            ],
        );
        let blocks = recognize(&circuit);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].block_type, BlockType::RcCompensation);
    }

    #[test]
    fn cascode_mirror_detected_over_simple_mirrors() {
        // 4 NMOS forming a cascode mirror. The 4-node cascode mirror pattern
        // should be preferred over two 2-node simple mirrors.
        let circuit = build_circuit(
            vec![
                make_nmos("MB_ref"), make_nmos("MB_mir"),
                make_nmos("MT_ref"), make_nmos("MT_mir"),
            ],
            &[
                ("vb_bot", 0, 0), ("vb_bot", 0, 1), ("vss", 0, 2),
                ("mid_mir", 1, 0), ("vb_bot", 1, 1), ("vss", 1, 2),
                ("vb_top", 2, 0), ("vb_top", 2, 1), ("vb_bot", 2, 2),
                ("out",    3, 0), ("vb_top", 3, 1), ("mid_mir", 3, 2),
            ],
        );
        let blocks = recognize(&circuit);
        // Should get a cascode mirror, not two simple mirrors
        let cascode_mirrors: Vec<_> = blocks.iter()
            .filter(|b| b.block_type == BlockType::CascodeMirror)
            .collect();
        assert_eq!(cascode_mirrors.len(), 1, "Should detect one cascode mirror");
        assert_eq!(cascode_mirrors[0].instance_indices.len(), 4);

        // No simple mirrors should be found (all instances claimed)
        let simple_mirrors: Vec<_> = blocks.iter()
            .filter(|b| b.block_type == BlockType::CurrentMirror)
            .collect();
        assert!(simple_mirrors.is_empty(), "Cascode mirror should claim all 4 instances");
    }

    #[test]
    fn multiple_blocks_detected() {
        // Diff pair + current mirror (separate devices)
        let circuit = build_circuit(
            vec![
                make_nmos("M1"), make_nmos("M2"),  // diff pair
                make_nmos("M3"), make_nmos("M4"),  // current mirror
            ],
            &[
                // Diff pair: M1, M2
                ("outm", 0, 0), ("inp", 0, 1), ("tail", 0, 2),
                ("outp", 1, 0), ("inn", 1, 1), ("tail", 1, 2),
                // Current mirror: M3 (diode), M4
                ("bias", 2, 0), ("bias", 2, 1), ("vss", 2, 2),
                ("iout", 3, 0), ("bias", 3, 1), ("vss", 3, 2),
            ],
        );
        let blocks = recognize(&circuit);
        let diff_pairs: Vec<_> = blocks.iter().filter(|b| b.block_type == BlockType::DiffPair).collect();
        let mirrors: Vec<_> = blocks.iter().filter(|b| b.block_type == BlockType::CurrentMirror).collect();
        assert_eq!(diff_pairs.len(), 1, "Should detect one diff pair");
        assert_eq!(mirrors.len(), 1, "Should detect one current mirror");
    }

    #[test]
    fn pmos_diff_pair_detected() {
        let circuit = build_circuit(
            vec![make_pmos("M1"), make_pmos("M2")],
            &[
                ("outm", 0, 0), ("inp", 0, 1), ("tail", 0, 2),
                ("outp", 1, 0), ("inn", 1, 1), ("tail", 1, 2),
            ],
        );
        let blocks = recognize(&circuit);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].block_type, BlockType::DiffPair);
    }

    #[test]
    fn no_cross_contamination() {
        // A diff pair should not accidentally match as a cascode or mirror.
        let circuit = two_nmos_circuit(
            ["outm", "inp", "tail"],
            ["outp", "inn", "tail"],
        );
        let blocks = recognize(&circuit);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].block_type, BlockType::DiffPair);
        // No other block types
        for b in &blocks {
            assert_ne!(b.block_type, BlockType::CurrentMirror);
            assert_ne!(b.block_type, BlockType::CascodeStack);
        }
    }
}
