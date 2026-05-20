#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Axis {
    Vertical,
    Horizontal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    Above,
    Below,
    Left,
    Right,
}

/// A placement constraint -- either hard (must satisfy) or soft (cost term).
#[derive(Debug, Clone)]
pub enum Constraint {
    // Hard constraints
    Symmetry {
        axis: Axis,
        group_a: Vec<u32>,
        group_b: Vec<u32>,
    },
    Alignment {
        instances: Vec<u32>,
        axis: Axis,
    },
    Adjacency {
        a: u32,
        b: u32,
        side: Side,
    },
    Orientation {
        instance: u32,
        rotation: u8,
        flip: bool,
    },
    RailSide {
        net_idx: u32,
        side: Side,
    },
    PortLocation {
        port_idx: u32,
        edge: Side,
    },

    // Soft constraints (with weight)
    Proximity {
        instances: Vec<u32>,
        weight: f64,
    },
    Matching {
        instances: Vec<u32>,
        weight: f64,
    },
    SignalFlow {
        from: u32,
        to: u32,
        weight: f64,
    },
    BlockClustering {
        block_instances: Vec<u32>,
        weight: f64,
    },
}

impl Constraint {
    pub fn is_hard(&self) -> bool {
        matches!(
            self,
            Constraint::Symmetry { .. }
                | Constraint::Alignment { .. }
                | Constraint::Adjacency { .. }
                | Constraint::Orientation { .. }
                | Constraint::RailSide { .. }
                | Constraint::PortLocation { .. }
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hard_constraints_detected() {
        let hard_cases: Vec<Constraint> = vec![
            Constraint::Symmetry {
                axis: Axis::Vertical,
                group_a: vec![0],
                group_b: vec![1],
            },
            Constraint::Alignment {
                instances: vec![0, 1],
                axis: Axis::Horizontal,
            },
            Constraint::Adjacency {
                a: 0,
                b: 1,
                side: Side::Right,
            },
            Constraint::Orientation {
                instance: 0,
                rotation: 0,
                flip: false,
            },
            Constraint::RailSide {
                net_idx: 0,
                side: Side::Above,
            },
            Constraint::PortLocation {
                port_idx: 0,
                edge: Side::Left,
            },
        ];
        for c in &hard_cases {
            assert!(c.is_hard(), "Expected hard: {:?}", c);
        }
    }

    #[test]
    fn soft_constraints_detected() {
        let soft_cases: Vec<Constraint> = vec![
            Constraint::Proximity {
                instances: vec![0, 1],
                weight: 1.0,
            },
            Constraint::Matching {
                instances: vec![0, 1],
                weight: 1.0,
            },
            Constraint::SignalFlow {
                from: 0,
                to: 1,
                weight: 1.0,
            },
            Constraint::BlockClustering {
                block_instances: vec![0, 1],
                weight: 1.0,
            },
        ];
        for c in &soft_cases {
            assert!(!c.is_hard(), "Expected soft: {:?}", c);
        }
    }
}
