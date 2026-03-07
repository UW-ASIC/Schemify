# SINA-Based Image-to-Schematic Plugin Architecture
## For Zig-Based Schematic Editor with FileIO.zig Interface

---

## Core Philosophy

**AI extracts topology. Humans handle layout.**

The AI pipeline identifies *what* components exist and *how* they connect.
The editor hands the user this connectivity as a bag of unplaced components
with enforced connection constraints. The user positions, routes, and refines —
optionally with the source image as a ghost reference layer.

---

## Why SINA

SINA (arXiv:2601.22114, January 2026) is the current state-of-the-art for
image-to-netlist conversion. It achieves **96.47% end-to-end netlist generation
accuracy**, which is 2.72x higher than the previous best (Masala-CHAI). It is
open-source, uses a modern stack (YOLOv11 + CCL + OCR + VLM), and its
intermediate representations — bounding boxes, wire clusters, pin-to-node
mappings — are exactly what we need for our bridge format.

### SINA's Pipeline (as published)

```
Image → YOLOv11 (component detection)
      → CCL (connectivity inference)
      → OCR (reference designator text)
      → VLM/GPT-4o (designator assignment + verification)
      → SPICE netlist
```

**What we change:** We replace the final SPICE netlist output with a
CircuitGraph JSON that preserves all intermediate data. And we extend the
front-end of the pipeline to handle three fundamentally different input styles.

### SINA's Known Limitations

SINA was trained on **700+ annotated schematics** from diverse sources
(research papers, textbooks, hand-drawn sketches). However:

1. **Limited component vocabulary.** The published model covers common passive
   and active components but doesn't enumerate exactly which classes. We need
   to extend for MOSFET variants (NMOS/PMOS with body terminal), current
   mirrors, differential pairs, and IC-level blocks.

2. **No explicit style adaptation.** SINA treats all input images through one
   pipeline. It does not detect the drawing style first, which means it can
   misinterpret crossing conventions, symbol variants, or handwriting noise.

3. **VLM dependency.** The GPT-4o verification step is powerful but adds
   latency and API cost. We should make this optional and evaluate whether
   Claude or a local VLM can substitute.

---

## The Three Schematic Worlds

The single biggest challenge in circuit image recognition is that **the same
logical circuit looks completely different** depending on where it comes from.
A resistor in a hand-drawn sketch, a Razavi textbook, and a TI datasheet are
three entirely different visual objects. Crossings, junctions, ground symbols,
MOSFET notation, and labeling conventions all vary.

Image2Net (ISEDA 2025, arXiv:2508.13157) identified this explicitly and solved
it by **detecting the drawing style first, then interpreting elements according
to that style's conventions.** We adopt this principle.

### Style 1: Hand-Drawn Schematics

**Visual characteristics:**
- Noisy, uneven strokes with variable line width
- Imprecise alignment — wires not perfectly horizontal/vertical
- Inconsistent symbol shapes (every person draws a resistor differently)
- Shadows, paper texture, lighting artifacts in photos
- Labels may be illegible, abbreviated, or missing entirely
- No grid, no snap, no standardization

**Specific challenges for SINA's pipeline:**
- **Component detection:** YOLO must be trained on highly augmented hand-drawn
  data (rotation, scale, stroke distortion, noise). The JUHCCR-v1 dataset
  (Nature Scientific Reports 2025, github.com/AyushRoy2001/Circuit-Component-Analysis)
  provides 3,191+ images with synthetic augmentation specifically for this.
  CircuitNet (github.com/aaanthonyyy/CircuitNet) trained on the same data
  domain and achieved 96.5% classification on 5 component types.
- **Wire tracing:** Adaptive thresholding is critical because lighting is
  uneven. Skeletonization must handle thick/thin strokes. Wire segments
  won't be perfectly Manhattan — the pipeline needs an angle tolerance
  (±15° from H/V) to snap to grid during the topology-building phase.
- **OCR:** Will frequently fail on handwritten labels. Fallback: auto-generate
  reference designators (R1, R2, C1...) and let the user fix them in the
  review step. PaddleOCR's handwriting mode helps but isn't reliable enough
  to trust without verification.
- **Junction ambiguity:** A hand-drawn dot at a crossing could mean "connected"
  or just "ink blob." Image2Net categorizes 3 crossing types; we need this
  crossing classifier for hand-drawn inputs.

**Preprocessing required:**
```
1. Perspective correction (if photo taken at angle)
2. Adaptive bilateral filtering (denoise while preserving edges)
3. Adaptive thresholding (Otsu or Sauvola for uneven lighting)
4. Morphological close (bridge small gaps in hand-drawn lines)
5. Optional: deskew (correct rotation if paper is tilted)
```

### Style 2: Razavi-Style Textbook Schematics

**Visual characteristics:**
- Clean, professional vector-quality rendering
- Distinctive MOSFET symbols: arrow on gate for PMOS, specific body terminal
  notation, often without explicit W/L labels on the symbol itself
- Current mirrors drawn as matched transistor pairs with specific visual cues
- Differential pairs with symmetric layout conventions
- Minimal color — typically black on white with occasional red/blue for signals
- Labels are typeset (LaTeX), clean, consistent fonts
- Node voltages labeled as Vx, VDD, VSS with overlines or subscripts
- Biasing circuits shown with specific current source symbols
- Cascode structures, folded cascode, telescopic OTA — these have distinctive
  visual patterns that are recognizable as higher-level blocks

**Specific challenges for SINA's pipeline:**
- **MOSFET terminal identification** is the hardest problem. Masala-CHAI
  (arXiv:2411.14299) identified this explicitly: "accurately identifying and
  mapping MOSFET terminals to the correct nets is a significant challenge."
  The drain, gate, and source must be correctly assigned based on the arrow
  direction, body connection, and spatial context. Razavi's conventions differ
  subtly from Sedra/Smith, Gray/Meyer, and Allen/Holberg.
- **Current source symbols** vary: ideal current source (circle with arrow),
  MOSFET-based current mirror (a MOSFET with a specific biasing connection),
  or a simple arrow. The detector must distinguish these.
- **Hierarchical structures:** A telescopic cascode or folded cascode is 8+
  transistors with a very specific topology. The detector should ideally
  recognize these as higher-level blocks, though this is a Phase 5+ feature.
- **Small-signal models:** Some textbook figures show small-signal equivalent
  circuits with dependent sources (gmVgs, routed as diamond sources). These
  are a different component class entirely.

**Training data sources:**
- Masala-CHAI provides **7,500 schematics extracted from 10 analog textbooks**
  with SPICE netlists, open-sourced at github.com/jitendra-bhandari/Masala-CHAI.
  This is the richest source of Razavi-style training data.
- AMSNet (arXiv:2405.09045) provides transistor-level schematics with SPICE
  netlists specifically for analog/mixed-signal circuits.
- Image2Net's device identification dataset (2,914 images, 84,195 annotations
  across 22 device types) includes textbook-sourced schematics. Its crossing
  and orientation datasets are also critical here. See the full Image2Net
  breakdown under Training Data Strategy.

**Preprocessing required:**
```
1. Minimal — images are already clean
2. Contrast normalization (some scanned textbooks have gray backgrounds)
3. Border/caption removal (crop to schematic region only)
4. Resolution upscaling if from low-DPI PDF extraction
```

### Style 3: IEEE / Manufacturer Datasheets

**Visual characteristics:**
- Highly standardized IEEE/IEC symbols (rectangular resistor vs. zigzag,
  logic gate shapes per IEEE Std 91)
- Dense, information-rich layouts with many components
- Pin numbers, absolute maximum ratings, truth tables mixed into the page
- Block diagrams mixed with transistor-level schematics on the same page
- Multi-page circuits with off-page connectors and signal names
- Color-coded signals in some modern datasheets (TI, Analog Devices)
- Proprietary fonts and rendering (PDF vector graphics, not raster)
- Application circuits with specific part numbers (LM358, AD8421, etc.)
- Test circuits, evaluation board schematics, reference designs

**Specific challenges for SINA's pipeline:**
- **Page segmentation:** The schematic is one region on a page that also
  contains text, tables, graphs, and block diagrams. Before running component
  detection, we must isolate the schematic region. Auto-SPICE (Masala-CHAI's
  predecessor) handles this by running YOLOv8 on the full page to localize
  schematic figures first.
- **Off-page connectors:** Signals that continue on another page are labeled
  with names (e.g., "VOUT → see Figure 12"). These must be captured as
  open pins with net names, not flagged as unconnected errors.
- **IC blocks as opaque components:** A datasheet's application circuit might
  show the IC as a rectangle with pin names. This is a single component with
  20+ pins, not a transistor-level schematic. The detector must recognize
  IC blocks as single components and extract all pin labels.
- **Mixed symbol standards:** US zigzag resistors vs. European rectangular
  resistors. ANSI vs. IEC logic gates. The style detector must identify which
  standard is in use.
- **PDF vector extraction:** Datasheet PDFs contain vector graphics, not
  rasters. Extracting the schematic as a vector image (via pdf2svg or
  Poppler) gives pixel-perfect lines that are much easier to process than
  photos. This should be the preferred input path for datasheets.

**Training data sources:**
- Image2Net dataset includes internet-sourced schematics covering this style.
- Masala-CHAI's pipeline includes textbook extraction which partially overlaps.
- Custom collection needed: scrape application notes from TI, Analog Devices,
  Microchip, NXP reference designs (publicly available, though redistribution
  may require care).

**Preprocessing required:**
```
1. PDF schematic region extraction (page → schematic crop)
2. Vector-to-raster conversion at high DPI (600+) if using raster pipeline
3. OR: direct vector path extraction for wire tracing (advanced, Phase 5+)
4. Color channel separation if color-coded signals exist
5. Multi-page assembly (detect off-page connectors, link by name)
```

---

## Style-Aware Pipeline Extension

Image2Net's key insight: **detect the style first, then adapt processing.**

We add a **Style Classifier** as the first stage of the pipeline, before
component detection. This is a lightweight CNN (or even a rule-based heuristic)
that classifies the input into one of the three styles. Each style then routes
through a tailored preprocessing chain and may use style-specific YOLO weights.

```
                          ┌─── Hand-Drawn Preprocessor ───┐
                          │   (denoise, deskew, threshold) │
Image ─► Style Classifier ├─── Textbook Preprocessor ─────┤─► Component Detection
                          │   (crop, normalize)            │   (shared or per-style
                          └─── Datasheet Preprocessor ────┘    YOLO weights)
                                (PDF extract, segment)          │
                                                                ▼
                                                     Wire Tracing (CCL)
                                                                │
                          ┌─── Hand-Drawn: angle-tolerant ─────┤
    Crossing Classifier ──┤─── Textbook: strict Manhattan ─────┤
                          └─── Datasheet: standard junctions ──┘
                                                                │
                                                                ▼
                                                     OCR + Label Assignment
                                                                │
                          ┌─── Hand-Drawn: auto-generate refs ─┤
                          ├─── Textbook: Vx/VDD/VSS patterns ──┤
                          └─── Datasheet: part numbers + pins ──┘
                                                                │
                                                                ▼
                                                     Topology Builder
                                                                │
                                                                ▼
                                                     VLM Verification (optional)
                                                                │
                                                                ▼
                                                     CircuitGraph JSON
```

### Crossing Classifier

A critical subproblem identified by Image2Net. At any wire intersection, one of
three things is true:

1. **Connected junction** (dot at crossing) — the wires share a node
2. **Unconnected crossing, bridge style** (one wire arcs over the other)
3. **Unconnected crossing, plain style** (wires simply cross with no indicator)

Style 3 is the ambiguous case. In Razavi textbooks, plain crossings are almost
always unconnected (connections always have dots). In hand-drawn circuits, it's
ambiguous. In datasheets, the convention varies by manufacturer.

The Style Classifier informs the Crossing Classifier's default assumption:
- Hand-drawn → require explicit dot, else assume unconnected (flag for review)
- Textbook → plain crossing = unconnected, dot = connected
- Datasheet → detect by manufacturer convention or flag for review

Image2Net trained a dedicated crossing classifier on their annotated dataset.
We should use their open-source crossing dataset directly.

### MOSFET Terminal Resolver

For Razavi-style inputs, we add a specialized post-detection stage:

```
MOSFET bounding box detected
  → Identify arrow direction (determines NMOS vs PMOS)
  → Locate gate terminal (horizontal line approaching the channel)
  → Determine drain vs source by position relative to arrow
  → Check for body/bulk terminal (4th connection)
  → Assign pin names: G, D, S, B
```

Masala-CHAI's approach: after YOLO detection, they prompt GPT-4o with the
labeled image and specific instructions about MOSFET terminal identification:
"To identify the source terminal of a MOSFET, choose the net highlighted in
red which is nearest to the arrow of the MOSFET." We adapt this for our VLM
verification step.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  LAYER 3: EDITOR INTEGRATION (Zig)                       │
│  ┌────────────────────────────────────────────────────┐  │
│  │  ImportPlugin.zig                                  │  │
│  │  ├── Reads CircuitGraph JSON via std.json          │  │
│  │  ├── Calls FileIO.addComponent() per part          │  │
│  │  ├── Registers pending connections (edge list)     │  │
│  │  ├── ConnectivityEnforcer: rubber-band viz,        │  │
│  │  │   validation via FileIO.ConnectivityCheck()     │  │
│  │  ├── GhostImageLayer: source image overlay         │  │
│  │  └── ReviewDialog: confidence display, type fixes  │  │
│  └────────────────────────────────────────────────────┘  │
│                          ▲                                │
│                          │ JSON via stdout / temp file    │
│                          │                                │
├──────────────────────────┼───────────────────────────────┤
│  LAYER 2: BRIDGE         │                               │
│  CircuitGraph JSON — see schema below                    │
│                          │                                │
├──────────────────────────┼───────────────────────────────┤
│  LAYER 1: AI PIPELINE (Python)                           │
│  ┌────────────────────────────────────────────────────┐  │
│  │  circuit_extract.py                                │  │
│  │  ├── StyleClassifier    (CNN or rule-based)        │  │
│  │  ├── Preprocessor       (per-style chain)          │  │
│  │  ├── ComponentDetector  (YOLOv11, SINA-based)      │  │
│  │  ├── CrossingClassifier (Image2Net-based)          │  │
│  │  ├── WireTracer         (OpenCV CCL + skeleton)    │  │
│  │  ├── MOSFETResolver     (terminal assignment)      │  │
│  │  ├── LabelReader        (PaddleOCR)                │  │
│  │  ├── TopologyBuilder    (graph construction)       │  │
│  │  └── VLMVerifier        (Claude/GPT-4o, optional)  │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

**The Python ↔ Zig boundary is a process boundary.** The editor spawns
`python3 circuit_extract.py --input image.jpg --stdout`, reads JSON from
stdout. No FFI, no shared memory, no linking. Same pattern as XSchem → ngspice.

---

## CircuitGraph JSON Bridge Format

```json
{
    "version": "1.0",
    "metadata": {
        "source_image": "photo_001.jpg",
        "detected_style": "textbook_razavi",
        "overall_confidence": 0.91,
        "image_dimensions": {"width": 1920, "height": 1080},
        "crossing_convention": "dot_means_connected",
        "pipeline_version": "0.1.0"
    },

    "components": [
        {
            "id": "comp_001",
            "type": "nmos",
            "symbol": "nmos4",
            "ref": "M1",
            "value": null,
            "confidence": 0.93,
            "pins": [
                {"id": "comp_001.G", "name": "G"},
                {"id": "comp_001.D", "name": "D"},
                {"id": "comp_001.S", "name": "S"},
                {"id": "comp_001.B", "name": "B"}
            ],
            "source_bbox": {"x": 500, "y": 300, "w": 60, "h": 80},
            "properties": {}
        }
    ],

    "nets": [
        {
            "id": "net_vdd",
            "name": "VDD",
            "pins": ["comp_003.D", "comp_005.1"],
            "confidence": 0.97
        },
        {
            "id": "net_002",
            "name": null,
            "pins": ["comp_001.D", "comp_002.S"],
            "confidence": 0.88
        }
    ],

    "warnings": [
        {
            "type": "ambiguous_crossing",
            "location": {"x": 340, "y": 210},
            "message": "Wire crossing without explicit junction marker",
            "assumed": "unconnected"
        },
        {
            "type": "low_confidence_detection",
            "component_id": "comp_007",
            "message": "Classified as current_source (0.64) — may be voltage_source",
            "confidence": 0.64
        },
        {
            "type": "ocr_uncertain",
            "component_id": "comp_003",
            "message": "Label read as '10k' but confidence low — verify value",
            "confidence": 0.55
        }
    ]
}
```

Key fields beyond SINA's output:
- `detected_style` — informs the editor which symbol library conventions apply
- `crossing_convention` — tells the editor how ambiguous crossings were resolved
- `warnings` with `ambiguous_crossing` type — lets the user resolve junction
  ambiguity during placement

---

## Zig Integration: ImportPlugin.zig

Subprocess spawning + JSON parsing + FileIO.zig calls. The Zig side is
deliberately simple — all intelligence lives in Python.

```zig
const std = @import("std");
const FileIO = @import("FileIO.zig");

pub const ImportResult = struct {
    component_handles: []FileIO.ComponentHandle,
    pending_nets: []PendingNet,
    warnings: []Warning,
    ghost_image_path: ?[]const u8,
    detected_style: []const u8,
};

pub const PendingNet = struct {
    net_id: []const u8,
    net_name: ?[]const u8,
    pin_handles: []FileIO.PinHandle,
    confidence: f64,
};

pub fn importFromImage(
    allocator: std.mem.Allocator,
    image_path: []const u8,
    fileio: *FileIO,
) !ImportResult {

    // 1. Spawn Python AI pipeline
    const graph_json = try runExtractor(allocator, image_path);
    defer allocator.free(graph_json);

    // 2. Parse CircuitGraph JSON
    const parsed = try std.json.parseFromSlice(
        CircuitGraph, allocator, graph_json,
        .{ .allocate = .alloc_always },
    );
    const graph = parsed.value;

    // 3. Add components (unplaced) via FileIO
    var handles = std.ArrayList(FileIO.ComponentHandle).init(allocator);
    var pin_map = std.StringHashMap(FileIO.PinHandle).init(allocator);

    for (graph.components) |comp| {
        const sym = symbol_map.get(comp.type) orelse continue;
        const h = try fileio.addComponent(.{
            .symbol = sym,
            .ref = comp.ref,
            .value = comp.value,
            .placed = false,
        });
        try handles.append(h);
        for (comp.pins) |pin| {
            try pin_map.put(pin.id, try fileio.getPin(h, pin.name));
        }
    }

    // 4. Register nets as pending connections
    var nets = std.ArrayList(PendingNet).init(allocator);
    for (graph.nets) |net| {
        var pins = std.ArrayList(FileIO.PinHandle).init(allocator);
        for (net.pins) |pid| {
            if (pin_map.get(pid)) |ph| try pins.append(ph);
        }
        try nets.append(.{
            .net_id = net.id,
            .net_name = net.name,
            .pin_handles = try pins.toOwnedSlice(),
            .confidence = net.confidence,
        });
    }

    return .{
        .component_handles = try handles.toOwnedSlice(),
        .pending_nets = try nets.toOwnedSlice(),
        .warnings = graph.warnings,
        .ghost_image_path = graph.metadata.source_image,
        .detected_style = graph.metadata.detected_style,
    };
}

fn runExtractor(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    var child = std.process.Child.init(
        &.{ "python3", "circuit_extract.py", "--input", path, "--stdout" },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(alloc, 10 * 1024 * 1024);
    const term = try child.wait();
    if (term.Exited != 0) return error.ExtractorFailed;
    return out;
}

const symbol_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "resistor",       "devices/res" },
    .{ "capacitor",      "devices/capa" },
    .{ "inductor",       "devices/ind" },
    .{ "npn",            "devices/npn" },
    .{ "pnp",            "devices/pnp" },
    .{ "nmos",           "devices/nmos" },
    .{ "nmos4",          "devices/nmos4" },
    .{ "pmos",           "devices/pmos" },
    .{ "pmos4",          "devices/pmos4" },
    .{ "opamp",          "devices/opamp" },
    .{ "diode",          "devices/diode" },
    .{ "voltage_source", "devices/vsource" },
    .{ "current_source", "devices/isource" },
    .{ "ground",         "devices/gnd" },
    .{ "vdd",            "devices/vdd" },
    .{ "vss",            "devices/vss" },
    .{ "ic_block",       "devices/generic_ic" },
});
```

---

## User Workflow

```
1. File → Import from Image → select file
2. Pipeline runs (~2-5s CPU, ~0.3s GPU)
3. Review dialog shows:
   - Detected style (hand-drawn / textbook / datasheet)
   - Component list with confidence scores
   - Warnings: ambiguous crossings, low-confidence detections, OCR failures
   - User can fix types, values, delete false positives
4. Components appear in staging area (sidebar), NOT on canvas
5. User drags components onto canvas
6. Rubber-band lines show pending connections between placed components
7. User routes wires; ConnectivityEnforcer validates against extracted topology
8. Optional ghost image layer for spatial reference
9. Save → native .sch format via FileIO.zig
```

---

## Training Data Strategy

### Combined Dataset

| Source                    | Count    | Styles           | Open Source | Key Contribution          |
|---------------------------|----------|------------------|-------------|---------------------------|
| SINA dataset              | 700+     | Mixed            | Yes (paper) | Detection model weights   |
| Masala-CHAI               | 7,500    | Textbook         | Yes (GitHub)| Razavi-style + netlists   |
| Image2Net                 | 2,914    | Mixed (3 styles) | Yes (GitHub)| 4 datasets (see below)    |
| JUHCCR-v1                 | 3,191+   | Hand-drawn       | Yes (GitHub)| Augmented hand-drawn data |
| AMSNet                    | ~1,000+  | Textbook (AMS)   | Yes         | Transistor-level + SPICE  |
| Custom (datasheets)       | TBD      | Datasheet        | Collect     | Application circuits      |

**Total available today: ~15,000+ annotated schematics.**

### Image2Net: The Multi-Style Benchmark (ISEDA 2025, arXiv:2508.13157)

Image2Net is the most directly relevant dataset for our multi-style pipeline
because it was built to solve the exact same problem we face — recognizing
circuits across fundamentally different visual styles. It open-sources **four
separate datasets**, each targeting a different stage of the pipeline:

**1. Device Identification Dataset (2,914 images, 84,195 annotations)**
Training data for our ComponentDetector stage. The 2,914 complete circuit
diagrams are sourced from textbooks, research papers, and the internet,
deliberately spanning diverse visual styles and complexity levels. Annotations
cover **22 device types** (resistors, capacitors, MOSFETs, op-amps, current
sources, etc.) and **3 crossing types** (junction dot, bridge, plain
crossing). The 84,195 individual annotations make this significantly richer
than SINA's 700+ images for training the YOLO detection model across styles.

**2. Crossing Identification Dataset**
Training data for our CrossingClassifier stage — the submodule that determines
whether intersecting wires are electrically connected. This is a dedicated
labeled set of crossing examples annotated with their type (connected junction,
bridge, or plain/ambiguous). No other public dataset isolates this critical
subproblem, which is one of the leading causes of topology errors.

**3. Device Orientation Classification Dataset**
Training data for determining component rotation and mirroring. When YOLO
detects a MOSFET, it gives a bounding box — but not whether it's rotated 90°,
flipped, or which direction the arrow points. This dataset trains a classifier
that resolves orientation, which directly feeds into our MOSFETResolver for
correct pin assignment (drain vs. source vs. gate).

**4. Netlist Evaluation Dataset (104 manually verified schematic-netlist pairs)**
This is a ground-truth test set, not training data. Each pair consists of a
circuit image and a manually annotated correct netlist. Image2Net also
introduced the **Netlist Edit Distance (NED)** metric — a graph-edit-distance
measure that compares the topology of a generated netlist against ground truth,
ignoring irrelevant differences like component naming. NED is more precise than
simple "pass/fail" accuracy because it quantifies *how wrong* an incorrect
netlist is (one missed connection scores better than a completely wrong
topology). We adopt NED as our primary evaluation metric alongside SINA's
accuracy percentage.

**How Image2Net maps to our pipeline stages:**

```
Image2Net Dataset                Our Pipeline Stage
─────────────────────────────    ──────────────────────────
Device Identification (2,914)  → ComponentDetector (YOLOv11 training)
Crossing Identification        → CrossingClassifier (dedicated model)
Orientation Classification     → MOSFETResolver (rotation/mirror)
Netlist Evaluation (104 pairs) → End-to-end test suite (NED metric)
```

**Key insight from Image2Net's approach:** Their framework detects the overall
drawing style first (by looking at the types of elements present), then
interprets each element according to that style's conventions. This is the
direct basis for our Style Classifier → per-style processing chain
architecture. Image2Net achieved 80.77% success rate on their benchmark, which
is below SINA's 96.47% — but Image2Net was tested on a harder multi-style set
including complex analog ICs, while SINA's test set was more constrained. The
two systems are complementary: SINA gives us the best pipeline architecture,
Image2Net gives us the best training/evaluation data for multi-style support.

### Per-Style Fine-Tuning Strategy

Rather than one model for everything, train **one base model + per-style
fine-tuned heads:**

```
Base YOLO backbone (shared feature extraction, pretrained on full Image2Net)
  ├── Hand-drawn detection head (fine-tuned on JUHCCR-v1 + CircuitNet data)
  ├── Textbook detection head (fine-tuned on Masala-CHAI + AMSNet)
  └── Datasheet detection head (fine-tuned on Image2Net internet subset + custom)
```

Image2Net's 2,914 images span all three styles, so the base backbone pretrains
on the full set. Per-style heads then specialize using the domain-specific data.

The Style Classifier selects which head to use. This avoids the model needing
to simultaneously handle sketchy handwriting and pixel-perfect vector graphics.

---

## Open-Source Code & Repos to Use

| Repo | URL | What We Use From It |
|------|-----|---------------------|
| SINA | arXiv:2601.22114 (contact authors) | Pipeline architecture, YOLO weights, CCL approach |
| Masala-CHAI | github.com/jitendra-bhandari/Masala-CHAI | YOLOv8 checkpoints, Hough transform net detection, 7,500 textbook schematics, prompt templates for VLM |
| Image2Net | referenced in arXiv:2508.13157 | 4 datasets: device ID (2,914 imgs / 84,195 annotations), crossing ID, orientation classification, netlist evaluation (104 ground-truth pairs + NED metric). See Training Data section. |
| JUHCCR-v1 | github.com/AyushRoy2001/Circuit-Component-Analysis | Hand-drawn component dataset + DenseNet-121 baseline |
| CircuitNet | github.com/aaanthonyyy/CircuitNet (MIT) | CNN classification model, Colab demo, reference pipeline |
| asg | github.com/aidangoettsch/asg | XSchem .sch writer reference code |

---

## Component Class Taxonomy

The union of all supported components across the three styles:

**Passive (all styles):**
resistor, capacitor, inductor, potentiometer, fuse

**Semiconductor (all styles):**
diode, led, zener, schottky, npn, pnp

**MOSFET (primarily textbook + datasheet):**
nmos (3-pin), nmos4 (4-pin with body), pmos (3-pin), pmos4 (4-pin with body)

**Sources (all styles):**
voltage_source (DC/AC), current_source, dependent_voltage_source (diamond),
dependent_current_source (diamond)

**Power/Ground (all styles):**
ground, vdd, vss, vcc

**IC-Level (primarily datasheet):**
opamp, comparator, ic_block (generic, N-pin), logic_gate (AND/OR/NOT/NAND/NOR)

**Connections/Annotations (all styles):**
junction_dot, crossing_bridge, off_page_connector, test_point, no_connect

---

## Dependencies

### Python Pipeline
```
ultralytics>=8.3.0        # YOLOv11
opencv-python>=4.9.0       # CCL, skeletonization, morphology
paddlepaddle>=2.6.0        # PaddleOCR backend
paddleocr>=2.7.0           # OCR
numpy>=1.26.0
Pillow>=10.0.0
scikit-image>=0.22.0       # Skeletonization, Hough transform
torch>=2.0.0               # YOLO backend
pdf2image>=1.17.0          # PDF → raster for datasheet input
# Optional:
anthropic>=0.40.0          # Claude VLM verification
openai>=1.50.0             # GPT-4o VLM verification
```

### Zig Editor Side
- `std.json` — JSON parsing (built-in)
- `std.process.Child` — subprocess management (built-in)
- FileIO.zig — your existing interface
- Your UI/rendering framework

### System
- Python 3.10+
- ~2GB disk for model weights
- GPU optional (CPU: ~2-5s/image, GPU: ~0.3s/image)

---

## Implementation Phases

### Phase 1: Bridge Format + Zig Import (1-2 weeks)
Define JSON schema. Implement ImportPlugin.zig. Test with hand-written JSON
(no AI). Get review dialog and staging area working.

### Phase 2: Base Python Pipeline (2-3 weeks)
SINA-based pipeline: YOLOv11 + CCL + OCR → CircuitGraph JSON. Test on clean
textbook images first (easiest case). Use Masala-CHAI's YOLOv8 checkpoint as
a starting point if SINA weights aren't immediately available.

### Phase 3: Connectivity Enforcer (1-2 weeks)
Rubber-band visualization, topology validation, wiring suggestions.

### Phase 4: Style Classifier + Preprocessing (2 weeks)
Add StyleClassifier. Implement per-style preprocessing chains. Train/integrate
crossing classifier from Image2Net data. Wire angle tolerance for hand-drawn.

### Phase 5: MOSFET Terminal Resolver (1-2 weeks)
Specialized post-detection for Razavi-style transistor circuits. Body terminal
detection, drain/source disambiguation, current mirror recognition.

### Phase 6: Datasheet Pipeline (2-3 weeks)
PDF extraction, page segmentation, off-page connector handling, IC block
recognition, multi-page assembly.

### Phase 7: Ghost Image Layer (1 week)
Source image as semi-transparent background. Opacity control. Zoom-sync.

### Phase 8: Training & Accuracy (ongoing)
Collect training data. Fine-tune per-style YOLO heads. Expand component
classes. Add VLM verification. Benchmark against Image2Net's NED metric.

---

## Directory Structure

```
your-editor/
├── src/
│   ├── FileIO.zig
│   └── plugins/import_image/
│       ├── ImportPlugin.zig
│       ├── ConnectivityEnforcer.zig
│       ├── GhostImageLayer.zig
│       ├── ReviewDialog.zig
│       └── symbol_map.zig
│
├── tools/circuit_extractor/
│   ├── circuit_extract.py          # CLI entry point
│   ├── style_classifier.py         # Hand-drawn / textbook / datasheet
│   ├── preprocessors/
│   │   ├── handdrawn.py            # Denoise, deskew, adaptive threshold
│   │   ├── textbook.py             # Crop, normalize
│   │   └── datasheet.py            # PDF extract, page segment
│   ├── detector.py                 # YOLOv11 component detection
│   ├── crossing_classifier.py      # Junction/bridge/plain crossing
│   ├── wire_tracer.py              # CCL + skeletonization
│   ├── mosfet_resolver.py          # Terminal assignment for MOSFETs
│   ├── label_reader.py             # PaddleOCR
│   ├── topology.py                 # Graph construction
│   ├── vlm_verify.py               # Optional VLM cross-check
│   ├── models/
│   │   ├── style_classifier.pt
│   │   ├── yolo_base.pt
│   │   ├── yolo_handdrawn.pt
│   │   ├── yolo_textbook.pt
│   │   ├── yolo_datasheet.pt
│   │   └── crossing_classifier.pt
│   ├── requirements.txt
│   └── tests/
│       ├── handdrawn_samples/
│       ├── razavi_samples/
│       ├── datasheet_samples/
│       └── expected_outputs/
│
├── schemas/
│   └── circuit_graph.schema.json
│
└── docs/
    └── architecture.md
```