//! Hit-testing and the uniform-grid spatial index used for culling.


use rustc_hash::{FxHashMap, FxHashSet};

use crate::schemify::{
    self as prim, Color, DeviceKind, Schematic,
};

use super::*;

pub const SELECT_HIT_RADIUS_SQ: f64 = 400.0;
pub(crate) const HIT_TOL: f64 = 20.0; // sqrt of SELECT_HIT_RADIUS_SQ

/// Squared distance from point (px,py) to line segment (ax,ay)-(bx,by).
pub fn point_to_segment_dist_sq(px: f64, py: f64, ax: f64, ay: f64, bx: f64, by: f64) -> f64 {
    let abx = bx - ax;
    let aby = by - ay;
    let len2 = abx * abx + aby * aby;
    if len2 <= 0.0 {
        let dx = px - ax;
        let dy = py - ay;
        return dx * dx + dy * dy;
    }
    let t = (((px - ax) * abx + (py - ay) * aby) / len2).clamp(0.0, 1.0);
    let dx = px - (ax + t * abx);
    let dy = py - (ay + t * aby);
    dx * dx + dy * dy
}

/// Normalize an angle (in radians) into [0, 2π).
pub(crate) fn normalize_angle(a: f64) -> f64 {
    let twopi = std::f64::consts::TAU;
    ((a % twopi) + twopi) % twopi
}

/// Check if angle `a` falls within the arc from `start` sweeping `sweep` radians.
pub(crate) fn angle_in_arc(a: f64, start: f64, sweep: f64) -> bool {
    if sweep.abs() >= std::f64::consts::TAU {
        return true; // full circle
    }
    let a = normalize_angle(a - start);
    if sweep >= 0.0 {
        a <= sweep
    } else {
        // Negative sweep: arc goes clockwise
        normalize_angle(-a) <= normalize_angle(-sweep)
    }
}

/// Ray-cast point-in-polygon test.
pub(crate) fn point_in_polygon(px: f64, py: f64, pts: &[[i32; 2]]) -> bool {
    let n = pts.len();
    if n < 3 {
        return false;
    }
    let mut inside = false;
    let mut j = n - 1;
    for i in 0..n {
        let (yi, yj) = (pts[i][1] as f64, pts[j][1] as f64);
        let (xi, xj) = (pts[i][0] as f64, pts[j][0] as f64);
        if ((yi > py) != (yj > py)) && (px < (xj - xi) * (py - yi) / (yj - yi) + xi) {
            inside = !inside;
        }
        j = i;
    }
    inside
}

impl App {
    pub fn hit_test_instance(&self, wx: i32, wy: i32) -> Option<usize> {
        let insts = &self.schematic().instances;
        for i in 0..insts.len() {
            let dx = wx as f64 - insts.x[i] as f64;
            let dy = wy as f64 - insts.y[i] as f64;

            let entry =
                prim::find_symbol(self.state.interner.resolve(&insts.symbol[i]), insts.kind[i]);
            let tol_sq = if let Some(entry) = entry {
                let mut max_ext: f64 = 14.0;
                for seg in &entry.segments {
                    max_ext = max_ext
                        .max(seg.x0.unsigned_abs() as f64)
                        .max(seg.y0.unsigned_abs() as f64)
                        .max(seg.x1.unsigned_abs() as f64)
                        .max(seg.y1.unsigned_abs() as f64);
                }
                for pp in &entry.pin_positions {
                    max_ext = max_ext
                        .max(pp.x.unsigned_abs() as f64)
                        .max(pp.y.unsigned_abs() as f64);
                }
                (max_ext + 5.0) * (max_ext + 5.0)
            } else {
                25.0 * 25.0
            };

            if dx * dx + dy * dy < tol_sq {
                return Some(i);
            }
        }
        None
    }

    pub fn hit_test_wire(&self, wx: i32, wy: i32, tol_sq: f64) -> Option<usize> {
        let wires = &self.schematic().wires;
        let (wpx, wpy) = (wx as f64, wy as f64);
        (0..wires.len()).find(|&i| {
            point_to_segment_dist_sq(
                wpx,
                wpy,
                wires.x0[i] as f64,
                wires.y0[i] as f64,
                wires.x1[i] as f64,
                wires.y1[i] as f64,
            ) < tol_sq
        })
    }

    pub fn hit_test_bus(&self, wx: i32, wy: i32, tol_sq: f64) -> Option<usize> {
        let buses = &self.schematic().buses;
        let (wpx, wpy) = (wx as f64, wy as f64);
        (0..buses.len()).find(|&i| {
            point_to_segment_dist_sq(
                wpx,
                wpy,
                buses.x0[i] as f64,
                buses.y0[i] as f64,
                buses.x1[i] as f64,
                buses.y1[i] as f64,
            ) < tol_sq
        })
    }

    pub fn hit_test_bus_ripper(&self, wx: i32, wy: i32) -> Option<usize> {
        self.schematic().bus_rippers.iter().position(|r| {
            let dx = (wx - r.x) as f64;
            let dy = (wy - r.y) as f64;
            dx * dx + dy * dy < SELECT_HIT_RADIUS_SQ
        })
    }

    pub fn hit_test_line(&self, wx: i32, wy: i32) -> Option<usize> {
        let (wpx, wpy) = (wx as f64, wy as f64);
        self.schematic().lines.iter().position(|l| {
            point_to_segment_dist_sq(wpx, wpy, l.x0 as f64, l.y0 as f64, l.x1 as f64, l.y1 as f64)
                < SELECT_HIT_RADIUS_SQ
        })
    }

    pub fn hit_test_rect(&self, wx: i32, wy: i32) -> Option<usize> {
        let tol = HIT_TOL as i32;
        self.schematic().rects.iter().position(|r| {
            wx >= r.x - tol
                && wx <= r.x + r.width + tol
                && wy >= r.y - tol
                && wy <= r.y + r.height + tol
        })
    }

    pub fn hit_test_circle(&self, wx: i32, wy: i32) -> Option<usize> {
        self.schematic().circles.iter().position(|c| {
            let dx = wx as f64 - c.cx as f64;
            let dy = wy as f64 - c.cy as f64;
            let dist = (dx * dx + dy * dy).sqrt();
            let radius = c.radius as f64;
            // Hit if inside (for filled) or near the stroke.
            (c.fill != Color::NONE && dist <= radius + HIT_TOL) || (dist - radius).abs() < HIT_TOL
        })
    }

    pub fn hit_test_arc(&self, wx: i32, wy: i32) -> Option<usize> {
        self.schematic().arcs.iter().position(|a| {
            let dx = wx as f64 - a.cx as f64;
            let dy = wy as f64 - a.cy as f64;
            let dist = (dx * dx + dy * dy).sqrt();
            if (dist - a.radius as f64).abs() >= HIT_TOL {
                return false;
            }
            angle_in_arc(dy.atan2(dx), a.start_angle as f64, a.sweep_angle as f64)
        })
    }

    pub fn hit_test_text(&self, wx: i32, wy: i32) -> Option<usize> {
        let tol = HIT_TOL as i32;
        for (i, t) in self.schematic().texts.iter().enumerate() {
            let content = self.resolve(t.content);
            let approx_w = (content.len() as f32 * t.font_size * 0.6) as i32;
            let approx_h = t.font_size as i32;
            if wx >= t.x - tol
                && wx <= t.x + approx_w + tol
                && wy >= t.y - tol
                && wy <= t.y + approx_h + tol
            {
                return Some(i);
            }
        }
        None
    }

    pub fn hit_test_polygon(&self, wx: i32, wy: i32) -> Option<usize> {
        let (wpx, wpy) = (wx as f64, wy as f64);
        for (i, p) in self.schematic().polygons.iter().enumerate() {
            if p.points.len() < 2 {
                continue;
            }
            // Edge proximity
            for win in p.points.windows(2) {
                let d2 = point_to_segment_dist_sq(
                    wpx,
                    wpy,
                    win[0][0] as f64,
                    win[0][1] as f64,
                    win[1][0] as f64,
                    win[1][1] as f64,
                );
                if d2 < SELECT_HIT_RADIUS_SQ {
                    return Some(i);
                }
            }
            // Closing edge + interior (filled)
            if p.points.len() >= 3 {
                let first = p.points.first().unwrap();
                let last = p.points.last().unwrap();
                let d2 = point_to_segment_dist_sq(
                    wpx,
                    wpy,
                    last[0] as f64,
                    last[1] as f64,
                    first[0] as f64,
                    first[1] as f64,
                );
                if d2 < SELECT_HIT_RADIUS_SQ {
                    return Some(i);
                }
                if p.fill != Color::NONE && point_in_polygon(wpx, wpy, &p.points) {
                    return Some(i);
                }
            }
        }
        None
    }

    /// Combined hit test: tries all types in priority order.
    pub fn hit_test(&self, wx: i32, wy: i32) -> Option<ObjectRef> {
        if let Some(i) = self.hit_test_instance(wx, wy) {
            return Some(ObjectRef::Instance(i as u32));
        }
        if let Some(i) = self.hit_test_wire(wx, wy, SELECT_HIT_RADIUS_SQ) {
            return Some(ObjectRef::Wire(i as u32));
        }
        if let Some(i) = self.hit_test_rect(wx, wy) {
            return Some(ObjectRef::Rect(i as u32));
        }
        if let Some(i) = self.hit_test_circle(wx, wy) {
            return Some(ObjectRef::Circle(i as u32));
        }
        if let Some(i) = self.hit_test_arc(wx, wy) {
            return Some(ObjectRef::Arc(i as u32));
        }
        if let Some(i) = self.hit_test_line(wx, wy) {
            return Some(ObjectRef::Line(i as u32));
        }
        if let Some(i) = self.hit_test_text(wx, wy) {
            return Some(ObjectRef::Text(i as u32));
        }
        if let Some(i) = self.hit_test_polygon(wx, wy) {
            return Some(ObjectRef::Polygon(i as u32));
        }
        None
    }

    /// Select all objects fully contained in the given rectangle.
    pub fn select_in_rect(&mut self, min_x: i32, min_y: i32, max_x: i32, max_y: i32) {
        let doc = self.state.active_document_mut();
        let sch = &doc.schematic;
        let mut objs: Vec<ObjectRef> = Vec::new();

        let in_rect = |x: i32, y: i32| x >= min_x && x <= max_x && y >= min_y && y <= max_y;

        for i in 0..sch.instances.len() {
            if in_rect(sch.instances.x[i], sch.instances.y[i]) {
                objs.push(ObjectRef::Instance(i as u32));
            }
        }
        for i in 0..sch.wires.len() {
            if in_rect(sch.wires.x0[i], sch.wires.y0[i])
                && in_rect(sch.wires.x1[i], sch.wires.y1[i])
            {
                objs.push(ObjectRef::Wire(i as u32));
            }
        }
        for i in 0..sch.buses.len() {
            if in_rect(sch.buses.x0[i], sch.buses.y0[i])
                && in_rect(sch.buses.x1[i], sch.buses.y1[i])
            {
                objs.push(ObjectRef::Bus(i as u32));
            }
        }
        for (i, l) in sch.lines.iter().enumerate() {
            if in_rect(l.x0, l.y0) && in_rect(l.x1, l.y1) {
                objs.push(ObjectRef::Line(i as u32));
            }
        }
        for (i, r) in sch.rects.iter().enumerate() {
            if in_rect(r.x, r.y) && in_rect(r.x + r.width, r.y + r.height) {
                objs.push(ObjectRef::Rect(i as u32));
            }
        }
        for (i, c) in sch.circles.iter().enumerate() {
            if in_rect(c.cx - c.radius, c.cy - c.radius)
                && in_rect(c.cx + c.radius, c.cy + c.radius)
            {
                objs.push(ObjectRef::Circle(i as u32));
            }
        }
        for (i, a) in sch.arcs.iter().enumerate() {
            if in_rect(a.cx - a.radius, a.cy - a.radius)
                && in_rect(a.cx + a.radius, a.cy + a.radius)
            {
                objs.push(ObjectRef::Arc(i as u32));
            }
        }
        for (i, t) in sch.texts.iter().enumerate() {
            if in_rect(t.x, t.y) {
                objs.push(ObjectRef::Text(i as u32));
            }
        }
        for (i, p) in sch.polygons.iter().enumerate() {
            if !p.points.is_empty() && p.points.iter().all(|pt| in_rect(pt[0], pt[1])) {
                objs.push(ObjectRef::Polygon(i as u32));
            }
        }

        doc.selection.objs = objs;
    }

    /// Manhattan routing helper: pick the corner of the L-route.
    pub fn manhattan_route(&self, start: [i32; 2], end: [i32; 2]) -> [i32; 2] {
        let dx = end[0] - start[0];
        let dy = end[1] - start[1];
        if dx.unsigned_abs() >= dy.unsigned_abs() {
            [end[0], start[1]]
        } else {
            [start[0], end[1]]
        }
    }
}

// ════════════════════════════════════════════════════════════
// Spatial index — uniform grid for viewport culling
// ════════════════════════════════════════════════════════════

/// Side length (in schematic units) of each spatial grid cell.
pub(crate) const CELL_SIZE: i32 = 200;

/// Uniform-grid spatial index over schematic objects. Each object is
/// inserted into every cell its AABB overlaps; a viewport query collects
/// entries from the touched cells, deduplicating via a hash set.
pub struct SpatialIndex {
    cells: FxHashMap<(i32, i32), Vec<ObjectRef>>,
}

impl SpatialIndex {
    /// Build a fresh spatial index from the given schematic.
    pub fn rebuild(sch: &Schematic) -> Self {
        let mut cells: FxHashMap<(i32, i32), Vec<ObjectRef>> = FxHashMap::default();

        for i in 0..sch.instances.len() {
            let (x, y) = (sch.instances.x[i], sch.instances.y[i]);
            let half = instance_half_extent(sch.instances.kind[i]);
            insert_aabb(
                &mut cells,
                ObjectRef::Instance(i as u32),
                x - half,
                y - half,
                x + half,
                y + half,
            );
        }
        for i in 0..sch.wires.len() {
            let (x0, y0, x1, y1) = (
                sch.wires.x0[i],
                sch.wires.y0[i],
                sch.wires.x1[i],
                sch.wires.y1[i],
            );
            insert_aabb(
                &mut cells,
                ObjectRef::Wire(i as u32),
                x0.min(x1),
                y0.min(y1),
                x0.max(x1),
                y0.max(y1),
            );
        }
        for i in 0..sch.buses.len() {
            let (x0, y0, x1, y1) = (
                sch.buses.x0[i],
                sch.buses.y0[i],
                sch.buses.x1[i],
                sch.buses.y1[i],
            );
            insert_aabb(
                &mut cells,
                ObjectRef::Bus(i as u32),
                x0.min(x1),
                y0.min(y1),
                x0.max(x1),
                y0.max(y1),
            );
        }
        for (i, l) in sch.lines.iter().enumerate() {
            insert_aabb(
                &mut cells,
                ObjectRef::Line(i as u32),
                l.x0.min(l.x1),
                l.y0.min(l.y1),
                l.x0.max(l.x1),
                l.y0.max(l.y1),
            );
        }
        for (i, r) in sch.rects.iter().enumerate() {
            insert_aabb(
                &mut cells,
                ObjectRef::Rect(i as u32),
                r.x,
                r.y,
                r.x + r.width,
                r.y + r.height,
            );
        }
        for (i, c) in sch.circles.iter().enumerate() {
            insert_aabb(
                &mut cells,
                ObjectRef::Circle(i as u32),
                c.cx - c.radius,
                c.cy - c.radius,
                c.cx + c.radius,
                c.cy + c.radius,
            );
        }
        for (i, a) in sch.arcs.iter().enumerate() {
            // Conservative AABB: full circle bounding box.
            insert_aabb(
                &mut cells,
                ObjectRef::Arc(i as u32),
                a.cx - a.radius,
                a.cy - a.radius,
                a.cx + a.radius,
                a.cy + a.radius,
            );
        }
        for (i, t) in sch.texts.iter().enumerate() {
            // Approximate extents; precise glyph metrics are unavailable here.
            let approx_w = (10.0 * t.font_size * 0.6) as i32;
            let approx_h = t.font_size as i32;
            insert_aabb(
                &mut cells,
                ObjectRef::Text(i as u32),
                t.x,
                t.y,
                t.x + approx_w,
                t.y + approx_h,
            );
        }
        for (i, p) in sch.polygons.iter().enumerate() {
            if p.points.is_empty() {
                continue;
            }
            let mut min_x = i32::MAX;
            let mut min_y = i32::MAX;
            let mut max_x = i32::MIN;
            let mut max_y = i32::MIN;
            for pt in &p.points {
                min_x = min_x.min(pt[0]);
                min_y = min_y.min(pt[1]);
                max_x = max_x.max(pt[0]);
                max_y = max_y.max(pt[1]);
            }
            insert_aabb(
                &mut cells,
                ObjectRef::Polygon(i as u32),
                min_x,
                min_y,
                max_x,
                max_y,
            );
        }

        Self { cells }
    }

    /// All entries whose cells overlap the query rectangle (deduplicated).
    /// Convenience wrapper; hot paths should reuse buffers with
    /// [`SpatialIndex::query_rect_into`].
    pub fn query_rect(&self, min_x: i32, min_y: i32, max_x: i32, max_y: i32) -> Vec<ObjectRef> {
        let mut out = Vec::new();
        let mut seen = FxHashSet::default();
        self.query_rect_into(min_x, min_y, max_x, max_y, &mut out, &mut seen);
        out
    }

    /// Allocation-free variant: both buffers are cleared (capacity retained)
    /// before use, so steady-state queries do not reallocate.
    pub fn query_rect_into(
        &self,
        min_x: i32,
        min_y: i32,
        max_x: i32,
        max_y: i32,
        out: &mut Vec<ObjectRef>,
        seen: &mut FxHashSet<ObjectRef>,
    ) {
        out.clear();
        seen.clear();

        let cx0 = cell_coord(min_x);
        let cy0 = cell_coord(min_y);
        let cx1 = cell_coord(max_x);
        let cy1 = cell_coord(max_y);

        for cy in cy0..=cy1 {
            for cx in cx0..=cx1 {
                if let Some(bucket) = self.cells.get(&(cx, cy)) {
                    out.reserve(bucket.len());
                    seen.reserve(bucket.len());
                    for entry in bucket {
                        if seen.insert(*entry) {
                            out.push(*entry);
                        }
                    }
                }
            }
        }
    }
}

/// Map a world coordinate to a cell index.
#[inline]
pub(crate) fn cell_coord(v: i32) -> i32 {
    v.div_euclid(CELL_SIZE)
}

/// Insert `entry` into every cell that the AABB overlaps.
pub(crate) fn insert_aabb(
    cells: &mut FxHashMap<(i32, i32), Vec<ObjectRef>>,
    entry: ObjectRef,
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,
) {
    let cx0 = cell_coord(min_x);
    let cy0 = cell_coord(min_y);
    let cx1 = cell_coord(max_x);
    let cy1 = cell_coord(max_y);
    for cy in cy0..=cy1 {
        for cx in cx0..=cx1 {
            cells.entry((cx, cy)).or_default().push(entry);
        }
    }
}

/// Conservative half-extent of an instance from its primitive geometry.
/// Falls back to 30 units when no primitive data is available.
pub(crate) fn instance_half_extent(kind: DeviceKind) -> i32 {
    let Some(entry) = prim::find_by_kind(kind) else {
        return 30;
    };
    let mut max_ext: i32 = 14;
    for seg in &entry.segments {
        max_ext = max_ext
            .max(seg.x0.unsigned_abs() as i32)
            .max(seg.y0.unsigned_abs() as i32)
            .max(seg.x1.unsigned_abs() as i32)
            .max(seg.y1.unsigned_abs() as i32);
    }
    for pp in &entry.pin_positions {
        max_ext = max_ext
            .max(pp.x.unsigned_abs() as i32)
            .max(pp.y.unsigned_abs() as i32);
    }
    for c in &entry.circles {
        max_ext = max_ext.max((c.cx.unsigned_abs() + c.r.unsigned_abs()) as i32);
        max_ext = max_ext.max((c.cy.unsigned_abs() + c.r.unsigned_abs()) as i32);
    }
    for a in &entry.arcs {
        max_ext = max_ext.max((a.cx.unsigned_abs() + a.r.unsigned_abs()) as i32);
        max_ext = max_ext.max((a.cy.unsigned_abs() + a.r.unsigned_abs()) as i32);
    }
    for r in &entry.rects {
        max_ext = max_ext
            .max(r.x0.unsigned_abs() as i32)
            .max(r.y0.unsigned_abs() as i32)
            .max(r.x1.unsigned_abs() as i32)
            .max(r.y1.unsigned_abs() as i32);
    }
    // Small padding for label offsets / stroke.
    max_ext + 5
}

// ════════════════════════════════════════════════════════════
// Connectivity resolution — pure function over schematic data
// ════════════════════════════════════════════════════════════

