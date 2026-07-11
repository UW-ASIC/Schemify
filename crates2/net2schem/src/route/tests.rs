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
    let strategies = classify_nets(&by_name, &TestGeo);
    assert_eq!(strategies[0], NetStrategy::Label, "VDD by name -> Label");

    let mut by_class = fanout_subckt("rail", 2, 100);
    by_class.nets[0].classification = NetClass::Ground;
    let strategies = classify_nets(&by_class, &TestGeo);
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
    let strategies = classify_nets(&subckt, &TestGeo);
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
