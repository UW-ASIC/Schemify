pub mod annealing;
pub mod constraint_gen;
pub mod constraints;
pub mod cost;

use crate::s2s::ir::{Primitive, Subcircuit};
use crate::s2s::output::PinGeometry;
use crate::s2s::recognition::{Block, BlockType, PlacementHint};

use std::collections::{HashMap, HashSet};

use self::constraint_gen::generate_constraints;
use self::constraints::{Axis, Constraint, Side};
use self::cost::{PlacementState, snap};
use self::annealing::simulated_annealing;

const GRID_SIZE: i32 = 200;
const MAX_COLS: i32 = 4;

/// SA threshold: circuits with more than this many items use simulated annealing.
const SA_THRESHOLD: usize = 10;

// --------------------------------------------------------------------------
// PlacementItem
// --------------------------------------------------------------------------

/// An item in the placement: either a recognized block or a single loose device.
#[derive(Debug, Clone)]
pub(crate) struct PlacementItem {
    /// Instance indices belonging to this item.
    pub instance_indices: Vec<u32>,
    /// Block type if recognized, None for loose devices.
    pub block_type: Option<BlockType>,
    /// Original block reference index (into blocks slice), if any.
    pub block_ref: Option<usize>,
}

// --------------------------------------------------------------------------
// Template functions
// --------------------------------------------------------------------------

/// Compute block bounding box width for a given block type.
fn block_width(block_type: BlockType) -> i32 {
    let hint = PlacementHint::for_type(block_type);
    if hint.h_spacing > 0 {
        hint.h_spacing
    } else if hint.v_spacing > 0 {
        hint.v_spacing / 2
    } else {
        GRID_SIZE
    }
}

/// Compute block bounding box height for a given block type.
fn block_height(block_type: BlockType) -> i32 {
    let hint = PlacementHint::for_type(block_type);
    if hint.v_spacing > 0 && hint.h_spacing > 0 {
        2 * hint.v_spacing
    } else if hint.v_spacing > 0 {
        hint.v_spacing
    } else if hint.h_spacing > 0 {
        hint.h_spacing / 2
    } else {
        GRID_SIZE
    }
}

fn place_diff_pair(subckt: &mut Subcircuit, block: &Block, origin_x: i32, origin_y: i32) -> i32 {
    let idx0 = block.instance_indices[0] as usize;
    let idx1 = block.instance_indices[1] as usize;

    subckt.instances[idx0].x = origin_x;
    subckt.instances[idx0].y = origin_y;
    subckt.instances[idx0].flip = true;
    subckt.instances[idx0].rotation = 0;

    subckt.instances[idx1].x = origin_x + block.hint.h_spacing;
    subckt.instances[idx1].y = origin_y;
    subckt.instances[idx1].flip = false;
    subckt.instances[idx1].rotation = 0;

    block.hint.h_spacing
}

fn place_current_mirror(
    subckt: &mut Subcircuit,
    block: &Block,
    origin_x: i32,
    origin_y: i32,
) -> i32 {
    let ref_idx = block.instance_indices[0] as usize;
    let mir_idx = block.instance_indices[1] as usize;

    subckt.instances[ref_idx].x = origin_x;
    subckt.instances[ref_idx].y = origin_y;
    subckt.instances[ref_idx].flip = true;
    subckt.instances[ref_idx].rotation = 0;

    subckt.instances[mir_idx].x = origin_x + block.hint.h_spacing;
    subckt.instances[mir_idx].y = origin_y;
    subckt.instances[mir_idx].flip = false;
    subckt.instances[mir_idx].rotation = 0;

    block.hint.h_spacing
}

fn place_cascode(subckt: &mut Subcircuit, block: &Block, origin_x: i32, origin_y: i32) -> i32 {
    let bot_idx = block.instance_indices[0] as usize;
    let top_idx = block.instance_indices[1] as usize;

    subckt.instances[bot_idx].x = origin_x;
    subckt.instances[bot_idx].y = origin_y + block.hint.v_spacing / 2;
    subckt.instances[bot_idx].rotation = 0;
    subckt.instances[bot_idx].flip = false;

    subckt.instances[top_idx].x = origin_x;
    subckt.instances[top_idx].y = origin_y - block.hint.v_spacing / 2;
    subckt.instances[top_idx].rotation = 0;
    subckt.instances[top_idx].flip = false;

    block.hint.v_spacing / 2
}

fn place_cascode_mirror(
    subckt: &mut Subcircuit,
    block: &Block,
    origin_x: i32,
    origin_y: i32,
) -> i32 {
    if block.instance_indices.len() < 4 {
        return GRID_SIZE;
    }
    let mb_ref = block.instance_indices[0] as usize;
    let mb_mir = block.instance_indices[1] as usize;
    let mt_ref = block.instance_indices[2] as usize;
    let mt_mir = block.instance_indices[3] as usize;

    subckt.instances[mb_ref].x = origin_x;
    subckt.instances[mb_ref].y = origin_y + block.hint.v_spacing / 2;
    subckt.instances[mb_ref].flip = true;
    subckt.instances[mb_ref].rotation = 0;

    subckt.instances[mb_mir].x = origin_x + block.hint.h_spacing;
    subckt.instances[mb_mir].y = origin_y + block.hint.v_spacing / 2;
    subckt.instances[mb_mir].flip = false;
    subckt.instances[mb_mir].rotation = 0;

    subckt.instances[mt_ref].x = origin_x;
    subckt.instances[mt_ref].y = origin_y - block.hint.v_spacing / 2;
    subckt.instances[mt_ref].flip = true;
    subckt.instances[mt_ref].rotation = 0;

    subckt.instances[mt_mir].x = origin_x + block.hint.h_spacing;
    subckt.instances[mt_mir].y = origin_y - block.hint.v_spacing / 2;
    subckt.instances[mt_mir].flip = false;
    subckt.instances[mt_mir].rotation = 0;

    block.hint.h_spacing
}

fn place_push_pull(
    subckt: &mut Subcircuit,
    block: &Block,
    origin_x: i32,
    origin_y: i32,
) -> i32 {
    if block.instance_indices.len() < 2 {
        return GRID_SIZE;
    }
    let idx0 = block.instance_indices[0] as usize;
    let idx1 = block.instance_indices[1] as usize;

    let (pmos_idx, nmos_idx) = if subckt.instances[idx0].primitive == Primitive::Pmos {
        (idx0, idx1)
    } else {
        (idx1, idx0)
    };

    subckt.instances[pmos_idx].x = origin_x;
    subckt.instances[pmos_idx].y = origin_y - block.hint.v_spacing / 2;
    subckt.instances[pmos_idx].rotation = 0;
    subckt.instances[pmos_idx].flip = false;

    subckt.instances[nmos_idx].x = origin_x;
    subckt.instances[nmos_idx].y = origin_y + block.hint.v_spacing / 2;
    subckt.instances[nmos_idx].rotation = 0;
    subckt.instances[nmos_idx].flip = false;

    block.hint.v_spacing / 2
}

fn place_common_source(
    subckt: &mut Subcircuit,
    block: &Block,
    origin_x: i32,
    origin_y: i32,
) -> i32 {
    if block.instance_indices.len() < 2 {
        return GRID_SIZE;
    }
    let idx0 = block.instance_indices[0] as usize;
    let idx1 = block.instance_indices[1] as usize;

    let (mos_idx, res_idx) = if subckt.instances[idx0].primitive.is_mosfet() {
        (idx0, idx1)
    } else {
        (idx1, idx0)
    };

    subckt.instances[mos_idx].x = origin_x;
    subckt.instances[mos_idx].y = origin_y;
    subckt.instances[mos_idx].rotation = 0;
    subckt.instances[mos_idx].flip = false;

    subckt.instances[res_idx].x = origin_x;
    subckt.instances[res_idx].y = origin_y - block.hint.v_spacing;
    subckt.instances[res_idx].rotation = 0;
    subckt.instances[res_idx].flip = false;

    GRID_SIZE
}

fn place_source_follower(
    subckt: &mut Subcircuit,
    block: &Block,
    origin_x: i32,
    origin_y: i32,
) -> i32 {
    if block.instance_indices.len() < 2 {
        return GRID_SIZE;
    }
    let idx0 = block.instance_indices[0] as usize;
    let idx1 = block.instance_indices[1] as usize;

    let (mos_idx, isrc_idx) = if subckt.instances[idx0].primitive.is_mosfet() {
        (idx0, idx1)
    } else {
        (idx1, idx0)
    };

    subckt.instances[mos_idx].x = origin_x;
    subckt.instances[mos_idx].y = origin_y;
    subckt.instances[mos_idx].rotation = 0;
    subckt.instances[mos_idx].flip = false;

    subckt.instances[isrc_idx].x = origin_x;
    subckt.instances[isrc_idx].y = origin_y + block.hint.v_spacing;
    subckt.instances[isrc_idx].rotation = 0;
    subckt.instances[isrc_idx].flip = false;

    GRID_SIZE
}

fn place_rc_compensation(
    subckt: &mut Subcircuit,
    block: &Block,
    origin_x: i32,
    origin_y: i32,
) -> i32 {
    if block.instance_indices.len() < 2 {
        return GRID_SIZE;
    }
    let idx0 = block.instance_indices[0] as usize;
    let idx1 = block.instance_indices[1] as usize;

    let (r_idx, c_idx) = if subckt.instances[idx0].primitive == Primitive::Resistor {
        (idx0, idx1)
    } else {
        (idx1, idx0)
    };

    subckt.instances[r_idx].x = origin_x;
    subckt.instances[r_idx].y = origin_y;
    subckt.instances[r_idx].rotation = 1;
    subckt.instances[r_idx].flip = false;

    subckt.instances[c_idx].x = origin_x + block.hint.h_spacing;
    subckt.instances[c_idx].y = origin_y;
    subckt.instances[c_idx].rotation = 1;
    subckt.instances[c_idx].flip = false;

    block.hint.h_spacing
}

fn place_wilson_mirror(
    subckt: &mut Subcircuit,
    block: &Block,
    origin_x: i32,
    origin_y: i32,
) -> i32 {
    if block.instance_indices.len() < 3 {
        return GRID_SIZE;
    }
    let ref_idx = block.instance_indices[0] as usize;
    let mir_idx = block.instance_indices[1] as usize;
    let fb_idx = block.instance_indices[2] as usize;

    subckt.instances[ref_idx].x = origin_x;
    subckt.instances[ref_idx].y = origin_y + block.hint.v_spacing / 2;
    subckt.instances[ref_idx].flip = true;
    subckt.instances[ref_idx].rotation = 0;

    subckt.instances[mir_idx].x = origin_x + block.hint.h_spacing;
    subckt.instances[mir_idx].y = origin_y + block.hint.v_spacing / 2;
    subckt.instances[mir_idx].flip = false;
    subckt.instances[mir_idx].rotation = 0;

    subckt.instances[fb_idx].x = origin_x + block.hint.h_spacing / 2;
    subckt.instances[fb_idx].y = origin_y - block.hint.v_spacing / 2;
    subckt.instances[fb_idx].rotation = 0;
    subckt.instances[fb_idx].flip = false;

    block.hint.h_spacing
}

fn place_widlar_mirror(
    subckt: &mut Subcircuit,
    block: &Block,
    origin_x: i32,
    origin_y: i32,
) -> i32 {
    if block.instance_indices.len() < 3 {
        return GRID_SIZE;
    }
    let ref_idx = block.instance_indices[0] as usize;
    let mir_idx = block.instance_indices[1] as usize;
    let r_idx = block.instance_indices[2] as usize;

    subckt.instances[ref_idx].x = origin_x;
    subckt.instances[ref_idx].y = origin_y;
    subckt.instances[ref_idx].flip = true;
    subckt.instances[ref_idx].rotation = 0;

    subckt.instances[mir_idx].x = origin_x + block.hint.h_spacing;
    subckt.instances[mir_idx].y = origin_y;
    subckt.instances[mir_idx].flip = false;
    subckt.instances[mir_idx].rotation = 0;

    subckt.instances[r_idx].x = origin_x + block.hint.h_spacing;
    subckt.instances[r_idx].y = origin_y + block.hint.v_spacing;
    subckt.instances[r_idx].rotation = 0;
    subckt.instances[r_idx].flip = false;

    block.hint.h_spacing
}

fn place_resistor_divider(
    subckt: &mut Subcircuit,
    block: &Block,
    origin_x: i32,
    origin_y: i32,
) -> i32 {
    if block.instance_indices.len() < 2 {
        return GRID_SIZE;
    }
    let idx0 = block.instance_indices[0] as usize;
    let idx1 = block.instance_indices[1] as usize;

    subckt.instances[idx0].x = origin_x;
    subckt.instances[idx0].y = origin_y - block.hint.v_spacing / 2;
    subckt.instances[idx0].rotation = 0;
    subckt.instances[idx0].flip = false;

    subckt.instances[idx1].x = origin_x;
    subckt.instances[idx1].y = origin_y + block.hint.v_spacing / 2;
    subckt.instances[idx1].rotation = 0;
    subckt.instances[idx1].flip = false;

    GRID_SIZE
}

fn apply_template(subckt: &mut Subcircuit, block: &Block, origin_x: i32, origin_y: i32) -> i32 {
    match block.block_type {
        BlockType::DiffPair => place_diff_pair(subckt, block, origin_x, origin_y),
        BlockType::CurrentMirror => place_current_mirror(subckt, block, origin_x, origin_y),
        BlockType::Cascode | BlockType::CascodeStack => place_cascode(subckt, block, origin_x, origin_y),
        BlockType::CascodeMirror => place_cascode_mirror(subckt, block, origin_x, origin_y),
        BlockType::PushPull => place_push_pull(subckt, block, origin_x, origin_y),
        BlockType::CommonSource => place_common_source(subckt, block, origin_x, origin_y),
        BlockType::SourceFollower => place_source_follower(subckt, block, origin_x, origin_y),
        BlockType::RcCompensation => place_rc_compensation(subckt, block, origin_x, origin_y),
        BlockType::WilsonMirror => place_wilson_mirror(subckt, block, origin_x, origin_y),
        BlockType::WidlarMirror => place_widlar_mirror(subckt, block, origin_x, origin_y),
        BlockType::ResistorDivider => place_resistor_divider(subckt, block, origin_x, origin_y),
    }
}

// --------------------------------------------------------------------------
// Public API
// --------------------------------------------------------------------------

/// Place recognized blocks using templates and grid-place the rest.
pub fn place(subckt: &mut Subcircuit, blocks: &[Block], backend: &dyn PinGeometry) {
    let mut placed: HashSet<u32> = HashSet::new();

    let block_instance_count: usize = blocks.iter().map(|b| b.instance_indices.len()).sum();
    let loose_count = subckt.instances.len() - block_instance_count.min(subckt.instances.len());
    let total_items = blocks.len() + loose_count;

    if total_items > SA_THRESHOLD {
        place_with_sa(subckt, blocks, &mut placed, 42, backend);
    } else {
        place_small(subckt, blocks, &mut placed, backend);
    }

    fix_pin_overlaps(subckt, backend);
}

fn fix_pin_overlaps(subckt: &mut Subcircuit, backend: &dyn PinGeometry) {
    let grid = 10i32;
    let max_passes = 5;
    for _ in 0..max_passes {
        let mut pin_map: HashMap<(i32, i32), Vec<(usize, usize, Option<u32>)>> = HashMap::new();
        for (i, inst) in subckt.instances.iter().enumerate() {
            for (p, pin) in inst.pins.iter().enumerate() {
                let (px, py) = crate::s2s::output::pin_position(backend, inst, p);
                pin_map.entry((px, py)).or_default().push((i, p, pin.net_idx));
            }
        }

        let mut to_shift: Option<usize> = None;
        for (_pos, pins) in &pin_map {
            if pins.len() < 2 {
                continue;
            }
            let mut nets: HashSet<u32> = HashSet::new();
            let mut inst_set: HashSet<usize> = HashSet::new();
            for &(inst_i, _, net) in pins {
                if let Some(n) = net {
                    nets.insert(n);
                }
                inst_set.insert(inst_i);
            }
            if nets.len() >= 2 && inst_set.len() >= 2 {
                let second_inst = pins.iter()
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

/// Place with simulated annealing for larger circuits.
pub fn place_with_sa(
    subckt: &mut Subcircuit,
    blocks: &[Block],
    placed: &mut HashSet<u32>,
    seed: u64,
    _backend: &dyn PinGeometry,
) {
    let constraints = generate_constraints(subckt, blocks);

    let mut items: Vec<PlacementItem> = Vec::new();

    for (bi, block) in blocks.iter().enumerate() {
        items.push(PlacementItem {
            instance_indices: block.instance_indices.clone(),
            block_type: Some(block.block_type),
            block_ref: Some(bi),
        });
        for &idx in &block.instance_indices {
            placed.insert(idx);
        }
    }

    for i in 0..subckt.instances.len() {
        if !placed.contains(&(i as u32)) {
            items.push(PlacementItem {
                instance_indices: vec![i as u32],
                block_type: None,
                block_ref: None,
            });
            placed.insert(i as u32);
        }
    }

    if items.is_empty() {
        return;
    }

    let mut state = PlacementState::new(items.len(), GRID_SIZE);
    for (i, item) in items.iter().enumerate() {
        if let Some(bt) = item.block_type {
            state.widths[i] = block_width(bt);
            state.heights[i] = block_height(bt);
        }
    }

    simulated_annealing(&mut state, &items, subckt, &constraints, seed);

    for (i, item) in items.iter().enumerate() {
        let (ox, oy) = state.positions[i];
        if let Some(block_ref) = item.block_ref {
            apply_template(subckt, &blocks[block_ref], ox, oy);
        } else {
            let inst_idx = item.instance_indices[0] as usize;
            subckt.instances[inst_idx].x = ox;
            subckt.instances[inst_idx].y = oy;
            subckt.instances[inst_idx].rotation = state.orientations[i].0;
            subckt.instances[inst_idx].flip = state.orientations[i].1;
        }
    }
}

const LOOSE_DEVICE_SIZE: i32 = 100;

#[derive(Clone, Debug)]
struct PlacedBBox {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
}

impl PlacedBBox {
    fn overlaps(&self, other: &PlacedBBox) -> bool {
        let x_overlap = self.x < other.x + other.w && other.x < self.x + self.w;
        let y_overlap = self.y < other.y + other.h && other.y < self.y + self.h;
        x_overlap && y_overlap
    }
}

fn has_collision(candidate: &PlacedBBox, occupied: &[PlacedBBox]) -> bool {
    occupied.iter().any(|b| candidate.overlaps(b))
}

fn block_y_region(block: &Block, subckt: &Subcircuit) -> i32 {
    let pmos_count = block
        .instance_indices
        .iter()
        .filter(|&&idx| subckt.instances[idx as usize].primitive == Primitive::Pmos)
        .count();
    let nmos_count = block
        .instance_indices
        .iter()
        .filter(|&&idx| subckt.instances[idx as usize].primitive == Primitive::Nmos)
        .count();
    if pmos_count > nmos_count {
        -GRID_SIZE
    } else if nmos_count > 0 {
        GRID_SIZE
    } else {
        0
    }
}

fn place_small(subckt: &mut Subcircuit, blocks: &[Block], placed: &mut HashSet<u32>, _backend: &dyn PinGeometry) {
    let mut occupied: Vec<PlacedBBox> = Vec::new();

    let has_pmos_block = blocks
        .iter()
        .any(|b| block_y_region(b, subckt) < 0);
    let has_nmos_block = blocks
        .iter()
        .any(|b| block_y_region(b, subckt) > 0);
    let multi_region = has_pmos_block && has_nmos_block;

    let loose_has_pmos = subckt.instances.iter().enumerate().any(|(i, inst)| {
        !blocks.iter().any(|b| b.instance_indices.contains(&(i as u32)))
            && inst.primitive == Primitive::Pmos
    });
    let loose_has_nmos = subckt.instances.iter().enumerate().any(|(i, inst)| {
        !blocks.iter().any(|b| b.instance_indices.contains(&(i as u32)))
            && inst.primitive == Primitive::Nmos
    });
    let multi_region = multi_region
        || (has_pmos_block && loose_has_nmos)
        || (has_nmos_block && loose_has_pmos)
        || (loose_has_pmos && loose_has_nmos);

    let mut pmos_x: i32 = 0;
    let mut nmos_x: i32 = 0;
    let mut center_x: i32 = 0;

    for block in blocks {
        let raw_region = block_y_region(block, subckt);
        let y_region = if multi_region { raw_region } else { 0 };

        let (origin_x, origin_y) = if y_region < 0 {
            let x = pmos_x;
            (x, -GRID_SIZE)
        } else if y_region > 0 {
            let x = nmos_x;
            (x, GRID_SIZE)
        } else {
            let x = center_x;
            (x, 0)
        };

        let bw = apply_template(subckt, block, origin_x, origin_y);
        let bh = block_height(block.block_type);
        for &idx in &block.instance_indices {
            placed.insert(idx);
        }
        occupied.push(PlacedBBox {
            x: origin_x,
            y: origin_y - (bh / 2),
            w: bw,
            h: bh,
        });

        if y_region < 0 {
            pmos_x += bw + 80;
        } else if y_region > 0 {
            nmos_x += bw + 80;
        } else {
            center_x += bw + 80;
        }
    }

    let block_x = pmos_x.max(nmos_x).max(center_x);

    let mut pmos_col: i32 = 0;
    let mut pmos_row: i32 = 0;
    let mut nmos_col: i32 = 0;
    let mut nmos_row: i32 = 0;
    let mut other_col: i32 = 0;
    let mut other_row: i32 = 0;

    for (i, inst) in subckt.instances.iter_mut().enumerate() {
        if placed.contains(&(i as u32)) {
            continue;
        }

        let (col, row, base_y) = if multi_region {
            match inst.primitive {
                Primitive::Pmos => (&mut pmos_col, &mut pmos_row, -GRID_SIZE),
                Primitive::Nmos => (&mut nmos_col, &mut nmos_row, GRID_SIZE),
                _ => (&mut other_col, &mut other_row, 0),
            }
        } else {
            (&mut other_col, &mut other_row, 0)
        };

        let mut candidate_x = block_x + *col * GRID_SIZE;
        let mut candidate_y = base_y - (*row * GRID_SIZE);

        let half = LOOSE_DEVICE_SIZE / 2;
        let mut candidate_bbox = PlacedBBox {
            x: candidate_x - half,
            y: candidate_y - half,
            w: LOOSE_DEVICE_SIZE,
            h: LOOSE_DEVICE_SIZE,
        };

        let max_attempts = (MAX_COLS as usize) * (MAX_COLS as usize + occupied.len() + 4);
        let mut attempts = 0;
        while has_collision(&candidate_bbox, &occupied) && attempts < max_attempts {
            *col += 1;
            if *col >= MAX_COLS {
                *col = 0;
                *row += 1;
            }
            candidate_x = block_x + *col * GRID_SIZE;
            candidate_y = base_y - (*row * GRID_SIZE);
            candidate_bbox = PlacedBBox {
                x: candidate_x - half,
                y: candidate_y - half,
                w: LOOSE_DEVICE_SIZE,
                h: LOOSE_DEVICE_SIZE,
            };
            attempts += 1;
        }

        inst.x = candidate_x;
        inst.y = candidate_y;

        occupied.push(candidate_bbox);

        *col += 1;
        if *col >= MAX_COLS {
            *col = 0;
            *row += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::s2s::ir::*;
    use crate::s2s::output::xschem::XschemBackend;
    use crate::s2s::recognition::{Block, BlockType, PlacementHint};

    fn test_backend() -> XschemBackend {
        XschemBackend::new("/tmp")
    }

    fn make_nmos(name: &str) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: Primitive::Nmos,
            symbol: "nmos4".to_string(),
            pins: vec![
                Pin { name: "D".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "G".into(), dir: PinDir::Input, net_idx: None },
                Pin { name: "S".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "B".into(), dir: PinDir::Bulk, net_idx: None },
            ],
            params: Default::default(),
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        }
    }

    fn make_pmos(name: &str) -> Instance {
        let mut inst = make_nmos(name);
        inst.primitive = Primitive::Pmos;
        inst.symbol = "pmos4".to_string();
        inst
    }

    fn make_resistor(name: &str) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: Primitive::Resistor,
            symbol: "res".to_string(),
            pins: vec![
                Pin { name: "p".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "n".into(), dir: PinDir::Inout, net_idx: None },
            ],
            params: Default::default(),
            x: 0, y: 0, rotation: 0, flip: false,
        }
    }

    fn make_capacitor(name: &str) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: Primitive::Capacitor,
            symbol: "cap".to_string(),
            pins: vec![
                Pin { name: "p".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "n".into(), dir: PinDir::Inout, net_idx: None },
            ],
            params: Default::default(),
            x: 0, y: 0, rotation: 0, flip: false,
        }
    }

    fn make_isource(name: &str) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: Primitive::Isource,
            symbol: "isource".to_string(),
            pins: vec![
                Pin { name: "p".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "n".into(), dir: PinDir::Inout, net_idx: None },
            ],
            params: Default::default(),
            x: 0, y: 0, rotation: 0, flip: false,
        }
    }

    #[test]
    fn diff_pair_template() {
        let mut subckt = Subcircuit::new("dp_test");
        subckt.instances.push(make_nmos("M1"));
        subckt.instances.push(make_nmos("M2"));

        let block = Block {
            block_type: BlockType::DiffPair,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::DiffPair),
        };
        place(&mut subckt, &[block], &test_backend());

        assert_eq!(subckt.instances[0].x, 0);
        assert_eq!(subckt.instances[0].y, 0);
        assert!(subckt.instances[0].flip);

        assert_eq!(subckt.instances[1].x, 160);
        assert_eq!(subckt.instances[1].y, 0);
        assert!(!subckt.instances[1].flip);
    }

    #[test]
    fn current_mirror_template() {
        let mut subckt = Subcircuit::new("cm_test");
        subckt.instances.push(make_nmos("Mref"));
        subckt.instances.push(make_nmos("Mmir"));

        let block = Block {
            block_type: BlockType::CurrentMirror,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::CurrentMirror),
        };
        place(&mut subckt, &[block], &test_backend());

        assert_eq!(subckt.instances[0].x, 0);
        assert_eq!(subckt.instances[0].y, 0);
        assert!(subckt.instances[0].flip);

        assert_eq!(subckt.instances[1].x, 160);
        assert_eq!(subckt.instances[1].y, 0);
        assert!(!subckt.instances[1].flip);
    }

    #[test]
    fn cascode_template() {
        let mut subckt = Subcircuit::new("cas_test");
        subckt.instances.push(make_nmos("Mbot"));
        subckt.instances.push(make_nmos("Mtop"));

        let block = Block {
            block_type: BlockType::Cascode,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::Cascode),
        };
        place(&mut subckt, &[block], &test_backend());

        assert_eq!(subckt.instances[0].x, 0);
        assert_eq!(subckt.instances[0].y, 80);
        assert_eq!(subckt.instances[1].x, 0);
        assert_eq!(subckt.instances[1].y, -80);
    }

    #[test]
    fn loose_instances_get_grid_placement() {
        let mut subckt = Subcircuit::new("grid_test");
        subckt.instances.push(make_nmos("M1"));
        subckt.instances.push(make_pmos("M2"));
        subckt.instances.push(make_resistor("R1"));

        place(&mut subckt, &[], &test_backend());

        assert_eq!(subckt.instances[0].x, 0);
        assert_eq!(subckt.instances[0].y, GRID_SIZE);
        assert_eq!(subckt.instances[1].x, 0);
        assert_eq!(subckt.instances[1].y, -GRID_SIZE);
        assert_eq!(subckt.instances[2].x, 0);
    }

    #[test]
    fn pin_position_transform() {
        let mut inst = make_nmos("M1");
        inst.x = 100;
        inst.y = 200;
        inst.rotation = 0;
        inst.flip = false;
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &inst, 0), (120, 170));
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &inst, 1), (80, 200));
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &inst, 2), (120, 230));

        inst.flip = true;
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &inst, 0), (80, 170));
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &inst, 1), (120, 200));

        inst.flip = false;
        inst.rotation = 1;
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &inst, 0), (100 + 30, 200 - 20));

        inst.rotation = 2;
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &inst, 0), (80, 230));

        let res = Instance {
            name: "R1".to_string(),
            primitive: Primitive::Resistor,
            symbol: "res".to_string(),
            pins: vec![
                Pin { name: "p".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "n".into(), dir: PinDir::Inout, net_idx: None },
            ],
            params: Default::default(),
            x: 50, y: 50, rotation: 0, flip: false,
        };
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &res, 0), (50, 20));
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &res, 1), (50, 80));
        assert_eq!(crate::s2s::output::pin_position(&test_backend(), &res, 10), (50, 50));
    }

    #[test]
    fn sa_deterministic() {
        let make = || {
            let mut subckt = Subcircuit::new("det");
            for i in 0..15 { subckt.instances.push(make_nmos(&format!("M{i}"))); }
            subckt
        };
        let blocks = vec![Block {
            block_type: BlockType::CurrentMirror,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::CurrentMirror),
        }];

        let mut subckt1 = make();
        let mut subckt2 = make();
        let mut placed1 = HashSet::new();
        let mut placed2 = HashSet::new();
        place_with_sa(&mut subckt1, &blocks, &mut placed1, 12345, &test_backend());
        place_with_sa(&mut subckt2, &blocks, &mut placed2, 12345, &test_backend());

        for (a, b) in subckt1.instances.iter().zip(subckt2.instances.iter()) {
            assert_eq!(a.x, b.x, "x mismatch for {}", a.name);
            assert_eq!(a.y, b.y, "y mismatch for {}", a.name);
        }
    }

    #[test]
    fn sa_different_seeds_differ() {
        let make = || {
            let mut subckt = Subcircuit::new("det");
            for i in 0..15 { subckt.instances.push(make_nmos(&format!("M{i}"))); }
            subckt
        };
        let blocks = vec![Block {
            block_type: BlockType::CurrentMirror,
            instance_indices: vec![0, 1],
            hint: PlacementHint::for_type(BlockType::CurrentMirror),
        }];

        let mut subckt1 = make();
        let mut subckt2 = make();
        let mut placed1 = HashSet::new();
        let mut placed2 = HashSet::new();
        place_with_sa(&mut subckt1, &blocks, &mut placed1, 12345, &test_backend());
        place_with_sa(&mut subckt2, &blocks, &mut placed2, 99999, &test_backend());

        let any_differ = subckt1.instances.iter().zip(subckt2.instances.iter())
            .any(|(a, b)| a.x != b.x || a.y != b.y);
        assert!(any_differ, "different seeds should produce different placements");
    }
}
