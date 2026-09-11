// Queue notification adapted from NVIDIA570.144 (MIT); R4OS owner/facade Apache-2.0.
// src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2019-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
//  * SPDX-License-Identifier: MIT
//  *
//  * Permission is hereby granted, free of charge, to any person obtaining a
//  * copy of this software and associated documentation files (the "Software"),
//  * to deal in the Software without restriction, including without limitation
//  * the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  * and/or sell copies of the Software, and to permit persons to whom the
//  * Software is furnished to do so, subject to the following conditions:
//  *
//  * The above copyright notice and this permission notice shall be included in
//  * all copies or substantial portions of the Software.
//  *
//  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  * DEALINGS IN THE SOFTWARE.
//  */
// src/nvidia/src/kernel/gpu/gsp/arch/turing/kernel_gsp_tu102.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2017-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
//  * SPDX-License-Identifier: MIT
//  *
//  * Permission is hereby granted, free of charge, to any person obtaining a
//  * copy of this software and associated documentation files (the "Software"),
//  * to deal in the Software without restriction, including without limitation
//  * the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  * and/or sell copies of the Software, and to permit persons to whom the
//  * Software is furnished to do so, subject to the following conditions:
//  *
//  * The above copyright notice and this permission notice shall be included in
//  * all copies or substantial portions of the Software.
//  *
//  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  * DEALINGS IN THE SOFTWARE.
//  */
// src/common/inc/swref/published/ampere/ga102/dev_gsp.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2003-2021 NVIDIA CORPORATION & AFFILIATES
//  * SPDX-License-Identifier: MIT
//  *
//  * Permission is hereby granted, free of charge, to any person obtaining a
//  * copy of this software and associated documentation files (the "Software"),
//  * to deal in the Software without restriction, including without limitation
//  * the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  * and/or sell copies of the Software, and to permit persons to whom the
//  * Software is furnished to do so, subject to the following conditions:
//  *
//  * The above copyright notice and this permission notice shall be included in
//  * all copies or substantial portions of the Software.
//  *
//  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  * DEALINGS IN THE SOFTWARE.
//  */
// src/nvidia/inc/kernel/gpu/gsp/message_queue.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2019-2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
//  * SPDX-License-Identifier: MIT
//  *
//  * Permission is hereby granted, free of charge, to any person obtaining a
//  * copy of this software and associated documentation files (the "Software"),
//  * to deal in the Software without restriction, including without limitation
//  * the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  * and/or sell copies of the Software, and to permit persons to whom the
//  * Software is furnished to do so, subject to the following conditions:
//  *
//  * The above copyright notice and this permission notice shall be included in
//  * all copies or substantial portions of the Software.
//  *
//  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  * DEALINGS IN THE SOFTWARE.
//  */
//! R4OS x86_64 MMIO binding for gsp_sequencer and the GA106 core executor.
//! Not opened by passive probing. The native boot owner must supply real run,
//! register-policy, DMA-retention, log-reader and quiescence implementations.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const identity = @import("identity.zig");
const bar0 = @import("bar0.zig");
const seq = @import("gsp_sequencer.zig");
const core = @import("gsp_core.zig");
const firmware_run = @import("falcon_run.zig");
const transport = @import("gsp_transport.zig");
const run_memory = @import("gsp_run_memory.zig");
const events = @import("gsp_boot_events.zig");
const exchange = @import("gsp_exchange.zig");
const display_rpc = @import("gsp_display_rpc.zig");
// Bare-metal RM queue 0, NV_PGSP_QUEUE_HEAD(0). This is not SWGEN0 or a
// virtual-function doorbell. The memory cursor is published separately.
pub const command_queue_head: u32 = 0x110c00;
pub const Access = enum { read, write };
pub const Phase = enum { boot, runtime };
const Scope = union(enum) { boot: void, request: u64 };
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
    // Pure normal-cold-boot admission. Bind the exact retained Libos/boot
    // descriptor and successful FRTS (prepare) or normal Booter Load (finish)
    // from this same run, plus full device/display recovery. No boolean caller
    // result or successful command alone grants these dependencies.
    admit_cold: ?*const fn (*anyopaque, core.Cold) anyerror!void = null,
    // Exact retained storage run for native queue traffic. Frozen at open;
    // its API and epoch must match this port, and every access rechecks it.
    // The native owner still admits firmware readiness/lockdown/reset state.
    queue_memory: ?*run_memory.Lease = null,
    // Pure admission of the actual same-run bootstrap and recovery bindings
    // before leaving boot. The Boot passed here already handled/ACKed INIT_DONE.
    // No callback or timer may manufacture firmware readiness from elapsed time.
    admit_runtime: ?*const fn (*anyopaque, *const events.Boot) anyerror!void = null,
};
pub const Run = struct { epoch: u64, deadline_ns: u64, resume_args: ?core.Resume = null };
pub const Port = struct {
    memory: ?r4os.driver_memory.Context = null,
    clock: ?r4os.r4dev.DriverResourceContext = null,
    owner: ?Owner = null,
    window: a.GfxMmioWindow = .{},
    shared: bar0.Lease = .{},
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
    cold_command: ?core.Cold = null,
    cold_admitted: bool = false,
    core_phase: u32 = 0,
    phase: Phase = .boot,
    runtime_session: ?*transport.Session = null,
    runtime_sequence: ?*RuntimeSequencer = null,

    /// Stable address, serialized init/Driver Work owner; not an IRQ callback
    /// or a dedicated task. Failure retains any partially returned mapping.
    pub fn open(self: *Port, ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, boot0: u32, boot1: u32, run: Run, owner: Owner) !void {
        return self.openUsing(ctx, snapshot, boot0, boot1, run, owner, null);
    }
    /// Borrow the capture's existing BAR0 window. Close retains this borrow
    /// through ambiguous effects; only the mapping owner can unmap it.
    pub fn openShared(self: *Port, ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, boot0: u32, boot1: u32, run: Run, owner: Owner, shared: *bar0.Owner) !void {
        return self.openUsing(ctx, snapshot, boot0, boot1, run, owner, shared);
    }
    fn openUsing(self: *Port, ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, boot0: u32, boot1: u32, run: Run, owner: Owner, shared: ?*bar0.Owner) !void {
        if (self.self_address != 0) return error.Busy;
        const chip = identity.chip(boot0, boot1) orelse return error.Profile;
        const bar = snapshot.bars[0];
        if (chip.id != 0x176 or identity.decision(snapshot) != .identity_words_only or
            bar.bytes < 0x841000 or bar.bytes > 0x100000000 or bar.bytes % 4096 != 0 or
            bar.base > std.math.maxInt(u64) - bar.bytes) return error.Profile;
        if (run.epoch == 0 or run.deadline_ns == 0 or run.deadline_ns == std.math.maxInt(u64)) return error.Options;
        if (owner.queue_memory) |memory| {
            if (memory.api != ctx.api or memory.generation() != run.epoch) return error.Stale;
        }
        self.self_address = @intFromPtr(self);
        errdefer |err| self.failure = err;
        self.run = run;
        self.owner = owner;
        self.boot0 = boot0;
        self.clock = ctx.resources() orelse return error.Api;
        try self.guard();
        self.memory = ctx.memory() orelse return error.Api;
        if (shared) |mapping| {
            try self.shared.acquire(mapping, ctx, snapshot, chip);
            self.window = try self.shared.whole();
        } else {
            const request: a.GfxMmioRequest = .{ .resource_base = bar.base, .resource_bytes = bar.bytes, .byte_length = bar.bytes, .cache_policy = a.gfx_buffer_cache_uncached };
            self.cleanup_needed = true;
            self.memory_status = self.memory.?.mmioMap(&request, &self.window);
            if (self.memory_status != a.gfx_buffer_result_ok) return error.Mapping;
        }
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
        if (self.firmware_operation != null or self.cold_command != null) return error.Busy;
        return .{ .context = self, .generation = generation, .now_ns = nowNs, .admit = admit, .read32 = sequenceRead, .write32 = sequenceWrite, .core_step = coreStep };
    }
    /// One native queue facade over the same BAR0 and prepared DMA run. The
    /// sole Session owns it; passive probing never opens or calls this path.
    /// This does not renew the native run's deadline or establish RM readiness.
    pub fn transportPort(self: *Port) !transport.Port {
        try self.guard();
        _ = try self.queueMemory(self.run.deadline_ns);
        return self.boundTransport();
    }
    fn boundTransport(self: *Port) transport.Port {
        return .{ .context = self, .generation = generation, .now_ns = nowNs, .read = queueRead, .publish = queuePublish, .notification = .{ .context = self, .generation = generation, .prepare = prepareCommand, .submit = notifyCommand } };
    }
    fn runtimeValid(self: *Port) bool {
        if (self.phase != .runtime) return true;
        const session = self.runtime_session orelse return false;
        return session.state == .active and session.epoch == self.run.epoch and std.meta.eql(session.port, self.boundTransport());
    }
    /// Commit the one-way boot -> runtime transition only for the actual
    /// bound Session after INIT_DONE and its ACK. No allocation, remapping,
    /// new queue epoch, renewed boot deadline or release of backing occurs.
    /// Return the same sole runtime token used by the RM object/exchange owner.
    pub fn handoffBoot(self: *Port, boot: *events.Boot) !events.Handoff {
        if (self.phase != .boot) return error.Phase;
        try self.guard();
        if (!std.meta.eql(boot.session.port, try self.transportPort()) or boot.session.epoch != self.run.epoch) return error.Binding;
        if (boot.state != .init_done or boot.pending != null or boot.session.pending != null or boot.session.state != .active) return error.State;
        const admit_runtime = self.owner.?.admit_runtime orelse return error.Unsupported;
        errdefer |err| self.failure = err;
        const deadline = @min(boot.deadline, self.run.deadline_ns);
        const memory = try self.queueMemory(deadline);
        if (!self.retained or !memory.retained or !self.effects_possible) return error.State;
        try admit_runtime(self.owner.?.context, boot);
        _ = try self.queueMemory(deadline);
        const handoff = try boot.handoff(deadline);
        // Everything fallible completed while boot still owned the deadline.
        self.runtime_session = boot.session;
        self.phase = .runtime;
        return handoff;
    }
    fn queueMemory(self: *Port, deadline: u64) !*run_memory.Lease {
        try self.guardFor(.{ .request = deadline });
        if (!self.ready) return error.State;
        if (self.operation != null or self.firmware_operation != null or self.cold_command != null) return error.Busy;
        const memory = self.owner.?.queue_memory orelse return error.Unsupported;
        if (self.phase == .runtime and (self.runtime_session == null or !self.retained or !memory.retained)) return error.State;
        return memory;
    }
    fn queueRead(p: *anyopaque, deadline: u64, queue: transport.ring.Queue, offset: usize, bytes: []u8) anyerror!void {
        const self = cast(p);
        if (self.runtime_sequence != null) return error.Busy;
        errdefer |err| self.failure = err;
        const memory = try self.queueMemory(deadline);
        const port = try memory.transportPort();
        try port.read(port.context, deadline, queue, offset, bytes);
        try self.guardFor(.{ .request = deadline });
    }
    fn queuePublish(p: *anyopaque, deadline: u64, queue: transport.ring.Queue, offset: usize, bytes: []const u8) anyerror!void {
        const self = cast(p);
        if (self.runtime_sequence) |execution| if (!execution.permitsAck(deadline, queue, offset, bytes)) return error.Busy;
        errdefer |err| self.failure = err;
        const memory = try self.queueMemory(deadline);
        // ACK publication can be the first effect too. It needs retention,
        // but does not ring the command queue notification register.
        try self.retainFor(.{ .request = deadline });
        const port = try memory.transportPort();
        try port.publish(port.context, deadline, queue, offset, bytes);
        try self.guardFor(.{ .request = deadline });
    }
    fn commandAdmission(self: *Port, deadline: u64) !void {
        if (self.runtime_sequence != null) return error.Busy;
        _ = try self.queueMemory(deadline);
        const scope: Scope = .{ .request = deadline };
        try self.accessFor(scope, .write, command_queue_head);
        try self.accessFor(scope, .read, 0); // Required BOOT0 flush, admitted before TX.
    }
    fn prepareCommand(p: *anyopaque, deadline: u64) anyerror!void {
        const self = cast(p);
        if (self.runtime_sequence != null) return error.Busy;
        errdefer |err| self.failure = err;
        try self.commandAdmission(deadline);
        try self.retainFor(.{ .request = deadline });
        try self.commandAdmission(deadline);
    }
    fn notifyCommand(p: *anyopaque, deadline: u64) anyerror!void {
        const self = cast(p);
        if (self.runtime_sequence != null) return error.Busy;
        errdefer |err| self.failure = err;
        try self.commandAdmission(deadline);
        if (!self.retained) return error.State;
        // writeFor() fences prior DMA/cursor publication, performs the exact
        // 32-bit zero write, then flushes PCI posted writes through BOOT0.
        try self.writeFor(.{ .request = deadline }, command_queue_head, 0);
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
    /// Two explicit stages around normal Booter Load. Arguments come from the
    /// bound run; the caller cannot substitute a new Libos DMA address here.
    pub fn beginColdBoot(self: *Port, stage: core.ColdStage, deadline: u64) !void {
        try self.guard();
        if (!self.ready) return error.State;
        if (self.operation != null or self.firmware_operation != null) return error.Busy;
        if (deadline > self.run.deadline_ns or deadline <= self.last_clock) return error.Deadline;
        const args = self.run.resume_args orelse return error.BootArguments;
        const command: core.Cold = .{ .stage = stage, .args = args };
        const operation = try core.Operation.initCold(command, self.run.epoch, deadline, self.boot0);
        if (!self.supports(.write, core.reg.bcr) or !self.supports(.read, core.reg.riscv_cpuctl)) return error.Register;
        if (self.owner.?.admit_cold == null) return error.Unsupported;
        self.operation = operation;
        self.cold_command = command;
        self.cold_admitted = false;
    }
    /// One bounded native stage step. Completion retains every DMA/MMIO owner
    /// and only means prepared or RISC-V ACTIVE; boot notifications must still
    /// establish RM_INIT_DONE. Failures preserve the operation and raw state.
    pub fn stepColdBoot(self: *Port) !bool {
        if (self.phase != .boot) return error.Phase;
        errdefer |err| self.failure = err;
        try self.guard();
        const command = self.cold_command orelse return error.State;
        const operation = if (self.operation) |*op| op else return error.State;
        if (operation.deadline <= self.last_clock or operation.deadline > self.run.deadline_ns) return error.Deadline;
        if (self.firmware_operation != null or operation.cold_stage != command.stage or
            self.run.resume_args == null or !std.meta.eql(self.run.resume_args.?, command.args) or
            operation.resume_args == null or !std.meta.eql(operation.resume_args.?, command.args)) return error.State;
        if (!self.cold_admitted) {
            const owner = self.owner.?;
            try (owner.admit_cold orelse return error.Unsupported)(owner.context, command);
            try self.guard();
            if (operation.deadline <= self.last_clock) return error.Deadline;
            self.cold_admitted = true;
            return false;
        }
        const done = try operation.step(.{ .context = self, .generation = generation, .now_ns = nowNs, .read32 = read32, .write32 = write32 });
        if (done) {
            self.operation = null;
            self.cold_command = null;
            self.cold_admitted = false;
        }
        return done;
    }
    /// FWSEC/Booter completion includes the command-specific result checks;
    /// generic runs return raw mailboxes. All DMA and this mapping stay held.
    /// Neither result establishes GSP readiness or device quiescence.
    pub fn stepFirmware(self: *Port) !?firmware_run.Result {
        if (self.phase != .boot) return error.Phase;
        errdefer |err| self.failure = err;
        try self.guard();
        const operation = if (self.firmware_operation) |*op| op else return error.State;
        const done = try operation.step(.{ .context = self, .generation = generation, .now_ns = nowNs, .admit = admitFirmware, .read32 = read32, .write32 = write32, .log_polling = if (self.owner.?.log_polling != null) logs else null });
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
        if (self.self_address != @intFromPtr(self) or !self.ready or self.failure != null or !self.mappingValid() or !self.runtimeValid()) return 0;
        const owner = self.owner orelse return 0;
        if (owner.queue_memory) |memory| {
            if (memory.generation() != self.run.epoch) return 0;
        }
        return owner.generation(owner.context);
    }
    fn nowNs(p: *anyopaque) u64 {
        const self = cast(p);
        if (self.self_address != @intFromPtr(self) or self.clock == null) return std.math.maxInt(u64);
        return self.clock.?.nowNs();
    }
    fn guard(self: *Port) !void {
        return self.guardFor(.boot);
    }
    fn guardFor(self: *Port, scope: Scope) !void {
        if (scope == .boot and self.phase != .boot) return error.Phase;
        if (self.self_address != @intFromPtr(self) or self.failure != null or self.owner == null or self.clock == null) return error.State;
        if (!self.mappingValid() or !self.runtimeValid()) return error.Stale;
        const owner = self.owner.?;
        if (owner.generation(owner.context) != self.run.epoch) return error.Stale;
        if (owner.queue_memory) |memory| {
            if (memory.generation() != self.run.epoch) return error.Stale;
        }
        const now = self.clock.?.nowNs();
        if (now == std.math.maxInt(u64) or now < self.last_clock) return error.Clock;
        self.last_clock = now;
        const deadline = switch (scope) {
            .boot => self.run.deadline_ns,
            .request => |limit| blk: {
                if (self.phase == .boot and limit > self.run.deadline_ns) return error.Deadline;
                break :blk limit;
            },
        };
        if (deadline == std.math.maxInt(u64) or now >= deadline) return error.Deadline;
    }
    fn mappingValid(self: *const Port) bool {
        return self.shared.owner == null or (self.shared.valid() and std.meta.eql(self.window, self.shared.stamp));
    }
    fn accessFor(self: *Port, scope: Scope, kind: Access, offset: u32) !void {
        try self.guardFor(scope);
        if (!self.supports(kind, offset)) return error.Register;
        const owner = self.owner.?;
        try owner.access(owner.context, kind, offset);
        try self.guardFor(scope);
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
        if (!self.ready or self.firmware_operation != null or self.cold_command != null) return error.Denied;
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
        return self.readFor(.boot, offset);
    }
    fn readFor(self: *Port, scope: Scope, offset: u32) !u32 {
        if (scope == .boot and self.phase != .boot) return error.Phase;
        errdefer |err| self.failure = err;
        try self.accessFor(scope, .read, offset);
        fence();
        const value = self.pointer(offset).*;
        fence();
        try self.guardFor(scope);
        return value;
    }
    fn retain(self: *Port) !void {
        return self.retainFor(.boot);
    }
    fn retainFor(self: *Port, scope: Scope) !void {
        if (self.retained) return;
        self.effects_possible = true; // Before a possibly partial callback.
        const owner = self.owner.?;
        if (owner.queue_memory) |memory| try memory.retainForDevice();
        try owner.retain(owner.context);
        self.retained = true;
        try self.guardFor(scope);
    }
    fn write(self: *Port, offset: u32, value: u32) !void {
        return self.writeFor(.boot, offset, value);
    }
    fn writeFor(self: *Port, scope: Scope, offset: u32, value: u32) !void {
        if (scope == .boot and self.phase != .boot) return error.Phase;
        errdefer |err| self.failure = err;
        try self.accessFor(scope, .write, offset);
        try self.accessFor(scope, .read, 0); // Admit mandatory flush before write.
        try self.retainFor(scope);
        try self.accessFor(scope, .write, offset);
        fence();
        self.pointer(offset).* = value;
        fence();
        if (try self.readFor(scope, 0) != self.boot0) return error.IdentityChanged;
    }
    fn read32(p: *anyopaque, offset: u32) anyerror!u32 {
        return cast(p).read(offset);
    }
    fn write32(p: *anyopaque, offset: u32, value: u32) anyerror!void {
        return cast(p).write(offset, value);
    }
    fn sequenceRead(p: *anyopaque, offset: u32) anyerror!u32 {
        if (cast(p).firmware_operation != null or cast(p).cold_command != null) return error.Busy;
        return read32(p, offset);
    }
    fn sequenceWrite(p: *anyopaque, offset: u32, value: u32) anyerror!void {
        if (cast(p).firmware_operation != null or cast(p).cold_command != null) return error.Busy;
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
        if (self.phase != .boot) return error.Phase;
        errdefer |err| self.failure = err;
        try self.guard();
        if (self.firmware_operation != null or self.cold_command != null) return error.Busy;
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
        if (self.runtime_sequence != null) return false;
        if (self.effects_possible) {
            const owner = self.owner orelse return false;
            if (!owner.quiesced(owner.context)) return false;
        }
        self.ready = false;
        if (self.shared.owner != null) {
            if (!self.mappingValid() or !self.shared.release()) return false;
            self.* = .{};
            return true;
        }
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

/// One borrowed CPU-sequencer notification in an admitted runtime. Keep this
/// value, the exchange and its immutable receipt at stable addresses; discard
/// all borrowed callback copies before close/reuse. No new mapping or DMA owner.
pub const RuntimeSequencer = struct {
    self_address: usize = 0,
    device: ?*Port = null,
    owner: ?*exchange.Exchange = null,
    ticket: ?transport.Ticket = null,
    epoch: u64 = 0,
    deadline: u64 = 0,
    execution: ?seq.DispatchExecution = null,
    operation: ?core.Operation = null,
    core_phase: u32 = 0,
    complete: bool = false,
    failed: bool = false,
    failure: ?anyerror = null,

    pub fn begin(self: *RuntimeSequencer, device: *Port, owner: *exchange.Exchange, limits: seq.Limits) !void {
        return self.beginSource(device, owner, limits, null);
    }
    pub fn beginDisplay(self: *RuntimeSequencer, device: *Port, owner: *display_rpc.Channel, limits: seq.Limits) !void {
        const pending = owner.pending orelse return error.State;
        if ((try owner.borrow(pending.ticket)).value != .notification) return error.State;
        return self.beginSource(device, &owner.exchange, limits, owner);
    }
    fn beginSource(self: *RuntimeSequencer, device: *Port, owner: *exchange.Exchange, limits: seq.Limits, display_owner: ?*display_rpc.Channel) !void {
        if (self.self_address != 0 or device.runtime_sequence != null) return error.Busy;
        if (device.phase != .runtime or device.runtime_session != owner.session) return error.State;
        const pending = owner.pending orelse return error.State;
        if (pending.response or pending.record.rpc.function != @intFromEnum(events.Kind.cpu_sequencer)) return error.State;
        _ = try owner.borrow(pending.ticket);
        const deadline = owner.deadline orelse return error.State;
        _ = try device.queueMemory(deadline);
        if (limits.register_bytes != device.window.byte_length) return error.Options;
        self.* = .{ .self_address = @intFromPtr(self), .device = device, .owner = owner, .ticket = pending.ticket, .epoch = owner.session.epoch, .deadline = deadline };
        device.runtime_sequence = self;
        errdefer |err| {
            self.failed = true;
            self.failure = err;
        }
        // Whole-stream admission runs before any register read/write/core step.
        self.execution = if (display_owner) |channel| try seq.DispatchExecution.initDisplay(channel, self.io(), limits) else try seq.DispatchExecution.initRuntime(owner, self.io(), limits);
    }
    fn from(p: *anyopaque) *RuntimeSequencer {
        return @ptrCast(@alignCast(p));
    }
    fn generation(p: *anyopaque) u64 {
        const self = from(p);
        if (self.self_address != @intFromPtr(self) or self.failed or self.complete) return 0;
        const device = self.device orelse return 0;
        const owner = self.owner orelse return 0;
        const ticket = self.ticket orelse return 0;
        const pending = owner.pending orelse return 0;
        if (device.phase != .runtime or device.runtime_sequence != self or device.runtime_session != owner.session or
            Port.generation(device) != self.epoch or pending.response or !std.meta.eql(ticket, pending.ticket) or
            pending.record.rpc.function != @intFromEnum(events.Kind.cpu_sequencer)) return 0;
        return self.epoch;
    }
    fn now(p: *anyopaque) u64 {
        const self = from(p);
        const device = self.device orelse return std.math.maxInt(u64);
        return Port.nowNs(device);
    }
    fn guard(self: *RuntimeSequencer) !u64 {
        if (self.failed or self.complete) return error.State;
        if (generation(self) != self.epoch) return error.Stale;
        const owner = self.owner.?;
        _ = try owner.borrow(self.ticket.?);
        var limit = @min(self.deadline, owner.deadline orelse return error.State);
        if (self.execution) |*execution| {
            limit = @min(limit, execution.runner.options.deadline_ns);
            if (execution.runner.phase_deadline) |phase| limit = @min(limit, phase);
        }
        try self.device.?.guardFor(.{ .request = limit });
        return limit;
    }
    fn io(self: *RuntimeSequencer) seq.Port {
        return .{ .context = self, .generation = generation, .now_ns = now, .admit = admit, .read32 = read, .write32 = write, .core_step = coreStep };
    }
    fn admit(p: *anyopaque, command: seq.Command) error{ Denied, Unsupported }!void {
        const self = from(p);
        const deadline = self.guard() catch return error.Denied;
        const device = self.device.?;
        const allowed = switch (command) {
            .write => |v| device.supports(.write, v.address),
            .modify => |v| device.supports(.read, v.address) and device.supports(.write, v.address),
            .poll => |v| device.supports(.read, v.address),
            .store => |v| device.supports(.read, v.address),
            else => true,
        };
        if (!allowed) return error.Denied;
        if (command == .core_resume) {
            if (device.owner.?.log_polling == null) return error.Unsupported;
            _ = core.Operation.init(.core_resume, self.epoch, deadline, device.boot0, device.run.resume_args) catch return error.Unsupported;
        }
        try device.owner.?.admit(device.owner.?.context, command);
        _ = self.guard() catch return error.Denied;
    }
    fn read(p: *anyopaque, address: u32) anyerror!u32 {
        const self = from(p);
        const limit = try self.guard();
        const value = try self.device.?.readFor(.{ .request = limit }, address);
        _ = try self.guard();
        return value;
    }
    fn write(p: *anyopaque, address: u32, value: u32) anyerror!void {
        const self = from(p);
        const limit = try self.guard();
        try self.device.?.writeFor(.{ .request = limit }, address, value);
        _ = try self.guard();
    }
    fn logs(p: *anyopaque, enable: bool) anyerror!void {
        const self = from(p);
        const limit = try self.guard();
        const device = self.device.?;
        try device.retainFor(.{ .request = limit });
        const owner = device.owner.?;
        try (owner.log_polling orelse return error.Resume)(owner.context, enable);
        _ = try self.guard();
    }
    fn coreStep(p: *anyopaque, opcode: seq.Opcode, state: *seq.CoreState, deadline: u64, _: *const [8]u32) anyerror!bool {
        const self = from(p);
        const limit = @min(deadline, try self.guard());
        const device = self.device.?;
        if (state.phase == 0) {
            if (self.operation != null) return error.Busy;
            self.operation = try core.Operation.init(opcode, self.epoch, limit, device.boot0, device.run.resume_args);
            self.core_phase = 0;
        }
        const operation = if (self.operation) |*value| value else return error.State;
        if (state.phase != self.core_phase or opcode != operation.opcode or state.phase == std.math.maxInt(u32)) return error.State;
        operation.deadline = @min(operation.deadline, limit); // A tightened exchange cannot renew this phase.
        const done = try operation.step(.{ .context = self, .generation = generation, .now_ns = now, .read32 = read, .write32 = write, .log_polling = logs });
        state.phase += 1;
        self.core_phase = state.phase;
        if (done) self.operation = null;
        return done;
    }
    fn permitsAck(self: *RuntimeSequencer, deadline: u64, queue: transport.ring.Queue, offset: usize, bytes: []const u8) bool {
        if (generation(self) != self.epoch or bytes.len != 4 or deadline > self.deadline) return false;
        const execution = if (self.execution) |*value| value else return false;
        if (execution.failed or execution.acknowledged or execution.runner.state != .complete or self.operation != null) return false;
        const owner = self.owner.?;
        if (owner.deadline == null or deadline > owner.deadline.?) return false;
        const ticket = owner.session.pending orelse return false;
        const location = (owner.session.link orelse return false).status_read;
        return std.meta.eql(ticket, self.ticket.?) and queue == location.queue and offset == location.offset and
            std.mem.readInt(u32, bytes[0..4], .little) == ticket.next;
    }
    pub fn step(self: *RuntimeSequencer) !seq.Progress {
        if (self.failed or self.self_address != @intFromPtr(self)) return error.State;
        if (self.complete) return .complete;
        errdefer |err| {
            self.failed = true;
            self.failure = err;
        }
        const execution = if (self.execution) |*value| value else return error.State;
        // Dispatch owns receipt/deadline failures; Runner checks the bound
        // native generation and its phase timeout before every bounded step.
        // Do not preempt that diagnostic with a generic native guard failure.
        const result = try execution.step();
        if (result == .complete) {
            self.complete = true;
            self.device.?.runtime_sequence = null;
        }
        return result;
    }
    /// Dispose only completed metadata or a failed/cancelled dispatch after
    /// the actual native owner established quiescence. This never frees DMA,
    /// acknowledges an event, resumes logs or performs recovery itself.
    pub fn close(self: *RuntimeSequencer) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self)) return false;
        const device = self.device orelse return false;
        if (!self.complete) {
            if (device.runtime_sequence != self) return false;
            const owner = device.owner orelse return false;
            if (!owner.quiesced(owner.context)) return false;
            self.owner.?.session.stop();
            device.runtime_sequence = null;
        }
        self.* = .{};
        return true;
    }
};
