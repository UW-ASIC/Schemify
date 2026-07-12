//! `.chn` serializer — see `parse.rs` for the reader.

use std::fmt::Write as _;

use lasso::Rodeo;

use crate::*;

/// Format version stamped into file headers.
const CHN_VERSION: u8 = 2;

/// Serialize a Schematic to CHN format.
/// Returns None on write error (should not happen with String buffer).
pub fn write_chn(sch: &Schematic, int: &Rodeo) -> Option<String> {
    let mut buf = String::with_capacity(4096);
    write_chn_impl(&mut buf, sch, int).ok()?;
    Some(buf)
}

fn write_chn_impl(w: &mut String, s: &Schematic, int: &Rodeo) -> std::fmt::Result {
    // Header
    match s.stype {
        SchematicType::Primitive => writeln!(w, "chn_prim {CHN_VERSION}")?,
        SchematicType::Testbench => writeln!(w, "chn_testbench {CHN_VERSION}")?,
        _ => writeln!(w, "chn {CHN_VERSION}")?,
    }

    // Top-level declaration
    match s.stype {
        SchematicType::Symbol | SchematicType::Primitive => {
            let name = if s.name.is_empty() {
                "untitled"
            } else {
                &s.name
            };
            writeln!(w, "\nSYMBOL {name}")?;
            write_sym_metadata(w, s, int)?;
        }
        SchematicType::Testbench => {
            let name = if s.name.is_empty() {
                "untitled"
            } else {
                &s.name
            };
            writeln!(w, "\nTESTBENCH {name}")?;
            write_testbench_metadata(w, s)?;
        }
        SchematicType::Schematic => {
            writeln!(w, "\nSCHEMATIC")?;
        }
    }

    write_pins(w, s, int)?;
    write_params(w, s, int)?;
    write_instances(w, s, int)?;
    write_wires(w, s, int)?;
    write_buses(w, s, int)?;
    write_bus_rippers(w, s)?;
    write_drawing(w, s, int)?;
    write_code_block(w, s)?;
    write_plugin_blocks(w, s, int)?;
    write_pyspice(w, s)?;
    write_documentation(w, s)?;

    Ok(())
}

fn write_sym_metadata(w: &mut String, s: &Schematic, int: &Rodeo) -> std::fmt::Result {
    for prop in &s.sym_properties {
        let key = int.resolve(&prop.key);
        let val = int.resolve(&prop.value);
        if key == "description" {
            writeln!(w, "  desc: {val}")?;
        } else if key == "type" {
            writeln!(w, "  type: {val}")?;
        }
    }
    Ok(())
}

fn write_testbench_metadata(w: &mut String, s: &Schematic) -> std::fmt::Result {
    if s.stimulus_lang != StimulusLang::default() {
        writeln!(w, "  stimulus_lang: {}", s.stimulus_lang.as_str())?;
    }
    if s.sim_backend != SpiceBackend::default() {
        writeln!(w, "  sim_backend: {}", s.sim_backend.as_str())?;
    }
    if !s.sim_corner.is_empty() {
        writeln!(w, "  sim_corner: {}", s.sim_corner)?;
    }
    Ok(())
}

fn write_pins(w: &mut String, s: &Schematic, int: &Rodeo) -> std::fmt::Result {
    if s.pins.is_empty() {
        return Ok(());
    }
    writeln!(w, "  pins:")?;
    for pin in &s.pins {
        let name = int.resolve(&pin.name);
        let dir = pin_dir_str(pin.direction);
        write!(w, "    {name}  {dir}")?;
        if pin.x != 0 || pin.y != 0 {
            write!(w, "  x={}  y={}", pin.x, pin.y)?;
        }
        if pin.width > 1 {
            write!(w, "  width={}", pin.width)?;
        }
        writeln!(w)?;
    }
    Ok(())
}

fn write_params(w: &mut String, s: &Schematic, int: &Rodeo) -> std::fmt::Result {
    let params: Vec<_> = s
        .sym_properties
        .iter()
        .filter(|p| !is_metadata(int.resolve(&p.key)))
        .collect();
    if params.is_empty() {
        return Ok(());
    }
    writeln!(w, "  params:")?;
    for p in params {
        let key = int.resolve(&p.key);
        let val = int.resolve(&p.value);
        writeln!(w, "    {key} = {val}")?;
    }
    Ok(())
}

fn write_instances(w: &mut String, s: &Schematic, int: &Rodeo) -> std::fmt::Result {
    if s.instances.is_empty() {
        return Ok(());
    }
    writeln!(w, "  instances:")?;

    for i in 0..s.instances.len() {
        let name = int.resolve(&s.instances.name[i]);
        let kind = s.instances.kind[i];
        let x = s.instances.x[i];
        let y = s.instances.y[i];
        let flags = s.instances.flags[i];
        let symbol = int.resolve(&s.instances.symbol[i]);
        let ps = s.instances.prop_start[i] as usize;
        let pc = s.instances.prop_count[i] as usize;

        let kind_name = kind_to_name(kind, symbol);
        write!(w, "    {name}  {kind_name}  x={x}  y={y}")?;

        let rot = flags.rotation();
        if rot != 0 {
            write!(w, "  rot={rot}")?;
        }
        if flags.flip() {
            write!(w, "  flip=1")?;
        }
        // Symbol override if kind_name differs
        if kind_name != symbol && !symbol.is_empty() {
            write!(w, "  sym={symbol}")?;
        }

        // Properties
        if pc > 0 {
            let props = &s.properties[ps..ps + pc];
            let non_structural: Vec<_> = props
                .iter()
                .filter(|p| !is_structural(int.resolve(&p.key)))
                .collect();
            if non_structural.len() > 3 {
                write!(w, "  .parameters{{ ")?;
                for (j, p) in non_structural.iter().enumerate() {
                    if j > 0 {
                        write!(w, "  ")?;
                    }
                    let k = int.resolve(&p.key);
                    let v = int.resolve(&p.value);
                    write!(w, "{k}={v}")?;
                }
                write!(w, " }}")?;
            } else {
                for p in &non_structural {
                    let k = int.resolve(&p.key);
                    let v = int.resolve(&p.value);
                    if v.contains(' ') || v.contains('(') {
                        write!(w, "  {k}=\"{v}\"")?;
                    } else {
                        write!(w, "  {k}={v}")?;
                    }
                }
            }
        }
        writeln!(w)?;
    }
    Ok(())
}

fn write_wires(w: &mut String, s: &Schematic, int: &Rodeo) -> std::fmt::Result {
    if s.wires.is_empty() {
        return Ok(());
    }
    writeln!(w, "\n  wires:")?;
    for i in 0..s.wires.len() {
        let x0 = s.wires.x0[i];
        let y0 = s.wires.y0[i];
        let x1 = s.wires.x1[i];
        let y1 = s.wires.y1[i];

        // Skip zero-length
        if x0 == x1 && y0 == y1 {
            continue;
        }

        write!(w, "    {x0} {y0} {x1} {y1}")?;

        if let Some(sym) = s.wires.net_name[i] {
            let net_name = int.resolve(&sym);
            if !net_name.is_empty() {
                write!(w, " {net_name}")?;
            }
        }

        let color = s.wires.color[i];
        if !color.is_none() {
            write!(w, " color=#{:02X}{:02X}{:02X}", color.r, color.g, color.b)?;
        }
        writeln!(w)?;
    }
    Ok(())
}

fn write_buses(w: &mut String, s: &Schematic, int: &Rodeo) -> std::fmt::Result {
    if s.buses.is_empty() {
        return Ok(());
    }
    writeln!(w, "  buses:")?;
    for i in 0..s.buses.len() {
        let label = int.resolve(&s.buses.label[i]);
        let width = s.buses.width[i];
        let start_bit = s.buses.start_bit[i];
        let x0 = s.buses.x0[i];
        let y0 = s.buses.y0[i];
        let x1 = s.buses.x1[i];
        let y1 = s.buses.y1[i];

        write!(w, "    {label} {width} {start_bit} {x0} {y0} {x1} {y1}")?;

        let color = s.buses.color[i];
        if !color.is_none() {
            write!(w, " color=#{:02X}{:02X}{:02X}", color.r, color.g, color.b)?;
        }
        writeln!(w)?;
    }
    Ok(())
}

fn write_bus_rippers(w: &mut String, s: &Schematic) -> std::fmt::Result {
    if s.bus_rippers.is_empty() {
        return Ok(());
    }
    writeln!(w, "  bus_rippers:")?;
    for r in &s.bus_rippers {
        writeln!(
            w,
            "    {} {} {} {} dir={} stub={}",
            r.bus_idx, r.bit, r.x, r.y, r.direction, r.stub_len
        )?;
    }
    Ok(())
}

fn write_drawing(w: &mut String, s: &Schematic, int: &Rodeo) -> std::fmt::Result {
    let has_any = !s.lines.is_empty()
        || !s.rects.is_empty()
        || !s.circles.is_empty()
        || !s.arcs.is_empty()
        || !s.texts.is_empty()
        || !s.polygons.is_empty();
    if !has_any {
        return Ok(());
    }
    writeln!(w, "  drawing:")?;
    for l in &s.lines {
        writeln!(w, "    line {} {} {} {}", l.x0, l.y0, l.x1, l.y1)?;
    }
    for r in &s.rects {
        writeln!(
            w,
            "    rect {} {} {} {}",
            r.x,
            r.y,
            r.x + r.width,
            r.y + r.height
        )?;
    }
    for c in &s.circles {
        writeln!(w, "    circle {} {} {}", c.cx, c.cy, c.radius)?;
    }
    for a in &s.arcs {
        writeln!(
            w,
            "    arc {} {} {} {} {}",
            a.cx, a.cy, a.radius, a.start_angle as i32, a.sweep_angle as i32
        )?;
    }
    for t in &s.texts {
        let content = int.resolve(&t.content);
        write!(
            w,
            "    text {} {} {} {} \"{}\"",
            t.x, t.y, t.font_size as i32, t.rotation, content
        )?;
        if !t.color.is_none() {
            write!(
                w,
                " color=#{:02X}{:02X}{:02X}",
                t.color.r, t.color.g, t.color.b
            )?;
        }
        writeln!(w)?;
    }
    for p in &s.polygons {
        write!(w, "    polygon")?;
        for pt in &p.points {
            write!(w, " {},{}", pt[0], pt[1])?;
        }
        if p.thickness > 0 {
            write!(w, " thickness={}", p.thickness)?;
        }
        if !p.fill.is_none() {
            write!(w, " fill=#{:02X}{:02X}{:02X}", p.fill.r, p.fill.g, p.fill.b)?;
        }
        if !p.stroke.is_none() {
            write!(
                w,
                " stroke=#{:02X}{:02X}{:02X}",
                p.stroke.r, p.stroke.g, p.stroke.b
            )?;
        }
        writeln!(w)?;
    }
    Ok(())
}

fn write_code_block(w: &mut String, s: &Schematic) -> std::fmt::Result {
    if s.spice_body.is_empty() {
        return Ok(());
    }
    writeln!(w, "  code:")?;
    for line in s.spice_body.lines() {
        writeln!(w, "    {line}")?;
    }
    Ok(())
}

fn write_plugin_blocks(w: &mut String, s: &Schematic, int: &Rodeo) -> std::fmt::Result {
    for pb in &s.plugin_blocks {
        let name = int.resolve(&pb.name);
        writeln!(w, "\nPLUGIN {name}")?;
        for e in &pb.entries {
            let key = int.resolve(&e.key);
            let val = int.resolve(&e.value);
            if val.contains('\n') {
                writeln!(w, "  {key}: |")?;
                for line in val.lines() {
                    writeln!(w, "    {line}")?;
                }
            } else {
                writeln!(w, "  {key}: {val}")?;
            }
        }
    }
    Ok(())
}

fn write_pyspice(w: &mut String, s: &Schematic) -> std::fmt::Result {
    if s.pyspice_source.is_empty() {
        return Ok(());
    }
    writeln!(w, "\nPYSPICE")?;
    for line in s.pyspice_source.lines() {
        writeln!(w, "  {line}")?;
    }
    Ok(())
}

fn write_documentation(w: &mut String, s: &Schematic) -> std::fmt::Result {
    if s.documentation.is_empty() {
        return Ok(());
    }
    writeln!(w, "\nDOCUMENTATION")?;
    for line in s.documentation.lines() {
        writeln!(w, "  {line}")?;
    }
    Ok(())
}

// ── Writer helpers ──────────────────────────────────────────────────────────

fn pin_dir_str(dir: PinDirection) -> &'static str {
    match dir {
        PinDirection::Input => "in",
        PinDirection::Output => "out",
        PinDirection::InOut => "inout",
        PinDirection::Power => "power",
        PinDirection::Ground => "ground",
    }
}

fn kind_to_name(kind: DeviceKind, symbol: &str) -> &str {
    // Preserve the specific symbol name (nmos3, nmos4, ...) if already set;
    // otherwise fall back to the canonical symbol name.
    if symbol.is_empty() {
        kind.symbol_name()
    } else {
        symbol
    }
}

fn is_metadata(key: &str) -> bool {
    matches!(
        key,
        "description" | "type" | "spice_body" | "include" | "spice_prefix"
    ) || key.starts_with("ann.")
        || key.starts_with("analysis.")
        || key.starts_with("measure.")
}

fn is_structural(key: &str) -> bool {
    matches!(key, "x" | "y" | "rot" | "flip" | "sym" | "name")
}

// ====================================================
// Tests
// ====================================================


#[cfg(test)]
mod tests {
    use super::*;
    use lasso::Rodeo;

    #[test]
    fn chn_round_trip() {
        let mut int = Rodeo::default();
        let mut sch = Schematic {
            stype: SchematicType::Schematic,
            ..Default::default()
        };

        // Instance with properties
        let prop_start = sch.properties.len() as u32;
        sch.properties.push(Property {
            key: int.get_or_intern("W"),
            value: int.get_or_intern("1u"),
        });
        sch.properties.push(Property {
            key: int.get_or_intern("L"),
            value: int.get_or_intern("150n"),
        });
        sch.instances.push(Instance {
            name: int.get_or_intern("M1"),
            symbol: int.get_or_intern("nmos4"),
            x: 100,
            y: -40,
            kind: DeviceKind::Nmos4,
            flags: InstanceFlags::new(1, true),
            prop_start,
            prop_count: 2,
        });

        // Named + colored wire, plain wire
        sch.wires.push(Wire {
            net_name: Some(int.get_or_intern("vout")),
            x0: 0,
            y0: 0,
            x1: 100,
            y1: 0,
            color: Color::rgb(255, 0, 128),
            thickness: 0,
        });
        sch.wires.push(Wire {
            net_name: None,
            x0: 100,
            y0: 0,
            x1: 100,
            y1: -40,
            color: Color::NONE,
            thickness: 0,
        });

        // Bus + ripper
        sch.buses.push(Bus {
            label: int.get_or_intern("data"),
            width: 8,
            start_bit: 0,
            x0: 10,
            y0: 20,
            x1: 200,
            y1: 20,
            color: Color::rgb(0, 0, 255),
            thickness: 0,
        });
        sch.bus_rippers.push(BusRipper {
            bus_idx: 0,
            bit: 3,
            x: 50,
            y: 20,
            direction: 1,
            stub_len: 15,
        });

        // Drawing items
        sch.lines.push(Line {
            x0: 0,
            y0: 0,
            x1: 10,
            y1: 10,
            color: Color::NONE,
            thickness: 0,
        });
        sch.texts.push(Text {
            x: 5,
            y: -3,
            content: int.get_or_intern("Hello World"),
            font_size: 14.0,
            color: Color::rgb(1, 2, 3),
            rotation: 1,
        });
        sch.polygons.push(Polygon {
            points: vec![[0, 0], [10, 0], [10, 10]],
            fill: Color::rgb(100, 200, 50),
            stroke: Color::rgb(0, 0, 0),
            thickness: 3,
        });

        sch.spice_body = ".tran 1n 1u\n.ic v(vout)=0".to_string();

        let chn = write_chn(&sch, &int).expect("write_chn failed");

        let mut int2 = Rodeo::default();
        let (sch2, warnings) = read_chn_report(&chn, &mut int2);
        assert!(warnings.is_empty(), "round-trip warnings: {warnings:?}");

        // Instance
        assert_eq!(sch2.instances.len(), 1);
        assert_eq!(int2.resolve(&sch2.instances.name[0]), "M1");
        assert_eq!(int2.resolve(&sch2.instances.symbol[0]), "nmos4");
        assert_eq!(sch2.instances.kind[0], DeviceKind::Nmos4);
        assert_eq!(sch2.instances.x[0], 100);
        assert_eq!(sch2.instances.y[0], -40);
        assert_eq!(sch2.instances.flags[0].rotation(), 1);
        assert!(sch2.instances.flags[0].flip());
        let props = sch2.instance_props(0);
        assert_eq!(props.len(), 2);
        assert_eq!(int2.resolve(&props[0].key), "W");
        assert_eq!(int2.resolve(&props[0].value), "1u");

        // Wires
        assert_eq!(sch2.wires.len(), 2);
        assert_eq!(
            sch2.wires.net_name[0].map(|s| int2.resolve(&s)),
            Some("vout")
        );
        assert_eq!(sch2.wires.color[0], Color::rgb(255, 0, 128));
        assert_eq!(sch2.wires.net_name[1], None);
        assert_eq!(
            (
                sch2.wires.x0[1],
                sch2.wires.y0[1],
                sch2.wires.x1[1],
                sch2.wires.y1[1]
            ),
            (100, 0, 100, -40)
        );

        // Bus + ripper
        assert_eq!(sch2.buses.len(), 1);
        assert_eq!(int2.resolve(&sch2.buses.label[0]), "data");
        assert_eq!(sch2.buses.width[0], 8);
        assert_eq!(sch2.buses.color[0], Color::rgb(0, 0, 255));
        assert_eq!(sch2.bus_rippers.len(), 1);
        assert_eq!(sch2.bus_rippers[0].bit, 3);
        assert_eq!(sch2.bus_rippers[0].stub_len, 15);

        // Drawing
        assert_eq!(sch2.lines.len(), 1);
        assert_eq!(sch2.texts.len(), 1);
        assert_eq!(int2.resolve(&sch2.texts[0].content), "Hello World");
        assert_eq!(sch2.texts[0].color, Color::rgb(1, 2, 3));
        assert_eq!(sch2.polygons.len(), 1);
        assert_eq!(sch2.polygons[0].points, vec![[0, 0], [10, 0], [10, 10]]);
        assert_eq!(sch2.polygons[0].thickness, 3);

        // Code block
        assert_eq!(sch2.spice_body, ".tran 1n 1u\n.ic v(vout)=0");

        // Second pass is a fixpoint: write(read(x)) == x.
        let chn2 = write_chn(&sch2, &int2).expect("second write failed");
        assert_eq!(chn, chn2, "writer is not a fixpoint of the reader");
    }

    #[test]
    fn reader_degrades_gracefully() {
        let input = "chn 3\n\nSCHEMATIC\n  future_stuff:\n    foo bar\n  wires:\n    0 0 bad 10\n    0 0 10 10\n";
        let mut int = Rodeo::default();
        let (sch, warnings) = read_chn_report(input, &mut int);
        // Unknown section skipped, malformed coordinate defaulted — both warned.
        assert!(warnings.iter().any(|w| w.msg.contains("unknown section")));
        assert!(warnings.iter().any(|w| w.msg.contains("invalid wire x1")));
        assert_eq!(sch.wires.len(), 2); // bad wire kept with defaulted coord
    }

    #[test]
    fn testbench_metadata_round_trip() {
        let int = Rodeo::default();
        let sch = Schematic {
            stype: SchematicType::Testbench,
            name: "tb_amp".to_string(),
            stimulus_lang: StimulusLang::Xyce,
            sim_backend: SpiceBackend::Xyce,
            sim_corner: "ss".to_string(),
            ..Default::default()
        };
        let chn = write_chn(&sch, &int).expect("write failed");
        let mut int2 = Rodeo::default();
        let (sch2, _) = read_chn_report(&chn, &mut int2);
        assert_eq!(sch2.stype, SchematicType::Testbench);
        assert_eq!(sch2.name, "tb_amp");
        assert_eq!(sch2.stimulus_lang, StimulusLang::Xyce);
        assert_eq!(sch2.sim_backend, SpiceBackend::Xyce);
        assert_eq!(sch2.sim_corner, "ss");
    }
}
