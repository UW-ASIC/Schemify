use schemify_core::primitives;
use schemify_core::types::Color;

use crate::App;

pub const SELECT_HIT_RADIUS_SQ: f64 = 400.0;
const HIT_TOL: f64 = 20.0; // sqrt of SELECT_HIT_RADIUS_SQ

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HitResult {
    Instance(usize),
    Wire(usize),
    Line(usize),
    Rect(usize),
    Circle(usize),
    Arc(usize),
    Text(usize),
    Polygon(usize),
    Nothing,
}

// ── Shared geometry helpers ──────────────────────────────────────────────────

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
    let t = ((px - ax) * abx + (py - ay) * aby) / len2;
    let t = t.clamp(0.0, 1.0);
    let cx = ax + t * abx;
    let cy = ay + t * aby;
    let dx = px - cx;
    let dy = py - cy;
    dx * dx + dy * dy
}

/// Normalize an angle (in radians) into [0, 2π).
fn normalize_angle(a: f64) -> f64 {
    let twopi = std::f64::consts::TAU;
    ((a % twopi) + twopi) % twopi
}

/// Check if angle `a` falls within the arc from `start` sweeping `sweep` radians.
fn angle_in_arc(a: f64, start: f64, sweep: f64) -> bool {
    if sweep.abs() >= std::f64::consts::TAU {
        return true; // full circle
    }
    let a = normalize_angle(a - start);
    if sweep >= 0.0 {
        a <= sweep
    } else {
        // Negative sweep: arc goes clockwise
        let pos_sweep = normalize_angle(-sweep);
        normalize_angle(-a) <= pos_sweep
    }
}

/// Ray-cast point-in-polygon test.
fn point_in_polygon(px: f64, py: f64, pts: &[[i32; 2]]) -> bool {
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

// ── Hit-test implementations ─────────────────────────────────────────────────

impl App {
    pub fn hit_test_instance(&self, wx: i32, wy: i32) -> Option<usize> {
        let insts = self.instances();
        let n = insts.len();
        for i in 0..n {
            let dx = wx as f64 - insts.x[i] as f64;
            let dy = wy as f64 - insts.y[i] as f64;

            let kind = insts.kind[i];
            let prim = primitives::find_by_name(kind.symbol_name());
            let tol_sq = if let Some(entry) = prim {
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
        let wires = self.wires();
        let n = wires.len();
        let wpx = wx as f64;
        let wpy = wy as f64;

        for i in 0..n {
            let d2 = point_to_segment_dist_sq(
                wpx,
                wpy,
                wires.x0[i] as f64,
                wires.y0[i] as f64,
                wires.x1[i] as f64,
                wires.y1[i] as f64,
            );
            if d2 < tol_sq {
                return Some(i);
            }
        }
        None
    }

    pub fn hit_test_line(&self, wx: i32, wy: i32) -> Option<usize> {
        let wpx = wx as f64;
        let wpy = wy as f64;
        for (i, l) in self.schematic().lines.iter().enumerate() {
            let d2 = point_to_segment_dist_sq(
                wpx,
                wpy,
                l.x0 as f64,
                l.y0 as f64,
                l.x1 as f64,
                l.y1 as f64,
            );
            if d2 < SELECT_HIT_RADIUS_SQ {
                return Some(i);
            }
        }
        None
    }

    pub fn hit_test_rect(&self, wx: i32, wy: i32) -> Option<usize> {
        let tol = HIT_TOL as i32;
        for (i, r) in self.schematic().rects.iter().enumerate() {
            if wx >= r.x - tol
                && wx <= r.x + r.width + tol
                && wy >= r.y - tol
                && wy <= r.y + r.height + tol
            {
                return Some(i);
            }
        }
        None
    }

    pub fn hit_test_circle(&self, wx: i32, wy: i32) -> Option<usize> {
        for (i, c) in self.schematic().circles.iter().enumerate() {
            let dx = wx as f64 - c.cx as f64;
            let dy = wy as f64 - c.cy as f64;
            let dist = (dx * dx + dy * dy).sqrt();
            let radius = c.radius as f64;
            // Hit if inside (for filled) or near the stroke
            if c.fill != Color::NONE && dist <= radius + HIT_TOL {
                return Some(i);
            }
            if (dist - radius).abs() < HIT_TOL {
                return Some(i);
            }
        }
        None
    }

    pub fn hit_test_arc(&self, wx: i32, wy: i32) -> Option<usize> {
        for (i, a) in self.schematic().arcs.iter().enumerate() {
            let dx = wx as f64 - a.cx as f64;
            let dy = wy as f64 - a.cy as f64;
            let dist = (dx * dx + dy * dy).sqrt();
            let radius = a.radius as f64;
            if (dist - radius).abs() >= HIT_TOL {
                continue;
            }
            // Check angle falls within arc sweep
            let angle = dy.atan2(dx);
            if angle_in_arc(angle, a.start_angle as f64, a.sweep_angle as f64) {
                return Some(i);
            }
        }
        None
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
        let wpx = wx as f64;
        let wpy = wy as f64;
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
            // Closing edge
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
                // Interior (filled)
                if p.fill != Color::NONE && point_in_polygon(wpx, wpy, &p.points) {
                    return Some(i);
                }
            }
        }
        None
    }

    /// Combined hit test: tries all types in priority order.
    pub fn hit_test(&self, wx: i32, wy: i32) -> HitResult {
        if let Some(idx) = self.hit_test_instance(wx, wy) {
            return HitResult::Instance(idx);
        }
        if let Some(idx) = self.hit_test_wire(wx, wy, SELECT_HIT_RADIUS_SQ) {
            return HitResult::Wire(idx);
        }
        if let Some(idx) = self.hit_test_rect(wx, wy) {
            return HitResult::Rect(idx);
        }
        if let Some(idx) = self.hit_test_circle(wx, wy) {
            return HitResult::Circle(idx);
        }
        if let Some(idx) = self.hit_test_arc(wx, wy) {
            return HitResult::Arc(idx);
        }
        if let Some(idx) = self.hit_test_line(wx, wy) {
            return HitResult::Line(idx);
        }
        if let Some(idx) = self.hit_test_text(wx, wy) {
            return HitResult::Text(idx);
        }
        if let Some(idx) = self.hit_test_polygon(wx, wy) {
            return HitResult::Polygon(idx);
        }
        HitResult::Nothing
    }

    /// Select all objects whose positions fall within the given rectangle.
    pub fn select_in_rect(&mut self, min_x: i32, min_y: i32, max_x: i32, max_y: i32) {
        {
            let doc = self.state.active_document_mut();
            doc.selection.clear();
        }

        // Instances: origin inside rect
        let n_inst = self.instances().len();
        let mut inst_hits = Vec::new();
        for i in 0..n_inst {
            let x = self.instances().x[i];
            let y = self.instances().y[i];
            if x >= min_x && x <= max_x && y >= min_y && y <= max_y {
                inst_hits.push(i);
            }
        }

        // Wires: both endpoints inside
        let n_wire = self.wires().len();
        let mut wire_hits = Vec::new();
        for i in 0..n_wire {
            let x0 = self.wires().x0[i];
            let y0 = self.wires().y0[i];
            let x1 = self.wires().x1[i];
            let y1 = self.wires().y1[i];
            if x0 >= min_x
                && x0 <= max_x
                && y0 >= min_y
                && y0 <= max_y
                && x1 >= min_x
                && x1 <= max_x
                && y1 >= min_y
                && y1 <= max_y
            {
                wire_hits.push(i);
            }
        }

        for idx in inst_hits {
            self.select_instance(idx);
        }
        for idx in wire_hits {
            self.select_wire(idx);
        }

        // Geometry types — collect then select to avoid borrow conflict
        let sch = &self.state.active_document().schematic;

        let line_hits: Vec<usize> = sch
            .lines
            .iter()
            .enumerate()
            .filter(|(_, l)| {
                l.x0 >= min_x
                    && l.x0 <= max_x
                    && l.y0 >= min_y
                    && l.y0 <= max_y
                    && l.x1 >= min_x
                    && l.x1 <= max_x
                    && l.y1 >= min_y
                    && l.y1 <= max_y
            })
            .map(|(i, _)| i)
            .collect();

        let rect_hits: Vec<usize> = sch
            .rects
            .iter()
            .enumerate()
            .filter(|(_, r)| {
                r.x >= min_x
                    && r.x <= max_x
                    && r.y >= min_y
                    && r.y <= max_y
                    && r.x + r.width >= min_x
                    && r.x + r.width <= max_x
                    && r.y + r.height >= min_y
                    && r.y + r.height <= max_y
            })
            .map(|(i, _)| i)
            .collect();

        let circle_hits: Vec<usize> = sch
            .circles
            .iter()
            .enumerate()
            .filter(|(_, c)| {
                c.cx - c.radius >= min_x
                    && c.cx + c.radius <= max_x
                    && c.cy - c.radius >= min_y
                    && c.cy + c.radius <= max_y
            })
            .map(|(i, _)| i)
            .collect();

        let arc_hits: Vec<usize> = sch
            .arcs
            .iter()
            .enumerate()
            .filter(|(_, a)| {
                a.cx - a.radius >= min_x
                    && a.cx + a.radius <= max_x
                    && a.cy - a.radius >= min_y
                    && a.cy + a.radius <= max_y
            })
            .map(|(i, _)| i)
            .collect();

        let text_hits: Vec<usize> = sch
            .texts
            .iter()
            .enumerate()
            .filter(|(_, t)| t.x >= min_x && t.x <= max_x && t.y >= min_y && t.y <= max_y)
            .map(|(i, _)| i)
            .collect();

        let polygon_hits: Vec<usize> = sch
            .polygons
            .iter()
            .enumerate()
            .filter(|(_, p)| {
                p.points
                    .iter()
                    .all(|pt| pt[0] >= min_x && pt[0] <= max_x && pt[1] >= min_y && pt[1] <= max_y)
            })
            .map(|(i, _)| i)
            .collect();

        let doc = self.state.active_document_mut();
        for idx in line_hits {
            doc.selection.lines.insert(idx);
        }
        for idx in rect_hits {
            doc.selection.rects.insert(idx);
        }
        for idx in circle_hits {
            doc.selection.circles.insert(idx);
        }
        for idx in arc_hits {
            doc.selection.arcs.insert(idx);
        }
        for idx in text_hits {
            doc.selection.texts.insert(idx);
        }
        for idx in polygon_hits {
            doc.selection.polygons.insert(idx);
        }
    }

    /// Manhattan routing helper.
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
