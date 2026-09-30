// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Per-producer CE channel borrowing the adapter's existing CE context.
//! Graph teardown waits for native queues; only the channel owns a child use.
const std = @import("std");
const runtime = @import("gsp_runtime.zig");
const nv = @import("r4nv_binding");
pub const Phase = enum {
    detached, waiting, instance_allocate, storage_wait, storage_release,
    channel_start, channel_wait, ready, channel_close, channel_closing, closed, unavailable,
};
pub const Owner = struct {
    self_address: usize = 0,
    phase: Phase = .detached,
    after_storage: Phase = .detached,
    context: ?runtime.ContextHandle = null,
    channel: ?runtime.ChannelHandle = null,
    storage: ?runtime.BufferHandle = null,
    epoch: u64 = 0,
    last_clock: u64 = 0,
    deadline: u64 = 0,
    phase_deadline: u64 = 0,
    closing: bool = false,
    reason: ?anyerror = null,

    pub fn request(self: *Owner, run: *runtime.Owner) !void {
        if (self.self_address != 0) return error.State;
        const source = &run.native_copy;
        if (run.graph_closing or source.self_address != @intFromPtr(source) or
            source.phase != .ready or source.epoch != run.epoch or source.context == null) return error.Unsupported;
        self.* = .{ .self_address = @intFromPtr(self), .phase = .waiting,
            .context = source.context, .epoch = run.epoch };
    }
    pub fn requestClose(self: *Owner) !void {
        if (self.self_address != @intFromPtr(self)) return error.State;
        self.closing = true;
        if (self.phase == .waiting or self.phase == .unavailable) self.phase = .closed;
    }
    pub fn step(self: *Owner, run: *runtime.Owner) !bool {
        if (self.phase == .detached) return false;
        if (self.self_address != @intFromPtr(self) or run.failure != null) return error.State;
        if (self.phase == .closed or self.phase == .unavailable) return false;
        if (run.epoch != self.epoch or !std.meta.eql(run.native_copy.context, self.context)) return error.Stale;
        if (self.phase == .ready and !self.closing) return false;
        const now = (run.clock() orelse return error.Api).nowNs();
        if (now == 0 or now == std.math.maxInt(u64) or now < self.last_clock) return error.Clock;
        self.last_clock = now;
        if (self.phase == .waiting or self.phase == .ready) {
            self.deadline = try std.math.add(u64, now, 60 * std.time.ns_per_s);
            self.next(if (self.phase == .waiting) .instance_allocate else .channel_close);
            return true;
        }
        if (now >= self.deadline or now >= self.phase_deadline) return error.Deadline;
        return self.advance(run) catch |err| {
            if (err == error.Busy) return false;
            // Known synchronous admission failures own no unknown GPU work.
            // All uncertain outcomes remain with the enclosing reset owner.
            if ((err == error.Memory or err == error.Exhausted or err == error.Unsupported) and
                (self.phase == .instance_allocate or self.phase == .channel_start)) {
                self.reason = err; self.retireStorage(.unavailable); return true;
            }
            return err;
        };
    }
    fn next(self: *Owner, phase: Phase) void {
        self.phase = phase;
        self.phase_deadline = @min(self.deadline, self.last_clock +| (5 * std.time.ns_per_s));
    }
    fn retireStorage(self: *Owner, after: Phase) void {
        self.after_storage = after;
        self.next(if (self.storage != null) .storage_release else after);
    }
    fn advance(self: *Owner, run: *runtime.Owner) !bool {
        if (self.closing) switch (self.phase) {
            .instance_allocate, .channel_start => { self.retireStorage(.closed); return true; },
            else => {},
        };
        switch (self.phase) {
            .instance_allocate => {
                self.storage = try run.allocateNativeStorage(4096, self.phase_deadline);
                self.next(.storage_wait);
            },
            .storage_wait => {
                const status = try run.nativeBufferStatus(self.storage.?);
                if (status.state != .handed_off) return false;
                if (self.closing) self.retireStorage(.closed) else if (status.info == null) {
                    self.reason = error.Memory; self.retireStorage(.unavailable);
                } else self.next(.channel_start);
            },
            .storage_release => {
                try run.releaseNativeBuffer(self.storage.?);
                self.storage = null; self.next(self.after_storage);
            },
            .channel_start => {
                self.channel = try run.createCopyChannel(self.context.?, 0, self.storage.?, self.phase_deadline);
                self.retireStorage(.channel_wait);
            },
            .channel_wait => {
                const status = try run.executionChannelStatus(self.channel.?);
                if (status.state != .handed_off) return false;
                if (self.closing) { self.next(.channel_close); return true; }
                const info = status.info orelse {
                    self.reason = status.host_rejected orelse error.Unsupported;
                    self.next(.channel_close); return true;
                };
                const parent = (try run.executionContextStatus(self.context.?)).info orelse return error.State;
                if (info.config.engine != .copy or info.config.engine_mask != nv.native_engine_copy or
                    !std.meta.eql(info.config.context, parent.binding)) return error.Descriptor;
                self.log(run, "ready");
                self.next(.ready);
            },
            .channel_close => {
                try run.retireExecutionChannel(self.channel.?, self.phase_deadline, true);
                self.log(run, "retire");
                const owner = run.fifos[self.channel.?.slot].owner orelse return error.State;
                if (owner.ring.self_address != 0) owner.ring.logDiagnostic(&run.ctx.?, owner.config.handle, owner.cid, owner.work_submit_token orelse 0);
                self.next(.channel_closing);
            },
            .channel_closing => {
                _ = run.executionChannelStatus(self.channel.?) catch |err| {
                    if (err != error.Stale) return err;
                    self.channel = null;
                    // Never free the borrowed context or its shared methods.
                    self.next(if (self.reason != null and !self.closing) .unavailable else .closed);
                    return true;
                };
                return false;
            },
            else => return error.State,
        }
        return true;
    }
    noinline fn log(self: *const Owner, run: *runtime.Owner, event: []const u8) void {
        const owner = run.fifos[self.channel.?.slot].owner orelse return;
        const c = owner.config;
        @import("gsp_mode_diagnostics.zig").write(&run.ctx.?,
            "NVIDIA gsp-shared-copy: {s} channel={x} hw-chid={d} group={x} share={x} methods={x}/{d} instance={x} context={d}:{d}",
            .{event, c.handle, c.hardware_channel, c.context.group, c.context.share, c.methods, c.method_bytes, c.instance,
                self.context.?.slot, self.context.?.serial});
    }
};
