use egui::{PointerButton, Pos2, Response};

use schemify_core::commands::{Command, Tool};
use schemify_core::primitives;
use schemify_handler::App;
use schemify_handler::state::PanMode;

use super::viewport::CanvasViewport;

const MOVE_DRAG_THRESHOLD_PX: f32 = 4.0;
const SELECT_HIT_RADIUS_SQ: f64 = 400.0;

/// Handle all mouse/keyboard interaction on the canvas response area.
pub fn handle(
    response: &Response,
    app: &mut App,
    viewport: &CanvasViewport,
    ctx: &egui::Context,
) {
    let snap = app.tool_state().snap_size;

    handle_space_key(app, ctx);
    handle_scroll_zoom(response, app, viewport);
    handle_mouse_press(response, app, viewport, snap);
    handle_mouse_drag(response, app, viewport, snap);
    handle_mouse_release(response, app, viewport, snap);
}

// ── Space key (pan toggle) ──────────────────────────────────────────────────

fn handle_space_key(app: &mut App, ctx: &egui::Context) {
    ctx.input(|i| {
        if i.key_pressed(egui::Key::Space) {
            app.canvas_mut().space_held = true;
            app.canvas_mut().space_drag_happened = false;
        }
        if i.key_released(egui::Key::Space) {
            let cs = &app.canvas();
            let drag_happened = cs.space_drag_happened;
            app.canvas_mut().space_held = false;
            if !drag_happened {
                // Toggle sticky grab mode.
                app.canvas_mut().pan_mode = PanMode::Grab;
            }
            app.canvas_mut().space_drag_happened = false;
        }
    });
}

// ── Scroll zoom (centered on cursor) ────────────────────────────────────────

fn handle_scroll_zoom(response: &Response, app: &mut App, viewport: &CanvasViewport) {
    if !response.hovered() {
        return;
    }

    let scroll_delta = response.ctx.input(|i| i.smooth_scroll_delta.y);
    if scroll_delta == 0.0 {
        return;
    }

    let hover_pos = match response.hover_pos() {
        Some(p) => p,
        None => return,
    };

    let world_before = viewport.pixel_to_world(hover_pos.x, hover_pos.y);

    let old_zoom = app.zoom();

    // Apply zoom.
    if scroll_delta > 0.0 {
        app.dispatch(Command::ZoomIn);
    } else {
        app.dispatch(Command::ZoomOut);
    }

    // Adjust pan so the world point under the cursor stays stationary.
    // After zoom change, compute where world_before now maps and correct pan.
    let actual_zoom = app.zoom();
    if (actual_zoom - old_zoom).abs() > f32::EPSILON {
        let new_vp = CanvasViewport {
            center: viewport.center,
            zoom: actual_zoom,
            pan: app.pan(),
        };
        let world_after = new_vp.pixel_to_world(hover_pos.x, hover_pos.y);
        let mut pan = app.pan();
        pan[0] += world_before[0] - world_after[0];
        pan[1] += world_before[1] - world_after[1];
        app.set_pan(pan[0], pan[1]);
    }
}

// ── Mouse press ─────────────────────────────────────────────────────────────

fn handle_mouse_press(
    response: &Response,
    app: &mut App,
    viewport: &CanvasViewport,
    snap: f32,
) {
    // Middle button -> start pan.
    if response.middle_clicked() || (response.clicked_by(PointerButton::Primary) && response.ctx.input(|i| i.pointer.button_pressed(PointerButton::Middle))) {
        // Handled below in drag.
    }

    if response.clicked_by(PointerButton::Primary) {
        let cs = &app.canvas();

        if cs.pan_mode == PanMode::Grab {
            // Click to exit grab mode.
            app.canvas_mut().pan_mode = PanMode::Off;
            app.canvas_mut().dragging = false;
            app.canvas_mut().move_active = false;
            app.canvas_mut().move_hit_idx = None;
            return;
        }

        if cs.space_held {
            // Space + click -> start pan drag (handled in drag section).
            if let Some(pos) = response.interact_pointer_pos() {
                app.canvas_mut().dragging = true;
                app.canvas_mut().drag_is_pan = true;
                app.canvas_mut().drag_last = [pos.x, pos.y];
            }
            return;
        }

        if let Some(pos) = response.interact_pointer_pos() {
            let [wx, wy] = snap_world(viewport, pos, snap);
            let tool = app.active_tool();

            match tool {
                Tool::Select => handle_select_click(app, viewport, pos, wx, wy),
                Tool::Wire => handle_wire_click(app, wx, wy),
                Tool::Line | Tool::Rect | Tool::Circle | Tool::Arc | Tool::Polygon => {
                    handle_draw_click(app, tool, wx, wy);
                }
                _ => {}
            }

            // If placement is active, click to place the component.
            if app.tool_state().placement.is_some() {
                handle_placement_click(app, wx, wy);
            }
        }
    }

    // Right click -> context menu.
    if response.clicked_by(PointerButton::Secondary) {
        if let Some(pos) = response.interact_pointer_pos() {
            let [wx, wy] = snap_world(viewport, pos, snap);

            let inst_hit = hit_test_instance(app, wx, wy);
            let wire_hit = hit_test_wire(app, wx, wy);

            app.ctx_menu_mut().open = true;
            app.ctx_menu_mut().pixel_pos = [pos.x, pos.y];
            app.ctx_menu_mut().inst_idx = inst_hit;
            app.ctx_menu_mut().wire_idx = wire_hit;
        }
    }

    // Double click -> open properties.
    if response.double_clicked_by(PointerButton::Primary) {
        app.dispatch(Command::OpenPropsDialog);
    }
}

// ── Mouse drag ──────────────────────────────────────────────────────────────

fn handle_mouse_drag(
    response: &Response,
    app: &mut App,
    viewport: &CanvasViewport,
    snap: f32,
) {
    // Middle-drag -> pan.
    if response.dragged_by(PointerButton::Middle) {
        let delta = response.drag_delta();
        if delta.length_sq() > 0.0 {
            pan_by_pixel_delta(app, viewport, delta);
        }
        return;
    }

    // Left-drag handling.
    if !response.dragged_by(PointerButton::Primary) {
        return;
    }

    let cs = &app.canvas();

    // Space + drag -> pan.
    if cs.drag_is_pan || cs.space_held {
        let delta = response.drag_delta();
        if delta.length_sq() > 0.0 {
            app.canvas_mut().space_drag_happened = true;
            pan_by_pixel_delta(app, viewport, delta);
        }
        return;
    }

    // Move-drag promotion: check if we exceed the threshold.
    if let Some(pos) = response.interact_pointer_pos() {
        let cs = &app.canvas();
        if !cs.move_active && cs.move_hit_idx.is_some() {
            let dx_px = pos.x - cs.move_press_pixel[0];
            let dy_px = pos.y - cs.move_press_pixel[1];
            if dx_px * dx_px + dy_px * dy_px >= MOVE_DRAG_THRESHOLD_PX * MOVE_DRAG_THRESHOLD_PX {
                app.canvas_mut().move_active = true;
                app.canvas_mut().drag_last = [pos.x, pos.y];
            }
        }

        let cs = &app.canvas();
        if cs.move_active {
            // Move selected objects by drag delta.
            let prev = snap_world(viewport, Pos2::new(cs.drag_last[0], cs.drag_last[1]), snap);
            let curr = snap_world(viewport, pos, snap);
            let dx = curr[0] - prev[0];
            let dy = curr[1] - prev[1];
            if dx != 0 || dy != 0 {
                app.dispatch(Command::MoveSelected { dx, dy });
            }
            app.canvas_mut().drag_last = [pos.x, pos.y];
            return;
        }

        // Rubber-band selection drag.
        let cs = &app.canvas();
        if app.active_tool() == Tool::Select && cs.move_hit_idx.is_none() {
            let dx_px = pos.x - cs.move_press_pixel[0];
            let dy_px = pos.y - cs.move_press_pixel[1];
            if !cs.rubber_band_active
                && dx_px * dx_px + dy_px * dy_px
                    >= MOVE_DRAG_THRESHOLD_PX * MOVE_DRAG_THRESHOLD_PX
            {
                app.canvas_mut().rubber_band_active = true;
            }

            if app.canvas().rubber_band_active {
                let [wx, wy] = snap_world(viewport, pos, snap);
                app.canvas_mut().rubber_band_end = [wx, wy];
            }
        }
    }
}

// ── Mouse release ───────────────────────────────────────────────────────────

fn handle_mouse_release(
    response: &Response,
    app: &mut App,
    _viewport: &CanvasViewport,
    _snap: f32,
) {
    // We detect release indirectly: if the button was being dragged and is no longer.
    // egui doesn't have a direct "released" event, but drag_stopped works.
    if response.drag_stopped_by(PointerButton::Primary) {
        let cs = &app.canvas();

        // Complete rubber-band selection.
        if cs.rubber_band_active {
            let start = cs.rubber_band_start;
            let end = cs.rubber_band_end;
            let min_x = start[0].min(end[0]);
            let min_y = start[1].min(end[1]);
            let max_x = start[0].max(end[0]);
            let max_y = start[1].max(end[1]);

            select_in_rect(app, min_x, min_y, max_x, max_y);
        }

        app.canvas_mut().rubber_band_active = false;
        app.canvas_mut().move_active = false;
        app.canvas_mut().move_hit_idx = None;
        app.canvas_mut().dragging = false;
        app.canvas_mut().drag_is_pan = false;
    }

    if response.drag_stopped_by(PointerButton::Middle) {
        app.canvas_mut().dragging = false;
        app.canvas_mut().drag_is_pan = false;
    }
}

// ── Select click handler ────────────────────────────────────────────────────

fn handle_select_click(app: &mut App, _viewport: &CanvasViewport, pos: Pos2, wx: i32, wy: i32) {

    // Hit test.
    let inst_hit = hit_test_instance(app, wx, wy);
    let wire_hit = hit_test_wire(app, wx, wy);

    if inst_hit.is_some() || wire_hit.is_some() {
        // Prime move: record which object was hit in case of drag.
        app.canvas_mut().move_press_pixel = [pos.x, pos.y];
        app.canvas_mut().move_start_world = [wx, wy];
        app.canvas_mut().drag_last = [pos.x, pos.y];
    }

    // Check if we clicked on an already-selected object (for move).
    if let Some(idx) = inst_hit {
        if app.is_instance_selected(idx) {
            app.canvas_mut().move_hit_idx = Some(idx);
            return;
        }
    }
    if let Some(idx) = wire_hit {
        if app.is_wire_selected(idx) {
            app.canvas_mut().move_hit_idx = Some(idx);
            return;
        }
    }

    // Not on a selected object, so do selection.
    app.dispatch(Command::SelectNone);

    if let Some(idx) = inst_hit {
        app.canvas_mut().move_hit_idx = Some(idx);
        app.select_instance(idx);
        return;
    }

    if let Some(idx) = wire_hit {
        app.canvas_mut().move_hit_idx = Some(idx);
        app.select_wire(idx);
        return;
    }

    // Clicked on empty space — prepare for rubber band.
    app.canvas_mut().rubber_band_start = [wx, wy];
    app.canvas_mut().rubber_band_end = [wx, wy];
    app.canvas_mut().rubber_band_active = false;
    app.canvas_mut().move_press_pixel = [pos.x, pos.y];
    app.canvas_mut().move_hit_idx = None;
}

// ── Wire tool click ─────────────────────────────────────────────────────────

fn handle_wire_click(app: &mut App, wx: i32, wy: i32) {
    if let Some(start) = app.tool_state().wire_start {
        // Second click: commit the wire.
        if start[0] != wx || start[1] != wy {
            // Manhattan routing: pick the dominant axis.
            let dx = (wx - start[0]).unsigned_abs();
            let dy = (wy - start[1]).unsigned_abs();
            let end = if dx >= dy {
                [wx, start[1]]
            } else {
                [start[0], wy]
            };

            let bus = app.tool_state().bus_mode;
            app.dispatch(Command::AddWire {
                x0: start[0],
                y0: start[1],
                x1: end[0],
                y1: end[1],
                net_name: None,
                bus,
            });
        }
        // Chain from endpoint for continuous wire drawing.
        app.set_wire_start(Some([wx, wy]));
    } else {
        // First click: set wire start.
        app.set_wire_start(Some([wx, wy]));
    }
}

// ── Drawing tool click ──────────────────────────────────────────────────────

fn handle_draw_click(app: &mut App, tool: Tool, wx: i32, wy: i32) {
    if app.tool_state().draw.first_point.is_none() {
        // First click: set start point.
        app.set_draw_first_point(Some([wx, wy]));
    } else {
        let start = app.tool_state().draw.first_point.unwrap();
        // Second click: commit the shape.
        match tool {
            Tool::Line => {
                app.dispatch(Command::AddLine {
                    x0: start[0], y0: start[1], x1: wx, y1: wy,
                });
            }
            Tool::Rect => {
                app.dispatch(Command::AddRect {
                    x: start[0].min(wx), y: start[1].min(wy),
                    w: (wx - start[0]).abs(), h: (wy - start[1]).abs(),
                });
            }
            Tool::Circle => {
                let dx = (wx - start[0]) as f64;
                let dy = (wy - start[1]) as f64;
                let radius = (dx * dx + dy * dy).sqrt() as i32;
                app.dispatch(Command::AddCircle {
                    cx: start[0], cy: start[1], radius,
                });
            }
            Tool::Arc => {
                let dx = (wx - start[0]) as f64;
                let dy = (wy - start[1]) as f64;
                let radius = (dx * dx + dy * dy).sqrt() as i32;
                let start_angle = dy.atan2(dx) as f32;
                app.dispatch(Command::AddArc {
                    cx: start[0], cy: start[1], radius,
                    start: start_angle, sweep: std::f32::consts::PI,
                });
            }
            _ => {}
        }
        app.set_draw_first_point(None);
    }
}

// ── Placement click ─────────────────────────────────────────────────────────

fn handle_placement_click(app: &mut App, wx: i32, wy: i32) {
    let pl = match &app.tool_state().placement {
        Some(p) => p.clone(),
        None => return,
    };

    app.dispatch(Command::PlaceDevice {
        symbol_path: pl.symbol_path.clone(),
        name: pl.name.clone(),
        x: wx,
        y: wy,
        rotation: pl.rotation,
        flip: pl.flip,
    });

    // Clear placement (PlaceDevice doesn't reset tool state, SetTool does).
    app.dispatch(Command::SetTool(Tool::Select));
}

// ── Pan helper ──────────────────────────────────────────────────────────────

fn pan_by_pixel_delta(app: &mut App, viewport: &CanvasViewport, delta: egui::Vec2) {
    // Pan is in world coordinates, so convert pixel delta to world delta.
    // delta_world = delta_pixel / zoom
    // Pan moves opposite to drag direction (dragging right -> scene moves left -> pan decreases).
    let _ = viewport; // zoom accessible from app
    let zoom = app.zoom();
    if zoom <= 0.0 {
        return;
    }
    let pan = app.pan();
    let new_pan = [pan[0] - delta.x / zoom, pan[1] - delta.y / zoom];

    app.set_pan(new_pan[0], new_pan[1]);
}

// ── Hit testing ─────────────────────────────────────────────────────────────

fn hit_test_instance(app: &App, wx: i32, wy: i32) -> Option<usize> {
    let insts = app.instances();
    let n = insts.len();
    for i in 0..n {
        let dx = wx as f64 - insts.x[i] as f64;
        let dy = wy as f64 - insts.y[i] as f64;

        // For instances with primitives, check against the bounding extent.
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
            (25.0_f64) * 25.0
        };

        if dx * dx + dy * dy < tol_sq {
            return Some(i);
        }
    }
    None
}

fn hit_test_wire(app: &App, wx: i32, wy: i32) -> Option<usize> {
    let wires = app.wires();
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
            let mut t = ((wpx - ax) * abx + (wpy - ay) * aby) / len2;
            t = t.clamp(0.0, 1.0);
            let cx = ax + t * abx;
            let cy = ay + t * aby;
            let ddx = wpx - cx;
            let ddy = wpy - cy;
            ddx * ddx + ddy * ddy
        };

        if d2 < SELECT_HIT_RADIUS_SQ {
            return Some(i);
        }
    }
    None
}

// ── Rubber-band selection ───────────────────────────────────────────────────

fn select_in_rect(app: &mut App, min_x: i32, min_y: i32, max_x: i32, max_y: i32) {
    app.dispatch(Command::SelectNone);

    let insts = app.instances();
    let n = insts.len();
    let mut inst_hits = Vec::new();
    for i in 0..n {
        let x = insts.x[i];
        let y = insts.y[i];
        if x >= min_x && x <= max_x && y >= min_y && y <= max_y {
            inst_hits.push(i);
        }
    }

    let wires = app.wires();
    let wn = wires.len();
    let mut wire_hits = Vec::new();
    for i in 0..wn {
        let x0 = wires.x0[i];
        let y0 = wires.y0[i];
        let x1 = wires.x1[i];
        let y1 = wires.y1[i];
        if x0 >= min_x && x0 <= max_x && y0 >= min_y && y0 <= max_y
            && x1 >= min_x && x1 <= max_x && y1 >= min_y && y1 <= max_y
        {
            wire_hits.push(i);
        }
    }

    for idx in inst_hits {
        app.select_instance(idx);
    }
    for idx in wire_hits {
        app.select_wire(idx);
    }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn snap_world(viewport: &CanvasViewport, pos: Pos2, snap_size: f32) -> [i32; 2] {
    viewport.snap_to_grid(pos.x, pos.y, snap_size)
}
