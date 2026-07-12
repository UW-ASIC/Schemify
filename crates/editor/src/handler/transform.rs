//! Geometric transforms over schematic objects: move/rotate/flip/align/
//! distribute, centroids, bounds, object removal.



use crate::schemify::{
    Instance,
    InstanceFlags, InstanceVec, Schematic, Wire,
};

use super::*;

impl App {
    pub(crate) fn move_selected(&mut self, dx: i32, dy: i32) {
        let doc = self.state.active_document_mut();
        for &r in &doc.selection.objs {
            translate_obj(&mut doc.schematic, r, dx, dy);
        }
    }

    pub(crate) fn rotate_selected(&mut self, clockwise: bool) {
        let doc = self.state.active_document_mut();
        let Some((cx, cy)) = centroid_of_selection(&doc.schematic, &doc.selection) else {
            return;
        };
        for &r in &doc.selection.objs {
            rotate_obj(&mut doc.schematic, r, cx, cy, clockwise);
        }
    }

    pub(crate) fn flip_selected(&mut self, horizontal: bool) {
        let doc = self.state.active_document_mut();
        let Some((cx, cy)) = centroid_of_selection(&doc.schematic, &doc.selection) else {
            return;
        };
        for &r in &doc.selection.objs {
            flip_obj(&mut doc.schematic, r, cx, cy, horizontal);
        }
    }

    pub(crate) fn align_selected_to_grid(&mut self) {
        let grid = self.state.tool.snap_size as i32;
        if grid <= 0 {
            return;
        }
        let doc = self.state.active_document_mut();
        for &r in &doc.selection.objs {
            snap_obj(&mut doc.schematic, r, grid);
        }
    }

    pub(crate) fn align_selected(&mut self, axis: AlignAxis, mode: AlignMode) {
        let doc = self.state.active_document_mut();
        let indices: Vec<usize> = doc
            .selection
            .instance_indices()
            .filter(|&i| i < doc.schematic.instances.len())
            .collect();
        if indices.len() < 2 {
            return;
        }
        let positions: Vec<i32> = indices
            .iter()
            .map(|&i| axis.get(&doc.schematic.instances, i))
            .collect();
        let lo = *positions.iter().min().unwrap();
        let hi = *positions.iter().max().unwrap();
        let target = match mode {
            AlignMode::Min => lo,
            AlignMode::Max => hi,
            AlignMode::Center => (lo + hi) / 2,
        };
        for idx in indices {
            axis.set(&mut doc.schematic.instances, idx, target);
        }
    }

    pub(crate) fn distribute_selected(&mut self, axis: AlignAxis) {
        let doc = self.state.active_document_mut();
        let mut indexed: Vec<(usize, i32)> = doc
            .selection
            .instance_indices()
            .filter(|&i| i < doc.schematic.instances.len())
            .map(|i| (i, axis.get(&doc.schematic.instances, i)))
            .collect();
        if indexed.len() < 3 {
            return;
        }
        indexed.sort_unstable_by_key(|&(_, v)| v);
        let n = indexed.len();
        let lo = indexed[0].1;
        let hi = indexed[n - 1].1;
        let step = (hi - lo) as f64 / (n - 1) as f64;
        for (rank, &(idx, _)) in indexed.iter().enumerate() {
            axis.set(
                &mut doc.schematic.instances,
                idx,
                lo + (step * rank as f64).round() as i32,
            );
        }
    }
}

pub(crate) enum AlignAxis {
    X,
    Y,
}

pub(crate) enum AlignMode {
    Min,
    Max,
    Center,
}

impl AlignAxis {
    pub(crate) fn get(&self, instances: &InstanceVec, idx: usize) -> i32 {
        match self {
            Self::X => instances.x[idx],
            Self::Y => instances.y[idx],
        }
    }

    pub(crate) fn set(&self, instances: &mut InstanceVec, idx: usize, val: i32) {
        match self {
            Self::X => instances.x[idx] = val,
            Self::Y => instances.y[idx] = val,
        }
    }
}

// ════════════════════════════════════════════════════════════
// Clipboard / delete / duplicate
// ════════════════════════════════════════════════════════════

pub fn rot_point(x: i32, y: i32, cx: i32, cy: i32, clockwise: bool) -> (i32, i32) {
    if clockwise {
        (cy - y + cx, x - cx + cy)
    } else {
        (y - cy + cx, cx - x + cy)
    }
}

/// Mirror (x, y) across the vertical (horizontal=true) or horizontal axis
/// through (cx, cy).
pub fn mirror_point(x: i32, y: i32, cx: i32, cy: i32, horizontal: bool) -> (i32, i32) {
    if horizontal {
        (2 * cx - x, y)
    } else {
        (x, 2 * cy - y)
    }
}

pub fn snap(val: i32, grid: i32) -> i32 {
    if grid <= 0 {
        return val;
    }
    ((val as f64 / grid as f64).round() as i32) * grid
}

/// Extract an AoS copy of instance `i` from the SoA storage.
pub(crate) fn instance_at(sch: &Schematic, i: usize) -> Instance {
    let v = &sch.instances;
    Instance {
        name: v.name[i],
        symbol: v.symbol[i],
        x: v.x[i],
        y: v.y[i],
        kind: v.kind[i],
        flags: v.flags[i],
        prop_start: v.prop_start[i],
        prop_count: v.prop_count[i],
    }
}

/// Extract an AoS copy of wire `i` from the SoA storage.
pub(crate) fn wire_at(sch: &Schematic, i: usize) -> Wire {
    let v = &sch.wires;
    Wire {
        net_name: v.net_name[i],
        x0: v.x0[i],
        y0: v.y0[i],
        x1: v.x1[i],
        y1: v.y1[i],
        color: v.color[i],
        thickness: v.thickness[i],
    }
}

pub fn translate_obj(sch: &mut Schematic, r: ObjectRef, dx: i32, dy: i32) {
    let i = r.index();
    match r {
        ObjectRef::Instance(_) => sch.translate_instance(i, dx, dy),
        ObjectRef::Wire(_) => sch.translate_wire(i, dx, dy),
        ObjectRef::Bus(_) => {
            if i < sch.buses.len() {
                sch.buses.x0[i] += dx;
                sch.buses.y0[i] += dy;
                sch.buses.x1[i] += dx;
                sch.buses.y1[i] += dy;
            }
        }
        ObjectRef::Line(_) => {
            if let Some(l) = sch.lines.get_mut(i) {
                l.x0 += dx;
                l.y0 += dy;
                l.x1 += dx;
                l.y1 += dy;
            }
        }
        ObjectRef::Rect(_) => {
            if let Some(rc) = sch.rects.get_mut(i) {
                rc.x += dx;
                rc.y += dy;
            }
        }
        ObjectRef::Circle(_) => {
            if let Some(c) = sch.circles.get_mut(i) {
                c.cx += dx;
                c.cy += dy;
            }
        }
        ObjectRef::Arc(_) => {
            if let Some(a) = sch.arcs.get_mut(i) {
                a.cx += dx;
                a.cy += dy;
            }
        }
        ObjectRef::Text(_) => {
            if let Some(t) = sch.texts.get_mut(i) {
                t.x += dx;
                t.y += dy;
            }
        }
        ObjectRef::Polygon(_) => {
            if let Some(p) = sch.polygons.get_mut(i) {
                for pt in &mut p.points {
                    pt[0] += dx;
                    pt[1] += dy;
                }
            }
        }
    }
}

pub fn snap_obj(sch: &mut Schematic, r: ObjectRef, grid: i32) {
    let i = r.index();
    match r {
        ObjectRef::Instance(_) => {
            if i < sch.instances.len() {
                sch.instances.x[i] = snap(sch.instances.x[i], grid);
                sch.instances.y[i] = snap(sch.instances.y[i], grid);
            }
        }
        ObjectRef::Wire(_) => {
            if i < sch.wires.len() {
                sch.wires.x0[i] = snap(sch.wires.x0[i], grid);
                sch.wires.y0[i] = snap(sch.wires.y0[i], grid);
                sch.wires.x1[i] = snap(sch.wires.x1[i], grid);
                sch.wires.y1[i] = snap(sch.wires.y1[i], grid);
            }
        }
        ObjectRef::Bus(_) => {
            if i < sch.buses.len() {
                sch.buses.x0[i] = snap(sch.buses.x0[i], grid);
                sch.buses.y0[i] = snap(sch.buses.y0[i], grid);
                sch.buses.x1[i] = snap(sch.buses.x1[i], grid);
                sch.buses.y1[i] = snap(sch.buses.y1[i], grid);
            }
        }
        ObjectRef::Line(_) => {
            if let Some(l) = sch.lines.get_mut(i) {
                l.x0 = snap(l.x0, grid);
                l.y0 = snap(l.y0, grid);
                l.x1 = snap(l.x1, grid);
                l.y1 = snap(l.y1, grid);
            }
        }
        ObjectRef::Rect(_) => {
            if let Some(rc) = sch.rects.get_mut(i) {
                rc.x = snap(rc.x, grid);
                rc.y = snap(rc.y, grid);
            }
        }
        ObjectRef::Circle(_) => {
            if let Some(c) = sch.circles.get_mut(i) {
                c.cx = snap(c.cx, grid);
                c.cy = snap(c.cy, grid);
            }
        }
        ObjectRef::Arc(_) => {
            if let Some(a) = sch.arcs.get_mut(i) {
                a.cx = snap(a.cx, grid);
                a.cy = snap(a.cy, grid);
            }
        }
        ObjectRef::Text(_) => {
            if let Some(t) = sch.texts.get_mut(i) {
                t.x = snap(t.x, grid);
                t.y = snap(t.y, grid);
            }
        }
        ObjectRef::Polygon(_) => {
            if let Some(p) = sch.polygons.get_mut(i) {
                for pt in &mut p.points {
                    pt[0] = snap(pt[0], grid);
                    pt[1] = snap(pt[1], grid);
                }
            }
        }
    }
}

pub fn rotate_obj(sch: &mut Schematic, r: ObjectRef, cx: i32, cy: i32, cw: bool) {
    let i = r.index();
    match r {
        ObjectRef::Instance(_) => {
            if i < sch.instances.len() {
                let flags = sch.instances.flags[i];
                let rot = if cw {
                    (flags.rotation() + 1) & 0x03
                } else {
                    (flags.rotation() + 3) & 0x03
                };
                sch.instances.flags[i] = InstanceFlags::new(rot, flags.flip());
                let (nx, ny) = rot_point(sch.instances.x[i], sch.instances.y[i], cx, cy, cw);
                sch.instances.x[i] = nx;
                sch.instances.y[i] = ny;
            }
        }
        ObjectRef::Wire(_) => {
            if i < sch.wires.len() {
                let (nx0, ny0) = rot_point(sch.wires.x0[i], sch.wires.y0[i], cx, cy, cw);
                let (nx1, ny1) = rot_point(sch.wires.x1[i], sch.wires.y1[i], cx, cy, cw);
                (sch.wires.x0[i], sch.wires.y0[i]) = (nx0, ny0);
                (sch.wires.x1[i], sch.wires.y1[i]) = (nx1, ny1);
            }
        }
        ObjectRef::Bus(_) => {
            if i < sch.buses.len() {
                let (nx0, ny0) = rot_point(sch.buses.x0[i], sch.buses.y0[i], cx, cy, cw);
                let (nx1, ny1) = rot_point(sch.buses.x1[i], sch.buses.y1[i], cx, cy, cw);
                (sch.buses.x0[i], sch.buses.y0[i]) = (nx0, ny0);
                (sch.buses.x1[i], sch.buses.y1[i]) = (nx1, ny1);
            }
        }
        ObjectRef::Line(_) => {
            if let Some(l) = sch.lines.get_mut(i) {
                let (nx0, ny0) = rot_point(l.x0, l.y0, cx, cy, cw);
                let (nx1, ny1) = rot_point(l.x1, l.y1, cx, cy, cw);
                (l.x0, l.y0, l.x1, l.y1) = (nx0, ny0, nx1, ny1);
            }
        }
        ObjectRef::Rect(_) => {
            if let Some(rc) = sch.rects.get_mut(i) {
                let (x0, y0) = rot_point(rc.x, rc.y, cx, cy, cw);
                let (x1, y1) = rot_point(rc.x + rc.width, rc.y + rc.height, cx, cy, cw);
                rc.x = x0.min(x1);
                rc.y = y0.min(y1);
                rc.width = (x1 - x0).abs();
                rc.height = (y1 - y0).abs();
            }
        }
        ObjectRef::Circle(_) => {
            if let Some(c) = sch.circles.get_mut(i) {
                (c.cx, c.cy) = rot_point(c.cx, c.cy, cx, cy, cw);
            }
        }
        ObjectRef::Arc(_) => {
            if let Some(a) = sch.arcs.get_mut(i) {
                (a.cx, a.cy) = rot_point(a.cx, a.cy, cx, cy, cw);
                let delta = if cw {
                    -std::f32::consts::FRAC_PI_2
                } else {
                    std::f32::consts::FRAC_PI_2
                };
                a.start_angle += delta;
            }
        }
        ObjectRef::Text(_) => {
            if let Some(t) = sch.texts.get_mut(i) {
                (t.x, t.y) = rot_point(t.x, t.y, cx, cy, cw);
                let delta: u8 = if cw { 1 } else { 3 };
                t.rotation = (t.rotation + delta) & 0x03;
            }
        }
        ObjectRef::Polygon(_) => {
            if let Some(p) = sch.polygons.get_mut(i) {
                for pt in &mut p.points {
                    let (nx, ny) = rot_point(pt[0], pt[1], cx, cy, cw);
                    pt[0] = nx;
                    pt[1] = ny;
                }
            }
        }
    }
}

pub fn flip_obj(sch: &mut Schematic, r: ObjectRef, cx: i32, cy: i32, horizontal: bool) {
    let i = r.index();
    match r {
        ObjectRef::Instance(_) => {
            if i < sch.instances.len() {
                let flags = sch.instances.flags[i];
                sch.instances.flags[i] = if horizontal {
                    InstanceFlags::new(flags.rotation(), !flags.flip())
                } else {
                    InstanceFlags::new((flags.rotation() + 2) & 0x03, !flags.flip())
                };
                let (nx, ny) =
                    mirror_point(sch.instances.x[i], sch.instances.y[i], cx, cy, horizontal);
                sch.instances.x[i] = nx;
                sch.instances.y[i] = ny;
            }
        }
        ObjectRef::Wire(_) => {
            if i < sch.wires.len() {
                let (nx0, ny0) = mirror_point(sch.wires.x0[i], sch.wires.y0[i], cx, cy, horizontal);
                let (nx1, ny1) = mirror_point(sch.wires.x1[i], sch.wires.y1[i], cx, cy, horizontal);
                (sch.wires.x0[i], sch.wires.y0[i]) = (nx0, ny0);
                (sch.wires.x1[i], sch.wires.y1[i]) = (nx1, ny1);
            }
        }
        ObjectRef::Bus(_) => {
            if i < sch.buses.len() {
                let (nx0, ny0) = mirror_point(sch.buses.x0[i], sch.buses.y0[i], cx, cy, horizontal);
                let (nx1, ny1) = mirror_point(sch.buses.x1[i], sch.buses.y1[i], cx, cy, horizontal);
                (sch.buses.x0[i], sch.buses.y0[i]) = (nx0, ny0);
                (sch.buses.x1[i], sch.buses.y1[i]) = (nx1, ny1);
            }
        }
        ObjectRef::Line(_) => {
            if let Some(l) = sch.lines.get_mut(i) {
                let (nx0, ny0) = mirror_point(l.x0, l.y0, cx, cy, horizontal);
                let (nx1, ny1) = mirror_point(l.x1, l.y1, cx, cy, horizontal);
                (l.x0, l.y0, l.x1, l.y1) = (nx0, ny0, nx1, ny1);
            }
        }
        ObjectRef::Rect(_) => {
            if let Some(rc) = sch.rects.get_mut(i) {
                let (x0, y0) = mirror_point(rc.x, rc.y, cx, cy, horizontal);
                let (x1, y1) = mirror_point(rc.x + rc.width, rc.y + rc.height, cx, cy, horizontal);
                rc.x = x0.min(x1);
                rc.y = y0.min(y1);
                rc.width = (x1 - x0).abs();
                rc.height = (y1 - y0).abs();
            }
        }
        ObjectRef::Circle(_) => {
            if let Some(c) = sch.circles.get_mut(i) {
                (c.cx, c.cy) = mirror_point(c.cx, c.cy, cx, cy, horizontal);
            }
        }
        ObjectRef::Arc(_) => {
            if let Some(a) = sch.arcs.get_mut(i) {
                (a.cx, a.cy) = mirror_point(a.cx, a.cy, cx, cy, horizontal);
                if horizontal {
                    a.start_angle = std::f32::consts::PI - a.start_angle - a.sweep_angle;
                } else {
                    a.start_angle = -a.start_angle - a.sweep_angle;
                }
            }
        }
        ObjectRef::Text(_) => {
            if let Some(t) = sch.texts.get_mut(i) {
                (t.x, t.y) = mirror_point(t.x, t.y, cx, cy, horizontal);
            }
        }
        ObjectRef::Polygon(_) => {
            if let Some(p) = sch.polygons.get_mut(i) {
                for pt in &mut p.points {
                    let (nx, ny) = mirror_point(pt[0], pt[1], cx, cy, horizontal);
                    pt[0] = nx;
                    pt[1] = ny;
                }
            }
        }
    }
}

/// Representative point of an object (for centroid computation).
/// `None` if the index is out of range.
pub(crate) fn centroid_obj(sch: &Schematic, r: ObjectRef) -> Option<(i64, i64)> {
    let i = r.index();
    match r {
        ObjectRef::Instance(_) => (i < sch.instances.len())
            .then(|| (sch.instances.x[i] as i64, sch.instances.y[i] as i64)),
        ObjectRef::Wire(_) => (i < sch.wires.len()).then(|| {
            (
                (sch.wires.x0[i] as i64 + sch.wires.x1[i] as i64) / 2,
                (sch.wires.y0[i] as i64 + sch.wires.y1[i] as i64) / 2,
            )
        }),
        ObjectRef::Bus(_) => (i < sch.buses.len()).then(|| {
            (
                (sch.buses.x0[i] as i64 + sch.buses.x1[i] as i64) / 2,
                (sch.buses.y0[i] as i64 + sch.buses.y1[i] as i64) / 2,
            )
        }),
        ObjectRef::Line(_) => sch.lines.get(i).map(|l| {
            (
                (l.x0 as i64 + l.x1 as i64) / 2,
                (l.y0 as i64 + l.y1 as i64) / 2,
            )
        }),
        ObjectRef::Rect(_) => sch.rects.get(i).map(|rc| {
            (
                rc.x as i64 + rc.width as i64 / 2,
                rc.y as i64 + rc.height as i64 / 2,
            )
        }),
        ObjectRef::Circle(_) => sch.circles.get(i).map(|c| (c.cx as i64, c.cy as i64)),
        ObjectRef::Arc(_) => sch.arcs.get(i).map(|a| (a.cx as i64, a.cy as i64)),
        ObjectRef::Text(_) => sch.texts.get(i).map(|t| (t.x as i64, t.y as i64)),
        ObjectRef::Polygon(_) => sch
            .polygons
            .get(i)
            .and_then(|p| p.points.first())
            .map(|pt| (pt[0] as i64, pt[1] as i64)),
    }
}

pub fn centroid_of_selection(sch: &Schematic, sel: &Selection) -> Option<(i32, i32)> {
    let mut sum = (0i64, 0i64, 0i64);
    for &r in &sel.objs {
        if let Some((x, y)) = centroid_obj(sch, r) {
            sum.0 += x;
            sum.1 += y;
            sum.2 += 1;
        }
    }
    (sum.2 > 0).then(|| ((sum.0 / sum.2) as i32, (sum.1 / sum.2) as i32))
}

pub(crate) fn centroid_of_clipboard(clip: &Clipboard) -> Option<(i32, i32)> {
    let mut sum = (0i64, 0i64, 0i64);
    let mut add = |x: i64, y: i64| {
        sum.0 += x;
        sum.1 += y;
        sum.2 += 1;
    };
    for it in &clip.instances {
        add(it.x as i64, it.y as i64);
    }
    for it in &clip.wires {
        add(
            (it.x0 as i64 + it.x1 as i64) / 2,
            (it.y0 as i64 + it.y1 as i64) / 2,
        );
    }
    for it in &clip.lines {
        add(
            (it.x0 as i64 + it.x1 as i64) / 2,
            (it.y0 as i64 + it.y1 as i64) / 2,
        );
    }
    for it in &clip.rects {
        add(
            it.x as i64 + it.width as i64 / 2,
            it.y as i64 + it.height as i64 / 2,
        );
    }
    for it in &clip.circles {
        add(it.cx as i64, it.cy as i64);
    }
    for it in &clip.arcs {
        add(it.cx as i64, it.cy as i64);
    }
    for it in &clip.texts {
        add(it.x as i64, it.y as i64);
    }
    for it in &clip.polygons {
        if let Some(pt) = it.points.first() {
            add(pt[0] as i64, pt[1] as i64);
        }
    }
    (sum.2 > 0).then(|| ((sum.0 / sum.2) as i32, (sum.1 / sum.2) as i32))
}

/// Whole-schematic bounding box (used by zoom-fit).
pub fn compute_bounds(sch: &Schematic) -> Option<(i32, i32, i32, i32)> {
    let mut min_x = i32::MAX;
    let mut min_y = i32::MAX;
    let mut max_x = i32::MIN;
    let mut max_y = i32::MIN;
    let mut any = false;
    let mut add = |x: i32, y: i32| {
        any = true;
        min_x = min_x.min(x);
        min_y = min_y.min(y);
        max_x = max_x.max(x);
        max_y = max_y.max(y);
    };
    for i in 0..sch.instances.len() {
        add(sch.instances.x[i], sch.instances.y[i]);
    }
    for i in 0..sch.wires.len() {
        add(sch.wires.x0[i], sch.wires.y0[i]);
        add(sch.wires.x1[i], sch.wires.y1[i]);
    }
    for i in 0..sch.buses.len() {
        add(sch.buses.x0[i], sch.buses.y0[i]);
        add(sch.buses.x1[i], sch.buses.y1[i]);
    }
    for l in &sch.lines {
        add(l.x0, l.y0);
        add(l.x1, l.y1);
    }
    for r in &sch.rects {
        add(r.x, r.y);
        add(r.x + r.width, r.y + r.height);
    }
    for c in &sch.circles {
        add(c.cx - c.radius, c.cy - c.radius);
        add(c.cx + c.radius, c.cy + c.radius);
    }
    for a in &sch.arcs {
        add(a.cx - a.radius, a.cy - a.radius);
        add(a.cx + a.radius, a.cy + a.radius);
    }
    for t in &sch.texts {
        add(t.x, t.y);
    }
    for p in &sch.polygons {
        for pt in &p.points {
            add(pt[0], pt[1]);
        }
    }
    any.then_some((min_x, min_y, max_x, max_y))
}

/// Remove a bus, deleting its rippers and re-pointing rippers of later buses.
pub(crate) fn remove_bus(sch: &mut Schematic, idx: usize) {
    sch.buses.remove(idx);
    let idx32 = idx as u32;
    sch.bus_rippers.retain(|r| r.bus_idx != idx32);
    for r in &mut sch.bus_rippers {
        if r.bus_idx > idx32 {
            r.bus_idx -= 1;
        }
    }
}

/// Remove every selected object, per kind in descending index order so
/// earlier removals don't shift later ones.
pub(crate) fn remove_selected_objects(sch: &mut Schematic, sel: &Selection) {
    let mut instances: Vec<usize> = Vec::new();
    let mut wires: Vec<usize> = Vec::new();
    let mut buses: Vec<usize> = Vec::new();
    let mut lines: Vec<usize> = Vec::new();
    let mut rects: Vec<usize> = Vec::new();
    let mut circles: Vec<usize> = Vec::new();
    let mut arcs: Vec<usize> = Vec::new();
    let mut texts: Vec<usize> = Vec::new();
    let mut polygons: Vec<usize> = Vec::new();
    for &r in &sel.objs {
        let i = r.index();
        match r {
            ObjectRef::Instance(_) => instances.push(i),
            ObjectRef::Wire(_) => wires.push(i),
            ObjectRef::Bus(_) => buses.push(i),
            ObjectRef::Line(_) => lines.push(i),
            ObjectRef::Rect(_) => rects.push(i),
            ObjectRef::Circle(_) => circles.push(i),
            ObjectRef::Arc(_) => arcs.push(i),
            ObjectRef::Text(_) => texts.push(i),
            ObjectRef::Polygon(_) => polygons.push(i),
        }
    }
    let desc = |v: &mut Vec<usize>| v.sort_unstable_by(|a, b| b.cmp(a));

    desc(&mut instances);
    for i in instances {
        if i < sch.instances.len() {
            sch.instances.remove(i);
        }
    }
    desc(&mut wires);
    for i in wires {
        if i < sch.wires.len() {
            sch.wires.remove(i);
        }
    }
    desc(&mut buses);
    for i in buses {
        if i < sch.buses.len() {
            remove_bus(sch, i);
        }
    }
    desc(&mut lines);
    for i in lines {
        if i < sch.lines.len() {
            sch.lines.remove(i);
        }
    }
    desc(&mut rects);
    for i in rects {
        if i < sch.rects.len() {
            sch.rects.remove(i);
        }
    }
    desc(&mut circles);
    for i in circles {
        if i < sch.circles.len() {
            sch.circles.remove(i);
        }
    }
    desc(&mut arcs);
    for i in arcs {
        if i < sch.arcs.len() {
            sch.arcs.remove(i);
        }
    }
    desc(&mut texts);
    for i in texts {
        if i < sch.texts.len() {
            sch.texts.remove(i);
        }
    }
    desc(&mut polygons);
    for i in polygons {
        if i < sch.polygons.len() {
            sch.polygons.remove(i);
        }
    }
}

// ════════════════════════════════════════════════════════════
// Hit testing & canvas geometry
// ════════════════════════════════════════════════════════════

