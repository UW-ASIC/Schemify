//! PDK model-to-kind mapping for multiple process nodes.
//!
//! Maps model names from various PDKs to kind name strings. Covers:
//! - SkyWater SKY130
//! - XFAB XH018
//! - Cadence GPDK045 / GPDK090
//! - TSMC 65nm
//! - GF180MCU
//! - Generic SPICE model names

/// Map a model name to a device kind string using all known PDK mappings.
///
/// Falls back to generic SPICE model name matching if no PDK prefix
/// is recognized. Returns `"unknown"` only if the model
/// name cannot be classified at all.
pub fn map_model_to_kind(model: &str) -> &'static str {
    if model.is_empty() {
        return "unknown";
    }

    // Try PDK-specific matchers first
    if let Some(k) = map_sky130(model) {
        return k;
    }
    if let Some(k) = map_xh018(model) {
        return k;
    }
    if let Some(k) = map_gpdk045(model) {
        return k;
    }
    if let Some(k) = map_gpdk090(model) {
        return k;
    }
    if let Some(k) = map_tsmc65(model) {
        return k;
    }
    if let Some(k) = map_gf180(model) {
        return k;
    }

    // Generic SPICE model name matching
    map_generic(model)
}

// -- SKY130 -------------------------------------------------------------------

fn map_sky130(model: &str) -> Option<&'static str> {
    if !model.starts_with("sky130_fd_pr__") && !model.starts_with("sky130_fd_sc_") {
        return None;
    }

    if model.starts_with("sky130_fd_sc_") {
        return Some("subckt");
    }

    let device = &model["sky130_fd_pr__".len()..];

    let kind = if device.starts_with("nfet") {
        "nmos4"
    } else if device.starts_with("pfet") {
        "pmos4"
    } else if device.starts_with("res_") || device.starts_with("res_high") {
        "resistor"
    } else if device.starts_with("cap_") || device.starts_with("cap_mim") {
        "capacitor"
    } else if device.starts_with("diode") {
        "diode"
    } else if device.starts_with("npn") {
        "npn"
    } else if device.starts_with("pnp") {
        "pnp"
    } else if device.starts_with("ind") {
        "inductor"
    } else {
        "subckt"
    };

    Some(kind)
}

// -- XH018 / XFAB ------------------------------------------------------------

fn map_xh018(model: &str) -> Option<&'static str> {
    if !model.starts_with("xh018_") {
        return None;
    }

    let kind = if model.contains("nmos") || model.contains("nfet") {
        "nmos4"
    } else if model.contains("pmos") || model.contains("pfet") {
        "pmos4"
    } else if model.contains("npn") {
        "npn"
    } else if model.contains("pnp") {
        "pnp"
    } else if model.contains("res") {
        "resistor"
    } else if model.contains("cap") {
        "capacitor"
    } else if model.contains("dio") {
        "diode"
    } else if model.contains("ind") {
        "inductor"
    } else {
        "subckt"
    };

    Some(kind)
}

// -- GPDK045 (Cadence Generic PDK 45nm) ---------------------------------------

fn map_gpdk045(model: &str) -> Option<&'static str> {
    if !model.starts_with("gpdk045_") && !model.starts_with("g45_") {
        return None;
    }

    let lower = model.to_ascii_lowercase();
    let kind = if lower.contains("nmos") || lower.contains("nfet") || lower.contains("nch") {
        "nmos4"
    } else if lower.contains("pmos") || lower.contains("pfet") || lower.contains("pch") {
        "pmos4"
    } else if lower.contains("npn") {
        "npn"
    } else if lower.contains("pnp") {
        "pnp"
    } else if lower.contains("res") {
        "resistor"
    } else if lower.contains("cap") || lower.contains("mim") {
        "capacitor"
    } else if lower.contains("dio") {
        "diode"
    } else if lower.contains("ind") {
        "inductor"
    } else {
        "subckt"
    };

    Some(kind)
}

// -- GPDK090 (Cadence Generic PDK 90nm) ---------------------------------------

fn map_gpdk090(model: &str) -> Option<&'static str> {
    if !model.starts_with("gpdk090_") && !model.starts_with("g90_") {
        return None;
    }

    let lower = model.to_ascii_lowercase();
    let kind = if lower.contains("nmos") || lower.contains("nfet") || lower.contains("nch") {
        "nmos4"
    } else if lower.contains("pmos") || lower.contains("pfet") || lower.contains("pch") {
        "pmos4"
    } else if lower.contains("npn") {
        "npn"
    } else if lower.contains("pnp") {
        "pnp"
    } else if lower.contains("res") {
        "resistor"
    } else if lower.contains("cap") || lower.contains("mim") {
        "capacitor"
    } else if lower.contains("dio") {
        "diode"
    } else if lower.contains("ind") {
        "inductor"
    } else {
        "subckt"
    };

    Some(kind)
}

// -- TSMC 65nm ----------------------------------------------------------------

fn map_tsmc65(model: &str) -> Option<&'static str> {
    if !model.starts_with("tsmc65_")
        && !model.starts_with("cln65")
        && !model.starts_with("crn65")
    {
        return None;
    }

    let lower = model.to_ascii_lowercase();
    let kind = if lower.contains("nmos") || lower.contains("nch") || lower.contains("nfet") {
        "nmos4"
    } else if lower.contains("pmos") || lower.contains("pch") || lower.contains("pfet") {
        "pmos4"
    } else if lower.contains("npn") {
        "npn"
    } else if lower.contains("pnp") {
        "pnp"
    } else if lower.contains("res") || lower.contains("rnw") || lower.contains("rpp") {
        "resistor"
    } else if lower.contains("cap") || lower.contains("mim") || lower.contains("mom") {
        "capacitor"
    } else if lower.contains("dio") || lower.contains("ndio") || lower.contains("pdio") {
        "diode"
    } else if lower.contains("ind") {
        "inductor"
    } else {
        "subckt"
    };

    Some(kind)
}

// -- GF180MCU -----------------------------------------------------------------

fn map_gf180(model: &str) -> Option<&'static str> {
    if !model.starts_with("gf180mcu_") {
        return None;
    }

    let kind = if model.contains("nfet") || model.contains("nmos") {
        "nmos4"
    } else if model.contains("pfet") || model.contains("pmos") {
        "pmos4"
    } else if model.contains("npn") {
        "npn"
    } else if model.contains("pnp") {
        "pnp"
    } else if model.contains("res") {
        "resistor"
    } else if model.contains("cap") {
        "capacitor"
    } else if model.contains("diode") {
        "diode"
    } else {
        "subckt"
    };

    Some(kind)
}

// -- Generic SPICE model names ------------------------------------------------

fn map_generic(model: &str) -> &'static str {
    let lower = model.to_ascii_lowercase();

    // Exact matches for common generic model names
    match lower.as_str() {
        "nmos" | "nch" | "nfet" | "nmos_3p3" | "nmos_1p8" => "nmos4",
        "pmos" | "pch" | "pfet" | "pmos_3p3" | "pmos_1p8" => "pmos4",
        "npn" | "npn13g2" | "npn13g2l" => "npn",
        "pnp" | "pnp13g2" => "pnp",
        "resistor" | "res" => "resistor",
        "capacitor" | "cap" => "capacitor",
        "inductor" | "ind" => "inductor",
        "diode" | "dio" => "diode",
        "njfet" | "njf" => "njfet",
        "pjfet" | "pjf" => "pjfet",
        "mesfet" | "nmf" => "mesfet",
        "vsource" | "vdc" | "vsin" | "vpulse" => "vsource",
        "isource" | "idc" | "isin" | "ipulse" => "isource",
        "vcvs" => "vcvs",
        "vccs" => "vccs",
        "ccvs" => "ccvs",
        "cccs" => "cccs",
        "tline" => "tline",
        _ => "unknown",
    }
}

// -- Tests --------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // SKY130
    #[test]
    fn sky130_nfet() {
        assert_eq!(map_model_to_kind("sky130_fd_pr__nfet_01v8"), "nmos4");
    }

    #[test]
    fn sky130_pfet() {
        assert_eq!(map_model_to_kind("sky130_fd_pr__pfet_01v8"), "pmos4");
    }

    #[test]
    fn sky130_res() {
        assert_eq!(
            map_model_to_kind("sky130_fd_pr__res_high_po_0p35"),
            "resistor"
        );
    }

    #[test]
    fn sky130_cap() {
        assert_eq!(
            map_model_to_kind("sky130_fd_pr__cap_mim_m3_1"),
            "capacitor"
        );
    }

    #[test]
    fn sky130_diode() {
        assert_eq!(
            map_model_to_kind("sky130_fd_pr__diode_pw2nd_05v5"),
            "diode"
        );
    }

    #[test]
    fn sky130_std_cell() {
        assert_eq!(map_model_to_kind("sky130_fd_sc_hd__inv_1"), "subckt");
    }

    #[test]
    fn sky130_npn() {
        assert_eq!(map_model_to_kind("sky130_fd_pr__npn_05v5"), "npn");
    }

    // XH018
    #[test]
    fn xh018_nmos() {
        assert_eq!(map_model_to_kind("xh018_nmos_1v8"), "nmos4");
    }

    #[test]
    fn xh018_pmos() {
        assert_eq!(map_model_to_kind("xh018_pmos_3v3"), "pmos4");
    }

    #[test]
    fn xh018_res() {
        assert_eq!(map_model_to_kind("xh018_res_pp"), "resistor");
    }

    #[test]
    fn xh018_cap() {
        assert_eq!(map_model_to_kind("xh018_cap_mim"), "capacitor");
    }

    #[test]
    fn xh018_diode() {
        assert_eq!(map_model_to_kind("xh018_dio_nw"), "diode");
    }

    // GPDK045
    #[test]
    fn gpdk045_nmos() {
        assert_eq!(map_model_to_kind("gpdk045_nmos"), "nmos4");
    }

    #[test]
    fn gpdk045_pmos() {
        assert_eq!(map_model_to_kind("gpdk045_pmos"), "pmos4");
    }

    #[test]
    fn gpdk045_res() {
        assert_eq!(map_model_to_kind("gpdk045_res_poly"), "resistor");
    }

    #[test]
    fn gpdk045_cap() {
        assert_eq!(map_model_to_kind("gpdk045_cap_mim"), "capacitor");
    }

    #[test]
    fn g45_prefix() {
        assert_eq!(map_model_to_kind("g45_nch"), "nmos4");
        assert_eq!(map_model_to_kind("g45_pch"), "pmos4");
    }

    // GPDK090
    #[test]
    fn gpdk090_nmos() {
        assert_eq!(map_model_to_kind("gpdk090_nmos"), "nmos4");
    }

    #[test]
    fn gpdk090_pmos() {
        assert_eq!(map_model_to_kind("gpdk090_pmos"), "pmos4");
    }

    #[test]
    fn g90_prefix() {
        assert_eq!(map_model_to_kind("g90_nfet"), "nmos4");
        assert_eq!(map_model_to_kind("g90_pfet"), "pmos4");
    }

    // TSMC65
    #[test]
    fn tsmc65_nmos() {
        assert_eq!(map_model_to_kind("tsmc65_nmos_1p2"), "nmos4");
    }

    #[test]
    fn tsmc65_pmos() {
        assert_eq!(map_model_to_kind("tsmc65_pmos_1p2"), "pmos4");
    }

    #[test]
    fn tsmc65_cln_prefix() {
        assert_eq!(map_model_to_kind("cln65_nch_mac"), "nmos4");
        assert_eq!(map_model_to_kind("cln65_pch_mac"), "pmos4");
    }

    #[test]
    fn tsmc65_res() {
        assert_eq!(map_model_to_kind("tsmc65_res_poly"), "resistor");
    }

    #[test]
    fn tsmc65_cap() {
        assert_eq!(map_model_to_kind("tsmc65_cap_mim_1p5f"), "capacitor");
    }

    #[test]
    fn tsmc65_mom_cap() {
        assert_eq!(map_model_to_kind("tsmc65_mom_cap"), "capacitor");
    }

    // GF180MCU
    #[test]
    fn gf180_nfet() {
        assert_eq!(map_model_to_kind("gf180mcu_fd_pr__nfet_03v3"), "nmos4");
    }

    #[test]
    fn gf180_pfet() {
        assert_eq!(map_model_to_kind("gf180mcu_fd_pr__pfet_03v3"), "pmos4");
    }

    #[test]
    fn gf180_cap() {
        assert_eq!(map_model_to_kind("gf180mcu_fd_pr__cap_mim"), "capacitor");
    }

    // Generic
    #[test]
    fn generic_nmos() {
        assert_eq!(map_model_to_kind("nmos"), "nmos4");
        assert_eq!(map_model_to_kind("nch"), "nmos4");
        assert_eq!(map_model_to_kind("nfet"), "nmos4");
    }

    #[test]
    fn generic_pmos() {
        assert_eq!(map_model_to_kind("pmos"), "pmos4");
        assert_eq!(map_model_to_kind("pch"), "pmos4");
    }

    #[test]
    fn generic_passives() {
        assert_eq!(map_model_to_kind("resistor"), "resistor");
        assert_eq!(map_model_to_kind("capacitor"), "capacitor");
        assert_eq!(map_model_to_kind("inductor"), "inductor");
    }

    #[test]
    fn generic_bjt() {
        assert_eq!(map_model_to_kind("npn"), "npn");
        assert_eq!(map_model_to_kind("pnp"), "pnp");
    }

    #[test]
    fn generic_sources() {
        assert_eq!(map_model_to_kind("vsource"), "vsource");
        assert_eq!(map_model_to_kind("isource"), "isource");
    }

    #[test]
    fn generic_controlled_sources() {
        assert_eq!(map_model_to_kind("vcvs"), "vcvs");
        assert_eq!(map_model_to_kind("vccs"), "vccs");
        assert_eq!(map_model_to_kind("ccvs"), "ccvs");
        assert_eq!(map_model_to_kind("cccs"), "cccs");
    }

    #[test]
    fn unknown_model() {
        assert_eq!(map_model_to_kind("my_custom_thing"), "unknown");
    }

    #[test]
    fn empty_model() {
        assert_eq!(map_model_to_kind(""), "unknown");
    }

    #[test]
    fn generic_diode() {
        assert_eq!(map_model_to_kind("diode"), "diode");
    }

    #[test]
    fn generic_jfet() {
        assert_eq!(map_model_to_kind("njfet"), "njfet");
        assert_eq!(map_model_to_kind("pjfet"), "pjfet");
    }
}
