//! GA106 RM570.144 sequencer core commands and SEC2 Falcon reset.
//! One bounded phase per call. The caller retains the native device, firmware,
//! DMA, display recovery and MMIO owners; completion is NOT GPU quiescence.
// Adapted from NVIDIA kernel_falcon_{tu102,ga102}.c, kernel_gsp_{tu102,ga102}.c
// and the GA102 register headers. NVIDIA portions: MIT; R4OS owner: Apache-2.0.
// Copyright (c) 2017-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2021-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2003-2021 NVIDIA CORPORATION & AFFILIATES
// Copyright (c) 2017-2021 NVIDIA CORPORATION & AFFILIATES
// Copyright (c) 2003-2022 NVIDIA CORPORATION & AFFILIATES
// Copyright (c) 2003-2024 NVIDIA CORPORATION & AFFILIATES
// Copyright (c) 2021-2023 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
const seq = @import("gsp_sequencer.zig");
pub const Engine = enum { gsp, sec2 };

// Compared with the complete original C headers by the existing ABI verifier.
pub const reg = struct {
    pub const hwcfg2 = 0x1100f4;
    pub const engine = 0x1103c0;
    pub const rm = 0x110084;
    pub const fbif = 0x110624;
    pub const dmactl = 0x11010c;
    pub const cpuctl = 0x110100;
    pub const cpuctl_alias = 0x110130;
    pub const bcr = 0x111668;
    pub const riscv_cpuctl = 0x111388;
    pub const mailbox0 = 0x110040;
    pub const mailbox1 = 0x110044;
    pub const os = 0x110080;
    pub const sec_cpuctl = 0x840100;
    pub const sec_cpuctl_alias = 0x840130;
    pub const sec_mailbox0 = 0x840040;
    pub const sec_hwcfg2 = 0x8400f4;
    pub const sec_engine = 0x8403c0;
    pub const sec_rm = 0x840084;
    pub const sec_fbif = 0x840624;
    pub const sec_dmactl = 0x84010c;
    pub const sec_bcr = 0x841668;
    pub const handoff = 0x1180f8;
};
pub const bits = struct {
    pub const reset_ready = 0x80000000;
    pub const scrubbing = 0x1000;
    pub const riscv_enabled = 0x400;
    pub const reset = 1;
    pub const allow_phys = 0x80;
    pub const start = 2;
    pub const alias = 0x40;
    pub const halted = 0x10;
    pub const bcr_riscv = 0x10;
    pub const bcr_valid = 1;
    pub const bcr_boot = 0x111;
    pub const active = 0x80;
    pub const handoff_done = 0x4000000;
};
pub const propagation_reads = 10;
pub const pre_reset_ns = 150 * std.time.ns_per_us;
pub const Resume = struct {
    // Admitted, retained GPU DMA address of the Libos init page, not its CPU VA.
    libos_dma: u64,
    app_version: u32,
};
pub const Io = struct {
    context: *anyopaque,
    generation: *const fn (*anyopaque) u64,
    now_ns: *const fn (*anyopaque) u64,
    read32: *const fn (*anyopaque, u32) anyerror!u32,
    write32: *const fn (*anyopaque, u32, u32) anyerror!void,
    // Required for resume: serialize with the actual log reader. A failed
    // resume leaves logs suspended; no cleanup callback runs automatically.
    log_polling: ?*const fn (*anyopaque, bool) anyerror!void = null,
};
pub const Phase = enum {
    suspend_logs,
    pre_reset,
    assert_reset,
    propagate_assert,
    release_reset,
    propagate_release,
    scrub,
    select_core,
    select_falcon,
    wait_falcon,
    rm,
    fbif,
    dmactl,
    start,
    halt,
    boot_low,
    boot_high,
    sec_start,
    handoff,
    sec_result,
    restore_logs,
    os,
    active,
    complete,
};
pub const Operation = struct {
    opcode: seq.Opcode,
    reset_engine: Engine = .gsp,
    epoch: u64,
    deadline: u64,
    boot0: u32,
    resume_args: ?Resume,
    phase: Phase,
    last_clock: u64 = 0,
    hint_deadline: ?u64 = null,
    reads: u8 = 0,
    last_address: ?u32 = null,
    last_value: ?u32 = null,
    write_attempted: bool = false,
    core_switch_written: bool = false,
    logs_suspended: bool = false,
    failure: ?anyerror = null,

    pub fn init(op: seq.Opcode, epoch: u64, deadline: u64, boot0: u32, resume_args: ?Resume) !Operation {
        if (epoch == 0 or deadline == 0 or deadline == std.math.maxInt(u64)) return error.Options;
        if (((boot0 >> 20) & 0x1ff) | ((boot0 & 0x100) << 1) != 0x176) return error.Profile;
        const phase: Phase = switch (op) {
            .core_reset => .pre_reset,
            .core_start => .start,
            .core_halt => .halt,
            .core_resume => .suspend_logs,
            else => return error.Opcode,
        };
        if (op == .core_resume) {
            const r = resume_args orelse return error.Resume;
            if (r.libos_dma == 0 or r.libos_dma % 4096 != 0 or r.libos_dma > std.math.maxInt(u64) - 4096) return error.Resume;
        }
        return .{ .opcode = op, .epoch = epoch, .deadline = deadline, .boot0 = boot0, .resume_args = resume_args, .phase = phase };
    }
    /// GA106 dispatch uses the same Falcon reset phases for both engines.
    /// SEC2's hardware reset is ksec2ResetHw_TU102, with the same ten reads
    /// per edge. Sequencer start/halt/resume retain their original targets.
    pub fn initReset(engine: Engine, epoch: u64, deadline: u64, boot0: u32) !Operation {
        var operation = try init(.core_reset, epoch, deadline, boot0, null);
        operation.reset_engine = engine;
        return operation;
    }
    fn register(self: *const Operation, address: u32) !u32 {
        if (self.reset_engine == .gsp) return address;
        if (self.opcode != .core_reset) return error.Opcode;
        return switch (address) {
            reg.hwcfg2 => reg.sec_hwcfg2,
            reg.engine => reg.sec_engine,
            reg.rm => reg.sec_rm,
            reg.fbif => reg.sec_fbif,
            reg.dmactl => reg.sec_dmactl,
            reg.bcr => reg.sec_bcr,
            else => error.Register,
        };
    }
    fn guard(self: *Operation, io: Io) !u64 {
        if (self.failure != null) return error.State;
        if (io.generation(io.context) != self.epoch) return error.Stale;
        const now = io.now_ns(io.context);
        if (now == std.math.maxInt(u64) or now < self.last_clock) return error.Clock;
        self.last_clock = now;
        if (now >= self.deadline) return error.Deadline;
        return now;
    }
    fn read(self: *Operation, io: Io, address: u32) !u32 {
        _ = try self.guard(io);
        self.last_address = try self.register(address);
        self.last_value = null;
        const value = try io.read32(io.context, self.last_address.?);
        self.last_value = value;
        _ = try self.guard(io);
        // These control/status registers cannot use PCI/PRIV read-error
        // patterns as valid completion. Never turn a lost GPU into success.
        if (value == 0xffffffff or value & 0xffff0000 == 0xbadf0000 or value & 0xffff0000 == 0xffff0000) return error.RegisterUnavailable;
        return value;
    }
    fn write(self: *Operation, io: Io, address: u32, value: u32) !void {
        _ = try self.guard(io);
        self.last_address = try self.register(address);
        self.last_value = value;
        self.write_attempted = true;
        try io.write32(io.context, self.last_address.?, value);
        _ = try self.guard(io);
    }
    fn startCpu(self: *Operation, io: Io, control: u32, alias: u32) !void {
        const value = try self.read(io, control);
        // ALIAS is write-only. Do not read it back to flush a posted write.
        try self.write(io, if (value & bits.alias != 0) alias else control, bits.start);
    }
    fn logs(self: *Operation, io: Io, enable: bool) !void {
        _ = try self.guard(io);
        const callback = io.log_polling orelse return error.Resume;
        if (!enable) self.logs_suspended = true;
        try callback(io.context, enable);
        if (enable) self.logs_suspended = false;
        _ = try self.guard(io);
    }
    pub fn step(self: *Operation, io: Io) !bool {
        if (self.failure != null) return error.State;
        if (self.phase == .complete) return true;
        return self.advance(io) catch |err| {
            self.failure = err;
            return err;
        };
    }
    fn advance(self: *Operation, io: Io) !bool {
        const now = try self.guard(io);
        switch (self.phase) {
            .suspend_logs => {
                try self.logs(io, false);
                self.phase = .pre_reset;
            },
            .pre_reset => {
                if (self.hint_deadline == null) self.hint_deadline = now + @min(pre_reset_ns, self.deadline - now);
                const value = try self.read(io, reg.hwcfg2);
                if (self.opcode == .core_resume and value & bits.riscv_enabled == 0) return error.Resume;
                // RESET_READY is only a hint: bug 3419321 allows proceeding
                // after 150 us, even when the bit never becomes set.
                if (value & bits.reset_ready != 0 or self.last_clock >= self.hint_deadline.?) self.phase = .assert_reset;
            },
            .assert_reset => {
                const value = try self.read(io, reg.engine);
                try self.write(io, reg.engine, value | bits.reset);
                self.reads = 0;
                self.phase = .propagate_assert;
            },
            .propagate_assert, .propagate_release => {
                _ = try self.read(io, reg.engine);
                self.reads += 1;
                if (self.reads == propagation_reads) self.phase = if (self.phase == .propagate_assert) .release_reset else .scrub;
            },
            .release_reset => {
                const value = try self.read(io, reg.engine);
                try self.write(io, reg.engine, value & ~@as(u32, bits.reset));
                self.reads = 0;
                self.phase = .propagate_release;
            },
            .scrub => {
                const value = try self.read(io, reg.hwcfg2);
                if (value & bits.scrubbing == 0) self.phase = .select_core;
            },
            .select_core => {
                if (self.opcode == .core_resume) {
                    try self.write(io, reg.bcr, bits.bcr_boot);
                    self.phase = .boot_low;
                } else {
                    const value = try self.read(io, reg.hwcfg2);
                    self.phase = if (value & bits.riscv_enabled == 0) .rm else .select_falcon;
                }
            },
            .select_falcon => {
                const value = try self.read(io, reg.bcr);
                if (value & bits.bcr_riscv == 0) {
                    self.phase = .rm;
                } else {
                    // Only after reset was released and scrubbing completed
                    // (bug 200586493). Preserve the vendor full-register write.
                    self.core_switch_written = true;
                    try self.write(io, reg.bcr, 0);
                    self.phase = .wait_falcon;
                }
            },
            .wait_falcon => if (try self.read(io, reg.bcr) & bits.bcr_valid != 0) {
                self.phase = .rm;
            },
            .rm => {
                try self.write(io, reg.rm, self.boot0);
                self.phase = .fbif;
            },
            .fbif => {
                const value = try self.read(io, reg.fbif);
                try self.write(io, reg.fbif, value | bits.allow_phys);
                self.phase = .dmactl;
            },
            .dmactl => {
                try self.write(io, reg.dmactl, 0);
                self.phase = .complete;
            },
            .start => {
                try self.startCpu(io, reg.cpuctl, reg.cpuctl_alias);
                self.phase = .complete;
            },
            .halt => if (try self.read(io, reg.cpuctl) & bits.halted != 0) {
                self.phase = .complete;
            },
            .boot_low => {
                try self.write(io, reg.mailbox0, @truncate(self.resume_args.?.libos_dma));
                self.phase = .boot_high;
            },
            .boot_high => {
                try self.write(io, reg.mailbox1, @truncate(self.resume_args.?.libos_dma >> 32));
                self.phase = .sec_start;
            },
            .sec_start => {
                try self.startCpu(io, reg.sec_cpuctl, reg.sec_cpuctl_alias);
                self.phase = .handoff;
            },
            .handoff => if (try self.read(io, reg.handoff) & bits.handoff_done != 0) {
                self.phase = .sec_result;
            },
            .sec_result => {
                if (try self.read(io, reg.sec_mailbox0) != 0) return error.SecMailbox;
                self.phase = .restore_logs;
            },
            .restore_logs => {
                try self.logs(io, true);
                self.phase = .os;
            },
            .os => {
                try self.write(io, reg.os, self.resume_args.?.app_version);
                self.phase = .active;
            },
            .active => {
                if (try self.read(io, reg.riscv_cpuctl) & bits.active == 0) return error.NotActive;
                self.phase = .complete;
            },
            .complete => unreachable,
        }
        _ = try self.guard(io);
        return self.phase == .complete;
    }
};
