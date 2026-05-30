use std::collections::HashSet;

use schemify_core::schematic::*;

// ════════════════════════════════════════════════════════════
// Bounding-box accumulator
// ════════════════════════════════════════════════════════════

/// Accumulator for bounding-box computation.
pub struct BoundsAccum {
    pub min_x: i32,
    pub min_y: i32,
    pub max_x: i32,
    pub max_y: i32,
    pub any: bool,
}

impl Default for BoundsAccum {
    fn default() -> Self {
        Self::new()
    }
}

impl BoundsAccum {
    pub fn new() -> Self {
        Self {
            min_x: i32::MAX,
            min_y: i32::MAX,
            max_x: i32::MIN,
            max_y: i32::MIN,
            any: false,
        }
    }

    pub fn add_point(&mut self, x: i32, y: i32) {
        self.any = true;
        self.min_x = self.min_x.min(x);
        self.min_y = self.min_y.min(y);
        self.max_x = self.max_x.max(x);
        self.max_y = self.max_y.max(y);
    }

    pub fn result(self) -> Option<(i32, i32, i32, i32)> {
        if self.any {
            Some((self.min_x, self.min_y, self.max_x, self.max_y))
        } else {
            None
        }
    }
}

pub fn snap(val: i32, grid: i32) -> i32 {
    if grid <= 0 {
        return val;
    }
    ((val as f64 / grid as f64).round() as i32) * grid
}

// ════════════════════════════════════════════════════════════
// SchematicCollection trait
// ════════════════════════════════════════════════════════════

pub trait SchematicCollection {
    type Item: Clone;

    fn is_empty(&self) -> bool {
        self.len() == 0
    }
    fn len(&self) -> usize;
    fn extract(&self, idx: usize) -> Self::Item;
    fn push(&mut self, item: Self::Item);
    fn remove(&mut self, idx: usize);
    fn translate(&mut self, idx: usize, dx: i32, dy: i32);
    fn snap_to_grid(&mut self, idx: usize, grid: i32);
    fn offset_item(item: &mut Self::Item, dx: i32, dy: i32);
    fn extend_bounds(&self, idx: usize, bounds: &mut BoundsAccum);
}

// ════════════════════════════════════════════════════════════
// InstanceVec (SoA)
// ════════════════════════════════════════════════════════════

impl SchematicCollection for InstanceVec {
    type Item = Instance;

    fn len(&self) -> usize {
        self.len()
    }

    fn extract(&self, idx: usize) -> Instance {
        Instance {
            name: self.name[idx],
            symbol: self.symbol[idx],
            spice_line: self.spice_line[idx],
            x: self.x[idx],
            y: self.y[idx],
            kind: self.kind[idx],
            flags: self.flags[idx],
            prop_start: self.prop_start[idx],
            prop_count: self.prop_count[idx],
            name_offset: self.name_offset[idx],
            param_offset: self.param_offset[idx],
        }
    }

    fn push(&mut self, item: Instance) {
        self.push(item);
    }

    fn remove(&mut self, idx: usize) {
        self.remove(idx);
    }

    fn translate(&mut self, idx: usize, dx: i32, dy: i32) {
        self.x[idx] += dx;
        self.y[idx] += dy;
    }

    fn snap_to_grid(&mut self, idx: usize, grid: i32) {
        self.x[idx] = snap(self.x[idx], grid);
        self.y[idx] = snap(self.y[idx], grid);
    }

    fn offset_item(item: &mut Instance, dx: i32, dy: i32) {
        item.x += dx;
        item.y += dy;
    }

    fn extend_bounds(&self, idx: usize, bounds: &mut BoundsAccum) {
        bounds.add_point(self.x[idx], self.y[idx]);
    }
}

// ════════════════════════════════════════════════════════════
// WireVec (SoA)
// ════════════════════════════════════════════════════════════

impl SchematicCollection for WireVec {
    type Item = Wire;

    fn len(&self) -> usize {
        self.len()
    }

    fn extract(&self, idx: usize) -> Wire {
        Wire {
            net_name: self.net_name[idx],
            x0: self.x0[idx],
            y0: self.y0[idx],
            x1: self.x1[idx],
            y1: self.y1[idx],
            color: self.color[idx],
            thickness: self.thickness[idx],
            bus: self.bus[idx],
        }
    }

    fn push(&mut self, item: Wire) {
        self.push(item);
    }

    fn remove(&mut self, idx: usize) {
        self.remove(idx);
    }

    fn translate(&mut self, idx: usize, dx: i32, dy: i32) {
        self.x0[idx] += dx;
        self.y0[idx] += dy;
        self.x1[idx] += dx;
        self.y1[idx] += dy;
    }

    fn snap_to_grid(&mut self, idx: usize, grid: i32) {
        self.x0[idx] = snap(self.x0[idx], grid);
        self.y0[idx] = snap(self.y0[idx], grid);
        self.x1[idx] = snap(self.x1[idx], grid);
        self.y1[idx] = snap(self.y1[idx], grid);
    }

    fn offset_item(item: &mut Wire, dx: i32, dy: i32) {
        item.x0 += dx;
        item.y0 += dy;
        item.x1 += dx;
        item.y1 += dy;
    }

    fn extend_bounds(&self, idx: usize, bounds: &mut BoundsAccum) {
        bounds.add_point(self.x0[idx], self.y0[idx]);
        bounds.add_point(self.x1[idx], self.y1[idx]);
    }
}

// ════════════════════════════════════════════════════════════
// Vec<Line> (AoS)
// ════════════════════════════════════════════════════════════

impl SchematicCollection for Vec<Line> {
    type Item = Line;

    fn len(&self) -> usize {
        self.len()
    }

    fn extract(&self, idx: usize) -> Line {
        self[idx].clone()
    }

    fn push(&mut self, item: Line) {
        self.push(item);
    }

    fn remove(&mut self, idx: usize) {
        self.remove(idx);
    }

    fn translate(&mut self, idx: usize, dx: i32, dy: i32) {
        self[idx].x0 += dx;
        self[idx].y0 += dy;
        self[idx].x1 += dx;
        self[idx].y1 += dy;
    }

    fn snap_to_grid(&mut self, idx: usize, grid: i32) {
        self[idx].x0 = snap(self[idx].x0, grid);
        self[idx].y0 = snap(self[idx].y0, grid);
        self[idx].x1 = snap(self[idx].x1, grid);
        self[idx].y1 = snap(self[idx].y1, grid);
    }

    fn offset_item(item: &mut Line, dx: i32, dy: i32) {
        item.x0 += dx;
        item.y0 += dy;
        item.x1 += dx;
        item.y1 += dy;
    }

    fn extend_bounds(&self, idx: usize, bounds: &mut BoundsAccum) {
        bounds.add_point(self[idx].x0, self[idx].y0);
        bounds.add_point(self[idx].x1, self[idx].y1);
    }
}

// ════════════════════════════════════════════════════════════
// Vec<Rect> (AoS)
// ════════════════════════════════════════════════════════════

impl SchematicCollection for Vec<Rect> {
    type Item = Rect;

    fn len(&self) -> usize {
        self.len()
    }

    fn extract(&self, idx: usize) -> Rect {
        self[idx].clone()
    }

    fn push(&mut self, item: Rect) {
        self.push(item);
    }

    fn remove(&mut self, idx: usize) {
        self.remove(idx);
    }

    fn translate(&mut self, idx: usize, dx: i32, dy: i32) {
        self[idx].x += dx;
        self[idx].y += dy;
    }

    fn snap_to_grid(&mut self, idx: usize, grid: i32) {
        self[idx].x = snap(self[idx].x, grid);
        self[idx].y = snap(self[idx].y, grid);
    }

    fn offset_item(item: &mut Rect, dx: i32, dy: i32) {
        item.x += dx;
        item.y += dy;
    }

    fn extend_bounds(&self, idx: usize, bounds: &mut BoundsAccum) {
        bounds.add_point(self[idx].x, self[idx].y);
        bounds.add_point(
            self[idx].x + self[idx].width,
            self[idx].y + self[idx].height,
        );
    }
}

// ════════════════════════════════════════════════════════════
// Vec<Circle> (AoS)
// ════════════════════════════════════════════════════════════

impl SchematicCollection for Vec<Circle> {
    type Item = Circle;

    fn len(&self) -> usize {
        self.len()
    }

    fn extract(&self, idx: usize) -> Circle {
        self[idx].clone()
    }

    fn push(&mut self, item: Circle) {
        self.push(item);
    }

    fn remove(&mut self, idx: usize) {
        self.remove(idx);
    }

    fn translate(&mut self, idx: usize, dx: i32, dy: i32) {
        self[idx].cx += dx;
        self[idx].cy += dy;
    }

    fn snap_to_grid(&mut self, idx: usize, grid: i32) {
        self[idx].cx = snap(self[idx].cx, grid);
        self[idx].cy = snap(self[idx].cy, grid);
    }

    fn offset_item(item: &mut Circle, dx: i32, dy: i32) {
        item.cx += dx;
        item.cy += dy;
    }

    fn extend_bounds(&self, idx: usize, bounds: &mut BoundsAccum) {
        let r = self[idx].radius;
        bounds.add_point(self[idx].cx - r, self[idx].cy - r);
        bounds.add_point(self[idx].cx + r, self[idx].cy + r);
    }
}

// ════════════════════════════════════════════════════════════
// Vec<Arc> (AoS)
// ════════════════════════════════════════════════════════════

impl SchematicCollection for Vec<Arc> {
    type Item = Arc;

    fn len(&self) -> usize {
        self.len()
    }

    fn extract(&self, idx: usize) -> Arc {
        self[idx].clone()
    }

    fn push(&mut self, item: Arc) {
        self.push(item);
    }

    fn remove(&mut self, idx: usize) {
        self.remove(idx);
    }

    fn translate(&mut self, idx: usize, dx: i32, dy: i32) {
        self[idx].cx += dx;
        self[idx].cy += dy;
    }

    fn snap_to_grid(&mut self, idx: usize, grid: i32) {
        self[idx].cx = snap(self[idx].cx, grid);
        self[idx].cy = snap(self[idx].cy, grid);
    }

    fn offset_item(item: &mut Arc, dx: i32, dy: i32) {
        item.cx += dx;
        item.cy += dy;
    }

    fn extend_bounds(&self, idx: usize, bounds: &mut BoundsAccum) {
        let r = self[idx].radius;
        bounds.add_point(self[idx].cx - r, self[idx].cy - r);
        bounds.add_point(self[idx].cx + r, self[idx].cy + r);
    }
}

// ════════════════════════════════════════════════════════════
// Vec<Text> (AoS)
// ════════════════════════════════════════════════════════════

impl SchematicCollection for Vec<Text> {
    type Item = Text;

    fn len(&self) -> usize {
        self.len()
    }

    fn extract(&self, idx: usize) -> Text {
        self[idx].clone()
    }

    fn push(&mut self, item: Text) {
        self.push(item);
    }

    fn remove(&mut self, idx: usize) {
        self.remove(idx);
    }

    fn translate(&mut self, idx: usize, dx: i32, dy: i32) {
        self[idx].x += dx;
        self[idx].y += dy;
    }

    fn snap_to_grid(&mut self, idx: usize, grid: i32) {
        self[idx].x = snap(self[idx].x, grid);
        self[idx].y = snap(self[idx].y, grid);
    }

    fn offset_item(item: &mut Text, dx: i32, dy: i32) {
        item.x += dx;
        item.y += dy;
    }

    fn extend_bounds(&self, idx: usize, bounds: &mut BoundsAccum) {
        bounds.add_point(self[idx].x, self[idx].y);
    }
}

// ════════════════════════════════════════════════════════════
// Vec<Polygon> (AoS)
// ════════════════════════════════════════════════════════════

impl SchematicCollection for Vec<Polygon> {
    type Item = Polygon;

    fn len(&self) -> usize {
        self.len()
    }

    fn extract(&self, idx: usize) -> Polygon {
        self[idx].clone()
    }

    fn push(&mut self, item: Polygon) {
        self.push(item);
    }

    fn remove(&mut self, idx: usize) {
        self.remove(idx);
    }

    fn translate(&mut self, idx: usize, dx: i32, dy: i32) {
        for pt in &mut self[idx].points {
            pt[0] += dx;
            pt[1] += dy;
        }
    }

    fn snap_to_grid(&mut self, idx: usize, grid: i32) {
        for pt in &mut self[idx].points {
            pt[0] = snap(pt[0], grid);
            pt[1] = snap(pt[1], grid);
        }
    }

    fn offset_item(item: &mut Polygon, dx: i32, dy: i32) {
        for pt in &mut item.points {
            pt[0] += dx;
            pt[1] += dy;
        }
    }

    fn extend_bounds(&self, idx: usize, bounds: &mut BoundsAccum) {
        for pt in &self[idx].points {
            bounds.add_point(pt[0], pt[1]);
        }
    }
}

// ════════════════════════════════════════════════════════════
// Generic helper functions
// ════════════════════════════════════════════════════════════

/// Translate all items whose index is in `sel`.
pub fn translate_selected<C: SchematicCollection>(
    c: &mut C,
    sel: &HashSet<usize>,
    dx: i32,
    dy: i32,
) {
    for &idx in sel {
        if idx < c.len() {
            c.translate(idx, dx, dy);
        }
    }
}

/// Snap all selected items to the given grid.
pub fn snap_selected<C: SchematicCollection>(c: &mut C, sel: &HashSet<usize>, grid: i32) {
    for &idx in sel {
        if idx < c.len() {
            c.snap_to_grid(idx, grid);
        }
    }
}

/// Remove all items whose index is in `sel`, in descending order to preserve indices.
pub fn remove_selected<C: SchematicCollection>(c: &mut C, sel: &HashSet<usize>) {
    let mut indices: Vec<usize> = sel.iter().copied().collect();
    indices.sort_unstable_by(|a, b| b.cmp(a));
    for idx in indices {
        if idx < c.len() {
            c.remove(idx);
        }
    }
}

/// Extract copies of all selected items.
pub fn copy_selected<C: SchematicCollection>(c: &C, sel: &HashSet<usize>) -> Vec<C::Item> {
    let mut out = Vec::with_capacity(sel.len());
    for &idx in sel {
        if idx < c.len() {
            out.push(c.extract(idx));
        }
    }
    out
}

/// Paste items into the collection, offsetting each by (dx, dy).
/// Clears `sel` and fills it with the indices of the newly added items.
pub fn paste_items<C: SchematicCollection>(
    c: &mut C,
    items: Vec<C::Item>,
    sel: &mut HashSet<usize>,
    dx: i32,
    dy: i32,
) {
    sel.clear();
    for mut item in items {
        C::offset_item(&mut item, dx, dy);
        let new_idx = c.len();
        c.push(item);
        sel.insert(new_idx);
    }
}

/// Duplicate selected items with an offset, updating selection to the new copies.
pub fn duplicate_selected<C: SchematicCollection>(
    c: &mut C,
    sel: &mut HashSet<usize>,
    dx: i32,
    dy: i32,
) {
    let copies: Vec<C::Item> = sel
        .iter()
        .filter(|&&idx| idx < c.len())
        .map(|&idx| c.extract(idx))
        .collect();
    sel.clear();
    for mut item in copies {
        C::offset_item(&mut item, dx, dy);
        let new_idx = c.len();
        c.push(item);
        sel.insert(new_idx);
    }
}

/// Extend the bounding box accumulator with every item in the collection.
pub fn bounds_all<C: SchematicCollection>(c: &C, accum: &mut BoundsAccum) {
    for i in 0..c.len() {
        c.extend_bounds(i, accum);
    }
}
