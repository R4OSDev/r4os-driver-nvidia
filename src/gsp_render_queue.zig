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
    list: a.GfxRenderList = .{},
    list_stamp: a.GfxRenderList = .{},
    grids: [render.batch_capacity]a.GfxSampleGrid = @splat(.{}),
    grid_stamps: [render.batch_capacity]a.GfxSampleGrid = @splat(.{}),
    color: ?render.ColorProgram = null,
    color_stamp: ?render.ColorProgram = null,
    draws: [render.batch_capacity]render.Draw = undefined,
    draw_count: usize = 0,
    slices: [render.batch_capacity]render.Draw = undefined,
    slice_count: usize = 0,
    draw_cursor: usize = 0,
    pixel_cursor: u64 = 0,
    next_draw: usize = 0,
    next_pixel: u64 = 0,
    pixel_limit: u32 = @import("gsp_work_scheduling.zig").render_pixels,
    phase: Phase = .retain,
    deadline: u64 = 0,
    acknowledged: bool = false,
    failed: bool = false,

    pub fn open(self: *Owner, queue: r4os.driver_queue.Context, memory: r4os.driver_memory.Context,
        binding: a.GfxBackendBinding, job: a.GfxDriverJob, now: u64) !void {
        if (self.self_address != 0) return error.Busy;
        const pixel_limit = self.pixel_limit;
        if (pixel_limit == 0 or pixel_limit > @import("gsp_work_scheduling.zig").render_pixels) return error.Bounds;
        self.* = .{ .self_address = @intFromPtr(self), .queue = queue, .memory = memory, .pixel_limit = pixel_limit,
            .binding = binding, .job = job, .stamp = job, .deadline = job.deadline_ns };
        if (job.version != 1 or job.size < @offsetOf(a.GfxDriverJob, "producer_kind") or
            (job.operation != a.gfx_queue_operation_render and job.operation != a.gfx_queue_operation_render_list and job.operation != a.gfx_queue_operation_render_grid_list and job.operation != a.gfx_queue_operation_render_color_list) or
            job.reserved0 != 0 or job.reserved1 != 0 or job.source_offset != 0 or job.target_offset != 0 or job.byte_length != 0 or
            job.row_count != 0 or job.source_pitch != 0 or job.target_pitch != 0 or job.render.reserved0 != 0 or
            job.fence.timeline == 0 or job.fence.point == 0 or job.fence.adapter_id != binding.adapter_id or
            job.fence.device_generation != binding.device_generation or job.fence.reset_generation != binding.reset_generation) {
            self.failed = true; return error.Descriptor;
        }
        if (job.operation == a.gfx_queue_operation_render_list or job.operation == a.gfx_queue_operation_render_grid_list or job.operation == a.gfx_queue_operation_render_color_list) {
            if (job.operation == a.gfx_queue_operation_render_color_list) {
                var mapped: a.GfxRenderColorList = .{};
                if (queue.readRenderColorList(&job.fence, &mapped) != a.gfx_queue_ok or mapped.version != 1 or
                    mapped.size != @sizeOf(a.GfxRenderColorList) or mapped.reserved0 != 0 or mapped.program.version != 1 or
                    mapped.program.size != @sizeOf(a.GfxRenderColorProgram) or mapped.program.reserved0 != 0 or
                    job.render.transfer != a.gfx_render_transfer_color or job.render.kind != a.gfx_render_kind_sample or
                    job.render.filter != a.gfx_render_filter_nearest) { self.failed = true; return error.Descriptor; }
                const color: render.ColorProgram = .{ .words = mapped.program.words };
                color.validate() catch { self.failed = true; return error.Descriptor; };
                self.list = .{ .count = mapped.count, .commands = mapped.commands }; self.color = color;
            } else if (job.operation == a.gfx_queue_operation_render_grid_list) {
                var mapped: a.GfxRenderGridList = .{};
                if (queue.readRenderGridList(&job.fence, &mapped) != a.gfx_queue_ok or mapped.version != 1 or
                    mapped.size != @sizeOf(a.GfxRenderGridList) or mapped.reserved0 != 0) { self.failed = true; return error.Descriptor; }
                self.list = .{ .count = mapped.count, .commands = mapped.commands }; self.grids = mapped.grids;
            } else if (queue.readRenderList(&job.fence, &self.list) != a.gfx_queue_ok) { self.failed = true; return error.Descriptor; }
            if (self.list.version != 1 or self.list.size < @sizeOf(a.GfxRenderList) or self.list.reserved0 != 0 or
                self.list.count == 0 or self.list.count > render.batch_capacity or
                !std.meta.eql(self.list.commands[0], job.render)) { self.failed = true; return error.Descriptor; }
            for (self.list.commands, 0..) |command, index| {
                if (index < self.list.count) {
                    if (command.reserved0 != 0 or command.kind != job.render.kind or command.filter != job.render.filter or
                        command.blend != job.render.blend or command.transfer != job.render.transfer) { self.failed = true; return error.Descriptor; }
                } else if (!std.meta.eql(command, a.GfxRenderCommand{}) or !std.meta.eql(self.grids[index], a.GfxSampleGrid{})) { self.failed = true; return error.Descriptor; }
            }
        } else { self.list.count = 1; self.list.commands[0] = job.render; }
        self.list_stamp = self.list;
        self.grid_stamps = self.grids;
        self.color_stamp = self.color;
        if (job.deadline_ns <= now or job.deadline_ns == std.math.maxInt(u64)) try self.finish(a.gfx_queue_result_failed);
    }
    pub fn valid(self: *const Owner) bool {
        return self.self_address == @intFromPtr(self) and !self.failed and std.meta.eql(self.job, self.stamp) and
            std.meta.eql(self.references, self.reference_stamps) and self.deadline == self.stamp.deadline_ns and
            std.meta.eql(self.list, self.list_stamp) and std.meta.eql(self.grids, self.grid_stamps) and
            std.meta.eql(self.color, self.color_stamp) and self.draw_count <= render.batch_capacity and
            self.slice_count <= render.batch_capacity and self.draw_cursor <= self.draw_count and self.next_draw <= self.draw_count;
    }
    pub fn commands(self: *const Owner) []const render.Draw { return self.slices[0..self.slice_count]; }
    /// The enclosing backend has already terminalized every fence after
    /// proven reset. Drop only this job's retained aliases; never ACK it anew.
    pub fn closeAfterReset(self: *Owner, proof: @import("gsp_reset.zig").Quiescence, epoch: u64) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or !proof.valid(epoch) or !std.meta.eql(self.job, self.stamp) or
            !std.meta.eql(self.references, self.reference_stamps)) return false;
        for (&self.references, &self.reference_stamps) |*reference, *stamp| {
            if (reference.reference.id == 0) continue;
            if (self.memory.bufferRelease(&reference.reference) != a.gfx_buffer_result_ok) return false;
            reference.* = .{}; stamp.* = .{};
        }
        self.* = .{}; return true;
    }
    pub fn prepareSlice(self: *Owner) !void {
        self.slice_count = 0;
        self.next_draw = self.draw_cursor;
        self.next_pixel = self.pixel_cursor;
        var remaining: u64 = self.pixel_limit;
        while (remaining != 0 and self.next_draw < self.draw_count and self.slice_count < render.batch_capacity) {
            const part = try render.slice(self.draws[self.next_draw], self.next_pixel, remaining);
            self.slices[self.slice_count] = part.draw;
            self.slice_count += 1;
            remaining -= part.next - self.next_pixel;
            self.next_pixel = part.next;
            if (part.next == part.total) { self.next_draw += 1; self.next_pixel = 0; }
        }
        if (self.slice_count == 0) return error.Empty;
    }
    pub fn validateSlice(self: *const Owner) !void {
        var draw = self.draw_cursor;
        var pixel = self.pixel_cursor;
        var remaining: u64 = self.pixel_limit;
        for (self.commands()) |command| {
            if (draw >= self.draw_count) return error.Binding;
            const part = try render.slice(self.draws[draw], pixel, remaining);
            if (!std.meta.eql(command, part.draw)) return error.Binding;
            remaining -= part.next - pixel;
            pixel = part.next;
            if (part.next == part.total) { draw += 1; pixel = 0; }
        }
        if (self.slice_count == 0 or draw != self.next_draw or pixel != self.next_pixel) return error.Binding;
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
                run.prepareQueuedGraphics(self) catch |err| {
                    if (err == error.Empty or err == error.Unsupported or err == error.Bounds or err == error.Overflow) {
                        if (err != error.Empty) try run.renderRejection(err);
                        try self.finish(if (err == error.Empty) a.gfx_queue_result_complete else a.gfx_queue_result_failed); return true;
                    }
                    return err;
                };
                try self.prepareSlice();
                self.phase = .upload;
            },
            .upload => {
                run.beginQueuedGraphicsUpload(self) catch |err| { if (err == error.Busy) return false; return err; };
                self.phase = .upload_wait;
            },
            .upload_wait => {
                if (run.graphics_upload != null) return false;
                if (!(try run.graphics_cache.binding()).matches(self.commands())) return error.Stale;
                self.phase = .draw;
            },
            .draw => {
                run.beginQueuedGraphicsDraw(self) catch |err| { if (err == error.Busy) return false; return err; };
                self.phase = .draw_wait;
            },
            .draw_wait => {
                _ = (try run.receiveGraphics(run.graphics_channel.?)) orelse return false;
                self.draw_cursor = self.next_draw; self.pixel_cursor = self.next_pixel;
                if (self.draw_cursor == self.draw_count) {
                    run.graphics_completed +|= 1;
                    try self.finish(a.gfx_queue_result_complete);
                } else {
                    try self.prepareSlice();
                    self.phase = .upload;
                    try run.yieldWork();
                }
            },
            .done => unreachable,
        }
        return true;
    }
};
