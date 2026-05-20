pub mod constraint_gen;
pub mod constraints;

use crate::s2s::ir::{Primitive, Subcircuit};
use crate::s2s::output::Backend;
use crate::s2s::recognition::{Block, BlockType, PlacementHint};

use std::collections::{HashMap, HashSet};

use self::constraint_gen::generate_constraints;
use self::constraints::{Axis, Constraint, Side};

const GRID_SIZE: i32 = 200;
const MAX_COLS: i32 = 4;

/// SA threshold: circuits with more than this many items use simulated annealing.
const SA_THRESHOLD: usize = 10;

// --------------------------------------------------------------------------
// XorShift64 PRNG (deterministic, no external deps)
// --------------------------------------------------------------------------

struct Xorshift64 {
    state: u64,
}

impl Xorshift64 {
    fn new(seed: u64) -> Self {
        // Ensure non-zero seed
        Self { state: if seed == 0 { 1 } else { seed } }
    }

    fn next_u64(&mut self) -> u64 {
        let mut x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        x
    }

    /// Uniform random in [0, bound)
    fn next_usize(&mut self, bound: usize) -> usize {
        if bound == 0 {
            return 0;
        }
        (self.next_u64() % bound as u64) as usize
    }

    /// Uniform random f64 in [0, 1)
    fn next_f64(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }
}

// --------------------------------------------------------------------------
// PlacementState for simulated annealing
// --------------------------------------------------------------------------

/// An item in the placement: either a recognized block or a single loose device.
#[derive(Debug, Clone)]
struct PlacementItem {
    /// Instance indices belonging to this item.
    instance_indices: Vec<u32>,
    /// Block type if recognized, None for loose devices.
    block_type: Option<BlockType>,
    /// Original block reference index (into blocks slice), if any.
    block_ref: Option<usize>,
}

/// State vector for simulated annealing placement.
#[derive(Debug, Clone)]
pub struct PlacementState {
    pub positions: Vec<(i32, i32)>,
    pub orientations: Vec<(u8, bool)>,  // (rotation, flip) per item
    pub widths: Vec<i32>,
    pub heights: Vec<i32>,
}

impl PlacementState {
    fn new(n: usize) -> Self {
        Self {
            positions: vec![(0, 0); n],
            orientations: vec![(0, false); n],
            widths: vec![GRID_SIZE; n],
            heights: vec![GRID_SIZE; n],
        }
    }

    /// Snap all coordinates to 10-unit grid.
    fn snap_to_grid(&mut self) {
        for pos in &mut self.positions {
            pos.0 = snap(pos.0);
            pos.1 = snap(pos.1);
        }
    }
}

/// Snap a coordinate to the nearest 10-unit grid.
fn snap(v: i32) -> i32 {
    ((v + 5) / 10) * 10
}

// --------------------------------------------------------------------------
// Cost function
// --------------------------------------------------------------------------

/// Weights for the SA cost function.
const W_HARD: f64 = 1e6;
const W_HPWL: f64 = 1.0;
const W_SIGNAL_FLOW: f64 = 50.0;
const W_ASPECT_RATIO: f64 = 100.0;

/// Compute total cost of a placement state.
fn compute_cost(
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

    // Build instance-to-item lookup
    let inst_to_item = build_inst_to_item(items);

    for constraint in constraints {
        match constraint {
            Constraint::Symmetry { axis, group_a, group_b } => {
                // For vertical symmetry: items in group_a and group_b should be
                // symmetric about some vertical axis.
                if let (Some(&a), Some(&b)) = (group_a.first(), group_b.first()) {
                    if let (Some(&item_a), Some(&item_b)) = (
                        inst_to_item.get(&a),
                        inst_to_item.get(&b),
                    ) {
                        let (xa, ya) = state.positions[item_a];
                        let (xb, yb) = state.positions[item_b];
                        match axis {
                            Axis::Vertical => {
                                // y should be equal
                                if ya != yb {
                                    violations += 1;
                                }
                            }
                            Axis::Horizontal => {
                                // x should be equal
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
                if let (Some(&item_a), Some(&item_b)) = (
                    inst_to_item.get(a),
                    inst_to_item.get(b),
                ) {
                    let (xa, ya) = state.positions[item_a];
                    let (xb, yb) = state.positions[item_b];
                    let ok = match side {
                        Side::Above => yb < ya,  // b should be above a (lower y)
                        Side::Below => yb > ya,
                        Side::Left => xb < xa,
                        Side::Right => xb > xa,
                    };
                    if !ok {
                        violations += 1;
                    }
                }
            }
            Constraint::Orientation { instance, rotation, flip } => {
                if let Some(&item_idx) = inst_to_item.get(instance) {
                    let (r, f) = state.orientations[item_idx];
                    if r != *rotation || f != *flip {
                        violations += 1;
                    }
                }
            }
            _ => {} // RailSide, PortLocation handled separately
        }
    }

    // Check overlap between items
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
            // Check AABB overlap
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
fn compute_hpwl(
    state: &PlacementState,
    items: &[PlacementItem],
    subckt: &Subcircuit,
) -> f64 {
    // Build instance-to-item lookup
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
                // Approximate pin position as block center + rough offset
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
            if let (Some(&item_from), Some(&item_to)) = (
                inst_to_item.get(from),
                inst_to_item.get(to),
            ) {
                let x_from = state.positions[item_from].0;
                let x_to = state.positions[item_to].0;
                // Signal should flow left-to-right: penalize backward edges
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

    // Ideal aspect ratio is ~1.5 (landscape). Penalize deviation.
    let ideal = 1.5;
    (ratio - ideal).abs()
}

/// Build a map from instance index to item index.
fn build_inst_to_item(items: &[PlacementItem]) -> std::collections::HashMap<u32, usize> {
    let mut map = std::collections::HashMap::new();
    for (item_idx, item) in items.iter().enumerate() {
        for &inst_idx in &item.instance_indices {
            map.insert(inst_idx, item_idx);
        }
    }
    map
}

// --------------------------------------------------------------------------
// Simulated Annealing
// --------------------------------------------------------------------------

/// Move operators for SA.
#[derive(Debug, Clone, Copy)]
enum MoveOp {
    Swap(usize, usize),
    Translate(usize, i32, i32),
    Rotate(usize),
    Flip(usize),
}

/// Run simulated annealing on the placement state.
fn simulated_annealing(
    state: &mut PlacementState,
    items: &[PlacementItem],
    subckt: &Subcircuit,
    constraints: &[Constraint],
    seed: u64,
) {
    let n = state.positions.len();
    if n == 0 {
        return;
    }

    let mut rng = Xorshift64::new(seed);

    // Initial random placement on grid for SA
    for i in 0..n {
        let cols = (n as f64).sqrt().ceil() as i32;
        let row = (i as i32) / cols;
        let col = (i as i32) % cols;
        state.positions[i] = (col * GRID_SIZE, row * GRID_SIZE);
    }
    state.snap_to_grid();

    let mut current_cost = compute_cost(state, items, subckt, constraints);

    // Calibrate initial temperature: sample 100 random moves, compute avg cost delta
    let calibration_moves = 100.min(n * n);
    let mut total_delta: f64 = 0.0;
    let mut num_deltas = 0;
    for _ in 0..calibration_moves {
        let op = random_move(n, &mut rng, constraints, items);
        let saved = save_state(state, &op);
        apply_move(state, &op);
        state.snap_to_grid();
        let new_cost = compute_cost(state, items, subckt, constraints);
        let delta = new_cost - current_cost;
        if delta > 0.0 {
            total_delta += delta;
            num_deltas += 1;
        }
        restore_state(state, &op, saved);
    }

    let avg_delta = if num_deltas > 0 {
        total_delta / num_deltas as f64
    } else {
        1.0
    };
    // Set T0 so acceptance prob for avg_delta is ~80%: exp(-avg_delta / T0) = 0.8
    let t0 = if avg_delta > 0.0 {
        -avg_delta / (0.8_f64).ln()
    } else {
        1.0
    };

    let max_iters = (50 * n * n).min(100_000);
    let alpha = 0.995_f64;
    let t_min = 0.01_f64;

    let mut t = t0;
    let mut best_state = state.clone();
    let mut best_cost = current_cost;
    let mut non_improving = 0_usize;

    for _ in 0..max_iters {
        if t < t_min || non_improving >= 1000 {
            break;
        }

        let op = random_move(n, &mut rng, constraints, items);
        let saved = save_state(state, &op);
        apply_move(state, &op);
        state.snap_to_grid();

        let new_cost = compute_cost(state, items, subckt, constraints);
        let delta = new_cost - current_cost;

        if delta < 0.0 || rng.next_f64() < (-delta / t).exp() {
            // Accept
            current_cost = new_cost;
            if current_cost < best_cost {
                best_cost = current_cost;
                best_state = state.clone();
                non_improving = 0;
            } else {
                non_improving += 1;
            }
        } else {
            // Reject
            restore_state(state, &op, saved);
            non_improving += 1;
        }

        t *= alpha;
    }

    // Restore best state found
    *state = best_state;
}

/// Generate a random move.
fn random_move(
    n: usize,
    rng: &mut Xorshift64,
    _constraints: &[Constraint],
    _items: &[PlacementItem],
) -> MoveOp {
    let op_type = rng.next_usize(4);
    match op_type {
        0 => {
            // Swap two items
            let a = rng.next_usize(n);
            let mut b = rng.next_usize(n);
            if n > 1 {
                while b == a {
                    b = rng.next_usize(n);
                }
            }
            MoveOp::Swap(a, b)
        }
        1 => {
            // Translate one item by +/- GRID_SIZE
            let idx = rng.next_usize(n);
            let dir = rng.next_usize(4);
            let (dx, dy) = match dir {
                0 => (GRID_SIZE, 0),
                1 => (-GRID_SIZE, 0),
                2 => (0, GRID_SIZE),
                _ => (0, -GRID_SIZE),
            };
            MoveOp::Translate(idx, dx, dy)
        }
        2 => {
            // Rotate
            let idx = rng.next_usize(n);
            MoveOp::Rotate(idx)
        }
        _ => {
            // Flip
            let idx = rng.next_usize(n);
            MoveOp::Flip(idx)
        }
    }
}

/// Saved state for undo.
#[derive(Debug)]
enum SavedState {
    Swap,
    Translate(i32, i32),  // original position
    Rotate(u8),           // original rotation
    Flip(bool),           // original flip
}

fn save_state(state: &PlacementState, op: &MoveOp) -> SavedState {
    match *op {
        MoveOp::Swap(_, _) => SavedState::Swap,
        MoveOp::Translate(idx, _, _) => {
            let (x, y) = state.positions[idx];
            SavedState::Translate(x, y)
        }
        MoveOp::Rotate(idx) => SavedState::Rotate(state.orientations[idx].0),
        MoveOp::Flip(idx) => SavedState::Flip(state.orientations[idx].1),
    }
}

fn apply_move(state: &mut PlacementState, op: &MoveOp) {
    match *op {
        MoveOp::Swap(a, b) => {
            state.positions.swap(a, b);
            state.orientations.swap(a, b);
            state.widths.swap(a, b);
            state.heights.swap(a, b);
        }
        MoveOp::Translate(idx, dx, dy) => {
            state.positions[idx].0 += dx;
            state.positions[idx].1 += dy;
        }
        MoveOp::Rotate(idx) => {
            state.orientations[idx].0 = (state.orientations[idx].0 + 1) % 4;
        }
        MoveOp::Flip(idx) => {
            state.orientations[idx].1 = !state.orientations[idx].1;
        }
    }
}

fn restore_state(state: &mut PlacementState, op: &MoveOp, saved: SavedState) {
    match (op, saved) {
        (MoveOp::Swap(a, b), SavedState::Swap) => {
            state.positions.swap(*a, *b);
            state.orientations.swap(*a, *b);
            state.widths.swap(*a, *b);
            state.heights.swap(*a, *b);
        }
        (MoveOp::Translate(idx, _, _), SavedState::Translate(x, y)) => {
            state.positions[*idx] = (x, y);
        }
        (MoveOp::Rotate(idx), SavedState::Rotate(r)) => {
            state.orientations[*idx].0 = r;
        }
        (MoveOp::Flip(idx), SavedState::Flip(f)) => {
            state.orientations[*idx].1 = f;
        }
        _ => unreachable!(),
    }
}

// --------------------------------------------------------------------------
// Template functions
// --------------------------------------------------------------------------

/// Compute block bounding box width for a given block type.
fn block_width(block_type: BlockType) -> i32 {
    let hint = PlacementHint::for_type(block_type);
    if hint.h_spacing > 0 {
        hint.h_spacing
    } else if hint.v_spacing > 0 {
        // Vertical-only blocks: width is half the vertical spacing (single column)
        hint.v_spacing / 2
    } else {
        GRID_SIZE
    }
}

/// Compute block bounding box height for a given block type.
fn block_height(block_type: BlockType) -> i32 {
    let hint = PlacementHint::for_type(block_type);
    if hint.v_spacing > 0 && hint.h_spacing > 0 {
        // 2D blocks like cascode mirror: total height is 2x v_spacing
        2 * hint.v_spacing
    } else if hint.v_spacing > 0 {
        hint.v_spacing
    } else if hint.h_spacing > 0 {
        // Horizontal-only blocks: height is half the horizontal spacing
        hint.h_spacing / 2
    } else {
        GRID_SIZE
    }
}

/// Place a differential pair.
///
/// M1: flip=true (gate faces right/center),
/// M2: flip=false (gate faces left/center).
/// Symmetric about vertical axis between them.
fn place_diff_pair(subckt: &mut Subcircuit, block: &Block, origin_x: i32, origin_y: i32) -> i32 {
    let idx0 = block.instance_indices[0] as usize;
    let idx1 = block.instance_indices[1] as usize;

    // M1 on left, flipped so gate faces center
    subckt.instances[idx0].x = origin_x;
    subckt.instances[idx0].y = origin_y;
    subckt.instances[idx0].flip = true;
    subckt.instances[idx0].rotation = 0;

    // M2 on right, normal orientation (gate faces center)
    subckt.instances[idx1].x = origin_x + block.hint.h_spacing;
    subckt.instances[idx1].y = origin_y;
    subckt.instances[idx1].flip = false;
    subckt.instances[idx1].rotation = 0;

    block.hint.h_spacing
}

/// Place a current mirror.
/// Reference (diode-connected) on left, mirror copy on right.
fn place_current_mirror(
    subckt: &mut Subcircuit,
    block: &Block,
    origin_x: i32,
    origin_y: i32,
) -> i32 {
    let ref_idx = block.instance_indices[0] as usize;
    let mir_idx = block.instance_indices[1] as usize;

    // Reference on left, flipped
    subckt.instances[ref_idx].x = origin_x;
    subckt.instances[ref_idx].y = origin_y;
    subckt.instances[ref_idx].flip = true;
    subckt.instances[ref_idx].rotation = 0;

    // Mirror copy on right, normal
    subckt.instances[mir_idx].x = origin_x + block.hint.h_spacing;
    subckt.instances[mir_idx].y = origin_y;
    subckt.instances[mir_idx].flip = false;
    subckt.instances[mir_idx].rotation = 0;

    block.hint.h_spacing
}

/// Place a cascode stack (vertical: bottom at +v_spacing/2, top at -v_spacing/2).
fn place_cascode(subckt: &mut Subcircuit, block: &Block, origin_x: i32, origin_y: i32) -> i32 {
    let bot_idx = block.instance_indices[0] as usize;
    let top_idx = block.instance_indices[1] as usize;

    subckt.instances[bot_idx].x = origin_x;
    subckt.instances[bot_idx].y = origin_y + block.hint.v_spacing / 2;
    subckt.instances[bot_idx].rotation = 0;
    subckt.instances[bot_idx].flip = false;

    subckt.instances[top_idx].x = origin_x;
    subckt.instances[top_idx].y = origin_y - block.hint.v_spacing / 2;
    subckt.instances[top_idx].rotation = 0;
    subckt.instances[top_idx].flip = false;

    block.hint.v_spacing / 2 // narrow width, single column
}

/// Place a cascode mirror (4 devices: 2x2 grid, bottom pair is mirror, top pair is mirror).
///
/// Layout (looking at the schematic):
///   MT_ref (top-left)    MT_mir (top-right)     <- top mirror pair
///   MB_ref (bot-left)    MB_mir (bot-right)     <- bottom mirror pair
fn place_cascode_mirror(
    subckt: &mut Subcircuit,
    block: &Block,
    origin_x: i32,
    origin_y: i32,
) -> i32 {
    if block.instance_indices.len() < 4 {
        return GRID_SIZE;
    }
    // Indices: [MB_ref, MB_mir, MT_ref, MT_mir] as produced by recognition
    let mb_ref = block.instance_indices[0] as usize;
    let mb_mir = block.instance_indices[1] as usize;
    let mt_ref = block.instance_indices[2] as usize;
    let mt_mir = block.instance_indices[3] as usize;

    // Bottom pair
    subckt.instances[mb_ref].x = origin_x;
    subckt.instances[mb_ref].y = origin_y + block.hint.v_spacing / 2;
    subckt.instances[mb_ref].flip = true;
    subckt.instances[mb_ref].rotation = 0;

    subckt.instances[mb_mir].x = origin_x + block.hint.h_spacing;
    subckt.instances[mb_mir].y = origin_y + block.hint.v_spacing / 2;
    subckt.instances[mb_mir].flip = false;
    subckt.instances[mb_mir].rotation = 0;

    // Top pair
    subckt.instances[mt_ref].x = origin_x;
    subckt.instances[mt_ref].y = origin_y - block.hint.v_spacing / 2;
    subckt.instances[mt_ref].flip = true;
    subckt.instances[mt_ref].rotation = 0;

    subckt.instances[mt_mir].x = origin_x + block.hint.h_spacing;
    subckt.instances[mt_mir].y = origin_y - block.hint.v_spacing / 2;
    subckt.instances[mt_mir].flip = false;
    subckt.instances[mt_mir].rotation = 0;

    block.hint.h_spacing
}

/// Place a push-pull pair (PMOS on top, NMOS on bottom).
fn place_push_pull(
    subckt: &mut Subcircuit,
    block: &Block,
    origin_x: i32,
    origin_y: i32,
) -> i32 {
    if block.instance_indices.len() < 2 {
        return GRID_SIZE;
    }
    let idx0 = block.instance_indices[0] as usize;
    let idx1 = block.instance_indices[1] as usize;

    // Determine which is PMOS and which is NMOS
    let (pmos_idx, nmos_idx) = if subckt.instances[idx0].primitive == Primitive::Pmos {
        (idx0, idx1)
    } else {
        (idx1, idx0)
    };

    // PMOS on top (negative y)
    subckt.instances[pmos_idx].x = origin_x;
    subckt.instances[pmos_idx].y = origin_y - block.hint.v_spacing / 2;
    subckt.instances[pmos_idx].rotation = 0;
    subckt.instances[pmos_idx].flip = false;

    // NMOS on bottom (positive y)
    subckt.instances[nmos_idx].x = origin_x;
    subckt.instances[nmos_idx].y = origin_y + block.hint.v_spacing / 2;
    subckt.instances[nmos_idx].rotation = 0;
    subckt.instances[nmos_idx].flip = false;

    block.hint.v_spacing / 2
}

/// Place a common-source stage: MOSFET at origin, load resistor above.
fn place_common_source(
    subckt: &mut Subcircuit,
    block: &Block,
    origin_x: i32,
    origin_y: i32,
) -> i32 {
    if block.instance_indices.len() < 2 {
        return GRID_SIZE;
    }
    let idx0 = block.instance_indices[0] as usize;
    let idx1 = block.instance_indices[1] as usize;

    // Determine which is MOSFET and which is resistor
    let (mos_idx, res_idx) = if subckt.instances[idx0].primitive.is_mosfet() {
        (idx0, idx1)
    } else {
        (idx1, idx0)
    };

    // MOSFET at origin
    subckt.instances[mos_idx].x = origin_x;
    subckt.instances[mos_idx].y = origin_y;
    subckt.instances[mos_idx].rotation = 0;
    subckt.instances[mos_idx].flip = false;

    // Load resistor above (negative y), oriented vertically
    subckt.instances[res_idx].x = origin_x;
    subckt.instances[res_idx].y = origin_y - block.hint.v_spacing;
    subckt.instances[res_idx].rotation = 0;
    subckt.instances[res_idx].flip = false;

    GRID_SIZE
}

/// Place a source follower: MOSFET at origin, current source below.
fn place_source_follower(
    subckt: &mut Subcircuit,
    block: &Block,
    origin_x: i32,
    origin_y: i32,
) -> i32 {
    if block.instance_indices.len() < 2 {
        return GRID_SIZE;
    }
    let idx0 = block.instance_indices[0] as usize;
    let idx1 = block.instance_indices[1] as usize;

    // Determine which is MOSFET and which is current source
    let (mos_idx, isrc_idx) = if subckt.instances[idx0].primitive.is_mosfet() {
        (idx0, idx1)
    } else {
        (idx1, idx0)
    };

    // MOSFET at origin
    subckt.instances[mos_idx].x = origin_x;
    subckt.instances[mos_idx].y = origin_y;
    subckt.instances[mos_idx].rotation = 0;
    subckt.instances[mos_idx].flip = false;

    // Current source below (positive y)
    subckt.instances[isrc_idx].x = origin_x;
    subckt.instances[isrc_idx].y = origin_y + block.hint.v_spacing;
    subckt.instances[isrc_idx].rotation = 0;
    subckt.instances[isrc_idx].flip = false;

    GRID_SIZE
}

/// Place RC compensation: R at origin, C to the right.
fn place_rc_compensation(
    subckt: &mut Subcircuit,
    block: &Block,
    origin_x: i32,
    origin_y: i32,
) -> i32 {
    if block.instance_indices.len() < 2 {
        return GRID_SIZE;
    }
    let idx0 = block.instance_indices[0] as usize;
    let idx1 = block.instance_indices[1] as usize;

    // Determine which is R and which is C
    let (r_idx, c_idx) = if subckt.instances[idx0].primitive == Primitive::Resistor {
        (idx0, idx1)
    } else {
        (idx1, idx0)
    };

    // R at origin, oriented horizontally (rotation=1 for 90deg CCW)
    subckt.instances[r_idx].x = origin_x;
    subckt.instances[r_idx].y = origin_y;
    subckt.instances[r_idx].rotation = 1;
    subckt.instances[r_idx].flip = false;

    // C to the right, also oriented horizontally
    subckt.instances[c_idx].x = origin_x + block.hint.h_spacing;
    subckt.instances[c_idx].y = origin_y;
    subckt.instances[c_idx].rotation = 1;
    subckt.instances[c_idx].flip = false;

    block.hint.h_spacing
}

/// Place a Wilson mirror (3 devices: ref, mirror, feedback).
/// Mirror pair side by side, feedback device above centered.
fn place_wilson_mirror(
    subckt: &mut Subcircuit,
    block: &Block,
    origin_x: i32,
    origin_y: i32,
) -> i32 {
    if block.instance_indices.len() < 3 {
        return GRID_SIZE;
    }
    let ref_idx = block.instance_indices[0] as usize;
    let mir_idx = block.instance_indices[1] as usize;
    let fb_idx = block.instance_indices[2] as usize;

    // Mirror pair at bottom
    subckt.instances[ref_idx].x = origin_x;
    subckt.instances[ref_idx].y = origin_y + block.hint.v_spacing / 2;
    subckt.instances[ref_idx].flip = true;
    subckt.instances[ref_idx].rotation = 0;

    subckt.instances[mir_idx].x = origin_x + block.hint.h_spacing;
    subckt.instances[mir_idx].y = origin_y + block.hint.v_spacing / 2;
    subckt.instances[mir_idx].flip = false;
    subckt.instances[mir_idx].rotation = 0;

    // Feedback device above, centered
    subckt.instances[fb_idx].x = origin_x + block.hint.h_spacing / 2;
    subckt.instances[fb_idx].y = origin_y - block.hint.v_spacing / 2;
    subckt.instances[fb_idx].rotation = 0;
    subckt.instances[fb_idx].flip = false;

    block.hint.h_spacing
}

/// Place a Widlar mirror (3 devices: ref MOSFET, mirror MOSFET, degeneration resistor).
/// Mirror pair side by side, resistor below mirror device.
fn place_widlar_mirror(
    subckt: &mut Subcircuit,
    block: &Block,
    origin_x: i32,
    origin_y: i32,
) -> i32 {
    if block.instance_indices.len() < 3 {
        return GRID_SIZE;
    }
    let ref_idx = block.instance_indices[0] as usize;
    let mir_idx = block.instance_indices[1] as usize;
    let r_idx = block.instance_indices[2] as usize;

    subckt.instances[ref_idx].x = origin_x;
    subckt.instances[ref_idx].y = origin_y;
    subckt.instances[ref_idx].flip = true;
    subckt.instances[ref_idx].rotation = 0;

    subckt.instances[mir_idx].x = origin_x + block.hint.h_spacing;
    subckt.instances[mir_idx].y = origin_y;
    subckt.instances[mir_idx].flip = false;
    subckt.instances[mir_idx].rotation = 0;

    subckt.instances[r_idx].x = origin_x + block.hint.h_spacing;
    subckt.instances[r_idx].y = origin_y + block.hint.v_spacing;
    subckt.instances[r_idx].rotation = 0;
    subckt.instances[r_idx].flip = false;

    block.hint.h_spacing
}

/// Place a resistor divider (2 resistors in vertical stack).
fn place_resistor_divider(
    subckt: &mut Subcircuit,
    block: &Block,
    origin_x: i32,
    origin_y: i32,
) -> i32 {
    if block.instance_indices.len() < 2 {
        return GRID_SIZE;
    }
    let idx0 = block.instance_indices[0] as usize;
    let idx1 = block.instance_indices[1] as usize;

    subckt.instances[idx0].x = origin_x;
    subckt.instances[idx0].y = origin_y - block.hint.v_spacing / 2;
    subckt.instances[idx0].rotation = 0;
    subckt.instances[idx0].flip = false;

    subckt.instances[idx1].x = origin_x;
    subckt.instances[idx1].y = origin_y + block.hint.v_spacing / 2;
    subckt.instances[idx1].rotation = 0;
    subckt.instances[idx1].flip = false;

    GRID_SIZE
}

/// Apply template placement for a block at the given origin.
/// Returns the width consumed by the template.
fn apply_template(subckt: &mut Subcircuit, block: &Block, origin_x: i32, origin_y: i32) -> i32 {
    match block.block_type {
        BlockType::DiffPair => place_diff_pair(subckt, block, origin_x, origin_y),
        BlockType::CurrentMirror => place_current_mirror(subckt, block, origin_x, origin_y),
        BlockType::Cascode | BlockType::CascodeStack => place_cascode(subckt, block, origin_x, origin_y),
        BlockType::CascodeMirror => place_cascode_mirror(subckt, block, origin_x, origin_y),
        BlockType::PushPull => place_push_pull(subckt, block, origin_x, origin_y),
        BlockType::CommonSource => place_common_source(subckt, block, origin_x, origin_y),
        BlockType::SourceFollower => place_source_follower(subckt, block, origin_x, origin_y),
        BlockType::RcCompensation => place_rc_compensation(subckt, block, origin_x, origin_y),
        BlockType::WilsonMirror => place_wilson_mirror(subckt, block, origin_x, origin_y),
        BlockType::WidlarMirror => place_widlar_mirror(subckt, block, origin_x, origin_y),
        BlockType::ResistorDivider => place_resistor_divider(subckt, block, origin_x, origin_y),
    }
}

// --------------------------------------------------------------------------
// Public API
// --------------------------------------------------------------------------

/// Place recognized blocks using templates and grid-place the rest.
///
/// For small circuits (<=10 total items), uses direct template + grid placement.
/// For larger circuits, uses simulated annealing for block-level placement,
/// then instantiates templates within each block.
pub fn place(subckt: &mut Subcircuit, blocks: &[Block], backend: &dyn Backend) {
    let mut placed: HashSet<u32> = HashSet::new();

    // Count total items: blocks + loose devices
    let block_instance_count: usize = blocks.iter().map(|b| b.instance_indices.len()).sum();
    let loose_count = subckt.instances.len() - block_instance_count.min(subckt.instances.len());
    let total_items = blocks.len() + loose_count;

    if total_items > SA_THRESHOLD {
        place_with_sa(subckt, blocks, &mut placed, 42, backend);
    } else {
        place_small(subckt, blocks, &mut placed, backend);
    }

    // Post-placement: fix any pin-level overlaps between instances on different nets.
    fix_pin_overlaps(subckt, backend);
}

/// Scan all instance pairs for pin-position overlaps between different nets.
/// If found, nudge one instance to eliminate the collision.
fn fix_pin_overlaps(subckt: &mut Subcircuit, backend: &dyn Backend) {
    let grid = 10i32;
    let max_passes = 5;
    for _ in 0..max_passes {
        // Build map of (x,y) → (instance_idx, pin_idx, net_idx).
        let mut pin_map: HashMap<(i32, i32), Vec<(usize, usize, Option<u32>)>> = HashMap::new();
        for (i, inst) in subckt.instances.iter().enumerate() {
            for (p, pin) in inst.pins.iter().enumerate() {
                let (px, py) = crate::s2s::output::pin_position(backend, inst, p);
                pin_map.entry((px, py)).or_default().push((i, p, pin.net_idx));
            }
        }

        // Find first collision: two pins at same position with different nets.
        let mut to_shift: Option<usize> = None;
        for (_pos, pins) in &pin_map {
            if pins.len() < 2 {
                continue;
            }
            // Check if any two pins belong to different nets.
            let mut nets: HashSet<u32> = HashSet::new();
            let mut inst_set: HashSet<usize> = HashSet::new();
            for &(inst_i, _, net) in pins {
                if let Some(n) = net {
                    nets.insert(n);
                }
                inst_set.insert(inst_i);
            }
            if nets.len() >= 2 && inst_set.len() >= 2 {
                // Collision. Shift the second instance.
                let second_inst = pins.iter()
                    .find(|&&(i, _, _)| i != pins[0].0)
                    .map(|&(i, _, _)| i);
                if let Some(idx) = second_inst {
                    to_shift = Some(idx);
                    break;
                }
            }
        }

        if let Some(idx) = to_shift {
            // Shift the instance right by one grid unit.
            subckt.instances[idx].x += grid;
        } else {
            break; // No more collisions.
        }
    }
}

/// Place with simulated annealing for larger circuits.
///
/// Accepts a `seed` for deterministic PRNG.
pub fn place_with_sa(
    subckt: &mut Subcircuit,
    blocks: &[Block],
    placed: &mut HashSet<u32>,
    seed: u64,
    _backend: &dyn Backend,
) {
    let constraints = generate_constraints(subckt, blocks);

    // Build placement items: one per block, one per loose device
    let mut items: Vec<PlacementItem> = Vec::new();

    for (bi, block) in blocks.iter().enumerate() {
        items.push(PlacementItem {
            instance_indices: block.instance_indices.clone(),
            block_type: Some(block.block_type),
            block_ref: Some(bi),
        });
        for &idx in &block.instance_indices {
            placed.insert(idx);
        }
    }

    for i in 0..subckt.instances.len() {
        if !placed.contains(&(i as u32)) {
            items.push(PlacementItem {
                instance_indices: vec![i as u32],
                block_type: None,
                block_ref: None,
            });
            placed.insert(i as u32);
        }
    }

    if items.is_empty() {
        return;
    }

    // Initialize SA state
    let mut state = PlacementState::new(items.len());
    for (i, item) in items.iter().enumerate() {
        if let Some(bt) = item.block_type {
            state.widths[i] = block_width(bt);
            state.heights[i] = block_height(bt);
        }
    }

    // Run SA
    simulated_annealing(&mut state, &items, subckt, &constraints, seed);

    // Apply SA results: set block origins then instantiate templates
    for (i, item) in items.iter().enumerate() {
        let (ox, oy) = state.positions[i];
        if let Some(block_ref) = item.block_ref {
            apply_template(subckt, &blocks[block_ref], ox, oy);
        } else {
            // Loose device: place directly
            let inst_idx = item.instance_indices[0] as usize;
            subckt.instances[inst_idx].x = ox;
            subckt.instances[inst_idx].y = oy;
            subckt.instances[inst_idx].rotation = state.orientations[i].0;
            subckt.instances[inst_idx].flip = state.orientations[i].1;
        }
    }
}

/// Conservative bounding-box size for a loose device (covers MOS pin span
/// with generous margin: x in [-20,40] => w=60, y in [-30,30] => h=60,
/// padded to 100x100 for comfortable clearance).
const LOOSE_DEVICE_SIZE: i32 = 100;

/// Axis-aligned bounding box used for overlap detection during placement.
#[derive(Clone, Debug)]
struct PlacedBBox {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
}

impl PlacedBBox {
    fn overlaps(&self, other: &PlacedBBox) -> bool {
        let x_overlap = self.x < other.x + other.w && other.x < self.x + self.w;
        let y_overlap = self.y < other.y + other.h && other.y < self.y + self.h;
        x_overlap && y_overlap
    }
}

/// Check whether a candidate bbox overlaps any entry in `occupied`.
fn has_collision(candidate: &PlacedBBox, occupied: &[PlacedBBox]) -> bool {
    occupied.iter().any(|b| candidate.overlaps(b))
}

/// Determine the dominant polarity of a block (PMOS-heavy -> negative Y, else positive).
fn block_y_region(block: &Block, subckt: &Subcircuit) -> i32 {
    let pmos_count = block
        .instance_indices
        .iter()
        .filter(|&&idx| subckt.instances[idx as usize].primitive == Primitive::Pmos)
        .count();
    let nmos_count = block
        .instance_indices
        .iter()
        .filter(|&&idx| subckt.instances[idx as usize].primitive == Primitive::Nmos)
        .count();
    if pmos_count > nmos_count {
        -GRID_SIZE // PMOS region above
    } else if nmos_count > 0 {
        GRID_SIZE // NMOS region below
    } else {
        0 // passives at center
    }
}

/// Place a small circuit (<=10 items) using direct template + grid.
fn place_small(subckt: &mut Subcircuit, blocks: &[Block], placed: &mut HashSet<u32>, _backend: &dyn Backend) {
    // Track all occupied bounding boxes for collision detection.
    let mut occupied: Vec<PlacedBBox> = Vec::new();

    // Check if we have blocks in multiple y-regions (PMOS + NMOS).
    // Only apply vertical separation when the circuit actually mixes polarities.
    let has_pmos_block = blocks
        .iter()
        .any(|b| block_y_region(b, subckt) < 0);
    let has_nmos_block = blocks
        .iter()
        .any(|b| block_y_region(b, subckt) > 0);
    let multi_region = has_pmos_block && has_nmos_block;

    // Also check loose instances for mixed polarity.
    let loose_has_pmos = subckt.instances.iter().enumerate().any(|(i, inst)| {
        !blocks.iter().any(|b| b.instance_indices.contains(&(i as u32)))
            && inst.primitive == Primitive::Pmos
    });
    let loose_has_nmos = subckt.instances.iter().enumerate().any(|(i, inst)| {
        !blocks.iter().any(|b| b.instance_indices.contains(&(i as u32)))
            && inst.primitive == Primitive::Nmos
    });
    let multi_region = multi_region
        || (has_pmos_block && loose_has_nmos)
        || (has_nmos_block && loose_has_pmos)
        || (loose_has_pmos && loose_has_nmos);

    // Separate blocks by polarity: PMOS-heavy above (y<0), NMOS-heavy below (y>0).
    let mut pmos_x: i32 = 0;
    let mut nmos_x: i32 = 0;
    let mut center_x: i32 = 0;

    for block in blocks {
        let raw_region = block_y_region(block, subckt);
        let y_region = if multi_region { raw_region } else { 0 };

        let (origin_x, origin_y) = if y_region < 0 {
            let x = pmos_x;
            (x, -GRID_SIZE)
        } else if y_region > 0 {
            let x = nmos_x;
            (x, GRID_SIZE)
        } else {
            let x = center_x;
            (x, 0)
        };

        let bw = apply_template(subckt, block, origin_x, origin_y);
        let bh = block_height(block.block_type);
        for &idx in &block.instance_indices {
            placed.insert(idx);
        }
        occupied.push(PlacedBBox {
            x: origin_x,
            y: origin_y - (bh / 2),
            w: bw,
            h: bh,
        });

        if y_region < 0 {
            pmos_x += bw + 80;
        } else if y_region > 0 {
            nmos_x += bw + 80;
        } else {
            center_x += bw + 80;
        }
    }

    // Loose devices start after the widest row.
    let block_x = pmos_x.max(nmos_x).max(center_x);

    // Grid-place remaining instances with collision avoidance.
    // Only separate PMOS/NMOS into regions when circuit has mixed polarity.
    let mut pmos_col: i32 = 0;
    let mut pmos_row: i32 = 0;
    let mut nmos_col: i32 = 0;
    let mut nmos_row: i32 = 0;
    let mut other_col: i32 = 0;
    let mut other_row: i32 = 0;

    for (i, inst) in subckt.instances.iter_mut().enumerate() {
        if placed.contains(&(i as u32)) {
            continue;
        }

        let (col, row, base_y) = if multi_region {
            match inst.primitive {
                Primitive::Pmos => (&mut pmos_col, &mut pmos_row, -GRID_SIZE),
                Primitive::Nmos => (&mut nmos_col, &mut nmos_row, GRID_SIZE),
                _ => (&mut other_col, &mut other_row, 0),
            }
        } else {
            (&mut other_col, &mut other_row, 0)
        };

        let mut candidate_x = block_x + *col * GRID_SIZE;
        let mut candidate_y = base_y - (*row * GRID_SIZE);

        let half = LOOSE_DEVICE_SIZE / 2;
        let mut candidate_bbox = PlacedBBox {
            x: candidate_x - half,
            y: candidate_y - half,
            w: LOOSE_DEVICE_SIZE,
            h: LOOSE_DEVICE_SIZE,
        };

        let max_attempts = (MAX_COLS as usize) * (MAX_COLS as usize + occupied.len() + 4);
        let mut attempts = 0;
        while has_collision(&candidate_bbox, &occupied) && attempts < max_attempts {
            *col += 1;
            if *col >= MAX_COLS {
                *col = 0;
                *row += 1;
            }
            candidate_x = block_x + *col * GRID_SIZE;
            candidate_y = base_y - (*row * GRID_SIZE);
            candidate_bbox = PlacedBBox {
                x: candidate_x - half,
                y: candidate_y - half,
                w: LOOSE_DEVICE_SIZE,
                h: LOOSE_DEVICE_SIZE,
            };
            attempts += 1;
        }

        inst.x = candidate_x;
        inst.y = candidate_y;

        occupied.push(candidate_bbox);

        *col += 1;
        if *col >= MAX_COLS {
            *col = 0;
            *row += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::s2s::ir::*;
    use crate::s2s::output::xschem::XschemBackend;
    use crate::s2s::recognition::{Block, BlockType, PlacementHint};

    fn test_backend() -> XschemBackend {
        XschemBackend::new("/tmp")
    }

    /// Helper: create a 4-pin NMOS instance at origin.
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
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        }
    }

    fn make_pmos(name: &str) -> Instance {
        let mut inst = make_nmos(name);
        inst.primitive = Primitive::Pmos;
        inst.symbol = "pmos4".to_string();
        inst
    }

    fn make_resistor(name: &str) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: Primitive::Resistor,
            symbol: "res".to_string(),
            pins: vec![
                Pin { name: "p".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "n".into(), dir: PinDir::Inout, net_idx: None },
            ],
            params: Default::default(),
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        }
    }

    fn make_capacitor(name: &str) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: Primitive::Capacitor,
            symbol: "cap".to_string(),
            pins: vec![
                Pin { name: "p".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "n".into(), dir: PinDir::Inout, net_idx: None },
            ],
            params: Default::default(),
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        }
    }

    fn make_isource(name: &str) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: Primitive::Isource,
            symbol: "isource".to_string(),
            pins: vec![
                Pin { name: "p".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "n".into(), dir: PinDir::Inout, net_idx: None },
            ],
            params: Default::default(),
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        }
    }

    // ======================================================================
    // Original backward-compatible tests
    // ======================================================================

    #[test]
    fn diff_pair_template() {
        let mut subckt = Subcircuit::new("dp_test");
        subckt.instances.push(make_nmos("M1"));
        subckt.instances.push(make_nmos("M2"));

        let block = Block {
            block_type: BlockType::DiffPair,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::DiffPair),
        };
        place(&mut subckt, &[block], &test_backend());

        // M1 at origin, flipped
        assert_eq!(subckt.instances[0].x, 0);
        assert_eq!(subckt.instances[0].y, 0);
        assert!(subckt.instances[0].flip);

        // M2 at +160, not flipped
        assert_eq!(subckt.instances[1].x, 160);
        assert_eq!(subckt.instances[1].y, 0);
        assert!(!subckt.instances[1].flip);
    }

    #[test]
    fn current_mirror_template() {
        let mut subckt = Subcircuit::new("cm_test");
        subckt.instances.push(make_nmos("Mref"));
        subckt.instances.push(make_nmos("Mmir"));

        let block = Block {
            block_type: BlockType::CurrentMirror,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::CurrentMirror),
        };
        place(&mut subckt, &[block], &test_backend());

        // Ref at origin, flipped
        assert_eq!(subckt.instances[0].x, 0);
        assert_eq!(subckt.instances[0].y, 0);
        assert!(subckt.instances[0].flip);

        // Mirror at +160, normal
        assert_eq!(subckt.instances[1].x, 160);
        assert_eq!(subckt.instances[1].y, 0);
        assert!(!subckt.instances[1].flip);
    }

    #[test]
    fn cascode_template() {
        let mut subckt = Subcircuit::new("cas_test");
        subckt.instances.push(make_nmos("Mbot"));
        subckt.instances.push(make_nmos("Mtop"));

        let block = Block {
            block_type: BlockType::Cascode,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::Cascode),
        };
        place(&mut subckt, &[block], &test_backend());

        // Bottom at y=+80
        assert_eq!(subckt.instances[0].x, 0);
        assert_eq!(subckt.instances[0].y, 80);

        // Top at y=-80
        assert_eq!(subckt.instances[1].x, 0);
        assert_eq!(subckt.instances[1].y, -80);
    }

    #[test]
    fn loose_instances_get_grid_placement() {
        let mut subckt = Subcircuit::new("grid_test");
        subckt.instances.push(make_nmos("M1"));
        subckt.instances.push(make_pmos("M2"));
        subckt.instances.push(make_resistor("R1"));

        // No recognized blocks => all go to grid
        // Mixed PMOS+NMOS => vertical separation: NMOS y=+200, PMOS y=-200, passive y=0
        place(&mut subckt, &[], &test_backend());

        // M1 (nmos): nmos region y=+200
        assert_eq!(subckt.instances[0].x, 0);
        assert_eq!(subckt.instances[0].y, GRID_SIZE);

        // M2 (pmos): pmos region y=-200
        assert_eq!(subckt.instances[1].x, 0);
        assert_eq!(subckt.instances[1].y, -GRID_SIZE);

        // R1 (resistor): center region y=0
        assert_eq!(subckt.instances[2].x, 0);
        assert_eq!(subckt.instances[2].y, 0);
    }

    #[test]
    fn pin_position_with_flip_and_rotation() {
        // NMOS at origin, no flip, no rotation
        let mut inst = make_nmos("M1");
        inst.x = 100;
        inst.y = 200;

        // Drain pin (idx 0): offset (20, -30) => (120, 170)
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &inst, 0), (120, 170));
        // Gate pin (idx 1): offset (-20, 0) => (80, 200)
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &inst, 1), (80, 200));
        // Source pin (idx 2): offset (20, 30) => (120, 230)
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &inst, 2), (120, 230));

        // With flip: ox is negated
        inst.flip = true;
        // Drain: offset (-20, -30) => (80, 170)
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &inst, 0), (80, 170));
        // Gate: offset (20, 0) => (120, 200)
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &inst, 1), (120, 200));

        // With flip + rotation=1 (90° CCW):
        // After flip: ox=-20, oy=-30 (drain)
        // After rot1: rx=-oy=30, ry=ox=-20
        inst.rotation = 1;
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &inst, 0), (100 + 30, 200 - 20));

        // No flip, rotation=2 (180):
        inst.flip = false;
        inst.rotation = 2;
        // Drain: ox=20, oy=-30 => rx=-20, ry=30
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &inst, 0), (80, 230));

        // Two-terminal device
        let mut res = make_resistor("R1");
        res.x = 50;
        res.y = 50;
        // Pin 0 (p): offset (0, -30) => (50, 20)
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &res, 0), (50, 20));
        // Pin 1 (n): offset (0, 30) => (50, 80)
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &res, 1), (50, 80));

        // Out-of-range pin index => instance origin
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &res, 10), (50, 50));
    }

    // ======================================================================
    // New template tests
    // ======================================================================

    #[test]
    fn cascode_stack_template() {
        let mut subckt = Subcircuit::new("cs_test");
        subckt.instances.push(make_nmos("Mbot"));
        subckt.instances.push(make_nmos("Mtop"));

        let block = Block {
            block_type: BlockType::CascodeStack,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::CascodeStack),
        };
        place(&mut subckt, &[block], &test_backend());

        // Same as Cascode: bottom at y=+80, top at y=-80
        assert_eq!(subckt.instances[0].x, 0);
        assert_eq!(subckt.instances[0].y, 80);
        assert_eq!(subckt.instances[1].x, 0);
        assert_eq!(subckt.instances[1].y, -80);
    }

    #[test]
    fn cascode_mirror_template() {
        let mut subckt = Subcircuit::new("cm4_test");
        for name in &["MB_ref", "MB_mir", "MT_ref", "MT_mir"] {
            subckt.instances.push(make_nmos(name));
        }

        let block = Block {
            block_type: BlockType::CascodeMirror,
            instance_indices: vec![0, 1, 2, 3],
            hint: PlacementHint::for_type(BlockType::CascodeMirror),
        };
        place(&mut subckt, &[block], &test_backend());

        // Bottom pair at y=+80, top pair at y=-80
        assert_eq!(subckt.instances[0].x, 0);   // MB_ref: left, bottom
        assert_eq!(subckt.instances[0].y, 80);
        assert!(subckt.instances[0].flip);

        assert_eq!(subckt.instances[1].x, 160);  // MB_mir: right, bottom
        assert_eq!(subckt.instances[1].y, 80);
        assert!(!subckt.instances[1].flip);

        assert_eq!(subckt.instances[2].x, 0);    // MT_ref: left, top
        assert_eq!(subckt.instances[2].y, -80);
        assert!(subckt.instances[2].flip);

        assert_eq!(subckt.instances[3].x, 160);  // MT_mir: right, top
        assert_eq!(subckt.instances[3].y, -80);
        assert!(!subckt.instances[3].flip);
    }

    #[test]
    fn push_pull_template() {
        let mut subckt = Subcircuit::new("pp_test");
        subckt.instances.push(make_nmos("MN"));
        subckt.instances.push(make_pmos("MP"));

        let block = Block {
            block_type: BlockType::PushPull,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::PushPull),
        };
        place(&mut subckt, &[block], &test_backend());

        // PMOS above (negative y), NMOS below (positive y)
        let pmos_idx = if subckt.instances[0].primitive == Primitive::Pmos { 0 } else { 1 };
        let nmos_idx = 1 - pmos_idx;

        assert!(subckt.instances[pmos_idx].y < subckt.instances[nmos_idx].y,
            "PMOS (y={}) should be above NMOS (y={})",
            subckt.instances[pmos_idx].y, subckt.instances[nmos_idx].y);

        // Both at same x
        assert_eq!(subckt.instances[pmos_idx].x, subckt.instances[nmos_idx].x);
    }

    #[test]
    fn common_source_template() {
        let mut subckt = Subcircuit::new("cs_test");
        subckt.instances.push(make_nmos("M1"));
        subckt.instances.push(make_resistor("R1"));

        let block = Block {
            block_type: BlockType::CommonSource,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::CommonSource),
        };
        place(&mut subckt, &[block], &test_backend());

        // MOSFET at origin
        let mos_idx = if subckt.instances[0].primitive.is_mosfet() { 0 } else { 1 };
        let res_idx = 1 - mos_idx;

        assert_eq!(subckt.instances[mos_idx].x, 0);
        assert_eq!(subckt.instances[mos_idx].y, 0);

        // Resistor above MOSFET (negative y)
        assert_eq!(subckt.instances[res_idx].x, 0);
        assert!(subckt.instances[res_idx].y < subckt.instances[mos_idx].y,
            "Resistor (y={}) should be above MOSFET (y={})",
            subckt.instances[res_idx].y, subckt.instances[mos_idx].y);
    }

    #[test]
    fn source_follower_template() {
        let mut subckt = Subcircuit::new("sf_test");
        subckt.instances.push(make_nmos("M1"));
        subckt.instances.push(make_isource("I1"));

        let block = Block {
            block_type: BlockType::SourceFollower,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::SourceFollower),
        };
        place(&mut subckt, &[block], &test_backend());

        // MOSFET at origin
        let mos_idx = if subckt.instances[0].primitive.is_mosfet() { 0 } else { 1 };
        let isrc_idx = 1 - mos_idx;

        assert_eq!(subckt.instances[mos_idx].x, 0);
        assert_eq!(subckt.instances[mos_idx].y, 0);

        // Current source below MOSFET (positive y)
        assert_eq!(subckt.instances[isrc_idx].x, 0);
        assert!(subckt.instances[isrc_idx].y > subckt.instances[mos_idx].y,
            "Current source (y={}) should be below MOSFET (y={})",
            subckt.instances[isrc_idx].y, subckt.instances[mos_idx].y);
    }

    #[test]
    fn rc_compensation_template() {
        let mut subckt = Subcircuit::new("rc_test");
        subckt.instances.push(make_resistor("R1"));
        subckt.instances.push(make_capacitor("C1"));

        let block = Block {
            block_type: BlockType::RcCompensation,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::RcCompensation),
        };
        place(&mut subckt, &[block], &test_backend());

        // R and C at same y
        assert_eq!(subckt.instances[0].y, subckt.instances[1].y);

        // Determine which is R, which is C
        let r_idx = if subckt.instances[0].primitive == Primitive::Resistor { 0 } else { 1 };
        let c_idx = 1 - r_idx;

        // R to the left of C
        assert!(subckt.instances[r_idx].x < subckt.instances[c_idx].x,
            "R (x={}) should be to the left of C (x={})",
            subckt.instances[r_idx].x, subckt.instances[c_idx].x);

        // Both rotated 90 degrees (horizontal orientation)
        assert_eq!(subckt.instances[r_idx].rotation, 1);
        assert_eq!(subckt.instances[c_idx].rotation, 1);
    }

    // ======================================================================
    // SA tests
    // ======================================================================

    #[test]
    fn sa_deterministic_with_same_seed() {
        // Create a circuit with >10 items to trigger SA
        let mut subckt1 = Subcircuit::new("sa_test");
        let mut subckt2 = Subcircuit::new("sa_test");
        for i in 0..12 {
            subckt1.instances.push(make_nmos(&format!("M{}", i)));
            subckt2.instances.push(make_nmos(&format!("M{}", i)));
        }

        let blocks: Vec<Block> = vec![];

        // Run SA with same seed
        let mut placed1 = HashSet::new();
        let mut placed2 = HashSet::new();
        place_with_sa(&mut subckt1, &blocks, &mut placed1, 12345, &test_backend());
        place_with_sa(&mut subckt2, &blocks, &mut placed2, 12345, &test_backend());

        // Results should be identical
        for i in 0..12 {
            assert_eq!(
                (subckt1.instances[i].x, subckt1.instances[i].y),
                (subckt2.instances[i].x, subckt2.instances[i].y),
                "Instance {} differs between runs with same seed", i
            );
        }
    }

    #[test]
    fn sa_different_seeds_may_differ() {
        let mut subckt1 = Subcircuit::new("sa_test");
        let mut subckt2 = Subcircuit::new("sa_test");
        for i in 0..12 {
            subckt1.instances.push(make_nmos(&format!("M{}", i)));
            subckt2.instances.push(make_nmos(&format!("M{}", i)));
        }

        let blocks: Vec<Block> = vec![];

        let mut placed1 = HashSet::new();
        let mut placed2 = HashSet::new();
        place_with_sa(&mut subckt1, &blocks, &mut placed1, 12345, &test_backend());
        place_with_sa(&mut subckt2, &blocks, &mut placed2, 99999, &test_backend());

        // At least one instance should differ (extremely unlikely to be identical)
        let any_differ = (0..12).any(|i| {
            subckt1.instances[i].x != subckt2.instances[i].x
                || subckt1.instances[i].y != subckt2.instances[i].y
        });
        assert!(any_differ, "Different seeds should produce different placements");
    }

    #[test]
    fn sa_cost_decreases() {
        // Verify SA improves placement quality
        let mut subckt = Subcircuit::new("sa_cost_test");
        for i in 0..12 {
            subckt.instances.push(make_nmos(&format!("M{}", i)));
        }

        let blocks: Vec<Block> = vec![];
        let constraints = generate_constraints(&subckt, &blocks);

        // Build items
        let items: Vec<PlacementItem> = (0..12).map(|i| PlacementItem {
            instance_indices: vec![i as u32],
            block_type: None,
            block_ref: None,
        }).collect();

        // Random initial state
        let mut initial_state = PlacementState::new(12);
        let mut rng = Xorshift64::new(42);
        for i in 0..12 {
            initial_state.positions[i] = (
                (rng.next_usize(10) as i32) * GRID_SIZE,
                (rng.next_usize(10) as i32) * GRID_SIZE,
            );
        }
        let initial_cost = compute_cost(&initial_state, &items, &subckt, &constraints);

        // Run SA
        let mut sa_state = initial_state.clone();
        simulated_annealing(&mut sa_state, &items, &subckt, &constraints, 42);
        let final_cost = compute_cost(&sa_state, &items, &subckt, &constraints);

        assert!(
            final_cost <= initial_cost,
            "SA should not worsen cost: initial={}, final={}", initial_cost, final_cost
        );
    }

    #[test]
    fn all_coordinates_on_10_unit_grid() {
        let mut subckt = Subcircuit::new("grid_test");
        for i in 0..15 {
            subckt.instances.push(make_nmos(&format!("M{}", i)));
        }

        let blocks: Vec<Block> = vec![];
        let mut placed = HashSet::new();
        place_with_sa(&mut subckt, &blocks, &mut placed, 42, &test_backend());

        for inst in &subckt.instances {
            assert_eq!(inst.x % 10, 0, "x={} not on 10-unit grid for {}", inst.x, inst.name);
            assert_eq!(inst.y % 10, 0, "y={} not on 10-unit grid for {}", inst.y, inst.name);
        }
    }

    #[test]
    fn empty_circuit_no_crash() {
        let mut subckt = Subcircuit::new("empty_test");
        place(&mut subckt, &[], &test_backend());
        assert!(subckt.instances.is_empty());
    }

    #[test]
    fn single_instance_placed_at_origin() {
        let mut subckt = Subcircuit::new("single_test");
        subckt.instances.push(make_nmos("M1"));
        place(&mut subckt, &[], &test_backend());

        assert_eq!(subckt.instances[0].x, 0);
        assert_eq!(subckt.instances[0].y, 0);
    }

    #[test]
    fn pmos_above_nmos_in_diff_pair() {
        // Verify that when we have a PMOS diff pair, both devices are
        // at the same y (symmetric). This is a layout convention check.
        let mut subckt = Subcircuit::new("dp_pmos_test");
        subckt.instances.push(make_pmos("MP1"));
        subckt.instances.push(make_pmos("MP2"));

        let block = Block {
            block_type: BlockType::DiffPair,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::DiffPair),
        };
        place(&mut subckt, &[block], &test_backend());

        // Both at same y (symmetric about vertical axis)
        assert_eq!(subckt.instances[0].y, subckt.instances[1].y);
    }

    #[test]
    fn no_overlap_small_circuit() {
        let mut subckt = Subcircuit::new("overlap_test");
        for i in 0..8 {
            subckt.instances.push(make_nmos(&format!("M{}", i)));
        }
        place(&mut subckt, &[], &test_backend());

        // Check that no two instances are at the exact same position
        for i in 0..subckt.instances.len() {
            for j in (i + 1)..subckt.instances.len() {
                let same_pos = subckt.instances[i].x == subckt.instances[j].x
                    && subckt.instances[i].y == subckt.instances[j].y;
                assert!(!same_pos,
                    "Instances {} and {} overlap at ({}, {})",
                    subckt.instances[i].name, subckt.instances[j].name,
                    subckt.instances[i].x, subckt.instances[i].y);
            }
        }
    }

    #[test]
    fn xorshift_deterministic() {
        let mut rng1 = Xorshift64::new(42);
        let mut rng2 = Xorshift64::new(42);

        for _ in 0..100 {
            assert_eq!(rng1.next_u64(), rng2.next_u64());
        }
    }

    #[test]
    fn xorshift_nonzero_seed_handling() {
        // Seed of 0 should be converted to 1
        let mut rng = Xorshift64::new(0);
        assert_ne!(rng.next_u64(), 0);
    }

    #[test]
    fn snap_to_grid_works() {
        assert_eq!(snap(0), 0);
        assert_eq!(snap(10), 10);
        assert_eq!(snap(15), 20);
        assert_eq!(snap(14), 10);
        assert_eq!(snap(-5), 0);
        assert_eq!(snap(-15), -10);
        assert_eq!(snap(203), 200);
    }

    #[test]
    fn placement_state_snap() {
        let mut state = PlacementState::new(2);
        state.positions[0] = (13, 27);
        state.positions[1] = (-3, 155);
        state.snap_to_grid();

        assert_eq!(state.positions[0], (10, 30));
        assert_eq!(state.positions[1], (0, 160));
    }

    #[test]
    fn sa_with_blocks_and_loose() {
        // Circuit with a diff pair block + loose devices, triggering SA path
        let mut subckt = Subcircuit::new("mixed_test");
        // Diff pair
        subckt.instances.push(make_nmos("M0"));
        subckt.instances.push(make_nmos("M1"));
        // 10 loose devices to push over SA threshold
        for i in 2..12 {
            subckt.instances.push(make_nmos(&format!("M{}", i)));
        }

        let blocks = vec![Block {
            block_type: BlockType::DiffPair,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::DiffPair),
        }];

        place(&mut subckt, &blocks, &test_backend());

        // Diff pair should still be placed via template
        // M0 flipped, M1 not flipped
        assert!(subckt.instances[0].flip);
        assert!(!subckt.instances[1].flip);
        // Same y for diff pair
        assert_eq!(subckt.instances[0].y, subckt.instances[1].y);
        // M1 to the right of M0
        assert!(subckt.instances[1].x > subckt.instances[0].x);
    }

    #[test]
    fn all_8_templates_produce_correct_coordinates() {
        // Test that all 8 templates produce non-zero-sized placements
        let templates = [
            (BlockType::DiffPair, 2),
            (BlockType::CurrentMirror, 2),
            (BlockType::Cascode, 2),
            (BlockType::CascodeMirror, 4),
            (BlockType::PushPull, 2),
            (BlockType::CommonSource, 2),
            (BlockType::SourceFollower, 2),
            (BlockType::RcCompensation, 2),
        ];

        for (bt, count) in &templates {
            let mut subckt = Subcircuit::new("template_test");
            for i in 0..*count {
                match bt {
                    BlockType::PushPull => {
                        if i == 0 { subckt.instances.push(make_nmos(&format!("I{}", i))); }
                        else { subckt.instances.push(make_pmos(&format!("I{}", i))); }
                    }
                    BlockType::CommonSource => {
                        if i == 0 { subckt.instances.push(make_nmos(&format!("I{}", i))); }
                        else { subckt.instances.push(make_resistor(&format!("I{}", i))); }
                    }
                    BlockType::SourceFollower => {
                        if i == 0 { subckt.instances.push(make_nmos(&format!("I{}", i))); }
                        else { subckt.instances.push(make_isource(&format!("I{}", i))); }
                    }
                    BlockType::RcCompensation => {
                        if i == 0 { subckt.instances.push(make_resistor(&format!("I{}", i))); }
                        else { subckt.instances.push(make_capacitor(&format!("I{}", i))); }
                    }
                    _ => {
                        subckt.instances.push(make_nmos(&format!("I{}", i)));
                    }
                }
            }

            let indices: Vec<u32> = (0..*count as u32).collect();
            let block = Block {
                block_type: *bt,
                instance_indices: indices,
                hint: PlacementHint::for_type(*bt),
            };

            let width = apply_template(&mut subckt, &block, 0, 0);
            assert!(width > 0, "Template {:?} produced zero width", bt);

            // Check that not all instances are at the same position
            // (except for single-column templates where x may be same but y differs)
            let positions: Vec<(i32, i32)> = subckt.instances.iter()
                .map(|inst| (inst.x, inst.y))
                .collect();
            let all_same = positions.windows(2).all(|w| w[0] == w[1]);
            assert!(!all_same, "Template {:?} placed all instances at same position", bt);
        }
    }

    #[test]
    fn hard_constraints_satisfied_after_template_placement() {
        // Place a diff pair and check that symmetry constraint is satisfied
        let mut subckt = Subcircuit::new("hc_test");
        subckt.instances.push(make_nmos("M0"));
        subckt.instances.push(make_nmos("M1"));

        let block = Block {
            block_type: BlockType::DiffPair,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::DiffPair),
        };
        place(&mut subckt, &[block], &test_backend());

        // Diff pair symmetry: both at same y
        assert_eq!(subckt.instances[0].y, subckt.instances[1].y,
            "Diff pair should be symmetric: y0={} vs y1={}",
            subckt.instances[0].y, subckt.instances[1].y);
    }

    #[test]
    fn overlap_detection_works() {
        // Two items at same position -> overlap detected
        let mut state = PlacementState::new(2);
        state.positions[0] = (0, 0);
        state.positions[1] = (0, 0);
        assert!(count_overlaps(&state) > 0);

        // Two items far apart -> no overlap
        state.positions[1] = (1000, 1000);
        assert_eq!(count_overlaps(&state), 0);
    }

    #[test]
    fn hpwl_computed_correctly() {
        let items = vec![
            PlacementItem {
                instance_indices: vec![0],
                block_type: None,
                block_ref: None,
            },
            PlacementItem {
                instance_indices: vec![1],
                block_type: None,
                block_ref: None,
            },
        ];

        let mut subckt = Subcircuit::new("hpwl_test");
        subckt.instances.push(make_nmos("M0"));
        subckt.instances.push(make_nmos("M1"));

        // Create a net connecting both instances
        let mut net = Net::new("n1");
        net.pins.push(PinRef { instance_idx: 0, pin_idx: 0 });
        net.pins.push(PinRef { instance_idx: 1, pin_idx: 0 });
        subckt.nets.push(net);

        let mut state = PlacementState::new(2);
        state.positions[0] = (0, 0);
        state.positions[1] = (400, 0);

        let hpwl = compute_hpwl(&state, &items, &subckt);
        // HPWL should be > 0 since items are apart
        assert!(hpwl > 0.0, "HPWL should be positive for separated connected items");
    }

    // ======================================================================
    // Grid placer overlap detection tests
    // ======================================================================

    /// Helper: build a PlacedBBox for an instance using the same logic as place_small.
    fn instance_bbox(inst: &Instance) -> PlacedBBox {
        let half = LOOSE_DEVICE_SIZE / 2;
        PlacedBBox {
            x: inst.x - half,
            y: inst.y - half,
            w: LOOSE_DEVICE_SIZE,
            h: LOOSE_DEVICE_SIZE,
        }
    }

    #[test]
    fn placed_bbox_overlaps_basic() {
        let a = PlacedBBox { x: 0, y: 0, w: 100, h: 100 };
        let b = PlacedBBox { x: 50, y: 50, w: 100, h: 100 };
        assert!(a.overlaps(&b), "Overlapping bboxes should be detected");

        let c = PlacedBBox { x: 200, y: 200, w: 100, h: 100 };
        assert!(!a.overlaps(&c), "Non-overlapping bboxes should not collide");

        // Edge-touching (not overlapping in half-open interval convention)
        let d = PlacedBBox { x: 100, y: 0, w: 100, h: 100 };
        assert!(!a.overlaps(&d), "Edge-touching bboxes should not overlap");
    }

    #[test]
    fn has_collision_helper() {
        let occupied = vec![
            PlacedBBox { x: 0, y: 0, w: 100, h: 100 },
            PlacedBBox { x: 200, y: 0, w: 100, h: 100 },
        ];
        let candidate_overlap = PlacedBBox { x: 50, y: 50, w: 100, h: 100 };
        assert!(has_collision(&candidate_overlap, &occupied));

        let candidate_free = PlacedBBox { x: 400, y: 400, w: 100, h: 100 };
        assert!(!has_collision(&candidate_free, &occupied));
    }

    #[test]
    fn grid_placement_no_bbox_overlaps_dense_loose() {
        // 5 loose NMOS instances on grid — verify zero bounding-box overlaps
        let mut subckt = Subcircuit::new("dense_test");
        for i in 0..5 {
            subckt.instances.push(make_nmos(&format!("M{}", i)));
        }
        place(&mut subckt, &[], &test_backend());

        // Check all pairs for bounding-box overlap
        for i in 0..subckt.instances.len() {
            let bi = instance_bbox(&subckt.instances[i]);
            for j in (i + 1)..subckt.instances.len() {
                let bj = instance_bbox(&subckt.instances[j]);
                assert!(
                    !bi.overlaps(&bj),
                    "Instances {} ({},{}) and {} ({},{}) have overlapping bounding boxes",
                    subckt.instances[i].name, subckt.instances[i].x, subckt.instances[i].y,
                    subckt.instances[j].name, subckt.instances[j].x, subckt.instances[j].y,
                );
            }
        }
    }

    #[test]
    fn grid_placement_no_bbox_overlaps_mixed_types() {
        // Mix of PMOS, NMOS, resistors — the PMOS y-offset should not cause overlaps
        let mut subckt = Subcircuit::new("mixed_types_test");
        subckt.instances.push(make_pmos("MP1"));
        subckt.instances.push(make_nmos("MN1"));
        subckt.instances.push(make_pmos("MP2"));
        subckt.instances.push(make_resistor("R1"));
        subckt.instances.push(make_nmos("MN2"));
        place(&mut subckt, &[], &test_backend());

        for i in 0..subckt.instances.len() {
            let bi = instance_bbox(&subckt.instances[i]);
            for j in (i + 1)..subckt.instances.len() {
                let bj = instance_bbox(&subckt.instances[j]);
                assert!(
                    !bi.overlaps(&bj),
                    "Instances {} ({},{}) and {} ({},{}) have overlapping bounding boxes",
                    subckt.instances[i].name, subckt.instances[i].x, subckt.instances[i].y,
                    subckt.instances[j].name, subckt.instances[j].x, subckt.instances[j].y,
                );
            }
        }
    }

    #[test]
    fn grid_placement_block_plus_loose_no_overlap() {
        // 1 diff-pair block + 3 loose NMOS — loose devices must not overlap the block
        let mut subckt = Subcircuit::new("block_loose_test");
        subckt.instances.push(make_nmos("M0")); // block member
        subckt.instances.push(make_nmos("M1")); // block member
        subckt.instances.push(make_nmos("M2")); // loose
        subckt.instances.push(make_nmos("M3")); // loose
        subckt.instances.push(make_resistor("R1")); // loose

        let block = Block {
            block_type: BlockType::DiffPair,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::DiffPair),
        };
        place(&mut subckt, &[block], &test_backend());

        // Build bboxes for the block (using block_width/block_height) and loose devices
        let bw = block_width(BlockType::DiffPair);
        let bh = block_height(BlockType::DiffPair);
        let block_bbox = PlacedBBox {
            x: subckt.instances[0].x, // block origin x (left device)
            y: -(bh / 2),
            w: bw,
            h: bh,
        };

        // Verify loose devices don't overlap the block bbox
        for i in 2..subckt.instances.len() {
            let loose_bbox = instance_bbox(&subckt.instances[i]);
            assert!(
                !block_bbox.overlaps(&loose_bbox),
                "Loose instance {} ({},{}) overlaps with diff-pair block bbox",
                subckt.instances[i].name, subckt.instances[i].x, subckt.instances[i].y,
            );
        }

        // Also verify loose devices don't overlap each other
        for i in 2..subckt.instances.len() {
            let bi = instance_bbox(&subckt.instances[i]);
            for j in (i + 1)..subckt.instances.len() {
                let bj = instance_bbox(&subckt.instances[j]);
                assert!(
                    !bi.overlaps(&bj),
                    "Loose instances {} and {} have overlapping bounding boxes",
                    subckt.instances[i].name, subckt.instances[j].name,
                );
            }
        }
    }
}
