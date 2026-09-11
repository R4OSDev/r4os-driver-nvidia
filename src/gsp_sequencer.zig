//! Cooperative CPU execution of a completely admitted GSP sequencer record.
//! One execution owner retains commands, MMIO ownership and DMA until genuine
//! device quiescence. No allocation, busy wait, automatic event ACK or reset on
//! failure. The native port is responsible for the actual architecture effects.
// Opcodes/semantics from NVIDIA570.144 rmgspseq.h and kernel_gsp.c; timeout
// units/default from gpu_timeout.h/gpu_timeout.c. NVIDIA portions: MIT.
// Original R4OS admission, port, scheduling and failure policy: Apache-2.0.
// Copyright (c) 2019-2020 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2019-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 1993-2023 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
const std = @import("std");
const events = @import("gsp_boot_events.zig");
const exchange = @import("gsp_exchange.zig");
const message = @import("gsp_message.zig");
pub const Error = error{ Profile, Options, Payload, Opcode, Register, Slot, Denied, Unsupported, State, Stale, Clock, Deadline, Timeout, Io };
pub const Opcode = enum(u32) { write = 0, modify, poll, delay_us, store, core_reset, core_start, core_halt, core_resume };
pub const Write = struct { address: u32, value: u32 };
pub const Modify = struct { address: u32, mask: u32, value: u32 };
pub const Poll = struct { address: u32, mask: u32, value: u32, timeout_us: u32, error_code: u32 };
pub const Store = struct { address: u32, index: u32 };
pub const Command = union(Opcode) {
    write: Write,
    modify: Modify,
    poll: Poll,
    delay_us: u32,
    store: Store,
    core_reset: void,
    core_start: void,
    core_halt: void,
    core_resume: void,
};
pub const Instruction = struct { command: Command, next: usize };
fn word(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
pub fn decode(commands: []const u8, offset: usize) Error!Instruction {
    if (commands.len > message.max_payload_bytes - 40 or commands.len % 4 != 0 or
        offset % 4 != 0 or offset >= commands.len) return error.Payload;
    const opcode = std.enums.fromInt(Opcode, word(commands, offset)) orelse return error.Opcode;
    const words: usize = switch (opcode) {
        .write, .store => 3,
        .modify => 4,
        .poll => 6,
        .delay_us => 2,
        else => 1,
    };
    if (words * 4 > commands.len - offset) return error.Payload;
    const p = commands[offset + 4 ..];
    const command: Command = switch (opcode) {
        .write => .{ .write = .{ .address = word(p, 0), .value = word(p, 4) } },
        .modify => .{ .modify = .{ .address = word(p, 0), .mask = word(p, 4), .value = word(p, 8) } },
        .poll => .{ .poll = .{ .address = word(p, 0), .mask = word(p, 4), .value = word(p, 8), .timeout_us = word(p, 12), .error_code = word(p, 16) } },
        .delay_us => .{ .delay_us = word(p, 0) },
        .store => .{ .store = .{ .address = word(p, 0), .index = word(p, 4) } },
        .core_reset => .core_reset,
        .core_start => .core_start,
        .core_halt => .core_halt,
        .core_resume => .core_resume,
    };
    return .{ .command = command, .next = offset + words * 4 };
}
pub const Options = struct {
    profile: message.Profile,
    epoch: u64,
    deadline_ns: u64,
    default_timeout_ns: u64,
    poll_interval_ns: u64,
    register_bytes: u64,
};
pub const CoreState = struct { phase: u32 = 0 };
pub const Port = struct {
    context: *anyopaque,
    generation: *const fn (*anyopaque) u64,
    now_ns: *const fn (*anyopaque) u64,
    // Pure admission for every instruction BEFORE any read/write/core action.
    // Same epoch must retain mapping, range policy, recovery and device owners.
    admit: *const fn (*anyopaque, Command) error{ Denied, Unsupported }!void,
    // Complete the architecture-required ordering/posted-write flush before
    // returning. Failure can follow an already performed register side effect.
    read32: *const fn (*anyopaque, u32) anyerror!u32,
    write32: *const fn (*anyopaque, u32, u32) anyerror!void,
    // Optional architecture executor; absence refuses all core opcodes before
    // earlier commands can run. One bounded phase per call, no internal polling
    // loop. It must advance phase to avoid replaying submitted effects; false
    // means more work, true means the actual operation completed. A false return
    // does not mean nothing happened. GA106 CORE_RESUME needs SEC2 and retained
    // boot arguments; it cannot be replaced by a generic Falcon start.
    core_step: ?*const fn (*anyopaque, Opcode, *CoreState, u64, *const [8]u32) anyerror!bool = null,
};
pub const State = enum { active, complete, failed };
pub const Progress = union(enum) { advanced, wait_until: u64, complete };
pub const Failure = struct { reason: Error, word_index: usize, opcode: ?Opcode, vendor_error: u32, last_value: ?u32, callback_error: ?anyerror };
pub const Runner = struct {
    port: Port,
    options: Options,
    commands: []const u8,
    saved: [8]u32,
    state: State = .active,
    offset: usize = 0,
    phase_deadline: ?u64 = null,
    delay_until: ?u64 = null,
    core: CoreState = .{},
    last_clock: u64 = 0,
    failure: ?Failure = null,
    callback_error: ?anyerror = null,
    last_value: ?u32 = null,

    /// Commands must remain a stable immutable CPU snapshot (for example the
    /// unacknowledged Boot dispatch). This value and the port have one owner;
    /// no rebinding or replay within the same device run is permitted.
    pub fn init(seq: events.Sequencer, port: Port, options: Options) Error!Runner {
        if (options.profile.chip_id != 0x176 or options.profile.confidential_compute) return error.Profile;
        if (options.epoch == 0 or options.deadline_ns == std.math.maxInt(u64) or
            options.default_timeout_ns == 0 or options.default_timeout_ns == std.math.maxInt(u64) or
            options.poll_interval_ns == 0 or options.poll_interval_ns == std.math.maxInt(u64) or
            options.register_bytes < 4 or options.register_bytes > 0x100000000 or options.register_bytes % 4 != 0) return error.Options;
        if (seq.commands.len % 4 != 0 or seq.commands.len > message.max_payload_bytes - 40 or
            seq.capacity_words == 0 or seq.capacity_words > (message.max_payload_bytes - 40) / 4 or
            seq.commands.len / 4 >= seq.capacity_words) return error.Payload;
        var self = Runner{ .port = port, .options = options, .commands = seq.commands, .saved = seq.saved };
        _ = try self.guard();
        // Admit the entire stream, including late unknown opcodes/unsupported
        // architecture effects, before the first register side effect.
        var required_delay: u64 = 0;
        while (self.offset < self.commands.len) {
            const instruction = try decode(self.commands, self.offset);
            const command = instruction.command;
            switch (command) {
                .write => |p| try self.address(p.address),
                .modify => |p| try self.address(p.address),
                .poll => |p| {
                    try self.address(p.address);
                    if (p.value & ~p.mask != 0) return error.Payload;
                },
                .store => |p| {
                    try self.address(p.address);
                    if (p.index >= self.saved.len) return error.Slot;
                },
                .delay_us => |us| required_delay = std.math.add(u64, required_delay, @as(u64, us) * std.time.ns_per_us) catch return error.Deadline,
                else => if (port.core_step == null) return error.Unsupported,
            }
            _ = try self.guard();
            try port.admit(port.context, command);
            _ = try self.guard();
            self.offset = instruction.next;
        }
        // An impossible mandatory delay must not leave earlier register writes
        // behind. Poll/core worst-case time is deliberately not added here.
        if (required_delay >= options.deadline_ns - self.last_clock) return error.Deadline;
        self.offset = 0;
        return self;
    }
    fn address(self: *const Runner, offset: u32) Error!void {
        if (offset % 4 != 0 or offset > self.options.register_bytes - 4) return error.Register;
    }
    fn fail(self: *Runner, reason: Error) Error {
        self.stop(reason);
        return reason;
    }
    fn stop(self: *Runner, reason: Error) void {
        const instruction = decode(self.commands, self.offset) catch null;
        self.failure = .{
            .reason = reason,
            .word_index = self.offset / 4,
            .opcode = if (instruction) |i| std.meta.activeTag(i.command) else null,
            .vendor_error = if (instruction) |i| if (i.command == .poll) i.command.poll.error_code else 0 else 0,
            .last_value = self.last_value,
            .callback_error = self.callback_error,
        };
        self.state = .failed;
    }
    fn guard(self: *Runner) Error!u64 {
        if (self.state == .failed) return error.State;
        if (self.port.generation(self.port.context) != self.options.epoch) return self.fail(error.Stale);
        const now = self.port.now_ns(self.port.context);
        if (now == std.math.maxInt(u64) or now < self.last_clock) return self.fail(error.Clock);
        self.last_clock = now;
        if (now >= self.options.deadline_ns) return self.fail(error.Deadline);
        if (self.phase_deadline) |phase_end| if (now >= phase_end) return self.fail(error.Timeout);
        return now;
    }
    fn read(self: *Runner, offset: u32) Error!u32 {
        _ = try self.guard();
        const value = self.port.read32(self.port.context, offset) catch |err| {
            self.callback_error = err;
            return self.fail(error.Io);
        };
        self.last_value = value;
        _ = try self.guard();
        return value;
    }
    fn write(self: *Runner, offset: u32, value: u32) Error!void {
        _ = try self.guard();
        self.port.write32(self.port.context, offset, value) catch |err| {
            self.callback_error = err;
            return self.fail(error.Io);
        };
        _ = try self.guard();
    }
    fn limit(self: *const Runner, now: u64, duration: u64) u64 {
        return now + @min(duration, self.options.deadline_ns - now);
    }
    fn waiting(self: *const Runner, now: u64) Progress {
        return .{ .wait_until = @min(self.limit(now, self.options.poll_interval_ns), self.phase_deadline orelse self.options.deadline_ns) };
    }
    fn advance(self: *Runner, next: usize) Progress {
        self.offset = next;
        self.phase_deadline = null;
        self.delay_until = null;
        self.core = .{};
        self.last_value = null;
        if (next == self.commands.len) {
            self.state = .complete;
            return .complete;
        }
        return .advanced;
    }

    /// At most one instruction, one poll sample or one architecture phase.
    /// Register modify has exactly one read then one write, preserving the
    /// original (old & ~mask) | value semantics, including value outside mask.
    /// Callers reschedule wait_until; this routine never sleeps or spins.
    pub fn step(self: *Runner) Error!Progress {
        if (self.state == .complete) return .complete;
        const now = try self.guard();
        if (self.offset == self.commands.len) return self.advance(self.offset);
        const instruction = decode(self.commands, self.offset) catch |err| return self.fail(err);
        switch (instruction.command) {
            .write => |p| try self.write(p.address, p.value),
            .modify => |p| {
                const value = try self.read(p.address);
                try self.write(p.address, (value & ~p.mask) | p.value);
            },
            .store => |p| self.saved[p.index] = try self.read(p.address),
            .poll => |p| {
                if (self.phase_deadline == null) {
                    // The executed NVIDIA timeoutSet ABI takes microseconds,
                    // despite rmgspseq.h's old "MS" comment. Zero uses the
                    // enclosing driver's default, always capped by boot TTL.
                    const duration = if (p.timeout_us == 0) self.options.default_timeout_ns else @as(u64, p.timeout_us) * std.time.ns_per_us;
                    self.phase_deadline = self.limit(now, duration);
                }
                if ((try self.read(p.address)) & p.mask != p.value) return self.waiting(self.last_clock);
            },
            .delay_us => |us| {
                if (self.delay_until == null) {
                    const duration = @as(u64, us) * std.time.ns_per_us;
                    if (duration >= self.options.deadline_ns - now) return self.fail(error.Deadline);
                    self.delay_until = now + duration;
                }
                if (now < self.delay_until.?) return .{ .wait_until = self.delay_until.? };
            },
            else => {
                if (self.phase_deadline == null) self.phase_deadline = self.limit(now, self.options.default_timeout_ns);
                _ = try self.guard();
                const done = self.port.core_step.?(self.port.context, std.meta.activeTag(instruction.command), &self.core, self.phase_deadline.?, &self.saved) catch |err| {
                    self.callback_error = err;
                    return self.fail(error.Io);
                };
                _ = try self.guard();
                if (!done) return self.waiting(self.last_clock);
            },
        }
        return self.advance(instruction.next);
    }
};

pub const DispatchError = Error || events.Error || exchange.Error;
pub const Limits = struct { default_timeout_ns: u64, poll_interval_ns: u64, register_bytes: u64 };
const Source = union(enum) {
    boot: *events.Boot,
    runtime: *exchange.Exchange,

    fn session(self: Source) *@import("gsp_transport.zig").Session {
        return switch (self) {
            .boot => |owner| owner.session,
            .runtime => |owner| owner.session,
        };
    }
    fn deadline(self: Source) DispatchError!u64 {
        return switch (self) {
            .boot => |owner| owner.deadline,
            .runtime => |owner| owner.deadline orelse error.State,
        };
    }
    fn borrow(self: Source, ticket: @import("gsp_transport.zig").Ticket) DispatchError!events.Sequencer {
        const event = switch (self) {
            .boot => |owner| (try owner.borrow(ticket)).event,
            .runtime => |owner| blk: {
                const dispatch = try owner.borrow(ticket);
                if (dispatch.response or dispatch.record.rpc.function != @intFromEnum(events.Kind.cpu_sequencer)) return error.State;
                break :blk try events.decode(dispatch.record);
            },
        };
        if (event != .cpu_sequencer) return error.State;
        return event.cpu_sequencer;
    }
    fn complete(self: Source, ticket: @import("gsp_transport.zig").Ticket) DispatchError!void {
        return switch (self) {
            .boot => |owner| owner.complete(ticket),
            .runtime => |owner| owner.complete(ticket),
        };
    }
    fn reject(self: Source, ticket: @import("gsp_transport.zig").Ticket) void {
        switch (self) {
            .boot => |owner| owner.reject(ticket) catch {},
            .runtime => |owner| owner.reject(ticket) catch {},
        }
    }
};
pub const DispatchExecution = struct {
    source: Source,
    ticket: @import("gsp_transport.zig").Ticket,
    runner: Runner,
    acknowledged: bool = false,
    failed: bool = false,

    /// The device port must use the same retained run epoch as the boot queue.
    /// CPU sequencer execution borrows its immutable pending payload. Admission
    /// failure rejects it without any hardware effect or queue acknowledgement.
    pub fn init(boot: *events.Boot, port: Port, limits: Limits) DispatchError!DispatchExecution {
        const pending = boot.pending orelse return error.State;
        const dispatch = try boot.borrow(pending.ticket);
        if (dispatch.event != .cpu_sequencer) return error.State;
        return initSource(.{ .boot = boot }, pending.ticket, port, limits);
    }
    /// The runtime exchange owns the same receipt and possibly an outstanding
    /// RM request. No nested receive/send or second queue pump is introduced.
    pub fn initRuntime(owner: *exchange.Exchange, port: Port, limits: Limits) DispatchError!DispatchExecution {
        const pending = owner.pending orelse return error.State;
        if (pending.response or pending.record.rpc.function != @intFromEnum(events.Kind.cpu_sequencer)) return error.State;
        return initSource(.{ .runtime = owner }, pending.ticket, port, limits);
    }
    fn initSource(source: Source, ticket: @import("gsp_transport.zig").Ticket, port: Port, limits: Limits) DispatchError!DispatchExecution {
        errdefer source.reject(ticket);
        const stream = try source.borrow(ticket);
        const session = source.session();
        const runner = try Runner.init(stream, port, .{
            .profile = session.profile,
            .epoch = session.epoch,
            .deadline_ns = try source.deadline(),
            .default_timeout_ns = limits.default_timeout_ns,
            .poll_interval_ns = limits.poll_interval_ns,
            .register_bytes = limits.register_bytes,
        });
        return .{ .source = source, .ticket = ticket, .runner = runner };
    }
    /// Advance one bounded step, retaining the exact source receipt throughout. The
    /// queue ACK occurs exactly once, after the real port completed ALL effects.
    /// On failure, keep runner/dispatch diagnostics and let the native lifetime
    /// owner establish quiescence/recovery. Never replay effects to retry ACK.
    pub fn step(self: *DispatchExecution) DispatchError!Progress {
        if (self.failed) return error.State;
        if (self.acknowledged) return .complete;
        _ = self.source.borrow(self.ticket) catch |err| {
            self.failed = true;
            self.runner.callback_error = err;
            self.runner.stop(error.State);
            self.source.reject(self.ticket);
            return err;
        };
        // A pending exchange can tighten its current budget. It cannot renew
        // an admitted stream or a poll/core phase; mandatory delays stay whole.
        const deadline = self.source.deadline() catch |err| {
            self.failed = true;
            self.runner.callback_error = err;
            self.runner.stop(error.State);
            self.source.reject(self.ticket);
            return err;
        };
        self.runner.options.deadline_ns = @min(self.runner.options.deadline_ns, deadline);
        if (self.runner.phase_deadline) |limit| self.runner.phase_deadline = @min(limit, self.runner.options.deadline_ns);
        const result = self.runner.step() catch |err| {
            self.failed = true;
            self.source.reject(self.ticket);
            return err;
        };
        if (result == .complete) {
            self.source.complete(self.ticket) catch |err| {
                self.failed = true;
                // Hardware effects completed; acknowledgement may already
                // be visible. Preserve completion, never execute it again.
                return err;
            };
            self.acknowledged = true;
        }
        return if (result == .wait_until) .{ .wait_until = @min(result.wait_until, self.runner.options.deadline_ns) } else result;
    }
};
