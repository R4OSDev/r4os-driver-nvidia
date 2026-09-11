//! R4OS x86_64 MMIO binding for gsp_sequencer and the GA106 core executor.
//! Not opened by passive probing. The native boot owner must supply real run,
//! register-policy, DMA-retention, log-reader and quiescence implementations.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const identity = @import("identity.zig");
const seq = @import("gsp_sequencer.zig");
const core = @import("gsp_core.zig");
const firmware_run = @import("falcon_run.zig");
pub const Access = enum { read, write };
pub const Owner = struct {
    context: *anyopaque,
    generation: *const fn (*anyopaque) u64,
    // Pure whole-command admission, including the command's implicit core
    // accesses. The owner must hold VRAM/VGA/display recovery and the exact
    // firmware/boot-argument bindings for the lifetime of the admitted run.
    admit: *const fn (*anyopaque, seq.Command) error{ Denied, Unsupported }!void,
    // Rechecked for EACH actual register access, including the BOOT0 flush.
    // Enforces changing lockdown, attached/reset state and register policy.
    access: *const fn (*anyopaque, Access, u32) anyerror!void,
    // Before the first possible effect, retain every GPU-visible allocation,
    // mapping and firmware owner. A failed call may itself have retained them.
    retain: *const fn (*anyopaque) anyerror!void,
    // True only after native recovery established actual device quiescence
    // and handled log-reader suspension. No timeout or Falcon halt substitutes.
    quiesced: *const fn (*anyopaque) bool,
    log_polling: ?*const fn (*anyopaque, bool) anyerror!void = null,
    // Bind exact firmware/DMA, FWSEC or Booter command/arguments and VRAM/VGA/
    // display recovery before reset, including post-halt register reads.
    // The executor performs reset and measures TCM itself. Pure admission;
    // absent capability refuses the entire operation before device effects.
    admit_firmware: ?*const fn (*anyopaque, *const firmware_run.Options) anyerror!void = null,
};
pub const Run = struct { epoch: u64, deadline_ns: u64, resume_args: ?core.Resume = null };
pub const Port = struct {
    memory: ?r4os.driver_memory.Context = null,
    clock: ?r4os.r4dev.DriverResourceContext = null,
    owner: ?Owner = null,
    window: a.GfxMmioWindow = .{},
    run: Run = .{ .epoch = 0, .deadline_ns = 0 },
    boot0: u32 = 0,
    self_address: usize = 0,
    last_clock: u64 = 0,
    cleanup_needed: bool = false,
    ready: bool = false,
    effects_possible: bool = false,
    retained: bool = false,
    failure: ?anyerror = null,
    memory_status: i32 = 0,
    operation: ?core.Operation = null,
    firmware_operation: ?firmware_run.Operation = null,
    core_phase: u32 = 0,

    /// Stable address, serialized init/Driver Work owner; not an IRQ callback
    /// or a dedicated task. Failure retains any partially returned mapping.
    pub fn open(self: *Port, ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, boot0: u32, boot1: u32, run: Run, owner: Owner) !void {
        if (self.self_address != 0) return error.Busy;
        const chip = identity.chip(boot0, boot1) orelse return error.Profile;
        const bar = snapshot.bars[0];
        if (chip.id != 0x176 or identity.decision(snapshot) != .identity_words_only or
            bar.bytes < 0x841000 or bar.bytes > 0x100000000 or bar.bytes % 4096 != 0 or
            bar.base > std.math.maxInt(u64) - bar.bytes) return error.Profile;
        if (run.epoch == 0 or run.deadline_ns == 0 or run.deadline_ns == std.math.maxInt(u64)) return error.Options;
        self.self_address = @intFromPtr(self);
        errdefer |err| self.failure = err;
        self.run = run;
        self.owner = owner;
        self.boot0 = boot0;
        self.clock = ctx.resources() orelse return error.Api;
        try self.guard();
        self.memory = ctx.memory() orelse return error.Api;
        const request: a.GfxMmioRequest = .{ .resource_base = bar.base, .resource_bytes = bar.bytes, .byte_length = bar.bytes, .cache_policy = a.gfx_buffer_cache_uncached };
        self.cleanup_needed = true;
        self.memory_status = self.memory.?.mmioMap(&request, &self.window);
        if (self.memory_status != a.gfx_buffer_result_ok) return error.Mapping;
        const w = &self.window;
        if (w.version != 1 or w.size < @sizeOf(a.GfxMmioWindow) or w.handle.id == 0 or w.handle.generation == 0 or
            w.cpu_address == 0 or w.cpu_address % 4096 != 0 or w.cpu_address > std.math.maxInt(u64) - bar.bytes or
            w.physical_address != bar.base or w.byte_length != bar.bytes or w.cache_policy != a.gfx_buffer_cache_uncached) return error.Mapping;
        self.ready = true;
        if (try self.read(0) != boot0 or try self.read(4) != boot1) return error.IdentityChanged;
        try self.guard();
    }
    pub fn sequencer(self: *Port) !seq.Port {
        try self.guard();
        if (!self.ready) return error.State;
        if (self.firmware_operation != null) return error.Busy;
        return .{ .context = self, .generation = generation, .now_ns = nowNs, .admit = admit, .read32 = sequenceRead, .write32 = sequenceWrite, .core_step = coreStep };
    }
    pub fn beginFirmware(self: *Port, options: firmware_run.Options) !void {
        try self.guard();
        if (!self.ready) return error.State;
        if (self.operation != null or self.firmware_operation != null) return error.Busy;
        if (options.epoch != self.run.epoch or options.boot0 != self.boot0 or options.deadline > self.run.deadline_ns or options.deadline <= self.last_clock) return error.Options;
        const operation = try firmware_run.Operation.init(options);
        // BCR and BROM live on the second page. Admit the complete aperture
        // before reset, including the possibly needed RISC-V/Falcon switch.
        if (!self.supports(.write, operation.base() + 0x1668)) return error.Register;
        // Admission itself remains an explicit phase in the stable stored
        // operation, so failure is preserved before any register mutation.
        if (self.owner.?.admit_firmware == null) return error.Unsupported;
        if (options.booter != null and self.owner.?.log_polling == null) return error.Unsupported;
        self.firmware_operation = operation;
    }
    /// FWSEC/Booter completion includes the command-specific result checks;
    /// generic runs return raw mailboxes. All DMA and this mapping stay held.
    /// Neither result establishes GSP readiness or device quiescence.
    pub fn stepFirmware(self: *Port) !?firmware_run.Result {
        errdefer |err| self.failure = err;
        try self.guard();
        const operation = if (self.firmware_operation) |*op| op else return error.State;
        const done = try operation.step(.{ .context = self, .generation = generation, .now_ns = nowNs, .admit = admitFirmware, .read32 = read32, .write32 = write32,
            .log_polling = if (self.owner.?.log_polling != null) logs else null });
        if (!done) return null;
        const result = operation.result.?;
        self.firmware_operation = null;
        return result;
    }
    fn admitFirmware(p: *anyopaque, options: *const firmware_run.Options) anyerror!void {
        const self = cast(p);
        try self.guard();
        const owner = self.owner.?;
        try (owner.admit_firmware orelse return error.Unsupported)(owner.context, options);
        try self.guard();
    }
    fn cast(p: *anyopaque) *Port {
        return @ptrCast(@alignCast(p));
    }
    fn generation(p: *anyopaque) u64 {
        const self = cast(p);
        if (self.self_address != @intFromPtr(self) or !self.ready or self.failure != null) return 0;
        const owner = self.owner orelse return 0;
        return owner.generation(owner.context);
    }
    fn nowNs(p: *anyopaque) u64 {
        const self = cast(p);
        if (self.self_address != @intFromPtr(self) or self.clock == null) return std.math.maxInt(u64);
        return self.clock.?.nowNs();
    }
    fn guard(self: *Port) !void {
        if (self.self_address != @intFromPtr(self) or self.failure != null or self.owner == null or self.clock == null) return error.State;
        const owner = self.owner.?;
        if (owner.generation(owner.context) != self.run.epoch) return error.Stale;
        const now = self.clock.?.nowNs();
        if (now == std.math.maxInt(u64) or now < self.last_clock) return error.Clock;
        self.last_clock = now;
        if (now >= self.run.deadline_ns) return error.Deadline;
    }
    fn access(self: *Port, kind: Access, offset: u32) !void {
        try self.guard();
        if (!self.supports(kind, offset)) return error.Register;
        const owner = self.owner.?;
        try owner.access(owner.context, kind, offset);
        try self.guard();
    }
    fn supports(self: *const Port, kind: Access, offset: u32) bool {
        if (!self.ready or self.window.byte_length < 4 or offset % 4 != 0 or offset > self.window.byte_length - 4) return false;
        return switch (kind) {
            .write => offset >= 8,
            .read => offset != core.reg.cpuctl_alias and offset != core.reg.sec_cpuctl_alias,
        };
    }
    fn admit(p: *anyopaque, command: seq.Command) error{ Denied, Unsupported }!void {
        const self = cast(p);
        self.guard() catch return error.Denied;
        if (!self.ready or self.firmware_operation != null) return error.Denied;
        // Reject known aperture/identity/write-only errors in the pure pass,
        // including errors near the end of a stream after otherwise valid IO.
        const supported = switch (command) {
            .write => |v| self.supports(.write, v.address),
            .modify => |v| self.supports(.read, v.address) and self.supports(.write, v.address),
            .poll => |v| self.supports(.read, v.address),
            .store => |v| self.supports(.read, v.address),
            else => true,
        };
        if (!supported) return error.Denied;
        if (command == .core_resume) {
            if (self.owner.?.log_polling == null) return error.Unsupported;
            _ = core.Operation.init(.core_resume, self.run.epoch, self.run.deadline_ns, self.boot0, self.run.resume_args) catch return error.Unsupported;
        }
        // This is the pure pass: no MMIO, log callbacks or retention here.
        const owner = self.owner.?;
        try owner.admit(owner.context, command);
        self.guard() catch return error.Denied;
    }
    fn fence() void {
        // UC MMIO plus a full x86 ordering boundary around DMA/normal memory.
        // mfence does not itself drain PCI posted writes; write() also reads
        // the same device's read-only BOOT0, never a write-only target alias.
        asm volatile ("mfence" ::: .{ .memory = true });
    }
    fn pointer(self: *Port, offset: u32) *volatile u32 {
        return @ptrFromInt(self.window.cpu_address + offset);
    }
    fn read(self: *Port, offset: u32) !u32 {
        errdefer |err| self.failure = err;
        try self.access(.read, offset);
        fence();
        const value = self.pointer(offset).*;
        fence();
        try self.guard();
        return value;
    }
    fn retain(self: *Port) !void {
        if (self.retained) return;
        self.effects_possible = true; // Before a possibly partial callback.
        const owner = self.owner.?;
        try owner.retain(owner.context);
        self.retained = true;
        try self.guard();
    }
    fn write(self: *Port, offset: u32, value: u32) !void {
        errdefer |err| self.failure = err;
        try self.access(.write, offset);
        try self.access(.read, 0); // Admit the mandatory flush before the write.
        try self.retain();
        try self.access(.write, offset);
        fence();
        self.pointer(offset).* = value;
        fence();
        if (try self.read(0) != self.boot0) return error.IdentityChanged;
    }
    fn read32(p: *anyopaque, offset: u32) anyerror!u32 {
        return cast(p).read(offset);
    }
    fn write32(p: *anyopaque, offset: u32, value: u32) anyerror!void {
        return cast(p).write(offset, value);
    }
    fn sequenceRead(p: *anyopaque, offset: u32) anyerror!u32 {
        if (cast(p).firmware_operation != null) return error.Busy;
        return read32(p, offset);
    }
    fn sequenceWrite(p: *anyopaque, offset: u32, value: u32) anyerror!void {
        if (cast(p).firmware_operation != null) return error.Busy;
        return write32(p, offset, value);
    }
    fn logs(p: *anyopaque, enable: bool) anyerror!void {
        const self = cast(p);
        try self.guard();
        try self.retain();
        const owner = self.owner.?;
        try (owner.log_polling orelse return error.Resume)(owner.context, enable);
        try self.guard();
    }
    fn coreStep(p: *anyopaque, opcode: seq.Opcode, state: *seq.CoreState, deadline: u64, _: *const [8]u32) anyerror!bool {
        const self = cast(p);
        errdefer |err| self.failure = err;
        try self.guard();
        if (self.firmware_operation != null) return error.Busy;
        if (deadline > self.run.deadline_ns or deadline <= self.last_clock) return error.Deadline;
        if (state.phase == 0) {
            if (self.operation != null) return error.Busy;
            self.operation = try core.Operation.init(opcode, self.run.epoch, deadline, self.boot0, self.run.resume_args);
            self.core_phase = 0;
        }
        const operation = if (self.operation) |*op| op else return error.State;
        if (state.phase != self.core_phase or opcode != operation.opcode or deadline != operation.deadline or state.phase == std.math.maxInt(u32)) return error.State;
        const done = try operation.step(.{ .context = self, .generation = generation, .now_ns = nowNs, .read32 = read32, .write32 = write32, .log_polling = logs });
        state.phase += 1;
        self.core_phase = state.phase;
        if (done) self.operation = null;
        return done;
    }
    /// Retryable mapping cleanup. Ambiguous device effects keep this port and
    /// every external DMA owner alive until the native owner proves quiescence.
    /// Invalidates outstanding callback copies before the first unmap attempt.
    pub fn close(self: *Port) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self)) return false;
        if (self.effects_possible) {
            const owner = self.owner orelse return false;
            if (!owner.quiesced(owner.context)) return false;
        }
        self.ready = false;
        if (self.memory) |memory| {
            if (self.window.handle.id != 0) {
                self.memory_status = memory.mmioUnmap(&self.window.handle, 1);
                if (self.memory_status != a.gfx_buffer_result_ok) return false;
                self.window = .{};
            }
            if (self.cleanup_needed) {
                self.memory_status = memory.collect();
                if (self.memory_status != a.gfx_buffer_result_ok) return false;
            }
        }
        self.* = .{};
        return true;
    }
};
