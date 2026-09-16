//! Resident native push list and its acknowledged VA bindings. Serialized
//! driver worker only; public queue/BO execution admission belongs upstream.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const virtual = @import("gsp_virtual_resources.zig");
pub const batch = @import("gsp_push_batch.zig");
const Space = @import("gsp_vaspace.zig").Info;
const Use = virtual.ExecutionUse;
const alignment = @max(@alignOf(Use), @alignOf(batch.Push));

pub const Owner = struct {
    self_address: usize = 0,
    heap: ?r4os.r4dev.DriverHeapContext = null,
    virtuals: ?*virtual.Owner = null,
    space: Space = undefined,
    allocation: a.DriverHeapAllocation = .{},
    stamp: a.DriverHeapAllocation = .{},
    use_count: usize = 0,
    push_count: usize = 0,
    acquired: usize = 0,
    ready: bool = false,
    damaged: bool = false,
    failed: bool = false,

    fn pushOffset(self: *const Owner) !usize {
        const byte_count = try std.math.mul(usize, self.use_count, @sizeOf(Use));
        return (try std.math.add(usize, byte_count, @alignOf(batch.Push) - 1)) & ~@as(usize, @alignOf(batch.Push) - 1);
    }
    fn bytes(self: *const Owner) !usize {
        return @max(1, try std.math.add(usize, try self.pushOffset(), try std.math.mul(usize, self.push_count, @sizeOf(batch.Push))));
    }
    fn storageValid(self: *const Owner) bool {
        const size = self.bytes() catch return false;
        const v = self.allocation;
        return self.self_address == @intFromPtr(self) and self.heap != null and self.virtuals != null and
            std.meta.eql(v, self.stamp) and v.version == 1 and v.size >= @sizeOf(a.DriverHeapAllocation) and
            v.handle != 0 and v.reserved == 0 and v.cpu_address != 0 and v.cpu_address % alignment == 0 and
            v.alignment >= alignment and v.byte_length >= size and v.cpu_address <= std.math.maxInt(u64) - v.byte_length and
            self.acquired <= self.use_count and self.push_count <= batch.capacity;
    }
    fn uses(self: *const Owner) []Use {
        const ptr: [*]Use = @ptrFromInt(self.allocation.cpu_address);
        return ptr[0..self.use_count];
    }
    fn pushes(self: *const Owner) []batch.Push {
        const ptr: [*]batch.Push = @ptrFromInt(self.allocation.cpu_address + (self.pushOffset() catch unreachable));
        return ptr[0..self.push_count];
    }
    pub fn open(self: *Owner, heap: r4os.r4dev.DriverHeapContext, resources: *virtual.Owner,
        space: Space, push_list: []const batch.Push, bindings: []const virtual.BindingHandle) !void
    {
        if (self.self_address != 0) return error.Busy;
        try batch.validate(push_list);
        if (space.epoch == 0) return error.Stale;
        // Invalid handles never allocate metadata or partially borrow a VA.
        for (bindings) |handle| {
            const view = try resources.executionView(handle);
            if (!std.meta.eql(view.mapping.allocation.space, space)) return error.Stale;
        }
        self.* = .{ .self_address = @intFromPtr(self), .heap = heap, .virtuals = resources,
            .space = space, .use_count = bindings.len, .push_count = push_list.len };
        const size = self.bytes() catch |err| { self.* = .{}; return err; };
        const result = heap.allocate(size, alignment, &self.allocation);
        self.stamp = self.allocation;
        if (result != a.driver_heap_ok and self.allocation.handle == 0 and self.allocation.cpu_address == 0) {
            self.* = .{}; return error.Memory;
        }
        if (!self.storageValid()) { self.damaged = true; return error.Retained; }
        self.populate(push_list, bindings, result) catch |err| {
            if (!self.close(true)) return error.Retained;
            return err;
        };
    }
    fn populate(self: *Owner, push_list: []const batch.Push, bindings: []const virtual.BindingHandle, result: i32) !void {
        if (result != a.driver_heap_ok) return error.Memory;
        for (bindings, 0..) |handle, i| {
            self.uses()[i] = try self.virtuals.?.acquireExecution(handle);
            self.acquired += 1;
        }
        @memcpy(self.pushes(), push_list);
        self.ready = true;
        try self.validate();
    }
    pub fn validate(self: *const Owner) !void {
        if (!self.storageValid() or self.damaged or self.failed or !self.ready or self.acquired != self.use_count) return error.Retained;
        for (self.uses()) |use| {
            try self.virtuals.?.validateExecution(use);
            if (!std.meta.eql(use.mapping.allocation.space, self.space)) return error.Stale;
        }
        try batch.validate(self.pushes());
        // A push may span adjacent RM mappings. Gaps, stale maps, another VA
        // space and blocklinear instruction backing are never executable.
        for (self.pushes()) |push| {
            var cursor = push.address;
            const end = push.address + push.bytes;
            while (cursor < end) {
                var covered = cursor;
                for (self.uses()) |use| {
                    const map = use.mapping;
                    if (map.virtual_kind) continue;
                    const base = map.address + map.virtual_offset;
                    if (base <= cursor and cursor - base < map.bytes) covered = @max(covered, base + map.bytes);
                }
                if (covered == cursor) return error.Bounds;
                cursor = @min(covered, end);
            }
        }
    }
    pub fn commands(self: *const Owner) ![]const batch.Push {
        try self.validate();
        return self.pushes();
    }
    pub fn close(self: *Owner, quiesced: bool) bool {
        if (self.self_address == 0) return true;
        if (!quiesced or self.failed) return false;
        return self.releaseStorage();
    }
    fn releaseStorage(self: *Owner) bool {
        if (!self.storageValid() or self.damaged) return false;
        while (self.acquired != 0) {
            self.virtuals.?.releaseExecution(self.uses()[self.acquired - 1]) catch return false;
            self.acquired -= 1;
        }
        if (self.heap.?.release(self.allocation.handle) != a.driver_heap_ok) return false;
        self.* = .{};
        return true;
    }
    pub fn closeAfterReset(self: *Owner, proof: @import("gsp_reset.zig").Quiescence) bool {
        if (self.self_address == 0) return true;
        if (!proof.valid(self.space.epoch)) return false;
        return self.releaseStorage();
    }
};
