//! Resident common-BO storage for host-owned GPU page tables. The VM owner
//! publishes/invalidates entries; this backend retains every allocation,
//! including partially prepared nodes and failures after index detachment.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const vm = @import("gsp_host_vm.zig");
const storage = @import("gsp_control_storage.zig");
const reset = @import("gsp_reset.zig");
const ok = a.gfx_buffer_result_ok;
pub const Node = struct {
    table: vm.Table = .{},
    allocation: a.DriverHeapAllocation,
    allocation_stamp: a.DriverHeapAllocation,
    previous: ?*Node = null,
    next: ?*Node = null,
    backing: storage.Storage = .{},
    cpu: a.GfxBufferMap = .{},
    cpu_stamp: a.GfxBufferMap = .{},
    prepared: bool = false,
    awaiting_collection: bool = false,
};
pub const Owner = struct {
    self_address: usize = 0,
    ctx: ?r4os.r4dev.DriverContext = null,
    heap: ?r4os.r4dev.DriverHeapContext = null,
    adapter: u32 = 0,
    epoch: u64 = 0,
    first: ?*Node = null,
    pending: a.DriverHeapAllocation = .{},
    pending_stamp: a.DriverHeapAllocation = .{},
    failure: ?vm.Error = null,
    deferred_pages: usize = 0,
    last_operation: enum { none, cpu_unmap, backing, heap_release } = .none,
    last_status: i32 = ok,
    last_backing_step: []const u8 = "none",

    pub fn configure(self: *Owner, ctx: *const r4os.r4dev.DriverContext, adapter: u32, epoch: u64) vm.Error!void {
        if (self.self_address != 0 or adapter == 0 or epoch == 0) return error.State;
        const heap = ctx.heap() orelse return error.Memory;
        self.* = .{ .self_address = @intFromPtr(self), .ctx = ctx.*, .heap = heap, .adapter = adapter, .epoch = epoch };
    }
    fn stable(self: *const Owner) vm.Error!void {
        if (self.self_address != @intFromPtr(self) or self.ctx == null or self.heap == null or self.adapter == 0 or self.epoch == 0) return error.Stale;
    }
    fn fail(self: *Owner, err: vm.Error) vm.Error {
        if (self.failure == null) self.failure = err;
        return err;
    }
    fn heapValid(value: a.DriverHeapAllocation) bool {
        return value.version == 1 and value.size >= @sizeOf(a.DriverHeapAllocation) and value.reserved == 0 and
            value.handle != 0 and value.cpu_address != 0 and value.cpu_address % @alignOf(Node) == 0 and
            value.byte_length >= @sizeOf(Node) and value.alignment >= @alignOf(Node) and
            value.cpu_address <= std.math.maxInt(u64) - value.byte_length;
    }
    fn cpuValid(value: a.GfxBufferMap) bool {
        return value.version == 1 and value.size >= @sizeOf(a.GfxBufferMap) and value.lease.id != 0 and
            value.lease.generation != 0 and value.lease.reserved0 == 0 and value.reserved0 == 0 and
            value.cpu_address != 0 and value.cpu_address & 4095 == 0 and value.cpu_address <= std.math.maxInt(u64) - 4096 and
            value.byte_length == 4096 and value.cache_policy == a.gfx_buffer_cache_write_back;
    }
    fn nodeValid(self: *const Owner, node: *const Node) vm.Error!void {
        if (!heapValid(node.allocation) or !std.meta.eql(node.allocation, node.allocation_stamp) or
            node.allocation.cpu_address != @intFromPtr(node) or !std.meta.eql(node.cpu, node.cpu_stamp)) return error.Descriptor;
        if (node.previous) |prev| {
            if (prev.next != node) return error.Descriptor;
        } else if (self.first != node) return error.Descriptor;
        if (node.next) |next| if (next.previous != node) return error.Descriptor;
    }
    fn cast(raw: *anyopaque) *Owner { return @ptrCast(@alignCast(raw)); }
    pub fn backend(self: *Owner) vm.Error!vm.Backend {
        try self.stable();
        return .{ .context = self, .allocate = allocate, .valid = valid, .release = release };
    }
    fn allocate(raw: *anyopaque) vm.Error!*vm.Table {
        const self = cast(raw);
        try self.stable();
        if (self.failure != null or self.pending.handle != 0 or self.pending.cpu_address != 0) return error.Retained;
        const status = self.heap.?.allocate(@sizeOf(Node), @alignOf(Node), &self.pending);
        self.pending_stamp = self.pending;
        if (status != a.driver_heap_ok and self.pending.handle == 0 and self.pending.cpu_address == 0) return error.Memory;
        if (!heapValid(self.pending)) return self.fail(error.Descriptor);
        if (status != a.driver_heap_ok) {
            try self.releasePending();
            return error.Memory;
        }
        const node: *Node = @ptrFromInt(self.pending.cpu_address);
        node.* = .{ .allocation = self.pending, .allocation_stamp = self.pending, .next = self.first };
        self.pending = .{};
        self.pending_stamp = .{};
        if (self.first) |head| head.previous = node;
        self.first = node;
        node.backing.prepare(&self.ctx.?, self.adapter, self.epoch, 4096) catch {
            // Nothing from this new page has been published. Keep the node
            // if common cleanup itself cannot complete.
            _ = self.dispose(node, null, false) catch return self.fail(error.Retained);
            return error.Memory;
        };
        const memory = node.backing.memory.?;
        const result = memory.bufferMap(&node.backing.reference.reference, a.gfx_buffer_map_write, 0, 4096, &node.cpu);
        node.cpu_stamp = node.cpu;
        if (result != ok or !cpuValid(node.cpu)) {
            _ = self.dispose(node, null, false) catch return self.fail(error.Retained);
            return error.Descriptor;
        }
        node.table.dma = node.backing.pages[0];
        node.table.cpu = @ptrFromInt(node.cpu.cpu_address);
        // A separate persistent CPU map is compatible with the held coherent
        // DMA lease; the underlying Storage retains its immutable descriptor.
        node.backing.retained = true;
        node.prepared = true;
        return &node.table;
    }
    fn valid(raw: *anyopaque, table: *const vm.Table) bool {
        const self = cast(raw);
        self.stable() catch return false;
        const node: *const Node = @fieldParentPtr("table", table);
        self.nodeValid(node) catch return false;
        return node.prepared and node.backing.valid() and node.backing.retained and node.backing.epoch == self.epoch and
            cpuValid(node.cpu) and table.dma == node.backing.pages[0] and
            table.cpu != null and @intFromPtr(table.cpu.?) == node.cpu.cpu_address;
    }
    fn release(raw: *anyopaque, table: *vm.Table) vm.Error!void {
        const self = cast(raw);
        try self.stable();
        if (!valid(raw, table)) return self.fail(error.Descriptor);
        const node: *Node = @fieldParentPtr("table", table);
        // The VM removed this table only after confirmed invalidation/root
        // detach. Finish that logical removal even if the common collector
        // awaits the surrounding native BO's RM destruction. Keep the node
        // resident until closeEmpty/closeAfterReset proves collection later.
        _ = self.dispose(node, null, true) catch |err| return self.fail(err);
    }
    fn releasePending(self: *Owner) vm.Error!void {
        if (!heapValid(self.pending) or !std.meta.eql(self.pending, self.pending_stamp)) return error.Descriptor;
        self.last_operation = .heap_release;
        self.last_status = self.heap.?.release(self.pending.handle);
        if (self.last_status != a.driver_heap_ok) return error.Retained;
        self.pending = .{};
        self.pending_stamp = .{};
    }
    fn dispose(self: *Owner, node: *Node, proof: ?reset.Quiescence, allow_deferred: bool) vm.Error!bool {
        try self.nodeValid(node);
        if (proof) |value| if (!value.valid(self.epoch)) return error.Stale;
        if (node.cpu.lease.id != 0) {
            if (!cpuValid(node.cpu) or node.backing.memory == null) return error.Descriptor;
            self.last_operation = .cpu_unmap;
            self.last_status = node.backing.memory.?.bufferUnmap(&node.cpu.lease);
            if (self.last_status != ok) return error.Retained;
            node.cpu = .{};
            node.cpu_stamp = .{};
        } else if (!std.meta.eql(node.cpu, a.GfxBufferMap{})) return error.Descriptor;
        const closed = if (proof) |value| blk: {
            break :blk if (node.prepared) node.backing.closeAfterReset(value) else node.backing.close();
        } else blk: {
            // Normal caller is the VM owner after a completed invalidate/root
            // detach, or private allocation cleanup before publication.
            node.backing.retained = false;
            break :blk node.backing.close();
        };
        if (!closed) {
            self.last_operation = .backing;
            self.last_status = node.backing.close_status;
            self.last_backing_step = @tagName(node.backing.close_step);
            if (allow_deferred and node.backing.awaitingCollection()) {
                if (!node.awaiting_collection) self.deferred_pages += 1;
                node.awaiting_collection = true;
                node.prepared = false;
                return false;
            }
            return error.Retained;
        }
        if (self.pending.handle != 0 or self.pending.cpu_address != 0) return error.Retained;
        self.pending = node.allocation;
        self.pending_stamp = node.allocation_stamp;
        if (node.previous) |prev| prev.next = node.next else self.first = node.next;
        if (node.next) |next| next.previous = node.previous;
        if (node.awaiting_collection) self.deferred_pages -= 1;
        try self.releasePending();
        return true;
    }
    /// One common BO/metadata allocation per reset cleanup step. The proof
    /// is checked again for each step while PCI bus mastering remains off.
    pub fn closeAfterReset(self: *Owner, proof: reset.Quiescence) vm.Error!bool {
        if (self.self_address == 0) return true;
        try self.stable();
        if (!proof.valid(self.epoch)) return error.Stale;
        if (self.pending.handle != 0 or self.pending.cpu_address != 0) { try self.releasePending(); return false; }
        if (self.first) |node| { _ = try self.dispose(node, proof, false); return false; }
        self.* = .{};
        return true;
    }
    pub fn closeEmpty(self: *Owner) vm.Error!void {
        if (self.self_address == 0) return;
        try self.stable();
        if (self.failure != null) return error.Retained;
        while (self.first) |node| {
            if (!node.awaiting_collection or node.prepared) return error.Retained;
            _ = try self.dispose(node, null, false);
        }
        if (self.deferred_pages != 0 or self.pending.handle != 0 or self.pending.cpu_address != 0) return error.Retained;
        self.* = .{};
    }
};
