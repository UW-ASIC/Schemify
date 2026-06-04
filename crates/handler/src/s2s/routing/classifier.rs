//! Net classifier — decides whether each net should be routed with drawn wires
//! or represented by net labels only, based on post-placement geometry.

use crate::s2s::ir::{Net, Subcircuit};
use crate::s2s::output::{pin_position, PinGeometry};
use crate::s2s::shared::{is_ground_name, is_power_name};

/// Strategy for drawing a net on the schematic.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetStrategy {
    /// Route with A* or L-shape wires.
    Wire,
    /// Use net labels at each pin (no drawn wires).
    Label,
}

/// Base Manhattan span threshold (schematic units) for a net to qualify as `Wire`.
const BASE_WIRE_DISTANCE_THRESHOLD: i32 = 300;

/// Fanout above which a net is always labelled (too many connections to draw).
const FANOUT_THRESHOLD: usize = 4;

/// Compute an adaptive wire distance threshold based on the circuit bounding box.
/// For small/tight circuits the threshold equals the base; for spread-out circuits
/// it scales up so that local nets still qualify as wires.
fn adaptive_threshold(subckt: &Subcircuit) -> i32 {
    if subckt.instances.is_empty() {
        return BASE_WIRE_DISTANCE_THRESHOLD;
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
    let x_span = max_x - min_x;
    let y_span = max_y - min_y;
    // Half-perimeter: nets spanning less than half the circuit bbox get wires.
    // This covers cross-region nets (PMOS↔NMOS) while still labelling truly global nets.
    let dynamic = (x_span + y_span) / 2;
    BASE_WIRE_DISTANCE_THRESHOLD.max(dynamic)
}

/// Classify all nets in a subcircuit based on post-placement pin positions.
pub fn classify_nets(subckt: &Subcircuit, backend: &dyn PinGeometry) -> Vec<NetStrategy> {
    let threshold = adaptive_threshold(subckt);
    subckt
        .nets
        .iter()
        .map(|net| classify_net(net, subckt, threshold, backend))
        .collect()
}

/// Classify a single net.
fn classify_net(
    net: &Net,
    subckt: &Subcircuit,
    wire_threshold: i32,
    backend: &dyn PinGeometry,
) -> NetStrategy {
    // Nets with 0 or 1 pins have nothing to route.
    if net.pins.len() < 2 {
        return NetStrategy::Label;
    }

    // Global nets (power rails) always get labels.
    if net.is_global {
        return NetStrategy::Label;
    }

    // Well-known power/ground names always get labels.
    if is_power_name(&net.name) || is_ground_name(&net.name) {
        return NetStrategy::Label;
    }

    // High-fanout nets always get labels.
    if net.pins.len() > FANOUT_THRESHOLD {
        return NetStrategy::Label;
    }

    // Compute bounding box of all pin positions (Manhattan span).
    let mut min_x = i32::MAX;
    let mut max_x = i32::MIN;
    let mut min_y = i32::MAX;
    let mut max_y = i32::MIN;

    for pin_ref in &net.pins {
        let inst = &subckt.instances[pin_ref.instance_idx as usize];
        let (px, py) = pin_position(backend, inst, pin_ref.pin_idx as usize);
        min_x = min_x.min(px);
        max_x = max_x.max(px);
        min_y = min_y.min(py);
        max_y = max_y.max(py);
    }

    let manhattan_span = (max_x - min_x) + (max_y - min_y);

    if manhattan_span <= wire_threshold {
        NetStrategy::Wire
    } else {
        NetStrategy::Label
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use crate::s2s::ir::{Instance, Net, Pin, PinDir, PinRef, Primitive, Subcircuit};
    use crate::s2s::output::xschem::XschemBackend;
    use std::collections::HashMap;

    fn test_backend() -> XschemBackend {
        XschemBackend::new("/tmp")
    }

    /// Helper: build a minimal two-terminal instance at (x, y).
    fn make_instance(name: &str, x: i32, y: i32) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: Primitive::Resistor,
            symbol: String::new(),
            pins: vec![
                Pin {
                    name: "p".into(),
                    dir: PinDir::Inout,
                    net_idx: Some(0),
                },
                Pin {
                    name: "n".into(),
                    dir: PinDir::Inout,
                    net_idx: Some(0),
                },
            ],
            params: HashMap::new(),
            x,
            y,
            rotation: 0,
            flip: false,
        }
    }

    /// Build a subcircuit with the given instances and a single net connecting pin 0 of each.
    fn make_subckt_with_net(
        instances: Vec<Instance>,
        net_name: &str,
        is_global: bool,
    ) -> Subcircuit {
        let pin_refs: Vec<PinRef> = (0..instances.len())
            .map(|i| PinRef {
                instance_idx: i as u32,
                pin_idx: 0,
            })
            .collect();

        let mut net = Net::new(net_name);
        net.is_global = is_global;
        net.pins = pin_refs;

        let mut subckt = Subcircuit::new("test");
        subckt.instances = instances;
        subckt.nets.push(net);
        subckt
    }

    #[test]
    fn power_net_global_flag_produces_label() {
        let instances = vec![make_instance("I0", 0, 0), make_instance("I1", 10, 0)];
        let subckt = make_subckt_with_net(instances, "some_net", true);

        let strategies = classify_nets(&subckt, &test_backend());
        assert_eq!(strategies[0], NetStrategy::Label);
    }

    #[test]
    fn power_net_name_vdd_produces_label() {
        let instances = vec![make_instance("I0", 0, 0), make_instance("I1", 10, 0)];
        let subckt = make_subckt_with_net(instances, "VDD", false);

        let strategies = classify_nets(&subckt, &test_backend());
        assert_eq!(strategies[0], NetStrategy::Label);
    }

    #[test]
    fn power_net_name_gnd_produces_label() {
        let instances = vec![make_instance("I0", 0, 0), make_instance("I1", 10, 0)];
        let subckt = make_subckt_with_net(instances, "gnd", false);

        let strategies = classify_nets(&subckt, &test_backend());
        assert_eq!(strategies[0], NetStrategy::Label);
    }

    #[test]
    fn power_net_name_zero_produces_label() {
        let instances = vec![make_instance("I0", 0, 0), make_instance("I1", 10, 0)];
        let subckt = make_subckt_with_net(instances, "0", false);

        let strategies = classify_nets(&subckt, &test_backend());
        assert_eq!(strategies[0], NetStrategy::Label);
    }

    #[test]
    fn high_fanout_produces_label() {
        // 5 instances -> fanout 5 > threshold 4
        let instances: Vec<Instance> = (0..5)
            .map(|i| make_instance(&format!("I{i}"), i * 10, 0))
            .collect();
        let subckt = make_subckt_with_net(instances, "n1", false);

        let strategies = classify_nets(&subckt, &test_backend());
        assert_eq!(strategies[0], NetStrategy::Label);
    }

    #[test]
    fn short_local_net_produces_wire() {
        // Two instances close together: pin positions are (0, -30) and (100, -30).
        // Manhattan span = 100, which is <= 300.
        let instances = vec![make_instance("I0", 0, 0), make_instance("I1", 100, 0)];
        let subckt = make_subckt_with_net(instances, "n1", false);

        let strategies = classify_nets(&subckt, &test_backend());
        assert_eq!(strategies[0], NetStrategy::Wire);
    }

    #[test]
    fn long_distance_net_produces_label() {
        // Two instances far apart: pin positions are (0, -30) and (500, -30).
        // Manhattan span = 500, which is > 300.
        let instances = vec![make_instance("I0", 0, 0), make_instance("I1", 500, 0)];
        let subckt = make_subckt_with_net(instances, "n1", false);

        let strategies = classify_nets(&subckt, &test_backend());
        assert_eq!(strategies[0], NetStrategy::Label);
    }

    #[test]
    fn zero_pin_net_produces_label() {
        let mut subckt = Subcircuit::new("test");
        subckt.instances.push(make_instance("I0", 0, 0));
        let net = Net::new("empty");
        subckt.nets.push(net);

        let strategies = classify_nets(&subckt, &test_backend());
        assert_eq!(strategies[0], NetStrategy::Label);
    }

    #[test]
    fn single_pin_net_produces_label() {
        let mut subckt = Subcircuit::new("test");
        subckt.instances.push(make_instance("I0", 0, 0));
        let mut net = Net::new("lonely");
        net.pins.push(PinRef {
            instance_idx: 0,
            pin_idx: 0,
        });
        subckt.nets.push(net);

        let strategies = classify_nets(&subckt, &test_backend());
        assert_eq!(strategies[0], NetStrategy::Label);
    }

    #[test]
    fn exactly_four_pins_is_wire_if_close() {
        // 4 pins (at threshold) close together => Wire
        let instances: Vec<Instance> = (0..4)
            .map(|i| make_instance(&format!("I{i}"), i * 30, 0))
            .collect();
        let subckt = make_subckt_with_net(instances, "n1", false);

        let strategies = classify_nets(&subckt, &test_backend());
        assert_eq!(strategies[0], NetStrategy::Wire);
    }

    #[test]
    fn vss_produces_label() {
        let instances = vec![make_instance("I0", 0, 0), make_instance("I1", 10, 0)];
        let subckt = make_subckt_with_net(instances, "VSS", false);

        let strategies = classify_nets(&subckt, &test_backend());
        assert_eq!(strategies[0], NetStrategy::Label);
    }

    #[test]
    fn vcc_produces_label() {
        let instances = vec![make_instance("I0", 0, 0), make_instance("I1", 10, 0)];
        let subckt = make_subckt_with_net(instances, "Vcc", false);

        let strategies = classify_nets(&subckt, &test_backend());
        assert_eq!(strategies[0], NetStrategy::Label);
    }
}
