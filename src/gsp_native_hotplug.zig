//! Connector lifecycle inside the serialized Device worker. Receiver metadata,
//! physical retirement and the common CPU image retain separate ownership.
const std = @import("std");
const a = @import("r4os").abi;
const runtime = @import("gsp_runtime.zig");
const receiver = @import("gsp_hotplug.zig");
pub const Phase = enum { online, pause, drain, mute, mute_wait, disable, disable_wait, clear, clear_wait, detach, detach_wait,
    settle, receiver_wait, query, query_wait, refresh, refresh_wait, commit, commit_wait, publish, unpause,
    resize, resize_publish, resize_catalog, source_create, source_map, source_clear, source_unmap, resize_submit, resize_wait, restore_unavailable,
    power_quiesce, power_off, power_off_wait, power_asleep, power_on, power_on_wait, power_refresh, power_failed };
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
    route: ?runtime.output_route.Claim = null,
    refreshing: bool = false,
    transitions: u64 = 0,
    restores: u64 = 0,
    source: a.GfxBufferReference = .{},
    source_map: a.GfxBufferMap = .{},
    source_descriptor: a.GfxBufferDescriptor = .{},
    cleared: u64 = 0,
    restore_ticket: u64 = 0,
    power_cycle: bool = false,
    power_waking: bool = false,
    power_intent: a.GfxPowerRequest = .{},
    power_published: ?a.GfxOutputPower = null,
    power_sequence: u64 = 0,
    power_receipt: u64 = 0,
    power_attempted: u64 = 0,
    power_generation: u64 = 0,
    power_failure: ?anyerror = null,

    pub fn step(self: *Owner, product: anytype) !bool {
        const run = product.running.?;
        try self.pollPower(product);
        if (!self.initialized) {
            self.initialized = true; self.sequence = run.receiver_events.sequence;
            self.generation = product.mode.?.output_generation;
            if (run.nativeOutputs()) |snapshot| {
                self.observation = try receiver.observe(snapshot, product.mode.?.signal.display_id);
                self.route = try runtime.output_route.identify(product.mode.?, snapshot);
            }
        }
        if (self.phase == .online and self.observation == null and !run.outputs.invalidated and run.output_generation == self.generation) {
            if (run.nativeOutputs()) |snapshot| {
                self.observation = try receiver.observe(snapshot, product.mode.?.signal.display_id);
                self.route = try runtime.output_route.identify(product.mode.?, snapshot);
            }
        }
        const notified = self.sequence != run.receiver_events.sequence;
        const signal = product.mode.?.signal;
        const affected = notified and (run.receiver_events.affects(signal.display_id, self.sequence) or
            (if (signal.mst) |stamp| run.receiver_events.affects(stamp.root, self.sequence) else false));
        const idle_modes = !product.modes.pending() and !product.audio.busy() and !product.cursor.busy() and
            (product.modes.phase == .idle or product.modes.phase == .unavailable or product.modes.phase == .detached);
        if (self.phase == .online and self.power_intent.off != 0 and self.power_intent.sequence != self.power_attempted and
            !affected and !run.outputs.invalidated and idle_modes) {
            self.power_cycle = true; self.power_waking = false; self.power_failure = null;
            self.power_attempted = self.power_intent.sequence;
            self.deadline = product.last_clock +| 30 * std.time.ns_per_s;
            self.phase = .power_quiesce;
            // VRR must stop before outputPaused makes new link work invalid.
            try self.pollPower(product);
            return true;
        }
        if (self.phase == .online and !affected and idle_modes and
            (self.refreshing or (notified and self.route != null and self.observation != null)))
        {
            self.sequence = run.receiver_events.sequence;
            self.refreshing = true;
            if (run.outputs.invalidated or run.outputs.snapshot() == null or run.outputs.data.generation <= self.generation) return false;
            const snapshot = run.outputs.snapshot().?;
            const seen = try receiver.observe(snapshot, product.mode.?.signal.display_id);
            const physical = runtime.output_route.identify(product.mode.?, snapshot) catch null;
            const unchanged = seen.state == .connected and self.observation.?.state == .connected and
                seen.fingerprint != null and std.meta.eql(seen.fingerprint, self.observation.?.fingerprint) and
                physical != null and std.meta.eql(physical.?, self.route.?);
            if (unchanged) {
                if (product.audio.busy() or product.cursor.busy()) return false;
                const updated: ?runtime.Owner.RefreshedDisplay = run.refreshDisplayMetadata(product.mode.?, product.link.?) catch |err| blk: {
                    if (err == error.Busy) return false;
                    break :blk null;
                };
                if (updated) |value| {
                    product.mode = value.mode; product.link = value.link; product.confirmed_image = value.image;
                    self.generation = snapshot.generation; self.observation = seen; self.route = physical;
                    self.refreshing = false;
                    product.ctx.?.logInfo("NVIDIA hotplug: unrelated receiver refresh confirmed own route, timing and image unchanged");
                    return true;
                }
            }
            self.refreshing = false;
            // Changed or incomplete evidence follows ordinary physical
            // retirement. A notification's mask never proves continuity.
        }
        const changed = self.sequence != run.receiver_events.sequence or
            (self.phase == .online and (run.outputs.invalidated or run.output_generation != self.generation)) or
            (self.plan != null and (run.outputs.invalidated or run.output_generation != self.plan.?.output_generation));
        if (changed and !self.power_cycle) {
            self.refreshing = false;
            self.sequence = run.receiver_events.sequence;
            self.deadline = product.last_clock +| 30 * std.time.ns_per_s;
            self.plan = null; self.attempted_generation = 0;
            if (self.phase == .online) self.transitions +|= 1;
            self.phase = if (product.output.connection_generation != 0) .pause else .drain;
            try run.pauseOutput(product.mode.?.window, true);
            try run.restoreOutput(product.mode.?.window, false);
            product.ctx.?.logInfo("NVIDIA hotplug: state=draining receiver=invalidated present=paused shadow=retained");
        }
        if (self.phase == .online) return false;
        if (self.phase != .power_asleep and self.phase != .power_failed and product.last_clock >= self.deadline) {
            if (self.phase == .receiver_wait and self.power_cycle) return self.failPower(product, error.Timeout);
            if (self.phase != .receiver_wait) return error.Deadline;
        }
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
            .power_quiesce => {
                if (run.anyAdaptiveRefresh() or run.refresh_quiescing) return false;
                if (!try product.audio.suspendRoute()) return false;
                try run.pauseOutput(window, true);
                try run.restoreOutput(window, false);
                self.phase = .pause;
            },
            .pause => {
                const result = try product.pauseCommonOutput(true);
                if (result == a.gfx_output_error_busy) return false;
                if (result != a.gfx_output_ok) return error.Catalog;
                self.phase = .drain;
            },
            .drain => {
                if (try self.releaseSource(product)) return true;
                try run.cancelOutputModeQuery(window);
                if (run.frame_setup) |work| return run.prepareOutputFramePool(work.image.window.slot - 1);
                if (try product.cursor.pause(product)) return true;
                if (try product.modes.pause(product)) return true;
                if (!run.cursorWorkAvailable() or run.native_active != null or run.buffer_active != null or
                    run.display_channel_active != null or run.display_engine_active) return false;
                if (product.primaryOutput()) run.cursor_reserving = false;
                if (run.display_images[window]) |image| {
                    self.previous = image.boot_mode orelse return error.State;
                    self.phase = if (self.previous.?.hasAudio()) .mute else .detach;
                } else if (run.display_retired[window] != null) self.phase = .settle else return error.State;
            },
            .mute, .disable, .clear => {
                self.audio_sequence = try run.beginDisplayDisconnect(window, if (self.phase == .mute) .mute else if (self.phase == .disable) .disable else .clear, self.deadline);
                self.phase = if (self.phase == .mute) .mute_wait else if (self.phase == .disable) .disable_wait else .clear_wait;
            },
            .mute_wait, .disable_wait, .clear_wait => {
                if (run.audio_work != null) return false;
                const receipt = run.audio_result orelse return error.Completion;
                if (receipt.sequence != self.audio_sequence or receipt.receipt == 0 or receipt.status != 0 or
                    receipt.operation != @as(runtime.display_audio.Operation, if (self.phase == .mute_wait) .mute else if (self.phase == .disable_wait) .disable else .clear)) return error.Completion;
                self.phase = if (self.phase == .mute_wait and self.previous.?.displayPort()) .disable else
                    if (self.phase != .clear_wait) .clear else .detach;
            },
            .detach => { try run.detachDisplayImage(product.core.?, product.window.?, self.deadline); self.phase = .detach_wait; },
            .detach_wait => {
                if (run.display_work != null) return false;
                const retired = run.display_retired[window] orelse return error.Completion;
                if (retired.epoch != run.epoch or retired.core_point == 0 or retired.window_point == 0 or run.display_images[window] != null) return error.Completion;
                self.phase = .settle;
            },
            .settle => {
                if (self.power_cycle) {
                    if (!try product.cursor.stopped(product)) return true;
                    if (try product.modes.stopped(product)) return true;
                    if (product.modes.pending()) return false;
                    const completed = product.modes.completed_ticket;
                    product.modes = .{ .completed_ticket = completed };
                    product.audio.afterStop();
                    self.restore_ticket = 0;
                    // Keep the paused common output, CPU image, geometry and
                    // connector identity, including its MST RM-ID hold.
                    // Sleep is not a cable withdrawal.
                    self.phase = .power_off;
                    return true;
                }
                // Withdrawal requests common rollback while its old identity
                // remains bound. Complete the matching job, then retry.
                var pending = false;
                if (product.output.connection_generation != 0) {
                    const result = product.outputs.?.withdraw(&product.output);
                    if (result == a.gfx_output_error_busy) pending = true else if (result != a.gfx_output_ok) return error.Catalog
                    else {
                        try run.recordMstPublication(self.previous.?, product.output, false);
                        product.output = .{};
                    }
                }
                if (!try product.cursor.stopped(product)) return true;
                if (try product.modes.stopped(product)) return true;
                if (pending or product.modes.pending()) return false;
                if (!try product.quiesceCommonOutput()) return false;
                const completed = product.modes.completed_ticket;
                product.modes = .{ .completed_ticket = completed };
                product.audio.afterStop();
                self.restore_ticket = 0;
                if (!product.primaryOutput()) run.preparing_outputs &= ~product.mode.?.signal.display_id;
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
                var previous = self.previous orelse product.mode.?;
                const image = run.currentPresentation(window).?.surface.scanout.?;
                previous.width = image.width; previous.height = image.height;
                const choice = run.reconnectDisplayPlan(product.engine.?, window, previous) catch |err| {
                    if (err == error.Unsupported or err == error.Unavailable or err == error.Routing or err == error.Stale) return true; return err;
                };
                self.plan = choice.plan;
                if (!product.primaryOutput()) run.preparing_outputs |= product.mode.?.signal.display_id;
                self.deadline = product.last_clock +| 30 * std.time.ns_per_s;
                // Same-sized paused outputs can retain their common CPU
                // owner. A resized secondary needs that old owner drained
                // while the physical image is still retired.
                if (choice.resize and self.power_cycle and !product.primaryOutput()) {
                    if (!try product.quiesceCommonOutput()) {
                        self.attempted_generation = 0;
                        return false;
                    }
                }
                self.phase = if (choice.resize) .resize else .query;
            },
            .query => {
                if (!product.primaryOutput() and !run.requirePrivatePresentation()) return false;
                try run.queryDisplayMode(product.mode_control.?, self.plan.?, self.deadline); self.phase = .query_wait;
            },
            .query_wait => {
                const status = try run.modeControlStatus(product.mode_control.?);
                if (run.mode_control_active or status.state != .handed_off) return false;
                const proof = status.info orelse { self.plan = null; self.phase = .receiver_wait; return true; };
                if (status.rejected != null or status.unavailable or !proof.possible or proof.over_clock or
                    proof.receipt == 0 or !proof.mode.sameIntent(self.plan.?)) {
                    self.plan = null; self.phase = .receiver_wait; return true;
                }
                self.plan = proof.mode;
                self.phase = .refresh;
            },
            .refresh => {
                try run.refreshDetachedImage(run.currentPresentation(window).?.surface.scanout.?.dma, self.deadline);
                self.phase = .refresh_wait;
            },
            .refresh_wait => {
                const status = try run.presentationImageStatus(run.currentPresentation(window).?.surface.scanout.?.dma);
                if (status.failure) |err| return err;
                if (status.pending or status.completed == 0) return false;
                self.phase = .commit;
            },
            .commit => {
                try run.commitModeDisplayImage(product.core.?, product.window.?, run.currentPresentation(window).?.surface.scanout.?.dma,
                    self.plan.?.receiver_mode_id, self.deadline);
                self.phase = .commit_wait;
            },
            .commit_wait => {
                if (run.display_work != null) return false;
                const dma = run.currentPresentation(window).?.surface.scanout.?.dma;
                if (try run.takeDisplayLinkFailure(product.engine.?, window, dma, self.plan.?)) |failed| {
                    if (failed.previous != null or run.display_images[window] != null) return error.Stale;
                    self.plan = null; self.phase = .receiver_wait;
                    if (!product.primaryOutput()) run.preparing_outputs &= ~product.mode.?.signal.display_id;
                    product.ctx.?.logInfo("NVIDIA hotplug: link-rejected headless=retained retry=next-receiver-capture");
                    return true;
                }
                const image = run.display_images[window] orelse return error.Completion;
                if (image.boot_mode == null or !std.meta.eql(image.boot_mode.?, self.plan.?) or image.mode_receipt == 0 or
                    image.link == null or !image.link.?.complete()) return error.Completion;
                product.mode = self.plan; product.link = image.link.?.plan; product.confirmed_image = image;
                try product.buildPublication();
                self.phase = .publish;
            },
            .publish => {
                const result = product.outputs.?.publish(&product.publication, &product.output);
                if (result == a.gfx_output_error_busy) return false;
                if (result != a.gfx_output_ok) return error.Catalog;
                try run.recordMstPublication(product.mode.?, product.output, true);
                self.phase = .unpause;
                try product.syncPresentationTarget();
            },
            .unpause => {
                const result = try product.pauseCommonOutput(false);
                if (result == a.gfx_output_error_busy) return false;
                if (result != a.gfx_output_ok) return error.Catalog;
                self.generation = self.plan.?.output_generation;
                self.route = try runtime.output_route.identify(product.mode.?, run.nativeOutputs() orelse return error.Busy);
                self.plan = null; self.phase = .online; self.restores +|= 1;
                self.power_cycle = false; self.power_waking = false;
                product.cursor.resumeOutput();
                try run.pauseOutput(window, false);
                try run.restoreOutput(window, false);
                if (!product.primaryOutput()) run.preparing_outputs &= ~product.mode.?.signal.display_id;
                product.ctx.?.logInfo("NVIDIA hotplug: state=online receiver=fresh image=CPU-refreshed mode=IMP-checked audio=requery");
            },
            .resize => {
                product.mode = self.plan;
                product.link = try runtime.display_link.derive(self.plan.?, run.nativeObject() orelse return error.Busy, run.nativeOutputs() orelse return error.Busy);
                try product.buildPublication();
                self.phase = .resize_publish;
            },
            .resize_publish => {
                const result = product.outputs.?.publish(&product.publication, &product.output);
                if (result == a.gfx_output_error_busy) return false;
                if (result != a.gfx_output_ok) return error.Catalog;
                try run.recordMstPublication(product.mode.?, product.output, true);
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
                try run.restoreOutput(window, true);
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
                    !std.meta.eql(run.currentPresentation(window).?.surface.scanout.?, image.image)) return error.Completion;
                product.confirmed_image = image;
                self.restore_ticket = 0;
                self.phase = .unpause;
            },
            .restore_unavailable => {
                if (try self.releaseSource(product)) return true;
                return self.keepHeadless(product);
            },
            .power_off, .power_on => {
                self.power_sequence = try run.beginMonitorPower(window, self.phase == .power_on, self.deadline);
                self.phase = if (self.phase == .power_off) .power_off_wait else .power_on_wait;
            },
            .power_off_wait, .power_on_wait => {
                if (run.monitor_work != null) return false;
                const result = run.monitor_result orelse return error.Completion;
                const on = self.phase == .power_on_wait;
                if (result.sequence != self.power_sequence or result.on != on) return error.Completion;
                self.power_receipt = result.receipt;
                if (result.failure) |err| {
                    if (on) return self.failPower(product, err);
                    // A rejected sleep is followed by one wake/reconstruction
                    // attempt; it cannot strand an otherwise healthy desktop.
                    self.power_failure = err; self.power_waking = true;
                    self.deadline = product.last_clock +| 30 * std.time.ns_per_s;
                    self.phase = .power_on;
                    return true;
                }
                if (!on) {
                    self.phase = .power_asleep;
                    product.ctx.?.logInfo("NVIDIA screen: off scanout=retired audio=muted images=retained system=running");
                } else {
                    self.power_generation = run.output_generation;
                    try run.receiver_events.refreshOutput(run.epoch, product.last_clock, product.mode.?.signal.display_id);
                    self.phase = .power_refresh;
                }
            },
            .power_asleep, .power_failed => {
                if (self.power_intent.off != 0 or (self.phase == .power_failed and self.power_intent.sequence == self.power_attempted)) return false;
                self.power_attempted = self.power_intent.sequence;
                self.power_waking = true;
                self.deadline = product.last_clock +| 30 * std.time.ns_per_s;
                self.phase = .power_on;
            },
            .power_refresh => {
                if (run.outputs.active() or run.outputs.state != .returned or run.outputs.invalidated or
                    run.outputs.data.generation <= self.power_generation) return false;
                self.sequence = run.receiver_events.sequence;
                self.attempted_generation = 0;
                self.phase = .receiver_wait;
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
    pub fn closeAfterReset(self: *Owner, product: anytype, proof: @import("gsp_reset.zig").Quiescence) !bool {
        if (!proof.valid(product.running.?.epoch) or product.running.?.reset_stage != .done) return error.Retained;
        if (try self.releaseSource(product)) return false;
        self.* = .{};
        return true;
    }
    fn keepHeadless(self: *Owner, product: anytype) bool {
        if (self.power_cycle) return self.failPower(product, error.Unavailable);
        self.plan = null; self.restore_ticket = 0; self.phase = .receiver_wait;
        product.running.?.restoreOutput(product.mode.?.window, false) catch return false;
        if (!product.primaryOutput()) product.running.?.preparing_outputs &= ~product.mode.?.signal.display_id;
        product.ctx.?.logInfo("NVIDIA hotplug: state=headless restore=unavailable shadow=retained retry=next-receiver-event");
        return true;
    }
    fn failPower(self: *Owner, product: anytype, err: anyerror) bool {
        self.power_failure = err; self.power_attempted = self.power_intent.sequence;
        self.plan = null; self.restore_ticket = 0; self.phase = .power_failed;
        product.running.?.restoreOutput(product.mode.?.window, false) catch {};
        if (!product.primaryOutput()) product.running.?.preparing_outputs &= ~product.mode.?.signal.display_id;
        product.ctx.?.logInfo("NVIDIA screen: wake=unavailable image=retained system=running retry=new-request");
        return true;
    }
    fn pollPower(self: *Owner, product: anytype) !void {
        const outputs = product.outputs orelse return;
        if (!outputs.supportsPower() or product.output.connection_generation == 0 or product.mode == null) return;
        const run = product.running.?;
        const window = product.mode.?.window;
        if (self.power_published == null or !std.meta.eql(self.power_published.?.identity, product.output)) {
            self.power_published = null;
            self.power_intent = .{ .identity = product.output };
            self.power_attempted = 0;
        }
        const active = run.display_images[window];
        const retired = run.display_retired[window];
        const image = active orelse (if (retired) |value| value.image else return);
        const link = image.link orelse return;
        if (!link.complete()) return;
        const phase: u32 = if (self.phase == .power_failed) a.gfx_power_phase_unavailable else
            if (self.phase == .power_asleep) a.gfx_power_phase_off else
            if (self.power_cycle) (if (self.power_waking) a.gfx_power_phase_waking else a.gfx_power_phase_stopping) else
            if (self.phase == .online) a.gfx_power_phase_on else a.gfx_power_phase_unavailable;
        var value: a.GfxOutputPower = .{ .identity = product.output,
            .capabilities = a.gfx_power_cap_signal | (if (link.mst != null or (link.dp != null and link.dp.?.sink.revision < 0x11))
                @as(u32, 0) else a.gfx_power_cap_sink), .phase = phase,
            .sequence = if (self.power_published) |old| old.sequence else 1,
            .request_sequence = self.power_intent.sequence,
            .since_ns = if (self.power_published) |old| old.since_ns else product.last_clock,
            .control_receipt = self.power_receipt,
            .core_point = if (active) |current| current.core_point else retired.?.core_point,
            .window_point = if (active) |current| current.window_point else retired.?.window_point,
            .reason = if (phase == a.gfx_power_phase_unavailable) (if (if (self.power_failure) |err| err == error.Timeout else false)
                a.gfx_power_reason_timeout else if (self.power_failure != null) a.gfx_power_reason_rejected else a.gfx_power_reason_link) else 0 };
        if (self.power_published) |old| {
            if (!std.meta.eql(old, value)) {
                if (value.sequence == std.math.maxInt(u64)) return error.Exhausted;
                value.sequence += 1; value.since_ns = product.last_clock;
            }
        }
        if (self.power_published == null or !std.meta.eql(self.power_published.?, value)) {
            const status = outputs.publishPower(&value);
            if (status == a.gfx_output_error_busy or status == a.gfx_output_error_stale) return;
            if (status != a.gfx_output_ok) return error.Catalog;
            self.power_published = value;
        }
        var intent: a.GfxPowerRequest = .{};
        const status = outputs.readPower(&product.output, &intent);
        if (status == a.gfx_output_error_busy or status == a.gfx_output_error_stale) return;
        if (status != a.gfx_output_ok or !std.meta.eql(intent.identity, product.output)) return error.Catalog;
        self.power_intent = intent;
    }
};
