//! Resident, dynamically indexed VA resources for the serialized driver worker.
//! The runtime supplies its sole exchange token and authenticates BO sources.
//! This owner retains every metadata allocation, including partial failures.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const boot = @import("gsp_boot_events.zig");
const names = @import("gsp_rm_names.zig");
pub const range = @import("gsp_virtual_range.zig");
pub const Error = range.Error || error{ Api, Memory };
const Tree = std.Treap(u64, std.math.order);
pub const Handle = struct { epoch: u64, serial: u64 };
pub const BindingHandle = struct { range: Handle, serial: u64 };
pub const Range = struct {
    index: Tree.Node = undefined,
    allocation: a.DriverHeapAllocation = .{},
    stamp: a.DriverHeapAllocation = .{},
    names: names.ResidentChildren = .{},
    value: ?range.Owner = null,
    bindings: Tree = .{},
    retiring: bool = false,
};
pub const Binding = struct {
    index: Tree.Node = undefined,
    allocation: a.DriverHeapAllocation = .{},
    stamp: a.DriverHeapAllocation = .{},
    value: range.Binding = .{},
    retiring: bool = false,
    executions: usize = 0,
};
pub const ExecutionUse = struct { handle: BindingHandle, mapping: range.wire.Mapping };
pub const Completion = struct { range: Handle, binding: ?BindingHandle, rejected: ?u32, retired: bool };
pub const Owner = struct {
    self_address: usize = 0,
    epoch: u64 = 0,
    serial: u64 = 0,
    heap: ?r4os.r4dev.DriverHeapContext = null,
    ranges: Tree = .{},
    active_range: ?*Range = null,
    active_binding: ?*Binding = null,
    pending: a.DriverHeapAllocation = .{},
    pending_stamp: a.DriverHeapAllocation = .{},
    pending_valid: bool = false,
    failure: ?Error = null,

    pub fn configure(self: *Owner, ctx: *const r4os.r4dev.DriverContext, epoch: u64) Error!void {
        if (epoch == 0) return error.Stale;
        if (self.self_address != 0) {
            try self.stable();
            if (self.epoch != epoch) return error.Stale;
            return;
        }
        const heap = ctx.heap() orelse return error.Api;
        self.self_address = @intFromPtr(self);
        self.epoch = epoch;
        self.heap = heap;
    }
    fn stable(self: *const Owner) Error!void {
        if (self.self_address != @intFromPtr(self) or self.epoch == 0 or self.heap == null) return error.Stale;
        if (self.failure != null) return error.Retained;
    }
    fn fail(self: *Owner, reason: Error) Error {
        if (self.failure == null) self.failure = reason;
        return reason;
    }
    fn nextSerial(self: *Owner) Error!u64 {
        self.serial = std.math.add(u64, self.serial, 1) catch return error.Exhausted;
        return self.serial;
    }
    fn validAllocation(comptime T: type, allocation: a.DriverHeapAllocation) bool {
        return allocation.version == 1 and allocation.size >= @sizeOf(a.DriverHeapAllocation) and allocation.reserved == 0 and
            allocation.handle != 0 and allocation.cpu_address != 0 and allocation.cpu_address % @alignOf(T) == 0 and
            allocation.byte_length >= @sizeOf(T) and allocation.alignment >= @alignOf(T) and
            allocation.cpu_address <= std.math.maxInt(u64) - allocation.byte_length;
    }
    fn allocate(self: *Owner, comptime T: type) Error!*T {
        try self.stable();
        if (self.active_range != null or self.pending.handle != 0 or self.pending.cpu_address != 0) return error.Busy;
        const result = self.heap.?.allocate(@sizeOf(T), @alignOf(T), &self.pending);
        self.pending_stamp = self.pending;
        if (result != a.driver_heap_ok and self.pending.handle == 0 and self.pending.cpu_address == 0) {
            self.pending = .{};
            self.pending_stamp = .{};
            return error.Memory;
        }
        if (!validAllocation(T, self.pending)) return self.fail(error.Descriptor);
        self.pending_valid = true;
        if (result != a.driver_heap_ok) {
            try self.releasePending();
            return error.Memory;
        }
        const value: *T = @ptrFromInt(self.pending.cpu_address);
        value.* = .{ .allocation = self.pending, .stamp = self.pending };
        return value;
    }
    fn published(self: *Owner) void {
        self.pending = .{};
        self.pending_stamp = .{};
        self.pending_valid = false;
    }
    fn releasePending(self: *Owner) Error!void {
        if (!self.pending_valid or !std.meta.eql(self.pending, self.pending_stamp) or self.pending.handle == 0) return error.Retained;
        if (self.heap.?.release(self.pending.handle) != a.driver_heap_ok) return self.fail(error.Retained);
        self.published();
    }
    fn release(self: *Owner, allocation: a.DriverHeapAllocation) Error!void {
        if (self.pending.handle != 0 or self.pending.cpu_address != 0) return self.fail(error.Retained);
        // Index detachment precedes release. Keep a descriptor outside the
        // freed allocation, and never inspect its node after this callback.
        self.pending = allocation;
        self.pending_stamp = allocation;
        self.pending_valid = true;
        try self.releasePending();
    }
    pub fn find(self: *Owner, handle: Handle) Error!*Range {
        try self.stable();
        if (handle.epoch != self.epoch or handle.serial == 0) return error.Stale;
        const node = self.ranges.getEntryFor(handle.serial).node orelse return error.Stale;
        const entry: *Range = @fieldParentPtr("index", node);
        if (!std.meta.eql(entry.allocation, entry.stamp) or !validAllocation(Range, entry.allocation) or
            entry.allocation.cpu_address != @intFromPtr(entry)) return error.Descriptor;
        return entry;
    }
    pub fn findBinding(self: *Owner, handle: BindingHandle) Error!*Binding {
        const parent = try self.find(handle.range);
        const node = parent.bindings.getEntryFor(handle.serial).node orelse return error.Stale;
        const entry: *Binding = @fieldParentPtr("index", node);
        if (!std.meta.eql(entry.allocation, entry.stamp) or !validAllocation(Binding, entry.allocation) or
            entry.allocation.cpu_address != @intFromPtr(entry)) return error.Descriptor;
        return entry;
    }
    pub fn executionView(self: *Owner, handle: BindingHandle) Error!ExecutionUse {
        const parent = try self.find(handle.range);
        const entry = try self.findBinding(handle);
        if (parent.retiring or entry.retiring or self.active_range == parent) return error.Busy;
        const value = if (parent.value) |*v| v else return error.State;
        return .{ .handle = handle, .mapping = try value.executionMapping(&entry.value) };
    }
    pub fn acquireExecution(self: *Owner, handle: BindingHandle) Error!ExecutionUse {
        const use = try self.executionView(handle);
        const entry = try self.findBinding(handle);
        entry.executions = std.math.add(usize, entry.executions, 1) catch return error.Exhausted;
        return use;
    }
    pub fn validateExecution(self: *Owner, use: ExecutionUse) Error!void {
        if ((try self.findBinding(use.handle)).executions == 0 or
            !std.meta.eql(use, try self.executionView(use.handle))) return error.Stale;
    }
    /// Only the work owner may call this after completion, before submission,
    /// or with its device-reset proof. No session/firmware access on reset.
    pub fn releaseExecution(self: *Owner, use: ExecutionUse) Error!void {
        const entry = try self.findBinding(use.handle);
        if (entry.executions == 0 or !std.meta.eql(entry.value.mapping, @as(?range.wire.Mapping, use.mapping)) or
            !std.meta.eql(entry.value.mapping, entry.value.stamp)) return error.Retained;
        entry.executions -= 1;
    }
    pub fn first(self: *Owner) Error!?Handle {
        if (self.self_address == 0) return null;
        try self.stable();
        const node = self.ranges.getMin() orelse return null;
        return .{ .epoch = self.epoch, .serial = node.key };
    }
    pub fn firstBinding(self: *Owner, handle: Handle) Error!?BindingHandle {
        const parent = try self.find(handle);
        const node = parent.bindings.getMin() orelse return null;
        return .{ .range = handle, .serial = node.key };
    }
    pub fn create(self: *Owner, token: *boot.Handoff, space: @import("gsp_vaspace.zig").Info,
        parent: names.Lease, config: range.Config, deadline: u64) Error!Handle
    {
        try self.stable();
        if (space.epoch != self.epoch or token.session.epoch != self.epoch) return error.Stale;
        const serial = try self.nextSerial();
        const entry = try self.allocate(Range);
        var place = self.ranges.getEntryFor(serial);
        place.set(&entry.index);
        self.published();
        entry.value = range.Owner.initResident(token, space, parent, config, deadline, &entry.names) catch |err| {
            if (entry.names.self_address != 0) return self.fail(error.Retained);
            try self.removeRange(entry);
            return err;
        };
        self.active_range = entry;
        return .{ .epoch = self.epoch, .serial = serial };
    }
    /// Prepare resident storage before borrowing the real BO owner. The
    /// caller fills value.source through that owner's retainAlias operation.
    /// A failed prepare/map must use discardBinding, never free this pointer.
    pub fn prepareBinding(self: *Owner, handle: Handle) Error!BindingHandle {
        const parent = try self.find(handle);
        const value = if (parent.value) |*v| v else return error.State;
        if (parent.retiring or value.state != .handed_off or value.info() == null) return error.State;
        const serial = try self.nextSerial();
        const entry = try self.allocate(Binding);
        var place = parent.bindings.getEntryFor(serial);
        place.set(&entry.index);
        self.published();
        return .{ .range = handle, .serial = serial };
    }
    pub fn discardBinding(self: *Owner, handle: BindingHandle) Error!void {
        const parent = try self.find(handle.range);
        const entry = try self.findBinding(handle);
        if (entry.executions != 0 or self.active_binding == entry or entry.value.owner != null or entry.value.mapped or entry.value.source.mapping_owner != null) return error.Busy;
        if (entry.value.source.self_address != 0) entry.value.source.close(true) catch |err| return self.fail(err);
        try self.removeBinding(parent, entry);
    }
    pub fn beginMap(self: *Owner, token: *boot.Handoff, handle: BindingHandle, offset: u64, deadline: u64) Error!void {
        const parent = try self.find(handle.range);
        const entry = try self.findBinding(handle);
        if (self.active_range != null or parent.retiring or entry.retiring) return error.Busy;
        const value = if (parent.value) |*v| v else return error.State;
        try value.beginMap(token, &entry.value, offset, deadline);
        self.active_range = parent;
        self.active_binding = entry;
    }
    pub fn beginUnmap(self: *Owner, token: *boot.Handoff, handle: BindingHandle, deadline: u64, quiesced: bool) Error!void {
        const parent = try self.find(handle.range);
        const entry = try self.findBinding(handle);
        if (entry.executions != 0 or self.active_range != null or parent.retiring or entry.retiring) return error.Busy;
        const value = if (parent.value) |*v| v else return error.State;
        try value.beginUnmap(token, &entry.value, deadline, quiesced);
        entry.retiring = true;
        self.active_range = parent;
        self.active_binding = entry;
    }
    pub fn beginDestroy(self: *Owner, token: *boot.Handoff, handle: Handle, deadline: u64, quiesced: bool) Error!void {
        const entry = try self.find(handle);
        if (self.active_range != null or entry.retiring or entry.bindings.root != null) return error.Busy;
        const value = if (entry.value) |*v| v else return error.State;
        try value.beginDestroy(token, deadline, quiesced);
        entry.retiring = true;
        self.active_range = entry;
    }
    /// A known rejected allocation has no RM object; retire only its metadata.
    pub fn discardRejected(self: *Owner, handle: Handle) Error!void {
        const entry = try self.find(handle);
        const value = if (entry.value) |*v| v else return error.State;
        if (self.active_range == entry or value.state != .finished or value.namespace_live or value.address != 0 or entry.bindings.root != null) return error.Busy;
        try self.removeRange(entry);
    }
    pub fn active(self: *Owner) ?*range.Owner {
        if (self.self_address != @intFromPtr(self)) return null;
        const entry = self.active_range orelse return null;
        return if (entry.value) |*value| value else null;
    }
    /// Called after the range successfully handed its exchange back. The
    /// returned completion is a value snapshot, safe after metadata retirement.
    pub fn complete(self: *Owner) Error!Completion {
        try self.stable();
        const entry = self.active_range orelse return error.State;
        const value = if (entry.value) |*v| v else return error.State;
        if (value.state != .handed_off and value.state != .finished) return error.State;
        const handle: Handle = .{ .epoch = self.epoch, .serial = entry.index.key };
        const binding = self.active_binding;
        const result: Completion = .{ .range = handle,
            .binding = if (binding) |v| .{ .range = handle, .serial = v.index.key } else null,
            .rejected = value.rejected, .retired = if (binding) |v| v.retiring else entry.retiring };
        self.active_binding = null;
        self.active_range = null;
        if (binding) |item| if (item.retiring) {
            if (item.value.owner != null or item.value.source.self_address != 0 or item.value.mapped) return self.fail(error.Retained);
            try self.removeBinding(entry, item);
        };
        if (entry.retiring) try self.removeRange(entry);
        return result;
    }
    fn removeBinding(self: *Owner, parent: *Range, entry: *Binding) Error!void {
        if (entry.executions != 0 or entry.value.owner != null or entry.value.source.self_address != 0 or entry.value.mapped or
            !std.meta.eql(entry.allocation, entry.stamp) or !validAllocation(Binding, entry.allocation)) return self.fail(error.Retained);
        const allocation = entry.allocation;
        var place = parent.bindings.getEntryForExisting(&entry.index);
        place.set(null);
        try self.release(allocation);
    }
    fn removeRange(self: *Owner, entry: *Range) Error!void {
        if (entry.bindings.root != null or entry.names.self_address != 0 or
            !std.meta.eql(entry.allocation, entry.stamp) or !validAllocation(Range, entry.allocation)) return self.fail(error.Retained);
        if (entry.value) |*value| if (value.namespace_live or value.address != 0 or value.bindings != null) return self.fail(error.Retained);
        const allocation = entry.allocation;
        var place = self.ranges.getEntryForExisting(&entry.index);
        place.set(null);
        try self.release(allocation);
    }
    /// One physical binding or one heap node per call. Reset has already
    /// invalidated all RM addresses, but pending descriptors are still owned.
    pub fn closeAfterReset(self: *Owner, proof: @import("gsp_reset.zig").Quiescence) Error!bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or !proof.valid(self.epoch) or self.heap == null) return error.Retained;
        self.active_range = null;
        self.active_binding = null;
        if (self.pending.handle != 0 or self.pending.cpu_address != 0) {
            try self.releasePending();
            return false;
        }
        const node = self.ranges.getMin() orelse return true;
        const entry: *Range = @fieldParentPtr("index", node);
        if (!std.meta.eql(entry.allocation, entry.stamp) or !validAllocation(Range, entry.allocation) or
            entry.allocation.cpu_address != @intFromPtr(entry)) return error.Retained;
        const value = if (entry.value) |*v| v else return error.Retained;
        var uses = entry.bindings.inorderIterator();
        while (uses.next()) |binding_node| {
            const binding: *Binding = @fieldParentPtr("index", binding_node);
            if (binding.executions != 0) return error.Retained;
        }
        if (!try value.closeAfterReset(proof)) return false;
        if (entry.bindings.getMin()) |child_node| {
            const child: *Binding = @fieldParentPtr("index", child_node);
            if (!std.meta.eql(child.allocation, child.stamp) or !validAllocation(Binding, child.allocation) or
                child.allocation.cpu_address != @intFromPtr(child)) return error.Retained;
            if (child.value.source.self_address != 0) try child.value.source.closeAfterReset(proof);
            try self.removeBinding(entry, child);
            return false;
        }
        try self.removeRange(entry);
        return false;
    }
};
