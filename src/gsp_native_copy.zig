// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Adapter-owned CE startup, independent of receiver discovery and scanout.
//! Runtime retains every RM object; this bounded worker keeps only handles.
const std = @import("std");
const runtime = @import("gsp_runtime.zig");

pub const Phase = enum {
    detached, waiting, context_start, context_wait, context_retire, context_retiring,
    methods_allocate, methods_attach, instance_allocate, channel_create, channel_wait,
    storage_wait, storage_release, register, ready,
};
pub const Owner = struct {
    self_address: usize = 0,
    phase: Phase = .detached,
    after_storage: Phase = .detached,
    context: ?runtime.ContextHandle = null,
    storage: ?runtime.BufferHandle = null,
    channel: ?runtime.ChannelHandle = null,
    rm_engine: u32 = 19,
    epoch: u64 = 0,
    last_clock: u64 = 0,
    deadline: u64 = 0,
    phase_deadline: u64 = 0,
    // The explicit recovery-to-console path needs its private CE for table
    // uploads, but intentionally exposes no application execution backend.
    publish_backend: bool = true,

    pub fn request(self: *Owner) !void {
        if (self.self_address != 0) return error.State;
        self.* = .{ .self_address = @intFromPtr(self), .phase = .waiting };
    }
    pub fn step(self: *Owner, run: *runtime.Owner) !bool {
        if (self.phase == .detached) return false;
        if (self.self_address != @intFromPtr(self) or run.failure != null) return error.State;
        if (self.phase == .ready) {
            if (self.epoch != run.epoch) return error.Stale;
            return false;
        }
        const now = (run.ctx.?.resources() orelse return error.Api).nowNs();
        if (now == 0 or now == std.math.maxInt(u64) or now < self.last_clock) return error.Clock;
        self.last_clock = now;
        if (self.phase == .waiting) {
            if (run.nativeAddressSpace() == null or run.nativeControlBuffer() == null) return false;
            self.epoch = run.epoch;
            self.deadline = try std.math.add(u64, now, 60 * std.time.ns_per_s);
            self.next(.context_start);
            return true;
        }
        if (run.epoch != self.epoch) return error.Stale;
        if (now >= self.deadline or now >= self.phase_deadline) return error.Deadline;
        return self.advance(run) catch |err| {
            if (err == error.Busy) return false;
            // The enclosing Device owns quarantine and reset. Never discard
            // a handle after an uncertain RM/GPU outcome in this helper.
            return err;
        };
    }
    fn next(self: *Owner, phase: Phase) void {
        self.phase = phase;
        self.phase_deadline = @min(self.deadline, self.last_clock +| (5 * std.time.ns_per_s));
    }
    fn allocate(self: *Owner, run: *runtime.Owner, bytes: u64, after: Phase) !void {
        if (self.storage != null) return error.State;
        self.storage = try run.allocateNativeStorage(bytes, self.phase_deadline);
        self.after_storage = after;
        self.next(.storage_wait);
    }
    fn release(self: *Owner, after: Phase) void {
        self.after_storage = after;
        self.next(.storage_release);
    }
    fn advance(self: *Owner, run: *runtime.Owner) !bool {
        switch (self.phase) {
            .context_start => {
                if (self.rm_engine > 28) return error.Unsupported;
                self.context = try run.createExecutionContext(self.rm_engine, self.phase_deadline);
                self.next(.context_wait);
            },
            .context_wait => {
                const status = try run.executionContextStatus(self.context.?);
                if (status.rejected != null or status.unavailable == .classes) return error.Unsupported;
                if (status.state != .handed_off) return false;
                if (status.unavailable == .engine) self.next(.context_retire) else {
                    if (status.info == null or status.info.?.method_bytes == 0) return error.Descriptor;
                    self.next(.methods_allocate);
                }
            },
            .context_retire => {
                try run.retireExecutionContext(self.context.?, self.phase_deadline);
                self.next(.context_retiring);
            },
            .context_retiring => {
                _ = run.executionContextStatus(self.context.?) catch |err| {
                    if (err != error.Stale) return err;
                    self.context = null;
                    self.rm_engine += 1;
                    self.next(.context_start);
                    return true;
                };
                return false;
            },
            .methods_allocate => try self.allocate(run, (try run.executionContextStatus(self.context.?)).info.?.method_bytes, .methods_attach),
            .methods_attach => {
                try run.attachContextMethods(self.context.?, 0, self.storage.?);
                self.release(.instance_allocate);
            },
            .instance_allocate => try self.allocate(run, 4096, .channel_create),
            .channel_create => {
                self.channel = try run.createCopyChannel(self.context.?, 0, self.storage.?, self.phase_deadline);
                self.next(.channel_wait);
            },
            .channel_wait => {
                const status = try run.executionChannelStatus(self.channel.?);
                if (status.rejected != null or status.host_rejected != null) return error.Channel;
                if (status.info == null) return false;
                self.release(.register);
            },
            .storage_wait => {
                const status = try run.nativeBufferStatus(self.storage.?);
                if (status.state != .handed_off) return false;
                if (status.info == null) return error.Memory;
                self.next(self.after_storage);
            },
            .storage_release => {
                try run.releaseNativeBuffer(self.storage.?);
                self.storage = null;
                self.next(self.after_storage);
            },
            .register => {
                if (self.publish_backend) _ = try run.registerCopyBackend(self.channel.?, self.phase_deadline);
                self.next(.ready);
            },
            else => return error.State,
        }
        return true;
    }
};
