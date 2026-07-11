//! Canvas interaction: pan/zoom, mouse press/drag/release, per-tool click
//! handlers.


use eframe::egui::{self, PointerButton, Pos2, Response};

use schemify_editor::handler::{App, ObjectRef, PanMode, SELECT_HIT_RADIUS_SQ};
use schemify_editor::schemify::{Command,
    Tool};

use crate::state::{CtxHit, GuiState};

use super::*;

// ════════════════════════════════════════════════════════════
// Interaction
// ════════════════════════════════════════════════════════════

const MOVE_DRAG_THRESHOLD_PX: f32 = 4.0;

pub(crate) fn snap_world(vp: &CanvasViewport, pos: Pos2, snap_size: f32) -> [i32; 2] {
    vp.snap_to_grid(pos.x, pos.y, snap_size)
}

pub(crate) fn set_zoom(app: &mut App, zoom: f32) {
    use schemify_editor::handler::Viewport;
    app.state.active_document_mut().viewport.zoom =
        zoom.clamp(Viewport::MIN_ZOOM, Viewport::MAX_ZOOM);
}

pub(crate) fn pan_by_pixel_delta(app: &mut App, delta: egui::Vec2) {
    let vp = &mut app.state.active_document_mut().viewport;
    if vp.zoom <= 0.0 {
        return;
    }
    vp.pan[0] -= delta.x / vp.zoom;
    vp.pan[1] -= delta.y / vp.zoom;
}

pub(crate) fn handle_interaction(response: &Response, app: &mut App, gui: &mut GuiState,
    vp: &CanvasViewport, ctx: &egui::Context) {
    let snap = app.state.tool.snap_size;
    handle_space_key(app, ctx);
    handle_scroll_zoom(response, app, vp);
    handle_mouse_press(response, app, gui, vp, snap);
    handle_mouse_drag(response, app, vp, snap);
    handle_mouse_release(response, app, vp, snap);
}

/// Space: hold to pan-drag; tap toggles sticky grab mode.
pub(crate) fn handle_space_key(app: &mut App, ctx: &egui::Context) {
    let (pressed, released) = ctx.input(|i| {
        (i.key_pressed(egui::Key::Space), i.key_released(egui::Key::Space))
    });
    let cs = &mut app.state.canvas;
    if pressed {
        cs.space_held = true;
        cs.space_drag_happened = false;
    }
    if released {
        let drag_happened = cs.space_drag_happened;
        cs.space_held = false;
        if !drag_happened {
            cs.pan_mode = PanMode::Grab;
        }
        cs.space_drag_happened = false;
    }
}

/// Scroll zoom centered on the cursor: the world point under the pointer
/// stays stationary.
pub(crate) fn handle_scroll_zoom(response: &Response, app: &mut App, vp: &CanvasViewport) {
    if !response.hovered() {
        return;
    }
    let scroll_delta = response.ctx.input(|i| i.smooth_scroll_delta.y);
    if scroll_delta == 0.0 {
        return;
    }
    let Some(hover_pos) = response.hover_pos() else {
        return;
    };

    let world_before = vp.pixel_to_world(hover_pos.x, hover_pos.y);
    let old_zoom = app.active_doc().viewport.zoom;

    // ~0.001 per scroll pixel — smooth on touchpads, sane on mice.
    set_zoom(app, old_zoom * (scroll_delta * 0.001).exp());

    let actual_zoom = app.active_doc().viewport.zoom;
    if (actual_zoom - old_zoom).abs() > f32::EPSILON {
        let new_vp = CanvasViewport {
            center: vp.center,
            zoom: actual_zoom,
            pan: app.active_doc().viewport.pan,
        };
        let world_after = new_vp.pixel_to_world(hover_pos.x, hover_pos.y);
        let pan = &mut app.state.active_document_mut().viewport.pan;
        pan[0] += world_before[0] - world_after[0];
        pan[1] += world_before[1] - world_after[1];
    }
}

pub(crate) fn handle_mouse_press(response: &Response, app: &mut App, gui: &mut GuiState,
    vp: &CanvasViewport, snap: f32) {
    if response.clicked_by(PointerButton::Primary) {
        if app.state.canvas.pan_mode == PanMode::Grab {
            // Click exits sticky grab mode.
            let cs = &mut app.state.canvas;
            cs.pan_mode = PanMode::Off;
            cs.dragging = false;
            cs.move_active = false;
            cs.move_hit = None;
            return;
        }

        if app.state.canvas.space_held {
            if let Some(pos) = response.interact_pointer_pos() {
                let cs = &mut app.state.canvas;
                cs.dragging = true;
                cs.drag_is_pan = true;
                cs.drag_last = [pos.x, pos.y];
            }
            return;
        }

        if let Some(pos) = response.interact_pointer_pos() {
            let [wx, wy] = snap_world(vp, pos, snap);
            let tool = app.state.tool.active;
            let shift = response.ctx.input(|i| i.modifiers.shift);

            match tool {
                Tool::Select | Tool::Move => handle_select_click(app, pos, wx, wy, shift),
                Tool::Wire => handle_wire_click(app, wx, wy),
                Tool::Bus => handle_bus_click(app, wx, wy),
                Tool::BusRipper => handle_bus_ripper_click(app, wx, wy),
                Tool::Polygon => app.state.tool.draw.polygon_points.push([wx, wy]),
                Tool::Line | Tool::Rect | Tool::Circle | Tool::Arc => {
                    handle_draw_click(app, tool, wx, wy);
                }
                Tool::Text if !app.state.tool.draw.text_input_active => {
                    app.state.tool.draw.text_pos = Some([wx, wy]);
                    app.state.tool.draw.text_input_active = true;
                }
                _ => {}
            }

            // Active placement: click places the component.
            if app.state.tool.placement.is_some() {
                handle_placement_click(app, wx, wy);
            }
        }
    }

    // Right click → context menu.
    if response.clicked_by(PointerButton::Secondary) {
        if let Some(pos) = response.interact_pointer_pos() {
            let [wx, wy] = snap_world(vp, pos, snap);
            let hit = match app.hit_test(wx, wy) {
                Some(r) => CtxHit::Obj(r),
                // Buses/rippers aren't in the main hit test; probe here.
                None => {
                    if let Some(i) = app.hit_test_bus_ripper(wx, wy) {
                        CtxHit::BusRipper(i)
                    } else if let Some(i) = app.hit_test_bus(wx, wy, SELECT_HIT_RADIUS_SQ) {
                        CtxHit::Obj(ObjectRef::Bus(i as u32))
                    } else {
                        CtxHit::None
                    }
                }
            };
            // Seed inline bus editors from the hit bus.
            if let CtxHit::Obj(ObjectRef::Bus(i)) = hit {
                let i = i as usize;
                gui.ctx_menu.bus_rename = app.resolve(app.schematic().buses.label[i]).to_string();
                gui.ctx_menu.bus_width = app.schematic().buses.width[i];
            }
            gui.ctx_menu.open = true;
            gui.ctx_menu.pixel_pos = [pos.x, pos.y];
            gui.ctx_menu.world_pos = [wx, wy];
            gui.ctx_menu.hit = hit;
        }
    }

    // Double click → commit polygon or open properties.
    if response.double_clicked_by(PointerButton::Primary) {
        if app.state.tool.active == Tool::Polygon {
            app.commit_polygon();
        } else {
            app.dispatch(Command::OpenPropsDialog).or_status(app);
        }
    }
}

pub(crate) fn handle_mouse_drag(response: &Response, app: &mut App, vp: &CanvasViewport, snap: f32) {
    // Middle-drag → pan.
    if response.dragged_by(PointerButton::Middle) {
        let delta = response.drag_delta();
        if delta.length_sq() > 0.0 {
            pan_by_pixel_delta(app, delta);
        }
        return;
    }

    if !response.dragged_by(PointerButton::Primary) {
        return;
    }

    // Space-drag or pan-drag → pan.
    if app.state.canvas.drag_is_pan || app.state.canvas.space_held {
        let delta = response.drag_delta();
        if delta.length_sq() > 0.0 {
            app.state.canvas.space_drag_happened = true;
            pan_by_pixel_delta(app, delta);
        }
        return;
    }

    // Pan tool: left-drag pans.
    if app.state.tool.active == Tool::Pan {
        let delta = response.drag_delta();
        if delta.length_sq() > 0.0 {
            pan_by_pixel_delta(app, delta);
        }
        return;
    }

    // First drag frame: seed drag state from the press origin.
    if response.drag_started_by(PointerButton::Primary) {
        if let Some(origin) = response.ctx.input(|i| i.pointer.press_origin()) {
            app.state.canvas.move_press_pixel = [origin.x, origin.y];
            match app.state.tool.active {
                Tool::Select => {
                    let [wx, wy] = snap_world(vp, origin, snap);
                    if app.hit_test(wx, wy).is_none() {
                        let cs = &mut app.state.canvas;
                        cs.rubber_band_start = [wx, wy];
                        cs.rubber_band_end = [wx, wy];
                        cs.rubber_band_active = false;
                        cs.move_hit = None;
                    }
                }
                Tool::Move => {
                    // Grab whatever is under the cursor so drag promotion
                    // moves it immediately.
                    let [wx, wy] = snap_world(vp, origin, snap);
                    if app.hit_test(wx, wy).is_some() {
                        handle_select_click(app, origin, wx, wy, false);
                    }
                }
                _ => {}
            }
        }
    }

    if let Some(pos) = response.interact_pointer_pos() {
        // Move-drag promotion past the threshold.
        let cs = &app.state.canvas;
        if !cs.move_active && cs.move_hit.is_some() {
            let dx = pos.x - cs.move_press_pixel[0];
            let dy = pos.y - cs.move_press_pixel[1];
            if dx * dx + dy * dy >= MOVE_DRAG_THRESHOLD_PX * MOVE_DRAG_THRESHOLD_PX {
                let cs = &mut app.state.canvas;
                cs.move_active = true;
                cs.move_accum = [0, 0];
                cs.drag_last = [pos.x, pos.y];
            }
        }

        let cs = &app.state.canvas;
        if cs.move_active {
            let prev = snap_world(vp, Pos2::new(cs.drag_last[0], cs.drag_last[1]), snap);
            let curr = snap_world(vp, pos, snap);
            let (dx, dy) = (curr[0] - prev[0], curr[1] - prev[1]);
            if dx != 0 || dy != 0 {
                app.dispatch(Command::MoveSelected { dx, dy }).or_status(app);
            }
            app.state.canvas.drag_last = [pos.x, pos.y];
            return;
        }

        // Rubber-band drag.
        let cs = &app.state.canvas;
        if app.state.tool.active == Tool::Select && cs.move_hit.is_none() {
            let dx = pos.x - cs.move_press_pixel[0];
            let dy = pos.y - cs.move_press_pixel[1];
            if !cs.rubber_band_active
                && dx * dx + dy * dy >= MOVE_DRAG_THRESHOLD_PX * MOVE_DRAG_THRESHOLD_PX
            {
                app.state.canvas.rubber_band_active = true;
            }
            if app.state.canvas.rubber_band_active {
                app.state.canvas.rubber_band_end = snap_world(vp, pos, snap);
            }
        }
    }
}

pub(crate) fn handle_mouse_release(response: &Response, app: &mut App, vp: &CanvasViewport, snap: f32) {
    if response.drag_stopped_by(PointerButton::Primary) {
        let cs = &app.state.canvas;
        let (move_active, rubber_band_active, drag_is_pan) =
            (cs.move_active, cs.rubber_band_active, cs.drag_is_pan);
        let (rb_start, rb_end) = (cs.rubber_band_start, cs.rubber_band_end);

        // Wire/draw tools: fast mouse movement turns clicks into drags in
        // egui — treat a non-move drag release as a click.
        if !move_active && !rubber_band_active && !drag_is_pan {
            let tool = app.state.tool.active;
            if matches!(tool, Tool::Wire | Tool::Bus | Tool::Line | Tool::Rect | Tool::Circle
                | Tool::Arc)
            {
                if let Some(pos) = response.interact_pointer_pos() {
                    let [wx, wy] = snap_world(vp, pos, snap);
                    match tool {
                        Tool::Wire => handle_wire_click(app, wx, wy),
                        Tool::Bus => handle_bus_click(app, wx, wy),
                        _ => handle_draw_click(app, tool, wx, wy),
                    }
                }
            }
        }

        if rubber_band_active {
            app.select_in_rect(
                rb_start[0].min(rb_end[0]),
                rb_start[1].min(rb_end[1]),
                rb_start[0].max(rb_end[0]),
                rb_start[1].max(rb_end[1]),
            );
        }

        app.state.canvas.rubber_band_active = false;
        if move_active {
            // Commit coalesced move undo before clearing move_active.
            app.commit_move_drag();
        }
        let cs = &mut app.state.canvas;
        cs.move_active = false;
        cs.move_hit = None;
        cs.dragging = false;
        cs.drag_is_pan = false;
    }

    if response.drag_stopped_by(PointerButton::Middle) {
        let cs = &mut app.state.canvas;
        cs.dragging = false;
        cs.drag_is_pan = false;
    }
}

pub(crate) fn handle_select_click(app: &mut App, pos: Pos2, wx: i32, wy: i32, shift: bool) {
    let hit = app.hit_test(wx, wy);

    if let Some(r) = hit {
        {
            let cs = &mut app.state.canvas;
            cs.move_press_pixel = [pos.x, pos.y];
            cs.move_start_world = [wx, wy];
            cs.drag_last = [pos.x, pos.y];
        }

        // Click on an already-selected object → arm move for the whole set.
        if app.active_doc().selection.contains(r) {
            app.state.canvas.move_hit = Some(r);
            return;
        }

        if !shift {
            app.dispatch(Command::SelectNone).or_status(app);
        }
        app.state.canvas.move_hit = Some(r);
        app.selection_mut().insert(r);
    } else {
        let cs = &mut app.state.canvas;
        cs.rubber_band_start = [wx, wy];
        cs.rubber_band_end = [wx, wy];
        cs.rubber_band_active = false;
        cs.move_press_pixel = [pos.x, pos.y];
        cs.move_hit = None;
    }
}

/// Two-click wire placement: first click anchors, second commits a
/// Manhattan segment and chains from its endpoint.
pub(crate) fn handle_wire_click(app: &mut App, wx: i32, wy: i32) {
    if let Some(start) = app.state.tool.wire_start {
        if start != [wx, wy] {
            let end = app.manhattan_route(start, [wx, wy]);
            app.dispatch(Command::AddWire {
                x0: start[0],
                y0: start[1],
                x1: end[0],
                y1: end[1],
            }).or_status(app);
            app.state.tool.wire_start = Some(end);
            return;
        }
    }
    app.state.tool.wire_start = Some([wx, wy]);
}

/// Same two-click flow for buses; width/start_bit are defaults, edited
/// later via the context menu.
pub(crate) fn handle_bus_click(app: &mut App, wx: i32, wy: i32) {
    if let Some(start) = app.state.tool.wire_start {
        if start != [wx, wy] {
            let end = app.manhattan_route(start, [wx, wy]);
            let label = format!("BUS{}", app.schematic().buses.len());
            app.dispatch(Command::AddBus {
                label,
                width: 8,
                start_bit: 0,
                x0: start[0],
                y0: start[1],
                x1: end[0],
                y1: end[1],
            }).or_status(app);
            app.state.tool.wire_start = Some(end);
            return;
        }
    }
    app.state.tool.wire_start = Some([wx, wy]);
}

/// Click on (or near) a bus drops a ripper there.
pub(crate) fn handle_bus_ripper_click(app: &mut App, wx: i32, wy: i32) {
    if let Some(bus_idx) = app.hit_test_bus(wx, wy, SELECT_HIT_RADIUS_SQ) {
        app.dispatch(Command::AddBusRipper {
            bus_idx: bus_idx as u32,
            bit: 0,
            x: wx,
            y: wy,
            direction: 0,
        }).or_status(app);
    }
}

pub(crate) fn handle_draw_click(app: &mut App, tool: Tool, wx: i32, wy: i32) {
    let Some(start) = app.state.tool.draw.first_point else {
        app.state.tool.draw.first_point = Some([wx, wy]);
        return;
    };
    match tool {
        Tool::Line => app
            .dispatch(Command::AddLine {
                x0: start[0],
                y0: start[1],
                x1: wx,
                y1: wy,
            })
            .or_status(app),
        Tool::Rect => app
            .dispatch(Command::AddRect {
                x: start[0].min(wx),
                y: start[1].min(wy),
                w: (wx - start[0]).abs(),
                h: (wy - start[1]).abs(),
            })
            .or_status(app),
        Tool::Circle => {
            let dx = (wx - start[0]) as f64;
            let dy = (wy - start[1]) as f64;
            app.dispatch(Command::AddCircle {
                cx: start[0],
                cy: start[1],
                radius: (dx * dx + dy * dy).sqrt() as i32,
            }).or_status(app);
        }
        Tool::Arc => {
            let dx = (wx - start[0]) as f64;
            let dy = (wy - start[1]) as f64;
            app.dispatch(Command::AddArc {
                cx: start[0],
                cy: start[1],
                radius: (dx * dx + dy * dy).sqrt() as i32,
                start: dy.atan2(dx) as f32,
                sweep: std::f32::consts::PI,
            }).or_status(app);
        }
        _ => unreachable!(),
    }
    app.state.tool.draw.first_point = None;
}

pub(crate) fn handle_placement_click(app: &mut App, wx: i32, wy: i32) {
    let Some(pl) = app.state.tool.placement.clone() else {
        return;
    };
    app.dispatch(Command::PlaceDevice {
        symbol_path: pl.symbol_path,
        name: pl.name,
        x: wx,
        y: wy,
        rotation: pl.rotation,
        flip: pl.flip,
    }).or_status(app);
    // PlaceDevice doesn't reset tool state; SetTool does.
    app.dispatch(Command::SetTool(Tool::Select)).or_status(app);
}
