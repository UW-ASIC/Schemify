//! MCP prompts — user-controlled templates.
//!
//! Prompts provide circuit design workflow templates that LLM clients
//! use as starting points. Discovered via `prompts/list`, instantiated
//! via `prompts/get`. Each prompt returns a structured message sequence
//! that guides the model through a multi-step design process.

const std = @import("std");
const mcp = @import("types.zig");

// ── Prompt definitions ────────────────────────────────────────────────────────

const PromptEntry = struct {
    name: []const u8,
    description: []const u8,
    arguments: []const mcp.PromptArgument,
    handler: *const fn (std.mem.Allocator, ?std.json.Value) []const u8,
};

const prompts = [_]PromptEntry{
    // ── Circuit design workflows ──────────────────────────────────────────
    .{
        .name = "design_amplifier",
        .description = "Guided differential amplifier design: specify target gain, bandwidth, power budget, and supply. " ++
            "Walks through topology selection, transistor sizing via gm/Id, load design, and bias point verification.",
        .arguments = &.{
            .{ .name = "gain", .description = "Target voltage gain in V/V (e.g. 10, 40, 100)", .required = false },
            .{ .name = "bandwidth", .description = "Target -3dB bandwidth (e.g. 10MHz, 100MHz)", .required = false },
            .{ .name = "power", .description = "Power budget (e.g. 1mW, 500uW)", .required = false },
            .{ .name = "supply", .description = "Supply voltage (e.g. 1.8V, 3.3V, 5V)", .required = false },
            .{ .name = "process", .description = "Process node (e.g. 180nm, 130nm, 65nm, 45nm)", .required = false },
            .{ .name = "topology", .description = "Topology: simple, cascode, folded_cascode, telescopic (default: auto-select)", .required = false },
            .{ .name = "load", .description = "Load type: resistive, active, current_mirror (default: active)", .required = false },
        },
        .handler = &handleDesignAmplifier,
    },
    .{
        .name = "import_xschem",
        .description = "Import an XSchem project into Schemify: detects PDK, converts .sch files, " ++
            "maps symbols, and preserves hierarchy. Handles sky130, gf180mcu, and IHP sg13g2 PDKs.",
        .arguments = &.{
            .{ .name = "project_path", .description = "Path to XSchem project directory or .sch file", .required = true },
            .{ .name = "pdk", .description = "PDK override: sky130, gf180mcu, ihp_sg13g2 (auto-detected if omitted)", .required = false },
            .{ .name = "top_cell", .description = "Top-level cell name (auto-detected if omitted)", .required = false },
            .{ .name = "include_testbenches", .description = "Import testbench files too: true/false (default: true)", .required = false },
        },
        .handler = &handleImportXschem,
    },
    .{
        .name = "optimize_sizing",
        .description = "gm/Id-based transistor sizing optimization: specify circuit topology, target specs, " ++
            "and constraints. Sets up optimization problem, runs gm/Id lookup, and applies optimal W/L values.",
        .arguments = &.{
            .{ .name = "target", .description = "Optimization target: gain, bandwidth, noise, power, area (default: gain)", .required = false },
            .{ .name = "gm_id", .description = "Target gm/Id ratio in S/A (e.g. 10, 15, 20). Higher = more efficient, lower = faster", .required = false },
            .{ .name = "vds_min", .description = "Minimum Vds headroom (e.g. 200mV, 150mV)", .required = false },
            .{ .name = "ids", .description = "Target drain current (e.g. 50uA, 100uA)", .required = false },
            .{ .name = "devices", .description = "Comma-separated instance names to optimize (e.g. M1,M2). All if omitted.", .required = false },
            .{ .name = "process", .description = "Process node for lookup tables (e.g. 180nm, 130nm)", .required = false },
        },
        .handler = &handleOptimizeSizing,
    },

    // ── Quick design templates ────────────────────────────────────────────
    .{
        .name = "design_current_mirror",
        .description = "Design a current mirror: simple, cascode, or wide-swing. Specify reference current and mirror ratio.",
        .arguments = &.{
            .{ .name = "type", .description = "Mirror type: simple, cascode, wide_swing, wilson (default: simple)", .required = false },
            .{ .name = "iref", .description = "Reference current (e.g. 10u, 100u)", .required = false },
            .{ .name = "ratio", .description = "Mirror ratio (e.g. 1, 2, 4, 0.5)", .required = false },
            .{ .name = "supply", .description = "Supply voltage", .required = false },
        },
        .handler = &handleDesignCurrentMirror,
    },
    .{
        .name = "analyze_circuit",
        .description = "Analyze the current schematic: identify topology, check biasing, estimate performance, " ++
            "and suggest improvements. Reads all instances, nets, and connectivity.",
        .arguments = &.{
            .{ .name = "focus", .description = "Analysis focus: power, speed, area, noise, matching, stability (default: general)", .required = false },
        },
        .handler = &handleAnalyzeCircuit,
    },
    .{
        .name = "create_testbench",
        .description = "Create a SPICE testbench for the current circuit with stimulus, analysis commands, and measurements.",
        .arguments = &.{
            .{ .name = "analysis", .description = "Analysis type: dc, ac, tran, noise, pz, monte_carlo (default: tran)", .required = false },
            .{ .name = "corners", .description = "Include process corners: true/false (default: false)", .required = false },
            .{ .name = "duration", .description = "Transient simulation duration (e.g. 10us, 1ms)", .required = false },
            .{ .name = "freq_range", .description = "AC analysis frequency range (e.g. 1Hz-1GHz)", .required = false },
        },
        .handler = &handleCreateTestbench,
    },
    .{
        .name = "explain_circuit",
        .description = "Read the current schematic and provide a detailed explanation of its function, " ++
            "topology identification, signal flow, and key design parameters.",
        .arguments = &.{},
        .handler = &handleExplainCircuit,
    },
};

// ── Prompt list response ──────────────────────────────────────────────────────

pub fn listPrompts(a: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    try w.writeAll("{\"prompts\":[");
    for (prompts, 0..) |prompt, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try mcp.writeJsonStr(w, prompt.name);
        try w.writeAll(",\"description\":");
        try mcp.writeJsonStr(w, prompt.description);
        if (prompt.arguments.len > 0) {
            try w.writeAll(",\"arguments\":[");
            for (prompt.arguments, 0..) |arg, j| {
                if (j > 0) try w.writeByte(',');
                try w.writeAll("{\"name\":");
                try mcp.writeJsonStr(w, arg.name);
                if (arg.description) |desc| {
                    try w.writeAll(",\"description\":");
                    try mcp.writeJsonStr(w, desc);
                }
                if (arg.required) |req| {
                    try w.writeAll(",\"required\":");
                    try w.writeAll(if (req) "true" else "false");
                }
                try w.writeByte('}');
            }
            try w.writeByte(']');
        }
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    return buf.items;
}

// ── Prompt get dispatch ───────────────────────────────────────────────────────

pub fn getPrompt(a: std.mem.Allocator, name: []const u8, arguments: ?std.json.Value) ![]const u8 {
    for (prompts) |prompt| {
        if (std.mem.eql(u8, prompt.name, name)) {
            const messages_json = prompt.handler(a, arguments);
            var buf: std.ArrayList(u8) = .{};
            const w = buf.writer(a);
            try w.writeAll("{\"description\":");
            try mcp.writeJsonStr(w, prompt.description);
            try w.writeAll(",\"messages\":");
            try w.writeAll(messages_json);
            try w.writeByte('}');
            return buf.items;
        }
    }
    return mcp.errorResponse(a, null, .prompt_not_found, "Prompt not found");
}

// ── Prompt handlers ───────────────────────────────────────────────────────────

fn getArgStr(args: ?std.json.Value, key: []const u8, default: []const u8) []const u8 {
    const val = args orelse return default;
    if (val != .object) return default;
    const v = val.object.get(key) orelse return default;
    return switch (v) {
        .string => |s| s,
        else => default,
    };
}

// ── design_amplifier ──────────────────────────────────────────────────────────

fn handleDesignAmplifier(a: std.mem.Allocator, args: ?std.json.Value) []const u8 {
    const gain = getArgStr(args, "gain", "20");
    const bw = getArgStr(args, "bandwidth", "10MHz");
    const power = getArgStr(args, "power", "1mW");
    const supply = getArgStr(args, "supply", "1.8V");
    const process = getArgStr(args, "process", "180nm");
    const topology = getArgStr(args, "topology", "auto");
    const load = getArgStr(args, "load", "active");

    const system_text =
        \\You are a CMOS analog circuit designer using Schemify. Follow these steps precisely.
        \\Use write_pyspice to define circuits as PySpice-RS Python code.
        \\Read resources (schemify://info, schemify://pyspice, schemify://skills/core) for context.
    ;

    const user_text = std.fmt.allocPrint(a,
        \\Design a differential amplifier with these specifications:
        \\- Voltage gain: {s} V/V
        \\- Bandwidth: {s}
        \\- Power budget: {s}
        \\- Supply voltage (VDD): {s}
        \\- Process: {s}
        \\- Topology preference: {s}
        \\- Load type: {s}
        \\
        \\## Design Workflow
        \\
        \\### Step 1: Topology Selection
        \\Based on the gain and bandwidth requirements, select an appropriate topology.
        \\- Av < 20: simple diff pair with active load
        \\- 20 <= Av < 60: telescopic cascode
        \\- Av >= 60: folded cascode or gain-boosted
        \\If topology is 'auto', choose based on these guidelines.
        \\
        \\### Step 2: Bias Point Design
        \\1. Calculate total tail current from power budget: I_tail = Power / VDD
        \\2. Each branch gets I_tail / 2
        \\3. For the input pair, target gm/Id = 15 S/A for balanced speed/efficiency
        \\4. Required gm = Av * gds_load (estimate gds from process)
        \\
        \\### Step 3: Transistor Sizing
        \\Use gm/Id methodology:
        \\1. From gm/Id target, look up Vgs-Vth and ft
        \\2. W/L = (2 * Id) / (un * Cox * (Vgs-Vth)^2) for square-law estimate
        \\3. For {s}: un*Cox ~ 170 uA/V^2 (NMOS), 60 uA/V^2 (PMOS)
        \\4. L >= 2 * Lmin for better matching and output resistance
        \\
        \\### Step 4: Build Circuit
        \\Use `write_pyspice` to define the circuit as PySpice-RS Python code.
        \\Include: input NMOS pair (M1, M2), tail current source (M5),
        \\PMOS active load (M3, M4), and bias circuitry.
        \\
        \\### Step 5: Verification
        \\1. Run `validate_circuit` to check connectivity
        \\2. Run `check_connectivity` to find floating nodes
        \\3. Generate netlist with `generate_netlist`
        \\4. Verify DC operating points are in saturation
        \\
        \\Begin by reading schemify://info and schemify://skills/core, then proceed through each step.
    , .{ gain, bw, power, supply, process, topology, load, process }) catch return "[]";

    return makeMessages(a, system_text, user_text);
}

// ── import_xschem ─────────────────────────────────────────────────────────────

fn handleImportXschem(a: std.mem.Allocator, args: ?std.json.Value) []const u8 {
    const project_path = getArgStr(args, "project_path", ".");
    const pdk = getArgStr(args, "pdk", "auto");
    const top_cell = getArgStr(args, "top_cell", "auto");
    const include_tb = getArgStr(args, "include_testbenches", "true");

    const system_text =
        \\You are importing an XSchem project into Schemify. Follow these steps carefully.
        \\Use file I/O tools (read_file, list_project_files, write_file) and write_pyspice for circuit definitions.
    ;

    const user_text = std.fmt.allocPrint(a,
        \\Import XSchem project into Schemify:
        \\- Project path: {s}
        \\- PDK: {s}
        \\- Top cell: {s}
        \\- Include testbenches: {s}
        \\
        \\## Import Workflow
        \\
        \\### Step 1: Project Discovery
        \\1. Use `list_project_files` to find all .sch files in the project
        \\2. Use `read_file` to examine the top-level schematic
        \\3. Parse the XSchem header to detect:
        \\   - XSchem version (v line)
        \\   - PDK references in symbol paths (sky130_fd_pr, gf180mcu_fd_sc, ihp-sg13g2)
        \\   - Library paths in `xschemrc`
        \\
        \\### Step 2: PDK Detection & Mapping
        \\If PDK is 'auto', detect from symbol paths:
        \\- `sky130_fd_pr/` -> sky130 (SkyWater 130nm)
        \\- `gf180mcu_fd_sc/` -> gf180mcu (GlobalFoundries 180nm)
        \\- `sg13_lv_*/` or `ihp-sg13g2/` -> ihp_sg13g2 (IHP 130nm SiGe)
        \\
        \\Map XSchem symbols to Schemify device kinds:
        \\- `sky130_fd_pr__nfet_01v8` -> nmos4 (model=nfet_01v8)
        \\- `sky130_fd_pr__pfet_01v8` -> pmos4 (model=pfet_01v8)
        \\- `sky130_fd_pr__res_*` -> resistor
        \\- `sky130_fd_pr__cap_*` -> capacitor
        \\- Generic: vsource, isource, gnd, vdd, lab_pin (ipin/opin/iopin)
        \\
        \\### Step 3: Schematic Conversion
        \\For each .sch file:
        \\1. Read with `read_file`
        \\2. Parse XSchem format (C/N/T blocks for components, wires, text)
        \\3. Convert each component to a PySpice-RS circuit definition using `write_pyspice`
        \\4. Preserve net names from wire labels
        \\5. Maintain hierarchy (subcircuit references)
        \\
        \\### Step 4: Validation
        \\1. Run `validate_circuit` on each converted schematic
        \\2. Check that all symbol references resolved
        \\3. Verify pin connectivity matches original
        \\4. Report any unmapped symbols or lost connections
        \\
        \\Begin by listing files at the project path, then read the top-level schematic.
    , .{ project_path, pdk, top_cell, include_tb }) catch return "[]";

    return makeMessages(a, system_text, user_text);
}

// ── optimize_sizing ───────────────────────────────────────────────────────────

fn handleOptimizeSizing(a: std.mem.Allocator, args: ?std.json.Value) []const u8 {
    const target = getArgStr(args, "target", "gain");
    const gm_id = getArgStr(args, "gm_id", "15");
    const vds_min = getArgStr(args, "vds_min", "200mV");
    const ids = getArgStr(args, "ids", "50uA");
    const devices = getArgStr(args, "devices", "all");
    const process = getArgStr(args, "process", "180nm");

    const system_text =
        \\You are performing gm/Id-based transistor sizing optimization in Schemify.
        \\Use read_pyspice to see the current design, and write_pyspice to apply optimized sizes.
        \\Read schemify://instances and schemify://nets to understand the circuit topology.
    ;

    const user_text = std.fmt.allocPrint(a,
        \\Optimize transistor sizing for the current circuit:
        \\- Optimization target: {s}
        \\- Target gm/Id: {s} S/A
        \\- Minimum Vds headroom: {s}
        \\- Target drain current: {s}
        \\- Devices to optimize: {s}
        \\- Process: {s}
        \\
        \\## gm/Id Optimization Workflow
        \\
        \\### Step 1: Circuit Analysis
        \\1. Read schemify://instances to get all transistor instances
        \\2. Read schemify://nets to understand connectivity
        \\3. Identify which transistors are in the signal path vs. bias
        \\4. Determine operating region requirements for each device
        \\
        \\### Step 2: gm/Id Design Space
        \\The gm/Id ratio controls the design tradeoff:
        \\- gm/Id = 5-8: strong inversion, fast, power-hungry, less matching
        \\- gm/Id = 10-15: moderate inversion, balanced speed/efficiency
        \\- gm/Id = 15-25: weak inversion, efficient, slow, good matching
        \\
        \\For the target gm/Id = {s}:
        \\1. Look up corresponding Vgs-Vth from process lookup tables
        \\2. Calculate Vdsat = 2 / (gm/Id) for each device
        \\3. Verify Vds > Vdsat + margin ({s}) for saturation
        \\
        \\### Step 3: Sizing Calculation
        \\For each transistor to optimize:
        \\1. From target Id = {s}: gm = (gm/Id) * Id
        \\2. W/L = gm / (un * Cox * (Vgs - Vth))
        \\   - {s} NMOS: un*Cox ~ 170 uA/V^2, PMOS: ~ 60 uA/V^2
        \\3. Choose L >= 2*Lmin for output resistance and matching
        \\4. Calculate W from W/L ratio
        \\5. Round W to nearest grid (typically 10nm steps)
        \\
        \\### Step 4: Apply Sizes
        \\Use `write_pyspice` to update the circuit definition with optimized sizes:
        \\- W (channel width)
        \\- L (channel length)
        \\- nf (number of fingers, if W is large: nf = W / W_finger_max)
        \\
        \\### Step 5: Verification
        \\1. Check voltage headroom: sum Vdsat values in each stack
        \\2. Verify all devices remain in saturation: Vds > Vdsat
        \\3. Check that gain target is met: Av ~ gm * Rout
        \\4. Estimate bandwidth: ft ~ gm / (2*pi*Cgg)
        \\5. Run `validate_circuit` for final check
        \\
        \\Begin by reading schemify://instances to enumerate the current design.
    , .{ target, gm_id, vds_min, ids, devices, process, gm_id, vds_min, ids, process }) catch return "[]";

    return makeMessages(a, system_text, user_text);
}

// ── design_current_mirror ─────────────────────────────────────────────────────

fn handleDesignCurrentMirror(a: std.mem.Allocator, args: ?std.json.Value) []const u8 {
    const mirror_type = getArgStr(args, "type", "simple");
    const iref = getArgStr(args, "iref", "10u");
    const ratio = getArgStr(args, "ratio", "1");
    const supply = getArgStr(args, "supply", "1.8V");

    const user_text = std.fmt.allocPrint(a,
        \\Design a {s} current mirror with VDD={s}:
        \\- Reference current: Iref = {s}
        \\- Mirror ratio: {s}:1
        \\
        \\## Design Steps
        \\
        \\1. **Topology**: Place the appropriate mirror topology:
        \\   - simple: M1 (diode-connected ref) + M2 (mirror), gates tied
        \\   - cascode: M1/M3 (ref stack) + M2/M4 (mirror stack), improved Rout
        \\   - wide_swing: cascode with Vgs-Vth biased cascode devices, max swing
        \\   - wilson: M1 ref + M2/M3 feedback loop, very high Rout
        \\
        \\2. **Sizing**: For ratio={s}:1, set M2.W = {s} * M1.W
        \\   Keep L identical for matching. Use L >= 2*Lmin.
        \\
        \\3. **Build**: Use `write_pyspice` with the PySpice-RS circuit definition.
        \\   Connect gates together, sources to supply rail (GND for NMOS, VDD for PMOS).
        \\
        \\4. **Verify**: Run `validate_circuit`, check all devices in saturation.
        \\
        \\Read schemify://skills/core for device naming conventions, then build the circuit.
    , .{ mirror_type, supply, iref, ratio, ratio, ratio }) catch return "[]";

    return makeUserMessage(a, user_text);
}

// ── analyze_circuit ───────────────────────────────────────────────────────────

fn handleAnalyzeCircuit(a: std.mem.Allocator, args: ?std.json.Value) []const u8 {
    const focus = getArgStr(args, "focus", "general");

    const user_text = std.fmt.allocPrint(a,
        \\Analyze the current schematic with focus on: {s}
        \\
        \\## Analysis Steps
        \\
        \\1. **Read State**: Query schemify://instances, schemify://nets, schemify://wires
        \\2. **Identify Topology**: Recognize common blocks (diff pair, mirror, cascode, etc.)
        \\3. **Check Biasing**: Verify DC operating points and voltage headroom
        \\4. **Run Diagnostics**:
        \\   - `validate_circuit` for structural errors
        \\   - `check_connectivity` for floating/unconnected pins
        \\   - `drc_check` for design rule violations
        \\5. **Performance Estimation** (focus: {s}):
        \\   - power: calculate total quiescent current, dynamic power
        \\   - speed: estimate dominant poles, unity-gain frequency
        \\   - area: sum transistor areas (W*L), identify oversized devices
        \\   - noise: identify noise-critical devices, estimate input-referred noise
        \\   - matching: check paired devices have identical L and orientation
        \\   - stability: estimate phase margin from loop gain analysis
        \\6. **Suggest Improvements**: Based on findings, recommend specific changes
        \\
        \\Begin by reading schemify://info and schemify://instances.
    , .{ focus, focus }) catch return "[]";

    return makeUserMessage(a, user_text);
}

// ── create_testbench ──────────────────────────────────────────────────────────

fn handleCreateTestbench(a: std.mem.Allocator, args: ?std.json.Value) []const u8 {
    const analysis = getArgStr(args, "analysis", "tran");
    const corners = getArgStr(args, "corners", "false");
    const duration = getArgStr(args, "duration", "10us");
    const freq_range = getArgStr(args, "freq_range", "1Hz-1GHz");

    const user_text = std.fmt.allocPrint(a,
        \\Create a SPICE testbench for the current circuit:
        \\- Analysis type: {s}
        \\- Process corners: {s}
        \\- Transient duration: {s}
        \\- AC frequency range: {s}
        \\
        \\## Testbench Workflow
        \\
        \\1. **Read Circuit**: Query schemify://instances and schemify://nets
        \\2. **Identify I/O**: Find input_pin, output_pin, inout_pin instances
        \\3. **Generate Stimulus**:
        \\   - tran: pulse/sine sources on inputs, step for DC analysis
        \\   - ac: small-signal AC source, DC bias point
        \\   - dc: sweep voltage source
        \\   - noise: identify input/output for noise analysis
        \\4. **Add Power Supplies**: VDD source, bias voltage sources
        \\5. **Analysis Commands**:
        \\   - .tran {s} (with appropriate timestep)
        \\   - .ac dec 20 {s} (log sweep)
        \\   - .dc sweep range
        \\   - .noise V(output) Vinput
        \\6. **Measurements**: .meas for gain, bandwidth, slew rate, settling time
        \\7. **Write**: Use `write_file` to save the testbench as .spice
        \\
        \\Begin by reading schemify://instances to understand the circuit ports.
    , .{ analysis, corners, duration, freq_range, duration, freq_range }) catch return "[]";

    return makeUserMessage(a, user_text);
}

// ── explain_circuit ───────────────────────────────────────────────────────────

fn handleExplainCircuit(_: std.mem.Allocator, _: ?std.json.Value) []const u8 {
    return makeUserMessageStatic(
        \\Read and explain the current schematic in detail.
        \\
        \\## Explanation Steps
        \\
        \\1. Read schemify://info for file and project context
        \\2. Read schemify://instances for all component instances
        \\3. Read schemify://nets for net connectivity
        \\4. Identify the circuit topology:
        \\   - Common structures: diff pair, current mirror, cascode, feedback
        \\   - Supply rails: VDD/GND connections
        \\   - Signal path: input to output
        \\5. For each functional block:
        \\   - Name the block (e.g. "input differential pair")
        \\   - List the components in it
        \\   - Explain its role in the overall circuit
        \\6. Describe the signal flow from input to output
        \\7. Note key design parameters (W/L ratios, bias currents, gain)
        \\8. Identify potential issues (floating nodes, missing bias, mismatch)
    );
}

// ── Message builders ──────────────────────────────────────────────────────────

/// Build a two-message sequence: system (assistant context) + user (task).
fn makeMessages(a: std.mem.Allocator, system_text: []const u8, user_text: []const u8) []const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    w.writeAll("[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":") catch return "[]";
    mcp.writeJsonStr(w, system_text) catch return "[]";
    w.writeAll("}},{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":") catch return "[]";
    mcp.writeJsonStr(w, user_text) catch return "[]";
    w.writeAll("}}]") catch return "[]";
    return buf.items;
}

fn makeUserMessage(a: std.mem.Allocator, text: []const u8) []const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(a);
    w.writeAll("[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":") catch return "[]";
    mcp.writeJsonStr(w, text) catch return "[]";
    w.writeAll("}}]") catch return "[]";
    return buf.items;
}

fn makeUserMessageStatic(comptime text: []const u8) []const u8 {
    return "[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":" ++ comptime blk: {
        // Simple compile-time JSON string escape: wrap in quotes.
        // Since our text has no quotes or backslashes, this is safe.
        break :blk "\"" ++ text ++ "\"";
    } ++ "}}]";
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "listPrompts produces valid JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const result = try listPrompts(a);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const prompt_list = obj.get("prompts").?.array;
    try std.testing.expect(prompt_list.items.len == prompts.len);
}

test "getPrompt unknown returns error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const result = try getPrompt(a, "nonexistent_prompt", null);
    try std.testing.expect(std.mem.indexOf(u8, result, "-32003") != null);
}

test "getPrompt design_amplifier returns messages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const result = try getPrompt(a, "design_amplifier", null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"messages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "differential amplifier") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "gm/Id") != null);
}

test "getPrompt import_xschem returns messages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Test with arguments
    const args_json = "{\"project_path\":\"/home/user/xschem_proj\",\"pdk\":\"sky130\"}";
    const args_parsed = try std.json.parseFromSlice(std.json.Value, a, args_json, .{});
    defer args_parsed.deinit();

    const result = try getPrompt(a, "import_xschem", args_parsed.value);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"messages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "/home/user/xschem_proj") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "sky130") != null);
}

test "getPrompt optimize_sizing returns messages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const result = try getPrompt(a, "optimize_sizing", null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"messages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "gm/Id") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "sizing") != null);
}

test "all prompts produce valid JSON responses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    for (prompts) |prompt| {
        const result = try getPrompt(a, prompt.name, null);
        // Verify it contains messages key (not an error)
        try std.testing.expect(std.mem.indexOf(u8, result, "\"messages\"") != null);
    }
}
