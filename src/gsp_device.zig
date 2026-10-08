//! Resident GA106 startup/runtime owner in serialized DriverInit/DriverWork.
//! The separate bounded gsp_irq endpoint ACKs registers and signals its worker;
//! queue/DMA mutation stays here under the actual boot hold and complete lease.
//! Old DMA retires only after the bounded GA106 reset proof. Rebuilt native
//! output or the restored reserved console keeps its new device graph resident.
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
const reset = @import("gsp_reset.zig");
const console = @import("boot_console.zig");

pub const Phase = enum { detached, frts, prepare, load, start, notifications, ready, recovering, resetting, retiring, failed };
pub const Progress = enum { progress, idle, stopped };
const LiveCheck = enum { state, binding, inputs, frts, display };
pub const RecoveryHooks = struct {
    context: usize = 0,
    // CPU-only restaging after old Port/Reader/RunMemory ownership retired.
    // It must leave a fresh, unsubmitted RunMemory and matching log reader.
    restage: *const fn (usize, *Device) anyerror!void,
};
pub const Device = struct {
    self_address: usize = 0,
    ctx: ?r4os.r4dev.DriverContext = null,
    clock_api: ?r4os.r4dev.DriverResourceContext = null,
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
    terminal_requested: bool = false,
    terminal_console_requested: bool = false,
    terminal_retired: bool = false,
    terminal_deadline: u64 = 0,
    failure: ?anyerror = null,
    failed_phase: ?Phase = null,
    recovery_failure: ?anyerror = null,
    first_live_failure: ?anyerror = null,
    live_failure_epoch: u64 = 0,
    live_check: LiveCheck = .state,
    live_detail: struct {
        check: LiveCheck = .state,
        memory_valid: bool = false,
        memory_failed: bool = false,
        recovery_owner: usize = 0,
        queue_epoch: u64 = 0,
        queue_failed: bool = false,
        queue_status: i32 = 0,
        log_status: i32 = 0,
        reader_error: ?anyerror = null,
        frts_error: ?anyerror = null,
    } = .{},
    failed_boot_info_status: i32 = std.math.minInt(i32),
    failed_boot_info: a.GfxNativeBootInfo = .{},
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
    native_output: @import("gsp_native_output.zig").Owner = .{},
    native_graphics: @import("gsp_native_graphics.zig").Owner = .{},
    render_startup: @import("gsp_render_startup.zig").Owner = .{},
    board: ?@import("vbios.zig").Result = null,
    interrupts: irq.Owner = .{},
    irq_wake: ?irq.Wake = null,
    recovery_deadline: u64 = 0,
    recovery_started: bool = false,
    reset_config: reset.Config = .{},
    reset_config_failure: ?anyerror = null,
    gpu_reset: reset.Reset = .{},
    fault_reset_attempted: bool = false,
    terminal_reset_attempted: bool = false,
    recovery_hooks: ?RecoveryHooks = null,
    reset_binding: a.GfxBackendBinding = .{},
    reset_original_display: u64 = 0,
    reset_display_status: i32 = 0,
    reset_display: a.GfxNativeState = .{},
    reset_retire_stage: enum { runtime, common, output, console_memory, port, reader, memory, terminal, restage, restart } = .runtime,
    reset_to_console: bool = false,
    boot_console: console.Owner = .{},
    reset_retire_deadline: u64 = 0,
    reset_frame_count: u8 = 2,
    reset_graphics_requested: bool = false,
    reset_output_requested: bool = false,
    reset_output_route: ?@import("gsp_output_route.zig").RestoreIdentity = null,
    headless_resumed: bool = false,
    reset_audio_location: u32 = 0,
    reset_audio_device: u32 = 0,
    reset_audio_attached: bool = false,
    heads_reported: u32 = 0,
    flip_watch: [8]struct {
        epoch: u64 = 0,
        sequence: u64 = 0,
        first_seen_ns: u64 = 0,
        reported: bool = false,
    } = @splat(.{}),
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
            display.chip == null or !@import("generation.zig").ga102Hal(display.chip.?.id) or display.operation == null or
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
        if (!(display.boot.display orelse return error.Api).supportsTerminalRelease()) return error.Api;
        const opened_at = clock.nowNs();
        if (opened_at == 0 or opened_at == std.math.maxInt(u64)) return error.Clock;
        const deadline = try std.math.add(u64, opened_at, 30 * std.time.ns_per_s);
        self.self_address = @intFromPtr(self);
        self.ctx = ctx.*;
        self.clock_api = clock;
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
        self.reset_config.capture(&display.snapshot.?, original.boot0, original.boot1, self.resetIo()) catch |err| {
            self.reset_config_failure = err;
            @import("gsp_mode_diagnostics.zig").write(ctx,
                "NVIDIA gpu-reset: capability=unavailable reason={s} scope=selected-NVIDIA-Fn0 initial-start=allowed", .{@errorName(err)});
        };
        try self.port.openShared(ctx, &display.snapshot.?, original.boot0, original.boot1,
            .{ .epoch = self.epoch, .deadline_ns = deadline, .resume_args = inputs.resume_args },
            self.owner(), &display.registers);
        var payloads: preboot.Payloads = .{};
        try preboot.encode(&display.snapshot.?, display.original_boot.?.byte_length, &payloads);
        self.session = try transport.Session.init(try self.port.transportPort(), .{ .chip_id = self.display.?.chip.?.id }, self.epoch, &self.tx, &self.rx);
        try self.port.preloadInit(&self.session.?, &payloads.system, &payloads.registry);
        self.ctx.?.logInfo("NVIDIA gsp-start: preboot=system-info,registry rpc-sequence=0 queue-sequence=2 firmware-submitted=no");
        try self.beginFirmware(.frts, &inputs);
    }

    /// CE is required for shader uploads even when no display is requested.
    /// Keep its admission with GR instead of relying on native-output setup.
    pub fn requestGraphics(self: *Device) !void {
        if (self.self_address != @intFromPtr(self) or self.stopped or self.terminal_requested or
            self.native_graphics.self_address != 0) return error.State;
        if (self.running.native_copy.phase == .detached) try self.running.native_copy.request();
        try self.native_graphics.request();
    }

    fn now(self: *Device) !u64 {
        const value = self.clock_api orelse return error.Api;
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
        if (self.stopped or self.phase == .failed or self.terminal_retired) { _ = self.catalog.close(); return .stopped; }
        const progress = self.advance() catch |err| blk: {
            if (self.phase == .recovering) {
                self.recovery_failure = err;
                self.logFailure("teardown", err);
                self.beginReset() catch |reset_error| self.resetFailed(reset_error);
            } else if (self.phase == .resetting or self.phase == .retiring) {
                self.resetFailed(err);
            } else self.fail(err);
            break :blk true;
        };
        self.observeFlipStall(progress);
        self.native_output.statistics.publish(&self.native_output);
        return if (self.phase == .failed) .stopped else if (progress) .progress else .idle;
    }
    /// One retained-metadata report per unusually long Window use. This does
    /// not touch PCI/MMIO, change a deadline or manufacture a flip receipt.
    noinline fn observeFlipStall(self: *Device, progress: bool) void {
        if (self.phase != .ready or self.running.failure != null or self.native_output.phase != .active) return;
        const run = &self.running;
        const current = run.last_clock;
        for (&run.display_flips, &self.flip_watch, 0..) |*slot, *watch, index| {
            const work = if (slot.*) |*value| value else { watch.* = .{}; continue; };
            if (watch.epoch != run.epoch or watch.sequence != work.receipt.sequence)
                watch.* = .{ .epoch = run.epoch, .sequence = work.receipt.sequence, .first_seen_ns = current };
            if (watch.reported or current < watch.first_seen_ns) continue;
            const age = current - watch.first_seen_ns;
            if (age < std.time.ns_per_s and current < work.deadline) continue;
            watch.reported = true;
            const word: ?u32 = work.window.notifier.observedWord() catch null;
            @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                "NVIDIA flip-stall: epoch={d} head={d} window={d} sequence={d} age-ns={d} now={d} deadline={d} phase={s} point={d} notifier={?x} visible={} old-released={}",
                .{run.epoch,work.receipt.head,index,work.receipt.sequence,age,current,work.deadline,@tagName(work.window.phase),
                    if (work.window.ticket) |ticket| ticket.point else 0,word,work.receipt.begun_observed_ns != 0,work.receipt.previous_released_ns != 0});
            @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                "NVIDIA flip-stall-owner: progress={} polls={d} events={d} RM={s} sequence={} power={} display-channel={?} mode={} engine={} FIFO={?} context={?} VA={} native={?} buffer={?} output={} copy={} GR={} upload={} display={}",
                .{progress,run.snapshot.polls,run.snapshot.events,if (run.activeChannel()) |channel| @tagName(channel.phase) else "none",
                    run.sequence.self_address != 0,run.power_active,run.display_channel_active,run.mode_control_active,run.display_engine_active,
                    run.fifo_active,run.context_active,run.virtuals.active_range != null,run.native_active,run.buffer_active,run.outputs.active(),
                    run.copy_job != null,run.graphics_work != null,run.display_upload_job != null,run.display_work != null});
        }
    }
    fn advance(self: *Device) !bool {
        if (self.terminal_requested and self.phase == .ready) {
            if (try self.now() >= self.terminal_deadline) return error.ShutdownDeadline;
            const progress = try self.running.step() == .progress;
            _ = try self.running.shutdownGraph(self.terminal_deadline);
            const queues = try self.running.native_queues.step(&self.running, null);
            const virtuals = try self.running.virtual_provider.step(&self.running);
            return progress or queues or virtuals;
        }
        if (self.phase == .ready and self.display.?.firmware_restore_generation != 0 and !self.reset_to_console and self.gpu_reset.self_address == 0) {
            self.reset_to_console = true;
            self.fail(error.ConsoleRestore);
            return true;
        }
        if (self.phase == .retiring) return self.retireAfterReset();
        if (self.phase == .resetting) {
            if ((self.recovery_hooks != null or self.terminal_requested) and self.reset_display.generation == 0) {
                const current = self.clock_api.?.nowNs();
                if (current == std.math.maxInt(u64) or current < self.last_clock or current >= self.reset_retire_deadline) return error.Timeout;
                self.last_clock = current;
                const display = self.display.?.boot.display orelse return error.Api;
                if (!display.supportsReset()) return error.Api;
                if (self.terminal_console_requested or (!self.reset_to_console and self.display.?.boot.native_adopted)) {
                    // A failed common queue can already invalidate the active
                    // scanout before q0. Its lost generation is distinct from
                    // both our committed native image and the immutable hold.
                    var current_boot: a.GfxNativeBootInfo = .{};
                    self.reset_display_status = display.bootInfo(&current_boot);
                    if (self.reset_display_status == a.gfx_output_error_busy) return false;
                    const original = self.display.?.original_boot orelse return error.Binding;
                    if (self.reset_display_status != a.gfx_output_ok or current_boot.version != 1 or
                        current_boot.size < @sizeOf(a.GfxNativeBootInfo) or
                        current_boot.physical_address != original.physical_address or current_boot.byte_length != original.byte_length or
                        current_boot.width != original.width or current_boot.height != original.height or
                        current_boot.pitch != original.pitch or current_boot.format != original.format or current_boot.policy != original.policy)
                        return error.Handoff;
                    if (self.terminal_console_requested) {
                        if (current_boot.state != a.display_state_bootfb or current_boot.generation < self.reset_original_display or
                            current_boot.generation <= self.boot_console.callback_generation)
                            return error.Handoff;
                        self.reset_original_display = current_boot.generation;
                    } else if (current_boot.state == a.display_state_unavailable and current_boot.generation > self.reset_original_display)
                        self.reset_original_display = current_boot.generation;
                    // deviceReset still authenticates the exact R4D/backend
                    // owner. This observation neither adopts an image nor
                    // authorizes release or asserts physical quiescence.
                }
                var state: a.GfxNativeState = .{};
                const result = display.deviceReset(&self.reset_binding, self.reset_original_display, false, &state);
                self.reset_display_status = result;
                if (result == a.gfx_output_error_busy) return false;
                if (result != a.gfx_output_ok or !validResetState(state) or state.generation <= self.reset_original_display)
                    return error.Handoff;
                try self.display.?.boot.adoptReset(state);
                if (self.terminal_console_requested) self.display.?.boot.console_active = false;
                self.reset_display = state;
                return true;
            }
            if (self.gpu_reset.self_address == 0) {
                try self.gpu_reset.open(&self.reset_config, self.epoch, self.resetIo());
                return true;
            }
            if (self.gpu_reset.quiescence() != null or try self.gpu_reset.step()) {
                self.phase = if (self.recovery_hooks != null or self.terminal_requested) .retiring else .failed;
                if (self.recovery_hooks != null or self.terminal_requested)
                    self.reset_retire_deadline = try std.math.add(u64, self.clock_api.?.nowNs(), 30 * std.time.ns_per_s);
                @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                    "NVIDIA gpu-reset: FLR=complete epoch={d} DMA=stopped bus-master=off resources=held display=unrestored", .{self.epoch});
            }
            return true;
        }
        if (self.phase == .recovering) {
            if (!self.recovery_started) {
                if (try self.now() >= self.recovery_deadline) return error.IrqRetirement;
                if (!self.interrupts.close()) return true;
                try self.recovery.open(&self.port, self.reader.?, self.recovery_deadline);
                self.recovery_started = true;
                return true;
            }
            self.port.traceRecovery(.step, null);
            defer self.port.traceRecovery(.between_steps, null);
            const before = self.recovery.phase;
            const complete = try self.recovery.step();
            if (before == .sb and self.recovery.phase == .unload) if (self.recovery.sb_result.? == .rejected) {
                const rejected = self.recovery.sb_result.?.rejected;
                @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                    "NVIDIA teardown-fwsec: rejected={s} observed={d} raw={x}/{x}/{x} booter-unload=next resources=held",
                    .{ @errorName(rejected.reason), rejected.observation.observed,
                        rejected.observation.raw[0], rejected.observation.raw[1], rejected.observation.raw[2] });
            };
            if (complete) {
                try self.beginReset();
            }
            return true;
        }
        try self.checkLive(false);
        if (self.phase == .ready) {
            if (self.interrupts.failed()) return error.Interrupt;
            if (self.running.failure) |err| return err;
            // Record the rebuilt execution binding while it is live, even
            // when a native output is still waiting for its receiver. The
            // previous display receipt proves only the old stopped epoch.
            // A later prepare_reset consumes this same new binding.
            if (self.gpu_reset.resumed and !self.headless_resumed) {
                if (self.running.copy_backend) |backend| {
                    if (try self.now() >= self.deadline) return error.Deadline;
                    const display = self.display.?.boot.display orelse return error.Api;
                    var state: a.GfxNativeState = .{};
                    const result = display.resumeHeadless(&backend.binding, self.reset_display.generation, &state);
                    if (result == a.gfx_output_error_busy) return false;
                    if (result != a.gfx_output_ok or !validResetState(state) or state.generation != self.reset_display.generation)
                        return error.Handoff;
                    self.headless_resumed = true;
                    @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                        "NVIDIA gpu-reset: headless-resumed epoch={d} device-generation={d} display-generation={d} output=held old-quiescence=revoked",
                        .{self.epoch,backend.binding.device_generation,state.generation});
                    return true;
                }
            }
            if (self.running.post.snapshot()) |inventory| {
                if (self.interrupts.self_address == 0) {
                    if (try self.now() >= self.deadline) return error.Deadline;
                    if (!self.inLockdown() and self.running.sequence.self_address == 0) {
                        try self.interrupts.open(&self.ctx.?, &self.display.?.registers, &self.display.?.snapshot.?,
                            self.display.?.chip.?, inventory, self.irq_wake orelse return error.IrqWake, self.port.boot0);
                        self.running.rm_enabled = true;
                        self.running.power_enabled = true;
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
            const copy_progress = try self.running.native_copy.step(&self.running);
            const allocation_progress = try self.running.allocations.step(&self.running);
            const virtual_progress = try self.running.virtual_provider.step(&self.running);
            const graphics_progress = try self.native_graphics.step(&self.running,
                self.running.native_copy.phase == .ready or self.running.native_copy.phase == .detached);
            if (progress) self.running.native_queues.wake();
            const native_progress = try self.running.native_queues.step(&self.running, &self.native_graphics);
            const render_progress = try self.render_startup.step(&self.running,
                if (self.native_graphics.phase == .ready) self.native_graphics.channel else null,
                if (self.running.native_copy.phase == .ready) self.running.native_copy.channel else null);
            // GPU execution starts before the optional display consumer. Its
            // finite startup deadlines must not include receiver/FRL/DP waits,
            // nor may display startup expire while shader warmup borrows RM/CE.
            // Known GR/cache unavailability still permits the CE display path.
            const graphics_starting = switch (self.native_graphics.phase) {
                .detached, .ready, .unavailable, .closed => false,
                else => true,
            };
            const render_starting = self.native_graphics.phase == .ready and self.running.native_copy.phase == .ready and
                self.render_startup.phase != .ready and self.render_startup.phase != .unavailable;
            const output_progress = if (self.native_output.phase == .waiting and (graphics_starting or render_starting)) false
                else try self.native_output.step();
            if (self.native_output.phase == .active and self.interrupts.display.epoch == 0) {
                const root = (try self.running.displayEngineStatus(self.native_output.engine.?)).info orelse return error.State;
                const head = self.native_output.mode.?.head;
                if (head >= root.hardware.heads or head >= 8) return error.Binding;
                self.interrupts.enableDisplay(self.running.post.snapshot() orelse return error.State,
                    self.epoch, @as(u32, 1) << @as(u5, @intCast(head))) catch |err| {
                    if (err == error.Busy) return progress or copy_progress or output_progress or allocation_progress or virtual_progress or graphics_progress or native_progress or render_progress;
                    return err;
                };
                self.running.head_events = &self.interrupts.display;
                self.ctx.?.logInfo("NVIDIA head-events: source=display-stall-LAST_DATA clock=IRQ-observation sequence=observed-events");
                return true;
            }
            if (self.native_output.phase == .active and self.interrupts.display.enabled) {
                var mask = self.interrupts.display.head_mask;
                const root = (try self.running.displayEngineStatus(self.native_output.engine.?)).info orelse return error.State;
                for (&self.running.display_images) |*slot| if (slot.*) |image| {
                    if (image.head >= root.hardware.heads or image.head >= 8 or image.boot_mode == null) return error.Binding;
                    mask |= @as(u32, 1) << @intCast(image.head);
                };
                if (mask != self.interrupts.display.head_mask) {
                    self.interrupts.extendDisplay(self.running.post.snapshot() orelse return error.State, self.epoch, mask) catch |err| {
                        if (err == error.Busy) return progress or copy_progress or output_progress or allocation_progress or virtual_progress or graphics_progress or native_progress or render_progress;
                        return err;
                    };
                    return true;
                }
            }
            if (self.interrupts.display.enabled) for (&self.interrupts.display.heads, 0..) |*head, index| {
                const bit = @as(u32, 1) << @as(u5, @intCast(index));
                if (self.interrupts.display.head_mask & bit == 0 or self.heads_reported & bit != 0) continue;
                const sample = head.snapshot() orelse continue;
                if (sample.sequence == 0) continue;
                self.heads_reported |= bit;
                @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                    "NVIDIA head-events: head={d} epoch={d} sequence={d} observed-ns={d} frame-counter={d} scanline={d}",
                    .{index,self.epoch,sample.sequence,sample.observed_ns,sample.frame_counter,sample.scanline});
            };
            return progress or copy_progress or output_progress or allocation_progress or virtual_progress or graphics_progress or native_progress or render_progress;
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
            .os_error => {
                self.logFailure("firmware-event", error.FirmwareError);
                boot.reject(dispatch.ticket) catch {};
                return error.FirmwareError;
            },
            .nocat => |record| {
                // NVIDIA's original boot callback journals this notification;
                // it is not a fatality or quiescence declaration. Runtime's
                // fault owner uses the same rule. INIT_DONE remains required.
                @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                    "NVIDIA gsp-nocat: type={d} flags={x} bugcheck={x} subsystem={d} error={x} tdr={x} diagnostic-bytes={d}",
                    .{ record.record_type, record.flags, record.bugcheck, record.subsystem, record.error_code, record.tdr_reason, record.diagnostic.len });
                self.logBootData("nocat-source", record.source);
                self.logBootData("nocat-engine", record.engine);
                self.logBootData("nocat-diagnostic", record.diagnostic);
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
        if (self.boot_console.self_address != 0) self.boot_console.invalidate();
        if (self.failure == null) { self.failure = err; self.failed_phase = self.phase; }
        self.running.reportIrq(&self.interrupts); // Worker-side snapshot; no allocation or BO mutation in the IRQ.
        self.running.stop(err);
        self.native_output.quarantine(err);
        self.native_graphics.quarantine(if (self.ctx) |*ctx| ctx else null, err);
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
        self.native_output.quarantine(error.Stopped);
        self.native_graphics.quarantine(if (self.ctx) |*ctx| ctx else null, error.Stopped);
        if (!self.catalog.close()) return false;
        self.running.stop(error.Stopped);
        self.native_output.statistics.publish(&self.native_output);
        if (!self.interrupts.close()) return false;
        self.stopped = true;
        return true;
    }
    /// Called under the synchronous lifecycle owner after pacing has joined.
    /// Startup/fault paths retain their existing conservative teardown; an
    /// idle headless runtime drains its actual RM graph and unloading RPC.
    pub fn requestShutdown(self: *Device) !void {
        if (self.self_address != @intFromPtr(self) or self.stopped) return error.State;
        if (self.terminal_requested) {
            // Retry only acknowledged physical-stop cleanup. Never renew a
            // failed firmware/reset attempt or enable DMA during shutdown.
            if (!self.terminal_retired and self.phase == .failed and self.gpu_reset.quiescence() != null) {
                self.phase = if (self.reset_display.generation == 0) .resetting else .retiring;
                self.reset_retire_deadline = try std.math.add(u64, try self.now(), 30 * std.time.ns_per_s);
            }
            return;
        }
        if (!self.port.effects_possible and self.gpu_reset.quiescence() == null and !self.hasResumedResetEpoch()) return error.State;
        if (!(self.display.?.boot.display orelse return error.Api).supportsTerminalRelease()) return error.Api;
        self.terminal_deadline = try std.math.add(u64, try self.now(), 60 * std.time.ns_per_s);
        self.terminal_console_requested = self.phase == .ready and self.reset_to_console and
            self.native_output.phase == .console_active and self.native_output.console == &self.boot_console and
            self.display.?.boot.console_active and self.boot_console.phase == .ready and self.boot_console.confirmed and
            self.boot_console.valid(self.epoch) and self.hasResumedResetEpoch() and
            self.running.copy_backend == null and self.running.presentation == null;
        self.terminal_requested = true;
        if (!self.catalog.close()) return error.Retained;
        if (self.phase == .failed) {
            if (self.gpu_reset.quiescence() == null) {
                // Exhausted automatic recovery does not quiesce the rebuilt
                // epoch. Explicit shutdown still owns its separate one-shot
                // physical stop. Never retry an incomplete/failed old FLR or
                // mistake the resumed epoch's old receipt for current DMA rest.
                if (!self.hasResumedResetEpoch()) return error.Retained;
                try self.beginReset();
            } else {
                if (self.reset_display.generation == 0) self.resetBinding();
                self.phase = .resetting;
                self.reset_retire_deadline = try std.math.add(u64, try self.now(), 5 * std.time.ns_per_s);
            }
        } else if (self.phase == .ready and self.running.failure == null and
            (self.native_output.self_address == 0 or self.native_output.phase == .waiting or self.native_output.phase == .receiver_wait) and
            (self.native_graphics.phase == .ready or self.native_graphics.phase == .unavailable or self.native_graphics.phase == .detached) and
            (self.native_graphics.phase != .ready or self.render_startup.phase == .ready or self.render_startup.phase == .unavailable)) {
            self.running.beginShutdown() catch |err| { self.fail(err); };
        } else if (self.phase != .recovering and self.phase != .resetting and self.phase != .retiring) {
            self.fail(error.ShutdownStartup);
        }
        self.ctx.?.logInfo("NVIDIA shutdown: pacing=joined terminal=yes DMA=retained display=held");
    }
    pub fn finishTerminal(self: *Device) bool {
        if (!self.terminal_requested or !self.terminal_retired or self.gpu_reset.quiescence() == null or
            self.display.?.self_address != 0 or self.memory.?.self_address != 0 or self.port.self_address != 0 or
            (self.interrupts.self_address != 0 and !self.interrupts.closed) or self.irq_wake != null) return false;
        self.* = .{};
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
    fn hasResumedResetEpoch(self: *const Device) bool {
        return self.fault_reset_attempted and self.gpu_reset.self_address == @intFromPtr(&self.gpu_reset) and
            self.gpu_reset.phase == .complete and self.gpu_reset.failure == null and self.gpu_reset.triggered and
            self.gpu_reset.resumed and self.epoch > self.gpu_reset.epoch;
    }
    fn hasUnstartedRestartHandoff(self: *const Device) bool {
        // The old shared display/queue already retired. A new memory epoch
        // and DMA enable do not create a new shared queue or display binding.
        // Keep that exact logical handoff only if restart failed before any
        // firmware submission/runtime/output owner; it never proves DMA rest.
        const lease = self.memory orelse return false;
        return self.hasResumedResetEpoch() and self.phase == .failed and self.reset_retire_stage == .restart and
            !self.reset_to_console and !self.port.effects_possible and self.running.self_address == 0 and
            self.running.copy_backend == null and self.native_output.self_address == 0 and self.native_graphics.self_address == 0 and
            self.session == null and self.handoff == null and self.boot == null and self.sequence == null and
            lease.self_address == @intFromPtr(lease) and !lease.retained and lease.generation() == self.epoch and
            validResetState(self.reset_display);
    }
    fn beginReset(self: *Device) !void {
        if (!self.interrupts.close()) return error.IrqRetirement;
        try self.reader.?.setPolling(false);
        if (self.reset_config_failure) |err| return err;
        // One automatic fault recovery per Device. A later explicit system
        // shutdown independently needs physical stop of the rebuilt epoch.
        // Never reuse the old epoch's proof or retry a failed terminal FLR.
        const attempted = if (self.terminal_requested) &self.terminal_reset_attempted else &self.fault_reset_attempted;
        if (attempted.*) return error.ResetLimit;
        const retired_handoff = self.terminal_requested and self.hasUnstartedRestartHandoff();
        if (self.gpu_reset.self_address != 0) {
            if (!self.terminal_requested or !self.hasResumedResetEpoch())
                return error.ResetLimit;
            self.gpu_reset = .{};
        }
        attempted.* = true;
        self.phase = .resetting;
        if (!retired_handoff) self.reset_display = .{};
        self.reset_retire_stage = .runtime;
        self.reset_retire_deadline = try std.math.add(u64, self.clock_api.?.nowNs(), 5 * std.time.ns_per_s);
        self.reset_graphics_requested = self.native_graphics.self_address != 0 and !self.reset_to_console;
        self.reset_output_requested = self.native_output.self_address != 0 or self.reset_to_console;
        if (self.recovery_hooks == null and !self.terminal_requested) {
            try self.gpu_reset.open(&self.reset_config, self.epoch, self.resetIo());
        } else {
            if (!retired_handoff) self.resetBinding();
            self.reset_frame_count = self.native_output.frame_count;
            self.reset_output_route = self.native_output.recoveryRoute();
            self.reset_audio_location = self.native_output.audio.location;
            self.reset_audio_device = self.native_output.audio.device;
            self.reset_audio_attached = self.native_output.audio.catalog != null;
        }
        if (retired_handoff) self.ctx.?.logInfo("NVIDIA shutdown: restart=unsubmitted shared-handoff=already-retired current-epoch-FLR=required old-DMA-proof=revoked");
        @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
            "NVIDIA gpu-reset: attempt=1 purpose={s} scope=selected-NVIDIA-Fn0 epoch={d} original-phase={s} driver={s} firmware={s} resources=held display=held",
            .{if (self.terminal_requested) "terminal" else "fault",self.epoch,@tagName(self.failed_phase orelse .detached),@import("nvidia_identity").version,@import("firmware.zig").lock.rm_version});
    }
    fn resetBinding(self: *Device) void {
        self.reset_original_display = if (self.reset_to_console) self.display.?.firmware_restore_generation
            else if (self.display.?.boot.native_adopted) self.display.?.boot.native_generation else self.display_epoch;
        self.reset_binding = if (self.running.copy_backend) |backend| backend.binding
            else .{ .adapter_id = self.running.adapter_id, .milestone = a.gfx_queue_milestone_device_execution };
    }
    fn validResetState(value: a.GfxNativeState) bool {
        return value.version == 1 and value.size >= @sizeOf(a.GfxNativeState) and value.reserved0 == 0 and
            value.generation != 0 and value.state == a.display_state_recovering and value.outcome == a.gfx_output_outcome_lost and value.retained == 1;
    }
    fn retireAfterReset(self: *Device) !bool {
        const proof = self.gpu_reset.quiescence() orelse return error.Retained;
        const current = self.clock_api.?.nowNs();
        if (current == std.math.maxInt(u64) or current < self.last_clock or current >= self.reset_retire_deadline) return error.Timeout;
        self.last_clock = current;
        switch (self.reset_retire_stage) {
            .runtime => {
                if (!try self.running.closeAfterReset(proof)) return false;
                self.reset_retire_stage = .common;
            },
            .common => {
                const display = self.display.?.boot.display orelse return error.Api;
                var result: a.GfxNativeState = .{};
                const status = display.deviceReset(&self.reset_binding, self.reset_display.generation, true, &result);
                self.reset_display_status = status;
                if (status == a.gfx_output_error_busy) return false;
                if (status != a.gfx_output_ok or !validResetState(result) or result.generation != self.reset_display.generation) return error.Handoff;
                self.reset_retire_stage = .output;
            },
            .output => {
                if (!try self.native_output.closeAfterReset(proof)) return false;
                if (self.terminal_console_requested and !self.boot_console.closeAfterReset(proof)) return error.Retained;
                self.native_graphics = .{};
                self.render_startup = .{};
                self.reset_retire_stage = if (self.reset_to_console and !self.terminal_requested) .console_memory else .port;
            },
            .console_memory => {
                if (self.boot_console.self_address == 0) try self.boot_console.open(self.vram.?, proof, self.consoleIo());
                if (!try self.boot_console.stage(proof)) return false;
                @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                    "NVIDIA console-memory: stopped-epoch={d} original-pages={d} original-pixel-bytes={d} source=held-CPU-image readback=all-bytes mapping=held",
                    .{proof.epoch,self.vram.?.boot_mapping.?.page_count,self.boot_console.bytes});
                self.reset_retire_stage = .port;
            },
            .port => {
                if (!self.port.closeAfterReset(proof)) return false;
                self.reset_retire_stage = .reader;
            },
            .reader => {
                if (!self.reader.?.close()) return false;
                self.reset_retire_stage = .memory;
            },
            .memory => {
                if (!self.memory.?.releaseAfterReset(proof)) return false;
                self.reset_retire_stage = if (self.terminal_requested) .terminal else .restage;
            },
            .terminal => {
                self.terminal_retired = true;
                self.ctx.?.logInfo("NVIDIA shutdown: FLR=confirmed DMA=stopped runtime=retired boot-capture=held");
            },
            .restage => {
                if (self.terminal_requested) {
                    if (self.memory.?.self_address != 0 or self.port.self_address != 0) return error.Retained;
                    self.reset_retire_stage = .terminal;
                    return true;
                }
                const hooks = self.recovery_hooks orelse return error.Api;
                try hooks.restage(hooks.context, self);
                if (self.memory.?.generation() <= self.epoch or self.reader.?.generation() != self.memory.?.generation()) return error.Stale;
                try self.reader.?.setPolling(false);
                self.reset_retire_stage = .restart;
            },
            .restart => {
                if (self.terminal_requested) return error.Retained;
                // Never overwrite a failed metadata-source close. An exact
                // generic queue retirement may already have revoked it.
                if (!self.catalog.close()) return error.Retained;
                // Every old GPU/DMA borrower has consumed its proof. Revoke
                // that proof before the first potentially posted DMA enable.
                try self.gpu_reset.resumeDma();
                self.epoch = self.memory.?.generation();
                if (self.reset_to_console) try self.boot_console.activate(self.epoch);
                const journal = self.running.faults;
                const adapter = self.running.adapter_id;
                const discover_receivers = self.running.discover_receivers;
                const requested_limit = self.running.memory_admission.requested_limit_bytes;
                self.running = .{};
                self.running.adapter_id = adapter;
                self.running.discover_receivers = discover_receivers;
                self.running.memory_admission.requested_limit_bytes = requested_limit;
                self.running.faults = journal;
                // Keep the first failure and every diagnostic record, but
                // the retired generation's fatal delivery is now consumed.
                self.running.faults.pending = false;
                if (self.board) |*board| self.running.outputs.board = board;
                self.session = null; self.boot = null; self.sequence = null; self.handoff = null;
                self.frts_result = null; self.load_result = null; self.expected_firmware = null;
                self.recovery = .{}; self.recovery_started = false;
                self.interrupts = .{}; self.heads_reported = 0;
                self.deadline = try std.math.add(u64, current, 30 * std.time.ns_per_s);
                const inputs = try self.memory.?.inputs();
                const original = self.display.?.operation.?.options;
                try self.port.openShared(&self.ctx.?, &self.display.?.snapshot.?, original.boot0, original.boot1,
                    .{ .epoch = self.epoch, .deadline_ns = self.deadline, .resume_args = inputs.resume_args }, self.owner(), &self.display.?.registers);
                self.catalog = .{};
                try self.catalog.open(&self.ctx.?, adapter);
                if (self.reset_output_requested)
                    try self.native_output.requestAfterReset(&self.ctx.?, &self.running, self.display.?, self.reset_display.generation, self.reset_output_route)
                else try self.running.native_copy.request();
                if (self.reset_graphics_requested) try self.native_graphics.request();
                if (self.reset_to_console) {
                    self.running.native_copy.publish_backend = false;
                    self.running.boot_console_restore = &self.boot_console;
                    self.native_output.console = &self.boot_console;
                    self.display.?.firmware_recovery = .{ .context = self.self_address, .callback = consoleRestored };
                }
                self.native_output.frame_count = self.reset_frame_count;
                if (self.reset_audio_attached) self.native_output.audio = .{ .catalog = &self.catalog,
                    .location = self.reset_audio_location, .device = self.reset_audio_device };
                var payloads: preboot.Payloads = .{};
                try preboot.encode(&self.display.?.snapshot.?, self.display.?.original_boot.?.byte_length, &payloads);
                self.session = try transport.Session.init(try self.port.transportPort(), .{ .chip_id = self.display.?.chip.?.id }, self.epoch, &self.tx, &self.rx);
                try self.port.preloadInit(&self.session.?, &payloads.system, &payloads.registry);
                try self.reader.?.setPolling(true);
                try self.beginFirmware(.frts, &inputs);
                @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                    "NVIDIA gpu-reset: restart epoch={d} display-generation={d} boot-hold={d} renderer=software DMA=new-generation",
                    .{self.epoch,self.reset_display.generation,self.display_epoch});
            },
        }
        return true;
    }
    fn resetFailed(self: *Device, err: anyerror) void {
        // Retained owner metadata only. No fresh GPU or API query after a
        // failed reset; identify the exact bounded retirement stage.
        @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
            "NVIDIA reset-retirement: phase={s} stage={s} runtime={s} cursor={d} backend={} allocation={} provider={} display-status={d} catalog-status={d} result={s}",
            .{ @tagName(self.phase), @tagName(self.reset_retire_stage), @tagName(self.running.reset_stage),
                self.running.reset_cursor, self.running.copy_backend != null, self.running.allocations.pending != null,
                self.running.virtual_provider.handle.id, self.reset_display_status, self.catalog.last_status, @errorName(err) });
        if (self.boot_console.self_address != 0) self.boot_console.invalidate();
        self.recovery_failure = err;
        self.phase = .failed;
        self.logFailure("reset", err);
        self.ctx.?.logError("NVIDIA recovery: reset-limit=1 automatic-retry=stopped; next boot: select R4OS Software Graphics in Limine (r4os.graphics=software); SSH/serial remain independent");
    }
    fn consoleIo(self: *Device) console.Io {
        return .{ .context = self, .generation = resetGeneration, .now_ns = resetNow, .read32 = consoleRead, .write32 = consoleWrite };
    }
    fn consoleRead(raw: *anyopaque, address: u32) !u32 {
        const self = from(raw);
        const pramin = @import("pramin.zig");
        const bar1 = @import("bar1_reader.zig");
        if (self.self_address != @intFromPtr(self) or self.stopped or !self.reset_to_console or
            self.display.?.firmware_owner != self.self_address or address & 3 != 0 or
            (address != 0 and address != 4 and address != pramin.window_register and
                address != bar1.block_register and address != bar1.bind_register and
                !(address >= pramin.aperture and address < pramin.aperture + pramin.aperture_bytes))) return error.Register;
        const view = try self.display.?.register_access.view(address, 4);
        const pointer: *volatile u32 = @ptrFromInt(view.cpu_address);
        asm volatile ("mfence" ::: .{ .memory = true });
        const value = pointer.*;
        asm volatile ("mfence" ::: .{ .memory = true });
        return value;
    }
    fn consoleWrite(raw: *anyopaque, address: u32, value: u32) !void {
        const self = from(raw);
        const pramin = @import("pramin.zig");
        const block = @import("bar1_reader.zig").block_register;
        const stopped = self.phase == .retiring and self.reset_retire_stage == .console_memory and self.gpu_reset.quiescence() != null;
        const binding_console = self.phase == .ready and self.native_output.phase == .console_mapping and self.boot_console.phase == .bind;
        if ((!stopped and !binding_console and !(self.phase == .ready and self.native_output.phase == .console_mapping and address == pramin.window_register)) or
            (address != pramin.window_register and !(binding_console and address == block) and
                !(stopped and address >= pramin.aperture and address < pramin.aperture + pramin.aperture_bytes))) return error.Register;
        _ = try consoleRead(raw, address);
        const view = try self.display.?.register_access.view(address, 4);
        const pointer: *volatile u32 = @ptrFromInt(view.cpu_address);
        asm volatile ("mfence" ::: .{ .memory = true });
        pointer.* = value;
        asm volatile ("mfence" ::: .{ .memory = true });
    }
    fn consoleRestored(raw: u64, generation_value: u64, description: *const a.GfxNativeBootInfo) callconv(.c) i32 {
        const self: *Device = @ptrFromInt(raw);
        if (self.self_address != raw or self.stopped or self.phase != .ready or self.native_output.phase != .console_handoff or
            generation_value < self.reset_display.generation or description.state != a.display_state_recovering) return 0;
        self.native_output.validateConsoleCompletion() catch return 0;
        self.boot_console.callback_generation = generation_value;
        return @intFromBool(self.boot_console.authorize(generation_value, description));
    }
    fn resetIo(self: *Device) reset.Io {
        return .{ .context = self, .generation = resetGeneration, .now_ns = resetNow, .admit = admitReset,
            .pci_read = resetPciRead, .pci_write = resetPciWrite, .read32 = resetRead, .write32 = resetWrite };
    }
    fn resetGeneration(raw: *anyopaque) u64 {
        const self = from(raw);
        return if (self.self_address == @intFromPtr(self) and !self.stopped) self.epoch else 0;
    }
    fn resetNow(raw: *anyopaque) u64 {
        const self = from(raw);
        return if (self.clock_api) |clock| clock.nowNs() else std.math.maxInt(u64);
    }
    fn admitReset(raw: *anyopaque, epoch: u64) !void {
        const self = from(raw);
        const held = self.display orelse return error.Binding;
        if (self.self_address != @intFromPtr(self) or self.stopped or (self.phase != .resetting and self.phase != .retiring) or
            self.failure == null or self.epoch != epoch or held.self_address != @intFromPtr(held) or
            held.firmware_owner != self.self_address or held.borrower != @intFromPtr(self.vram.?) or
            held.boot.held_generation != self.display_epoch or !held.register_access.valid() or
            (self.interrupts.self_address != 0 and !self.interrupts.closed) or
            self.reader.?.enabled or self.reader.?.busy) return error.Binding;
    }
    fn resetPciRead(raw: *anyopaque, offset: u16) !u32 {
        const self = from(raw);
        if (self.self_address != @intFromPtr(self) or self.stopped or offset >= 4096 or offset & 3 != 0) return error.State;
        const pci = self.display.?.snapshot.?.pci;
        if (pci.bus_kind != 2 or pci.function != 0) return error.Unsupported;
        return self.ctx.?.api.pci_read_config32(pci.bus_kind, pci.bus, pci.device, pci.function, offset);
    }
    fn resetPciWrite(raw: *anyopaque, offset: u16, value: u32) !void {
        const self = from(raw);
        try admitReset(raw, self.epoch);
        if (offset != 4 and offset != reset.reg.device_control and offset != reset.reg.downstream and
            !(offset >= 0x10 and offset <= 0x24 and offset & 3 == 0)) return error.Register;
        const pci = self.display.?.snapshot.?.pci;
        if (self.ctx.?.api.pci_write_config32(pci.bus_kind, pci.bus, pci.device, pci.function, offset, value) != 0)
            return error.Configuration;
    }
    fn resetRead(raw: *anyopaque, address: u32) !u32 {
        const self = from(raw);
        try admitReset(raw, self.epoch);
        if (address != 0 and address != 4 and address != core.reg.cpuctl and
            address != reset.reg.gfw_permission and address != reset.reg.gfw_progress) return error.Register;
        const view = try self.display.?.register_access.view(address, 4);
        const pointer: *volatile u32 = @ptrFromInt(view.cpu_address);
        asm volatile ("mfence" ::: .{ .memory = true });
        const value = pointer.*;
        asm volatile ("mfence" ::: .{ .memory = true });
        return value;
    }
    fn resetWrite(raw: *anyopaque, address: u32, value: u32) !void {
        const self = from(raw);
        try admitReset(raw, self.epoch);
        if (address < reset.reg.config_base or address >= reset.reg.config_base + 4096 or
            !reset.layout.contains(&reset.layout.writable, @intCast(address - reset.reg.config_base)) or
            address == reset.reg.config_base + 4) return error.Register;
        const view = try self.display.?.register_access.view(address, 4);
        const pointer: *volatile u32 = @ptrFromInt(view.cpu_address);
        asm volatile ("mfence" ::: .{ .memory = true });
        pointer.* = value;
        asm volatile ("mfence" ::: .{ .memory = true });
        if (try resetPciRead(raw, 0) != self.reset_config.identity_word) return error.IdentityChanged;
    }
    fn checkLive(self: *Device, recovering: bool) !void {
        return self.validateLive(recovering) catch |err| {
            if (self.first_live_failure == null) {
                self.first_live_failure = err;
                self.live_failure_epoch = self.epoch;
                // Capture the cause before quarantine invalidates the run.
                // These are held CPU metadata only, no query/MMIO/RPC/retry.
                self.live_detail.check = self.live_check;
                if (self.memory) |backing| {
                    self.live_detail.memory_valid = backing.ownershipValid();
                    self.live_detail.memory_failed = backing.failed;
                    self.live_detail.recovery_owner = backing.recovery_owner;
                    self.live_detail.queue_epoch = backing.queue.epoch;
                    self.live_detail.queue_failed = backing.queue.failed;
                    self.live_detail.queue_status = backing.queue.last_status;
                    self.live_detail.log_status = backing.last_log_status;
                }
                if (self.reader) |reader| self.live_detail.reader_error = reader.last_error;
                if (self.vram) |reservation| {
                    if (reservation.binding(.frts)) |_| {} else |cause| {
                        self.live_detail.frts_error = cause;
                    }
                }
            }
            return err;
        };
    }
    fn validateLive(self: *Device, recovering: bool) !void {
        self.live_check = .state;
        if (self.self_address == 0 or self.self_address != @intFromPtr(self) or self.stopped) return error.State;
        self.live_check = .binding;
        const display = self.display orelse return error.Binding;
        const backing = self.memory orelse return error.Binding;
        const reservation = self.vram orelse return error.Binding;
        if (display.self_address != @intFromPtr(display) or !display.ready or display.context == null or
            display.context.?.api != self.ctx.?.api or display.boot.held_generation != self.display_epoch or
            display.borrower != @intFromPtr(reservation) or !display.register_access.valid() or
            (display.firmware_owner != 0 and display.firmware_owner != self.self_address)) return error.Binding;
        self.live_check = .inputs;
        const inputs = if (recovering)
            (if (backing.recovery_owner == 0) try backing.retainedInputs() else try backing.recoveryInputs(backing.recovery_owner))
            else try backing.inputs();
        self.live_check = .frts;
        if (backing.queue.epoch != self.epoch or inputs.frts == null or !reservation.validates(inputs.frts.?)) return error.Stale;
        self.live_check = .display;
        const original = display.original_boot orelse return error.Binding;
        var current: a.GfxNativeBootInfo = .{};
        const status = display.boot.display.?.bootInfo(&current);
        if (status != a.gfx_output_ok or
            !((current.state == a.display_state_preparing and current.generation == original.generation) or
                (self.reset_display.generation != 0 and current.generation == self.reset_display.generation and
                    (current.state == a.display_state_recovering or current.state == a.display_state_preparing)) or
                self.native_output.ownsNative(current) or self.native_output.ownsPreparing(current) or self.native_output.ownsConsole(current)) or
            current.physical_address != original.physical_address or
            current.byte_length != original.byte_length or current.width != original.width or
            current.height != original.height or current.pitch != original.pitch or current.format != original.format) {
            if (self.failed_boot_info_status == std.math.minInt(i32)) {
                self.failed_boot_info_status = status;
                self.failed_boot_info = current;
            }
            return error.Display;
        }
    }
    fn owner(self: *Device) native.Owner {
        return .{ .context = self, .generation = generation, .admit = admit, .access = access,
            .retain = retain, .quiesced = quiesced, .log_polling = polling,
            .admit_firmware = admitFirmware, .admit_cold = admitCold, .queue_memory = self.memory,
            .admit_runtime = admitRuntime, .admit_command = admitCommand, .admit_copy = admitCopy, .admit_graphics = admitGraphics, .admit_batch = admitBatch,
            .admit_unload = admitUnload, .admit_host_mmu = admitHostMmu,
            .admit_display_retirement = admitDisplayRetirement,
            .admit_display_push = admitDisplayPush,
            .wake_work = wakeWork,
            .recovery = .{ .generation = recoveryGeneration, .admit = admitRecovery, .access = recoveryAccess } };
    }
    fn generation(raw: *anyopaque) u64 {
        const self = from(raw);
        self.checkLive(false) catch return 0;
        return self.epoch;
    }
    fn wakeWork(raw: *anyopaque) void {
        const self = from(raw);
        if (self.irq_wake) |wake| _ = wake.signal(wake.context);
    }
    fn retain(raw: *anyopaque) !void {
        const self = from(raw);
        try self.checkLive(false);
        try self.display.?.retainForFirmware(self.self_address, self.display_epoch);
    }
    fn quiesced(raw: *anyopaque) bool {
        const self = from(raw);
        // This predicate admits old transport/MMIO cleanup only. The boot
        // display owner separately requires its own scanout/mapping proof.
        if (self.gpu_reset.quiescence() != null) return true;
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
        if (self.running.unload.self_address != 0) {
            if (!self.running.graph_closing or self.running.graph == null or self.running.graph.?.state != .finished or
                channel != &self.running.channel.? or !self.running.unload.matches(channel, deadline)) return error.Binding;
        } else if (self.running.power_active) {
            const performance_owner = if (self.running.power_owner) |*value| value else return error.Binding;
            const graph = if (self.running.graph) |*value| value else return error.Binding;
            const internal = self.running.static_info orelse return error.Binding;
            if (graph.state != .loaned or performance_owner.binding.epoch != self.epoch or
                performance_owner.binding.client != graph.base.plan.handles.client or performance_owner.binding.subdevice != graph.base.plan.handles.subdevice or
                performance_owner.shared_binding.client != internal.client or performance_owner.shared_binding.subdevice != internal.subdevice or
                !performance_owner.matches(channel, deadline)) return error.Binding;
        } else if (self.running.mode_control_active) {
            const mode = if (self.running.mode_control_owner) |*value| value else return error.Binding;
            const root = if (self.running.mode_control_root) |value| value else return error.Binding;
            const engine = if (self.running.display_engine_owner) |*value| value else return error.Binding;
            self.running.validateModeTopology(root, mode.mode, &mode.topology) catch return error.Binding;
            if (root.epoch != self.epoch or root.root != engine.binding.root or engine.info() == null or
                !mode.matches(channel, deadline)) return error.Binding;
        } else if (self.running.display_channel_active) |index| {
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
            const allocation = self.running.native_buffers.items()[index].owner orelse return error.Binding;
            if (!allocation.matches(channel, deadline)) return error.Binding;
        } else if (self.running.buffer_active) |index| {
            const mapping = self.running.buffers.items()[index].owner orelse return error.Binding;
            if (!mapping.matches(channel, deadline)) return error.Binding;
        } else if (self.running.virtuals.active()) |mapping| {
            if (!mapping.matches(channel, deadline)) return error.Binding;
        } else if (self.running.outputs.active()) {
            if (!self.running.outputs.matches(channel, deadline)) return error.Binding;
        } else if (self.running.sor_work) |*work| {
            if (channel != &self.running.channel.? or !work.matches(channel, deadline)) return error.Binding;
            self.running.validateSorAssignment() catch return error.Binding;
        } else if (self.running.display_work != null and self.running.monitor_work == null) {
            const work = &self.running.display_work.?;
            if (work.refresh) |*refresh| {
                if (channel != &self.running.channel.? or work.deadline != deadline or !refresh.control.matches(channel, deadline)) return error.Binding;
                self.running.validateAdaptiveRefresh() catch return error.Binding;
                if (!self.running.adaptiveReceiverCurrent()) return error.Binding;
            } else {
                const link = work.linkControl() orelse return error.Binding;
                if (channel != &self.running.channel.? or work.deadline != deadline or !link.matches(channel, deadline)) return error.Binding;
                self.running.validateDisplayLink() catch return error.Binding;
            }
        } else if (self.running.audio_work) |*work| {
            if (channel != &self.running.channel.? or !work.matches(channel, deadline)) return error.Binding;
            self.running.validateDisplayAudio() catch return error.Binding;
        } else if (self.running.monitor_work) |*work| {
            if (channel != &self.running.channel.? or !work.matches(channel, deadline)) return error.Binding;
            self.running.validateMonitorPower() catch return error.Binding;
        } else if (self.running.graph) |*graph| {
            if (!graph.matches(channel, deadline)) return error.Binding;
        } else if (self.running.static_info == null) {
            if (channel.function != @import("gsp_static.zig").function or
                channel.request.ptr != self.running.static_request[0..].ptr or channel.request.len != self.running.static_request.len) return error.Binding;
        } else if (!self.running.post.matches(channel, deadline)) return error.Binding;
    }
    fn admitUnload(raw: *anyopaque, port: *const native.Port, unload: *const @import("gsp_unload.zig").Owner, deadline: u64) !void {
        const self = from(raw);
        try self.checkLive(false);
        const run = &self.running;
        if (self.phase != .ready or port != &self.port or port.phase != .runtime or self.session == null or self.inLockdown() or
            run.self_address != @intFromPtr(run) or run.failure != null or run.sequence.self_address != 0 or
            !run.graph_closing or run.graph == null or run.graph.?.state != .finished or unload != &run.unload or
            run.activeChannel() != &run.channel.? or port.runtime_session != &self.session.? or
            !unload.waitingForSuspend(&run.channel.?, deadline)) return error.Binding;
    }
    fn admitHostMmu(raw: *anyopaque, port: *const native.Port, vm: *@import("gsp_host_vm.zig").Owner, deadline: u64) !void {
        const self = from(raw);
        try self.checkLive(false);
        const run = &self.running;
        if (self.phase != .ready or port != &self.port or port.phase != .runtime or self.session == null or self.inLockdown() or
            run.self_address != @intFromPtr(run) or run.failure != null or run.sequence.self_address != 0 or run.graph == null or
            run.graph.?.address_space == null or vm != &run.graph.?.address_space.?.host_vm or vm.epoch != run.epoch or
            port.runtime_session != &self.session.? or self.session.?.pending != null) return error.Binding;
        const channel = run.activeChannel() orelse return error.State;
        if (channel.session != &self.session.? or channel.phase != .idle or channel.pending != null or
            channel.request.len != 0) return error.Binding;
        if (channel.deadline) |limit| if (limit != deadline) return error.Binding;
        const operation = try vm.invalidation();
        if (operation.deadline != deadline or operation.root_dma != try vm.rootAddress()) return error.Binding;
        try channel.guard(deadline);
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
    fn admitGraphics(raw: *anyopaque, port: *const native.Port, fifo: *@import("gsp_fifo.zig").Owner, ticket: @import("gsp_push_ring.zig").Ticket, deadline: u64) !void {
        const self = from(raw);
        try self.checkLive(false);
        const run = &self.running;
        if (self.phase != .ready or port != &self.port or port.phase != .runtime or self.session == null or self.inLockdown() or
            run.self_address != @intFromPtr(run) or run.failure != null or run.sequence.self_address != 0 or run.graph_closing or run.power_active or
            run.fifo_active != null or run.context_active != null or run.virtuals.active_range != null or run.native_active != null or run.buffer_active != null or
            run.outputs.active() or run.display_engine_active or run.display_channel_active != null or run.mode_control_active or
            run.batch_work != null or run.copy_job != null or run.display_upload_job != null or run.initial_image != null or run.cursor_upload != null or
            run.display_work != null or run.audio_work != null or run.graphics_upload != null) return error.State;
        const work = if (run.graphics_work) |*value| value else return error.Binding;
        try run.validateGraphicsWork();
        if (work.submitted or work.receipt != null or work.ticket == null or !std.meta.eql(work.ticket.?, ticket) or
            work.deadline != deadline or !fifo.matchesGraphics(ticket, work.command)) return error.Binding;
        const handle = work.channel_handle;
        if (handle.epoch != self.epoch or handle.slot >= run.fifos.len or run.fifos[handle.slot].owner != fifo or
            run.fifos[handle.slot].serial != handle.serial or ticket.epoch != self.epoch) return error.Binding;
        const rpc = run.activeChannel() orelse return error.State;
        if (rpc.session != &self.session.? or port.runtime_session != rpc.session or rpc.session.pending != null or
            rpc.phase != .idle or rpc.pending != null or rpc.in_lockdown) return error.Binding;
        if (work.queued) try rpc.guardUnsubmitted(deadline) else try rpc.guard(deadline);
    }
    fn admitBatch(raw: *anyopaque, port: *const native.Port, fifo: *@import("gsp_fifo.zig").Owner, ticket: @import("gsp_push_ring.zig").Ticket, deadline: u64) !void {
        const self = from(raw);
        try self.checkLive(false);
        const run = &self.running;
        if (self.phase != .ready or port != &self.port or port.phase != .runtime or self.session == null or self.inLockdown() or
            run.self_address != @intFromPtr(run) or run.failure != null or run.sequence.self_address != 0 or run.graph_closing or run.power_active or
            run.fifo_active != null or run.context_active != null or run.virtuals.active_range != null or run.native_active != null or run.buffer_active != null or
            run.outputs.active() or run.display_engine_active or run.display_channel_active != null or run.mode_control_active or
            run.copy_job != null or run.queued_render != null or run.display_upload_job != null or run.initial_image != null or run.cursor_upload != null or
            run.display_work != null or run.audio_work != null or run.monitor_work != null or run.sor_work != null or
            run.graphics_work != null or run.graphics_upload != null) return error.State;
        const work = if (run.batch_work) |*value| value else return error.Binding;
        try run.validatePushBatch();
        if (work.submitted or work.receipt != null or work.ticket == null or !std.meta.eql(work.ticket.?, ticket) or
            work.deadline != deadline or !fifo.matchesBatch(ticket, try work.resources.commands())) return error.Binding;
        const handle = work.channel_handle;
        if (handle.epoch != self.epoch or handle.slot >= run.fifos.len or run.fifos[handle.slot].owner != fifo or
            run.fifos[handle.slot].serial != handle.serial or ticket.epoch != self.epoch) return error.Binding;
        const rpc = run.activeChannel() orelse return error.State;
        if (rpc.session != &self.session.? or port.runtime_session != rpc.session or rpc.session.pending != null or
            rpc.phase != .idle or rpc.pending != null or rpc.in_lockdown) return error.Binding;
        try rpc.guard(deadline);
    }
    fn admitCopy(raw: *anyopaque, port: *const native.Port, fifo: *@import("gsp_fifo.zig").Owner, ticket: @import("gsp_push_ring.zig").Ticket, deadline: u64) !void {
        const self = from(raw);
        try self.checkLive(false);
        if (self.phase != .ready or port != &self.port or port.phase != .runtime or self.session == null or self.inLockdown() or
            self.running.self_address != @intFromPtr(&self.running) or self.running.failure != null or self.running.sequence.self_address != 0 or
            self.running.fifo_active != null or self.running.context_active != null or self.running.virtuals.active_range != null or self.running.native_active != null or self.running.buffer_active != null or
            self.running.batch_work != null or self.running.outputs.active() or self.running.graph_closing or self.running.power_active or self.running.display_engine_active or self.running.display_channel_active != null or self.running.display_work != null or self.running.mode_control_active or self.running.graphics_work != null) return error.State;
        self.running.validateCopyOverlap() catch return error.Binding;
        const channel_handle = if (self.running.native_copy.probe.busy()) blk: {
            const run = &self.running;
            const work = &run.native_copy.probe;
            const graph = if (run.graph) |*value| value else return error.Binding;
            const staging = if (graph.control_buffer) |*value| value else return error.Binding;
            if (run.native_copy.phase != .probe_wait or run.copy_backend != null or run.copy_job != null or
                run.graphics_upload != null or run.display_upload_job != null or run.cursor_upload != null or run.initial_image != null or
                work.source != staging or !std.meta.eql(work.channel, run.native_copy.channel.?) or
                !work.matches(ticket, deadline) or fifo.config.context.vaspace != staging.binding.space.handle or
                !fifo.ring.matchesTransfer(ticket, fifo.config.object_class, work.transfer() catch return error.Binding)) return error.Binding;
            break :blk work.channel;
        } else if (self.running.graphics_upload) |*work| blk: {
            const run = &self.running;
            const graph = if (run.graph) |*value| value else return error.Binding;
            const staging = if (graph.control_buffer) |*value| value else return error.Binding;
            if (run.copy_job != null or run.display_upload_job != null or run.cursor_upload != null or run.initial_image != null or
                work.operation.cache_owner != &run.graphics_cache or work.operation.source != staging or
                !work.operation.matches(ticket,deadline) or fifo.config.context.vaspace != staging.binding.space.handle or
                !fifo.ring.matchesTransfer(ticket,fifo.config.object_class,work.operation.transfer() catch return error.Binding)) return error.Binding;
            break :blk work.channel;
        } else if (self.running.cursor_upload) |*work| blk: {
            if (self.native_output.phase != .active or !self.native_output.callback_confirmed or self.native_output.mode == null or
                self.running.cursor_storage == null or self.native_output.mode.?.head != self.running.cursor_storage.?.head) return error.Binding;
            try self.running.validateCursorUpload();
            const staging = work.operation.source.?;
            if (!work.operation.matches(ticket, deadline) or fifo.config.context.vaspace != staging.binding.space.handle or
                !fifo.ring.matchesTransfer(ticket, fifo.config.object_class, work.operation.transfer() catch return error.Binding)) return error.Binding;
            break :blk work.channel;
        } else if (self.running.display_upload_job) |*work| blk: {
            const resources = self.running.display_resources_slot.owner orelse return error.Binding;
            const root = if (self.running.display_engine_owner) |*value| value else return error.Binding;
            const graph = if (self.running.graph) |*value| value else return error.Binding;
            const staging = if (graph.control_buffer) |*value| value else return error.Binding;
            if (self.running.copy_job != null or self.running.initial_image != null or root.info() == null or !root.instance_bound or
                !resources.valid() or !std.meta.eql(resources.binding.?, root.binding) or resources.instance != &root.instance_storage or
                work.operation.source != staging or !work.operation.matches(ticket, deadline) or fifo.config.context.vaspace != staging.binding.space.handle) return error.Binding;
            if (!fifo.ring.matchesTransfer(ticket, fifo.config.object_class, work.operation.transfer() catch return error.Binding)) return error.Binding;
            if (work.operation.purpose == .identity_lut) {
                try self.running.validateIdentityLutUpload();
                if (self.native_output.phase != .identity_wait or self.native_output.running != &self.running or
                    self.native_output.mode == null or !self.native_output.mode.?.native_lut or
                    self.native_output.engine == null or self.native_output.engine.?.root != root.binding.root or
                    resources.identity_lut.?.control.head != self.native_output.mode.?.head or
                    resources.identity_lut.?.control.window != self.native_output.mode.?.window) return error.Binding;
            } else {
                if (work.operation.table != &resources.table or work.operation.target != &root.instance_storage) return error.Binding;
                try self.running.validateDisplayTableUpdate();
            }
            break :blk work.channel_handle;
        } else if (self.running.direct_work != null and self.running.direct_work.?.phase == .restore) blk: {
            const work = &self.running.direct_work.?;
            if (work.submitted or work.ticket == null or !std.meta.eql(work.ticket.?, ticket) or work.deadline != deadline) return error.Binding;
            const transfer = self.running.directRestoreTransfer() catch return error.Binding;
            if (!fifo.ring.matchesTransfer(ticket, fifo.config.object_class, transfer)) return error.Binding;
            break :blk work.channel;
        } else if (self.running.initial_image) |*work| blk: {
            const entry = work.presentation;
            if (self.running.copy_job != null or !work.operation.matches(ticket, deadline)) return error.Binding;
            const transfer = self.running.initialImageTransfer() catch return error.Binding;
            if (!fifo.ring.matchesTransfer(ticket, fifo.config.object_class, transfer)) return error.Binding;
            break :blk entry.channel_handle;
        } else blk: {
            const work = if (self.running.copy_job) |value| value else return error.Binding;
            if (work.submitted or work.ticket == null or !std.meta.eql(work.ticket.?, ticket) or !std.meta.eql(work.job, work.job_stamp) or
                work.deadline != deadline) return error.Binding;
            if (work.target_presentation != null) {
                // Native image jobs retain their source through the common
                // queue. Only the CPU-shadow path owns an Initial read lease.
                if (work.job.operation == r4os.abi.gfx_queue_operation_present) {
                    if (work.render_read.self_address != 0) return error.Binding;
                } else if (!work.render_read.matches(ticket, deadline)) return error.Binding;
            }
            const transfer = self.running.copyTransfer() catch return error.Binding;
            const part = @import("gsp_copy_wire.zig").slice(transfer, work.copied, self.running.work_schedule.copy_limit) catch return error.Binding;
            if (!std.meta.eql(work.transfer, transfer) or work.slice_end != part.next or
                !fifo.ring.matchesTransfer(ticket, fifo.config.object_class, part.transfer)) return error.Binding;
            break :blk work.channel_handle;
        };
        if (channel_handle.epoch != self.epoch or channel_handle.slot >= self.running.fifos.len) return error.Binding;
        const slot = &self.running.fifos[channel_handle.slot];
        if (slot.owner != fifo or slot.serial != channel_handle.serial or !fifo.matchesCopy(ticket)) return error.Binding;
        const rpc = self.running.activeChannel() orelse return error.State;
        if (rpc.session != &self.session.? or port.runtime_session != rpc.session or rpc.session.pending != null or
            rpc.phase != .idle or rpc.pending != null or rpc.in_lockdown or ticket.epoch != self.epoch) return error.Binding;
        const public_upload = if (self.running.graphics_upload) |work| work.queued else false;
        if (public_upload) try rpc.guardUnsubmitted(deadline) else try rpc.guard(deadline);
    }
    fn admitCursorPoint(self: *Device, port: *const native.Port, channel: *@import("gsp_display_channel.zig").Owner, deadline: u64, access_kind: native.DisplayAccess) !void {
        if (self.phase != .ready or port != &self.port or port.phase != .runtime or self.session == null or self.inLockdown() or
            self.running.self_address != @intFromPtr(&self.running) or self.running.failure != null or self.native_output.phase != .active or
            self.native_output.mode == null or self.native_output.modes.job != null or !self.native_output.callback_confirmed) return error.State;
        const mode = self.native_output.mode.?;
        if (mode.window >= self.running.display_images.len) return error.Binding;
        const root = if (self.running.display_engine_owner) |*value| value else return error.Binding;
        const info = root.info() orelse return error.Binding;
        if (!info.cursor or !info.instance_bound or channel.parent != root or channel.config.index != mode.head or mode.head >= info.hardware.heads or
            channel.config.root.epoch != self.epoch or channel.exchange.session != &self.session.? or port.runtime_session != &self.session.? or
            self.session.?.pending != null) return error.Binding;
        try self.running.validateCursorPoint(channel, deadline);
        const active = self.running.display_images[mode.window] orelse return error.Binding;
        if (active.head != mode.head or (access_kind == .publish and channel.point.pending.?.submitted_ns == 0)) return error.Binding;
    }
    fn admitDisplayPush(raw: *anyopaque, port: *const native.Port, channel: *@import("gsp_display_channel.zig").Owner, deadline: u64, access_kind: native.DisplayAccess) !void {
        const self = from(raw);
        try self.checkLive(false);
        if (channel.config.kind == .cursor) return self.admitCursorPoint(port, channel, deadline, access_kind);
        if (self.phase != .ready or port != &self.port or port.phase != .runtime or self.session == null or self.inLockdown() or
            self.running.self_address != @intFromPtr(&self.running) or self.running.failure != null or self.running.sequence.self_address != 0 or
            self.running.fifo_active != null or self.running.context_active != null or self.running.virtuals.active_range != null or self.running.native_active != null or self.running.buffer_active != null or
            self.running.outputs.active() or self.running.graph_closing or self.running.display_engine_active or self.running.display_channel_active != null or self.running.mode_control_active or
            self.running.copy_job != null or self.running.display_upload_job != null or self.running.cursor_upload != null or self.running.initial_image != null) return error.State;
        if (channel.config.kind == .window and self.running.displayFlip(channel.config.index) != null)
            return self.admitFlipPush(port, channel, deadline, access_kind);
        const work = if (self.running.display_work) |*value| value else return error.Binding;
        const resources = self.running.display_resources_slot.owner orelse return error.Binding;
        const root = if (self.running.display_engine_owner) |*value| value else return error.Binding;
        const root_info = root.info() orelse return error.Binding;
        if (!resources.valid()) return error.Binding;
        if (!work.core.config.with_core or (if (work.window) |value| !value.config.with_core else false) or
            (if (work.position) |value| !value.config.with_core else false)) return error.Binding;
        if (work.core.handle.slot != 0 or work.deadline != deadline) return error.Binding;
        if (work.refresh) |*refresh| {
            if (channel.config.kind != .core or refresh.control.phase != .core) return error.Binding;
            self.running.validateAdaptiveRefresh() catch return error.Binding;
            if (access_kind == .publish and !self.running.adaptiveReceiverCurrent()) return error.Binding;
        } else if (work.core.config.refresh_control != null or self.running.anyAdaptiveRefresh()) return error.Binding;
        if (work.cursor) |cursor| {
            if (self.native_output.phase != .active or !self.native_output.callback_confirmed or self.native_output.mode == null or
                self.native_output.mode.?.head != cursor.control.head) return error.Binding;
            self.running.validateCursorCommit() catch return error.Binding;
        } else if (work.core.config.cursor_image != null) return error.Binding;
        const position_part: ?*runtime.PositionSubmission = if (channel.config.kind == .immediate)
            if (work.position) |*value| value else return error.Binding else null;
        const ownership_pending = if (work.ownership) |*value| value.phase != .complete else false;
        if (ownership_pending and channel.config.kind != .core) return error.Binding;
        const part: ?*runtime.DisplaySubmission = if (position_part != null) null else
            if (channel.config.kind == .core) (if (ownership_pending) &work.ownership.? else &work.core)
            else if (work.window) |*value| value else return error.Binding;
        const handle = if (position_part) |value| value.handle else part.?.handle;
        const config = if (position_part) |value| &value.config else &part.?.config;
        const phase = if (position_part) |value| value.phase else part.?.phase;
        const ticket = if (position_part) |value| value.ticket else part.?.ticket;
        const slot = handle.slot;
        if (handle.epoch != self.epoch or slot >= self.running.display_channels.len or self.running.display_channels[slot] == null or
            &self.running.display_channels[slot].? != channel or channel.config.handle != handle.handle or channel.config.kind != config.kind or
            channel.parent != root or channel.info() == null or !channel.ring.valid() or resources.instance != &root.instance_storage or
            !std.meta.eql(resources.binding.?, root.binding) or config.windows != root_info.hardware.windows or
            config.initialize == channel.ring.initialized) return error.Binding;
        if (part) |value| if (resources.publishedNotifier(slot) != value.notifier or config.notifier != value.notifier.handle) return error.Binding;
        if (work.boot_mode) |plan| {
            const lut = if (plan.native_lut) resources.identityLutControls(plan.head, plan.window) orelse return error.Binding else null;
            if (!std.meta.eql(work.core.config.identity_lut, lut) or
                (if (work.window) |value| !std.meta.eql(value.config.identity_lut, lut) else lut != null) or
                (if (work.ownership) |value| !std.meta.eql(value.config.identity_lut, lut) else false)) return error.Binding;
        } else {
            if (work.core.config.identity_lut != null) return error.Binding;
            if (work.window) |value| if (value.config.identity_lut) |lut| {
                const route = value.config.route orelse return error.Binding;
                if (!std.meta.eql(resources.identityLutControls(route.head, route.window), @as(?@import("gsp_display_identity_lut.zig").Controls, lut))) return error.Binding;
            };
        }
        const mst_repair = if (work.link_restore) |*restore| restore.control.mst_rebuild != null else false;
        var null_detach_read = false;
        if (ownership_pending) {
            const ownership = &work.ownership.?;
            const window_part = if (work.window) |*value| value else return error.Binding;
            const route = work.core.config.route orelse return error.Binding;
            const expected: runtime.display_channel.push.commands.Config = .{ .notifier = work.core.notifier.handle,
                .windows = root_info.hardware.windows, .initialize = !channel.ring.initialized, .route = route,
                .ownership_only = true, .preserve_windows = self.running.displayPeerWindows(route.window) catch return error.Binding,
                .signal = work.core.config.signal, .cursor_usage = work.core.config.cursor_usage,
                .identity_lut = work.core.config.identity_lut,
                .mst_sor_control = work.core.config.mst_sor_control, .clear_dsc = work.core.config.clear_dsc };
            if (work.detach != null or work.refresh != null or work.cursor != null or work.link_restore != null or work.link_stop != null or
                work.core.phase != .prepare or work.core.ticket != null or window_part.phase != .prepare or window_part.ticket != null or
                (if (work.position) |value| value.phase != .prepare or value.ticket != null else false) or
                route.window >= 8 or route.head >= root_info.hardware.heads or window_part.handle.slot != 1 + route.window or
                ownership.handle.epoch != work.core.handle.epoch or ownership.handle.handle != work.core.handle.handle or
                ownership.notifier != work.core.notifier or !std.meta.eql(config.*, expected) or
                !std.meta.eql(window_part.config.route, work.core.config.route) or self.running.display_images[route.window] != null)
                return error.Binding;
            if (work.boot_mode) |plan| {
                const link = if (work.link) |*value| value else return error.Binding;
                if (work.wake_before_link and work.wake_receipt == 0) {
                    self.running.validateDigitalWakeBinding(route.window) catch return error.Binding;
                } else if (!link.readyScanout()) return error.Binding;
                self.running.validateDisplayLink() catch return error.Binding;
                const planned = self.running.displayWorkPlan(.{ .epoch = self.epoch, .root = root.binding.root }, route.window) catch return error.Binding;
                if (!std.meta.eql(plan, planned) or plan.head != route.head or
                    !std.meta.eql(work.core.config.signal, @as(?runtime.boot_mode.Signal, planned.signal)) or
                    work.core.config.cursor_usage != planned.cursor_size) return error.Binding;
            } else if (work.core.config.signal != null or work.link != null or work.core.config.cursor_usage != 0 or
                work.core.config.mst_sor_control != null or work.core.config.clear_dsc) return error.Binding;
            if (phase == .submitted) {
                if (access_kind != .read or ticket == null or ticket.?.kind != .frame or
                    channel.ring.pending == null or channel.ring.program == null or !channel.ring.published or
                    !std.meta.eql(ticket.?, channel.ring.pending.?) or !channel.ring.matchesPublished(ticket.?, config.*) or
                    ownership.notifier.phase != .submitted or ownership.notifier.point != ticket.?.point or
                    ownership.notifier.deadline != deadline or ownership.notifier.offset != 0) return error.Binding;
            }
        } else if (config.ownership_only) return error.Binding else if (mst_repair) {
            self.running.validateMstLinkRecovery() catch return error.Binding;
            const restore = &work.link_restore.?;
            if (!restore.scanout_replaced or restore.control.phase != .scanout or restore.control.pending) return error.Binding;
            const window_part = &work.window.?;
            const route = work.core.config.route.?;
            if (route.head >= root_info.hardware.heads or route.window >= 8 or window_part.handle.slot != route.window + 1) return error.Binding;
            if (work.position) |*position| {
                if (!root_info.immediate or position.handle.epoch != self.epoch or position.handle.slot != 9 + route.window) return error.Binding;
                const position_owner = if (self.running.display_channels[position.handle.slot]) |*value| value else return error.Binding;
                if (position_owner.parent != root or position_owner.info() == null or !position_owner.ring.valid() or !position_owner.ring.initialized or
                    position_owner.config.kind != .immediate or position_owner.config.index != route.window or
                    position_owner.config.handle != position.handle.handle) return error.Binding;
                if (position.phase == .submitted) {
                    const expected = runtime.display_channel.push.commands.immediate(position.config) catch return error.Binding;
                    if (position.ticket == null or position_owner.ring.pending == null or position_owner.ring.program == null or !position_owner.ring.published or
                        !std.meta.eql(position.ticket.?, position_owner.ring.pending.?) or
                        !runtime.display_channel.push.commands.same(expected, position_owner.ring.program.?)) return error.Binding;
                }
                if (position_part != null) {
                    if (phase == .submitted) {
                        if (access_kind != .read or work.core.phase != .complete or window_part.phase != .complete) return error.Binding;
                    } else if (work.core.phase != .prepare or window_part.phase != .prepare) return error.Binding;
                } else if (position.phase != .submitted and !(access_kind == .read and config.kind == .core and
                    work.core.phase == .complete and position.phase == .complete)) return error.Binding;
            } else if (position_part != null) return error.Binding;
            if (config.kind == .core) {
                if (window_part.phase != .submitted and window_part.phase != .complete) return error.Binding;
            } else if (config.kind == .window and work.core.phase != .prepare) return error.Binding;
        } else if (work.detach != null) {
            self.running.validateDisplayDetach() catch return error.Binding;
            const window_part = &work.window.?;
            const route = work.core.config.route.?;
            if (route.head >= root_info.hardware.heads or (config.kind != .core and config.kind != .window) or
                resources.publishedImage(window_part.handle.slot, work.detach.?.image.dma) == null or
                !std.meta.eql(resources.publishedImage(window_part.handle.slot, work.detach.?.image.dma).?, work.detach.?.image)) return error.Binding;
            if (config.kind == .core) {
                if (window_part.phase != .submitted and window_part.phase != .complete) return error.Binding;
            } else if (work.core.phase != .prepare) {
                // Only the exact still-published NULL Window may observe GET
                // after its own interlocked Core completed. No publication,
                // other output or ordinary image gains this read admission.
                const core_owner = if (self.running.display_channels[work.core.handle.slot]) |*value| value else return error.Binding;
                if (access_kind != .read or config.kind != .window or work.core.phase != .complete or
                    window_part.phase != .submitted or window_part.ticket == null or
                    channel.ring.pending == null or !std.meta.eql(window_part.ticket.?, channel.ring.pending.?) or
                    !channel.ring.matchesPublished(window_part.ticket.?, window_part.config) or
                    window_part.notifier.phase != .submitted or window_part.notifier.point != window_part.ticket.?.point or
                    window_part.notifier.deadline != deadline or work.core.ticket == null or
                    core_owner.ring.pending != null or core_owner.ring.completed != work.core.ticket.?.point or
                    work.core.notifier.phase != .complete or work.core.notifier.point != work.core.ticket.?.point) return error.Binding;
                null_detach_read = true;
            }
        } else if (work.window) |*window_part| {
            if (work.core.config.detach_sor != null or window_part.config.detach_sor != null) return error.Binding;
            const route = work.core.config.route orelse return error.Binding;
            if (work.boot_mode) |plan| {
                const link = if (work.link) |*value| value else return error.Binding;
                if (!link.readyScanout()) return error.Binding;
                self.running.validateDisplayLink() catch return error.Binding;
                const expected = self.running.displayWorkPlan(.{ .epoch = self.epoch, .root = root.binding.root }, route.window) catch return error.Binding;
                if (!std.meta.eql(plan, expected) or !std.meta.eql(work.core.config.signal, @as(?runtime.boot_mode.Signal, expected.signal)) or
                    work.core.config.cursor_usage != expected.cursor_size or
                    plan.head != route.head or window_part.config.scanout == null or window_part.config.scanout.?.width != plan.width or
                    window_part.config.scanout.?.height != plan.height) return error.Binding;
            } else if (work.core.config.signal != null or work.link != null) return error.Binding;
            if (window_part.config.signal != null or window_part.config.position != null or work.core.config.position != null or work.core.config.with_position or
                window_part.config.with_position != (work.position != null)) return error.Binding;
            if (work.position) |*position| {
                if (route.window >= 8 or !root_info.immediate or position.handle.epoch != self.epoch or position.handle.slot != 9 + route.window) return error.Binding;
                const position_owner = if (self.running.display_channels[position.handle.slot]) |*value| value else return error.Binding;
                const completed_position = access_kind == .read and config.kind == .core and work.core.config.mst_sor_control != null and
                    work.core.phase == .complete and window_part.phase == .complete and position.phase == .complete and
                    position.ticket != null and position_owner.ring.initialized and position_owner.ring.pending == null and
                    position_owner.ring.completed == position.ticket.?.point;
                if (position_owner.parent != root or position_owner.info() == null or !position_owner.ring.valid() or
                    position_owner.config.kind != .immediate or position_owner.config.index != route.window or position_owner.config.handle != position.handle.handle or
                    position.config.kind != .immediate or position.config.windows != root_info.hardware.windows or
                    (position.config.initialize == position_owner.ring.initialized and !completed_position) or
                    !std.meta.eql(position.config.route, work.core.config.route)) return error.Binding;
                const expected = runtime.display_channel.push.commands.immediate(position.config) catch return error.Binding;
                if (work.boot_mode != null and !std.meta.eql(position.config.position.?, runtime.display_channel.push.commands.Point{})) return error.Binding;
                if (position.phase == .submitted) {
                    if (position.ticket == null or position_owner.ring.pending == null or position_owner.ring.program == null or !position_owner.ring.published or
                        !std.meta.eql(position.ticket.?, position_owner.ring.pending.?) or
                        !runtime.display_channel.push.commands.same(expected, position_owner.ring.program.?)) return error.Binding;
                }
                if (position_part != null) {
                    if (phase == .submitted) {
                        if (access_kind != .read or work.core.phase != .complete or window_part.phase != .complete) return error.Binding;
                    } else if (work.core.phase != .prepare or window_part.phase != .prepare) return error.Binding;
                } else if (position.phase != .submitted and !(access_kind == .read and config.kind == .core and
                    work.core.phase == .complete and work.core.config.mst_sor_control != null and position.phase == .complete)) return error.Binding;
            } else if (position_part != null or work.boot_mode != null) return error.Binding;
            if (self.running.presentation != null) {
                const scanout = window_part.config.scanout orelse return error.Binding;
                const status = self.running.presentationImageStatus(scanout.dma) catch return error.Binding;
                if (status.pending or status.completed == 0 or status.failure != null) return error.Binding;
            }
            if (route.window >= 8 or route.head >= root_info.hardware.heads or window_part.handle.slot != 1 + route.window or
                work.core.config.kind != .core or window_part.config.kind != .window or
                !std.meta.eql(window_part.config.route, work.core.config.route) or
                window_part.config.scanout == null or !std.meta.eql(resources.publishedImage(window_part.handle.slot, window_part.config.scanout.?.dma), window_part.config.scanout)) return error.Binding;
            if (config.kind == .core) {
                if (window_part.phase != .submitted and window_part.phase != .complete) return error.Binding;
            } else if (config.kind == .window and work.core.phase != .prepare) return error.Binding;
        } else if (config.route != null or config.scanout != null or config.signal != null or config.position != null or config.with_position or config.detach_sor != null or
            work.boot_mode != null or work.position != null or config.kind != .core) return error.Binding;
        if (access_kind == .publish) {
            if (phase != .prepare or ticket == null or !channel.ring.matches(ticket.?, config.*)) return error.Binding;
            if (part) |value| if (ticket.?.kind == .frame and (value.notifier.phase != .armed or value.notifier.point != ticket.?.point or
                value.notifier.deadline != deadline or value.notifier.offset != config.notifier_offset)) return error.Binding;
        } else if (phase != .prepare and phase != .rewind and !null_detach_read and
            !(position_part != null and phase == .submitted) and
            !(ownership_pending and access_kind == .read and phase == .submitted) and
            !((work.cursor != null or work.detach != null or work.core.config.mst_sor_control != null) and config.kind == .core and phase == .complete)) return error.Binding;
        const rpc = self.running.activeChannel() orelse return error.State;
        const canonical = if (self.running.channel) |*value| value else return error.State;
        if (rpc != canonical or rpc.session != &self.session.? or port.runtime_session != rpc.session or rpc.session.pending != null or
            rpc.phase != .idle or rpc.pending != null or rpc.in_lockdown or rpc.request.len != 0) return error.Binding;
        try rpc.guard(deadline);
    }
    fn admitFlipPush(self: *Device, port: *const native.Port, channel: *@import("gsp_display_channel.zig").Owner,
        deadline: u64, access_kind: native.DisplayAccess) !void
    {
        if (self.running.display_work != null or self.running.head_events != &self.interrupts.display or
            !self.interrupts.display.enabled or self.interrupts.display.epoch != self.epoch) return error.Binding;
        self.running.validateOutputFlip(channel.config.index) catch return error.Binding;
        const work = self.running.displayFlip(channel.config.index) orelse return error.Binding;
        const part = &work.window;
        const config = part.config;
        const root = if (self.running.display_engine_owner) |*value| value else return error.Binding;
        const info = root.info() orelse return error.Binding;
        const resources = self.running.display_resources_slot.owner orelse return error.Binding;
        const slot = part.handle.slot;
        if (work.deadline != deadline or part.handle.epoch != self.epoch or slot == 0 or slot > 8 or
            self.running.display_channels[slot] == null or &self.running.display_channels[slot].? != channel or
            channel.config.handle != part.handle.handle or channel.config.kind != .window or channel.parent != root or
            channel.info() == null or !channel.ring.valid() or !channel.ring.initialized or
            config.windows != info.hardware.windows or config.route.?.head >= info.hardware.heads or
            !resources.valid() or resources.instance != &root.instance_storage or !std.meta.eql(resources.binding.?, root.binding) or
            resources.publishedNotifier(slot) != part.notifier or config.notifier != part.notifier.handle or
            work.receipt.begun_observed_ns != 0) return error.Binding;
        if (access_kind == .publish) {
            const ticket = part.ticket orelse return error.Binding;
            if (part.phase != .prepare or !channel.ring.matches(ticket, config)) return error.Binding;
            if (ticket.kind == .frame and (part.notifier.phase != .armed or part.notifier.point != ticket.point or
                part.notifier.deadline != deadline or part.notifier.offset != config.notifier_offset)) return error.Binding;
        } else if (part.phase != .prepare and part.phase != .rewind) return error.Binding;
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
        if (self.running.epoch != 0) {
            @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                "NVIDIA runtime-failure: epoch={d} render={s} native-job={s} main-RM={s} context={?d} fifo={?d} native={?d} buffer={?d}",
                .{ self.running.epoch, @tagName(self.render_startup.phase),
                    if (self.running.queued_native) |job| @tagName(job.phase) else "none",
                    if (self.running.channel) |channel| @tagName(channel.phase) else "none",
                    self.running.context_active, self.running.fifo_active, self.running.native_active, self.running.buffer_active });
        }
        @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
            "NVIDIA admission-failure: live={s} epoch={d} port={s} boot-status={d} boot-state={d} boot-generation={d}",
            .{ if (self.first_live_failure) |reason| @errorName(reason) else "none", self.live_failure_epoch,
                if (self.port.first_generation_failure) |reason| @tagName(reason) else "none",
                self.failed_boot_info_status, self.failed_boot_info.state, self.failed_boot_info.generation });
        if (self.first_live_failure != null) {
            @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
            "NVIDIA admission-detail: check={s} memory-valid={} failed={} recovery={x} queue-epoch={d} queue-failed={}",
            .{ @tagName(self.live_detail.check), self.live_detail.memory_valid, self.live_detail.memory_failed,
                self.live_detail.recovery_owner, self.live_detail.queue_epoch, self.live_detail.queue_failed });
            @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
            "NVIDIA admission-io: queue-status={d} log-status={d} reader={s} frts={s}",
            .{ self.live_detail.queue_status, self.live_detail.log_status,
                if (self.live_detail.reader_error) |reason| @errorName(reason) else "none",
                if (self.live_detail.frts_error) |reason| @errorName(reason) else "none" });
        }
        if (self.port.firmware_operation) |*operation| {
            @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                "NVIDIA falcon-failure: phase={s} engine={s} epoch={d} last-address={?x} last-value={?x} nested={s}",
                .{ @tagName(operation.phase), @tagName(operation.options.engine), operation.options.epoch,
                    operation.last_address, operation.last_value, if (operation.hs_operation) |*hs_operation| @tagName(hs_operation.phase) else "none" });
        }
        if (self.recovery.operation) |*operation| {
            const latency = self.port.recovery_latency;
            @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                "NVIDIA teardown-latency: stage={s} address={?x} elapsed-ns={d} start={d} end={d} includes-descheduled=yes",
                .{ @tagName(latency.stage), latency.address, latency.elapsed_ns, latency.started_ns, latency.finished_ns });
            if (operation.hs_operation) |*nested| {
                @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                    "NVIDIA teardown-nested: phase={s} last-address={?x} last-value={?x} transferred={d} blocks={d}",
                    .{ @tagName(nested.phase), nested.last_address, nested.last_value, nested.transferred, nested.result.blocks });
            }
            @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                "NVIDIA teardown-operation: phase={s} engine={s} operation={s} nested={s} last-address={?x} last-value={?x}",
                .{ @tagName(self.recovery.phase), @tagName(operation.options.engine), @tagName(operation.phase),
                    if (operation.hs_operation) |*nested| @tagName(nested.phase) else "none", operation.last_address, operation.last_value });
            @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                "NVIDIA teardown-clock: last={d} deadline={d} operation-last={d} nested-last={d} port-error={s}",
                .{ self.port.recovery_last_clock, self.recovery.deadline, operation.last_clock,
                    if (operation.hs_operation) |*nested| nested.last_clock else 0,
                    if (self.port.recovery_failure) |failure| @errorName(failure) else "none" });
        }
        if (self.recovery.operation) |*operation| if (operation.fwsec_check) |check| {
            @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                "NVIDIA teardown-fwsec: phase={s} command={s} observed={d} raw={x}/{x}/{x}",
                .{ @tagName(operation.phase), @tagName(check.command), check.observed, check.raw[0], check.raw[1], check.raw[2] });
        };
        if (self.recovery.sb_result) |sb| if (sb == .rejected) {
            const rejected = sb.rejected;
            @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                "NVIDIA teardown-fwsec: retained-rejection={s} observed={d} raw={x}/{x}/{x}",
                .{ @errorName(rejected.reason), rejected.observation.observed,
                    rejected.observation.raw[0], rejected.observation.raw[1], rejected.observation.raw[2] });
        };
        if (self.boot) |*boot| if (boot.failure) |failure| {
            if (failure.rpc) |rpc| if (failure.ticket) |ticket| {
                @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                    "NVIDIA boot-rpc: function={x} result={x} private={x} sequence={d} gfid={d} epoch={d} queue-sequence={d} cursor={d} next={d}",
                    .{ rpc.function, rpc.result, rpc.result_private, rpc.sequence, rpc.cpu_rm_gfid, ticket.epoch, ticket.sequence, ticket.cursor, ticket.next });
            };
            if (failure.payload) |payload| {
                const count = @min(payload.length, payload.prefix.len);
                @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                    "NVIDIA boot-payload: bytes={d} captured={d}", .{ payload.length, count });
                var offset: usize = 0;
                while (offset < count) : (offset += 16) {
                    const part: usize = @min(count - offset, 16);
                    const hex = std.fmt.bytesToHex(payload.prefix[offset..][0..16].*, .lower);
                    @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                        "NVIDIA boot-bytes: offset={d} hex={s}", .{ offset, hex[0 .. part * 2] });
                }
            }
        };
        @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
            "NVIDIA native-restore: stage={s} reason={s} epoch={d} display-hold={d} effects={} memory-retained={} restore-proved=no",
            .{phase,@errorName(err),self.epoch,self.display_epoch,self.port.effects_possible,self.memory.?.retained});
    }
    fn logBytes(self: *Device, engine: u32, bytes: []const u8) void {
        var escaped: [160]u8 = undefined;
        const count = @min(bytes.len, escaped.len);
        for (bytes[0..count], escaped[0..count]) |byte, *out| out.* = if (byte >= 32 and byte < 127) byte else '.';
        var buffer: [240]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buffer, "NVIDIA gsp-print: engine={d} bytes={d} text={s}", .{ engine, bytes.len, escaped[0..count] }) catch return;
        self.ctx.?.logInfo(text);
    }
    fn logBootData(self: *Device, label: []const u8, bytes: []const u8) void {
        const count: usize = @min(bytes.len, 64);
        var offset: usize = 0;
        while (offset < count) {
            // @min narrows to u5 otherwise; 16 bytes need 32 hex characters.
            const part: usize = @min(count - offset, 16);
            var block: [16]u8 = @splat(0);
            @memcpy(block[0..part], bytes[offset..][0..part]);
            const hex = std.fmt.bytesToHex(block, .lower);
            @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                "NVIDIA boot-data: kind={s} bytes={d} captured={d} offset={d} hex={s}",
                .{ label, bytes.len, count, offset, hex[0 .. part * 2] });
            offset += part;
        }
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
