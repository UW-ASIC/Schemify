use std::collections::HashMap;

use lasso::Rodeo;

use schemify_core::primitives;
use schemify_core::schematic::Schematic;
use schemify_core::types::{Connectivity, Net, NetConnKind, NetEndpoint, PinConnection};

/// Pure function: resolve connectivity from schematic data.
/// Pre-computes nets, point-to-net map, per-instance connections, net names.
pub fn resolve(sch: &Schematic, interner: &Rodeo) -> Connectivity {
    let wires = &sch.wires;
    let instances = &sch.instances;

    if wires.is_empty() && instances.is_empty() {
        return Connectivity::default();
    }

    let mut uf = UnionFind::new();

    // Step 1: Connect each wire's two endpoints
    for i in 0..wires.len() {
        let p0 = (wires.x0[i], wires.y0[i]);
        let p1 = (wires.x1[i], wires.y1[i]);
        uf.make_set(p0);
        uf.make_set(p1);
        uf.unite(p0, p1);
    }

    // Step 2: T-junction detection — wire endpoint touching interior of another wire
    for i in 0..wires.len() {
        for pt in [(wires.x0[i], wires.y0[i]), (wires.x1[i], wires.y1[i])] {
            for j in 0..wires.len() {
                if j == i || wires.bus[j] {
                    continue;
                }
                // Don't merge wires with different explicit net names
                let ni = interner.resolve(&wires.net_name[i]);
                let nj = interner.resolve(&wires.net_name[j]);
                if !ni.is_empty() && !nj.is_empty() && ni != nj {
                    continue;
                }
                if on_wire_interior(pt, (wires.x0[j], wires.y0[j]), (wires.x1[j], wires.y1[j])) {
                    uf.unite(pt, (wires.x0[j], wires.y0[j]));
                }
            }
        }
    }

    // Step 3: Instance pin positions — merge with touching wires
    for i in 0..instances.len() {
        let kind = instances.kind[i];
        let prim = match primitives::find_by_kind(kind) {
            Some(p) if !p.pin_positions.is_empty() => p,
            _ => continue,
        };

        let flags = instances.flags[i];
        let inst_x = instances.x[i];
        let inst_y = instances.y[i];

        for pin in &prim.pin_positions {
            let (tx, ty) = flags.transform_point(pin.x as i32, pin.y as i32);
            let abs = (inst_x + tx, inst_y + ty);
            uf.make_set(abs);

            // Find first touching wire, check for contested point
            let mut first_wire: Option<usize> = None;
            let mut first_net = "";
            let mut contested = false;

            for wi in 0..wires.len() {
                let w0 = (wires.x0[wi], wires.y0[wi]);
                let w1 = (wires.x1[wi], wires.y1[wi]);
                let touches = abs == w0 || abs == w1 || on_wire_interior(abs, w0, w1);
                if touches {
                    let wn = interner.resolve(&wires.net_name[wi]);
                    if first_wire.is_none() {
                        first_wire = Some(wi);
                        first_net = wn;
                    } else if !wn.is_empty() && !first_net.is_empty() && wn != first_net {
                        contested = true;
                        break;
                    }
                }
            }

            if !contested {
                if let Some(wi) = first_wire {
                    uf.unite(abs, (wires.x0[wi], wires.y0[wi]));
                }
            }
        }
    }

    // Step 4: Collect root -> name from wire net_name annotations
    let mut root_names: Vec<((i32, i32), String)> = Vec::new();

    for i in 0..wires.len() {
        let name = interner.resolve(&wires.net_name[i]);
        if name.is_empty() {
            continue;
        }
        let k = (wires.x0[i], wires.y0[i]);
        uf.make_set(k);
        let root = uf.find(k);
        upsert_root_name(&mut root_names, root, name);
    }

    // Collect net names from label pins and power instances
    for i in 0..instances.len() {
        let kind = instances.kind[i];
        let name_str: String = if kind.is_label() {
            interner.resolve(&instances.name[i]).to_owned()
        } else if kind.is_power() {
            // Check for explicit "net" property (set by SPICE import to preserve
            // the original net name). Fall back to injected_net() for manually
            // placed power symbols.
            let ps = instances.prop_start[i] as usize;
            let pc = instances.prop_count[i] as usize;
            let net_prop = sch.properties[ps..ps + pc]
                .iter()
                .find(|p| interner.resolve(&p.key) == "net");
            if let Some(prop) = net_prop {
                interner.resolve(&prop.value).to_owned()
            } else {
                kind.injected_net().unwrap_or("0").to_owned()
            }
        } else {
            continue;
        };

        let prim = match primitives::find_by_kind(kind) {
            Some(p) if !p.pin_positions.is_empty() => p,
            _ => continue,
        };

        let flags = instances.flags[i];
        let (tx, ty) = flags.transform_point(
            prim.pin_positions[0].x as i32,
            prim.pin_positions[0].y as i32,
        );
        let abs = (instances.x[i] + tx, instances.y[i] + ty);
        uf.make_set(abs);
        let root = uf.find(abs);
        upsert_root_name(&mut root_names, root, &name_str);
    }

    // Auto-name unnamed nets: find highest existing auto index
    let mut auto_idx: u32 = 1;
    for (_, name) in &root_names {
        if let Some(n) = parse_auto_net_idx(name) {
            if n >= auto_idx {
                auto_idx = n + 1;
            }
        }
    }

    // Assign auto names to unnamed roots
    for i in 0..wires.len() {
        for k in [(wires.x0[i], wires.y0[i]), (wires.x1[i], wires.y1[i])] {
            let root = uf.find(k);
            if !root_names.iter().any(|(r, _)| *r == root) {
                root_names.push((root, format!("net{auto_idx}")));
                auto_idx += 1;
            }
        }
    }

    // Build net list with indices
    let mut root_to_id: HashMap<(i32, i32), usize> = HashMap::new();
    let mut nets: Vec<Net> = Vec::with_capacity(root_names.len());
    let mut net_names: Vec<String> = Vec::with_capacity(root_names.len());

    for (root, name) in &root_names {
        let id = nets.len();
        net_names.push(name.clone());
        nets.push(Net {
            name: name.clone(),
            connections: Vec::new(),
        });
        root_to_id.insert(*root, id);
    }

    // Wire endpoint connections + point_to_net
    let mut point_to_net: HashMap<(i32, i32), usize> = HashMap::new();

    for i in 0..wires.len() {
        for (ep_x, ep_y) in [(wires.x0[i], wires.y0[i]), (wires.x1[i], wires.y1[i])] {
            let root = uf.find((ep_x, ep_y));
            if let Some(&nid) = root_to_id.get(&root) {
                point_to_net.insert((ep_x, ep_y), nid);
                nets[nid].connections.push(NetEndpoint {
                    x: ep_x,
                    y: ep_y,
                    kind: NetConnKind::WireEndpoint { wire_idx: i },
                });
            }
        }
    }

    // Instance connections
    let mut instance_connections: Vec<Vec<PinConnection>> = vec![Vec::new(); instances.len()];

    #[allow(clippy::needless_range_loop)] // indexes multiple SoA parallel arrays
    for i in 0..instances.len() {
        let kind = instances.kind[i];
        let prim = match primitives::find_by_kind(kind) {
            Some(p) if !p.pin_positions.is_empty() => p,
            _ => continue,
        };

        let flags = instances.flags[i];
        let inst_x = instances.x[i];
        let inst_y = instances.y[i];

        for pin in &prim.pin_positions {
            let (tx, ty) = flags.transform_point(pin.x as i32, pin.y as i32);
            let abs = (inst_x + tx, inst_y + ty);
            let root = uf.find(abs);
            let net_idx = root_to_id.get(&root).copied().unwrap_or(usize::MAX);

            instance_connections[i].push(PinConnection {
                pin_name: pin.name.to_owned(),
                net_idx,
                x: abs.0,
                y: abs.1,
            });

            if net_idx != usize::MAX {
                point_to_net.insert(abs, net_idx);
                nets[net_idx].connections.push(NetEndpoint {
                    x: abs.0,
                    y: abs.1,
                    kind: NetConnKind::InstancePin {
                        instance_idx: i,
                        pin_name: pin.name.to_owned(),
                    },
                });
            }
        }
    }

    // Label connections (for display)
    for i in 0..instances.len() {
        let kind = instances.kind[i];
        if !kind.is_label() {
            continue;
        }
        let label_name = interner.resolve(&instances.name[i]);
        if label_name.is_empty() {
            continue;
        }

        let prim = match primitives::find_by_kind(kind) {
            Some(p) if !p.pin_positions.is_empty() => p,
            _ => continue,
        };

        let flags = instances.flags[i];
        let (tx, ty) = flags.transform_point(
            prim.pin_positions[0].x as i32,
            prim.pin_positions[0].y as i32,
        );
        let abs = (instances.x[i] + tx, instances.y[i] + ty);
        let root = uf.find(abs);

        if let Some(&nid) = root_to_id.get(&root) {
            nets[nid].connections.push(NetEndpoint {
                x: abs.0,
                y: abs.1,
                kind: NetConnKind::Label {
                    name: label_name.to_owned(),
                },
            });
        }
    }

    Connectivity {
        nets,
        point_to_net,
        instance_connections,
        net_names,
    }
}

// ── Union-find with path compression + union by rank ──

struct UnionFind {
    parent: HashMap<(i32, i32), (i32, i32)>,
    rank: HashMap<(i32, i32), u8>,
}

impl UnionFind {
    fn new() -> Self {
        Self {
            parent: HashMap::new(),
            rank: HashMap::new(),
        }
    }

    fn make_set(&mut self, k: (i32, i32)) {
        self.parent.entry(k).or_insert(k);
        self.rank.entry(k).or_insert(0);
    }

    fn find(&mut self, k: (i32, i32)) -> (i32, i32) {
        let mut cur = k;
        loop {
            match self.parent.get(&cur).copied() {
                Some(parent) if parent != cur => cur = parent,
                _ => break,
            }
        }
        let root = cur;
        // Path compression
        cur = k;
        while cur != root {
            let parent = self.parent.insert(cur, root).unwrap_or(cur);
            cur = parent;
        }
        root
    }

    fn unite(&mut self, x: (i32, i32), y: (i32, i32)) {
        let rx = self.find(x);
        let ry = self.find(y);
        if rx == ry {
            return;
        }
        let rank_x = self.rank.get(&rx).copied().unwrap_or(0);
        let rank_y = self.rank.get(&ry).copied().unwrap_or(0);
        if rank_x < rank_y {
            self.parent.insert(rx, ry);
        } else if rank_x > rank_y {
            self.parent.insert(ry, rx);
        } else {
            self.parent.insert(ry, rx);
            *self.rank.entry(rx).or_insert(0) += 1;
        }
    }
}

// ── Helpers ──

fn on_wire_interior(pt: (i32, i32), w0: (i32, i32), w1: (i32, i32)) -> bool {
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

fn upsert_root_name(root_names: &mut Vec<((i32, i32), String)>, root: (i32, i32), name: &str) {
    if let Some(existing) = root_names.iter_mut().find(|(r, _)| *r == root) {
        if net_name_rank(name) > net_name_rank(&existing.1) {
            existing.1 = name.to_owned();
        }
    } else {
        root_names.push((root, name.to_owned()));
    }
}

fn is_auto_net_name(name: &str) -> bool {
    name.len() > 3 && name.starts_with("net") && name.as_bytes()[3].is_ascii_digit()
}

fn parse_auto_net_idx(name: &str) -> Option<u32> {
    if is_auto_net_name(name) {
        name[3..].parse().ok()
    } else {
        None
    }
}

fn net_name_rank(name: &str) -> u8 {
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

// ── Tests ──

#[cfg(test)]
mod tests {
    use lasso::Rodeo;
    use schemify_core::schematic::{Schematic, Wire};
    use schemify_core::types::{Color, InstanceFlags};

    use super::*;

    fn empty_wire(x0: i32, y0: i32, x1: i32, y1: i32, interner: &mut Rodeo) -> Wire {
        Wire {
            net_name: interner.get_or_intern(""),
            x0,
            y0,
            x1,
            y1,
            color: Color::NONE,
            thickness: 1,
            bus: false,
        }
    }

    fn named_wire(x0: i32, y0: i32, x1: i32, y1: i32, name: &str, interner: &mut Rodeo) -> Wire {
        Wire {
            net_name: interner.get_or_intern(name),
            x0,
            y0,
            x1,
            y1,
            color: Color::NONE,
            thickness: 1,
            bus: false,
        }
    }

    #[test]
    fn empty_schematic() {
        let interner = Rodeo::default();
        let sch = Schematic::default();
        let c = resolve(&sch, &interner);
        assert!(c.nets.is_empty());
        assert!(c.point_to_net.is_empty());
        assert!(c.instance_connections.is_empty());
    }

    #[test]
    fn simple_two_wire_net() {
        let mut interner = Rodeo::default();
        let mut sch = Schematic::default();
        // Wire 0: (0,0) -> (100,0)
        // Wire 1: (100,0) -> (200,0) — shared endpoint
        let w0 = empty_wire(0, 0, 100, 0, &mut interner);
        let w1 = empty_wire(100, 0, 200, 0, &mut interner);
        sch.wires.push(w0);
        sch.wires.push(w1);

        let c = resolve(&sch, &interner);

        // Shared endpoint -> one net
        assert_eq!(c.nets.len(), 1);
        assert_eq!(c.net_names.len(), 1);
        // All 3 unique points map to net 0
        assert_eq!(c.point_to_net.get(&(0, 0)), Some(&0));
        assert_eq!(c.point_to_net.get(&(100, 0)), Some(&0));
        assert_eq!(c.point_to_net.get(&(200, 0)), Some(&0));
    }

    #[test]
    fn t_junction_merge() {
        let mut interner = Rodeo::default();
        let mut sch = Schematic::default();
        // Horizontal: (0,0) -> (200,0)
        // Vertical endpoint at (100,0) touches interior
        let w0 = empty_wire(0, 0, 200, 0, &mut interner);
        let w1 = empty_wire(100, -50, 100, 0, &mut interner);
        sch.wires.push(w0);
        sch.wires.push(w1);

        let c = resolve(&sch, &interner);

        // T-junction merges into single net
        assert_eq!(c.nets.len(), 1);
    }

    #[test]
    fn labeled_net_overrides_auto() {
        let mut interner = Rodeo::default();
        let mut sch = Schematic::default();
        // Named wire + unnamed wire sharing endpoint
        let w0 = named_wire(0, 0, 100, 0, "VDD", &mut interner);
        let w1 = empty_wire(100, 0, 200, 0, &mut interner);
        sch.wires.push(w0);
        sch.wires.push(w1);

        let c = resolve(&sch, &interner);

        assert_eq!(c.nets.len(), 1);
        assert_eq!(c.nets[0].name, "VDD");
        assert_eq!(c.net_names[0], "VDD");
    }

    #[test]
    fn two_separate_nets() {
        let mut interner = Rodeo::default();
        let mut sch = Schematic::default();
        // Two disconnected wires
        let w0 = empty_wire(0, 0, 100, 0, &mut interner);
        let w1 = empty_wire(300, 0, 400, 0, &mut interner);
        sch.wires.push(w0);
        sch.wires.push(w1);

        let c = resolve(&sch, &interner);

        assert_eq!(c.nets.len(), 2);
    }

    #[test]
    fn transform_point_no_rotation_no_flip() {
        let flags = InstanceFlags::new(0, false, false);
        assert_eq!(flags.transform_point(10, 20), (10, 20));
    }

    #[test]
    fn transform_point_rotation_1() {
        let flags = InstanceFlags::new(1, false, false);
        assert_eq!(flags.transform_point(10, 20), (-20, 10));
    }

    #[test]
    fn transform_point_rotation_2() {
        let flags = InstanceFlags::new(2, false, false);
        assert_eq!(flags.transform_point(10, 20), (-10, -20));
    }

    #[test]
    fn transform_point_rotation_3() {
        let flags = InstanceFlags::new(3, false, false);
        assert_eq!(flags.transform_point(10, 20), (20, -10));
    }

    #[test]
    fn transform_point_flip_no_rotation() {
        let flags = InstanceFlags::new(0, true, false);
        assert_eq!(flags.transform_point(10, 20), (-10, 20));
    }

    #[test]
    fn transform_point_flip_with_rotation_1() {
        // flip first: (-10, 20), then rot 1: (-20, -10)
        let flags = InstanceFlags::new(1, true, false);
        assert_eq!(flags.transform_point(10, 20), (-20, -10));
    }

    #[test]
    fn net_naming_helpers() {
        assert!(is_auto_net_name("net1"));
        assert!(is_auto_net_name("net42"));
        assert!(!is_auto_net_name("VDD"));
        assert!(!is_auto_net_name("net"));
        assert!(!is_auto_net_name("ne"));

        assert_eq!(net_name_rank(""), 0);
        assert_eq!(net_name_rank("net1"), 1);
        assert_eq!(net_name_rank("0"), 2);
        assert_eq!(net_name_rank("VDD"), 3);
    }
}
