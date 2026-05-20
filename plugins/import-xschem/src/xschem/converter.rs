//! Convert XSchem intermediate representation into `ImportResult`.

use super::pdk_remap;
use super::props::{get_prop, parse_props};
use super::types::{XSchemDoc, XSchemElement};
use crate::result::*;
use crate::ParseError;

/// Convert a parsed XSchem document into an `ImportResult`.
pub fn convert(doc: &XSchemDoc) -> Result<ImportResult, ParseError> {
    let mut result = ImportResult::default();

    for elem in &doc.elements {
        match elem {
            XSchemElement::Version(_) => {}
            XSchemElement::Component {
                symbol,
                x,
                y,
                rotation,
                flip,
                props,
            } => {
                convert_component(symbol, *x, *y, *rotation, *flip, props, &mut result)?;
            }
            XSchemElement::Wire {
                x0,
                y0,
                x1,
                y1,
                props,
            } => {
                convert_wire(*x0, *y0, *x1, *y1, props, &mut result);
            }
            XSchemElement::Text {
                content,
                x,
                y,
                rotation,
                size,
                ..
            } => {
                convert_text(content, *x, *y, *rotation, *size, &mut result);
            }
            XSchemElement::Line {
                x0, y0, x1, y1, ..
            } => {
                result.lines.push(LineResult {
                    x0: *x0,
                    y0: *y0,
                    x1: *x1,
                    y1: *y1,
                });
            }
            XSchemElement::Box {
                x0, y0, x1, y1, ..
            } => {
                let w = *x1 - *x0;
                let h = *y1 - *y0;
                result.rects.push(RectResult {
                    x: *x0,
                    y: *y0,
                    width: w,
                    height: h,
                });
            }
            XSchemElement::Arc {
                cx,
                cy,
                r,
                start,
                sweep,
                ..
            } => {
                result.arcs.push(ArcResult {
                    cx: *cx,
                    cy: *cy,
                    radius: *r,
                    start_angle: *start,
                    sweep_angle: *sweep,
                });
            }
            XSchemElement::Pin {
                x,
                y,
                direction,
                props,
                ..
            } => {
                convert_pin(*x, *y, direction, props, &mut result);
            }
            XSchemElement::Global(_name) => {
                // Globals stored as schematic-level properties
            }
            XSchemElement::Spice(_content) => {
                // SPICE blocks stored as schematic-level properties
            }
        }
    }

    Ok(result)
}

// -- Component -> InstanceResult --

fn convert_component(
    symbol: &str,
    x: i32,
    y: i32,
    rotation: u8,
    flip: bool,
    props_str: &str,
    result: &mut ImportResult,
) -> Result<(), ParseError> {
    let props_map = parse_props(props_str);

    // Determine device kind: first try PDK model remap, then symbol path
    let model = get_prop(&props_map, "model")
        .or_else(|| get_prop(&props_map, "device"));

    let kind = if let Some(model_name) = model {
        if let Some(pdk) = pdk_remap::remap_model(model_name) {
            pdk.kind.to_string()
        } else {
            resolve_device_kind(symbol).to_string()
        }
    } else {
        resolve_device_kind(symbol).to_string()
    };

    let name = get_prop(&props_map, "name").unwrap_or("?").to_string();

    // Collect properties (excluding "name")
    let properties: Vec<PropertyResult> = props_map
        .iter()
        .filter(|(k, _)| k.as_str() != "name")
        .map(|(k, v)| PropertyResult {
            key: k.clone(),
            value: v.clone(),
        })
        .collect();

    result.instances.push(InstanceResult {
        name,
        symbol: symbol.to_string(),
        kind,
        x,
        y,
        rotation: rotation & 0x03,
        flip,
        properties,
    });

    Ok(())
}

// -- Wire -> WireResult --

fn convert_wire(
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    props_str: &str,
    result: &mut ImportResult,
) {
    let props_map = parse_props(props_str);
    let net_name = get_prop(&props_map, "lab").unwrap_or("").to_string();

    result.wires.push(WireResult {
        x0,
        y0,
        x1,
        y1,
        net_name,
        bus: false,
    });
}

// -- Text -> TextResult --

fn convert_text(
    content: &str,
    x: i32,
    y: i32,
    rotation: u8,
    size: f32,
    result: &mut ImportResult,
) {
    result.texts.push(TextResult {
        x,
        y,
        content: content.to_string(),
        font_size: size,
        rotation,
    });
}

// -- Pin -> PinResult --

fn convert_pin(
    x: i32,
    y: i32,
    direction: &str,
    props_str: &str,
    result: &mut ImportResult,
) {
    let props_map = parse_props(props_str);
    let pin_name = get_prop(&props_map, "name")
        .or_else(|| get_prop(&props_map, "lab"))
        .unwrap_or("?")
        .to_string();

    let dir = match direction {
        "in" | "input" => "input",
        "out" | "output" => "output",
        "inout" | "io" => "inout",
        "power" | "pwr" => "power",
        "ground" | "gnd" => "ground",
        _ => "inout",
    };

    result.pins.push(PinResult {
        name: pin_name,
        x,
        y,
        direction: dir.to_string(),
        width: 1,
    });
}

// -- Symbol path -> device kind string --

fn resolve_device_kind(symbol_path: &str) -> &'static str {
    match symbol_path.rsplit('/').next().unwrap_or("") {
        "res.sym" => "resistor",
        "cap.sym" => "capacitor",
        "ind.sym" => "inductor",
        "nmos.sym" | "nfet.sym" => "nmos4",
        "pmos.sym" | "pfet.sym" => "pmos4",
        "npn.sym" => "npn",
        "pnp.sym" => "pnp",
        "vsource.sym" | "vsrc.sym" => "vsource",
        "isource.sym" | "isrc.sym" => "isource",
        "gnd.sym" => "gnd",
        "vdd.sym" => "vdd",
        "lab_pin.sym" | "lab_wire.sym" => "lab_pin",
        "ipin.sym" => "input_pin",
        "opin.sym" => "output_pin",
        "iopin.sym" => "inout_pin",
        "vcvs.sym" => "vcvs",
        "vccs.sym" => "vccs",
        "ccvs.sym" => "ccvs",
        "cccs.sym" => "cccs",
        "diode.sym" => "diode",
        "zener.sym" => "zener",
        "njfet.sym" => "njfet",
        "pjfet.sym" => "pjfet",
        "ammeter.sym" => "ammeter",
        "noconn.sym" => "noconn",
        "title.sym" => "title",
        "launcher.sym" => "launcher",
        "code.sym" | "code_shown.sym" => "code",
        _ => "subckt",
    }
}

// -- Tests --

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_resistor() {
        assert_eq!(resolve_device_kind("devices/res.sym"), "resistor");
        assert_eq!(
            resolve_device_kind("/usr/share/xschem/xschem_library/devices/res.sym"),
            "resistor"
        );
    }

    #[test]
    fn resolve_nmos() {
        assert_eq!(resolve_device_kind("devices/nmos.sym"), "nmos4");
        assert_eq!(resolve_device_kind("devices/nfet.sym"), "nmos4");
    }

    #[test]
    fn resolve_labels() {
        assert_eq!(resolve_device_kind("devices/lab_pin.sym"), "lab_pin");
        assert_eq!(resolve_device_kind("devices/ipin.sym"), "input_pin");
        assert_eq!(resolve_device_kind("devices/opin.sym"), "output_pin");
        assert_eq!(resolve_device_kind("devices/iopin.sym"), "inout_pin");
    }

    #[test]
    fn resolve_power() {
        assert_eq!(resolve_device_kind("devices/gnd.sym"), "gnd");
        assert_eq!(resolve_device_kind("devices/vdd.sym"), "vdd");
    }

    #[test]
    fn resolve_unknown() {
        assert_eq!(resolve_device_kind("my_pdk/my_custom.sym"), "subckt");
    }

    #[test]
    fn convert_component_creates_instance() {
        let doc = XSchemDoc {
            version: Some("3.4.5".into()),
            elements: vec![XSchemElement::Component {
                symbol: "devices/res.sym".into(),
                x: 100,
                y: 200,
                rotation: 0,
                flip: false,
                props: "name=R1 value=10k".into(),
            }],
            metadata: vec![],
        };

        let result = convert(&doc).unwrap();
        assert_eq!(result.instances.len(), 1);
        assert_eq!(result.instances[0].x, 100);
        assert_eq!(result.instances[0].y, 200);
        assert_eq!(result.instances[0].kind, "resistor");
        assert_eq!(result.instances[0].rotation, 0);
        assert!(!result.instances[0].flip);
    }

    #[test]
    fn convert_wire_creates_wire() {
        let doc = XSchemDoc {
            version: None,
            elements: vec![XSchemElement::Wire {
                x0: 10,
                y0: 20,
                x1: 30,
                y1: 40,
                props: "lab=VCC".into(),
            }],
            metadata: vec![],
        };

        let result = convert(&doc).unwrap();
        assert_eq!(result.wires.len(), 1);
        assert_eq!(result.wires[0].x0, 10);
        assert_eq!(result.wires[0].y0, 20);
        assert_eq!(result.wires[0].x1, 30);
        assert_eq!(result.wires[0].y1, 40);
        assert_eq!(result.wires[0].net_name, "VCC");
    }

    #[test]
    fn convert_component_with_rotation_and_flip() {
        let doc = XSchemDoc {
            version: None,
            elements: vec![XSchemElement::Component {
                symbol: "devices/cap.sym".into(),
                x: 300,
                y: 400,
                rotation: 2,
                flip: true,
                props: "name=C1 value=1u".into(),
            }],
            metadata: vec![],
        };

        let result = convert(&doc).unwrap();
        assert_eq!(result.instances[0].kind, "capacitor");
        assert_eq!(result.instances[0].rotation, 2);
        assert!(result.instances[0].flip);
    }

    #[test]
    fn convert_pdk_model_overrides_symbol() {
        let doc = XSchemDoc {
            version: None,
            elements: vec![XSchemElement::Component {
                symbol: "some/custom/nfet.sym".into(),
                x: 0,
                y: 0,
                rotation: 0,
                flip: false,
                props: "name=M1 model=sky130_fd_pr__nfet_01v8".into(),
            }],
            metadata: vec![],
        };

        let result = convert(&doc).unwrap();
        assert_eq!(result.instances[0].kind, "nmos4");
    }

    #[test]
    fn convert_text_element() {
        let doc = XSchemDoc {
            version: None,
            elements: vec![XSchemElement::Text {
                content: "Hello".into(),
                x: 50,
                y: 60,
                rotation: 1,
                flip: false,
                size: 0.4,
                props: String::new(),
            }],
            metadata: vec![],
        };

        let result = convert(&doc).unwrap();
        assert_eq!(result.texts.len(), 1);
        assert_eq!(result.texts[0].x, 50);
        assert_eq!(result.texts[0].y, 60);
        assert_eq!(result.texts[0].rotation, 1);
    }

    #[test]
    fn convert_geometric_primitives() {
        let doc = XSchemDoc {
            version: None,
            elements: vec![
                XSchemElement::Line { layer: 4, x0: 0, y0: 0, x1: 100, y1: 100 },
                XSchemElement::Box { layer: 5, x0: 10, y0: 20, x1: 110, y1: 120 },
                XSchemElement::Arc { layer: 4, cx: 50, cy: 50, r: 25, start: 0.0, sweep: 360.0 },
            ],
            metadata: vec![],
        };

        let result = convert(&doc).unwrap();
        assert_eq!(result.lines.len(), 1);
        assert_eq!(result.rects.len(), 1);
        assert_eq!(result.rects[0].width, 100);
        assert_eq!(result.rects[0].height, 100);
        assert_eq!(result.arcs.len(), 1);
        assert_eq!(result.arcs[0].radius, 25);
    }
}
