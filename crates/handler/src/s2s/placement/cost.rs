//! Placement cost function for simulated annealing.
//!
//! Four-term weighted sum: hard constraint violations, HPWL, signal flow, aspect ratio.

use std::collections::HashMap;

use super::constraints::{Axis, Constraint, Side};
use super::PlacementItem;
use crate::s2s::ir::Subcircuit;

/// Weights for the SA cost function.
const W_HARD: f64 = 1e6;
const W_HPWL: f64 = 1.0;
const W_SIGNAL_FLOW: f64 = 50.0;
const W_ASPECT_RATIO: f64 = 100.0;

/// State vector for simulated annealing placement.
#[derive(Debug, Clone)]
pub struct PlacementState {
    pub positions: Vec<(i32, i32)>,
    pub orientations: Vec<(u8, bool)>,
    pub widths: Vec<i32>,
    pub heights: Vec<i32>,
}

impl PlacementState {
    pub fn new(n: usize, grid_size: i32) -> Self {
        Self {
            positions: vec![(0, 0); n],
            orientations: vec![(0, false); n],
            widths: vec![grid_size; n],
            heights: vec![grid_size; n],
        }
    }

    /// Snap all coordinates to 10-unit grid.
    pub fn snap_to_grid(&mut self) {
        for pos in &mut self.positions {
            pos.0 = snap(pos.0);
            pos.1 = snap(pos.1);
        }
    }
}

/// Snap a coordinate to the nearest 10-unit grid.
pub fn snap(v: i32) -> i32 {
    ((v + 5) / 10) * 10
}

/// Compute total cost of a placement state.
pub(crate) fn compute_cost(
    state: &PlacementState,
    items: &[PlacementItem],
    subckt: &Subcircuit,
    constraints: &[Constraint],
) -> f64 {
    let hard_violations = count_hard_violations(state, items, constraints) as f64;
    let hpwl = compute_hpwl(state, items, subckt);
    let flow_cost = compute_signal_flow_cost(state, items, constraints);
    let aspect = compute_aspect_ratio_penalty(state);

    W_HARD * hard_violations + W_HPWL * hpwl + W_SIGNAL_FLOW * flow_cost + W_ASPECT_RATIO * aspect
}

/// Count hard constraint violations.
fn count_hard_violations(
    state: &PlacementState,
    items: &[PlacementItem],
    constraints: &[Constraint],
) -> usize {
    let mut violations = 0;
    let inst_to_item = build_inst_to_item(items);

    for constraint in constraints {
        match constraint {
            Constraint::Symmetry {
                axis,
                group_a,
                group_b,
            } => {
                if let (Some(&a), Some(&b)) = (group_a.first(), group_b.first()) {
                    if let (Some(&item_a), Some(&item_b)) =
                        (inst_to_item.get(&a), inst_to_item.get(&b))
                    {
                        let (xa, ya) = state.positions[item_a];
                        let (xb, yb) = state.positions[item_b];
                        match axis {
                            Axis::Vertical => {
                                if ya != yb {
                                    violations += 1;
                                }
                            }
                            Axis::Horizontal => {
                                if xa != xb {
                                    violations += 1;
                                }
                            }
                        }
                    }
                }
            }
            Constraint::Alignment { instances, axis } => {
                if instances.len() >= 2 {
                    let coords: Vec<(i32, i32)> = instances
                        .iter()
                        .filter_map(|idx| inst_to_item.get(idx).map(|&i| state.positions[i]))
                        .collect();
                    if coords.len() >= 2 {
                        match axis {
                            Axis::Horizontal => {
                                let y0 = coords[0].1;
                                if coords.iter().any(|c| c.1 != y0) {
                                    violations += 1;
                                }
                            }
                            Axis::Vertical => {
                                let x0 = coords[0].0;
                                if coords.iter().any(|c| c.0 != x0) {
                                    violations += 1;
                                }
                            }
                        }
                    }
                }
            }
            Constraint::Adjacency { a, b, side } => {
                if let (Some(&item_a), Some(&item_b)) = (inst_to_item.get(a), inst_to_item.get(b)) {
                    let (xa, ya) = state.positions[item_a];
                    let (xb, yb) = state.positions[item_b];
                    let ok = match side {
                        Side::Above => yb < ya,
                        Side::Below => yb > ya,
                        Side::Left => xb < xa,
                        Side::Right => xb > xa,
                    };
                    if !ok {
                        violations += 1;
                    }
                }
            }
            Constraint::Orientation {
                instance,
                rotation,
                flip,
            } => {
                if let Some(&item_idx) = inst_to_item.get(instance) {
                    let (r, f) = state.orientations[item_idx];
                    if r != *rotation || f != *flip {
                        violations += 1;
                    }
                }
            }
            _ => {}
        }
    }

    violations += count_overlaps(state);
    violations
}

/// Check for overlapping bounding boxes between placed items.
fn count_overlaps(state: &PlacementState) -> usize {
    let n = state.positions.len();
    let mut overlaps = 0;
    for i in 0..n {
        let (xi, yi) = state.positions[i];
        let wi = state.widths[i];
        let hi = state.heights[i];
        for j in (i + 1)..n {
            let (xj, yj) = state.positions[j];
            let wj = state.widths[j];
            let hj = state.heights[j];
            let x_overlap = xi < xj + wj && xj < xi + wi;
            let y_overlap = yi < yj + hj && yj < yi + hi;
            if x_overlap && y_overlap {
                overlaps += 1;
            }
        }
    }
    overlaps
}

/// Compute total half-perimeter wirelength (HPWL) for all nets.
fn compute_hpwl(state: &PlacementState, items: &[PlacementItem], subckt: &Subcircuit) -> f64 {
    let inst_to_item = build_inst_to_item(items);
    let mut total_hpwl: f64 = 0.0;

    for net in &subckt.nets {
        if net.pins.is_empty() {
            continue;
        }
        let mut min_x = i32::MAX;
        let mut max_x = i32::MIN;
        let mut min_y = i32::MAX;
        let mut max_y = i32::MIN;
        let mut found = false;

        for pin_ref in &net.pins {
            if let Some(&item_idx) = inst_to_item.get(&pin_ref.instance_idx) {
                let (bx, by) = state.positions[item_idx];
                let px = bx + state.widths[item_idx] / 2;
                let py = by + state.heights[item_idx] / 2;
                min_x = min_x.min(px);
                max_x = max_x.max(px);
                min_y = min_y.min(py);
                max_y = max_y.max(py);
                found = true;
            }
        }

        if found {
            total_hpwl += (max_x - min_x + max_y - min_y) as f64;
        }
    }

    total_hpwl
}

/// Compute signal-flow backward-edge cost.
fn compute_signal_flow_cost(
    state: &PlacementState,
    items: &[PlacementItem],
    constraints: &[Constraint],
) -> f64 {
    let inst_to_item = build_inst_to_item(items);
    let mut cost = 0.0;

    for constraint in constraints {
        if let Constraint::SignalFlow { from, to, weight } = constraint {
            if let (Some(&item_from), Some(&item_to)) =
                (inst_to_item.get(from), inst_to_item.get(to))
            {
                let x_from = state.positions[item_from].0;
                let x_to = state.positions[item_to].0;
                if x_to < x_from {
                    cost += (x_from - x_to) as f64 * weight;
                }
            }
        }
    }

    cost
}

/// Compute bounding box aspect ratio penalty.
fn compute_aspect_ratio_penalty(state: &PlacementState) -> f64 {
    if state.positions.is_empty() {
        return 0.0;
    }

    let mut min_x = i32::MAX;
    let mut max_x = i32::MIN;
    let mut min_y = i32::MAX;
    let mut max_y = i32::MIN;

    for (i, &(x, y)) in state.positions.iter().enumerate() {
        min_x = min_x.min(x);
        max_x = max_x.max(x + state.widths[i]);
        min_y = min_y.min(y);
        max_y = max_y.max(y + state.heights[i]);
    }

    let w = (max_x - min_x).max(1) as f64;
    let h = (max_y - min_y).max(1) as f64;
    let ratio = w / h;
    (ratio - 1.5).abs()
}

/// Build a map from instance index to item index.
pub(crate) fn build_inst_to_item(items: &[PlacementItem]) -> HashMap<u32, usize> {
    let mut map = HashMap::new();
    for (item_idx, item) in items.iter().enumerate() {
        for &inst_idx in &item.instance_indices {
            map.insert(inst_idx, item_idx);
        }
    }
    map
}
