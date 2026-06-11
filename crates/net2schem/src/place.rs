//! Placement: power/signal DAGs → Sugiyama layering → block templates.
//!
//! Merged port of the old `placement/{mod,dag,sugiyama,templates}.rs`:
//! - Power-flow DAG assigns y-layers (VDD top → GND bottom).
//! - Signal-flow DAG assigns x-layers (inputs left → outputs right).
//! - Sugiyama: cycle removal, longest-path layering, barycenter crossing
//!   minimization. Recognized blocks collapse into super-nodes.
//! - Capacitors float: skipped during layering, placed by neighbor averaging.
//! - Block-internal placement is a data-driven template table (one config row
//!   per `BlockType` instead of eleven near-identical functions).

use std::collections::{HashMap, HashSet, VecDeque};

use crate::emit::{pin_position, PinGeometry};
use crate::ir::{Net, NetClass, NetId, PinDir, Primitive, Subcircuit};
use crate::recognition::{Block, BlockType};

const LAYER_SPACING: i32 = 160;
const DEFAULT_SIZE: i32 = 200;

// ---------------------------------------------------------------------------
// Net rail classification (pure — extracted from DAG building for testability)
// ---------------------------------------------------------------------------

/// Which rail (if any) a net belongs to for placement purposes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RailKind {
    Power,
    Ground,
    Signal,
}

/// Classify a net as power / ground / signal from its annotation class and
/// well-known rail names. Pure function of the net.
pub fn classify_rail(net: &Net) -> RailKind {
    const POWER_NAMES: &[&str] = &["vdd", "vcc", "avdd", "dvdd"];
    const GROUND_NAMES: &[&str] = &["vss", "gnd", "0", "avss", "dvss"];
    if matches!(net.classification, NetClass::Power)
        || POWER_NAMES.iter().any(|&p| net.name.eq_ignore_ascii_case(p))
    {
        RailKind::Power
    } else if matches!(net.classification, NetClass::Ground)
        || GROUND_NAMES.iter().any(|&g| net.name.eq_ignore_ascii_case(g))
    {
        RailKind::Ground
    } else {
        RailKind::Signal
    }
}

fn is_power_net(net: &Net) -> bool {
    classify_rail(net) == RailKind::Power
}

fn is_ground_net(net: &Net) -> bool {
    classify_rail(net) == RailKind::Ground
}

// ---------------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------------

pub fn place(subckt: &mut Subcircuit, blocks: &[Block], backend: &dyn PinGeometry) {
    place_with_children(subckt, blocks, backend, &HashMap::new());
}

pub fn place_with_children(
    subckt: &mut Subcircuit,
    blocks: &[Block],
    backend: &dyn PinGeometry,
    children: &HashMap<String, Subcircuit>,
) {
    let mut placed: HashSet<u32> = HashSet::new();

    // Phase 1: Power flow DAG → y-layers
    let power_dag = build_power_dag_with_children(subckt, blocks, children);
    let y_result = sugiyama_layers(
        &power_dag.nodes,
        &power_dag.edges,
        &power_dag.start_anchors,
        &power_dag.end_anchors,
    );

    // Phase 2: Signal flow DAG → x-layers
    let signal_dag = build_signal_dag_with_children(subckt, blocks, children);
    let x_result = sugiyama_layers(
        &signal_dag.nodes,
        &signal_dag.edges,
        &signal_dag.start_anchors,
        &signal_dag.end_anchors,
    );

    // Build super-node → block map (super-node id = first instance of block)
    let mut super_to_block: HashMap<u32, usize> = HashMap::new();
    for (bi, block) in blocks.iter().enumerate() {
        if !block.instance_indices.is_empty() {
            super_to_block.insert(block.instance_indices[0], bi);
        }
    }

    // Phase 3: Assign coordinates from layers, spreading within each cell.
    // Iterate the ordered layers (barycenter order from crossing minimization)
    // rather than the node→layer map — HashMap order is nondeterministic and
    // would scramble columns from run to run.
    // Track how many items have been placed at each (x_layer, y_layer) to offset them
    let mut cell_count: HashMap<(usize, usize), i32> = HashMap::new();

    for (y_layer, layer_nodes) in y_result.layers.iter().enumerate() {
        for &node in layer_nodes {
            let x_layer = x_result.node_layer.get(&node).copied().unwrap_or(0);
            let offset = cell_count.entry((x_layer, y_layer)).or_insert(0);
            let x = x_layer as i32 * LAYER_SPACING + *offset * LAYER_SPACING;
            let y = y_layer as i32 * LAYER_SPACING;
            *offset += 1;

            if let Some(&bi) = super_to_block.get(&node) {
                apply_template(subckt, &blocks[bi], x, y);
                for &idx in &blocks[bi].instance_indices {
                    placed.insert(idx);
                }
            } else {
                let idx = node as usize;
                if idx < subckt.instances.len() {
                    subckt.instances[idx].x = x;
                    subckt.instances[idx].y = y;
                    placed.insert(node);
                }
            }
        }
    }

    // Assign skipped nodes (capacitors) using average of neighbor layers
    for &sn in &power_dag.skipped_nodes {
        let idx = sn as usize;
        if idx >= subckt.instances.len() || placed.contains(&sn) {
            continue;
        }
        let y_layer = estimate_layer_from_neighbors(sn, subckt, &y_result.node_layer);
        let x_layer = estimate_layer_from_neighbors(sn, subckt, &x_result.node_layer);
        let offset = cell_count.entry((x_layer, y_layer)).or_insert(0);
        let x = x_layer as i32 * LAYER_SPACING + *offset * LAYER_SPACING;
        let y = y_layer as i32 * LAYER_SPACING;
        *offset += 1;
        subckt.instances[idx].x = x;
        subckt.instances[idx].y = y;
        placed.insert(sn);
    }

    // Fallback: any unplaced instance gets placed in a grid below
    let max_y = y_result.layers.len() as i32 * LAYER_SPACING + LAYER_SPACING;
    let mut fallback_col = 0;
    let mut fallback_row = 0;
    for i in 0..subckt.instances.len() {
        if placed.contains(&(i as u32)) {
            continue;
        }
        subckt.instances[i].x = fallback_col * LAYER_SPACING;
        subckt.instances[i].y = max_y + fallback_row * LAYER_SPACING;
        fallback_col += 1;
        if fallback_col >= 4 {
            fallback_col = 0;
            fallback_row += 1;
        }
    }

    align_loose_to_neighbors(subckt, blocks);

    orient_rail_tied_mosfets(subckt, blocks);

    fix_pin_overlaps(subckt, backend);

    // Body-overlap resolution: fix_pin_overlaps only separates coincident
    // pins (+10 nudges), which can leave instance BODIES overlapping — pins
    // end up strictly inside foreign bodies and no legal wire can reach them
    // (unfixable R6 for the router). Separate bodies, then re-run the pin
    // pass in case a shift re-aligned pins of vertically adjacent groups.
    for _ in 0..3 {
        if !separate_overlapping_bodies(subckt, blocks, backend) {
            break;
        }
        fix_pin_overlaps(subckt, backend);
    }
}

/// Minimum horizontal gap kept between instance bodies after separation.
/// Two body half-widths (40) leave a 4-grid routing channel between devices
/// — enough for a couple of vertical legs to pass without plowing bodies
/// (R6) or piling onto one shared track (conductive touches).
const BODY_GAP: i32 = 40;

/// Body bbox of one instance: bounding box of its transformed pin positions
/// plus the origin (same convention the schematic rules use). Zero-extent
/// dimensions are widened by one grid (±10) so two-terminal devices, whose
/// pins are collinear, still have an interior.
fn instance_body_bbox(
    inst: &crate::ir::Instance,
    backend: &dyn PinGeometry,
) -> (i32, i32, i32, i32) {
    let (mut x_min, mut x_max, mut y_min, mut y_max) = (inst.x, inst.x, inst.y, inst.y);
    for p in 0..inst.pins.len() {
        let (px, py) = pin_position(backend, inst, p);
        x_min = x_min.min(px);
        x_max = x_max.max(px);
        y_min = y_min.min(py);
        y_max = y_max.max(py);
    }
    if x_min == x_max {
        x_min -= 10;
        x_max += 10;
    }
    if y_min == y_max {
        y_min -= 10;
        y_max += 10;
    }
    (x_min, x_max, y_min, y_max)
}

/// Post-placement pass: push apart instances whose bodies overlap within a
/// row. Recognized blocks move as rigid units (template geometry preserved).
/// Deterministic: groups are sorted by (x, y, name) and only ever shifted
/// right by grid multiples, so relative left-to-right order is preserved.
/// Returns true if anything moved.
fn separate_overlapping_bodies(
    subckt: &mut Subcircuit,
    blocks: &[Block],
    backend: &dyn PinGeometry,
) -> bool {
    struct Group {
        members: Vec<usize>,
        x_min: i32,
        x_max: i32,
        y_min: i32,
        y_max: i32,
        name: String,
    }

    let n = subckt.instances.len();
    let mut in_block = vec![false; n];
    let mut groups: Vec<Group> = Vec::new();

    let push_group = |members: Vec<usize>, subckt: &Subcircuit, groups: &mut Vec<Group>| {
        let (mut x_min, mut x_max) = (i32::MAX, i32::MIN);
        let (mut y_min, mut y_max) = (i32::MAX, i32::MIN);
        let mut name: Option<&str> = None;
        for &i in &members {
            let inst = &subckt.instances[i];
            let (bx0, bx1, by0, by1) = instance_body_bbox(inst, backend);
            x_min = x_min.min(bx0);
            x_max = x_max.max(bx1);
            y_min = y_min.min(by0);
            y_max = y_max.max(by1);
            if name.is_none_or(|n| inst.name.as_str() < n) {
                name = Some(&inst.name);
            }
        }
        groups.push(Group {
            members,
            x_min,
            x_max,
            y_min,
            y_max,
            name: name.unwrap_or_default().to_string(),
        });
    };

    for block in blocks {
        let members: Vec<usize> = block
            .instance_indices
            .iter()
            .map(|&i| i as usize)
            .filter(|&i| i < n)
            .collect();
        if members.is_empty() || members.iter().any(|&i| in_block[i]) {
            continue;
        }
        for &i in &members {
            in_block[i] = true;
        }
        push_group(members, subckt, &mut groups);
    }
    for i in 0..n {
        if !in_block[i] {
            push_group(vec![i], subckt, &mut groups);
        }
    }

    // Left-to-right sweep: each group must clear every earlier group it
    // overlaps vertically. Sort key includes name so equal positions break
    // ties deterministically.
    groups.sort_by(|a, b| {
        (a.x_min, a.y_min, a.x_max, a.y_max)
            .cmp(&(b.x_min, b.y_min, b.x_max, b.y_max))
            .then_with(|| a.name.cmp(&b.name))
    });

    let mut moved = false;
    for g in 1..groups.len() {
        let mut required = i32::MIN;
        for e in 0..g {
            let y_overlap =
                groups[e].y_min < groups[g].y_max && groups[g].y_min < groups[e].y_max;
            if y_overlap {
                required = required.max(groups[e].x_max + BODY_GAP);
            }
        }
        if required > groups[g].x_min {
            // Bboxes are grid-aligned, but round up defensively.
            let dx = (required - groups[g].x_min + 9) / 10 * 10;
            for &i in &groups[g].members {
                subckt.instances[i].x += dx;
            }
            groups[g].x_min += dx;
            groups[g].x_max += dx;
            moved = true;
        }
    }
    moved
}

/// Pull loose two-terminal instances (R/L/C/V/I) into the column of the
/// devices they actually connect to.
///
/// Layering collapses recognized blocks into super-nodes, so the barycenter
/// pass cannot tell which column a resistor belongs over — e.g. both drain
/// resistors of a diff pair connect to the same super-node and end up in
/// arbitrary columns, crossing wires. Pin-level net connectivity resolves
/// this: each loose instance moves to the average x of its signal-net
/// neighbors (a load resistor lands over its drain, a tail source centers
/// under the pair).
fn align_loose_to_neighbors(subckt: &mut Subcircuit, blocks: &[Block]) {
    let in_block: HashSet<u32> = blocks
        .iter()
        .flat_map(|b| b.instance_indices.iter().copied())
        .collect();

    let loose_two_term: Vec<bool> = subckt
        .instances
        .iter()
        .enumerate()
        .map(|(i, inst)| {
            !in_block.contains(&(i as u32))
                && matches!(
                    inst.primitive,
                    Primitive::Resistor
                        | Primitive::Inductor
                        | Primitive::Capacitor
                        | Primitive::Vsource
                        | Primitive::Isource
                )
        })
        .collect();

    // Conflict = closer than one layer cell to another instance.
    const CLEARANCE: i32 = 120;
    let conflicts = |x: i32, y: i32, positions: &[(i32, i32)], skip: usize| {
        positions
            .iter()
            .enumerate()
            .any(|(j, &(px, py))| j != skip && (px - x).abs() < CLEARANCE && (py - y).abs() < CLEARANCE)
    };

    for _ in 0..2 {
        // Desired x per loose instance: average of signal-net neighbor columns.
        let mut desired: Vec<Option<(usize, i32)>> = Vec::new();
        for i in 0..subckt.instances.len() {
            if !loose_two_term[i] {
                desired.push(None);
                continue;
            }
            let mut sum = 0i64;
            let mut count = 0i64;
            for net in &subckt.nets {
                let on_net = net.pins.iter().any(|p| p.instance_idx.index() == i);
                if !on_net || classify_rail(net) != RailKind::Signal {
                    continue;
                }
                for pin_ref in &net.pins {
                    if pin_ref.instance_idx.index() != i {
                        sum += subckt[pin_ref.instance_idx].x as i64;
                        count += 1;
                    }
                }
            }
            if count == 0 {
                desired.push(None);
                continue;
            }
            // Snap to the routing grid so pins stay on-grid.
            let avg = ((sum / count) as i32 / 10) * 10;
            desired.push(Some((i, avg)));
        }

        // Apply moves: a mover may take a spot another mover is vacating
        // (column swap), so check against desired positions of movers and
        // current positions of everything else.
        let target_positions: Vec<(i32, i32)> = (0..subckt.instances.len())
            .map(|i| match desired[i] {
                Some((_, dx)) => (dx, subckt.instances[i].y),
                None => (subckt.instances[i].x, subckt.instances[i].y),
            })
            .collect();

        for i in 0..subckt.instances.len() {
            let Some((_, dx)) = desired[i] else { continue };
            if dx == subckt.instances[i].x {
                continue;
            }
            let y = subckt.instances[i].y;
            if !conflicts(dx, y, &target_positions, i) {
                subckt.instances[i].x = dx;
            }
        }
    }
}

/// Vertically mirror standalone MOSFETs whose source faces away from its
/// rail: an NMOS with source on a POWER net (charge-pump diode chain) or a
/// PMOS with source on a GROUND net is drawn source-toward-rail, matching
/// the upright rail-symbol idiom and keeping power pins above ground pins
/// (Q2). Block members keep their template orientation.
fn orient_rail_tied_mosfets(subckt: &mut Subcircuit, blocks: &[Block]) {
    let mut in_block: HashSet<u32> = HashSet::new();
    for block in blocks {
        in_block.extend(block.instance_indices.iter().copied());
    }

    for (i, inst) in subckt.instances.iter_mut().enumerate() {
        if in_block.contains(&(i as u32)) || inst.rotation != 0 || inst.flip {
            continue;
        }
        let source_rail = inst
            .pin_net(2)
            .and_then(|ni| subckt.nets.get(ni.index()))
            .map(classify_rail);
        let mirror = match inst.primitive {
            Primitive::Nmos => source_rail == Some(RailKind::Power),
            Primitive::Pmos => source_rail == Some(RailKind::Ground),
            _ => false,
        };
        if mirror {
            // flip (negate x) + rotate 180 = pure vertical mirror.
            inst.rotation = 2;
            inst.flip = true;
        }
    }
}

fn estimate_layer_from_neighbors(
    inst_idx: u32,
    subckt: &Subcircuit,
    node_layer: &HashMap<u32, usize>,
) -> usize {
    let mut sum = 0usize;
    let mut count = 0usize;

    for net in &subckt.nets {
        // Power/ground nets are label-routed and touch half the circuit —
        // they carry no positional information. Estimate from signal
        // neighbors only (a load cap belongs beside its driver, not pulled
        // toward the rail source).
        if classify_rail(net) != RailKind::Signal {
            continue;
        }
        let touches_inst = net.pins.iter().any(|p| p.instance_idx.0 == inst_idx);
        if !touches_inst {
            continue;
        }
        for pin_ref in &net.pins {
            if pin_ref.instance_idx.0 == inst_idx {
                continue;
            }
            if let Some(&layer) = node_layer.get(&pin_ref.instance_idx.0) {
                sum += layer;
                count += 1;
            }
        }
    }

    if count > 0 {
        sum / count
    } else {
        node_layer.values().copied().max().unwrap_or(0) / 2
    }
}

// ---------------------------------------------------------------------------
// DAG construction (power flow → y, signal flow → x)
// ---------------------------------------------------------------------------

pub struct DagGraph {
    pub nodes: Vec<u32>,
    pub edges: Vec<(u32, u32)>,
    pub start_anchors: Vec<u32>,
    pub end_anchors: Vec<u32>,
    pub skipped_nodes: Vec<u32>,
}

pub fn build_power_dag(subckt: &Subcircuit, blocks: &[Block]) -> DagGraph {
    build_power_dag_with_children(subckt, blocks, &HashMap::new())
}

pub fn build_power_dag_with_children(
    subckt: &Subcircuit,
    blocks: &[Block],
    children: &HashMap<String, Subcircuit>,
) -> DagGraph {
    let (inst_to_super, super_nodes) = build_super_node_map(subckt, blocks);
    let mut start_anchors = Vec::new();
    let mut end_anchors = Vec::new();
    let mut skipped_nodes = Vec::new();
    let mut edges: Vec<(u32, u32)> = Vec::new();
    let mut seen_edges: HashSet<(u32, u32)> = HashSet::new();

    // Classify anchors: Vsource with positive pin (pin 0) on a VDD net AND
    // negative pin (pin 1) on ground = rail anchor. A series ammeter
    // (0V Vsource between VDD and a signal net) is NOT a rail — anchoring it
    // would pull its branch to the top layer and misalign it.
    // No explicit GND anchors — the bottom layer emerges from topology.
    // This prevents Vsource from being both start AND end (which collapses layering).
    for (i, inst) in subckt.instances.iter().enumerate() {
        if inst.primitive != Primitive::Vsource {
            continue;
        }
        let sn = inst_to_super[&(i as u32)];
        let pin0_power = inst
            .pin_net(0)
            .and_then(|ni| subckt.nets.get(ni.index()))
            .is_some_and(is_power_net);
        let pin1_ground = inst
            .pin_net(1)
            .and_then(|ni| subckt.nets.get(ni.index()))
            .is_some_and(is_ground_net);
        if pin0_power && pin1_ground && !start_anchors.contains(&sn) {
            start_anchors.push(sn);
        }
    }

    // Identify capacitors to skip
    for (i, inst) in subckt.instances.iter().enumerate() {
        if inst.primitive == Primitive::Capacitor {
            let sn = inst_to_super[&(i as u32)];
            if !skipped_nodes.contains(&sn) {
                skipped_nodes.push(sn);
            }
        }
    }

    // Create edges from VDD anchors to devices on VDD nets via power-carrying pins.
    // Skip MOSFET bulk (pin 3) and gate (pin 1) — those are bias, not current path.
    for net in &subckt.nets {
        if is_power_net(net) {
            for pin_ref in &net.pins {
                let inst = &subckt[pin_ref.instance_idx];
                if inst.primitive.is_mosfet() && (pin_ref.pin_idx.0 == 3 || pin_ref.pin_idx.0 == 1) {
                    continue;
                }
                let sn = inst_to_super[&pin_ref.instance_idx.0];
                if !start_anchors.contains(&sn) && !skipped_nodes.contains(&sn) {
                    for &anchor in &start_anchors {
                        if anchor != sn && !seen_edges.contains(&(anchor, sn)) {
                            edges.push((anchor, sn));
                            seen_edges.insert((anchor, sn));
                        }
                    }
                }
            }
        }
    }

    // Build directed edges from internal net connectivity
    for net in &subckt.nets {
        if classify_rail(net) != RailKind::Signal {
            continue;
        }

        let mut producers: Vec<u32> = Vec::new(); // upstream (closer to VDD)
        let mut consumers: Vec<u32> = Vec::new(); // downstream (closer to GND)
        let mut nmos_source_nodes: HashSet<u32> = HashSet::new();
        let mut pmos_source_nodes: HashSet<u32> = HashSet::new();

        for pin_ref in &net.pins {
            let inst = &subckt[pin_ref.instance_idx];
            let sn = inst_to_super[&pin_ref.instance_idx.0];

            if skipped_nodes.contains(&sn) {
                continue;
            }

            match inst.primitive {
                Primitive::Nmos => {
                    if pin_ref.pin_idx.0 == 0 {
                        consumers.push(sn);
                    } else if pin_ref.pin_idx.0 == 2 {
                        producers.push(sn);
                        nmos_source_nodes.insert(sn);
                    }
                }
                Primitive::Pmos => {
                    if pin_ref.pin_idx.0 == 2 {
                        consumers.push(sn);
                        pmos_source_nodes.insert(sn);
                    } else if pin_ref.pin_idx.0 == 0 {
                        producers.push(sn);
                    }
                }
                Primitive::Vsource | Primitive::Isource => {
                    // Two-terminal source on a signal net: role follows the
                    // OTHER terminal, not pin polarity. Netlists write both
                    // `Itail tail 0` and `Itail 0 tail` for the same tail
                    // sink, so polarity alone is unreliable.
                    //   other pin on power  → fed from the rail → producer (above)
                    //   other pin on ground → sinks to ground   → consumer (below)
                    let other_net = inst
                        .pin_net((1 - pin_ref.pin_idx.0) as usize)
                        .and_then(|ni| subckt.nets.get(ni.index()));
                    match other_net.map(classify_rail) {
                        Some(RailKind::Power) => producers.push(sn),
                        Some(RailKind::Ground) => consumers.push(sn),
                        _ => {
                            // Floating between two signal nets (e.g. series
                            // ammeter mid-path): fall back to polarity.
                            // Vsource: pin 0 (+) upstream. Isource: current
                            // exits pin 1 (-) → pin 1 upstream.
                            let upstream = if inst.primitive == Primitive::Vsource {
                                pin_ref.pin_idx.0 == 0
                            } else {
                                pin_ref.pin_idx.0 == 1
                            };
                            if upstream {
                                producers.push(sn);
                            } else {
                                consumers.push(sn);
                            }
                        }
                    }
                }
                Primitive::Subcircuit => {
                    // Use child subcircuit's port directions to determine role
                    if let Some(child) = children.get(&inst.symbol) {
                        let pin_idx = pin_ref.pin_idx.index();
                        if pin_idx < child.port_directions.len() {
                            match child.port_directions[pin_idx] {
                                PinDir::Power => producers.push(sn),
                                PinDir::Ground => consumers.push(sn),
                                _ => {}
                            }
                        }
                    }
                }
                _ => {
                    // Passives: direction resolved by orient_passives_by_bfs
                }
            }
        }

        // Create edges: producer → consumer for each pair.
        // Skip transmission gate pairs (NMOS source + PMOS source on same net = parallel).
        let is_tgate_net = !nmos_source_nodes.is_empty() && !pmos_source_nodes.is_empty();
        for &p in &producers {
            for &c in &consumers {
                if p == c {
                    continue;
                }
                if is_tgate_net && nmos_source_nodes.contains(&p) && pmos_source_nodes.contains(&c) {
                    continue;
                }
                if !seen_edges.contains(&(p, c)) {
                    edges.push((p, c));
                    seen_edges.insert((p, c));
                }
            }
        }
    }

    // For passives (resistors, inductors) that weren't oriented by MOSFET connections,
    // orient them using BFS from VDD anchors
    orient_passives_by_bfs(subckt, &inst_to_super, &start_anchors, &skipped_nodes,
                           &mut edges, &mut seen_edges);

    // Ground-touching nodes left isolated by edge construction (e.g. a
    // stimulus Vsource or load whose signal net has no producer) would
    // default to layer 0 — the TOP — putting their ground pin above the
    // rails (Q2). They sink to ground: anchor them to the bottom layer.
    let mut edge_nodes: HashSet<u32> = HashSet::new();
    for &(f, t) in &edges {
        edge_nodes.insert(f);
        edge_nodes.insert(t);
    }
    for (i, inst) in subckt.instances.iter().enumerate() {
        let sn = inst_to_super[&(i as u32)];
        if edge_nodes.contains(&sn)
            || start_anchors.contains(&sn)
            || skipped_nodes.contains(&sn)
            || end_anchors.contains(&sn)
        {
            continue;
        }
        let touches_ground = inst.pins.iter().any(|p| {
            p.net_idx
                .and_then(|ni| subckt.nets.get(ni.index()))
                .is_some_and(is_ground_net)
        });
        if touches_ground {
            end_anchors.push(sn);
        }
    }

    let nodes: Vec<u32> = super_nodes.into_iter()
        .filter(|n| !skipped_nodes.contains(n))
        .collect();

    DagGraph { nodes, edges, start_anchors, end_anchors, skipped_nodes }
}

pub fn build_signal_dag(subckt: &Subcircuit, blocks: &[Block]) -> DagGraph {
    build_signal_dag_with_children(subckt, blocks, &HashMap::new())
}

pub fn build_signal_dag_with_children(
    subckt: &Subcircuit,
    blocks: &[Block],
    children: &HashMap<String, Subcircuit>,
) -> DagGraph {
    let (inst_to_super, super_nodes) = build_super_node_map(subckt, blocks);

    let mut start_anchors = Vec::new();
    let mut end_anchors = Vec::new();
    let mut edges: Vec<(u32, u32)> = Vec::new();
    let mut seen_edges: HashSet<(u32, u32)> = HashSet::new();

    // Port-based anchors
    for (i, dir) in subckt.port_directions.iter().enumerate() {
        if i >= subckt.ports.len() {
            break;
        }
        let port_name = &subckt.ports[i];
        // Find the net for this port
        if let Some(net) = subckt.nets.iter().find(|n| n.name == *port_name) {
            for pin_ref in &net.pins {
                let sn = inst_to_super[&pin_ref.instance_idx.0];
                match dir {
                    PinDir::Input => {
                        if !start_anchors.contains(&sn) {
                            start_anchors.push(sn);
                        }
                    }
                    PinDir::Output => {
                        if !end_anchors.contains(&sn) {
                            end_anchors.push(sn);
                        }
                    }
                    _ => {}
                }
            }
        }
    }

    // If no ports (testbench), use Vsource instances as input anchors
    if start_anchors.is_empty() && end_anchors.is_empty() {
        for (i, inst) in subckt.instances.iter().enumerate() {
            if inst.primitive == Primitive::Vsource {
                let sn = inst_to_super[&(i as u32)];
                if !start_anchors.contains(&sn) {
                    start_anchors.push(sn);
                }
            }
        }
    }

    // Build signal edges: gate = input (edge TO device), drain = output (edge FROM device)
    for net in &subckt.nets {
        if classify_rail(net) != RailKind::Signal {
            continue;
        }

        let mut signal_producers: Vec<u32> = Vec::new();
        let mut signal_consumers: Vec<u32> = Vec::new();

        for pin_ref in &net.pins {
            let inst = &subckt[pin_ref.instance_idx];
            let sn = inst_to_super[&pin_ref.instance_idx.0];

            if inst.primitive.is_mosfet() || inst.primitive.is_bjt() || inst.primitive.is_jfet() {
                if pin_ref.pin_idx.0 == 1 {
                    // Gate = signal consumer
                    signal_consumers.push(sn);
                } else if pin_ref.pin_idx.0 == 0 {
                    // Drain = signal producer
                    signal_producers.push(sn);
                }
            } else if inst.primitive == Primitive::Subcircuit {
                if let Some(child) = children.get(&inst.symbol) {
                    let pin_idx = pin_ref.pin_idx.index();
                    if pin_idx < child.port_directions.len() {
                        match child.port_directions[pin_idx] {
                            PinDir::Input => signal_consumers.push(sn),
                            PinDir::Output => signal_producers.push(sn),
                            _ => {}
                        }
                    }
                }
            }
        }

        for &p in &signal_producers {
            for &c in &signal_consumers {
                if p != c && !seen_edges.contains(&(p, c)) {
                    edges.push((p, c));
                    seen_edges.insert((p, c));
                }
            }
        }
    }

    DagGraph {
        nodes: super_nodes,
        edges,
        start_anchors,
        end_anchors,
        skipped_nodes: Vec::new(),
    }
}

fn build_super_node_map(subckt: &Subcircuit, blocks: &[Block]) -> (HashMap<u32, u32>, Vec<u32>) {
    let mut inst_to_super: HashMap<u32, u32> = HashMap::new();
    let mut super_nodes: Vec<u32> = Vec::new();

    // Each block becomes a super-node identified by its first instance index
    for block in blocks {
        if block.instance_indices.is_empty() {
            continue;
        }
        let super_id = block.instance_indices[0];
        super_nodes.push(super_id);
        for &idx in &block.instance_indices {
            inst_to_super.insert(idx, super_id);
        }
    }

    // Loose instances are their own super-node
    for i in 0..subckt.instances.len() {
        let idx = i as u32;
        if !inst_to_super.contains_key(&idx) {
            inst_to_super.insert(idx, idx);
            super_nodes.push(idx);
        }
    }

    (inst_to_super, super_nodes)
}

fn orient_passives_by_bfs(
    subckt: &Subcircuit,
    inst_to_super: &HashMap<u32, u32>,
    vdd_anchors: &[u32],
    skipped: &[u32],
    edges: &mut Vec<(u32, u32)>,
    seen_edges: &mut HashSet<(u32, u32)>,
) {
    // For each non-power/ground net containing a passive device AND another device:
    // If one device already has an edge from a VDD anchor (directly or transitively)
    // and the other doesn't, create an edge from the closer one to the farther one.
    //
    // Strategy: compute reachability depth from VDD anchors using existing edges,
    // then orient passive connections based on depth.

    // Compute depth via BFS on the existing directed edge graph
    let mut adj: HashMap<u32, Vec<u32>> = HashMap::new();
    for &(from, to) in edges.iter() {
        adj.entry(from).or_default().push(to);
    }

    let mut depth: HashMap<u32, usize> = HashMap::new();
    let mut queue: VecDeque<u32> = VecDeque::new();
    for &a in vdd_anchors {
        depth.insert(a, 0);
        queue.push_back(a);
    }
    while let Some(node) = queue.pop_front() {
        let d = depth[&node];
        if let Some(neighbors) = adj.get(&node) {
            for &next in neighbors {
                if !depth.contains_key(&next) {
                    depth.insert(next, d + 1);
                    queue.push_back(next);
                }
            }
        }
    }

    // For nets with a passive: orient based on depth difference
    for net in &subckt.nets {
        if classify_rail(net) != RailKind::Signal {
            continue;
        }

        // Collect all super-nodes on this net (with their depths)
        let mut net_nodes: Vec<(u32, Option<usize>, bool)> = Vec::new(); // (sn, depth, is_passive)
        for pin_ref in &net.pins {
            let inst = &subckt[pin_ref.instance_idx];
            let sn = inst_to_super[&pin_ref.instance_idx.0];
            if skipped.contains(&sn) {
                continue;
            }
            if net_nodes.iter().any(|(n, _, _)| *n == sn) {
                continue;
            }
            let is_passive = matches!(
                inst.primitive,
                Primitive::Resistor | Primitive::Inductor
            );
            net_nodes.push((sn, depth.get(&sn).copied(), is_passive));
        }

        // If we have a passive and another node, and one has depth and the other doesn't
        // (or they have different depths), create an edge
        let has_passive = net_nodes.iter().any(|(_, _, p)| *p);
        if !has_passive || net_nodes.len() < 2 {
            continue;
        }

        for i in 0..net_nodes.len() {
            for j in (i + 1)..net_nodes.len() {
                let (sn_a, depth_a, _) = net_nodes[i];
                let (sn_b, depth_b, _) = net_nodes[j];
                if sn_a == sn_b {
                    continue;
                }

                let (from, to) = match (depth_a, depth_b) {
                    (Some(da), Some(db)) if da < db => (sn_a, sn_b),
                    (Some(da), Some(db)) if db < da => (sn_b, sn_a),
                    (Some(_), None) => (sn_a, sn_b),
                    (None, Some(_)) => (sn_b, sn_a),
                    _ => continue,
                };

                if !seen_edges.contains(&(from, to)) {
                    edges.push((from, to));
                    seen_edges.insert((from, to));
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Sugiyama layering
// ---------------------------------------------------------------------------

pub struct LayerResult {
    pub layers: Vec<Vec<u32>>,
    pub node_layer: HashMap<u32, usize>,
}

pub fn sugiyama_layers(
    nodes: &[u32],
    edges: &[(u32, u32)],
    anchors_start: &[u32],
    anchors_end: &[u32],
) -> LayerResult {
    if nodes.is_empty() {
        return LayerResult {
            layers: Vec::new(),
            node_layer: HashMap::new(),
        };
    }

    let node_set: HashSet<u32> = nodes.iter().copied().collect();

    // Build adjacency lists
    let mut successors: HashMap<u32, Vec<u32>> = HashMap::new();
    let mut predecessors: HashMap<u32, Vec<u32>> = HashMap::new();
    for &n in nodes {
        successors.entry(n).or_default();
        predecessors.entry(n).or_default();
    }

    // Phase 1: Cycle removal via DFS
    let acyclic_edges = remove_cycles(nodes, edges, anchors_start);

    for &(from, to) in &acyclic_edges {
        if node_set.contains(&from) && node_set.contains(&to) {
            successors.entry(from).or_default().push(to);
            predecessors.entry(to).or_default().push(from);
        }
    }

    // Phase 2: Longest-path layer assignment
    let mut node_layer = longest_path_layering(&successors, &predecessors, nodes, anchors_start);

    // Force end anchors to last layer
    if !anchors_end.is_empty() {
        let max_layer = node_layer.values().copied().max().unwrap_or(0);
        for &a in anchors_end {
            if node_layer.contains_key(&a) {
                let current = node_layer[&a];
                if current < max_layer {
                    node_layer.insert(a, max_layer);
                }
            }
        }
    }

    // Build layers vec
    let max_layer = node_layer.values().copied().max().unwrap_or(0);
    let mut layers: Vec<Vec<u32>> = vec![Vec::new(); max_layer + 1];
    for (&node, &layer) in &node_layer {
        layers[layer].push(node);
    }
    // HashMap iteration order is random; sort for a deterministic initial
    // within-layer order (barycenter ties preserve it).
    for layer in &mut layers {
        layer.sort_unstable();
    }

    // Phase 3: Crossing minimization (barycenter)
    minimize_crossings(&mut layers, &successors, &predecessors);

    LayerResult { layers, node_layer }
}

fn remove_cycles(
    nodes: &[u32],
    edges: &[(u32, u32)],
    anchors_start: &[u32],
) -> Vec<(u32, u32)> {
    let node_set: HashSet<u32> = nodes.iter().copied().collect();
    let mut adj: HashMap<u32, Vec<u32>> = HashMap::new();
    for &(from, to) in edges {
        if node_set.contains(&from) && node_set.contains(&to) {
            adj.entry(from).or_default().push(to);
        }
    }

    let mut visited: HashSet<u32> = HashSet::new();
    let mut on_stack: HashSet<u32> = HashSet::new();
    let mut back_edges: HashSet<(u32, u32)> = HashSet::new();

    // DFS from start anchors first, then remaining nodes
    let mut start_order: Vec<u32> = anchors_start
        .iter()
        .filter(|n| node_set.contains(n))
        .copied()
        .collect();
    for &n in nodes {
        if !start_order.contains(&n) {
            start_order.push(n);
        }
    }

    for &root in &start_order {
        if visited.contains(&root) {
            continue;
        }
        dfs_find_back_edges(root, &adj, &mut visited, &mut on_stack, &mut back_edges);
    }

    // Return edges with back-edges reversed
    let mut result = Vec::with_capacity(edges.len());
    for &(from, to) in edges {
        if back_edges.contains(&(from, to)) {
            result.push((to, from));
        } else {
            result.push((from, to));
        }
    }
    result
}

fn dfs_find_back_edges(
    node: u32,
    adj: &HashMap<u32, Vec<u32>>,
    visited: &mut HashSet<u32>,
    on_stack: &mut HashSet<u32>,
    back_edges: &mut HashSet<(u32, u32)>,
) {
    visited.insert(node);
    on_stack.insert(node);

    if let Some(neighbors) = adj.get(&node) {
        for &next in neighbors {
            if !visited.contains(&next) {
                dfs_find_back_edges(next, adj, visited, on_stack, back_edges);
            } else if on_stack.contains(&next) {
                back_edges.insert((node, next));
            }
        }
    }

    on_stack.remove(&node);
}

fn longest_path_layering(
    successors: &HashMap<u32, Vec<u32>>,
    predecessors: &HashMap<u32, Vec<u32>>,
    nodes: &[u32],
    anchors_start: &[u32],
) -> HashMap<u32, usize> {
    let mut layer: HashMap<u32, usize> = HashMap::new();
    let mut in_degree: HashMap<u32, usize> = HashMap::new();

    for &n in nodes {
        let deg = predecessors.get(&n).map_or(0, |p| p.len());
        in_degree.insert(n, deg);
    }

    // Initialize queue with nodes that have no predecessors
    let mut queue: VecDeque<u32> = VecDeque::new();
    for &n in nodes {
        if in_degree[&n] == 0 {
            layer.insert(n, 0);
            queue.push_back(n);
        }
    }

    // If no zero-in-degree nodes found but we have start anchors, force them
    if queue.is_empty() {
        for &a in anchors_start {
            if !layer.contains_key(&a) {
                layer.insert(a, 0);
                queue.push_back(a);
            }
        }
    }

    // BFS topological traversal — longest path
    while let Some(node) = queue.pop_front() {
        let current_layer = layer[&node];
        if let Some(succs) = successors.get(&node) {
            for &s in succs {
                let new_layer = current_layer + 1;
                let existing = layer.entry(s).or_insert(0);
                if new_layer > *existing {
                    *existing = new_layer;
                }
                let deg = in_degree.get_mut(&s).unwrap();
                *deg = deg.saturating_sub(1);
                if *deg == 0 {
                    queue.push_back(s);
                }
            }
        }
    }

    // Any unreached nodes get assigned to the middle layer
    let max_layer = layer.values().copied().max().unwrap_or(0);
    let mid = max_layer / 2;
    for &n in nodes {
        layer.entry(n).or_insert(mid);
    }

    layer
}

fn minimize_crossings(
    layers: &mut [Vec<u32>],
    successors: &HashMap<u32, Vec<u32>>,
    predecessors: &HashMap<u32, Vec<u32>>,
) {
    if layers.len() < 2 {
        return;
    }

    for _ in 0..24 {
        // Top-down sweep
        for i in 1..layers.len() {
            let prev_pos: HashMap<u32, usize> = layers[i - 1]
                .iter()
                .enumerate()
                .map(|(pos, &node)| (node, pos))
                .collect();

            let mut scored: Vec<(u32, f64)> = layers[i]
                .iter()
                .map(|&node| {
                    let preds = predecessors.get(&node).map_or(&[][..], |v| v.as_slice());
                    (node, barycenter(preds, &prev_pos))
                })
                .collect();

            scored.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
            layers[i] = scored.into_iter().map(|(n, _)| n).collect();
        }

        // Bottom-up sweep
        for i in (0..layers.len() - 1).rev() {
            let next_pos: HashMap<u32, usize> = layers[i + 1]
                .iter()
                .enumerate()
                .map(|(pos, &node)| (node, pos))
                .collect();

            let mut scored: Vec<(u32, f64)> = layers[i]
                .iter()
                .map(|&node| {
                    let succs = successors.get(&node).map_or(&[][..], |v| v.as_slice());
                    (node, barycenter(succs, &next_pos))
                })
                .collect();

            scored.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
            layers[i] = scored.into_iter().map(|(n, _)| n).collect();
        }
    }
}

fn barycenter(neighbors: &[u32], positions: &HashMap<u32, usize>) -> f64 {
    let mut sum = 0.0;
    let mut count = 0;
    for &n in neighbors {
        if let Some(&pos) = positions.get(&n) {
            sum += pos as f64;
            count += 1;
        }
    }
    if count == 0 {
        f64::MAX
    } else {
        sum / count as f64
    }
}

// ---------------------------------------------------------------------------
// Block templates (data-driven; replaces 11 near-identical placement fns)
// ---------------------------------------------------------------------------

/// One device slot inside a block template.
///
/// Offsets are in *half* units of the block's `PlacementHint` spacing:
/// `dx = dx2 * h_spacing / 2`, `dy = dy2 * v_spacing / 2`. Halves are the
/// finest granularity the old hand-written templates used (`±spacing/2`,
/// `spacing/2`, `spacing`), so every old layout is representable exactly.
#[derive(Clone, Copy)]
struct Slot {
    dx2: i32,
    dy2: i32,
    rotation: u8,
    flip: bool,
}

const fn slot(dx2: i32, dy2: i32, rotation: u8, flip: bool) -> Slot {
    Slot { dx2, dy2, rotation, flip }
}

/// How block instances map onto template slots.
#[derive(Clone, Copy)]
enum SlotOrder {
    /// Recognition order is already correct (ref-first / bottom-first).
    AsIs,
    /// First slot must be the MOSFET (CommonSource / SourceFollower).
    MosfetFirst,
    /// First slot must be the PMOS (PushPull).
    PmosFirst,
    /// First slot must be the resistor (RcCompensation).
    ResistorFirst,
}

/// Horizontal advance returned to the caller after placing the block.
#[derive(Clone, Copy)]
enum Advance {
    HSpacing,
    HalfVSpacing,
    Fixed,
}

struct Template {
    order: SlotOrder,
    slots: &'static [Slot],
    advance: Advance,
}

/// Side-by-side pair: ref/left device flipped, mirror/right device upright.
static T_PAIR: Template = Template {
    order: SlotOrder::AsIs,
    slots: &[slot(0, 0, 0, true), slot(2, 0, 0, false)],
    advance: Advance::HSpacing,
};
/// Vertical stack, bottom device first (below origin), top above.
static T_CASCODE: Template = Template {
    order: SlotOrder::AsIs,
    slots: &[slot(0, 1, 0, false), slot(0, -1, 0, false)],
    advance: Advance::HalfVSpacing,
};
/// [bot-ref, bot-mir, top-ref, top-mir] 2x2 grid.
static T_CASCODE_MIRROR: Template = Template {
    order: SlotOrder::AsIs,
    slots: &[
        slot(0, 1, 0, true),
        slot(2, 1, 0, false),
        slot(0, -1, 0, true),
        slot(2, -1, 0, false),
    ],
    advance: Advance::HSpacing,
};
/// PMOS above origin, NMOS below.
static T_PUSH_PULL: Template = Template {
    order: SlotOrder::PmosFirst,
    slots: &[slot(0, -1, 0, false), slot(0, 1, 0, false)],
    advance: Advance::HalfVSpacing,
};
/// MOSFET at origin, load a full v_spacing above.
static T_COMMON_SOURCE: Template = Template {
    order: SlotOrder::MosfetFirst,
    slots: &[slot(0, 0, 0, false), slot(0, -2, 0, false)],
    advance: Advance::Fixed,
};
/// MOSFET at origin, current source a full v_spacing below.
static T_SOURCE_FOLLOWER: Template = Template {
    order: SlotOrder::MosfetFirst,
    slots: &[slot(0, 0, 0, false), slot(0, 2, 0, false)],
    advance: Advance::Fixed,
};
/// R and C side by side, both rotated 90 degrees.
static T_RC_COMP: Template = Template {
    order: SlotOrder::ResistorFirst,
    slots: &[slot(0, 0, 1, false), slot(2, 0, 1, false)],
    advance: Advance::HSpacing,
};
/// [ref, mirror, feedback]: pair on bottom row, fb centered above.
static T_WILSON: Template = Template {
    order: SlotOrder::AsIs,
    slots: &[
        slot(0, 1, 0, true),
        slot(2, 1, 0, false),
        slot(1, -1, 0, false),
    ],
    advance: Advance::HSpacing,
};
/// [ref, mirror, degeneration R below mirror].
static T_WIDLAR: Template = Template {
    order: SlotOrder::AsIs,
    slots: &[
        slot(0, 0, 0, true),
        slot(2, 0, 0, false),
        slot(2, 2, 0, false),
    ],
    advance: Advance::HSpacing,
};
/// Two devices stacked vertically around the origin.
static T_VSTACK: Template = Template {
    order: SlotOrder::AsIs,
    slots: &[slot(0, -1, 0, false), slot(0, 1, 0, false)],
    advance: Advance::Fixed,
};

/// Per-BlockType placement config. Exhaustive match — adding a `BlockType`
/// without a template row is a compile error.
fn template_for(block_type: BlockType) -> &'static Template {
    match block_type {
        BlockType::DiffPair | BlockType::CurrentMirror => &T_PAIR,
        BlockType::CascodeStack => &T_CASCODE,
        BlockType::CascodeMirror => &T_CASCODE_MIRROR,
        BlockType::PushPull => &T_PUSH_PULL,
        BlockType::CommonSource => &T_COMMON_SOURCE,
        BlockType::SourceFollower => &T_SOURCE_FOLLOWER,
        BlockType::RcCompensation => &T_RC_COMP,
        BlockType::WilsonMirror => &T_WILSON,
        BlockType::WidlarMirror => &T_WIDLAR,
        BlockType::ResistorDivider => &T_VSTACK,
    }
}

/// Place a recognized block's instances using its template.
/// Returns the horizontal advance (block width contribution).
pub fn apply_template(
    subckt: &mut Subcircuit,
    block: &Block,
    origin_x: i32,
    origin_y: i32,
) -> i32 {
    let template = template_for(block.block_type);
    if block.instance_indices.len() < template.slots.len() {
        return DEFAULT_SIZE;
    }

    let mut idxs: Vec<usize> = block
        .instance_indices
        .iter()
        .take(template.slots.len())
        .map(|&i| i as usize)
        .collect();

    // Role-based reorder: old templates swapped the first two instances when
    // index 0 was not the expected device kind.
    let swap = match template.order {
        SlotOrder::AsIs => false,
        SlotOrder::MosfetFirst => !subckt.instances[idxs[0]].primitive.is_mosfet(),
        SlotOrder::PmosFirst => subckt.instances[idxs[0]].primitive != Primitive::Pmos,
        SlotOrder::ResistorFirst => subckt.instances[idxs[0]].primitive != Primitive::Resistor,
    };
    if swap {
        idxs.swap(0, 1);
    }

    let h = block.hint.h_spacing;
    let v = block.hint.v_spacing;
    for (s, &i) in template.slots.iter().zip(&idxs) {
        let inst = &mut subckt.instances[i];
        inst.x = origin_x + s.dx2 * h / 2;
        inst.y = origin_y + s.dy2 * v / 2;
        inst.rotation = s.rotation;
        inst.flip = s.flip;
    }

    match template.advance {
        Advance::HSpacing => h,
        Advance::HalfVSpacing => v / 2,
        Advance::Fixed => DEFAULT_SIZE,
    }
}

/// Nudge instances apart when pins from different nets land on the same
/// grid point (which would short them visually and confuse routing).
pub fn fix_pin_overlaps(subckt: &mut Subcircuit, backend: &dyn PinGeometry) {
    let grid = 10i32;
    let max_passes = (subckt.instances.len() * 2).max(20);
    for _ in 0..max_passes {
        type PinInfo = Vec<(usize, usize, Option<NetId>)>;
        let mut pin_map: HashMap<(i32, i32), PinInfo> = HashMap::new();
        for (i, inst) in subckt.instances.iter().enumerate() {
            for (p, pin) in inst.pins.iter().enumerate() {
                let (px, py) = pin_position(backend, inst, p);
                pin_map
                    .entry((px, py))
                    .or_default()
                    .push((i, p, pin.net_idx));
            }
        }

        // Sort buckets by position: HashMap iteration order is random and
        // would make WHICH instance gets shifted nondeterministic run-to-run.
        let mut buckets: Vec<(&(i32, i32), &PinInfo)> = pin_map.iter().collect();
        buckets.sort_by_key(|(pos, _)| **pos);

        let mut to_shift: Option<usize> = None;
        for (_, pins) in buckets {
            if pins.len() < 2 {
                continue;
            }
            let mut nets: HashSet<NetId> = HashSet::new();
            let mut inst_set: HashSet<usize> = HashSet::new();
            for &(inst_i, _, net) in pins {
                if let Some(n) = net {
                    nets.insert(n);
                }
                inst_set.insert(inst_i);
            }
            if nets.len() >= 2 && inst_set.len() >= 2 {
                let second_inst = pins
                    .iter()
                    .find(|&&(i, _, _)| i != pins[0].0)
                    .map(|&(i, _, _)| i);
                if let Some(idx) = second_inst {
                    to_shift = Some(idx);
                    break;
                }
            }
        }

        if let Some(idx) = to_shift {
            subckt.instances[idx].x += grid;
        } else {
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir::*;
    use crate::recognition::PlacementHint;

    /// Minimal geometry: every pin at the instance origin (pin_position falls
    /// back to (inst.x, inst.y) when the offsets slice is empty).
    struct TestGeom;

    impl PinGeometry for TestGeom {
        fn pin_offsets(&self, _primitive: Primitive) -> &[(i32, i32)] {
            &[]
        }
        fn transform_pin(&self, dx: i32, dy: i32, _rotation: u8, _flip: bool) -> (i32, i32) {
            (dx, dy)
        }
    }

    fn mos(name: &str, primitive: Primitive, symbol: &str) -> Instance {
        Instance {
            name: name.to_string(),
            primitive,
            symbol: symbol.to_string(),
            pins: vec![
                Pin { name: "D".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "G".into(), dir: PinDir::Input, net_idx: None },
                Pin { name: "S".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "B".into(), dir: PinDir::Bulk, net_idx: None },
            ],
            params: Default::default(),
            x: 0, y: 0, rotation: 0, flip: false,
        }
    }

    fn two_term(name: &str, primitive: Primitive, symbol: &str) -> Instance {
        Instance {
            name: name.to_string(),
            primitive,
            symbol: symbol.to_string(),
            pins: vec![
                Pin { name: "p".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "n".into(), dir: PinDir::Inout, net_idx: None },
            ],
            params: Default::default(),
            x: 0, y: 0, rotation: 0, flip: false,
        }
    }

    fn make_nmos(name: &str) -> Instance {
        mos(name, Primitive::Nmos, "nmos4")
    }
    fn make_pmos(name: &str) -> Instance {
        mos(name, Primitive::Pmos, "pmos4")
    }
    fn make_resistor(name: &str) -> Instance {
        two_term(name, Primitive::Resistor, "res")
    }
    fn make_capacitor(name: &str) -> Instance {
        two_term(name, Primitive::Capacitor, "cap")
    }
    fn make_vsource(name: &str) -> Instance {
        two_term(name, Primitive::Vsource, "vsource")
    }

    fn connect(subckt: &mut Subcircuit, net_name: &str, inst_idx: u32, pin_idx: u32) {
        let net_idx = if let Some(pos) = subckt.nets.iter().position(|n| n.name == net_name) {
            pos
        } else {
            subckt.nets.push(Net::new(net_name));
            subckt.nets.len() - 1
        };
        subckt.nets[net_idx].pins.push(PinRef {
            instance_idx: InstId(inst_idx),
            pin_idx: PinIdx(pin_idx as u16),
        });
        subckt.instances[inst_idx as usize].pins[pin_idx as usize].net_idx =
            Some(NetId(net_idx as u32));
    }

    fn classify_net(subckt: &mut Subcircuit, net_name: &str, class: NetClass) {
        if let Some(net) = subckt.nets.iter_mut().find(|n| n.name == net_name) {
            net.classification = class;
        }
    }

    #[test]
    fn classify_rail_uses_class_and_name() {
        let mut net = Net::new("VDD");
        assert_eq!(classify_rail(&net), RailKind::Power);
        net.name = "0".into();
        assert_eq!(classify_rail(&net), RailKind::Ground);
        net.name = "vout".into();
        assert_eq!(classify_rail(&net), RailKind::Signal);
        net.classification = NetClass::Ground;
        assert_eq!(classify_rail(&net), RailKind::Ground);
    }

    #[test]
    fn power_dag_capacitors_are_skipped() {
        let mut subckt = Subcircuit::new("rc");
        subckt.instances.push(make_resistor("R1")); // idx 0
        subckt.instances.push(make_capacitor("C1")); // idx 1

        connect(&mut subckt, "vdd", 0, 0);
        connect(&mut subckt, "mid", 0, 1);
        connect(&mut subckt, "mid", 1, 0);
        connect(&mut subckt, "0", 1, 1);

        classify_net(&mut subckt, "vdd", NetClass::Power);
        classify_net(&mut subckt, "0", NetClass::Ground);

        let dag = build_power_dag(&subckt, &[]);
        assert!(dag.skipped_nodes.contains(&1), "Capacitor should be skipped");
        assert!(!dag.nodes.contains(&1), "Skipped nodes should not be in nodes list");
    }

    #[test]
    fn sugiyama_linear_chain_layers() {
        let result = sugiyama_layers(&[0, 1, 2], &[(0, 1), (1, 2)], &[0], &[2]);
        assert_eq!(result.node_layer[&0], 0);
        assert_eq!(result.node_layer[&1], 1);
        assert_eq!(result.node_layer[&2], 2);
        assert_eq!(result.layers.len(), 3);
    }

    /// Layers monotone: VDD source on top, Rd in the middle, NMOS at bottom.
    #[test]
    fn common_source_layers_monotone_power_to_ground() {
        let mut subckt = Subcircuit::new("cs");
        subckt.instances.push(make_vsource("Vdd")); // idx 0 — VDD anchor
        subckt.instances.push(make_resistor("Rd")); // idx 1
        subckt.instances.push(make_nmos("M1")); // idx 2

        connect(&mut subckt, "vdd", 0, 0); // Vdd.p = vdd
        connect(&mut subckt, "0", 0, 1); // Vdd.n = gnd
        connect(&mut subckt, "vdd", 1, 0); // Rd.p = vdd
        connect(&mut subckt, "vout", 1, 1); // Rd.n = vout
        connect(&mut subckt, "vout", 2, 0); // M1.D = vout
        connect(&mut subckt, "vin", 2, 1); // M1.G = vin
        connect(&mut subckt, "0", 2, 2); // M1.S = gnd
        connect(&mut subckt, "0", 2, 3); // M1.B = gnd

        classify_net(&mut subckt, "vdd", NetClass::Power);
        classify_net(&mut subckt, "0", NetClass::Ground);

        place(&mut subckt, &[], &TestGeom);

        let (vdd_y, rd_y, m1_y) = (
            subckt.instances[0].y,
            subckt.instances[1].y,
            subckt.instances[2].y,
        );
        assert!(
            vdd_y <= rd_y && rd_y < m1_y,
            "expected monotone VDD→Rd→M1 flow, got Vdd y={vdd_y}, Rd y={rd_y}, M1 y={m1_y}"
        );
    }

    #[test]
    fn inverter_pmos_above_nmos() {
        let mut subckt = Subcircuit::new("inv");
        subckt.instances.push(make_pmos("Mp")); // idx 0
        subckt.instances.push(make_nmos("Mn")); // idx 1

        connect(&mut subckt, "vdd", 0, 2); // Mp.S = vdd
        connect(&mut subckt, "vout", 0, 0); // Mp.D = vout
        connect(&mut subckt, "vin", 0, 1); // Mp.G = vin
        connect(&mut subckt, "vout", 1, 0); // Mn.D = vout
        connect(&mut subckt, "vin", 1, 1); // Mn.G = vin
        connect(&mut subckt, "0", 1, 2); // Mn.S = gnd

        classify_net(&mut subckt, "vdd", NetClass::Power);
        classify_net(&mut subckt, "0", NetClass::Ground);

        place(&mut subckt, &[], &TestGeom);

        assert!(
            subckt.instances[0].y < subckt.instances[1].y,
            "PMOS (y={}) should be above NMOS (y={})",
            subckt.instances[0].y,
            subckt.instances[1].y
        );
    }

    /// Floating capacitor (skipped in the DAG) lands between its neighbors'
    /// layers via neighbor averaging, not in the fallback grid.
    #[test]
    fn capacitor_floats_to_neighbor_average() {
        let mut subckt = Subcircuit::new("csc");
        subckt.instances.push(make_vsource("Vdd")); // idx 0
        subckt.instances.push(make_resistor("Rd")); // idx 1
        subckt.instances.push(make_nmos("M1")); // idx 2
        subckt.instances.push(make_capacitor("Cl")); // idx 3

        connect(&mut subckt, "vdd", 0, 0);
        connect(&mut subckt, "0", 0, 1);
        connect(&mut subckt, "vdd", 1, 0);
        connect(&mut subckt, "vout", 1, 1);
        connect(&mut subckt, "vout", 2, 0);
        connect(&mut subckt, "vin", 2, 1);
        connect(&mut subckt, "0", 2, 2);
        connect(&mut subckt, "vout", 3, 0);
        connect(&mut subckt, "0", 3, 1);

        classify_net(&mut subckt, "vdd", NetClass::Power);
        classify_net(&mut subckt, "0", NetClass::Ground);

        place(&mut subckt, &[], &TestGeom);

        let max_layer_y = (subckt.instances.iter().take(3).map(|i| i.y).max().unwrap_or(0))
            + LAYER_SPACING;
        assert!(
            subckt.instances[3].y < max_layer_y,
            "Cap (y={}) should be averaged into the layer span, not dumped below {}",
            subckt.instances[3].y,
            max_layer_y
        );
    }

    /// Every BlockType has a template row, and applying it moves the
    /// block's instances to the requested origin.
    #[test]
    fn template_table_covers_all_block_types() {
        const ALL: &[BlockType] = &[
            BlockType::DiffPair,
            BlockType::CurrentMirror,
            BlockType::CascodeStack,
            BlockType::CascodeMirror,
            BlockType::PushPull,
            BlockType::CommonSource,
            BlockType::SourceFollower,
            BlockType::RcCompensation,
            BlockType::WilsonMirror,
            BlockType::WidlarMirror,
            BlockType::ResistorDivider,
        ];

        for &bt in ALL {
            let mut subckt = Subcircuit::new("tpl");
            subckt.instances.push(make_pmos("A")); // satisfies PmosFirst/MosfetFirst
            subckt.instances.push(make_resistor("B")); // satisfies ResistorFirst swap
            subckt.instances.push(make_nmos("C"));
            subckt.instances.push(make_nmos("D"));

            let block = Block {
                block_type: bt,
                instance_indices: vec![0, 1, 2, 3],
                hint: PlacementHint::for_type(bt),
            };

            let n_slots = template_for(bt).slots.len();
            assert!(n_slots >= 2, "{bt:?}: template must place at least 2 devices");

            let advance = apply_template(&mut subckt, &block, 1000, 1000);
            assert!(advance > 0, "{bt:?}: advance must be positive");

            for inst in subckt.instances.iter().take(n_slots) {
                assert!(
                    (inst.x - 1000).abs() <= 320 && (inst.y - 1000).abs() <= 320,
                    "{bt:?}: instance {} not placed near origin: ({}, {})",
                    inst.name,
                    inst.x,
                    inst.y
                );
            }
        }
    }

    /// Overlapping loose instances in the same row get pushed apart to at
    /// least BODY_GAP, on-grid, preserving left-to-right order.
    #[test]
    fn separate_overlapping_bodies_clears_row_overlap() {
        let mut subckt = Subcircuit::new("ovl");
        subckt.instances.push(make_nmos("a")); // (160, 320)
        subckt.instances.push(make_nmos("b")); // (170, 320) — bodies overlap
        subckt.instances[0].x = 160;
        subckt.instances[0].y = 320;
        subckt.instances[1].x = 170;
        subckt.instances[1].y = 320;

        let moved = separate_overlapping_bodies(&mut subckt, &[], &TestGeom);
        assert!(moved, "overlap should trigger a shift");

        // TestGeom bodies are origin ±10 in both dims.
        let (a, b) = (&subckt.instances[0], &subckt.instances[1]);
        assert_eq!(a.x, 160, "left instance must not move");
        assert!(b.x > a.x, "relative order preserved");
        assert!(
            b.x - 10 >= a.x + 10 + BODY_GAP,
            "bodies must be separated by BODY_GAP, got a.x={} b.x={}",
            a.x,
            b.x
        );
        assert_eq!(b.x % 10, 0, "shift must stay grid-aligned");
        assert!(
            !separate_overlapping_bodies(&mut subckt, &[], &TestGeom),
            "second pass must be a no-op"
        );
    }

    /// Block members move rigidly: internal template offsets survive the shift.
    #[test]
    fn separate_overlapping_bodies_moves_blocks_rigidly() {
        let mut subckt = Subcircuit::new("blk");
        subckt.instances.push(make_nmos("m1")); // block member at (0, 0)
        subckt.instances.push(make_nmos("m2")); // block member at (160, 0)
        subckt.instances.push(make_resistor("r1")); // loose, overlapping m1
        subckt.instances[1].x = 160;
        subckt.instances[2].x = -10;

        let block = Block {
            block_type: BlockType::DiffPair,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::DiffPair),
        };

        separate_overlapping_bodies(&mut subckt, &[block], &TestGeom);

        assert_eq!(
            subckt.instances[1].x - subckt.instances[0].x,
            160,
            "block-internal geometry must be preserved"
        );
        assert!(
            subckt.instances[0].x - 10 >= subckt.instances[2].x + 10 + BODY_GAP,
            "block must clear the loose instance: r1.x={} m1.x={}",
            subckt.instances[2].x,
            subckt.instances[0].x
        );
    }

    /// Template behavior matches the old hand-written fns for a sample type.
    #[test]
    fn diff_pair_template_matches_legacy_layout() {
        let mut subckt = Subcircuit::new("dp");
        subckt.instances.push(make_nmos("M1"));
        subckt.instances.push(make_nmos("M2"));

        let block = Block {
            block_type: BlockType::DiffPair,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::DiffPair),
        };
        let advance = apply_template(&mut subckt, &block, 100, 200);

        let h = block.hint.h_spacing;
        assert_eq!((subckt.instances[0].x, subckt.instances[0].y), (100, 200));
        assert!(subckt.instances[0].flip);
        assert_eq!(
            (subckt.instances[1].x, subckt.instances[1].y),
            (100 + h, 200)
        );
        assert!(!subckt.instances[1].flip);
        assert_eq!(advance, h);
    }
}
