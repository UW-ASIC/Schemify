const std = @import("std");

const types = @import("types.zig");

pub const Command = types.Command;
pub const Immediate = types.Immediate;
pub const Undoable = types.Undoable;
pub const PrimitiveKind = types.PrimitiveKind;
pub const PlaceDevice = types.PlaceDevice;
pub const AddWire = types.AddWire;
pub const SetInstanceProp = types.SetInstanceProp;
pub const PluginMutation = types.PluginMutation;
pub const RunImport = types.RunImport;
pub const dispatch = @import("Dispatch.zig").dispatch;
pub const handlers = @import("handlers/lib.zig");
pub const parser = @import("parser.zig");

const RingBuffer = @import("utility").RingBuffer;

pub const CommandQueue = struct {
    ring: RingBuffer(Command, 64) = .{},

    pub fn push(self: *CommandQueue, alloc: std.mem.Allocator, cmd: Command) error{Full}!void {
        _ = alloc;
        return self.ring.tryPush(cmd);
    }

    pub fn pop(self: *CommandQueue) ?Command {
        return self.ring.pop();
    }

    pub fn isEmpty(self: *const CommandQueue) bool {
        return self.ring.count == 0;
    }

    pub fn deinit(self: *CommandQueue, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
