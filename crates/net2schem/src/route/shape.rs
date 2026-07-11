//! L-shape fallback routing and detour sweeps, with foreign-pin clearance
//! checks (`LShapeSafety`): upstream cktimg wire reuse lacks foreign-pin
//! clearance, so the safety net lives here (see tests/rules.rs).

use super::*;

/// Context for safe L-shape generation (foreign-pin + foreign-wire +
/// component-body avoidance).
pub(crate) struct LShapeSafety<'a> {
    pub(crate) pin_pos_to_nets: &'a HashMap<(i32, i32), Vec<usize>>,
    pub(crate) current_net: usize,
    pub(crate) obstacles: &'a BitGrid,
    /// Routed segments of previously routed (foreign) nets: candidate
    /// endpoints/corners must not land on them and collinear overlap is
    /// forbidden (X-crossings are fine) — see `conductive_touch`.
    pub(crate) foreign_wires: &'a WireIndex,
}

impl LShapeSafety<'_> {
    /// Does this point sit on a pin belonging to another net?
    pub(crate) fn is_foreign(&self, pt: (i32, i32)) -> bool {
        match self.pin_pos_to_nets.get(&pt) {
            Some(nets) => nets.iter().any(|&n| n != self.current_net),
            None => false,
        }
    }

    /// Score collision damage of a candidate L: foreign-pin hits and
    /// foreign-wire conductive touches weigh 100 each (electrical shorts —
    /// trip R8), component-body crossings and wire X-crossings weigh 1
    /// (cosmetic — R6/Q4). Start/end pin cells are exempt. A score of 0
    /// means the L is clean; anything else sends the caller to the detour
    /// sweep, which picks the least-damaging shape crossing-aware.
    pub(crate) fn hit_score(&self, wires: &[Wire], corner: (i32, i32), from: (i32, i32), to: (i32, i32)) -> u32 {
        const PIN_HIT: u32 = 100;
        let mut score = 0u32;
        if self.is_foreign(corner) && corner != from && corner != to {
            score += PIN_HIT;
        }
        let from_grid = (from.0 / GRID_RES, from.1 / GRID_RES);
        let to_grid = (to.0 / GRID_RES, to.1 / GRID_RES);
        for w in wires {
            score += PIN_HIT
                * self
                    .foreign_wires
                    .count_touches((w.x1, w.y1, w.x2, w.y2), &[from, to]);
            score += self.foreign_wires.count_crossings((w.x1, w.y1, w.x2, w.y2));
            let (horiz, fixed, lo, hi) = if w.y1 == w.y2 {
                let (lo, hi) = minmax(w.x1, w.x2);
                (true, w.y1, lo, hi)
            } else {
                let (lo, hi) = minmax(w.y1, w.y2);
                (false, w.x1, lo, hi)
            };
            let mut v = lo + GRID_RES;
            while v < hi {
                let pt = if horiz { (v, fixed) } else { (fixed, v) };
                if self.is_foreign(pt) {
                    score += PIN_HIT;
                } else {
                    let gp = (pt.0 / GRID_RES, pt.1 / GRID_RES);
                    if gp != from_grid && gp != to_grid && self.obstacles.get(gp.0, gp.1) {
                        score += 1;
                    }
                }
                v += GRID_RES;
            }
        }
        score
    }

    /// Score an orthogonal polyline (candidate route) for clearance damage:
    /// foreign-pin hits and foreign-wire conductive touches weigh 10000
    /// (electrical shorts — trip R8), component body cells weigh 100 (trip
    /// R6), and proper X-crossings of routed wires weigh 1 (cosmetic — Q4,
    /// breaks ties between otherwise-clean candidates). Interior vertices
    /// and the interior of every segment are checked; the start/end pin
    /// cells are exempt. 0 means the candidate is clean.
    pub(crate) fn score_path(&self, pts: &[(i32, i32)], from: (i32, i32), to: (i32, i32)) -> u32 {
        const PIN_HIT: u32 = 10_000;
        const BODY_HIT: u32 = 100;
        let from_grid = (from.0 / GRID_RES, from.1 / GRID_RES);
        let to_grid = (to.0 / GRID_RES, to.1 / GRID_RES);
        let mut score = 0u32;
        let check = |pt: (i32, i32)| {
            if pt == from || pt == to {
                return 0;
            }
            if self.is_foreign(pt) {
                return PIN_HIT;
            }
            let gp = (pt.0 / GRID_RES, pt.1 / GRID_RES);
            if gp != from_grid && gp != to_grid && self.obstacles.get(gp.0, gp.1) {
                return BODY_HIT;
            }
            0
        };
        // Interior vertices (corners between segments).
        if pts.len() > 2 {
            for &p in &pts[1..pts.len() - 1] {
                score += check(p);
            }
        }
        // Interior points of each segment, on the routing grid.
        for seg in pts.windows(2) {
            let (a, b) = (seg[0], seg[1]);
            if a == b {
                continue;
            }
            // Conductive touches against foreign routed wires (T-touch,
            // coincident endpoints, collinear overlap) — same weight as a
            // foreign-pin short.
            score += PIN_HIT
                * self
                    .foreign_wires
                    .count_touches((a.0, a.1, b.0, b.1), &[from, to]);
            // Proper X-crossings: cosmetic, lowest weight (Q4).
            score += self.foreign_wires.count_crossings((a.0, a.1, b.0, b.1));
            let (horiz, fixed, lo, hi) = if a.1 == b.1 {
                let (lo, hi) = minmax(a.0, b.0);
                (true, a.1, lo, hi)
            } else {
                let (lo, hi) = minmax(a.1, b.1);
                (false, a.0, lo, hi)
            };
            let mut v = lo + GRID_RES;
            while v < hi {
                score += check(if horiz { (v, fixed) } else { (fixed, v) });
                v += GRID_RES;
            }
        }
        score
    }
}

/// Generate L-shape wire segments between two points.
///
/// This is the single parameterized replacement for the old
/// `l_shape_wires` / `l_shape_wires_vfirst` / `l_shape_wires_safe` trio:
/// * `vertical_first` selects the preferred bend direction (false =
///   horizontal-then-vertical, the old default).
/// * With `safety: Some(..)`, the preferred orientation is checked for
///   foreign-pin / component-body collisions; if it hits, the other
///   orientation is tried; if both hit, an empty vec is returned (caller
///   falls back to labels). With `safety: None` the preferred orientation is
///   returned unconditionally.
pub(crate) fn l_shape(
    net_idx: NetId,
    from: (i32, i32),
    to: (i32, i32),
    vertical_first: bool,
    safety: Option<&LShapeSafety>,
) -> Vec<Wire> {
    let bare = |vfirst: bool| -> (Vec<Wire>, (i32, i32)) {
        let corner = if vfirst {
            (from.0, to.1)
        } else {
            (to.0, from.1)
        };
        let mut wires = Vec::new();
        for (a, b) in [(from, corner), (corner, to)] {
            if a != b {
                wires.push(Wire {
                    net_idx,
                    x1: a.0,
                    y1: a.1,
                    x2: b.0,
                    y2: b.1,
                });
            }
        }
        (wires, corner)
    };

    match safety {
        None => bare(vertical_first).0,
        Some(ctx) => {
            for vfirst in [vertical_first, !vertical_first] {
                let (wires, corner) = bare(vfirst);
                if ctx.hit_score(&wires, corner, from, to) == 0 {
                    return wires;
                }
            }
            Vec::new() // Both L-shapes hit obstacles -> caller escalates.
        }
    }
}

/// Trunk-offset steps (schematic units) swept by `best_detour`, in
/// preference order (small detours first). Pins sit on GRID_RES multiples,
/// so shifting the trunk line by grid steps threads it between pin rows.
/// The large tail offsets (±220 and beyond) let long row/column-spanning
/// nets in dense arrays escape AROUND the array entirely: inside it, every
/// near corridor is either a body band or already carries other nets'
/// trunks/corners (conductive-touch penalties), so without far escapes the
/// sweep degenerates to body plows (R6) or cross-net touches (R8).
pub(crate) const DETOUR_OFFSETS: [i32; 32] = [
    10, -10, 20, -20, 30, -30, 40, -40, 60, -60, 90, -90, 130, -130, 180, -180, 220, -220, 260,
    -260, 300, -300, 350, -350, 410, -410, 480, -480, 560, -560, 650, -650,
];

/// Last-resort routing for a pin pair: sweep L-shape and Z/U-shape detour
/// candidates whose trunk line is shifted off the pin rows, score each for
/// foreign-pin / body collisions, and return the least damaging one.
///
/// Candidates, in preference order:
///  * both L-shapes (horizontal-first, vertical-first),
///  * midpoint Z-shapes (trunk halfway between the pins),
///  * Z/U-shapes with a horizontal trunk at `from.y`/`to.y` ± offset,
///  * Z/U-shapes with a vertical trunk at `from.x`/`to.x` ± offset,
///  * leg-shifted U-shapes (legs stepped off the pin rows/columns, short
///    stubs into the pins) for array layouts whose pin lanes carry foreign
///    trunks.
/// The U-shapes (offset trunk when the pins are collinear) are what lets a
/// long row-spanning connection escape above/below a row of components
/// instead of cutting straight through every body.
///
/// Always returns at least one wire for `from != to` (strict Q5). Scoring is
/// 0 for a fully legal candidate; ties keep the earliest (simplest/shortest)
/// candidate.
pub(crate) fn best_detour(
    net_idx: NetId,
    from: (i32, i32),
    to: (i32, i32),
    safety: &LShapeSafety,
) -> Vec<Wire> {
    let mut candidates: Vec<Vec<(i32, i32)>> =
        Vec::with_capacity(4 + DETOUR_OFFSETS.len() * 4 * (1 + LEG_SHIFTS.len()));

    // L-shapes.
    candidates.push(vec![from, (to.0, from.1), to]);
    candidates.push(vec![from, (from.0, to.1), to]);

    // Midpoint Z-shapes.
    let ym = snap((from.1 + to.1) / 2, GRID_RES);
    let xm = snap((from.0 + to.0) / 2, GRID_RES);
    candidates.push(vec![from, (from.0, ym), (to.0, ym), to]);
    candidates.push(vec![from, (xm, from.1), (xm, to.1), to]);

    // Offset-trunk Z/U-shapes.
    for &off in &DETOUR_OFFSETS {
        for base in [from.1, to.1] {
            let y = base + off;
            candidates.push(vec![from, (from.0, y), (to.0, y), to]);
        }
        for base in [from.0, to.0] {
            let x = base + off;
            candidates.push(vec![from, (x, from.1), (x, to.1), to]);
        }
    }

    // Leg-shifted U-shapes: like the offset-trunk family but with both
    // legs stepped laterally off the pin rows/columns by `s`, reaching the
    // pins through short stubs. In array layouts the pin columns themselves
    // carry foreign trunks (e.g. bitlines), so any leg running along them
    // conductively touches no matter where the trunk goes; one or two grid
    // cells sideways is usually a clean lane. Listed after the simpler
    // families so they only win when the simple shapes are all dirty.
    // Shifts beyond ±20 reach the middle of the inter-column lanes (column
    // pitch ~160, body width ~40 → ~12 free tracks between columns) when the
    // tracks hugging the bodies are taken.
    const LEG_SHIFTS: [i32; 10] = [10, -10, 20, -20, 30, -30, 40, -40, 60, -60];
    for &off in &DETOUR_OFFSETS {
        for base in [from.1, to.1] {
            let y = base + off;
            for &s in &LEG_SHIFTS {
                candidates.push(vec![
                    from,
                    (from.0 + s, from.1),
                    (from.0 + s, y),
                    (to.0 + s, y),
                    (to.0 + s, to.1),
                    to,
                ]);
            }
        }
        for base in [from.0, to.0] {
            let x = base + off;
            for &s in &LEG_SHIFTS {
                candidates.push(vec![
                    from,
                    (from.0, from.1 + s),
                    (x, from.1 + s),
                    (x, to.1 + s),
                    (to.0, to.1 + s),
                    to,
                ]);
            }
        }
    }

    let mut best: Option<(u32, usize)> = None;
    for (i, cand) in candidates.iter().enumerate() {
        let score = safety.score_path(cand, from, to);
        if best.map_or(true, |(bs, _)| score < bs) {
            best = Some((score, i));
            if score == 0 {
                break; // Earliest clean candidate wins.
            }
        }
    }

    let (best_score, best_i) = best.expect("non-empty candidate list");
    if best_score > 0 && std::env::var_os("N2S_DETOUR_DEBUG").is_some() {
        eprintln!(
            "[detour] net {} {:?}->{:?}: best score {} (cand #{}/{})",
            net_idx.0,
            from,
            to,
            best_score,
            best_i,
            candidates.len()
        );
    }
    let pts = &candidates[best_i];
    pts.windows(2)
        .filter(|seg| seg[0] != seg[1])
        .map(|seg| Wire {
            net_idx,
            x1: seg[0].0,
            y1: seg[0].1,
            x2: seg[1].0,
            y2: seg[1].1,
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Label placement
// ---------------------------------------------------------------------------
