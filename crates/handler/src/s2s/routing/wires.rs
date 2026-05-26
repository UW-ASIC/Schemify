//! Wire generation, L-shape fallback, and post-processing (merge, T-junction, dedup).

use std::collections::{HashMap, HashSet};

use crate::s2s::ir::{Label, Net, Wire};
use super::pathfind::{BitGrid, GRID_RES};

// ---------------------------------------------------------------------------
// Path -> Wire conversion
// ---------------------------------------------------------------------------

/// Convert a path (sequence of grid-snapped points) into Wire segments.
pub fn path_to_wires(net_idx: u32, path: &[(i32, i32)], grid_snap: i32) -> Vec<Wire> {
    if path.len() < 2 {
        return Vec::new();
    }

    let mut wires = Vec::new();
    let mut seg_start = 0;

    for i in 1..path.len() {
        if i + 1 < path.len() {
            let dx1 = (path[i].0 - path[i - 1].0).signum();
            let dy1 = (path[i].1 - path[i - 1].1).signum();
            let dx2 = (path[i + 1].0 - path[i].0).signum();
            let dy2 = (path[i + 1].1 - path[i].1).signum();
            if dx1 == dx2 && dy1 == dy2 {
                continue;
            }
        }

        let (x1, y1) = path[seg_start];
        let (x2, y2) = path[i];

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
pub fn snap(val: i32, grid_snap: i32) -> i32 {
    if grid_snap == 0 {
        return val;
    }
    let rem = val.rem_euclid(grid_snap);
    if rem < (grid_snap + 1) / 2 { val - rem } else { val - rem + grid_snap }
}

// ---------------------------------------------------------------------------
// L-shape fallback
// ---------------------------------------------------------------------------

/// Generate L-shape wire segments (horizontal then vertical).
pub fn l_shape_wires(net_idx: u32, from: (i32, i32), to: (i32, i32)) -> Vec<Wire> {
    let mut wires = Vec::new();
    let mx = to.0;
    let my = from.1;

    if from.0 != mx {
        wires.push(Wire { net_idx, x1: from.0, y1: from.1, x2: mx, y2: my });
    }
    if my != to.1 {
        wires.push(Wire { net_idx, x1: mx, y1: my, x2: to.0, y2: to.1 });
    }
    wires
}

/// Generate L-shape wire segments (vertical then horizontal).
pub fn l_shape_wires_vfirst(net_idx: u32, from: (i32, i32), to: (i32, i32)) -> Vec<Wire> {
    let mut wires = Vec::new();
    let mx = from.0;
    let my = to.1;

    if from.1 != my {
        wires.push(Wire { net_idx, x1: from.0, y1: from.1, x2: mx, y2: my });
    }
    if mx != to.0 {
        wires.push(Wire { net_idx, x1: mx, y1: my, x2: to.0, y2: to.1 });
    }
    wires
}

/// L-shape with foreign-pin and component-body avoidance.
pub fn l_shape_wires_safe(
    net_idx: u32,
    from: (i32, i32),
    to: (i32, i32),
    pin_pos_to_nets: &HashMap<(i32, i32), Vec<usize>>,
    current_net: usize,
    obstacles: &BitGrid,
) -> Vec<Wire> {
    let from_grid = (from.0 / GRID_RES, from.1 / GRID_RES);
    let to_grid = (to.0 / GRID_RES, to.1 / GRID_RES);

    let is_foreign = |pt: (i32, i32)| -> bool {
        if let Some(nets) = pin_pos_to_nets.get(&pt) {
            nets.iter().any(|&n| n != current_net)
        } else {
            false
        }
    };

    let wire_hits = |w: &Wire| -> bool {
        if w.y1 == w.y2 {
            let (lo, hi) = minmax(w.x1, w.x2);
            let step = GRID_RES;
            let mut x = lo + step;
            while x < hi {
                if is_foreign((x, w.y1)) {
                    return true;
                }
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

    let corner_a = (to.0, from.1);
    let wires_a = l_shape_wires(net_idx, from, to);
    let a_hits_corner = is_foreign(corner_a) && corner_a != from && corner_a != to;
    let a_hits_segment = wires_a.iter().any(|w| wire_hits(w));

    let corner_b = (from.0, to.1);
    let wires_b = l_shape_wires_vfirst(net_idx, from, to);
    let b_hits_corner = is_foreign(corner_b) && corner_b != from && corner_b != to;
    let b_hits_segment = wires_b.iter().any(|w| wire_hits(w));

    if !a_hits_corner && !a_hits_segment {
        wires_a
    } else if !b_hits_corner && !b_hits_segment {
        wires_b
    } else {
        Vec::new()
    }
}

// ---------------------------------------------------------------------------
// Label placement
// ---------------------------------------------------------------------------

/// Place net labels at each pin position for a Label-strategy net.
pub fn place_labels_for_net(net_idx: u32, positions: &[(i32, i32)], labels: &mut Vec<Label>) {
    if positions.is_empty() {
        return;
    }

    if positions.len() == 1 {
        labels.push(Label { net_idx, x: positions[0].0, y: positions[0].1, rotation: 0 });
        return;
    }

    let cx: i32 = positions.iter().map(|p| p.0).sum::<i32>() / positions.len() as i32;
    let cy: i32 = positions.iter().map(|p| p.1).sum::<i32>() / positions.len() as i32;

    for &(px, py) in positions {
        labels.push(Label { net_idx, x: px, y: py, rotation: label_rotation(px, py, cx, cy) });
    }
}

/// Pick label rotation so it points away from the centroid.
pub fn label_rotation(from_x: i32, from_y: i32, to_x: i32, to_y: i32) -> u8 {
    let dx = to_x - from_x;
    let dy = to_y - from_y;
    if dx.abs() >= dy.abs() {
        if dx >= 0 { 2 } else { 0 }
    } else {
        if dy >= 0 { 1 } else { 3 }
    }
}

// ---------------------------------------------------------------------------
// Wire post-processing
// ---------------------------------------------------------------------------

/// Optimize wire segments: merge collinear, restore T-junctions, deduplicate.
pub fn optimize_wires(wires: &mut Vec<Wire>, labels: &mut Vec<Label>, nets: &[Net]) {
    *wires = merge_collinear_wires(wires);
    *wires = restore_t_junctions(wires);
    let taken = std::mem::take(wires);
    *wires = deduplicate_wires(taken, labels, nets);
}

/// Merge collinear wire segments that share an endpoint and lie on the same axis.
pub fn merge_collinear_wires(wires: &[Wire]) -> Vec<Wire> {
    if wires.is_empty() {
        return Vec::new();
    }

    let mut by_net: HashMap<u32, Vec<Wire>> = HashMap::new();
    for w in wires {
        by_net.entry(w.net_idx).or_default().push(*w);
    }

    let mut result = Vec::new();
    for (net_idx, mut net_wires) in by_net {
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

        result.extend(merge_segments_1d(net_idx, &horiz, true));
        result.extend(merge_segments_1d(net_idx, &vert, false));
        result.extend(other);
    }

    result.sort_by(|a, b| {
        a.net_idx.cmp(&b.net_idx)
            .then(a.x1.cmp(&b.x1))
            .then(a.y1.cmp(&b.y1))
            .then(a.x2.cmp(&b.x2))
            .then(a.y2.cmp(&b.y2))
    });

    result
}

fn merge_segments_1d(net_idx: u32, segments: &[Wire], is_horizontal: bool) -> Vec<Wire> {
    if segments.is_empty() {
        return Vec::new();
    }

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
        intervals.sort();
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
                continue;
            }
            if is_horizontal {
                result.push(Wire { net_idx, x1: lo, y1: shared, x2: hi, y2: shared });
            } else {
                result.push(Wire { net_idx, x1: shared, y1: lo, x2: shared, y2: hi });
            }
        }
    }

    result
}

/// Restore T-junctions by splitting wires at interior crossings.
pub fn restore_t_junctions(wires: &[Wire]) -> Vec<Wire> {
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

        let mut h_splits: Vec<Vec<i32>> = vec![Vec::new(); horiz.len()];
        let mut v_splits: Vec<Vec<i32>> = vec![Vec::new(); vert.len()];

        for (hi, h) in horiz.iter().enumerate() {
            let hy = h.y1;
            let (hx_lo, hx_hi) = minmax(h.x1, h.x2);
            for (vi, v) in vert.iter().enumerate() {
                let vx = v.x1;
                let (vy_lo, vy_hi) = minmax(v.y1, v.y2);
                if vx > hx_lo && vx < hx_hi && hy > vy_lo && hy < vy_hi {
                    h_splits[hi].push(vx);
                    v_splits[vi].push(hy);
                }
            }
        }

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
                        result.push(Wire { net_idx: *net_idx, x1: pair[0], y1: h.y1, x2: pair[1], y2: h.y1 });
                    }
                }
            }
        }

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
                        result.push(Wire { net_idx: *net_idx, x1: v.x1, y1: pair[0], x2: v.x1, y2: pair[1] });
                    }
                }
            }
        }
    }

    result
}

fn normalize_wire_coords(w: &Wire) -> (i32, i32, i32, i32) {
    if (w.x1, w.y1) <= (w.x2, w.y2) {
        (w.x1, w.y1, w.x2, w.y2)
    } else {
        (w.x2, w.y2, w.x1, w.y1)
    }
}

fn deduplicate_wires(wires: Vec<Wire>, labels: &mut Vec<Label>, nets: &[Net]) -> Vec<Wire> {
    let mut seen: HashMap<(i32, i32, i32, i32), u32> = HashMap::new();
    let mut result = Vec::new();
    let mut conflict_nets: HashSet<u32> = HashSet::new();

    for w in &wires {
        let key = normalize_wire_coords(w);
        if let Some(&existing_net) = seen.get(&key) {
            if existing_net != w.net_idx {
                conflict_nets.insert(w.net_idx);
            }
        } else {
            seen.insert(key, w.net_idx);
        }
    }

    seen.clear();
    for w in &wires {
        if conflict_nets.contains(&w.net_idx) {
            continue;
        }
        let key = normalize_wire_coords(w);
        if seen.contains_key(&key) {
            continue;
        }
        seen.insert(key, w.net_idx);
        result.push(*w);
    }

    for &net_idx in &conflict_nets {
        if (net_idx as usize) < nets.len() {
            let net = &nets[net_idx as usize];
            let has_label = labels.iter().any(|l| l.net_idx == net_idx);
            if !has_label && !net.pins.is_empty() {
                labels.push(Label { net_idx, x: 0, y: 0, rotation: 0 });
            }
        }
    }

    result
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

pub fn minmax(a: i32, b: i32) -> (i32, i32) {
    if a <= b { (a, b) } else { (b, a) }
}

/// Manhattan distance between two points (schematic units).
pub fn manhattan(a: (i32, i32), b: (i32, i32)) -> i32 {
    (a.0 - b.0).abs() + (a.1 - b.1).abs()
}

/// Total Manhattan span of a set of positions.
pub fn manhattan_span(positions: &[(i32, i32)]) -> i32 {
    if positions.is_empty() {
        return 0;
    }
    let min_x = positions.iter().map(|p| p.0).min().unwrap();
    let max_x = positions.iter().map(|p| p.0).max().unwrap();
    let min_y = positions.iter().map(|p| p.1).min().unwrap();
    let max_y = positions.iter().map(|p| p.1).max().unwrap();
    (max_x - min_x) + (max_y - min_y)
}
