//! A* pathfinding over the routing grid, plus path → wire conversion.

use std::cmp::Ordering;
use std::collections::BinaryHeap;

use super::*;

/// Route a multi-pin net, iteratively connecting the nearest unconnected pin
/// to the set of already-routed pins (minimum spanning tree approach).
///
/// Every pin pair with distinct positions ends up wired (strict Q5: a
/// Wire-classified net must be routed with wires). Escalation ladder per pair:
///  1. windowed A*, standard budget
///  a. windowed A*, generous budget (cheap — bounded by the window)
///  b. windowed A*, generous budget, relaxed crossing penalty
///  c. widened-window A* (3x margin), generous budget, relaxed crossings —
///     only for short pairs, where the window stays small
///  d. detour sweep: L-shapes plus Z/U-shapes with the trunk line shifted off
///     the pin rows; the least-damaging candidate wins (foreign-pin shorts
///     weighted far above cosmetic body crossings), so a clean corridor is
///     taken whenever one exists. May still trip R6 if every candidate
///     collides; accepted trade-off for guaranteed connectivity.
/// After MAX_ASTAR_FAILURES_PER_NET full A* failures, remaining pairs of the
/// net skip steps 1-c (per-net failure budget); pairs farther apart than
/// ASTAR_MAX_PAIR_DIST skip them outright (bounded work on huge layouts).
#[allow(clippy::too_many_arguments)]
pub(crate) fn route_multi_pin_net(
    net_idx: NetId,
    positions: &[(i32, i32)],
    obstacles: &BitGrid,
    body_grid: &BitGrid,
    foreign_pins: &HashSet<(i32, i32)>,
    wire_index: &WireIndex,
    router: &Router,
    budget_multiplier: f64,
    pin_pos_to_nets: &HashMap<(i32, i32), Vec<usize>>,
    current_net: usize,
    workspace: &mut RouterWorkspace,
) -> Vec<Wire> {
    if positions.len() < 2 {
        return Vec::new();
    }

    let mut wires = Vec::new();
    let mut routed_pins: Vec<usize> = vec![0]; // Start with first pin.
    let mut remaining: Vec<usize> = (1..positions.len()).collect();

    // This net's own segments routed so far (crossing penalty sees them too).
    let mut own: Vec<(i32, i32, i32, i32)> = Vec::new();
    let mut astar_failures: u32 = 0;

    let safety = LShapeSafety {
        pin_pos_to_nets,
        current_net,
        obstacles: body_grid,
        foreign_wires: wire_index,
    };

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

        let segment_wires = if from == to {
            Vec::new()
        } else {
            let ctx = CrossingCtx {
                index: wire_index,
                own: &own,
            };
            let mut path = None;
            if astar_failures < MAX_ASTAR_FAILURES_PER_NET
                && manhattan(from, to) <= ASTAR_MAX_PAIR_DIST
            {
                // (1) Windowed A*, standard budget.
                path = astar_path(
                    from, to, obstacles, foreign_pins, &ctx, budget_multiplier, 1, false, false,
                    workspace,
                );
                // (a) Generous budget: exhaust the search window.
                if path.is_none() {
                    path = astar_path(
                        from, to, obstacles, foreign_pins, &ctx, budget_multiplier, 1, true, false,
                        workspace,
                    );
                }
                // (b) Relaxed crossing penalty.
                if path.is_none() {
                    path = astar_path(
                        from, to, obstacles, foreign_pins, &ctx, budget_multiplier, 1, true, true,
                        workspace,
                    );
                }
                // (c) Widened window (3x margin) for short pairs: detours
                // around dense pin rows often lie just outside the base
                // window. Bounded: only when the window stays small.
                if path.is_none() && manhattan(from, to) <= 800 {
                    path = astar_path(
                        from, to, obstacles, foreign_pins, &ctx, budget_multiplier, 3, true, true,
                        workspace,
                    );
                }
                if path.is_none() {
                    astar_failures += 1;
                }
            }
            // A*-found paths still need a conductive-touch check: navigation
            // cells reopened around this net's own pins can overlap foreign
            // wires, letting a path elbow on / terminate on / run along one
            // (T-touch or collinear short, R8). Reject such paths and let
            // the detour ladder find a legal shape instead.
            let path_wires = path
                .map(|p| path_to_wires(net_idx, &p, router.grid_snap))
                .filter(|ws| {
                    ws.iter().all(|w| {
                        wire_index.count_touches((w.x1, w.y1, w.x2, w.y2), &[from, to]) == 0
                    })
                });
            match path_wires {
                Some(ws) => ws,
                None => {
                    // (d) Safe L-shape fast path, then the detour sweep:
                    // always produces wires; picks the least-damaging
                    // candidate (legal whenever any candidate is).
                    let safe = l_shape(net_idx, from, to, false, Some(&safety));
                    if safe.is_empty() {
                        best_detour(net_idx, from, to, &safety)
                    } else {
                        safe
                    }
                }
            }
        };

        own.extend(segment_wires.iter().map(|w| (w.x1, w.y1, w.x2, w.y2)));
        wires.extend(segment_wires);
    }

    wires
}

// ---------------------------------------------------------------------------
// A* pathfinder
// ---------------------------------------------------------------------------

type BestMap = HashMap<(i32, i32), (i32, Direction, Option<(i32, i32)>)>;

/// Reusable A* scratch buffers (allocated once, cleared per pin pair).
pub(crate) struct RouterWorkspace {
    open: BinaryHeap<AStarNode>,
    best: BestMap,
    closed: HashSet<(i32, i32)>,
}

impl RouterWorkspace {
    pub(crate) fn new() -> Self {
        Self {
            open: BinaryHeap::new(),
            best: HashMap::new(),
            closed: HashSet::new(),
        }
    }

    pub(crate) fn clear(&mut self) {
        self.open.clear();
        self.best.clear();
        self.closed.clear();
    }
}

/// Direction of movement on the grid.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum Direction {
    Up,
    Down,
    Left,
    Right,
    None, // start node
}

/// A* search node.
#[derive(Debug, Clone, Eq, PartialEq)]
pub(crate) struct AStarNode {
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
/// Coordinates are in schematic units (not grid cells); internally converted
/// to grid cells at `GRID_RES` resolution.
///
/// The search is confined to the start-end bounding box inflated by
/// `max(20, dist/4) * margin_mult` grid cells, so a failing search exhausts
/// a bounded window instead of flooding the whole layout (`margin_mult > 1`
/// is the widened-window escalation retry).
///
/// Budget: with `generous_budget`, enough iterations to exhaust the window
/// (4 pushes per cell max). Otherwise `(manhattan_distance + 1) * 200`
/// capped at 100 000, times `budget_multiplier`.
///
/// `ignore_crossings` disables the crossing penalty (escalation step b).
#[allow(clippy::too_many_arguments)]
pub(crate) fn astar_path(
    start: (i32, i32),
    end: (i32, i32),
    obstacles: &BitGrid,
    foreign_pins: &HashSet<(i32, i32)>,
    crossings: &CrossingCtx,
    budget_multiplier: f64,
    margin_mult: i32,
    generous_budget: bool,
    ignore_crossings: bool,
    workspace: &mut RouterWorkspace,
) -> Option<Vec<(i32, i32)>> {
    if start == end {
        return None;
    }

    let s = (start.0 / GRID_RES, start.1 / GRID_RES);
    let e = (end.0 / GRID_RES, end.1 / GRID_RES);

    let dist = manhattan(s, e);

    // Inflated src-dst bounding window (grid cells).
    let margin = 20.max(dist / 4) * margin_mult.max(1);
    let win_x = (s.0.min(e.0) - margin, s.0.max(e.0) + margin);
    let win_y = (s.1.min(e.1) - margin, s.1.max(e.1) + margin);

    let max_iterations = if generous_budget {
        // Exhausting the window: at most 4 pushes (and thus pops) per cell,
        // capped so failing searches over large windows stay bounded.
        let w = (win_x.1 - win_x.0 + 1) as u64;
        let h = (win_y.1 - win_y.0 + 1) as u64;
        ((w * h * 4) as usize).min(GENEROUS_BUDGET_CAP)
    } else {
        let base_budget = ((dist as u64 + 1) * 200).min(100_000) as f64;
        (base_budget * budget_multiplier) as usize
    };

    workspace.clear();

    workspace.open.push(AStarNode {
        pos: s,
        g_cost: 0,
        f_cost: manhattan(s, e),
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

            // Stay inside the search window.
            if np.0 < win_x.0 || np.0 > win_x.1 || np.1 < win_y.0 || np.1 > win_y.1 {
                continue;
            }

            if workspace.closed.contains(&np) {
                continue;
            }

            // Allow start and end even if they overlap obstacles (pins are on components).
            if np != s && np != e && (obstacles.get(np.0, np.1) || foreign_pins.contains(&np)) {
                continue;
            }

            // Conductive-touch legality: a path point lying ON a foreign
            // routed wire becomes a cross-net T-touch / collinear short
            // once emitted. Foreign-wire cells are hard obstacles already;
            // this closes the hole left by cells reopened around the
            // current net's own pins (unconditional — even the relaxed
            // escalation rungs must not short).
            if np != s
                && np != e
                && crossings
                    .index
                    .point_on_any((np.0 * GRID_RES, np.1 * GRID_RES))
            {
                continue;
            }

            let mut step_cost = COST_BASE;

            // Bend penalty.
            if current.direction != Direction::None && current.direction != dir {
                step_cost += COST_BEND;
            }

            // Crossing penalty: moving from current to np across an existing wire.
            if !ignore_crossings {
                let seg_start = (current.pos.0 * GRID_RES, current.pos.1 * GRID_RES);
                let seg_end = (np.0 * GRID_RES, np.1 * GRID_RES);
                if crossings.crosses(seg_start, seg_end) {
                    step_cost += COST_CROSSING;
                }
            }

            let new_g = current.g_cost + step_cost;
            let should_update = match workspace.best.get(&np) {
                Some(&(existing_g, _, _)) => new_g < existing_g,
                None => true,
            };

            if should_update {
                let h = manhattan(np, e);
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
pub(crate) fn reconstruct_path(best: &BestMap, start: (i32, i32), end: (i32, i32)) -> Vec<(i32, i32)> {
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

/// Convert a path (sequence of grid-snapped points) into Wire segments,
/// merging collinear consecutive points into single segments.
pub(crate) fn path_to_wires(net_idx: NetId, path: &[(i32, i32)], grid_snap: i32) -> Vec<Wire> {
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

// ---------------------------------------------------------------------------
// L-shape fallback
// ---------------------------------------------------------------------------
