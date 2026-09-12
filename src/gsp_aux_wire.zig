// AUX protocol reference notices; original R4OS ownership code remains Apache-2.0.
// Nvidia/OpenKernelModules-570.144/src/common/sdk/nvidia/inc/ctrl/ctrl0073/ctrl0073dp.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2005-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//! Fixed NVIDIA 570.144 AUX read/EDID-selection allowlist. No DPCD write,
//! link training, arbitrary I2C slave or user-controlled command word.
//! Complete original reference notices are retained above.
const std = @import("std");
pub const Error = error{ Query, Bounds, Payload, Unexpected };
pub const bytes = 48;
pub const command: u32 = 0x731341;
pub const rpc_flags: u32 = 1; // COPYOUT_ON_ERROR, as exported method flags 0x844 specify.
pub const Operation = union(enum) {
    caps: void,
    segment: u8,
    offset: u8,
    segment_status: void,
    offset_status: void,
    read: struct { count: u8, last: bool },
    stop: void,
};
pub const Request = struct { display_id: u32, operation: Operation };
pub const ReplyType = enum(u32) { ack = 0, nack = 1, defer_reply = 2, timeout = 3, i2c_nack = 4, i2c_defer = 8, invalid_argument = 0xffffffff };
pub const Reply = struct { status: u32 = 0, kind: ReplyType = .ack, retry_ms: u32 = 0, count: u8 = 0, data: [16]u8 = @splat(0) };
fn put(output: []u8, offset: usize, value: u32) void { std.mem.writeInt(u32, output[offset..][0..4], value, .little); }
fn get(input: []const u8, offset: usize) u32 { return std.mem.readInt(u32, input[offset..][0..4], .little); }
pub fn length(op: Operation) u8 { return switch (op) { .caps => 16, .read => |read| read.count, .stop => 0, else => 1 }; }
fn cmd(op: Operation) u32 {
    return switch (op) { .caps => 9, .segment, .offset => 4, .segment_status, .offset_status => 6,
        .read => |read| if (read.last) 1 else 5, .stop => 0 };
}
fn address(op: Operation) u32 { return switch (op) { .caps => 0, .segment, .segment_status => 0x30, else => 0x50 }; }
pub fn encode(request: Request, output: []u8) Error![]const u8 {
    if (request.display_id == 0 or request.display_id & (request.display_id - 1) != 0) return error.Query;
    switch (request.operation) {
        .segment => |segment| if (segment >= 16) return error.Query,
        .read => |read| if (read.count == 0 or read.count > 16) return error.Query,
        else => {},
    }
    if (output.len < bytes) return error.Bounds;
    const buffer = output[0..bytes];
    @memset(buffer, 0);
    put(buffer, 4, request.display_id);
    buffer[8] = @intFromBool(request.operation == .stop);
    put(buffer, 12, cmd(request.operation));
    put(buffer, 16, address(request.operation));
    switch (request.operation) { .segment => |segment| buffer[20] = segment, .offset => |offset| buffer[20] = offset, else => {} }
    const count = length(request.operation);
    put(buffer, 36, if (count == 0) 0 else count - 1);
    return buffer;
}
pub fn decode(request: Request, status: u32, input: []const u8) Error!Reply {
    if (input.len != bytes) return error.Payload;
    if (get(input, 0) != 0 or get(input, 4) != request.display_id or input[8] != @intFromBool(request.operation == .stop) or
        get(input, 12) != cmd(request.operation) or get(input, 16) != address(request.operation)) return error.Unexpected;
    // Only retry time is meaningful on the two explicit retryable RM errors.
    // COPYOUT permits it; rejected reads still expose no data or reply type.
    if (status != 0) return .{ .status = status, .retry_ms = if (status == 3 or status == 0x66) get(input, 44) else 0 };
    const kind = std.enums.fromInt(ReplyType, get(input, 40)) orelse return error.Payload;
    if (kind != .ack) return .{ .kind = kind };
    const count = get(input, 36);
    if (count > length(request.operation)) return error.Payload;
    var result = Reply{ .kind = kind, .count = @intCast(count) };
    if (request.operation == .read or request.operation == .caps) @memcpy(result.data[0..count], input[20..][0..count]);
    return result;
}
