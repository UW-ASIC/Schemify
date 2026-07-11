//! Segment geometry: crossing predicates and the bucketed wire index the
//! A* crossing penalty queries.

use super::*;

/// Spatial bucket index over routed wire segments. Each segment is inserted
/// into every CROSSING_BUCKET-sized cell it touches; an A* step (GRID_RES
/// long) queries at most 2 cells instead of scanning all routed wires.
///
/// Also tracks which routed segments already conductively touch each other
/// (directly or transitively) with a union-find, so candidate scoring can
/// count only NEW cross-net merges: a foreign segment already reachable
/// from one of the candidate net's own pin points adds no new short no
/// matter what gets drawn.
#[derive(Default)]
pub(crate) struct WireIndex {
    /// All routed segments, by id.
    segs: Vec<(i32, i32, i32, i32)>,
    /// Spatial buckets of segment ids.
    buckets: HashMap<(i32, i32), Vec<u32>>,
    /// Union-find parent per segment id (existing conductive contacts).
    parent: Vec<u32>,
}

/// Iterate the bucket cells overlapped by a segment's bounding box.
pub(crate) fn bucket_range(seg: (i32, i32, i32, i32)) -> impl Iterator<Item = (i32, i32)> {
    let (bx_lo, bx_hi) = minmax(
        seg.0.div_euclid(CROSSING_BUCKET),
        seg.2.div_euclid(CROSSING_BUCKET),
    );
    let (by_lo, by_hi) = minmax(
        seg.1.div_euclid(CROSSING_BUCKET),
        seg.3.div_euclid(CROSSING_BUCKET),
    );
    (bx_lo..=bx_hi).flat_map(move |bx| (by_lo..=by_hi).map(move |by| (bx, by)))
}

impl WireIndex {
    /// Union-find root of a segment id (no path compression; chains are
    /// short and lookups need only `&self`).
    pub(crate) fn find(&self, mut i: u32) -> u32 {
        while self.parent[i as usize] != i {
            i = self.parent[i as usize];
        }
        i
    }

    pub(crate) fn add(&mut self, seg: (i32, i32, i32, i32)) {
        let id = self.segs.len() as u32;
        self.segs.push(seg);
        self.parent.push(id);
        // Merge with already-routed segments this one conductively touches
        // (same-net T-joints AND any pre-existing cross-net contacts).
        for cell in bucket_range(seg) {
            if let Some(ids) = self.buckets.get(&cell) {
                for &j in ids {
                    if conductive_touch(seg, self.segs[j as usize]) {
                        let (ra, rb) = (self.find(id), self.find(j));
                        if ra != rb {
                            self.parent[ra as usize] = rb;
                        }
                    }
                }
            }
        }
        for cell in bucket_range(seg) {
            self.buckets.entry(cell).or_default().push(id);
        }
    }

    /// Does the (short, axis-aligned) segment a-b properly cross any indexed wire?
    pub(crate) fn crosses(&self, a: (i32, i32), b: (i32, i32)) -> bool {
        for cell in bucket_range((a.0, a.1, b.0, b.1)) {
            if let Some(ids) = self.buckets.get(&cell) {
                for &id in ids {
                    let (x1, y1, x2, y2) = self.segs[id as usize];
                    if orthogonal_segments_intersect(a.0, a.1, b.0, b.1, x1, y1, x2, y2) {
                        return true;
                    }
                }
            }
        }
        false
    }

    /// Count indexed wires the (axis-aligned) segment properly crosses.
    /// Bucket-deduped so a wire spanning several buckets counts once.
    pub(crate) fn count_crossings(&self, seg: (i32, i32, i32, i32)) -> u32 {
        let mut seen: Vec<u32> = Vec::new();
        for cell in bucket_range(seg) {
            if let Some(ids) = self.buckets.get(&cell) {
                for &id in ids {
                    if seen.contains(&id) {
                        continue;
                    }
                    let (x1, y1, x2, y2) = self.segs[id as usize];
                    if orthogonal_segments_intersect(seg.0, seg.1, seg.2, seg.3, x1, y1, x2, y2) {
                        seen.push(id);
                    }
                }
            }
        }
        seen.len() as u32
    }

    /// Is the point on any indexed (foreign) wire segment, endpoints
    /// inclusive? A path point there becomes a cross-net T-touch /
    /// coincident-point / collinear short once emitted.
    pub(crate) fn point_on_any(&self, p: (i32, i32)) -> bool {
        let b = (p.0.div_euclid(CROSSING_BUCKET), p.1.div_euclid(CROSSING_BUCKET));
        self.buckets.get(&b).is_some_and(|ids| {
            ids.iter()
                .any(|&id| point_on_wire(p, self.segs[id as usize]))
        })
    }

    /// Union-find roots of all indexed segments containing point `p`.
    pub(crate) fn roots_at_point(&self, p: (i32, i32), out: &mut Vec<u32>) {
        let b = (p.0.div_euclid(CROSSING_BUCKET), p.1.div_euclid(CROSSING_BUCKET));
        if let Some(ids) = self.buckets.get(&b) {
            for &id in ids {
                if point_on_wire(p, self.segs[id as usize]) {
                    let r = self.find(id);
                    if !out.contains(&r) {
                        out.push(r);
                    }
                }
            }
        }
    }

    /// Count the NEW cross-net merges the candidate segment would create:
    /// distinct connected components (by existing conductive contact) of
    /// indexed foreign wires that the candidate touches (see
    /// `conductive_touch`) and that are NOT already reachable from one of
    /// the `exempt` points (the candidate net's own pins, fixed by
    /// placement — anything already touching them is merged with this net
    /// regardless of what gets drawn). Every count here becomes an
    /// electrical short once core's `resolve_connectivity` runs (R8).
    pub(crate) fn count_touches(&self, seg: (i32, i32, i32, i32), exempt: &[(i32, i32)]) -> u32 {
        let mut exempt_roots: Vec<u32> = Vec::new();
        for &p in exempt {
            self.roots_at_point(p, &mut exempt_roots);
        }
        let mut new_roots: Vec<u32> = Vec::new();
        for cell in bucket_range(seg) {
            if let Some(ids) = self.buckets.get(&cell) {
                for &id in ids {
                    if conductive_touch(seg, self.segs[id as usize]) {
                        let r = self.find(id);
                        if !exempt_roots.contains(&r) && !new_roots.contains(&r) {
                            new_roots.push(r);
                        }
                    }
                }
            }
        }
        new_roots.len() as u32
    }
}

/// Crossing lookup for the net being routed: the global spatial index plus a
/// small linear list of this net's own segments routed so far.
pub(crate) struct CrossingCtx<'a> {
    pub(crate) index: &'a WireIndex,
    pub(crate) own: &'a [(i32, i32, i32, i32)],
}

impl CrossingCtx<'_> {
    pub(crate) fn crosses(&self, a: (i32, i32), b: (i32, i32)) -> bool {
        self.index.crosses(a, b) || segments_cross(a, b, self.own)
    }
}

// ---------------------------------------------------------------------------
// Multi-pin net routing
// ---------------------------------------------------------------------------

/// Check if the segment (a->b) crosses any of the existing wire segments.
pub(crate) fn segments_cross(a: (i32, i32), b: (i32, i32), existing_wires: &[(i32, i32, i32, i32)]) -> bool {
    existing_wires
        .iter()
        .any(|&(x1, y1, x2, y2)| orthogonal_segments_intersect(a.0, a.1, b.0, b.1, x1, y1, x2, y2))
}

/// Check if two axis-aligned segments intersect (proper crossing, not shared endpoints).
#[allow(clippy::too_many_arguments)]
pub(crate) fn orthogonal_segments_intersect(
    ax1: i32,
    ay1: i32,
    ax2: i32,
    ay2: i32,
    bx1: i32,
    by1: i32,
    bx2: i32,
    by2: i32,
) -> bool {
    let a_horiz = ay1 == ay2;
    let a_vert = ax1 == ax2;
    let b_horiz = by1 == by2;
    let b_vert = bx1 == bx2;

    // Only perpendicular pairs can properly cross.
    if a_horiz && b_vert {
        let (a_min_x, a_max_x) = minmax(ax1, ax2);
        let (b_min_y, b_max_y) = minmax(by1, by2);
        // Strict intersection (not endpoint touching).
        bx1 > a_min_x && bx1 < a_max_x && ay1 > b_min_y && ay1 < b_max_y
    } else if a_vert && b_horiz {
        let (b_min_x, b_max_x) = minmax(bx1, bx2);
        let (a_min_y, a_max_y) = minmax(ay1, ay2);
        ax1 > b_min_x && ax1 < b_max_x && by1 > a_min_y && by1 < a_max_y
    } else {
        false
    }
}

pub(crate) fn minmax(a: i32, b: i32) -> (i32, i32) {
    if a <= b {
        (a, b)
    } else {
        (b, a)
    }
}

// ---------------------------------------------------------------------------
// Cross-net conductive-touch legality
// ---------------------------------------------------------------------------
//
// Core's `resolve_connectivity` is a point-keyed union-find over wire
// endpoints plus T-junction detection (wire endpoint ON another wire's
// interior) plus pin-on-wire merging. For two wires of DIFFERENT nets that
// means:
//   * shared endpoint point            -> connected (same union-find key),
//   * endpoint on the other's interior -> connected (T-junction),
//   * collinear overlap                -> connected (always implies an
//                                         endpoint of one lying on the other),
//   * pure perpendicular X-crossing
//     (both interiors, no endpoint on
//     the other segment)               -> NOT connected (legal).
// So the router's legality rule is exactly: no endpoint of either segment
// may lie ON the other segment (endpoints inclusive). X-crossings stay legal.

/// Is `p` on the axis-aligned segment `s` (endpoints inclusive)?
pub(crate) fn point_on_wire(p: (i32, i32), s: (i32, i32, i32, i32)) -> bool {
    let (x1, y1, x2, y2) = s;
    if y1 == y2 {
        let (lo, hi) = minmax(x1, x2);
        p.1 == y1 && lo <= p.0 && p.0 <= hi
    } else if x1 == x2 {
        let (lo, hi) = minmax(y1, y2);
        p.0 == x1 && lo <= p.1 && p.1 <= hi
    } else {
        false
    }
}

/// Conductive touch between two axis-aligned segments: any endpoint of one
/// lying ON the other (endpoints inclusive). Per the rules above this is
/// exactly the condition under which core's connectivity engine merges
/// them; pure perpendicular X-crossings return false (legal).
pub(crate) fn conductive_touch(c: (i32, i32, i32, i32), f: (i32, i32, i32, i32)) -> bool {
    point_on_wire((c.0, c.1), f)
        || point_on_wire((c.2, c.3), f)
        || point_on_wire((f.0, f.1), c)
        || point_on_wire((f.2, f.3), c)
}

// ---------------------------------------------------------------------------
// Path -> Wire conversion
// ---------------------------------------------------------------------------
