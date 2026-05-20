use schemify_core::primitives;

use crate::App;

pub const SELECT_HIT_RADIUS_SQ: f64 = 400.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HitResult {
    Instance(usize),
    Wire(usize),
    Nothing,
}

impl App {
    /// Hit-test instances: iterate all instances, compute bounding extent
    /// from primitive geometry, return first whose squared distance from
    /// (wx, wy) is within tolerance.
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

    /// Hit-test wires: compute point-to-segment squared distance for each
    /// wire, return first under `tol_sq`.
    pub fn hit_test_wire(&self, wx: i32, wy: i32, tol_sq: f64) -> Option<usize> {
        let wires = self.wires();
        let n = wires.len();
        let wpx = wx as f64;
        let wpy = wy as f64;

        for i in 0..n {
            let ax = wires.x0[i] as f64;
            let ay = wires.y0[i] as f64;
            let bx = wires.x1[i] as f64;
            let by = wires.y1[i] as f64;

            let abx = bx - ax;
            let aby = by - ay;
            let len2 = abx * abx + aby * aby;

            let d2 = if len2 <= 0.0 {
                let ddx = wpx - ax;
                let ddy = wpy - ay;
                ddx * ddx + ddy * ddy
            } else {
                let t = ((wpx - ax) * abx + (wpy - ay) * aby) / len2;
                let t = t.clamp(0.0, 1.0);
                let cx = ax + t * abx;
                let cy = ay + t * aby;
                let ddx = wpx - cx;
                let ddy = wpy - cy;
                ddx * ddx + ddy * ddy
            };

            if d2 < tol_sq {
                return Some(i);
            }
        }
        None
    }

    /// Combined hit test: tries instances first, then wires.
    pub fn hit_test(&self, wx: i32, wy: i32) -> HitResult {
        if let Some(idx) = self.hit_test_instance(wx, wy) {
            return HitResult::Instance(idx);
        }
        if let Some(idx) = self.hit_test_wire(wx, wy, SELECT_HIT_RADIUS_SQ) {
            return HitResult::Wire(idx);
        }
        HitResult::Nothing
    }

    /// Select all instances and wires whose positions fall within the
    /// given rectangle (inclusive).
    pub fn select_in_rect(&mut self, min_x: i32, min_y: i32, max_x: i32, max_y: i32) {
        {
            let doc = self.state.active_document_mut();
            doc.selection.clear();
        }

        let n_inst = self.instances().len();
        let mut inst_hits = Vec::new();
        for i in 0..n_inst {
            let x = self.instances().x[i];
            let y = self.instances().y[i];
            if x >= min_x && x <= max_x && y >= min_y && y <= max_y {
                inst_hits.push(i);
            }
        }

        let n_wire = self.wires().len();
        let mut wire_hits = Vec::new();
        for i in 0..n_wire {
            let x0 = self.wires().x0[i];
            let y0 = self.wires().y0[i];
            let x1 = self.wires().x1[i];
            let y1 = self.wires().y1[i];
            if x0 >= min_x && x0 <= max_x && y0 >= min_y && y0 <= max_y
                && x1 >= min_x && x1 <= max_x && y1 >= min_y && y1 <= max_y
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
    }

    /// Manhattan routing helper: given start and end points, compute
    /// the corner point for an L-shaped route along the dominant axis.
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
