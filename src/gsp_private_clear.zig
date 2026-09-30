// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Bounded CE startup qualification of one fresh private control allocation.
//! The scratch BO is never reused as allegedly fresh instance/method storage.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const runtime = @import("gsp_runtime.zig");
const control = @import("gsp_control_buffer.zig");
const storage = @import("gsp_native_backing.zig");
const ring = @import("gsp_push_ring.zig");
pub const payload_bytes = 4096;
pub const staging_bytes = 8192;
pub const Phase = enum { detached, prepare, prepared, submitted, done };
pub const Owner = struct {
    self_address: usize = 0,
    phase: Phase = .detached,
    source: ?*control.Owner = null,
    source_stamp: ?control.Info = null,
    target: storage.Use = .{},
    target_stamp: ?storage.Source = null,
    reuse: storage.Use = .{},
    channel: runtime.ChannelHandle = undefined,
    buffer: runtime.BufferHandle = undefined,
    cpu: a.GfxBufferMap = .{},
    cpu_stamp: a.GfxBufferMap = .{},
    gpu: a.GfxDeviceLease = .{},
    gpu_stamp: a.GfxDeviceLease = .{},
    ticket: ?ring.Ticket = null,
    round: u32 = 0,
    exact_bytes: u64 = 0,
    deadline: u64 = 0,
    descriptor_failed: bool = false,

    pub fn open(self: *Owner, run: *runtime.Owner, channel: runtime.ChannelHandle, buffer: runtime.BufferHandle, deadline: u64) !void {
        if (self.self_address != 0) return error.State;
        const graph = if (run.graph) |*value| value else return error.State;
        const source = if (graph.control_buffer) |*value| value else return error.State;
        const info = source.info() orelse return error.State;
        if (info.epoch != run.epoch or info.bytes < staging_bytes or !std.meta.eql(run.native_copy.channel.?, channel)) return error.Descriptor;
        self.* = .{ .self_address = @intFromPtr(self), .phase = .prepare, .source = source,
            .source_stamp = info, .channel = channel, .buffer = buffer, .deadline = deadline };
        try run.retainNativeStorage(buffer, &self.target);
        self.target_stamp = self.target.info() orelse return error.Descriptor;
        const target = self.target_stamp.?;
        if (target.bytes != payload_bytes or target.epoch != info.epoch or target.adapter != source.adapter or
            (info.address < target.address + payload_bytes and target.address < info.address + info.bytes)) return error.Descriptor;
    }
    pub fn busy(self: *const Owner) bool {
        return self.self_address != 0 and self.phase != .done;
    }
    fn valid(self: *const Owner) bool {
        return self.self_address == @intFromPtr(self) and !self.descriptor_failed and self.source != null and
            self.round < 5 and std.meta.eql(self.source.?.info(), self.source_stamp) and
            std.meta.eql(self.target.info(), self.target_stamp) and std.meta.eql(self.cpu, self.cpu_stamp) and std.meta.eql(self.gpu, self.gpu_stamp);
    }
    pub fn transfer(self: *const Owner) !ring.wire.Transfer {
        if (!self.valid() or self.cpu.lease.id != 0 or self.gpu.lease.id == 0) return error.Stale;
        return if (self.round & 1 == 0)
            .{ .source = self.target_stamp.?.address, .target = self.source_stamp.?.address + 7, .bytes = payload_bytes }
        else .{ .source = self.source_stamp.?.address, .target = self.target_stamp.?.address, .bytes = payload_bytes };
    }
    pub fn matches(self: *const Owner, ticket: ring.Ticket, deadline: u64) bool {
        return self.valid() and self.phase == .prepared and self.ticket != null and std.meta.eql(ticket, self.ticket.?) and deadline == self.deadline;
    }
    pub fn step(self: *Owner, run: *runtime.Owner, now: u64) !bool {
        if (!self.busy()) return false;
        return self.advance(run, now) catch |err| {
            if (err == error.Descriptor) self.descriptor_failed = true;
            return err;
        };
    }
    fn advance(self: *Owner, run: *runtime.Owner, now: u64) !bool {
        if (!self.valid() or self.channel.epoch != run.epoch) return error.Stale;
        if (now >= self.deadline) return error.Deadline;
        // Startup shutdown belongs to Device quarantine/reset, which keeps
        // these borrows until physical quiescence; no optimistic cancellation.
        if (run.graph_closing or run.shutdown_closing) return error.State;
        switch (self.phase) {
            .prepare => {
                try self.mapCpu(a.gfx_buffer_map_write);
                const bytes: [*]u8 = @ptrFromInt(self.cpu.cpu_address);
                @memset(bytes[0..staging_bytes], 0xa5);
                if (self.round & 1 != 0) for (bytes[0..payload_bytes], 0..) |*value, index| {
                    value.* = pattern(index, self.round);
                };
                try self.unmapCpu();
                try self.acquireSystem();
                self.phase = .prepared;
            },
            .prepared => {
                const rpc = run.activeChannel() orelse return error.State;
                if (run.power_active or run.fifo_active != null or run.context_active != null or run.native_active != null or
                    run.buffer_active != null or run.virtuals.active_range != null or run.sequence.self_address != 0 or
                    rpc.phase != .idle or rpc.pending != null or run.outputs.active()) return false;
                _ = try run.executionChannelStatus(self.channel);
                const owner = run.fifos[self.channel.slot].owner orelse return error.State;
                self.ticket = try owner.prepareCopy(try self.transfer());
                try run.device.?.submitCopy(owner, self.ticket.?, self.deadline);
                self.phase = .submitted;
            },
            .submitted => {
                _ = try run.executionChannelStatus(self.channel);
                const owner = run.fifos[self.channel.slot].owner orelse return error.State;
                if (try owner.ring.poll() < self.ticket.?.point) return false;
                if (!self.releaseSystem()) return error.Retained;
                if (self.round & 1 == 0) try self.compare();
                self.ticket = null;
                self.round += 1;
                if (self.round == 5) {
                    if (!self.target.close(true)) return error.Retained;
                    // The previous nonzero patterns cannot claim initial clear
                    // again, even after the first execution use has ended.
                    run.retainNativeStorage(self.buffer, &self.reuse) catch |err| {
                        if (err != error.Busy or self.reuse.self_address != 0) return err;
                        self.phase = .done;
                        return true;
                    };
                    return error.ReusedInitialClear;
                }
                self.phase = .prepare;
            },
            else => return error.State,
        }
        return true;
    }
    fn mapCpu(self: *Owner, access: u32) !void {
        const memory = self.source.?.backing.memory.?;
        const rc = memory.bufferMap(&self.source.?.backing.reference.reference, access, 0, self.source_stamp.?.bytes, &self.cpu);
        self.cpu_stamp = self.cpu;
        if (rc != a.gfx_buffer_result_ok and self.cpu.lease.id == 0) return error.Map;
        const cpu = self.cpu;
        if (cpu.version != 1 or cpu.size < @sizeOf(a.GfxBufferMap) or !handleValid(cpu.lease) or cpu.cpu_address == 0 or
            cpu.cpu_address & 4095 != 0 or cpu.byte_length != self.source_stamp.?.bytes or cpu.cpu_address > std.math.maxInt(u64) - cpu.byte_length or
            cpu.cache_policy != a.gfx_buffer_cache_write_back or cpu.reserved0 != 0) return error.Descriptor;
        if (rc != a.gfx_buffer_result_ok) return error.Map;
    }
    fn unmapCpu(self: *Owner) !void {
        if (!std.meta.eql(self.cpu, self.cpu_stamp) or self.source.?.backing.memory.?.bufferUnmap(&self.cpu.lease) != a.gfx_buffer_result_ok) return error.Retained;
        self.cpu = .{}; self.cpu_stamp = .{};
    }
    fn acquireSystem(self: *Owner) !void {
        const access: u32 = if (self.round & 1 == 0) 1 else 0;
        const rc = self.source.?.backing.memory.?.deviceAcquire(&self.source.?.backing.reference.reference,
            &.{ .byte_length = staging_bytes, .gpu_virtual_address = self.source_stamp.?.address,
                .adapter_id = self.source.?.adapter, .device_generation = self.source_stamp.?.epoch, .access = access, .address_space = 1 }, &self.gpu);
        self.gpu_stamp = self.gpu;
        if (rc != a.gfx_buffer_result_ok and self.gpu.lease.id == 0) return error.Memory;
        const gpu = self.gpu;
        if (gpu.version != 1 or gpu.size < @sizeOf(a.GfxDeviceLease) or !handleValid(gpu.lease) or gpu.byte_offset != 0 or
            gpu.byte_length != staging_bytes or gpu.gpu_virtual_address != self.source_stamp.?.address or gpu.adapter_id != self.source.?.adapter or
            gpu.device_generation != self.source_stamp.?.epoch or gpu.driver_owner != self.target_stamp.?.driver_owner or
            gpu.access != access or gpu.address_space != 1 or gpu.dma_mask != std.math.maxInt(u64)) return error.Descriptor;
        if (rc != a.gfx_buffer_result_ok) return error.Memory;
    }
    fn compare(self: *Owner) !void {
        try self.mapCpu(a.gfx_buffer_map_read);
        const bytes: [*]const u8 = @ptrFromInt(self.cpu.cpu_address);
        var bad: usize = 0;
        for (bytes[0..staging_bytes], 0..) |value, index| {
            const expected: u8 = if (index < 7 or index >= 7 + payload_bytes) 0xa5
                else if (self.round == 0) 0 else pattern(index - 7, self.round - 1);
            if (value != expected) bad += 1;
        }
        try self.unmapCpu();
        if (bad != 0) return error.PrivateClearBytes;
        self.exact_bytes += staging_bytes;
    }
    fn releaseSystem(self: *Owner) bool {
        if (!std.meta.eql(self.cpu, self.cpu_stamp) or !std.meta.eql(self.gpu, self.gpu_stamp)) return false;
        // Normal RM shutdown can retire the staging owner before the final
        // physical reset. A completed probe no longer borrows that owner.
        if (self.cpu.lease.id == 0 and self.gpu.lease.id == 0) return true;
        const memory = self.source.?.backing.memory.?;
        if (self.gpu.lease.id != 0) {
            if (memory.deviceRelease(&self.gpu, 1) != a.gfx_buffer_result_ok) return false;
            self.gpu = .{}; self.gpu_stamp = .{};
        }
        if (self.cpu.lease.id != 0) self.unmapCpu() catch return false;
        return true;
    }
    pub fn closeAfterReset(self: *Owner, proof: @import("gsp_reset.zig").Quiescence, epoch: u64) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or self.descriptor_failed or !proof.valid(epoch) or
            self.source_stamp == null or self.source_stamp.?.epoch != epoch) return false;
        if (!self.releaseSystem() or !self.target.closeAfterReset(proof) or !self.reuse.closeAfterReset(proof)) return false;
        self.* = .{}; return true;
    }
};
fn pattern(index: usize, round: u32) u8 {
    return @truncate((index *% 197 +% (index >> 8) *% 43 +% @as(usize, round) *% 73) ^ (index >> 4));
}
fn handleValid(value: a.GfxBufferHandle) bool { return value.id != 0 and value.generation != 0 and value.reserved0 == 0; }
