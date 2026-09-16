// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Public native jobs share the common producer scheduler. The kernel owns
//! BO/VA execution loans; this worker owns contexts and actual RM map uses.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const nv = @import("r4nv_binding");
const runtime = @import("gsp_runtime.zig");
const graphics = @import("gsp_native_graphics.zig");
const batch = @import("gsp_push_batch.zig");
const Tree = std.Treap(u64, std.math.order);
pub const operation_bit: u64 = @as(u64, 1) << a.gfx_queue_operation_native;
const Node = struct {
    index: Tree.Node = undefined,
    next: ?*Node = null,
    previous: ?*Node = null,
    allocation: a.DriverHeapAllocation,
    stamp: a.DriverHeapAllocation,
    producer: @import("gsp_work_scheduling.zig").Producer,
    graphics: graphics.Owner = .{},
    jobs: usize = 0,
    closing: bool = false,
};
fn validAllocation(value: a.DriverHeapAllocation, bytes: usize, alignment: usize) bool {
    return value.version == 1 and value.size >= @sizeOf(a.DriverHeapAllocation) and value.handle != 0 and value.reserved == 0 and
        value.cpu_address != 0 and value.cpu_address % alignment == 0 and value.alignment >= alignment and
        value.byte_length >= bytes and value.cpu_address <= std.math.maxInt(u64) - value.byte_length;
}
fn producer(job: a.GfxDriverJob) @import("gsp_work_scheduling.zig").Producer {
    return .{ .kind = job.producer_kind, .id = job.producer_id, .generation = job.producer_generation };
}
fn matches(info: a.GfxQueueOwnerInfo, timeline: u64, owner: @import("gsp_work_scheduling.zig").Producer) bool {
    return info.version == 1 and info.size >= @sizeOf(a.GfxQueueOwnerInfo) and info.timeline == timeline and info.closing <= 1 and
        info.producer_kind == owner.kind and info.producer_id == owner.id and info.producer_generation == owner.generation;
}
pub const Owner = struct {
    source: ?*const graphics.Owner = null,
    heap: ?r4os.r4dev.DriverHeapContext = null,
    queue: r4os.driver_queue.Context = undefined,
    binding: a.GfxBackendBinding = .{},
    epoch: u64 = 0,
    nodes: Tree = .{},
    head: ?*Node = null,
    cursor: ?*Node = null,
    count: usize = 0,
    scan_remaining: usize = 0,
    dirty: bool = false,
    spare: a.DriverHeapAllocation = .{},
    spare_valid: bool = false,

    pub fn wake(self: *Owner) void {
        self.dirty = true;
    }

    pub fn step(self: *Owner, run: *runtime.Owner, source: ?*const graphics.Owner) !bool {
        if (run.failure != null) return false;
        if (self.source == null) {
            const template = source orelse return false;
            const backend = if (run.copy_backend) |*value| value else return false;
            const table = backend.queue.table;
            if (run.graph_closing or template.phase != .ready or template.closing or run.virtual_provider.handle.id == 0 or
                table.size < @sizeOf(a.GfxDriverQueueApi) or table.read_native_info == 0 or table.read_native_data == 0 or
                table.read_native_binding == 0 or table.queue_owner_info == 0) return false;
            const rc = backend.queue.updateOperations(&backend.binding, backend.operations | operation_bit);
            if (rc == a.gfx_queue_error_busy) return false;
            if (rc != 1) return error.Queue;
            backend.operations |= operation_bit;
            self.source = template;
            self.epoch = run.epoch;
            self.binding = backend.binding;
            self.queue = backend.queue;
            self.heap = run.ctx.?.heap() orelse return error.Api;
            return true;
        }
        if (run.copy_backend == null and self.head == null and self.spare.handle == 0) {
            self.* = .{};
            return false;
        }
        if (run.epoch != self.epoch or run.copy_backend == null or !std.meta.eql(run.copy_backend.?.binding, self.binding)) return error.Stale;
        if (self.dirty) {
            self.scan_remaining = self.count;
            self.dirty = false;
        }
        const node = self.cursor orelse self.head orelse return false;
        try self.validate(node);
        self.cursor = node.next;
        if (self.scan_remaining != 0) self.scan_remaining -= 1;
        var info: a.GfxQueueOwnerInfo = .{};
        const rc = self.queue.queueOwnerInfo(&self.binding, node.index.key, &info);
        if (rc == 0) node.closing = true else if (rc == 1) {
            if (!matches(info, node.index.key, node.producer)) return error.Descriptor;
            node.closing = node.closing or info.closing == 1;
        } else return error.Queue;
        if (run.graph_closing) node.closing = true;
        if (node.closing and node.jobs == 0) try node.graphics.requestClose();
        const progress = try node.graphics.step(run, true);
        if (progress) self.scan_remaining = self.count;
        if (node.jobs == 0 and (node.graphics.phase == .closed or node.graphics.phase == .unavailable)) {
            try self.remove(node);
            return true;
        }
        return progress or self.scan_remaining != 0;
    }
    fn validate(self: *const Owner, node: *const Node) !void {
        if (self.heap == null or !std.meta.eql(node.allocation, node.stamp) or node.allocation.cpu_address != @intFromPtr(node) or
            !validAllocation(node.allocation, @sizeOf(Node), @alignOf(Node))) return error.Retained;
    }
    fn releaseSpare(self: *Owner) !void {
        if (!self.spare_valid or self.heap.?.release(self.spare.handle) != a.driver_heap_ok) return error.Retained;
        self.spare = .{};
        self.spare_valid = false;
    }
    fn acquire(self: *Owner, run: *runtime.Owner, job: a.GfxDriverJob) !*Node {
        if (self.source == null or self.epoch != run.epoch or self.spare.handle != 0) return error.Unsupported;
        const identity = producer(job);
        var info: a.GfxQueueOwnerInfo = .{};
        const rc = self.queue.queueOwnerInfo(&self.binding, job.fence.timeline, &info);
        if (rc != 1 or !matches(info, job.fence.timeline, identity)) return error.Stale;
        if (info.closing != 0) return error.Cancelled;
        var place = self.nodes.getEntryFor(job.fence.timeline);
        if (place.node) |index| {
            const node: *Node = @fieldParentPtr("index", index);
            try self.validate(node);
            if (!std.meta.eql(node.producer, identity)) return error.Stale;
            if (node.closing or node.graphics.phase == .closed or node.graphics.phase == .unavailable) return error.Cancelled;
            node.jobs = try std.math.add(usize, node.jobs, 1);
            return node;
        }
        const result = self.heap.?.allocate(@sizeOf(Node), @alignOf(Node), &self.spare);
        if (result != a.driver_heap_ok and self.spare.handle == 0 and self.spare.cpu_address == 0) return error.Memory;
        if (!validAllocation(self.spare, @sizeOf(Node), @alignOf(Node))) return error.Retained;
        self.spare_valid = true;
        if (result != a.driver_heap_ok) {
            try self.releaseSpare();
            return error.Memory;
        }
        const node: *Node = @ptrFromInt(self.spare.cpu_address);
        node.* = .{ .allocation = self.spare, .stamp = self.spare, .producer = identity, .jobs = 1 };
        node.graphics.requestRegular(self.source.?) catch |err| {
            try self.releaseSpare();
            return err;
        };
        place.set(&node.index);
        node.next = self.head;
        if (self.head) |head| head.previous = node;
        self.head = node;
        self.count += 1;
        self.dirty = true;
        self.spare = .{};
        self.spare_valid = false;
        return node;
    }
    fn release(self: *Owner, node: *Node) !void {
        try self.validate(node);
        if (node.jobs == 0) return error.Retained;
        node.jobs -= 1;
        self.dirty = true;
    }
    fn remove(self: *Owner, node: *Node) !void {
        try self.validate(node);
        if (node.jobs != 0 or self.spare.handle != 0) return error.Retained;
        if (self.cursor == node) self.cursor = node.next;
        if (node.previous) |previous| previous.next = node.next else self.head = node.next;
        if (node.next) |next| next.previous = node.previous;
        var place = self.nodes.getEntryForExisting(&node.index);
        place.set(null);
        self.count -= 1;
        self.scan_remaining = @min(self.scan_remaining, self.count);
        self.spare = node.allocation;
        self.spare_valid = true;
        try self.releaseSpare();
    }
    pub fn retiring(self: *const Owner, handle: runtime.ChannelHandle) bool {
        var node = self.head;
        while (node) |value| : (node = value.next) if (value.closing and value.jobs == 0 and value.graphics.channel != null and
            std.meta.eql(value.graphics.channel.?, handle) and value.graphics.phase == .channel_close) return true;
        return false;
    }
    /// Runtime calls this only after all physical contexts/channels have
    /// consumed the same reset proof; these are now merely host descriptors.
    pub fn closeAfterReset(self: *Owner, proof: @import("gsp_reset.zig").Quiescence, epoch: u64) !bool {
        if (self.source == null and self.head == null and self.spare.handle == 0) return true;
        if (!proof.valid(epoch) or epoch != self.epoch) return error.Stale;
        if (self.spare.handle != 0) {
            try self.releaseSpare();
            return false;
        }
        if (self.head) |node| {
            try self.remove(node);
            return false;
        }
        self.* = .{};
        return true;
    }
};

pub const Phase = enum { inspect, count_bindings, allocate, pushes, bindings, context, submit, wait, done };
pub const Job = struct {
    self_address: usize = 0,
    queue: r4os.driver_queue.Context = undefined,
    binding: a.GfxBackendBinding = .{},
    job: a.GfxDriverJob = .{},
    stamp: a.GfxDriverJob = .{},
    heap: ?r4os.r4dev.DriverHeapContext = null,
    epoch: u64 = 0,
    info: a.GfxNativeJobInfo = .{},
    header: nv.R4NvNativeSubmitHeader = undefined,
    allocation: a.DriverHeapAllocation = .{},
    allocation_stamp: a.DriverHeapAllocation = .{},
    binding_count: usize = 0,
    binding_cursor: usize = 0,
    resource_cursor: u32 = 0,
    part_cursor: usize = 0,
    push_cursor: usize = 0,
    node: ?*Node = null,
    phase: Phase = .inspect,
    waited: bool = false,

    pub fn open(self: *Job, run: *runtime.Owner, queue: r4os.driver_queue.Context, binding: a.GfxBackendBinding, job: a.GfxDriverJob) !void {
        if (self.self_address != 0) return error.State;
        self.* = .{ .self_address = @intFromPtr(self), .queue = queue, .binding = binding, .job = job, .stamp = job, .epoch = run.epoch, .heap = run.ctx.?.heap() orelse return error.Api };
        if (job.version != 1 or job.size < @sizeOf(a.GfxDriverJob) or job.operation != a.gfx_queue_operation_native or
            job.producer_kind == 0 or job.producer_kind > 3 or job.producer_id == 0 or job.producer_generation == 0 or job.producer_reserved != 0 or
            job.fence.timeline == 0 or job.fence.point == 0 or job.fence.adapter_id != binding.adapter_id or
            job.fence.device_generation != binding.device_generation or job.fence.reset_generation != binding.reset_generation) return error.Descriptor;
    }
    fn storageBytes(self: *const Job) !usize {
        return @max(1, try std.math.add(usize, try std.math.mul(usize, self.header.push_count, @sizeOf(batch.Push)), try std.math.mul(usize, self.binding_count, @sizeOf(runtime.VirtualBindingHandle))));
    }
    fn validStorage(self: *const Job) bool {
        return std.meta.eql(self.allocation, self.allocation_stamp) and
            validAllocation(self.allocation, self.storageBytes() catch return false, @alignOf(runtime.VirtualBindingHandle));
    }
    pub fn pushes(self: *const Job) []const batch.Push {
        const ptr: [*]const batch.Push = @ptrFromInt(self.allocation.cpu_address);
        return ptr[0..self.header.push_count];
    }
    pub fn bindings(self: *const Job) []const runtime.VirtualBindingHandle {
        const ptr: [*]const runtime.VirtualBindingHandle = @ptrFromInt(self.allocation.cpu_address + @as(usize, self.header.push_count) * @sizeOf(batch.Push));
        return ptr[0..self.binding_count];
    }
    pub fn channel(self: *const Job) !runtime.ChannelHandle {
        const node = self.node orelse return error.State;
        if (node.graphics.phase != .ready) return error.Busy;
        return node.graphics.channel orelse error.State;
    }
    pub fn validate(self: *const Job, run: *const runtime.Owner) !void {
        if (self.self_address != @intFromPtr(self) or !std.meta.eql(self.job, self.stamp) or self.epoch != run.epoch or
            !self.validStorage() or self.push_cursor != self.header.push_count or self.binding_cursor != self.binding_count) return error.Retained;
        try run.native_queues.validate(self.node orelse return error.Stale);
    }
    fn parts(self: *Job, run: *runtime.Owner) ![]const runtime.VirtualBindingHandle {
        var value: a.GfxNativeBinding = .{};
        if (self.queue.nativeBinding(&self.job.fence, self.resource_cursor, &value) != 1) return error.Stale;
        return run.virtual_provider.executionParts(self.epoch, value);
    }
    fn read(self: *Job, offset: u32, bytes: []u8) !void {
        if (self.queue.nativeData(&self.job.fence, offset, bytes) != 1) return error.Stale;
    }
    pub fn step(self: *Job, run: *runtime.Owner, now: u64) !bool {
        if (self.self_address != @intFromPtr(self) or !std.meta.eql(self.job, self.stamp) or self.epoch != run.epoch) return error.Retained;
        if (self.phase == .done) return false;
        if (self.phase != .wait and self.job.deadline_ns != 0 and now >= self.job.deadline_ns) {
            try self.finish(run, a.gfx_queue_result_cancelled);
            return true;
        }
        const progress = self.advance(run) catch |err| {
            if (err == error.Busy) {
                if (self.waited) return false;
                run.yieldWork() catch |yield_error| {
                    if (yield_error == error.Busy) return false;
                    return yield_error;
                };
                self.waited = true;
                return true;
            }
            if (run.failure != null or err == error.Retained or err == error.Descriptor or self.phase == .wait) return err;
            try run.nativeRejection(err);
            try self.finish(run, if (err == error.Cancelled) a.gfx_queue_result_cancelled else a.gfx_queue_result_failed);
            return true;
        };
        if (!progress) return false;
        self.waited = false;
        if (self.phase != .wait and self.phase != .done) try run.yieldWork();
        return true;
    }
    fn advance(self: *Job, run: *runtime.Owner) !bool {
        switch (self.phase) {
            .inspect => {
                if (self.queue.nativeInfo(&self.job.fence, &self.info) != 1) return error.Stale;
                if (self.info.version != 1 or self.info.size < @sizeOf(a.GfxNativeJobInfo) or self.info.reserved0 != 0 or
                    self.info.interface_id_lo != nv.backend_v1_header.interface_id_lo or self.info.interface_id_hi != nv.backend_v1_header.interface_id_hi or
                    self.info.revision != 1 or self.info.command_bytes < @sizeOf(nv.R4NvNativeSubmitHeader)) return error.Unsupported;
                try self.read(0, std.mem.asBytes(&self.header));
                if (self.header.version != nv.native_submit_version or self.header.size != @sizeOf(nv.R4NvNativeSubmitHeader) or
                    self.header.engine_mask != nv.native_engine_graphics or self.header.reserved0 != 0 or self.header.reserved1 != 0 or
                    self.header.push_count > batch.capacity or self.info.command_bytes != @sizeOf(nv.R4NvNativeSubmitHeader) +
                    self.header.push_count * @sizeOf(nv.R4NvNativePush)) return error.Unsupported;
                self.phase = .count_bindings;
            },
            .count_bindings => {
                if (self.resource_cursor == self.info.resource_count) {
                    self.phase = .allocate;
                    return true;
                }
                self.binding_count = try std.math.add(usize, self.binding_count, (try self.parts(run)).len);
                self.resource_cursor += 1;
            },
            .allocate => {
                const bytes = try self.storageBytes();
                const rc = self.heap.?.allocate(bytes, @alignOf(runtime.VirtualBindingHandle), &self.allocation);
                self.allocation_stamp = self.allocation;
                if (rc != a.driver_heap_ok and self.allocation.handle == 0 and self.allocation.cpu_address == 0) return error.Memory;
                if (!self.validStorage()) return error.Retained;
                if (rc != a.driver_heap_ok) return error.Memory;
                self.resource_cursor = 0;
                self.phase = .pushes;
            },
            .pushes => {
                if (self.push_cursor == self.header.push_count) {
                    self.phase = .bindings;
                    return true;
                }
                var value: nv.R4NvNativePush = undefined;
                try self.read(@intCast(@sizeOf(nv.R4NvNativeSubmitHeader) + self.push_cursor * @sizeOf(nv.R4NvNativePush)), std.mem.asBytes(&value));
                if (value.flags & ~@as(u32, nv.native_push_incomplete | nv.native_push_no_prefetch) != 0) return error.Unsupported;
                const push: batch.Push = .{ .address = value.address, .bytes = value.byte_length, .incomplete = value.flags & nv.native_push_incomplete != 0, .no_prefetch = value.flags & nv.native_push_no_prefetch != 0 };
                _ = try batch.entry(push);
                @constCast(self.pushes())[self.push_cursor] = push;
                self.push_cursor += 1;
            },
            .bindings => {
                if (self.resource_cursor == self.info.resource_count) {
                    if (self.binding_cursor != self.binding_count) return error.Retained;
                    try batch.validate(self.pushes());
                    self.phase = .context;
                    return true;
                }
                const values = try self.parts(run);
                if (self.part_cursor >= values.len or self.binding_cursor >= self.binding_count) return error.Retained;
                @constCast(self.bindings())[self.binding_cursor] = values[self.part_cursor];
                self.binding_cursor += 1;
                self.part_cursor += 1;
                if (self.part_cursor == values.len) {
                    self.resource_cursor += 1;
                    self.part_cursor = 0;
                }
            },
            .context => {
                if (self.node == null) self.node = try run.native_queues.acquire(run, self.job);
                if (self.node.?.closing) return error.Cancelled;
                if (self.node.?.graphics.phase == .unavailable or self.node.?.graphics.phase == .closed) return error.Unsupported;
                _ = try self.channel();
                self.phase = .submit;
            },
            .submit => {
                if (self.node.?.closing) return error.Cancelled;
                try self.validate(run);
                try run.beginQueuedPushBatch(self);
                self.phase = .wait;
            },
            .wait => {
                if ((try run.receivePushBatch(try self.channel())) == null) return false;
                try self.finish(run, a.gfx_queue_result_complete);
            },
            .done => return error.State,
        }
        return true;
    }
    fn freeStorage(self: *Job, owner: *Owner) !void {
        if (self.allocation.handle != 0 or self.allocation.cpu_address != 0) {
            if (!self.validStorage() or self.heap.?.release(self.allocation.handle) != a.driver_heap_ok) return error.Retained;
            self.allocation = .{};
            self.allocation_stamp = .{};
        }
        if (self.node) |node| {
            try owner.release(node);
            self.node = null;
        }
    }
    fn finish(self: *Job, run: *runtime.Owner, result: u32) !void {
        try self.freeStorage(&run.native_queues);
        if (self.queue.complete(&self.job.fence, result, 1) != 1) return error.Retained;
        self.phase = .done;
    }
    pub fn closeAfterReset(self: *Job, owner: *Owner, proof: @import("gsp_reset.zig").Quiescence, epoch: u64) bool {
        if (self.self_address == 0) return true;
        if (!proof.valid(epoch) or self.epoch != epoch or self.self_address != @intFromPtr(self) or !std.meta.eql(self.job, self.stamp)) return false;
        self.freeStorage(owner) catch return false;
        self.* = .{};
        return true;
    }
};
