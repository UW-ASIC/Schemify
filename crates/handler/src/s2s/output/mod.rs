pub mod schemify;
pub mod xschem;

use crate::s2s::ir::{Circuit, Instance, PinDir, Primitive, Subcircuit};
use crate::s2s::shared::{GROUND_NAMES, POWER_NAMES};

/// Pin geometry provider — knows pin offsets and coordinate transforms.
///
/// Used by placement and routing to compute absolute pin positions.
/// Separate from output concerns (symbol resolution, file writing).
pub trait PinGeometry {
    /// Pin offsets (dx, dy) for the given primitive type, relative to instance origin.
    fn pin_offsets(&self, primitive: Primitive) -> &[(i32, i32)];

    /// Apply flip and rotation to a pin offset, returning the transformed (dx, dy).
    fn transform_pin(&self, dx: i32, dy: i32, rotation: u8, flip: bool) -> (i32, i32);
}

/// Schematic file output backend.
///
/// Implementations handle symbol resolution and file writing for a specific format.
pub trait Backend: PinGeometry {
    /// Resolve the symbol path for a primitive, given an optional hint from the instance.
    fn resolve_symbol(&self, primitive: Primitive, symbol_hint: &str) -> String;

    /// Write all output files for the circuit.
    fn write_all(&self, circuit: &Circuit) -> anyhow::Result<()>;
}

/// Get pin position in schematic coordinates for a placed instance.
pub fn pin_position(geo: &dyn PinGeometry, inst: &Instance, pin_idx: usize) -> (i32, i32) {
    let offsets = geo.pin_offsets(inst.primitive);
    if pin_idx >= offsets.len() {
        return (inst.x, inst.y);
    }
    let (dx, dy) = offsets[pin_idx];
    let (rx, ry) = geo.transform_pin(dx, dy, inst.rotation, inst.flip);
    (inst.x + rx, inst.y + ry)
}

// ---------------------------------------------------------------------------
// Generic helpers (extracted from xschem backend for reuse)
// ---------------------------------------------------------------------------

/// Bounding box of placed instances.
#[derive(Debug, Clone, Copy)]
pub(crate) struct BBox {
    pub(crate) x_min: i32,
    pub(crate) x_max: i32,
    pub(crate) y_min: i32,
    pub(crate) y_max: i32,
}

/// Compute the bounding box of all placed instances in a subcircuit.
///
/// Returns `None` if there are no instances (caller should fall back to defaults).
pub(crate) fn compute_instance_bbox(subckt: &Subcircuit) -> Option<BBox> {
    if subckt.instances.is_empty() {
        return None;
    }
    let mut x_min = i32::MAX;
    let mut x_max = i32::MIN;
    let mut y_min = i32::MAX;
    let mut y_max = i32::MIN;
    for inst in &subckt.instances {
        if inst.x < x_min {
            x_min = inst.x;
        }
        if inst.x > x_max {
            x_max = inst.x;
        }
        if inst.y < y_min {
            y_min = inst.y;
        }
        if inst.y > y_max {
            y_max = inst.y;
        }
    }
    Some(BBox {
        x_min,
        x_max,
        y_min,
        y_max,
    })
}

/// Snap a value to the nearest multiple of 10.
pub(crate) fn snap_to_grid(v: i32) -> i32 {
    crate::transform::snap(v, 10)
}

/// Distribute `n` pin Y-positions evenly within [y_min, y_max], centered.
///
/// Returns a Vec of grid-snapped Y coordinates.
pub(crate) fn distribute_y(n: usize, y_min: i32, y_max: i32) -> Vec<i32> {
    if n == 0 {
        return Vec::new();
    }
    let range = y_max - y_min;
    let spacing = range / (n as i32 + 1).max(1);
    (0..n)
        .map(|i| snap_to_grid(y_min + spacing * (i as i32 + 1)))
        .collect()
}

/// Distribute `n` pin X-positions evenly within [x_min, x_max], centered.
pub(crate) fn distribute_x(n: usize, x_min: i32, x_max: i32) -> Vec<i32> {
    if n == 0 {
        return Vec::new();
    }
    let range = x_max - x_min;
    let spacing = range / (n as i32 + 1).max(1);
    (0..n)
        .map(|i| snap_to_grid(x_min + spacing * (i as i32 + 1)))
        .collect()
}

/// Classify subcircuit ports into input, output, and io/power/ground groups.
///
/// Uses `subckt.port_directions` when available. Falls back to `PinDir::Inout`
/// for ports without a direction entry.
type PortList<'a> = Vec<(&'a str, PinDir)>;

pub(crate) fn classify_ports(subckt: &Subcircuit) -> (PortList<'_>, PortList<'_>, PortList<'_>) {
    let mut inputs = Vec::new();
    let mut outputs = Vec::new();
    let mut ios = Vec::new();

    for (i, port) in subckt.ports.iter().enumerate() {
        let dir = subckt
            .port_directions
            .get(i)
            .copied()
            .unwrap_or(PinDir::Inout);
        match dir {
            PinDir::Input => inputs.push((port.as_str(), dir)),
            PinDir::Output => outputs.push((port.as_str(), dir)),
            _ => ios.push((port.as_str(), dir)),
        }
    }

    (inputs, outputs, ios)
}
