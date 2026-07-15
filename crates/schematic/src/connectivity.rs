//! Union-find connectivity resolution: wires + labels + buses -> nets.


use lasso::Rodeo;
use rustc_hash::FxHashMap;

use crate::{Connectivity, DeviceKind, PinConnection, Schematic, Sym, WireVec};


/// Resolve connectivity from schematic data: per-instance pin connections,
/// resolved net names, label conflicts.
pub fn resolve_connectivity(sch: &Schematic, interner: &Rodeo) -> Connectivity {
    let wires = &sch.wires;
    let instances = &sch.instances;

    if wires.is_empty() && instances.is_empty() {
        return Connectivity::default();
    }

    let mut uf = UnionFind::new();

    // Step 1: connect each wire's two endpoints.
    for i in 0..wires.len() {
        let p0 = (wires.x0[i], wires.y0[i]);
        let p1 = (wires.x1[i], wires.y1[i]);
        uf.make_set(p0);
        uf.make_set(p1);
        uf.unite(p0, p1);
    }

    // Step 1b: bus expansion — synthetic net points for each bus bit.
    if !sch.buses.is_empty() {
        expand_buses(sch, &mut uf);
    }

    // Step 2: T-junction detection — wire endpoint touching the interior of
    // another wire. Spatial index avoids the O(W²) pairwise comparison.
    let wire_idx = WireIndex::build(wires);
    for i in 0..wires.len() {
        for pt in [(wires.x0[i], wires.y0[i]), (wires.x1[i], wires.y1[i])] {
            for j in wire_idx.find_interior_hits(pt.0, pt.1) {
                if j == i {
                    continue;
                }
                uf.unite(pt, (wires.x0[j], wires.y0[j]));
            }
        }
    }

    // Step 3: instance pin positions — merge with touching wires.
    for i in 0..instances.len() {
        let kind = instances.kind[i];
        let entry = match crate::find_symbol(interner.resolve(&instances.symbol[i]), kind) {
            Some(p) if !p.pin_positions.is_empty() => p,
            _ => continue,
        };

        let flags = instances.flags[i];
        let inst_x = instances.x[i];
        let inst_y = instances.y[i];

        for pin in &entry.pin_positions {
            let (tx, ty) = flags.transform_point(pin.x as i32, pin.y as i32);
            let abs = (inst_x + tx, inst_y + ty);
            uf.make_set(abs);

            for wi in 0..wires.len() {
                let w0 = (wires.x0[wi], wires.y0[wi]);
                let w1 = (wires.x1[wi], wires.y1[wi]);
                if abs == w0 || abs == w1 || on_wire_interior(abs, w0, w1) {
                    uf.unite(abs, w0);
                    break;
                }
            }
        }
    }

    // Step 4: collect net names from label pins and power instances; track
    // LabPin instances per root for conflict detection. root_names keeps
    // insertion order (net ids must be stable across resolves); root_to_id
    // provides O(1) root -> position lookup and doubles as the net-id map.
    let mut root_names: Vec<(u32, String)> = Vec::new();
    let mut root_to_id: FxHashMap<u32, usize> = FxHashMap::default();
    let mut labpin_per_root: FxHashMap<u32, Vec<(usize, Sym)>> = FxHashMap::default();

    for i in 0..instances.len() {
        let kind = instances.kind[i];
        // Borrow from the interner; allocate only if the name is stored.
        let name_str: &str = if kind.is_label() {
            interner.resolve(&instances.name[i])
        } else if kind.is_power() {
            let net_prop = sch
                .instance_props(i)
                .iter()
                .find(|p| interner.resolve(&p.key) == "net");
            match net_prop {
                Some(p) => interner.resolve(&p.value),
                None => kind.injected_net().unwrap_or("0"),
            }
        } else {
            continue;
        };

        let entry = match crate::find_symbol(interner.resolve(&instances.symbol[i]), kind) {
            Some(p) if !p.pin_positions.is_empty() => p,
            _ => continue,
        };

        let flags = instances.flags[i];
        let (tx, ty) = flags.transform_point(
            entry.pin_positions[0].x as i32,
            entry.pin_positions[0].y as i32,
        );
        let abs = (instances.x[i] + tx, instances.y[i] + ty);
        let root = uf.find(abs);
        upsert_root_name(&mut root_names, &mut root_to_id, root, name_str);

        if kind == DeviceKind::LabPin {
            // The label name is already interned on the instance; carry the
            // Sym instead of cloning the resolved string.
            labpin_per_root
                .entry(root)
                .or_default()
                .push((i, instances.name[i]));
        }
    }

    // Named wires name their net too (precedence arbitrated by net_name_rank,
    // same as labels).
    for i in 0..wires.len() {
        if let Some(sym) = wires.net_name[i] {
            let name = interner.resolve(&sym);
            if !name.is_empty() {
                let root = uf.find((wires.x0[i], wires.y0[i]));
                upsert_root_name(&mut root_names, &mut root_to_id, root, name);
            }
        }
    }

    // Detect conflicting LabPins: same root, different names.
    let mut label_conflicts: std::collections::HashSet<usize> = Default::default();
    for entries in labpin_per_root.values() {
        if entries.len() < 2 {
            continue;
        }
        // Sym equality == string equality (single interner).
        let first_name = entries[0].1;
        if entries.iter().any(|&(_, n)| n != first_name) {
            for (idx, _) in entries {
                label_conflicts.insert(*idx);
            }
        }
    }

    // Auto-name unnamed nets: find the highest existing auto index.
    let mut auto_idx: u32 = 1;
    for (_, name) in &root_names {
        if let Some(n) = parse_auto_net_idx(name) {
            if n >= auto_idx {
                auto_idx = n + 1;
            }
        }
    }

    // Assign auto names to unnamed roots.
    for i in 0..wires.len() {
        for k in [(wires.x0[i], wires.y0[i]), (wires.x1[i], wires.y1[i])] {
            let root = uf.find(k);
            if let std::collections::hash_map::Entry::Vacant(e) = root_to_id.entry(root) {
                e.insert(root_names.len());
                root_names.push((root, format!("net{auto_idx}")));
                auto_idx += 1;
            }
        }
    }

    // root_to_id already maps each root to its position in root_names —
    // exactly the net id. Names move out of root_names into net_names.
    let net_names: Vec<String> = root_names.into_iter().map(|(_, name)| name).collect();

    // Instance connections.
    let mut instance_connections: Vec<Vec<PinConnection>> = vec![Vec::new(); instances.len()];

    #[allow(clippy::needless_range_loop)] // indexes multiple SoA parallel arrays
    for i in 0..instances.len() {
        let kind = instances.kind[i];
        let entry = match crate::find_symbol(interner.resolve(&instances.symbol[i]), kind) {
            Some(p) if !p.pin_positions.is_empty() => p,
            _ => continue,
        };

        let flags = instances.flags[i];
        let inst_x = instances.x[i];
        let inst_y = instances.y[i];

        instance_connections[i].reserve(entry.pin_positions.len());
        for pin in &entry.pin_positions {
            let (tx, ty) = flags.transform_point(pin.x as i32, pin.y as i32);
            let abs = (inst_x + tx, inst_y + ty);
            let root = uf.find(abs);

            instance_connections[i].push(PinConnection {
                pin_name: pin.name,
                net_idx: root_to_id.get(&root).map(|&id| id as u32),
                x: abs.0,
                y: abs.1,
            });
        }
    }

    Connectivity {
        instance_connections,
        net_names,
        label_conflicts,
    }
}

// ── Union-find with path compression + union by rank ──
//
// Points are interned once into dense u32 indices; parent/rank live in flat
// Vecs so find/unite are array walks (one hash lookup per point, not per hop).

pub(crate) struct UnionFind {
    idx: FxHashMap<(i32, i32), u32>,
    parent: Vec<u32>,
    rank: Vec<u8>,
}

impl UnionFind {
    pub(crate) fn new() -> Self {
        Self {
            idx: FxHashMap::default(),
            parent: Vec::new(),
            rank: Vec::new(),
        }
    }

    /// Intern a point, returning its dense index.
    pub(crate) fn make_set(&mut self, k: (i32, i32)) -> u32 {
        match self.idx.entry(k) {
            std::collections::hash_map::Entry::Occupied(e) => *e.get(),
            std::collections::hash_map::Entry::Vacant(e) => {
                let i = self.parent.len() as u32;
                e.insert(i);
                self.parent.push(i);
                self.rank.push(0);
                i
            }
        }
    }

    /// Root index of the point's set. Interns the point if unseen.
    pub(crate) fn find(&mut self, k: (i32, i32)) -> u32 {
        let i = self.make_set(k);
        self.find_idx(i)
    }

    pub(crate) fn find_idx(&mut self, start: u32) -> u32 {
        let mut root = start;
        while self.parent[root as usize] != root {
            root = self.parent[root as usize];
        }
        // Path compression
        let mut cur = start;
        while cur != root {
            let next = self.parent[cur as usize];
            self.parent[cur as usize] = root;
            cur = next;
        }
        root
    }

    pub(crate) fn unite(&mut self, x: (i32, i32), y: (i32, i32)) {
        let rx = self.find(x);
        let ry = self.find(y);
        if rx == ry {
            return;
        }
        let (rx, ry) = (rx as usize, ry as usize);
        if self.rank[rx] < self.rank[ry] {
            self.parent[rx] = ry as u32;
        } else if self.rank[rx] > self.rank[ry] {
            self.parent[ry] = rx as u32;
        } else {
            self.parent[ry] = rx as u32;
            self.rank[rx] += 1;
        }
    }
}

// ── Spatial index for T-junction detection ──

pub(crate) struct WireIndex {
    /// y -> (wire_idx, x_min, x_max) for horizontal wires
    horiz: FxHashMap<i32, Vec<(usize, i32, i32)>>,
    /// x -> (wire_idx, y_min, y_max) for vertical wires
    vert: FxHashMap<i32, Vec<(usize, i32, i32)>>,
}

impl WireIndex {
    pub(crate) fn build(wires: &WireVec) -> Self {
        let mut horiz: FxHashMap<i32, Vec<(usize, i32, i32)>> = FxHashMap::default();
        let mut vert: FxHashMap<i32, Vec<(usize, i32, i32)>> = FxHashMap::default();

        for i in 0..wires.len() {
            let (x0, y0, x1, y1) = (wires.x0[i], wires.y0[i], wires.x1[i], wires.y1[i]);
            if y0 == y1 {
                horiz
                    .entry(y0)
                    .or_default()
                    .push((i, x0.min(x1), x0.max(x1)));
            } else if x0 == x1 {
                vert.entry(x0)
                    .or_default()
                    .push((i, y0.min(y1), y0.max(y1)));
            }
            // Diagonal wires (rare) are ignored — they cannot form
            // axis-aligned T-junctions anyway.
        }

        Self { horiz, vert }
    }

    /// Indices of wires whose *interior* contains the point (px, py).
    pub(crate) fn find_interior_hits(&self, px: i32, py: i32) -> Vec<usize> {
        let mut hits = Vec::new();
        if let Some(segs) = self.horiz.get(&py) {
            for &(idx, min_x, max_x) in segs {
                if min_x < px && px < max_x {
                    hits.push(idx);
                }
            }
        }
        if let Some(segs) = self.vert.get(&px) {
            for &(idx, min_y, max_y) in segs {
                if min_y < py && py < max_y {
                    hits.push(idx);
                }
            }
        }
        hits
    }
}

// ── Bus expansion ──

/// Expand buses into synthetic net points and connect rippers.
///
/// Each bus bit gets a synthetic coordinate at `(i32::MIN/2 + bus_idx, bit)`
/// to avoid collisions with real schematic coordinates. Rippers connect
/// their physical (x, y) position to the synthetic point of their bus bit.
pub(crate) fn expand_buses(sch: &Schematic, uf: &mut UnionFind) {
    const BASE_X: i32 = i32::MIN / 2;
    let buses = &sch.buses;

    for bus_i in 0..buses.len() {
        let width = buses.width[bus_i];
        let start = buses.start_bit[bus_i];
        for bit in start..start + width {
            uf.make_set((BASE_X + bus_i as i32, bit as i32));
        }
    }

    for rip in &sch.bus_rippers {
        let bus_i = rip.bus_idx as usize;
        if bus_i >= buses.len() {
            continue;
        }
        let synthetic = (BASE_X + bus_i as i32, rip.bit as i32);
        let physical = (rip.x, rip.y);
        uf.make_set(physical);
        uf.unite(physical, synthetic);
    }
}

// ── Connectivity helpers ──

pub(crate) fn on_wire_interior(pt: (i32, i32), w0: (i32, i32), w1: (i32, i32)) -> bool {
    if w0.1 == w1.1 && pt.1 == w0.1 {
        // Horizontal wire
        let (min_x, max_x) = (w0.0.min(w1.0), w0.0.max(w1.0));
        min_x < pt.0 && pt.0 < max_x
    } else if w0.0 == w1.0 && pt.0 == w0.0 {
        // Vertical wire
        let (min_y, max_y) = (w0.1.min(w1.1), w0.1.max(w1.1));
        min_y < pt.1 && pt.1 < max_y
    } else {
        false
    }
}

pub(crate) fn upsert_root_name(
    root_names: &mut Vec<(u32, String)>,
    root_to_id: &mut FxHashMap<u32, usize>,
    root: u32,
    name: &str,
) {
    match root_to_id.entry(root) {
        std::collections::hash_map::Entry::Occupied(e) => {
            let existing = &mut root_names[*e.get()];
            if net_name_rank(name) > net_name_rank(&existing.1) {
                existing.1 = name.to_owned();
            }
        }
        std::collections::hash_map::Entry::Vacant(e) => {
            e.insert(root_names.len());
            root_names.push((root, name.to_owned()));
        }
    }
}

pub(crate) fn is_auto_net_name(name: &str) -> bool {
    name.len() > 3 && name.starts_with("net") && name.as_bytes()[3].is_ascii_digit()
}

pub(crate) fn parse_auto_net_idx(name: &str) -> Option<u32> {
    if is_auto_net_name(name) {
        name[3..].parse().ok()
    } else {
        None
    }
}

/// Priority when several names land on one net: user names > "0" > auto > empty.
pub(crate) fn net_name_rank(name: &str) -> u8 {
    if name.is_empty() {
        return 0;
    }
    if is_auto_net_name(name) {
        return 1;
    }
    if name == "0" {
        return 2;
    }
    3
}

// ════════════════════════════════════════════════════════════
// Netlist — Schematic + Connectivity -> crate::sim CircuitIR
// ════════════════════════════════════════════════════════════


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn net_naming_helpers() {
        assert!(is_auto_net_name("net1"));
        assert!(is_auto_net_name("net42"));
        assert!(!is_auto_net_name("VDD"));
        assert!(!is_auto_net_name("net"));

        assert_eq!(net_name_rank(""), 0);
        assert_eq!(net_name_rank("net1"), 1);
        assert_eq!(net_name_rank("0"), 2);
        assert_eq!(net_name_rank("VDD"), 3);
    }

    #[test]
    fn named_wire_names_its_net() {
        let mut interner = Rodeo::default();
        let mut sch = Schematic::default();
        sch.wires.push(crate::Wire {
            net_name: Some(interner.get_or_intern("VOUT")),
            x0: 0,
            y0: 0,
            x1: 100,
            y1: 0,
            color: crate::Color::NONE,
            thickness: 0,
        });
        let conn = resolve_connectivity(&sch, &interner);
        assert_eq!(conn.net_names, vec!["VOUT"]);
    }
}
