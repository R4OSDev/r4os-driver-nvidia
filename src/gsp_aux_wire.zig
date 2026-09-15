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
//! Fixed NVIDIA 570.144 EDID and SST DPCD allowlist. No arbitrary I2C
//! slave, register range or user-controlled command word.
//! Complete original reference notices are retained above.
const std = @import("std");
pub const Error = error{ Query, Bounds, Payload, Unexpected };
pub const bytes = 48;
pub const command: u32 = 0x731341;
pub const rpc_flags: u32 = 1; // COPYOUT_ON_ERROR, as exported method flags 0x844 specify.
/// Fixed MST control/mailbox ranges. No caller-selected native AUX address.
pub const Mst = union(enum) {
    guid: void,
    guid_write: [16]u8,
    control: ?u8,
    irq: struct { esi: bool = false, ack: ?u8 = null },
    payload: struct { id: u8, start: u8, count: u8 },
    payload_status: bool, // true clears UPDATED before the next allocation.
    payload_table: u2, // Four read-only 16-byte parts, status + 63 VC IDs.
    mailbox: struct {
        box: enum { down_request, up_reply, down_reply, up_request },
        offset: u8,
        count: u8,
        data: [16]u8 = @splat(0),
    },
    pub fn valid(self: Mst) bool {
        return switch (self) {
            .guid, .payload_status, .payload_table => true,
            .guid_write => |value| !std.mem.allEqual(u8, &value, 0),
            .control => |value| if (value) |bits| bits & ~@as(u8, 7) == 0 else true,
            .irq => |value| if (value.ack) |bits| bits != 0 and bits & ~@as(u8, 0x30) == 0 else true,
            .payload => |value| value.id <= 63 and value.start <= 63 and value.count <= 63 and
                @as(u16, value.start) + value.count <= 64 and
                (if (value.id == 0) value.start == 0 and value.count == 63 else value.start != 0),
            .mailbox => |value| value.count != 0 and value.count <= 16 and @as(u16, value.offset) + value.count <= 48,
        };
    }
    pub fn write(self: Mst) bool {
        return switch (self) {
            .guid, .payload_table => false,
            .guid_write => true,
            .control => |value| value != null,
            .irq => |value| value.ack != null,
            .payload => true,
            .payload_status => |value| value,
            .mailbox => |value| value.box == .down_request or value.box == .up_reply,
        };
    }
    pub fn size(self: Mst) u8 {
        return switch (self) {
            .guid, .guid_write, .payload_table => 16,
            .payload => 3,
            .mailbox => |value| value.count,
            else => 1,
        };
    }
    pub fn address(self: Mst) u32 {
        return switch (self) {
            .guid, .guid_write => 0x30,
            .control => 0x111,
            .irq => |value| if (value.esi) 0x2003 else 0x201,
            .payload => 0x1c0,
            .payload_status => 0x2c0,
            .payload_table => |part| 0x2c0 + @as(u32, part) * 16,
            .mailbox => |value| @as(u32, switch (value.box) {
                .down_request => 0x1000,
                .up_reply => 0x1200,
                .down_reply => 0x1400,
                .up_request => 0x1600,
            }) + value.offset,
        };
    }
    pub fn fill(self: Mst, output: *[16]u8) void {
        switch (self) {
            .control => |value| output[0] = value orelse 0,
            .irq => |value| output[0] = value.ack orelse 0,
            .payload => |value| @memcpy(output[0..3], &[_]u8{ value.id, value.start, value.count }),
            .payload_status => |value| output[0] = @intFromBool(value),
            .mailbox => |value| if (self.write()) {
                @memcpy(output[0..value.count], value.data[0..value.count]);
            },
            .guid, .payload_table => {},
            .guid_write => |value| output.* = value,
        }
    }
};
pub const Operation = union(enum) {
    mst: Mst,
    caps: void,
    extended_caps: void,
    color_caps: void,
    dsc_caps: void,
    fec_caps: void,
    mst_caps: void,
    fec_status: void,
    fec_clear: void,
    dsc_control: void,
    dsc_enable: bool,
    downspread_read: void,
    downspread_write: u8,
    repeaters: void,
    link_config: void,
    link_status: void,
    power: void,
    power_on: u8,
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
pub fn i2c(op: Operation) bool {
    return switch (op) {
        .segment, .offset, .segment_status, .offset_status, .read, .stop => true,
        else => false,
    };
}
fn put(output: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, output[offset..][0..4], value, .little);
}
fn get(input: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, input[offset..][0..4], .little);
}
pub fn length(op: Operation) u8 {
    return switch (op) {
        .mst => |value| value.size(),
        .caps, .extended_caps, .dsc_caps => 16,
        .repeaters, .link_status => 8,
        .link_config => 2,
        .read => |read| read.count,
        .stop => 0,
        else => 1,
    };
}
fn cmd(op: Operation) u32 {
    return switch (op) {
        .mst => |value| if (value.write()) 8 else 9,
        .caps, .extended_caps, .color_caps, .dsc_caps, .fec_caps, .mst_caps, .fec_status, .dsc_control, .downspread_read, .repeaters, .link_config, .link_status, .power => 9,
        .power_on, .downspread_write, .fec_clear, .dsc_enable => 8,
        .segment, .offset => 4,
        .segment_status, .offset_status => 6,
        .read => |read| if (read.last) 1 else 5,
        .stop => 0,
    };
}
fn address(op: Operation) u32 {
    return switch (op) {
        .mst => |value| value.address(),
        .caps => 0,
        .extended_caps => 0x2200,
        .repeaters => 0xf0000,
        .color_caps => 0x2210,
        .dsc_caps => 0x60,
        .fec_caps => 0x90,
        .mst_caps => 0x21,
        .fec_status, .fec_clear => 0x280,
        .dsc_control, .dsc_enable => 0x160,
        .downspread_read, .downspread_write => 0x107,
        .link_config => 0x100,
        .link_status => 0x200,
        .power, .power_on => 0x600,
        .segment, .segment_status => 0x30,
        else => 0x50,
    };
}
pub fn encode(request: Request, output: []u8) Error![]const u8 {
    if (request.display_id == 0 or request.display_id & (request.display_id - 1) != 0) return error.Query;
    switch (request.operation) {
        .mst => |value| if (!value.valid()) return error.Query,
        .segment => |segment| if (segment >= 16) return error.Query,
        .read => |read| if (read.count == 0 or read.count > 16) return error.Query,
        .power_on => |value| if (value & 7 != 1) return error.Query,
        else => {},
    }
    if (output.len < bytes) return error.Bounds;
    const buffer = output[0..bytes];
    @memset(buffer, 0);
    put(buffer, 4, request.display_id);
    buffer[8] = @intFromBool(request.operation == .stop);
    put(buffer, 12, cmd(request.operation));
    put(buffer, 16, address(request.operation));
    switch (request.operation) {
        .mst => |value| value.fill(buffer[20..36]),
        .segment => |segment| buffer[20] = segment,
        .offset => |offset| buffer[20] = offset,
        .power_on, .downspread_write => |value| buffer[20] = value,
        .fec_clear => buffer[20] = 3, // W1C: neither sticky transition may grant a new FEC proof.
        .dsc_enable => |enabled| buffer[20] = @intFromBool(enabled),
        else => {},
    }
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
    if (cmd(request.operation) == 9 or request.operation == .read) @memcpy(result.data[0..count], input[20..][0..count]);
    return result;
}
