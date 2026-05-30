use std::fmt::Write;

use lasso::Rodeo;

use schemify_core::schematic::*;
use schemify_core::simulation::{SpiceBackend, StimulusLang};
use schemify_core::types::*;

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
        SchematicType::Primitive => writeln!(w, "chn_prim 1")?,
        SchematicType::Testbench => writeln!(w, "chn_testbench 1")?,
        _ => writeln!(w, "chn 1")?,
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
    write_drawing(w, s, int)?;
    write_code_block(w, s)?;
    write_plugin_blocks(w, s, int)?;
    write_pyspice(w, s)?;
    write_documentation(w, s)?;

    Ok(())
}

// ====================================================
// Section Writers
// ====================================================

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
                write!(w, "\n      .parameters{{ ")?;
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
                    write!(w, "  {k}={v}")?;
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

        if s.wires.bus[i] {
            write!(w, " bus=1")?;
        }
        let color = s.wires.color[i];
        if !color.is_none() {
            write!(w, " color=#{:02X}{:02X}{:02X}", color.r, color.g, color.b)?;
        }
        let nn = int.resolve(&s.wires.net_name[i]);
        if !nn.is_empty() {
            write!(w, " {nn}")?;
        }
        writeln!(w)?;
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

// ====================================================
// Helpers
// ====================================================

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
    // For MOSFET variants, preserve the specific symbol name (nmos3, nmos4, etc.)
    // if already set; otherwise fall back to the canonical symbol name.
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::reader::read_chn;

    fn sym_schematic(name: &str) -> Schematic {
        Schematic {
            stype: SchematicType::Symbol,
            name: name.to_string(),
            ..Default::default()
        }
    }

    #[test]
    fn text_roundtrip() {
        let mut int = Rodeo::default();
        let mut sch = sym_schematic("test_sym");
        sch.texts.push(Text {
            x: 10,
            y: 20,
            content: int.get_or_intern("Hello World"),
            font_size: 14.0,
            color: Color::NONE,
            rotation: 1,
        });

        let chn = write_chn(&sch, &int).expect("write_chn failed");
        let mut int2 = Rodeo::default();
        let sch2 = read_chn(&chn, &mut int2);

        assert_eq!(sch2.texts.len(), 1, "text not preserved on roundtrip");
        let t = &sch2.texts[0];
        assert_eq!(t.x, 10);
        assert_eq!(t.y, 20);
        assert_eq!(int2.resolve(&t.content), "Hello World");
        assert_eq!(t.font_size, 14.0);
        assert_eq!(t.rotation, 1);
    }

    #[test]
    fn polygon_roundtrip() {
        let int = Rodeo::default();
        let mut sch = sym_schematic("test_sym");
        sch.polygons.push(Polygon {
            points: vec![[0, 0], [10, 0], [10, 10], [0, 10]],
            fill: Color::NONE,
            stroke: Color::NONE,
            thickness: 2,
        });

        let chn = write_chn(&sch, &int).expect("write_chn failed");
        let mut int2 = Rodeo::default();
        let sch2 = read_chn(&chn, &mut int2);

        assert_eq!(sch2.polygons.len(), 1, "polygon not preserved on roundtrip");
        let p = &sch2.polygons[0];
        assert_eq!(p.points, vec![[0, 0], [10, 0], [10, 10], [0, 10]]);
        assert_eq!(p.thickness, 2);
    }

    #[test]
    fn text_with_color_roundtrip() {
        let mut int = Rodeo::default();
        let mut sch = sym_schematic("test_sym");
        sch.texts.push(Text {
            x: 5,
            y: -3,
            content: int.get_or_intern("VDD"),
            font_size: 10.0,
            color: Color::rgb(255, 0, 128),
            rotation: 0,
        });

        let chn = write_chn(&sch, &int).expect("write_chn failed");
        let mut int2 = Rodeo::default();
        let sch2 = read_chn(&chn, &mut int2);

        assert_eq!(sch2.texts.len(), 1);
        let t = &sch2.texts[0];
        assert_eq!(t.x, 5);
        assert_eq!(t.y, -3);
        assert_eq!(int2.resolve(&t.content), "VDD");
        assert_eq!(t.color, Color::rgb(255, 0, 128));
    }

    #[test]
    fn polygon_with_colors_roundtrip() {
        let int = Rodeo::default();
        let mut sch = sym_schematic("test_sym");
        sch.polygons.push(Polygon {
            points: vec![[0, 0], [5, 10], [10, 0]],
            fill: Color::rgb(100, 200, 50),
            stroke: Color::rgb(0, 0, 0),
            thickness: 3,
        });

        let chn = write_chn(&sch, &int).expect("write_chn failed");
        let mut int2 = Rodeo::default();
        let sch2 = read_chn(&chn, &mut int2);

        assert_eq!(sch2.polygons.len(), 1);
        let p = &sch2.polygons[0];
        assert_eq!(p.points, vec![[0, 0], [5, 10], [10, 0]]);
        assert_eq!(p.fill, Color::rgb(100, 200, 50));
        assert_eq!(p.stroke, Color::rgb(0, 0, 0));
        assert_eq!(p.thickness, 3);
    }

    #[test]
    fn mixed_drawing_roundtrip() {
        let mut int = Rodeo::default();
        let mut sch = sym_schematic("test_sym");

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
            y: 5,
            content: int.get_or_intern("label"),
            font_size: 12.0,
            color: Color::NONE,
            rotation: 0,
        });
        sch.polygons.push(Polygon {
            points: vec![[0, 0], [1, 2], [3, 4]],
            fill: Color::NONE,
            stroke: Color::NONE,
            thickness: 0,
        });

        let chn = write_chn(&sch, &int).expect("write_chn failed");
        let mut int2 = Rodeo::default();
        let sch2 = read_chn(&chn, &mut int2);

        assert_eq!(sch2.lines.len(), 1);
        assert_eq!(sch2.texts.len(), 1);
        assert_eq!(sch2.polygons.len(), 1);
    }
}
