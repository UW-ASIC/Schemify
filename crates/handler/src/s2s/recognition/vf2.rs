//! VF2 subgraph isomorphism engine for analog block recognition.
//!
//! Implements the VF2 algorithm (Cordella et al., 2004) adapted for
//! circuit graphs where nodes are device instances and edges represent
//! pin-connectivity constraints (same-net or different-net).

use crate::s2s::ir::{Primitive, Subcircuit};

// ---------------------------------------------------------------------------
// Pattern graph types
// ---------------------------------------------------------------------------

/// Unique identifier for a pattern.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PatternId {
    DiffPair,
    CurrentMirror,
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

/// A node in the pattern graph (represents a device in the template).
#[derive(Debug, Clone)]
pub struct PatternNode {
    pub id: u32,
    /// Required device type, or `None` for wildcard.
    pub device_type: Option<Primitive>,
    /// Constraint relating this node's type to another node.
    pub type_constraint: Option<TypeConstraint>,
}

/// Constraint on the device type of a pattern node relative to another node.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TypeConstraint {
    /// Must be the same Primitive as the referenced node.
    SameAsNode(u32),
    /// Must be complementary: NMOS<->PMOS or NPN<->PNP.
    Complementary(u32),
}

/// An edge in the pattern graph (a pin-connectivity constraint between two nodes).
#[derive(Debug, Clone)]
pub struct PatternEdge {
    pub from_node: u32,
    pub from_pin: u32,
    pub to_node: u32,
    pub to_pin: u32,
    pub constraint: EdgeConstraint,
}

/// Constraint on the net relationship between two pins.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EdgeConstraint {
    /// The two pins must be connected to the same net.
    SameNet,
    /// The two pins must be on different nets.
    DifferentNet,
}

/// A complete pattern graph used for VF2 matching.
#[derive(Debug, Clone)]
pub struct PatternGraph {
    pub id: PatternId,
    pub nodes: Vec<PatternNode>,
    pub edges: Vec<PatternEdge>,
}

impl PatternGraph {
    /// Number of nodes in this pattern (its "specificity").
    pub fn node_count(&self) -> usize {
        self.nodes.len()
    }
}

// ---------------------------------------------------------------------------
// VF2 matching state
// ---------------------------------------------------------------------------

/// Internal state for the VF2 recursive matching algorithm.
struct Vf2State<'a> {
    pattern: &'a PatternGraph,
    subckt: &'a Subcircuit,
    /// core_1[pattern_node] = Some(circuit_instance_idx) if mapped.
    core_1: Vec<Option<u32>>,
    /// core_2[circuit_instance] = Some(pattern_node_idx) if mapped.
    core_2: Vec<Option<u32>>,
    /// Current depth (number of matched pairs).
    depth: usize,
    /// Collected complete mappings.
    results: Vec<Vec<u32>>,
}

impl<'a> Vf2State<'a> {
    fn new(pattern: &'a PatternGraph, subckt: &'a Subcircuit) -> Self {
        let n_pattern = pattern.nodes.len();
        let n_circuit = subckt.instances.len();
        Self {
            pattern,
            subckt,
            core_1: vec![None; n_pattern],
            core_2: vec![None; n_circuit],
            depth: 0,
            results: Vec::new(),
        }
    }

    /// Run VF2 matching, collecting all valid mappings.
    fn run(&mut self) {
        self.match_recursive();
    }

    fn match_recursive(&mut self) {
        if self.depth == self.pattern.nodes.len() {
            // Complete match found — record the mapping.
            let mapping: Vec<u32> = self
                .core_1
                .iter()
                .map(|o| o.expect("complete mapping must have all nodes"))
                .collect();
            self.results.push(mapping);
            return;
        }

        // Pick the next unmapped pattern node (lowest index).
        let p_node = self
            .core_1
            .iter()
            .position(|o| o.is_none())
            .expect("depth < node_count implies an unmapped node exists");

        // Try to map it to each unmapped circuit instance.
        let n_circuit = self.subckt.instances.len();
        for c_inst in 0..n_circuit {
            if self.core_2[c_inst].is_some() {
                continue; // already mapped
            }

            if self.is_feasible(p_node, c_inst as u32) {
                // Extend the mapping.
                self.core_1[p_node] = Some(c_inst as u32);
                self.core_2[c_inst] = Some(p_node as u32);
                self.depth += 1;

                self.match_recursive();

                // Backtrack.
                self.depth -= 1;
                self.core_1[p_node] = None;
                self.core_2[c_inst] = None;
            }
        }
    }

    /// Check whether mapping pattern node `p` to circuit instance `c` is feasible.
    fn is_feasible(&self, p: usize, c: u32) -> bool {
        let p_node = &self.pattern.nodes[p];
        let c_inst = &self.subckt.instances[c as usize];

        // 1. Device type check.
        if let Some(required_type) = p_node.device_type {
            if c_inst.primitive != required_type {
                return false;
            }
        }

        // 2. Type constraint check (relative to already-mapped nodes).
        if let Some(ref tc) = p_node.type_constraint {
            match tc {
                TypeConstraint::SameAsNode(ref_node) => {
                    if let Some(ref_c) = self.core_1[*ref_node as usize] {
                        let ref_prim = self.subckt.instances[ref_c as usize].primitive;
                        if c_inst.primitive != ref_prim {
                            return false;
                        }
                    }
                    // If ref node not yet mapped, we can't check — allow for now,
                    // it will be checked when the ref node is mapped.
                }
                TypeConstraint::Complementary(ref_node) => {
                    if let Some(ref_c) = self.core_1[*ref_node as usize] {
                        let ref_prim = self.subckt.instances[ref_c as usize].primitive;
                        if !is_complementary(ref_prim, c_inst.primitive) {
                            return false;
                        }
                    }
                }
            }
        }

        // 2b. Check type constraints of already-mapped nodes that reference `p`.
        for (other_p, node) in self.pattern.nodes.iter().enumerate() {
            if other_p == p {
                continue;
            }
            if let Some(ref tc) = node.type_constraint {
                let refers_to_p = match tc {
                    TypeConstraint::SameAsNode(ref_node) => *ref_node == p as u32,
                    TypeConstraint::Complementary(ref_node) => *ref_node == p as u32,
                };
                if refers_to_p {
                    if let Some(other_c) = self.core_1[other_p] {
                        let other_prim = self.subckt.instances[other_c as usize].primitive;
                        match tc {
                            TypeConstraint::SameAsNode(_) => {
                                if other_prim != c_inst.primitive {
                                    return false;
                                }
                            }
                            TypeConstraint::Complementary(_) => {
                                if !is_complementary(other_prim, c_inst.primitive) {
                                    return false;
                                }
                            }
                        }
                    }
                }
            }
        }

        // 3. Edge constraint check: for every pattern edge involving `p` where
        //    the other endpoint is already mapped (or is `p` itself for self-edges),
        //    verify the net constraint.
        for edge in &self.pattern.edges {
            // Self-edge: both endpoints are the current node `p`.
            // Check the constraint between two pins on the same circuit instance.
            if edge.from_node == p as u32 && edge.to_node == p as u32 {
                let net_a = self.pin_net(c, edge.from_pin);
                let net_b = self.pin_net(c, edge.to_pin);
                match edge.constraint {
                    EdgeConstraint::SameNet => match (net_a, net_b) {
                        (Some(a), Some(b)) if a == b => {}
                        _ => return false,
                    },
                    EdgeConstraint::DifferentNet => match (net_a, net_b) {
                        (Some(a), Some(b)) if a != b => {}
                        _ => return false,
                    },
                }
                continue;
            }

            let (this_pin, other_node, other_pin) = if edge.from_node == p as u32 {
                (edge.from_pin, edge.to_node, edge.to_pin)
            } else if edge.to_node == p as u32 {
                (edge.to_pin, edge.from_node, edge.from_pin)
            } else {
                continue; // edge doesn't involve this pattern node
            };

            // Only check if the other node is already mapped.
            if let Some(other_c) = self.core_1[other_node as usize] {
                let c_net = self.pin_net(c, this_pin);
                let other_net = self.pin_net(other_c, other_pin);

                match edge.constraint {
                    EdgeConstraint::SameNet => {
                        match (c_net, other_net) {
                            (Some(a), Some(b)) if a == b => {} // OK
                            _ => return false,
                        }
                    }
                    EdgeConstraint::DifferentNet => {
                        match (c_net, other_net) {
                            (Some(a), Some(b)) if a != b => {} // OK
                            _ => return false,
                        }
                    }
                }
            }
        }

        true
    }

    /// Get the net index for a pin on a circuit instance.
    fn pin_net(&self, inst_idx: u32, pin_idx: u32) -> Option<u32> {
        self.subckt
            .instances
            .get(inst_idx as usize)?
            .pins
            .get(pin_idx as usize)?
            .net_idx
    }
}

/// Check if two primitives are complementary (NMOS<->PMOS or NPN<->PNP).
fn is_complementary(a: Primitive, b: Primitive) -> bool {
    matches!(
        (a, b),
        (Primitive::Nmos, Primitive::Pmos)
            | (Primitive::Pmos, Primitive::Nmos)
            | (Primitive::Npn, Primitive::Pnp)
            | (Primitive::Pnp, Primitive::Npn)
    )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Find all matches of `pattern` in `subckt`.
///
/// Returns a vector of mappings. Each mapping is a `Vec<u32>` of length
/// `pattern.nodes.len()`, where `mapping[pattern_node_idx]` gives the
/// circuit instance index it maps to.
pub fn find_matches(pattern: &PatternGraph, subckt: &Subcircuit) -> Vec<Vec<u32>> {
    if pattern.nodes.is_empty() || subckt.instances.is_empty() {
        return Vec::new();
    }
    let mut state = Vf2State::new(pattern, subckt);
    state.run();
    state.results
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::s2s::ir::*;
    use std::collections::HashMap;

    /// Helper: build a MOSFET instance with 4 pins (D, G, S, B).
    fn make_mosfet(name: &str, prim: Primitive) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: prim,
            symbol: String::new(),
            pins: vec![
                Pin {
                    name: "D".into(),
                    dir: PinDir::Inout,
                    net_idx: None,
                },
                Pin {
                    name: "G".into(),
                    dir: PinDir::Input,
                    net_idx: None,
                },
                Pin {
                    name: "S".into(),
                    dir: PinDir::Inout,
                    net_idx: None,
                },
                Pin {
                    name: "B".into(),
                    dir: PinDir::Bulk,
                    net_idx: None,
                },
            ],
            params: HashMap::new(),
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        }
    }

    fn make_nmos(name: &str) -> Instance {
        make_mosfet(name, Primitive::Nmos)
    }

    fn make_pmos(name: &str) -> Instance {
        make_mosfet(name, Primitive::Pmos)
    }

    /// Build a circuit from a list of instances and net connections.
    /// connections: &[(net_name, instance_idx, pin_idx)]
    fn build_circuit(instances: Vec<Instance>, connections: &[(&str, u32, u32)]) -> Circuit {
        let mut c = Circuit::new("test");
        for inst in instances {
            c.add_instance(inst);
        }
        for &(net_name, inst_idx, pin_idx) in connections {
            let net_idx = c.get_or_create_net(net_name);
            c.connect(
                net_idx,
                PinRef {
                    instance_idx: inst_idx,
                    pin_idx,
                },
            );
        }
        c
    }

    /// Build a simple diff pair pattern for testing.
    fn diff_pair_pattern() -> PatternGraph {
        crate::s2s::recognition::patterns::diff_pair()
    }

    // -- VF2 core tests --

    #[test]
    fn vf2_empty_pattern_no_matches() {
        let pattern = PatternGraph {
            id: PatternId::DiffPair,
            nodes: vec![],
            edges: vec![],
        };
        let c = Circuit::new("empty");
        let matches = find_matches(&pattern, &c.top);
        assert!(matches.is_empty());
    }

    #[test]
    fn vf2_empty_circuit_no_matches() {
        let pattern = diff_pair_pattern();
        let c = Circuit::new("empty");
        let matches = find_matches(&pattern, &c.top);
        assert!(matches.is_empty());
    }

    #[test]
    fn vf2_diff_pair_nmos_match() {
        let circuit = build_circuit(
            vec![make_nmos("M1"), make_nmos("M2")],
            &[
                ("outm", 0, 0),
                ("inp", 0, 1),
                ("tail", 0, 2),
                ("outp", 1, 0),
                ("inn", 1, 1),
                ("tail", 1, 2),
            ],
        );
        let pattern = diff_pair_pattern();
        let matches = find_matches(&pattern, &circuit.top);
        // Should find 2 matches (M1->node0,M2->node1 and M2->node0,M1->node1)
        assert_eq!(matches.len(), 2);
        // Both mappings should contain instances 0 and 1
        for m in &matches {
            let mut sorted = m.clone();
            sorted.sort();
            assert_eq!(sorted, vec![0, 1]);
        }
    }

    #[test]
    fn vf2_diff_pair_pmos_match() {
        let circuit = build_circuit(
            vec![make_pmos("M1"), make_pmos("M2")],
            &[
                ("outm", 0, 0),
                ("inp", 0, 1),
                ("tail", 0, 2),
                ("outp", 1, 0),
                ("inn", 1, 1),
                ("tail", 1, 2),
            ],
        );
        let pattern = diff_pair_pattern();
        let matches = find_matches(&pattern, &circuit.top);
        assert_eq!(matches.len(), 2);
    }

    #[test]
    fn vf2_diff_pair_no_match_shared_gate() {
        // Same gate net -> not a diff pair
        let circuit = build_circuit(
            vec![make_nmos("M1"), make_nmos("M2")],
            &[
                ("outm", 0, 0),
                ("vin", 0, 1),
                ("tail", 0, 2),
                ("outp", 1, 0),
                ("vin", 1, 1),
                ("tail", 1, 2),
            ],
        );
        let pattern = diff_pair_pattern();
        let matches = find_matches(&pattern, &circuit.top);
        assert!(matches.is_empty());
    }

    #[test]
    fn vf2_diff_pair_no_match_different_types() {
        // NMOS + PMOS -> not a diff pair (must be same type)
        let circuit = build_circuit(
            vec![make_nmos("M1"), make_pmos("M2")],
            &[
                ("outm", 0, 0),
                ("inp", 0, 1),
                ("tail", 0, 2),
                ("outp", 1, 0),
                ("inn", 1, 1),
                ("tail", 1, 2),
            ],
        );
        let pattern = diff_pair_pattern();
        let matches = find_matches(&pattern, &circuit.top);
        assert!(matches.is_empty());
    }

    #[test]
    fn vf2_same_net_constraint() {
        // Test SameNet edge constraint: current mirror pattern
        // gate-gate same, source-source same, gate-drain same on ref
        let pattern = crate::s2s::recognition::patterns::current_mirror();
        let circuit = build_circuit(
            vec![make_nmos("M1"), make_nmos("M2")],
            &[
                ("bias", 0, 0),
                ("bias", 0, 1),
                ("vss", 0, 2),
                ("out", 1, 0),
                ("bias", 1, 1),
                ("vss", 1, 2),
            ],
        );
        let matches = find_matches(&pattern, &circuit.top);
        // Should find match(es): the diode-connected device maps to node 0
        assert!(!matches.is_empty());
    }

    #[test]
    fn vf2_complementary_constraint() {
        // Push-pull: NMOS + PMOS with same gate and drain nets
        let pattern = crate::s2s::recognition::patterns::push_pull();
        let circuit = build_circuit(
            vec![make_nmos("MN"), make_pmos("MP")],
            &[
                ("out", 0, 0),
                ("vin", 0, 1),
                ("vss", 0, 2),
                ("out", 1, 0),
                ("vin", 1, 1),
                ("vdd", 1, 2),
            ],
        );
        let matches = find_matches(&pattern, &circuit.top);
        assert!(!matches.is_empty());
    }

    #[test]
    fn vf2_no_match_when_types_wrong() {
        // Push-pull expects complementary types; two NMOS should not match.
        let pattern = crate::s2s::recognition::patterns::push_pull();
        let circuit = build_circuit(
            vec![make_nmos("MN"), make_nmos("MP")],
            &[
                ("out", 0, 0),
                ("vin", 0, 1),
                ("vss", 0, 2),
                ("out", 1, 0),
                ("vin", 1, 1),
                ("vss", 1, 2),
            ],
        );
        let matches = find_matches(&pattern, &circuit.top);
        assert!(matches.is_empty());
    }
}
