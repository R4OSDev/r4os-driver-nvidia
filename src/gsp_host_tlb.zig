// src/nvidia/src/kernel/gpu/mmu/arch/turing/kern_gmmu_tu102.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2021-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// src/common/inc/swref/published/turing/tu102/dev_vm.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2003-2023 NVIDIA CORPORATION & AFFILIATES
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
//! Bounded Turing/Ampere PF invalidate with SYS_MEMBAR and global ACK.
//! A completed receipt concerns translation retirement for one held PDB;
//! callers must separately prove that all users of the removed mapping ended.
const page = @import("gsp_host_page.zig");
pub const pf_base: u32 = 0xb80000;
pub const pdb_low: u32 = pf_base + 0x30a0;
pub const pdb_high: u32 = pf_base + 0x30a4;
pub const invalidate: u32 = pf_base + 0x30b0;
pub const trigger: u32 = 0x80000000;
pub const command: u32 = trigger | 0xc1;
pub const Error = page.Error || error{ State, Stale, Deadline, Register, Io };
pub const Io = struct {
    context: *anyopaque,
    generation: *const fn (*anyopaque) u64,
    now_ns: *const fn (*anyopaque) u64,
    read32: *const fn (*anyopaque, u32) anyerror!u32,
    write32: *const fn (*anyopaque, u32, u32) anyerror!void,
};
pub const Receipt = struct { owner: usize, epoch: u64, root_dma: u64, serial: u64 };
pub const Phase = enum { idle, low, high, verify_low, verify_high, publish, waiting, final_low, final_high, done, failed };
pub fn words(root_dma: u64) Error![2]u32 {
    _ = try page.directory(root_dma);
    return .{ @as(u32, @truncate(root_dma >> 8)) | 2, @intCast(root_dma >> 40) };
}
pub const Operation = struct {
    self_address: usize = 0,
    epoch: u64,
    root_dma: u64,
    serial: u64,
    deadline: u64,
    last_time: u64 = 0,
    phase: Phase = .idle,
    effects_possible: bool = false,
    failure: ?Error = null,

    pub fn init(epoch: u64, root_dma: u64, serial: u64, deadline: u64) Error!Operation {
        if (epoch == 0 or serial == 0 or deadline == 0) return error.State;
        _ = try words(root_dma);
        return .{ .epoch = epoch, .root_dma = root_dma, .serial = serial, .deadline = deadline };
    }
    fn guard(self: *const Operation, io: Io) Error!void {
        if (self.self_address != @intFromPtr(self) or io.generation(io.context) != self.epoch) return error.Stale;
        const now = io.now_ns(io.context);
        if (now < self.last_time or now >= self.deadline) return error.Deadline;
    }
    pub fn step(self: *Operation, io: Io) Error!bool {
        if (self.self_address != 0 and self.self_address != @intFromPtr(self)) return error.Stale;
        if (self.phase == .failed or self.phase == .done) return error.State;
        self.self_address = @intFromPtr(self);
        return self.advance(io) catch |err| {
            self.failure = err;
            self.phase = .failed;
            return err;
        };
    }
    fn read(io: Io, address: u32) Error!u32 {
        const value = io.read32(io.context, address) catch return error.Io;
        if (value == 0xffffffff) return error.Register;
        return value;
    }
    fn write(self: *Operation, io: Io, address: u32, value: u32) Error!void {
        self.effects_possible = true; // A failed write may already be visible.
        io.write32(io.context, address, value) catch return error.Io;
    }
    fn advance(self: *Operation, io: Io) Error!bool {
        try self.guard(io);
        self.last_time = io.now_ns(io.context);
        const address = try words(self.root_dma);
        switch (self.phase) {
            .idle => if (try read(io, invalidate) & trigger == 0) { self.phase = .low; },
            .low => { try self.write(io, pdb_low, address[0]); self.phase = .high; },
            .high => { try self.write(io, pdb_high, address[1]); self.phase = .verify_low; },
            .verify_low => {
                if (try read(io, pdb_low) != address[0]) return error.Register;
                self.phase = .verify_high;
            },
            .verify_high => {
                if (try read(io, pdb_high) != address[1]) return error.Register;
                self.phase = .publish;
            },
            .publish => {
                // Private coherent table writes precede this UC MMIO command.
                asm volatile ("mfence" ::: .{ .memory = true });
                try self.write(io, invalidate, command);
                self.phase = .waiting;
            },
            .waiting => if (try read(io, invalidate) & trigger == 0) { self.phase = .final_low; },
            .final_low => {
                if (try read(io, pdb_low) != address[0]) return error.Register;
                self.phase = .final_high;
            },
            .final_high => {
                if (try read(io, pdb_high) != address[1]) return error.Register;
                self.phase = .done;
            },
            .done, .failed => return error.State,
        }
        try self.guard(io);
        self.last_time = io.now_ns(io.context);
        return self.phase == .done;
    }
    pub fn receipt(self: *const Operation, io: Io) ?Receipt {
        if (self.self_address != @intFromPtr(self) or self.phase != .done or self.failure != null or !self.effects_possible) return null;
        self.guard(io) catch return null;
        return .{ .owner = self.self_address, .epoch = self.epoch, .root_dma = self.root_dma, .serial = self.serial };
    }
};
