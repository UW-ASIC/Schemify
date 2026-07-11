//! Wire post-processing: collinear merge, T-junction restore, dedupe.

use super::*;

/// Optimize wire segments: merge collinear, restore T-junctions, deduplicate.
/// Order matters — each step depends on the previous.
pub(crate) fn optimize_wires(wires: &mut Vec<Wire>) {
    *wires = merge_collinear_wires(wires);
    *wires = restore_t_junctions(wires);
    // Drop exact duplicate segments (same coords, any net); first occurrence
    // wins. A later net sharing the same geometry keeps its *other* segments
    // — strict Q5: a Wire-classified net never loses all its wires. (The old
    // behavior dropped the entire conflicting net and fell back to labels.)
    let mut seen: HashSet<(i32, i32, i32, i32)> = HashSet::new();
    wires.retain(|w| seen.insert(normalize_wire_coords(w)));
}

/// Merge collinear wire segments that share an endpoint and lie on the same axis.
pub(crate) fn merge_collinear_wires(wires: &[Wire]) -> Vec<Wire> {
    if wires.is_empty() {
        return Vec::new();
    }

    // Group wires by net_idx. BTreeMap: deterministic output order.
    let mut by_net: std::collections::BTreeMap<NetId, Vec<Wire>> =
        std::collections::BTreeMap::new();
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
/// `is_horizontal`: if true, segments share Y and merge along X; otherwise
/// they share X and merge along Y.
pub(crate) fn merge_segments_1d(net_idx: NetId, segments: &[Wire], is_horizontal: bool) -> Vec<Wire> {
    if segments.is_empty() {
        return Vec::new();
    }

    // Group by the shared coordinate.
    let mut groups: HashMap<i32, Vec<(i32, i32)>> = HashMap::new();
    for w in segments {
        let (shared, a, b) = if is_horizontal {
            let (a, b) = minmax(w.x1, w.x2);
            (w.y1, a, b)
        } else {
            let (a, b) = minmax(w.y1, w.y2);
            (w.x1, a, b)
        };
        groups.entry(shared).or_default().push((a, b));
    }

    let mut result = Vec::new();
    for (shared, mut intervals) in groups {
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
            result.push(if is_horizontal {
                Wire {
                    net_idx,
                    x1: lo,
                    y1: shared,
                    x2: hi,
                    y2: shared,
                }
            } else {
                Wire {
                    net_idx,
                    x1: shared,
                    y1: lo,
                    x2: shared,
                    y2: hi,
                }
            });
        }
    }

    result
}

// ---------------------------------------------------------------------------
// T-junction restoration
// ---------------------------------------------------------------------------

/// After merging collinear segments, interior crossing points between
/// same-net horizontal and vertical wires lose their T-junction endpoints.
/// Schematic formats only connect wires at shared endpoints, not at interior
/// crossings, so split wires at such crossings to restore T-junctions.
pub(crate) fn restore_t_junctions(wires: &[Wire]) -> Vec<Wire> {
    // Group wires by net. BTreeMap: deterministic output order.
    let mut by_net: std::collections::BTreeMap<NetId, Vec<Wire>> =
        std::collections::BTreeMap::new();
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

        // Collect interior crossing split points for each wire.
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

        // Split a wire at the collected points along its axis.
        let mut split_at = |w: &Wire, splits: &[i32], horizontal: bool| {
            if splits.is_empty() {
                result.push(*w);
                return;
            }
            let mut pts = splits.to_vec();
            let (lo, hi) = if horizontal {
                minmax(w.x1, w.x2)
            } else {
                minmax(w.y1, w.y2)
            };
            pts.push(lo);
            pts.push(hi);
            pts.sort();
            pts.dedup();
            for pair in pts.windows(2) {
                if pair[0] != pair[1] {
                    result.push(if horizontal {
                        Wire {
                            net_idx: *net_idx,
                            x1: pair[0],
                            y1: w.y1,
                            x2: pair[1],
                            y2: w.y1,
                        }
                    } else {
                        Wire {
                            net_idx: *net_idx,
                            x1: w.x1,
                            y1: pair[0],
                            x2: w.x1,
                            y2: pair[1],
                        }
                    });
                }
            }
        };

        for (i, h) in horiz.iter().enumerate() {
            split_at(h, &h_splits[i], true);
        }
        for (i, v) in vert.iter().enumerate() {
            split_at(v, &v_splits[i], false);
        }
    }

    result
}

// ---------------------------------------------------------------------------
// Wire deduplication
// ---------------------------------------------------------------------------

/// Normalize wire coordinates so (x1,y1) <= (x2,y2) lexicographically.
pub(crate) fn normalize_wire_coords(w: &Wire) -> (i32, i32, i32, i32) {
    if (w.x1, w.y1) <= (w.x2, w.y2) {
        (w.x1, w.y1, w.x2, w.y2)
    } else {
        (w.x2, w.y2, w.x1, w.y1)
    }
}

// ---------------------------------------------------------------------------
// Utility functions
// ---------------------------------------------------------------------------

/// Manhattan distance between two points (schematic units or grid cells).
pub(crate) fn manhattan(a: (i32, i32), b: (i32, i32)) -> i32 {
    (a.0 - b.0).abs() + (a.1 - b.1).abs()
}

/// Total Manhattan span of a set of positions (max - min over x and y).
pub(crate) fn manhattan_span(positions: &[(i32, i32)]) -> i32 {
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
