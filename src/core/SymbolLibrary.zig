//! SymbolLibrary — comptime duck-typing contract for symbol resolution.
//!
//! There is no runtime struct here. Any type `T` is a valid resolver if it
//! exposes exactly one declaration:
//!
//!   pub fn resolve(self: *T, name: []const u8) ?*const Schemify
//!
//! Usage in a generic function:
//!
//!   fn myNetlister(comptime R: type, resolver: *R, ...) void {
//!       validateResolver(R);           // compile-time contract check
//!       if (resolver.resolve("nmos")) |def| { ... }
//!   }
//!
//! Example — in-memory map resolver:
//!
//!   pub const MapLibrary = struct {
//!       map: std.StringHashMapUnmanaged(*const Schemify),
//!
//!       pub fn resolve(self: *@This(), name: []const u8) ?*const Schemify {
//!           return self.map.get(name);
//!       }
//!   };
//!
//! Example — lazy-loading disk resolver:
//!
//!   pub const EasyPDKLibrary = struct {
//!       paths: std.ArrayListUnmanaged([]const u8),
//!       cache: std.StringHashMapUnmanaged(*Schemify),
//!       alloc: std.mem.Allocator,
//!
//!       pub fn resolve(self: *@This(), name: []const u8) ?*const Schemify {
//!           if (self.cache.get(name)) |hit| return hit;
//!           for (self.paths.items) |path| {
//!               if (std.mem.endsWith(u8, path, name)) {
//!                   // load from disk, insert into cache, return pointer
//!               }
//!           }
//!           return null;
//!       }
//!   };

const sch = @import("Schemify.zig");
pub const Schemify = sch.Schemify;

/// Compile-time check that `T` satisfies the resolver contract.
/// Emits a descriptive @compileError if the `resolve` declaration is absent.
pub fn validateResolver(comptime T: type) void {
    if (!@hasDecl(T, "resolve")) {
        @compileError(
            @typeName(T) ++
            " must have: pub fn resolve(self: *" ++
            @typeName(T) ++
            ", name: []const u8) ?*const Schemify",
        );
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────── //

test "validateResolver accepts conforming type" {
    const GoodLib = struct {
        pub fn resolve(_: *@This(), _: []const u8) ?*const Schemify {
            return null;
        }
    };
    // Must not @compileError
    validateResolver(GoodLib);
}
