// src/nvidia/inc/kernel/os/nv_memory_type.h
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
// src/nvidia/src/kernel/gpu/mem_mgr/mem_utils.c
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
// src/common/sdk/nvidia/inc/ctrl/ctrl2080/ctrl2080internal.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2020-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//! Original synchronous GSP memset of a private, confirmed contiguous VRAM
//! extent. It precedes VA publication and all channel/storage consumers.
const std = @import("std");
const exchange = @import("gsp_exchange.zig");
pub const Error = exchange.Error;
pub const function: u32 = 76;
pub const command: u32 = 0x20800afa;
pub const bytes: usize = 120;
pub const Binding = struct { epoch: u64, client: u32, subdevice: u32 };
pub const Reply = union(enum) { ok, rejected: u32 };
pub fn validate(binding: Binding) Error!void {
    if (binding.epoch == 0 or binding.client == 0 or binding.subdevice == 0 or binding.client == binding.subdevice) return error.Handle;
}
fn put(out: []u8, at: usize, value: u32) void { std.mem.writeInt(u32, out[at..][0..4], value, .little); }
fn wide(out: []u8, at: usize, value: u64) void { std.mem.writeInt(u64, out[at..][0..8], value, .little); }
pub fn encode(binding: Binding, base: u64, length: u64, output: []u8) Error![]const u8 {
    try validate(binding);
    if (output.len < bytes or base == 0 or base % 4096 != 0 or length == 0 or length % 4096 != 0 or
        base >= (@as(u64, 1) << 37) or length > (@as(u64, 1) << 37) - base) return error.Bounds;
    const out = output[0..bytes]; @memset(out, 0);
    put(out, 0, binding.client); put(out, 4, binding.subdevice); put(out, 8, command); put(out, 16, 96);
    // src[32] and authTag[16] stay zero for unencrypted MEMSET. dst starts48.
    wide(out, 72, base); wide(out, 80, length);
    put(out, 96, 2); // ADDR_FBMEM.
    put(out, 100, 1); // NV_MEMORY_UNCACHED; never create a CPU WB alias.
    wide(out, 104, length); put(out, 116, 1); // Synchronous MEMSET, value0.
    return out;
}
pub fn matches(binding: Binding, base: u64, length: u64, request: []const u8) bool {
    var expected: [bytes]u8 = undefined;
    const value = encode(binding, base, length, &expected) catch return false;
    return std.mem.eql(u8, value, request);
}
pub fn decode(binding: Binding, base: u64, length: u64, request: []const u8, record: exchange.message.Record) Error!Reply {
    if (!matches(binding, base, length, request) or record.rpc.function != function or record.rpc.cpu_rm_gfid != 0) return error.Payload;
    if (record.rpc.result != 0) return error.FirmwareResult;
    const data = record.payload;
    if (data.len != 24 and data.len != bytes) return error.Payload;
    for (data[0..24], 0..) |value, at| {
        if (at >= 12 and at < 16) continue;
        if (value != request[at]) return error.Unexpected;
    }
    const status = std.mem.readInt(u32, data[12..16], .little);
    if (status != 0) return .{ .rejected = status };
    if (data.len != bytes or !std.mem.eql(u8, data[24..], request[24..])) return error.Payload;
    return .ok;
}
