//! Simulated annealing engine for placement optimization.

use crate::s2s::ir::Subcircuit;
use super::constraints::Constraint;
use super::cost::{compute_cost, PlacementState};
use super::{PlacementItem, GRID_SIZE};

/// XorShift64 PRNG (deterministic, no external deps).
pub struct Xorshift64 {
    state: u64,
}

impl Xorshift64 {
    pub fn new(seed: u64) -> Self {
        Self { state: if seed == 0 { 1 } else { seed } }
    }

    pub fn next_u64(&mut self) -> u64 {
        let mut x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        x
    }

    pub fn next_usize(&mut self, bound: usize) -> usize {
        if bound == 0 {
            return 0;
        }
        (self.next_u64() % bound as u64) as usize
    }

    pub fn next_f64(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }
}

/// Move operators for SA.
#[derive(Debug, Clone, Copy)]
enum MoveOp {
    Swap(usize, usize),
    Translate(usize, i32, i32),
    Rotate(usize),
    Flip(usize),
}

/// Saved state for undo.
#[derive(Debug)]
enum SavedState {
    Swap,
    Translate(i32, i32),
    Rotate(u8),
    Flip(bool),
}

/// Run simulated annealing on the placement state.
pub fn simulated_annealing(
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

    // Initial random placement on grid
    for i in 0..n {
        let cols = (n as f64).sqrt().ceil() as i32;
        let row = (i as i32) / cols;
        let col = (i as i32) % cols;
        state.positions[i] = (col * GRID_SIZE, row * GRID_SIZE);
    }
    state.snap_to_grid();

    let mut current_cost = compute_cost(state, items, subckt, constraints);

    // Calibrate initial temperature
    let calibration_moves = 100.min(n * n);
    let mut total_delta: f64 = 0.0;
    let mut num_deltas = 0;
    for _ in 0..calibration_moves {
        let op = random_move(n, &mut rng);
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

        let op = random_move(n, &mut rng);
        let saved = save_state(state, &op);
        apply_move(state, &op);
        state.snap_to_grid();

        let new_cost = compute_cost(state, items, subckt, constraints);
        let delta = new_cost - current_cost;

        if delta < 0.0 || rng.next_f64() < (-delta / t).exp() {
            current_cost = new_cost;
            if current_cost < best_cost {
                best_cost = current_cost;
                best_state = state.clone();
                non_improving = 0;
            } else {
                non_improving += 1;
            }
        } else {
            restore_state(state, &op, saved);
            non_improving += 1;
        }

        t *= alpha;
    }

    *state = best_state;
}

fn random_move(n: usize, rng: &mut Xorshift64) -> MoveOp {
    let op_type = rng.next_usize(4);
    match op_type {
        0 => {
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
            let idx = rng.next_usize(n);
            MoveOp::Rotate(idx)
        }
        _ => {
            let idx = rng.next_usize(n);
            MoveOp::Flip(idx)
        }
    }
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
