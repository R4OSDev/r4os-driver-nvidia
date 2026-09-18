// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Per-decoder RM context/channel lifecycle. Runtime owns physical resources;
//! this worker retains handles through every pending operation and close.
const std = @import("std");
const runtime = @import("gsp_runtime.zig");
const context_wire = @import("gsp_context_wire.zig");
pub const Phase = enum {
    detached, waiting, context_start, context_wait, methods_allocate, methods_attach,
    instance_allocate, storage_wait, storage_release, channel_start, channel_wait,
    ready, channel_close, channel_closing, context_close, context_closing, closed, unavailable,
};
pub const Owner = struct {
    self_address: usize = 0,
    phase: Phase = .detached,
    after_storage: Phase = .detached,
    context: ?runtime.ContextHandle = null,
    channel: ?runtime.ChannelHandle = null,
    storage: ?runtime.BufferHandle = null,
    rm_engine: u32 = 29,
    method_bytes: u32 = 0,
    epoch: u64 = 0,
    last_clock: u64 = 0,
    deadline: u64 = 0,
    phase_deadline: u64 = 0,
    next_engine: bool = false,
    closing: bool = false,
    reason: ?anyerror = null,
    rm_status: ?u32 = null,

    pub fn request(self: *Owner) !void {
        if (self.self_address != 0) return error.State;
        self.* = .{ .self_address = @intFromPtr(self), .phase = .waiting };
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
        if (self.epoch != 0 and self.epoch != run.epoch) return error.Stale;
        if (self.phase == .ready and !self.closing) return false;
        const now = (run.ctx.?.resources() orelse return error.Api).nowNs();
        if (now == 0 or now == std.math.maxInt(u64) or now < self.last_clock) return error.Clock;
        self.last_clock = now;
        if (self.phase == .waiting) {
            if (run.nativeAddressSpace() == null or run.nativeControlBuffer() == null) return false;
            self.epoch = run.epoch;
            self.deadline = try std.math.add(u64, now, 60 * std.time.ns_per_s);
            self.next(.context_start); return true;
        }
        if (self.phase == .ready) {
            self.deadline = try std.math.add(u64, now, 60 * std.time.ns_per_s);
            self.next(.channel_close); return true;
        }
        if (now >= self.deadline or now >= self.phase_deadline) return error.Deadline;
        return self.advance(run) catch |err| {
            if (err == error.Busy) return false;
            // Only synchronous admission failures can select ordinary unwind.
            // Unknown/device outcomes propagate to the runtime reset owner.
            if ((err == error.Memory or err == error.Exhausted or err == error.Unsupported) and
                (self.phase == .context_start or self.phase == .methods_allocate or self.phase == .methods_attach or
                self.phase == .instance_allocate or self.phase == .channel_start)) {
                self.reason = err; self.retireStorage(.context_close); return true;
            }
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
        self.after_storage = after; self.next(.storage_wait);
    }
    fn retireStorage(self: *Owner, after: Phase) void {
        self.after_storage = after;
        self.next(if (self.storage != null) .storage_release else after);
    }
    fn advance(self: *Owner, run: *runtime.Owner) !bool {
        if (self.closing) switch (self.phase) {
            .context_start, .methods_allocate, .methods_attach, .instance_allocate, .channel_start => {
                self.retireStorage(.context_close); return true;
            },
            else => {},
        };
        switch (self.phase) {
            .context_start => {
                _ = try context_wire.nvdecInstance(self.rm_engine);
                self.context = try run.createExecutionContext(self.rm_engine, self.phase_deadline);
                self.next(.context_wait);
            },
            .context_wait => {
                const status = try run.executionContextStatus(self.context.?);
                if (status.state != .handed_off) return false;
                if (self.closing) { self.next(.context_close); return true; }
                const info = status.info orelse {
                    // Only an absent enumerated engine advances discovery.
                    // Class/allocation/transport rejection never substitutes it.
                    self.next_engine = status.rejected == null and status.unavailable == .engine and self.rm_engine < 36;
                    self.reason = error.Unsupported; self.rm_status = status.rejected;
                    self.next(.context_close); return true;
                };
                if (info.rm_engine != self.rm_engine or info.nv_engine != try context_wire.nvEngine(self.rm_engine) or
                    info.engine.data[2] != self.rm_engine or info.engine.count == 0 or info.method_bytes == 0) return error.Descriptor;
                self.method_bytes = info.method_bytes;
                self.next(.methods_allocate);
            },
            .methods_allocate => try self.allocate(run, self.method_bytes, .methods_attach),
            .methods_attach => {
                try run.attachContextMethods(self.context.?, 0, self.storage.?);
                self.retireStorage(.instance_allocate);
            },
            .instance_allocate => try self.allocate(run, 4096, .channel_start),
            .storage_wait => {
                const status = try run.nativeBufferStatus(self.storage.?);
                if (status.state != .handed_off) return false;
                if (self.closing) { self.retireStorage(.context_close); return true; }
                if (status.info == null) {
                    self.reason = error.Memory; self.rm_status = status.rejected;
                    self.retireStorage(.context_close);
                } else self.next(self.after_storage);
            },
            .storage_release => {
                try run.releaseNativeBuffer(self.storage.?);
                self.storage = null; self.next(self.after_storage);
            },
            .channel_start => {
                self.channel = try run.createNvdecChannel(self.context.?, 0, self.storage.?, self.phase_deadline);
                self.retireStorage(.channel_wait);
            },
            .channel_wait => {
                const status = try run.executionChannelStatus(self.channel.?);
                if (status.state != .handed_off) return false;
                if (self.closing) { self.next(.channel_close); return true; }
                const info = status.info orelse {
                    self.reason = status.host_rejected orelse error.Unsupported; self.rm_status = status.rejected;
                    self.next(.channel_close); return true;
                };
                if (info.config.engine != .nvdec or info.config.rm_engine != self.rm_engine or
                    info.config.object_class != try run.nvdecClass() or info.config.graphics != null or
                    info.config.engine_mask != @import("r4nv_binding").native_engine_video) return error.Descriptor;
                // Ready means RM channel allocation only. It is no decoder
                // success receipt: each picture must inspect NVDEC status.
                self.next(.ready);
            },
            .channel_close => {
                try run.retireExecutionChannel(self.channel.?, self.phase_deadline, true);
                self.next(.channel_closing);
            },
            .channel_closing => {
                _ = run.executionChannelStatus(self.channel.?) catch |err| {
                    if (err != error.Stale) return err;
                    self.channel = null; self.next(.context_close); return true;
                };
                return false;
            },
            .context_close => {
                if (self.context) |handle| {
                    run.retireExecutionContext(handle, self.phase_deadline) catch |err| {
                        if (err == error.Retained) return false;
                        return err;
                    };
                    self.next(.context_closing);
                } else if (self.next_engine and !self.closing) {
                    self.next_engine = false; self.rm_engine += 1; self.reason = null; self.rm_status = null;
                    self.next(.context_start);
                } else self.phase = if (self.closing) .closed else .unavailable;
            },
            .context_closing => {
                _ = run.executionContextStatus(self.context.?) catch |err| {
                    if (err != error.Stale) return err;
                    self.context = null; self.next(.context_close); return true;
                };
                return false;
            },
            else => return error.State,
        }
        return true;
    }
};
