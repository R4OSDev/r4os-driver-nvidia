// src/common/sdk/nvidia/inc/nvos.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 1993-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// src/common/sdk/nvidia/inc/class/cl0040.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2001-2001 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// src/nvidia/src/kernel/mem_mgr/video_mem.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2020-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// src/nvidia-modeset/kapi/src/nvkms-kapi.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2015-2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//! Pinned NVIDIA570.144 NV01_MEMORY_LOCAL_USER and GPU-VA mapping.
//! Complete source notices are prepended by the reference preparation step.
//! RM chooses physical placement; returned offsets are not contiguous heaps.
const std = @import("std");
const base = @import("gsp_buffer_wire.zig");
const exchange = @import("gsp_exchange.zig");
pub const Error = base.Error;
pub const Binding = base.Binding;
pub const Operation = enum { allocate_memory, allocate_virtual, map, unmap, free_virtual, free_memory };
pub const alignment: u64 = 65536;
pub const Layout = struct { blocklinear: bool = false, scanout: bool = false, contiguous: bool = false };
pub fn function(op: Operation) u32 { return switch (op) { .allocate_memory, .allocate_virtual => 103, .map => 14, .unmap => 15, .free_virtual, .free_memory => 10 }; }
fn translated(op: Operation) base.Operation { return switch (op) { .allocate_memory, .allocate_virtual => .allocate, .map => .map, .unmap => .unmap, .free_virtual => .free_virtual, .free_memory => .free_memory }; }
fn part(bytes: u64) base.Part { return .{ .total_bytes = bytes, .byte_length = bytes }; }
fn put(out: []u8, at: usize, v: u32) void { std.mem.writeInt(u32, out[at..][0..4], v, .little); }
fn wide(out: []u8, at: usize, v: u64) void { std.mem.writeInt(u64, out[at..][0..8], v, .little); }
fn word(in: []const u8, at: usize) u32 { return std.mem.readInt(u32, in[at..][0..4], .little); }
fn long(in: []const u8, at: usize) u64 { return std.mem.readInt(u64, in[at..][0..8], .little); }
pub fn encode(binding: Binding, bytes: u64, op: Operation, address: u64, out: []u8) Error!base.Encoded {
    return encodeLayout(binding, bytes, .{}, op, address, out);
}
pub fn encodeLayout(binding: Binding, bytes: u64, layout: Layout, op: Operation, address: u64, out: []u8) Error!base.Encoded {
    if (bytes == 0 or bytes % alignment != 0) return error.Bounds;
    const result = try base.encodePart(binding, part(bytes), translated(op), &.{}, address, out);
    if (op == .allocate_memory or op == .allocate_virtual) {
        const p = out[32..160];
        const format: u32 = if (layout.blocklinear) 2 << 16 else 0;
        put(p, 24, 0x00800000 | format); // 4K, VRAM, uncompressed generic kind.
        put(p, 28, 4); // Locally cached GPU memory, explicit YES.
        wide(p, 72, alignment);
        if (op == .allocate_memory) {
            put(out, 8, binding.memory);
            put(out, 12, 0x40); // NV01_MEMORY_LOCAL_USER.
            put(p, 4, if (layout.scanout) 8 else 0); // PRIMARY or IMAGE.
            put(p, 8, if (layout.scanout) 0x102 else 0x1102); // Scanout never sets NO_SCANOUT.
            put(p, 24, (if (layout.scanout or layout.contiguous) @as(u32, 0x10800000) else 0x08800000) | format);
            put(p, 108, 0);
        }
    } else if (op == .map) put(out, 32, 0x100); // 4K, no CPU snoop; immediate TLB update.
    return result;
}
pub fn decode(binding: Binding, bytes: u64, op: Operation, request: []const u8, record: exchange.message.Record, address: u64) Error!base.Reply {
    if (op != .allocate_memory) {
        const result = try base.decodePart(binding, part(bytes), translated(op), request, record, address);
        if (op == .allocate_virtual and result == .ok and result.ok % alignment != 0) return error.Bounds;
        return result;
    }
    try base.validatePart(binding, part(bytes));
    if (bytes == 0 or bytes % alignment != 0 or request.len != 160 or record.rpc.function != 103 or record.rpc.cpu_rm_gfid != 0) return error.Payload;
    if (record.rpc.result != 0) return error.FirmwareResult;
    const data = record.payload;
    if (data.len != 32 and data.len != 160) return error.Payload;
    for (data[0..32], 0..) |v, i| {
        if (i >= 16 and i < 20) continue;
        if (v != request[i]) return error.Unexpected;
    }
    const status = word(data, 16);
    if (status != 0) return .{ .rejected = status };
    if (data.len != 160) return error.Payload;
    const p = data[32..];
    // Only physicality and the documented physical offset/limit may change
    // for this exact uncompressed request. Any other successful outcome
    // remains retained until the driver can describe it safely.
    const attr = word(p, 24);
    const physicality = (attr >> 27) & 3;
    const requested_attr = word(request[32..], 24);
    if ((attr & ~@as(u32, 3 << 27)) != (requested_attr & ~@as(u32, 3 << 27)) or
        (physicality != 1 and physicality != 2) or (((requested_attr >> 27) & 3) == 2 and physicality != 2)) return error.Payload;
    for (p, 0..) |v, i| {
        if ((i >= 24 and i < 28) or (i >= 80 and i < 96)) continue;
        if (v != request[32 + i]) return error.Payload;
    }
    if (long(p, 64) != bytes or long(p, 88) != bytes - 1 or long(p, 80) % alignment != 0) return error.Bounds;
    return .{ .ok = long(p, 80) }; // First physical page only, never CPU-accessible.
}
