// ExFiles/Reference/GFX/Nvidia/Nouveau/drivers/gpu/drm/nouveau/nvkm/subdev/gsp/rm/r535/gr.c
// /*
//  * Copyright 2023 Red Hat Inc.
//  *
//  * Permission is hereby granted, free of charge, to any person obtaining a
//  * copy of this software and associated documentation files (the "Software"),
//  * to deal in the Software without restriction, including without limitation
//  * the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  * and/or sell copies of the Software, and to permit persons to whom the
//  * Software is furnished to do so, subject to the following conditions:
//  *
//  * The above copyright notice and this permission notice shall be included in
//  * all copies or substantial portions of the Software.
//  *
//  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
//  * THE COPYRIGHT HOLDER(S) OR AUTHOR(S) BE LIABLE FOR ANY CLAIM, DAMAGES OR
//  * OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
//  * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  * OTHER DEALINGS IN THE SOFTWARE.
//  */
//! One bounded step in the existing device worker. GR uses its own RM
//! group/channel; display and CE retain their existing owners.
const std = @import("std");
const r4os = @import("r4os");
const runtime = @import("gsp_runtime.zig");
pub const Phase = enum {
    detached, waiting, context_start, context_wait, globals_attach, buffers_allocate, buffers_attach, methods_allocate, storage_wait,
    methods_attach, storage_release, instance_allocate, channel_start, channel_wait,
    probe_start, probe_wait, ready, channel_close, channel_closing,
    context_close, context_closing, closed, unavailable, failed,
};
pub const Owner = struct {
    self_address: usize = 0,
    phase: Phase = .detached,
    failed_phase: ?Phase = null,
    after_storage: Phase = .detached,
    context: ?runtime.ContextHandle = null,
    golden_context: ?runtime.ContextHandle = null,
    golden_borrowed: bool = false,
    closing: bool = false,
    regular: bool = false,
    buffer_index: usize = 0,
    channel: ?runtime.ChannelHandle = null,
    storage: ?runtime.BufferHandle = null,
    receipt: ?runtime.GraphicsReceipt = null,
    epoch: u64 = 0,
    last_clock: u64 = 0,
    deadline: u64 = 0,
    phase_deadline: u64 = 0,
    reason: ?anyerror = null,
    rm_status: ?u32 = null,
    method_bytes: u32 = 0,

    pub fn request(self: *Owner) !void {
        if (self.self_address != 0) return error.State;
        self.* = .{ .self_address = @intFromPtr(self), .phase = .waiting };
    }
    /// Another regular GR group/channel, with its own mutable context buffers.
    /// The device's golden owner outlives startup; the RM context acquires an
    /// independent global-storage loan before allocating its channel.
    pub fn requestRegular(self: *Owner, source: *const Owner) !void {
        if (self.self_address != 0 or source.self_address != @intFromPtr(source) or
            source.phase != .ready or source.closing or source.golden_borrowed or
            source.golden_context == null or source.epoch == 0) return error.State;
        self.* = .{ .self_address = @intFromPtr(self), .phase = .waiting, .regular = true,
            .golden_context = source.golden_context, .golden_borrowed = true, .epoch = source.epoch };
    }
    /// Request only: an outstanding RM operation or GPU barrier must finish
    /// before its physical owners can be retired. Repeated requests are inert.
    pub fn requestClose(self: *Owner) !void {
        if (self.self_address != @intFromPtr(self) or self.phase == .failed) return error.State;
        self.closing = true;
        if (self.phase == .waiting or self.phase == .unavailable) {
            self.golden_context = null;
            self.phase = .closed;
        }
    }
    pub fn step(self: *Owner, run: *runtime.Owner, allow_start: bool) !bool {
        if (self.phase == .detached or self.phase == .closed or self.phase == .unavailable) return false;
        if (self.self_address != @intFromPtr(self) or self.phase == .failed) return error.State;
        if (self.phase == .ready and !self.closing) return false;
        const now = (run.ctx.?.resources() orelse return error.Api).nowNs();
        if (now == 0 or now == std.math.maxInt(u64) or now < self.last_clock) return error.Clock;
        self.last_clock = now;
        if (self.phase == .ready) {
            if (run.epoch != self.epoch) return error.Stale;
            self.deadline = try std.math.add(u64, now, 60 * std.time.ns_per_s);
            self.next(.channel_close);
            return true;
        }
        if (self.phase == .waiting) {
            if (!allow_start or run.nativeAddressSpace() == null or run.nativeControlBuffer() == null) return false;
            if (self.golden_borrowed and run.epoch != self.epoch) return error.Stale;
            self.epoch = run.epoch;
            self.deadline = try std.math.add(u64, now, 60 * std.time.ns_per_s);
            self.next(.context_start);
            return true;
        }
        if (run.epoch != self.epoch) return error.Stale;
        if (now >= self.deadline or now >= self.phase_deadline) return error.Deadline;
        return self.advance(run) catch |err| {
            if (err == error.Busy) return false;
            // These synchronous admission failures occurred before physical
            // submission. Rejected RM operations arrive through status after
            // their normal unwind. Unknown outcomes remain quarantined.
            if ((err == error.Memory or err == error.Exhausted or err == error.Unsupported) and
                (self.phase == .context_start or self.phase == .methods_allocate or self.phase == .instance_allocate or
                self.phase == .methods_attach or self.phase == .channel_start or self.phase == .buffers_allocate or
                self.phase == .buffers_attach or self.phase == .globals_attach)) {
                self.reason = err;
                self.retireStorage(.context_close);
                return true;
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
        self.after_storage = after;
        self.next(.storage_wait);
    }
    fn retireStorage(self: *Owner, after: Phase) void {
        self.after_storage = after;
        self.next(if (self.storage != null) .storage_release else after);
    }
    fn advance(self: *Owner, run: *runtime.Owner) !bool {
        if (self.closing) switch (self.phase) {
            .context_start, .globals_attach, .buffers_allocate, .buffers_attach,
            .methods_allocate, .methods_attach, .instance_allocate, .channel_start => {
                self.retireStorage(.context_close); return true;
            },
            .probe_start => { self.next(.channel_close); return true; },
            else => {},
        };
        switch (self.phase) {
            .context_start => {
                self.context = if (self.regular) try run.createRegularGraphicsContext(self.golden_context.?, self.phase_deadline)
                    else try run.createExecutionContext(1, self.phase_deadline);
                self.next(.context_wait);
            },
            .context_wait => {
                const status = try run.executionContextStatus(self.context.?);
                if (status.state != .handed_off) return false;
                if (self.closing) { self.next(.context_close); return true; }
                const info = status.info orelse {
                    self.reason = error.Unsupported; self.rm_status = status.rejected;
                    self.next(.context_close); return true;
                };
                if (info.rm_engine != 1 or info.nv_engine != 1 or info.engine.count == 0 or info.method_bytes == 0) return error.Descriptor;
                self.method_bytes = info.method_bytes;
                self.buffer_index = 0;
                self.next(if (self.regular) .globals_attach else .methods_allocate);
            },
            .globals_attach => {
                try run.shareGraphicsContextGlobals(self.context.?, self.golden_context.?);
                self.next(.methods_allocate);
            },
            .buffers_allocate => {
                const requirement = (try run.graphicsContextRequirement(self.context.?, self.buffer_index)) orelse {
                    self.next(.instance_allocate); return true;
                };
                if (self.regular and requirement.global) { self.buffer_index += 1; return true; }
                if (self.storage != null) return error.State;
                self.storage = try run.allocateGraphicsContextStorage(requirement, self.phase_deadline);
                self.after_storage = .buffers_attach; self.next(.storage_wait);
            },
            .buffers_attach => {
                try run.attachGraphicsContextBuffer(self.context.?, self.buffer_index, self.storage.?);
                self.buffer_index += 1; self.retireStorage(.buffers_allocate);
            },
            .methods_allocate => try self.allocate(run, self.method_bytes, .methods_attach),
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
            .methods_attach => {
                try run.attachContextMethods(self.context.?, 0, self.storage.?);
                self.retireStorage(.buffers_allocate);
            },
            .storage_release => {
                try run.releaseNativeBuffer(self.storage.?);
                self.storage = null;
                self.next(self.after_storage);
            },
            .channel_start => {
                self.channel = try run.createGraphicsChannel(self.context.?, 0, self.storage.?, self.phase_deadline);
                self.retireStorage(.channel_wait);
            },
            .channel_wait => {
                const status = try run.executionChannelStatus(self.channel.?);
                if (status.state != .handed_off) return false;
                if (self.closing) { self.next(.channel_close); return true; }
                const info = status.info orelse {
                    self.reason = error.Unsupported; self.rm_status = status.rejected;
                    self.next(.channel_close); return true;
                };
                if (info.config.engine != .graphics or info.config.object_class != try run.graphicsClass()) return error.Descriptor;
                self.next(if (self.regular) .probe_start else .channel_close);
            },
            .probe_start => {
                try run.beginGraphicsBarrier(self.channel.?, self.phase_deadline);
                self.next(.probe_wait);
            },
            .probe_wait => {
                self.receipt = (try run.receiveGraphics(self.channel.?)) orelse return false;
                if (self.closing) { self.next(.channel_close); return true; }
                self.next(.ready);
                var line: [200]u8 = undefined;
                if (!self.golden_borrowed) run.ctx.?.logInfo(try std.fmt.bufPrintZ(&line,
                    "NVIDIA graphics-engine: ready class={x} rm-engine=1 golden=complete epoch={d} barrier={d} render=unavailable",
                    .{try run.graphicsClass(), self.epoch, self.receipt.?.point}));
            },
            .channel_close => {
                try run.retireExecutionChannel(self.channel.?, self.phase_deadline, true);
                self.next(.channel_closing);
            },
            .channel_closing => {
                _ = run.executionChannelStatus(self.channel.?) catch |err| {
                    if (err != error.Stale) return err;
                    self.channel = null;
                    if (!self.regular and self.reason == null and !self.closing) {
                        self.golden_context = self.context; self.context = null; self.regular = true;
                        self.next(.context_start);
                    } else self.next(.context_close);
                    return true;
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
                } else if (self.golden_context) |handle| {
                    if (!self.golden_borrowed) self.context = handle;
                    self.golden_context = null;
                } else if (self.closing) {
                    self.receipt = null; self.phase = .closed;
                } else self.unavailable(&run.ctx.?);
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
    fn unavailable(self: *Owner, ctx: *const r4os.r4dev.DriverContext) void {
        self.phase = .unavailable;
        var line: [200]u8 = undefined;
        const message = std.fmt.bufPrintZ(&line, "NVIDIA graphics-engine: unavailable reason={s} rm-status={?} display=preserved",
            .{if (self.reason) |err| @errorName(err) else "unknown", self.rm_status}) catch return;
        ctx.logInfo(message);
    }
    pub fn quarantine(self: *Owner, ctx: ?*const r4os.r4dev.DriverContext, err: anyerror) void {
        if (self.self_address == 0 or self.phase == .closed or self.phase == .unavailable or self.phase == .failed) return;
        self.failed_phase = self.phase; self.reason = err; self.phase = .failed;
        if (ctx) |value| value.logInfo("NVIDIA graphics-engine: stopped resources=retained completion=not-inferred");
    }
};
