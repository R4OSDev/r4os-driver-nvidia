//! GA106 HS Falcon DMA/PKC execution, shared by GSP FWSEC and SEC2 Booters.
//! Caller owns the completed engine reset, TCM admission, firmware/memory,
//! display recovery and exclusive register writer. Halt is not quiescence or
//! firmware authentication; callers interpret the returned raw mailboxes.
// Adapted from NVIDIA570.144 kernel_gsp_falcon_ga102.c and
// kernel_falcon_tu102.c plus published GA102 register definitions (MIT).
// Original R4OS state/deadline/admission interfaces: Apache-2.0.
// Copyright (c) 2017-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2021-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2003-2021 NVIDIA CORPORATION & AFFILIATES
// Copyright (c) 2017-2021 NVIDIA CORPORATION & AFFILIATES
// Copyright (c) 2003-2022 NVIDIA CORPORATION & AFFILIATES
// Copyright (c) 2003-2024 NVIDIA CORPORATION & AFFILIATES
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
const load = @import("fwsec_load.zig");
pub const Engine = @import("gsp_core.zig").Engine;
pub const reg = struct {
    pub const gsp = 0x110000;
    pub const sec2 = 0x840000;
    pub const fbif_offset = 0x600;
    pub const second_offset = 0x1000;
    pub const fbif_control = 0x24;
    pub const transcfg = 0;
    pub const dma_control = 0x10c;
    pub const dma_base = 0x110;
    pub const dma_base_high = 0x128;
    pub const dma_destination = 0x114;
    pub const dma_source_offset = 0x11c;
    pub const dma_command = 0x118;
    pub const signature = 0x210;
    pub const engine_mask = 0x19c;
    pub const ucode = 0x198;
    pub const algorithm = 0x180;
    pub const boot_vector = 0x104;
    pub const cpu_control = 0x100;
    pub const cpu_alias = 0x130;
    pub const mailbox0 = 0x40;
    pub const mailbox1 = 0x44;
};
pub const bits = struct {
    pub const physical_no_context = 0x80;
    pub const transcfg_mask = 7;
    pub const coherent_physical = 5;
    pub const full = 1;
    pub const idle = 2;
    pub const imem_command = 0x614;
    pub const dmem_command = 0x600;
    pub const rsa3k = 1;
    pub const cpu_alias = 0x40;
    pub const cpu_start = 2;
    pub const cpu_halted = 0x10;
};
pub const Options = struct {
    engine: Engine,
    boot0: u32,
    epoch: u64,
    deadline: u64,
    plan: load.Plan,
    // Limits from the actual reset/TCM owner; these numbers alone do not
    // establish admission. Io.admit must bind them to that same live engine.
    imem_capacity: u32,
    dmem_capacity: u32,
    mailboxes: [2]?u32 = .{ null, null },
};
pub const Io = struct {
    context: *anyopaque,
    generation: *const fn (*anyopaque) u64,
    now_ns: *const fn (*anyopaque) u64,
    // Pure full-operation admission before any effect: exact retained image,
    // completed reset/Falcon selection, actual TCM limits and display/VRAM
    // recovery. Retention and current access policy apply to every write.
    admit: *const fn (*anyopaque, *const Options) anyerror!void,
    read32: *const fn (*anyopaque, u32) anyerror!u32,
    write32: *const fn (*anyopaque, u32, u32) anyerror!void,
};
pub const Result = struct { mailboxes: [2]?u32, blocks: u32 };
pub const Phase = enum {
    admission,
    fbif_control,
    dma_control,
    transcfg,
    base_wait,
    base_low,
    base_high,
    block_wait,
    destination,
    source_offset,
    command,
    idle,
    signature,
    engine_mask,
    ucode,
    algorithm,
    boot_vector,
    mailbox0,
    mailbox1,
    start,
    halt,
    result0,
    result1,
    complete,
};

pub fn validate(options: *const Options) !void {
    if (options.epoch == 0 or options.deadline == 0 or options.deadline == std.math.maxInt(u64)) return error.Options;
    if (((options.boot0 >> 20) & 0x1ff) | ((options.boot0 & 0x100) << 1) != 0x176) return error.Profile;
    const plan = &options.plan;
    const gsp = options.engine == .gsp;
    if (plan.ucode_id != (if (gsp) @as(u8, 9) else 3) or plan.engine_mask != (if (gsp) @as(u16, 0x400) else 1) or
        plan.imem.command != bits.imem_command or plan.dmem.command != bits.dmem_command or
        plan.imem.destination != 0 or plan.dmem.destination != 0 or plan.dmem.source_offset != 0 or
        plan.imem.source_offset != (if (gsp) @as(u32, 0) else 256) or plan.boot_vector != plan.imem.source_offset) return error.Profile;
    for ([_]load.Transfer{ plan.imem, plan.dmem }, [_]u32{ options.imem_capacity, options.dmem_capacity }) |transfer, capacity| {
        if (capacity == 0 or capacity > 0x1000000 or capacity % 256 != 0 or transfer.bytes == 0 or
            transfer.bytes % 256 != 0 or transfer.bytes > capacity) return error.Capacity;
        if (transfer.base == 0 or transfer.base % 256 != 0 or transfer.base > load.dma_mask or
            transfer.source_offset > load.dma_mask - transfer.base or
            @as(u64, transfer.bytes) - 1 > load.dma_mask - transfer.base - transfer.source_offset) return error.Address;
        if (@as(u64, transfer.source_offset) + transfer.bytes > @as(u64, std.math.maxInt(u32)) + 1) return error.Address;
    }
    if (plan.imem.base + plan.imem.source_offset + plan.imem.bytes != plan.dmem.base or
        plan.signature_address % 4 != 0 or @as(u64, plan.signature_address) + 384 > plan.dmem.bytes) return error.Layout;
}
pub const Operation = struct {
    options: Options,
    self_address: usize = 0,
    phase: Phase = .admission,
    part: u1 = 0,
    transferred: u32 = 0,
    result: Result = .{ .mailboxes = .{ null, null }, .blocks = 0 },
    last_clock: u64 = 0,
    last_address: ?u32 = null,
    last_value: ?u32 = null,
    write_attempted: bool = false,
    dma_attempted: bool = false,
    start_attempted: bool = false,
    failure: ?anyerror = null,

    pub fn init(options: Options) !Operation {
        try validate(&options);
        return .{ .options = options };
    }
    pub fn base(self: *const Operation) u32 {
        return if (self.options.engine == .gsp) reg.gsp else reg.sec2;
    }
    fn transfer(self: *const Operation) load.Transfer {
        return if (self.part == 0) self.options.plan.imem else self.options.plan.dmem;
    }
    fn guard(self: *Operation, io: Io) !void {
        if (self.failure != null or self.self_address != @intFromPtr(self)) return error.State;
        if (io.generation(io.context) != self.options.epoch) return error.Stale;
        const now = io.now_ns(io.context);
        if (now == std.math.maxInt(u64) or now < self.last_clock) return error.Clock;
        self.last_clock = now;
        if (now >= self.options.deadline) return error.Deadline;
    }
    fn read(self: *Operation, io: Io, offset: u32, control: bool) !u32 {
        try self.guard(io);
        self.last_address = self.base() + offset;
        self.last_value = null;
        const value = try io.read32(io.context, self.last_address.?);
        self.last_value = value;
        try self.guard(io);
        if (control and (value == 0xffffffff or value & 0xffff0000 == 0xbadf0000 or value & 0xffff0000 == 0xffff0000)) return error.RegisterUnavailable;
        return value;
    }
    fn write(self: *Operation, io: Io, offset: u32, value: u32) !void {
        try self.guard(io);
        self.last_address = self.base() + offset;
        self.last_value = value;
        self.write_attempted = true;
        try io.write32(io.context, self.last_address.?, value);
        try self.guard(io);
    }
    /// Exactly one bounded phase per call, including one sample for each
    /// poll. Caller schedules the next step without extending the deadline.
    /// Moving a started operation or replaying a failed one is rejected.
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
        const plan = &self.options.plan;
        const part = self.transfer();
        switch (self.phase) {
            .admission => {
                try validate(&self.options);
                try io.admit(io.context, &self.options);
                self.phase = .fbif_control;
            },
            .fbif_control => {
                const value = try self.read(io, reg.fbif_offset + reg.fbif_control, true);
                try self.write(io, reg.fbif_offset + reg.fbif_control, value | bits.physical_no_context);
                self.phase = .dma_control;
            },
            .dma_control => {
                try self.write(io, reg.dma_control, 0);
                self.phase = .transcfg;
            },
            .transcfg => {
                const value = try self.read(io, reg.fbif_offset + reg.transcfg, true);
                try self.write(io, reg.fbif_offset + reg.transcfg, (value & ~@as(u32, bits.transcfg_mask)) | bits.coherent_physical);
                self.phase = .base_wait;
            },
            .base_wait => if (try self.read(io, reg.dma_command, true) & bits.full == 0) {
                self.phase = .base_low;
            },
            .base_low => {
                try self.write(io, reg.dma_base, @truncate(part.base >> 8));
                self.phase = .base_high;
            },
            .base_high => {
                try self.write(io, reg.dma_base_high, @intCast((part.base >> 40) & 0x1ff));
                self.phase = .block_wait;
            },
            .block_wait => if (try self.read(io, reg.dma_command, true) & bits.full == 0) {
                self.phase = .destination;
            },
            .destination => {
                try self.write(io, reg.dma_destination, part.destination + self.transferred);
                self.phase = .source_offset;
            },
            .source_offset => {
                try self.write(io, reg.dma_source_offset, part.source_offset + self.transferred);
                self.phase = .command;
            },
            .command => {
                self.dma_attempted = true;
                try self.write(io, reg.dma_command, part.command);
                self.transferred += 256;
                self.result.blocks += 1;
                self.phase = if (self.transferred == part.bytes) .idle else .block_wait;
            },
            .idle => if (try self.read(io, reg.dma_command, true) & bits.idle != 0) {
                if (self.part == 0) {
                    self.part = 1;
                    self.transferred = 0;
                    self.phase = .base_wait;
                } else self.phase = .signature;
            },
            .signature => {
                try self.write(io, reg.second_offset + reg.signature, plan.signature_address);
                self.phase = .engine_mask;
            },
            .engine_mask => {
                try self.write(io, reg.second_offset + reg.engine_mask, plan.engine_mask);
                self.phase = .ucode;
            },
            .ucode => {
                try self.write(io, reg.second_offset + reg.ucode, plan.ucode_id);
                self.phase = .algorithm;
            },
            .algorithm => {
                try self.write(io, reg.second_offset + reg.algorithm, bits.rsa3k);
                self.phase = .boot_vector;
            },
            .boot_vector => {
                try self.write(io, reg.boot_vector, plan.boot_vector);
                self.phase = .mailbox0;
            },
            .mailbox0 => {
                if (self.options.mailboxes[0]) |value| try self.write(io, reg.mailbox0, value);
                self.phase = .mailbox1;
            },
            .mailbox1 => {
                if (self.options.mailboxes[1]) |value| try self.write(io, reg.mailbox1, value);
                self.phase = .start;
            },
            .start => {
                const value = try self.read(io, reg.cpu_control, true);
                self.start_attempted = true;
                try self.write(io, if (value & bits.cpu_alias != 0) reg.cpu_alias else reg.cpu_control, bits.cpu_start);
                self.phase = .halt;
            },
            .halt => if (try self.read(io, reg.cpu_control, true) & bits.cpu_halted != 0) {
                self.phase = .result0;
            },
            .result0 => {
                if (self.options.mailboxes[0] != null) self.result.mailboxes[0] = try self.read(io, reg.mailbox0, false);
                self.phase = .result1;
            },
            .result1 => {
                if (self.options.mailboxes[1] != null) self.result.mailboxes[1] = try self.read(io, reg.mailbox1, false);
                self.phase = .complete;
            },
            .complete => {},
        }
        try self.guard(io);
        return self.phase == .complete;
    }
};
