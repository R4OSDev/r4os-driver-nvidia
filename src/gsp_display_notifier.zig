// Derived display protocol portions: MIT, original sources/notices below.
//
// Original/Nvidia570144/src/nvidia-modeset/src/nvkms-rm.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2013-2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//
// Original/Nvidia570144/src/nvidia-modeset/src/nvkms-dma.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 1993-2013 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//
// Original/Nvidia570144/src/common/sdk/nvidia/inc/class/clc67d.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2020 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//! Private coherent display notifier. The display-table owner retains both
//! CPU mapping and physical DMA residency for the complete hardware lifetime.
//! NVIDIA nvkms-rm.c/nvkms-dma.c permit SYS pushbuffer and notifier pairs;
//! the GA106 implementation never accesses these fields through BAR1.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const storage = @import("gsp_display_storage.zig");
pub const Error = storage.Error || error{State, Stale, Bounds, Completion};
pub const Phase = enum { ready, armed, submitted, complete, failed };
pub const Result = struct { word: u32, timestamp: u64 };
pub const Owner = struct {
    self_address: usize = 0,
    backing: storage.Storage = .{},
    cpu: a.GfxBufferMap = .{},
    cpu_stamp: a.GfxBufferMap = .{},
    physical_stamp: u64 = 0,
    handle: u32 = 0,
    channel: u32 = 0,
    epoch: u64 = 0,
    phase: Phase = .ready,
    point: u64 = 0,
    deadline: u64 = 0,
    result: ?Result = null,
    failed: bool = false,

    pub fn open(self: *Owner, ctx: *const r4os.r4dev.DriverContext, adapter: u32, epoch: u64, channel: u32, handle: u32) Error!void {
        if (self.self_address != 0) return error.Busy;
        if (epoch == 0 or channel > 8 or handle == 0) return error.Bounds;
        self.self_address = @intFromPtr(self); self.handle = handle; self.channel = channel; self.epoch = epoch;
        self.prepare(ctx, adapter) catch |err| {
            if (err == error.Descriptor or err == error.Retained or !self.closeUnpublished()) { self.quarantine(); return error.Retained; }
            return err;
        };
    }
    fn prepare(self: *Owner, ctx: *const r4os.r4dev.DriverContext, adapter: u32) Error!void {
        try self.backing.prepareRole(ctx, adapter, self.epoch, .notifier);
        self.physical_stamp = self.backing.physical() orelse return error.Stale;
        const result = self.backing.memory.?.bufferMap(&self.backing.reference.reference, a.gfx_buffer_map_write, 0, storage.bytes, &self.cpu);
        self.cpu_stamp = self.cpu;
        if (result != a.gfx_buffer_result_ok and self.cpu.lease.id == 0) return error.Map;
        const cpu = self.cpu;
        if (cpu.version != 1 or cpu.size < @sizeOf(a.GfxBufferMap) or cpu.lease.id == 0 or cpu.lease.generation == 0 or cpu.lease.reserved0 != 0 or
            cpu.cpu_address == 0 or cpu.cpu_address & 4095 != 0 or cpu.cpu_address > std.math.maxInt(u64) - storage.bytes or
            cpu.byte_length != storage.bytes or cpu.cache_policy != a.gfx_buffer_cache_write_back or cpu.reserved0 != 0) return error.Descriptor;
        if (result != a.gfx_buffer_result_ok) return error.Map;
        for (0..4) |i| if (self.word(i).* != 0) return error.Descriptor;
    }
    pub fn valid(self: *const Owner) bool {
        return self.self_address == @intFromPtr(self) and !self.failed and self.epoch != 0 and self.backing.epoch == self.epoch and
            self.backing.role == .notifier and self.backing.physical() == self.physical_stamp and self.physical_stamp != 0 and
            self.cpu.lease.id != 0 and std.meta.eql(self.cpu, self.cpu_stamp);
    }
    fn word(self: *const Owner, index: usize) *volatile u32 { return @ptrFromInt(self.cpu.cpu_address + index * 4); }
    pub fn arm(self: *Owner, point: u64, deadline: u64) Error!void {
        if (!self.valid()) return error.Stale;
        if ((self.phase != .ready and self.phase != .complete) or point == 0 or point <= self.point or deadline == 0 or deadline == std.math.maxInt(u64)) return error.State;
        // The previous operation must already have a hardware completion.
        // This exact private mapping has no independent CPU writer.
        for (0..4) |i| self.word(i).* = 0;
        fence(); self.point = point; self.deadline = deadline; self.result = null; self.phase = .armed;
    }
    pub fn submitted(self: *Owner, point: u64, deadline: u64) Error!void {
        if (!self.valid() or self.phase != .armed or self.point != point or self.deadline != deadline) return error.Stale;
        self.phase = .submitted;
    }
    pub fn poll(self: *Owner) Error!?Result {
        if (!self.valid() or self.phase != .submitted) return error.State;
        const first = self.word(0).*; fence();
        const status = first >> 30;
        if (status == 3) return error.Completion;
        if (status != 2) return null;
        const lo = self.word(2).*; const hi = self.word(3).*; fence();
        if (self.word(0).* != first) return null;
        self.result = .{ .word = first, .timestamp = (@as(u64, hi) << 32) | lo };
        self.phase = .complete; return self.result;
    }
    pub fn quarantine(self: *Owner) void { self.failed = true; self.phase = .failed; self.backing.retained = true; }
    /// Only an unpublished table may abandon this allocation. There is no
    /// equivalent release from channel Free or CPU-only shutdown.
    pub fn closeUnpublished(self: *Owner) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or self.backing.retained or self.phase == .submitted or self.failed) return false;
        if (self.cpu.lease.id != 0) {
            if (!std.meta.eql(self.cpu, self.cpu_stamp) or self.backing.memory.?.bufferUnmap(&self.cpu.lease) != a.gfx_buffer_result_ok) return false;
            self.cpu = .{}; self.cpu_stamp = .{};
        }
        if (!self.backing.close()) return false;
        self.* = .{}; return true;
    }
};
pub fn fence() void { asm volatile ("mfence" ::: .{ .memory = true }); }
