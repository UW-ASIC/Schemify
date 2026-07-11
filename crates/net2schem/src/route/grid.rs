//! Sparse bit grids: obstacles from instance bboxes, body-proximity scores.

use super::*;

/// Compact bit-grid for obstacle tracking (flat Vec<u64> with computed indices).
#[derive(Clone)]
pub(crate) struct BitGrid {
    data: Vec<u64>,
    min_x: i32,
    min_y: i32,
    width: usize,
    height: usize,
}

impl BitGrid {
    pub(crate) fn new(min_x: i32, min_y: i32, max_x: i32, max_y: i32) -> Self {
        let width = ((max_x - min_x + 1) as usize).max(1);
        let height = ((max_y - min_y + 1) as usize).max(1);
        let num_u64 = (width * height).div_ceil(64);
        Self {
            data: vec![0u64; num_u64],
            min_x,
            min_y,
            width,
            height,
        }
    }

    pub(crate) fn idx(&self, gx: i32, gy: i32) -> Option<usize> {
        let lx = gx - self.min_x;
        let ly = gy - self.min_y;
        if lx >= 0 && ly >= 0 && (lx as usize) < self.width && (ly as usize) < self.height {
            Some(ly as usize * self.width + lx as usize)
        } else {
            None
        }
    }

    pub(crate) fn set(&mut self, gx: i32, gy: i32) {
        if let Some(idx) = self.idx(gx, gy) {
            self.data[idx / 64] |= 1u64 << (idx % 64);
        }
    }

    pub(crate) fn get(&self, gx: i32, gy: i32) -> bool {
        match self.idx(gx, gy) {
            Some(idx) => (self.data[idx / 64] >> (idx % 64)) & 1 == 1,
            None => false,
        }
    }

    pub(crate) fn unset(&mut self, gx: i32, gy: i32) {
        if let Some(idx) = self.idx(gx, gy) {
            self.data[idx / 64] &= !(1u64 << (idx % 64));
        }
    }
}

// ---------------------------------------------------------------------------
// Obstacle grid
// ---------------------------------------------------------------------------

/// Build a compact obstacle grid from instance bounding boxes.
///
/// Each cell in the grid (at GRID_RES resolution) that overlaps a component
/// is marked as an obstacle.
pub(crate) fn build_obstacle_grid(instances: &[Instance]) -> BitGrid {
    if instances.is_empty() {
        return BitGrid::new(0, 0, 1, 1);
    }
    let hw = COMPONENT_HALF_W / GRID_RES;
    let hh = COMPONENT_HALF_H / GRID_RES;
    let padding = 200; // Extra cells for routing headroom
    let mut min_x = i32::MAX;
    let mut min_y = i32::MAX;
    let mut max_x = i32::MIN;
    let mut max_y = i32::MIN;
    for inst in instances {
        let cx = inst.x / GRID_RES;
        let cy = inst.y / GRID_RES;
        min_x = min_x.min(cx - hw);
        min_y = min_y.min(cy - hh);
        max_x = max_x.max(cx + hw);
        max_y = max_y.max(cy + hh);
    }
    let mut grid = BitGrid::new(
        min_x - padding,
        min_y - padding,
        max_x + padding,
        max_y + padding,
    );
    for inst in instances {
        let cx = inst.x / GRID_RES;
        let cy = inst.y / GRID_RES;
        for gx in (cx - hw)..=(cx + hw) {
            for gy in (cy - hh)..=(cy + hh) {
                grid.set(gx, gy);
            }
        }
    }
    grid
}

/// Tight per-instance body grid for L-shape/detour scoring, matching the
/// R6 body definition: bbox of the instance origin plus its transformed pin
/// positions, with zero extents widened to one grid (±10). Only STRICTLY
/// interior grid points are marked — a wire running along the hull edge
/// (where the pins sit) is legal — so the real lanes between adjacent
/// components stay visible to the scorer, unlike the conservative
/// ±COMPONENT_HALF_W/H navigation grid.
pub(crate) fn build_body_score_grid<B: PinGeometry + ?Sized>(subckt: &Subcircuit, backend: &B) -> BitGrid {
    let instances = &subckt.instances;
    if instances.is_empty() {
        return BitGrid::new(0, 0, 1, 1);
    }
    // Same overall grid bounds as the navigation grid.
    let hw = COMPONENT_HALF_W / GRID_RES;
    let hh = COMPONENT_HALF_H / GRID_RES;
    let padding = 200;
    let mut min_x = i32::MAX;
    let mut min_y = i32::MAX;
    let mut max_x = i32::MIN;
    let mut max_y = i32::MIN;
    for inst in instances {
        let cx = inst.x / GRID_RES;
        let cy = inst.y / GRID_RES;
        min_x = min_x.min(cx - hw);
        min_y = min_y.min(cy - hh);
        max_x = max_x.max(cx + hw);
        max_y = max_y.max(cy + hh);
    }
    let mut grid = BitGrid::new(
        min_x - padding,
        min_y - padding,
        max_x + padding,
        max_y + padding,
    );
    for inst in instances {
        let mut x_min = inst.x;
        let mut x_max = inst.x;
        let mut y_min = inst.y;
        let mut y_max = inst.y;
        for pi in 0..inst.pins.len() {
            let (px, py) = pin_position(backend, inst, pi);
            x_min = x_min.min(px);
            x_max = x_max.max(px);
            y_min = y_min.min(py);
            y_max = y_max.max(py);
        }
        if x_min == x_max {
            x_min -= GRID_RES;
            x_max += GRID_RES;
        }
        if y_min == y_max {
            y_min -= GRID_RES;
            y_max += GRID_RES;
        }
        // Strictly interior grid points: g*GRID_RES in the OPEN interval.
        let gx0 = x_min.div_euclid(GRID_RES) + 1;
        let gx1 = (x_max - 1).div_euclid(GRID_RES);
        let gy0 = y_min.div_euclid(GRID_RES) + 1;
        let gy1 = (y_max - 1).div_euclid(GRID_RES);
        for gx in gx0..=gx1 {
            for gy in gy0..=gy1 {
                grid.set(gx, gy);
            }
        }
    }
    grid
}

/// Mark grid cells along a wire segment as hard obstacles for subsequent nets.
pub(crate) fn mark_wire_on_grid_hard(obstacles: &mut BitGrid, wire: &Wire) {
    let x1 = wire.x1 / GRID_RES;
    let y1 = wire.y1 / GRID_RES;
    let x2 = wire.x2 / GRID_RES;
    let y2 = wire.y2 / GRID_RES;
    if y1 == y2 {
        let (lo, hi) = minmax(x1, x2);
        for gx in lo..=hi {
            obstacles.set(gx, y1);
        }
    } else if x1 == x2 {
        let (lo, hi) = minmax(y1, y2);
        for gy in lo..=hi {
            obstacles.set(x1, gy);
        }
    }
}

// ---------------------------------------------------------------------------
// Crossing-penalty spatial index
// ---------------------------------------------------------------------------
