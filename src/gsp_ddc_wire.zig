// DDC/I2C reference notices: unchanged NVIDIA 570.144 attribution.
// Nvidia570.144/src/common/sdk/nvidia/inc/ctrl/ctrl402c.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2010-2020 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// Nvidia570.144/src/nvidia/interface/rmapi/src/g_finn_rm_api.c
// Except where noted otherwise, the individual files within this package are
// licensed as MIT:
//
//     Copyright (c) 2021 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//     FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
//     THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//     LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//     FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//     DEALINGS IN THE SOFTWARE.
//! Fixed NVIDIA 570.144 FINN encoding for one read-only 128-byte DDC block.
//! Pointer-free on the wire, bounded before access, no generic RM controls.
//! Reference: original ctrl402c.h and g_finn_rm_api.c; full notices above.
const std = @import("std");
pub const Error = error{ Query, Bounds, Payload };
pub const bytes = 200;
pub const block_bytes = 128;
pub const max_blocks = 32;
pub const command: u32 = 0x402c0105;
pub const rpc_flags: u32 = 2; // RMAPI_RPC_FLAGS_SERIALIZED, not NVOS54 flags.
pub const Request = struct { port: u8, block: u8 };

fn validate(request: Request) Error!void {
    if (request.port >= 16 or request.block >= max_blocks) return error.Query;
}
const Writer = struct {
    output: []u8,
    cursor: usize = 256,
    fn put(self: *Writer, value: u64, width: u7) void {
        for (0..width) |bit| {
            const index = self.cursor + bit;
            self.output[index / 8] |= (@as(u8, @truncate(value >> @as(u6, @intCast(bit)))) & 1) << @as(u3, @intCast(index % 8));
        }
        self.cursor += width;
    }
    fn field(self: *Writer, value: u64, width: u7) void { self.put(1, 1); self.put(value, width); }
};
const Reader = struct {
    input: []const u8,
    cursor: usize = 256,
    fn take(self: *Reader, width: u7) u64 {
        var value: u64 = 0;
        for (0..width) |bit| {
            const index = self.cursor + bit;
            value |= @as(u64, (self.input[index / 8] >> @as(u3, @intCast(index % 8))) & 1) << @as(u6, @intCast(bit));
        }
        self.cursor += width;
        return value;
    }
    fn field(self: *Reader, width: u7) Error!u64 {
        if (self.take(1) != 1) return error.Payload;
        return self.take(width);
    }
};

/// Production callers pass no data: an EDID read transmits a zeroed output
/// buffer. Host firmware fixtures may serialize a supplied response payload.
pub fn encode(request: Request, data: ?*const [block_bytes]u8, output: []u8) Error![]const u8 {
    try validate(request);
    if (output.len < bytes) return error.Bounds;
    const buffer = output[0..bytes];
    @memset(buffer, 0);
    for ([_]u64{ 0, bytes, 0x402c01, 5 }, 0..) |value, index|
        std.mem.writeInt(u64, buffer[index * 8 ..][0..8], value, .little);
    var writer = Writer{ .output = buffer };
    writer.field(request.port, 8);
    writer.field(0, 32); // Basic 7-bit addressing, 100-kHz transaction, no WARs.
    writer.field(0xa0, 16); // Shifted EDID slave address, per ctrl402c.h.
    writer.field(10, 32); // READ_EDID_DDC; never an arbitrary I2C write.
    writer.put(1, 1); // transData is present.
    writer.put(1, 1); // edidData union arm is present.
    writer.field(request.block / 2, 8);
    writer.field(@as(u16, request.block % 2) * 128, 8);
    writer.field(block_bytes, 32);
    writer.put(1, 1); // Inline data present, never a serialized CPU address.
    for (0..block_bytes) |index| writer.field(if (data) |payload| payload[index] else 0, 8);
    std.debug.assert(writer.cursor == 1554);
    return buffer;
}

/// Two passes validate every presence bit and fixed echo before the first
/// output mutation. A malformed final byte cannot leave a partly new block.
pub fn decode(request: Request, input: []const u8, output: *[block_bytes]u8) Error!void {
    try validate(request);
    if (input.len != bytes) return error.Payload;
    for ([_]u64{ 0, bytes, 0x402c01, 5 }, 0..) |expected, index|
        if (std.mem.readInt(u64, input[index * 8 ..][0..8], .little) != expected) return error.Payload;
    var reader = Reader{ .input = input };
    if (try reader.field(8) != request.port or try reader.field(32) != 0 or try reader.field(16) != 0xa0 or
        try reader.field(32) != 10 or reader.take(1) != 1 or reader.take(1) != 1 or
        try reader.field(8) != request.block / 2 or try reader.field(8) != @as(u16, request.block % 2) * 128 or
        try reader.field(32) != block_bytes or reader.take(1) != 1) return error.Payload;
    const data_start = reader.cursor;
    for (0..block_bytes) |_| _ = try reader.field(8);
    // Pinned serializer zero-pads the terminal word; no unparsed tail.
    while (reader.cursor < bytes * 8) if (reader.take(1) != 0) return error.Payload;
    reader.cursor = data_start;
    for (output) |*value| value.* = @intCast(try reader.field(8));
}
