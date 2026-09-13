//! Warm the bounded shader storage once before advertising common rendering.
//! Existing CE/GR channels and the existing worker perform every operation.
const std = @import("std");
const runtime = @import("gsp_runtime.zig");
pub const Phase = enum { waiting, allocate, storage, attach, release, upload, uploaded, enable, unwind, ready, unavailable };
pub const Owner = struct {
    phase: Phase = .waiting,
    storage: ?runtime.BufferHandle = null,
    channel: ?runtime.ChannelHandle = null,
    copy_channel: ?runtime.ChannelHandle = null,
    kind: runtime.render_cache.Kind = .programs,
    deadline: u64 = 0,
    epoch: u64 = 0,

    pub fn step(self: *Owner, run: *runtime.Owner, channel: ?runtime.ChannelHandle, copy_channel: ?runtime.ChannelHandle) !bool {
        if (self.phase == .ready or self.phase == .unavailable) return false;
        const now = (run.ctx.?.resources() orelse return error.Api).nowNs();
        if (now == 0 or now == std.math.maxInt(u64)) return error.Clock;
        if (self.phase == .waiting) {
            if (channel == null or copy_channel == null or run.copy_backend == null) return false;
            self.channel = channel; self.copy_channel = copy_channel; self.epoch = run.epoch;
            self.deadline = try std.math.add(u64, now, 15 * std.time.ns_per_s);
            run.graphics_starting = true; self.phase = .allocate;
            return true;
        }
        if (run.epoch != self.epoch) return error.Stale;
        if (now >= self.deadline) return error.Deadline;
        return self.advance(run) catch |err| {
            if (err == error.Busy) return false;
            if (run.failure == null and (err == error.Memory or err == error.Exhausted or err == error.Unsupported) and
                (self.phase == .allocate or self.phase == .storage or self.phase == .attach)) {
                self.phase = .unwind; return true;
            }
            return err;
        };
    }
    fn advance(self: *Owner, run: *runtime.Owner) !bool {
        switch (self.phase) {
            .allocate => {
                self.storage = try run.allocateNativeStorage(if (self.kind == .programs) runtime.render.shader_bytes else runtime.render.packet_bytes, self.deadline);
                self.phase = .storage;
            },
            .storage => {
                const status = try run.nativeBufferStatus(self.storage.?);
                if (status.state != .handed_off) return false;
                if (status.info == null) return error.Memory;
                self.phase = .attach;
            },
            .attach => {
                try run.attachGraphicsCache(self.kind, self.storage.?);
                self.phase = .release;
            },
            .release => {
                try run.releaseNativeBuffer(self.storage.?); self.storage = null;
                if (self.kind == .programs) { self.kind = .packet; self.phase = .allocate; } else self.phase = .upload;
            },
            .upload => {
                try run.beginGraphicsUpload(self.copy_channel.?, .programs, null, self.deadline);
                self.phase = .uploaded;
            },
            .uploaded => {
                if (run.graphics_upload != null) return false;
                if (run.graphics_cache.program_point == 0) return error.State;
                self.phase = .enable;
            },
            .enable => {
                run.enableGraphicsQueue(self.channel.?, self.copy_channel.?) catch |err| {
                    if (err != error.Unsupported) return err;
                    if (!run.graphics_cache.close(true)) return error.Retained;
                    run.graphics_starting = false; self.phase = .unavailable;
                    run.ctx.?.logInfo("NVIDIA render: unavailable common-queue-capability-update=missing");
                    return true;
                };
                run.graphics_starting = false; self.phase = .ready;
                run.ctx.?.logInfo("NVIDIA render: ready engine=C797 shaders=6 cache=warm budget=131072 common-queue=yes pixels=unverified");
            },
            .unwind => {
                if (self.storage) |handle| { try run.releaseNativeBuffer(handle); self.storage = null; }
                if (!run.graphics_cache.close(true)) return error.Retained;
                run.graphics_starting = false; self.phase = .unavailable;
                run.ctx.?.logInfo("NVIDIA render: unavailable cache-allocation=rejected display=preserved");
            },
            else => return error.State,
        }
        return true;
    }
};
