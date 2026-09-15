// NVIDIA570.144/src/common/sdk/nvidia/inc/ctrl/ctrl2080/ctrl2080tmr.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2008-2015 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// NVIDIA 570.144/src/common/sdk/nvidia/inc/ctrl/ctrl2080/ctrl2080internal.h
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
//! Pinned 570.144 physical-RM controls. All setters retain the complete input
//! and require the exact reply before changing DMA lifetime or policy state.
const std = @import("std");
const exchange = @import("gsp_exchange.zig");
const telemetry = @import("r4nv_telemetry");
pub const function: u32 = 76;
pub const max_bytes: usize = 40;
pub const Error = exchange.Error || error{Address};
pub const Binding = struct { epoch: u64, client: u32, subdevice: u32 };
pub const Operation = union(enum) {
    attach: u64,
    detach,
    poll: struct { mask: u64, interval_ms: u32 },
    boost: struct { level: u2, seconds: u16 },
    timer,
};
pub const Reply = union(enum) { acknowledged, rejected: u32, timer: u64 };
pub fn command(operation: Operation) u32 {
    return switch (operation) { .attach, .detach => 0x20800afe, .poll => 0x20800aff, .boost => 0x20800a9a, .timer => 0x20800403 };
}
pub fn size(operation: Operation) usize { return if (operation == .poll) 40 else 32; }
fn put(out: []u8, offset: usize, value: u32) void { std.mem.writeInt(u32, out[offset..][0..4], value, .little); }
pub fn encode(binding: Binding, operation: Operation, output: []u8) Error![]const u8 {
    if (binding.epoch == 0 or binding.client == 0 or binding.subdevice == 0 or binding.client == binding.subdevice) return error.Handle;
    if (output.len < size(operation)) return error.Bounds;
    switch (operation) {
        .attach => |address| if (address == 0 or address & 4095 != 0 or address > ((@as(u64, 1) << 47) - 4096)) return error.Address,
        .detach, .timer => {},
        .poll => |value| if (value.mask & ~telemetry.poll_mask != 0 or value.interval_ms < 100 or value.interval_ms > 10000) return error.Payload,
        .boost => |value| if (value.level > 2 or
            (value.level == 0 and value.seconds != 0) or (value.level != 0 and (value.seconds == 0 or value.seconds >= 3600))) return error.Payload,
    }
    const out = output[0..size(operation)];
    @memset(out, 0);
    put(out, 0, binding.client); put(out, 4, binding.subdevice); put(out, 8, command(operation));
    put(out, 16, @intCast(out.len - 24));
    switch (operation) {
        .attach => |address| std.mem.writeInt(u64, out[24..32], address, .little),
        .detach, .timer => {},
        .poll => |value| {
            std.mem.writeInt(u64, out[24..32], value.mask, .little);
            put(out, 32, value.interval_ms);
        },
        .boost => |value| {
            // Internal 2X uses NvBool, unlike public PERF_BOOST's NvU32.
            out[24] = value.level;
            put(out, 28, value.seconds);
        },
    }
    return out;
}
pub fn decode(binding: Binding, operation: Operation, record: exchange.message.Record) Error!Reply {
    if (record.rpc.function != function or record.rpc.cpu_rm_gfid != 0) return error.Unexpected;
    if (record.rpc.result == exchange.message.pending) return error.Payload;
    if (record.rpc.result != 0) return error.FirmwareResult;
    var request: [max_bytes]u8 = undefined;
    const expected = try encode(binding, operation, &request);
    if (record.payload.len < 24) return error.Payload;
    for (record.payload[0..24], expected[0..24], 0..) |value, wanted, index| {
        if (index >= 12 and index < 16) continue;
        if (value != wanted) return error.Unexpected;
    }
    const status = std.mem.readInt(u32, record.payload[12..16], .little);
    // RM may return just the validated control header for a rejection.
    if (status != 0) {
        if (record.payload.len != 24 and record.payload.len != expected.len) return error.Payload;
        return .{ .rejected = status };
    }
    if (record.payload.len != expected.len) return error.Payload;
    if (operation == .timer) return .{ .timer = std.mem.readInt(u64, record.payload[24..32], .little) };
    if (!std.mem.eql(u8, record.payload[24..], expected[24..])) return error.Payload;
    return .acknowledged;
}
