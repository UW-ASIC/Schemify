//! Orthogonal router with A* pathfinding, net classification and label support.
//!
//! Pipeline (ported + compacted from old `schemify-net2schem::routing`):
//! 1. Classify each net (Wire vs Label) — classifier merged into this module
//! 2. Build a sparse obstacle grid from placed component bounding boxes
//! 3. Route Wire-strategy nets via A* (fall back to L-shape if no path)
//! 4. Route Label-strategy nets with net labels at each pin
//! 5. Post-process: merge collinear segments, restore T-junctions, dedupe,
//!    grid-snap endpoints

use std::collections::{HashMap, HashSet};

use crate::emit::{pin_position, PinGeometry};
use crate::ir::{Instance, Label, Net, NetClass, NetId, PinIdx, Subcircuit, Wire};
use crate::shared::{is_ground_name, is_power_name};

/// Grid resolution for the A* routing grid.
const GRID_RES: i32 = 10;

/// Approximate half-width of a component bounding box for obstacle marking.
const COMPONENT_HALF_W: i32 = 40;
/// Approximate half-height of a component bounding box for obstacle marking.
const COMPONENT_HALF_H: i32 = 40;

// ---------------------------------------------------------------------------
// A* cost parameters
// ---------------------------------------------------------------------------

/// Base cost for moving one grid cell.
const COST_BASE: i32 = 1;
/// Penalty for changing direction (bend).
const COST_BEND: i32 = 3;
/// Penalty for crossing an existing wire (Q4): worth a 20-cell detour.
const COST_CROSSING: i32 = 20;

/// Hard cap on the adaptive budget multiplier. Without it, large circuits
/// produced multipliers in the hundreds (net count x spread), i.e. tens of
/// millions of A* iterations *per pin pair*.
const ADAPTIVE_MULTIPLIER_CAP: f64 = 8.0;

/// Full A* escalation failures tolerated per net before its remaining pin
/// pairs skip the A* attempts and go straight to L-shape routing.
const MAX_ASTAR_FAILURES_PER_NET: u32 = 2;

/// Pin pairs farther apart than this (schematic units) skip A* and go
/// straight to the detour sweep: long-haul searches in dense layouts mostly
/// exhaust enormous windows (seconds of work), and the offset-trunk U-shape
/// is the right corridor answer for row-spanning connections anyway.
const ASTAR_MAX_PAIR_DIST: i32 = 3000;

/// Iteration cap for the window-exhausting (generous-budget) A* attempts so
/// a failing search over a large window stays bounded.
const GENEROUS_BUDGET_CAP: usize = 250_000;

/// Bucket edge length (schematic units) for the crossing-penalty spatial
/// index. A* step segments are GRID_RES long, so a lookup touches <= 2
/// buckets instead of scanning every routed segment.
const CROSSING_BUCKET: i32 = 80;

// ---------------------------------------------------------------------------
// Classifier parameters
// ---------------------------------------------------------------------------

/// Base Manhattan span threshold (schematic units) for a net to qualify as `Wire`.
const BASE_WIRE_DISTANCE_THRESHOLD: i32 = 500;

/// Fanout above which a net is always labelled (too many connections to draw).
const FANOUT_THRESHOLD: usize = 6;

// ---------------------------------------------------------------------------
// Net classifier
// ---------------------------------------------------------------------------

/// Strategy for drawing a net on the schematic.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetStrategy {
    /// Route with A* or L-shape wires.
    Wire,
    /// Use net labels at each pin (no drawn wires).
    Label,
}

// Two distinct adaptive mechanisms share the bbox half-perimeter measure:
//  * `adaptive_multiplier` scales the A* per-pair *search budget* by circuit
//    size (net-count factor x spread/200 factor, hard-capped at
//    ADAPTIVE_MULTIPLIER_CAP) so dense or spread-out layouts get more
//    iterations before giving up,
//  * `adaptive_threshold` scales the classifier's wire-vs-label *span cutoff*
//    up to the instance bbox half-perimeter (min BASE_WIRE_DISTANCE_THRESHOLD)
//    so local nets in large layouts still draw as wires.
// Both grow with layout spread but gate different decisions (search effort vs
// drawing strategy); the shared bbox math lives in `instance_half_perimeter`.

/// Half-perimeter (x-span + y-span) of the instance-origin bounding box.
/// Returns 0 with fewer than 2 instances.

mod astar;
mod geom;
mod grid;
mod labels;
mod optimize;
mod shape;

pub(crate) use astar::*;
pub(crate) use geom::*;
pub(crate) use grid::*;
pub(crate) use labels::*;
pub(crate) use optimize::*;
pub(crate) use shape::*;

fn instance_half_perimeter(subckt: &Subcircuit) -> i32 {
    if subckt.instances.len() < 2 {
        return 0;
    }
    let mut min_x = i32::MAX;
    let mut max_x = i32::MIN;
    let mut min_y = i32::MAX;
    let mut max_y = i32::MIN;
    for inst in &subckt.instances {
        min_x = min_x.min(inst.x);
        max_x = max_x.max(inst.x);
        min_y = min_y.min(inst.y);
        max_y = max_y.max(inst.y);
    }
    (max_x - min_x) + (max_y - min_y)
}

/// Adaptive wire distance threshold for the classifier (see comment above).
fn adaptive_threshold(subckt: &Subcircuit) -> i32 {
    // A quarter of the half-perimeter: scales with layout spread so local
    // nets in big layouts still wire, without making EVERY span "local" — a
    // net crossing most of the array is long no matter how big the array is
    // (Q5 "long span ⇒ label", and near-full-span wires are what blow up Q4:
    // flash-ADC ladder taps at ~30% of the span still cross every column).
    BASE_WIRE_DISTANCE_THRESHOLD.max(instance_half_perimeter(subckt) / 4)
}

/// Adaptive A* search budget multiplier (see comment above).
/// Clamped to [1.0, ADAPTIVE_MULTIPLIER_CAP].
fn adaptive_multiplier(subckt: &Subcircuit) -> f64 {
    let net_factor = (subckt.nets.len() as f64 / 10.0).max(1.0);
    let dist_factor = (instance_half_perimeter(subckt) as f64 / 200.0).max(1.0);
    (net_factor * dist_factor).min(ADAPTIVE_MULTIPLIER_CAP)
}

/// Classify all nets in a subcircuit based on post-placement pin positions.
pub fn classify_nets<B: PinGeometry + ?Sized>(
    subckt: &Subcircuit,
    backend: &B,
) -> Vec<NetStrategy> {
    let threshold = adaptive_threshold(subckt);
    subckt
        .nets
        .iter()
        .map(|net| classify_net(net, subckt, threshold, backend))
        .collect()
}

/// Classify a single net.
fn classify_net<B: PinGeometry + ?Sized>(
    net: &Net,
    subckt: &Subcircuit,
    wire_threshold: i32,
    backend: &B,
) -> NetStrategy {
    // Nets with 0 or 1 pins have nothing to route.
    if net.pins.len() < 2 {
        return NetStrategy::Label;
    }

    // Global nets (power rails) always get labels.
    if net.is_global {
        return NetStrategy::Label;
    }

    // Well-known power/ground names and classified power/ground nets always
    // get labels (rail symbols) — standard EDA practice, and avoids MST+A*
    // routing of high-fanout rails across the whole layout.
    if is_power_name(&net.name)
        || is_ground_name(&net.name)
        || matches!(net.classification, NetClass::Power | NetClass::Ground)
    {
        return NetStrategy::Label;
    }

    // High-fanout nets always get labels — checked BEFORE block membership:
    // array structures (e.g. SRAM word/bit lines) are intra-block nets with
    // dozens of pins spanning the whole row; wiring them forces trunk lines
    // through every cell body (R6). Labels are the standard drawing for them.
    if net.pins.len() > FANOUT_THRESHOLD {
        return NetStrategy::Label;
    }

    // Manhattan span of all pin positions vs the adaptive threshold.
    let mut min_x = i32::MAX;
    let mut max_x = i32::MIN;
    let mut min_y = i32::MAX;
    let mut max_y = i32::MIN;
    for pin_ref in &net.pins {
        let inst = &subckt[pin_ref.instance_idx];
        let (px, py) = pin_position(backend, inst, pin_ref.pin_idx.index());
        min_x = min_x.min(px);
        max_x = max_x.max(px);
        min_y = min_y.min(py);
        max_y = max_y.max(py);
    }
    let manhattan_span = (max_x - min_x) + (max_y - min_y);

    // Block-internal nets wire within the span threshold like everything
    // else: templates place block members adjacently, so genuine block
    // wiring is short. (Intra-/inter-block paths used to force wires at ANY
    // span; a flash-ADC ladder tap is "intra-block" at the divider yet runs
    // to a comparator across the array — near-full-span wires are what blow
    // up Q4. Long is long, block or not.)
    if manhattan_span <= wire_threshold {
        NetStrategy::Wire
    } else {
        NetStrategy::Label
    }
}

// ---------------------------------------------------------------------------
// Public router interface
// ---------------------------------------------------------------------------

/// Orthogonal wire router with net-label support.

pub struct Router {
    /// Grid snap quantum. Coordinates are rounded to the nearest multiple.
    pub grid_snap: i32,
    /// User-supplied multiplier applied on top of the adaptive budget scaling.
    /// Default is 1.0 (no extra scaling). Increase to allow more search effort.
    pub budget_multiplier: f64,
}

impl Default for Router {
    fn default() -> Self {
        Self {
            grid_snap: 10,
            budget_multiplier: 1.0,
        }
    }
}

impl Router {
    pub fn new() -> Self {
        Self::default()
    }

    /// Route all nets in the subcircuit, populating `subckt.wires` and `subckt.labels`.
    ///
    /// Uses the net classifier to decide strategy, then A* for Wire-strategy nets
    /// with L-shape fallback, and net labels for Label-strategy nets.
    pub fn route<B: PinGeometry + ?Sized>(&self, subckt: &mut Subcircuit, backend: &B) {
        let adaptive_mult = adaptive_multiplier(subckt) * self.budget_multiplier;
        let strategies = classify_nets(subckt, backend);

        // Build obstacle grid from placed component bounding boxes. This is
        // the A* navigation grid: pin entry channels of OTHER nets stay
        // blocked so a path can never thread through a foreign component's
        // pin corridor (those paths are R6 body violations); the current
        // net's own pin channels are opened per net in the routing loop.
        let mut obstacles = build_obstacle_grid(&subckt.instances);

        // (net_idx, pin_positions) split by strategy.
        let mut wire_nets: Vec<(usize, Vec<(i32, i32)>)> = Vec::new();
        let mut label_nets: Vec<(usize, Vec<(i32, i32)>)> = Vec::new();

        // Map of snapped pin positions -> net indices for foreign-pin avoidance.
        // Include ALL nets (even single-pin) so wires never pass through any pin.
        let mut pin_pos_to_nets: HashMap<(i32, i32), Vec<usize>> = HashMap::new();
        for (net_i, net) in subckt.nets.iter().enumerate() {
            for pr in &net.pins {
                let inst = &subckt[pr.instance_idx];
                let (px, py) = pin_position(backend, inst, pr.pin_idx.index());
                let pos = (self.snap(px), self.snap(py));
                pin_pos_to_nets.entry(pos).or_default().push(net_i);
            }
        }

        // Body-only scoring grid for L-shape/detour legality checks: the
        // tight per-instance pin-hull footprint (R6's exact body
        // definition), NOT the inflated navigation grid — in dense arrays
        // the ±COMPONENT_HALF inflation fuses into a solid wall, blinding
        // the scorer to the real inter-component lanes.
        let body_grid = build_body_score_grid(subckt, backend);

        for (net_i, strategy) in strategies.iter().enumerate() {
            let net = &subckt.nets[net_i];
            if net.pins.is_empty() {
                continue;
            }

            // Wire-strategy nets cap at 32 pins to bound A* search cost.
            // Label-strategy nets use all pins so every connection gets a label.
            let limit = match strategy {
                NetStrategy::Wire => net.pins.len().min(32),
                NetStrategy::Label => net.pins.len(),
            };
            let positions: Vec<(i32, i32)> = (0..limit)
                .map(|p| {
                    let pr = net.pins[p];
                    let inst = &subckt[pr.instance_idx];
                    let (px, py) = pin_position(backend, inst, pr.pin_idx.index());
                    (self.snap(px), self.snap(py))
                })
                .collect();

            match strategy {
                NetStrategy::Wire => wire_nets.push((net_i, positions)),
                NetStrategy::Label => label_nets.push((net_i, positions)),
            }
        }

        // Sort wire nets by ascending Manhattan span (short locals first).
        wire_nets.sort_by_key(|(_, positions)| manhattan_span(positions));

        // Spatial index of routed segments for crossing-penalty lookups.
        let mut wire_index = WireIndex::default();

        // Reusable A* workspace across all nets.
        let mut workspace = RouterWorkspace::new();

        // --- Route Wire-strategy nets ---
        // Foreign-pin buffer reused across nets (pins belonging only to other nets).
        let mut foreign_pins: HashSet<(i32, i32)> = HashSet::with_capacity(pin_pos_to_nets.len());
        // Navigation-grid cells temporarily opened around the current net's pins.
        let mut reopened: Vec<(i32, i32)> = Vec::new();
        for (net_i, positions) in &wire_nets {
            foreign_pins.clear();
            foreign_pins.extend(
                pin_pos_to_nets
                    .iter()
                    .filter(|(_, nets)| nets.iter().all(|&n| n != *net_i))
                    .map(|(&(px, py), _)| (px / GRID_RES, py / GRID_RES)),
            );

            // Open this net's own pin entry channels in the navigation grid
            // so A* can enter/exit pins sitting inside component bodies.
            reopened.clear();
            for &(px, py) in positions {
                let gx = px / GRID_RES;
                let gy = py / GRID_RES;
                for &(dx, dy) in &[(0, 0), (0, -1), (0, 1), (-1, 0), (1, 0)] {
                    if obstacles.get(gx + dx, gy + dy) {
                        obstacles.unset(gx + dx, gy + dy);
                        reopened.push((gx + dx, gy + dy));
                    }
                }
            }

            let result = route_multi_pin_net(
                NetId(*net_i as u32),
                positions,
                &obstacles,
                &body_grid,
                &foreign_pins,
                &wire_index,
                self,
                adaptive_mult,
                &pin_pos_to_nets,
                *net_i,
                &mut workspace,
            );

            // Re-close this net's pin channels for subsequent nets.
            for &(gx, gy) in &reopened {
                obstacles.set(gx, gy);
            }

            for w in &result {
                wire_index.add((w.x1, w.y1, w.x2, w.y2));
                mark_wire_on_grid_hard(&mut obstacles, w);
            }
            subckt.wires.extend(result);

            // Wire nets always end fully wired (escalation ladder bottoms out
            // at the unconditional detour sweep) -> single naming label at
            // first pin.
            if let Some(&(px, py)) = positions.first() {
                subckt.labels.push(Label {
                    net_idx: NetId(*net_i as u32),
                    x: px,
                    y: py,
                    rotation: 0,
                });
            }
        }

        // --- Place labels for Label-strategy nets ---
        for (net_i, positions) in &label_nets {
            let is_power_gnd = {
                let net = &subckt.nets[*net_i];
                matches!(net.classification, NetClass::Power | NetClass::Ground)
                    || is_power_name(&net.name)
                    || is_ground_name(&net.name)
            };

            // MOSFET bulk tied to source on the same power/ground net: draw a
            // short stub wire source→bulk and skip the bulk's rail symbol —
            // one symbol per device instead of two stacked 30 units apart.
            let mut keep = vec![true; positions.len()];
            if is_power_gnd {
                let net = &subckt.nets[*net_i];
                let mut stubs: Vec<Wire> = Vec::new();
                for (a, pra) in net.pins.iter().enumerate() {
                    if pra.pin_idx != PinIdx(3) || a >= positions.len() {
                        continue;
                    }
                    let inst = &subckt[pra.instance_idx];
                    if !inst.primitive.is_mosfet() {
                        continue;
                    }
                    let source = net.pins.iter().position(|prb| {
                        prb.instance_idx == pra.instance_idx && prb.pin_idx == PinIdx(2)
                    });
                    if let Some(b) = source.filter(|&b| b < positions.len()) {
                        keep[a] = false;
                        let (sx, sy) = positions[b];
                        let (bx, by) = positions[a];
                        stubs.push(Wire {
                            net_idx: NetId(*net_i as u32),
                            x1: sx,
                            y1: sy,
                            x2: bx,
                            y2: by,
                        });
                    }
                }
                subckt.wires.extend(stubs);
            }

            let kept: Vec<(i32, i32)> = positions
                .iter()
                .zip(&keep)
                .filter_map(|(&p, &k)| k.then_some(p))
                .collect();
            place_labels_for_net(NetId(*net_i as u32), &kept, &mut subckt.labels, is_power_gnd);
        }

        // Post-process: merge collinear segments, restore T-junctions, deduplicate.
        optimize_wires(&mut subckt.wires);
    }

    /// Snap a coordinate to the nearest grid multiple.
    fn snap(&self, val: i32) -> i32 {
        snap(val, self.grid_snap)
    }
}

/// Grid-snap a single coordinate (round-half-up toward +inf).
fn snap(val: i32, grid_snap: i32) -> i32 {
    if grid_snap == 0 {
        return val;
    }
    let rem = val.rem_euclid(grid_snap);
    if rem < (grid_snap + 1) / 2 {
        val - rem
    } else {
        val - rem + grid_snap
    }
}

// ---------------------------------------------------------------------------
// BitGrid – compact obstacle storage
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests;
