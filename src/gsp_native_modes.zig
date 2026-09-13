//! Bounded common mode-job consumer in the serialized native Device worker.
//! The common owner lends SYSTEM references and owns the confirmation timer;
//! this owner proves real GPU changes and retires only its own resources.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const runtime = @import("gsp_runtime.zig");

pub const Phase = enum {
    detached, unavailable, catalog_next, catalog_query, catalog_wait, enable, publish,
    idle, decision, query, query_wait, allocate, allocate_wait, bind, release_creator,
    table_upload, table_wait, prepare, image_upload, image_wait, commit, commit_wait,
    select, retire_shadow, remove_image, withdraw_upload, withdraw_wait, retire_native,
    reply, failed,
};
pub const Owner = struct {
    self_address: usize = 0,
    phase: Phase = .detached,
    failed_phase: ?Phase = null,
    failure: ?anyerror = null,
    last_status: i32 = 0,
    deadline: u64 = 0,
    cursor: u32 = 0,
    publication: a.GfxOutputPublication = .{},
    plan: ?runtime.boot_mode.Plan = null,
    job: ?a.GfxDriverModeJob = null,
    applied: ?a.GfxDriverModeJob = null,
    previous: ?runtime.ActiveDisplayImage = null,
    previous_storage: ?runtime.BufferHandle = null,
    candidate: u32 = 0,
    candidate_storage: ?runtime.BufferHandle = null,
    retire_dma: u32 = 0,
    retire_storage: ?runtime.BufferHandle = null,
    retire_group: a.GfxBufferHandle = .{},
    outcome: u32 = 0,
    error_code: i32 = 0,
    completed_ticket: u64 = 0,
    diagnostic: @import("gsp_mode_diagnostics.zig").Report = .{},

    pub fn step(self: *Owner, product: anytype) !bool {
        if (self.phase == .failed or self.phase == .unavailable) return false;
        if (self.self_address == 0) self.self_address = @intFromPtr(self);
        if (self.self_address != @intFromPtr(self)) return error.Stale;
        return self.advance(product) catch |err| {
            if (err == error.Busy) return false;
            // Before any candidate resource or display submission, failure
            // can preserve the current image without claiming a GPU restore.
            if (self.job != null and self.job.?.operation == a.gfx_mode_operation_apply and
                self.candidate_storage == null and self.candidate == 0 and product.running.?.failure == null and
                !product.running.?.mode_control_active and self.phase != .reply and
                (err == error.Unsupported or err == error.Descriptor or err == error.Memory or
                    err == error.Bounds or err == error.Exhausted or err == error.Deadline)) {
                self.error_code = if (err == error.Deadline) a.gfx_output_error_timeout else a.gfx_output_error_unsupported;
                self.diagnostic.failed(@tagName(self.phase), err);
                self.outcome = a.gfx_output_outcome_old_preserved; self.phase = .reply;
                return true;
            }
            self.quarantine(product, err);
            return err;
        };
    }
    fn advance(self: *Owner, product: anytype) !bool {
        const run = product.running.?;
        const now = product.last_clock;
        if (self.phase != .detached and self.phase != .idle and self.phase != .decision and self.phase != .reply and
            now >= self.deadline) return error.Deadline;
        switch (self.phase) {
            .detached => {
                if (!product.outputs.?.supportsModes() or product.receiver.flags & a.gfx_output_flag_connected == 0 or
                    product.receiver.flags & (a.gfx_output_flag_receiver_incomplete | a.gfx_output_flag_edid_invalid | a.gfx_output_flag_edid_missing) != 0) {
                    self.phase = .unavailable; return false;
                }
                self.publication = product.publication;
                self.publication.modes = @splat(.{});
                self.publication.info.mode_count = 0; self.publication.info.preferred_mode_id = 0;
                self.publication.info.limits.max_width = 0; self.publication.info.limits.max_height = 0;
                self.deadline = now +| (5 * std.time.ns_per_s);
                self.phase = .catalog_next;
            },
            .catalog_next => {
                if (self.cursor == product.receiver.mode_count) {
                    if (self.publication.info.mode_count == 0) { self.phase = .unavailable; return true; }
                    self.publication.info.limits.flags = a.gfx_output_limit_modeset;
                    self.phase = .enable; return true;
                }
                const mode = product.receiver.modes[self.cursor];
                self.plan = run.displayModePlan(product.engine.?, product.mode.?.window, mode.mode_id) catch |err| {
                    if (err == error.Unsupported) { self.cursor += 1; return true; }
                    return err;
                };
                run.validateModeQuery(product.engine.?, self.plan.?) catch |err| {
                    if (err == error.Unsupported) { self.cursor += 1; return true; }
                    return err;
                };
                self.checkSurface(run, mode.width, mode.height) catch |err| {
                    if (err == error.Unsupported or err == error.Bounds) { self.cursor += 1; return true; }
                    return err;
                };
                self.deadline = now +| (5 * std.time.ns_per_s);
                self.phase = .catalog_query;
            },
            .catalog_query => {
                try run.queryDisplayMode(product.mode_control.?, self.plan.?, self.deadline);
                self.phase = .catalog_wait;
            },
            .catalog_wait => {
                const status = try run.modeControlStatus(product.mode_control.?);
                if (status.state != .handed_off or run.mode_control_active) return false;
                if (status.rejected != null or status.unavailable) { self.phase = .unavailable; return true; }
                const proof = status.info orelse return error.State;
                if (proof.possible and !proof.over_clock and std.meta.eql(proof.mode, self.plan.?)) {
                    const mode = product.receiver.modes[self.cursor];
                    const info = &self.publication.info;
                    self.publication.modes[info.mode_count] = mode; info.mode_count += 1;
                    if (info.preferred_mode_id == 0 or mode.flags & a.gfx_output_mode_preferred != 0) info.preferred_mode_id = mode.mode_id;
                    info.limits.max_width = @max(info.limits.max_width, mode.width);
                    info.limits.max_height = @max(info.limits.max_height, mode.height);
                    // This is an admission envelope for individually IMP-
                    // checked modes on one head, not measured GPU throughput.
                    info.limits.max_pixel_clock_hz = @max(info.limits.max_pixel_clock_hz, mode.pixel_clock_hz);
                    info.limits.total_pixel_clock_hz = info.limits.max_pixel_clock_hz;
                    const bytes = @as(u64, mode.width) * 4 * mode.height;
                    const rate = try std.math.add(u64, try std.math.mul(u64, bytes, mode.refresh_millihz), 999);
                    info.limits.bandwidth_bytes_per_second = @max(info.limits.bandwidth_bytes_per_second, rate / 1000);
                }
                self.cursor += 1; self.phase = .catalog_next;
            },
            .enable => {
                self.last_status = product.outputs.?.enableModes(&product.backend);
                if (self.last_status == a.gfx_output_error_busy) return false;
                if (self.last_status != a.gfx_output_ok) return error.ModeApi;
                run.require_mode_receipt = true;
                self.phase = .publish;
            },
            .publish => {
                var identity: a.GfxOutputId = .{};
                self.last_status = product.outputs.?.publish(&self.publication, &identity);
                if (self.last_status == a.gfx_output_error_busy) return false;
                if (self.last_status != a.gfx_output_ok or identity.adapter_id != product.backend.adapter_id or
                    identity.device_generation != product.backend.device_generation or identity.connector_id != product.output.connector_id or
                    identity.connection_generation == 0) return error.Catalog;
                product.publication = self.publication; product.output = identity;
                self.phase = .idle;
                product.ctx.?.logInfo("NVIDIA native-modes: ready source=EDID,OR-clock,IMP operation=apply,confirm,rollback");
            },
            .idle, .decision => return self.take(product),
            .query => {
                try run.queryDisplayMode(product.mode_control.?, self.plan.?, self.deadline);
                self.phase = .query_wait;
            },
            .query_wait => {
                const status = try run.modeControlStatus(product.mode_control.?);
                if (status.state != .handed_off or run.mode_control_active) return false;
                const proof = status.info orelse return error.Unsupported;
                if (status.rejected != null or status.unavailable or !proof.possible or proof.over_clock or
                    proof.receipt == 0 or !std.meta.eql(proof.mode, self.plan.?)) return error.Unsupported;
                self.phase = if (self.job.?.operation == a.gfx_mode_operation_apply) .allocate else .commit;
            },
            .allocate => {
                self.candidate_storage = try run.allocateDisplaySurface(.{ .width = self.plan.?.width, .height = self.plan.?.height,
                    .usage = a.gfx_buffer_usage_transfer_target | a.gfx_buffer_usage_scanout }, self.deadline);
                self.phase = .allocate_wait;
            },
            .allocate_wait => {
                const status = try run.nativeBufferStatus(self.candidate_storage.?);
                if (status.state != .handed_off or run.native_active != null) return false;
                if (status.info == null or status.rejected != null or status.host_rejected != null) return error.Memory;
                self.phase = .bind;
            },
            .bind => {
                self.candidate = try run.bindDisplayStorage(product.engine.?, .window, product.mode.?.window, self.candidate_storage.?);
                self.phase = .release_creator;
            },
            .release_creator => {
                try run.releaseNativeBuffer(self.candidate_storage.?);
                self.phase = .table_upload;
            },
            .table_upload => {
                try run.uploadDisplayTable(product.engine.?, product.copy.?, self.deadline);
                self.phase = .table_wait;
            },
            .table_wait => {
                const status = try run.displayTableStatus(product.engine.?);
                if (status.uploading) return false;
                if (status.published_revision != status.revision) return error.Completion;
                self.phase = .prepare;
            },
            .prepare => {
                try run.prepareDisplayPresentationImage(self.candidate, self.job.?.reference, self.deadline);
                self.phase = .image_upload;
            },
            .image_upload => {
                try run.uploadDisplayPresentationImage(self.candidate, self.deadline);
                self.phase = .image_wait;
            },
            .image_wait => {
                const status = try run.presentationImageStatus(self.candidate);
                if (status.failure) |err| return err;
                if (status.pending or status.completed == 0) return false;
                self.phase = .commit;
            },
            .commit => {
                const dma = if (self.job.?.operation == a.gfx_mode_operation_apply) self.candidate else self.previous.?.image.dma;
                try run.commitModeDisplayImage(product.core.?, product.window.?, dma, self.plan.?.receiver_mode_id, self.deadline);
                self.phase = .commit_wait;
            },
            .commit_wait => {
                if (run.display_work != null) return false;
                const image = try run.displayImageStatus(product.engine.?, product.mode.?.window) orelse return error.Completion;
                if (image.boot_mode == null or !std.meta.eql(image.boot_mode.?, self.plan.?) or image.mode_receipt == 0 or
                    image.core_point == 0 or image.window_point == 0 or image.link == null or image.link.?.receipt == 0) return error.Completion;
                self.phase = .select;
            },
            .select => {
                if (self.job.?.operation == a.gfx_mode_operation_apply) {
                    try run.selectDisplayPresentationImage(self.candidate);
                    self.outcome = a.gfx_output_outcome_applied; self.phase = .reply;
                } else {
                    try run.selectDisplayPresentationImage(self.previous.?.image.dma);
                    self.retire_dma = self.candidate; self.retire_storage = self.candidate_storage;
                    self.outcome = a.gfx_output_outcome_old_preserved; self.phase = .retire_shadow;
                }
            },
            .retire_shadow => {
                if (self.retire_group.id == 0) self.retire_group = try run.presentationImageBuffer(self.retire_dma);
                if (!try run.retireDisplayPresentationImage(self.retire_dma, self.deadline)) return false;
                self.phase = .remove_image;
            },
            .remove_image => {
                try run.removeDisplayImage(product.engine.?, product.mode.?.window, self.retire_dma);
                self.phase = .withdraw_upload;
            },
            .withdraw_upload => {
                try run.uploadDisplayTable(product.engine.?, product.copy.?, self.deadline);
                self.phase = .withdraw_wait;
            },
            .withdraw_wait => {
                const status = try run.displayTableStatus(product.engine.?);
                if (status.uploading) return false;
                if (status.published_revision != status.revision) return error.Completion;
                self.phase = .retire_native;
            },
            .retire_native => {
                _ = run.nativeBufferStatus(self.retire_storage.?) catch |err| {
                    if (err != error.Stale) return err;
                    if (run.native_active != null) return false;
                    if (run.presentationPeer(self.retire_group)) |dma| {
                        self.retire_dma = dma; self.retire_storage = try imageStorage(run, dma);
                        self.phase = .retire_shadow; return true;
                    }
                    self.phase = .reply; return true;
                };
                return false;
            },
            .reply => {
                const job = self.job.?;
                const receipt: a.GfxDriverModeCompletion = .{ .ticket = job.ticket, .sequence = job.sequence, .operation = job.operation,
                    .outcome = self.outcome, .quiesced = if (self.outcome == a.gfx_output_outcome_applied) 1 else 2, .error_code = self.error_code };
                self.last_status = product.outputs.?.completeMode(&receipt);
                self.diagnostic.finish(product, @tagName(self.phase), receipt, self.last_status);
                if (self.last_status != a.gfx_output_ok) return error.ModeApi;
                self.log(product, "complete");
                if (job.operation == a.gfx_mode_operation_apply and self.outcome == a.gfx_output_outcome_applied) {
                    self.applied = job; self.phase = .decision;
                } else {
                    self.completed_ticket = job.ticket; self.applied = null; self.previous = null; self.previous_storage = null;
                    self.candidate = 0; self.candidate_storage = null; self.retire_dma = 0; self.retire_storage = null; self.phase = .idle;
                    self.retire_group = .{};
                }
                self.job = null;
            },
            .unavailable, .failed => return false,
        }
        return true;
    }
    fn take(self: *Owner, product: anytype) !bool {
        var job: a.GfxDriverModeJob = .{};
        const status = product.outputs.?.takeMode(&product.backend, &job);
        if (status == 0) return false;
        if (status != a.gfx_output_ok) return error.ModeApi;
        self.job = job; self.deadline = job.deadline_ns; self.error_code = 0; self.outcome = 0;
        self.diagnostic.begin(product, job);
        if (job.version != 1 or job.size < @sizeOf(a.GfxDriverModeJob) or job.reserved0 != 0 or job.ticket == 0 or job.sequence == 0 or
            !std.meta.eql(job.backend, product.backend) or !std.meta.eql(job.assignment.output, product.output)) return error.Stale;
        if (self.phase == .decision) {
            const previous = self.applied.?;
            if (job.ticket != previous.ticket or job.sequence != previous.sequence + 1 or
                !std.meta.eql(job.assignment, previous.assignment) or !std.meta.eql(job.mode, previous.mode) or !std.meta.eql(job.reference, previous.reference)) return error.Stale;
            if (job.operation == a.gfx_mode_operation_confirm) {
                if (!std.meta.eql(product.running.?.presentation.?.surface.shadow.buffer,
                    try product.running.?.presentationImageBuffer(self.candidate))) return error.Stale;
                self.retire_dma = self.previous.?.image.dma; self.retire_storage = self.previous_storage;
                self.outcome = a.gfx_output_outcome_applied; self.phase = .retire_shadow;
            } else if (job.operation == a.gfx_mode_operation_rollback) {
                self.plan = try product.running.?.displayModePlan(product.engine.?, product.mode.?.window, self.previous.?.boot_mode.?.receiver_mode_id);
                if (!std.meta.eql(self.plan.?, self.previous.?.boot_mode.?)) return error.Stale;
                self.phase = .query;
            } else return error.State;
        } else {
            if (job.operation != a.gfx_mode_operation_apply or job.ticket <= self.completed_ticket or job.sequence != 1) return error.Stale;
            try self.validateApply(product, job);
            self.previous = (try product.running.?.displayImageStatus(product.engine.?, product.mode.?.window)) orelse return error.State;
            self.previous_storage = try imageStorage(product.running.?, self.previous.?.image.dma);
            self.plan = try product.running.?.displayModePlan(product.engine.?, product.mode.?.window, job.mode.mode_id);
            self.phase = .query;
        }
        self.log(product, "begin");
        return true;
    }
    fn validateApply(self: *Owner, product: anytype, job: a.GfxDriverModeJob) !void {
        _ = self;
        const assignment = job.assignment;
        if (assignment.version != 1 or assignment.size < @sizeOf(a.GfxScanoutState) or assignment.reserved0 != 0 or
            assignment.mode_id != job.mode.mode_id or assignment.head_id != product.mode.?.head or
            assignment.plane_id != product.mode.?.window or assignment.pll_id != product.mode.?.head or
            assignment.source_x != 0 or assignment.source_y != 0 or assignment.destination_x != 0 or assignment.destination_y != 0 or
            assignment.source_width != job.mode.width or assignment.source_height != job.mode.height or
            assignment.destination_width != job.mode.width or assignment.destination_height != job.mode.height or
            assignment.rotation != 0 or assignment.color != 0 or assignment.bits_per_color != 8) return error.Unsupported;
        var found = false;
        for (product.publication.modes[0..product.publication.info.mode_count]) |mode| if (std.meta.eql(mode, job.mode)) { found = true; break; };
        if (!found) return error.Unsupported;
        const ref = job.reference;
        if (ref.version != 1 or ref.size < @sizeOf(a.GfxBufferReference) or ref.flags != 0 or ref.reserved0 != 0 or
            ref.reference.id == 0 or ref.reference.generation == 0 or ref.reference.reserved0 != 0 or
            ref.buffer.id == 0 or ref.buffer.generation == 0 or ref.buffer.reserved0 != 0 or
            std.meta.eql(ref.buffer, product.running.?.presentation.?.surface.shadow.buffer)) return error.Descriptor;
        var d: a.GfxBufferDescriptor = .{};
        if (product.memory.?.bufferDescribe(&ref.reference, &d) != a.gfx_buffer_result_ok) return error.Memory;
        const usage = a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source | a.gfx_buffer_usage_scanout;
        if (d.version != 1 or d.size < @sizeOf(a.GfxBufferDescriptor) or d.location != a.gfx_buffer_location_system or
            d.adapter_id != 0 or d.device_generation != 0 or d.modifier != 0 or d.format != a.gfx_buffer_format_xrgb8888 or
            d.width != job.mode.width or d.height != job.mode.height or d.plane_count != 1 or d.plane_offsets[0] != 0 or
            d.plane_pitches[0] != @as(u64, d.width) * 4 or d.byte_length != d.plane_pitches[0] * d.height or d.usage & usage != usage) return error.Descriptor;
    }
    fn checkSurface(_: *Owner, run: *runtime.Owner, width: u32, height: u32) !void {
        const space = (run.nativeAddressSpace() orelse return error.Busy).*;
        const caps = run.nativeMemoryCapabilities() orelse return error.Busy;
        const memory = run.nativeMemory() orelse return error.Busy;
        const plan = try runtime.vram.surface.create(run.adapter_id, space, caps, .{ .width = width, .height = height, .usage = 40 });
        _ = try runtime.display_resources.image.create(plan, 1, 1);
        const policy: runtime.vram.storage.Policy = .{ .capabilities = caps, .physical_bytes = @min(memory.physical_bytes, memory.reported_bytes), .role = .scanout };
        try policy.validate(space, plan.allocation_bytes);
    }
    fn imageStorage(run: *runtime.Owner, dma: u32) !runtime.BufferHandle {
        const resources = run.display_resources_slot.owner orelse return error.State;
        const entry = run.presentation orelse return error.State;
        const source = (resources.publishedStorage(entry.window.slot, dma) orelse return error.Stale).info() orelse return error.Stale;
        // The creator reference was closed after the display Use imported it,
        // so Owner.info() deliberately no longer exports that closed alias.
        // Match the retained allocator against the live Use instead.
        for (&run.native_buffers, 0..) |*slot, index| if (slot.owner) |owner| {
            if (owner.self_address == @intFromPtr(owner) and owner.failure == null and owner.committed and owner.common_live and
                owner.namespace_live and owner.mapped and owner.storage_claimed and owner.state == .handed_off and
                owner.binding.space.epoch == source.epoch and owner.adapter == source.adapter and
                owner.address == source.address and owner.logical_bytes == source.bytes and
                std.meta.eql(owner.reservation.buffer, source.reference.buffer) and std.meta.eql(owner.reservation, owner.reservation_stamp))
                return .{ .epoch = run.epoch, .serial = slot.serial, .slot = @intCast(index) };
        };
        return error.Stale;
    }
    pub fn quarantine(self: *Owner, product: anytype, err: anyerror) void {
        if (self.phase == .detached or self.phase == .failed or self.phase == .unavailable) return;
        self.failed_phase = self.phase; self.failure = err;
        self.phase = .failed;
        if (self.job) |job| {
            self.outcome = a.gfx_output_outcome_lost;
            self.error_code = if (err == error.Timeout or err == error.Deadline) a.gfx_output_error_timeout else a.gfx_output_error_unavailable;
            const receipt: a.GfxDriverModeCompletion = .{ .ticket = job.ticket, .sequence = job.sequence,
                .operation = job.operation, .outcome = self.outcome, .quiesced = 0, .error_code = self.error_code };
            self.last_status = product.outputs.?.completeMode(&receipt);
            self.diagnostic.failed(@tagName(self.failed_phase.?), err);
            self.diagnostic.finish(product, @tagName(self.failed_phase.?), receipt, self.last_status);
        }
        self.log(product, "failed-held");
    }
    fn log(self: *Owner, product: anytype, event: []const u8) void {
        var buffer: [240]u8 = undefined;
        const job = self.job orelse self.applied orelse a.GfxDriverModeJob{};
        const text = std.fmt.bufPrintZ(&buffer, "NVIDIA native-modes: {s} ticket={d} sequence={d} operation={d} phase={s} old={d} new={d} outcome={d} status={d}",
            .{event,job.ticket,job.sequence,job.operation,@tagName(self.failed_phase orelse self.phase),if(self.previous)|old|old.image.dma else 0,self.candidate,self.outcome,self.last_status}) catch return;
        product.ctx.?.logInfo(text);
    }
};
