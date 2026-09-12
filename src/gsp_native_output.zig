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

pub const Phase = enum {
    detached, waiting, context_start, context_wait, context_retire, context_retiring,
    methods_allocate, methods_attach, copy_allocate, copy_create, copy_wait,
    engine_create, engine_wait, mode_create, mode_wait, instance_allocate, instance_attach, instance_wait,
    core_notifier, window_notifier, surface_allocate, surface_bind,
    storage_wait, storage_release, table_upload, table_wait,
    core_create, core_wait, window_create, window_wait, immediate_create, immediate_wait,
    shadow_create, shadow_map, shadow_copy, shadow_unmap, register, publish, prepare,
    image_upload, image_wait, scanout_commit, scanout_wait, handoff, active, failed,
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
    rm_engine: u32 = 19,
    context: ?runtime.ContextHandle = null,
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
    link: ?runtime.hdmi_link.Plan = null,
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

    /// Explicit mode=native only. Check the common handoff API before the
    /// device worker can execute the already prepared firmware operations.
    pub fn request(self: *Owner, ctx: *const r4os.r4dev.DriverContext, running: *runtime.Owner, captured: *capture.Capture) !void {
        if (self.self_address != 0) return error.Busy;
        const display = ctx.graphicsDisplay() orelse return error.Api;
        const outputs = ctx.graphicsOutputs() orelse return error.Api;
        const memory = ctx.memory() orelse return error.Api;
        const clock = ctx.resources() orelse return error.Api;
        if (display.table.version != 1 or display.table.size < @sizeOf(a.GfxDriverDisplayApi) or
            display.table.prepare_held == 0 or display.table.transition == 0 or display.table.boot_info == 0 or
            outputs.table.publish == 0 or outputs.table.withdraw == 0) return error.Api;
        if (!captured.ready or captured.scanout_original == null or captured.original_boot == null or
            captured.boot.held_generation == 0 or captured.boot.read.lease.id == 0 or captured.boot.read.cpu_address == 0) return error.Binding;
        const boot = captured.original_boot.?;
        const bytes = try std.math.mul(u64, boot.pitch, boot.height);
        if (bytes == 0 or captured.boot.read.byte_length < bytes or captured.boot.read.cpu_address > std.math.maxInt(u64) - bytes) return error.Descriptor;
        const now = clock.nowNs();
        if (now == 0 or now == std.math.maxInt(u64)) return error.Clock;
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
        if (self.phase != .active and (now >= self.deadline or now >= self.phase_deadline)) return error.Deadline;
        return self.advance() catch |err| {
            if (err == error.Busy) return false;
            self.quarantine(err);
            return err;
        };
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
    fn advance(self: *Owner) !bool {
        const run = self.running.?;
        const held = self.captured.?;
        const boot = held.original_boot.?;
        switch (self.phase) {
            .waiting => {
                if (run.nativeObject() == null or run.nativeOutputs() == null or run.nativeMemoryCapabilities() == null or
                    run.nativeAddressSpace() == null or run.nativeControlBuffer() == null) return false;
                self.next(.context_start);
            },
            .context_start => {
                if (self.rm_engine > 28) return error.Unsupported;
                self.context = try run.createExecutionContext(self.rm_engine, self.phase_deadline);
                self.next(.context_wait);
            },
            .context_wait => {
                const status = try run.executionContextStatus(self.context.?);
                if (status.rejected != null or status.unavailable == .classes) return error.Unsupported;
                if (status.state != .handed_off) return false;
                if (status.unavailable == .engine) self.next(.context_retire) else {
                    if (status.info == null or status.info.?.method_bytes == 0) return error.Descriptor;
                    self.next(.methods_allocate);
                }
            },
            .context_retire => {
                try run.retireExecutionContext(self.context.?, self.phase_deadline);
                self.next(.context_retiring);
            },
            .context_retiring => {
                _ = run.executionContextStatus(self.context.?) catch |err| {
                    if (err != error.Stale) return err;
                    self.context = null;
                    self.rm_engine += 1;
                    self.next(.context_start);
                    return true;
                };
                return false;
            },
            .methods_allocate => try self.allocate((try run.executionContextStatus(self.context.?)).info.?.method_bytes, .methods_attach),
            .methods_attach => {
                try run.attachContextMethods(self.context.?, 0, self.storage.?);
                self.release(.copy_allocate);
            },
            .copy_allocate => try self.allocate(4096, .copy_create),
            .copy_create => {
                self.copy = try run.createCopyChannel(self.context.?, 0, self.storage.?, self.phase_deadline);
                self.next(.copy_wait);
            },
            .copy_wait => {
                const status = try run.executionChannelStatus(self.copy.?);
                if (status.rejected != null or status.host_rejected != null) return error.Channel;
                if (status.info == null) return false;
                self.release(.engine_create);
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
                const mask = info.hardware.windows & held.scanout_original.?.window_mask & 255;
                if (mask == 0) return error.Unsupported;
                const saved = try runtime.boot_mode.capture(&held.scanout_original.?, &boot, @ctz(mask));
                const snapshot = run.nativeOutputs() orelse return error.Busy;
                self.mode = try runtime.boot_mode.bind(saved, snapshot, run.epoch, held.boot.held_generation);
                self.link = try runtime.hdmi_link.derive(self.mode.?, run.nativeObject() orelse return error.Busy, snapshot);
                self.next(.mode_create);
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
                if (!admission.possible or admission.over_clock or admission.receipt == 0 or !std.meta.eql(admission.mode, self.mode.?)) return error.Unsupported;
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
                self.next(.surface_allocate);
            },
            .surface_allocate => {
                self.storage = try run.allocateDisplaySurface(.{ .width = boot.width, .height = boot.height,
                    .usage = a.gfx_buffer_usage_scanout | a.gfx_buffer_usage_transfer_target }, self.phase_deadline);
                self.next_phase = .surface_bind;
                self.next(.storage_wait);
            },
            .storage_wait => {
                const status = try run.nativeBufferStatus(self.storage.?);
                if (status.rejected != null or status.host_rejected != null) return error.Buffer;
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
                }
            },
            .core_wait, .window_wait, .immediate_wait => {
                const handle = switch (self.phase) { .core_wait => self.core.?, .window_wait => self.window.?, else => self.immediate.? };
                const status = try run.displayChannelStatus(handle);
                if (status.rejected != null or status.host_rejected != null) return error.Channel;
                if (status.info == null) return false;
                self.next(switch (self.phase) { .core_wait => .window_create, .window_wait => .immediate_create, else => .shadow_create });
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
                self.last_status = self.display.?.prepareHeld(&registration, held.boot.held_generation, &self.prepared);
                if (self.last_status != a.gfx_output_ok or !validState(self.prepared, held.boot.held_generation,
                    a.display_state_preparing, a.gfx_output_outcome_validated)) return error.Handoff;
                try held.boot.adoptNative(self.prepared);
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
                try self.validateRoute();
                try run.commitBootDisplayImage(self.core.?, self.window.?, self.dma, self.phase_deadline);
                self.next(.scanout_wait);
            },
            .scanout_wait => {
                const image = try run.displayImageStatus(self.engine.?, self.mode.?.window) orelse return false;
                if (run.display_work != null) return false;
                self.confirmed_image = image;
                try self.validateCompletion();
                self.next(.handoff);
            },
            .handoff => {
                try self.validateCompletion();
                self.last_status = self.display.?.transition(held.boot.held_generation, 0, &self.receipt);
                if (self.last_status != a.gfx_output_ok or !self.callback_confirmed or
                    !validState(self.receipt, held.boot.held_generation, a.display_state_software_native, a.gfx_output_outcome_applied)) return error.Handoff;
                self.next(.active);
                self.ctx.?.logInfo("NVIDIA native-output: state=software-native boot-mode=retained shadow=system scanout=vram completion=CE,WIMM,Window,Core,HDMI common-handoff=confirmed");
            },
            .active => {
                try self.validateRoute();
                return false;
            },
            .detached, .failed => return error.State,
        }
        return true;
    }

    fn validateRoute(self: *Owner) !void {
        const run = self.running.?;
        if (run.failure != null or run.outputs.invalidated) return error.Stale;
        const snapshot = run.nativeOutputs() orelse return error.Busy;
        const bound = try runtime.boot_mode.bind(self.mode.?, snapshot, run.epoch, self.captured.?.boot.held_generation);
        if (!std.meta.eql(bound, self.mode.?)) return error.Stale;
        const object = run.nativeObject() orelse return error.Busy;
        if (!std.meta.eql(try runtime.hdmi_link.derive(bound, object, snapshot), self.link.?)) return error.Stale;
    }
    fn buildPublication(self: *Owner) !void {
        try self.validateRoute();
        const snapshot = self.running.?.nativeOutputs().?;
        const mode = self.mode.?;
        var found = false;
        for (snapshot.topology.routes[0..snapshot.count], snapshot.receivers[0..snapshot.count]) |*route, *receiver| {
            if (route.id != mode.signal.display_id) continue;
            if (found) return error.Routing;
            try catalog.encode(&self.receiver, route, receiver);
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
        // Only the captured geometry is currently admitted by the common
        // bridge. Receiver modes stay in the independent receiver catalog.
        self.publication.modes[0] = .{ .mode_id = 1, .flags = a.gfx_output_mode_geometry_only | a.gfx_output_mode_preferred,
            .width = mode.width, .height = mode.height };
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
            image.link.?.acknowledged != @as(u8, if (self.mode.?.transport_hdmi) 7 else 2) or
            self.confirmed_image == null or !std.meta.eql(image, self.confirmed_image.?)) return error.Completion;
    }
    fn validState(state: a.GfxNativeState, generation: u64, expected: u32, outcome: u32) bool {
        return state.version == 1 and state.size >= @sizeOf(a.GfxNativeState) and state.reserved0 == 0 and
            state.generation == generation and state.state == expected and state.outcome == outcome and state.retained == 1;
    }
    pub fn ownsNative(self: *const Owner, current: a.GfxNativeBootInfo) bool {
        return self.self_address == @intFromPtr(self) and (self.phase == .active or self.phase == .failed) and self.callback_confirmed and
            validState(self.receipt, self.captured.?.boot.held_generation, a.display_state_software_native, a.gfx_output_outcome_applied) and
            current.state == a.display_state_software_native and current.generation == self.receipt.generation;
    }
    pub fn quarantine(self: *Owner, err: anyerror) void {
        if (self.phase == .detached) return;
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
    fn restore(raw: u64, generation: u64, _: *const a.GfxNativeBootInfo) callconv(.c) i32 {
        if (raw == 0) return 0;
        const self: *Owner = @ptrFromInt(raw);
        if (self.self_address != raw or self.prepared.generation == 0 or generation <= self.prepared.generation) return 0;
        var current: a.GfxNativeBootInfo = .{};
        if (self.display.?.bootInfo(&current) != a.gfx_output_ok or current.generation != generation or
            current.state != a.display_state_recovering) return 0;
        self.restore_requested = true;
        // Acknowledge only after an implemented physical restore and complete
        // device quiescence. Firmware teardown alone is insufficient.
        return 0;
    }
};
