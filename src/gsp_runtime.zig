// Nouveau/drivers/gpu/drm/nouveau/nvkm/subdev/gsp/rm/r570/client.c
// /* SPDX-License-Identifier: MIT
//  *
//  * Copyright (c) 2025, NVIDIA CORPORATION. All rights reserved.
//  */
//
// Original Linux MIT license text:
// MIT License
//
// Copyright (c) <year> <copyright holders>
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
//! Resident post-INIT_DONE owner for RM discovery, object creation and events.
//! Queue work is serialized; object handles do not imply native display takeover.
//! Every message uses the actual retained native port and its exact receipt.
const std = @import("std");
const r4os = @import("r4os");
const native = @import("gsp_sequencer_port.zig");
const boot = @import("gsp_boot_events.zig");
const exchange = @import("gsp_exchange.zig");
const events = @import("gsp_runtime_events.zig");
const logs = @import("gsp_logs.zig");
const init = @import("gsp_init.zig");
const static = @import("gsp_static.zig");
const postinit = @import("gsp_postinit.zig");
const rm = @import("gsp_rm_graph.zig");
const display = @import("gsp_display_rpc.zig");
const subscriptions = @import("gsp_event_objects.zig");
const outputs = @import("gsp_outputs.zig");
const inventory = @import("gsp_memory_inventory.zig");
pub const buffer_mapping = @import("gsp_buffer_mapping.zig");
pub const vram = @import("gsp_vram.zig");
pub const BufferHandle = struct { epoch: u64, serial: u64, slot: u16 };
pub const BufferStatus = struct { state: buffer_mapping.State, info: ?buffer_mapping.Info, rejected: ?u32, host_rejected: ?buffer_mapping.Error };
const BufferSlot = struct { owner: ?*buffer_mapping.Owner = null, allocation: r4os.abi.DriverHeapAllocation = .{}, heap: ?r4os.r4dev.DriverHeapContext = null, serial: u64 = 0 };
pub const NativeBufferStatus = struct { state: vram.State, info: ?vram.Info, rejected: ?u32, host_rejected: ?i32 };
const NativeBufferSlot = struct { owner: ?*vram.Owner = null, allocation: r4os.abi.DriverHeapAllocation = .{}, heap: ?r4os.r4dev.DriverHeapContext = null, serial: u64 = 0 };
pub const Progress = enum { idle, progress };
pub const Snapshot = struct {
    polls: u64 = 0,
    events: u64 = 0,
    sequencers: u64 = 0,
    xid_count: u64 = 0,
    last_xid: u32 = 0,
    nocat_count: u64 = 0,
    raw_words: u64 = 0,
    lost_words: u64 = 0,
    moving_logs: u64 = 0,
    last_poll_ns: u64 = 0,
    last_event_ns: u64 = 0,
    hotplug_events: u64 = 0,
    dp_irq_events: u64 = 0,
};
pub const Owner = struct {
    self_address: usize = 0,
    ctx: ?r4os.r4dev.DriverContext = null,
    device: ?*native.Port = null,
    reader: ?*logs.Reader = null,
    channel: ?exchange.Exchange = null,
    ordinary: ?events.Dispatch = null,
    sequence: native.RuntimeSequencer = .{},
    epoch: u64 = 0,
    adapter_id: u32 = 0,
    last_clock: u64 = 0,
    next_log: u64 = 0,
    log_index: usize = 0,
    snapshot: Snapshot = .{},
    failure: ?anyerror = null,
    protocol_failure: ?exchange.Error = null,
    static_request: [static.payload_bytes]u8 = @splat(0),
    static_info: ?static.Info = null,
    reservation: ?*const @import("boot_vram_lease.zig").Lease = null,
    memory_inventory: inventory.Owner = .{},
    physical_bytes: u64 = 0,
    startup_deadline: u64 = 0,
    post: postinit.Owner = .{},
    rm_enabled: bool = false, // Set by the real device only after IRQ installation.
    graph: ?rm.Owner = null,
    display_object: ?display.Object = null,
    rm_rejection: ?u32 = null,
    outputs: outputs.Owner = .{},
    output_refresh: bool = false,
    output_generation: u64 = 0,
    output_next_ns: u64 = 0,
    buffers: [256]BufferSlot = @splat(.{}),
    buffer_active: ?u16 = null,
    buffer_serial: u64 = 0,
    native_buffers: [256]NativeBufferSlot = @splat(.{}),
    native_active: ?u16 = null,
    graph_closing: bool = false,
    close_deadline: u64 = 0,
    words: [logs.output_bytes]u8 = undefined,

    pub fn open(self: *Owner, ctx: *const r4os.r4dev.DriverContext, device: *native.Port,
        handoff: *boot.Handoff, reader: *logs.Reader, reservation: *const @import("boot_vram_lease.zig").Lease, deadline: u64) !void
    {
        if (self.self_address != 0) return error.Busy;
        if (self.adapter_id == 0) return error.Binding;
        if (device.phase != .runtime or device.runtime_session != handoff.session or
            reader.memory == null or device.owner == null or device.owner.?.queue_memory != reader.memory or
            reader.generation() != handoff.session.epoch or !reader.enabled or reader.busy or
            reservation.backing != reader.memory.?.boot_storage) return error.Binding;
        self.self_address = @intFromPtr(self);
        self.ctx = ctx.*;
        self.device = device;
        self.reader = reader;
        self.reservation = reservation;
        self.epoch = handoff.session.epoch;
        self.startup_deadline = deadline;
        errdefer |err| self.failure = err;
        self.channel = try exchange.Exchange.init(handoff, deadline);
        const opened_at = try self.now();
        self.next_log = opened_at +| std.time.ns_per_s;
        self.physical_bytes = (device.owner.?.queue_memory.?.boot_storage.?.vram_plan orelse return error.Binding).fb_bytes;
        // Nouveau's bare-metal570 path queries this directly after INIT_DONE;
        // no vGPU guest-version handshake is needed. One fixed request budget
        // also covers interleaved notifications and lockdown; never retry TX.
        try self.channel.?.begin(static.function, &self.static_request,
            @min(deadline, try std.math.add(u64, opened_at, 5 * std.time.ns_per_s)));
    }
    fn now(self: *Owner) !u64 {
        if (self.self_address == 0 or self.self_address != @intFromPtr(self) or self.failure != null) return error.State;
        const device = self.device orelse return error.State;
        const channel = self.activeChannel() orelse return error.State;
        if (device.phase != .runtime or device.runtime_session != channel.session or
            channel.session.epoch != self.epoch or channel.session.port.generation(channel.session.port.context) != self.epoch) return error.Stale;
        const current = channel.session.port.now_ns(channel.session.port.context);
        if (current == std.math.maxInt(u64) or current < self.last_clock) return error.Clock;
        self.last_clock = current;
        return current;
    }
    pub fn step(self: *Owner) !Progress {
        if (self.self_address == 0 or self.self_address != @intFromPtr(self) or self.failure != null) return error.State;
        return self.advance() catch |err| {
            self.stop(err);
            return err;
        };
    }
    /// Logical shutdown invalidates every borrowed inventory and retains the
    /// existing RM/session resources. It is not physical GPU quiescence.
    pub fn stop(self: *Owner, err: anyerror) void {
        if (self.self_address == 0 or self.self_address != @intFromPtr(self) or self.failure != null) return;
        self.outputs.invalidate() catch {};
        self.memory_inventory.invalidate();
        self.failure = err;
        if (self.activeChannel()) |channel| {
            self.protocol_failure = channel.fail(error.Handler);
            // A failed token transition can leave only handed-off views.
            // They cannot ACK or poison another owner; stop the one retained
            // session explicitly while the outer device retains its DMA.
            channel.session.stop();
            if (channel.last_rpc) |rpc| self.log("NVIDIA gsp-runtime: failed={s} last-rpc={x} sequence={d} result={x} receipt={s}",
                .{@errorName(err), rpc.function, rpc.sequence, rpc.result, if (channel.session.pending != null) @as([]const u8, "retained") else "none"});
            if (self.post.self_address != 0 and self.post.state != .complete)
                self.log("NVIDIA gsp-postinit: failed={s} command={x} status={x} replies={d}",
                    .{@errorName(err), @intFromEnum(self.post.command), self.post.last_status orelse exchange.message.pending, self.post.replies});
        }
        if (self.graph) |*graph| {
            if (graph.state != .finished) graph.base.exchange.session.rm_names.retain(graph.reservation) catch {};
            self.log("NVIDIA gsp-rm: failed={s} state={s} client={x} rejection={?}",
                .{@errorName(err), @tagName(graph.state), graph.reservation.client, self.rm_rejection});
            if (graph.control_buffer) |*owner|
                self.log("NVIDIA gsp-control: failed={s} operation={s} reply={?} registered={} allocated={} mapped={} retained={}",
                    .{@errorName(err), if (owner.caps_active) "memory-caps" else if (owner.operation) |operation| @tagName(operation) else "none", owner.last_status,
                        owner.registered, owner.allocated, owner.mapped, owner.backing.retained});
        }
    }
    pub fn activeChannel(self: *Owner) ?*exchange.Exchange {
        if (self.native_active) |index| if (self.native_buffers[index].owner) |owner| return &owner.exchange;
        if (self.buffer_active) |index| if (self.buffers[index].owner) |owner| return &owner.exchange;
        if (self.outputs.channel()) |channel| return &channel.exchange;
        if (self.graph) |*graph| if (graph.channel()) |channel| return channel;
        return if (self.channel) |*channel| channel else null;
    }
    pub fn nativeObject(self: *Owner) ?display.Object {
        if (self.self_address != @intFromPtr(self) or self.failure != null or self.graph == null or
            self.graph.?.self_address != @intFromPtr(&self.graph.?) or self.graph.?.state != .loaned or
            self.display_object == null or self.channel == null or self.activeChannel() != &self.channel.? or
            self.channel.?.session.state != .active) return null;
        return self.display_object;
    }
    pub fn nativeOutputs(self: *Owner) ?*const outputs.Snapshot {
        _ = self.now() catch return null;
        if (self.nativeObject() == null) return null;
        return self.outputs.snapshot();
    }
    pub fn nativeMemory(self: *Owner) ?*const inventory.Summary {
        _ = self.now() catch return null;
        return self.memory_inventory.snapshot();
    }
    pub fn nativeAddressSpace(self: *Owner) ?*const @import("gsp_vaspace.zig").Info {
        _ = self.now() catch return null;
        if (self.nativeObject() == null) return null;
        const owner = if (self.graph.?.address_space) |*value| value else return null;
        if (owner.self_address != @intFromPtr(owner) or owner.state != .handed_off or owner.exchange.session.state != .active) return null;
        return if (owner.info) |*info| info else null;
    }
    pub fn nativeMemoryCapabilities(self: *Owner) ?@import("gsp_memory_caps.zig").Info {
        const space = self.nativeAddressSpace() orelse return null;
        const owner = if (self.graph.?.control_buffer) |*value| value else return null;
        if (owner.adapter != self.adapter_id or !std.meta.eql(owner.binding.space, space.*)) return null;
        return owner.memoryCapabilities();
    }
    pub fn nativeControlBuffer(self: *Owner) ?@import("gsp_control_buffer.zig").Info {
        const space = self.nativeAddressSpace() orelse return null;
        const owner = if (self.graph.?.control_buffer) |*value| value else return null;
        if (owner.adapter != self.adapter_id or owner.backing.adapter != self.adapter_id or
            owner.backing.epoch != self.epoch or !std.meta.eql(owner.binding.space, space.*)) return null;
        return owner.info();
    }
    /// Called by the serialized native engine worker after queue.take. The
    /// common queue authenticates the full job/driver generation and supplies
    /// the reference; diagnostic buffer IDs are never imported here.
    pub fn mapQueuedBuffer(self: *Owner, fence: *const r4os.abi.GfxFence, which: u32, deadline: u64) !BufferHandle {
        _ = try self.now();
        if (self.graph_closing or self.native_active != null or self.buffer_active != null or self.sequence.self_address != 0 or self.outputs.active()) return error.Busy;
        const space = (self.nativeAddressSpace() orelse return error.State).*;
        if (self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        try self.channel.?.guard(deadline);
        const serial = try std.math.add(u64, self.buffer_serial, 1);
        const index: u16 = blk: {
            for (&self.buffers, 0..) |*slot, i| if (slot.allocation.handle == 0) break :blk @intCast(i);
            return error.Exhausted;
        };
        const heap = self.ctx.?.heap() orelse return error.Api;
        const memory = self.ctx.?.memory() orelse return error.Api;
        const queue = self.ctx.?.graphicsQueue() orelse return error.Api;
        const slot = &self.buffers[index];
        slot.heap = heap;
        const result = heap.allocate(@sizeOf(buffer_mapping.Owner), @alignOf(buffer_mapping.Owner), &slot.allocation);
        const allocation = slot.allocation;
        if (result != r4os.abi.driver_heap_ok and allocation.handle == 0) return error.Memory;
        if (allocation.version != 1 or allocation.size < @sizeOf(r4os.abi.DriverHeapAllocation) or allocation.handle == 0 or
            allocation.cpu_address == 0 or allocation.cpu_address % @alignOf(buffer_mapping.Owner) != 0 or allocation.reserved != 0 or
            allocation.byte_length < @sizeOf(buffer_mapping.Owner) or allocation.alignment < @alignOf(buffer_mapping.Owner) or
            allocation.cpu_address > std.math.maxInt(u64) - allocation.byte_length) {
            self.stop(error.Descriptor);
            return error.Descriptor;
        }
        errdefer {
            if (heap.release(allocation.handle) == r4os.abi.driver_heap_ok) slot.* = .{} else self.stop(error.Retained);
        }
        if (result != r4os.abi.driver_heap_ok) return error.Memory;
        var source: r4os.abi.GfxBufferReference = .{};
        if (queue.retainResource(fence, which, &source) != r4os.abi.gfx_buffer_result_ok) return error.Resource;
        errdefer if (memory.bufferRelease(&source.reference) != r4os.abi.gfx_buffer_result_ok) self.stop(error.Retained);
        var token = try self.channel.?.handoff(deadline);
        const value = buffer_mapping.Owner.init(&token, &self.ctx.?, self.adapter_id, space, self.graph.?.reservation, source, deadline) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| {
                self.stop(restore);
                return restore;
            };
            return err;
        };
        const owner: *buffer_mapping.Owner = @ptrFromInt(allocation.cpu_address);
        owner.* = value;
        slot.owner = owner;
        slot.serial = serial;
        self.buffer_serial = serial;
        self.buffer_active = index;
        return .{ .epoch = self.epoch, .serial = serial, .slot = index };
    }
    fn findBuffer(self: *Owner, handle: BufferHandle) !*buffer_mapping.Owner {
        _ = try self.now();
        if (handle.epoch != self.epoch or handle.slot >= self.buffers.len or handle.serial == 0 or
            self.buffers[handle.slot].serial != handle.serial) return error.Stale;
        return self.buffers[handle.slot].owner orelse return error.Stale;
    }
    pub fn bufferStatus(self: *Owner, handle: BufferHandle) !BufferStatus {
        const owner = try self.findBuffer(handle);
        return .{ .state = owner.state, .info = owner.info(), .rejected = owner.rejected, .host_rejected = owner.host_rejected };
    }
    pub fn retireBuffer(self: *Owner, handle: BufferHandle, deadline: u64, quiesced: bool) !void {
        const owner = try self.findBuffer(handle);
        if (!quiesced or self.native_active != null or self.buffer_active != null or self.outputs.active() or self.sequence.self_address != 0 or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        if (owner.state != .handed_off) return error.State;
        var token = try self.channel.?.handoff(deadline);
        owner.beginDestroy(&token, deadline, quiesced) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| {
                self.stop(restore);
                return restore;
            };
            return err;
        };
        self.buffer_active = handle.slot;
    }
    /// Returns a runtime handle immediately; nativeBufferStatus publishes a
    /// borrowed driver reference only after RM allocation/map ACKs and common
    /// commit. Consumers import that reference through the common API.
    pub fn allocateNativeBuffer(self: *Owner, bytes: u64, deadline: u64) !BufferHandle {
        _ = try self.now();
        if (self.graph_closing or self.native_active != null or self.buffer_active != null or self.sequence.self_address != 0 or self.outputs.active()) return error.Busy;
        const space = (self.nativeAddressSpace() orelse return error.State).*;
        if (self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        try self.channel.?.guard(deadline);
        const serial = try std.math.add(u64, self.buffer_serial, 1);
        const index: u16 = blk: {
            for (&self.native_buffers, 0..) |*slot, i| if (slot.allocation.handle == 0) break :blk @intCast(i);
            return error.Exhausted;
        };
        const heap = self.ctx.?.heap() orelse return error.Api;
        const slot = &self.native_buffers[index];
        slot.heap = heap;
        const result = heap.allocate(@sizeOf(vram.Owner), @alignOf(vram.Owner), &slot.allocation);
        const allocation = slot.allocation;
        if (result != r4os.abi.driver_heap_ok and allocation.handle == 0) return error.Memory;
        if (allocation.version != 1 or allocation.size < @sizeOf(r4os.abi.DriverHeapAllocation) or allocation.handle == 0 or
            allocation.cpu_address == 0 or allocation.cpu_address % @alignOf(vram.Owner) != 0 or allocation.reserved != 0 or
            allocation.byte_length < @sizeOf(vram.Owner) or allocation.alignment < @alignOf(vram.Owner) or
            allocation.cpu_address > std.math.maxInt(u64) - allocation.byte_length) {
            self.stop(error.Descriptor); return error.Descriptor;
        }
        errdefer if (heap.release(allocation.handle) == r4os.abi.driver_heap_ok) { slot.* = .{}; } else self.stop(error.Retained);
        if (result != r4os.abi.driver_heap_ok) return error.Memory;
        var token = try self.channel.?.handoff(deadline);
        const value = vram.Owner.init(&token, &self.ctx.?, self.adapter_id, space, self.graph.?.reservation, bytes, deadline) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| { self.stop(restore); return restore; };
            return err;
        };
        const owner: *vram.Owner = @ptrFromInt(allocation.cpu_address);
        owner.* = value; slot.owner = owner; slot.serial = serial;
        self.buffer_serial = serial; self.native_active = index;
        return .{ .epoch = self.epoch, .serial = serial, .slot = index };
    }
    fn findNativeBuffer(self: *Owner, handle: BufferHandle) !*vram.Owner {
        _ = try self.now();
        if (handle.epoch != self.epoch or handle.slot >= self.native_buffers.len or handle.serial == 0 or
            self.native_buffers[handle.slot].serial != handle.serial) return error.Stale;
        return self.native_buffers[handle.slot].owner orelse return error.Stale;
    }
    pub fn nativeBufferStatus(self: *Owner, handle: BufferHandle) !NativeBufferStatus {
        const owner = try self.findNativeBuffer(handle);
        return .{ .state = owner.state, .info = owner.info(), .rejected = owner.rejected, .host_rejected = owner.host_rejected };
    }
    pub fn releaseNativeBuffer(self: *Owner, handle: BufferHandle) !void {
        const owner = try self.findNativeBuffer(handle);
        try owner.closeReference();
        if (!owner.common_live and !owner.namespace_live) try self.freeNativeSlot(handle.slot);
    }
    fn freeNativeSlot(self: *Owner, index: usize) !void {
        const slot = &self.native_buffers[index];
        const heap = slot.heap orelse return error.Api;
        if (heap.release(slot.allocation.handle) != r4os.abi.driver_heap_ok) return error.Retained;
        slot.* = .{};
    }
    fn collectNativeBuffer(self: *Owner, deadline: u64) !bool {
        if (self.native_active != null or self.buffer_active != null or self.outputs.active() or self.sequence.self_address != 0 or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return false;
        const memory = blk: {
            for (&self.native_buffers) |*slot| if (slot.owner) |owner| { if (owner.closing and owner.common_live) break :blk owner.memory; };
            return false;
        };
        var ticket: r4os.abi.GfxOwnedBufferRelease = .{};
        const result = memory.bufferTakeRelease(self.adapter_id, self.epoch, &ticket);
        if (result == r4os.abi.gfx_buffer_error_busy) return false;
        if (result != r4os.abi.gfx_buffer_result_ok) return error.Retained;
        for (&self.native_buffers, 0..) |*slot, index| if (slot.owner) |owner| {
            if (!owner.accepts(ticket)) continue;
            var token = try self.channel.?.handoff(deadline);
            try owner.beginDestroy(&token, ticket, deadline);
            self.native_active = @intCast(index); return true;
        };
        return error.Descriptor; // Claimed unknown identity remains held.
    }
    /// Requires all engine users independently quiesced. Each child mapping
    /// is drained before graph.beginDestroy may send any parent/event free.
    pub fn beginDestroyGraph(self: *Owner, deadline: u64, quiesced: bool) !void {
        _ = try self.now();
        if (!quiesced or self.graph_closing or self.native_active != null or self.buffer_active != null or self.outputs.active() or
            self.sequence.self_address != 0 or self.nativeObject() == null or self.channel.?.phase != .idle) return error.Busy;
        try self.channel.?.guard(deadline);
        for (&self.native_buffers, 0..) |*slot, index| if (slot.owner != null) {
            try self.releaseNativeBuffer(.{ .epoch = self.epoch, .serial = slot.serial, .slot = @intCast(index) });
        };
        self.graph_closing = true;
        self.close_deadline = deadline;
    }
    pub fn takeDisplayChanges(self: *Owner) !subscriptions.Changes {
        const current = try self.now();
        if (self.nativeObject() == null) return error.State;
        return self.graph.?.takeChanges(try std.math.add(u64, current, std.time.ns_per_s));
    }
    fn advance(self: *Owner) !Progress {
        const current = try self.now();
        const channel = self.activeChannel() orelse return error.State;
        self.snapshot.polls +|= 1;
        self.snapshot.last_poll_ns = current;
        if (self.sequence.self_address != 0) {
            if (try self.sequence.step() == .complete) {
                if (!self.sequence.close()) return error.Retained;
                self.snapshot.sequencers +|= 1;
                self.snapshot.events +|= 1;
                self.snapshot.last_event_ns = current;
            }
            return .progress;
        }
        if (self.native_active) |index| {
            const owner = self.native_buffers[index].owner orelse return error.State;
            if (owner.state == .ready or owner.state == .closed) {
                const deadline = owner.deadline;
                var token = try owner.handoff();
                self.channel = try exchange.Exchange.init(&token, deadline);
                if (owner.state == .finished) try self.freeNativeSlot(index);
                self.native_active = null;
                return .progress;
            }
            if (try owner.poll()) |dispatch| {
                try self.notification(&owner.exchange, dispatch, current);
                return .progress;
            }
            return if (owner.exchange.phase == .waiting) .idle else .progress;
        }
        if (self.buffer_active) |index| {
            const slot = &self.buffers[index];
            const owner = slot.owner orelse return error.State;
            if (owner.state == .ready or owner.state == .closed) {
                var token = try owner.handoff(owner.deadline);
                self.channel = try exchange.Exchange.init(&token, owner.deadline);
                if (owner.state == .finished) {
                    const heap = slot.heap orelse return error.Api;
                    if (heap.release(slot.allocation.handle) != r4os.abi.driver_heap_ok) return error.Retained;
                    slot.* = .{};
                }
                self.buffer_active = null;
                return .progress;
            }
            if (try owner.poll()) |dispatch| {
                try self.notification(&owner.exchange, dispatch, current);
                return .progress;
            }
            return if (owner.exchange.phase == .waiting) .idle else .progress;
        }
        if (self.nativeObject() != null and try self.collectNativeBuffer(if (self.graph_closing) self.close_deadline else try std.math.add(u64, current, 5 * std.time.ns_per_s))) return .progress;
        if (self.graph_closing and self.graph.?.state == .loaned) graph_close: {
            try channel.guard(self.close_deadline);
            for (&self.buffers, 0..) |*slot, index| if (slot.owner != null) {
                try self.retireBuffer(.{ .epoch = self.epoch, .serial = slot.serial, .slot = @intCast(index) }, self.close_deadline, true);
                return .progress;
            };
            for (&self.native_buffers) |*slot| if (slot.owner != null) break :graph_close;
            var token = try channel.handoff(self.close_deadline);
            try self.graph.?.reclaim(&token, self.close_deadline);
            try self.graph.?.beginDestroy(self.close_deadline);
            return .progress;
        }
        if (self.outputs.active()) {
            if (self.outputs.state == .complete or self.outputs.state == .obsolete) {
                var loan = try self.graph.?.loan(self.outputs.deadline);
                self.channel = try exchange.Exchange.init(&loan.runtime, self.outputs.deadline);
                try self.outputs.returned(current);
                self.output_next_ns = try std.math.add(u64, current, std.time.ns_per_s);
                self.log("NVIDIA gsp-outputs: generation={d} inventory={s} routes={d} receivers={d} native-output=unavailable",
                    .{self.output_generation, if (!self.outputs.data.coherent) @as([]const u8, "obsolete") else if (self.outputs.data.topology.rejected != null) "query-rejected" else "complete",
                        self.outputs.data.topology.count, self.outputs.data.count});
                if (self.outputs.data.final_rejection orelse self.outputs.data.topology.rejected) |rejected|
                    self.log("NVIDIA gsp-outputs: rejected command={x} rpc={?} rm={?}", .{@intFromEnum(rejected.command), rejected.rpc, rejected.control});
                if (self.outputs.data.coherent) {
                    const catalog = &self.outputs.data.topology;
                    self.log("NVIDIA gsp-heads: generation={d} count={?} observation=queried lease=no", .{self.output_generation, catalog.head_count});
                    for (catalog.routes[0..catalog.count]) |*route| {
                        self.log("NVIDIA gsp-route: display={x} active-heads={?} or={?} dcb-slot={?} ddc-port={?} communication-port={?}",
                            .{route.id, catalog.activeHeads(route.id), if (route.resource) |resource| resource.index else null,
                                if (route.resource) |resource| resource.dcb_index else null, if (route.buses) |buses| buses.ddc else null,
                                if (route.buses) |buses| buses.communication else null});
                        const wire = &route.wiring;
                        self.log("NVIDIA gsp-wire: display={x} relation={s} physical={s} rm-connector={?} heads={s} encoder={s} protocol={s}",
                            .{route.id, @tagName(wire.relation), @tagName(wire.physical_status),
                                if (wire.physical) |physical| @as(?u32, physical.index) else null,
                                @tagName(wire.heads), @tagName(wire.encoder), @tagName(wire.protocol)});
                        if (wire.relation == .static) {
                            const port = &wire.relation.static;
                            self.log("NVIDIA gsp-bus: display={x} dcb={d} connector={d} ccb={d} pmgr-i2c={?} pmgr-aux={?} assignment={s} mask={x} links={?}",
                                .{route.id, port.index, port.connector, port.ccb, port.i2c, port.aux, @tagName(port.assignment), port.output_mask, port.link_mask});
                            for (&wire.hpd) |*signal| if (signal.*) |hpd|
                                self.log("NVIDIA gsp-hpd: display={x} function={d} status={s} pin={?} active-high={?} level=unread",
                                    .{route.id, hpd.function, @tagName(hpd.status), hpd.line, hpd.active_high});
                            for (&wire.external_dongle, 0..) |*signal, bit| if (signal.*) |dongle|
                                self.log("NVIDIA gsp-xpio: display={x} dp-dvi={d} status={s} table={?} pin={?} level=unread",
                                    .{route.id, bit, @tagName(dongle.status), dongle.table, dongle.line});
                        } else if (wire.relation == .dynamic)
                            self.log("NVIDIA gsp-root: display={x} root={x} physical=not-inferred", .{route.id, wire.relation.dynamic});
                    }
                }
                return .progress;
            }
            const before = self.outputs.data.count;
            if (try self.outputs.poll()) |dispatch| {
                const source = self.outputs.channel() orelse return error.State;
                try self.notification(&source.exchange, try source.exchange.borrow(dispatch.ticket), current);
                return .progress;
            }
            if (self.outputs.data.count != before) {
                const capture = &self.outputs.data.receivers[before];
                self.log("NVIDIA gsp-receiver: candidate generation={d} display={x} status={s} edid={d} modes={d} audio={d} warnings={x} rpc={?} rm={?} source={s}",
                    .{self.output_generation, capture.display_id, @tagName(capture.status), capture.edid_bytes,
                        capture.report.mode_count, capture.report.audio_count, capture.report.warnings, capture.rpc_status, capture.control_status, @tagName(capture.source)});
                if (capture.buses != null or capture.ddc_rpc_status != null or capture.ddc_control_status != null)
                    self.log("NVIDIA gsp-ddc: generation={d} display={x} port={?} flags={?} retries={d} rpc={?} rm={?}",
                        .{self.output_generation, capture.display_id, if (capture.buses) |buses| @as(?u32, buses.ddc) else null,
                            capture.port_info, capture.ddc_retries, capture.ddc_rpc_status, capture.ddc_control_status});
                if (capture.source == .aux or capture.aux_rpc_status != null or capture.aux_control_status != null or capture.aux_reply != null)
                    self.log("NVIDIA gsp-aux: generation={d} display={x} dpcd={d} retries={d} rpc={?} rm={?} reply={?}",
                        .{self.output_generation, capture.display_id, capture.aux_caps_bytes, capture.aux_retries,
                            capture.aux_rpc_status, capture.aux_control_status,
                            if (capture.aux_reply) |reply| @as(?u32, @intFromEnum(reply)) else null});
            }
            if (self.outputs.refresh) |*refresh| if (refresh.waiting()) return .idle;
            return if ((self.activeChannel() orelse return error.State).phase == .waiting) .idle else .progress;
        }
        if (self.graph) |*graph| {
            switch (graph.state) {
                .ready => {
                    var loan = try graph.loan(graph.deadline);
                    self.channel = try exchange.Exchange.init(&loan.runtime, graph.deadline);
                    self.display_object = loan.object;
                    self.log("NVIDIA gsp-rm: objects=ready client={x} device={x} subdevice={x} display={x} events=HPD,DP native-output=unavailable",
                        .{graph.base.plan.handles.client, graph.base.plan.handles.device, graph.base.plan.handles.subdevice, loan.object.display});
                    if (self.nativeAddressSpace()) |info|
                        self.log("NVIDIA gsp-vaspace: handle={x} base={x} bytes={x} big-page={d} page-tables=RM app-mappings=none",
                            .{info.handle, info.base, info.bytes, info.big_page_bytes})
                    else self.log("NVIDIA gsp-vaspace: unavailable rm={?} receiver-inventory=available", .{graph.address_space.?.rejected});
                    if (self.nativeMemoryCapabilities()) |caps|
                        self.log("NVIDIA gsp-memory-caps: raw={x},{x},{x} system-render={} system-scanout={} gpu-cache={} blocklinear={} gob-bytes={d} generic-kind={x} engines=unqualified",
                            .{caps.raw[0], caps.raw[1], caps.raw[2], caps.renderSystem(), caps.scanoutSystem(), caps.gpuCachedSystem(), caps.blocklinear(), caps.gobBytes(), caps.genericPageKind()})
                    else self.log("NVIDIA gsp-memory-caps: unavailable native-layouts=unqualified", .{});
                    if (self.nativeControlBuffer()) |info|
                        self.log("NVIDIA gsp-control: memory={x} virtual={x} gpu-va={x} bytes={d} backing=BO pages=system-linear gpu-cache=disabled channels=none",
                            .{info.memory, info.virtual, info.address, info.bytes})
                    else if (graph.control_buffer) |*owner|
                        self.log("NVIDIA gsp-control: unavailable rm={?} host={s} receiver-inventory=available",
                            .{owner.rejected, if (owner.host_rejected) |err| @errorName(err) else "none"});
                    return .progress;
                },
                .rejected => {
                    // A validated RM rejection was ACKed by its exact owner.
                    // Destroy only the proven live prefix, in reverse order.
                    const status = if (graph.subscriptions) |*owner| blk: {
                        const result = owner.last_status orelse return error.State;
                        break :blk if (result.result == .rm_error) result.result.rm_error else return error.State;
                    } else blk: {
                        const result = graph.base.last_status orelse return error.State;
                        break :blk if (result.result == .rm_error) result.result.rm_error else return error.State;
                    };
                    self.rm_rejection = status;
                    const end = @min(self.startup_deadline, try std.math.add(u64, current, 5 * std.time.ns_per_s));
                    self.log("NVIDIA gsp-rm: rejected status={x} cleanup=proven-objects deadline-ns={d}", .{status, end});
                    try graph.beginDestroy(end);
                    return .progress;
                },
                .closed => {
                    var token = try graph.finish(graph.deadline);
                    self.channel = try exchange.Exchange.init(&token, graph.deadline);
                    return if (self.graph_closing) error.RmClosed else error.RmRejected; // Object frees do not stop GPU DMA.
                },
                .base_creating, .i2c_creating, .vaspace_creating, .control_creating, .events_creating, .events_destroying, .control_destroying, .vaspace_destroying, .i2c_destroying, .base_destroying => {
                    if (try graph.poll()) |dispatch| {
                        try self.notification(self.activeChannel() orelse return error.State, dispatch, current);
                        return .progress;
                    }
                    return if ((self.activeChannel() orelse return error.State).phase == .waiting) .idle else .progress;
                },
                .loaned => {},
                else => return error.State,
            }
        }
        if (self.static_info != null and self.post.state != .complete and channel.phase == .idle) {
            if (self.post.self_address == 0) try self.post.open(channel, &self.static_info.?);
            const end = @min(self.startup_deadline, try std.math.add(u64, current, 5 * std.time.ns_per_s));
            try self.post.prepare(end);
            self.log("NVIDIA gsp-postinit: command={x} gpc={d} deadline-ns={d}", .{@intFromEnum(self.post.command), self.post.gpc, end});
            return .progress;
        }
        // A fresh idle observation gets a new bound. Pending messages and
        // sequencer phases keep their original deadline across rescheduling.
        const deadline = channel.deadline orelse (std.math.add(u64, current, std.time.ns_per_s) catch return error.Clock);
        if (try channel.poll(deadline)) |dispatch| {
            if (dispatch.response) {
                if (self.static_info != null) {
                    try self.post.accept(dispatch);
                    if (self.post.snapshot()) |info|
                        self.log("NVIDIA gsp-postinit: gpcs={d} tpcs={d} intr-entries={d} gsp-stall={d} irq=awaiting-owner native-output=unavailable",
                            .{@popCount(info.gpc_mask), info.tpc_count, info.entry_count, info.entries[info.gsp_index.?].stall});
                    return .progress;
                }
                if (channel.function != static.function) return error.Unexpected;
                const info = try static.decode(dispatch.record, self.physical_bytes);
                try self.memory_inventory.prepare(self.reservation.?, &info, self.epoch);
                try channel.complete(dispatch.ticket);
                self.static_info = info; // Publish no observation before a successful ACK.
                try self.memory_inventory.publish();
                self.log("NVIDIA gsp-static: client={x} device={x} subdevice={x} fb-bytes={d} regions={d} bar1-pdb={x} bar2-pdb={x}",
                    .{info.client, info.device, info.subdevice, info.fb_bytes, info.region_count, info.bar1_pdb, info.bar2_pdb});
                self.logMemory();
                return .progress;
            }
            try self.notification(channel, dispatch, current);
            return .progress;
        }
        if (self.rm_enabled and self.graph == null and self.post.snapshot() != null and channel.phase == .idle and !channel.in_lockdown) {
            const end = @min(self.startup_deadline, try std.math.add(u64, current, 5 * std.time.ns_per_s));
            var token = try channel.handoff(end);
            // Nouveau r570's kernel client uses processID=~0 and an empty
            // name. This is not a fabricated R4OS program or host pointer.
            self.graph = try rm.Owner.init(&token, std.math.maxInt(u32), "", end);
            self.graph.?.control_context = self.ctx;
            self.graph.?.control_adapter = self.adapter_id;
            self.log("NVIDIA gsp-rm: creating client={x} deadline-ns={d}", .{self.graph.?.reservation.client, end});
            return .progress;
        }
        if (!self.graph_closing and self.graph != null and self.graph.?.state == .loaned and channel.phase == .idle and !channel.in_lockdown and
            (self.outputs.state == .detached or (self.output_refresh and current >= self.output_next_ns))) {
            const end = try std.math.add(u64, current, 10 * std.time.ns_per_s);
            self.output_generation = try std.math.add(u64, self.output_generation, 1);
            var token = try channel.handoff(end);
            try self.graph.?.reclaim(&token, end);
            try self.outputs.begin(&self.graph.?, self.output_generation, end);
            self.output_refresh = false;
            self.log("NVIDIA gsp-outputs: acquiring generation={d} deadline-ns={d}", .{self.output_generation, end});
            return .progress;
        }
        // No busy wait or raw-log dump on every empty queue. One ring per
        // second bounds DMA copying and output, even under continual logging.
        if (current >= self.next_log and self.reader.?.enabled) {
            self.next_log = current +| std.time.ns_per_s;
            try self.captureLog(deadline);
        }
        return .idle;
    }
    fn logMemory(self: *Owner) void {
        const data = self.nativeMemory() orelse return;
        self.log("NVIDIA gsp-memory: epoch={d} physical={d} reported={d} regions={d} holes={d} rm-budget={d} retained={d} screened={d} allocation=none",
            .{data.epoch, data.physical_bytes, data.reported_bytes, data.region_count, data.region_holes,
                data.speculative_reserved, data.retained_bytes, data.screened_bytes});
        self.log("NVIDIA gsp-memory: union={d} surface-extents={d} table-pages={d} instance={any} payload-extents={d} firmware-layout-matches={any}",
            .{data.retained_count, data.surface_extents, data.table_pages, data.instance_active, data.payload_extents, data.firmware_layout_matches});
        for (data.windows) |bar|
            self.log("NVIDIA gsp-aperture: pci-bar={d} base={x} bytes={d} status={s} prefetch={any} rebar-present={any} resize=no",
                .{bar.pci_index, bar.base, bar.bytes, @tagName(bar.status), bar.prefetchable, data.rebar_present});
        for (self.memory_inventory.regions[0..data.region_count], 0..) |*region, index|
            self.log("NVIDIA gsp-region: index={d} base={x} bytes={d} rm-budget={d} protected={any} iso={any} compressed={any} performance={d}",
                .{index, region.base, region.bytes, region.reserved, region.protected, region.iso, region.compressed, region.performance});
    }
    fn notification(self: *Owner, channel: *exchange.Exchange, dispatch: exchange.Dispatch, current: u64) !void {
        if (dispatch.response) return error.Unexpected;
        const source = self.outputs.channel();
        if (source != null and &source.?.exchange != channel) return error.Binding;
        if (dispatch.record.rpc.function != @intFromEnum(boot.Kind.libos_print)) try self.outputs.invalidate();
        if (dispatch.record.rpc.function == @intFromEnum(boot.Kind.cpu_sequencer)) {
            const limits = @import("gsp_sequencer.zig").Limits{
                .default_timeout_ns = std.time.ns_per_s, .poll_interval_ns = std.time.ns_per_ms,
                .register_bytes = self.device.?.window.byte_length,
            };
            if (source) |owner| try self.sequence.beginDisplay(self.device.?, owner, limits) else try self.sequence.begin(self.device.?, channel, limits);
            return;
        }
        const sink = events.Sink{
            .context = self, .generation = generation, .admit = admit, .deliver = deliver,
        };
        self.ordinary = if (source) |owner| try events.Dispatch.initDisplay(owner, sink) else try events.Dispatch.init(channel, sink);
        try self.ordinary.?.step();
        self.snapshot.events +|= 1;
        self.snapshot.last_event_ns = current;
        self.ordinary = null;
    }
    fn from(raw: *anyopaque) *Owner { return @ptrCast(@alignCast(raw)); }
    fn generation(raw: *anyopaque) u64 {
        const self = from(raw);
        _ = self.now() catch return 0;
        return self.epoch;
    }
    fn admit(raw: *anyopaque, scope: events.Scope, event: events.Event) error{ Denied, Unsupported }!void {
        const self = from(raw);
        if (generation(raw) != scope.epoch or self.epoch != scope.epoch) return error.Denied;
        // Diagnostics/lockdown stay here. Display changes require an exact
        // live RM event registration; other effects still need their owners.
        switch (event) {
            .libos_print, .lockdown, .os_error, .nocat => {},
            .post_event => {
                const graph = if (self.graph) |*value| value else return error.Unsupported;
                const sink = graph.eventSink() catch return error.Denied;
                try sink.admit(sink.context, scope, event);
            },
            else => return error.Unsupported,
        }
    }
    fn deliver(raw: *anyopaque, scope: events.Scope, event: events.Event) !void {
        const self = from(raw);
        switch (event) {
            .libos_print => |v| self.logBytes("print", v.engine, v.bytes),
            .lockdown => {}, // Exchange owns engage-before-I/O and release-after-ACK.
            .post_event => |post| {
                const graph = if (self.graph) |*value| value else return error.Unsupported;
                const sink = try graph.eventSink();
                try sink.deliver(sink.context, scope, event);
                const kind = (try post.display()) orelse return error.Unexpected;
                self.output_refresh = true; // Coalesced; no new scan until current receipts drain.
                if (kind == .hotplug) self.snapshot.hotplug_events +|= 1 else self.snapshot.dp_irq_events +|= 1;
                self.log("NVIDIA gsp-event: kind={s} status={x} data={x} refresh=required", .{@tagName(kind), post.status, post.data});
            },
            .os_error => |v| {
                self.snapshot.xid_count +|= 1;
                self.snapshot.last_xid = v.xid;
                self.log("NVIDIA gsp-xid: xid={d} previous={d} runlist={d} channel={d}", .{v.xid, v.previous_xid, v.runlist, v.channel});
                self.logBytes("xid-text", v.xid, v.text);
            },
            .nocat => |v| {
                self.snapshot.nocat_count +|= 1;
                self.log("NVIDIA gsp-nocat: flags={x} type={d} bugcheck={x} subsystem={d} error={x} tdr={d} diagnostic-bytes={d}",
                    .{v.flags, v.record_type, v.bugcheck, v.subsystem, v.error_code, v.tdr_reason, v.diagnostic.len});
                self.logBytes("nocat-source", v.subsystem, v.source);
                self.logBytes("nocat-engine", v.subsystem, v.engine);
            },
            else => return error.Unsupported,
        }
    }
    fn captureLog(self: *Owner, deadline: u64) !void {
        const index = self.log_index;
        self.log_index = (index + 1) % init.log_count;
        const observed = self.reader.?.capture(index, deadline, &self.words) catch |err| {
            if (err == error.ProducerChanged) {
                self.snapshot.moving_logs +|= 1;
                return;
            }
            return err;
        };
        self.snapshot.raw_words +|= observed.word_count;
        self.snapshot.lost_words +|= observed.lost_words;
        if (observed.word_count != 0 or observed.lost_words != 0) {
            self.log("NVIDIA gsp-log: ring={d} first={d} next={d} words={d} lost={d} raw=uninterpreted",
                .{index, observed.first_word, observed.next_word, observed.word_count, observed.lost_words});
        }
    }
    fn log(self: *Owner, comptime format: []const u8, args: anytype) void {
        var buffer: [256]u8 = undefined;
        const line = std.fmt.bufPrintZ(&buffer, format, args) catch return;
        self.ctx.?.logInfo(line);
    }
    fn logBytes(self: *Owner, kind: []const u8, source: u32, bytes: []const u8) void {
        var escaped: [160]u8 = undefined;
        const count = @min(bytes.len, escaped.len);
        for (bytes[0..count], escaped[0..count]) |byte, *out| out.* = if (byte >= 32 and byte < 127) byte else '.';
        self.log("NVIDIA gsp-runtime: {s} source={d} bytes={d} text={s}", .{kind, source, bytes.len, escaped[0..count]});
    }
};
