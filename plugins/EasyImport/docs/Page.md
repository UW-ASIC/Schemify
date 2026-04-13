### EasyImport Plugin

This plugin intends to import ANY project from any other schematic software.

Currently supported backends:

- XSchem

#### How to use:

```Zig
pub const EasyImportUnion = union(Backend) {
    // inline a for loop to check this for all the elements in the union
    comptime {
    const required = .{
        .{ "init", fn (std.mem.Allocator) B },
        .{ "label", fn (*const B) []const u8 },
        .{ "detectProjectRoot", fn (*const B, []const u8) bool },
    };
    inline for (required) |r| {
        if (!@hasDecl(B, r[0]))
            @compileError(@typeName(B) ++ " missing required method: " ++ r[0]);
    }
    if (!@hasDecl(B, "convertProject"))
        @compileError(@typeName(B) ++ " missing required method: convertProject");
    if (!@hasDecl(B, "getFiles"))
        @compileError(@typeName(B) ++ " missing required method: getFiles");
    }
    XSchem: XS.Backend
    Virtuoso: Virtuoso.Backend
};

pub const EasyImport = struct {
    ProjectPath: []const u8,
    BackendType: EasyImportUnion,

    pub fn init(alloc: std.mem.Allocator, ProjectPath: []const u8, backend: EasyImportUnion) !EasyImport {
        return EasyImport{
            .ProjectPath = ProjectPath,
            .BackendType = backend,
        };
    }

    // inline this function
    pub fn convertProject(self: *const EasyImport, logger: ?*core.Logger) !void {
        BackendType.convertProject(self.ProjectPath, logger);
    }

    pub fn getFiles(self: *const EasyImport, logger: ?*core.Logger) !void {
        BackendType.getFiles(self.ProjectPath, logger);
    }
};
```

#### Creating a Backend

Your code must implement the functions like this...

```Zig
// Look at the above comptime requirements from the union.
```

#### XSchem-Specific

1. Project Conversion
   - Parse XSchemRC to find PDK path & File paths
     - If none are defined at project root. You might have to find the xschem one in the system and use that one.
   - Convert PDK library (for volare xschem/ to schemify/) and maintain the internal directory structure.
     - That PDK Library now must be referenced by our Schemify Instance (Config.toml should have it as well)
   - Recursively convert the following:
     - However, we need to build a dependency tree, converting the one that are at the roots (because they are the dependencies of others.)
       - So we need to have an iteration to parse to form that dependency tree so we pick the order. From there follow the below:
     - .sch only -> .chn_tb (testbench)
     - .sch + .sym -> .chn (component)
     - .sym only -> .chn_prim (primitive)
     - At the end update the Config.toml with these files (done in the format **/**.chn (or something like it) not listng out each file). Maintain their directory as best as possible.

The result is a project by itself with its own Config.toml and own schematic files that can be referenced by schemify.

- Our App's Config.toml should now reference that Config.toml as a dependency

Notice this Config.toml stuff you may need to modify toml.zig to hot-reload every time the top-level Config.toml is changed, so we can just modify the Config.toml, or maybe the state and it will auto-update the file and vice versa.

Testing:

- The main testing technique here is...
  - When we convert XSchem -> Schemify, we should be able to produce the same netlist from both the original XSchem project and the converted one.
    - Hence, we find pairs that we have converted, it should actually be exportable so we can add a top-level function for that.
    - We build their netlist (for xschem with the xschem app not our own netlister, for schemify with our own netlister)

The code we have right now, may be EXTREMELY INCORRECT

#### Cadence Virtuoso-Specific [WIP]
