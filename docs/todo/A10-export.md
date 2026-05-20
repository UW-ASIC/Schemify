# A10: Export (SVG/PNG/PDF)

**Wave**: 3
**Depends on**: A3 (canvas rendering — reuse shape building logic)

## Goal
Export schematic to SVG, PNG, PDF. Reuse canvas render logic but target file output instead of screen.

## Branch
`feat/export`

## Zig Reference Files
- `../Schemify/src/commands/handlers/View.zig` — export command handling (search for "export")

## Crate/File Map

### display (`crates/display/src/`)
- NEW `export/mod.rs` — public API: `export_svg()`, `export_png()`, `export_pdf()`
- NEW `export/svg.rs` — SVG writer (manual XML or `svg` crate)
- NEW `export/png.rs` — rasterize via `tiny-skia` or egui offscreen render
- NEW `export/pdf.rs` — via `svg2pdf` or `printpdf`

## Approach

**SVG**: walk schematic, emit SVG elements directly. Don't go through egui — SVG is the most natural output. Lines, circles, arcs, rects, text → SVG primitives.

**PNG**: render SVG → rasterize with `resvg`/`tiny-skia`. Or use egui's built-in screenshot if the canvas is visible.

**PDF**: SVG → PDF via `svg2pdf`. Cleanest pipeline.

So the real work is SVG. PNG and PDF are conversions from SVG.

```rust
pub fn export_svg(schematic: &Schematic, interner: &Rodeo, opts: &ExportOptions) -> String;
pub fn export_png(schematic: &Schematic, interner: &Rodeo, opts: &ExportOptions) -> Vec<u8>;
pub fn export_pdf(schematic: &Schematic, interner: &Rodeo, opts: &ExportOptions) -> Vec<u8>;

pub struct ExportOptions {
    pub width: u32,
    pub height: u32,
    pub background: Option<[u8; 4]>,
    pub scale: f32,
    pub selection_only: bool,
}
```

## Checklist
- [ ] `export/svg.rs`: emit SVG from schematic (wires, symbols, labels, geometry)
- [ ] Reuse `transform_point` for instance rendering (same math as canvas)
- [ ] Symbol rendering: PrimEntry segments/circles/arcs/text → SVG elements
- [ ] Wire rendering: line elements with color/thickness
- [ ] Text rendering: SVG text elements with font-size, rotation
- [ ] Auto-fit bounding box (or explicit dimensions)
- [ ] `export/png.rs`: SVG → PNG via resvg/tiny-skia
- [ ] `export/pdf.rs`: SVG → PDF via svg2pdf
- [ ] Tests: simple schematic → SVG string contains expected elements
- [ ] Tests: export dimensions match expected bounds
- [ ] Commit after each meaningful change

## Potential Deps
```toml
resvg = "0.44"     # SVG → raster
tiny-skia = "0.11"  # rasterizer
svg2pdf = "0.12"    # SVG → PDF
```

## Do NOT Touch
- `canvas.rs` / `render.rs` — A3 territory (you may share utility fns but don't modify)
- `handler/` — export commands already dispatch, you implement the logic
- `sim/` — not your crate
