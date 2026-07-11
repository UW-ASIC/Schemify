//! Schematic-mutating helpers behind dispatch: clipboard copy/paste,
//! delete/duplicate of the selection.




use super::*;
// ════════════════════════════════════════════════════════════
// Undo / Redo
// ════════════════════════════════════════════════════════════

impl App {
    pub(crate) fn copy_to_clipboard(&mut self) {
        let doc = &self.state.documents[self.state.active_doc];
        let sch = &doc.schematic;
        let mut clip = Clipboard::default();
        for &r in &doc.selection.objs {
            let i = r.index();
            match r {
                ObjectRef::Instance(_) if i < sch.instances.len() => {
                    clip.instances.push(instance_at(sch, i));
                }
                ObjectRef::Wire(_) if i < sch.wires.len() => clip.wires.push(wire_at(sch, i)),
                ObjectRef::Line(_) if i < sch.lines.len() => clip.lines.push(sch.lines[i].clone()),
                ObjectRef::Rect(_) if i < sch.rects.len() => clip.rects.push(sch.rects[i].clone()),
                ObjectRef::Circle(_) if i < sch.circles.len() => {
                    clip.circles.push(sch.circles[i].clone());
                }
                ObjectRef::Arc(_) if i < sch.arcs.len() => clip.arcs.push(sch.arcs[i].clone()),
                ObjectRef::Text(_) if i < sch.texts.len() => clip.texts.push(sch.texts[i].clone()),
                ObjectRef::Polygon(_) if i < sch.polygons.len() => {
                    clip.polygons.push(sch.polygons[i].clone());
                }
                _ => {} // buses are not clipboard objects; out-of-range refs skipped
            }
        }
        self.state.clipboard = clip;
    }

    pub(crate) fn paste_from_clipboard(&mut self) {
        let (dx, dy) = self.paste_offset();
        // Split borrows: clipboard shared, active document mut — no clone needed.
        let state = &mut self.state;
        let clip = &state.clipboard;
        let doc = &mut state.documents[state.active_doc];
        let sch = &mut doc.schematic;
        let sel = &mut doc.selection;
        sel.clear();
        sel.objs.reserve(
            clip.instances.len()
                + clip.wires.len()
                + clip.lines.len()
                + clip.rects.len()
                + clip.circles.len()
                + clip.arcs.len()
                + clip.texts.len()
                + clip.polygons.len(),
        );

        for it in &clip.instances {
            let mut it = it.clone();
            it.x += dx;
            it.y += dy;
            // Property-pool indices belong to the source document.
            it.prop_start = 0;
            it.prop_count = 0;
            sel.objs
                .push(ObjectRef::Instance(sch.instances.len() as u32));
            sch.instances.push(it);
        }
        for it in &clip.wires {
            let mut it = it.clone();
            it.x0 += dx;
            it.y0 += dy;
            it.x1 += dx;
            it.y1 += dy;
            sel.objs.push(ObjectRef::Wire(sch.wires.len() as u32));
            sch.wires.push(it);
        }
        for it in &clip.lines {
            let mut it = it.clone();
            it.x0 += dx;
            it.y0 += dy;
            it.x1 += dx;
            it.y1 += dy;
            sel.objs.push(ObjectRef::Line(sch.lines.len() as u32));
            sch.lines.push(it);
        }
        for it in &clip.rects {
            let mut it = it.clone();
            it.x += dx;
            it.y += dy;
            sel.objs.push(ObjectRef::Rect(sch.rects.len() as u32));
            sch.rects.push(it);
        }
        for it in &clip.circles {
            let mut it = it.clone();
            it.cx += dx;
            it.cy += dy;
            sel.objs.push(ObjectRef::Circle(sch.circles.len() as u32));
            sch.circles.push(it);
        }
        for it in &clip.arcs {
            let mut it = it.clone();
            it.cx += dx;
            it.cy += dy;
            sel.objs.push(ObjectRef::Arc(sch.arcs.len() as u32));
            sch.arcs.push(it);
        }
        for it in &clip.texts {
            let mut it = it.clone();
            it.x += dx;
            it.y += dy;
            sel.objs.push(ObjectRef::Text(sch.texts.len() as u32));
            sch.texts.push(it);
        }
        for it in &clip.polygons {
            let mut it = it.clone();
            for pt in &mut it.points {
                pt[0] += dx;
                pt[1] += dy;
            }
            sel.objs.push(ObjectRef::Polygon(sch.polygons.len() as u32));
            sch.polygons.push(it);
        }
    }

    pub(crate) fn paste_offset(&self) -> (i32, i32) {
        let Some((cx, cy)) = centroid_of_clipboard(&self.state.clipboard) else {
            return (20, 20);
        };
        let cursor = self.state.canvas.cursor_world;
        let mut dx = cursor[0] - cx;
        let mut dy = cursor[1] - cy;
        if self.state.tool.snap_to_grid {
            let grid = self.state.tool.snap_size as i32;
            if grid > 0 {
                dx = ((dx as f64 / grid as f64).round() as i32) * grid;
                dy = ((dy as f64 / grid as f64).round() as i32) * grid;
            }
        }
        (dx, dy)
    }

    pub(crate) fn exec_delete_selected(&mut self) {
        let doc = self.state.active_document_mut();
        remove_selected_objects(&mut doc.schematic, &doc.selection);
        doc.selection.clear();
    }

    pub(crate) fn exec_duplicate_selected(&mut self) {
        const D: i32 = 20;
        let doc = self.state.active_document_mut();
        let sch = &mut doc.schematic;
        let old_sel = std::mem::take(&mut doc.selection.objs);
        doc.selection.objs.reserve(old_sel.len());
        for r in old_sel {
            let i = r.index();
            let new_ref = match r {
                ObjectRef::Instance(_) if i < sch.instances.len() => {
                    let mut it = instance_at(sch, i);
                    it.x += D;
                    it.y += D;
                    it.prop_start = 0;
                    it.prop_count = 0;
                    let n = sch.instances.len() as u32;
                    sch.instances.push(it);
                    Some(ObjectRef::Instance(n))
                }
                ObjectRef::Wire(_) if i < sch.wires.len() => {
                    let mut it = wire_at(sch, i);
                    it.x0 += D;
                    it.y0 += D;
                    it.x1 += D;
                    it.y1 += D;
                    let n = sch.wires.len() as u32;
                    sch.wires.push(it);
                    Some(ObjectRef::Wire(n))
                }
                ObjectRef::Line(_) if i < sch.lines.len() => {
                    let mut it = sch.lines[i].clone();
                    it.x0 += D;
                    it.y0 += D;
                    it.x1 += D;
                    it.y1 += D;
                    sch.lines.push(it);
                    Some(ObjectRef::Line(sch.lines.len() as u32 - 1))
                }
                ObjectRef::Rect(_) if i < sch.rects.len() => {
                    let mut it = sch.rects[i].clone();
                    it.x += D;
                    it.y += D;
                    sch.rects.push(it);
                    Some(ObjectRef::Rect(sch.rects.len() as u32 - 1))
                }
                ObjectRef::Circle(_) if i < sch.circles.len() => {
                    let mut it = sch.circles[i].clone();
                    it.cx += D;
                    it.cy += D;
                    sch.circles.push(it);
                    Some(ObjectRef::Circle(sch.circles.len() as u32 - 1))
                }
                ObjectRef::Arc(_) if i < sch.arcs.len() => {
                    let mut it = sch.arcs[i].clone();
                    it.cx += D;
                    it.cy += D;
                    sch.arcs.push(it);
                    Some(ObjectRef::Arc(sch.arcs.len() as u32 - 1))
                }
                ObjectRef::Text(_) if i < sch.texts.len() => {
                    let mut it = sch.texts[i].clone();
                    it.x += D;
                    it.y += D;
                    sch.texts.push(it);
                    Some(ObjectRef::Text(sch.texts.len() as u32 - 1))
                }
                ObjectRef::Polygon(_) if i < sch.polygons.len() => {
                    let mut it = sch.polygons[i].clone();
                    for pt in &mut it.points {
                        pt[0] += D;
                        pt[1] += D;
                    }
                    sch.polygons.push(it);
                    Some(ObjectRef::Polygon(sch.polygons.len() as u32 - 1))
                }
                _ => None, // buses are not duplicated
            };
            if let Some(nr) = new_ref {
                doc.selection.objs.push(nr);
            }
        }
    }
}

// ════════════════════════════════════════════════════════════
// File handlers
// ════════════════════════════════════════════════════════════

