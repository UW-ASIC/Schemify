//! Shared constants and mappings used across the s2s pipeline.

use schemify_core::types::DeviceKind;

use super::ir::Primitive;

// ---------------------------------------------------------------------------
// Power / ground name constants
// ---------------------------------------------------------------------------

pub(crate) const POWER_NAMES: &[&str] = &["vdd", "vcc", "avdd", "dvdd"];
pub(crate) const GROUND_NAMES: &[&str] = &["vss", "gnd", "0", "avss", "dvss"];

pub(crate) fn is_power_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    POWER_NAMES.iter().any(|&p| lower == p)
}

pub(crate) fn is_ground_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    GROUND_NAMES.iter().any(|&g| lower == g)
}

// ---------------------------------------------------------------------------
// Primitive <-> DeviceKind mapping
// ---------------------------------------------------------------------------

pub(crate) fn map_device_kind(p: Primitive) -> DeviceKind {
    match p {
        Primitive::Nmos => DeviceKind::Nmos4,
        Primitive::Pmos => DeviceKind::Pmos4,
        Primitive::Npn => DeviceKind::Npn,
        Primitive::Pnp => DeviceKind::Pnp,
        Primitive::Resistor => DeviceKind::Resistor,
        Primitive::Capacitor => DeviceKind::Capacitor,
        Primitive::Inductor => DeviceKind::Inductor,
        Primitive::Diode => DeviceKind::Diode,
        Primitive::Vsource => DeviceKind::Vsource,
        Primitive::Isource => DeviceKind::Isource,
        Primitive::Vcvs => DeviceKind::Vcvs,
        Primitive::Vccs => DeviceKind::Vccs,
        Primitive::Ccvs => DeviceKind::Ccvs,
        Primitive::Cccs => DeviceKind::Cccs,
        Primitive::Jfet => DeviceKind::Njfet,
        Primitive::BehavioralSource => DeviceKind::Behavioral,
        Primitive::Subcircuit => DeviceKind::Subckt,
    }
}

pub(crate) fn map_primitive(kind: DeviceKind) -> Option<Primitive> {
    match kind {
        DeviceKind::Nmos4
        | DeviceKind::Nmos3
        | DeviceKind::Nmos4Depl
        | DeviceKind::NmosSub
        | DeviceKind::Nmoshv4
        | DeviceKind::Rnmos4 => Some(Primitive::Nmos),
        DeviceKind::Pmos4 | DeviceKind::Pmos3 | DeviceKind::PmosSub | DeviceKind::Pmoshv4 => {
            Some(Primitive::Pmos)
        }
        DeviceKind::Npn => Some(Primitive::Npn),
        DeviceKind::Pnp => Some(Primitive::Pnp),
        DeviceKind::Resistor | DeviceKind::Resistor3 | DeviceKind::VarResistor => {
            Some(Primitive::Resistor)
        }
        DeviceKind::Capacitor => Some(Primitive::Capacitor),
        DeviceKind::Inductor => Some(Primitive::Inductor),
        DeviceKind::Diode | DeviceKind::Zener => Some(Primitive::Diode),
        DeviceKind::Vsource => Some(Primitive::Vsource),
        DeviceKind::Isource => Some(Primitive::Isource),
        DeviceKind::Vcvs => Some(Primitive::Vcvs),
        DeviceKind::Vccs => Some(Primitive::Vccs),
        DeviceKind::Ccvs => Some(Primitive::Ccvs),
        DeviceKind::Cccs => Some(Primitive::Cccs),
        DeviceKind::Njfet | DeviceKind::Pjfet => Some(Primitive::Jfet),
        DeviceKind::Behavioral => Some(Primitive::BehavioralSource),
        DeviceKind::Subckt | DeviceKind::DigitalInstance => Some(Primitive::Subcircuit),
        _ => None,
    }
}

pub(crate) fn primitive_sym(p: Primitive) -> &'static str {
    match p {
        Primitive::Nmos => "nmos4",
        Primitive::Pmos => "pmos4",
        Primitive::Npn => "npn",
        Primitive::Pnp => "pnp",
        Primitive::Resistor => "res",
        Primitive::Capacitor => "capa",
        Primitive::Inductor => "ind",
        Primitive::Diode => "diode",
        Primitive::Vsource => "vsource",
        Primitive::Isource => "isource",
        Primitive::Vcvs => "vcvs",
        Primitive::Vccs => "vccs",
        Primitive::Ccvs => "ccvs",
        Primitive::Cccs => "cccs",
        Primitive::Jfet => "jfet",
        Primitive::BehavioralSource => "bsource",
        Primitive::Subcircuit => "subckt",
    }
}
