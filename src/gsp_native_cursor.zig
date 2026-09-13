//! Optional common cursor jobs, consumed by the existing serialized Device
//! worker. Image CE, PIO position, Core activation and Present visibility
//! are distinct owners and receipts. No cursor operation draws a desktop.
const std = @import("std");
const a = @import("r4os").abi;
const runtime = @import("gsp_runtime.zig");
const image = @import("gsp_cursor_image.zig");
pub const Phase = enum { detached, unavailable, idle, allocate, allocation_wait, bind, release_creator, table_upload, table_wait,
    channel, channel_wait, upload, upload_wait, barrier, point, point_wait, commit, commit_wait, reply, failed };
pub const Owner = struct {
    self_address: usize = 0,
    phase: Phase = .detached,
    job: ?a.GfxDriverCursorJob = null,
    receipt: a.GfxDriverCursorCompletion = .{},
    channel: ?runtime.DisplayChannelHandle = null,
    allocation: ?runtime.BufferHandle = null,
    plan: ?image.Plan = null,
    image_slot: ?u1 = null,
    next_slot: u1 = 0,
    image_sequence: u64 = 0,
    point_sequence: u64 = 0,
    commit_sequence: u64 = 0,
    disabled: bool = false,
    configured: bool = false,
    failure: ?anyerror = null,

    pub fn busy(self: *const Owner) bool { return self.job != null; }
    pub fn pause(self: *Owner, product: anytype) !bool {
        if (!product.running.?.display_paused) return error.State;
        product.running.?.cursor_reserving = false;
        return switch (self.phase) {
            .allocation_wait, .bind, .release_creator, .table_upload, .table_wait => self.advance(product),
            else => false,
        };
    }
    pub fn stopped(self: *Owner, product: anytype) !bool {
        const run = product.running.?;
        if (!run.display_paused or run.cursor_point != null or run.display_work != null or run.cursor_upload != null or
            (run.cursor_storage != null and run.cursor_storage.?.active != null)) return error.Busy;
        if (!self.configured) return true;
        self.disabled = true;
        if (self.job == null) {
            // Disable admission first. A queued common request can make this
            // busy; consume that bounded request below and return its alias.
            const info = self.capabilities(product);
            const result = product.display.?.cursorConfigure(&info);
            if (result == a.gfx_output_ok) { self.phase = .unavailable; self.configured = false; return true; }
            if (result != a.gfx_output_error_busy) return error.CursorApi;
            var job: a.GfxDriverCursorJob = .{};
            const taken = product.display.?.cursorTake(&product.backend, &job);
            if (taken == 0 or taken == a.gfx_output_error_busy) return false;
            if (taken != a.gfx_output_ok or job.version != 1 or job.size < @sizeOf(a.GfxDriverCursorJob) or
                !std.meta.eql(job.backend, product.backend) or job.sequence == 0 or
                job.request.display_generation != product.receipt.generation or job.request.head_id != product.mode.?.head) return error.CursorApi;
            self.job = job;
        }
        self.reply(product, false, a.gfx_output_error_unavailable);
        _ = try self.advance(product);
        return false;
    }
    pub fn resumeOutput(self: *Owner) void {
        std.debug.assert(self.job == null and !self.configured);
        self.disabled = false; self.phase = .detached; self.image_sequence = 0; self.image_slot = null;
    }
    fn exclusive(self: *const Owner) bool {
        const job = self.job orelse return false;
        if (self.phase == .reply or self.phase == .failed) return false;
        return job.request.operation == a.display_cursor_operation_prepare or job.request.operation == a.display_cursor_operation_hide or
            job.request.operation == a.display_cursor_operation_release or self.phase == .commit or self.phase == .commit_wait;
    }
    pub fn step(self: *Owner, product: anytype) !bool {
        if (self.phase == .unavailable or self.phase == .failed) return false;
        if (self.self_address == 0) self.self_address = @intFromPtr(self);
        if (self.self_address != @intFromPtr(self)) return error.Stale;
        const run = product.running.?;
        defer run.cursor_reserving = self.exclusive();
        return self.advance(product) catch |err| {
            if (err == error.Busy) return false;
            // Before publication, optional cursor failures preserve the
            // display. Never release or relabel any unconfirmed GPU use.
            if (self.job != null and self.phase != .reply and run.failure == null and run.cursor_upload == null and
                run.cursor_point == null and run.display_work == null and run.display_upload_job == null and
                run.native_active == null and run.display_channel_active == null and
                (err == error.Unsupported or err == error.Bounds or err == error.Memory or err == error.Map or
                    err == error.Deadline or err == error.Timeout or err == error.Exhausted)) {
                self.reply(product, false, if (err == error.Deadline or err == error.Timeout) a.gfx_output_error_timeout else a.gfx_output_error_unsupported);
                return true;
            }
            self.quarantine(product, err); return err;
        };
    }
    fn capabilities(self: *const Owner, product: anytype) a.DisplayCursorInfo {
        return .{ .head_id = product.mode.?.head, .backend = product.backend, .display_generation = product.receipt.generation,
            .flags = if (self.disabled) 0 else 15, .max_width = image.max_size, .max_height = image.max_size,
            .min_x = std.math.minInt(i16), .min_y = std.math.minInt(i16), .max_x = std.math.maxInt(i16), .max_y = std.math.maxInt(i16) };
    }
    fn advance(self: *Owner, product: anytype) !bool {
        const run = product.running.?;
        const now = product.last_clock;
        if (self.job) |job| if (self.phase != .reply and now >= job.deadline_ns) return error.Deadline;
        switch (self.phase) {
            .detached => {
                if (!product.display.?.supportsCursor() or product.mode.?.cursor_size == 0) { self.phase = .unavailable; return false; }
                if (run.head_events == null) return false;
                const value = self.capabilities(product);
                const result = product.display.?.cursorConfigure(&value);
                if (result == a.gfx_output_error_busy) return false;
                if (result == a.gfx_output_error_unsupported or result == a.err_no_fn) { self.phase = .unavailable; return false; }
                if (result != a.gfx_output_ok) return error.CursorApi;
                self.configured = true; self.phase = .idle;
                product.ctx.?.logInfo("NVIDIA cursor: available image=ARGB8888 size=256 point=PIO completion=CE,Core,head-IRQ,ARM");
            },
            .idle => {
                if (product.modes.job != null or (product.modes.phase != .idle and product.modes.phase != .decision and
                    product.modes.phase != .unavailable and product.modes.phase != .detached)) return false;
                var job: a.GfxDriverCursorJob = .{};
                const result = product.display.?.cursorTake(&product.backend, &job);
                if (result == a.gfx_output_error_busy) return false;
                if (result == 0) {
                    if (self.disabled) {
                        const value = self.capabilities(product);
                        if (product.display.?.cursorConfigure(&value) == a.gfx_output_ok) self.phase = .unavailable;
                    }
                    return false;
                }
                if (result != a.gfx_output_ok) return error.CursorApi;
                self.job = job;
                if (job.version != 1 or job.size < @sizeOf(a.GfxDriverCursorJob) or job.sequence == 0 or job.deadline_ns <= now or
                    job.deadline_ns == std.math.maxInt(u64) or !std.meta.eql(job.backend, product.backend) or
                    job.request.version != 1 or job.request.size < @sizeOf(a.DisplayCursorRequest) or
                    job.request.display_generation != product.receipt.generation or job.request.head_id != product.mode.?.head or
                    job.request.operation > a.display_cursor_operation_release or (job.barrier_timeline == 0) != (job.barrier_point == 0)) return error.Descriptor;
                const request = job.request;
                if (request.operation == a.display_cursor_operation_prepare) {
                    if (self.disabled) { self.reply(product, false, a.gfx_output_error_unsupported); return true; }
                    if (run.cursor_storage != null and run.cursor_storage.?.active != null) return error.State;
                    self.plan = try image.make(request.width, request.height, request.hotspot_x, request.hotspot_y, request.pitch, request.byte_length);
                    self.phase = if (run.cursor_storage == null) .allocate else if (self.channel == null) .channel else .upload;
                } else if (request.operation == a.display_cursor_operation_show or request.operation == a.display_cursor_operation_move) {
                    if (self.image_slot == null or self.channel == null or request.image_sequence != self.image_sequence or self.image_sequence == 0) return error.Stale;
                    self.phase = if (request.operation == a.display_cursor_operation_show) .barrier else .point;
                } else if (run.cursor_storage == null or run.cursor_storage.?.active == null) self.reply(product, true, 0)
                else self.phase = .commit;
            },
            .allocate => {
                if (!run.cursorWorkAvailable()) return false;
                self.allocation = try run.allocateNativeStorage(2 * image.max_bytes, self.job.?.deadline_ns);
                self.phase = .allocation_wait;
            },
            .allocation_wait => {
                const result = try run.nativeBufferStatus(self.allocation.?);
                if (result.state != .handed_off or run.native_active != null) return false;
                if (result.info == null) { self.disabled = true; return error.Unsupported; }
                self.phase = .bind;
            },
            .bind => {
                _ = try run.bindCursorStorage(product.engine.?, self.allocation.?, product.mode.?.head);
                self.phase = .release_creator;
            },
            .release_creator => {
                try run.releaseNativeBuffer(self.allocation.?);
                self.phase = .table_upload;
            },
            .table_upload => {
                try run.uploadDisplayTable(product.engine.?, product.copy.?, self.job.?.deadline_ns);
                self.phase = .table_wait;
            },
            .table_wait => {
                const table = try run.displayTableStatus(product.engine.?);
                if (table.uploading) return false;
                if (table.revision != table.published_revision) return error.Completion;
                self.phase = if (self.channel == null) .channel else .upload;
            },
            .channel => {
                self.channel = try run.createDisplayChannel(product.engine.?, .cursor, product.mode.?.head, self.job.?.deadline_ns);
                self.phase = .channel_wait;
            },
            .channel_wait => {
                const result = try run.displayChannelStatus(self.channel.?);
                if (run.display_channel_active != null) return false;
                if (result.info == null) { self.disabled = true; return error.Unsupported; }
                self.phase = .upload;
            },
            .upload => {
                try run.uploadCursorImage(product.copy.?, self.job.?.request.reference, self.plan.?, self.next_slot, self.job.?.deadline_ns);
                self.phase = .upload_wait;
            },
            .upload_wait => {
                if (run.cursor_upload != null) return false;
                if (run.cursor_storage.?.upload_error) |err| return err;
                const ready = run.cursor_storage.?.uploaded[self.next_slot] orelse return error.Completion;
                if (ready.point == 0 or !std.meta.eql(ready.plan, self.plan.?)) return error.Completion;
                self.image_slot = self.next_slot; self.next_slot ^= 1; self.image_sequence = self.job.?.sequence;
                self.reply(product, true, 0);
            },
            .barrier => {
                const job = self.job.?;
                if (job.barrier_point != 0) {
                    const seen = run.flip_receipts[product.mode.?.head] orelse return false;
                    if (seen.epoch != run.epoch or seen.head != job.request.head_id or seen.source_timeline != job.barrier_timeline or
                        seen.source_point < job.barrier_point or seen.begun_observed_ns == 0) return false;
                }
                self.phase = .point;
            },
            .point => {
                self.point_sequence = try run.moveCursor(self.channel.?, self.job.?.request.x, self.job.?.request.y, self.job.?.deadline_ns);
                self.phase = .point_wait;
            },
            .point_wait => {
                if (run.cursor_point != null) return false;
                const seen = run.display_channels[self.channel.?.slot].?.point.completed orelse return error.Completion;
                if (seen.sequence != self.point_sequence or seen.point.x != self.job.?.request.x or seen.point.y != self.job.?.request.y) return error.Completion;
                if (self.job.?.request.operation == a.display_cursor_operation_move) self.reply(product, true, 0) else self.phase = .commit;
            },
            .commit => {
                const showing = self.job.?.request.operation == a.display_cursor_operation_show;
                self.commit_sequence = try run.commitCursorImage(product.core.?, if (showing) self.image_slot else null, self.job.?.deadline_ns);
                self.phase = .commit_wait;
            },
            .commit_wait => {
                if (run.display_work != null) return false;
                if (run.cursor_storage.?.completed != self.commit_sequence) return error.Completion;
                const showing = self.job.?.request.operation == a.display_cursor_operation_show;
                if (showing != (run.cursor_storage.?.active != null) or (showing and run.cursor_storage.?.active != self.image_slot)) return error.Completion;
                self.reply(product, true, 0);
            },
            .reply => {
                const result = product.display.?.cursorComplete(&self.receipt);
                if (result == a.gfx_output_error_busy) return false;
                if (result != a.gfx_output_ok) return error.CursorApi;
                if (self.job.?.request.operation == a.display_cursor_operation_release and self.receipt.outcome == a.gfx_output_outcome_applied) {
                    self.image_sequence = 0; self.image_slot = null;
                }
                self.job = null; self.phase = .idle;
            },
            .unavailable, .failed => return false,
        }
        return true;
    }
    fn reply(self: *Owner, product: anytype, applied: bool, error_code: i32) void {
        const run = product.running.?;
        self.receipt = .{ .sequence = self.job.?.sequence, .display_generation = self.job.?.request.display_generation,
            .outcome = if (applied) a.gfx_output_outcome_applied else a.gfx_output_outcome_old_preserved, .error_code = error_code,
            .visibility = if (run.cursor_storage != null and run.cursor_storage.?.active != null) a.display_cursor_visibility_visible else a.display_cursor_visibility_hidden };
        self.phase = .reply;
    }
    pub fn quarantine(self: *Owner, product: anytype, err: anyerror) void {
        if (self.phase == .failed) return;
        if (self.job) |job| {
            self.receipt = .{ .sequence = job.sequence, .display_generation = job.request.display_generation,
                .outcome = a.gfx_output_outcome_lost, .visibility = a.display_cursor_visibility_unknown,
                .error_code = if (err == error.Deadline or err == error.Timeout) a.gfx_output_error_timeout else a.gfx_output_error_unavailable };
            _ = product.display.?.cursorComplete(&self.receipt);
        }
        self.failure = err; self.phase = .failed;
        product.running.?.cursor_reserving = false;
    }
};
