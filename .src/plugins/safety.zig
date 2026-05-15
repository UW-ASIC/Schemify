//! Plugin safety — ELF binary inspection and trust store management.
//!
//! Provides read-only inspection of native .so files to detect dangerous
//! dynamic symbol imports (execve, dlopen, socket, etc.) without ever
//! loading or executing the plugin. Maintains a SHA-256 based trust store
//! under the XDG config directory for TOFU (trust on first use) approval.
//!
//! This file only imports `std` — no other project dependencies.

const std = @import("std");
const builtin = @import("builtin");
const elf = std.elf;
const Sha256 = std.crypto.hash.sha2.Sha256;

const native_endian: std.builtin.Endian = builtin.target.cpu.arch.endian();

// ── Dangerous imports ────────────────────────────────────────────────────────

const dangerous_import_list = [_][]const u8{
    "dlopen",
    "system",
    "execve",
    "execvp",
    "execl",
    "execlp",
    "fork",
    "popen",
    "socket",
    "connect",
    "bind",
    "listen",
    "accept",
};

// ── ELF inspection ───────────────────────────────────────────────────────────

pub const InspectionResult = struct {
    dangerous_imports: []const []const u8,
    all_imports: []const []const u8,
    is_safe: bool,

    pub fn deinit(self: *const InspectionResult, alloc: std.mem.Allocator) void {
        for (self.all_imports) |name| alloc.free(name);
        if (self.all_imports.len > 0) alloc.free(self.all_imports);
        for (self.dangerous_imports) |name| alloc.free(name);
        if (self.dangerous_imports.len > 0) alloc.free(self.dangerous_imports);
    }
};

pub const InspectError = error{
    InvalidElfMagic,
    InvalidElfClass,
    NotDynamicLibrary,
    MissingSections,
    OutOfMemory,
    FileNotFound,
    IoError,
};

/// Inspect an ELF64 shared object for dangerous dynamic symbol imports.
///
/// Reads the binary on disk, parses ELF headers and the .dynsym/.dynstr
/// sections, and returns all imported symbol names plus any that match the
/// dangerous imports list. Does NOT load or execute the plugin.
pub fn inspectElf(alloc: std.mem.Allocator, path: []const u8) InspectError!InspectionResult {
    const file_bytes = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => return InspectError.FileNotFound,
        error.OutOfMemory => return InspectError.OutOfMemory,
        else => return InspectError.IoError,
    };
    defer alloc.free(file_bytes);

    return inspectElfBytes(alloc, file_bytes);
}

/// Core ELF inspection on a byte slice — enables testing without disk I/O.
fn inspectElfBytes(alloc: std.mem.Allocator, data: []const u8) InspectError!InspectionResult {
    // Validate ELF magic
    if (data.len < @sizeOf(elf.Elf64_Ehdr)) return InspectError.InvalidElfMagic;
    if (!std.mem.eql(u8, data[0..4], elf.MAGIC)) return InspectError.InvalidElfMagic;

    // Require ELF64
    if (data[elf.EI_CLASS] != elf.ELFCLASS64) return InspectError.InvalidElfClass;

    // Determine endianness
    const endian: std.builtin.Endian = switch (data[elf.EI_DATA]) {
        elf.ELFDATA2LSB => .little,
        elf.ELFDATA2MSB => .big,
        else => return InspectError.InvalidElfMagic,
    };

    // Parse ELF header
    const ehdr = readStruct(elf.Elf64_Ehdr, data[0..@sizeOf(elf.Elf64_Ehdr)], endian);

    // Must be a shared object (ET_DYN = 3)
    if (@intFromEnum(ehdr.e_type) != 3) return InspectError.NotDynamicLibrary;

    // Locate section headers
    const shoff = ehdr.e_shoff;
    const shentsize = ehdr.e_shentsize;
    const shnum = ehdr.e_shnum;

    if (shoff == 0 or shnum == 0) return InspectError.MissingSections;
    if (shentsize < @sizeOf(elf.Elf64_Shdr)) return InspectError.MissingSections;

    // Find .dynsym and .dynstr sections
    var dynsym_shdr: ?elf.Elf64_Shdr = null;
    var dynstr_shdr: ?elf.Elf64_Shdr = null;

    for (0..shnum) |i| {
        const offset = shoff + i * shentsize;
        const end = offset + @sizeOf(elf.Elf64_Shdr);
        if (end > data.len) break;

        const shdr = readStruct(elf.Elf64_Shdr, data[offset..][0..@sizeOf(elf.Elf64_Shdr)], endian);

        if (shdr.sh_type == elf.SHT_DYNSYM) {
            dynsym_shdr = shdr;
            // .dynstr is linked via sh_link
            const str_idx = shdr.sh_link;
            if (str_idx < shnum) {
                const str_off = shoff + @as(u64, str_idx) * shentsize;
                const str_end = str_off + @sizeOf(elf.Elf64_Shdr);
                if (str_end <= data.len) {
                    dynstr_shdr = readStruct(
                        elf.Elf64_Shdr,
                        data[str_off..][0..@sizeOf(elf.Elf64_Shdr)],
                        endian,
                    );
                }
            }
            break;
        }
    }

    const dsym = dynsym_shdr orelse return InspectError.MissingSections;
    const dstr = dynstr_shdr orelse return InspectError.MissingSections;

    // Validate section bounds
    if (dsym.sh_offset + dsym.sh_size > data.len) return InspectError.MissingSections;
    if (dstr.sh_offset + dstr.sh_size > data.len) return InspectError.MissingSections;

    const sym_data = data[dsym.sh_offset..][0..dsym.sh_size];
    const str_data = data[dstr.sh_offset..][0..dstr.sh_size];

    const sym_size = @sizeOf(elf.Elf64_Sym);
    if (dsym.sh_entsize != 0 and dsym.sh_entsize != sym_size) return InspectError.MissingSections;
    const num_syms = dsym.sh_size / sym_size;

    // Collect imported symbols: those with SHN_UNDEF (not defined in this object)
    var imports = std.ArrayListUnmanaged([]const u8){};
    var dangerous = std.ArrayListUnmanaged([]const u8){};

    for (0..num_syms) |i| {
        const sym_off = i * sym_size;
        if (sym_off + sym_size > sym_data.len) break;

        const sym = readStruct(elf.Elf64_Sym, sym_data[sym_off..][0..sym_size], endian);

        // Only interested in undefined symbols (imports from other libraries)
        if (sym.st_shndx != elf.SHN_UNDEF) continue;

        // Skip null symbol (index 0 typically)
        if (sym.st_name == 0) continue;

        // Extract name from string table
        const name = extractString(str_data, sym.st_name) orelse continue;
        if (name.len == 0) continue;

        const duped = alloc.dupe(u8, name) catch return InspectError.OutOfMemory;
        imports.append(alloc, duped) catch {
            alloc.free(duped);
            return InspectError.OutOfMemory;
        };

        // Check against dangerous list
        if (isDangerous(name)) {
            const d = alloc.dupe(u8, name) catch return InspectError.OutOfMemory;
            dangerous.append(alloc, d) catch {
                alloc.free(d);
                return InspectError.OutOfMemory;
            };
        }
    }

    const is_safe = dangerous.items.len == 0;
    return .{
        .all_imports = imports.toOwnedSlice(alloc) catch return InspectError.OutOfMemory,
        .dangerous_imports = dangerous.toOwnedSlice(alloc) catch return InspectError.OutOfMemory,
        .is_safe = is_safe,
    };
}

fn isDangerous(name: []const u8) bool {
    for (&dangerous_import_list) |d| {
        if (std.mem.eql(u8, name, d)) return true;
    }
    return false;
}

fn extractString(strtab: []const u8, offset: u32) ?[]const u8 {
    if (offset >= strtab.len) return null;
    const start = strtab[offset..];
    const nul = std.mem.indexOfScalar(u8, start, 0) orelse return start;
    return start[0..nul];
}

/// Read a packed extern struct from a byte slice, converting from file endianness.
fn readStruct(comptime T: type, bytes: *const [@sizeOf(T)]u8, endian: std.builtin.Endian) T {
    var result: T = undefined;
    const result_bytes = std.mem.asBytes(&result);
    @memcpy(result_bytes, bytes);

    // If file endian differs from native, byte-swap each field
    if (endian != native_endian) {
        inline for (std.meta.fields(T)) |field| {
            const F = field.type;
            if (@typeInfo(F) == .int or @typeInfo(F) == .@"enum") {
                const Int = if (@typeInfo(F) == .@"enum") @typeInfo(F).@"enum".tag_type else F;
                const ptr: *Int = @alignCast(@ptrCast(result_bytes.ptr + @offsetOf(T, field.name)));
                ptr.* = @byteSwap(ptr.*);
            }
        }
    }
    return result;
}

// ── Trust store ──────────────────────────────────────────────────────────────

pub const TrustEntry = struct {
    hash: [64]u8,
    path: []const u8,
};

const trust_store_filename = "trusted_plugins.json";

/// Return the path to the trust store JSON file.
///
/// Uses `$XDG_CONFIG_HOME/schemify/trusted_plugins.json` if the env var is
/// set, otherwise falls back to `$HOME/.config/schemify/trusted_plugins.json`.
pub fn trustStorePath(alloc: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.allocPrint(alloc, "{s}/schemify/{s}", .{ xdg, trust_store_filename });
    }
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
    return std.fmt.allocPrint(alloc, "{s}/.config/schemify/{s}", .{ home, trust_store_filename });
}

/// Check if a plugin binary is trusted by comparing its SHA-256 hash
/// against the stored hash in the trust store.
///
/// Returns `false` if the trust store does not exist, the plugin is not
/// listed, or the hash has changed since approval.
pub fn isTrusted(alloc: std.mem.Allocator, plugin_name: []const u8, binary_path: []const u8) bool {
    const hash = hashFile(alloc, binary_path) catch return false;
    const store = readTrustStore(alloc) catch return false;
    defer store.deinit();

    const plugins_obj = switch (store.value) {
        .object => |obj| obj.get("plugins") orelse return false,
        else => return false,
    };

    const entries = switch (plugins_obj) {
        .object => |obj| obj,
        else => return false,
    };

    const entry_val = entries.get(plugin_name) orelse return false;
    const entry_obj = switch (entry_val) {
        .object => |obj| obj,
        else => return false,
    };

    const stored_hash_val = entry_obj.get("hash") orelse return false;
    const stored_hash = switch (stored_hash_val) {
        .string => |s| s,
        else => return false,
    };

    return std.mem.eql(u8, stored_hash, &hash);
}

/// Mark a plugin as trusted by storing the SHA-256 hash of its current binary.
///
/// Creates the trust store directory and file if they do not exist. Updates
/// the entry in-place if the plugin was previously trusted.
pub fn trustPlugin(alloc: std.mem.Allocator, plugin_name: []const u8, binary_path: []const u8) !void {
    const hash = try hashFile(alloc, binary_path);

    const store_path = try trustStorePath(alloc);
    defer alloc.free(store_path);

    // Ensure parent directory exists
    const dir_end = std.mem.lastIndexOfScalar(u8, store_path, '/') orelse return error.InvalidPath;
    const dir_path = store_path[0..dir_end];
    std.fs.cwd().makePath(dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return error.IoError,
    };

    // Read existing store or create empty structure
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var root_obj = std.json.ObjectMap.init(arena_alloc);
    var plugins_obj = std.json.ObjectMap.init(arena_alloc);

    // Try to load existing trust store
    if (std.fs.cwd().readFileAlloc(arena_alloc, store_path, 1024 * 1024)) |existing| {
        if (std.json.parseFromSlice(std.json.Value, arena_alloc, existing, .{})) |parsed| {
            if (parsed.value == .object) {
                // Copy existing plugins
                if (parsed.value.object.get("plugins")) |pv| {
                    if (pv == .object) {
                        var it = pv.object.iterator();
                        while (it.next()) |kv| {
                            plugins_obj.put(kv.key_ptr.*, kv.value_ptr.*) catch return error.OutOfMemory;
                        }
                    }
                }
            }
        } else |_| {
            // Corrupt file — start fresh
        }
    } else |_| {
        // File doesn't exist — start fresh
    }

    // Build the entry object
    var entry = std.json.ObjectMap.init(arena_alloc);
    entry.put(
        "hash",
        std.json.Value{ .string = try arena_alloc.dupe(u8, &hash) },
    ) catch return error.OutOfMemory;
    entry.put(
        "path",
        std.json.Value{ .string = try arena_alloc.dupe(u8, binary_path) },
    ) catch return error.OutOfMemory;

    // Store plugin entry
    const name_duped = try arena_alloc.dupe(u8, plugin_name);
    plugins_obj.put(name_duped, std.json.Value{ .object = entry }) catch return error.OutOfMemory;

    root_obj.put("plugins", std.json.Value{ .object = plugins_obj }) catch return error.OutOfMemory;

    const root = std.json.Value{ .object = root_obj };

    // Serialize to JSON
    const json_bytes = std.json.Stringify.valueAlloc(alloc, root, .{
        .whitespace = .indent_2,
    }) catch return error.OutOfMemory;
    defer alloc.free(json_bytes);

    // Write atomically: write to temp file then rename
    const file = std.fs.cwd().createFile(store_path, .{}) catch return error.IoError;
    defer file.close();
    file.writeAll(json_bytes) catch return error.IoError;
}

/// Remove a plugin from the trust store.
pub fn revokePlugin(alloc: std.mem.Allocator, plugin_name: []const u8) !void {
    const store_path = try trustStorePath(alloc);
    defer alloc.free(store_path);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const existing = std.fs.cwd().readFileAlloc(arena_alloc, store_path, 1024 * 1024) catch return;
    const parsed = std.json.parseFromSlice(std.json.Value, arena_alloc, existing, .{}) catch return;

    if (parsed.value != .object) return;
    const plugins_val = parsed.value.object.get("plugins") orelse return;
    if (plugins_val != .object) return;

    var plugins_obj = std.json.ObjectMap.init(arena_alloc);
    var it = plugins_val.object.iterator();
    while (it.next()) |kv| {
        if (!std.mem.eql(u8, kv.key_ptr.*, plugin_name)) {
            plugins_obj.put(kv.key_ptr.*, kv.value_ptr.*) catch return;
        }
    }

    var root_obj = std.json.ObjectMap.init(arena_alloc);
    root_obj.put("plugins", std.json.Value{ .object = plugins_obj }) catch return;

    const root = std.json.Value{ .object = root_obj };
    const json_bytes = std.json.Stringify.valueAlloc(alloc, root, .{
        .whitespace = .indent_2,
    }) catch return;
    defer alloc.free(json_bytes);

    const file = std.fs.cwd().createFile(store_path, .{}) catch return;
    defer file.close();
    file.writeAll(json_bytes) catch {};
}

/// Compute the SHA-256 hash of a file and return it as a 64-character hex string.
pub fn hashFile(alloc: std.mem.Allocator, path: []const u8) ![64]u8 {
    _ = alloc; // No allocation needed for streaming hash
    const file = std.fs.cwd().openFile(path, .{}) catch return error.IoError;
    defer file.close();

    var hasher = Sha256.init(.{});
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch return error.IoError;
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// Compute SHA-256 of raw bytes, returned as a 64-char lowercase hex string.
pub fn hashBytes(data: []const u8) [64]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

// ── Internal helpers ─────────────────────────────────────────────────────────

fn readTrustStore(alloc: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    const store_path = try trustStorePath(alloc);
    defer alloc.free(store_path);

    const contents = std.fs.cwd().readFileAlloc(alloc, store_path, 1024 * 1024) catch
        return error.FileNotFound;
    defer alloc.free(contents);

    return std.json.parseFromSlice(std.json.Value, alloc, contents, .{});
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "hashBytes produces correct SHA-256" {
    const hash = hashBytes("hello world");
    // SHA-256 of "hello world" is well-known
    try std.testing.expectEqualStrings(
        "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9",
        &hash,
    );
}

test "hashBytes empty input" {
    const hash = hashBytes("");
    // SHA-256 of empty string
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &hash,
    );
}

test "isDangerous matches known symbols" {
    try std.testing.expect(isDangerous("execve"));
    try std.testing.expect(isDangerous("dlopen"));
    try std.testing.expect(isDangerous("socket"));
    try std.testing.expect(isDangerous("fork"));
    try std.testing.expect(isDangerous("system"));
    try std.testing.expect(isDangerous("popen"));
    try std.testing.expect(!isDangerous("printf"));
    try std.testing.expect(!isDangerous("malloc"));
    try std.testing.expect(!isDangerous("schemify_activate"));
}

test "extractString basic" {
    const table = "hello\x00world\x00";
    try std.testing.expectEqualStrings("hello", extractString(table, 0).?);
    try std.testing.expectEqualStrings("world", extractString(table, 6).?);
    try std.testing.expect(extractString(table, 100) == null);
}

test "inspectElfBytes rejects non-ELF" {
    const bad_data = "not an ELF file at all";
    const result = inspectElfBytes(std.testing.allocator, bad_data);
    try std.testing.expectError(InspectError.InvalidElfMagic, result);
}

test "inspectElfBytes rejects truncated header" {
    const short = "\x7fELF";
    const result = inspectElfBytes(std.testing.allocator, short);
    try std.testing.expectError(InspectError.InvalidElfMagic, result);
}

test "inspectElfBytes rejects ELF32" {
    // Construct minimal ELF header with ELFCLASS32
    var buf: [@sizeOf(elf.Elf64_Ehdr)]u8 = undefined;
    @memset(&buf, 0);
    @memcpy(buf[0..4], elf.MAGIC);
    buf[elf.EI_CLASS] = elf.ELFCLASS32;
    buf[elf.EI_DATA] = elf.ELFDATA2LSB;
    const result = inspectElfBytes(std.testing.allocator, &buf);
    try std.testing.expectError(InspectError.InvalidElfClass, result);
}

test "inspectElfBytes parses synthetic ELF with dangerous imports" {
    // Build a minimal ELF64 shared object in memory:
    //   ELF header → 2 section headers (dynsym, dynstr) → dynsym data → dynstr data

    const alloc = std.testing.allocator;

    // String table: \0 printf \0 execve \0 socket \0 schemify_activate \0
    const dynstr =
        "\x00printf\x00execve\x00socket\x00schemify_activate\x00";

    const sym_size = @sizeOf(elf.Elf64_Sym);

    // 4 symbols: null + printf + execve + socket
    // schemify_activate is defined (st_shndx != 0), so it's not an import
    const num_syms = 5;
    var sym_data: [num_syms * sym_size]u8 = undefined;
    @memset(&sym_data, 0);

    // Helper to write a symbol at index i
    const writeSym = struct {
        fn f(buf: []u8, idx: usize, name_off: u32, shndx: u16) void {
            const off = idx * sym_size;
            // st_name: u32 at offset 0
            std.mem.writeInt(u32, buf[off..][0..4], name_off, .little);
            // st_info: u8 at offset 4 (STB_GLOBAL << 4 | STT_FUNC)
            buf[off + 4] = (elf.STB_GLOBAL << 4) | elf.STT_FUNC;
            // st_other: u8 at offset 5
            buf[off + 5] = 0;
            // st_shndx: u16 at offset 6
            std.mem.writeInt(u16, buf[off + 6 ..][0..2], shndx, .little);
            // st_value: u64 at offset 8 — leave 0
            // st_size: u64 at offset 16 — leave 0
        }
    }.f;

    // sym 0: null (already zeroed)
    // sym 1: printf (offset 1, undefined import)
    writeSym(&sym_data, 1, 1, elf.SHN_UNDEF);
    // sym 2: execve (offset 8, undefined import — DANGEROUS)
    writeSym(&sym_data, 2, 8, elf.SHN_UNDEF);
    // sym 3: socket (offset 15, undefined import — DANGEROUS)
    writeSym(&sym_data, 3, 15, elf.SHN_UNDEF);
    // sym 4: schemify_activate (offset 22, defined — NOT an import)
    writeSym(&sym_data, 4, 22, 1);

    // Layout: ehdr | shdr[0] (dynsym) | shdr[1] (dynstr) | sym_data | dynstr
    const ehdr_size = @sizeOf(elf.Elf64_Ehdr);
    const shdr_size = @sizeOf(elf.Elf64_Shdr);
    const shoff = ehdr_size;
    const data_off = ehdr_size + 2 * shdr_size;
    const str_off = data_off + sym_data.len;
    const total = str_off + dynstr.len;

    var buf: [total]u8 = undefined;
    @memset(&buf, 0);

    // ELF header
    @memcpy(buf[0..4], elf.MAGIC);
    buf[elf.EI_CLASS] = elf.ELFCLASS64;
    buf[elf.EI_DATA] = elf.ELFDATA2LSB;
    buf[elf.EI_VERSION] = 1;
    // e_type = ET_DYN (3)
    std.mem.writeInt(u16, buf[16..18], 3, .little);
    // e_machine — doesn't matter for our parser
    std.mem.writeInt(u16, buf[18..20], 0x3E, .little); // EM_X86_64
    // e_version
    std.mem.writeInt(u32, buf[20..24], 1, .little);
    // e_shoff
    std.mem.writeInt(u64, buf[40..48], shoff, .little);
    // e_ehsize
    std.mem.writeInt(u16, buf[52..54], ehdr_size, .little);
    // e_shentsize
    std.mem.writeInt(u16, buf[58..60], shdr_size, .little);
    // e_shnum
    std.mem.writeInt(u16, buf[60..62], 2, .little);

    // Section header 0: .dynsym
    const sh0 = shoff;
    // sh_type = SHT_DYNSYM (11)
    std.mem.writeInt(u32, buf[sh0 + 4 ..][0..4], elf.SHT_DYNSYM, .little);
    // sh_offset
    std.mem.writeInt(u64, buf[sh0 + 24 ..][0..8], data_off, .little);
    // sh_size
    std.mem.writeInt(u64, buf[sh0 + 32 ..][0..8], sym_data.len, .little);
    // sh_link → index of dynstr section (1)
    std.mem.writeInt(u32, buf[sh0 + 40 ..][0..4], 1, .little);
    // sh_entsize
    std.mem.writeInt(u64, buf[sh0 + 56 ..][0..8], sym_size, .little);

    // Section header 1: .dynstr
    const sh1 = shoff + shdr_size;
    // sh_type = SHT_STRTAB (3)
    std.mem.writeInt(u32, buf[sh1 + 4 ..][0..4], elf.SHT_STRTAB, .little);
    // sh_offset
    std.mem.writeInt(u64, buf[sh1 + 24 ..][0..8], str_off, .little);
    // sh_size
    std.mem.writeInt(u64, buf[sh1 + 32 ..][0..8], dynstr.len, .little);

    // Copy data sections
    @memcpy(buf[data_off..][0..sym_data.len], &sym_data);
    @memcpy(buf[str_off..][0..dynstr.len], dynstr);

    // Run inspection
    const result = try inspectElfBytes(alloc, &buf);
    defer result.deinit(alloc);

    // Should find 3 imports (printf, execve, socket) but NOT schemify_activate
    try std.testing.expectEqual(@as(usize, 3), result.all_imports.len);
    try std.testing.expectEqual(@as(usize, 2), result.dangerous_imports.len);
    try std.testing.expect(!result.is_safe);

    // Verify the dangerous ones are execve and socket
    var found_execve = false;
    var found_socket = false;
    for (result.dangerous_imports) |name| {
        if (std.mem.eql(u8, name, "execve")) found_execve = true;
        if (std.mem.eql(u8, name, "socket")) found_socket = true;
    }
    try std.testing.expect(found_execve);
    try std.testing.expect(found_socket);
}

test "inspectElfBytes reports safe for clean binary" {
    const alloc = std.testing.allocator;

    // String table with only safe symbols
    const dynstr = "\x00malloc\x00free\x00schemify_activate\x00";

    const sym_size = @sizeOf(elf.Elf64_Sym);
    const num_syms = 3;
    var sym_data: [num_syms * sym_size]u8 = undefined;
    @memset(&sym_data, 0);

    const writeSym = struct {
        fn f(buf: []u8, idx: usize, name_off: u32, shndx: u16) void {
            const off = idx * sym_size;
            std.mem.writeInt(u32, buf[off..][0..4], name_off, .little);
            buf[off + 4] = (elf.STB_GLOBAL << 4) | elf.STT_FUNC;
            std.mem.writeInt(u16, buf[off + 6 ..][0..2], shndx, .little);
        }
    }.f;

    writeSym(&sym_data, 1, 1, elf.SHN_UNDEF); // malloc
    writeSym(&sym_data, 2, 8, elf.SHN_UNDEF); // free

    const ehdr_size = @sizeOf(elf.Elf64_Ehdr);
    const shdr_size = @sizeOf(elf.Elf64_Shdr);
    const shoff = ehdr_size;
    const data_off = ehdr_size + 2 * shdr_size;
    const str_off = data_off + sym_data.len;
    const total = str_off + dynstr.len;

    var buf: [total]u8 = undefined;
    @memset(&buf, 0);

    @memcpy(buf[0..4], elf.MAGIC);
    buf[elf.EI_CLASS] = elf.ELFCLASS64;
    buf[elf.EI_DATA] = elf.ELFDATA2LSB;
    buf[elf.EI_VERSION] = 1;
    std.mem.writeInt(u16, buf[16..18], 3, .little);
    std.mem.writeInt(u16, buf[18..20], 0x3E, .little);
    std.mem.writeInt(u32, buf[20..24], 1, .little);
    std.mem.writeInt(u64, buf[40..48], shoff, .little);
    std.mem.writeInt(u16, buf[52..54], ehdr_size, .little);
    std.mem.writeInt(u16, buf[58..60], shdr_size, .little);
    std.mem.writeInt(u16, buf[60..62], 2, .little);

    const sh0 = shoff;
    std.mem.writeInt(u32, buf[sh0 + 4 ..][0..4], elf.SHT_DYNSYM, .little);
    std.mem.writeInt(u64, buf[sh0 + 24 ..][0..8], data_off, .little);
    std.mem.writeInt(u64, buf[sh0 + 32 ..][0..8], sym_data.len, .little);
    std.mem.writeInt(u32, buf[sh0 + 40 ..][0..4], 1, .little);
    std.mem.writeInt(u64, buf[sh0 + 56 ..][0..8], sym_size, .little);

    const sh1 = shoff + shdr_size;
    std.mem.writeInt(u32, buf[sh1 + 4 ..][0..4], elf.SHT_STRTAB, .little);
    std.mem.writeInt(u64, buf[sh1 + 24 ..][0..8], str_off, .little);
    std.mem.writeInt(u64, buf[sh1 + 32 ..][0..8], dynstr.len, .little);

    @memcpy(buf[data_off..][0..sym_data.len], &sym_data);
    @memcpy(buf[str_off..][0..dynstr.len], dynstr);

    const result = try inspectElfBytes(alloc, &buf);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), result.all_imports.len);
    try std.testing.expectEqual(@as(usize, 0), result.dangerous_imports.len);
    try std.testing.expect(result.is_safe);
}

test "trustStorePath uses XDG_CONFIG_HOME" {
    // This test relies on HOME being set (always true on Linux in test env)
    const path = try trustStorePath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/schemify/trusted_plugins.json"));
}
