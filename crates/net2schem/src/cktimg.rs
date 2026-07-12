//! cktImg front-end: parse, place, AND route via the `cktimg` library.
//!
//! Schemify's pin geometry is installed into cktimg once per process
//! (`install_geometry`): anchor overrides carry the exact symbol pin offsets
//! (rotated by M(x,y)=(-y,x) into cktimg's canonical convention — plus an
//! axis-centering translation for 3-terminal families, see [`m`] — so its
//! orientation heuristics and conduction-axis alignment keep working), and
//! the layout config pins device origins to Schemify's 10-unit grid. cktimg's router upholds the
//! host-geometry contract (no wire through a foreign pin, no geometric
//! shorts — see cktImg tests/host_geometry.rs), so its wires/labels convert
//! 1:1; the per-device (rotation, mirror) is recovered exactly by
//! `fit_orientation` because M and every cktimg orientation compose to one
//! of Schemify's eight instance transforms.
//!
//! Host components with runtime pin lists (project symbols, testbench DUTs)
//! register as cktimg host classes via [`netlist_to_circuit_with`]; their
//! `X` masters then place as box devices instead of being skipped.
//!
//! cktimg flattens `.subckt`s with definitions, so the result is a single
//! top-level schematic.

use std::cell::RefCell;
use std::sync::OnceLock;

use ::cktimg::devices::{self, class_at, HostClass, SymbolRole, TerminalRole};
use ::cktimg::ir::NetIdx;
use ::cktimg::{config, Ir, Strings};

use crate::emit::{pin_offsets, subckt_box_pin_offset};
use crate::ir::{
    Circuit, InstId, Instance, InstanceFlags, Label, Net, NetClass, NetId, Pin, PinDir, PinIdx,
    PinRef, Primitive, Subcircuit, Wire, primitive_sym,
};

/// Schemify canonical → cktimg canonical for 3-terminal families:
/// M(x,y) = (-y, x) rotates the vertical channel (drain top, source bottom,
/// gate left) onto cktimg's horizontal one (drain right, source left, gate
/// below), then translates by (0, -20) so the conducting pair lands ON the
/// conduction axis through the origin — cktimg's layout invariant ("a
/// resistor's pins line up with a MOSFET's drain/source", devices CLASSES
/// doc). Schemify's channel is offset 20 right of the symbol origin; without
/// the translation every MOS/BJT sat 20 off-axis against every bipole,
/// jogging wires and failing strict-mode pin coverage (nets stripped to
/// labels). The rotation stays orthogonal and the translation is constant,
/// so `fit_orientation` recovers (flags, origin) exactly.
fn m(off: (i32, i32)) -> devices::Pt {
    devices::Pt { x: -off.1, y: off.0 - 20 }
}

/// Bipoles rotate the OTHER way: Schemify's first pin is at the top, but
/// cktimg's two-terminal convention is first pin LEFT (`a=(-20,0)`) with
/// signal flowing left→right. M2(x,y) = (y, -x) maps top→left. Installing
/// bipoles with `m` instead put pin0 on the right, so cktimg's orientation
/// heuristics faced connected pins away from each other and fell back to
/// net labels where a straight wire should exist.
fn m2(off: (i32, i32)) -> devices::Pt {
    devices::Pt { x: off.1, y: -off.0 }
}

/// Install Schemify pin anchors + 10-grid layout into cktimg, once per
/// process (cktimg geometry must not change mid-run).
fn install_geometry() {
    static ONCE: OnceLock<()> = OnceLock::new();
    ONCE.get_or_init(|| {
        let take = |p: Primitive, n: usize, f: fn((i32, i32)) -> devices::Pt| -> &'static [devices::Pt] {
            Box::leak(
                pin_offsets(p)[..n]
                    .iter()
                    .map(|&o| f(o))
                    .collect::<Vec<_>>()
                    .into_boxed_slice(),
            )
        };
        let nmos = take(Primitive::Nmos, 3, m); // cktimg MOS class: d,g,s (no bulk)
        let pmos = take(Primitive::Pmos, 3, m);
        let jfet = take(Primitive::Jfet, 3, m);
        let npn = take(Primitive::Npn, 3, m);
        let pnp = take(Primitive::Pnp, 3, m);
        let two = take(Primitive::Resistor, 2, m2);
        devices::install_host_classes(
            &[
                ("nmos", nmos),
                ("nfet", nmos),
                ("nfetd", nmos),
                ("pmos", pmos),
                ("pfet", pmos),
                ("pfetd", pmos),
                ("njfet", jfet),
                ("pjfet", jfet),
                ("npn", npn),
                ("pnp", pnp),
                // Everything Schemify maps to a two-terminal primitive.
                // (potentiometer & friends with >2 terminals keep builtin
                // anchors and import as best-effort — no Schemify symbol.)
                ("res", two),
                ("generic", two),
                ("varistor", two),
                ("thermistor", two),
                ("thermistorptc", two),
                ("thermistorntc", two),
                ("photoresistor", two),
                ("memristor", two),
                ("cap", two),
                ("ecap", two),
                ("vcap", two),
                ("ind", two),
                ("cuteind", two),
                ("vind", two),
                ("diode", two),
                ("schottky", two),
                ("zener", two),
                ("tunneldiode", two),
                ("led", two),
                ("photodiode", two),
                ("varcap", two),
                ("tvsdiode", two),
                ("vsource", two),
                ("vsourceac", two),
                ("vsourcesin", two),
                ("battery", two),
                ("isource", two),
                ("isourceac", two),
                ("cvsource", two),
                ("cisource", two),
            ],
            &[],
        );
        config::install(config::Config {
            layout: config::Layout {
                abut_gap: 20,
                tap_unit: 20,
                track_w: 10,
                track_h: 20,
                margin_gap: 30,
                bus_gap: 40,
                // ponytail: 7! = 5040 orders; conflict-aware evaluate is ~ms,
                // so 10! (3.6M) stalls big imports for minutes. Raise only
                // with a faster evaluate.
                enum_limit: 7,
                grid: 10,
                strict_geometry: true,
            },
            render: config::Render::default(),
        });
    });
}

/// A host component whose pin list is only known at runtime (a project
/// symbol, a testbench DUT). Registered with cktimg so `X` instances of it
/// place as box devices. Pin anchors come from `offsets` when given (a
/// project `.chn_prim` with its own symbol geometry — the app will draw
/// that art, so wires must land on ITS pins); otherwise they follow the
/// box-symbol layout the app draws for `.chn` cells
/// (`emit::subckt_box_pin_offset`).
#[derive(Clone, Debug)]
pub struct HostSymbol {
    pub name: String,
    pub pins: Vec<(String, PinDir)>,
    /// Schemify-frame pin anchor per pin, same order as `pins`.
    /// `None` = generated box-symbol layout.
    pub offsets: Option<Vec<(i32, i32)>>,
}

/// The parse-report reason cktimg gives an `X` line whose master is neither
/// a builtin, a `.subckt` in the same netlist, nor a registered host symbol.
/// Import surfaces these as diagnostics; callers that REQUIRE every master
/// to resolve (the agent testbench flow) match on it.
pub const UNRESOLVED_SUBCKT: &str = "undefined subckt / unknown master";

/// Parse + place + route `src` with cktimg using Schemify geometry.
pub fn netlist_to_circuit(src: &str) -> anyhow::Result<Circuit> {
    netlist_to_circuit_with(src, &[])
}

/// [`netlist_to_circuit`], with host symbols registered first — lets a
/// testbench netlist instantiate project symbols as DUT boxes.
pub fn netlist_to_circuit_with(src: &str, symbols: &[HostSymbol]) -> anyhow::Result<Circuit> {
    install_geometry();
    for s in symbols {
        // A project symbol named like a builtin (someone calls their cell
        // "res") cannot shadow it — the X master resolves to the builtin,
        // same as before registration existed.
        if devices::is_builtin(&s.name) {
            continue;
        }
        if let Some(offs) = &s.offsets {
            anyhow::ensure!(
                offs.len() == s.pins.len(),
                "symbol '{}': {} offsets for {} pins",
                s.name,
                offs.len(),
                s.pins.len()
            );
        }
        // Anchors: explicit prim geometry when given, else the box-symbol
        // layout — which must match emit::pin_position for Subcircuit
        // instances exactly (both derive from subckt_box_pin_offset).
        let probe: Vec<Pin> = s
            .pins
            .iter()
            .map(|(n, dir)| Pin {
                name: n.clone(),
                dir: *dir,
                net_idx: None,
            })
            .collect();
        let terminals = s
            .pins
            .iter()
            .enumerate()
            .map(|(i, (n, dir))| {
                let (dx, dy) = match &s.offsets {
                    Some(offs) => offs[i],
                    None => subckt_box_pin_offset(&probe, i).ok_or_else(|| {
                        anyhow::anyhow!("symbol '{}': pin {i} out of range", s.name)
                    })?,
                };
                let role = if *dir == PinDir::Input {
                    TerminalRole::Gate
                } else {
                    TerminalRole::Passive
                };
                Ok((n.clone(), role, devices::Pt { x: dx, y: dy }))
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        devices::register_host_class(&HostClass {
            name: s.name.clone(),
            terminals,
        });
    }

    let top = RefCell::new(None);
    // The cktimg backend: capture the placed+routed IR; the rendered
    // "document" is unused.
    let (_, report) = ::cktimg::run(src, |ir: &Ir, s: &Strings| {
        *top.borrow_mut() = Some(subcircuit_from_ir(ir, s));
        String::new()
    });

    let mut circuit = Circuit::new("top");
    circuit.top = top
        .into_inner()
        .ok_or_else(|| anyhow::anyhow!("cktimg backend was not invoked"))?;

    // Surface everything cktimg could not represent (ignored/skipped lines).
    circuit.diagnostics = report
        .ignored
        .iter()
        .chain(report.skipped.iter())
        .map(|n| crate::ir::ParseDiagnostic {
            line_no: n.line as usize,
            message: format!("{}: {}", n.reason, n.text),
        })
        .collect();
    Ok(circuit)
}

/// Placed+routed cktimg IR → this crate's `Subcircuit`: instances, classified
/// nets, and the routed wires/labels converted 1:1 (Schemify units — the
/// anchors installed above ARE Schemify's pin offsets).
fn subcircuit_from_ir(ir: &Ir, s: &Strings) -> Subcircuit {
    let mut sub = Subcircuit::new("top");

    // Net indices are shared verbatim between the two IRs.
    for &name in &ir.nets.name {
        sub.nets.push(Net::new(s.get(name)));
    }

    let phys = ir.physical.as_ref();
    for d in 0..ir.devices.len() {
        let class = class_at(ir.devices.symbol[d].index());
        let pin_base = ir.devices.pin0[d].index();

        // Rails and ports exist to anchor cktimg's placer; keep only their
        // net classification — power/ground nets carry bus wiring already.
        if class.role != SymbolRole::None {
            if let Some(net) = ir.pins.net[pin_base] {
                let class_for = match class.role {
                    SymbolRole::PowerRail => Some(NetClass::Power),
                    SymbolRole::GroundRail => Some(NetClass::Ground),
                    _ => None,
                };
                if let Some(c) = class_for {
                    sub.nets[net.index()].classification = c;
                }
            }
            continue;
        }

        let primitive = map_class(class.name);
        let inst_id = InstId(sub.instances.len() as u32);

        let mut pins = Vec::with_capacity(class.terminals.len());
        for (slot, term) in class.terminals.iter().enumerate() {
            let net_idx = ir.pins.net[pin_base + slot].map(|n| NetId(n.index() as u32));
            if let Some(net) = net_idx {
                sub.nets[net.index()].pins.push(PinRef {
                    instance_idx: inst_id,
                    pin_idx: PinIdx(slot as u16),
                });
            }
            pins.push(Pin {
                name: term.name.to_string(),
                dir: if term.role.is_control() {
                    PinDir::Input
                } else {
                    PinDir::Inout
                },
                net_idx,
            });
        }

        let value = s.get(ir.devices.value[d]);
        let params = params_from_value(primitive, value);

        let pos = phys.map(|p| p.pos[d]).unwrap_or_default();
        let symbol = match primitive {
            Primitive::Subcircuit => class.name.to_string(),
            p => primitive_sym(p).to_string(),
        };
        let mut inst = Instance {
            name: s.get(ir.devices.name[d]).to_string(),
            primitive,
            symbol,
            pins,
            params,
            x: pos.x,
            y: pos.y,
            flags: InstanceFlags::new(0, false),
        };
        fit_orientation(&mut inst, ir, pin_base, pos, class);
        sub.instances.push(inst);
    }

    // Wires + labels: cktimg routed on Schemify's own pin geometry, so the
    // polylines convert segment-for-segment. Polylines may retrace a shared
    // edge (trunk + stub); exact duplicates are an R4 violation — dedup on
    // normalized endpoints.
    if let Some(phys) = phys {
        let mut seen = std::collections::HashSet::new();
        for n in 0..sub.nets.len() {
            for poly in phys.segments(NetIdx::from_index(n)) {
                for w in poly.windows(2) {
                    if w[0] == w[1] {
                        continue;
                    }
                    let (a, b) = ((w[0].x, w[0].y), (w[1].x, w[1].y));
                    let key = (n, a.min(b), a.max(b));
                    if !seen.insert(key) {
                        continue;
                    }
                    sub.wires.push(Wire {
                        net_idx: NetId(n as u32),
                        x1: w[0].x,
                        y1: w[0].y,
                        x2: w[1].x,
                        y2: w[1].y,
                    });
                }
            }
        }
        for l in &phys.labels {
            sub.labels.push(Label {
                net_idx: NetId(l.net.index() as u32),
                x: l.at.x,
                y: l.at.y,
                flags: InstanceFlags::new(0, false),
            });
        }
    }
    sub
}

/// Recover the Schemify (rotation, flip, origin) whose pin offsets land
/// exactly on the pins cktimg placed. The installed anchors are
/// M(Schemify offsets) + t with M orthogonal and t a constant translation
/// (the 3-terminal axis shift), and cktimg's orientation is orthogonal too —
/// so for the right flags the implied origin `q_k − F(o_k)` is the same for
/// every pin: solve for it from pin 0 and pick the flags with zero residual.
fn fit_orientation(
    inst: &mut Instance,
    ir: &Ir,
    pin_base: usize,
    pos: ::cktimg::ir::Pt,
    class: &'static ::cktimg::devices::DeviceClass,
) {
    let Some(phys) = ir.physical.as_ref() else {
        return;
    };
    if inst.pins.is_empty() {
        return;
    }
    // Canonical offset of pin `slot` in the Schemify frame. Subcircuit hosts
    // use the anchors that were REGISTERED for them (box layout or explicit
    // `.chn_prim` geometry — `class.terminals` is exactly what we installed,
    // raw Schemify offsets); primitives use their pin table via pin_position.
    let canon = |inst: &mut Instance, slot: usize| -> (i32, i32) {
        if inst.primitive == Primitive::Subcircuit {
            let a = class.terminals[slot].at;
            inst.flags.transform_point(a.x, a.y)
        } else {
            (inst.x, inst.y) = (0, 0); // pin_position with zeroed origin yields F(o_k)
            crate::emit::pin_position(inst, slot)
        }
    };
    let mut best = (i64::MAX, inst.flags, (pos.x, pos.y));
    for rotation in 0..4u8 {
        for flip in [false, true] {
            inst.flags = InstanceFlags::new(rotation, flip);
            let q0 = phys.pin_xy[pin_base];
            let f0 = canon(inst, 0);
            let origin = (q0.x - f0.0, q0.y - f0.1);
            let residual: i64 = (0..inst.pins.len())
                .map(|slot| {
                    let q = phys.pin_xy[pin_base + slot];
                    let (fx, fy) = canon(inst, slot);
                    ((q.x - origin.0 - fx) as i64).abs() + ((q.y - origin.1 - fy) as i64).abs()
                })
                .sum();
            if residual < best.0 {
                best = (residual, inst.flags, origin);
            }
        }
    }
    (_, inst.flags, (inst.x, inst.y)) = best;
}

/// cktImg stores one opaque `value` string per device; Schemify prims read
/// specific param keys (`spice_format` substitutes `@r`/`@c`/`@dc`/`@w`/…,
/// and the symbol text anchors display them). A generic "value" key would
/// netlist as the prim DEFAULT instead of the parsed value — the classic
/// "imported schematic simulates with wrong values" failure.
fn params_from_value(primitive: Primitive, value: &str) -> Vec<(String, String)> {
    if value.is_empty() {
        return Vec::new();
    }
    let mut params: Vec<(String, String)> = match primitive {
        // "W=1u/L=100n" composite (cktImg netlist/parse.rs) → w/l keys.
        Primitive::Nmos | Primitive::Pmos => value
            .split('/')
            .filter_map(|t| t.split_once('='))
            .map(|(k, v)| (k.to_ascii_lowercase(), v.to_string()))
            .collect(),
        Primitive::Resistor => vec![("r".into(), value.into())],
        Primitive::Capacitor => vec![("c".into(), value.into())],
        Primitive::Inductor => vec![("l".into(), value.into())],
        // Source spec tail: "1", "dc 1", "SIN(0 1 1k)". A plain level maps
        // to @dc; waveform specs have no Schemify param key — keep raw.
        Primitive::Vsource | Primitive::Isource => {
            let v = value
                .strip_prefix("dc ")
                .or_else(|| value.strip_prefix("DC "))
                .unwrap_or(value);
            if v.split_whitespace().count() == 1 && !v.contains('(') {
                vec![("dc".into(), v.into())]
            } else {
                vec![("value".into(), value.into())]
            }
        }
        // "c1 c2 gain" tail: the trailing token is the gain @spice_format reads.
        Primitive::Vcvs | Primitive::Vccs => value
            .split_whitespace()
            .next_back()
            .map(|g| vec![("gain".into(), g.into())])
            .unwrap_or_default(),
        // No Schemify param key (diode/BJT/JFET models resolve via class) — keep raw.
        _ => vec![("value".into(), value.into())],
    };
    params.retain(|(_, v)| !v.is_empty());
    params.sort(); // Instance.params contract: sorted by key
    params
}

/// cktimg device class name → this crate's primitive. Classes with no
/// counterpart fall back to a subcircuit box (per-instance pins).
fn map_class(name: &str) -> Primitive {
    match name {
        "nmos" | "nfet" | "nfetd" => Primitive::Nmos,
        "pmos" | "pfet" | "pfetd" => Primitive::Pmos,
        "njfet" | "pjfet" => Primitive::Jfet,
        "npn" => Primitive::Npn,
        "pnp" => Primitive::Pnp,
        "res" | "generic" | "varistor" | "potentiometer" | "thermistor" | "thermistorptc"
        | "thermistorntc" | "photoresistor" | "memristor" => Primitive::Resistor,
        "cap" | "ecap" | "vcap" => Primitive::Capacitor,
        "ind" | "cuteind" | "vind" => Primitive::Inductor,
        "diode" | "schottky" | "zener" | "tunneldiode" | "led" | "photodiode" | "varcap"
        | "tvsdiode" => Primitive::Diode,
        "vsource" | "vsourceac" | "vsourcesin" | "battery" => Primitive::Vsource,
        "isource" | "isourceac" => Primitive::Isource,
        "cvsource" => Primitive::Vcvs,
        "cisource" => Primitive::Vccs,
        _ => Primitive::Subcircuit,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Report plumbing: a line cktimg can't represent lands in diagnostics.
    #[test]
    fn unsupported_lines_reported() {
        let c = netlist_to_circuit("R1 in out 1k\nT1 in 0 out 0 z0=50\n").unwrap();
        assert_eq!(c.diagnostics.len(), 1, "{:?}", c.diagnostics);
        assert!(c.diagnostics[0].to_string().contains("no builtin symbol"));
    }

    // An X master that is neither builtin, .subckt-defined, nor a registered
    // host symbol surfaces with the UNRESOLVED_SUBCKT reason — the hook the
    // agent import uses to fail netlist→schematic with an actionable error.
    #[test]
    fn unresolved_subckt_master_reported() {
        let c = netlist_to_circuit("R1 in out 1k\nX1 in out 0 my_missing_cell\n").unwrap();
        assert!(
            c.diagnostics
                .iter()
                .any(|d| d.message.contains(UNRESOLVED_SUBCKT)
                    && d.message.contains("my_missing_cell")),
            "{:?}",
            c.diagnostics
        );
    }

    // Explicit `.chn_prim` geometry: registered anchors override the box
    // layout, and the imported pins land exactly on them.
    #[test]
    fn host_symbol_with_explicit_offsets() {
        let dut = HostSymbol {
            name: "my_sensor".into(),
            pins: vec![("a".into(), PinDir::Input), ("b".into(), PinDir::Inout)],
            offsets: Some(vec![(-10, -20), (10, 20)]),
        };
        let c = netlist_to_circuit_with("V1 in 0 1\nXS in out my_sensor\nRL out 0 1k\n", &[dut])
            .unwrap();
        let s = c
            .top
            .instances
            .iter()
            .find(|i| i.name.eq_ignore_ascii_case("xs"))
            .expect("sensor placed");
        assert_eq!(s.primitive, Primitive::Subcircuit);
        // fit_orientation solved (flags, origin) against the registered
        // anchors: whatever orientation cktimg chose, each net's wiring or
        // label must sit exactly on flags(offset) + origin.
        let offs = [(-10, -20), (10, 20)];
        for (slot, off) in offs.iter().enumerate() {
            let (rx, ry) = s.flags.transform_point(off.0, off.1);
            let (px, py) = (s.x + rx, s.y + ry);
            let net = s.pins[slot].net_idx.expect("pin wired");
            let on_geom = c.top.wires.iter().any(|w| {
                w.net_idx == net
                    && ((w.x1 == px && w.y1 == py) || (w.x2 == px && w.y2 == py))
            }) || c.top.labels.iter().any(|l| l.net_idx == net && l.x == px && l.y == py);
            assert!(on_geom, "pin {slot} at ({px},{py}) has no wire/label endpoint");
        }
    }

    // A rail-named bulk on a 4-node MOS card must parse (upstream model fix).
    #[test]
    fn rail_named_bulk_parses() {
        let c = netlist_to_circuit("M1 out in vss vss nmos\nR1 vdd out 1k\n").unwrap();
        assert!(c.top.instances.iter().any(|i| i.primitive == Primitive::Nmos));
        // Rail devices classify their nets even though they import as labels.
        let vss = c.top.nets.iter().find(|n| n.name == "vss").unwrap();
        assert_eq!(vss.classification, NetClass::Ground);
    }

    // Smallest check that fails if the wiring breaks: parse a divider, expect
    // placed instances, connected nets, and routed wires/labels.
    #[test]
    fn rc_divider_imports_placed_and_routed() {
        let c = netlist_to_circuit("V1 in 0 1\nR1 in out 1k\nR2 out 0 1k\n").unwrap();
        assert_eq!(c.top.instances.len(), 3, "V1 R1 R2 kept, rails dropped");
        for inst in &c.top.instances {
            assert!(inst.pins.iter().any(|p| p.net_idx.is_some()), "{} floats", inst.name);
            assert_eq!(inst.x % 10, 0, "{} off-grid x={}", inst.name, inst.x);
            assert_eq!(inst.y % 10, 0, "{} off-grid y={}", inst.name, inst.y);
        }
        assert!(
            !c.top.wires.is_empty() || !c.top.labels.is_empty(),
            "router produced no connectivity"
        );
        let r1 = c.top.instances.iter().find(|i| i.name.eq_ignore_ascii_case("r1")).unwrap();
        assert_eq!(r1.primitive, Primitive::Resistor);
        assert_eq!(
            r1.params.iter().find(|(k, _)| k == "r").map(|(_, v)| v.as_str()),
            Some("1k"),
            "resistor value must land on the prim's @r param key"
        );
    }

    // Runtime host symbol: a testbench netlist instantiates a project symbol
    // as a DUT box instead of skipping the X line.
    #[test]
    fn host_symbol_places_as_dut_box() {
        let dut = HostSymbol {
            name: "my_amp".into(),
            pins: vec![
                ("in".into(), PinDir::Input),
                ("out".into(), PinDir::Output),
                ("vdd".into(), PinDir::Inout),
                ("vss".into(), PinDir::Inout),
            ],
            offsets: None,
        };
        let c = netlist_to_circuit_with(
            "V1 in 0 1\nXDUT in out vdd 0 my_amp\nRL out 0 10k\nR2 vdd in 1k\n",
            &[dut],
        )
        .unwrap();
        assert!(
            c.diagnostics.is_empty(),
            "DUT line skipped: {:?}",
            c.diagnostics
        );
        let dut = c
            .top
            .instances
            .iter()
            .find(|i| i.name.eq_ignore_ascii_case("xdut"))
            .expect("DUT placed");
        assert_eq!(dut.primitive, Primitive::Subcircuit);
        assert_eq!(dut.symbol, "my_amp");
        assert_eq!(dut.pins.len(), 4);
        assert!(dut.pins.iter().all(|p| p.net_idx.is_some()), "DUT pins wired");
    }
}
