//! One admitted GA106 firmware execution: engine reset, actual TCM observation,
//! HS upload/start/halt. Caller owns exact retained memory and display recovery.
//! Completion returns raw mailboxes, not authentication or GPU quiescence.
// Original R4OS composition/lifetime: Apache-2.0. HWCFG capacity calculation
// follows Nouveau nvkm_falcon_oneinit (nvkm/falcon/base.c), under MIT:
// Copyright (c) 2016, NVIDIA CORPORATION. All rights reserved.
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
const core = @import("gsp_core.zig");
const hs = @import("falcon_hs.zig");
const load = @import("fwsec_load.zig");
pub const hwcfg_offset = 0x108;
pub const max_tcm_bytes = 0x1ff00;
pub const Options = struct {
    engine: core.Engine,
    boot0: u32,
    epoch: u64,
    deadline: u64,
    plan: load.Plan,
    mailboxes: [2]?u32 = .{ null, null },

    fn upload(self: *const Options, hwcfg: u32) hs.Options {
        return .{ .engine = self.engine, .boot0 = self.boot0, .epoch = self.epoch, .deadline = self.deadline, .plan = self.plan, .mailboxes = self.mailboxes, .imem_capacity = (hwcfg & 0x1ff) << 8, .dmem_capacity = (hwcfg & 0x3fe00) >> 1 };
    }
};
pub const Io = struct {
    context: *anyopaque,
    generation: *const fn (*anyopaque) u64,
    now_ns: *const fn (*anyopaque) u64,
    // Pure whole-run admission: exact retained firmware/DMA and exclusive
    // VRAM/VGA/display recovery. Reset and TCM are performed by this owner,
    // never accepted as a caller-provided success bit or capacity number.
    admit: *const fn (*anyopaque, *const Options) anyerror!void,
    read32: *const fn (*anyopaque, u32) anyerror!u32,
    write32: *const fn (*anyopaque, u32, u32) anyerror!void,
};
pub const Phase = enum { admission, reset, hwcfg, status, engine, core_select, stable_hwcfg, upload, complete };
pub const Operation = struct {
    options: Options,
    reset: core.Operation,
    hs_operation: ?hs.Operation = null,
    phase: Phase = .admission,
    self_address: usize = 0,
    last_clock: u64 = 0,
    last_address: ?u32 = null,
    last_value: ?u32 = null,
    hwcfg: u32 = 0,
    hwcfg2: u32 = 0,
    result: ?hs.Result = null,
    failure: ?anyerror = null,

    pub fn init(options: Options) !Operation {
        // Reject the whole malformed transfer before even resetting hardware.
        // Actual (possibly smaller) capacities are read after reset completes.
        var upload = options.upload(0x3ffff);
        upload.imem_capacity = max_tcm_bytes;
        upload.dmem_capacity = max_tcm_bytes;
        try hs.validate(&upload);
        return .{ .options = options, .reset = try core.Operation.initReset(options.engine, options.epoch, options.deadline, options.boot0) };
    }
    pub fn base(self: *const Operation) u32 {
        return if (self.options.engine == .gsp) hs.reg.gsp else hs.reg.sec2;
    }
    fn guard(self: *Operation, io: Io) !void {
        if (self.failure != null or self.self_address != @intFromPtr(self)) return error.State;
        if (io.generation(io.context) != self.options.epoch) return error.Stale;
        const now = io.now_ns(io.context);
        if (now == std.math.maxInt(u64) or now < self.last_clock) return error.Clock;
        self.last_clock = now;
        if (now >= self.options.deadline) return error.Deadline;
    }
    fn read(self: *Operation, io: Io, offset: u32) !u32 {
        try self.guard(io);
        self.last_address = self.base() + offset;
        self.last_value = null;
        const value = try io.read32(io.context, self.last_address.?);
        self.last_value = value;
        try self.guard(io);
        if (value == 0xffffffff or value & 0xffff0000 == 0xbadf0000 or value & 0xffff0000 == 0xffff0000) return error.RegisterUnavailable;
        return value;
    }
    // The nested HS executor uses this same stable operation's proven reset
    // and post-reset observations. All actual reads/writes still go through
    // the caller's live device owner; a temporary adapter is call-local only.
    const Adapter = struct { operation: *Operation, io: Io };
    fn cast(p: *anyopaque) *Adapter {
        return @ptrCast(@alignCast(p));
    }
    fn generation(p: *anyopaque) u64 {
        const a = cast(p);
        return a.io.generation(a.io.context);
    }
    fn nowNs(p: *anyopaque) u64 {
        const a = cast(p);
        return a.io.now_ns(a.io.context);
    }
    fn read32(p: *anyopaque, address: u32) anyerror!u32 {
        const a = cast(p);
        return a.io.read32(a.io.context, address);
    }
    fn write32(p: *anyopaque, address: u32, value: u32) anyerror!void {
        const a = cast(p);
        return a.io.write32(a.io.context, address, value);
    }
    fn admitUpload(p: *anyopaque, options: *const hs.Options) anyerror!void {
        const a = cast(p);
        const self = a.operation;
        try self.guard(a.io);
        if (self.phase != .upload or self.reset.phase != .complete or self.reset.failure != null or
            !self.reset.write_attempted or self.reset.reset_engine != self.options.engine or
            self.reset.epoch != options.epoch or self.reset.deadline != options.deadline or
            !std.meta.eql(options.*, self.options.upload(self.hwcfg))) return error.State;
    }
    pub fn step(self: *Operation, io: Io) !bool {
        if (self.self_address == 0) self.self_address = @intFromPtr(self);
        if (self.self_address != @intFromPtr(self)) return error.State;
        return self.advance(io) catch |err| {
            self.failure = err;
            return err;
        };
    }
    fn advance(self: *Operation, io: Io) !bool {
        try self.guard(io);
        switch (self.phase) {
            .admission => {
                try io.admit(io.context, &self.options);
                self.phase = .reset;
            },
            .reset => {
                if (try self.reset.step(.{ .context = io.context, .generation = io.generation, .now_ns = io.now_ns, .read32 = io.read32, .write32 = io.write32 })) self.phase = .hwcfg;
            },
            .hwcfg => {
                self.hwcfg = try self.read(io, hwcfg_offset);
                self.phase = .status;
            },
            .status => {
                self.hwcfg2 = try self.read(io, 0xf4);
                if (self.hwcfg2 & core.bits.scrubbing != 0) return error.EngineState;
                self.phase = .engine;
            },
            .engine => {
                if (try self.read(io, 0x3c0) & core.bits.reset != 0) return error.EngineState;
                self.phase = if (self.hwcfg2 & core.bits.riscv_enabled == 0) .stable_hwcfg else .core_select;
            },
            .core_select => {
                const value = try self.read(io, 0x1668);
                // NVIDIA only waits for VALID after writing a core switch.
                // An engine already in Falcon mode may retain reset's VALID=0.
                if (value & core.bits.bcr_riscv != 0 or
                    (self.reset.core_switch_written and value & core.bits.bcr_valid == 0)) return error.EngineState;
                self.phase = .stable_hwcfg;
            },
            .stable_hwcfg => {
                if (try self.read(io, hwcfg_offset) != self.hwcfg) return error.Unstable;
                self.hs_operation = try hs.Operation.init(self.options.upload(self.hwcfg));
                self.phase = .upload;
            },
            .upload => {
                var adapter: Adapter = .{ .operation = self, .io = io };
                const operation = &self.hs_operation.?;
                if (try operation.step(.{ .context = &adapter, .generation = generation, .now_ns = nowNs, .admit = admitUpload, .read32 = read32, .write32 = write32 })) {
                    self.result = operation.result;
                    self.phase = .complete;
                }
            },
            .complete => {},
        }
        try self.guard(io);
        return self.phase == .complete;
    }
};
