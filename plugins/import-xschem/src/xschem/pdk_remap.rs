//! PDK-specific model name remapping.
//!
//! Maps XSchem model names from various PDKs to a canonical device kind
//! string plus a cleaned model name for SPICE netlisting.

/// Result of a PDK model lookup.
#[derive(Debug, Clone, PartialEq)]
pub struct PdkMapping {
    pub kind: &'static str,
    pub model_name: String,
}

/// Attempt to remap a PDK-specific model name to a device kind string.
///
/// Returns `None` if the model name is not recognized as a known PDK device,
/// in which case the caller should fall back to symbol-path-based detection.
pub fn remap_model(model: &str) -> Option<PdkMapping> {
    if let Some(m) = remap_sky130(model) {
        return Some(m);
    }
    if let Some(m) = remap_xh018(model) {
        return Some(m);
    }
    if let Some(m) = remap_gf180(model) {
        return Some(m);
    }
    None
}

// -- SKY130 --

fn remap_sky130(model: &str) -> Option<PdkMapping> {
    if !model.starts_with("sky130_fd_pr__") && !model.starts_with("sky130_fd_sc_") {
        return None;
    }

    let device_part = if model.starts_with("sky130_fd_pr__") {
        &model["sky130_fd_pr__".len()..]
    } else {
        return Some(PdkMapping {
            kind: "subckt",
            model_name: model.to_string(),
        });
    };

    let kind = if device_part.starts_with("nfet") {
        "nmos4"
    } else if device_part.starts_with("pfet") {
        "pmos4"
    } else if device_part.starts_with("res_") || device_part.starts_with("res_high") {
        "resistor"
    } else if device_part.starts_with("cap_") || device_part.starts_with("cap_mim") {
        "capacitor"
    } else if device_part.starts_with("diode") {
        "diode"
    } else if device_part.starts_with("npn") {
        "npn"
    } else if device_part.starts_with("pnp") {
        "pnp"
    } else if device_part.starts_with("ind") {
        "inductor"
    } else {
        "subckt"
    };

    Some(PdkMapping {
        kind,
        model_name: model.to_string(),
    })
}

// -- XH018 / XFAB --

fn remap_xh018(model: &str) -> Option<PdkMapping> {
    if !model.starts_with("xh018_") {
        return None;
    }

    let kind = if model.contains("nmos") {
        "nmos4"
    } else if model.contains("pmos") {
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
    } else {
        "subckt"
    };

    Some(PdkMapping {
        kind,
        model_name: model.to_string(),
    })
}

// -- GF180MCU --

fn remap_gf180(model: &str) -> Option<PdkMapping> {
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

    Some(PdkMapping {
        kind,
        model_name: model.to_string(),
    })
}

// -- Tests --

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sky130_nfet() {
        let m = remap_model("sky130_fd_pr__nfet_01v8").unwrap();
        assert_eq!(m.kind, "nmos4");
        assert_eq!(m.model_name, "sky130_fd_pr__nfet_01v8");
    }

    #[test]
    fn sky130_pfet() {
        let m = remap_model("sky130_fd_pr__pfet_01v8").unwrap();
        assert_eq!(m.kind, "pmos4");
    }

    #[test]
    fn sky130_res() {
        let m = remap_model("sky130_fd_pr__res_high_po_0p35").unwrap();
        assert_eq!(m.kind, "resistor");
    }

    #[test]
    fn sky130_cap() {
        let m = remap_model("sky130_fd_pr__cap_mim_m3_1").unwrap();
        assert_eq!(m.kind, "capacitor");
    }

    #[test]
    fn sky130_diode() {
        let m = remap_model("sky130_fd_pr__diode_pw2nd_05v5").unwrap();
        assert_eq!(m.kind, "diode");
    }

    #[test]
    fn sky130_standard_cell() {
        let m = remap_model("sky130_fd_sc_hd__inv_1").unwrap();
        assert_eq!(m.kind, "subckt");
    }

    #[test]
    fn xh018_nmos() {
        let m = remap_model("xh018_nmos_1v8").unwrap();
        assert_eq!(m.kind, "nmos4");
    }

    #[test]
    fn xh018_pmos() {
        let m = remap_model("xh018_pmos_3v3").unwrap();
        assert_eq!(m.kind, "pmos4");
    }

    #[test]
    fn gf180_nfet() {
        let m = remap_model("gf180mcu_fd_pr__nfet_03v3").unwrap();
        assert_eq!(m.kind, "nmos4");
    }

    #[test]
    fn gf180_cap() {
        let m = remap_model("gf180mcu_fd_pr__cap_mim").unwrap();
        assert_eq!(m.kind, "capacitor");
    }

    #[test]
    fn unknown_model_returns_none() {
        assert!(remap_model("my_custom_device").is_none());
    }

    #[test]
    fn generic_passthrough() {
        assert!(remap_model("nch").is_none());
        assert!(remap_model("pch").is_none());
        assert!(remap_model("").is_none());
    }
}
