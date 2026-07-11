//! Device taxonomy. Every per-kind fact lives in ONE place: the exhaustive
//! [`DeviceKind::spec`] table. Adding a device = add the enum variant, add
//! its spec row here, add its IR-emit arm in `sim` — the compiler names all
//! three sites (no wildcard arms).

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum DeviceKind {
    #[default]
    Unknown = 0,
    // Passives
    Resistor,
    Resistor3,
    VarResistor,
    Capacitor,
    Inductor,
    // Diodes
    Diode,
    Zener,
    // MOSFETs
    Nmos3,
    Pmos3,
    Nmos4,
    Pmos4,
    Nmos4Depl,
    NmosSub,
    PmosSub,
    Nmoshv4,
    Pmoshv4,
    Rnmos4,
    // BJTs
    Npn,
    Pnp,
    // JFETs / MESFET
    Njfet,
    Pjfet,
    Mesfet,
    // Sources
    Vsource,
    Isource,
    Sqwsource,
    Ammeter,
    Behavioral,
    // Controlled sources
    Vcvs,
    Vccs,
    Ccvs,
    Cccs,
    // Transmission / coupling
    Coupling,
    Tline,
    TlineLossy,
    // Switches
    Vswitch,
    Iswitch,
    // Simulation / probes
    Param,
    Probe,
    ProbeDiff,
    Code,
    Graph,
    // HDL
    Hdl,
    // Connectors / labels
    Gnd,
    Vdd,
    LabPin,
    InputPin,
    OutputPin,
    InoutPin,
    // Non-electrical
    Annotation,
    Noconn,
    Title,
    Launcher,
    RgbLed,
    Generic,
    // Hierarchical
    DigitalInstance,
    Subckt,
}

/// Coarse role of a device kind. `Device` = participates in the circuit;
/// the rest are schematic-level markers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// Circuit element (may still be non-netlisted, e.g. `Unknown`).
    Device,
    /// Net label pin (lab/input/output/inout).
    Label,
    /// Power connector (gnd/vdd) injecting a named net.
    Power,
    /// Pure annotation: no electrical meaning.
    Annotation,
}

/// Everything the rest of the codebase needs to know about a [`DeviceKind`],
/// in one row. Returned by the single exhaustive match in
/// [`DeviceKind::spec`].
pub struct DeviceSpec {
    /// Accepted names; `names[0]` is canonical. Replaces `from_name`.
    pub names: &'static [&'static str],
    pub role: Role,
    /// Emits its own netlist card (`is_electrical`).
    pub netlisted: bool,
    /// SPICE element letter; 0 = no netlist line of its own.
    pub prefix: u8,
    pub pins: &'static [&'static str],
    /// SPICE `.model` type keyword, if the device references a model card.
    pub model_keyword: Option<&'static str>,
    /// Net name a connector injects at its pin position (gnd -> "0").
    pub injected_net: Option<&'static str>,
    /// UI symbol key (collapses variants: all MOSFETs draw "nmos"/"pmos").
    pub symbol: &'static str,
    /// Fallback model name for netlisting when neither the instance nor the
    /// PDK provides one.
    pub default_model: &'static str,
}

/// Shorthand row constructor: netlisted circuit device.
const fn dev(
    names: &'static [&'static str],
    prefix: u8,
    pins: &'static [&'static str],
    model_keyword: Option<&'static str>,
    symbol: &'static str,
    default_model: &'static str,
) -> DeviceSpec {
    DeviceSpec {
        names,
        role: Role::Device,
        netlisted: true,
        prefix,
        pins,
        model_keyword,
        injected_net: None,
        symbol,
        default_model,
    }
}

/// Shorthand row constructor: pure annotation (no electrical meaning).
const fn ann(names: &'static [&'static str], pins: &'static [&'static str]) -> DeviceSpec {
    DeviceSpec {
        names,
        role: Role::Annotation,
        netlisted: false,
        prefix: 0,
        pins,
        model_keyword: None,
        injected_net: None,
        symbol: names[0],
        default_model: "unknown",
    }
}

impl DeviceKind {
    /// Every variant, for table-driven iteration (`from_name`, spec tests).
    pub const ALL: [DeviceKind; 57] = [
        Self::Unknown,
        Self::Resistor,
        Self::Resistor3,
        Self::VarResistor,
        Self::Capacitor,
        Self::Inductor,
        Self::Diode,
        Self::Zener,
        Self::Nmos3,
        Self::Pmos3,
        Self::Nmos4,
        Self::Pmos4,
        Self::Nmos4Depl,
        Self::NmosSub,
        Self::PmosSub,
        Self::Nmoshv4,
        Self::Pmoshv4,
        Self::Rnmos4,
        Self::Npn,
        Self::Pnp,
        Self::Njfet,
        Self::Pjfet,
        Self::Mesfet,
        Self::Vsource,
        Self::Isource,
        Self::Sqwsource,
        Self::Ammeter,
        Self::Behavioral,
        Self::Vcvs,
        Self::Vccs,
        Self::Ccvs,
        Self::Cccs,
        Self::Coupling,
        Self::Tline,
        Self::TlineLossy,
        Self::Vswitch,
        Self::Iswitch,
        Self::Param,
        Self::Probe,
        Self::ProbeDiff,
        Self::Code,
        Self::Graph,
        Self::Hdl,
        Self::Gnd,
        Self::Vdd,
        Self::LabPin,
        Self::InputPin,
        Self::OutputPin,
        Self::InoutPin,
        Self::Annotation,
        Self::Noconn,
        Self::Title,
        Self::Launcher,
        Self::RgbLed,
        Self::Generic,
        Self::DigitalInstance,
        Self::Subckt,
    ];

    /// The one spec row for this kind. Exhaustive — a new variant does not
    /// compile until its row exists.
    pub const fn spec(self) -> &'static DeviceSpec {
        match self {
            // Unknown: a Device by role, but never netlisted.
            Self::Unknown => &const { DeviceSpec {
                names: &["unknown"],
                role: Role::Device,
                netlisted: false,
                prefix: 0,
                pins: &[],
                model_keyword: None,
                injected_net: None,
                symbol: "generic",
                default_model: "unknown",
            } },

            // ── Passives ──
            Self::Resistor => &const { dev(&["resistor", "res"], b'R', &["p", "n"], None, "resistor", "unknown") },
            Self::Resistor3 => &const { dev(&["resistor3"], b'R', &["p", "n", "t"], None, "resistor", "unknown") },
            Self::VarResistor => &const { dev(&["var_resistor"], b'R', &[], None, "resistor", "unknown") },
            Self::Capacitor => &const { dev(&["capacitor", "cap", "capa"], b'C', &["p", "n"], None, "capacitor", "unknown") },
            Self::Inductor => &const { dev(&["inductor", "ind"], b'L', &["p", "n"], None, "inductor", "unknown") },

            // ── Diodes ──
            Self::Diode => &const { dev(&["diode"], b'D', &["p", "n"], Some("d"), "diode", "unknown") },
            Self::Zener => &const { dev(&["zener"], b'D', &["p", "n"], Some("d"), "zener", "unknown") },

            // ── MOSFETs ──
            Self::Nmos3 => &const { dev(&["nmos3"], b'M', &["d", "g", "s"], Some("nch"), "nmos", "nmos") },
            Self::Pmos3 => &const { dev(&["pmos3"], b'M', &["d", "g", "s"], Some("pch"), "pmos", "pmos") },
            Self::Nmos4 => &const { dev(&["nmos4", "nmos"], b'M', &["d", "g", "s", "b"], Some("nch"), "nmos", "nmos") },
            Self::Pmos4 => &const { dev(&["pmos4", "pmos"], b'M', &["d", "g", "s", "b"], Some("pch"), "pmos", "pmos") },
            Self::Nmos4Depl => &const { dev(&["nmos4_depl"], b'M', &["d", "g", "s", "b"], Some("nch"), "nmos", "nmos") },
            Self::NmosSub => &const { dev(&["nmos_sub"], b'M', &["d", "g", "s"], Some("nch"), "nmos", "nmos") },
            Self::PmosSub => &const { dev(&["pmos_sub"], b'M', &["d", "g", "s"], Some("pch"), "pmos", "pmos") },
            Self::Nmoshv4 => &const { dev(&["nmoshv4"], b'M', &["d", "g", "s", "b"], Some("nch"), "nmos", "nmos") },
            Self::Pmoshv4 => &const { dev(&["pmoshv4"], b'M', &["d", "g", "s", "b"], Some("pch"), "pmos", "pmos") },
            Self::Rnmos4 => &const { dev(&["rnmos4"], b'M', &["d", "g", "s", "b"], Some("nch"), "nmos", "nmos") },

            // ── BJTs ──
            Self::Npn => &const { dev(&["npn", "npn2"], b'Q', &["c", "b", "e"], Some("npn"), "npn", "npn") },
            Self::Pnp => &const { dev(&["pnp", "pnp2"], b'Q', &["c", "b", "e"], Some("pnp"), "pnp", "pnp") },

            // ── JFETs / MESFET ──
            Self::Njfet => &const { dev(&["njfet", "jfet"], b'J', &["d", "g", "s"], Some("njf"), "njfet", "njfet") },
            Self::Pjfet => &const { dev(&["pjfet"], b'J', &["d", "g", "s"], Some("pjf"), "pjfet", "pjfet") },
            Self::Mesfet => &const { dev(&["mesfet"], b'Z', &["d", "g", "s"], Some("NMF"), "mesfet", "unknown") },

            // ── Sources ──
            Self::Vsource => &const { dev(&["vsource", "voltage_source"], b'V', &["p", "n"], None, "vsource", "unknown") },
            Self::Isource => &const { dev(&["isource", "current_source"], b'I', &["p", "n"], None, "isource", "unknown") },
            // Sqwsource: legacy square-wave marker — draws like a vsource but
            // is never netlisted.
            Self::Sqwsource => &const { DeviceSpec {
                netlisted: false,
                ..dev(&["sqwsource"], b'V', &["p", "n"], None, "vsource", "unknown")
            } },
            Self::Ammeter => &const { dev(&["ammeter"], b'I', &["p", "n"], None, "ammeter", "unknown") },
            Self::Behavioral => &const { dev(&["behavioral", "bsource"], b'V', &["p", "n"], None, "vsource", "unknown") },

            // ── Controlled sources ──
            Self::Vcvs => &const { dev(&["vcvs"], b'E', &["p", "n", "cp", "cn"], None, "vcvs", "unknown") },
            Self::Vccs => &const { dev(&["vccs"], b'G', &["p", "n", "cp", "cn"], None, "vccs", "unknown") },
            Self::Ccvs => &const { dev(&["ccvs"], b'H', &["p", "n", "cp", "cn"], None, "ccvs", "unknown") },
            Self::Cccs => &const { dev(&["cccs"], b'F', &["p", "n", "cp", "cn"], None, "cccs", "unknown") },

            // ── Transmission / coupling ──
            Self::Coupling => &const { dev(&["coupling"], b'K', &["l1", "l2"], None, "coupling", "unknown") },
            Self::Tline => &const { dev(&["tline"], b'T', &["p1p", "p1n", "p2p", "p2n"], None, "tline", "unknown") },
            Self::TlineLossy => &const { dev(&["tline_lossy"], b'O', &["p1p", "p1n", "p2p", "p2n"], Some("LTRA"), "tline", "unknown") },

            // ── Switches ──
            Self::Vswitch => &const { dev(&["vswitch"], b'S', &["p", "n"], Some("SW"), "vswitch", "unknown") },
            Self::Iswitch => &const { dev(&["iswitch"], b'S', &["p", "n"], Some("CSW"), "iswitch", "unknown") },

            // ── Simulation / probes (annotations) ──
            Self::Param => &const { ann(&["param"], &[]) },
            Self::Probe => &const { DeviceSpec { pins: &["p"], ..ann(&["probe"], &[]) } },
            Self::ProbeDiff => &const { DeviceSpec { symbol: "probe", ..ann(&["probe_diff"], &[]) } },
            Self::Code => &const { ann(&["code"], &[]) },
            Self::Graph => &const { ann(&["graph"], &[]) },

            // ── HDL (OSDI / Verilog-A: 'N' device letter in ngspice) ──
            Self::Hdl => &const { dev(&["hdl", "verilog_a_block"], b'N', &[], None, "hdl", "unknown") },

            // ── Power connectors ──
            Self::Gnd => &const { DeviceSpec {
                names: &["gnd"],
                role: Role::Power,
                netlisted: false,
                prefix: 0,
                pins: &["gnd"],
                model_keyword: None,
                injected_net: Some("0"),
                symbol: "gnd",
                default_model: "unknown",
            } },
            Self::Vdd => &const { DeviceSpec {
                names: &["vdd"],
                role: Role::Power,
                netlisted: false,
                prefix: 0,
                pins: &["vdd"],
                model_keyword: None,
                injected_net: Some("VDD"),
                symbol: "vdd",
                default_model: "unknown",
            } },

            // ── Net label pins ──
            Self::LabPin => &const { DeviceSpec { role: Role::Label, ..ann(&["lab_pin"], &["pin"]) } },
            Self::InputPin => &const { DeviceSpec { role: Role::Label, ..ann(&["input_pin"], &["pin"]) } },
            Self::OutputPin => &const { DeviceSpec { role: Role::Label, ..ann(&["output_pin"], &["pin"]) } },
            Self::InoutPin => &const { DeviceSpec { role: Role::Label, ..ann(&["inout_pin"], &["pin"]) } },

            // ── Non-electrical annotations ──
            Self::Annotation => &const { ann(&["annotation"], &[]) },
            Self::Noconn => &const { ann(&["noconn"], &[]) },
            Self::Title => &const { ann(&["title"], &[]) },
            Self::Launcher => &const { ann(&["launcher"], &[]) },
            Self::RgbLed => &const { ann(&["rgb_led"], &[]) },
            Self::Generic => &const { ann(&["generic"], &[]) },

            // ── Hierarchical ──
            Self::DigitalInstance => &const { dev(&["digital_instance", "digital_block"], b'X', &[], None, "digital_instance", "unknown") },
            Self::Subckt => &const { dev(&["subckt", "subcircuit", "spice_block"], b'X', &[], None, "subckt", "unknown") },
        }
    }

    // ── Delegates: original API, now reading the spec table ──

    pub fn from_name(s: &str) -> Self {
        Self::ALL
            .iter()
            .copied()
            .find(|k| k.spec().names.contains(&s))
            .unwrap_or(Self::Unknown)
    }

    pub fn is_non_electrical(self) -> bool {
        self.spec().role != Role::Device
    }

    pub fn is_label(self) -> bool {
        self.spec().role == Role::Label
    }

    pub fn is_power(self) -> bool {
        self.spec().role == Role::Power
    }

    pub fn is_electrical(self) -> bool {
        self.spec().netlisted
    }

    /// SPICE element letter; 0 = no netlist line of its own.
    pub fn prefix(self) -> u8 {
        self.spec().prefix
    }

    pub fn default_pins(self) -> &'static [&'static str] {
        self.spec().pins
    }

    pub fn model_keyword(self) -> Option<&'static str> {
        self.spec().model_keyword
    }

    /// Net name a connector injects at its pin position (gnd -> "0").
    pub fn injected_net(self) -> Option<&'static str> {
        self.spec().injected_net
    }

    pub fn symbol_name(self) -> &'static str {
        self.spec().symbol
    }

    /// Fallback model name for netlisting when neither the instance nor the
    /// PDK provides one.
    pub fn default_model(self) -> &'static str {
        self.spec().default_model
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_kind_from_name() {
        assert_eq!(DeviceKind::from_name("resistor"), DeviceKind::Resistor);
        assert_eq!(DeviceKind::from_name("res"), DeviceKind::Resistor);
        assert_eq!(DeviceKind::from_name("nmos"), DeviceKind::Nmos4);
        assert_eq!(DeviceKind::from_name("nmos4"), DeviceKind::Nmos4);
        assert_eq!(DeviceKind::from_name("spice_block"), DeviceKind::Subckt);
        assert_eq!(DeviceKind::from_name("verilog_a_block"), DeviceKind::Hdl);
        assert_eq!(DeviceKind::from_name("no_such_device"), DeviceKind::Unknown);
        // round-trip: every kind's symbol_name parses back to a kind with the
        // same SPICE prefix (symbol_name collapses MOSFET variants).
        assert_eq!(
            DeviceKind::from_name(DeviceKind::Capacitor.symbol_name()),
            DeviceKind::Capacitor
        );
        assert_eq!(DeviceKind::Nmos4.prefix(), b'M');
        assert_eq!(DeviceKind::Subckt.prefix(), b'X');
        assert_eq!(DeviceKind::Nmos4.default_pins(), ["d", "g", "s", "b"]);
        assert_eq!(DeviceKind::Nmos4.model_keyword(), Some("nch"));
    }

    #[test]
    fn spec_table_roundtrip() {
        // Every alias maps back to its kind; no name claimed twice.
        let mut seen = std::collections::HashMap::new();
        for k in DeviceKind::ALL {
            for name in k.spec().names {
                assert_eq!(DeviceKind::from_name(name), k, "alias {name:?}");
                if let Some(prev) = seen.insert(*name, k) {
                    panic!("name {name:?} claimed by both {prev:?} and {k:?}");
                }
            }
        }
        // Every kind contributes at least one unique name.
        assert!(seen.len() >= DeviceKind::ALL.len());
    }

    #[test]
    fn spec_invariants() {
        for k in DeviceKind::ALL {
            let s = k.spec();
            assert!(!s.names.is_empty(), "{k:?} has no names");
            // Only Device-role kinds may be netlisted.
            if s.netlisted {
                assert_eq!(s.role, Role::Device, "{k:?} netlisted but not Device");
            }
            // injected_net only makes sense for power connectors.
            if s.injected_net.is_some() {
                assert_eq!(s.role, Role::Power, "{k:?} injects a net but isn't Power");
            }
        }
        // Spot-check the exceptions preserved from the old predicates.
        assert!(!DeviceKind::Unknown.is_electrical());
        assert!(!DeviceKind::Sqwsource.is_electrical());
        assert!(!DeviceKind::Unknown.is_non_electrical());
        assert!(!DeviceKind::Sqwsource.is_non_electrical());
        assert_eq!(DeviceKind::Gnd.injected_net(), Some("0"));
        assert_eq!(DeviceKind::VarResistor.default_pins(), &[] as &[&str]);
        assert_eq!(DeviceKind::Npn.default_model(), "npn");
        assert_eq!(DeviceKind::Resistor.default_model(), "unknown");
    }
}
