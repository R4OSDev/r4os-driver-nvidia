//! Resident GA106 startup/runtime owner in serialized DriverInit/DriverWork.
//! The separate bounded gsp_irq endpoint ACKs registers and signals its worker;
//! queue/DMA mutation stays here under the actual boot hold and complete lease.
//! The first implementation retains the device through poweroff: successful
//! firmware teardown does not yet prove UEFI restoration or global DMA stop.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const native = @import("gsp_sequencer_port.zig");
const memory = @import("gsp_run_memory.zig");
const capture = @import("boot_vram.zig");
const vram = @import("boot_vram_lease.zig");
const logs = @import("gsp_logs.zig");
const firmware = @import("falcon_run.zig");
const hs = @import("falcon_hs.zig");
const core = @import("gsp_core.zig");
const booter = @import("booter_result.zig");
const security = @import("fwsec_result.zig");
const transport = @import("gsp_transport.zig");
const events = @import("gsp_boot_events.zig");
const sequencer = @import("gsp_sequencer.zig");
const teardown = @import("gsp_teardown.zig");
const runtime = @import("gsp_runtime.zig");
const preboot = @import("gsp_preboot.zig");
const irq = @import("gsp_irq.zig");

pub const Phase = enum { detached, frts, prepare, load, start, notifications, ready, recovering, failed };
pub const Progress = enum { progress, idle, stopped };
pub const Device = struct {
    self_address: usize = 0,
    ctx: ?r4os.r4dev.DriverContext = null,
    display: ?*capture.Capture = null,
    vram: ?*vram.Lease = null,
    memory: ?*memory.Lease = null,
    reader: ?*logs.Reader = null,
    port: native.Port = .{},
    phase: Phase = .detached,
    epoch: u64 = 0,
    display_epoch: u64 = 0,
    deadline: u64 = 0,
    phase_deadline: u64 = 0,
    last_clock: u64 = 0,
    stopped: bool = false,
    failure: ?anyerror = null,
    failed_phase: ?Phase = null,
    recovery_failure: ?anyerror = null,
    frts_result: ?firmware.Result = null,
    load_result: ?firmware.Result = null,
    expected_firmware: ?firmware.Options = null,
    session: ?transport.Session = null,
    boot: ?events.Boot = null,
    sequence: ?sequencer.DispatchExecution = null,
    handoff: ?events.Handoff = null,
    recovery: teardown.Recovery = .{},
    running: runtime.Owner = .{},
    catalog: @import("gsp_catalog.zig").Owner = .{},
    board: ?@import("vbios.zig").Result = null,
    interrupts: irq.Owner = .{},
    irq_wake: ?irq.Wake = null,
    recovery_deadline: u64 = 0,
    recovery_started: bool = false,
    tx: [transport.message.max_bytes]u8 = undefined,
    rx: [transport.message.max_bytes]u8 = undefined,

    /// Open only after the complete original package and boot snapshots were
    /// admitted. No reset or firmware instruction occurs until step(). The
    /// caller must retain this address and use a kernel with terminal display
    /// shutdown and thread-to-work admission (DriverApi35 / Kernel0.1.152).
    pub fn open(self: *Device, ctx: *const r4os.r4dev.DriverContext, display: *capture.Capture,
        reservation: *vram.Lease, backing: *memory.Lease, reader: *logs.Reader,
        board: ?*const @import("vbios.zig").Result) !void
    {
        if (self.self_address != 0) return error.Busy;
        if (ctx.apiVersion() < a.driver_api_thread_work_version) return error.Api;
        if (display.context == null or display.context.?.api != ctx.api or display.snapshot == null or
            display.chip == null or display.chip.?.id != 0x176 or display.operation == null or
            !display.ready or display.firmware_owner != 0 or reservation.display != display or
            reservation.backing != backing.boot_storage or backing.api != ctx.api or
            reader.memory != backing or reader.generation() != backing.generation() or reader.busy) return error.Binding;
        if (display.snapshot.?.command & 4 == 0) return error.BusMasterDisabled;
        if (board) |value| if (value.validated_device != display.snapshot.?.pci.device_id) return error.Binding;
        const inputs = try backing.inputs();
        const frts = inputs.frts orelse return error.Binding;
        if (!reservation.validates(frts) or inputs.fwsec_command != 0x15 or
            backing.retained or display.boot.held_generation == 0) return error.Binding;
        const clock = ctx.resources() orelse return error.Api;
        const opened_at = clock.nowNs();
        if (opened_at == 0 or opened_at == std.math.maxInt(u64)) return error.Clock;
        const deadline = try std.math.add(u64, opened_at, 30 * std.time.ns_per_s);
        self.self_address = @intFromPtr(self);
        self.ctx = ctx.*;
        self.display = display;
        self.vram = reservation;
        self.memory = backing;
        self.reader = reader;
        self.epoch = backing.generation();
        self.display_epoch = display.boot.held_generation;
        self.deadline = deadline;
        self.last_clock = opened_at;
        if (board) |value| {
            self.board = value.*;
            self.running.outputs.board = &self.board.?;
        }
        errdefer |err| { self.failure = err; self.failed_phase = self.phase; self.phase = .failed; }
        const pci = display.snapshot.?.pci;
        const adapter = 0x0100_0000 | (@as(u32, pci.bus) << 8) | (@as(u32, pci.device) << 3) | pci.function;
        self.running.adapter_id = adapter;
        try self.catalog.open(ctx, adapter);
        errdefer _ = self.catalog.close();
        try self.checkLive(false);
        const original = display.operation.?.options;
        try self.port.openShared(ctx, &display.snapshot.?, original.boot0, original.boot1,
            .{ .epoch = self.epoch, .deadline_ns = deadline, .resume_args = inputs.resume_args },
            self.owner(), &display.registers);
        var payloads: preboot.Payloads = .{};
        try preboot.encode(&display.snapshot.?, display.original_boot.?.byte_length, &payloads);
        self.session = try transport.Session.init(try self.port.transportPort(), .{ .chip_id = 0x176 }, self.epoch, &self.tx, &self.rx);
        try self.port.preloadInit(&self.session.?, &payloads.system, &payloads.registry);
        self.ctx.?.logInfo("NVIDIA gsp-start: preboot=system-info,registry rpc-sequence=0 queue-sequence=2 firmware-submitted=no");
        try self.beginFirmware(.frts, &inputs);
    }

    fn now(self: *Device) !u64 {
        const value = self.port.clock orelse return error.Api;
        const current = value.nowNs();
        if (current == std.math.maxInt(u64) or current < self.last_clock) return error.Clock;
        self.last_clock = current;
        return current;
    }
    fn phaseLimit(self: *Device) !u64 {
        const current = try self.now();
        if (current >= self.deadline) return error.Deadline;
        return @min(self.deadline, current +| (5 * std.time.ns_per_s));
    }
    fn beginFirmware(self: *Device, phase: Phase, inputs: *const memory.Inputs) !void {
        self.phase = phase;
        self.phase_deadline = try self.phaseLimit();
        const options: firmware.Options = switch (phase) {
            .frts => .{ .engine = .gsp, .boot0 = self.port.boot0, .epoch = self.epoch,
                .deadline = self.phase_deadline, .plan = inputs.fwsec,
                .fwsec = .{ .frts = inputs.frts.?.range.offset } },
            .load => .{ .engine = .sec2, .boot0 = self.port.boot0, .epoch = self.epoch,
                .deadline = self.phase_deadline, .plan = inputs.booters[0].plan,
                .booter = .{ .normal_load = inputs.boot.metadata_address },
                .mailboxes = try booter.arguments(.{ .normal_load = inputs.boot.metadata_address }) },
            else => return error.State,
        };
        self.expected_firmware = options;
        try self.port.beginFirmware(options);
        self.logPhase();
    }
    fn beginCold(self: *Device, stage: core.ColdStage) !void {
        self.phase = if (stage == .prepare) .prepare else .start;
        self.phase_deadline = try self.phaseLimit();
        self.expected_firmware = null;
        try self.port.beginColdBoot(stage, self.phase_deadline);
        self.logPhase();
    }

    /// At most one native phase step or one notification. A shared worker
    /// may call a bounded number of these; waits belong to its dedicated
    /// pacing task, never an IRQ or a long-running shared-work callback.
    pub fn step(self: *Device) Progress {
        if (self.self_address == 0 or self.self_address != @intFromPtr(self)) return .stopped;
        if (self.stopped or self.phase == .failed) { _ = self.catalog.close(); return .stopped; }
        const progress = self.advance() catch |err| blk: {
            if (self.phase == .recovering) {
                self.recovery_failure = err;
                self.phase = .failed;
                self.logFailure("teardown", err);
            } else self.fail(err);
            break :blk true;
        };
        return if (self.phase == .failed) .stopped else if (progress) .progress else .idle;
    }
    fn advance(self: *Device) !bool {
        if (self.phase == .recovering) {
            if (!self.recovery_started) {
                if (try self.now() >= self.recovery_deadline) return error.IrqRetirement;
                if (!self.interrupts.close()) return true;
                try self.recovery.open(&self.port, self.reader.?, self.recovery_deadline);
                self.recovery_started = true;
                return true;
            }
            if (try self.recovery.step()) {
                self.phase = .failed;
                self.ctx.?.logWarn("NVIDIA gsp-start: teardown=complete memory=retained display=held poweroff-required=yes");
            }
            return true;
        }
        try self.checkLive(false);
        if (self.phase == .ready) {
            if (self.interrupts.failed()) return error.Interrupt;
            if (self.running.post.snapshot()) |inventory| {
                if (self.interrupts.self_address == 0) {
                    if (try self.now() >= self.deadline) return error.Deadline;
                    if (!self.inLockdown() and self.running.sequence.self_address == 0) {
                        try self.interrupts.open(&self.ctx.?, &self.display.?.registers, &self.display.?.snapshot.?,
                            self.display.?.chip.?, inventory, self.irq_wake orelse return error.IrqWake, self.port.boot0);
                        self.running.rm_enabled = true;
                        self.ctx.?.logInfo("NVIDIA gsp-irq: configured=yes source=GSP wake=semaphore worker=serialized native-output=unavailable");
                        return true;
                    }
                }
            }
            const progress = try self.running.step() == .progress;
            if (self.running.outputs.invalidated) try self.catalog.invalidate();
            if (self.running.nativeOutputs()) |snapshot| {
                // A rejected discovery supplies no authoritative generation.
                if (snapshot.topology.rejected == null and snapshot.final_rejection == null) {
                    const before = self.catalog.sequence;
                    try self.catalog.publish(snapshot);
                    if (before != self.catalog.sequence) {
                        var bytes: [180]u8 = undefined;
                        const line = try std.fmt.bufPrintZ(&bytes, "NVIDIA gsp-catalog: generation={d} receivers={d} source=receiver-only modeset=no",
                            .{ snapshot.generation, snapshot.count });
                        self.ctx.?.logInfo(line);
                    }
                } else try self.catalog.invalidate();
            }
            return progress;
        }
        if (try self.now() >= self.deadline) return error.Deadline;
        switch (self.phase) {
            .frts, .load => if (try self.port.stepFirmware()) |result| {
                if (self.phase == .frts) {
                    if (result.fwsec == null) return error.State;
                    self.frts_result = result;
                    try self.beginCold(.prepare);
                } else {
                    if (result.booter == null or result.booter.?.skipped) return error.State;
                    self.load_result = result;
                    try self.beginCold(.finish);
                }
            },
            .prepare => if (try self.port.stepColdBoot()) {
                const inputs = try self.memory.?.inputs();
                try self.beginFirmware(.load, &inputs);
            },
            .start => if (try self.port.stepColdBoot()) {
                self.phase = .notifications;
                self.phase_deadline = self.deadline;
                if (self.session == null or self.port.preloaded_session != &self.session.? or self.session.?.tx_sequence != 2) return error.State;
                self.boot = try events.Boot.init(&self.session.?, self.deadline);
                self.logPhase();
            },
            .notifications => return self.poll(),
            else => return error.State,
        }
        return true;
    }
    fn poll(self: *Device) !bool {
        const boot = &self.boot.?;
        if (self.sequence) |*execution| {
            if (try execution.step() == .complete) self.sequence = null;
            return true;
        }
        const dispatch = try boot.poll() orelse return false;
        switch (dispatch.event) {
            .cpu_sequencer => {
                self.sequence = try sequencer.DispatchExecution.init(boot, try self.port.sequencer(),
                    .{ .default_timeout_ns = std.time.ns_per_s, .poll_interval_ns = std.time.ns_per_ms,
                        .register_bytes = self.port.window.byte_length });
                return true;
            },
            .os_error, .nocat => {
                self.logFailure("firmware-event", error.FirmwareError);
                boot.reject(dispatch.ticket) catch {};
                return error.FirmwareError;
            },
            .libos_print => |message| self.logBytes(message.engine, message.bytes),
            .lockdown, .init_done => {},
        }
        try boot.complete(dispatch.ticket);
        if (boot.state == .init_done) {
            self.handoff = try self.port.handoffBoot(boot);
            self.phase = .ready;
            try self.running.open(&self.ctx.?, &self.port, &self.handoff.?, self.reader.?, self.vram.?, self.deadline);
            self.ctx.?.logInfo("NVIDIA gsp-start: firmware-ready=INIT_DONE ack=complete rm-static=awaiting runtime=polling memory=retained display=held native-output=unavailable");
        }
        return true;
    }
    fn fail(self: *Device, err: anyerror) void {
        if (self.failure == null) { self.failure = err; self.failed_phase = self.phase; }
        self.running.reportIrq(&self.interrupts); // Worker-side snapshot; no allocation or BO mutation in the IRQ.
        self.running.stop(err);
        if (!self.catalog.close()) self.ctx.?.logError("NVIDIA gsp-catalog: metadata close failed; cleanup retry required");
        self.logFailure(if (self.phase == .ready) "runtime" else "startup", err);
        if (self.interrupts.self_address != 0) {
            var bytes: [220]u8 = undefined;
            const endpoint = &self.interrupts;
            const line = std.fmt.bufPrintZ(&bytes, "NVIDIA gsp-irq: failed irq={d} status={d} fault={d} raw={x} mask={x} received={d} messages={d}",
                .{ endpoint.irq, endpoint.last_status, @atomicLoad(u32, &endpoint.fault, .acquire),
                    @atomicLoad(u32, &endpoint.last_raw, .acquire), @atomicLoad(u32, &endpoint.last_mask, .acquire),
                    @atomicLoad(u64, &endpoint.interrupts, .acquire), @atomicLoad(u64, &endpoint.messages, .acquire) }) catch null;
            if (line) |text| self.ctx.?.logError(text);
        }
        if (!self.port.effects_possible or !self.memory.?.retained) { self.phase = .failed; return; }
        self.phase = .recovering;
        const current = self.now() catch |failure| { self.recovery_failure = failure; self.phase = .failed; return; };
        const limit = std.math.add(u64, current, 10 * std.time.ns_per_s) catch { self.phase = .failed; return; };
        self.recovery_deadline = limit;
        // The next short worker slice retires IRQ delivery first. No reset
        // races a live callback; failure retains the entire GPU dependency graph.
    }
    pub fn stop(self: *Device) bool {
        if (!self.catalog.close()) return false;
        self.running.stop(error.Stopped);
        if (!self.interrupts.close()) return false;
        self.stopped = true;
        return true;
    }
    pub fn closeBeforeSubmission(self: *Device) bool {
        if (self.self_address == 0) return true;
        if (!self.catalog.close()) return false;
        if (self.self_address != @intFromPtr(self) or self.port.effects_possible or
            self.memory.?.retained or self.display.?.firmware_owner != 0) return false;
        if (!self.port.close()) return false;
        self.* = .{};
        return true;
    }

    fn from(raw: *anyopaque) *Device { return @ptrCast(@alignCast(raw)); }
    fn checkLive(self: *Device, recovering: bool) !void {
        if (self.self_address == 0 or self.self_address != @intFromPtr(self) or self.stopped) return error.State;
        const display = self.display orelse return error.Binding;
        const backing = self.memory orelse return error.Binding;
        const reservation = self.vram orelse return error.Binding;
        if (display.self_address != @intFromPtr(display) or !display.ready or display.context == null or
            display.context.?.api != self.ctx.?.api or display.boot.held_generation != self.display_epoch or
            display.borrower != @intFromPtr(reservation) or !display.register_access.valid() or
            (display.firmware_owner != 0 and display.firmware_owner != self.self_address)) return error.Binding;
        const inputs = if (recovering)
            (if (backing.recovery_owner == 0) try backing.retainedInputs() else try backing.recoveryInputs(backing.recovery_owner))
            else try backing.inputs();
        if (backing.queue.epoch != self.epoch or inputs.frts == null or !reservation.validates(inputs.frts.?)) return error.Stale;
        const original = display.original_boot orelse return error.Binding;
        var current: a.GfxNativeBootInfo = .{};
        if (display.boot.display.?.bootInfo(&current) != a.gfx_output_ok or current.state != a.display_state_preparing or
            current.generation != original.generation or current.physical_address != original.physical_address or
            current.byte_length != original.byte_length or current.width != original.width or
            current.height != original.height or current.pitch != original.pitch or current.format != original.format) return error.Display;
    }
    fn owner(self: *Device) native.Owner {
        return .{ .context = self, .generation = generation, .admit = admit, .access = access,
            .retain = retain, .quiesced = quiesced, .log_polling = polling,
            .admit_firmware = admitFirmware, .admit_cold = admitCold, .queue_memory = self.memory,
            .admit_runtime = admitRuntime, .admit_command = admitCommand, .admit_copy = admitCopy,
            .admit_display_retirement = admitDisplayRetirement,
            .admit_display_push = admitDisplayPush,
            .recovery = .{ .generation = recoveryGeneration, .admit = admitRecovery, .access = recoveryAccess } };
    }
    fn generation(raw: *anyopaque) u64 {
        const self = from(raw);
        self.checkLive(false) catch return 0;
        return self.epoch;
    }
    fn retain(raw: *anyopaque) !void {
        const self = from(raw);
        try self.checkLive(false);
        try self.display.?.retainForFirmware(self.self_address, self.display_epoch);
    }
    fn quiesced(raw: *anyopaque) bool {
        const self = from(raw);
        // Deliberately no post-submit success until full device and UEFI
        // restoration have real implementations and hardware evidence.
        return !self.memory.?.retained and self.display.?.firmware_owner == 0;
    }
    fn polling(raw: *anyopaque, enabled: bool) !void {
        const self = from(raw);
        try self.checkLive(false);
        try self.reader.?.setPolling(enabled);
    }
    fn admitFirmware(raw: *anyopaque, options: *const firmware.Options) !void {
        const self = from(raw);
        try self.checkLive(false);
        const expected = self.expected_firmware orelse return error.State;
        if (!std.meta.eql(expected, options.*) or (self.phase != .frts and self.phase != .load)) return error.Binding;
        const inputs = try self.memory.?.inputs();
        if (self.phase == .frts) {
            if (!std.meta.eql(options.plan, inputs.fwsec) or options.fwsec == null or
                options.fwsec.? != .frts or options.fwsec.?.frts != inputs.frts.?.range.offset) return error.Binding;
        } else if (self.frts_result == null or inputs.booters[0].prepared.operation != .load or
            !std.meta.eql(options.plan, inputs.booters[0].plan) or options.booter == null or
            options.booter.? != .normal_load or options.booter.?.normal_load != inputs.boot.metadata_address) return error.Binding;
    }
    fn admitCold(raw: *anyopaque, command: core.Cold) !void {
        const self = from(raw);
        try self.checkLive(false);
        if (!std.meta.eql(command.args, (try self.memory.?.inputs()).resume_args) or self.frts_result == null) return error.Binding;
        if (command.stage == .prepare) {
            if (self.phase != .prepare or self.load_result != null) return error.State;
        } else if (self.phase != .start or self.load_result == null) return error.State;
    }
    fn admitRuntime(raw: *anyopaque, boot: *const events.Boot) !void {
        const self = from(raw);
        try self.checkLive(false);
        if (self.phase != .notifications or self.boot == null or boot != &self.boot.? or
            self.load_result == null or self.frts_result == null or self.sequence != null) return error.Binding;
    }
    fn admit(raw: *anyopaque, command: sequencer.Command) error{ Denied, Unsupported }!void {
        const self = from(raw);
        self.checkLive(false) catch return error.Denied;
        if ((self.phase != .notifications and self.phase != .ready) or self.boot == null or self.inLockdown()) return error.Denied;
        const permitted = switch (command) {
            .write => |v| allowed(.write, v.address),
            .modify => |v| allowed(.read, v.address) and allowed(.write, v.address),
            .poll => |v| allowed(.read, v.address),
            .store => |v| allowed(.read, v.address),
            .delay_us, .core_reset, .core_start, .core_halt, .core_resume => true,
        };
        if (!permitted) return error.Unsupported;
    }
    fn admitCommand(raw: *anyopaque, port: *const native.Port, deadline: u64) !void {
        const self = from(raw);
        try self.checkLive(false);
        if (self.phase != .ready or port != &self.port or port.phase != .runtime or self.session == null or
            self.running.self_address != @intFromPtr(&self.running) or self.running.failure != null or
            self.running.sequence.self_address != 0) return error.State;
        const channel = self.running.activeChannel() orelse return error.State;
        if (channel.session != &self.session.? or port.runtime_session != channel.session or
            channel.phase != .prepared or channel.pending != null or channel.session.pending != null or
            channel.deadline != deadline) return error.Binding;
        if (channel.in_lockdown) return error.Lockdown;
        if (self.running.display_channel_active) |index| {
            const display_dma = if (self.running.display_channels[index]) |*value| value else return error.Binding;
            if (!display_dma.matches(channel, deadline)) return error.Binding;
        } else if (self.running.display_engine_active) {
            const display_root = if (self.running.display_engine_owner) |*value| value else return error.Binding;
            if (!display_root.matches(channel, deadline)) return error.Binding;
        } else if (self.running.fifo_active) |index| {
            const fifo = self.running.fifos[index].owner orelse return error.Binding;
            if (!fifo.matches(channel, deadline)) return error.Binding;
        } else if (self.running.context_active) |index| {
            const context = self.running.contexts[index].owner orelse return error.Binding;
            if (!context.matches(channel, deadline)) return error.Binding;
        } else if (self.running.native_active) |index| {
            const allocation = self.running.native_buffers[index].owner orelse return error.Binding;
            if (!allocation.matches(channel, deadline)) return error.Binding;
        } else if (self.running.buffer_active) |index| {
            const mapping = self.running.buffers[index].owner orelse return error.Binding;
            if (!mapping.matches(channel, deadline)) return error.Binding;
        } else if (self.running.outputs.active()) {
            if (!self.running.outputs.matches(channel, deadline)) return error.Binding;
        } else if (self.running.graph) |*graph| {
            if (!graph.matches(channel, deadline)) return error.Binding;
        } else if (self.running.static_info == null) {
            if (channel.function != @import("gsp_static.zig").function or
                channel.request.ptr != self.running.static_request[0..].ptr or channel.request.len != self.running.static_request.len) return error.Binding;
        } else if (!self.running.post.matches(channel, deadline)) return error.Binding;
    }
    fn admitDisplayRetirement(raw: *anyopaque, port: *const native.Port, display_dma: *@import("gsp_display_channel.zig").Owner, deadline: u64) !void {
        const self = from(raw);
        try self.checkLive(false);
        if (self.phase != .ready or port != &self.port or port.phase != .runtime or self.session == null or self.inLockdown() or
            self.running.self_address != @intFromPtr(&self.running) or self.running.failure != null or self.running.sequence.self_address != 0) return error.State;
        const index = self.running.display_channel_active orelse return error.State;
        const current = if (self.running.display_channels[index]) |*value| value else return error.Binding;
        if (current != display_dma or !current.admitsRetirement(deadline) or self.running.activeChannel() != &current.exchange or
            current.exchange.session != &self.session.? or port.runtime_session != &self.session.? or self.session.?.pending != null) return error.Binding;
    }
    fn admitCopy(raw: *anyopaque, port: *const native.Port, fifo: *@import("gsp_fifo.zig").Owner, ticket: @import("gsp_copy_ring.zig").Ticket, deadline: u64) !void {
        const self = from(raw);
        try self.checkLive(false);
        if (self.phase != .ready or port != &self.port or port.phase != .runtime or self.session == null or self.inLockdown() or
            self.running.self_address != @intFromPtr(&self.running) or self.running.failure != null or self.running.sequence.self_address != 0 or
            self.running.fifo_active != null or self.running.context_active != null or self.running.native_active != null or self.running.buffer_active != null or
            self.running.outputs.active() or self.running.graph_closing or self.running.display_engine_active or self.running.display_channel_active != null or self.running.display_work != null) return error.State;
        const channel_handle = if (self.running.display_upload_job) |*work| blk: {
            const resources = self.running.display_resources_slot.owner orelse return error.Binding;
            const root = if (self.running.display_engine_owner) |*value| value else return error.Binding;
            const graph = if (self.running.graph) |*value| value else return error.Binding;
            const staging = if (graph.control_buffer) |*value| value else return error.Binding;
            if (self.running.copy_job != null or root.channels_started or root.info() == null or !root.instance_bound or
                !resources.valid() or !std.meta.eql(resources.binding.?, root.binding) or resources.instance != &root.instance_storage or
                work.operation.table != &resources.table or work.operation.source != staging or work.operation.target != &root.instance_storage or
                !work.operation.matches(ticket, deadline) or fifo.config.context.vaspace != staging.binding.space.handle) return error.Binding;
            if (!fifo.ring.matchesTransfer(ticket, fifo.config.copy_class, work.operation.transfer() catch return error.Binding)) return error.Binding;
            for (&self.running.display_channels) |*entry| if (entry.* != null) return error.Binding;
            break :blk work.channel_handle;
        } else blk: {
            const work = if (self.running.copy_job) |*value| value else return error.Binding;
            if (work.submitted or work.ticket == null or !std.meta.eql(work.ticket.?, ticket) or !std.meta.eql(work.job, work.job_stamp) or
                work.deadline != deadline) return error.Binding;
            break :blk work.channel_handle;
        };
        if (channel_handle.epoch != self.epoch or channel_handle.slot >= self.running.fifos.len) return error.Binding;
        const slot = &self.running.fifos[channel_handle.slot];
        if (slot.owner != fifo or slot.serial != channel_handle.serial or !fifo.matchesCopy(ticket)) return error.Binding;
        const rpc = self.running.activeChannel() orelse return error.State;
        if (rpc.session != &self.session.? or port.runtime_session != rpc.session or rpc.session.pending != null or
            rpc.phase != .idle or rpc.pending != null or rpc.in_lockdown or ticket.epoch != self.epoch) return error.Binding;
        try rpc.guard(deadline);
    }
    fn admitDisplayPush(raw: *anyopaque, port: *const native.Port, channel: *@import("gsp_display_channel.zig").Owner, deadline: u64, access_kind: native.DisplayAccess) !void {
        const self = from(raw);
        try self.checkLive(false);
        if (self.phase != .ready or port != &self.port or port.phase != .runtime or self.session == null or self.inLockdown() or
            self.running.self_address != @intFromPtr(&self.running) or self.running.failure != null or self.running.sequence.self_address != 0 or
            self.running.fifo_active != null or self.running.context_active != null or self.running.native_active != null or self.running.buffer_active != null or
            self.running.outputs.active() or self.running.graph_closing or self.running.display_engine_active or self.running.display_channel_active != null or
            self.running.copy_job != null or self.running.display_upload_job != null) return error.State;
        const work = if (self.running.display_work) |*value| value else return error.Binding;
        const resources = self.running.display_resources_slot.owner orelse return error.Binding;
        const root = if (self.running.display_engine_owner) |*value| value else return error.Binding;
        const root_info = root.info() orelse return error.Binding;
        if (!resources.valid()) return error.Binding;
        if (work.handle.epoch != self.epoch or work.handle.slot != 0 or work.deadline != deadline or self.running.display_channels[0] == null or
            &self.running.display_channels[0].? != channel or channel.config.handle != work.handle.handle or channel.config.kind != .core or
            channel.parent != root or channel.info() == null or !channel.ring.valid() or resources.instance != &root.instance_storage or
            !std.meta.eql(resources.binding.?, root.binding) or resources.publishedNotifier(0) != work.notifier or
            work.config.notifier != work.notifier.handle or work.config.windows != root_info.hardware.windows or
            work.config.initialize == channel.ring.initialized) return error.Binding;
        if (access_kind == .publish) {
            if (work.phase != .prepare or work.ticket == null or !channel.ring.matches(work.ticket.?, work.config)) return error.Binding;
            if (work.ticket.?.kind == .frame and (work.notifier.phase != .armed or work.notifier.point != work.ticket.?.point or work.notifier.deadline != deadline)) return error.Binding;
        } else if (work.phase != .prepare and work.phase != .rewind) return error.Binding;
        const rpc = self.running.activeChannel() orelse return error.State;
        const canonical = if (self.running.channel) |*value| value else return error.State;
        if (rpc != canonical or rpc.session != &self.session.? or port.runtime_session != rpc.session or rpc.session.pending != null or
            rpc.phase != .idle or rpc.pending != null or rpc.in_lockdown or rpc.request.len != 0) return error.Binding;
        try rpc.guard(deadline);
    }
    fn access(raw: *anyopaque, kind: native.Access, address: u32) !void {
        const self = from(raw);
        try self.checkLive(false);
        if (self.inLockdown()) return error.Lockdown;
        if (!allowed(kind, address)) return error.Register;
    }
    fn inLockdown(self: *Device) bool {
        if (self.running.activeChannel()) |channel| return channel.in_lockdown;
        return if (self.boot) |*boot| boot.in_lockdown else false;
    }
    fn recoveryGeneration(raw: *anyopaque) u64 {
        const self = from(raw);
        if (self.phase != .recovering) return 0;
        self.checkLive(true) catch return 0;
        return self.epoch;
    }
    fn admitRecovery(raw: *anyopaque, port: *const native.Port) !void {
        const self = from(raw);
        if (port != &self.port or self.phase != .recovering or self.failure == null or self.reader.?.busy or
            self.reader.?.enabled or self.display.?.firmware_owner != self.self_address or
            (self.interrupts.self_address != 0 and !self.interrupts.closed)) return error.State;
        try self.checkLive(true);
    }
    fn recoveryAccess(raw: *anyopaque, kind: native.Access, address: u32) !void {
        const self = from(raw);
        if (self.phase != .recovering) return error.State;
        try self.checkLive(true);
        if (!allowed(kind, address)) return error.Register;
    }
    fn logPhase(self: *Device) void {
        var buffer: [180]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buffer, "NVIDIA gsp-start: phase={s} epoch={d} deadline-ns={d} display-hold={d}",
            .{ @tagName(self.phase), self.epoch, self.phase_deadline, self.display_epoch }) catch return;
        self.ctx.?.logInfo(text);
    }
    fn logFailure(self: *Device, phase: []const u8, err: anyerror) void {
        var buffer: [220]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buffer, "NVIDIA gsp-start: failed={s} phase={s} reason={s} effects={} memory-retained={}",
            .{ phase, @tagName(self.failed_phase orelse self.phase), @errorName(err), self.port.effects_possible, self.memory.?.retained }) catch return;
        self.ctx.?.logError(text);
    }
    fn logBytes(self: *Device, engine: u32, bytes: []const u8) void {
        var escaped: [160]u8 = undefined;
        const count = @min(bytes.len, escaped.len);
        for (bytes[0..count], escaped[0..count]) |byte, *out| out.* = if (byte >= 32 and byte < 127) byte else '.';
        var buffer: [240]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buffer, "NVIDIA gsp-print: engine={d} bytes={d} text={s}", .{ engine, bytes.len, escaped[0..count] }) catch return;
        self.ctx.?.logInfo(text);
    }
};

/// Only the published registers already used by our GA106 firmware/core
/// executors are admitted. An unfamiliar firmware sequencer request stops
/// with its original receipt; it never expands this policy dynamically.
pub fn allowed(kind: native.Access, address: u32) bool {
    if (address & 3 != 0) return false;
    if (address == 0 or address == 4) return kind == .read;
    for ([_]u32{ core.reg.hwcfg2, core.reg.sec_hwcfg2, core.reg.riscv_cpuctl, core.reg.handoff,
        hs.reg.gsp + firmware.hwcfg_offset, hs.reg.sec2 + firmware.hwcfg_offset }) |read_only|
        if (address == read_only) return kind == .read;
    if (kind == .read and (address == core.reg.cpuctl_alias or address == core.reg.sec_cpuctl_alias)) return false;
    inline for (@typeInfo(core.reg).@"struct".decls) |decl| {
        if (address == @field(core.reg, decl.name)) return true;
    }
    const offsets = [_]u32{ 0xf4, firmware.hwcfg_offset, hs.reg.dma_control, hs.reg.dma_base,
        hs.reg.dma_base_high, hs.reg.dma_destination, hs.reg.dma_source_offset, hs.reg.dma_command,
        hs.reg.fbif_offset + hs.reg.fbif_control, hs.reg.fbif_offset + hs.reg.transcfg,
        hs.reg.second_offset + hs.reg.signature, hs.reg.second_offset + hs.reg.engine_mask,
        hs.reg.second_offset + hs.reg.ucode, hs.reg.second_offset + hs.reg.algorithm,
        hs.reg.boot_vector, hs.reg.cpu_control, hs.reg.cpu_alias, hs.reg.mailbox0, hs.reg.mailbox1 };
    for ([_]u32{ hs.reg.gsp, hs.reg.sec2 }) |base| for (offsets) |offset| if (address == base + offset) return true;
    if (kind == .read) {
        for (security.frts_registers ++ security.sb_registers) |register| if (address == register) return true;
    }
    return false;
}
