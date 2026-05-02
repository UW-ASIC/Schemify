# Testing

## Test Structure

```
src/
  *.zig           unit tests inline (test "..." blocks)
tests/
  roundtrip/      xschem ↔ CHN roundtrip tests
  netlist/        SPICE netlist generation tests
  fixtures/       test schematics (.chn, .sch, .spice)
plugins/
  EasyImport/
    test/         EasyImport plugin integration tests
```

## Running Tests

```bash
# All tests
zig build test

# Filter by name
zig build test -- --test-filter "CHN parser"

# Filter by file
zig build test -- src/core/chn/parser.zig

# Verbose output
zig build test -- --verbose
```

## Unit Tests

Unit tests live inline in the source file they test:

```zig
// src/core/chn/parser.zig

pub fn parseChN(allocator: std.mem.Allocator, input: []const u8) !Schematic {
    // ...
}

test "parseChN: simple SYMBOL section" {
    const input =
        \\chn 1
        \\SYMBOL inv
        \\  pins:
        \\    A  in  x=0 y=0
        \\    Z  out x=40 y=0
    ;
    const result = try parseChN(std.testing.allocator, input);
    defer result.deinit(std.testing.allocator);

    const sym = result.symbol orelse return error.NoSymbol;
    try std.testing.expectEqualStrings("inv", sym.name);
    try std.testing.expectEqual(@as(usize, 2), sym.pins.len);
}
```

## Roundtrip Tests

The xschem roundtrip tests verify that reading a `.sch` file and converting to `.chn` and back produces an equivalent schematic:

```
tests/roundtrip/
  fixtures/
    cmos_inv.sch      xschem source
    cmos_inv.chn      expected CHN output
  roundtrip_test.zig
```

```bash
zig build test -- --test-filter "roundtrip"
```

The roundtrip tests use a dependency graph to handle fixture ordering — schematics that reference symbols are tested after the symbols they depend on.

## Integration Tests

Integration tests in `tests/` use real file I/O via `std.testing.tmpDir()`:

```zig
test "FileIO: write CHN and read back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "test.chn");
    defer std.testing.allocator.free(path);

    const schematic = try buildTestSchematic();
    try FileIO.writeChn(schematic, path);

    const result = try FileIO.readChn(std.testing.allocator, path);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(schematic.instances.len, result.instances.len);
}
```

## GUI Tests

The GUI test checklist in `TODO.md` covers 30+ categories of manual tests for the editor. These are not automated — they require running the editor and verifying behavior visually.

Key categories:
- Wire placement and deletion
- Instance placement, rotation, flip
- Rubber-band selection
- Undo/redo across all operations
- Zoom and pan
- Symbol browser
- Net label placement and connectivity
- Plugin panel docking
- Schematic saving and loading

## Plugin Tests

Plugin integration tests build and load the plugin into a test host:

```zig
test "EasyImport: convert xschem inverter" {
    const plugin = try PluginHost.loadPlugin("libEasyImport.so");
    defer plugin.unload();

    // Send load message
    const load_result = plugin.process(.{.load = {}});
    try std.testing.expect(load_result.registered_panels.len > 0);

    // Send convert command
    const convert_result = plugin.process(.{
        .command = .{ .tag = "convert", .payload = "fixtures/cmos_inv.sch" }
    });
    try std.testing.expect(convert_result.vfs_writes.len > 0);
}
```

## Test Conventions

- No mocking. Use real data structures, real parsers.
- For file I/O tests: `std.testing.tmpDir()`
- For schematic tests: use `tests/fixtures/` test schematics
- All public functions must have at least one test
- Test names follow: `"ModuleName: description of scenario"`
