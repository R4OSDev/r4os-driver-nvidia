//! Product boot takeover in the serialized device worker. Each call advances
//! one bounded operation; firmware replies and hardware completion remain
//! owned by Runtime. The common commit callback never waits for this worker.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const runtime = @import("gsp_runtime.zig");
const capture = @import("boot_vram.zig");
const catalog = @import("gsp_catalog.zig");
const Outputs = @TypeOf(@as(r4os.r4dev.DriverContext, undefined).graphicsOutputs().?);

pub fn frameCount(option: []const u8) !u8 {
    if (option.len == 0 or std.mem.eql(u8, option, "2")) return 2;
    if (std.mem.eql(u8, option, "3")) return 3;
    return error.Descriptor;
}

pub const Phase = enum {
    detached, waiting, engine_create, engine_wait, receiver_wait, sor_wait, sor_refresh, mode_create, mode_wait, instance_allocate, instance_attach, instance_wait,
    core_notifier, window_notifier, identity_allocate, identity_bind, identity_upload, identity_wait, surface_allocate, surface_bind,
    storage_wait, storage_release, table_upload, table_wait,
    core_create, core_wait, window_create, window_wait, immediate_create, immediate_wait,
    shadow_create, shadow_map, shadow_copy, shadow_unmap, register, publish, prepare,
    image_upload, image_wait, console_mapping, scanout_commit, scanout_wait, handoff, console_handoff, console_active, active, failed,
};

pub const Owner = struct {
    self_address: usize = 0,
    ctx: ?r4os.r4dev.DriverContext = null,
    running: ?*runtime.Owner = null,
    captured: ?*capture.Capture = null,
    memory: ?r4os.driver_memory.Context = null,
    display: ?r4os.driver_display.Context = null,
    outputs: ?Outputs = null,
    phase: Phase = .detached,
    failed_phase: ?Phase = null,
    failure: ?anyerror = null,
    last_status: i32 = 0,
    withdraw_status: i32 = 0,
    last_clock: u64 = 0,
    deadline: u64 = 0,
    phase_deadline: u64 = 0,
    next_phase: Phase = .detached,
    storage: ?runtime.BufferHandle = null,
    copy: ?runtime.ChannelHandle = null,
    engine: ?runtime.DisplayEngineHandle = null,
    mode_control: ?runtime.ModeControlHandle = null,
    mode_admission: ?runtime.mode_control.Result = null,
    core: ?runtime.DisplayChannelHandle = null,
    window: ?runtime.DisplayChannelHandle = null,
    immediate: ?runtime.DisplayChannelHandle = null,
    dma: u32 = 0,
    mode: ?runtime.boot_mode.Plan = null,
    link: ?runtime.display_link.Plan = null,
    shadow: a.GfxBufferReference = .{},
    shadow_map: a.GfxBufferMap = .{},
    shadow_descriptor: a.GfxBufferDescriptor = .{},
    copied: u64 = 0,
    backend: a.GfxBackendBinding = .{},
    output: a.GfxOutputId = .{},
    publication: a.GfxOutputPublication = .{},
    receiver: a.GfxReceiverInfo = .{},
    prepared: a.GfxNativeState = .{},
    receipt: a.GfxNativeState = .{},
    confirmed_image: ?runtime.ActiveDisplayImage = null,
    callback_confirmed: bool = false,
    restore_requested: bool = false,
    modes: @import("gsp_native_modes.zig").Owner = .{},
    cursor: @import("gsp_native_cursor.zig").Owner = .{},
    audio: @import("gsp_native_audio.zig").Owner = .{},
    hotplug: @import("gsp_native_hotplug.zig").Owner = .{},
    additional: @import("gsp_additional_output.zig").Owner = .{},
    frame_count: u8 = 2,
    statistics: @import("gsp_frame_stats.zig").Owner = .{},
    color: @import("gsp_output_color.zig").Owner = .{},
    refresh: @import("gsp_native_refresh.zig").Owner = .{},
    output_fault_reported: [8]bool = @splat(false),
    reset_generation: u64 = 0,
    console: ?*@import("boot_console.zig").Owner = null,
    waiting_generation: u64 = 0,
    restore_route: ?runtime.output_route.RestoreIdentity = null,
    sor_saved: ?runtime.boot_mode.Plan = null,
    sor_sequence: u64 = 0,
    sor_attempted: bool = false,

    /// Explicit mode=native only. Check the common handoff API before the
    /// device worker can execute the already prepared firmware operations.
    pub fn request(self: *Owner, ctx: *const r4os.r4dev.DriverContext, running: *runtime.Owner, captured: *capture.Capture) !void {
        if (self.self_address != 0) return error.Busy;
        const display = ctx.graphicsDisplay() orelse return error.Api;
        const outputs = ctx.graphicsOutputs() orelse return error.Api;
        const memory = ctx.memory() orelse return error.Api;
        const clock = ctx.resources() orelse return error.Api;
        if (display.table.version != 1 or display.table.size < @offsetOf(a.GfxDriverDisplayApi, "prepare_held") + 8 or
            display.table.prepare_held == 0 or display.table.transition == 0 or display.table.boot_info == 0 or
            outputs.table.publish == 0 or outputs.table.withdraw == 0 or !outputs.supportsHotplug()) return error.Api;
        if (!captured.ready or captured.scanout_original == null or captured.original_boot == null or
            captured.boot.held_generation == 0 or captured.boot.read.lease.id == 0 or captured.boot.read.cpu_address == 0) return error.Binding;
        const boot = captured.original_boot.?;
        const bytes = try std.math.mul(u64, boot.pitch, boot.height);
        if (bytes == 0 or captured.boot.read.byte_length < bytes or captured.boot.read.cpu_address > std.math.maxInt(u64) - bytes) return error.Descriptor;
        const now = clock.nowNs();
        if (now == 0 or now == std.math.maxInt(u64)) return error.Clock;
        if (running.native_copy.phase == .detached) try running.native_copy.request();
        self.* = .{ .self_address = @intFromPtr(self), .ctx = ctx.*, .running = running, .captured = captured,
            .memory = memory, .display = display, .outputs = outputs, .phase = .waiting, .last_clock = now,
            .deadline = try std.math.add(u64, now, 120 * std.time.ns_per_s),
            .phase_deadline = try std.math.add(u64, now, 30 * std.time.ns_per_s) };
    }

    pub fn step(self: *Owner) !bool {
        if (self.phase == .detached) return false;
        if (self.self_address != @intFromPtr(self) or self.phase == .failed) return error.State;
        const now = self.ctx.?.resources().?.nowNs();
        if (now == std.math.maxInt(u64) or now < self.last_clock) return error.Clock;
        self.last_clock = now;
        if (self.phase != .active and self.phase != .console_active and self.phase != .waiting and self.phase != .receiver_wait and
            (now >= self.deadline or now >= self.phase_deadline)) return error.Deadline;
        return (if (self.phase == .active) self.advanceActive() else self.advance()) catch |err| {
            if (err == error.Busy) return false;
            self.quarantine(err);
            return err;
        };
    }
    /// Reuse the original captured CPU image and discovered device policy,
    /// while the common bridge retains the independently identified hold.
    pub fn requestAfterReset(self: *Owner, ctx: *const r4os.r4dev.DriverContext, running: *runtime.Owner,
        captured: *capture.Capture, generation: u64, route: ?runtime.output_route.RestoreIdentity) !void
    {
        if (generation == 0 or !captured.boot.native_adopted or captured.boot.native_generation != generation) return error.Stale;
        const display = ctx.graphicsDisplay() orelse return error.Api;
        if (!display.supportsReset()) return error.Api;
        try self.request(ctx, running, captured);
        self.reset_generation = generation;
        self.restore_route = route;
    }

    pub fn recoveryRoute(self: *const Owner) ?runtime.output_route.RestoreIdentity {
        if (self.self_address != @intFromPtr(self)) return null;
        const mode = self.mode orelse return null;
        const claim = self.hotplug.route orelse return null;
        const seen = self.hotplug.observation orelse return null;
        if (claim.mst != null or seen.state != .connected or seen.fingerprint == null or
            claim.display_id != mode.signal.display_id or claim.head != mode.head or claim.window != mode.window or
            claim.sor != mode.signal.sor or claim.protocol != (mode.signal.sor_control >> 8) & 15) return null;
        return .{ .claim = claim, .fingerprint = seen.fingerprint.? };
    }

    // Runtime graph and common display consumers must retire first. A mode
    // or cursor job contains borrowed references, not additional ownership.
    pub fn closeAfterReset(self: *Owner, proof: @import("gsp_reset.zig").Quiescence) !bool {
        if (self.self_address == 0) return true;
        const run = self.running orelse return error.Stale;
        if (self.self_address != @intFromPtr(self) or !proof.valid(run.epoch) or run.reset_stage != .done or self.phase != .failed) return error.Retained;
        if (!try self.additional.closeAfterReset(self, proof)) return false;
        if (!try self.hotplug.closeAfterReset(self, proof)) return false;
        if (self.shadow_map.lease.id != 0) {
            if (self.memory.?.bufferUnmap(&self.shadow_map.lease) != a.gfx_buffer_result_ok) return error.Retained;
            self.shadow_map = .{}; return false;
        }
        if (self.shadow.reference.id != 0) {
            if (self.memory.?.bufferRelease(&self.shadow.reference) != a.gfx_buffer_result_ok) return error.Retained;
            self.shadow = .{}; return false;
        }
        self.* = .{};
        return true;
    }
    fn next(self: *Owner, phase: Phase) void {
        self.phase = phase;
        self.phase_deadline = @min(self.deadline, self.last_clock +| (5 * std.time.ns_per_s));
    }
    fn allocate(self: *Owner, bytes: u64, then: Phase) !void {
        if (self.storage != null) return error.State;
        self.storage = try self.running.?.allocateNativeStorage(bytes, self.phase_deadline);
        self.next_phase = then;
        self.next(.storage_wait);
    }
    fn release(self: *Owner, then: Phase) void {
        self.next_phase = then;
        self.next(.storage_release);
    }
    noinline fn advance(self: *Owner) !bool {
        switch (self.phase) {
            inline else => |phase| return self.advancePhase(phase),
        }
    }
    // Only one startup phase runs per worker slice; its snapshot storage
    // must not remain live across unrelated initialization calls.
    noinline fn advancePhase(self: *Owner, comptime phase: Phase) !bool {
        const run = self.running.?;
        const held = self.captured.?;
        const boot = held.original_boot.?;
        switch (phase) {
            .waiting => {
                if (run.native_copy.phase != .ready or run.nativeObject() == null) return false;
                self.copy = run.native_copy.channel orelse return error.State;
                self.deadline = try std.math.add(u64, self.last_clock, 120 * std.time.ns_per_s);
                self.next(.engine_create);
            },
            .engine_create => {
                self.engine = try run.createDisplayEngine(self.phase_deadline);
                self.next(.engine_wait);
            },
            .engine_wait => {
                const status = try run.displayEngineStatus(self.engine.?);
                if (status.rejected != null or status.unavailable) return error.Unsupported;
                const info = status.info orelse return false;
                if (!info.core or !info.window or !info.immediate or info.hardware.windows == 0) return error.Unsupported;
                self.next(.receiver_wait);
            },
            .receiver_wait => {
                const info = (try run.displayEngineStatus(self.engine.?)).info orelse return error.State;
                const mask = info.hardware.windows & held.scanout_original.?.window_mask & 255;
                if (mask == 0) return error.Unsupported;
                const saved = runtime.boot_mode.capture(&held.scanout_original.?, &boot, @ctz(mask)) catch |err| {
                    @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                        "NVIDIA native-output: preflight=boot-capture reason={s} format={d} window-mask={x}",
                        .{@errorName(err), boot.format, mask});
                    const raw = &held.scanout_original.?;
                    const heads = @import("boot_scanout.zig").routedHeads(raw);
                    if (@popCount(heads) == 1) {
                        const head = &raw.heads[@ctz(heads)];
                        @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                            "NVIDIA native-output: retained-signal output={x} control={x} clock-config={x} point-in={x} point-out-adjust={x} hdmi={x} dsc={x}/{x}",
                            .{head.get(.output), head.get(.control), head.get(.clock_config), head.color.get(.point_in),
                                head.color.get(.point_out_adjust), head.color.get(.hdmi), head.dsc_control, head.dsc_pps_control});
                        // Repeat only immutable retained fields at the actual
                        // rejection; startup records may already have rolled
                        // out of the bounded public boot log. No new MMIO.
                        const decoder = @import("boot_scanout.zig");
                        if (decoder.timing(head)) |timing| {
                            @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                                "NVIDIA native-output: rejected-geometry boot={d}x{d} active={d}x{d} input={d}x{d} output={d}x{d} total={d}x{d} depth={d} hdmi={} clock={x}",
                                .{boot.width, boot.height, timing.active.x, timing.active.y, timing.viewport_in.x,
                                    timing.viewport_in.y, timing.viewport_out.x, timing.viewport_out.y,
                                    timing.total.x, timing.total.y, timing.depth_code, timing.hdmi_enabled, head.get(.clock)});
                        } else |decode_error| {
                            @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                                "NVIDIA native-output: rejected-timing boot={d}x{d} reason={s} total={x} sync={x} blank-end={x} blank-start={x} input={x} output={x} clock={x}",
                                .{boot.width, boot.height, @errorName(decode_error), head.get(.total), head.get(.sync_end),
                                    head.get(.blank_end), head.get(.blank_start), head.get(.viewport_in), head.get(.viewport_out), head.get(.clock)});
                        }
                        const retained_window = &raw.windows[@ctz(mask)];
                        const retained_sors = decoder.headSors(raw, @ctz(heads));
                        @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                            "NVIDIA native-output: rejected-route head={d} sor-mask={x} sor-control={x} window={d} size={x} input={x} output={x}",
                            .{@ctz(heads), retained_sors, if (retained_sors != 0) raw.sors[@ctz(retained_sors)] else @as(u32, 0),
                                @ctz(mask), retained_window.get(.size), retained_window.get(.input), retained_window.get(.output)});
                    }
                    return err;
                };
                const snapshot = run.nativeOutputs() orelse return error.Busy;
                self.mode = runtime.boot_mode.bind(saved, snapshot, run.epoch, held.boot.held_generation) catch |err| {
                    if (err != error.Routing and err != error.Stale and err != error.Unsupported) return err;
                    if (err == error.Routing and self.restore_route != null and !self.sor_attempted) {
                        const end = try std.math.add(u64, self.last_clock, 5 * std.time.ns_per_s);
                        const sequence = run.beginBootSorAssignment(self.engine.?, saved, self.restore_route.?, end) catch |assignment_error| {
                            if (assignment_error == error.Busy or assignment_error == error.Stale or
                                assignment_error == error.Routing or assignment_error == error.Unsupported) {
                                if (snapshot.generation != self.waiting_generation) {
                                    self.waiting_generation = snapshot.generation;
                                    @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                                        "NVIDIA native-output: SOR-admission-wait generation={d} reason={s} cursor-admission={} work={} channel={?} sequence={d}",
                                        .{snapshot.generation, @errorName(assignment_error), run.cursorWorkAvailable(), run.hasQueuedWork(),
                                            if (run.channel) |channel| channel.phase else null, run.sequence.self_address});
                                }
                                return false;
                            }
                            return assignment_error;
                        };
                        self.sor_saved = saved; self.sor_sequence = sequence; self.sor_attempted = true;
                        self.deadline = try std.math.add(u64, self.last_clock, 120 * std.time.ns_per_s);
                        self.next(.sor_wait);
                        return true;
                    }
                    // A missing/currently unusable receiver cannot invalidate
                    // an otherwise running GPU. No display PUT has occurred.
                    if (snapshot.generation != self.waiting_generation) {
                        self.waiting_generation = snapshot.generation;
                        @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                            "NVIDIA native-output: waiting-for-route generation={d} reason={s} device-backend=retained",
                            .{snapshot.generation,@errorName(err)});
                    }
                    return false;
                };
                if (self.console == null) {
                    const previous = self.mode.?;
                    self.mode = try @import("gsp_receiver_mode.zig").admitBootHdmi(previous, snapshot);
                    if (previous.transport_hdmi != self.mode.?.transport_hdmi)
                        @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                            "NVIDIA native-output: boot-transport=HDMI admission=fresh-physical-receiver raster=retained clock={x} source/IMP/link=pending",
                            .{self.mode.?.signal.clock});
                    try run.configureIdentityLutUsage(self.engine.?, self.mode.?.window);
                    self.mode.?.native_lut = true;
                }
                if (info.cursor) {
                    try run.configureCursorUsage(self.engine.?, @import("gsp_cursor_image.zig").max_size);
                    self.mode.?.cursor_size = @import("gsp_cursor_image.zig").max_size;
                }
                self.link = runtime.display_link.derive(self.mode.?, run.nativeObject() orelse return error.Busy, snapshot) catch |err| {
                    @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                        "NVIDIA native-output: preflight=display-link reason={s} display={x} transport-hdmi={} clock={x} hdmi={x}",
                        .{@errorName(err), self.mode.?.signal.display_id, saved.transport_hdmi, saved.signal.clock, saved.signal.hdmi});
                    return err;
                };
                // Time without a receiver consumes no active modeset budget.
                self.deadline = try std.math.add(u64, self.last_clock, 120 * std.time.ns_per_s);
                self.next(.mode_create);
            },
            .sor_wait => {
                _ = (try run.sorAssignmentStatus(self.sor_sequence)) orelse return false;
                const result = try run.finishSorAssignment(self.sor_sequence);
                if (result.rejected != null or result.obsolete or !result.crossbar or result.assignment == null) {
                    if (run.sor_result != null) try run.abandonSorAssignment(self.sor_sequence);
                    self.sor_saved = null; self.sor_sequence = 0;
                    self.next(.receiver_wait);
                    return true;
                }
                self.next(.sor_refresh);
            },
            .sor_refresh => {
                if (run.nativeOutputs() == null) return false;
                self.mode = run.finishBootSorAssignment(self.engine.?, self.sor_sequence, self.sor_saved.?) catch |err| {
                    if (err == error.Busy) return false;
                    if (err != error.Stale and err != error.Routing and err != error.Unsupported) return err;
                    try run.abandonSorAssignment(self.sor_sequence);
                    self.sor_saved = null; self.sor_sequence = 0;
                    self.next(.receiver_wait);
                    return true;
                };
                @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                    "NVIDIA native-output: SOR-restored epoch={d} display={x} sor={d} generation={d} receiver=same route=same topology=fresh",
                    .{run.epoch, self.mode.?.signal.display_id, self.mode.?.signal.sor, self.mode.?.output_generation});
                self.sor_saved = null; self.sor_sequence = 0;
                self.next(.receiver_wait);
            },
            .mode_create => {
                self.mode_control = try run.createModeControl(self.engine.?, self.mode.?, self.phase_deadline);
                self.next(.mode_wait);
            },
            .mode_wait => {
                const status = try run.modeControlStatus(self.mode_control.?);
                if (status.state != .handed_off) return false;
                if (status.rejected != null or status.unavailable) return error.Unsupported;
                const admission = status.info orelse return error.State;
                if (admission.receipt == 0 or !std.meta.eql(admission.mode, self.mode.?)) return error.Unsupported;
                if ((!admission.possible or admission.over_clock) and self.mode.?.cursor_size != 0) {
                    try run.configureCursorUsage(self.engine.?, 0);
                    self.mode = try run.bootDisplayPlan(self.engine.?, self.mode.?.window);
                    self.link = try runtime.display_link.derive(self.mode.?, run.nativeObject() orelse return error.Busy,
                        run.nativeOutputs() orelse return error.Busy);
                    try run.queryDisplayMode(self.mode_control.?, self.mode.?, self.phase_deadline);
                    return true;
                }
                if (!admission.possible or admission.over_clock) return error.Unsupported;
                self.mode_admission = admission;
                self.next(.instance_allocate);
            },
            .instance_allocate => try self.allocate(65536, .instance_attach),
            .instance_attach => {
                try run.attachDisplayInstance(self.engine.?, self.storage.?, self.phase_deadline);
                self.next(.instance_wait);
            },
            .instance_wait => {
                const status = try run.displayEngineStatus(self.engine.?);
                if (status.rejected != null or status.unavailable) return error.Display;
                if (status.info == null or !status.info.?.instance_bound) return false;
                self.release(.core_notifier);
            },
            .core_notifier => {
                _ = try run.createDisplayNotifier(self.engine.?, .core, 0);
                self.next(.window_notifier);
            },
            .window_notifier => {
                _ = try run.createDisplayNotifier(self.engine.?, .window, self.mode.?.window);
                self.next(if (self.console == null) .identity_allocate else .surface_allocate);
            },
            .identity_allocate => {
                if (self.storage != null or !self.mode.?.native_lut) return error.State;
                self.storage = try run.allocateIdentityLutStorage(self.phase_deadline);
                self.next_phase = .identity_bind;
                self.next(.storage_wait);
            },
            .identity_bind => {
                try run.bindIdentityLut(self.engine.?, self.storage.?, self.mode.?.head, self.mode.?.window);
                self.release(.identity_upload);
            },
            .identity_upload => {
                try run.uploadIdentityLut(self.engine.?, self.copy.?, self.phase_deadline);
                self.next(.identity_wait);
            },
            .identity_wait => {
                if (!try run.identityLutReady(self.engine.?)) return false;
                self.next(.surface_allocate);
            },
            .surface_allocate => {
                if (self.console) |source| {
                    self.dma = try run.bindBootConsole(self.engine.?, self.mode.?.window, source);
                    self.next(.table_upload);
                    return true;
                }
                self.storage = try run.allocateDisplaySurface(.{ .width = boot.width, .height = boot.height,
                    .usage = a.gfx_buffer_usage_scanout | a.gfx_buffer_usage_transfer_target }, self.phase_deadline);
                self.next_phase = .surface_bind;
                self.next(.storage_wait);
            },
            .storage_wait => {
                const status = try run.nativeBufferStatus(self.storage.?);
                if (status.rejected != null or status.host_rejected != null) {
                    @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                        "NVIDIA native-output: buffer-rejected state={s} rm=0x{?x} host={?d} next={s}",
                        .{@tagName(status.state), status.rejected, status.host_rejected, @tagName(self.next_phase)});
                    return error.Buffer;
                }
                if (status.info == null) return false;
                self.next(self.next_phase);
            },
            .storage_release => {
                try run.releaseNativeBuffer(self.storage.?);
                self.storage = null;
                self.next(self.next_phase);
            },
            .surface_bind => {
                self.dma = try run.bindDisplayStorage(self.engine.?, .window, self.mode.?.window, self.storage.?);
                self.release(.table_upload);
            },
            .table_upload => {
                try run.uploadDisplayTable(self.engine.?, self.copy.?, self.phase_deadline);
                self.next(.table_wait);
            },
            .table_wait => {
                const status = try run.displayTableStatus(self.engine.?);
                if (status.uploading or status.entries == 0 or status.revision != status.published_revision) return false;
                self.next(.core_create);
            },
            .core_create, .window_create, .immediate_create => {
                const kind: runtime.display_channel.wire.Kind = switch (self.phase) { .core_create => .core, .window_create => .window, else => .immediate };
                const handle = try run.createDisplayChannel(self.engine.?, kind, if (kind == .core) 0 else self.mode.?.window, self.phase_deadline);
                switch (kind) {
                    .core => { self.core = handle; self.next(.core_wait); },
                    .window => { self.window = handle; self.next(.window_wait); },
                    .immediate => { self.immediate = handle; self.next(.immediate_wait); },
                    .cursor => unreachable,
                }
            },
            .core_wait, .window_wait, .immediate_wait => {
                const handle = switch (self.phase) { .core_wait => self.core.?, .window_wait => self.window.?, else => self.immediate.? };
                const status = try run.displayChannelStatus(handle);
                if (status.rejected != null or status.host_rejected != null) return error.Channel;
                if (status.info == null) return false;
                self.next(switch (self.phase) { .core_wait => .window_create, .window_wait => .immediate_create,
                    else => if (self.console != null) .console_mapping else .shadow_create });
            },
            .shadow_create => {
                const pitch = try std.math.mul(u64, boot.width, 4);
                self.shadow_descriptor = .{ .byte_length = try std.math.mul(u64, pitch, boot.height), .width = boot.width, .height = boot.height,
                    .format = a.gfx_buffer_format_xrgb8888, .plane_count = 1, .plane_pitches = .{ pitch, 0, 0, 0 },
                    .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source };
                self.last_status = self.memory.?.bufferCreate(&self.shadow_descriptor, &self.shadow);
                if (self.last_status != a.gfx_buffer_result_ok or self.shadow.reference.id == 0 or self.shadow.buffer.id == 0) return error.Buffer;
                self.next(.shadow_map);
            },
            .shadow_map => {
                self.last_status = self.memory.?.bufferMap(&self.shadow.reference, a.gfx_buffer_map_write, 0, self.shadow_descriptor.byte_length, &self.shadow_map);
                if (self.last_status != a.gfx_buffer_result_ok or self.shadow_map.lease.id == 0 or self.shadow_map.cpu_address == 0 or
                    self.shadow_map.byte_length != self.shadow_descriptor.byte_length or
                    self.shadow_map.cpu_address > std.math.maxInt(u64) - self.shadow_map.byte_length) return error.Map;
                self.next(.shadow_copy);
            },
            .shadow_copy => {
                // The very same immutable RAM capture is used by common
                // commit. Row padding is excluded; never read former VRAM.
                const target: [*]u8 = @ptrFromInt(self.shadow_map.cpu_address);
                const source: [*]const u8 = @ptrFromInt(held.boot.read.cpu_address);
                const pitch = self.shadow_descriptor.plane_pitches[0];
                var budget: u64 = 65536;
                while (budget != 0 and self.copied < self.shadow_descriptor.byte_length) {
                    const x = self.copied % pitch;
                    const y = self.copied / pitch;
                    const count = @min(budget, pitch - x);
                    @memcpy(target[self.copied..][0..count], source[y * boot.pitch + x..][0..count]);
                    self.copied += count;
                    budget -= count;
                }
                if (self.copied == self.shadow_descriptor.byte_length) self.next(.shadow_unmap);
            },
            .shadow_unmap => {
                self.last_status = self.memory.?.bufferUnmap(&self.shadow_map.lease);
                if (self.last_status != a.gfx_buffer_result_ok) return error.Map;
                self.shadow_map = .{};
                self.next(.register);
            },
            .register => {
                self.backend = try run.registerDisplayPresentation(self.copy.?, self.engine.?, self.window.?, self.dma, self.shadow.reference, self.phase_deadline);
                self.next(.publish);
            },
            .publish => {
                try self.buildPublication();
                self.last_status = self.outputs.?.publish(&self.publication, &self.output);
                if (self.last_status != a.gfx_output_ok or self.output.adapter_id != self.backend.adapter_id or
                    self.output.device_generation != self.backend.device_generation or self.output.connector_id != self.mode.?.signal.display_id or
                    self.output.connection_generation == 0) return error.Catalog;
                self.next(.prepare);
            },
            .prepare => {
                var registration: a.GfxNativeRegistration = .{ .backend = self.backend, .output = self.output,
                    .reference = self.shadow.reference, .context = self.self_address,
                    .commit_callback = @intFromPtr(&commit), .restore_callback = @intFromPtr(&restore) };
                @memcpy(registration.name[0..6], "nvidia");
                self.last_status = if (self.reset_generation != 0)
                    self.display.?.prepareReset(&registration, held.boot.held_generation, self.reset_generation, &self.prepared)
                else self.display.?.prepareHeld(&registration, held.boot.held_generation, &self.prepared);
                if (self.last_status != a.gfx_output_ok or
                    (if (self.reset_generation != 0) self.prepared.generation <= self.reset_generation else self.prepared.generation != held.boot.held_generation) or
                    !validState(self.prepared, self.prepared.generation,
                    a.display_state_preparing, a.gfx_output_outcome_validated)) return error.Handoff;
                if (self.reset_generation != 0) try held.boot.adoptRecoveredNative(self.prepared, self.reset_generation)
                else try held.boot.adoptNative(self.prepared);
                self.next(.image_upload);
            },
            .image_upload => {
                try self.validateRoute();
                try run.uploadInitialImage(self.phase_deadline);
                self.next(.image_wait);
            },
            .image_wait => {
                const status = try run.initialImageStatus();
                if (status.failure) |err| return err;
                if (status.pending or status.completed == 0) return false;
                self.next(.scanout_commit);
            },
            .scanout_commit => {
                if (self.console == null) {
                    try self.validateRoute();
                    if (!try self.audio.beforeInitial(self)) return false;
                } else run.require_mode_receipt = true;
                try run.commitBootDisplayImage(self.core.?, self.window.?, self.dma, self.phase_deadline);
                self.next(.scanout_wait);
            },
            .scanout_wait => {
                const image = try run.displayImageStatus(self.engine.?, self.mode.?.window) orelse return false;
                if (run.display_work != null) return false;
                self.confirmed_image = image;
                if (self.console != null) {
                    try self.validateConsoleCompletion();
                    self.console.?.confirmed = true;
                    self.next(.console_handoff);
                    return true;
                }
                try self.validateCompletion();
                self.next(.handoff);
            },
            .handoff => {
                try self.validateCompletion();
                self.last_status = self.display.?.transition(self.prepared.generation, 0, &self.receipt);
                if (self.last_status != a.gfx_output_ok or !self.callback_confirmed or
                    !validState(self.receipt, self.prepared.generation, a.display_state_software_native, a.gfx_output_outcome_applied)) return error.Handoff;
                // Present and the common bridge each imported their own alias.
                // The boot creator must not leak after a later confirmation
                // retires that image. Mode-job references remain borrowed.
                self.last_status = self.memory.?.bufferRelease(&self.shadow.reference);
                if (self.last_status != a.gfx_buffer_result_ok) return error.Retained;
                self.shadow = .{};
                if (self.frame_count < 2 or self.frame_count > 3) return error.Descriptor;
                run.presentation_buffers = self.frame_count;
                self.next(.active);
                // The common receipt has completed takeover. The Device
                // generation gate must see that ownership before rebinding
                // this head's presentation through the ordinary runtime API.
                try self.syncPresentationTarget();
                self.ctx.?.logInfo("NVIDIA native-output: state=software-native boot-mode=retained shadow=system scanout=vram completion=CE,WIMM,Window,Core link=confirmed common-handoff=confirmed");
            },
            .console_mapping => {
                if (!try self.console.?.bindStep()) return false;
                self.next(.scanout_commit);
            },
            .console_handoff => {
                try self.validateConsoleCompletion();
                var current: a.GfxNativeBootInfo = .{};
                if (self.display.?.bootInfo(&current) != a.gfx_output_ok or current.generation < self.reset_generation or
                    (current.state != a.display_state_recovering and current.state != a.display_state_unavailable)) return error.Handoff;
                self.last_status = self.display.?.transition(current.generation, 2, &self.receipt);
                if (self.last_status == a.gfx_output_error_busy) return false;
                if (self.last_status != a.gfx_output_ok or self.receipt.reserved0 != 0 or self.receipt.version != 1 or
                    self.receipt.size < @sizeOf(a.GfxNativeState)) return error.Handoff;
                if (self.receipt.retained == 1 and self.receipt.outcome == a.gfx_output_outcome_lost and
                    (self.receipt.state == a.display_state_unavailable or self.receipt.state == a.display_state_recovering)) return false;
                if (self.receipt.retained != 0 or self.receipt.outcome != a.gfx_output_outcome_applied or
                    self.receipt.state != a.display_state_bootfb or self.receipt.generation <= current.generation) return error.Handoff;
                held.boot.console_active = true;
                held.boot.native_adopted = false;
                self.next(.console_active);
                self.ctx.?.logInfo("NVIDIA console: original-BAR1=verified scanout=C67D-confirmed bootfb=restored firmware-and-console-reservation=resident");
            },
            .console_active => return false,
            .detached, .active, .failed => return error.State,
        }
        return true;
    }
    // The active output dispatch must not retain initialization buffers while
    // invoking the independent mode/hotplug/additional-output owners.
    noinline fn advanceActive(self: *Owner) !bool {
        const run = self.running.?;
        if (try @call(.never_inline, @TypeOf(self.refresh).step, .{ &self.refresh, self })) return true;
        if (self.refresh.busy()) return false;
        if (self.reportOutputFault()) return true;
        if (try self.additional.failedJobs(self)) return true;
        if (run.output_faults[self.mode.?.window]) |err| {
            if (try self.modes.failedJobs(self, err)) return true;
            return self.additional.step(self);
        }
        const changed = try @call(.never_inline, @TypeOf(self.hotplug).step, .{ &self.hotplug, self });
        if (changed) return true;
        if (self.hotplug.phase != .online or self.hotplug.refreshing) return self.additional.step(self);
        if (@call(.never_inline, @TypeOf(self.color).step, .{ &self.color, self })) return true;
        // The additional owner must consume its completed SOR work
        // before an idle-only primary route query can succeed.
        if (self.additional.hardwareBusy()) return self.additional.step(self);
        try self.validateRoute();
        if (run.frame_setup != null) return run.prepareFramePool();
        if (try @call(.never_inline, @TypeOf(self.cursor).step, .{ &self.cursor, self })) return true;
        if (self.cursor.busy()) return false;
        if (try @call(.never_inline, @TypeOf(self.audio).step, .{ &self.audio, self })) return true;
        if (self.audio.busy()) return false;
        if (self.modes.phase == .idle or self.modes.phase == .unavailable or self.modes.phase == .decision) {
            if (try self.additional.step(self)) return true;
            if (self.additional.hardwareBusy()) return false;
        }
        if (try @call(.never_inline, @TypeOf(self.modes).step, .{ &self.modes, self })) return true;
        if (self.modes.phase == .idle or self.modes.phase == .decision or self.modes.phase == .unavailable)
            return run.prepareFramePool();
        return false;
    }

    fn reportOutputFault(self: *Owner) bool {
        const run = self.running.?;
        for (run.output_faults, 0..) |fault, window| {
            if (fault == null or self.output_fault_reported[window]) continue;
            var status: i32 = a.gfx_output_error_busy;
            if (window == self.mode.?.window) status = self.outputs.?.pauseOutput(&self.output, true) else {
                for (&self.additional.outputs) |*output| {
                    if (output.mode == null or output.mode.?.window != window or output.target.display_generation == 0) continue;
                    status = self.display.?.outputTransition(&output.target, 1, false);
                    if (status == a.gfx_output_ok or status == a.gfx_output_error_stale) {
                        output.failure = fault; output.phase = .failed;
                    }
                    break;
                }
            }
            // Metadata removal can be retried without stopping healthy GPU
            // engines. No response here proves physical Window retirement.
            if (status == a.gfx_output_ok or status == a.gfx_output_error_stale) {
                self.output_fault_reported[window] = true;
                return true;
            }
        }
        return false;
    }

    pub fn syncPresentationTarget(self: *Owner) !void {
        const mode = self.mode orelse return error.State;
        const run = self.running.?;
        if (run.display_images[mode.window] == null) {
            if (!run.outputPaused(mode.window) or run.display_retired[mode.window] == null) return error.Stale;
            // A catalog can be published before the headless resize job.
            // That catalog alone must never authorize image presentation.
            run.presentation_targets[mode.window] = null;
            return;
        }
        try run.bindPresentationTarget(mode.window, .{ .adapter_id = self.backend.adapter_id,
            .device_generation = self.backend.device_generation, .connector_id = self.output.connector_id,
            .connection_generation = self.output.connection_generation, .display_generation = self.receipt.generation,
            .head_id = mode.head });
    }
    pub fn primaryOutput(_: *Owner) bool { return true; }
    pub fn pauseCommonOutput(self: *Owner, paused: bool) !i32 {
        return self.outputs.?.pauseOutput(&self.output, paused);
    }
    pub fn quiesceCommonOutput(_: *Owner) !bool { return true; }
    fn validateRoute(self: *Owner) !void {
        const run = self.running.?;
        if (run.failure != null or run.outputs.invalidated) return error.Stale;
        const snapshot = run.nativeOutputs() orelse return error.Busy;
        const bound = try runtime.boot_mode.bind(self.mode.?, snapshot, run.epoch, self.captured.?.boot.held_generation);
        if (!std.meta.eql(bound, self.mode.?)) return error.Stale;
        const object = run.nativeObject() orelse return error.Busy;
        if (!std.meta.eql(try runtime.display_link.derive(bound, object, snapshot), self.link.?)) return error.Stale;
    }
    pub fn buildPublication(self: *Owner) !void {
        try self.validateRoute();
        const snapshot = self.running.?.nativeOutputs().?;
        const mode = self.mode.?;
        var found = false;
        for (snapshot.topology.routes[0..snapshot.count], snapshot.receivers[0..snapshot.count]) |*route, *receiver| {
            if (route.id != mode.signal.display_id) continue;
            if (found) return error.Routing;
            try catalog.encodeCaptured(&self.receiver, route, receiver, snapshot);
            found = true;
        }
        if (!found) return error.Routing;
        self.publication = .{ .backend = self.backend };
        const head = @as(u32, 1) << @intCast(mode.head);
        const plane = @as(u32, 1) << @intCast(mode.window);
        self.publication.info = .{ .identity = .{ .adapter_id = self.backend.adapter_id,
            .device_generation = self.backend.device_generation, .connector_id = mode.signal.display_id },
            .flags = self.receiver.flags, .connector_kind = self.receiver.connector_kind,
            .mode_count = 1, .preferred_mode_id = 1, .edid_bytes = self.receiver.edid_bytes,
            .possible_heads = head, .possible_planes = plane, .possible_plls = head,
            .limits = .{ .head_mask = head, .plane_mask = plane, .pll_mask = head, .max_width = mode.width, .max_height = mode.height } };
        // Initial handoff admits only captured geometry. The mode worker
        // promotes checked receiver timings after native ownership is active.
        self.publication.modes[0] = .{ .mode_id = 1, .flags = a.gfx_output_mode_geometry_only | a.gfx_output_mode_preferred,
            .width = mode.width, .height = mode.height };
        if (mode.receiver_mode_id != 0) {
            var found_mode = false;
            for (self.receiver.modes[0..self.receiver.mode_count]) |value| if (value.mode_id == mode.receiver_mode_id) {
                self.publication.modes[0] = value;
                self.publication.info.preferred_mode_id = value.mode_id;
                found_mode = true; break;
            };
            if (!found_mode) return error.Stale;
        }
        @memcpy(self.publication.edid[0..self.receiver.edid_bytes], self.receiver.edid[0..self.receiver.edid_bytes]);
    }
    fn validateCompletion(self: *Owner) !void {
        try self.validateRoute();
        const run = self.running.?;
        const mode_status = try run.modeControlStatus(self.mode_control.?);
        if (mode_status.info == null or self.mode_admission == null or !std.meta.eql(mode_status.info.?, self.mode_admission.?)) return error.Completion;
        const image = try run.displayImageStatus(self.engine.?, self.mode.?.window) orelse return error.State;
        if (run.display_work != null or run.initial_image != null or run.presentation == null or
            run.presentation.?.initial_point == 0 or run.presentation.?.initial_failure != null or
            image.boot_mode == null or !std.meta.eql(image.boot_mode.?, self.mode.?) or image.position == null or
            !std.meta.eql(image.position.?.handle, self.immediate.?) or image.position.?.sequence == 0 or
            image.core_point == 0 or image.window_point == 0 or image.link == null or
            !std.meta.eql(image.link.?.plan, self.link.?) or image.link.?.receipt == 0 or
            !image.link.?.complete() or
            self.confirmed_image == null or !std.meta.eql(image, self.confirmed_image.?)) return error.Completion;
    }
    pub fn validateConsoleCompletion(self: *Owner) !void {
        const source = self.console orelse return error.State;
        const run = self.running.?;
        const mode_status = try run.modeControlStatus(self.mode_control.?);
        const active = try run.displayImageStatus(self.engine.?, self.mode.?.window) orelse return error.Completion;
        const expected = try source.imageInfo(run.epoch, self.dma, self.window.?.slot);
        const current_mode = try run.bootDisplayPlan(self.engine.?, self.mode.?.window);
        if (source.phase != .ready or run.presentation != null or run.copy_backend != null or run.display_work != null or
            !std.meta.eql(current_mode, self.mode.?) or
            mode_status.info == null or self.mode_admission == null or !std.meta.eql(mode_status.info.?, self.mode_admission.?) or
            !std.meta.eql(active.image, expected) or active.core_point == 0 or active.window_point == 0 or
            active.mode_receipt == 0 or active.position == null or active.position.?.sequence == 0 or
            !std.meta.eql(active.position.?.handle, self.immediate.?) or active.boot_mode == null or
            !std.meta.eql(active.boot_mode.?, self.mode.?) or active.link == null or !active.link.?.complete() or
            !std.meta.eql(active.link.?.plan, self.link.?) or active.link.?.receipt == 0 or
            !std.meta.eql(self.confirmed_image, @as(?runtime.ActiveDisplayImage, active))) return error.Completion;
    }
    pub fn ownsConsole(self: *const Owner, current: a.GfxNativeBootInfo) bool {
        if (self.self_address != @intFromPtr(self) or self.console == null) return false;
        if (self.phase == .console_active) return self.captured.?.boot.console_active and
            current.state == a.display_state_bootfb and current.generation == self.receipt.generation;
        return self.phase == .console_handoff and current.generation >= self.reset_generation and
            current.generation == self.captured.?.firmware_restore_generation and
            (current.state == a.display_state_unavailable or current.state == a.display_state_recovering);
    }
    fn validState(state: a.GfxNativeState, generation: u64, expected: u32, outcome: u32) bool {
        return state.version == 1 and state.size >= @sizeOf(a.GfxNativeState) and state.reserved0 == 0 and
            state.generation == generation and state.state == expected and state.outcome == outcome and state.retained == 1;
    }
    pub fn ownsNative(self: *const Owner, current: a.GfxNativeBootInfo) bool {
        return self.self_address == @intFromPtr(self) and (self.phase == .active or self.phase == .failed) and self.callback_confirmed and
            self.prepared.generation != 0 and self.prepared.generation == self.captured.?.boot.native_generation and
            validState(self.receipt, self.prepared.generation, a.display_state_software_native, a.gfx_output_outcome_applied) and
            current.state == a.display_state_software_native and current.generation == self.receipt.generation;
    }
    pub fn ownsPreparing(self: *const Owner, current: a.GfxNativeBootInfo) bool {
        return self.self_address == @intFromPtr(self) and self.captured != null and self.prepared.generation != 0 and
            self.prepared.generation == self.captured.?.boot.native_generation and self.captured.?.boot.native_adopted and
            current.state == a.display_state_preparing and current.generation == self.prepared.generation and
            (self.phase == .image_upload or self.phase == .image_wait or self.phase == .scanout_commit or self.phase == .scanout_wait or self.phase == .handoff);
    }
    pub fn quarantine(self: *Owner, err: anyerror) void {
        if (self.phase == .detached) return;
        self.refresh.lost(self);
        self.additional.quarantine(self);
        self.cursor.quarantine(self, err);
        self.audio.quarantine(self, err);
        self.modes.quarantine(self, err);
        if (self.failure == null) { self.failure = err; self.failed_phase = self.phase; }
        self.phase = .failed;
        // Metadata withdrawal never proves physical display/DMA quiescence.
        // Keep shadow, capture, registered callbacks and the complete RM graph.
        if (self.output.connection_generation != 0) {
            self.withdraw_status = self.outputs.?.withdraw(&self.output);
            if (self.withdraw_status == a.gfx_output_ok or self.withdraw_status == a.gfx_output_error_stale) self.output = .{};
        }
        var buffer: [220]u8 = undefined;
        const line = std.fmt.bufPrintZ(&buffer, "NVIDIA native-output: failed phase={s} reason={s} status={d} withdraw={d} common-outcome={d} resources=retained",
            .{ @tagName(self.failed_phase.?), @errorName(self.failure.?), self.last_status, self.withdraw_status, self.receipt.outcome }) catch return;
        self.ctx.?.logError(line);
    }
    fn commit(raw: u64, generation: u64, boot: *const a.GfxNativeBootInfo) callconv(.c) i32 {
        if (raw == 0) return 0;
        const self: *Owner = @ptrFromInt(raw);
        if (self.self_address != raw or self.phase != .handoff or self.callback_confirmed or self.restore_requested or
            generation != self.prepared.generation or boot.generation != generation) return 0;
        const original = self.captured.?.original_boot.?;
        if (boot.width != original.width or boot.height != original.height or boot.pitch != original.pitch or
            boot.physical_address != original.physical_address or boot.byte_length != original.byte_length or boot.format != original.format) return 0;
        self.validateCompletion() catch return 0;
        self.callback_confirmed = true;
        return 1;
    }
    fn restore(raw: u64, generation: u64, boot: *const a.GfxNativeBootInfo) callconv(.c) i32 {
        if (raw == 0) return 0;
        const self: *Owner = @ptrFromInt(raw);
        if (self.self_address != raw or self.prepared.generation == 0 or generation <= self.prepared.generation) return 0;
        var current: a.GfxNativeBootInfo = .{};
        if (self.display.?.bootInfo(&current) != a.gfx_output_ok or current.generation != generation or
            current.state != a.display_state_recovering) return 0;
        self.restore_requested = true;
        @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
            "NVIDIA native-restore: requested generation={d} worker=reset-and-console resources=held", .{generation});
        return self.captured.?.restoreFirmware(generation, boot);
    }
};
