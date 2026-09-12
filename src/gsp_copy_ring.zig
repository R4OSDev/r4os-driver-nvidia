// NVIDIA570.144/src/common/sdk/nvidia/inc/class/clc6b5.h
// /*******************************************************************************
//     Copyright (c) 2020, NVIDIA CORPORATION. All rights reserved.
// 
//     Permission is hereby granted, free of charge, to any person obtaining a
//     copy of this software and associated documentation files (the "Software"),
//     to deal in the Software without restriction, including without limitation
//     the rights to use, copy, modify, merge, publish, distribute, sublicense,
//     and/or sell copies of the Software, and to permit persons to whom the
//     Software is furnished to do so, subject to the following conditions:
// 
//     The above copyright notice and this permission notice shall be included in
//     all copies or substantial portions of the Software.
// 
//     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//     IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//     FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
//     THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//     LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//     FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//     DEALINGS IN THE SOFTWARE.
// 
// *******************************************************************************/
// NVIDIA570.144/src/common/sdk/nvidia/inc/class/clc6b5sw.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2018-2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// NVIDIA570.144/kernel-open/nvidia-uvm/uvm_volta_host.c
// /*******************************************************************************
//     Copyright (c) 2016-2024 NVIDIA Corporation
// 
//     Permission is hereby granted, free of charge, to any person obtaining a copy
//     of this software and associated documentation files (the "Software"), to
//     deal in the Software without restriction, including without limitation the
//     rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
//     sell copies of the Software, and to permit persons to whom the Software is
//     furnished to do so, subject to the following conditions:
// 
//         The above copyright notice and this permission notice shall be
//         included in all copies or substantial portions of the Software.
// 
//     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//     IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//     FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
//     THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//     LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//     FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//     DEALINGS IN THE SOFTWARE.
// 
// *******************************************************************************/
// NVIDIA570.144/kernel-open/nvidia-uvm/uvm_maxwell_ce.c
// /*******************************************************************************
//     Copyright (c) 2021-2023 NVIDIA Corporation
// 
//     Permission is hereby granted, free of charge, to any person obtaining a copy
//     of this software and associated documentation files (the "Software"), to
//     deal in the Software without restriction, including without limitation the
//     rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
//     sell copies of the Software, and to permit persons to whom the Software is
//     furnished to do so, subject to the following conditions:
// 
//         The above copyright notice and this permission notice shall be
//         included in all copies or substantial portions of the Software.
// 
//     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//     IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//     FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
//     THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//     LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//     FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//     DEALINGS IN THE SOFTWARE.
// 
// *******************************************************************************/
// ExFiles/Reference/GFX/Nvidia/Nouveau/drivers/gpu/drm/nouveau/nvkm/subdev/vfn/base.c
// /*
//  * Copyright 2021 Red Hat Inc.
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
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
//  * THE COPYRIGHT HOLDER(S) OR AUTHOR(S) BE LIABLE FOR ANY CLAIM, DAMAGES OR
//  * OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
//  * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  * OTHER DEALINGS IN THE SOFTWARE.
//  */
//! One private, persistently mapped WB command BO. Residency is held by FIFO;
//! this owner governs concurrent CPU/GPU fields and never uses GPGet as a fence.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const storage = @import("gsp_control_storage.zig");
pub const wire = @import("gsp_copy_wire.zig");
pub const Error = wire.Error || storage.Error || error{ Stale, State, Exhausted, Completion, Retained };
pub const Ticket = struct { owner: usize, epoch: u64, channel: u32, token: u32, point: u32, put: u32 };
pub const Ring = struct {
    self_address: usize = 0,
    backing: ?*storage.Storage = null,
    cpu: a.GfxBufferMap = .{},
    cpu_stamp: a.GfxBufferMap = .{},
    address: u64 = 0,
    issued: u32 = 0,
    completed: u32 = 0,
    put: u32 = 0,
    pending: ?Ticket = null,
    published: bool = false,
    failed: bool = false,

    pub fn open(self: *Ring, backing: *storage.Storage, address: u64) Error!void {
        if (self.self_address != 0 or !backing.gpuReady(address)) return error.State;
        try wire.extent(address, 12288, 40);
        try wire.extent(backing.pages[2], 4096, 40);
        self.* = .{ .self_address = @intFromPtr(self), .backing = backing, .address = address };
        if (backing.memory.?.bufferMap(&backing.reference.reference, a.gfx_buffer_map_write, 0, 12288, &self.cpu) != a.gfx_buffer_result_ok) {
            if (self.cpu.lease.id != 0) { self.failed = true; return error.Descriptor; }
            self.* = .{}; return error.Map;
        }
        const mapped = self.cpu;
        if (mapped.version != 1 or mapped.size < @sizeOf(a.GfxBufferMap) or mapped.lease.id == 0 or mapped.lease.generation == 0 or
            mapped.lease.reserved0 != 0 or mapped.cpu_address == 0 or mapped.cpu_address & 4095 != 0 or
            mapped.cpu_address > std.math.maxInt(u64) - 12288 or mapped.byte_length != 12288 or
            mapped.cache_policy != a.gfx_buffer_cache_write_back or mapped.reserved0 != 0) { self.failed = true; return error.Descriptor; }
        self.cpu_stamp = mapped;
        // Storage zeroed and unmapped this private BO before its RM allocation.
        // Do not clear it again once the channel can access USERD.
        if (self.word(wire.put_offset).* != 0 or self.word(wire.completion_offset).* != 0) { self.failed = true; return error.Descriptor; }
    }
    pub fn valid(self: *const Ring) bool {
        return self.self_address == @intFromPtr(self) and self.backing != null and !self.failed and
            self.backing.?.gpuReady(self.address) and self.cpu.lease.id != 0 and std.meta.eql(self.cpu, self.cpu_stamp);
    }
    fn word(self: *const Ring, offset: usize) *volatile u32 { return @ptrFromInt(self.cpu.cpu_address + offset); }
    pub fn fence() void { asm volatile ("mfence" ::: .{ .memory = true }); }
    pub fn prepare(self: *Ring, class: u32, channel_handle: u32, token: u32, transfer: wire.Transfer) Error!Ticket {
        if (!self.valid()) return error.Stale;
        if (self.pending != null or self.issued - self.completed >= wire.capacity) return error.Busy;
        const point = std.math.add(u32, self.issued, 1) catch return error.Exhausted;
        const push = wire.push_offset + (self.issued % wire.capacity) * wire.slot_bytes;
        const commands = try wire.encode(class, transfer, self.address + wire.completion_offset, point);
        const gp = try wire.entry(self.address + push);
        for (commands, 0..) |value, i| self.word(push + i * 4).* = value;
        self.word(self.put * 8).* = gp[0]; self.word(self.put * 8 + 4).* = gp[1];
        const ticket: Ticket = .{ .owner = @intFromPtr(self), .epoch = self.backing.?.epoch,
            .channel = channel_handle, .token = token, .point = point, .put = (self.put + 1) % 512 };
        self.pending = ticket; return ticket;
    }
    pub fn matches(self: *const Ring, ticket: Ticket) bool {
        return self.valid() and self.pending != null and std.meta.eql(self.pending.?, ticket) and !self.published;
    }
    pub fn publish(self: *Ring, ticket: Ticket) Error!void {
        if (!self.matches(ticket)) return error.Stale;
        // Private producer accepts SYS memory only: no CPU BAR1 writes belong
        // to this submission. A future BAR1 producer also needs UVM's BAR1 read.
        fence(); self.published = true; self.issued = ticket.point; self.put = ticket.put;
        self.word(wire.put_offset).* = ticket.put; fence();
    }
    pub fn notified(self: *Ring, ticket: Ticket) Error!void {
        if (!self.valid() or !self.published or self.pending == null or !std.meta.eql(self.pending.?, ticket)) return error.Stale;
        self.pending = null; self.published = false;
    }
    pub fn poll(self: *Ring) Error!u32 {
        if (!self.valid()) return error.Stale;
        const point = self.word(wire.completion_offset).*; fence();
        if (point < self.completed or point > self.issued) { self.failed = true; return error.Completion; }
        self.completed = point; return point;
    }
    pub fn idle(self: *const Ring) bool { return self.valid() and self.pending == null and self.issued == self.completed; }
    pub fn close(self: *Ring) bool {
        if (self.self_address == 0) return true;
        if (!self.idle() or self.backing.?.memory.?.bufferUnmap(&self.cpu.lease) != a.gfx_buffer_result_ok) return false;
        self.* = .{}; return true;
    }
};
