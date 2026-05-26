//! A* pathfinding on a compact bit-grid with bend and crossing penalties.

use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap, HashSet};

use crate::s2s::ir::Wire;

/// Grid resolution for pathfinding.
pub const GRID_RES: i32 = 10;

/// Approximate half-width of a component bounding box for obstacle marking.
pub const COMPONENT_HALF_W: i32 = 40;
/// Approximate half-height of a component bounding box for obstacle marking.
pub const COMPONENT_HALF_H: i32 = 40;

/// Base cost for moving one grid cell.
const COST_BASE: i32 = 1;
/// Penalty for changing direction (bend).
const COST_BEND: i32 = 3;
/// Penalty for crossing an existing wire.
const COST_CROSSING: i32 = 10;

// ---------------------------------------------------------------------------
// BitGrid
// ---------------------------------------------------------------------------

/// Compact bit-grid for obstacle tracking.
pub struct BitGrid {
    data: Vec<u64>,
    min_x: i32,
    min_y: i32,
    width: usize,
    height: usize,
}

impl BitGrid {
    pub fn new(min_x: i32, min_y: i32, max_x: i32, max_y: i32) -> Self {
        let width = ((max_x - min_x + 1) as usize).max(1);
        let height = ((max_y - min_y + 1) as usize).max(1);
        let total_bits = width * height;
        let num_u64 = (total_bits + 63) / 64;
        Self {
            data: vec![0u64; num_u64],
            min_x,
            min_y,
            width,
            height,
        }
    }

    fn in_bounds(&self, gx: i32, gy: i32) -> bool {
        let lx = gx - self.min_x;
        let ly = gy - self.min_y;
        lx >= 0 && ly >= 0 && (lx as usize) < self.width && (ly as usize) < self.height
    }

    pub fn set(&mut self, gx: i32, gy: i32) {
        if !self.in_bounds(gx, gy) {
            return;
        }
        let lx = (gx - self.min_x) as usize;
        let ly = (gy - self.min_y) as usize;
        let idx = ly * self.width + lx;
        self.data[idx / 64] |= 1u64 << (idx % 64);
    }

    pub fn get(&self, gx: i32, gy: i32) -> bool {
        if !self.in_bounds(gx, gy) {
            return false;
        }
        let lx = (gx - self.min_x) as usize;
        let ly = (gy - self.min_y) as usize;
        let idx = ly * self.width + lx;
        (self.data[idx / 64] >> (idx % 64)) & 1 == 1
    }

    pub fn unset(&mut self, gx: i32, gy: i32) {
        if !self.in_bounds(gx, gy) {
            return;
        }
        let lx = (gx - self.min_x) as usize;
        let ly = (gy - self.min_y) as usize;
        let idx = ly * self.width + lx;
        self.data[idx / 64] &= !(1u64 << (idx % 64));
    }
}

// ---------------------------------------------------------------------------
// Obstacle grid building
// ---------------------------------------------------------------------------

use crate::s2s::ir::Instance;

/// Build a compact obstacle grid from instance bounding boxes.
pub fn build_obstacle_grid(instances: &[Instance]) -> BitGrid {
    if instances.is_empty() {
        return BitGrid::new(0, 0, 1, 1);
    }
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
    let mut grid = BitGrid::new(min_x - padding, min_y - padding, max_x + padding, max_y + padding);
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

/// Mark grid cells along a wire segment as hard obstacles.
pub fn mark_wire_on_grid_hard(obstacles: &mut BitGrid, wire: &Wire) {
    let x1 = wire.x1 / GRID_RES;
    let y1 = wire.y1 / GRID_RES;
    let x2 = wire.x2 / GRID_RES;
    let y2 = wire.y2 / GRID_RES;
    if y1 == y2 {
        let (lo, hi) = super::wires::minmax(x1, x2);
        for gx in lo..=hi {
            obstacles.set(gx, y1);
        }
    } else if x1 == x2 {
        let (lo, hi) = super::wires::minmax(y1, y2);
        for gy in lo..=hi {
            obstacles.set(x1, gy);
        }
    }
}

// ---------------------------------------------------------------------------
// A* workspace
// ---------------------------------------------------------------------------

/// Reusable workspace for A* pathfinding.
pub struct RouterWorkspace {
    open: BinaryHeap<AStarNode>,
    best: HashMap<(i32, i32), (i32, Direction, Option<(i32, i32)>)>,
    closed: HashSet<(i32, i32)>,
}

impl RouterWorkspace {
    pub fn new() -> Self {
        Self {
            open: BinaryHeap::new(),
            best: HashMap::new(),
            closed: HashSet::new(),
        }
    }

    fn clear(&mut self) {
        self.open.clear();
        self.best.clear();
        self.closed.clear();
    }
}

// ---------------------------------------------------------------------------
// A* types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum Direction {
    Up,
    Down,
    Left,
    Right,
    None,
}

#[derive(Debug, Clone, Eq, PartialEq)]
struct AStarNode {
    pos: (i32, i32),
    g_cost: i32,
    f_cost: i32,
    direction: Direction,
}

impl Ord for AStarNode {
    fn cmp(&self, other: &Self) -> Ordering {
        other
            .f_cost
            .cmp(&self.f_cost)
            .then_with(|| other.g_cost.cmp(&self.g_cost))
    }
}

impl PartialOrd for AStarNode {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

// ---------------------------------------------------------------------------
// A* pathfinding
// ---------------------------------------------------------------------------

/// Find a path from `start` to `end` using A*.
///
/// Coordinates are in schematic units. Returns grid-snapped path points.
pub fn astar_path(
    start: (i32, i32),
    end: (i32, i32),
    obstacles: &BitGrid,
    foreign_pins: &[(i32, i32)],
    existing_wires: &[(i32, i32, i32, i32)],
    budget_multiplier: f64,
    workspace: &mut RouterWorkspace,
) -> Option<Vec<(i32, i32)>> {
    if start == end {
        return None;
    }

    let s = (start.0 / GRID_RES, start.1 / GRID_RES);
    let e = (end.0 / GRID_RES, end.1 / GRID_RES);

    let dist = manhattan_grid(s, e);
    let base_budget = ((dist as u64 + 1) * 200).min(100_000) as f64;
    let max_iterations = (base_budget * budget_multiplier) as usize;

    workspace.clear();

    let h = manhattan_grid(s, e);
    workspace.open.push(AStarNode {
        pos: s,
        g_cost: 0,
        f_cost: h,
        direction: Direction::None,
    });
    workspace.best.insert(s, (0, Direction::None, None));

    let neighbors: [(i32, i32, Direction); 4] = [
        (0, -1, Direction::Up),
        (0, 1, Direction::Down),
        (-1, 0, Direction::Left),
        (1, 0, Direction::Right),
    ];

    let mut iterations = 0;

    while let Some(current) = workspace.open.pop() {
        iterations += 1;
        if iterations > max_iterations {
            return None;
        }

        if current.pos == e {
            return Some(reconstruct_path(&workspace.best, s, e));
        }

        if workspace.closed.contains(&current.pos) {
            continue;
        }
        workspace.closed.insert(current.pos);

        if let Some(&(known_g, _, _)) = workspace.best.get(&current.pos) {
            if current.g_cost > known_g {
                continue;
            }
        }

        for &(dx, dy, dir) in &neighbors {
            let np = (current.pos.0 + dx, current.pos.1 + dy);

            if workspace.closed.contains(&np) {
                continue;
            }

            if np != s && np != e && (obstacles.get(np.0, np.1) || foreign_pins.contains(&np)) {
                continue;
            }

            let mut step_cost = COST_BASE;

            if current.direction != Direction::None && current.direction != dir {
                step_cost += COST_BEND;
            }

            let seg_start = (current.pos.0 * GRID_RES, current.pos.1 * GRID_RES);
            let seg_end = (np.0 * GRID_RES, np.1 * GRID_RES);
            if segments_cross(seg_start, seg_end, existing_wires) {
                step_cost += COST_CROSSING;
            }

            let new_g = current.g_cost + step_cost;
            let should_update = match workspace.best.get(&np) {
                Some(&(existing_g, _, _)) => new_g < existing_g,
                None => true,
            };

            if should_update {
                let h = manhattan_grid(np, e);
                workspace.best.insert(np, (new_g, dir, Some(current.pos)));
                workspace.open.push(AStarNode {
                    pos: np,
                    g_cost: new_g,
                    f_cost: new_g + h,
                    direction: dir,
                });
            }
        }
    }

    None
}

fn reconstruct_path(
    best: &HashMap<(i32, i32), (i32, Direction, Option<(i32, i32)>)>,
    start: (i32, i32),
    end: (i32, i32),
) -> Vec<(i32, i32)> {
    let mut path = Vec::new();
    let mut current = end;
    path.push((current.0 * GRID_RES, current.1 * GRID_RES));

    while current != start {
        if let Some(&(_, _, Some(parent))) = best.get(&current) {
            current = parent;
            path.push((current.0 * GRID_RES, current.1 * GRID_RES));
        } else {
            break;
        }
    }

    path.reverse();
    path
}

// ---------------------------------------------------------------------------
// Segment crossing detection
// ---------------------------------------------------------------------------

fn segments_cross(
    a: (i32, i32),
    b: (i32, i32),
    existing_wires: &[(i32, i32, i32, i32)],
) -> bool {
    for &(x1, y1, x2, y2) in existing_wires {
        if orthogonal_segments_intersect(a.0, a.1, b.0, b.1, x1, y1, x2, y2) {
            return true;
        }
    }
    false
}

fn orthogonal_segments_intersect(
    ax1: i32, ay1: i32, ax2: i32, ay2: i32,
    bx1: i32, by1: i32, bx2: i32, by2: i32,
) -> bool {
    let a_horiz = ay1 == ay2;
    let a_vert = ax1 == ax2;
    let b_horiz = by1 == by2;
    let b_vert = bx1 == bx2;

    if a_horiz && b_vert {
        let (a_min_x, a_max_x) = super::wires::minmax(ax1, ax2);
        let (b_min_y, b_max_y) = super::wires::minmax(by1, by2);
        let ay = ay1;
        let bx = bx1;
        bx > a_min_x && bx < a_max_x && ay > b_min_y && ay < b_max_y
    } else if a_vert && b_horiz {
        let (b_min_x, b_max_x) = super::wires::minmax(bx1, bx2);
        let (a_min_y, a_max_y) = super::wires::minmax(ay1, ay2);
        let ax = ax1;
        let by = by1;
        ax > b_min_x && ax < b_max_x && by > a_min_y && by < a_max_y
    } else {
        false
    }
}

/// Manhattan distance between two grid cells.
pub fn manhattan_grid(a: (i32, i32), b: (i32, i32)) -> i32 {
    (a.0 - b.0).abs() + (a.1 - b.1).abs()
}
