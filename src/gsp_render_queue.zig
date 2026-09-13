//! A canonical common-queue draw retains its mapping references through the
//! small descriptor upload and the actual GR completion. No second execution
//! lease is invented for a resource already owned by the common queue.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const render = @import("r4nv_render");
pub const Phase = enum { retain, prepare, upload, upload_wait, draw, draw_wait, done };
pub const Owner = struct {
    self_address: usize = 0,
    queue: r4os.driver_queue.Context = undefined,
    memory: r4os.driver_memory.Context = undefined,
    binding: a.GfxBackendBinding = .{},
    job: a.GfxDriverJob = .{},
    stamp: a.GfxDriverJob = .{},
    references: [2]a.GfxBufferReference = @splat(.{}),
    reference_stamps: [2]a.GfxBufferReference = @splat(.{}),
    draw: ?render.Draw = null,
    phase: Phase = .retain,
    deadline: u64 = 0,
    acknowledged: bool = false,
    failed: bool = false,

    pub fn open(self: *Owner, queue: r4os.driver_queue.Context, memory: r4os.driver_memory.Context,
        binding: a.GfxBackendBinding, job: a.GfxDriverJob, now: u64) !void {
        if (self.self_address != 0) return error.Busy;
        self.* = .{ .self_address = @intFromPtr(self), .queue = queue, .memory = memory,
            .binding = binding, .job = job, .stamp = job, .deadline = job.deadline_ns };
        if (job.version != 1 or job.size < @sizeOf(a.GfxDriverJob) or job.operation != a.gfx_queue_operation_render or
            job.reserved0 != 0 or job.reserved1 != 0 or job.source_offset != 0 or job.target_offset != 0 or job.byte_length != 0 or
            job.row_count != 0 or job.source_pitch != 0 or job.target_pitch != 0 or job.render.reserved0 != 0 or
            job.fence.timeline == 0 or job.fence.point == 0 or job.fence.adapter_id != binding.adapter_id or
            job.fence.device_generation != binding.device_generation or job.fence.reset_generation != binding.reset_generation) {
            self.failed = true; return error.Descriptor;
        }
        if (job.deadline_ns <= now or job.deadline_ns == std.math.maxInt(u64)) try self.finish(a.gfx_queue_result_failed);
    }
    pub fn valid(self: *const Owner) bool {
        return self.self_address == @intFromPtr(self) and !self.failed and std.meta.eql(self.job, self.stamp) and
            std.meta.eql(self.references, self.reference_stamps) and self.deadline == self.stamp.deadline_ns;
    }
    fn finish(self: *Owner, result: u32) !void {
        if (!self.valid() or self.acknowledged) return error.Retained;
        if (self.queue.complete(&self.job.fence, result, 1) != a.gfx_queue_ok) return error.Retained;
        self.acknowledged = true;
        var index: usize = 2;
        while (index != 0) {
            index -= 1;
            if (self.references[index].reference.id == 0) continue;
            if (self.memory.bufferRelease(&self.references[index].reference) != a.gfx_buffer_result_ok) return error.Retained;
            self.references[index] = .{}; self.reference_stamps[index] = .{};
        }
        self.phase = .done;
    }
    pub fn step(self: *Owner, run: anytype, now: u64) !bool {
        if (!self.valid()) return error.Stale;
        if (self.phase == .done) return false;
        // Never acknowledge quiescence while either hardware sub-operation
        // remains submitted, even after the public deadline has expired.
        if (now >= self.deadline and run.graphics_upload == null and run.graphics_work == null) {
            try self.finish(a.gfx_queue_result_failed); return true;
        }
        switch (self.phase) {
            .retain => {
                const sampled = self.job.render.kind == a.gfx_render_kind_sample;
                const first: usize = if (sampled) 0 else 1;
                for (first..2) |i| {
                    const reference = &self.references[i];
                    if (reference.reference.id != 0) continue;
                    const rc = self.queue.retainResource(&self.job.fence, @intCast(i), reference);
                    self.reference_stamps[i] = reference.*;
                    if (rc != a.gfx_queue_ok and reference.reference.id == 0 and reference.buffer.id == 0) {
                        try self.finish(a.gfx_queue_result_failed); return true;
                    }
                    if (rc != a.gfx_queue_ok or reference.version != 1 or reference.size < @sizeOf(a.GfxBufferReference) or
                        reference.flags != a.gfx_buffer_reference_mapping_only or reference.reserved0 != 0 or
                        reference.reference.id == 0 or reference.reference.generation == 0 or reference.reference.reserved0 != 0 or
                        !std.meta.eql(reference.buffer, if (i == 0) self.job.source_buffer else self.job.target_buffer)) return error.Descriptor;
                }
                self.phase = .prepare;
            },
            .prepare => {
                self.draw = run.queuedGraphicsDraw(self) catch |err| {
                    if (err == error.Empty or err == error.Unsupported or err == error.Bounds or err == error.Overflow) {
                        try self.finish(if (err == error.Empty) a.gfx_queue_result_complete else a.gfx_queue_result_failed); return true;
                    }
                    return err;
                };
                self.phase = .upload;
            },
            .upload => {
                run.beginQueuedGraphicsUpload(self) catch |err| { if (err == error.Busy) return false; return err; };
                self.phase = .upload_wait;
            },
            .upload_wait => {
                if (run.graphics_upload != null) return false;
                if (run.graphics_cache.packet_point == 0 or run.graphics_cache.draw == null or
                    !std.meta.eql(run.graphics_cache.draw.?, self.draw.?)) return error.Stale;
                self.phase = .draw;
            },
            .draw => {
                run.beginQueuedGraphicsDraw(self) catch |err| { if (err == error.Busy) return false; return err; };
                self.phase = .draw_wait;
            },
            .draw_wait => {
                _ = (try run.receiveGraphics(run.graphics_channel.?)) orelse return false;
                run.graphics_completed +|= 1;
                try self.finish(a.gfx_queue_result_complete);
            },
            .done => unreachable,
        }
        return true;
    }
};
