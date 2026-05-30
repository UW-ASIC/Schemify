use crate::s2s::ir::{PinDir, Subcircuit};
use crate::s2s::recognition::{Block, BlockType};

use super::constraints::{Axis, Constraint, Side};

/// Generate placement constraints from recognized blocks and circuit structure.
pub fn generate_constraints(subckt: &Subcircuit, blocks: &[Block]) -> Vec<Constraint> {
    let mut constraints = Vec::new();

    for block in blocks {
        generate_block_constraints(block, &mut constraints);
    }

    generate_power_constraints(subckt, &mut constraints);
    generate_port_constraints(subckt, &mut constraints);

    constraints
}

fn generate_block_constraints(block: &Block, constraints: &mut Vec<Constraint>) {
    match block.block_type {
        BlockType::DiffPair => {
            let inst0 = block.instance_indices[0];
            let inst1 = block.instance_indices[1];
            constraints.push(Constraint::Symmetry {
                axis: Axis::Vertical,
                group_a: vec![inst0],
                group_b: vec![inst1],
            });
            constraints.push(Constraint::Matching {
                instances: vec![inst0, inst1],
                weight: 1.0,
            });
            constraints.push(Constraint::Orientation {
                instance: inst0,
                rotation: 0,
                flip: false,
            });
            constraints.push(Constraint::Orientation {
                instance: inst1,
                rotation: 0,
                flip: true,
            });
        }
        BlockType::CurrentMirror => {
            let inst0 = block.instance_indices[0];
            let inst1 = block.instance_indices[1];
            constraints.push(Constraint::Alignment {
                instances: vec![inst0, inst1],
                axis: Axis::Horizontal,
            });
            constraints.push(Constraint::Matching {
                instances: vec![inst0, inst1],
                weight: 1.0,
            });
            constraints.push(Constraint::Adjacency {
                a: inst0,
                b: inst1,
                side: Side::Right,
            });
        }
        BlockType::Cascode => {
            let bottom = block.instance_indices[0];
            let top = block.instance_indices[1];
            constraints.push(Constraint::Adjacency {
                a: bottom,
                b: top,
                side: Side::Above,
            });
            constraints.push(Constraint::Alignment {
                instances: vec![bottom, top],
                axis: Axis::Vertical,
            });
        }
        BlockType::PushPull => {
            let pmos = block.instance_indices[0];
            let nmos = block.instance_indices[1];
            constraints.push(Constraint::Adjacency {
                a: pmos,
                b: nmos,
                side: Side::Above,
            });
            constraints.push(Constraint::Symmetry {
                axis: Axis::Horizontal,
                group_a: vec![pmos],
                group_b: vec![nmos],
            });
        }
        _ => {
            // For unhandled block types, emit a clustering soft constraint.
            if !block.instance_indices.is_empty() {
                constraints.push(Constraint::BlockClustering {
                    block_instances: block.instance_indices.clone(),
                    weight: 0.5,
                });
            }
        }
    }
}

/// Detect power/ground nets by name and global flag, emit RailSide constraints.
fn generate_power_constraints(subckt: &Subcircuit, constraints: &mut Vec<Constraint>) {
    for (idx, net) in subckt.nets.iter().enumerate() {
        let name_lower = net.name.to_lowercase();
        if is_power_name(&name_lower) || (net.is_global && is_power_name(&name_lower)) {
            constraints.push(Constraint::RailSide {
                net_idx: idx as u32,
                side: Side::Above,
            });
        } else if is_ground_name(&name_lower) || (net.is_global && is_ground_name(&name_lower)) {
            constraints.push(Constraint::RailSide {
                net_idx: idx as u32,
                side: Side::Below,
            });
        }
    }
}

fn is_power_name(name: &str) -> bool {
    name == "vdd"
        || name == "vcc"
        || name == "vdda"
        || name.starts_with("vdd_")
        || name.starts_with("vcc_")
}

fn is_ground_name(name: &str) -> bool {
    name == "vss"
        || name == "gnd"
        || name == "0"
        || name == "vssa"
        || name.starts_with("vss_")
        || name.starts_with("gnd_")
}

/// Emit PortLocation constraints based on port directions.
fn generate_port_constraints(subckt: &Subcircuit, constraints: &mut Vec<Constraint>) {
    for (idx, dir) in subckt.port_directions.iter().enumerate() {
        let edge = match dir {
            PinDir::Input => Side::Left,
            PinDir::Output => Side::Right,
            PinDir::Power => Side::Above,
            PinDir::Ground => Side::Below,
            // Inout and Bulk: no strong placement preference, skip.
            PinDir::Inout | PinDir::Bulk => continue,
        };
        constraints.push(Constraint::PortLocation {
            port_idx: idx as u32,
            edge,
        });
    }
}

/// Check for conflicting hard constraints. Returns a list of conflict
/// descriptions (empty means no conflicts).
pub fn check_conflicts(constraints: &[Constraint]) -> Vec<String> {
    let mut conflicts = Vec::new();

    // Collect orientation constraints per instance.
    let mut orientations: std::collections::HashMap<u32, Vec<(u8, bool, usize)>> =
        std::collections::HashMap::new();
    for (i, c) in constraints.iter().enumerate() {
        if let Constraint::Orientation {
            instance,
            rotation,
            flip,
        } = c
        {
            orientations
                .entry(*instance)
                .or_default()
                .push((*rotation, *flip, i));
        }
    }
    for (inst, entries) in &orientations {
        if entries.len() > 1 {
            let first = entries[0];
            for other in &entries[1..] {
                if first.0 != other.0 || first.1 != other.1 {
                    conflicts.push(format!(
                        "Instance {} has conflicting orientation constraints: \
                         constraint #{} (rot={}, flip={}) vs constraint #{} (rot={}, flip={})",
                        inst, first.2, first.0, first.1, other.2, other.0, other.1,
                    ));
                }
            }
        }
    }

    // Collect adjacency constraints per instance pair, check for contradictions.
    // E.g., A above B and A below B at the same time.
    let mut adjacencies: std::collections::HashMap<(u32, u32), Vec<(Side, usize)>> =
        std::collections::HashMap::new();
    for (i, c) in constraints.iter().enumerate() {
        if let Constraint::Adjacency { a, b, side } = c {
            adjacencies.entry((*a, *b)).or_default().push((*side, i));
        }
    }
    for ((a, b), entries) in &adjacencies {
        for i in 0..entries.len() {
            for j in (i + 1)..entries.len() {
                let (side_i, ci) = entries[i];
                let (side_j, cj) = entries[j];
                if sides_conflict(side_i, side_j) {
                    conflicts.push(format!(
                        "Instance {} and {} have conflicting adjacency constraints: \
                         constraint #{} ({:?}) vs constraint #{} ({:?})",
                        a, b, ci, side_i, cj, side_j,
                    ));
                }
            }
        }
    }

    conflicts
}

/// Two sides conflict if they are opposites on the same axis.
fn sides_conflict(a: Side, b: Side) -> bool {
    matches!(
        (a, b),
        (Side::Above, Side::Below)
            | (Side::Below, Side::Above)
            | (Side::Left, Side::Right)
            | (Side::Right, Side::Left)
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::s2s::ir::*;
    use crate::s2s::recognition::{Block, BlockType, PlacementHint};

    fn make_empty_subckt() -> Subcircuit {
        Subcircuit::new("test")
    }

    fn make_diff_pair_block() -> Block {
        Block {
            block_type: BlockType::DiffPair,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::DiffPair),
        }
    }

    fn make_current_mirror_block() -> Block {
        Block {
            block_type: BlockType::CurrentMirror,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::CurrentMirror),
        }
    }

    fn make_cascode_block() -> Block {
        Block {
            block_type: BlockType::Cascode,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::Cascode),
        }
    }

    #[test]
    fn diff_pair_produces_symmetry_matching_orientation() {
        let subckt = make_empty_subckt();
        let blocks = vec![make_diff_pair_block()];
        let constraints = generate_constraints(&subckt, &blocks);

        // Should produce: Symmetry, Matching, Orientation(inst0), Orientation(inst1)
        let sym_count = constraints
            .iter()
            .filter(|c| {
                matches!(
                    c,
                    Constraint::Symmetry {
                        axis: Axis::Vertical,
                        ..
                    }
                )
            })
            .count();
        assert_eq!(sym_count, 1);

        let match_count = constraints
            .iter()
            .filter(|c| matches!(c, Constraint::Matching { .. }))
            .count();
        assert_eq!(match_count, 1);

        let orient: Vec<_> = constraints
            .iter()
            .filter_map(|c| {
                if let Constraint::Orientation {
                    instance,
                    rotation,
                    flip,
                } = c
                {
                    Some((*instance, *rotation, *flip))
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(orient.len(), 2);
        assert!(orient.contains(&(0, 0, false)));
        assert!(orient.contains(&(1, 0, true)));
    }

    #[test]
    fn current_mirror_produces_alignment_matching_adjacency() {
        let subckt = make_empty_subckt();
        let blocks = vec![make_current_mirror_block()];
        let constraints = generate_constraints(&subckt, &blocks);

        let align_count = constraints
            .iter()
            .filter(|c| {
                matches!(
                    c,
                    Constraint::Alignment {
                        axis: Axis::Horizontal,
                        ..
                    }
                )
            })
            .count();
        assert_eq!(align_count, 1);

        let match_count = constraints
            .iter()
            .filter(|c| matches!(c, Constraint::Matching { .. }))
            .count();
        assert_eq!(match_count, 1);

        let adj_count = constraints
            .iter()
            .filter(|c| {
                matches!(
                    c,
                    Constraint::Adjacency {
                        side: Side::Right,
                        ..
                    }
                )
            })
            .count();
        assert_eq!(adj_count, 1);
    }

    #[test]
    fn cascode_produces_adjacency_above_and_alignment_vertical() {
        let subckt = make_empty_subckt();
        let blocks = vec![make_cascode_block()];
        let constraints = generate_constraints(&subckt, &blocks);

        let adj_above = constraints.iter().any(|c| {
            matches!(
                c,
                Constraint::Adjacency {
                    a: 0,
                    b: 1,
                    side: Side::Above,
                }
            )
        });
        assert!(adj_above, "Expected Adjacency(0, 1, Above)");

        let align_vert = constraints.iter().any(|c| {
            matches!(
                c,
                Constraint::Alignment {
                    axis: Axis::Vertical,
                    ..
                }
            )
        });
        assert!(align_vert, "Expected Alignment(Vertical)");
    }

    #[test]
    fn power_net_vdd_produces_rail_side_top() {
        let mut subckt = make_empty_subckt();
        subckt.nets.push(Net::new("vdd"));
        let constraints = generate_constraints(&subckt, &[]);

        let rail = constraints.iter().any(|c| {
            matches!(
                c,
                Constraint::RailSide {
                    net_idx: 0,
                    side: Side::Above,
                }
            )
        });
        assert!(rail, "Expected RailSide(0, Above) for vdd");
    }

    #[test]
    fn power_net_vss_produces_rail_side_bottom() {
        let mut subckt = make_empty_subckt();
        subckt.nets.push(Net::new("vss"));
        let constraints = generate_constraints(&subckt, &[]);

        let rail = constraints.iter().any(|c| {
            matches!(
                c,
                Constraint::RailSide {
                    net_idx: 0,
                    side: Side::Below,
                }
            )
        });
        assert!(rail, "Expected RailSide(0, Below) for vss");
    }

    #[test]
    fn power_net_gnd_produces_rail_side_bottom() {
        let mut subckt = make_empty_subckt();
        subckt.nets.push(Net::new("GND"));
        let constraints = generate_constraints(&subckt, &[]);

        let rail = constraints.iter().any(|c| {
            matches!(
                c,
                Constraint::RailSide {
                    net_idx: 0,
                    side: Side::Below,
                }
            )
        });
        assert!(rail, "Expected RailSide(0, Below) for GND");
    }

    #[test]
    fn input_port_produces_port_location_left() {
        let mut subckt = make_empty_subckt();
        subckt.ports.push("inp".to_string());
        subckt.port_directions.push(PinDir::Input);
        let constraints = generate_constraints(&subckt, &[]);

        let port = constraints.iter().any(|c| {
            matches!(
                c,
                Constraint::PortLocation {
                    port_idx: 0,
                    edge: Side::Left,
                }
            )
        });
        assert!(port, "Expected PortLocation(0, Left) for input port");
    }

    #[test]
    fn output_port_produces_port_location_right() {
        let mut subckt = make_empty_subckt();
        subckt.ports.push("out".to_string());
        subckt.port_directions.push(PinDir::Output);
        let constraints = generate_constraints(&subckt, &[]);

        let port = constraints.iter().any(|c| {
            matches!(
                c,
                Constraint::PortLocation {
                    port_idx: 0,
                    edge: Side::Right,
                }
            )
        });
        assert!(port, "Expected PortLocation(0, Right) for output port");
    }

    #[test]
    fn conflicting_orientations_detected() {
        let constraints = vec![
            Constraint::Orientation {
                instance: 0,
                rotation: 0,
                flip: false,
            },
            Constraint::Orientation {
                instance: 0,
                rotation: 0,
                flip: true,
            },
        ];
        let conflicts = check_conflicts(&constraints);
        assert_eq!(conflicts.len(), 1);
        assert!(
            conflicts[0].contains("Instance 0"),
            "Conflict message should mention instance: {}",
            conflicts[0],
        );
    }

    #[test]
    fn no_conflicts_when_orientations_agree() {
        let constraints = vec![
            Constraint::Orientation {
                instance: 0,
                rotation: 0,
                flip: false,
            },
            Constraint::Orientation {
                instance: 1,
                rotation: 0,
                flip: true,
            },
        ];
        let conflicts = check_conflicts(&constraints);
        assert!(conflicts.is_empty());
    }

    #[test]
    fn conflicting_adjacencies_detected() {
        let constraints = vec![
            Constraint::Adjacency {
                a: 0,
                b: 1,
                side: Side::Above,
            },
            Constraint::Adjacency {
                a: 0,
                b: 1,
                side: Side::Below,
            },
        ];
        let conflicts = check_conflicts(&constraints);
        assert_eq!(conflicts.len(), 1);
    }

    #[test]
    fn empty_blocks_only_power_port_constraints() {
        let mut subckt = make_empty_subckt();
        subckt.nets.push(Net::new("vdd"));
        subckt.nets.push(Net::new("vss"));
        subckt.ports.push("inp".to_string());
        subckt.port_directions.push(PinDir::Input);

        let constraints = generate_constraints(&subckt, &[]);

        // Should have 2 rail constraints + 1 port constraint, no block constraints.
        assert_eq!(constraints.len(), 3);
        assert!(constraints.iter().all(|c| matches!(
            c,
            Constraint::RailSide { .. } | Constraint::PortLocation { .. }
        )));
    }

    #[test]
    fn no_duplicate_constraints_for_single_block() {
        let subckt = make_empty_subckt();
        let blocks = vec![make_diff_pair_block()];
        let constraints = generate_constraints(&subckt, &blocks);

        // Count Symmetry constraints -- should be exactly 1.
        let sym_count = constraints
            .iter()
            .filter(|c| matches!(c, Constraint::Symmetry { .. }))
            .count();
        assert_eq!(sym_count, 1);

        // Count Matching constraints -- should be exactly 1.
        let match_count = constraints
            .iter()
            .filter(|c| matches!(c, Constraint::Matching { .. }))
            .count();
        assert_eq!(match_count, 1);

        // Count Orientation constraints -- should be exactly 2 (one per instance).
        let orient_count = constraints
            .iter()
            .filter(|c| matches!(c, Constraint::Orientation { .. }))
            .count();
        assert_eq!(orient_count, 2);
    }
}
