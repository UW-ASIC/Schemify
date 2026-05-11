//! WASM plugin loader — wasm3-based plugin execution for sandboxed WASM modules.
//!
//! WASM plugins run in a sandboxed environment where the only way to interact
//! with the host is through imported `schemify_host_*` functions. This provides
//! strong security guarantees:
//!
//!   - No direct memory access to host address space
//!   - No filesystem access except through host-provided APIs
//!   - No network access
//!   - No syscalls — all capabilities are mediated by the host function table
//!   - Deterministic execution (no threads, no randomness unless host provides it)
//!
//! Because of this sandboxing, WASM plugins are auto-approved (no TOFU trust
//! prompt) as long as `validateImports()` confirms they only import the
//! sanctioned `schemify_host_*` functions.
//!
//! ## Architecture
//!
//! The loading pipeline is:
//!   1. Read .wasm bytes from disk
//!   2. `validateImports()` — parse the import section of the WASM binary to
//!      ensure only `schemify_host_*` functions are imported (no WASI, etc.)
//!   3. Instantiate a wasm3 environment + runtime + module
//!   4. Link host functions: bind each `schemify_host_*` import to the
//!      corresponding entry in the SchemifyHost function pointer table
//!   5. Find and validate `schemify_activate` export
//!   6. Return `WasmPlugin` with trampolines wrapping WASM exports
//!
//! ## Memory model
//!
//! WASM plugins operate in their own linear memory. String arguments (JSON, HTML)
//! are passed as (offset, length) pairs into WASM linear memory. The plugin
//! allocates via its own malloc/schemify_alloc export, and returns string pointers
//! as offsets into its linear memory.

const std = @import("std");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;

// -- wasm3 C bindings (conditional on build availability) ---------------------

const wasm3_mod = @import("wasm3");

/// Detect whether the real wasm3 module is available (has `c` field with @cImport)
/// or if we got the stub (has `is_stub` sentinel).
const has_runtime = @hasDecl(wasm3_mod, "c") and !@hasDecl(wasm3_mod, "is_stub");

const m3 = if (has_runtime) wasm3_mod.c else struct {};

// -- Availability flag --------------------------------------------------------

/// Comptime flag indicating whether the WASM runtime is available.
/// Other modules can check `loader_wasm.available` to gate WASM-specific paths.
pub const available = has_runtime;

// -- Errors -------------------------------------------------------------------

pub const LoadError = error{
    /// The WASM runtime (wasm3) is not compiled in.
    WasmNotAvailable,
    /// The .wasm binary could not be parsed or failed validation.
    InvalidModule,
    /// The module does not export `schemify_activate`.
    MissingActivate,
    /// The module imports functions outside the allowed `schemify_host_*` set.
    UntrustedImports,
    /// Allocator failure during module instantiation.
    OutOfMemory,
    /// wasm3 returned an error during linking or compilation.
    LinkError,
    /// The WASM module trapped during execution.
    Trap,
    /// File could not be read from disk.
    FileNotFound,
};

// -- WASM binary format constants ---------------------------------------------

const WASM_MAGIC = [4]u8{ 0x00, 0x61, 0x73, 0x6D };
const WASM_VERSION = [4]u8{ 0x01, 0x00, 0x00, 0x00 };
const SECTION_IMPORT: u8 = 2;
const IMPORT_KIND_FUNC: u8 = 0;

// -- LEB128 decoder -----------------------------------------------------------

/// Decode an unsigned LEB128 value from a byte slice.
/// Returns the decoded value and number of bytes consumed, or null on overflow/underrun.
fn decodeLeb128(bytes: []const u8) ?struct { value: u32, len: usize } {
    var result: u32 = 0;
    var shift: u5 = 0;
    for (bytes, 0..) |byte, i| {
        if (i >= 5) return null; // u32 LEB128 is at most 5 bytes
        const payload: u32 = @as(u32, byte & 0x7F);
        if (shift >= 32) return null;
        result |= payload << shift;
        shift +%= 7;
        if (byte & 0x80 == 0) {
            return .{ .value = result, .len = i + 1 };
        }
    } else {
        return null; // ran out of bytes
    }
}

// -- Import validation (standalone WASM binary parser) ------------------------

/// Validate that a WASM module only imports functions from the `schemify_host_*`
/// namespace under the `"env"` module. This is the security gate for
/// auto-approving WASM plugins.
///
/// Returns `true` if the module is safe to auto-approve (all imports are
/// sanctioned `schemify_host_*` functions), `false` if any unexpected imports
/// are found (e.g., WASI functions, raw memory imports from unknown modules).
///
/// This function parses the WASM binary format directly — no wasm3 needed.
pub fn validateImports(wasm_bytes: []const u8) bool {
    // Minimum valid WASM: 8 bytes (magic + version)
    if (wasm_bytes.len < 8) return false;

    // Validate magic number
    if (!std.mem.eql(u8, wasm_bytes[0..4], &WASM_MAGIC)) return false;

    // Validate version
    if (!std.mem.eql(u8, wasm_bytes[4..8], &WASM_VERSION)) return false;

    // Iterate sections to find the Import section (ID = 2)
    var offset: usize = 8;
    while (offset < wasm_bytes.len) {
        // Section ID (1 byte)
        if (offset >= wasm_bytes.len) return false;
        const section_id = wasm_bytes[offset];
        offset += 1;

        // Section size (LEB128)
        const size_result = decodeLeb128(wasm_bytes[offset..]) orelse return false;
        offset += size_result.len;
        const section_size = size_result.value;

        if (section_id == SECTION_IMPORT) {
            // Parse import section contents
            return parseImportSection(wasm_bytes[offset..][0..section_size]);
        }

        // Skip this section
        offset += section_size;
    }

    // No import section found — module imports nothing, which is valid.
    return true;
}

/// Parse the import section and validate all entries.
fn parseImportSection(data: []const u8) bool {
    var offset: usize = 0;

    // Number of imports (LEB128)
    const count_result = decodeLeb128(data[offset..]) orelse return false;
    offset += count_result.len;
    const num_imports = count_result.value;

    var i: u32 = 0;
    while (i < num_imports) : (i += 1) {
        // Module name length (LEB128)
        const mod_len_result = decodeLeb128(data[offset..]) orelse return false;
        offset += mod_len_result.len;
        const mod_len = mod_len_result.value;

        // Module name bytes
        if (offset + mod_len > data.len) return false;
        const mod_name = data[offset..][0..mod_len];
        offset += mod_len;

        // Field name length (LEB128)
        const field_len_result = decodeLeb128(data[offset..]) orelse return false;
        offset += field_len_result.len;
        const field_len = field_len_result.value;

        // Field name bytes
        if (offset + field_len > data.len) return false;
        const field_name = data[offset..][0..field_len];
        offset += field_len;

        // Import kind (1 byte)
        if (offset >= data.len) return false;
        const kind = data[offset];
        offset += 1;

        // Skip the kind-specific data
        switch (kind) {
            0 => {
                // Function import: type index (LEB128)
                const type_result = decodeLeb128(data[offset..]) orelse return false;
                offset += type_result.len;
            },
            1 => {
                // Table import: element type (1 byte) + limits
                offset += 1; // element type
                if (offset >= data.len) return false;
                const limits_flags = data[offset];
                offset += 1;
                const min_result = decodeLeb128(data[offset..]) orelse return false;
                offset += min_result.len;
                if (limits_flags & 1 != 0) {
                    const max_result = decodeLeb128(data[offset..]) orelse return false;
                    offset += max_result.len;
                }
            },
            2 => {
                // Memory import: limits
                if (offset >= data.len) return false;
                const limits_flags = data[offset];
                offset += 1;
                const min_result = decodeLeb128(data[offset..]) orelse return false;
                offset += min_result.len;
                if (limits_flags & 1 != 0) {
                    const max_result = decodeLeb128(data[offset..]) orelse return false;
                    offset += max_result.len;
                }
            },
            3 => {
                // Global import: value type (1 byte) + mutability (1 byte)
                offset += 2;
            },
            else => return false, // Unknown import kind
        }

        // Validate: module name must be "env"
        if (!std.mem.eql(u8, mod_name, "env")) return false;

        // Validate: function imports must start with "schemify_host_"
        if (kind == IMPORT_KIND_FUNC) {
            if (!std.mem.startsWith(u8, field_name, "schemify_host_")) return false;
        } else {
            // We only allow function imports from "env"
            // Memory/table/global imports from "env" are not permitted
            return false;
        }
    }

    return true;
}

// -- WasmPlugin ---------------------------------------------------------------

/// A loaded WASM plugin instance. Mirrors `NativePlugin` from loader_native.zig
/// but wraps WASM export trampolines instead of raw dlsym function pointers.
pub const WasmPlugin = struct {
    /// Resolved plugin export trampolines (same shape as native exports).
    exports: types.PluginExports,

    /// Raw .wasm module bytes. Owned by the WasmPlugin; freed on close().
    module_bytes: []const u8,

    /// Allocator used for module_bytes and internal state.
    alloc: Allocator,

    /// Opaque pointer to the WasmInstance (for trampolines to access wasm3 state).
    instance: ?*WasmInstance = null,

    /// Close the WASM plugin, freeing module bytes and runtime resources.
    pub fn close(self: *WasmPlugin) void {
        if (self.instance) |inst| {
            inst.deinit();
            self.alloc.destroy(inst);
        }
        self.alloc.free(self.module_bytes);
        self.* = undefined;
    }
};

// -- WasmInstance (per-plugin wasm3 state) ------------------------------------

/// Internal state for a single loaded WASM plugin module.
/// Contains the wasm3 runtime, module, and resolved function handles.
const WasmInstance = struct {
    runtime: if (has_runtime) m3.IM3Runtime else *anyopaque,
    module: if (has_runtime) m3.IM3Module else *anyopaque,

    // Resolved WASM export function handles
    fn_activate: if (has_runtime) m3.IM3Function else *anyopaque,
    fn_deactivate: if (has_runtime) ?m3.IM3Function else ?*anyopaque = null,
    fn_render: if (has_runtime) ?m3.IM3Function else ?*anyopaque = null,
    fn_on_html_event: if (has_runtime) ?m3.IM3Function else ?*anyopaque = null,
    fn_on_command: if (has_runtime) ?m3.IM3Function else ?*anyopaque = null,
    fn_on_schematic_changed: if (has_runtime) ?m3.IM3Function else ?*anyopaque = null,
    fn_on_selection_changed: if (has_runtime) ?m3.IM3Function else ?*anyopaque = null,
    fn_on_key_event: if (has_runtime) ?m3.IM3Function else ?*anyopaque = null,
    fn_on_hover: if (has_runtime) ?m3.IM3Function else ?*anyopaque = null,
    fn_provide: if (has_runtime) ?m3.IM3Function else ?*anyopaque = null,
    fn_on_message: if (has_runtime) ?m3.IM3Function else ?*anyopaque = null,

    // Pointer to the WASM linear memory (cached for string copy operations)
    fn_alloc: if (has_runtime) ?m3.IM3Function else ?*anyopaque = null,

    // Host function table (stored for trampoline access)
    host: *const types.SchemifyHost,

    // String result buffer (plugin-owned, valid until next call)
    result_buf: [types.MAX_OUT_BUF]u8 = undefined,
    result_len: usize = 0,

    fn deinit(self: *WasmInstance) void {
        if (has_runtime) {
            // m3_FreeRuntime also frees the module loaded into it
            if (self.runtime != null) {
                m3.m3_FreeRuntime(self.runtime);
            }
        }
    }
};

// -- WasmRuntime --------------------------------------------------------------

/// Manages the wasm3 engine and can instantiate multiple WASM modules.
/// One per process. Creates per-plugin runtimes internally.
pub const WasmRuntime = struct {
    alloc: Allocator,
    env: if (has_runtime) m3.IM3Environment else ?*anyopaque,
    host: *const types.SchemifyHost,

    /// Stack size for WASM plugin runtimes (64KB).
    const STACK_SIZE: u32 = 64 * 1024;

    /// Initialize the WASM runtime engine.
    pub fn init(alloc: Allocator, host: *const types.SchemifyHost) LoadError!WasmRuntime {
        if (!has_runtime) return LoadError.WasmNotAvailable;

        const env = m3.m3_NewEnvironment() orelse return LoadError.OutOfMemory;

        return .{
            .alloc = alloc,
            .env = env,
            .host = host,
        };
    }

    /// Shut down the WASM runtime, freeing the environment.
    pub fn deinit(self: *WasmRuntime) void {
        if (has_runtime) {
            if (self.env != null) m3.m3_FreeEnvironment(self.env);
        }
    }

    /// Parse, validate, and instantiate a WASM module from raw bytes.
    pub fn loadModule(self: *WasmRuntime, wasm_bytes: []const u8, host: *const types.SchemifyHost) LoadError!WasmPlugin {
        if (!has_runtime) return LoadError.WasmNotAvailable;

        // Step 1: Validate imports (security gate)
        if (!validateImports(wasm_bytes)) return LoadError.UntrustedImports;

        // Step 2: Create a per-plugin wasm3 runtime
        const runtime = m3.m3_NewRuntime(self.env, STACK_SIZE, null) orelse
            return LoadError.OutOfMemory;
        errdefer m3.m3_FreeRuntime(runtime);

        // Step 3: Parse the module
        var module: m3.IM3Module = undefined;
        const parse_result = m3.m3_ParseModule(
            self.env,
            &module,
            wasm_bytes.ptr,
            @intCast(wasm_bytes.len),
        );
        if (!wasm3_mod.isOk(parse_result)) return LoadError.InvalidModule;

        // Step 4: Load module into runtime (transfers ownership)
        const load_result = m3.m3_LoadModule(runtime, module);
        if (!wasm3_mod.isOk(load_result)) {
            m3.m3_FreeModule(module);
            return LoadError.InvalidModule;
        }

        // Step 5: Link host functions
        linkHostFunctions(module) catch return LoadError.LinkError;

        // Step 6: Find schemify_activate export (required)
        var fn_activate: m3.IM3Function = undefined;
        const find_result = m3.m3_FindFunction(&fn_activate, runtime, "schemify_activate");
        if (!wasm3_mod.isOk(find_result)) return LoadError.MissingActivate;

        // Step 7: Find optional exports
        const instance = self.alloc.create(WasmInstance) catch return LoadError.OutOfMemory;
        instance.* = .{
            .runtime = runtime,
            .module = module,
            .fn_activate = fn_activate,
            .fn_deactivate = findOptionalFn(runtime, "schemify_deactivate"),
            .fn_render = findOptionalFn(runtime, "schemify_render"),
            .fn_on_html_event = findOptionalFn(runtime, "schemify_on_html_event"),
            .fn_on_command = findOptionalFn(runtime, "schemify_on_command"),
            .fn_on_schematic_changed = findOptionalFn(runtime, "schemify_on_schematic_changed"),
            .fn_on_selection_changed = findOptionalFn(runtime, "schemify_on_selection_changed"),
            .fn_on_key_event = findOptionalFn(runtime, "schemify_on_key_event"),
            .fn_on_hover = findOptionalFn(runtime, "schemify_on_hover"),
            .fn_provide = findOptionalFn(runtime, "schemify_provide"),
            .fn_on_message = findOptionalFn(runtime, "schemify_on_message"),
            .fn_alloc = findOptionalFn(runtime, "schemify_alloc"),
            .host = host,
        };

        // Step 8: Duplicate wasm_bytes (module requires persistent bytes)
        const bytes_copy = self.alloc.dupe(u8, wasm_bytes) catch {
            self.alloc.destroy(instance);
            return LoadError.OutOfMemory;
        };

        // Step 9: Build trampoline PluginExports
        return .{
            .module_bytes = bytes_copy,
            .alloc = self.alloc,
            .instance = instance,
            .exports = buildTrampolineExports(instance),
        };
    }
};

// -- Helper: find optional WASM export function --------------------------------

fn findOptionalFn(runtime: anytype, name: [*:0]const u8) if (has_runtime) ?m3.IM3Function else ?*anyopaque {
    if (!has_runtime) return null;
    var func: m3.IM3Function = undefined;
    const result = m3.m3_FindFunction(&func, runtime, name);
    if (wasm3_mod.isOk(result)) return func;
    return null;
}

// -- Host function linking ----------------------------------------------------

/// Link all schemify_host_* functions into the WASM module.
/// These are the functions that the WASM plugin imports from "env".
fn linkHostFunctions(module: anytype) !void {
    if (!has_runtime) return;

    // Each host function takes/returns i32 pointers into WASM linear memory.
    // Signature notation: "v(i)" = void(i32), "i(i)" = i32(i32), etc.
    const RawFn = *const fn (m3.IM3Runtime, m3.IM3ImportContext, [*c]u64, ?*anyopaque) callconv(.c) ?*const anyopaque;
    const links = [_]struct { name: [*:0]const u8, sig: [*:0]const u8, func: RawFn }{
        .{ .name = "schemify_host_log", .sig = "v(ii)", .func = &hostLog },
        .{ .name = "schemify_host_set_status", .sig = "v(i)", .func = &hostSetStatus },
        .{ .name = "schemify_host_push_command", .sig = "i(i)", .func = &hostPushCommand },
        .{ .name = "schemify_host_request_refresh", .sig = "v()", .func = &hostRequestRefresh },
        .{ .name = "schemify_host_read_file", .sig = "i(i)", .func = &hostReadFile },
        .{ .name = "schemify_host_write_file", .sig = "i(ii)", .func = &hostWriteFile },
        .{ .name = "schemify_host_project_dir", .sig = "i()", .func = &hostProjectDir },
        .{ .name = "schemify_host_plugin_data_dir", .sig = "i()", .func = &hostPluginDataDir },
        .{ .name = "schemify_host_register_panel", .sig = "v(i)", .func = &hostRegisterPanel },
        .{ .name = "schemify_host_unregister_panel", .sig = "v(i)", .func = &hostUnregisterPanel },
        .{ .name = "schemify_host_register_command", .sig = "v(i)", .func = &hostRegisterCommand },
        .{ .name = "schemify_host_register_keybind", .sig = "v(i)", .func = &hostRegisterKeybind },
        .{ .name = "schemify_host_register_provider", .sig = "v(i)", .func = &hostRegisterProvider },
        .{ .name = "schemify_host_publish", .sig = "v(ii)", .func = &hostPublish },
    };

    for (&links) |link| {
        // Use LinkRawFunctionEx to skip missing imports (plugin may not import all)
        const result = m3.m3_LinkRawFunctionEx(module, "env", link.name, link.sig, link.func, null);
        // m3Err_functionLookupFailed is OK — means plugin doesn't import this function
        if (result != null and result != m3.m3Err_functionLookupFailed) {
            return error.LinkError;
        }
    }
}

// -- Host function trampolines (WASM -> Host) ---------------------------------
//
// These functions are called by wasm3 when the WASM plugin calls an imported
// schemify_host_* function. They read arguments from the WASM stack, convert
// pointers from WASM linear memory offsets to host pointers, call the real
// host function, and write results back.

fn getWasmStr(runtime: m3.IM3Runtime, offset: u32) ?[*:0]const u8 {
    if (offset == 0) return null;
    var mem_size: u32 = 0;
    const mem = m3.m3_GetMemory(runtime, &mem_size, 0) orelse return null;
    if (offset >= mem_size) return null;
    // The string in WASM memory is null-terminated
    return @ptrCast(mem + offset);
}

// TODO: These host function implementations need access to the SchemifyHost
// function table. In wasm3, the _ctx->userdata can carry this pointer.
// For now, we use a thread-local to store the active host pointer.
threadlocal var active_host: ?*const types.SchemifyHost = null;

fn hostLog(runtime: m3.IM3Runtime, _ctx: m3.IM3ImportContext, _sp: [*c]u64, _mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = _ctx;
    _ = _mem;
    const host = active_host orelse return null;
    const log_fn = host.log orelse return null;
    const level_offset: u32 = @truncate(_sp[0]);
    const msg_offset: u32 = @truncate(_sp[1]);
    const level_str = getWasmStr(runtime, level_offset);
    const msg_str = getWasmStr(runtime, msg_offset);
    log_fn(level_str, msg_str);
    return null; // m3Err_none
}

fn hostSetStatus(runtime: m3.IM3Runtime, _ctx: m3.IM3ImportContext, _sp: [*c]u64, _mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = _ctx;
    _ = _mem;
    const host = active_host orelse return null;
    const func = host.set_status orelse return null;
    const offset: u32 = @truncate(_sp[0]);
    func(getWasmStr(runtime, offset));
    return null;
}

fn hostPushCommand(runtime: m3.IM3Runtime, _ctx: m3.IM3ImportContext, _sp: [*c]u64, _mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = _ctx;
    _ = _mem;
    const host = active_host orelse return null;
    const func = host.push_command orelse return null;
    const sp: [*]u64 = @ptrCast(_sp);
    const offset: u32 = @truncate(sp[1]); // args start after return slot
    const result = func(getWasmStr(runtime, offset));
    const ret_ptr: *u32 = @ptrCast(@alignCast(sp));
    ret_ptr.* = if (result != 0) @as(u32, 1) else @as(u32, 0);
    return null;
}

fn hostRequestRefresh(_runtime: m3.IM3Runtime, _ctx: m3.IM3ImportContext, _sp: [*c]u64, _mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = _runtime;
    _ = _ctx;
    _ = _sp;
    _ = _mem;
    const host = active_host orelse return null;
    const func = host.request_refresh orelse return null;
    func();
    return null;
}

fn hostReadFile(runtime: m3.IM3Runtime, _ctx: m3.IM3ImportContext, _sp: [*c]u64, _mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = _ctx;
    _ = _mem;
    const host = active_host orelse return null;
    const func = host.read_file orelse return null;
    const path_offset: u32 = @truncate(_sp[1]);
    const result = func(getWasmStr(runtime, path_offset));
    const ret_ptr: *u32 = @ptrCast(@alignCast(_sp));
    if (result) |str_ptr| {
        const inst = active_instance orelse {
            ret_ptr.* = 0;
            return null;
        };
        const str = std.mem.span(str_ptr);
        ret_ptr.* = writeStringToWasm(inst, str) orelse 0;
    } else {
        ret_ptr.* = 0;
    }
    return null;
}

fn hostWriteFile(runtime: m3.IM3Runtime, _ctx: m3.IM3ImportContext, _sp: [*c]u64, _mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = _ctx;
    _ = _mem;
    const host = active_host orelse return null;
    const func = host.write_file orelse return null;
    const sp: [*]u64 = @ptrCast(_sp);
    const path_offset: u32 = @truncate(sp[1]);
    const content_offset: u32 = @truncate(sp[2]);
    const result = func(getWasmStr(runtime, path_offset), getWasmStr(runtime, content_offset));
    const ret_ptr: *u32 = @ptrCast(@alignCast(sp));
    ret_ptr.* = if (result != 0) @as(u32, 1) else @as(u32, 0);
    return null;
}

fn hostProjectDir(_runtime: m3.IM3Runtime, _ctx: m3.IM3ImportContext, _sp: [*c]u64, _mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = _runtime;
    _ = _ctx;
    _ = _mem;
    const host = active_host orelse return null;
    const func = host.project_dir orelse return null;
    const result = func();
    const ret_ptr: *u32 = @ptrCast(@alignCast(_sp));
    if (result) |str_ptr| {
        const inst = active_instance orelse {
            ret_ptr.* = 0;
            return null;
        };
        const str = std.mem.span(str_ptr);
        ret_ptr.* = writeStringToWasm(inst, str) orelse 0;
    } else {
        ret_ptr.* = 0;
    }
    return null;
}

fn hostPluginDataDir(_runtime: m3.IM3Runtime, _ctx: m3.IM3ImportContext, _sp: [*c]u64, _mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = _runtime;
    _ = _ctx;
    _ = _mem;
    const host = active_host orelse return null;
    const func = host.plugin_data_dir orelse return null;
    const result = func();
    const ret_ptr: *u32 = @ptrCast(@alignCast(_sp));
    if (result) |str_ptr| {
        const inst = active_instance orelse {
            ret_ptr.* = 0;
            return null;
        };
        const str = std.mem.span(str_ptr);
        ret_ptr.* = writeStringToWasm(inst, str) orelse 0;
    } else {
        ret_ptr.* = 0;
    }
    return null;
}

fn hostRegisterPanel(runtime: m3.IM3Runtime, _ctx: m3.IM3ImportContext, _sp: [*c]u64, _mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = _ctx;
    _ = _mem;
    const host = active_host orelse return null;
    const func = host.register_panel orelse return null;
    const offset: u32 = @truncate(_sp[0]);
    func(getWasmStr(runtime, offset));
    return null;
}

fn hostUnregisterPanel(runtime: m3.IM3Runtime, _ctx: m3.IM3ImportContext, _sp: [*c]u64, _mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = _ctx;
    _ = _mem;
    const host = active_host orelse return null;
    const func = host.unregister_panel orelse return null;
    const offset: u32 = @truncate(_sp[0]);
    func(getWasmStr(runtime, offset));
    return null;
}

fn hostRegisterCommand(runtime: m3.IM3Runtime, _ctx: m3.IM3ImportContext, _sp: [*c]u64, _mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = _ctx;
    _ = _mem;
    const host = active_host orelse return null;
    const func = host.register_command orelse return null;
    const offset: u32 = @truncate(_sp[0]);
    func(getWasmStr(runtime, offset));
    return null;
}

fn hostRegisterKeybind(runtime: m3.IM3Runtime, _ctx: m3.IM3ImportContext, _sp: [*c]u64, _mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = _ctx;
    _ = _mem;
    const host = active_host orelse return null;
    const func = host.register_keybind orelse return null;
    const offset: u32 = @truncate(_sp[0]);
    func(getWasmStr(runtime, offset));
    return null;
}

fn hostRegisterProvider(runtime: m3.IM3Runtime, _ctx: m3.IM3ImportContext, _sp: [*c]u64, _mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = _ctx;
    _ = _mem;
    const host = active_host orelse return null;
    const func = host.register_provider orelse return null;
    const offset: u32 = @truncate(_sp[0]);
    func(getWasmStr(runtime, offset));
    return null;
}

fn hostPublish(runtime: m3.IM3Runtime, _ctx: m3.IM3ImportContext, _sp: [*c]u64, _mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = _ctx;
    _ = _mem;
    const host = active_host orelse return null;
    const func = host.publish orelse return null;
    const topic_offset: u32 = @truncate(_sp[0]);
    const payload_offset: u32 = @truncate(_sp[1]);
    func(getWasmStr(runtime, topic_offset), getWasmStr(runtime, payload_offset));
    return null;
}

// -- Trampoline exports (Host -> WASM) ----------------------------------------
//
// These wrapper functions are stored in PluginExports and called by the plugin
// system. They set up the active_host, copy arguments into WASM memory, call
// the WASM export, and extract results.

fn buildTrampolineExports(instance: *WasmInstance) types.PluginExports {
    // Store the instance pointer in a global for trampolines to access.
    // This is safe because plugin calls are single-threaded per the scheduler design.
    active_instance = instance;

    return .{
        .activate = &trampolineActivate,
        .deactivate = if (instance.fn_deactivate != null) &trampolineDeactivate else null,
        .render = if (instance.fn_render != null) &trampolineRender else null,
        .on_html_event = if (instance.fn_on_html_event != null) &trampolineOnHtmlEvent else null,
        .on_command = if (instance.fn_on_command != null) &trampolineOnCommand else null,
        .on_schematic_changed = if (instance.fn_on_schematic_changed != null) &trampolineOnSchematicChanged else null,
        .on_selection_changed = if (instance.fn_on_selection_changed != null) &trampolineOnSelectionChanged else null,
        .on_key_event = if (instance.fn_on_key_event != null) &trampolineOnKeyEvent else null,
        .on_hover = if (instance.fn_on_hover != null) &trampolineOnHover else null,
        .provide = if (instance.fn_provide != null) &trampolineProvide else null,
        .on_message = if (instance.fn_on_message != null) &trampolineOnMessage else null,
    };
}

// Thread-local active instance for trampoline access
threadlocal var active_instance: ?*WasmInstance = null;

fn trampolineActivate(host_ptr: *const types.SchemifyHost) callconv(.c) void {
    if (!has_runtime) return;
    const inst = active_instance orelse return;
    active_host = host_ptr;

    // In WASM, schemify_activate uses imported host functions directly.
    // We call it with 0 args (the host pointer is implicit).
    _ = m3.m3_Call(inst.fn_activate, 0, null);
}

fn trampolineDeactivate() callconv(.c) void {
    if (!has_runtime) return;
    const inst = active_instance orelse return;
    const func = inst.fn_deactivate orelse return;
    _ = m3.m3_Call(func, 0, null);
}

fn trampolineRender(panel_id: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    if (!has_runtime) return null;
    const inst = active_instance orelse return null;
    const func = inst.fn_render orelse return null;

    // Write panel_id string into WASM memory, get offset
    const offset = writeStringToWasm(inst, std.mem.span(panel_id)) orelse return null;
    var args = [_]?*const anyopaque{@ptrCast(&offset)};
    const result = m3.m3_Call(func, 1, @ptrCast(&args));
    if (!wasm3_mod.isOk(result)) return null;

    // Read return value (offset into WASM memory)
    return readStringFromWasm(inst, func);
}

fn trampolineOnHtmlEvent(panel_id: [*:0]const u8, event_json: [*:0]const u8) callconv(.c) void {
    if (!has_runtime) return;
    const inst = active_instance orelse return;
    const func = inst.fn_on_html_event orelse return;

    const off1 = writeStringToWasm(inst, std.mem.span(panel_id)) orelse return;
    const off2 = writeStringToWasm(inst, std.mem.span(event_json)) orelse return;
    var args = [_]?*const anyopaque{ @ptrCast(&off1), @ptrCast(&off2) };
    _ = m3.m3_Call(func, 2, @ptrCast(&args));
}

fn trampolineOnCommand(name: [*:0]const u8, args_json: [*:0]const u8) callconv(.c) void {
    if (!has_runtime) return;
    const inst = active_instance orelse return;
    const func = inst.fn_on_command orelse return;

    const off1 = writeStringToWasm(inst, std.mem.span(name)) orelse return;
    const off2 = writeStringToWasm(inst, std.mem.span(args_json)) orelse return;
    var args = [_]?*const anyopaque{ @ptrCast(&off1), @ptrCast(&off2) };
    _ = m3.m3_Call(func, 2, @ptrCast(&args));
}

fn trampolineOnSchematicChanged() callconv(.c) void {
    if (!has_runtime) return;
    const inst = active_instance orelse return;
    const func = inst.fn_on_schematic_changed orelse return;
    _ = m3.m3_Call(func, 0, null);
}

fn trampolineOnSelectionChanged(json: [*:0]const u8) callconv(.c) void {
    if (!has_runtime) return;
    const inst = active_instance orelse return;
    const func = inst.fn_on_selection_changed orelse return;

    const off = writeStringToWasm(inst, std.mem.span(json)) orelse return;
    var args = [_]?*const anyopaque{@ptrCast(&off)};
    _ = m3.m3_Call(func, 1, @ptrCast(&args));
}

fn trampolineOnKeyEvent(json: [*:0]const u8) callconv(.c) void {
    if (!has_runtime) return;
    const inst = active_instance orelse return;
    const func = inst.fn_on_key_event orelse return;

    const off = writeStringToWasm(inst, std.mem.span(json)) orelse return;
    var args = [_]?*const anyopaque{@ptrCast(&off)};
    _ = m3.m3_Call(func, 1, @ptrCast(&args));
}

fn trampolineOnHover(json: [*:0]const u8) callconv(.c) void {
    if (!has_runtime) return;
    const inst = active_instance orelse return;
    const func = inst.fn_on_hover orelse return;

    const off = writeStringToWasm(inst, std.mem.span(json)) orelse return;
    var args = [_]?*const anyopaque{@ptrCast(&off)};
    _ = m3.m3_Call(func, 1, @ptrCast(&args));
}

fn trampolineProvide(type_str: [*:0]const u8, ctx_json: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    if (!has_runtime) return null;
    const inst = active_instance orelse return null;
    const func = inst.fn_provide orelse return null;

    const off1 = writeStringToWasm(inst, std.mem.span(type_str)) orelse return null;
    const off2 = writeStringToWasm(inst, std.mem.span(ctx_json)) orelse return null;
    var args = [_]?*const anyopaque{ @ptrCast(&off1), @ptrCast(&off2) };
    const result = m3.m3_Call(func, 2, @ptrCast(&args));
    if (!wasm3_mod.isOk(result)) return null;

    return readStringFromWasm(inst, func);
}

fn trampolineOnMessage(sender: [*:0]const u8, topic: [*:0]const u8, payload: [*:0]const u8) callconv(.c) void {
    if (!has_runtime) return;
    const inst = active_instance orelse return;
    const func = inst.fn_on_message orelse return;

    const off1 = writeStringToWasm(inst, std.mem.span(sender)) orelse return;
    const off2 = writeStringToWasm(inst, std.mem.span(topic)) orelse return;
    const off3 = writeStringToWasm(inst, std.mem.span(payload)) orelse return;
    var args = [_]?*const anyopaque{ @ptrCast(&off1), @ptrCast(&off2), @ptrCast(&off3) };
    _ = m3.m3_Call(func, 3, @ptrCast(&args));
}

// -- WASM memory helpers ------------------------------------------------------

/// Write a null-terminated string into WASM linear memory.
/// Calls the plugin's `schemify_alloc` export to allocate space.
/// Returns the WASM memory offset, or null on failure.
fn writeStringToWasm(inst: *WasmInstance, str: []const u8) ?u32 {
    if (!has_runtime) return null;

    const alloc_fn = inst.fn_alloc orelse {
        // Fallback: write to a fixed scratch area at the start of memory.
        // This is a simplified approach — real plugins should export schemify_alloc.
        var mem_size: u32 = 0;
        const mem = m3.m3_GetMemory(inst.runtime, &mem_size, 0) orelse return null;
        // Use a high offset that's less likely to conflict (after 60KB of stack)
        const scratch_base: u32 = 60 * 1024;
        if (scratch_base + str.len + 1 > mem_size) return null;
        const dest = mem[scratch_base .. scratch_base + str.len + 1];
        @memcpy(dest[0..str.len], str);
        dest[str.len] = 0;
        return scratch_base;
    };

    // Call schemify_alloc(size) -> offset
    var size: u32 = @intCast(str.len + 1);
    var args = [_]?*const anyopaque{@ptrCast(&size)};
    const result = m3.m3_Call(alloc_fn, 1, @ptrCast(&args));
    if (!wasm3_mod.isOk(result)) return null;

    // Get the returned offset
    var ret_offset: u32 = 0;
    var rets = [_]?*const anyopaque{@ptrCast(&ret_offset)};
    const get_result = m3.m3_GetResults(alloc_fn, 1, @ptrCast(&rets));
    if (!wasm3_mod.isOk(get_result)) return null;

    if (ret_offset == 0) return null;

    // Copy string data into WASM memory at the allocated offset
    var mem_size: u32 = 0;
    const mem = m3.m3_GetMemory(inst.runtime, &mem_size, 0) orelse return null;
    if (ret_offset + str.len + 1 > mem_size) return null;
    const dest = mem[ret_offset .. ret_offset + str.len + 1];
    @memcpy(dest[0..str.len], str);
    dest[str.len] = 0;

    return ret_offset;
}

/// Read a string result from a WASM function's return value.
/// The function should return an i32 offset into WASM linear memory.
/// Copies the string into inst.result_buf and returns a pointer to it.
fn readStringFromWasm(inst: *WasmInstance, func: m3.IM3Function) ?[*:0]const u8 {
    if (!has_runtime) return null;

    // Get the return value (offset into WASM memory)
    var ret_offset: u32 = 0;
    var rets = [_]?*const anyopaque{@ptrCast(&ret_offset)};
    const result = m3.m3_GetResults(func, 1, @ptrCast(&rets));
    if (!wasm3_mod.isOk(result)) return null;

    if (ret_offset == 0) return null;

    // Read the string from WASM memory
    var mem_size: u32 = 0;
    const mem = m3.m3_GetMemory(inst.runtime, &mem_size, 0) orelse return null;
    if (ret_offset >= mem_size) return null;

    // Find the null terminator
    var end = ret_offset;
    while (end < mem_size and mem[end] != 0) : (end += 1) {}
    const len = end - ret_offset;

    if (len >= inst.result_buf.len) return null;

    // Copy into result buffer
    @memcpy(inst.result_buf[0..len], mem[ret_offset..end]);
    inst.result_buf[len] = 0;
    inst.result_len = len;

    return @ptrCast(&inst.result_buf);
}

// -- Public load function -----------------------------------------------------

/// Load a WASM plugin from a .wasm file path.
///
/// This is the high-level entry point. Reads the file, validates imports,
/// and instantiates via a temporary WasmRuntime.
pub fn load(alloc: Allocator, path: []const u8, host: *const types.SchemifyHost) LoadError!WasmPlugin {
    if (!has_runtime) return LoadError.WasmNotAvailable;

    // Read the .wasm file
    const file = std.fs.cwd().openFile(path, .{}) catch return LoadError.FileNotFound;
    defer file.close();
    const wasm_bytes = file.readToEndAlloc(alloc, 16 * 1024 * 1024) catch return LoadError.OutOfMemory;
    errdefer alloc.free(wasm_bytes);

    // Validate imports (security check)
    if (!validateImports(wasm_bytes)) {
        alloc.free(wasm_bytes);
        return LoadError.UntrustedImports;
    }

    // Create a runtime and load the module
    var runtime = WasmRuntime.init(alloc, host) catch return LoadError.WasmNotAvailable;
    errdefer runtime.deinit();

    const plugin = runtime.loadModule(wasm_bytes, host) catch |e| {
        alloc.free(wasm_bytes);
        return e;
    };

    // The plugin now owns wasm_bytes (via loadModule's dupe), so free our copy
    alloc.free(wasm_bytes);

    return plugin;
}


// -- Tests --------------------------------------------------------------------

test "validateImports: valid minimal WASM with no imports" {
    // Minimal valid WASM module: magic + version + no sections
    const minimal = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expect(validateImports(&minimal));
}

test "validateImports: rejects invalid magic" {
    const bad_magic = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expect(!validateImports(&bad_magic));
}

test "validateImports: rejects too-short binary" {
    const short = [_]u8{ 0x00, 0x61, 0x73 };
    try std.testing.expect(!validateImports(&short));
}

test "validateImports: accepts valid schemify_host import" {
    // Construct a WASM binary with one valid import:
    //   import "env" "schemify_host_log" (func (type 0))
    const wasm = comptime blk: {
        var buf: [128]u8 = undefined;
        var pos: usize = 0;

        // Magic + version
        const header = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
        @memcpy(buf[pos..][0..header.len], &header);
        pos += header.len;

        // Type section (section ID 1): one func type () -> ()
        buf[pos] = 0x01; // section ID
        pos += 1;
        buf[pos] = 0x04; // section size
        pos += 1;
        buf[pos] = 0x01; // 1 type
        pos += 1;
        buf[pos] = 0x60; // func type
        pos += 1;
        buf[pos] = 0x00; // 0 params
        pos += 1;
        buf[pos] = 0x00; // 0 results
        pos += 1;

        // Import section (section ID 2)
        const mod_name = "env";
        const field_name = "schemify_host_log";
        const import_payload_size = 1 + // num imports
            1 + mod_name.len + // module name
            1 + field_name.len + // field name
            1 + // import kind (func)
            1; // type index

        buf[pos] = 0x02; // section ID
        pos += 1;
        buf[pos] = @intCast(import_payload_size); // section size
        pos += 1;
        buf[pos] = 0x01; // 1 import
        pos += 1;
        buf[pos] = @intCast(mod_name.len); // module name length
        pos += 1;
        @memcpy(buf[pos..][0..mod_name.len], mod_name);
        pos += mod_name.len;
        buf[pos] = @intCast(field_name.len); // field name length
        pos += 1;
        @memcpy(buf[pos..][0..field_name.len], field_name);
        pos += field_name.len;
        buf[pos] = 0x00; // import kind: function
        pos += 1;
        buf[pos] = 0x00; // type index 0
        pos += 1;

        break :blk buf[0..pos].*;
    };

    try std.testing.expect(validateImports(&wasm));
}

test "validateImports: rejects non-env module import" {
    // Import from "wasi_snapshot_preview1" instead of "env"
    const wasm = comptime blk: {
        var buf: [128]u8 = undefined;
        var pos: usize = 0;

        const header = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
        @memcpy(buf[pos..][0..header.len], &header);
        pos += header.len;

        const mod_name = "wasi_snapshot_preview1";
        const field_name = "fd_write";
        const import_payload_size = 1 + 1 + mod_name.len + 1 + field_name.len + 1 + 1;

        buf[pos] = 0x02;
        pos += 1;
        buf[pos] = @intCast(import_payload_size);
        pos += 1;
        buf[pos] = 0x01;
        pos += 1;
        buf[pos] = @intCast(mod_name.len);
        pos += 1;
        @memcpy(buf[pos..][0..mod_name.len], mod_name);
        pos += mod_name.len;
        buf[pos] = @intCast(field_name.len);
        pos += 1;
        @memcpy(buf[pos..][0..field_name.len], field_name);
        pos += field_name.len;
        buf[pos] = 0x00;
        pos += 1;
        buf[pos] = 0x00;
        pos += 1;

        break :blk buf[0..pos].*;
    };

    try std.testing.expect(!validateImports(&wasm));
}

test "validateImports: rejects env import without schemify_host prefix" {
    // Import "env" "malloc" — not allowed
    const wasm = comptime blk: {
        var buf: [128]u8 = undefined;
        var pos: usize = 0;

        const header = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
        @memcpy(buf[pos..][0..header.len], &header);
        pos += header.len;

        const mod_name = "env";
        const field_name = "malloc";
        const import_payload_size = 1 + 1 + mod_name.len + 1 + field_name.len + 1 + 1;

        buf[pos] = 0x02;
        pos += 1;
        buf[pos] = @intCast(import_payload_size);
        pos += 1;
        buf[pos] = 0x01;
        pos += 1;
        buf[pos] = @intCast(mod_name.len);
        pos += 1;
        @memcpy(buf[pos..][0..mod_name.len], mod_name);
        pos += mod_name.len;
        buf[pos] = @intCast(field_name.len);
        pos += 1;
        @memcpy(buf[pos..][0..field_name.len], field_name);
        pos += field_name.len;
        buf[pos] = 0x00;
        pos += 1;
        buf[pos] = 0x00;
        pos += 1;

        break :blk buf[0..pos].*;
    };

    try std.testing.expect(!validateImports(&wasm));
}

test "validateImports: rejects memory import from env" {
    // Import "env" "memory" (memory) — only function imports allowed
    const wasm = comptime blk: {
        var buf: [128]u8 = undefined;
        var pos: usize = 0;

        const header = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
        @memcpy(buf[pos..][0..header.len], &header);
        pos += header.len;

        const mod_name = "env";
        const field_name = "memory";
        // memory import: kind=2, limits_flags=0, min=1
        const import_payload_size = 1 + 1 + mod_name.len + 1 + field_name.len + 1 + 1 + 1;

        buf[pos] = 0x02;
        pos += 1;
        buf[pos] = @intCast(import_payload_size);
        pos += 1;
        buf[pos] = 0x01;
        pos += 1;
        buf[pos] = @intCast(mod_name.len);
        pos += 1;
        @memcpy(buf[pos..][0..mod_name.len], mod_name);
        pos += mod_name.len;
        buf[pos] = @intCast(field_name.len);
        pos += 1;
        @memcpy(buf[pos..][0..field_name.len], field_name);
        pos += field_name.len;
        buf[pos] = 0x02; // import kind: memory
        pos += 1;
        buf[pos] = 0x00; // limits flags: no max
        pos += 1;
        buf[pos] = 0x01; // min = 1
        pos += 1;

        break :blk buf[0..pos].*;
    };

    try std.testing.expect(!validateImports(&wasm));
}

test "decodeLeb128: basic values" {
    // 0 = 0x00
    const r0 = decodeLeb128(&[_]u8{0x00}).?;
    try std.testing.expectEqual(@as(u32, 0), r0.value);
    try std.testing.expectEqual(@as(usize, 1), r0.len);

    // 127 = 0x7F
    const r127 = decodeLeb128(&[_]u8{0x7F}).?;
    try std.testing.expectEqual(@as(u32, 127), r127.value);

    // 128 = 0x80 0x01
    const r128 = decodeLeb128(&[_]u8{ 0x80, 0x01 }).?;
    try std.testing.expectEqual(@as(u32, 128), r128.value);
    try std.testing.expectEqual(@as(usize, 2), r128.len);

    // 624485 = 0xE5 0x8E 0x26
    const r624485 = decodeLeb128(&[_]u8{ 0xE5, 0x8E, 0x26 }).?;
    try std.testing.expectEqual(@as(u32, 624485), r624485.value);
    try std.testing.expectEqual(@as(usize, 3), r624485.len);
}

test "WasmRuntime: init returns WasmNotAvailable when runtime not compiled in" {
    if (has_runtime) return error.SkipZigTest;
    const host = std.mem.zeroes(types.SchemifyHost);
    const result = WasmRuntime.init(std.testing.allocator, &host);
    try std.testing.expectError(LoadError.WasmNotAvailable, result);
}

test "WasmRuntime: init and deinit succeed when runtime is available" {
    if (!has_runtime) return error.SkipZigTest;
    const host = std.mem.zeroes(types.SchemifyHost);
    var runtime = try WasmRuntime.init(std.testing.allocator, &host);
    runtime.deinit();
}

test "WasmRuntime: loadModule rejects invalid WASM" {
    if (!has_runtime) return error.SkipZigTest;
    const host = std.mem.zeroes(types.SchemifyHost);
    var runtime = try WasmRuntime.init(std.testing.allocator, &host);
    defer runtime.deinit();

    // Empty module (just header, no sections) — wasm3 should reject it or
    // at minimum we should fail at finding schemify_activate
    const minimal = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    const result = runtime.loadModule(&minimal, &host);
    // Should fail with InvalidModule (wasm3 can't parse an empty module)
    // or MissingActivate (if it parses but has no exports)
    try std.testing.expect(result == LoadError.InvalidModule or
        result == LoadError.MissingActivate or
        result == LoadError.LinkError);
}

test "available flag reflects runtime presence" {
    // This test simply documents that the available flag is set correctly
    // based on whether wasm3 was compiled in.
    try std.testing.expect(available == has_runtime);
}
