//! Growable worker-owned metadata. Resource owners and RM name nodes live in
//! separate stable allocations; only these index entries may move. No entry
//! pointer may survive a call that acquires another slot in the same pool.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
pub const Error = error{ Stale, Busy, Memory, Descriptor, Retained, Exhausted };
pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();
        const initial = 32;
        self_address: usize = 0,
        heap: ?r4os.r4dev.DriverHeapContext = null,
        small: [initial]T = @splat(.{}),
        dynamic: []T = &.{},
        allocation: a.DriverHeapAllocation = .{},
        stamp: a.DriverHeapAllocation = .{},
        pending: a.DriverHeapAllocation = .{},
        pending_stamp: a.DriverHeapAllocation = .{},
        pending_valid: bool = false,

        pub fn items(self: *Self) []T { return if (self.dynamic.len != 0) self.dynamic else &self.small; }
        pub fn view(self: *const Self) []const T { return if (self.dynamic.len != 0) self.dynamic else &self.small; }
        fn stable(self: *const Self) Error!void {
            if (self.self_address != @intFromPtr(self) or self.heap == null or
                !std.meta.eql(self.allocation, self.stamp) or !std.meta.eql(self.pending, self.pending_stamp)) return error.Stale;
            if (self.dynamic.len != 0 and (self.allocation.cpu_address != @intFromPtr(self.dynamic.ptr) or
                self.allocation.byte_length < self.dynamic.len * @sizeOf(T))) return error.Descriptor;
        }
        fn valid(value: a.DriverHeapAllocation, bytes: u64) bool {
            return value.version == 1 and value.size >= @sizeOf(a.DriverHeapAllocation) and value.reserved == 0 and
                value.handle != 0 and value.cpu_address != 0 and value.cpu_address % @alignOf(T) == 0 and
                value.alignment >= @alignOf(T) and value.byte_length >= bytes and
                value.cpu_address <= std.math.maxInt(u64) - value.byte_length;
        }
        fn pendingEmpty(self: *const Self) bool { return self.pending.handle == 0 and self.pending.cpu_address == 0; }
        fn dropPending(self: *Self) Error!void {
            if (self.pendingEmpty()) return;
            if (!self.pending_valid) return error.Descriptor;
            if (self.heap.?.release(self.pending.handle) != a.driver_heap_ok) return error.Retained;
            self.pending = .{}; self.pending_stamp = .{}; self.pending_valid = false;
        }
        pub fn acquire(self: *Self, heap: r4os.r4dev.DriverHeapContext) Error!u32 {
            if (self.self_address == 0) { self.self_address = @intFromPtr(self); self.heap = heap; }
            try self.stable();
            if (!self.pendingEmpty()) return error.Retained;
            const before = self.items();
            for (before, 0..) |*item, i| if (item.allocation.handle == 0 and item.allocation.cpu_address == 0) return @intCast(i);
            const maximum = @as(u64, std.math.maxInt(u32)) + 1;
            const count = @min(@as(u64, before.len) * 2, maximum);
            if (count <= before.len) return error.Exhausted;
            const bytes = std.math.mul(u64, count, @sizeOf(T)) catch return error.Exhausted;
            const rc = self.heap.?.allocate(bytes, @max(8, @alignOf(T)), &self.pending);
            self.pending_stamp = self.pending;
            if (rc != a.driver_heap_ok and self.pendingEmpty()) { self.pending = .{}; self.pending_stamp = .{}; return error.Memory; }
            if (!valid(self.pending, bytes)) return error.Descriptor;
            self.pending_valid = true;
            if (rc != a.driver_heap_ok) { try self.dropPending(); return error.Memory; }
            const ptr: [*]T = @ptrFromInt(self.pending.cpu_address);
            const next = ptr[0..@intCast(count)];
            @memcpy(next[0..before.len], before);
            @memset(next[before.len..], .{});
            const previous = self.allocation;
            self.allocation = self.pending; self.stamp = self.allocation;
            self.dynamic = next;
            // The new array is authoritative before retiring the old one.
            // Failed release retains only its descriptor, never a second owner.
            self.pending = previous; self.pending_stamp = previous;
            self.pending_valid = previous.handle != 0;
            try self.dropPending();
            return @intCast(before.len);
        }
        /// Caller has retired every resource, normally or with reset proof.
        /// Unknown heap descriptors are retained even after device quiescence.
        pub fn closeEmpty(self: *Self) Error!void {
            if (self.self_address == 0) return;
            try self.stable();
            for (self.view()) |*item| if (item.allocation.handle != 0 or item.allocation.cpu_address != 0) return error.Busy;
            try self.dropPending();
            if (self.allocation.handle != 0 and self.heap.?.release(self.allocation.handle) != a.driver_heap_ok) return error.Retained;
            self.* = .{};
        }
    };
}
