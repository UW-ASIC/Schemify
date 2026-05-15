//! Async scheduler for Plugin API v1.
//!
//! Dispatches plugin calls to a worker thread so the main thread never blocks.
//! Communication between main thread and worker uses:
//! - A lock-free ring buffer for write commands (plugin -> host)
//! - Double-buffered arenas for rendered HTML (swap atomically per frame)
//! - An atomic work queue for dispatching events/renders to the worker
//!
//! Phase 1: single worker thread. Can be expanded to a pool later.
//!
//! Thread model:
//!   Main thread:  beginFrame() -> dispatchRender/dispatchEvent -> collectResults()
//!   Worker thread: wait for work -> execute plugin call -> store result -> signal done

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const lib = @import("lib.zig");
const PluginSystem = lib.PluginSystem;
const types = @import("types.zig");
const host_api = @import("host_api.zig");

// -- Configuration ------------------------------------------------------------

/// Maximum number of write commands buffered per frame.
const WRITE_QUEUE_CAPACITY: usize = 256;

/// Maximum number of pending work items in the dispatch queue.
const WORK_QUEUE_CAPACITY: usize = 64;

/// Maximum size for a single data field in a write command or panel update.
const MAX_DATA_SIZE: usize = 64 * 1024;

/// Maximum number of panel updates buffered per frame.
const MAX_PANEL_UPDATES: usize = 64;

// -- Public types -------------------------------------------------------------

/// Results collected from the worker thread at frame boundary.
pub const Results = struct {
    panel_updates: []const PanelUpdate,
    write_commands: []const WriteCommand,
};

/// A single panel HTML update produced by schemify_render.
pub const PanelUpdate = struct {
    panel_id: []const u8,
    html: []const u8,
};

/// A write command issued by a plugin via host API calls.
pub const WriteCommand = struct {
    kind: WriteKind,
    data: []const u8,
    data2: []const u8,
};

pub const WriteKind = enum(u8) {
    log,
    set_status,
    push_command,
    register_panel,
    unregister_panel,
    register_command,
    register_keybind,
    register_provider,
    publish,
};

/// An event to be dispatched to plugins on the worker thread.
pub const Event = union(enum) {
    html_event: HtmlEventData,
    command: CommandData,
    schematic_changed,
    selection_changed: []const u8,
    key_event: []const u8,
    hover: []const u8,
};

pub const HtmlEventData = struct {
    panel_id: []const u8,
    json: []const u8,
};

pub const CommandData = struct {
    plugin_name: []const u8,
    name: []const u8,
    args: []const u8,
};

// -- Internal work item -------------------------------------------------------

const WorkKind = enum(u8) {
    render,
    html_event,
    command,
    schematic_changed,
    selection_changed,
    key_event,
    hover,
    shutdown,
};

const WorkItem = struct {
    kind: WorkKind,
    // Indices into the snapshot arena for string data.
    data1: []const u8 = "",
    data2: []const u8 = "",
    data3: []const u8 = "",
};

// -- Ring buffer (power-of-two, single-producer single-consumer) ---------------
//
// Uses the existing utility RingBuffer for write commands (main thread drains,
// worker thread pushes). For the work queue we use a similar structure but
// the roles are reversed (main pushes, worker drains).

fn SpscRing(comptime T: type, comptime cap: usize) type {
    comptime assert(cap > 0 and (cap & (cap - 1)) == 0);
    const mask = cap - 1;

    return struct {
        buf: [cap]T = undefined,
        // Using atomics: head is read position, tail is write position.
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        const Self = @This();

        /// Try to push an item. Returns false if full.
        pub fn tryPush(self: *Self, item: T) bool {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.acquire);
            if (t -% h >= cap) return false;
            self.buf[t & mask] = item;
            self.tail.store(t +% 1, .release);
            return true;
        }

        /// Try to pop an item. Returns null if empty.
        pub fn tryPop(self: *Self) ?T {
            const h = self.head.load(.monotonic);
            const t = self.tail.load(.acquire);
            if (h == t) return null;
            const item = self.buf[h & mask];
            self.head.store(h +% 1, .release);
            return item;
        }

        /// Number of items available for reading.
        pub fn len(self: *const Self) usize {
            const t = self.tail.load(.acquire);
            const h = self.head.load(.acquire);
            return t -% h;
        }

        /// Reset to empty (not thread-safe, call only when quiesced).
        pub fn reset(self: *Self) void {
            self.head.store(0, .monotonic);
            self.tail.store(0, .monotonic);
        }
    };
}

// -- Scheduler ----------------------------------------------------------------

pub const Scheduler = struct {
    alloc: Allocator,
    plugin_system: *PluginSystem,

    // Work queue: main thread pushes, worker pops.
    work_queue: *SpscRing(WorkItem, WORK_QUEUE_CAPACITY),

    // Write command queue: worker pushes, main thread drains.
    write_queue: *SpscRing(WriteCommand, WRITE_QUEUE_CAPACITY),

    // Double-buffered panel updates.
    // front_buf: what collectResults reads (swapped from back at frame end).
    // back_buf: what the worker writes into.
    panel_bufs: [2]*PanelBuffer,
    active_buf: std.atomic.Value(u8), // index the worker writes to (0 or 1)

    // Snapshot arena for copying event data so worker can read without races.
    snapshot_arena: std.heap.ArenaAllocator,

    // Worker thread handle.
    worker: ?std.Thread,
    running: std.atomic.Value(bool),

    // Collected results (valid between collectResults and next beginFrame).
    last_results: Results,

    // Pre-allocated buffer for drained write commands (avoids dangling pointer).
    write_cmd_buf: [WRITE_QUEUE_CAPACITY]WriteCommand = undefined,
    write_cmd_count: usize = 0,

    // Mutex protecting PluginSystem access from concurrent worker/main threads.
    plugin_mutex: std.Thread.Mutex = .{},

    const PanelBuffer = struct {
        updates: [MAX_PANEL_UPDATES]PanelUpdate = undefined,
        count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        // Arena for storing HTML strings that the worker produces.
        arena: std.heap.ArenaAllocator,

        fn init(alloc: Allocator) PanelBuffer {
            return .{
                .arena = std.heap.ArenaAllocator.init(alloc),
            };
        }

        fn deinit(self: *PanelBuffer) void {
            self.arena.deinit();
        }

        fn reset(self: *PanelBuffer) void {
            _ = self.arena.reset(.retain_capacity);
            self.count.store(0, .monotonic);
        }

        fn push(self: *PanelBuffer, panel_id: []const u8, html: []const u8) void {
            const idx = self.count.load(.monotonic);
            if (idx >= MAX_PANEL_UPDATES) return;
            const a = self.arena.allocator();
            const id_copy = a.dupe(u8, panel_id) catch return;
            const html_copy = a.dupe(u8, html) catch return;
            self.updates[idx] = .{ .panel_id = id_copy, .html = html_copy };
            self.count.store(idx + 1, .release);
        }

        fn slice(self: *const PanelBuffer) []const PanelUpdate {
            const n = self.count.load(.acquire);
            return self.updates[0..n];
        }
    };

    // -- Public API -----------------------------------------------------------

    pub fn init(alloc: Allocator, plugin_system: *PluginSystem) Scheduler {
        const work_q = alloc.create(SpscRing(WorkItem, WORK_QUEUE_CAPACITY)) catch
            @panic("scheduler: failed to allocate work queue");
        work_q.* = .{};

        const write_q = alloc.create(SpscRing(WriteCommand, WRITE_QUEUE_CAPACITY)) catch
            @panic("scheduler: failed to allocate write queue");
        write_q.* = .{};

        const buf0 = alloc.create(PanelBuffer) catch
            @panic("scheduler: failed to allocate panel buffer 0");
        buf0.* = PanelBuffer.init(alloc);

        const buf1 = alloc.create(PanelBuffer) catch
            @panic("scheduler: failed to allocate panel buffer 1");
        buf1.* = PanelBuffer.init(alloc);

        var sched = Scheduler{
            .alloc = alloc,
            .plugin_system = plugin_system,
            .work_queue = work_q,
            .write_queue = write_q,
            .panel_bufs = .{ buf0, buf1 },
            .active_buf = std.atomic.Value(u8).init(0),
            .snapshot_arena = std.heap.ArenaAllocator.init(alloc),
            .worker = null,
            .running = std.atomic.Value(bool).init(false),
            .last_results = .{ .panel_updates = &.{}, .write_commands = &.{} },
        };

        sched.startWorker();
        return sched;
    }

    pub fn deinit(self: *Scheduler) void {
        self.stopWorker();

        self.panel_bufs[0].deinit();
        self.panel_bufs[1].deinit();
        self.alloc.destroy(self.panel_bufs[0]);
        self.alloc.destroy(self.panel_bufs[1]);

        self.alloc.destroy(self.work_queue);
        self.alloc.destroy(self.write_queue);

        self.snapshot_arena.deinit();
    }

    /// Called at the start of each frame on the main thread.
    /// Resets the snapshot arena and prepares for new dispatches.
    pub fn beginFrame(self: *Scheduler) void {
        // Reset snapshot arena — all event data copied last frame is invalidated.
        // This is safe because the worker has finished with them (we swap buffers
        // in collectResults which happens before beginFrame next cycle).
        _ = self.snapshot_arena.reset(.retain_capacity);
    }

    /// Dispatch a render request for a panel. The worker thread will call
    /// schemify_render on each active plugin and buffer the HTML result.
    pub fn dispatchRender(self: *Scheduler, panel_id: []const u8) void {
        const arena_alloc = self.snapshot_arena.allocator();
        const id_copy = arena_alloc.dupe(u8, panel_id) catch return;
        _ = self.work_queue.tryPush(.{
            .kind = .render,
            .data1 = id_copy,
        });
    }

    /// Dispatch an event to be delivered to plugins on the worker thread.
    pub fn dispatchEvent(self: *Scheduler, event: Event) void {
        const arena_alloc = self.snapshot_arena.allocator();
        const work = switch (event) {
            .html_event => |ev| WorkItem{
                .kind = .html_event,
                .data1 = arena_alloc.dupe(u8, ev.panel_id) catch return,
                .data2 = arena_alloc.dupe(u8, ev.json) catch return,
            },
            .command => |cmd| WorkItem{
                .kind = .command,
                .data1 = arena_alloc.dupe(u8, cmd.plugin_name) catch return,
                .data2 = arena_alloc.dupe(u8, cmd.name) catch return,
                .data3 = arena_alloc.dupe(u8, cmd.args) catch return,
            },
            .schematic_changed => WorkItem{
                .kind = .schematic_changed,
            },
            .selection_changed => |json| WorkItem{
                .kind = .selection_changed,
                .data1 = arena_alloc.dupe(u8, json) catch return,
            },
            .key_event => |json| WorkItem{
                .kind = .key_event,
                .data1 = arena_alloc.dupe(u8, json) catch return,
            },
            .hover => |json| WorkItem{
                .kind = .hover,
                .data1 = arena_alloc.dupe(u8, json) catch return,
            },
        };
        _ = self.work_queue.tryPush(work);
    }

    /// Collect results from the worker thread. Called once per frame on the
    /// main thread. Swaps the double buffer and drains the write queue.
    /// The returned Results is valid until the next call to collectResults.
    pub fn collectResults(self: *Scheduler) Results {
        // Swap active panel buffer: worker starts writing to the other one.
        const current = self.active_buf.load(.acquire);
        const next: u8 = current ^ 1;

        // Reset the buffer we are about to hand to the worker.
        self.panel_bufs[next].reset();
        self.active_buf.store(next, .release);

        // Read panel updates from the buffer the worker just finished with.
        const panel_updates = self.panel_bufs[current].slice();

        // Drain write commands into the pre-allocated struct buffer.
        self.write_cmd_count = 0;
        while (self.write_queue.tryPop()) |cmd| {
            if (self.write_cmd_count < WRITE_QUEUE_CAPACITY) {
                self.write_cmd_buf[self.write_cmd_count] = cmd;
                self.write_cmd_count += 1;
            }
        }

        self.last_results = .{
            .panel_updates = panel_updates,
            .write_commands = self.write_cmd_buf[0..self.write_cmd_count],
        };

        return self.last_results;
    }

    /// Push a write command into the queue (called from host_api on the worker).
    /// This is the thread-safe path for plugins to issue host writes.
    pub fn pushWriteCommand(self: *Scheduler, kind: WriteKind, data: []const u8, data2: []const u8) void {
        _ = self.write_queue.tryPush(.{
            .kind = kind,
            .data = data,
            .data2 = data2,
        });
    }

    /// Lock the plugin mutex before mutating PluginSystem state (activate/deactivate).
    /// Must be called from the main thread.
    pub fn lockPlugins(self: *Scheduler) void {
        self.plugin_mutex.lock();
    }

    /// Unlock the plugin mutex after mutating PluginSystem state.
    pub fn unlockPlugins(self: *Scheduler) void {
        self.plugin_mutex.unlock();
    }

    // -- Worker thread ---------------------------------------------------------

    fn startWorker(self: *Scheduler) void {
        self.running.store(true, .release);
        self.worker = std.Thread.spawn(.{}, workerLoop, .{self}) catch {
            // Fallback: run synchronously if thread spawn fails.
            self.worker = null;
            return;
        };
    }

    fn stopWorker(self: *Scheduler) void {
        if (self.worker == null) return;
        self.running.store(false, .release);
        // Push a shutdown sentinel to wake the worker.
        _ = self.work_queue.tryPush(.{ .kind = .shutdown });
        self.worker.?.join();
        self.worker = null;
    }

    fn workerLoop(self: *Scheduler) void {
        while (self.running.load(.acquire)) {
            const maybe_work = self.work_queue.tryPop();
            if (maybe_work) |work| {
                if (work.kind == .shutdown) break;
                self.executeWork(work);
            } else {
                // No work available — yield to avoid busy-spinning.
                std.Thread.yield() catch {};
                // Brief sleep to reduce CPU usage when idle.
                std.Thread.sleep(100_000); // 100us
            }
        }
    }

    fn executeWork(self: *Scheduler, work: WorkItem) void {
        self.plugin_mutex.lock();
        defer self.plugin_mutex.unlock();

        switch (work.kind) {
            .render => self.executeRender(work.data1),
            .html_event => self.plugin_system.sendHtmlEvent(work.data1, work.data2),
            .command => self.plugin_system.sendCommand(work.data1, work.data2, work.data3),
            .schematic_changed => self.plugin_system.sendSchematicChanged(),
            .selection_changed => self.plugin_system.sendSelectionChanged(work.data1),
            .key_event => self.plugin_system.sendKeyEvent(work.data1),
            .hover => self.plugin_system.sendHover(work.data1),
            .shutdown => {},
        }
    }

    fn executeRender(self: *Scheduler, panel_id: []const u8) void {
        // Call renderPanel on the plugin system (Phase 0 synchronous path).
        // Then capture the HTML from the plugin system into our double buffer.
        self.plugin_system.renderPanel(panel_id);
        const html = self.plugin_system.getPanelHtml(panel_id);
        if (html.len > 0) {
            const buf_idx = self.active_buf.load(.acquire);
            self.panel_bufs[buf_idx].push(panel_id, html);
        }
    }
};

// -- Tests --------------------------------------------------------------------

test "SpscRing push and pop" {
    var ring: SpscRing(u32, 4) = .{};

    try std.testing.expect(ring.tryPush(10));
    try std.testing.expect(ring.tryPush(20));
    try std.testing.expect(ring.tryPush(30));
    try std.testing.expect(ring.tryPush(40));
    // Full — should fail.
    try std.testing.expect(!ring.tryPush(50));

    try std.testing.expectEqual(@as(?u32, 10), ring.tryPop());
    try std.testing.expectEqual(@as(?u32, 20), ring.tryPop());
    try std.testing.expectEqual(@as(?u32, 30), ring.tryPop());
    try std.testing.expectEqual(@as(?u32, 40), ring.tryPop());
    // Empty — should return null.
    try std.testing.expectEqual(@as(?u32, null), ring.tryPop());
}

test "SpscRing len tracks correctly" {
    var ring: SpscRing(u8, 8) = .{};
    try std.testing.expectEqual(@as(usize, 0), ring.len());

    _ = ring.tryPush(1);
    _ = ring.tryPush(2);
    try std.testing.expectEqual(@as(usize, 2), ring.len());

    _ = ring.tryPop();
    try std.testing.expectEqual(@as(usize, 1), ring.len());
}

test "SpscRing wraparound" {
    var ring: SpscRing(u16, 4) = .{};

    // Fill and drain multiple times to exercise wraparound.
    for (0..3) |round| {
        const base: u16 = @intCast(round * 4);
        _ = ring.tryPush(base + 0);
        _ = ring.tryPush(base + 1);
        _ = ring.tryPush(base + 2);
        _ = ring.tryPush(base + 3);

        try std.testing.expectEqual(@as(?u16, base + 0), ring.tryPop());
        try std.testing.expectEqual(@as(?u16, base + 1), ring.tryPop());
        try std.testing.expectEqual(@as(?u16, base + 2), ring.tryPop());
        try std.testing.expectEqual(@as(?u16, base + 3), ring.tryPop());
    }
}

test "WriteCommand queue push and drain" {
    const alloc = std.testing.allocator;
    var write_q = try alloc.create(SpscRing(WriteCommand, WRITE_QUEUE_CAPACITY));
    defer alloc.destroy(write_q);
    write_q.* = .{};

    // Push several write commands.
    _ = write_q.tryPush(.{ .kind = .log, .data = "info", .data2 = "hello" });
    _ = write_q.tryPush(.{ .kind = .set_status, .data = "ready", .data2 = "" });
    _ = write_q.tryPush(.{ .kind = .publish, .data = "topic", .data2 = "payload" });

    try std.testing.expectEqual(@as(usize, 3), write_q.len());

    // Drain.
    var count: usize = 0;
    while (write_q.tryPop()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(usize, 0), write_q.len());
}

test "PanelBuffer push and slice" {
    const alloc = std.testing.allocator;
    var buf = Scheduler.PanelBuffer.init(alloc);
    defer buf.deinit();

    buf.push("panel_a", "<h1>Hello</h1>");
    buf.push("panel_b", "<p>World</p>");

    const items = buf.slice();
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("panel_a", items[0].panel_id);
    try std.testing.expectEqualStrings("<h1>Hello</h1>", items[0].html);
    try std.testing.expectEqualStrings("panel_b", items[1].panel_id);
    try std.testing.expectEqualStrings("<p>World</p>", items[1].html);

    // Reset clears.
    buf.reset();
    try std.testing.expectEqual(@as(usize, 0), buf.slice().len);
}

test "PanelBuffer double buffer swap" {
    const alloc = std.testing.allocator;

    var buf0 = Scheduler.PanelBuffer.init(alloc);
    defer buf0.deinit();
    var buf1 = Scheduler.PanelBuffer.init(alloc);
    defer buf1.deinit();

    // Simulate: worker writes to buf0.
    buf0.push("panel_x", "<div>A</div>");

    // Swap: main reads buf0, worker starts writing to buf1.
    const results = buf0.slice();
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("panel_x", results[0].panel_id);

    // buf1 is fresh.
    try std.testing.expectEqual(@as(usize, 0), buf1.slice().len);
    buf1.push("panel_y", "<div>B</div>");
    try std.testing.expectEqual(@as(usize, 1), buf1.slice().len);
}

test "Scheduler init and deinit" {
    // This test verifies that the scheduler can be created and torn down
    // without crashing, including starting and stopping the worker thread.
    const alloc = std.testing.allocator;

    // We need a PluginSystem, but we can use a minimal one with no plugins.
    // Create dummy callbacks.
    const T = struct {
        fn logMsg(_: *anyopaque, _: []const u8, _: []const u8) void {}
        fn setStatus(_: *anyopaque, _: []const u8) void {}
        fn pushCommand(_: *anyopaque, _: []const u8) bool {
            return false;
        }
        fn requestRefresh(_: *anyopaque) void {}
        fn readFile(_: *anyopaque, _: []const u8) ?[]const u8 {
            return null;
        }
        fn writeFile(_: *anyopaque, _: []const u8, _: []const u8) bool {
            return false;
        }
        fn projectDir(_: *anyopaque) []const u8 {
            return "/tmp";
        }
        fn pluginDataDir(_: *anyopaque, _: []const u8) []const u8 {
            return "/tmp/data";
        }
        fn registerPanel(_: *anyopaque, _: []const u8) void {}
        fn unregisterPanel(_: *anyopaque, _: []const u8) void {}
        fn registerCommand(_: *anyopaque, _: []const u8) void {}
        fn registerKeybind(_: *anyopaque, _: []const u8) void {}
        fn registerProvider(_: *anyopaque, _: []const u8) void {}
        fn setConfig(_: *anyopaque, _: []const u8, _: []const u8) void {}
        fn publish(_: *anyopaque, _: []const u8, _: []const u8) void {}
    };

    var dummy: u8 = 0;
    var ps = PluginSystem.init(alloc, .{
        .ctx = @ptrCast(&dummy),
        .log_msg = T.logMsg,
        .set_status = T.setStatus,
        .push_command = T.pushCommand,
        .request_refresh = T.requestRefresh,
        .read_file = T.readFile,
        .write_file = T.writeFile,
        .project_dir = T.projectDir,
        .plugin_data_dir = T.pluginDataDir,
        .register_panel = T.registerPanel,
        .unregister_panel = T.unregisterPanel,
        .register_command = T.registerCommand,
        .register_keybind = T.registerKeybind,
        .register_provider = T.registerProvider,
        .set_config = T.setConfig,
        .publish = T.publish,
    });
    defer ps.deinit();

    var sched = Scheduler.init(alloc, &ps);
    defer sched.deinit();

    // Basic lifecycle: beginFrame + collectResults with no work.
    sched.beginFrame();
    const results = sched.collectResults();
    try std.testing.expectEqual(@as(usize, 0), results.panel_updates.len);
}
