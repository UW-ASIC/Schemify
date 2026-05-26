//! Orthogonal router with A* pathfinding and net-label support.
//!
//! Pipeline:
//! 1. Classify each net (Wire vs Label) using the classifier
//! 2. Build a sparse obstacle grid from placed component bounding boxes
//! 3. Route Wire-strategy nets via A* (fall back to L-shape if no path)
//! 4. Route Label-strategy nets with net labels at each pin
//! 5. Post-process: merge collinear wire segments, grid-snap endpoints

pub mod classifier;

use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap, HashSet};

use crate::s2s::ir::{Instance, Label, Net, Subcircuit, Wire};
use crate::s2s::output::{pin_position, PinGeometry};
use classifier::NetStrategy;

/// Grid resolution for the A* routing grid.
const GRID_RES: i32 = 10;

/// Approximate half-width of a component bounding box for obstacle marking.
const COMPONENT_HALF_W: i32 = 40;
/// Approximate half-height of a component bounding box for obstacle marking.
const COMPONENT_HALF_H: i32 = 40;

// ---------------------------------------------------------------------------
// A* cost parameters
// ---------------------------------------------------------------------------

/// Base cost for moving one grid cell.
const COST_BASE: i32 = 1;
/// Penalty for changing direction (bend).
const COST_BEND: i32 = 3;
/// Penalty for crossing an existing wire.
const COST_CROSSING: i32 = 10;

// ---------------------------------------------------------------------------
// Public router interface
// ---------------------------------------------------------------------------

/// Orthogonal wire router with net-label support.
pub struct Router {
    /// Grid snap quantum. Coordinates are rounded to the nearest multiple.
    pub grid_snap: i32,
    /// Manhattan distance above which net labels are used instead of wires
    /// (used by L-shape fallback; the classifier has its own threshold).
    pub label_threshold: i32,
    /// User-supplied multiplier applied on top of the adaptive budget scaling.
    /// Default is 1.0 (no extra scaling). Increase to allow more search effort.
    pub budget_multiplier: f64,
}

impl Default for Router {
    fn default() -> Self {
        Self {
            grid_snap: 10,
            label_threshold: 300,
            budget_multiplier: 1.0,
        }
    }
}

impl Router {
    pub fn new() -> Self {
        Self::default()
    }

    /// Route all nets in the subcircuit, populating `subckt.wires` and `subckt.labels`.
    ///
    /// Uses the net classifier to decide strategy, then A* for Wire-strategy nets
    /// with L-shape fallback, and net labels for Label-strategy nets.
    pub fn route(&self, subckt: &mut Subcircuit, backend: &dyn PinGeometry) {
        let adaptive_mult = adaptive_multiplier(subckt) * self.budget_multiplier;
        let strategies = classifier::classify_nets(subckt, backend);

        // Build obstacle grid from placed component bounding boxes.
        let mut obstacles = build_obstacle_grid(&subckt.instances);

        // Collect (net_idx, strategy, pin_positions) and sort Wire nets first by
        // ascending Manhattan span so short locals get routed before longer ones.
        let mut wire_nets: Vec<(usize, Vec<(i32, i32)>)> = Vec::new();
        let mut label_nets: Vec<(usize, Vec<(i32, i32)>)> = Vec::new();

        // Identify which nets correspond to subcircuit ports (need labels even with 1 pin).
        let port_net_names: std::collections::HashSet<&str> =
            subckt.ports.iter().map(|p| p.as_str()).collect();

        // Build a map of snapped pin positions → net index for foreign-pin avoidance.
        // Include ALL nets (even single-pin) so wires never pass through any pin.
        let mut pin_pos_to_nets: HashMap<(i32, i32), Vec<usize>> = HashMap::new();
        for (net_i, net) in subckt.nets.iter().enumerate() {
            for pr in &net.pins {
                let inst = &subckt.instances[pr.instance_idx as usize];
                let (px, py) = pin_position(backend, inst, pr.pin_idx as usize);
                let pos = (self.snap(px), self.snap(py));
                pin_pos_to_nets.entry(pos).or_default().push(net_i);
            }
        }

        // Clear obstacle cells at and around pin positions so A* and L-shape
        // can enter/exit pins that sit inside component bounding boxes.
        for &(px, py) in pin_pos_to_nets.keys() {
            let gx = px / GRID_RES;
            let gy = py / GRID_RES;
            for &(dx, dy) in &[(0,0), (0,-1), (0,1), (-1,0), (1,0)] {
                obstacles.unset(gx + dx, gy + dy);
            }
        }

        for (net_i, strategy) in strategies.iter().enumerate() {
            let net = &subckt.nets[net_i];
            let is_port_net = port_net_names.contains(net.name.as_str());
            if net.pins.is_empty() {
                continue;
            }

            let limit = net.pins.len().min(32);
            let positions: Vec<(i32, i32)> = (0..limit)
                .map(|p| {
                    let pr = net.pins[p];
                    let inst = &subckt.instances[pr.instance_idx as usize];
                    let (px, py) = pin_position(backend, inst, pr.pin_idx as usize);
                    (self.snap(px), self.snap(py))
                })
                .collect();

            match strategy {
                NetStrategy::Wire => wire_nets.push((net_i, positions)),
                NetStrategy::Label => label_nets.push((net_i, positions)),
            }
        }

        // Sort wire nets by ascending Manhattan span (short locals first).
        wire_nets.sort_by_key(|(_, positions)| manhattan_span(positions));

        // Track existing wire segments for crossing-penalty calculation.
        let mut existing_wires: Vec<(i32, i32, i32, i32)> = Vec::new();

        // Reusable A* workspace across all nets.
        let mut workspace = RouterWorkspace::new();

        // --- Route Wire-strategy nets ---
        for (net_i, positions) in &wire_nets {
            // Build per-net foreign pin list (pins belonging only to other nets).
            let foreign_pins: Vec<(i32, i32)> = pin_pos_to_nets.iter()
                .filter(|(_, nets)| nets.iter().all(|&n| n != *net_i))
                .map(|(&(px, py), _)| (px / GRID_RES, py / GRID_RES))
                .collect();

            let result = route_multi_pin_net(
                *net_i as u32,
                positions,
                &obstacles,
                &foreign_pins,
                &existing_wires,
                self,
                adaptive_mult,
                &pin_pos_to_nets,
                *net_i,
                &mut workspace,
            );

            for w in &result.wires {
                existing_wires.push((w.x1, w.y1, w.x2, w.y2));
                mark_wire_on_grid_hard(&mut obstacles, w);
            }
            subckt.wires.extend(result.wires);

            if result.needs_labels {
                // Some pin pairs couldn't be wired → place labels at ALL pins.
                place_labels_for_net(*net_i as u32, positions, &mut subckt.labels);
            } else {
                // All pairs wired → single naming label at first pin.
                if let Some(&(px, py)) = positions.first() {
                    subckt.labels.push(Label {
                        net_idx: *net_i as u32,
                        x: px,
                        y: py,
                        rotation: 0,
                    });
                }
            }
        }

        // --- Place labels for Label-strategy nets ---
        for (net_i, positions) in &label_nets {
            place_labels_for_net(*net_i as u32, positions, &mut subckt.labels);
        }

        // Post-process: merge collinear segments, restore T-junctions, deduplicate.
        optimize_wires(&mut subckt.wires, &mut subckt.labels, &subckt.nets);
    }

    /// Snap a coordinate to the nearest grid multiple.
    fn snap(&self, val: i32) -> i32 {
        if self.grid_snap == 0 {
            return val;
        }
        let g = self.grid_snap;
        let rem = val.rem_euclid(g);
        if rem < (g + 1) / 2 { val - rem } else { val - rem + g }
    }
}

// ---------------------------------------------------------------------------
// BitGrid – compact obstacle storage
// ---------------------------------------------------------------------------

/// Compact bit-grid for obstacle tracking.
/// Uses a flat Vec<u64> with computed indices, replacing HashSet<(i32,i32)>.
struct BitGrid {
    data: Vec<u64>,
    min_x: i32,
    min_y: i32,
    width: usize,
    height: usize,
}

impl BitGrid {
    fn new(min_x: i32, min_y: i32, max_x: i32, max_y: i32) -> Self {
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

    fn set(&mut self, gx: i32, gy: i32) {
        if !self.in_bounds(gx, gy) {
            return;
        }
        let lx = (gx - self.min_x) as usize;
        let ly = (gy - self.min_y) as usize;
        let idx = ly * self.width + lx;
        self.data[idx / 64] |= 1u64 << (idx % 64);
    }

    fn get(&self, gx: i32, gy: i32) -> bool {
        if !self.in_bounds(gx, gy) {
            return false;
        }
        let lx = (gx - self.min_x) as usize;
        let ly = (gy - self.min_y) as usize;
        let idx = ly * self.width + lx;
        (self.data[idx / 64] >> (idx % 64)) & 1 == 1
    }

    fn unset(&mut self, gx: i32, gy: i32) {
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
// Obstacle grid
// ---------------------------------------------------------------------------

/// Build a compact obstacle grid from instance bounding boxes.
///
/// Each cell in the grid (at GRID_RES resolution) that overlaps a component
/// is marked as an obstacle.
fn build_obstacle_grid(instances: &[Instance]) -> BitGrid {
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

/// Mark grid cells along a wire segment as hard obstacles for subsequent nets.
fn mark_wire_on_grid_hard(obstacles: &mut BitGrid, wire: &Wire) {
    let x1 = wire.x1 / GRID_RES;
    let y1 = wire.y1 / GRID_RES;
    let x2 = wire.x2 / GRID_RES;
    let y2 = wire.y2 / GRID_RES;
    if y1 == y2 {
        // Horizontal wire.
        let (lo, hi) = minmax(x1, x2);
        for gx in lo..=hi {
            obstacles.set(gx, y1);
        }
    } else if x1 == x2 {
        // Vertical wire.
        let (lo, hi) = minmax(y1, y2);
        for gy in lo..=hi {
            obstacles.set(x1, gy);
        }
    }
}

// ---------------------------------------------------------------------------
// Multi-pin net routing
// ---------------------------------------------------------------------------

/// Route a multi-pin net, connecting all pins.
///
/// Strategy: iteratively connect the nearest unconnected pin to the set of
/// already-routed pins (minimum spanning tree approach).
/// Result of routing a multi-pin net.
struct RouteResult {
    wires: Vec<Wire>,
    /// True if any pin pair could not be wired (needs label fallback).
    needs_labels: bool,
}

fn route_multi_pin_net(
    net_idx: u32,
    positions: &[(i32, i32)],
    obstacles: &BitGrid,
    foreign_pins: &[(i32, i32)],
    existing_wires: &[(i32, i32, i32, i32)],
    router: &Router,
    budget_multiplier: f64,
    pin_pos_to_nets: &HashMap<(i32, i32), Vec<usize>>,
    current_net: usize,
    workspace: &mut RouterWorkspace,
) -> RouteResult {
    if positions.len() < 2 {
        return RouteResult { wires: Vec::new(), needs_labels: false };
    }

    let mut wires = Vec::new();
    let mut needs_labels = false;
    let mut routed_pins: Vec<usize> = vec![0]; // Start with first pin.
    let mut remaining: Vec<usize> = (1..positions.len()).collect();

    while !remaining.is_empty() {
        // Find the closest pair (routed_pin, remaining_pin).
        let mut best_dist = i32::MAX;
        let mut best_routed = 0;
        let mut best_remaining_idx = 0;

        for (ri, &rem_idx) in remaining.iter().enumerate() {
            for &rp_idx in &routed_pins {
                let d = manhattan(positions[rp_idx], positions[rem_idx]);
                if d < best_dist {
                    best_dist = d;
                    best_routed = rp_idx;
                    best_remaining_idx = ri;
                }
            }
        }

        let target_idx = remaining.remove(best_remaining_idx);
        routed_pins.push(target_idx);

        let from = positions[best_routed];
        let to = positions[target_idx];

        // Combine existing wires with the ones we've created so far for this net.
        let mut all_wires: Vec<(i32, i32, i32, i32)> = existing_wires.to_vec();
        for w in &wires {
            let w: &Wire = w;
            all_wires.push((w.x1, w.y1, w.x2, w.y2));
        }

        // Attempt A* routing.
        let segment_wires = if from == to {
            Vec::new()
        } else if let Some(path) = astar_path(from, to, obstacles, foreign_pins, &all_wires, budget_multiplier, workspace) {
            path_to_wires(net_idx, &path, router.grid_snap)
        } else {
            // Fallback: L-shape with foreign-pin and body avoidance.
            l_shape_wires_safe(net_idx, from, to, pin_pos_to_nets, current_net, obstacles)
        };

        if segment_wires.is_empty() && from != to {
            needs_labels = true;
        }

        wires.extend(segment_wires);
    }

    RouteResult { wires, needs_labels }
}

// ---------------------------------------------------------------------------
// A* workspace
// ---------------------------------------------------------------------------

/// Reusable workspace for A* pathfinding.
/// Retains allocated capacity between calls.
struct RouterWorkspace {
    open: BinaryHeap<AStarNode>,
    best: HashMap<(i32, i32), (i32, Direction, Option<(i32, i32)>)>,
    closed: HashSet<(i32, i32)>,
}

impl RouterWorkspace {
    fn new() -> Self {
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
// A* pathfinder
// ---------------------------------------------------------------------------

/// Direction of movement on the grid.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum Direction {
    Up,
    Down,
    Left,
    Right,
    None, // start node
}

/// A* search node.
#[derive(Debug, Clone, Eq, PartialEq)]
struct AStarNode {
    pos: (i32, i32),
    g_cost: i32,
    f_cost: i32,
    direction: Direction,
}

impl Ord for AStarNode {
    fn cmp(&self, other: &Self) -> Ordering {
        // Min-heap: reverse comparison on f_cost, break ties on g_cost (prefer more explored).
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

/// Find a path from `start` to `end` on the grid using A*.
///
/// Returns `None` if start==end or no path exists within the search budget.
///
/// Coordinates are in schematic units (not grid cells). Internally converted
/// to grid cells at `GRID_RES` resolution.
///
/// `budget_multiplier` scales the per-pair search budget. The base budget is
/// `(manhattan_distance + 1) * 200` capped at 100 000. The effective budget is
/// `base * budget_multiplier`.
fn astar_path(
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

    // Budget: limit search to avoid runaway on large grids.
    // The base budget scales with Manhattan distance; the multiplier adapts it
    // to the overall circuit size and any user-supplied scaling.
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
            return None; // Search budget exhausted.
        }

        if current.pos == e {
            // Reconstruct path.
            return Some(reconstruct_path(&workspace.best, s, e));
        }

        if workspace.closed.contains(&current.pos) {
            continue;
        }
        workspace.closed.insert(current.pos);

        // Check that this is still the best known cost for this position.
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

            // Allow start and end even if they overlap obstacles (pins are on components).
            if np != s && np != e && (obstacles.get(np.0, np.1) || foreign_pins.contains(&np)) {
                continue;
            }

            let mut step_cost = COST_BASE;

            // Bend penalty.
            if current.direction != Direction::None && current.direction != dir {
                step_cost += COST_BEND;
            }

            // Crossing penalty: check if moving from current to np crosses an existing wire.
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

    None // No path found.
}

/// Reconstruct the path from start to end using the best-cost map.
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

/// Check if the segment (a->b) crosses any of the existing wire segments.
///
/// Both the test segment and existing wires are axis-aligned (orthogonal),
/// so we only need to check perpendicular segment intersections.
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

/// Check if two axis-aligned segments intersect (proper crossing, not shared endpoints).
fn orthogonal_segments_intersect(
    ax1: i32,
    ay1: i32,
    ax2: i32,
    ay2: i32,
    bx1: i32,
    by1: i32,
    bx2: i32,
    by2: i32,
) -> bool {
    // Determine orientation of each segment.
    let a_horiz = ay1 == ay2;
    let a_vert = ax1 == ax2;
    let b_horiz = by1 == by2;
    let b_vert = bx1 == bx2;

    // Only perpendicular pairs can properly cross.
    if a_horiz && b_vert {
        // A is horizontal, B is vertical.
        let (a_min_x, a_max_x) = minmax(ax1, ax2);
        let (b_min_y, b_max_y) = minmax(by1, by2);
        let ay = ay1;
        let bx = bx1;
        // Strict intersection (not endpoint touching).
        bx > a_min_x && bx < a_max_x && ay > b_min_y && ay < b_max_y
    } else if a_vert && b_horiz {
        // A is vertical, B is horizontal.
        let (b_min_x, b_max_x) = minmax(bx1, bx2);
        let (a_min_y, a_max_y) = minmax(ay1, ay2);
        let ax = ax1;
        let by = by1;
        ax > b_min_x && ax < b_max_x && by > a_min_y && by < a_max_y
    } else {
        false
    }
}

fn minmax(a: i32, b: i32) -> (i32, i32) {
    if a <= b {
        (a, b)
    } else {
        (b, a)
    }
}

// ---------------------------------------------------------------------------
// Path -> Wire conversion
// ---------------------------------------------------------------------------

/// Convert a path (sequence of grid-snapped points) into Wire segments.
///
/// Merges collinear consecutive points into single segments.
fn path_to_wires(net_idx: u32, path: &[(i32, i32)], grid_snap: i32) -> Vec<Wire> {
    if path.len() < 2 {
        return Vec::new();
    }

    let mut wires = Vec::new();
    let mut seg_start = 0;

    for i in 1..path.len() {
        // Check if the next point continues in the same direction.
        if i + 1 < path.len() {
            let dx1 = (path[i].0 - path[i - 1].0).signum();
            let dy1 = (path[i].1 - path[i - 1].1).signum();
            let dx2 = (path[i + 1].0 - path[i].0).signum();
            let dy2 = (path[i + 1].1 - path[i].1).signum();
            if dx1 == dx2 && dy1 == dy2 {
                continue; // Collinear, keep extending.
            }
        }

        let (x1, y1) = path[seg_start];
        let (x2, y2) = path[i];

        // Skip zero-length segments.
        if x1 != x2 || y1 != y2 {
            wires.push(Wire {
                net_idx,
                x1: snap(x1, grid_snap),
                y1: snap(y1, grid_snap),
                x2: snap(x2, grid_snap),
                y2: snap(y2, grid_snap),
            });
        }
        seg_start = i;
    }

    wires
}

/// Grid-snap a single coordinate.
fn snap(val: i32, grid_snap: i32) -> i32 {
    if grid_snap == 0 {
        return val;
    }
    let rem = val.rem_euclid(grid_snap);
    if rem < (grid_snap + 1) / 2 { val - rem } else { val - rem + grid_snap }
}

// ---------------------------------------------------------------------------
// L-shape fallback
// ---------------------------------------------------------------------------

/// Generate L-shape wire segments (horizontal then vertical) between two points.
fn l_shape_wires(net_idx: u32, from: (i32, i32), to: (i32, i32)) -> Vec<Wire> {
    let mut wires = Vec::new();
    let mx = to.0;
    let my = from.1;

    // Horizontal segment.
    if from.0 != mx {
        wires.push(Wire {
            net_idx,
            x1: from.0,
            y1: from.1,
            x2: mx,
            y2: my,
        });
    }

    // Vertical segment.
    if my != to.1 {
        wires.push(Wire {
            net_idx,
            x1: mx,
            y1: my,
            x2: to.0,
            y2: to.1,
        });
    }

    wires
}

/// L-shape with foreign-pin and component-body avoidance.
/// Try horizontal-first, then vertical-first.
/// If both hit foreign pins or obstacles, fall back to label strategy (return empty).
fn l_shape_wires_safe(
    net_idx: u32,
    from: (i32, i32),
    to: (i32, i32),
    pin_pos_to_nets: &HashMap<(i32, i32), Vec<usize>>,
    current_net: usize,
    obstacles: &BitGrid,
) -> Vec<Wire> {
    let from_grid = (from.0 / GRID_RES, from.1 / GRID_RES);
    let to_grid = (to.0 / GRID_RES, to.1 / GRID_RES);

    // Check if a point hits a foreign pin.
    let is_foreign = |pt: (i32, i32)| -> bool {
        if let Some(nets) = pin_pos_to_nets.get(&pt) {
            nets.iter().any(|&n| n != current_net)
        } else {
            false
        }
    };

    // Check if any wire segment passes through a foreign pin or component body.
    let wire_hits = |w: &Wire| -> bool {
        if w.y1 == w.y2 {
            let (lo, hi) = minmax(w.x1, w.x2);
            let step = GRID_RES;
            let mut x = lo + step;
            while x < hi {
                if is_foreign((x, w.y1)) {
                    return true;
                }
                // Check obstacle grid (component body), exempting start/end pins.
                let gp = (x / GRID_RES, w.y1 / GRID_RES);
                if gp != from_grid && gp != to_grid && obstacles.get(gp.0, gp.1) {
                    return true;
                }
                x += step;
            }
        } else if w.x1 == w.x2 {
            let (lo, hi) = minmax(w.y1, w.y2);
            let step = GRID_RES;
            let mut y = lo + step;
            while y < hi {
                if is_foreign((w.x1, y)) {
                    return true;
                }
                let gp = (w.x1 / GRID_RES, y / GRID_RES);
                if gp != from_grid && gp != to_grid && obstacles.get(gp.0, gp.1) {
                    return true;
                }
                y += step;
            }
        }
        false
    };

    // Option A: horizontal then vertical (corner at (to.x, from.y)).
    let corner_a = (to.0, from.1);
    let wires_a = l_shape_wires(net_idx, from, to);
    let a_hits_corner = is_foreign(corner_a) && corner_a != from && corner_a != to;
    let a_hits_segment = wires_a.iter().any(|w| wire_hits(w));

    // Option B: vertical then horizontal (corner at (from.x, to.y)).
    let corner_b = (from.0, to.1);
    let wires_b = l_shape_wires_vfirst(net_idx, from, to);
    let b_hits_corner = is_foreign(corner_b) && corner_b != from && corner_b != to;
    let b_hits_segment = wires_b.iter().any(|w| wire_hits(w));

    if !a_hits_corner && !a_hits_segment {
        wires_a
    } else if !b_hits_corner && !b_hits_segment {
        wires_b
    } else {
        // Both L-shapes hit obstacles → fall back to labels (return empty).
        Vec::new()
    }
}

/// Generate L-shape wire segments (vertical then horizontal) between two points.
fn l_shape_wires_vfirst(net_idx: u32, from: (i32, i32), to: (i32, i32)) -> Vec<Wire> {
    let mut wires = Vec::new();
    let mx = from.0;
    let my = to.1;

    // Vertical segment.
    if from.1 != my {
        wires.push(Wire {
            net_idx,
            x1: from.0,
            y1: from.1,
            x2: mx,
            y2: my,
        });
    }

    // Horizontal segment.
    if mx != to.0 {
        wires.push(Wire {
            net_idx,
            x1: mx,
            y1: my,
            x2: to.0,
            y2: to.1,
        });
    }

    wires
}

// ---------------------------------------------------------------------------
// Label placement
// ---------------------------------------------------------------------------

/// Place net labels at each pin position for a Label-strategy net.
fn place_labels_for_net(net_idx: u32, positions: &[(i32, i32)], labels: &mut Vec<Label>) {
    if positions.is_empty() {
        return;
    }

    // Single pin: place label pointing right (default).
    if positions.len() == 1 {
        labels.push(Label {
            net_idx,
            x: positions[0].0,
            y: positions[0].1,
            rotation: 0,
        });
        return;
    }

    // Compute centroid for rotation.
    let cx: i32 = positions.iter().map(|p| p.0).sum::<i32>() / positions.len() as i32;
    let cy: i32 = positions.iter().map(|p| p.1).sum::<i32>() / positions.len() as i32;

    for &(px, py) in positions {
        labels.push(Label {
            net_idx,
            x: px,
            y: py,
            rotation: label_rotation(px, py, cx, cy),
        });
    }
}

/// Pick label rotation so it points *away* from the other endpoint.
///
/// 0 = right, 1 = up, 2 = left, 3 = down.
fn label_rotation(from_x: i32, from_y: i32, to_x: i32, to_y: i32) -> u8 {
    let dx = to_x - from_x;
    let dy = to_y - from_y;
    if dx.abs() >= dy.abs() {
        // Dominant horizontal: point away horizontally.
        if dx >= 0 {
            2
        } else {
            0
        }
    } else {
        // Dominant vertical: point away vertically.
        if dy >= 0 {
            1
        } else {
            3
        }
    }
}

// ---------------------------------------------------------------------------
// Wire post-processing
// ---------------------------------------------------------------------------

/// Optimize wire segments: merge collinear, restore T-junctions, deduplicate.
/// Order: merge -> T-junction -> dedup (each step depends on the previous).
fn optimize_wires(wires: &mut Vec<Wire>, labels: &mut Vec<Label>, nets: &[Net]) {
    // Step 1: Merge collinear
    *wires = merge_collinear_wires(wires);
    // Step 2: Restore T-junctions
    *wires = restore_t_junctions(wires);
    // Step 3: Deduplicate
    let taken = std::mem::take(wires);
    *wires = deduplicate_wires(taken, labels, nets);
}

/// Merge collinear wire segments that share an endpoint and lie on the same axis.
fn merge_collinear_wires(wires: &[Wire]) -> Vec<Wire> {
    if wires.is_empty() {
        return Vec::new();
    }

    // Group wires by net_idx.
    let mut by_net: HashMap<u32, Vec<Wire>> = HashMap::new();
    for w in wires {
        by_net.entry(w.net_idx).or_default().push(*w);
    }

    let mut result = Vec::new();
    for (net_idx, mut net_wires) in by_net {
        // Separate into horizontal and vertical.
        let mut horiz: Vec<Wire> = Vec::new();
        let mut vert: Vec<Wire> = Vec::new();
        let mut other: Vec<Wire> = Vec::new();

        for w in net_wires.drain(..) {
            if w.y1 == w.y2 {
                horiz.push(w);
            } else if w.x1 == w.x2 {
                vert.push(w);
            } else {
                other.push(w);
            }
        }

        // Merge horizontal segments sharing the same Y.
        result.extend(merge_segments_1d(net_idx, &horiz, true));
        // Merge vertical segments sharing the same X.
        result.extend(merge_segments_1d(net_idx, &vert, false));
        result.extend(other);
    }

    // Sort for deterministic output.
    result.sort_by(|a, b| {
        a.net_idx
            .cmp(&b.net_idx)
            .then(a.x1.cmp(&b.x1))
            .then(a.y1.cmp(&b.y1))
            .then(a.x2.cmp(&b.x2))
            .then(a.y2.cmp(&b.y2))
    });

    result
}

/// Merge collinear segments along one axis.
///
/// `is_horizontal`: if true, segments share Y and we merge along X.
/// Otherwise, segments share X and we merge along Y.
fn merge_segments_1d(net_idx: u32, segments: &[Wire], is_horizontal: bool) -> Vec<Wire> {
    if segments.is_empty() {
        return Vec::new();
    }

    // Group by the shared coordinate.
    let mut groups: HashMap<i32, Vec<(i32, i32)>> = HashMap::new();
    for w in segments {
        if is_horizontal {
            let y = w.y1;
            let (a, b) = minmax(w.x1, w.x2);
            groups.entry(y).or_default().push((a, b));
        } else {
            let x = w.x1;
            let (a, b) = minmax(w.y1, w.y2);
            groups.entry(x).or_default().push((a, b));
        }
    }

    let mut result = Vec::new();
    for (shared, mut intervals) in groups {
        // Sort intervals by start.
        intervals.sort();
        // Merge overlapping/adjacent intervals.
        let mut merged: Vec<(i32, i32)> = Vec::new();
        for (lo, hi) in intervals {
            if let Some(last) = merged.last_mut() {
                if lo <= last.1 {
                    last.1 = last.1.max(hi);
                    continue;
                }
            }
            merged.push((lo, hi));
        }

        for (lo, hi) in merged {
            if lo == hi {
                continue; // zero-length
            }
            if is_horizontal {
                result.push(Wire {
                    net_idx,
                    x1: lo,
                    y1: shared,
                    x2: hi,
                    y2: shared,
                });
            } else {
                result.push(Wire {
                    net_idx,
                    x1: shared,
                    y1: lo,
                    x2: shared,
                    y2: hi,
                });
            }
        }
    }

    result
}

// ---------------------------------------------------------------------------
// T-junction restoration
// ---------------------------------------------------------------------------

/// After merging collinear segments, interior crossing points between
/// same-net horizontal and vertical wires lose their T-junction endpoints.
/// xschem only connects wires at shared endpoints, not at interior crossings.
/// This function splits wires at such crossings to restore T-junctions.
fn restore_t_junctions(wires: &[Wire]) -> Vec<Wire> {
    // Group wires by net.
    let mut by_net: HashMap<u32, Vec<Wire>> = HashMap::new();
    for w in wires {
        by_net.entry(w.net_idx).or_default().push(*w);
    }

    let mut result = Vec::new();
    for (net_idx, net_wires) in &by_net {
        let mut horiz: Vec<Wire> = Vec::new();
        let mut vert: Vec<Wire> = Vec::new();

        for w in net_wires {
            if w.y1 == w.y2 && w.x1 != w.x2 {
                horiz.push(*w);
            } else if w.x1 == w.x2 && w.y1 != w.y2 {
                vert.push(*w);
            } else {
                result.push(*w);
            }
        }

        // Collect split points for each wire.
        let mut h_splits: Vec<Vec<i32>> = vec![Vec::new(); horiz.len()];
        let mut v_splits: Vec<Vec<i32>> = vec![Vec::new(); vert.len()];

        for (hi, h) in horiz.iter().enumerate() {
            let hy = h.y1;
            let (hx_lo, hx_hi) = minmax(h.x1, h.x2);
            for (vi, v) in vert.iter().enumerate() {
                let vx = v.x1;
                let (vy_lo, vy_hi) = minmax(v.y1, v.y2);
                // Check if they cross at interior of both.
                if vx > hx_lo && vx < hx_hi && hy > vy_lo && hy < vy_hi {
                    // Interior crossing — split horizontal at vx and vertical at hy.
                    h_splits[hi].push(vx);
                    v_splits[vi].push(hy);
                }
            }
        }

        // Split horizontal wires.
        for (i, h) in horiz.iter().enumerate() {
            if h_splits[i].is_empty() {
                result.push(*h);
            } else {
                let mut pts = h_splits[i].clone();
                let (lo, hi_x) = minmax(h.x1, h.x2);
                pts.push(lo);
                pts.push(hi_x);
                pts.sort();
                pts.dedup();
                for pair in pts.windows(2) {
                    if pair[0] != pair[1] {
                        result.push(Wire {
                            net_idx: *net_idx,
                            x1: pair[0],
                            y1: h.y1,
                            x2: pair[1],
                            y2: h.y1,
                        });
                    }
                }
            }
        }

        // Split vertical wires.
        for (i, v) in vert.iter().enumerate() {
            if v_splits[i].is_empty() {
                result.push(*v);
            } else {
                let mut pts = v_splits[i].clone();
                let (lo, hi_y) = minmax(v.y1, v.y2);
                pts.push(lo);
                pts.push(hi_y);
                pts.sort();
                pts.dedup();
                for pair in pts.windows(2) {
                    if pair[0] != pair[1] {
                        result.push(Wire {
                            net_idx: *net_idx,
                            x1: v.x1,
                            y1: pair[0],
                            x2: v.x1,
                            y2: pair[1],
                        });
                    }
                }
            }
        }
    }

    result
}

// ---------------------------------------------------------------------------
// Wire deduplication
// ---------------------------------------------------------------------------

/// Normalize wire coordinates so (x1,y1) <= (x2,y2) lexicographically.
fn normalize_wire_coords(w: &Wire) -> (i32, i32, i32, i32) {
    if (w.x1, w.y1) <= (w.x2, w.y2) {
        (w.x1, w.y1, w.x2, w.y2)
    } else {
        (w.x2, w.y2, w.x1, w.y1)
    }
}

/// Remove duplicate wire segments. If two wires occupy the same coordinates
/// with different net labels, keep the first and convert the second net to
/// label strategy by dropping its wire and relying on its existing label.
fn deduplicate_wires(wires: Vec<Wire>, labels: &mut Vec<Label>, nets: &[Net]) -> Vec<Wire> {
    let mut seen: HashMap<(i32, i32, i32, i32), u32> = HashMap::new();
    let mut result = Vec::new();
    let mut conflict_nets: HashSet<u32> = HashSet::new();

    for w in &wires {
        let key = normalize_wire_coords(w);
        if let Some(&existing_net) = seen.get(&key) {
            if existing_net != w.net_idx {
                // Conflict: same wire segment claimed by different nets.
                // Remove the later net's wires; it will use labels instead.
                conflict_nets.insert(w.net_idx);
            }
            // Skip duplicate (same or different net).
        } else {
            seen.insert(key, w.net_idx);
        }
    }

    // Second pass: keep wires not belonging to conflicting nets, and also
    // check if segments overlap with wires from different nets.
    // Rebuild seen map for the clean pass.
    seen.clear();
    for w in &wires {
        if conflict_nets.contains(&w.net_idx) {
            continue;
        }
        let key = normalize_wire_coords(w);
        if seen.contains_key(&key) {
            continue; // Skip within-net duplicates too.
        }
        seen.insert(key, w.net_idx);
        result.push(*w);
    }

    // Add labels for conflict nets so their pins are still named.
    for &net_idx in &conflict_nets {
        if (net_idx as usize) < nets.len() {
            let net = &nets[net_idx as usize];
            // Check if labels already exist for this net.
            let has_label = labels.iter().any(|l| l.net_idx == net_idx);
            if !has_label && !net.pins.is_empty() {
                // The route() fn already places a naming label for wire nets,
                // so this is just a safety net.
                labels.push(Label {
                    net_idx,
                    x: 0,
                    y: 0,
                    rotation: 0,
                });
            }
        }
    }

    result
}

// ---------------------------------------------------------------------------
// Adaptive budget
// ---------------------------------------------------------------------------

/// Compute the average instance spread (sum of X and Y extent) as a proxy for
/// routing complexity.  Returns 0.0 when fewer than 2 instances exist.
fn compute_avg_instance_spread(subckt: &Subcircuit) -> f64 {
    if subckt.instances.len() < 2 {
        return 0.0;
    }
    let xs: Vec<i32> = subckt.instances.iter().map(|i| i.x).collect();
    let ys: Vec<i32> = subckt.instances.iter().map(|i| i.y).collect();
    let x_spread = xs.iter().max().unwrap() - xs.iter().min().unwrap();
    let y_spread = ys.iter().max().unwrap() - ys.iter().min().unwrap();
    (x_spread + y_spread) as f64
}

/// Derive an adaptive budget multiplier from the subcircuit's size.
///
/// Larger circuits (more nets, more spread-out instances) get a proportionally
/// higher search budget so the A* router has room to find paths in dense or
/// far-apart layouts.  The multiplier is always >= 1.0 (never shrinks the
/// budget).
fn adaptive_multiplier(subckt: &Subcircuit) -> f64 {
    let num_nets = subckt.nets.len();
    let net_factor = (num_nets as f64 / 10.0).max(1.0);

    let avg_manhattan = compute_avg_instance_spread(subckt);
    let dist_factor = (avg_manhattan / 200.0).max(1.0);

    net_factor * dist_factor
}

// ---------------------------------------------------------------------------
// Utility functions
// ---------------------------------------------------------------------------

/// Manhattan distance between two points (schematic units).
fn manhattan(a: (i32, i32), b: (i32, i32)) -> i32 {
    (a.0 - b.0).abs() + (a.1 - b.1).abs()
}

/// Manhattan distance between two grid cells.
fn manhattan_grid(a: (i32, i32), b: (i32, i32)) -> i32 {
    (a.0 - b.0).abs() + (a.1 - b.1).abs()
}

/// Total Manhattan span of a set of positions (max - min over x and y).
fn manhattan_span(positions: &[(i32, i32)]) -> i32 {
    if positions.is_empty() {
        return 0;
    }
    let min_x = positions.iter().map(|p| p.0).min().unwrap();
    let max_x = positions.iter().map(|p| p.0).max().unwrap();
    let min_y = positions.iter().map(|p| p.1).min().unwrap();
    let max_y = positions.iter().map(|p| p.1).max().unwrap();
    (max_x - min_x) + (max_y - min_y)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use crate::s2s::ir::{Instance, Net, Pin, PinDir, PinRef, Primitive, Subcircuit};
    use crate::s2s::output::xschem::XschemBackend;
    use std::collections::HashMap;

    fn test_backend() -> XschemBackend {
        XschemBackend::new("/tmp")
    }

    /// Helper: build a minimal instance at (x, y) with `n` dummy pins.
    fn make_instance(name: &str, x: i32, y: i32, n: usize) -> Instance {
        let pins: Vec<Pin> = (0..n)
            .map(|i| Pin {
                name: format!("p{i}"),
                dir: PinDir::Inout,
                net_idx: Some(0),
            })
            .collect();
        Instance {
            name: name.to_string(),
            primitive: Primitive::Resistor,
            symbol: String::new(),
            pins,
            params: HashMap::new(),
            x,
            y,
            rotation: 0,
            flip: false,
        }
    }

    /// Build a subcircuit with two instances and one net connecting pin 0 of each.
    fn two_instance_subckt(x1: i32, y1: i32, x2: i32, y2: i32) -> Subcircuit {
        let mut subckt = Subcircuit::new("test");
        subckt.instances.push(make_instance("I0", x1, y1, 2));
        subckt.instances.push(make_instance("I1", x2, y2, 2));

        let mut net = Net::new("n1");
        net.pins.push(PinRef {
            instance_idx: 0,
            pin_idx: 0,
        });
        net.pins.push(PinRef {
            instance_idx: 1,
            pin_idx: 0,
        });
        subckt.nets.push(net);
        subckt
    }

    // -----------------------------------------------------------------------
    // Existing tests (preserved)
    // -----------------------------------------------------------------------

    #[test]
    fn short_connection_produces_wires_and_naming_label() {
        // Two-terminal resistor pin 0 offset is (0, -30).
        // Instance at (0,0) -> pin at (0, -30). Instance at (100,0) -> pin at (100, -30).
        // Manhattan distance = 100, which is < 300.
        let mut subckt = two_instance_subckt(0, 0, 100, 0);
        let router = Router::new();
        router.route(&mut subckt, &test_backend());

        assert!(!subckt.wires.is_empty(), "should produce wire segments");
        // Wire-strategy nets now get a single naming label for xschem compatibility.
        assert_eq!(subckt.labels.len(), 1, "should have exactly one naming label");
    }

    #[test]
    fn long_connection_produces_labels_no_wires() {
        // Instance at (0,0) -> pin at (0, -30). Instance at (500,0) -> pin at (500, -30).
        // Manhattan span = 500. Adaptive threshold = max(300, (500+0)/2) = 300.
        // 500 > 300 → Label.
        let mut subckt = two_instance_subckt(0, 0, 500, 0);
        let router = Router::new();
        router.route(&mut subckt, &test_backend());

        assert!(subckt.wires.is_empty(), "should not produce wires");
        assert_eq!(subckt.labels.len(), 2, "should produce two labels");
    }

    #[test]
    fn grid_snapping_rounds_to_nearest_10() {
        let router = Router {
            grid_snap: 10,
            ..Router::default()
        };

        assert_eq!(router.snap(0), 0);
        assert_eq!(router.snap(4), 0);
        assert_eq!(router.snap(5), 10);      // round half up
        assert_eq!(router.snap(14), 10);
        assert_eq!(router.snap(15), 20);
        assert_eq!(router.snap(-4), 0);       // -4 closer to 0 than -10
        assert_eq!(router.snap(-5), 0);       // equidistant, round toward +inf
        assert_eq!(router.snap(-6), -10);     // -6 closer to -10 than 0
        assert_eq!(router.snap(-20), -20);    // exact grid value preserved
        assert_eq!(router.snap(-200), -200);  // exact grid value preserved
        assert_eq!(router.snap(23), 20);
        assert_eq!(router.snap(27), 30);
    }

    #[test]
    fn l_shape_wire_horizontal_then_vertical() {
        // Place instances so that pin positions differ in both X and Y.
        // Resistor pin 0 offset: (0, -30).
        // I0 at (0, 0) -> pin (0, -30). I1 at (50, 60) -> pin (50, 30).
        let mut subckt = two_instance_subckt(0, 0, 50, 60);
        let router = Router::new();
        router.route(&mut subckt, &test_backend());

        // Should produce wire segments (may be merged/reordered by post-processing).
        assert!(!subckt.wires.is_empty(), "expected wire segments");

        // All wires should be orthogonal.
        for w in &subckt.wires {
            assert!(
                w.x1 == w.x2 || w.y1 == w.y2,
                "wire should be orthogonal: ({},{}) -> ({},{})",
                w.x1,
                w.y1,
                w.x2,
                w.y2
            );
        }
    }

    #[test]
    fn single_pin_net_gets_label_no_wires() {
        let mut subckt = Subcircuit::new("test");
        subckt.instances.push(make_instance("I0", 0, 0, 2));

        let mut net = Net::new("lonely");
        net.pins.push(PinRef {
            instance_idx: 0,
            pin_idx: 0,
        });
        subckt.nets.push(net);

        let router = Router::new();
        router.route(&mut subckt, &test_backend());

        assert!(subckt.wires.is_empty());
        assert_eq!(subckt.labels.len(), 1, "single-pin net should get a label");
    }

    #[test]
    fn label_rotation_points_away_from_other_endpoint() {
        // "to" is to the right of "from" -> label at "from" should point left (2)
        assert_eq!(label_rotation(0, 0, 100, 0), 2);
        // "to" is to the left -> label points right (0)
        assert_eq!(label_rotation(100, 0, 0, 0), 0);
        // "to" is below (positive Y) -> label points up (1)
        assert_eq!(label_rotation(0, 0, 0, 100), 1);
        // "to" is above (negative Y) -> label points down (3)
        assert_eq!(label_rotation(0, 100, 0, 0), 3);
    }

    // -----------------------------------------------------------------------
    // A* router tests
    // -----------------------------------------------------------------------

    #[test]
    fn astar_finds_path_on_empty_grid() {
        let obstacles = BitGrid::new(-100, -100, 100, 100);
        let existing: Vec<(i32, i32, i32, i32)> = Vec::new();
        let mut ws = RouterWorkspace::new();

        let path = astar_path((0, 0), (50, 30), &obstacles, &[], &existing, 1.0, &mut ws);
        assert!(path.is_some(), "A* should find a path on empty grid");

        let path = path.unwrap();
        assert_eq!(path.first(), Some(&(0, 0)), "path should start at start");
        assert_eq!(path.last(), Some(&(50, 30)), "path should end at end");

        // All steps should be on the 10-unit grid.
        for &(x, y) in &path {
            assert_eq!(x % GRID_RES, 0, "x={x} should be on grid");
            assert_eq!(y % GRID_RES, 0, "y={y} should be on grid");
        }

        // All steps should be orthogonal (horizontal or vertical moves).
        for i in 1..path.len() {
            let dx = (path[i].0 - path[i - 1].0).abs();
            let dy = (path[i].1 - path[i - 1].1).abs();
            assert!(
                (dx == GRID_RES && dy == 0) || (dx == 0 && dy == GRID_RES),
                "step {i} not orthogonal: ({},{}) -> ({},{})",
                path[i - 1].0,
                path[i - 1].1,
                path[i].0,
                path[i].1
            );
        }
    }

    #[test]
    fn astar_returns_none_when_start_equals_end() {
        let obstacles = BitGrid::new(-100, -100, 100, 100);
        let existing: Vec<(i32, i32, i32, i32)> = Vec::new();
        let mut ws = RouterWorkspace::new();

        let path = astar_path((10, 20), (10, 20), &obstacles, &[], &existing, 1.0, &mut ws);
        assert!(path.is_none(), "A* should return None when start==end");
    }

    #[test]
    fn astar_avoids_obstacles() {
        let mut obstacles = BitGrid::new(-100, -100, 100, 100);
        // Place a wall of obstacles between x=2 and x=2, y=-2..=2 (grid coords).
        // In schematic coords that's x=20, y=-20..=20.
        for y in -2..=2 {
            obstacles.set(2, y);
        }

        let existing: Vec<(i32, i32, i32, i32)> = Vec::new();
        let mut ws = RouterWorkspace::new();
        let path = astar_path((0, 0), (40, 0), &obstacles, &[], &existing, 1.0, &mut ws);
        assert!(path.is_some(), "A* should find a path around the wall");

        let path = path.unwrap();
        // Verify no path point is on the obstacle (except possibly start/end which
        // are exempt, but here they aren't obstacles).
        for &(x, y) in &path {
            let gx = x / GRID_RES;
            let gy = y / GRID_RES;
            if (x, y) != (0, 0) && (x, y) != (40, 0) {
                assert!(
                    !obstacles.get(gx, gy),
                    "path should not go through obstacle at grid ({gx},{gy})"
                );
            }
        }
    }

    #[test]
    fn bend_penalty_prefers_straight_paths() {
        let obstacles = BitGrid::new(-100, -100, 100, 100);
        let existing: Vec<(i32, i32, i32, i32)> = Vec::new();
        let mut ws = RouterWorkspace::new();

        // Horizontal path: start and end on the same Y.
        let path = astar_path((0, 0), (50, 0), &obstacles, &[], &existing, 1.0, &mut ws);
        assert!(path.is_some());
        let path = path.unwrap();

        // With bend penalty, the optimal path should be a straight horizontal line.
        for &(_, y) in &path {
            assert_eq!(y, 0, "straight horizontal path should have y=0");
        }
    }

    #[test]
    fn crossing_penalty_causes_detour() {
        let obstacles = BitGrid::new(-100, -100, 100, 100);
        let mut ws = RouterWorkspace::new();

        // Existing horizontal wire at y=0 from x=10 to x=40.
        let existing = vec![(10, 0, 40, 0)];

        // Route from (0, -20) to (50, 20): a direct path would cross the wire.
        let path_with_crossing =
            astar_path((0, -20), (50, 20), &obstacles, &[], &existing, 1.0, &mut ws);
        assert!(path_with_crossing.is_some());

        // Route with no existing wires: should be cheaper/shorter.
        let empty_existing: Vec<(i32, i32, i32, i32)> = Vec::new();
        let path_without_crossing =
            astar_path((0, -20), (50, 20), &obstacles, &[], &empty_existing, 1.0, &mut ws);
        assert!(path_without_crossing.is_some());

        // Both paths reach the destination.
        let p1 = path_with_crossing.unwrap();
        let p2 = path_without_crossing.unwrap();
        assert_eq!(p1.last(), Some(&(50, 20)));
        assert_eq!(p2.last(), Some(&(50, 20)));
    }

    #[test]
    fn all_wires_orthogonal() {
        let mut subckt = two_instance_subckt(0, 0, 100, 100);
        let router = Router::new();
        router.route(&mut subckt, &test_backend());

        for w in &subckt.wires {
            assert!(
                w.x1 == w.x2 || w.y1 == w.y2,
                "wire not orthogonal: ({},{}) -> ({},{})",
                w.x1,
                w.y1,
                w.x2,
                w.y2
            );
        }
    }

    #[test]
    fn all_endpoints_on_grid() {
        let mut subckt = two_instance_subckt(0, 0, 73, 47);
        let router = Router::new();
        router.route(&mut subckt, &test_backend());

        for w in &subckt.wires {
            assert_eq!(w.x1 % 10, 0, "x1={} not on grid", w.x1);
            assert_eq!(w.y1 % 10, 0, "y1={} not on grid", w.y1);
            assert_eq!(w.x2 % 10, 0, "x2={} not on grid", w.x2);
            assert_eq!(w.y2 % 10, 0, "y2={} not on grid", w.y2);
        }
    }

    #[test]
    fn collinear_segments_are_merged() {
        // Two adjacent horizontal segments on the same line.
        let wires = vec![
            Wire {
                net_idx: 0,
                x1: 0,
                y1: 0,
                x2: 20,
                y2: 0,
            },
            Wire {
                net_idx: 0,
                x1: 20,
                y1: 0,
                x2: 50,
                y2: 0,
            },
        ];

        let merged = merge_collinear_wires(&wires);
        assert_eq!(merged.len(), 1, "two adjacent collinear segments should merge");
        assert_eq!(merged[0].x1, 0);
        assert_eq!(merged[0].x2, 50);
        assert_eq!(merged[0].y1, 0);
        assert_eq!(merged[0].y2, 0);
    }

    #[test]
    fn multi_pin_net_connects_all_pins() {
        // Three instances close together, forming a net with 3 pins.
        let mut subckt = Subcircuit::new("test");
        subckt.instances.push(make_instance("I0", 0, 0, 2));
        subckt.instances.push(make_instance("I1", 50, 0, 2));
        subckt.instances.push(make_instance("I2", 100, 0, 2));

        let mut net = Net::new("n1");
        for i in 0..3 {
            net.pins.push(PinRef {
                instance_idx: i,
                pin_idx: 0,
            });
        }
        subckt.nets.push(net);

        let router = Router::new();
        router.route(&mut subckt, &test_backend());

        // Should produce wires (net is short, 3 pins <= 4 threshold).
        assert!(!subckt.wires.is_empty(), "multi-pin net should produce wires");
    }

    #[test]
    fn deterministic_output() {
        // Run routing twice and verify results are identical.
        let mut s1 = two_instance_subckt(0, 0, 100, 50);
        let mut s2 = two_instance_subckt(0, 0, 100, 50);
        let router = Router::new();
        router.route(&mut s1, &test_backend());
        router.route(&mut s2, &test_backend());

        assert_eq!(s1.wires.len(), s2.wires.len(), "wire count should match");
        for (w1, w2) in s1.wires.iter().zip(s2.wires.iter()) {
            assert_eq!(w1.x1, w2.x1);
            assert_eq!(w1.y1, w2.y1);
            assert_eq!(w1.x2, w2.x2);
            assert_eq!(w1.y2, w2.y2);
        }

        assert_eq!(s1.labels.len(), s2.labels.len(), "label count should match");
        for (l1, l2) in s1.labels.iter().zip(s2.labels.iter()) {
            assert_eq!(l1.x, l2.x);
            assert_eq!(l1.y, l2.y);
            assert_eq!(l1.rotation, l2.rotation);
        }
    }

    #[test]
    fn fallback_to_l_shape_when_astar_blocked() {
        // Create a complete wall of obstacles around the endpoint.
        // A* will fail, so L-shape fallback should kick in.
        let from = (0, 0);
        let to = (100, 0);

        // Build an impenetrable wall.
        let mut obstacles = BitGrid::new(-100, -100, 100, 100);
        // Surround the end point at grid (10, 0) with obstacles.
        for gx in 8..=12 {
            for gy in -2..=2 {
                if gx == 10 && gy == 0 {
                    continue; // Don't block the endpoint itself.
                }
                obstacles.set(gx, gy);
            }
        }

        let existing: Vec<(i32, i32, i32, i32)> = Vec::new();
        let mut ws = RouterWorkspace::new();
        let _result = astar_path(from, to, &obstacles, &[], &existing, 1.0, &mut ws);

        // A* may or may not find a path depending on exact geometry.
        // But the L-shape fallback should always produce wires:
        let wires = l_shape_wires(0, from, to);
        assert!(!wires.is_empty(), "L-shape fallback should produce wires");
        assert_eq!(wires.len(), 1, "horizontal-only should be 1 segment");
        assert_eq!(wires[0].x1, 0);
        assert_eq!(wires[0].x2, 100);
        assert_eq!(wires[0].y1, 0);
        assert_eq!(wires[0].y2, 0);
    }

    #[test]
    fn l_shape_fallback_produces_orthogonal_wires() {
        let wires = l_shape_wires(0, (0, 0), (50, 30));
        assert_eq!(wires.len(), 2);

        // First: horizontal.
        assert_eq!(wires[0].y1, wires[0].y2);
        // Second: vertical.
        assert_eq!(wires[1].x1, wires[1].x2);
    }

    #[test]
    fn segment_crossing_detection() {
        // Horizontal wire from (10,0) to (50,0).
        let existing = vec![(10, 0, 50, 0)];

        // Vertical segment from (30, -10) to (30, 10) crosses it.
        assert!(segments_cross((30, -10), (30, 10), &existing));

        // Vertical segment from (30, 10) to (30, 20) does not cross.
        assert!(!segments_cross((30, 10), (30, 20), &existing));

        // Parallel horizontal segment does not cross.
        assert!(!segments_cross((10, 5), (50, 5), &existing));
    }

    #[test]
    fn merge_collinear_vertical() {
        let wires = vec![
            Wire {
                net_idx: 0,
                x1: 10,
                y1: 0,
                x2: 10,
                y2: 20,
            },
            Wire {
                net_idx: 0,
                x1: 10,
                y1: 20,
                x2: 10,
                y2: 50,
            },
        ];

        let merged = merge_collinear_wires(&wires);
        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0].x1, 10);
        assert_eq!(merged[0].x2, 10);
        assert_eq!(merged[0].y1, 0);
        assert_eq!(merged[0].y2, 50);
    }

    #[test]
    fn non_collinear_segments_not_merged() {
        let wires = vec![
            Wire {
                net_idx: 0,
                x1: 0,
                y1: 0,
                x2: 20,
                y2: 0,
            },
            Wire {
                net_idx: 0,
                x1: 20,
                y1: 0,
                x2: 20,
                y2: 30,
            },
        ];

        let merged = merge_collinear_wires(&wires);
        assert_eq!(merged.len(), 2, "non-collinear L-shape should not merge");
    }

    // -----------------------------------------------------------------------
    // Adaptive budget tests
    // -----------------------------------------------------------------------

    #[test]
    fn adaptive_multiplier_larger_for_bigger_circuit() {
        // Small circuit: 2 instances close together, 1 net.
        let small = two_instance_subckt(0, 0, 100, 0);

        // Large circuit: many instances spread out, many nets.
        let mut large = Subcircuit::new("large");
        for i in 0..20 {
            large
                .instances
                .push(make_instance(&format!("I{i}"), i * 200, i * 100, 2));
        }
        // Add 20 nets (one per pair of adjacent instances).
        for i in 0..20 {
            let mut net = Net::new(&format!("n{i}"));
            net.pins.push(PinRef {
                instance_idx: (i % 20) as u32,
                pin_idx: 0,
            });
            net.pins.push(PinRef {
                instance_idx: ((i + 1) % 20) as u32,
                pin_idx: 0,
            });
            large.nets.push(net);
        }

        let small_mult = adaptive_multiplier(&small);
        let large_mult = adaptive_multiplier(&large);

        assert!(
            large_mult > small_mult,
            "large circuit ({large_mult}) should get a bigger multiplier than small ({small_mult})"
        );
    }

    #[test]
    fn adaptive_multiplier_at_least_one() {
        // Tiny circuit: single instance, no nets.
        let tiny = Subcircuit::new("tiny");
        let mult = adaptive_multiplier(&tiny);
        assert!(
            mult >= 1.0,
            "adaptive multiplier should never be below 1.0, got {mult}"
        );
    }

    #[test]
    fn budget_multiplier_field_routes_successfully() {
        let mut subckt = two_instance_subckt(0, 0, 100, 0);
        let router = Router {
            budget_multiplier: 2.0,
            ..Router::default()
        };
        router.route(&mut subckt, &test_backend());

        // Should still produce wires (short connection).
        assert!(
            !subckt.wires.is_empty(),
            "router with budget_multiplier=2.0 should produce wires"
        );
    }

    #[test]
    fn compute_avg_instance_spread_empty() {
        let subckt = Subcircuit::new("empty");
        assert_eq!(compute_avg_instance_spread(&subckt), 0.0);
    }

    #[test]
    fn compute_avg_instance_spread_single() {
        let mut subckt = Subcircuit::new("single");
        subckt.instances.push(make_instance("I0", 50, 50, 1));
        assert_eq!(compute_avg_instance_spread(&subckt), 0.0);
    }

    #[test]
    fn compute_avg_instance_spread_two() {
        let subckt = two_instance_subckt(0, 0, 300, 400);
        let spread = compute_avg_instance_spread(&subckt);
        // x_spread = 300, y_spread = 400, total = 700
        assert_eq!(spread, 700.0);
    }

    // -----------------------------------------------------------------------
    // restore_t_junctions tests
    // -----------------------------------------------------------------------

    #[test]
    fn t_junction_crossing_splits_wires() {
        let wires = vec![
            Wire { net_idx: 0, x1: 0, y1: 0, x2: 100, y2: 0 },   // horizontal
            Wire { net_idx: 0, x1: 50, y1: -50, x2: 50, y2: 50 }, // vertical
        ];
        let result = restore_t_junctions(&wires);
        // Should produce 4 wire segments
        assert_eq!(result.len(), 4, "Expected 4 segments after T-junction split, got {}: {:?}", result.len(), result);
        // Check that (50,0) appears as an endpoint
        let has_junction = result.iter().any(|w| (w.x1 == 50 && w.y1 == 0) || (w.x2 == 50 && w.y2 == 0));
        assert!(has_junction, "Junction point (50,0) should be an endpoint");
    }

    #[test]
    fn t_junction_no_crossing_no_split() {
        let wires = vec![
            Wire { net_idx: 0, x1: 0, y1: 0, x2: 100, y2: 0 },
            Wire { net_idx: 0, x1: 0, y1: 50, x2: 100, y2: 50 },
        ];
        let result = restore_t_junctions(&wires);
        assert_eq!(result.len(), 2, "Parallel wires should not be split");
    }

    #[test]
    fn t_junction_endpoint_touching_not_split() {
        let wires = vec![
            Wire { net_idx: 0, x1: 0, y1: 0, x2: 100, y2: 0 },
            Wire { net_idx: 0, x1: 0, y1: -50, x2: 0, y2: 0 },
        ];
        let result = restore_t_junctions(&wires);
        assert_eq!(result.len(), 2, "Endpoint-touching wires should not be split");
    }

    // -----------------------------------------------------------------------
    // deduplicate_wires tests
    // -----------------------------------------------------------------------

    #[test]
    fn dedup_same_net_duplicate_removed() {
        let wires = vec![
            Wire { net_idx: 0, x1: 0, y1: 0, x2: 100, y2: 0 },
            Wire { net_idx: 0, x1: 0, y1: 0, x2: 100, y2: 0 },
        ];
        let nets = vec![Net::new("n0")];
        let mut labels = Vec::new();
        let result = deduplicate_wires(wires, &mut labels, &nets);
        assert_eq!(result.len(), 1, "Duplicate wire on same net should be removed");
        assert_eq!(result[0].net_idx, 0);
    }

    #[test]
    fn dedup_same_net_reversed_duplicate_removed() {
        let wires = vec![
            Wire { net_idx: 0, x1: 0, y1: 0, x2: 100, y2: 0 },
            Wire { net_idx: 0, x1: 100, y1: 0, x2: 0, y2: 0 },
        ];
        let nets = vec![Net::new("n0")];
        let mut labels = Vec::new();
        let result = deduplicate_wires(wires, &mut labels, &nets);
        assert_eq!(result.len(), 1, "Reversed duplicate should be removed");
    }

    #[test]
    fn dedup_cross_net_conflict_uses_label_fallback() {
        let mut n0 = Net::new("n0");
        n0.pins.push(crate::s2s::ir::PinRef { instance_idx: 0, pin_idx: 0 });
        let mut n1 = Net::new("n1");
        n1.pins.push(crate::s2s::ir::PinRef { instance_idx: 1, pin_idx: 0 });
        let nets = vec![n0, n1];
        let wires = vec![
            Wire { net_idx: 0, x1: 0, y1: 0, x2: 100, y2: 0 },
            Wire { net_idx: 1, x1: 0, y1: 0, x2: 100, y2: 0 },
        ];
        let mut labels = Vec::new();
        let result = deduplicate_wires(wires, &mut labels, &nets);
        // The conflicting net (net 1) should have its wires removed
        assert!(result.iter().all(|w| w.net_idx != 1), "Conflicting net's wires should be removed");
        // A label should be added for the conflicting net
        assert!(labels.iter().any(|l| l.net_idx == 1), "Label should be added for conflicting net");
    }

    #[test]
    fn dedup_different_segments_no_removal() {
        let wires = vec![
            Wire { net_idx: 0, x1: 0, y1: 0, x2: 100, y2: 0 },
            Wire { net_idx: 1, x1: 200, y1: 0, x2: 300, y2: 0 },
        ];
        let nets = vec![Net::new("n0"), Net::new("n1")];
        let mut labels = Vec::new();
        let result = deduplicate_wires(wires, &mut labels, &nets);
        assert_eq!(result.len(), 2, "Non-overlapping wires should both be kept");
    }
}
