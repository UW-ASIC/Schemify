//! Fixture gallery rendered through the adapter itself: each PySpice fixture
//! goes netlist → `netlist_to_circuit` → `emit::schematic_from_subcircuit`
//! → core `Schematic`, drawn with the real embedded `.chn_prim` symbol art —
//! the same geometry + `InstanceFlags::transform_point` convention as the GUI
//! canvas (`gui/src/canvas/render.rs::draw_prim_geometry`). What you see is
//! what Schemify opens. cktImg's own SVG stays one click away as reference.
//!
//! Run from the workspace root, inside `nix develop`:
//!     cargo visualize-net2schem [name-filter]
//! Output: target/net2schem-gallery/ served on http://localhost:8732/
//! Set VISUALIZE_NO_SERVE=1 to render without the blocking dev server.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::Command;

use lasso::Rodeo;
use schemify_net2schem::emit;
use schemify_schematic::{prims, Schematic};

fn main() -> anyhow::Result<()> {
    let filter = std::env::args().nth(1).unwrap_or_default();
    let pyspice_dir = std::env::var("PYSPICE_MODULE_DIR")
        .expect("set PYSPICE_MODULE_DIR — run inside `nix develop`");

    let fixture_root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixture");
    let out = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/net2schem-gallery");
    std::fs::create_dir_all(&out)?;

    // tests/fixture/<category>/<name>.py, optionally filtered by substring.
    let mut fixtures: Vec<(String, PathBuf)> = Vec::new();
    for cat in std::fs::read_dir(&fixture_root)? {
        let cat = cat?.path();
        if !cat.is_dir() {
            continue;
        }
        for f in std::fs::read_dir(&cat)? {
            let f = f?.path();
            if f.extension().is_some_and(|x| x == "py") {
                let name = format!(
                    "{}/{}",
                    cat.file_name().unwrap().to_string_lossy(),
                    f.file_stem().unwrap().to_string_lossy()
                );
                if name.contains(&filter) {
                    fixtures.push((name, f));
                }
            }
        }
    }
    fixtures.sort();
    assert!(!fixtures.is_empty(), "no fixtures match '{filter}'");

    let mut cards = String::new();
    let mut failed = 0usize;
    for (name, path) in &fixtures {
        let slug = name.replace('/', "_");
        let card = match render_fixture(&pyspice_dir, path, &slug, &out) {
            Ok(c) => c,
            Err(e) => {
                failed += 1;
                format!("<p class=\"err\">{}</p>", esc(&format!("{e:#}")))
            }
        };
        let _ = writeln!(
            cards,
            "<section id=\"{slug}\"><h2><a href=\"#{slug}\">{name}</a>\
             <span class=\"links\"><a href=\"{slug}.cir\">netlist</a> \
             <a href=\"{slug}.ref.svg\">cktImg reference</a></span></h2>\n{card}</section>",
        );
        println!("rendered {name}");
    }

    let index = format!(
        "<!doctype html><meta charset=\"utf-8\"><title>net2schem gallery</title>\n\
         <style>body{{font-family:sans-serif;margin:2rem}}\
         main{{display:grid;grid-template-columns:repeat(auto-fill,minmax(420px,1fr));gap:1.5rem}}\
         section{{border:1px solid #ddd;border-radius:6px;padding:1rem}}\
         img{{width:100%;height:auto;border:1px solid #eee;background:#fff}}\
         h2{{font-size:1rem;margin-top:0}} .links{{font-weight:normal;font-size:.8rem;float:right}}\
         .links a{{margin-left:.8rem}}\
         .err{{color:#c62828;font-family:monospace;white-space:pre-wrap;font-size:.8rem}}\
         ul.viol{{color:#c62828;font-family:monospace;font-size:.8rem;padding-left:1.2rem}}\
         p.ok{{color:#2e7d32;font-size:.8rem}}</style>\n\
         <h1>net2schem gallery — {} fixtures, {} failed</h1>\n\
         <p>Each schematic is the adapter's own output — netlist → \
         <code>netlist_to_circuit</code> → <code>schematic_from_subcircuit</code> → \
         core <code>Schematic</code> — drawn with Schemify's embedded symbol art, \
         exactly what the app opens. \"cktImg reference\" links the upstream render \
         of the same placed IR for comparison.</p>\n<main>\n{}</main>\n",
        fixtures.len(),
        failed,
        cards
    );
    std::fs::write(out.join("index.html"), index)?;
    println!("{} fixtures rendered to {}", fixtures.len(), out.display());

    if std::env::var_os("VISUALIZE_NO_SERVE").is_some() {
        return Ok(());
    }
    serve_and_open(&out, 8732);
    Ok(())
}

/// Generate the netlist, run it through the full adapter chain, write the
/// artifacts, and return the card body HTML.
fn render_fixture(
    pyspice_dir: &str,
    fixture: &Path,
    slug: &str,
    out: &Path,
) -> anyhow::Result<String> {
    let netlist = generate_netlist(fixture, pyspice_dir)?;
    std::fs::write(out.join(format!("{slug}.cir")), &netlist)?;

    // Adapter first: it installs Schemify's pin geometry + strict layout
    // config into cktimg (process-wide), so the reference render below uses
    // the exact configuration the adapter consumed.
    let circuit = schemify_net2schem::netlist_to_circuit(&netlist)?;
    let (ref_svg, _) = cktimg::run(&netlist, svg::render);
    std::fs::write(out.join(format!("{slug}.ref.svg")), ref_svg)?;

    // The full adapter chain, same as the app's import path.
    let mut rodeo = Rodeo::default();
    let ports = emit::parse_pininfo(&netlist);
    let sch = emit::schematic_from_subcircuit(&circuit.top, &mut rodeo, &ports);
    std::fs::write(out.join(format!("{slug}.sch.svg")), render_schematic(&sch, &rodeo))?;

    let violations = emit::validate_subcircuit(&circuit.top);
    let mut card = format!(
        "<a href=\"{slug}.sch.svg\"><img src=\"{slug}.sch.svg\" loading=\"lazy\" \
         alt=\"{slug}\"></a>\
         <p class=\"ok\">{} instances, {} wires</p>",
        sch.instances.len(),
        sch.wires.len(),
    );
    if violations.is_empty() {
        card.push_str("<p class=\"ok\">no emit-rule violations</p>");
    } else {
        card.push_str("<ul class=\"viol\">");
        for v in &violations {
            let _ = write!(card, "<li>{:?}: {}</li>", v.severity, esc(&v.message));
        }
        card.push_str("</ul>");
    }
    for d in &circuit.diagnostics {
        let _ = write!(
            card,
            "<p class=\"err\">parse: line {}: {}</p>",
            d.line_no,
            esc(&d.message)
        );
    }
    Ok(card)
}

// ---------------------------------------------------------------------------
// Core-Schematic SVG renderer — mirrors gui/src/canvas/render.rs
// ---------------------------------------------------------------------------

/// SVG builder that tracks bounds as elements are emitted, so the viewBox
/// wraps everything drawn.
struct Svg {
    body: String,
    lo: (i32, i32),
    hi: (i32, i32),
}

impl Svg {
    fn new() -> Self {
        Svg {
            body: String::new(),
            lo: (i32::MAX, i32::MAX),
            hi: (i32::MIN, i32::MIN),
        }
    }
    fn grow(&mut self, x: i32, y: i32) {
        self.lo = (self.lo.0.min(x), self.lo.1.min(y));
        self.hi = (self.hi.0.max(x), self.hi.1.max(y));
    }
    fn line(&mut self, x0: i32, y0: i32, x1: i32, y1: i32, stroke: &str, w: f32, title: &str) {
        self.grow(x0, y0);
        self.grow(x1, y1);
        let t = if title.is_empty() {
            String::new()
        } else {
            format!("<title>{}</title>", esc(title))
        };
        let _ = writeln!(
            self.body,
            "<line x1=\"{x0}\" y1=\"{y0}\" x2=\"{x1}\" y2=\"{y1}\" stroke=\"{stroke}\" stroke-width=\"{w}\">{t}</line>",
        );
    }
    fn circle(&mut self, cx: i32, cy: i32, r: i32, stroke: &str, w: f32) {
        self.grow(cx - r, cy - r);
        self.grow(cx + r, cy + r);
        let _ = writeln!(
            self.body,
            "<circle cx=\"{cx}\" cy=\"{cy}\" r=\"{r}\" fill=\"none\" stroke=\"{stroke}\" stroke-width=\"{w}\"/>",
        );
    }
    fn rect(&mut self, x0: i32, y0: i32, x1: i32, y1: i32, stroke: &str, w: f32) {
        self.grow(x0, y0);
        self.grow(x1, y1);
        let (x, y) = (x0.min(x1), y0.min(y1));
        let _ = writeln!(
            self.body,
            "<rect x=\"{x}\" y=\"{y}\" width=\"{}\" height=\"{}\" fill=\"none\" stroke=\"{stroke}\" stroke-width=\"{w}\"/>",
            (x1 - x0).abs(),
            (y1 - y0).abs(),
        );
    }
    /// Arc as a sampled polyline — same approximation and math-convention
    /// angles (y-down: y = cy − r·sin θ) as the GUI's `stroke_arc`.
    fn arc(&mut self, cx: i32, cy: i32, r: i32, start_deg: f32, sweep_deg: f32, stroke: &str, w: f32) {
        let n = ((sweep_deg.abs() / 10.0) as usize).clamp(8, 64);
        let (start, sweep) = (start_deg.to_radians(), sweep_deg.to_radians());
        let mut pts = String::new();
        for i in 0..=n {
            let a = start + sweep * (i as f32 / n as f32);
            let x = cx as f32 + r as f32 * a.cos();
            let y = cy as f32 - r as f32 * a.sin();
            self.grow(x as i32, y as i32);
            let _ = write!(pts, "{x:.1},{y:.1} ");
        }
        let _ = writeln!(
            self.body,
            "<polyline points=\"{pts}\" fill=\"none\" stroke=\"{stroke}\" stroke-width=\"{w}\"/>",
        );
    }
    fn text(&mut self, x: i32, y: i32, size: i32, fill: &str, anchor: &str, content: &str) {
        if content.is_empty() {
            return;
        }
        self.grow(x, y);
        let _ = writeln!(
            self.body,
            "<text x=\"{x}\" y=\"{y}\" font-size=\"{size}\" fill=\"{fill}\" text-anchor=\"{anchor}\" dominant-baseline=\"middle\">{}</text>",
            esc(content),
        );
    }
    /// Collision-placed label at a baseline anchor; textLength pins the
    /// rendered width to the collision box in any viewer (cktImg's trick).
    fn label(&mut self, x: i32, y: i32, fill: &str, content: &str) {
        if content.is_empty() {
            return;
        }
        self.grow(x, y - TEXT_H);
        self.grow(x + text_w(content), y + DESCENT);
        let _ = writeln!(
            self.body,
            "<text x=\"{x}\" y=\"{y}\" font-size=\"7\" fill=\"{fill}\" textLength=\"{}\" lengthAdjust=\"spacingAndGlyphs\">{}</text>",
            text_w(content) - 2,
            esc(content),
        );
    }
    fn finish(self) -> String {
        if self.lo.0 > self.hi.0 {
            return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"20\">\
                    <text x=\"5\" y=\"15\">empty</text></svg>"
                .into();
        }
        const PAD: i32 = 40;
        format!(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"{} {} {} {}\" font-family=\"sans-serif\">\n{}</svg>\n",
            self.lo.0 - PAD,
            self.lo.1 - PAD,
            self.hi.0 - self.lo.0 + 2 * PAD,
            self.hi.1 - self.lo.1 + 2 * PAD,
            self.body,
        )
    }
}

const SYM: &str = "#000";
const WIRE: &str = "#1565c0";

// Label metrics + collision placement, ported verbatim from cktImg
// build/src/labels.rs (CHAR_W/TEXT_H/DESCENT/GAP and the 6-candidate search).
const CHAR_W: i32 = 5;
const TEXT_H: i32 = 7;
const DESCENT: i32 = 2;
const GAP: i32 = 3;

fn text_w(s: &str) -> i32 {
    CHAR_W * s.len() as i32 + 2
}

#[derive(Clone, Copy)]
struct R {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
}

impl R {
    fn of(a: (i32, i32), b: (i32, i32)) -> R {
        R { x0: a.0.min(b.0), y0: a.1.min(b.1), x1: a.0.max(b.0), y1: a.1.max(b.1) }
    }
    /// Strict overlap — touching edges don't collide (cktImg geom.rs).
    fn hits(&self, o: &R) -> bool {
        self.x0 < o.x1 && o.x0 < self.x1 && self.y0 < o.y1 && o.y0 < self.y1
    }
    fn inflate(self, by: i32) -> R {
        R { x0: self.x0 - by, y0: self.y0 - by, x1: self.x1 + by, y1: self.y1 + by }
    }
    fn grow_pt(&mut self, x: i32, y: i32) {
        self.x0 = self.x0.min(x);
        self.y0 = self.y0.min(y);
        self.x1 = self.x1.max(x);
        self.y1 = self.y1.max(y);
    }
}

const EMPTY_R: R = R { x0: i32::MAX, y0: i32::MAX, x1: i32::MIN, y1: i32::MIN };

/// Text collision box for a label whose baseline anchor is `a`.
fn rect_at(a: (i32, i32), w: i32) -> R {
    R { x0: a.0, y0: a.1 - TEXT_H, x1: a.0 + w, y1: a.1 + DESCENT }
}

/// cktImg's refdes placement: try right of the body, then right-above,
/// right-below, then the same three on the left; first clear spot wins and
/// becomes an obstacle for later labels.
fn place_label(obstacles: &mut Vec<R>, body: R, w: i32) -> (i32, i32) {
    let right = body.x1 + GAP;
    let left = body.x0 - GAP - w;
    let cy = (body.y0 + body.y1) / 2 + TEXT_H / 2; // baseline centers the em box
    let dy = TEXT_H + DESCENT + GAP;
    let cands = [
        (right, cy),
        (right, cy - dy),
        (right, cy + dy),
        (left, cy),
        (left, cy - dy),
        (left, cy + dy),
    ];
    let at = cands
        .into_iter()
        .find(|&a| {
            let r = rect_at(a, w);
            !obstacles.iter().any(|o| o.hits(&r))
        })
        .unwrap_or(cands[0]);
    obstacles.push(rect_at(at, w));
    at
}

/// Draw the adapter-produced core `Schematic` with the real embedded symbol
/// art — geometry and transform convention lifted from the GUI canvas
/// (`draw_prim_geometry` / `render_instances`). Refdes/value/net-label text
/// uses cktImg's collision-avoided placement instead of the prim anchors,
/// which is what keeps their gallery legible.
fn render_schematic(sch: &Schematic, int: &Rodeo) -> String {
    let mut svg = Svg::new();
    let mut obstacles: Vec<R> = Vec::new();

    for i in 0..sch.wires.len() {
        let net = sch.wires.net_name[i].map(|s| int.resolve(&s)).unwrap_or("");
        let (x0, y0, x1, y1) =
            (sch.wires.x0[i], sch.wires.y0[i], sch.wires.x1[i], sch.wires.y1[i]);
        svg.line(x0, y0, x1, y1, WIRE, 1.5, net);
        obstacles.push(R::of((x0, y0), (x1, y1)).inflate(1));
    }

    // Pass 1: symbol art + pin markers; collect each instance's oriented
    // body box and the text it needs placed.
    struct Pending<'a> {
        body: R,
        name: &'a str,
        value: String,
        non_electrical: bool,
    }
    let mut pending: Vec<Pending> = Vec::new();

    let insts = &sch.instances;
    for i in 0..insts.len() {
        let (ox, oy) = (insts.x[i], insts.y[i]);
        let flags = insts.flags[i];
        let symbol = int.resolve(&insts.symbol[i]);
        let name = int.resolve(&insts.name[i]);
        let tp = |x: i16, y: i16| {
            let (ax, ay) = flags.transform_point(x as i32, y as i32);
            (ox + ax, oy + ay)
        };
        let mut body = EMPTY_R;

        let Some(entry) = prims::find_symbol(symbol, insts.kind[i]) else {
            // Generic fallback box, as the GUI draws for unknown subcircuits.
            svg.rect(ox - 20, oy - 20, ox + 20, oy + 20, SYM, 1.5);
            svg.text(ox, oy, 10, SYM, "middle", symbol);
            let body = R { x0: ox - 20, y0: oy - 20, x1: ox + 20, y1: oy + 20 };
            obstacles.push(body);
            pending.push(Pending { body, name, value: String::new(), non_electrical: false });
            continue;
        };

        for s in &entry.segments {
            let (x0, y0) = tp(s.x0, s.y0);
            let (x1, y1) = tp(s.x1, s.y1);
            svg.line(x0, y0, x1, y1, SYM, 1.5, "");
            body.grow_pt(x0, y0);
            body.grow_pt(x1, y1);
        }
        for c in &entry.circles {
            let (cx, cy) = tp(c.cx, c.cy);
            svg.circle(cx, cy, c.r as i32, SYM, 1.5);
            body.grow_pt(cx - c.r as i32, cy - c.r as i32);
            body.grow_pt(cx + c.r as i32, cy + c.r as i32);
        }
        for a in &entry.arcs {
            let (cx, cy) = tp(a.cx, a.cy);
            // Angles follow the point transform: flip mirrors (θ → 180−θ,
            // sweep reversed), then each rotation step subtracts 90°.
            let (mut start, mut sweep) = (a.start as f32, a.sweep as f32);
            if flags.flip() {
                start = 180.0 - start;
                sweep = -sweep;
            }
            start -= 90.0 * flags.rotation() as f32;
            svg.arc(cx, cy, a.r as i32, start, sweep, SYM, 1.5);
            body.grow_pt(cx - a.r as i32, cy - a.r as i32);
            body.grow_pt(cx + a.r as i32, cy + a.r as i32);
        }
        for r in &entry.rects {
            let (x0, y0) = tp(r.x0, r.y0);
            let (x1, y1) = tp(r.x1, r.y1);
            svg.rect(x0, y0, x1, y1, SYM, 1.5);
            body.grow_pt(x0, y0);
            body.grow_pt(x1, y1);
        }
        for pp in &entry.pin_positions {
            if entry.non_electrical && pp.x == 0 && pp.y == 0 {
                continue;
            }
            let (px, py) = tp(pp.x, pp.y);
            svg.circle(px, py, 3, SYM, 0.9);
            body.grow_pt(px - 3, py - 3);
            body.grow_pt(px + 3, py + 3);
        }
        if body.x0 > body.x1 {
            body = R { x0: ox, y0: oy, x1: ox, y1: oy };
        }
        obstacles.push(body);

        // Literal texts (e.g. "VDD") are symbol art — draw at their anchor.
        // @anchors become the placed value string: "@w/@l" → "10u/500n".
        let props = sch.instance_props(i);
        let mut value_parts: Vec<String> = Vec::new();
        for dt in &entry.texts {
            if dt.content == "@name" {
                continue; // name is collision-placed below
            } else if let Some(keys) = dt.content.strip_prefix('@') {
                let label = keys
                    .split('/')
                    .map(|part| {
                        // "@w/@l": each part may carry its own @ prefix.
                        let part = part.strip_prefix('@').unwrap_or(part);
                        props
                            .iter()
                            .find(|p| int.resolve(&p.key) == part)
                            .map(|p| int.resolve(&p.value))
                            .unwrap_or(part)
                    })
                    .collect::<Vec<_>>()
                    .join("/");
                // Unresolved anchors (no such prop) print as the bare key —
                // noise, not data. Only keep values that resolved.
                if !label.is_empty() && label != keys.replace('@', "") {
                    value_parts.push(label);
                }
            } else {
                let (tx, ty) = tp(dt.x, dt.y);
                svg.text(tx, ty, 10, SYM, "middle", dt.content);
            }
        }
        pending.push(Pending {
            body,
            name,
            value: value_parts.join(" "),
            non_electrical: entry.non_electrical,
        });
    }

    // Pass 2: collision-placed text. Refdes first (denser), then its value
    // preferentially on the line directly below, then net-label texts.
    for p in &pending {
        let name_at = if !p.non_electrical && !p.name.is_empty() {
            Some(place_label(&mut obstacles, p.body, text_w(p.name)))
        } else {
            None
        };
        if !p.value.is_empty() {
            let w = text_w(&p.value);
            let below = name_at.map(|(nx, ny)| (nx, ny + TEXT_H + DESCENT + 1));
            let at = match below {
                Some(b) if !obstacles.iter().any(|o| o.hits(&rect_at(b, w))) => {
                    obstacles.push(rect_at(b, w));
                    b
                }
                _ => place_label(&mut obstacles, p.body, w),
            };
            svg.label(at.0, at.1, "#666", &p.value);
        }
        if let Some((nx, ny)) = name_at {
            svg.label(nx, ny, "#444", p.name);
        }
    }

    svg.finish()
}

/// Run the fixture script through python3, returning the SPICE netlist
/// (stdout). Mirrors tests/rules.rs::generate_netlist.
fn generate_netlist(fixture: &Path, pyspice_dir: &str) -> anyhow::Result<String> {
    let mut pythonpath = pyspice_dir.to_string();
    if let Ok(existing) = std::env::var("PYTHONPATH") {
        if !existing.is_empty() {
            pythonpath = format!("{pythonpath}:{existing}");
        }
    }
    let output = Command::new("python3")
        .arg(fixture)
        .env("PYTHONPATH", pythonpath)
        .output()?;
    anyhow::ensure!(
        output.status.success(),
        "python3 exited with {}:\n{}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

// ponytail: python stdlib http.server, same dev-only pattern as cktImg's
// `cargo visualize`. Swap for a Rust http dep only if python stops being a given.
fn serve_and_open(dir: &Path, port: u16) {
    // Kill any stale server still holding this port from a previous run.
    if let Ok(out) = Command::new("ss")
        .args(["-tlnp", &format!("sport = :{port}")])
        .output()
    {
        let text = String::from_utf8_lossy(&out.stdout);
        for cap in text.split("pid=").skip(1) {
            let pid = cap.split(|c: char| !c.is_ascii_digit()).next().unwrap_or("");
            if !pid.is_empty() {
                let _ = Command::new("kill").arg(pid).status();
                std::thread::sleep(std::time::Duration::from_millis(200));
            }
        }
    }

    let mut server = Command::new("python3")
        .args(["-m", "http.server", &port.to_string()])
        .current_dir(dir)
        .spawn()
        .expect("start python3 http.server (is python3 installed?)");

    let url = format!("http://localhost:{port}/");
    let opener = if cfg!(target_os = "macos") { "open" } else { "xdg-open" };
    let _ = Command::new(opener).arg(&url).status();
    println!("serving {url}  (Ctrl-C to stop)");
    let _ = server.wait();
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}
