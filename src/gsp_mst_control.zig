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
//! Fixed NVIDIA570.144 MST RM parameters. The live graph owner adds the
//! normal control RPC envelope and authenticates its dispatch/receipt.
//! Allocation IDs come exclusively from successful RM replies.
const std = @import("std");
pub const Error = error{ Bounds, Descriptor, Payload, RmRejected, Pending, LinkTraining };
pub const Rate = struct { head: u32, sor: u32, enable: bool, immediate: bool = false, check: bool = false };
pub const Trigger = struct { head: u32, sor: u32 };
pub const Train = struct { root: u32, rate: u8, lanes: u8, enhanced: bool, post_adjust: bool = false };
pub const Training = struct { status: u32, failure: u32, retry_ms: u32 };
pub const Stream = struct {
    head: u32,
    sor: u32,
    link: u32,
    hblank: u32,
    vblank: u32,
    start: u32,
    end: u32,
    pbn: u32,
    timeslice_pbn: u32,
};
pub const Query = union(enum) {
    allocate: u32,
    free: u32,
    stream: Stream,
    act: u32,
    rate: Rate,
    trigger: Trigger,
    train: Train,
    clear_vsc: u32,
    clear_hdr: u32,
    pub fn command(self: Query) u32 {
        return switch (self) {
            .allocate => 0x73135b,
            .free => 0x73135c,
            .stream => 0x731362,
            .act => 0x731367,
            .rate => 0x731363,
            .trigger => 0x73136f,
            .train => 0x731343,
            .clear_vsc => 0x730289,
            .clear_hdr => 0x730288,
        };
    }
    pub fn size(self: Query) usize {
        return switch (self) {
            .allocate => 24,
            .free, .act => 8,
            .stream => 84,
            .rate, .trigger => 16,
            .train => 28,
            .clear_vsc => 16,
            .clear_hdr => 60,
        };
    }
    pub fn encode(self: Query, output: []u8) Error!usize {
        var bytes: [84]u8 = @splat(0);
        switch (self) {
            .allocate, .free, .act => |id| {
                if (id == 0 or id & (id - 1) != 0) return error.Descriptor;
                put(&bytes, 4, id);
                // preferredDisplayId=0, force=false, useBFM=false. The
                // ffffffff pool query is never treated as an allocation.
            },
            .stream => |value| {
                if (value.head >= 8 or value.sor >= 8 or value.link > 1 or value.start == 0 or value.start > 63 or value.end > 63 or
                    (if (value.pbn == 0) value.end + 1 != value.start or value.timeslice_pbn != 0 else value.end < value.start or value.pbn > 65535 or value.timeslice_pbn < value.pbn or value.timeslice_pbn > 65535)) return error.Descriptor;
                put(&bytes, 4, value.head);
                put(&bytes, 8, value.sor);
                put(&bytes, 12, value.link);
                bytes[16] = 1;
                bytes[17] = 1; // Override + MST, ordinary one-head/one-stream.
                put(&bytes, 24, value.hblank);
                put(&bytes, 28, value.vblank);
                put(&bytes, 40, value.start);
                put(&bytes, 44, value.end);
                put(&bytes, 48, value.pbn);
                put(&bytes, 52, value.timeslice_pbn);
                // RGB, no single-head multi-stream, no deprecated sendACT.
            },
            .rate => |value| {
                if (value.head >= 8 or value.sor >= 8) return error.Descriptor;
                put(&bytes, 4, value.head); put(&bytes, 8, value.sor);
                put(&bytes, 12, @as(u32, @intFromBool(value.enable)) |
                    (@as(u32, @intFromBool(value.immediate)) << 1) | (@as(u32, @intFromBool(value.check)) << 3));
            },
            .trigger => |value| {
                if (value.head >= 8 or value.sor >= 8) return error.Descriptor;
                put(&bytes, 4, value.head); put(&bytes, 8, value.sor);
                // One ordinary head per stream; singleHeadMSTPipeline=0.
            },
            .train => |value| {
                if (value.root == 0 or value.root & (value.root - 1) != 0 or
                    (value.rate != 6 and value.rate != 10 and value.rate != 20 and value.rate != 30) or
                    (value.lanes != 1 and value.lanes != 2 and value.lanes != 4)) return error.Descriptor;
                put(&bytes, 4, value.root);
                put(&bytes, 8, 3 | (1 << 4) | (1 << 13) | @as(u32, if (value.enhanced) 128 else 0) |
                    @as(u32, if (value.post_adjust) 1 << 10 else 0));
                put(&bytes, 12, value.lanes | (@as(u32, value.rate) << 8));
                // Real 8b/10b MST training, no fake/no-LT/skip-HW flags.
                // The owner must have ruled out non-transparent repeaters.
            },
            .clear_vsc, .clear_hdr => |id| {
                if (id == 0 or id & (id - 1) != 0) return error.Descriptor;
                put(&bytes, 4, id);
                if (self == .clear_vsc) put(&bytes, 8, 7) else {
                    put(&bytes, 8, 0x105); put(&bytes, 12, 32);
                    bytes[21..57].* = @import("r4gfx_edid").color.dpSdrMetadata();
                }
            },
        }
        const count = self.size();
        if (output.len < count) return error.Bounds;
        @memcpy(output[0..count], bytes[0..count]);
        return count;
    }
    pub fn decode(self: Query, status: u32, input: []const u8) Error!u32 {
        if (self == .train) {
            const result = try self.training(status, input);
            if ((result.status == 3 or result.status == 0x66) and result.retry_ms != 0) return error.Pending;
            if (result.status != 0) return error.RmRejected;
            if (result.failure != 0) return error.LinkTraining;
            return 0;
        }
        if (status != 0) return error.RmRejected;
        var expected: [84]u8 = undefined;
        const count = try self.encode(&expected);
        if (input.len != count) return error.Payload;
        if (self == .allocate) {
            if (!std.mem.eql(u8, input[0..16], expected[0..16]) or get(input, 20) != 0) return error.Payload;
            const id = get(input, 16);
            if (id == 0 or id == self.allocate or id & (id - 1) != 0) return error.Payload;
            return id;
        }
        if (self == .rate) {
            if (!std.mem.eql(u8, input[0..12], expected[0..12]) or
                get(input, 12) & 0x7fffffff != get(&expected, 12)) return error.Payload;
            if (self.rate.check and get(input, 12) & 0x80000000 == 0) return error.Pending;
            return 0;
        }
        if (!std.mem.eql(u8, input, expected[0..count])) return error.Payload;
        return 0;
    }
    pub fn training(self: Query, status: u32, input: []const u8) Error!Training {
        if (self != .train) return error.Descriptor;
        var expected: [84]u8 = undefined;
        const count = try self.encode(&expected);
        if (input.len != count or !std.mem.eql(u8, input[0..16], expected[0..16]) or get(input, 24) != 0) return error.Payload;
        return .{ .status = status, .failure = get(input, 16), .retry_ms = get(input, 20) };
    }
};
fn put(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
fn get(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
