// C67A cursor methods and GA102 PIO registers (MIT). R4OS owner policy: Apache-2.0.
// ExFiles/Reference/GFX/Nvidia/OpenKernelModules-570.144/src/common/sdk/nvidia/inc/class/clc67a.h
// ExFiles/Reference/GFX/Nvidia/OpenKernelModules-570.144/src/nvidia-modeset/src/nvkms-cursor3.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2020 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
//  * SPDX-FileCopyrightText: Copyright (c) 2016 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// ExFiles/Reference/GFX/Nvidia/OpenGpuDoc/manuals/ampere/ga102/dev_display_withoffset.ref.txt
// Copyright (c) 2021, NVIDIA CORPORATION. All rights reserved.
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
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
// 
// ExFiles/Reference/GFX/Nvidia/Nouveau/drivers/gpu/drm/nouveau/dispnv50/cursc37a.c
// /*
//  * Copyright 2018 Red Hat Inc.
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
//! Dedicated C67A PIO cursor position state, serialized by Device's worker.
//! Drained methods plus a newer real head event are separate from image
//! activation and never complete a common-copy or Window fence.
const std = @import("std");
const head = @import("gsp_head_events.zig");
pub const Error = error{ Busy, Bounds, State, Stale, Exhausted, Completion, Timeout };
pub const Point = struct {
    x: i16, y: i16,
    pub fn encode(self: Point) u32 { return @as(u32, @as(u16, @bitCast(self.x))) | (@as(u32, @as(u16, @bitCast(self.y))) << 16); }
};
pub const Sample = struct { free: u32, control: u32, state: u32 };
pub const Receipt = struct { sequence: u64, point: Point, submitted_ns: u64, drained_ns: u64, head: head.Sample };
pub const Job = struct {
    sequence: u64, point: Point, point_stamp: Point, deadline: u64,
    submitted_ns: u64 = 0, update_submitted_ns: u64 = 0, baseline: head.Sample = .{}, published: bool = false,
    next_method: u8 = 0,
};
pub const Owner = struct {
    issued: u64 = 0,
    pending: ?Job = null,
    completed: ?Receipt = null,

    pub fn begin(self: *Owner, x: i32, y: i32, now: u64, deadline: u64) Error!u64 {
        if (self.pending != null) return error.Busy;
        if (now == 0 or deadline <= now) return error.Timeout;
        if (self.issued == std.math.maxInt(u64)) return error.Exhausted;
        const point: Point = .{ .x = std.math.cast(i16, x) orelse return error.Bounds, .y = std.math.cast(i16, y) orelse return error.Bounds };
        self.pending = .{ .sequence = self.issued + 1, .point = point, .point_stamp = point, .deadline = deadline };
        return self.issued + 1;
    }
    pub fn valid(self: *const Owner, deadline: u64) bool {
        const job = self.pending orelse return false;
        return job.deadline == deadline and job.sequence != 0 and job.next_method <= methods.len and
            (job.published or job.next_method == 0) and std.meta.eql(job.point, job.point_stamp) and
            (if (job.published) job.sequence == self.issued and job.submitted_ns != 0 else job.sequence == self.issued +| 1);
    }
    pub fn prepare(self: *Owner, now: u64, observed: head.Sample) Error!void {
        const job = if (self.pending) |*pending| pending else return error.State;
        if (!self.valid(job.deadline) or job.published) return error.Stale;
        if (now == 0 or now >= job.deadline or observed.observed_ns > now) return error.Timeout;
        job.submitted_ns = now; job.baseline = observed;
    }
    fn publish(self: *Owner, deadline: u64) Error!void {
        if (!self.valid(deadline)) return error.Stale;
        const job = &self.pending.?;
        if (job.published or job.submitted_ns == 0) return error.State;
        // Before the first possibly partial MMIO write. Never replay UPDATE.
        job.published = true; self.issued = job.sequence;
    }
    pub fn prepareUpdate(self: *Owner, now: u64, observed: head.Sample) Error!void {
        const job = if (self.pending) |*pending| pending else return error.State;
        if (!self.valid(job.deadline) or !job.published or job.next_method != methods.len-1) return error.Stale;
        if (now == 0 or now >= job.deadline or now < job.submitted_ns or observed.observed_ns > now) return error.Timeout;
        job.update_submitted_ns = now; job.baseline = observed;
    }
    /// Called immediately before one possibly partial MMIO write. Each
    /// method owns its own FREE credit; its prefix must never be replayed.
    pub fn issueMethod(self: *Owner, deadline: u64) Error!usize {
        if (!self.valid(deadline)) return error.Stale;
        if (self.pending.?.next_method >= methods.len) return error.State;
        if (self.pending.?.next_method == methods.len-1 and self.pending.?.update_submitted_ns == 0) return error.State;
        if (!self.pending.?.published) try self.publish(deadline);
        const index = self.pending.?.next_method;
        self.pending.?.next_method += 1;
        return index;
    }
    pub fn observe(self: *Owner, sample: Sample, observed: head.Sample, now: u64) Error!bool {
        const job = self.pending orelse return error.State;
        if (!self.valid(job.deadline) or !job.published) return error.Stale;
        if (now >= job.deadline) return error.Timeout;
        if (job.next_method != methods.len or job.update_submitted_ns == 0 or !try idle(sample) or
            observed.sequence <= job.baseline.sequence or observed.observed_ns < job.update_submitted_ns) return false;
        if (observed.observed_ns > now) return false;
        self.completed = .{ .sequence = job.sequence, .point = job.point, .submitted_ns = job.submitted_ns, .drained_ns = now, .head = observed };
        self.pending = null; return true;
    }
};
pub fn base(index: u32) Error!u32 { if (index >= 8) return error.Bounds; return 0x6d8000 + index * 4096; }
// Exact MoveCursorC3 from NVIDIA570.144 nvkms-cursor3.c: position then
// UPDATE with no flip lock. RELEASE_ELV is a distinct owner operation.
pub const methods = [_]u32{ 0x208, 0x200 };
pub fn value(point: Point, index: usize) u32 { return switch (index) { 0 => point.encode(), 1 => 0, else => unreachable }; }
pub fn writable(sample: Sample) Error!bool {
    if (sample.free == 0xffffffff or sample.control == 0xffffffff or sample.state == 0xffffffff) return error.Completion;
    if (sample.state & 0xf == 1) return error.Completion; // MP_STATE_PBERR.
    // NVIDIA's WaitForFreeSpace applies before each method, including the
    // UPDATE which drains its prepared position. Processing state is not
    // a completion receipt and must not block that final method.
    return sample.free & 0x3f != 0 and sample.control & 0x11 == 1;
}
pub fn idle(sample: Sample) Error!bool {
    // Allocated and unlocked, empty PIO method processor and no method
    // execution. FREE alone is never evidence of position visibility.
    return try writable(sample) and sample.state & 0x8007000f == 0x40000;
}
