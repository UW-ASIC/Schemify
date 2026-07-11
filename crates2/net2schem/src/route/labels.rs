//! Net-label placement for Label-strategy nets.

use super::*;

/// Place net labels at each pin position for a Label-strategy net.
///
/// When `force_upright` is true (power/ground nets), rotation is always 0
/// so VDD/GND rail symbols keep their canonical orientation (vdd above,
/// gnd below the pin).
pub(crate) fn place_labels_for_net(
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
pub(crate) fn label_rotation(from_x: i32, from_y: i32, to_x: i32, to_y: i32) -> u8 {
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
