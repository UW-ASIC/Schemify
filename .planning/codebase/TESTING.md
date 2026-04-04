# Testing Patterns

**Analysis Date:** 2026-04-04

## Test Framework

**Runner:**
- Zig built-in `test` blocks (no external test framework)
- Custom test runner: `test/test_runner.zig` -- prints pass/fail/skip/leak per test
- Custom size runner: `test/size_runner.zig` -- collects `@sizeOf` reports
- Config: `build.zig` `test_defs` array and `test` step definition

**Assertion Library:**
- `std.testing` (Zig standard library)
- Key functions: `expectEqual`, `expectEqualStrings`, `expect`, `expectError`

**Run Commands:**
```bash
zig build test           # Run all test suites
zig build test_core      # Run core module tests only
zig build test_utility   # Run utility module tests only
zig build test-core      # Hyphenated alias for test_core
zig build get_size       # Print @sizeOf for every struct in src/
```

## Test File Organization

**Location:** Two patterns coexist:

1. **Inline tests in `lib.zig`** -- module-level tests live at the bottom of each module's `lib.zig`. This is the primary pattern for unit tests.
2. **Inline tests in struct files** -- individual `.zig` files contain tests specific to that file's struct/functionality.
3. **External test files** in `test/` -- integration-level and extensive test suites.

**Naming:**
- Inline: `test "descriptive name"` blocks at bottom of `.zig` files
- External: `test/<module>/test_<module>.zig` (e.g., `test/core/test_core.zig`)

**Structure:**
```
test/
  test_runner.zig         # Custom runner with pass/fail/leak reporting
  size_runner.zig         # Struct size collection runner
  core/
    test_core.zig         # Extensive Reader/Writer/Schemify tests (~1100 LOC)
```

**Test discovery mechanism:** `lib.zig` uses a `comptime` block to import all sub-files, which pulls their `test` blocks into the test binary:
```zig
// src/core/lib.zig
comptime {
    _ = @import("types.zig");
    _ = @import("Devices.zig");
    _ = @import("Reader.zig");
    _ = @import("Writer.zig");
    // ...
}
```

Alternative pattern using `refAllDecls`:
```zig
// src/commands/lib.zig
test {
    @import("std").testing.refAllDecls(@This());
}
```

## Test Suites Defined in build.zig

The `test_defs` array in `build.zig` defines which test suites exist:

```zig
const test_defs = [_]Def{
    .{ "core", "test/core/test_core.zig", &.{"core"} },
    .{ "utility", "src/utility/lib.zig", &.{} },
};
```

Each entry creates:
- A `zig build test_<name>` step
- A `zig build test-<name>` hyphenated alias
- The aggregate `zig build test` step includes all suites

Tests are compiled with `optimize = .ReleaseFast` and use the custom `test/test_runner.zig`.

## Test Structure

**Suite organization -- inline in lib.zig:**
```zig
// src/state/lib.zig
test "Viewport zoom clamps" {
    var vp = Viewport{};
    vp.zoomIn();
    try std.testing.expect(vp.zoom > 1.0);
    vp.zoomReset();
    try std.testing.expectEqual(@as(f32, 1.0), vp.zoom);
}

test "Selection clear and isEmpty" {
    var sel = Selection{};
    try std.testing.expect(sel.isEmpty());
    sel.clear();
    try std.testing.expect(sel.isEmpty());
}
```

**Suite organization -- external file with helpers:**
```zig
// test/core/test_core.zig
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const Schemify = core.Schemify;

// Helpers at top
fn readCHN(data: []const u8) Schemify {
    return Schemify.readFile(data, testing.allocator, null);
}

fn roundTrip(input: []const u8) !void {
    var s1 = readCHN(input);
    defer s1.deinit();
    const written = s1.writeFile(testing.allocator, null) orelse return error.WriteFailed;
    defer testing.allocator.free(written);
    var s2 = Schemify.readFile(written, testing.allocator, null);
    defer s2.deinit();
    try testing.expectEqual(s1.instances.len, s2.instances.len);
    // ...
}

test "round-trip: empty schematic" {
    try roundTrip("chn 1.0\n");
}
```

**Patterns:**
- Setup: Direct struct initialization with defaults (no setup/teardown functions)
- Teardown: `defer` for cleanup: `defer s1.deinit();`, `defer testing.allocator.free(written);`
- Assertions: `try std.testing.expectX(...)` -- always `try`, never discard errors

## Test Categories

### 1. Type Round-Trip Tests
Verify serialization/deserialization consistency for enums and tags:

```zig
// src/core/lib.zig
test "PinDir fromStr/toStr round-trip" {
    const PD = types.PinDir;
    const dirs = [_]PD{ .input, .output, .inout, .power, .ground };
    for (dirs) |d| {
        const s = d.toStr();
        const back = PD.fromStr(s);
        try std.testing.expectEqual(d, back);
    }
}

test "ConnKind tag round-trip" {
    const CK = types.ConnKind;
    const kinds = [_]CK{ .instance_pin, .wire_endpoint, .label };
    for (kinds) |k| {
        const tag = k.toTag();
        const back = CK.fromTag(tag);
        try std.testing.expectEqual(k, back);
    }
}
```

**Files:** `src/core/lib.zig`

### 2. Struct Size Tests
Guard against padding bloat and track memory footprint:

```zig
// src/commands/lib.zig
test "Expose struct size for Command" {
    const print = @import("std").debug.print;
    print("Command:      {d}B\n", .{@sizeOf(Command)});
    print("PlaceDevice:  {d}B\n", .{@sizeOf(PlaceDevice)});
}
```

Also used as assertions:
```zig
// src/plugins/lib.zig
test "ParsedWidget field order is data-oriented (largest alignment first)" {
    const pw_size = @sizeOf(ParsedWidget);
    try std.testing.expect(pw_size <= 40);
}
```

**Files:** `src/commands/lib.zig`, `src/utility/lib.zig`, `src/plugins/lib.zig`, `src/plugins/installer.zig`, `src/core/Schemify.zig`, `src/core/SpiceIF.zig`, `src/core/Toml.zig`, `src/commands/Undo.zig`

### 3. State/Behavior Unit Tests
Verify struct method behavior in isolation:

```zig
// src/state/lib.zig
test "ClosedTabs ring buffer" {
    var tabs = ClosedTabs{};
    try std.testing.expectEqual(@as(?[]const u8, null), tabs.popLast());
    const a = std.testing.allocator;
    tabs.push(a, "a.chn");
    tabs.push(a, "b.chn");
    try std.testing.expectEqual(@as(u8, 2), tabs.len);
    const last = tabs.popLast().?;
    try std.testing.expectEqualStrings("b.chn", last);
    a.free(last);
}
```

**Files:** `src/state/lib.zig`, `src/utility/lib.zig`

### 4. Wire Protocol Tests
Verify binary message encoding/decoding:

```zig
// src/plugins/lib.zig
test "Reader round-trip: load message" {
    var buf: [64]u8 = undefined;
    buf[0] = 0x01; // Tag.load
    std.mem.writeInt(u16, buf[1..3], 6, .little);
    std.mem.writeInt(u16, buf[3..5], 4, .little);
    @memcpy(buf[5..9], "test");

    var r = Reader.init(buf[0..9]);
    const msg = r.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("test", msg.load.project_dir);
    try std.testing.expect(r.next() == null);
}

test "Writer overflow flag" {
    var buf: [2]u8 = undefined;
    var w = Writer.init(&buf);
    w.setStatus("this is way too long for a 2-byte buffer");
    try std.testing.expect(w.overflow());
}
```

**Files:** `src/plugins/lib.zig`

### 5. Parser Tests
Verify file format and config parsing:

```zig
// src/core/Toml.zig
test "toml parse paths array" {
    var cfg = try ProjectConfig.parseFromString(std.testing.allocator,
        \\[paths]
        \\chn = ["inv.chn", "buf.chn"]
        \\chn_tb = ["tb.chn_tb"]
    );
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 2), cfg.paths.chn.len);
    try std.testing.expectEqualStrings("inv.chn", cfg.paths.chn[0]);
}

test "toml missing file returns default" {
    var cfg = try ProjectConfig.parseFromPath(std.testing.allocator, "/nonexistent/path");
    defer cfg.deinit();
    try std.testing.expectEqualStrings("Untitled", cfg.name);
}
```

**Files:** `src/core/Toml.zig`, `src/core/HdlParser.zig` (Verilog/VHDL parser tests), `src/core/YosysJson.zig`, `src/core/Synthesis.zig`, `src/core/devices/primitives.zig`

### 6. Integration/Round-Trip Tests
Full read-write-read cycle for file formats:

```zig
// test/core/test_core.zig
test "round-trip preserves instances" {
    const input = "chn 1.0\n  instances\n    R1 resistor 100 200\n";
    var s1 = readCHN(input);
    defer s1.deinit();
    const written = s1.writeFile(testing.allocator, null) orelse return error.WriteFailed;
    defer testing.allocator.free(written);
    var s2 = Schemify.readFile(written, testing.allocator, null);
    defer s2.deinit();
    try testing.expectEqual(s1.instances.len, s2.instances.len);
}
```

**Files:** `test/core/test_core.zig` (~1100 LOC of extensive tests)

### 7. GUI Theme Tests
JSON parsing and override behavior:

```zig
// src/gui/Theme.zig
test "applyJson: valid JSON sets overrides" { ... }
test "applyJson: invalid JSON leaves overrides unchanged" { ... }
test "applyJson: full replacement resets prior values (D-05)" { ... }
test "applyJson: unknown fields ignored (D-06)" { ... }
test "applyJson: color clamping" { ... }
```

**Files:** `src/gui/Theme.zig`

### 8. Comptime Device Table Tests
Verify comptime-built lookup tables from `.chn_prim` files:

```zig
// src/core/Devices.zig
test "device_table built from .chn_prim files: nmos4 prefix" {
    try testing.expectEqual(@as(u8, 'M'), device_table[@intFromEnum(DeviceKind.nmos4)].prefix);
}

test "device_table built from .chn_prim files: nmos4 pins" {
    const pins = device_table[@intFromEnum(DeviceKind.nmos4)].pins;
    try testing.expectEqual(@as(usize, 4), pins.len);
}
```

**Files:** `src/core/Devices.zig`, `src/core/devices/primitives.zig`

## Mocking

**No mocking framework.** Zig's comptime generics and `anytype` parameters provide natural test seams:

**`state: anytype` pattern** -- command handlers accept any type that has the right field shape, so tests can pass a minimal mock:
```zig
// Command handlers use state: anytype
pub fn handle(imm: Immediate, state: anytype) Error!void {
    state.view.zoomIn();  // works with any type that has .view.zoomIn()
}
```

**`std.testing.allocator`** -- the standard testing allocator detects leaks and double-frees. The custom test runner (`test/test_runner.zig`) resets it per test and reports leaks:
```zig
for (builtin.test_functions) |t| {
    std.testing.allocator_instance = .{};
    defer {
        if (std.testing.allocator_instance.deinit() == .leak) {
            leak += 1;
        }
    }
    t.func() catch |err| { ... };
}
```

**No external service mocking.** Tests use:
- In-memory data (string literals parsed directly)
- `testing.allocator` for allocation
- `null` for optional logger parameters

## Fixtures and Test Data

**Inline string literals** -- test data is embedded directly in test blocks using Zig multiline strings:
```zig
test "toml parse paths array" {
    var cfg = try ProjectConfig.parseFromString(std.testing.allocator,
        \\[paths]
        \\chn = ["inv.chn", "buf.chn"]
    );
    defer cfg.deinit();
}
```

**CHN format test data** in `test/core/test_core.zig` uses multiline string literals representing schematic files.

**Binary test data** constructed manually for wire protocol tests:
```zig
var buf: [64]u8 = undefined;
buf[0] = 0x01; // Tag.load
std.mem.writeInt(u16, buf[1..3], 6, .little);
```

**No fixture files on disk** -- all test data is inline. Exception: `test "toml missing file returns default"` intentionally reads a nonexistent path.

## Coverage

**Requirements:** None enforced. No coverage threshold or CI gate.

**View coverage:** Zig does not have built-in coverage reporting. Use LLVM-based tools if needed:
```bash
zig build test -Doptimize=Debug  # Debug builds include DWARF info
```

## Test Count by Module

| Module | File | Approx. Tests |
|--------|------|---------------|
| core | `src/core/lib.zig` | 6 |
| core | `src/core/Toml.zig` | 6 |
| core | `src/core/Devices.zig` | 14 |
| core | `src/core/HdlParser.zig` | 10 |
| core | `src/core/SpiceIF.zig` | 4 |
| core | `src/core/Synthesis.zig` | 9 |
| core | `src/core/YosysJson.zig` | 7 |
| core | `src/core/devices/primitives.zig` | 12 |
| core | `src/core/Schemify.zig` | 1 |
| core (external) | `test/core/test_core.zig` | ~50+ |
| state | `src/state/lib.zig` | 8 |
| utility | `src/utility/lib.zig` | 8 |
| commands | `src/commands/lib.zig` | 2 |
| commands | `src/commands/Undo.zig` | 1 |
| plugins | `src/plugins/lib.zig` | 11 |
| plugins | `src/plugins/installer.zig` | 1 |
| gui | `src/gui/Theme.zig` | 7 |
| **Total** | | **~157+** |

## Test Types

**Unit Tests:**
- Scope: Individual struct methods, enum conversions, utility functions
- Location: Inline in `lib.zig` and individual struct files
- Pattern: Direct instantiation, call method, assert result

**Integration Tests:**
- Scope: Full read-parse-write-reparse cycles for file formats
- Location: `test/core/test_core.zig`
- Pattern: Parse input string, write output, reparse, compare structural equality

**E2E Tests:**
- Not present. GUI testing requires manual verification on both backends (`zig build run` native, `zig build -Dbackend=web` WASM).

## Common Patterns

**Async Testing:** Not applicable -- Zig tests are synchronous. WASM paths are `comptime`-gated out of test builds.

**Error Testing:**
```zig
// Test that missing config returns default (not an error)
test "toml missing file returns default" {
    var cfg = try ProjectConfig.parseFromPath(std.testing.allocator, "/nonexistent/path");
    defer cfg.deinit();
    try std.testing.expectEqualStrings("Untitled", cfg.name);
}

// Test that parse errors are returned correctly
test "verilog module not found returns error" {
    const result = HdlParser.parse(testing.allocator, .verilog, src, "nonexistent");
    try testing.expectError(error.ModuleNotFound, result);
}
```

**Leak Detection:**
The custom test runner (`test/test_runner.zig`) resets `std.testing.allocator_instance` before each test and checks for leaks in `defer`. Tests that allocate must free or the runner will report a leak and exit with code 1.

**Exhaustive Enum Testing:**
```zig
test "PinDir fromStr/toStr round-trip" {
    const dirs = [_]PD{ .input, .output, .inout, .power, .ground };
    for (dirs) |d| {
        const s = d.toStr();
        const back = PD.fromStr(s);
        try std.testing.expectEqual(d, back);
    }
}
```

## Adding New Tests

**For a new module:**
1. Add tests to the module's `lib.zig` at the bottom
2. Ensure `comptime { _ = @import("NewFile.zig"); }` in `lib.zig` to pull sub-file tests
3. If extensive, create `test/<module>/test_<module>.zig`
4. Add entry to `test_defs` in `build.zig`:
   ```zig
   .{ "mymodule", "test/mymodule/test_mymodule.zig", &.{"mymodule"} },
   ```

**For a new struct file:**
1. Add `test "Expose struct size for TypeName"` to report padding
2. Add behavioral tests at bottom of the file
3. Ensure `lib.zig` imports it in the `comptime` block

**For the "get_size" step:**
Add a test containing the string `"Expose struct size"` to any `.zig` file in `src/`. The `build.zig` walker will find it automatically.

---

*Testing analysis: 2026-04-04*
