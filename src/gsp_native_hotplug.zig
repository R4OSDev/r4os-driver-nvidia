//! Connector lifecycle inside the serialized Device worker. Receiver metadata,
//! physical retirement and the common CPU image retain separate ownership.
const std = @import("std");
const a = @import("r4os").abi;
const runtime = @import("gsp_runtime.zig");
const receiver = @import("gsp_hotplug.zig");
const reconnect = @import("gsp_reconnect.zig");
pub const Phase = enum { online, pause, drain, mute, mute_wait, clear, clear_wait, detach, detach_wait,
    settle, receiver_wait, query, query_wait, refresh, refresh_wait, commit, commit_wait, publish, unpause,
    resize, resize_publish, resize_catalog, source_create, source_map, source_clear, source_unmap, resize_submit, resize_wait, restore_unavailable };
pub const Owner = struct {
    phase: Phase = .online,
    initialized: bool = false,
    sequence: u64 = 0,
    generation: u64 = 0,
    attempted_generation: u64 = 0,
    deadline: u64 = 0,
    audio_sequence: u64 = 0,
    plan: ?runtime.boot_mode.Plan = null,
    previous: ?runtime.boot_mode.Plan = null,
    observation: ?receiver.Observation = null,
    transitions: u64 = 0,
    restores: u64 = 0,
    source: a.GfxBufferReference = .{},
    source_map: a.GfxBufferMap = .{},
    source_descriptor: a.GfxBufferDescriptor = .{},
    cleared: u64 = 0,
    restore_ticket: u64 = 0,

    pub fn step(self: *Owner, product: anytype) !bool {
        const run = product.running.?;
        if (!self.initialized) {
            self.initialized = true; self.sequence = run.receiver_events.sequence;
            self.generation = product.mode.?.output_generation;
            if (run.nativeOutputs()) |snapshot| self.observation = try receiver.observe(snapshot, product.mode.?.signal.display_id);
        }
        const changed = self.sequence != run.receiver_events.sequence or
            (self.phase == .online and (run.outputs.invalidated or run.output_generation != self.generation)) or
            (self.plan != null and (run.outputs.invalidated or run.output_generation != self.plan.?.output_generation));
        if (changed) {
            self.sequence = run.receiver_events.sequence;
            self.deadline = product.last_clock +| 30 * std.time.ns_per_s;
            self.plan = null; self.attempted_generation = 0;
            if (self.phase == .online) self.transitions +|= 1;
            self.phase = if (product.output.connection_generation != 0) .pause else .drain;
            run.display_paused = true;
            run.display_restoring = false;
            product.ctx.?.logInfo("NVIDIA hotplug: state=draining receiver=invalidated present=paused shadow=retained");
        }
        if (self.phase == .online) return false;
        if (self.phase != .receiver_wait and product.last_clock >= self.deadline) return error.Deadline;
        return self.advance(product) catch |err| {
            if (err == error.Busy) return false;
            return err;
        };
    }
    fn advance(self: *Owner, product: anytype) !bool {
        const run = product.running.?;
        const window = product.mode.?.window;
        switch (self.phase) {
            .online => return false,
            .pause => {
                const result = product.outputs.?.pauseOutput(&product.output, true);
                if (result == a.gfx_output_error_busy) return false;
                if (result != a.gfx_output_ok) return error.Catalog;
                self.phase = .drain;
            },
            .drain => {
                if (try self.releaseSource(product)) return true;
                try run.cancelModeQuery();
                if (run.frame_setup != null) return run.prepareFramePool();
                if (try product.cursor.pause(product)) return true;
                if (try product.modes.pause(product)) return true;
                if (!run.cursorWorkAvailable() or run.native_active != null or run.buffer_active != null or
                    run.display_channel_active != null or run.display_engine_active) return false;
                run.cursor_reserving = false;
                if (run.display_images[window]) |image| {
                    self.previous = image.boot_mode orelse return error.State;
                    self.phase = if (self.previous.?.transport_hdmi) .mute else .detach;
                } else if (run.display_retired[window] != null) self.phase = .settle else return error.State;
            },
            .mute, .clear => {
                self.audio_sequence = try run.beginHdmiDisconnect(window, if (self.phase == .mute) .mute else .clear, self.deadline);
                self.phase = if (self.phase == .mute) .mute_wait else .clear_wait;
            },
            .mute_wait, .clear_wait => {
                if (run.audio_work != null) return false;
                const receipt = run.audio_result orelse return error.Completion;
                if (receipt.sequence != self.audio_sequence or receipt.receipt == 0 or receipt.status != 0 or
                    receipt.operation != @as(runtime.hdmi_audio.Operation, if (self.phase == .mute_wait) .mute else .clear)) return error.Completion;
                self.phase = if (self.phase == .mute_wait) .clear else .detach;
            },
            .detach => { try run.detachDisplayImage(product.core.?, product.window.?, self.deadline); self.phase = .detach_wait; },
            .detach_wait => {
                if (run.display_work != null) return false;
                const retired = run.display_retired[window] orelse return error.Completion;
                if (retired.epoch != run.epoch or retired.core_point == 0 or retired.window_point == 0 or run.display_images[window] != null) return error.Completion;
                self.phase = .settle;
            },
            .settle => {
                // Withdrawal requests common rollback while its old identity
                // remains bound. Complete the matching job, then retry.
                var pending = false;
                if (product.output.connection_generation != 0) {
                    const result = product.outputs.?.withdraw(&product.output);
                    if (result == a.gfx_output_error_busy) pending = true else if (result != a.gfx_output_ok) return error.Catalog
                    else product.output = .{};
                }
                if (!try product.cursor.stopped(product)) return true;
                if (try product.modes.stopped(product)) return true;
                if (pending or product.modes.pending()) return false;
                const completed = product.modes.completed_ticket;
                product.modes = .{ .completed_ticket = completed };
                product.audio.afterStop();
                self.restore_ticket = 0;
                self.phase = .receiver_wait;
                product.ctx.?.logInfo("NVIDIA hotplug: state=headless scanout=quiesced shadow=retained queues=drained");
            },
            .receiver_wait => {
                if (run.outputs.active() or run.outputs.state != .returned or run.outputs.data.generation == self.attempted_generation) return false;
                const snapshot = &run.outputs.data;
                self.attempted_generation = snapshot.generation;
                const seen = try receiver.observe(snapshot, product.mode.?.signal.display_id);
                const changed = self.observation != null and self.observation.?.fingerprint != null and seen.fingerprint != null and
                    !std.meta.eql(self.observation.?.fingerprint.?, seen.fingerprint.?);
                self.observation = seen;
                @import("gsp_mode_diagnostics.zig").write(&product.ctx.?,
                    "NVIDIA hotplug: receiver={s} generation={d} edid-changed={} power=unknown retries={d}",
                    .{@tagName(seen.state),seen.generation,changed,run.receiver_events.retries});
                if (seen.state != .connected or run.nativeOutputs() == null) return true;
                const base = run.bootDisplayPlan(product.engine.?, window) catch |err| {
                    if (err == error.Unsupported or err == error.Routing or err == error.Stale) return true; return err;
                };
                var previous = self.previous orelse product.mode.?;
                const image = run.presentation.?.surface.scanout.?;
                previous.width = image.width; previous.height = image.height;
                const choice = reconnect.choose(base, snapshot, run.nativeObject() orelse return error.Busy, previous) catch |err| {
                    if (err == error.Unsupported or err == error.Unavailable) return true; return err;
                };
                self.plan = choice.plan;
                self.deadline = product.last_clock +| 30 * std.time.ns_per_s;
                self.phase = if (choice.resize) .resize else .query;
            },
            .query => { try run.queryDisplayMode(product.mode_control.?, self.plan.?, self.deadline); self.phase = .query_wait; },
            .query_wait => {
                const status = try run.modeControlStatus(product.mode_control.?);
                if (run.mode_control_active or status.state != .handed_off) return false;
                const proof = status.info orelse { self.plan = null; self.phase = .receiver_wait; return true; };
                if (status.rejected != null or status.unavailable or !proof.possible or proof.over_clock or
                    proof.receipt == 0 or !std.meta.eql(proof.mode, self.plan.?)) {
                    self.plan = null; self.phase = .receiver_wait; return true;
                }
                self.phase = .refresh;
            },
            .refresh => {
                try run.refreshDetachedImage(run.presentation.?.surface.scanout.?.dma, self.deadline);
                self.phase = .refresh_wait;
            },
            .refresh_wait => {
                const status = try run.presentationImageStatus(run.presentation.?.surface.scanout.?.dma);
                if (status.failure) |err| return err;
                if (status.pending or status.completed == 0) return false;
                self.phase = .commit;
            },
            .commit => {
                try run.commitModeDisplayImage(product.core.?, product.window.?, run.presentation.?.surface.scanout.?.dma,
                    self.plan.?.receiver_mode_id, self.deadline);
                self.phase = .commit_wait;
            },
            .commit_wait => {
                if (run.display_work != null) return false;
                const image = run.display_images[window] orelse return error.Completion;
                if (image.boot_mode == null or !std.meta.eql(image.boot_mode.?, self.plan.?) or image.mode_receipt == 0 or
                    image.link == null or image.link.?.receipt == 0 or image.link.?.acknowledged != @as(u8, if (self.plan.?.transport_hdmi) 7 else 2)) return error.Completion;
                product.mode = self.plan; product.link = image.link.?.plan; product.confirmed_image = image;
                try product.buildPublication();
                self.phase = .publish;
            },
            .publish => {
                const result = product.outputs.?.publish(&product.publication, &product.output);
                if (result == a.gfx_output_error_busy) return false;
                if (result != a.gfx_output_ok) return error.Catalog;
                self.phase = .unpause;
            },
            .unpause => {
                const result = product.outputs.?.pauseOutput(&product.output, false);
                if (result == a.gfx_output_error_busy) return false;
                if (result != a.gfx_output_ok) return error.Catalog;
                self.generation = self.plan.?.output_generation;
                self.plan = null; self.phase = .online; self.restores +|= 1;
                product.cursor.resumeOutput();
                run.display_paused = false;
                run.display_restoring = false;
                product.ctx.?.logInfo("NVIDIA hotplug: state=online receiver=fresh image=CPU-refreshed mode=IMP-checked audio=requery");
            },
            .resize => {
                product.mode = self.plan;
                product.link = try runtime.hdmi_link.derive(self.plan.?, run.nativeObject() orelse return error.Busy, run.nativeOutputs() orelse return error.Busy);
                try product.buildPublication();
                self.phase = .resize_publish;
            },
            .resize_publish => {
                const result = product.outputs.?.publish(&product.publication, &product.output);
                if (result == a.gfx_output_error_busy) return false;
                if (result != a.gfx_output_ok) return error.Catalog;
                self.phase = .resize_catalog;
            },
            .resize_catalog => {
                if (product.modes.phase != .idle) {
                    if (product.modes.phase == .unavailable) return self.keepHeadless(product);
                    return product.modes.step(product);
                }
                var admitted = false;
                for (product.publication.modes[0..product.publication.info.mode_count]) |mode|
                    if (mode.mode_id == self.plan.?.receiver_mode_id) { admitted = true; break; };
                if (!admitted) return self.keepHeadless(product);
                self.phase = .source_create;
            },
            .source_create => {
                const pitch = try std.math.mul(u64, self.plan.?.width, 4);
                self.source_descriptor = .{ .width = self.plan.?.width, .height = self.plan.?.height,
                    .byte_length = try std.math.mul(u64, pitch, self.plan.?.height), .format = a.gfx_buffer_format_xrgb8888,
                    .plane_count = 1, .plane_pitches = .{pitch,0,0,0},
                    .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source | a.gfx_buffer_usage_scanout };
                const result = product.memory.?.bufferCreate(&self.source_descriptor, &self.source);
                if (result != a.gfx_buffer_result_ok) {
                    if (self.source.reference.id != 0) return error.Retained;
                    return self.keepHeadless(product);
                }
                if (self.source.reference.id == 0 or self.source.buffer.id == 0) return error.Descriptor;
                self.cleared = 0; self.phase = .source_map;
            },
            .source_map => {
                const result = product.memory.?.bufferMap(&self.source.reference, a.gfx_buffer_map_write, 0,
                    self.source_descriptor.byte_length, &self.source_map);
                if (result != a.gfx_buffer_result_ok) {
                    self.phase = .restore_unavailable;
                    return true;
                }
                if (self.source_map.lease.id == 0 or self.source_map.cpu_address == 0 or
                    self.source_map.byte_length != self.source_descriptor.byte_length or
                    self.source_map.cpu_address > std.math.maxInt(u64) - self.source_map.byte_length) return error.Descriptor;
                self.phase = .source_clear;
            },
            .source_clear => {
                const bytes: [*]u8 = @ptrFromInt(self.source_map.cpu_address);
                const count = @min(@as(u64, 65536), self.source_map.byte_length - self.cleared);
                @memset(bytes[self.cleared..][0..count], 0);
                self.cleared += count;
                if (self.cleared == self.source_map.byte_length) self.phase = .source_unmap;
            },
            .source_unmap => {
                if (product.memory.?.bufferUnmap(&self.source_map.lease) != a.gfx_buffer_result_ok) return error.Map;
                self.source_map = .{}; self.phase = .resize_submit;
            },
            .resize_submit => {
                var input: a.GfxAtomicState = .{ .count = 1 };
                const plan = self.plan.?;
                input.assignments[0] = .{ .output = product.output, .mode_id = plan.receiver_mode_id,
                    .head_id = plan.head, .plane_id = plan.window, .pll_id = plan.head, .bits_per_color = 8,
                    .source_width = plan.width, .source_height = plan.height, .destination_width = plan.width,
                    .destination_height = plan.height, .buffer = self.source.reference };
                var status: a.GfxModeStatus = .{};
                const result = product.outputs.?.restoreMode(&input, &status);
                if (result == a.gfx_output_error_busy) return false;
                if (result != a.gfx_output_ok) {
                    self.phase = .restore_unavailable;
                    return true;
                }
                if (status.ticket == 0 or status.version != 1 or status.size < @sizeOf(a.GfxModeStatus) or
                    !std.meta.eql(status.output, product.output)) return error.Descriptor;
                self.restore_ticket = status.ticket;
                run.display_restoring = true;
                self.phase = .resize_wait;
            },
            .resize_wait => {
                if (try self.releaseSource(product)) return true;
                if (try product.modes.step(product)) return true;
                var status: a.GfxModeStatus = .{};
                const result = product.outputs.?.modeStatus(self.restore_ticket, &status);
                if (result != a.gfx_output_ok or status.ticket != self.restore_ticket or
                    !std.meta.eql(status.output, product.output)) return error.ModeApi;
                if (status.phase == a.gfx_mode_phase_reverted) return self.keepHeadless(product);
                if (status.phase == a.gfx_mode_phase_lost) return error.Completion;
                if (status.phase != a.gfx_mode_phase_confirmed) return false;
                if (product.modes.pending() or product.modes.completed_ticket != self.restore_ticket or
                    status.outcome != a.gfx_output_outcome_applied) return error.Completion;
                const image = run.display_images[window] orelse return error.Completion;
                if (image.boot_mode == null or !std.meta.eql(image.boot_mode.?, self.plan.?) or
                    image.link == null or image.link.?.receipt == 0 or
                    !std.meta.eql(run.presentation.?.surface.scanout.?, image.image)) return error.Completion;
                product.confirmed_image = image;
                self.restore_ticket = 0;
                self.phase = .unpause;
            },
            .restore_unavailable => {
                if (try self.releaseSource(product)) return true;
                return self.keepHeadless(product);
            },
        }
        return true;
    }
    fn releaseSource(self: *Owner, product: anytype) !bool {
        if (self.source_map.lease.id != 0) {
            if (product.memory.?.bufferUnmap(&self.source_map.lease) != a.gfx_buffer_result_ok) return error.Map;
            self.source_map = .{}; return true;
        }
        if (self.source.reference.id != 0) {
            if (product.memory.?.bufferRelease(&self.source.reference) != a.gfx_buffer_result_ok) return error.Retained;
            self.source = .{}; return true;
        }
        return false;
    }
    fn keepHeadless(self: *Owner, product: anytype) bool {
        self.plan = null; self.restore_ticket = 0; self.phase = .receiver_wait;
        product.running.?.display_restoring = false;
        product.ctx.?.logInfo("NVIDIA hotplug: state=headless restore=unavailable shadow=retained retry=next-receiver-event");
        return true;
    }
};
