//! Additional physical/MST heads share Runtime's RM graph, CE, Core and mode control.
//! A common output is activated only after its own physical image receipt.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const runtime = @import("gsp_runtime.zig");
const catalog = @import("gsp_catalog.zig");
// Additional heads use desktop software cursors and have no app-audio
// publisher yet. Physical HDMI/DP mute/disable still runs in Hotplug/Runtime.
const SoftwareCursor = struct {
    pub fn busy(_: *const SoftwareCursor) bool { return false; }
    pub fn pause(_: *SoftwareCursor, _: anytype) !bool { return false; }
    pub fn stopped(_: *SoftwareCursor, _: anytype) !bool { return true; }
    pub fn resumeOutput(_: *SoftwareCursor) void {}
};
const NoAudioPublisher = struct {
    pub fn busy(_: *const NoAudioPublisher) bool { return false; }
    pub fn suspendRoute(_: *NoAudioPublisher) !bool { return true; }
    pub fn afterStop(_: *NoAudioPublisher) void {}
    pub fn afterLinkRestore(_: *NoAudioPublisher) void {}
};

pub const Phase = enum { unused, assign, assignment, refresh, query, queried, notifier, notifier_upload, notifier_wait,
    allocate, allocated, bind, creator, table_upload, table_wait, window, window_wait, immediate, immediate_wait,
    shadow, map, clear, unmap, presentation, initial, initial_wait, commit, committed, publish, register, activate, active, failed };
pub const Output = struct {
    // Borrow shared adapter services. All mutable per-head owners below
    // remain in this stable slot; no second Device or RM graph is created.
    ctx: ?r4os.r4dev.DriverContext = null,
    running: ?*runtime.Owner = null,
    captured: ?*@import("boot_vram.zig").Capture = null,
    memory: ?r4os.driver_memory.Context = null,
    display: ?r4os.driver_display.Context = null,
    outputs: ?r4os.driver_outputs.Context = null,
    backend: a.GfxBackendBinding = .{},
    engine: ?runtime.DisplayEngineHandle = null,
    copy: ?runtime.ChannelHandle = null,
    core: ?runtime.DisplayChannelHandle = null,
    mode_control: ?runtime.ModeControlHandle = null,
    last_clock: u64 = 0,
    link: ?runtime.display_link.Plan = null,
    confirmed_image: ?runtime.ActiveDisplayImage = null,
    modes: @import("gsp_native_modes.zig").Owner = .{},
    hotplug: @import("gsp_native_hotplug.zig").Owner = .{},
    cursor: SoftwareCursor = .{},
    audio: NoAudioPublisher = .{},
    phase: Phase = .unused,
    display_id: u32 = 0,
    generation: u64 = 0,
    deadline: u64 = 0,
    assignment: u64 = 0,
    root_probe: bool = false,
    mode: ?runtime.boot_mode.Plan = null,
    storage: ?runtime.BufferHandle = null,
    dma: u32 = 0,
    window: ?runtime.DisplayChannelHandle = null,
    immediate: ?runtime.DisplayChannelHandle = null,
    shadow: a.GfxBufferReference = .{},
    mapping: a.GfxBufferMap = .{},
    descriptor: a.GfxBufferDescriptor = .{},
    cleared: u64 = 0,
    receiver: a.GfxReceiverInfo = .{},
    publication: a.GfxOutputPublication = .{},
    output: a.GfxOutputId = .{},
    target: a.GfxOutputTarget = .{},
    common_activation_pending: bool = false,
    failure: ?anyerror = null,
    statistics: @import("gsp_frame_stats.zig").Owner = .{},
    color: @import("gsp_output_color.zig").Owner = .{},

    pub fn busy(self: *const Output) bool {
        if (self.phase == .active) return (self.hotplug.phase != .online and self.hotplug.phase != .receiver_wait and
            self.hotplug.phase != .power_asleep and self.hotplug.phase != .power_failed) or
            (self.modes.phase != .detached and self.modes.phase != .idle and self.modes.phase != .decision and self.modes.phase != .unavailable);
        return self.phase != .unused and self.phase != .failed;
    }
    fn waitingForCatalog(self: *const Output) bool {
        return self.phase == .publish or self.phase == .register or self.phase == .activate;
    }
    fn attach(self: *Output, product: anytype) void {
        self.ctx = product.ctx; self.running = product.running; self.captured = product.captured;
        self.memory = product.memory; self.display = product.display; self.outputs = product.outputs;
        self.backend = product.backend; self.engine = product.engine; self.copy = product.copy;
        self.core = product.core; self.mode_control = product.mode_control; self.last_clock = product.last_clock;
    }
    fn next(self: *Output, phase: Phase) void { self.phase = phase; }
    fn advance(self: *Output, product: anytype) !bool {
        const run = product.running.?;
        if (self.phase == .unused) return false;
        if (self.phase == .failed) return self.modes.failedJobs(self, self.failure orelse error.DeviceLost);
        if (self.phase == .active) {
            const changed = try self.hotplug.step(self);
            if (changed or self.hotplug.phase != .online or self.hotplug.refreshing) return changed;
            if (self.color.step(self)) return true;
            if (try self.modes.step(self)) return true;
            if (self.modes.phase == .idle or self.modes.phase == .decision or self.modes.phase == .unavailable)
                return run.prepareOutputFramePool(self.mode.?.window);
            return false;
        }
        if (product.last_clock >= self.deadline) return error.Deadline;
        switch (self.phase) {
            .assign => {
                if (!run.requirePrivatePresentation()) return false;
                const snapshot = run.nativeOutputs() orelse return false;
                var virtual = false;
                for (snapshot.receivers[0..snapshot.count]) |*receiver| if (receiver.display_id == self.display_id) { virtual = receiver.source == .mst; };
                if (virtual) {
                    // RM already assigned the physical root/SOR and allocated
                    // this verified leaf ID. A second physical ASSIGN_SOR
                    // would incorrectly displace its active siblings.
                    self.mode = try run.claimDisplayRoute(product.engine.?, self.display_id, self.receiver.preferred_mode_id);
                    self.next(.query);
                    return true;
                }
                self.assignment = try run.beginSorAssignment(product.engine.?, self.display_id, self.deadline);
                self.next(.assignment);
            },
            .assignment => {
                if (try run.sorAssignmentStatus(self.assignment) == null) return false;
                const result = try run.finishSorAssignment(self.assignment);
                if (result.obsolete or result.rejected != null or result.receipt == 0) return error.Unsupported;
                self.next(.refresh);
            },
            .refresh => {
                if (self.root_probe) {
                    try run.finishMstRootAssignment(product.engine.?, self.assignment);
                    run.preparing_outputs &= ~self.display_id;
                    self.* = .{}; // The root needs no BO, channel or common output.
                    return true;
                }
                self.mode = try run.claimAssignedDisplayRoute(product.engine.?, self.assignment, self.receiver.preferred_mode_id);
                self.next(.query);
            },
            .query => {
                try run.queryDisplayMode(product.mode_control.?, self.mode.?, self.deadline);
                self.next(.queried);
            },
            .queried => {
                const status = try run.modeControlStatus(product.mode_control.?);
                if (run.mode_control_active or status.state != .handed_off) return false;
                const result = status.info orelse return error.Unsupported;
                if (status.rejected != null or status.unavailable or !result.possible or result.over_clock or
                    result.receipt == 0 or !result.mode.sameIntent(self.mode.?)) return error.Unsupported;
                self.mode = result.mode;
                self.next(.notifier);
            },
            .notifier => {
                const resources = run.display_resources_slot.owner orelse return error.State;
                if (resources.publishedNotifier(self.mode.?.window + 1) != null) self.next(.allocate) else {
                    _ = try run.createDisplayNotifier(product.engine.?, .window, self.mode.?.window);
                    self.next(.notifier_upload);
                }
            },
            .notifier_upload, .table_upload => {
                try run.uploadDisplayTable(product.engine.?, product.copy.?, self.deadline);
                self.next(if (self.phase == .notifier_upload) .notifier_wait else .table_wait);
            },
            .notifier_wait, .table_wait => {
                const status = try run.displayTableStatus(product.engine.?);
                if (status.uploading or status.revision != status.published_revision) return false;
                self.next(if (self.phase == .notifier_wait) .allocate else .window);
            },
            .allocate => {
                self.storage = try run.allocateDisplaySurface(.{ .width = self.mode.?.width, .height = self.mode.?.height,
                    .usage = a.gfx_buffer_usage_scanout | a.gfx_buffer_usage_transfer_target }, self.deadline);
                self.next(.allocated);
            },
            .allocated => {
                const status = try run.nativeBufferStatus(self.storage.?);
                if (status.rejected != null or status.host_rejected != null) return error.Memory;
                if (run.native_active != null or status.info == null) return false;
                self.next(.bind);
            },
            .bind => {
                self.dma = try run.bindDisplayStorage(product.engine.?, .window, self.mode.?.window, self.storage.?);
                self.next(.creator);
            },
            .creator => {
                try run.releaseNativeBuffer(self.storage.?); self.storage = null;
                self.next(.table_upload);
            },
            .window, .immediate => {
                const kind: runtime.display_channel.wire.Kind = if (self.phase == .window) .window else .immediate;
                const handle = try run.createDisplayChannel(product.engine.?, kind, self.mode.?.window, self.deadline);
                if (self.phase == .window) { self.window = handle; self.next(.window_wait); }
                else { self.immediate = handle; self.next(.immediate_wait); }
            },
            .window_wait, .immediate_wait => {
                const status = try run.displayChannelStatus(if (self.phase == .window_wait) self.window.? else self.immediate.?);
                if (status.rejected != null or status.host_rejected != null) return error.Channel;
                if (run.display_channel_active != null or status.info == null) return false;
                self.next(if (self.phase == .window_wait) .immediate else .shadow);
            },
            .shadow => {
                const mode = self.mode.?;
                const pitch = try std.math.mul(u64, mode.width, 4);
                self.descriptor = .{ .byte_length = try std.math.mul(u64, pitch, mode.height), .width = mode.width, .height = mode.height,
                    .format = a.gfx_buffer_format_xrgb8888, .plane_count = 1, .plane_pitches = .{ pitch, 0, 0, 0 },
                    .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source };
                const status = product.memory.?.bufferCreate(&self.descriptor, &self.shadow);
                if (status != a.gfx_buffer_result_ok or self.shadow.reference.id == 0 or self.shadow.buffer.id == 0) return error.Memory;
                self.next(.map);
            },
            .map => {
                const status = product.memory.?.bufferMap(&self.shadow.reference, a.gfx_buffer_map_write, 0, self.descriptor.byte_length, &self.mapping);
                if (status != a.gfx_buffer_result_ok or self.mapping.lease.id == 0 or self.mapping.cpu_address == 0 or
                    self.mapping.byte_length != self.descriptor.byte_length or
                    self.mapping.cpu_address > std.math.maxInt(u64) - self.mapping.byte_length) return error.Map;
                self.next(.clear);
            },
            .clear => {
                const bytes: [*]u8 = @ptrFromInt(self.mapping.cpu_address);
                const count = @min(@as(u64, 65536), self.mapping.byte_length - self.cleared);
                @memset(bytes[self.cleared..][0..count], 0); self.cleared += count;
                if (self.cleared == self.mapping.byte_length) self.next(.unmap);
            },
            .unmap => {
                if (product.memory.?.bufferUnmap(&self.mapping.lease) != a.gfx_buffer_result_ok) return error.Retained;
                self.mapping = .{}; self.next(.presentation);
            },
            .presentation => {
                const binding = try run.registerDisplayPresentation(product.copy.?, product.engine.?, self.window.?, self.dma,
                    self.shadow.reference, self.deadline);
                if (!std.meta.eql(binding, product.backend)) return error.Binding;
                self.next(.initial);
            },
            .initial => { try run.uploadDisplayPresentationImage(self.dma, self.deadline); self.next(.initial_wait); },
            .initial_wait => {
                const status = try run.presentationImageStatus(self.dma);
                if (status.failure) |err| return err;
                if (status.pending or status.completed == 0) return false;
                self.next(.commit);
            },
            .commit => {
                try run.commitModeDisplayImage(product.core.?, self.window.?, self.dma, self.mode.?.receiver_mode_id, self.deadline);
                self.next(.committed);
            },
            .committed => {
                if (run.display_work != null) return false;
                const image = try run.displayImageStatus(product.engine.?, self.mode.?.window) orelse return error.Completion;
                if (image.boot_mode == null or !std.meta.eql(image.boot_mode.?, self.mode.?) or image.image.dma != self.dma or
                    image.core_point == 0 or image.window_point == 0 or image.mode_receipt == 0 or image.position == null or
                    !std.meta.eql(image.position.?.handle, self.immediate.?) or image.link == null or !image.link.?.complete()) return error.Completion;
                self.link = image.link.?.plan; self.confirmed_image = image;
                try self.buildPublication();
                self.next(.publish);
            },
            .publish => {
                const status = product.outputs.?.publish(&self.publication, &self.output);
                if (status == a.gfx_output_error_busy) return false;
                if (status != a.gfx_output_ok or self.output.connector_id != self.display_id or
                    self.output.adapter_id != product.backend.adapter_id or self.output.device_generation != product.backend.device_generation or
                    self.output.connection_generation == 0) return error.Catalog;
                try run.recordMstPublication(self.mode.?, self.output, true);
                self.next(.register);
            },
            .register => {
                const mode = self.mode.?;
                const request: a.GfxAdditionalOutput = .{ .backend = product.backend, .output = self.output,
                    .head_id = mode.head, .width = mode.width, .height = mode.height, .format = a.gfx_buffer_format_xrgb8888 };
                const status = product.display.?.outputRegister(&request, &self.target);
                if (status == a.gfx_output_error_busy) return false;
                if (status != a.gfx_output_ok) return error.Catalog;
                try run.bindPresentationTarget(mode.window, self.target);
                self.next(.activate);
            },
            .activate => {
                const status = product.display.?.outputTransition(&self.target, 0, false);
                if (status == a.gfx_output_error_busy) return false;
                if (status != a.gfx_output_ok) return error.Catalog;
                if (product.memory.?.bufferRelease(&self.shadow.reference) != a.gfx_buffer_result_ok) return error.Retained;
                self.shadow = .{};
                run.additional_paused[self.mode.?.window] = false;
                run.currentPresentation(self.mode.?.window).?.pending = true;
                self.next(.active);
                run.preparing_outputs &= ~self.display_id;
                product.ctx.?.logInfo("NVIDIA additional-output: active own-head,window,shadow,image physical-completion=confirmed common-output=registered");
            },
            .unused, .active, .failed => unreachable,
        }
        return true;
    }
    pub fn buildPublication(self: *Output) !void {
        const run = self.running.?;
        const snapshot = run.nativeOutputs() orelse return error.Busy;
        const mode = self.mode.?;
        var found = false;
        for (snapshot.topology.routes[0..snapshot.count], snapshot.receivers[0..snapshot.count]) |*route, *receiver| {
            if (route.id != self.display_id) continue;
            if (found) return error.Routing;
            try catalog.encodeCaptured(&self.receiver, route, receiver, snapshot); found = true;
        }
        if (!found) return error.Routing;
        const head = @as(u32, 1) << @intCast(mode.head);
        const plane = @as(u32, 1) << @intCast(mode.window);
        self.publication = .{ .backend = self.backend };
        self.publication.info = .{ .identity = .{ .adapter_id = self.backend.adapter_id,
            .device_generation = self.backend.device_generation, .connector_id = self.display_id },
            .flags = self.receiver.flags, .connector_kind = self.receiver.connector_kind, .mode_count = 1,
            .preferred_mode_id = mode.receiver_mode_id, .edid_bytes = self.receiver.edid_bytes,
            .possible_heads = head, .possible_planes = plane, .possible_plls = head,
            .limits = .{ .head_mask = head, .plane_mask = plane, .pll_mask = head, .max_width = mode.width, .max_height = mode.height } };
        found = false;
        for (self.receiver.modes[0..self.receiver.mode_count]) |value| if (value.mode_id == mode.receiver_mode_id) {
            if (value.width != mode.width or value.height != mode.height or found) return error.Stale;
            self.publication.modes[0] = value; found = true;
        };
        if (!found) return error.Stale;
        @memcpy(self.publication.edid[0..self.receiver.edid_bytes], self.receiver.edid[0..self.receiver.edid_bytes]);
    }
    pub fn primaryOutput(_: *Output) bool { return false; }
    pub fn pauseCommonOutput(self: *Output, paused: bool) !i32 {
        if (!paused) try self.syncPresentationTarget();
        if (self.target.display_generation == 0 and paused) return a.gfx_output_ok;
        return self.display.?.outputTransition(&self.target, if (paused) 1 else 0, false);
    }
    pub fn quiesceCommonOutput(self: *Output) !bool {
        if (self.target.display_generation == 0) return true;
        const run = self.running.?;
        const window = self.mode.?.window;
        if (run.display_images[window] != null or run.display_retired[window] == null) return error.State;
        const result = self.display.?.outputTransition(&self.target, 2, true);
        if (result == a.gfx_output_error_busy) return false;
        if (result != a.gfx_output_ok) return error.Catalog;
        self.target = .{}; self.statistics = .{};
        self.common_activation_pending = false;
        run.presentation_targets[window] = null;
        return true;
    }
    pub fn syncPresentationTarget(self: *Output) !void {
        const run = self.running.?;
        const mode = self.mode orelse return error.State;
        const current = run.currentPresentation(mode.window) orelse return error.State;
        const image = run.display_images[mode.window];
        if (image == null and (!run.outputPaused(mode.window) or run.display_retired[mode.window] == null)) return error.Stale;
        const same = self.target.display_generation != 0 and self.target.connection_generation == self.output.connection_generation;
        if (!same) {
            if (self.target.display_generation != 0) {
                const paused = self.display.?.outputTransition(&self.target, 1, false);
                if (paused == a.gfx_output_error_busy) return error.Busy;
                if (paused != a.gfx_output_ok) return error.Catalog;
            }
            const request: a.GfxAdditionalOutput = .{ .backend = self.backend, .output = self.output, .head_id = mode.head,
                .width = if (image) |value| value.image.width else current.surface.descriptor.width,
                .height = if (image) |value| value.image.height else current.surface.descriptor.height,
                .format = a.gfx_buffer_format_xrgb8888 };
            const result = self.display.?.outputRegister(&request, &self.target);
            if (result == a.gfx_output_error_busy) return error.Busy;
            if (result != a.gfx_output_ok) return error.Catalog;
            self.common_activation_pending = !run.outputPaused(mode.window);
        }
        if (image != null) try run.bindPresentationTarget(mode.window, self.target)
        else run.presentation_targets[mode.window] = null;
        if (self.common_activation_pending) {
            const active = self.display.?.outputTransition(&self.target, 0, false);
            if (active == a.gfx_output_error_busy) return error.Busy;
            if (active != a.gfx_output_ok) return error.Catalog;
            self.common_activation_pending = false;
        }
    }
};

pub const Owner = struct {
    outputs: [8]Output = @splat(.{}),
    cursor: u3 = 0,
    reset_cursor: usize = 0,
    // Common display_reset has already retired additional targets and all
    // borrowed mode surfaces. These are only the R4D's private CPU sources.
    pub fn closeAfterReset(self: *Owner, product: anytype, proof: @import("gsp_reset.zig").Quiescence) !bool {
        if (!proof.valid(product.running.?.epoch) or product.running.?.reset_stage != .done) return error.Retained;
        if (self.reset_cursor == self.outputs.len) return true;
        const output = &self.outputs[self.reset_cursor];
        if (!try output.hotplug.closeAfterReset(product, proof)) return false;
        if (output.mapping.lease.id != 0) {
            if (product.memory.?.bufferUnmap(&output.mapping.lease) != a.gfx_buffer_result_ok) return error.Retained;
            output.mapping = .{}; return false;
        }
        if (output.shadow.reference.id != 0) {
            if (product.memory.?.bufferRelease(&output.shadow.reference) != a.gfx_buffer_result_ok) return error.Retained;
            output.shadow = .{}; return false;
        }
        output.* = .{};
        self.reset_cursor += 1;
        return false;
    }
    pub fn busy(self: *const Owner) bool {
        for (&self.outputs) |*output| if (output.busy()) return true;
        return false;
    }
    pub fn hardwareBusy(self: *const Owner) bool {
        for (&self.outputs) |*output| if (output.busy() and !output.waitingForCatalog()) return true;
        return false;
    }
    pub fn failedJobs(self: *Owner, product: anytype) !bool {
        // LOST replies require no RM object or idle display engine. A held
        // Window must not prevent its common decision from being answered.
        for (&self.outputs) |*output| if (output.phase == .failed) {
            if (try self.advance(output, product)) return true;
        };
        return false;
    }
    pub fn quarantine(self: *Owner, product: anytype) void {
        for (&self.outputs) |*output| {
            if (output.phase == .unused) continue;
            if (output.target.display_generation != 0) _ = product.display.?.outputTransition(&output.target, 1, false);
            if (output.output.connection_generation != 0 and product.outputs.?.withdraw(&output.output) == a.gfx_output_ok) {
                if (output.mode) |mode| product.running.?.recordMstPublication(mode, output.output, false) catch {};
                output.output = .{};
            }
            if (output.mode) |mode| product.running.?.additional_paused[mode.window] = true;
            product.running.?.preparing_outputs &= ~output.display_id;
            output.modes.quarantine(output, error.DeviceLost);
            output.failure = error.DeviceLost; output.phase = .failed;
        }
    }
    pub fn step(self: *Owner, product: anytype) !bool {
        if (!product.display.?.supportsOutputs()) return false;
        // RM queries and physical commits remain serialized. Publication can
        // wait on a different head's confirmation; it must let that owner
        // consume its decision instead of monopolizing the adapter worker.
        for (&self.outputs) |*output| if (output.busy() and !output.waitingForCatalog()) return self.advance(output, product);
        const run = product.running.?;
        if (!self.busy() and product.hotplug.phase == .online and !product.hotplug.refreshing and !run.outputPaused(product.mode.?.window) and
            !product.modes.pending() and !product.audio.busy() and !product.cursor.busy()) {
            if (run.nativeOutputs()) |snapshot| {
                candidates: for (snapshot.topology.routes[0..snapshot.count], snapshot.receivers[0..snapshot.count]) |*route, *receiver| {
                    if (route.id == product.mode.?.signal.display_id or receiver.connected != true) continue;
                    const root_probe = route.resource != null and route.resource.?.index == 0xffffffff and
                        (runtime.output_route.mstRootFingerprint(snapshot, route.id) catch null) != null;
                    if (!root_probe and !receiver.report.complete()) continue;
                    for (&self.outputs) |*output| if (output.display_id == route.id) continue :candidates;
                    for (&self.outputs) |*output| if (output.phase == .unused) {
                        if (!root_probe) {
                            try catalog.encodeCaptured(&output.receiver, route, receiver, snapshot);
                            if (output.receiver.preferred_mode_id == 0 or output.receiver.mode_count == 0) continue :candidates;
                        }
                        output.root_probe = root_probe;
                        output.display_id = route.id; output.generation = snapshot.generation;
                        output.deadline = product.last_clock +| 30 * std.time.ns_per_s;
                        output.phase = .assign;
                        run.preparing_outputs |= route.id;
                        return true;
                    };
                }
            }
        }
        const start = self.cursor;
        for (0..8) |offset| {
            const index = start +% @as(u3, @intCast(offset));
            if (try self.advance(&self.outputs[index], product)) { self.cursor = index +% 1; return true; }
        }
        return false;
    }
    fn advance(_: *Owner, output: *Output, product: anytype) !bool {
        if (output.phase == .unused) return false;
        output.attach(product);
        return output.advance(product) catch |err| {
            if (err == error.Busy) return false;
            output.modes.quarantine(output, err);
            output.failure = err; output.phase = .failed;
            const run = product.running.?;
            run.preparing_outputs &= ~output.display_id;
            if (output.target.display_generation != 0) {
                _ = product.display.?.outputTransition(&output.target, 1, false);
                run.additional_paused[output.mode.?.window] = true;
            }
            if (run.sor_result) |result| if (result.sequence == output.assignment) run.abandonSorAssignment(output.assignment) catch {};
            // No timeout proves physical retirement. Every partially created
            // alias/channel remains owned until its explicit cleanup path.
            product.ctx.?.logError("NVIDIA additional-output: initialization unavailable partial resources retained primary output preserved");
            return true;
        };
    }
};
