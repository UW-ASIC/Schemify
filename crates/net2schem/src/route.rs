//! Orthogonal router with A* pathfinding, net classification and label support.
//!
//! Pipeline (ported + compacted from old `schemify-net2schem::routing`):
//! 1. Classify each net (Wire vs Label) — classifier merged into this module
//! 2. Build a sparse obstacle grid from placed component bounding boxes
//! 3. Route Wire-strategy nets via A* (fall back to L-shape if no path)
//! 4. Route Label-strategy nets with net labels at each pin
//! 5. Post-process: merge collinear segments, restore T-junctions, dedupe,
//!    grid-snap endpoints

use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap, HashSet};

use crate::emit::{pin_position, PinGeometry};
use crate::ir::{Instance, Label, Net, NetClass, NetId, PinIdx, Subcircuit, Wire};
use crate::recognition::Block;
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
///
/// `blocks` is accepted for API stability but no longer influences strategy:
/// block membership used to force wires at any span, which blew up Q4 on
/// array layouts (see `classify_net`).
pub fn classify_nets<B: PinGeometry + ?Sized>(
    subckt: &Subcircuit,
    backend: &B,
    _blocks: &[Block],
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
        self.route_with_blocks(subckt, backend, &[]);
    }

    /// Route with recognized block info for smarter wire vs label decisions.
    pub fn route_with_blocks<B: PinGeometry + ?Sized>(
        &self,
        subckt: &mut Subcircuit,
        backend: &B,
        blocks: &[Block],
    ) {
        let adaptive_mult = adaptive_multiplier(subckt) * self.budget_multiplier;
        let strategies = classify_nets(subckt, backend, blocks);

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

/// Compact bit-grid for obstacle tracking (flat Vec<u64> with computed indices).
#[derive(Clone)]
struct BitGrid {
    data: Vec<u64>,
    min_x: i32,
    min_y: i32,
    width: usize,
    height: usize,
}

impl BitGrid {
    fn new(min_x: i32, min_y: i32, max_x: i32, max_y: i32) -> Self {
        let width = ((max_x - min_x + 1) as usize).max(1);
        let height = ((max_y - min_y + 1) as usize).max(1);
        let num_u64 = (width * height).div_ceil(64);
        Self {
            data: vec![0u64; num_u64],
            min_x,
            min_y,
            width,
            height,
        }
    }

    fn idx(&self, gx: i32, gy: i32) -> Option<usize> {
        let lx = gx - self.min_x;
        let ly = gy - self.min_y;
        if lx >= 0 && ly >= 0 && (lx as usize) < self.width && (ly as usize) < self.height {
            Some(ly as usize * self.width + lx as usize)
        } else {
            None
        }
    }

    fn set(&mut self, gx: i32, gy: i32) {
        if let Some(idx) = self.idx(gx, gy) {
            self.data[idx / 64] |= 1u64 << (idx % 64);
        }
    }

    fn get(&self, gx: i32, gy: i32) -> bool {
        match self.idx(gx, gy) {
            Some(idx) => (self.data[idx / 64] >> (idx % 64)) & 1 == 1,
            None => false,
        }
    }

    fn unset(&mut self, gx: i32, gy: i32) {
        if let Some(idx) = self.idx(gx, gy) {
            self.data[idx / 64] &= !(1u64 << (idx % 64));
        }
    }
}

// ---------------------------------------------------------------------------
// Obstacle grid
// ---------------------------------------------------------------------------

/// Build a compact obstacle grid from instance bounding boxes.
///
/// Each cell in the grid (at GRID_RES resolution) that overlaps a component
/// is marked as an obstacle.
fn build_obstacle_grid(instances: &[Instance]) -> BitGrid {
    if instances.is_empty() {
        return BitGrid::new(0, 0, 1, 1);
    }
    let hw = COMPONENT_HALF_W / GRID_RES;
    let hh = COMPONENT_HALF_H / GRID_RES;
    let padding = 200; // Extra cells for routing headroom
    let mut min_x = i32::MAX;
    let mut min_y = i32::MAX;
    let mut max_x = i32::MIN;
    let mut max_y = i32::MIN;
    for inst in instances {
        let cx = inst.x / GRID_RES;
        let cy = inst.y / GRID_RES;
        min_x = min_x.min(cx - hw);
        min_y = min_y.min(cy - hh);
        max_x = max_x.max(cx + hw);
        max_y = max_y.max(cy + hh);
    }
    let mut grid = BitGrid::new(
        min_x - padding,
        min_y - padding,
        max_x + padding,
        max_y + padding,
    );
    for inst in instances {
        let cx = inst.x / GRID_RES;
        let cy = inst.y / GRID_RES;
        for gx in (cx - hw)..=(cx + hw) {
            for gy in (cy - hh)..=(cy + hh) {
                grid.set(gx, gy);
            }
        }
    }
    grid
}

/// Tight per-instance body grid for L-shape/detour scoring, matching the
/// R6 body definition: bbox of the instance origin plus its transformed pin
/// positions, with zero extents widened to one grid (±10). Only STRICTLY
/// interior grid points are marked — a wire running along the hull edge
/// (where the pins sit) is legal — so the real lanes between adjacent
/// components stay visible to the scorer, unlike the conservative
/// ±COMPONENT_HALF_W/H navigation grid.
fn build_body_score_grid<B: PinGeometry + ?Sized>(subckt: &Subcircuit, backend: &B) -> BitGrid {
    let instances = &subckt.instances;
    if instances.is_empty() {
        return BitGrid::new(0, 0, 1, 1);
    }
    // Same overall grid bounds as the navigation grid.
    let hw = COMPONENT_HALF_W / GRID_RES;
    let hh = COMPONENT_HALF_H / GRID_RES;
    let padding = 200;
    let mut min_x = i32::MAX;
    let mut min_y = i32::MAX;
    let mut max_x = i32::MIN;
    let mut max_y = i32::MIN;
    for inst in instances {
        let cx = inst.x / GRID_RES;
        let cy = inst.y / GRID_RES;
        min_x = min_x.min(cx - hw);
        min_y = min_y.min(cy - hh);
        max_x = max_x.max(cx + hw);
        max_y = max_y.max(cy + hh);
    }
    let mut grid = BitGrid::new(
        min_x - padding,
        min_y - padding,
        max_x + padding,
        max_y + padding,
    );
    for inst in instances {
        let mut x_min = inst.x;
        let mut x_max = inst.x;
        let mut y_min = inst.y;
        let mut y_max = inst.y;
        for pi in 0..inst.pins.len() {
            let (px, py) = pin_position(backend, inst, pi);
            x_min = x_min.min(px);
            x_max = x_max.max(px);
            y_min = y_min.min(py);
            y_max = y_max.max(py);
        }
        if x_min == x_max {
            x_min -= GRID_RES;
            x_max += GRID_RES;
        }
        if y_min == y_max {
            y_min -= GRID_RES;
            y_max += GRID_RES;
        }
        // Strictly interior grid points: g*GRID_RES in the OPEN interval.
        let gx0 = x_min.div_euclid(GRID_RES) + 1;
        let gx1 = (x_max - 1).div_euclid(GRID_RES);
        let gy0 = y_min.div_euclid(GRID_RES) + 1;
        let gy1 = (y_max - 1).div_euclid(GRID_RES);
        for gx in gx0..=gx1 {
            for gy in gy0..=gy1 {
                grid.set(gx, gy);
            }
        }
    }
    grid
}

/// Mark grid cells along a wire segment as hard obstacles for subsequent nets.
fn mark_wire_on_grid_hard(obstacles: &mut BitGrid, wire: &Wire) {
    let x1 = wire.x1 / GRID_RES;
    let y1 = wire.y1 / GRID_RES;
    let x2 = wire.x2 / GRID_RES;
    let y2 = wire.y2 / GRID_RES;
    if y1 == y2 {
        let (lo, hi) = minmax(x1, x2);
        for gx in lo..=hi {
            obstacles.set(gx, y1);
        }
    } else if x1 == x2 {
        let (lo, hi) = minmax(y1, y2);
        for gy in lo..=hi {
            obstacles.set(x1, gy);
        }
    }
}

// ---------------------------------------------------------------------------
// Crossing-penalty spatial index
// ---------------------------------------------------------------------------

/// Spatial bucket index over routed wire segments. Each segment is inserted
/// into every CROSSING_BUCKET-sized cell it touches; an A* step (GRID_RES
/// long) queries at most 2 cells instead of scanning all routed wires.
///
/// Also tracks which routed segments already conductively touch each other
/// (directly or transitively) with a union-find, so candidate scoring can
/// count only NEW cross-net merges: a foreign segment already reachable
/// from one of the candidate net's own pin points adds no new short no
/// matter what gets drawn.
#[derive(Default)]
struct WireIndex {
    /// All routed segments, by id.
    segs: Vec<(i32, i32, i32, i32)>,
    /// Spatial buckets of segment ids.
    buckets: HashMap<(i32, i32), Vec<u32>>,
    /// Union-find parent per segment id (existing conductive contacts).
    parent: Vec<u32>,
}

/// Iterate the bucket cells overlapped by a segment's bounding box.
fn bucket_range(seg: (i32, i32, i32, i32)) -> impl Iterator<Item = (i32, i32)> {
    let (bx_lo, bx_hi) = minmax(
        seg.0.div_euclid(CROSSING_BUCKET),
        seg.2.div_euclid(CROSSING_BUCKET),
    );
    let (by_lo, by_hi) = minmax(
        seg.1.div_euclid(CROSSING_BUCKET),
        seg.3.div_euclid(CROSSING_BUCKET),
    );
    (bx_lo..=bx_hi).flat_map(move |bx| (by_lo..=by_hi).map(move |by| (bx, by)))
}

impl WireIndex {
    /// Union-find root of a segment id (no path compression; chains are
    /// short and lookups need only `&self`).
    fn find(&self, mut i: u32) -> u32 {
        while self.parent[i as usize] != i {
            i = self.parent[i as usize];
        }
        i
    }

    fn add(&mut self, seg: (i32, i32, i32, i32)) {
        let id = self.segs.len() as u32;
        self.segs.push(seg);
        self.parent.push(id);
        // Merge with already-routed segments this one conductively touches
        // (same-net T-joints AND any pre-existing cross-net contacts).
        for cell in bucket_range(seg) {
            if let Some(ids) = self.buckets.get(&cell) {
                for &j in ids {
                    if conductive_touch(seg, self.segs[j as usize]) {
                        let (ra, rb) = (self.find(id), self.find(j));
                        if ra != rb {
                            self.parent[ra as usize] = rb;
                        }
                    }
                }
            }
        }
        for cell in bucket_range(seg) {
            self.buckets.entry(cell).or_default().push(id);
        }
    }

    /// Does the (short, axis-aligned) segment a-b properly cross any indexed wire?
    fn crosses(&self, a: (i32, i32), b: (i32, i32)) -> bool {
        for cell in bucket_range((a.0, a.1, b.0, b.1)) {
            if let Some(ids) = self.buckets.get(&cell) {
                for &id in ids {
                    let (x1, y1, x2, y2) = self.segs[id as usize];
                    if orthogonal_segments_intersect(a.0, a.1, b.0, b.1, x1, y1, x2, y2) {
                        return true;
                    }
                }
            }
        }
        false
    }

    /// Count indexed wires the (axis-aligned) segment properly crosses.
    /// Bucket-deduped so a wire spanning several buckets counts once.
    fn count_crossings(&self, seg: (i32, i32, i32, i32)) -> u32 {
        let mut seen: Vec<u32> = Vec::new();
        for cell in bucket_range(seg) {
            if let Some(ids) = self.buckets.get(&cell) {
                for &id in ids {
                    if seen.contains(&id) {
                        continue;
                    }
                    let (x1, y1, x2, y2) = self.segs[id as usize];
                    if orthogonal_segments_intersect(seg.0, seg.1, seg.2, seg.3, x1, y1, x2, y2) {
                        seen.push(id);
                    }
                }
            }
        }
        seen.len() as u32
    }

    /// Is the point on any indexed (foreign) wire segment, endpoints
    /// inclusive? A path point there becomes a cross-net T-touch /
    /// coincident-point / collinear short once emitted.
    fn point_on_any(&self, p: (i32, i32)) -> bool {
        let b = (p.0.div_euclid(CROSSING_BUCKET), p.1.div_euclid(CROSSING_BUCKET));
        self.buckets.get(&b).is_some_and(|ids| {
            ids.iter()
                .any(|&id| point_on_wire(p, self.segs[id as usize]))
        })
    }

    /// Union-find roots of all indexed segments containing point `p`.
    fn roots_at_point(&self, p: (i32, i32), out: &mut Vec<u32>) {
        let b = (p.0.div_euclid(CROSSING_BUCKET), p.1.div_euclid(CROSSING_BUCKET));
        if let Some(ids) = self.buckets.get(&b) {
            for &id in ids {
                if point_on_wire(p, self.segs[id as usize]) {
                    let r = self.find(id);
                    if !out.contains(&r) {
                        out.push(r);
                    }
                }
            }
        }
    }

    /// Count the NEW cross-net merges the candidate segment would create:
    /// distinct connected components (by existing conductive contact) of
    /// indexed foreign wires that the candidate touches (see
    /// `conductive_touch`) and that are NOT already reachable from one of
    /// the `exempt` points (the candidate net's own pins, fixed by
    /// placement — anything already touching them is merged with this net
    /// regardless of what gets drawn). Every count here becomes an
    /// electrical short once core's `resolve_connectivity` runs (R8).
    fn count_touches(&self, seg: (i32, i32, i32, i32), exempt: &[(i32, i32)]) -> u32 {
        let mut exempt_roots: Vec<u32> = Vec::new();
        for &p in exempt {
            self.roots_at_point(p, &mut exempt_roots);
        }
        let mut new_roots: Vec<u32> = Vec::new();
        for cell in bucket_range(seg) {
            if let Some(ids) = self.buckets.get(&cell) {
                for &id in ids {
                    if conductive_touch(seg, self.segs[id as usize]) {
                        let r = self.find(id);
                        if !exempt_roots.contains(&r) && !new_roots.contains(&r) {
                            new_roots.push(r);
                        }
                    }
                }
            }
        }
        new_roots.len() as u32
    }
}

/// Crossing lookup for the net being routed: the global spatial index plus a
/// small linear list of this net's own segments routed so far.
struct CrossingCtx<'a> {
    index: &'a WireIndex,
    own: &'a [(i32, i32, i32, i32)],
}

impl CrossingCtx<'_> {
    fn crosses(&self, a: (i32, i32), b: (i32, i32)) -> bool {
        self.index.crosses(a, b) || segments_cross(a, b, self.own)
    }
}

// ---------------------------------------------------------------------------
// Multi-pin net routing
// ---------------------------------------------------------------------------

/// Route a multi-pin net, iteratively connecting the nearest unconnected pin
/// to the set of already-routed pins (minimum spanning tree approach).
///
/// Every pin pair with distinct positions ends up wired (strict Q5: a
/// Wire-classified net must be routed with wires). Escalation ladder per pair:
///  1. windowed A*, standard budget
///  a. windowed A*, generous budget (cheap — bounded by the window)
///  b. windowed A*, generous budget, relaxed crossing penalty
///  c. widened-window A* (3x margin), generous budget, relaxed crossings —
///     only for short pairs, where the window stays small
///  d. detour sweep: L-shapes plus Z/U-shapes with the trunk line shifted off
///     the pin rows; the least-damaging candidate wins (foreign-pin shorts
///     weighted far above cosmetic body crossings), so a clean corridor is
///     taken whenever one exists. May still trip R6 if every candidate
///     collides; accepted trade-off for guaranteed connectivity.
/// After MAX_ASTAR_FAILURES_PER_NET full A* failures, remaining pairs of the
/// net skip steps 1-c (per-net failure budget); pairs farther apart than
/// ASTAR_MAX_PAIR_DIST skip them outright (bounded work on huge layouts).
#[allow(clippy::too_many_arguments)]
fn route_multi_pin_net(
    net_idx: NetId,
    positions: &[(i32, i32)],
    obstacles: &BitGrid,
    body_grid: &BitGrid,
    foreign_pins: &HashSet<(i32, i32)>,
    wire_index: &WireIndex,
    router: &Router,
    budget_multiplier: f64,
    pin_pos_to_nets: &HashMap<(i32, i32), Vec<usize>>,
    current_net: usize,
    workspace: &mut RouterWorkspace,
) -> Vec<Wire> {
    if positions.len() < 2 {
        return Vec::new();
    }

    let mut wires = Vec::new();
    let mut routed_pins: Vec<usize> = vec![0]; // Start with first pin.
    let mut remaining: Vec<usize> = (1..positions.len()).collect();

    // This net's own segments routed so far (crossing penalty sees them too).
    let mut own: Vec<(i32, i32, i32, i32)> = Vec::new();
    let mut astar_failures: u32 = 0;

    let safety = LShapeSafety {
        pin_pos_to_nets,
        current_net,
        obstacles: body_grid,
        foreign_wires: wire_index,
    };

    while !remaining.is_empty() {
        // Find the closest pair (routed_pin, remaining_pin).
        let mut best_dist = i32::MAX;
        let mut best_routed = 0;
        let mut best_remaining_idx = 0;

        for (ri, &rem_idx) in remaining.iter().enumerate() {
            for &rp_idx in &routed_pins {
                let d = manhattan(positions[rp_idx], positions[rem_idx]);
                if d < best_dist {
                    best_dist = d;
                    best_routed = rp_idx;
                    best_remaining_idx = ri;
                }
            }
        }

        let target_idx = remaining.remove(best_remaining_idx);
        routed_pins.push(target_idx);

        let from = positions[best_routed];
        let to = positions[target_idx];

        let segment_wires = if from == to {
            Vec::new()
        } else {
            let ctx = CrossingCtx {
                index: wire_index,
                own: &own,
            };
            let mut path = None;
            if astar_failures < MAX_ASTAR_FAILURES_PER_NET
                && manhattan(from, to) <= ASTAR_MAX_PAIR_DIST
            {
                // (1) Windowed A*, standard budget.
                path = astar_path(
                    from, to, obstacles, foreign_pins, &ctx, budget_multiplier, 1, false, false,
                    workspace,
                );
                // (a) Generous budget: exhaust the search window.
                if path.is_none() {
                    path = astar_path(
                        from, to, obstacles, foreign_pins, &ctx, budget_multiplier, 1, true, false,
                        workspace,
                    );
                }
                // (b) Relaxed crossing penalty.
                if path.is_none() {
                    path = astar_path(
                        from, to, obstacles, foreign_pins, &ctx, budget_multiplier, 1, true, true,
                        workspace,
                    );
                }
                // (c) Widened window (3x margin) for short pairs: detours
                // around dense pin rows often lie just outside the base
                // window. Bounded: only when the window stays small.
                if path.is_none() && manhattan(from, to) <= 800 {
                    path = astar_path(
                        from, to, obstacles, foreign_pins, &ctx, budget_multiplier, 3, true, true,
                        workspace,
                    );
                }
                if path.is_none() {
                    astar_failures += 1;
                }
            }
            // A*-found paths still need a conductive-touch check: navigation
            // cells reopened around this net's own pins can overlap foreign
            // wires, letting a path elbow on / terminate on / run along one
            // (T-touch or collinear short, R8). Reject such paths and let
            // the detour ladder find a legal shape instead.
            let path_wires = path
                .map(|p| path_to_wires(net_idx, &p, router.grid_snap))
                .filter(|ws| {
                    ws.iter().all(|w| {
                        wire_index.count_touches((w.x1, w.y1, w.x2, w.y2), &[from, to]) == 0
                    })
                });
            match path_wires {
                Some(ws) => ws,
                None => {
                    // (d) Safe L-shape fast path, then the detour sweep:
                    // always produces wires; picks the least-damaging
                    // candidate (legal whenever any candidate is).
                    let safe = l_shape(net_idx, from, to, false, Some(&safety));
                    if safe.is_empty() {
                        best_detour(net_idx, from, to, &safety)
                    } else {
                        safe
                    }
                }
            }
        };

        own.extend(segment_wires.iter().map(|w| (w.x1, w.y1, w.x2, w.y2)));
        wires.extend(segment_wires);
    }

    wires
}

// ---------------------------------------------------------------------------
// A* pathfinder
// ---------------------------------------------------------------------------

type BestMap = HashMap<(i32, i32), (i32, Direction, Option<(i32, i32)>)>;

/// Reusable A* scratch buffers (allocated once, cleared per pin pair).
struct RouterWorkspace {
    open: BinaryHeap<AStarNode>,
    best: BestMap,
    closed: HashSet<(i32, i32)>,
}

impl RouterWorkspace {
    fn new() -> Self {
        Self {
            open: BinaryHeap::new(),
            best: HashMap::new(),
            closed: HashSet::new(),
        }
    }

    fn clear(&mut self) {
        self.open.clear();
        self.best.clear();
        self.closed.clear();
    }
}

/// Direction of movement on the grid.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum Direction {
    Up,
    Down,
    Left,
    Right,
    None, // start node
}

/// A* search node.
#[derive(Debug, Clone, Eq, PartialEq)]
struct AStarNode {
    pos: (i32, i32),
    g_cost: i32,
    f_cost: i32,
    direction: Direction,
}

impl Ord for AStarNode {
    fn cmp(&self, other: &Self) -> Ordering {
        // Min-heap: reverse comparison on f_cost, break ties on g_cost (prefer more explored).
        other
            .f_cost
            .cmp(&self.f_cost)
            .then_with(|| other.g_cost.cmp(&self.g_cost))
    }
}

impl PartialOrd for AStarNode {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// Find a path from `start` to `end` on the grid using A*.
///
/// Returns `None` if start==end or no path exists within the search budget.
///
/// Coordinates are in schematic units (not grid cells); internally converted
/// to grid cells at `GRID_RES` resolution.
///
/// The search is confined to the start-end bounding box inflated by
/// `max(20, dist/4) * margin_mult` grid cells, so a failing search exhausts
/// a bounded window instead of flooding the whole layout (`margin_mult > 1`
/// is the widened-window escalation retry).
///
/// Budget: with `generous_budget`, enough iterations to exhaust the window
/// (4 pushes per cell max). Otherwise `(manhattan_distance + 1) * 200`
/// capped at 100 000, times `budget_multiplier`.
///
/// `ignore_crossings` disables the crossing penalty (escalation step b).
#[allow(clippy::too_many_arguments)]
fn astar_path(
    start: (i32, i32),
    end: (i32, i32),
    obstacles: &BitGrid,
    foreign_pins: &HashSet<(i32, i32)>,
    crossings: &CrossingCtx,
    budget_multiplier: f64,
    margin_mult: i32,
    generous_budget: bool,
    ignore_crossings: bool,
    workspace: &mut RouterWorkspace,
) -> Option<Vec<(i32, i32)>> {
    if start == end {
        return None;
    }

    let s = (start.0 / GRID_RES, start.1 / GRID_RES);
    let e = (end.0 / GRID_RES, end.1 / GRID_RES);

    let dist = manhattan(s, e);

    // Inflated src-dst bounding window (grid cells).
    let margin = 20.max(dist / 4) * margin_mult.max(1);
    let win_x = (s.0.min(e.0) - margin, s.0.max(e.0) + margin);
    let win_y = (s.1.min(e.1) - margin, s.1.max(e.1) + margin);

    let max_iterations = if generous_budget {
        // Exhausting the window: at most 4 pushes (and thus pops) per cell,
        // capped so failing searches over large windows stay bounded.
        let w = (win_x.1 - win_x.0 + 1) as u64;
        let h = (win_y.1 - win_y.0 + 1) as u64;
        ((w * h * 4) as usize).min(GENEROUS_BUDGET_CAP)
    } else {
        let base_budget = ((dist as u64 + 1) * 200).min(100_000) as f64;
        (base_budget * budget_multiplier) as usize
    };

    workspace.clear();

    workspace.open.push(AStarNode {
        pos: s,
        g_cost: 0,
        f_cost: manhattan(s, e),
        direction: Direction::None,
    });
    workspace.best.insert(s, (0, Direction::None, None));

    let neighbors: [(i32, i32, Direction); 4] = [
        (0, -1, Direction::Up),
        (0, 1, Direction::Down),
        (-1, 0, Direction::Left),
        (1, 0, Direction::Right),
    ];

    let mut iterations = 0;

    while let Some(current) = workspace.open.pop() {
        iterations += 1;
        if iterations > max_iterations {
            return None; // Search budget exhausted.
        }

        if current.pos == e {
            return Some(reconstruct_path(&workspace.best, s, e));
        }

        if workspace.closed.contains(&current.pos) {
            continue;
        }
        workspace.closed.insert(current.pos);

        // Check that this is still the best known cost for this position.
        if let Some(&(known_g, _, _)) = workspace.best.get(&current.pos) {
            if current.g_cost > known_g {
                continue;
            }
        }

        for &(dx, dy, dir) in &neighbors {
            let np = (current.pos.0 + dx, current.pos.1 + dy);

            // Stay inside the search window.
            if np.0 < win_x.0 || np.0 > win_x.1 || np.1 < win_y.0 || np.1 > win_y.1 {
                continue;
            }

            if workspace.closed.contains(&np) {
                continue;
            }

            // Allow start and end even if they overlap obstacles (pins are on components).
            if np != s && np != e && (obstacles.get(np.0, np.1) || foreign_pins.contains(&np)) {
                continue;
            }

            // Conductive-touch legality: a path point lying ON a foreign
            // routed wire becomes a cross-net T-touch / collinear short
            // once emitted. Foreign-wire cells are hard obstacles already;
            // this closes the hole left by cells reopened around the
            // current net's own pins (unconditional — even the relaxed
            // escalation rungs must not short).
            if np != s
                && np != e
                && crossings
                    .index
                    .point_on_any((np.0 * GRID_RES, np.1 * GRID_RES))
            {
                continue;
            }

            let mut step_cost = COST_BASE;

            // Bend penalty.
            if current.direction != Direction::None && current.direction != dir {
                step_cost += COST_BEND;
            }

            // Crossing penalty: moving from current to np across an existing wire.
            if !ignore_crossings {
                let seg_start = (current.pos.0 * GRID_RES, current.pos.1 * GRID_RES);
                let seg_end = (np.0 * GRID_RES, np.1 * GRID_RES);
                if crossings.crosses(seg_start, seg_end) {
                    step_cost += COST_CROSSING;
                }
            }

            let new_g = current.g_cost + step_cost;
            let should_update = match workspace.best.get(&np) {
                Some(&(existing_g, _, _)) => new_g < existing_g,
                None => true,
            };

            if should_update {
                let h = manhattan(np, e);
                workspace.best.insert(np, (new_g, dir, Some(current.pos)));
                workspace.open.push(AStarNode {
                    pos: np,
                    g_cost: new_g,
                    f_cost: new_g + h,
                    direction: dir,
                });
            }
        }
    }

    None // No path found.
}

/// Reconstruct the path from start to end using the best-cost map.
fn reconstruct_path(best: &BestMap, start: (i32, i32), end: (i32, i32)) -> Vec<(i32, i32)> {
    let mut path = Vec::new();
    let mut current = end;
    path.push((current.0 * GRID_RES, current.1 * GRID_RES));

    while current != start {
        if let Some(&(_, _, Some(parent))) = best.get(&current) {
            current = parent;
            path.push((current.0 * GRID_RES, current.1 * GRID_RES));
        } else {
            break;
        }
    }

    path.reverse();
    path
}

// ---------------------------------------------------------------------------
// Segment crossing detection
// ---------------------------------------------------------------------------

/// Check if the segment (a->b) crosses any of the existing wire segments.
fn segments_cross(a: (i32, i32), b: (i32, i32), existing_wires: &[(i32, i32, i32, i32)]) -> bool {
    existing_wires
        .iter()
        .any(|&(x1, y1, x2, y2)| orthogonal_segments_intersect(a.0, a.1, b.0, b.1, x1, y1, x2, y2))
}

/// Check if two axis-aligned segments intersect (proper crossing, not shared endpoints).
#[allow(clippy::too_many_arguments)]
fn orthogonal_segments_intersect(
    ax1: i32,
    ay1: i32,
    ax2: i32,
    ay2: i32,
    bx1: i32,
    by1: i32,
    bx2: i32,
    by2: i32,
) -> bool {
    let a_horiz = ay1 == ay2;
    let a_vert = ax1 == ax2;
    let b_horiz = by1 == by2;
    let b_vert = bx1 == bx2;

    // Only perpendicular pairs can properly cross.
    if a_horiz && b_vert {
        let (a_min_x, a_max_x) = minmax(ax1, ax2);
        let (b_min_y, b_max_y) = minmax(by1, by2);
        // Strict intersection (not endpoint touching).
        bx1 > a_min_x && bx1 < a_max_x && ay1 > b_min_y && ay1 < b_max_y
    } else if a_vert && b_horiz {
        let (b_min_x, b_max_x) = minmax(bx1, bx2);
        let (a_min_y, a_max_y) = minmax(ay1, ay2);
        ax1 > b_min_x && ax1 < b_max_x && by1 > a_min_y && by1 < a_max_y
    } else {
        false
    }
}

fn minmax(a: i32, b: i32) -> (i32, i32) {
    if a <= b {
        (a, b)
    } else {
        (b, a)
    }
}

// ---------------------------------------------------------------------------
// Cross-net conductive-touch legality
// ---------------------------------------------------------------------------
//
// Core's `resolve_connectivity` is a point-keyed union-find over wire
// endpoints plus T-junction detection (wire endpoint ON another wire's
// interior) plus pin-on-wire merging. For two wires of DIFFERENT nets that
// means:
//   * shared endpoint point            -> connected (same union-find key),
//   * endpoint on the other's interior -> connected (T-junction),
//   * collinear overlap                -> connected (always implies an
//                                         endpoint of one lying on the other),
//   * pure perpendicular X-crossing
//     (both interiors, no endpoint on
//     the other segment)               -> NOT connected (legal).
// So the router's legality rule is exactly: no endpoint of either segment
// may lie ON the other segment (endpoints inclusive). X-crossings stay legal.

/// Is `p` on the axis-aligned segment `s` (endpoints inclusive)?
fn point_on_wire(p: (i32, i32), s: (i32, i32, i32, i32)) -> bool {
    let (x1, y1, x2, y2) = s;
    if y1 == y2 {
        let (lo, hi) = minmax(x1, x2);
        p.1 == y1 && lo <= p.0 && p.0 <= hi
    } else if x1 == x2 {
        let (lo, hi) = minmax(y1, y2);
        p.0 == x1 && lo <= p.1 && p.1 <= hi
    } else {
        false
    }
}

/// Conductive touch between two axis-aligned segments: any endpoint of one
/// lying ON the other (endpoints inclusive). Per the rules above this is
/// exactly the condition under which core's connectivity engine merges
/// them; pure perpendicular X-crossings return false (legal).
fn conductive_touch(c: (i32, i32, i32, i32), f: (i32, i32, i32, i32)) -> bool {
    point_on_wire((c.0, c.1), f)
        || point_on_wire((c.2, c.3), f)
        || point_on_wire((f.0, f.1), c)
        || point_on_wire((f.2, f.3), c)
}

// ---------------------------------------------------------------------------
// Path -> Wire conversion
// ---------------------------------------------------------------------------

/// Convert a path (sequence of grid-snapped points) into Wire segments,
/// merging collinear consecutive points into single segments.
fn path_to_wires(net_idx: NetId, path: &[(i32, i32)], grid_snap: i32) -> Vec<Wire> {
    if path.len() < 2 {
        return Vec::new();
    }

    let mut wires = Vec::new();
    let mut seg_start = 0;

    for i in 1..path.len() {
        // Check if the next point continues in the same direction.
        if i + 1 < path.len() {
            let dx1 = (path[i].0 - path[i - 1].0).signum();
            let dy1 = (path[i].1 - path[i - 1].1).signum();
            let dx2 = (path[i + 1].0 - path[i].0).signum();
            let dy2 = (path[i + 1].1 - path[i].1).signum();
            if dx1 == dx2 && dy1 == dy2 {
                continue; // Collinear, keep extending.
            }
        }

        let (x1, y1) = path[seg_start];
        let (x2, y2) = path[i];

        // Skip zero-length segments.
        if x1 != x2 || y1 != y2 {
            wires.push(Wire {
                net_idx,
                x1: snap(x1, grid_snap),
                y1: snap(y1, grid_snap),
                x2: snap(x2, grid_snap),
                y2: snap(y2, grid_snap),
            });
        }
        seg_start = i;
    }

    wires
}

// ---------------------------------------------------------------------------
// L-shape fallback
// ---------------------------------------------------------------------------

/// Context for safe L-shape generation (foreign-pin + foreign-wire +
/// component-body avoidance).
struct LShapeSafety<'a> {
    pin_pos_to_nets: &'a HashMap<(i32, i32), Vec<usize>>,
    current_net: usize,
    obstacles: &'a BitGrid,
    /// Routed segments of previously routed (foreign) nets: candidate
    /// endpoints/corners must not land on them and collinear overlap is
    /// forbidden (X-crossings are fine) — see `conductive_touch`.
    foreign_wires: &'a WireIndex,
}

impl LShapeSafety<'_> {
    /// Does this point sit on a pin belonging to another net?
    fn is_foreign(&self, pt: (i32, i32)) -> bool {
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
    fn hit_score(&self, wires: &[Wire], corner: (i32, i32), from: (i32, i32), to: (i32, i32)) -> u32 {
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
    fn score_path(&self, pts: &[(i32, i32)], from: (i32, i32), to: (i32, i32)) -> u32 {
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
fn l_shape(
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
const DETOUR_OFFSETS: [i32; 32] = [
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
fn best_detour(
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

/// Place net labels at each pin position for a Label-strategy net.
///
/// When `force_upright` is true (power/ground nets), rotation is always 0
/// so VDD/GND rail symbols keep their canonical orientation (vdd above,
/// gnd below the pin).
fn place_labels_for_net(
    net_idx: NetId,
    positions: &[(i32, i32)],
    labels: &mut Vec<Label>,
    force_upright: bool,
) {
    if positions.is_empty() {
        return;
    }

    // Single pin: place label pointing right (default).
    if positions.len() == 1 {
        labels.push(Label {
            net_idx,
            x: positions[0].0,
            y: positions[0].1,
            rotation: 0,
        });
        return;
    }

    // Compute centroid; each label points away from it.
    let cx: i32 = positions.iter().map(|p| p.0).sum::<i32>() / positions.len() as i32;
    let cy: i32 = positions.iter().map(|p| p.1).sum::<i32>() / positions.len() as i32;

    for &(px, py) in positions {
        let rotation = if force_upright {
            0
        } else {
            label_rotation(px, py, cx, cy)
        };
        labels.push(Label {
            net_idx,
            x: px,
            y: py,
            rotation,
        });
    }
}

/// Pick label rotation so it points *away* from the other endpoint.
///
/// 0 = right, 1 = up, 2 = left, 3 = down.
fn label_rotation(from_x: i32, from_y: i32, to_x: i32, to_y: i32) -> u8 {
    let dx = to_x - from_x;
    let dy = to_y - from_y;
    if dx.abs() >= dy.abs() {
        if dx >= 0 {
            2
        } else {
            0
        }
    } else if dy >= 0 {
        1
    } else {
        3
    }
}

// ---------------------------------------------------------------------------
// Wire post-processing
// ---------------------------------------------------------------------------

/// Optimize wire segments: merge collinear, restore T-junctions, deduplicate.
/// Order matters — each step depends on the previous.
fn optimize_wires(wires: &mut Vec<Wire>) {
    *wires = merge_collinear_wires(wires);
    *wires = restore_t_junctions(wires);
    // Drop exact duplicate segments (same coords, any net); first occurrence
    // wins. A later net sharing the same geometry keeps its *other* segments
    // — strict Q5: a Wire-classified net never loses all its wires. (The old
    // behavior dropped the entire conflicting net and fell back to labels.)
    let mut seen: HashSet<(i32, i32, i32, i32)> = HashSet::new();
    wires.retain(|w| seen.insert(normalize_wire_coords(w)));
}

/// Merge collinear wire segments that share an endpoint and lie on the same axis.
fn merge_collinear_wires(wires: &[Wire]) -> Vec<Wire> {
    if wires.is_empty() {
        return Vec::new();
    }

    // Group wires by net_idx. BTreeMap: deterministic output order.
    let mut by_net: std::collections::BTreeMap<NetId, Vec<Wire>> =
        std::collections::BTreeMap::new();
    for w in wires {
        by_net.entry(w.net_idx).or_default().push(*w);
    }

    let mut result = Vec::new();
    for (net_idx, mut net_wires) in by_net {
        let mut horiz: Vec<Wire> = Vec::new();
        let mut vert: Vec<Wire> = Vec::new();
        let mut other: Vec<Wire> = Vec::new();

        for w in net_wires.drain(..) {
            if w.y1 == w.y2 {
                horiz.push(w);
            } else if w.x1 == w.x2 {
                vert.push(w);
            } else {
                other.push(w);
            }
        }

        result.extend(merge_segments_1d(net_idx, &horiz, true));
        result.extend(merge_segments_1d(net_idx, &vert, false));
        result.extend(other);
    }

    // Sort for deterministic output.
    result.sort_by(|a, b| {
        a.net_idx
            .cmp(&b.net_idx)
            .then(a.x1.cmp(&b.x1))
            .then(a.y1.cmp(&b.y1))
            .then(a.x2.cmp(&b.x2))
            .then(a.y2.cmp(&b.y2))
    });

    result
}

/// Merge collinear segments along one axis.
///
/// `is_horizontal`: if true, segments share Y and merge along X; otherwise
/// they share X and merge along Y.
fn merge_segments_1d(net_idx: NetId, segments: &[Wire], is_horizontal: bool) -> Vec<Wire> {
    if segments.is_empty() {
        return Vec::new();
    }

    // Group by the shared coordinate.
    let mut groups: HashMap<i32, Vec<(i32, i32)>> = HashMap::new();
    for w in segments {
        let (shared, a, b) = if is_horizontal {
            let (a, b) = minmax(w.x1, w.x2);
            (w.y1, a, b)
        } else {
            let (a, b) = minmax(w.y1, w.y2);
            (w.x1, a, b)
        };
        groups.entry(shared).or_default().push((a, b));
    }

    let mut result = Vec::new();
    for (shared, mut intervals) in groups {
        intervals.sort();
        // Merge overlapping/adjacent intervals.
        let mut merged: Vec<(i32, i32)> = Vec::new();
        for (lo, hi) in intervals {
            if let Some(last) = merged.last_mut() {
                if lo <= last.1 {
                    last.1 = last.1.max(hi);
                    continue;
                }
            }
            merged.push((lo, hi));
        }

        for (lo, hi) in merged {
            if lo == hi {
                continue; // zero-length
            }
            result.push(if is_horizontal {
                Wire {
                    net_idx,
                    x1: lo,
                    y1: shared,
                    x2: hi,
                    y2: shared,
                }
            } else {
                Wire {
                    net_idx,
                    x1: shared,
                    y1: lo,
                    x2: shared,
                    y2: hi,
                }
            });
        }
    }

    result
}

// ---------------------------------------------------------------------------
// T-junction restoration
// ---------------------------------------------------------------------------

/// After merging collinear segments, interior crossing points between
/// same-net horizontal and vertical wires lose their T-junction endpoints.
/// Schematic formats only connect wires at shared endpoints, not at interior
/// crossings, so split wires at such crossings to restore T-junctions.
fn restore_t_junctions(wires: &[Wire]) -> Vec<Wire> {
    // Group wires by net. BTreeMap: deterministic output order.
    let mut by_net: std::collections::BTreeMap<NetId, Vec<Wire>> =
        std::collections::BTreeMap::new();
    for w in wires {
        by_net.entry(w.net_idx).or_default().push(*w);
    }

    let mut result = Vec::new();
    for (net_idx, net_wires) in &by_net {
        let mut horiz: Vec<Wire> = Vec::new();
        let mut vert: Vec<Wire> = Vec::new();

        for w in net_wires {
            if w.y1 == w.y2 && w.x1 != w.x2 {
                horiz.push(*w);
            } else if w.x1 == w.x2 && w.y1 != w.y2 {
                vert.push(*w);
            } else {
                result.push(*w);
            }
        }

        // Collect interior crossing split points for each wire.
        let mut h_splits: Vec<Vec<i32>> = vec![Vec::new(); horiz.len()];
        let mut v_splits: Vec<Vec<i32>> = vec![Vec::new(); vert.len()];

        for (hi, h) in horiz.iter().enumerate() {
            let hy = h.y1;
            let (hx_lo, hx_hi) = minmax(h.x1, h.x2);
            for (vi, v) in vert.iter().enumerate() {
                let vx = v.x1;
                let (vy_lo, vy_hi) = minmax(v.y1, v.y2);
                if vx > hx_lo && vx < hx_hi && hy > vy_lo && hy < vy_hi {
                    h_splits[hi].push(vx);
                    v_splits[vi].push(hy);
                }
            }
        }

        // Split a wire at the collected points along its axis.
        let mut split_at = |w: &Wire, splits: &[i32], horizontal: bool| {
            if splits.is_empty() {
                result.push(*w);
                return;
            }
            let mut pts = splits.to_vec();
            let (lo, hi) = if horizontal {
                minmax(w.x1, w.x2)
            } else {
                minmax(w.y1, w.y2)
            };
            pts.push(lo);
            pts.push(hi);
            pts.sort();
            pts.dedup();
            for pair in pts.windows(2) {
                if pair[0] != pair[1] {
                    result.push(if horizontal {
                        Wire {
                            net_idx: *net_idx,
                            x1: pair[0],
                            y1: w.y1,
                            x2: pair[1],
                            y2: w.y1,
                        }
                    } else {
                        Wire {
                            net_idx: *net_idx,
                            x1: w.x1,
                            y1: pair[0],
                            x2: w.x1,
                            y2: pair[1],
                        }
                    });
                }
            }
        };

        for (i, h) in horiz.iter().enumerate() {
            split_at(h, &h_splits[i], true);
        }
        for (i, v) in vert.iter().enumerate() {
            split_at(v, &v_splits[i], false);
        }
    }

    result
}

// ---------------------------------------------------------------------------
// Wire deduplication
// ---------------------------------------------------------------------------

/// Normalize wire coordinates so (x1,y1) <= (x2,y2) lexicographically.
fn normalize_wire_coords(w: &Wire) -> (i32, i32, i32, i32) {
    if (w.x1, w.y1) <= (w.x2, w.y2) {
        (w.x1, w.y1, w.x2, w.y2)
    } else {
        (w.x2, w.y2, w.x1, w.y1)
    }
}

// ---------------------------------------------------------------------------
// Utility functions
// ---------------------------------------------------------------------------

/// Manhattan distance between two points (schematic units or grid cells).
fn manhattan(a: (i32, i32), b: (i32, i32)) -> i32 {
    (a.0 - b.0).abs() + (a.1 - b.1).abs()
}

/// Total Manhattan span of a set of positions (max - min over x and y).
fn manhattan_span(positions: &[(i32, i32)]) -> i32 {
    if positions.is_empty() {
        return 0;
    }
    let min_x = positions.iter().map(|p| p.0).min().unwrap();
    let max_x = positions.iter().map(|p| p.0).max().unwrap();
    let min_y = positions.iter().map(|p| p.1).min().unwrap();
    let max_y = positions.iter().map(|p| p.1).max().unwrap();
    (max_x - min_x) + (max_y - min_y)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir::{InstId, Instance, Net, Pin, PinDir, PinRef, Primitive, Subcircuit};
    use std::collections::HashMap;

    /// Minimal pin-geometry stub: two-terminal devices with pins at
    /// (0, -30) and (0, 30) relative to the instance origin, no transforms.
    struct TestGeo;

    impl PinGeometry for TestGeo {
        fn pin_offsets(&self, _primitive: Primitive) -> &[(i32, i32)] {
            &[(0, -30), (0, 30), (20, 0), (-20, 0)]
        }

        fn transform_pin(&self, dx: i32, dy: i32, _rotation: u8, _flip: bool) -> (i32, i32) {
            (dx, dy)
        }
    }

    fn make_instance(name: &str, x: i32, y: i32) -> Instance {
        let pins: Vec<Pin> = (0..2)
            .map(|i| Pin {
                name: format!("p{i}"),
                dir: PinDir::Inout,
                net_idx: Some(NetId(0)),
            })
            .collect();
        Instance {
            name: name.to_string(),
            primitive: Primitive::Resistor,
            symbol: String::new(),
            pins,
            params: HashMap::new(),
            x,
            y,
            rotation: 0,
            flip: false,
        }
    }

    /// Subcircuit with `n` instances spaced `dx` apart and one net on pin 0 of each.
    fn fanout_subckt(net_name: &str, n: usize, dx: i32) -> Subcircuit {
        let mut subckt = Subcircuit::new("test");
        let mut net = Net::new(net_name);
        for i in 0..n {
            subckt
                .instances
                .push(make_instance(&format!("I{i}"), i as i32 * dx, 0));
            net.pins.push(PinRef {
                instance_idx: InstId(i as u32),
                pin_idx: PinIdx(0),
            });
        }
        subckt.nets.push(net);
        subckt
    }

    // --- Mandated tests ---

    #[test]
    fn astar_routes_around_obstacle_with_orthogonal_segments() {
        let mut obstacles = BitGrid::new(-100, -100, 100, 100);
        // Vertical wall at grid x=2, y=-2..=2 (schematic x=20, y=-20..=20).
        for y in -2..=2 {
            obstacles.set(2, y);
        }

        let mut ws = RouterWorkspace::new();
        let widx = WireIndex::default();
        let ctx = CrossingCtx {
            index: &widx,
            own: &[],
        };
        let no_pins: std::collections::HashSet<(i32, i32)> = Default::default();
        let path = astar_path(
            (0, 0),
            (40, 0),
            &obstacles,
            &no_pins,
            &ctx,
            1.0,
            1,
            false,
            false,
            &mut ws,
        )
        .expect("A* should find a path around the wall");

        assert_eq!(path.first(), Some(&(0, 0)));
        assert_eq!(path.last(), Some(&(40, 0)));

        // No interior point goes through the wall.
        for &(x, y) in &path {
            if (x, y) != (0, 0) && (x, y) != (40, 0) {
                assert!(
                    !obstacles.get(x / GRID_RES, y / GRID_RES),
                    "path passes through obstacle at ({x},{y})"
                );
            }
        }

        // Every step is a single orthogonal grid move.
        for w in path.windows(2) {
            let dx = (w[1].0 - w[0].0).abs();
            let dy = (w[1].1 - w[0].1).abs();
            assert!(
                (dx == GRID_RES && dy == 0) || (dx == 0 && dy == GRID_RES),
                "non-orthogonal step {:?} -> {:?}",
                w[0],
                w[1]
            );
        }
    }

    #[test]
    fn power_net_classified_label() {
        let by_name = fanout_subckt("VDD", 2, 100);
        let strategies = classify_nets(&by_name, &TestGeo, &[]);
        assert_eq!(strategies[0], NetStrategy::Label, "VDD by name -> Label");

        let mut by_class = fanout_subckt("rail", 2, 100);
        by_class.nets[0].classification = NetClass::Ground;
        let strategies = classify_nets(&by_class, &TestGeo, &[]);
        assert_eq!(
            strategies[0],
            NetStrategy::Label,
            "Ground classification -> Label"
        );

        // End-to-end: rail symbols at every pin, upright (rotation 0), no wires.
        let mut subckt = fanout_subckt("gnd", 3, 100);
        Router::new().route(&mut subckt, &TestGeo);
        assert!(subckt.wires.is_empty(), "power/gnd nets are not wired");
        assert_eq!(subckt.labels.len(), 3, "one rail symbol per pin");
        assert!(
            subckt.labels.iter().all(|l| l.rotation == 0),
            "rail symbols keep canonical upright orientation"
        );
    }

    #[test]
    fn mosfet_bulk_stub_merges_rail_symbols() {
        // NMOS with source (pin 2) and bulk (pin 3) both on gnd: one stub wire
        // source->bulk and a single rail symbol instead of two.
        let mut subckt = Subcircuit::new("test");
        let pins: Vec<Pin> = ["d", "g", "s", "b"]
            .iter()
            .map(|n| Pin {
                name: n.to_string(),
                dir: PinDir::Inout,
                net_idx: Some(NetId(0)),
            })
            .collect();
        subckt.instances.push(Instance {
            name: "M1".to_string(),
            primitive: Primitive::Nmos,
            symbol: String::new(),
            pins,
            params: HashMap::new(),
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        });
        let mut net = Net::new("gnd");
        net.pins.push(PinRef {
            instance_idx: InstId(0),
            pin_idx: PinIdx(2), // source at (20, 0)
        });
        net.pins.push(PinRef {
            instance_idx: InstId(0),
            pin_idx: PinIdx(3), // bulk at (-20, 0)
        });
        subckt.nets.push(net);

        Router::new().route(&mut subckt, &TestGeo);

        assert_eq!(subckt.wires.len(), 1, "one source->bulk stub wire");
        let w = &subckt.wires[0];
        let mut xs = [w.x1, w.x2];
        xs.sort();
        assert_eq!((xs[0], xs[1], w.y1, w.y2), (-20, 20, 0, 0));
        assert_eq!(subckt.labels.len(), 1, "bulk rail symbol skipped");
        assert_eq!(subckt.labels[0].rotation, 0);
        assert_eq!((subckt.labels[0].x, subckt.labels[0].y), (20, 0));
    }

    #[test]
    fn eight_pin_fanout_classified_label() {
        let subckt = fanout_subckt("load", 8, 50);
        let strategies = classify_nets(&subckt, &TestGeo, &[]);
        assert_eq!(
            strategies[0],
            NetStrategy::Label,
            "fanout 8 > {FANOUT_THRESHOLD} -> Label"
        );
        // End-to-end: label nets produce labels at every pin, no wires.
        let mut subckt = subckt;
        Router::new().route(&mut subckt, &TestGeo);
        assert!(subckt.wires.is_empty());
        assert_eq!(subckt.labels.len(), 8);
    }

    // --- Kernel / post-processing coverage ---

    #[test]
    fn route_short_net_produces_orthogonal_grid_wires_and_naming_label() {
        let mut subckt = fanout_subckt("n1", 2, 100);
        Router::new().route(&mut subckt, &TestGeo);

        assert!(!subckt.wires.is_empty(), "short net should be wired");
        assert_eq!(subckt.labels.len(), 1, "single naming label");
        for w in &subckt.wires {
            assert!(w.x1 == w.x2 || w.y1 == w.y2, "wire must be orthogonal");
            for v in [w.x1, w.y1, w.x2, w.y2] {
                assert_eq!(v % 10, 0, "endpoint {v} not grid-snapped");
            }
        }
    }

    #[test]
    fn snap_rounds_to_nearest_grid() {
        assert_eq!(snap(0, 10), 0);
        assert_eq!(snap(4, 10), 0);
        assert_eq!(snap(5, 10), 10); // round half up
        assert_eq!(snap(14, 10), 10);
        assert_eq!(snap(-4, 10), 0);
        assert_eq!(snap(-6, 10), -10);
        assert_eq!(snap(-20, 10), -20);
        assert_eq!(snap(7, 0), 7); // zero quantum = no snapping
    }

    #[test]
    fn l_shape_variants_match_old_outputs() {
        let from = (0, 0);
        let to = (50, 30);

        // Horizontal-first (old l_shape_wires): corner at (to.x, from.y).
        let h = l_shape(NetId(0), from, to, false, None);
        assert_eq!(h.len(), 2);
        assert_eq!((h[0].x1, h[0].y1, h[0].x2, h[0].y2), (0, 0, 50, 0));
        assert_eq!((h[1].x1, h[1].y1, h[1].x2, h[1].y2), (50, 0, 50, 30));

        // Vertical-first (old l_shape_wires_vfirst): corner at (from.x, to.y).
        let v = l_shape(NetId(0), from, to, true, None);
        assert_eq!(v.len(), 2);
        assert_eq!((v[0].x1, v[0].y1, v[0].x2, v[0].y2), (0, 0, 0, 30));
        assert_eq!((v[1].x1, v[1].y1, v[1].x2, v[1].y2), (0, 30, 50, 30));

        // Straight line: single segment, no zero-length corner stub.
        let straight = l_shape(NetId(0), (0, 0), (100, 0), false, None);
        assert_eq!(straight.len(), 1);
    }

    #[test]
    fn l_shape_safety_avoids_foreign_pin_and_falls_back() {
        let mut pin_map: HashMap<(i32, i32), Vec<usize>> = HashMap::new();
        // Foreign pin (net 1) at the horizontal-first corner (50, 0).
        pin_map.insert((50, 0), vec![1]);
        let obstacles = BitGrid::new(-100, -100, 100, 100);
        let no_wires = WireIndex::default();
        let safety = LShapeSafety {
            pin_pos_to_nets: &pin_map,
            current_net: 0,
            obstacles: &obstacles,
            foreign_wires: &no_wires,
        };

        // H-first corner is foreign -> falls back to vertical-first.
        let wires = l_shape(NetId(0), (0, 0), (50, 30), false, Some(&safety));
        assert_eq!(wires.len(), 2);
        assert_eq!((wires[0].x1, wires[0].y1), (0, 0));
        assert_eq!((wires[0].x2, wires[0].y2), (0, 30), "should be vertical-first");

        // Both corners foreign -> empty (label fallback).
        let mut pin_map2 = pin_map.clone();
        pin_map2.insert((0, 30), vec![1]);
        let safety2 = LShapeSafety {
            pin_pos_to_nets: &pin_map2,
            current_net: 0,
            obstacles: &obstacles,
            foreign_wires: &no_wires,
        };
        let wires = l_shape(NetId(0), (0, 0), (50, 30), false, Some(&safety2));
        assert!(wires.is_empty());
    }

    #[test]
    fn collinear_segments_merged() {
        let wires = vec![
            Wire {
                net_idx: NetId(0),
                x1: 0,
                y1: 0,
                x2: 20,
                y2: 0,
            },
            Wire {
                net_idx: NetId(0),
                x1: 20,
                y1: 0,
                x2: 50,
                y2: 0,
            },
        ];
        let merged = merge_collinear_wires(&wires);
        assert_eq!(merged.len(), 1);
        assert_eq!((merged[0].x1, merged[0].x2), (0, 50));
    }

    #[test]
    fn t_junction_interior_crossing_split() {
        let wires = vec![
            Wire {
                net_idx: NetId(0),
                x1: 0,
                y1: 0,
                x2: 100,
                y2: 0,
            },
            Wire {
                net_idx: NetId(0),
                x1: 50,
                y1: -50,
                x2: 50,
                y2: 50,
            },
        ];
        let result = restore_t_junctions(&wires);
        assert_eq!(result.len(), 4, "crossing splits both wires");
        assert!(result
            .iter()
            .any(|w| (w.x1 == 50 && w.y1 == 0) || (w.x2 == 50 && w.y2 == 0)));
    }

    #[test]
    fn adaptive_threshold_and_multiplier_scale_with_spread() {
        let small = fanout_subckt("n", 2, 100);
        assert_eq!(adaptive_threshold(&small), BASE_WIRE_DISTANCE_THRESHOLD);
        assert_eq!(adaptive_multiplier(&small), 1.0);

        let mut large = Subcircuit::new("large");
        for i in 0..20 {
            large
                .instances
                .push(make_instance(&format!("I{i}"), i * 200, i * 100));
        }
        for i in 0..20 {
            large.nets.push(Net::new(&format!("n{i}")));
        }
        // half-perimeter = 3800 + 1900 = 5700; threshold = a quarter of it.
        assert_eq!(adaptive_threshold(&large), 1425);
        assert!(adaptive_multiplier(&large) > adaptive_multiplier(&small));
        // Uncapped this would be 2.0 * 28.5 = 57; the cap clamps it.
        assert_eq!(adaptive_multiplier(&large), ADAPTIVE_MULTIPLIER_CAP);
    }

    #[test]
    fn wire_index_bucketed_crossing_lookup() {
        let mut idx = WireIndex::default();
        // Horizontal wire spanning several buckets.
        idx.add((10, 0, 400, 0));

        // Vertical step crossing it.
        assert!(idx.crosses((30, -10), (30, 10)));
        assert!(idx.crosses((390, -10), (390, 10)));
        // Endpoint touching is not a proper crossing.
        assert!(!idx.crosses((30, 0), (30, 10)));
        // Parallel segment does not cross.
        assert!(!idx.crosses((30, 10), (40, 10)));
        // Far-away segment in an untouched bucket.
        assert!(!idx.crosses((5000, -10), (5000, 10)));

        // Own-net segments are also seen by the context.
        let own = [(10, 100, 400, 100)];
        let ctx = CrossingCtx {
            index: &idx,
            own: &own,
        };
        assert!(ctx.crosses((30, 90), (30, 110)));
        assert!(!ctx.crosses((30, 190), (30, 210)));
    }

    #[test]
    fn cross_net_touch_legality() {
        let f = (180, 320, 260, 320); // foreign horizontal wire

        // (a) T-touch: candidate endpoint ON the foreign wire's interior.
        assert!(conductive_touch((220, 290, 220, 320), f));
        // (b) Coincident endpoints across nets.
        assert!(conductive_touch((180, 320, 180, 250), f));
        // Reverse T: foreign endpoint strictly inside the candidate interior.
        assert!(conductive_touch((170, 320, 200, 320), f));
        // (c) Collinear overlap.
        assert!(conductive_touch((200, 320, 240, 320), f));
        assert!(conductive_touch((100, 320, 300, 320), f));
        // Pure X-crossing is legal (does not connect in core).
        assert!(!conductive_touch((220, 290, 220, 350), f));
        // Disjoint / parallel-offset segments don't touch.
        assert!(!conductive_touch((180, 330, 260, 330), f));
    }

    #[test]
    fn count_touches_exempts_pre_merged_components() {
        let mut idx = WireIndex::default();
        // Foreign "bitline" column...
        idx.add((190, 30, 190, 310));
        // ...with a jog T-joined onto it (same connected component)...
        idx.add((100, 150, 190, 150));
        // ...and an unrelated foreign wire elsewhere.
        idx.add((400, 100, 500, 100));

        // The net's own pin (190, 290) sits ON the bitline: the bitline AND
        // (transitively) its jog are already merged with this net — running
        // a leg along the column over both is no NEW short.
        let pin = (190, 290);
        assert_eq!(idx.count_touches((190, -30, 190, 290), &[pin]), 0);
        // Without the pin exemption the same leg counts the (single)
        // pre-joined component once.
        assert_eq!(idx.count_touches((190, -30, 190, 290), &[]), 1);
        // Touching the unrelated wire still counts.
        assert_eq!(idx.count_touches((450, 100, 450, 200), &[pin]), 1);
        // X-crossing the unrelated wire does not.
        assert_eq!(idx.count_touches((450, 50, 450, 200), &[pin]), 0);
    }

    #[test]
    fn wire_index_counts_conductive_touches() {
        let mut idx = WireIndex::default();
        // Long wire spanning multiple CROSSING_BUCKET cells: bucket overlap
        // must not double-count.
        idx.add((0, 0, 400, 0));
        idx.add((100, -50, 100, 50)); // crosses the first at (100, 0)

        // Candidate endpoint lands on the horizontal wire's interior: 1 touch.
        assert_eq!(idx.count_touches((50, 0, 50, -80), &[]), 1);
        // Fully clear of both wires: 0 touches.
        assert_eq!(idx.count_touches((50, -80, 50, -20), &[]), 0);
        // Collinear overlap with the long wire: counted once despite the
        // segment being indexed in several buckets.
        assert_eq!(idx.count_touches((150, 0, 350, 0), &[]), 1);
        // X-crossing only: legal.
        assert_eq!(idx.count_touches((200, -10, 200, 10), &[]), 0);
    }

    #[test]
    fn detour_avoids_foreign_wire_touch() {
        // Foreign wire occupies the straight corridor between the pins; the
        // detour sweep must pick a candidate that does not conductively
        // touch it (an offset trunk), never the collinear overlap.
        let pin_map: HashMap<(i32, i32), Vec<usize>> = HashMap::new();
        let obstacles = BitGrid::new(-100, -100, 100, 100);
        let mut foreign = WireIndex::default();
        foreign.add((40, 0, 160, 0)); // foreign wire on the from-to line
        let safety = LShapeSafety {
            pin_pos_to_nets: &pin_map,
            current_net: 0,
            obstacles: &obstacles,
            foreign_wires: &foreign,
        };

        let from = (0, 0);
        let to = (200, 0);
        let wires = best_detour(NetId(0), from, to, &safety);
        assert!(!wires.is_empty(), "detour always produces wires (Q5)");
        for w in &wires {
            assert_eq!(
                foreign.count_touches((w.x1, w.y1, w.x2, w.y2), &[from, to]),
                0,
                "detour wire ({},{})-({},{}) conductively touches the foreign wire",
                w.x1,
                w.y1,
                w.x2,
                w.y2
            );
        }
    }

    #[test]
    fn wire_net_always_ends_wired() {
        // Surround the target pin column with foreign pins so both safe
        // L-shape corners hit foreign pins; A* is windowed away by a solid
        // obstacle wall -> ladder must bottom out at the unsafe L-shape.
        let mut subckt = fanout_subckt("n1", 2, 100);
        // A third net's pins at both prospective L-corners.
        subckt.instances.push(make_instance("I2", 100, -30)); // pin0 at (100,-60)
        let mut blocker = Net::new("blk");
        blocker.pins.push(PinRef {
            instance_idx: InstId(2),
            pin_idx: PinIdx(0),
        });
        subckt.nets.push(blocker);

        Router::new().route(&mut subckt, &TestGeo);

        // The 2-pin wire net must have wire segments no matter what.
        assert!(
            subckt.wires.iter().any(|w| w.net_idx == NetId(0)),
            "Wire-classified net must end with wires (strict Q5)"
        );
    }
}
