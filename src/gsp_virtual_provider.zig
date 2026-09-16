//! Common VA provider, serialized by the existing Device worker. The kernel
//! owns process lifetime; this adapter owns real RM handles and partial binds.
//! Native submissions resolve kernel-retained public bindings here; the batch
//! owner independently retains each actual RM mapping through GPU completion.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const runtime = @import("gsp_runtime.zig");
const Tree = std.Treap(u64, std.math.order);
const Waiting = enum { none, range_create, range_destroy, buffer_create, buffer_destroy, map, unmap };
const Node = struct {
    index: Tree.Node = undefined,
    allocation: a.DriverHeapAllocation,
    stamp: a.DriverHeapAllocation,
    resource: a.GfxBufferHandle,
    request: a.GfxVirtualRequest,
    reference: a.GfxBufferReference,
    range: ?runtime.VirtualHandle = null,
    buffer: ?runtime.BufferHandle = null,
    capacity: usize,
    used: usize = 0,
    mapped: u64 = 0,
    chunk: u64 = 0,
    address: u64 = 0,
    system: bool = false,
    ready: bool = false,
    result: i32 = 1,
    waiting: Waiting = .none,

    fn parts(self: *Node) []runtime.VirtualBindingHandle {
        const data: [*]runtime.VirtualBindingHandle = @ptrFromInt(@intFromPtr(self) + @sizeOf(Node));
        return data[0..self.capacity];
    }
    fn token(self: *const Node) a.GfxVirtualToken {
        return .{ .opaque0 = self.request.memory_generation, .opaque1 = self.index.key, .opaque2 = self.request.kind };
    }
};
pub const Owner = struct {
    handle: a.GfxBufferHandle = .{},
    memory: ?r4os.driver_memory.Context = null,
    heap: ?r4os.r4dev.DriverHeapContext = null,
    serial: u64 = 0,
    nodes: Tree = .{},
    requested: bool = false,
    closing: bool = false,
    pending: ?struct { job: a.GfxVirtualJob, node: ?*Node = null, detached: bool = false } = null,
    spare: a.DriverHeapAllocation = .{},
    spare_valid: bool = false,

    fn notify(raw: usize) callconv(.c) i32 {
        const self: *Owner = @ptrFromInt(raw);
        self.requested = true; // Closing providers must still receive retire jobs.
        return 0;
    }
    pub fn closed(self: *const Owner) bool {
        return self.handle.id == 0 and self.empty();
    }
    fn empty(self: *const Owner) bool {
        return self.pending == null and self.nodes.root == null and
            self.spare.handle == 0 and self.spare.cpu_address == 0;
    }
    pub fn close(self: *Owner) void {
        self.closing = true;
        self.requested = true;
        if (self.memory) |memory| {
            if (self.handle.id != 0) {
                const rc = memory.virtualUnregister(&self.handle);
                if (rc == 1 or (rc == a.gfx_buffer_error_stale and self.empty())) self.handle = .{};
            }
        }
    }
    fn deadline(running: *runtime.Owner) !u64 {
        const clock = running.ctx.?.resources() orelse return error.Api;
        const instant = clock.nowNs();
        if (instant == 0 or instant == std.math.maxInt(u64)) return error.Clock;
        return std.math.add(u64, instant, 5 * std.time.ns_per_s);
    }
    fn find(self: *Owner, token: a.GfxVirtualToken, epoch: u64, kind: u32) !*Node {
        if (token.opaque0 != epoch or token.opaque1 == 0 or token.opaque2 != kind) return error.Stale;
        const index = self.nodes.getEntryFor(token.opaque1).node orelse return error.Stale;
        const node: *Node = @fieldParentPtr("index", index);
        if (!std.meta.eql(node.allocation, node.stamp) or node.allocation.cpu_address != @intFromPtr(node) or
            !std.meta.eql(node.token(), token)) return error.Descriptor;
        return node;
    }
    /// Only call with the canonical snapshot read for an active kernel job.
    /// Its execution loan prevents public retirement; no application token
    /// by itself can authorize this private mapping lookup.
    pub fn executionParts(self: *Owner, epoch: u64, value: a.GfxNativeBinding) ![]const runtime.VirtualBindingHandle {
        if (self.closing or self.handle.id == 0 or value.version != 1 or value.size < @sizeOf(a.GfxNativeBinding) or
            value.reserved0 != 0 or value.access > 1) return error.Stale;
        const node = try self.find(value.token, epoch, 2);
        if (!node.ready or node.result != 1 or node.waiting != .none or node.used == 0 or node.used > node.capacity or
            node.mapped != node.request.byte_length or !std.meta.eql(value.binding, node.resource) or
            value.address != node.address or value.byte_length != node.request.byte_length) return error.Stale;
        if (self.pending) |pending| if (pending.node == node and pending.job.operation == 1) return error.Retained;
        return node.parts()[0..node.used];
    }
    fn create(self: *Owner, running: *runtime.Owner, job: a.GfxVirtualJob) !*Node {
        const request = job.request;
        if (request.memory_generation != running.epoch or request.adapter_id != running.adapter_id or
            (request.kind != 1 and request.kind != 2)) return error.Invalid;
        var parent: ?*Node = null;
        var system = false;
        var capacity: u64 = 0;
        if (request.kind == 2) {
            parent = try self.find(job.parent_token, running.epoch, 1);
            if (!parent.?.ready or !std.meta.eql(parent.?.resource, request.parent)) return error.Stale;
            if (job.reference.flags != 0) return error.Unsupported;
            var descriptor: a.GfxBufferDescriptor = .{};
            if (self.memory.?.bufferDescribe(&job.reference.reference, &descriptor) != 1) return error.Stale;
            if (descriptor.version != 1 or descriptor.size < @sizeOf(a.GfxBufferDescriptor) or descriptor.reserved0 != 0) return error.Descriptor;
            if (request.byte_length == 0 or request.byte_length > descriptor.byte_length or
                request.byte_offset > descriptor.byte_length - request.byte_length or
                request.byte_length > parent.?.request.byte_length or request.virtual_offset > parent.?.request.byte_length - request.byte_length or
                (request.byte_offset | request.virtual_offset | request.byte_length) & 4095 != 0) return error.Bounds;
            system = descriptor.location == a.gfx_buffer_location_system;
            if (!system and descriptor.location != a.gfx_buffer_location_device_local) return error.Unsupported;
            if (system) {
                const chunk = @import("gsp_buffer_mapping.zig").chunk_bytes;
                const extent = try std.math.add(u64, request.byte_offset % chunk, request.byte_length);
                capacity = (extent - 1) / chunk + 1;
            } else capacity = 1;
        }
        const bytes = try std.math.add(u64, @sizeOf(Node), try std.math.mul(u64, capacity, @sizeOf(runtime.VirtualBindingHandle)));
        const address = if (parent) |value| try std.math.add(u64, value.address, request.virtual_offset) else 0;
        const serial = try std.math.add(u64, self.serial, 1);
        if (self.spare.handle != 0 or self.spare.cpu_address != 0) return error.Retained;
        const rc = self.heap.?.allocate(bytes, @alignOf(Node), &self.spare);
        const storage = self.spare;
        if (rc != a.driver_heap_ok and storage.handle == 0 and storage.cpu_address == 0) { self.spare = .{}; return error.Memory; }
        if (storage.version != 1 or storage.size < @sizeOf(a.DriverHeapAllocation) or storage.reserved != 0 or storage.handle == 0 or
            storage.cpu_address == 0 or storage.cpu_address % @alignOf(Node) != 0 or storage.alignment < @alignOf(Node) or
            storage.byte_length < bytes or storage.cpu_address > std.math.maxInt(u64) - storage.byte_length) return error.Descriptor;
        self.spare_valid = true;
        if (rc != a.driver_heap_ok) { try self.releaseSpare(); return error.Memory; }
        const node: *Node = @ptrFromInt(storage.cpu_address);
        node.* = .{ .allocation = storage, .stamp = storage, .resource = job.resource, .request = request,
            .reference = job.reference, .capacity = @intCast(capacity), .system = system,
            .range = if (parent) |value| value.range else null,
            .address = address };
        var place = self.nodes.getEntryFor(serial);
        place.set(&node.index);
        self.serial = serial;
        self.spare = .{};
        self.spare_valid = false;
        return node;
    }
    fn releaseSpare(self: *Owner) !void {
        if (!self.spare_valid or self.heap.?.release(self.spare.handle) != a.driver_heap_ok) return error.Retained;
        self.spare = .{}; self.spare_valid = false;
    }
    fn remove(self: *Owner, node: *Node) !void {
        if (!std.meta.eql(node.allocation, node.stamp) or node.allocation.cpu_address != @intFromPtr(node) or
            self.spare.handle != 0 or self.spare.cpu_address != 0) return error.Retained;
        self.spare = node.allocation; self.spare_valid = true;
        var place = self.nodes.getEntryForExisting(&node.index);
        place.set(null);
        if (self.pending) |*pending| if (pending.node == node) { pending.node = null; pending.detached = true; };
        try self.releaseSpare(); // No dereference of node after this call.
    }
    fn errorResult(err: anyerror) i32 {
        return switch (err) {
            error.Memory, error.Exhausted => a.gfx_buffer_error_oom,
            error.Budget => a.gfx_buffer_error_budget,
            error.Unavailable => a.gfx_buffer_error_unavailable,
            error.Unsupported => a.gfx_buffer_error_unsupported,
            error.Overflow, error.Bounds => a.gfx_buffer_error_overflow,
            error.Stale => a.gfx_buffer_error_stale,
            error.Timeout => a.gfx_queue_error_wait_timeout,
            else => a.gfx_buffer_error_invalid,
        };
    }
    fn finish(self: *Owner, result: i32, token: a.GfxVirtualToken, address: u64) !void {
        const job = self.pending.?.job;
        if (self.memory.?.virtualComplete(&self.handle, &.{ .resource = job.resource, .operation = job.operation,
            .result = result, .token = token, .address = address }) != 1) return error.Retained;
        self.pending = null;
    }
    fn take(self: *Owner) !bool {
        if (!self.requested and !self.closing) return false;
        var job: a.GfxVirtualJob = .{};
        const rc = self.memory.?.virtualTake(&self.handle, &job);
        if (rc == a.gfx_buffer_error_busy) { self.requested = false; return false; }
        if (rc == a.gfx_buffer_error_stale and self.empty()) {
            // The kernel may retire an empty provider during driver close.
            self.closing = true; self.handle = .{}; return false;
        }
        if (rc != 1) return error.Api;
        self.pending = .{ .job = job };
        if (job.version != 1 or job.size < @sizeOf(a.GfxVirtualJob) or job.reserved0 != 0 or job.operation > 1) return error.Descriptor;
        return true;
    }
    pub fn step(self: *Owner, running: *runtime.Owner) !bool {
        if (running.failure != null) return false;
        if (self.handle.id == 0) {
            if (self.closing or running.graph_closing or running.nativeAddressSpace() == null) return false;
            const memory = running.ctx.?.memory() orelse return false;
            if (memory.table.size < @offsetOf(a.GfxDriverMemoryApi, "virtual_complete") + 8 or memory.table.virtual_register == 0 or
                memory.table.virtual_take == 0 or memory.table.virtual_complete == 0 or memory.table.virtual_unregister == 0) return false;
            self.memory = memory;
            self.heap = running.ctx.?.heap() orelse return error.Api;
            const rc = memory.virtualRegister(&.{ .adapter_id = running.adapter_id, .memory_generation = running.epoch,
                .notify = @intFromPtr(&notify), .context = @intFromPtr(self) }, &self.handle);
            if (rc == a.gfx_buffer_error_busy or rc == a.gfx_buffer_error_unavailable) return false;
            if (rc != 1) return error.Api;
            return true;
        }
        if (self.closing) { self.close(); if (self.handle.id == 0) return true; }
        if (self.pending == null and !try self.take()) return false;
        const job = self.pending.?.job;
        if (self.pending.?.node == null) {
            if (job.operation == 1) {
                const node = try self.find(job.token, running.epoch, job.request.kind);
                if (!node.ready or !std.meta.eql(node.resource, job.resource)) return error.Descriptor;
                self.pending.?.node = node;
            } else {
                if (self.closing) { try self.finish(a.gfx_queue_error_device_lost, .{}, 0); return true; }
                self.pending.?.node = self.create(running, job) catch |err| {
                    if (err == error.Descriptor or err == error.Retained) return err;
                    try self.finish(errorResult(err), .{}, 0); return true;
                };
            }
        }
        return self.advance(running) catch |err| {
            if (err == error.Busy) return false;
            // Once work is in flight, an unexpected result cannot prove that
            // its RM object disappeared. Reset retains the exact pending job.
            return err;
        };
    }
    fn advance(self: *Owner, running: *runtime.Owner) !bool {
        const node = self.pending.?.node.?;
        const job = self.pending.?.job;
        const budget = try deadline(running);
        const instant = budget - 5 * std.time.ns_per_s;
        if (job.operation == 0 and node.result == 1 and (self.closing or instant >= node.request.deadline_ns))
            node.result = if (self.closing) a.gfx_queue_error_device_lost else a.gfx_queue_error_wait_timeout;
        if (node.waiting != .none) return self.poll(running, node);
        if (job.operation == 0 and node.result == 1) {
            if (node.request.kind == 1) {
                if (node.range == null) {
                    node.range = running.allocateVirtualRange(.{ .bytes = node.request.byte_length, .alignment = node.request.alignment,
                        .fixed_address = node.request.fixed_address, .location = if (node.request.location == 0) .system else .video,
                        .blocklinear = node.request.flags & 1 != 0 }, budget) catch |err| return self.reject(running, node, err);
                    node.waiting = .range_create;
                    return true;
                }
            } else {
                if (node.system and node.buffer == null) {
                    node.buffer = running.mapVirtualReference(node.reference, budget) catch |err| return self.reject(running, node, err);
                    node.waiting = .buffer_create;
                    return true;
                }
                if (node.mapped < node.request.byte_length) {
                    if (node.used >= node.capacity) return error.Descriptor;
                    const result = running.mapVirtualBuffer(node.range.?, if (node.system) .{ .system = node.buffer.? } else .{ .native_reference = node.reference },
                        node.request.byte_offset + node.mapped, node.request.virtual_offset + node.mapped,
                        node.request.byte_length - node.mapped, budget) catch |err| return self.reject(running, node, err);
                    node.parts()[node.used] = result.handle;
                    node.used += 1; node.chunk = result.bytes; node.waiting = .map;
                    return true;
                }
            }
            node.ready = true;
            try self.finish(1, node.token(), node.address);
            return true;
        }
        // The common queue holds its public execution loan until the driver's
        // physical completion. The private batch also holds each actual RM
        // mapping; runtime unmap refuses those uses independently.
        if (node.used != 0) {
            const part = node.parts()[node.used - 1];
            const status = try running.virtualBindingStatus(part);
            if (status.mapped) {
                try running.unmapVirtualBuffer(part, budget, true);
                node.waiting = .unmap;
            } else {
                try running.discardVirtualBinding(part);
                node.used -= 1;
            }
            return true;
        }
        if (node.buffer) |buffer| {
            if (try running.releaseVirtualReference(buffer, budget, true)) node.waiting = .buffer_destroy else node.buffer = null;
            return true;
        }
        if (node.request.kind == 1) if (node.range) |range| {
            try running.retireVirtualRange(range, budget, true);
            node.waiting = .range_destroy; return true;
        };
        const result = node.result;
        try self.remove(node);
        try self.finish(if (job.operation == 1) 1 else result, if (job.operation == 1) job.token else .{}, 0);
        return true;
    }
    fn reject(self: *Owner, running: *runtime.Owner, node: *Node, err: anyerror) !bool {
        _ = self;
        if (err == error.Busy) return false;
        if (running.failure != null or err == error.Descriptor or err == error.Retained) return err;
        node.result = errorResult(err);
        return true; // Roll back previously acknowledged parts in later slices.
    }
    fn poll(self: *Owner, running: *runtime.Owner, node: *Node) !bool {
        _ = self;
        switch (node.waiting) {
            .range_create => {
                const status = try running.virtualStatus(node.range.?);
                if (status.state != .handed_off and status.state != .finished) return false;
                if (status.info) |info| { node.address = info.address; } else if (node.result == 1) { node.result = a.gfx_buffer_error_unavailable; }
            },
            .range_destroy => {
                _ = running.virtualStatus(node.range.?) catch |err| {
                    if (err != error.Stale) return err;
                    node.range = null; node.waiting = .none; return true;
                };
                return false;
            },
            .buffer_create => {
                const status = try running.bufferStatus(node.buffer.?);
                if (status.state != .handed_off) return false;
                if (status.info == null and node.result == 1) node.result = if (status.host_rejected) |err| errorResult(err) else a.gfx_buffer_error_unavailable;
            },
            .buffer_destroy => {
                _ = running.bufferStatus(node.buffer.?) catch |err| {
                    if (err != error.Stale) return err;
                    node.buffer = null; node.waiting = .none; return true;
                };
                return false;
            },
            .map => {
                if ((try running.virtualStatus(node.range.?)).state != .handed_off) return false;
                const status = try running.virtualBindingStatus(node.parts()[node.used - 1]);
                if (status.mapped) {
                    if (status.bytes != node.chunk or node.chunk == 0 or node.chunk > node.request.byte_length - node.mapped) return error.Descriptor;
                    node.mapped += node.chunk;
                } else if (status.rejected != null) {
                    if (node.result == 1) node.result = a.gfx_buffer_error_unavailable;
                } else return error.Descriptor;
            },
            .unmap => {
                _ = running.virtualBindingStatus(node.parts()[node.used - 1]) catch |err| {
                    if (err != error.Stale) return err;
                    node.used -= 1; node.waiting = .none; return true;
                };
                return false;
            },
            .none => return error.State,
        }
        node.waiting = .none;
        return true;
    }
    /// Called after runtime VA aliases AND RAM registrations consumed the
    /// real reset proof, before native BOs whose common loans still pin them.
    /// One common claim/metadata node per call; no fabricated RM reply.
    pub fn closeAfterReset(self: *Owner, proof: @import("gsp_reset.zig").Quiescence, epoch: u64) !bool {
        if (!proof.valid(epoch)) return error.Retained;
        self.close();
        if (self.spare.handle != 0 or self.spare.cpu_address != 0) { try self.releaseSpare(); return false; }
        if (self.closed()) return true;
        if (self.pending == null and !try self.take()) return false;
        const job = self.pending.?.job;
        if (job.request.memory_generation != epoch) return error.Stale;
        const node = if (self.pending.?.detached) null else if (job.operation == 1) try self.find(job.token, epoch, job.request.kind) else self.pending.?.node;
        if (node) |value| try self.remove(value);
        try self.finish(if (job.operation == 1) 1 else a.gfx_queue_error_device_lost, if (job.operation == 1) job.token else .{}, 0);
        return false;
    }
};
