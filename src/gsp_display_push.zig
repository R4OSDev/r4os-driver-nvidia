// Derived display protocol portions: MIT, original sources/notices below.
//
// Original/Nouveau/dispnv50/disp.c
// /*
//  * Copyright 2011 Red Hat Inc.
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
//  *
//  * Authors: Ben Skeggs
//  */
//
// Original/Nouveau/nvkm/subdev/gsp/rm/r535/disp.c
// /*
//  * Copyright 2023 Red Hat Inc.
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
//
// Original/Nouveau/include/nvhw/class/clc37b.h
// /*
//  * Copyright (c) 1993-2017, NVIDIA CORPORATION. All rights reserved.
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
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  * DEALINGS IN THE SOFTWARE.
//  */
//
// Original/Nouveau/include/nvhw/class/cl507c.h
// /*
//  * Copyright (c) 1993-2014, NVIDIA CORPORATION. All rights reserved.
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
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  * DEALINGS IN THE SOFTWARE.
//  */
//! Private physical display command producer. A single bounded operation
//! uses the GA106 PUT/GET protocol; notifier completion is separate from GET.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const storage = @import("gsp_display_storage.zig");
pub const commands = @import("gsp_display_commands.zig");
const channel_wire = @import("gsp_display_channel_wire.zig");
const notifier = @import("gsp_display_notifier.zig");
pub const Error = storage.Error || commands.Error || error{State, Stale, Completion, Exhausted};
pub const Kind = enum { rewind, frame };
pub const jump_zero: u32 = 0x20000000;
pub const Ticket = struct { owner: usize, epoch: u64, channel: u32, point: u64, kind: Kind, start: u16, put: u16 };
pub const Ring = struct {
    self_address: usize = 0,
    backing: ?*storage.Storage = null,
    binding: ?channel_wire.Config = null,
    binding_stamp: ?channel_wire.Config = null,
    cpu: a.GfxBufferMap = .{},
    cpu_stamp: a.GfxBufferMap = .{},
    put: u16 = 0,
    issued: u64 = 0,
    completed: u64 = 0,
    initialized: bool = false,
    pending: ?Ticket = null,
    program: ?commands.Program = null,
    published: bool = false,
    failed: bool = false,

    pub fn open(self: *Ring, backing: *storage.Storage, binding: channel_wire.Config) Error!void {
        if (self.self_address != 0) return error.Busy;
        if (binding.kind != .core or binding.index != 0 or backing.role != .pushbuffer or !backing.retained or
            backing.physical() != binding.physical or backing.epoch != binding.root.epoch) return error.State;
        self.* = .{ .self_address = @intFromPtr(self), .backing = backing, .binding = binding, .binding_stamp = binding };
        const status = backing.memory.?.bufferMap(&backing.reference.reference, a.gfx_buffer_map_write, 0, storage.bytes, &self.cpu);
        self.cpu_stamp = self.cpu;
        if (status != a.gfx_buffer_result_ok and self.cpu.lease.id == 0) { self.* = .{}; return error.Map; }
        const cpu = self.cpu;
        if (cpu.version != 1 or cpu.size < @sizeOf(a.GfxBufferMap) or cpu.lease.id == 0 or cpu.lease.generation == 0 or cpu.lease.reserved0 != 0 or
            cpu.cpu_address == 0 or cpu.cpu_address & 4095 != 0 or cpu.cpu_address > std.math.maxInt(u64) - storage.bytes or
            cpu.byte_length != storage.bytes or cpu.cache_policy != a.gfx_buffer_cache_write_back or cpu.reserved0 != 0 or status != a.gfx_buffer_result_ok) {
            self.failed = true; return error.Descriptor;
        }
    }
    pub fn valid(self: *const Ring) bool {
        return self.self_address == @intFromPtr(self) and !self.failed and self.backing != null and self.binding != null and
            std.meta.eql(self.binding, self.binding_stamp) and self.backing.?.retained and self.backing.?.role == .pushbuffer and
            self.backing.?.physical() == self.binding.?.physical and self.backing.?.epoch == self.binding.?.root.epoch and
            self.cpu.lease.id != 0 and std.meta.eql(self.cpu, self.cpu_stamp) and self.put < 1023;
    }
    fn word(self: *const Ring, index: usize) *volatile u32 { return @ptrFromInt(self.cpu.cpu_address + index * 4); }
    pub fn prepare(self: *Ring, get: u16, config: commands.Config) Error!Ticket {
        if (!self.valid()) return error.Stale;
        if (self.pending != null or self.issued != self.completed or get != self.put) return error.Busy;
        if (config.initialize == self.initialized) return error.State;
        const program = try commands.core(config);
        const point = std.math.add(u64, self.issued, 1) catch return error.Exhausted;
        var ticket: Ticket = .{ .owner = @intFromPtr(self), .epoch = self.binding.?.root.epoch,
            .channel = self.binding.?.handle, .point = point, .kind = .frame, .start = self.put, .put = self.put + program.count };
        if (ticket.put >= 1023) {
            // Prior GET==PUT above is nonzero here: the hardware has left
            // the beginning. Publish JUMP0/PUT0 first, then await GET0 before
            // filling and publishing the new beginning, as Nouveau does.
            if (self.put == 0) return error.Bounds;
            self.word(self.put).* = jump_zero;
            ticket.kind = .rewind; ticket.put = 0;
            self.program = null;
        } else {
            for (program.words[0..program.count], 0..) |value, i| self.word(self.put + i).* = value;
            self.program = program;
        }
        notifier.fence(); self.pending = ticket; return ticket;
    }
    pub fn matches(self: *const Ring, ticket: Ticket, config: commands.Config) bool {
        if (!self.valid() or self.published or self.pending == null or !std.meta.eql(self.pending.?, ticket) or config.initialize == self.initialized) return false;
        notifier.fence();
        if (ticket.kind == .rewind) return self.program == null and ticket.start == self.put and ticket.put == 0 and self.word(ticket.start).* == jump_zero;
        const expected = commands.core(config) catch return false;
        if (self.program == null or !commands.same(self.program.?, expected) or ticket.start != self.put or ticket.put != ticket.start + expected.count) return false;
        for (expected.words[0..expected.count], 0..) |value, i| if (self.word(ticket.start + i).* != value) return false;
        return true;
    }
    pub fn publish(self: *Ring, ticket: Ticket, config: commands.Config) Error!void {
        if (!self.matches(ticket, config)) return error.Stale;
        // Publish ownership before a possibly partial MMIO callback.
        notifier.fence(); self.published = true; self.put = ticket.put;
        if (ticket.kind == .frame) self.issued = ticket.point;
    }
    pub fn rewound(self: *Ring, get: u16) Error!bool {
        if (!self.valid() or !self.published or self.pending == null or self.pending.?.kind != .rewind) return error.State;
        if (get != 0) return false;
        self.pending = null; self.published = false; return true;
    }
    pub fn finish(self: *Ring, point: u64) Error!void {
        if (!self.valid() or !self.published or self.pending == null or self.pending.?.kind != .frame or
            self.pending.?.point != point or self.issued != point) return error.Stale;
        self.completed = point; self.initialized = true; self.pending = null; self.published = false; self.program = null;
    }
    /// Physical channel retirement, not the notifier or GET, authorizes
    /// relinquishing this permanently mapped private command allocation.
    pub fn close(self: *Ring, retired: bool) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or !retired or self.backing == null or self.cpu.lease.id == 0 or !std.meta.eql(self.cpu, self.cpu_stamp)) return false;
        if (self.backing.?.memory.?.bufferUnmap(&self.cpu.lease) != a.gfx_buffer_result_ok) return false;
        self.* = .{}; return true;
    }
};
pub fn userBase(kind: channel_wire.Kind, index: u32) Error!u32 {
    return switch (kind) { .core => if (index == 0) 0x680000 else error.Bounds, .window => if (index < 8) 0x690000 + index * 4096 else error.Bounds };
}
pub fn cursor(raw: u32) Error!u16 {
    if (raw & ~@as(u32, 0xffc) != 0) return error.Completion;
    return @intCast(raw >> 2);
}
