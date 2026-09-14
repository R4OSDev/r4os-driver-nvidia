// Wire references: NVIDIA 570.144 ctrl0073dfp.h and ctrl0073system.h.
// Original R4OS bounded transaction/ownership policy: Apache-2.0.
// SPDX-FileCopyrightText: Copyright (c) 2005-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-FileCopyrightText: Copyright (c) 2005-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: MIT
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
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
//! Assign one external SST output through the existing live NV0073 object.
//! Capability discovery precedes the setter. No allocation, MMIO or scanout;
//! the caller must reacquire coherent topology before using the new mapping.
const std = @import("std");
const display = @import("gsp_display_rpc.zig");
const exchange = @import("gsp_exchange.zig");
pub const function: u32 = 76;
pub const max_bytes = 104;
pub const Operation = enum { caps, assign };
pub const Request = struct {
    object: display.Object,
    display_id: u32,
    // Display IDs already owned by an active head or a pending route, indexed
    // by the actual SOR. Excluding these also protects not-yet-lit outputs.
    protected: [4]u32 = @splat(0),
    pub fn excluded(self: Request) u8 {
        var bits: u8 = 0;
        for (self.protected, 0..) |id, index| if (id != 0) { bits |= @as(u8, 1) << @intCast(index); };
        return bits;
    }
    fn validate(self: Request) !void {
        if (self.object.epoch == 0 or self.object.client == 0 or self.object.display == 0) return error.Handle;
        if (!oneBit(self.display_id)) return error.Descriptor;
        var seen = self.display_id;
        for (self.protected) |id| if (id != 0) {
            if (!oneBit(id) or id & seen != 0) return error.Descriptor;
            seen |= id;
        };
    }
};
pub const Assignment = struct {
    sor: u32,
    displays: [4]u32,
    kinds: [4]u32,
    reserved: u8,
    flags: u32,
};
pub const Reply = union(enum) {
    caps: [2]u8,
    assigned: Assignment,
    rejected: struct { status: u32, rpc: bool },
};
fn oneBit(value: u32) bool { return value != 0 and value & (value - 1) == 0; }
fn put(bytes: []u8, offset: usize, value: u32) void { std.mem.writeInt(u32, bytes[offset..][0..4], value, .little); }
fn word(bytes: []const u8, offset: usize) u32 { return std.mem.readInt(u32, bytes[offset..][0..4], .little); }
fn command(operation: Operation) u32 { return if (operation == .caps) 0x730101 else 0x731152; }
fn paramsSize(operation: Operation) usize { return if (operation == .caps) 2 else 80; }

pub fn encode(request: Request, operation: Operation, output: *[max_bytes]u8) !usize {
    try request.validate();
    const size = paramsSize(operation);
    @memset(output, 0);
    put(output, 0, request.object.client); put(output, 4, request.object.display);
    put(output, 8, command(operation)); put(output, 16, @intCast(size));
    if (operation == .assign) {
        put(output, 28, request.display_id);
        output[32] = request.excluded();
        // Default subdevice, no slave, no forced sublink, no 2-head/1-OR and
        // default audio preference. Output fields and C padding start at zero.
    }
    return 24 + size;
}
pub fn decode(request: Request, operation: Operation, record: exchange.message.Record) !Reply {
    try request.validate();
    if (record.rpc.function != function or record.rpc.cpu_rm_gfid != 0) return error.Unexpected;
    if (record.rpc.result == 0xffffffff) return error.Payload;
    if (record.rpc.result != 0) return .{ .rejected = .{ .status = record.rpc.result, .rpc = true } };
    const bytes = record.payload;
    if (bytes.len != 24 + paramsSize(operation) or word(bytes, 0) != request.object.client or
        word(bytes, 4) != request.object.display or word(bytes, 8) != command(operation) or
        word(bytes, 16) != paramsSize(operation) or word(bytes, 20) != 0) return error.Unexpected;
    if (word(bytes, 12) != 0) return .{ .rejected = .{ .status = word(bytes, 12), .rpc = false } };
    const params = bytes[24..];
    if (operation == .caps) return .{ .caps = params[0..2].* };
    if (word(params, 0) != 0 or word(params, 4) != request.display_id or params[8] != request.excluded() or
        word(params, 12) != 0 or word(params, 16) != 0 or params[20] != 0 or params[72] & ~@as(u8, 15) != 0 or
        word(params, 76) & ~@as(u32, 2) != 0) return error.Payload;
    var result: Assignment = .{ .sor = 0xffffffff, .displays = @splat(0), .kinds = @splat(0),
        .reserved = params[72], .flags = word(params, 76) };
    for (0..4) |index| {
        const mask = word(params, 40 + index * 8);
        const kind = word(params, 44 + index * 8);
        // Pinned 570.144 supplies both maps. Neither conflicting maps nor
        // 2-head/1-OR can authorize this SST request.
        if (word(params, 24 + index * 4) != mask or kind > 3 or (mask == 0) != (kind == 0)) return error.Payload;
        result.displays[index] = mask; result.kinds[index] = kind;
        if (request.protected[index] != 0 and (mask & request.protected[index] == 0 or kind != 1)) return error.Binding;
        for (request.protected, 0..) |id, other| if (other != index and mask & id != 0) return error.Binding;
        if (mask & request.display_id != 0) {
            const bit = @as(u8, 1) << @intCast(index);
            if (result.sor != 0xffffffff or kind != 1 or (request.excluded() | result.reserved) & bit != 0) return error.Binding;
            result.sor = @intCast(index);
        }
    }
    if (result.sor == 0xffffffff) return error.Binding;
    return .{ .assigned = result };
}

pub const Work = struct {
    request: Request,
    connector: display.Connector = .{},
    fingerprint: [32]u8 = @splat(0),
    generation: u64,
    sequence: u64,
    deadline: u64,
    operation: Operation = .caps,
    pending: bool = false,
    complete: bool = false,
    obsolete: bool = false,
    capabilities: ?[2]u8 = null,
    assignment: ?Assignment = null,
    rejected: ?struct { status: u32, rpc: bool } = null,
    receipt: u64 = 0,
    bytes: [max_bytes]u8 = @splat(0),
    length: usize = 0,
    pub fn crossbar(self: *const Work) bool { return if (self.capabilities) |caps| caps[1] & 8 != 0 else false; }
    pub fn matches(self: *const Work, channel: *const exchange.Exchange, deadline: u64) bool {
        if (!self.pending or self.complete or self.obsolete or self.deadline != deadline or self.generation == 0 or self.sequence == 0 or
            (self.operation == .assign and !self.crossbar()) or self.request.object.epoch != channel.session.epoch or
            channel.phase != .prepared or channel.deadline != deadline or channel.function != function or
            channel.request.ptr != self.bytes[0..].ptr or channel.request.len != self.length) return false;
        var expected: [max_bytes]u8 = undefined;
        const n = encode(self.request, self.operation, &expected) catch return false;
        return n == self.length and std.mem.eql(u8, expected[0..n], self.bytes[0..n]);
    }
    /// Call after the response ACK. Rejections are normal admission results;
    /// malformed or ownership-changing responses remain explicit failures.
    pub fn consume(self: *Work, reply: Reply, serial: u64) !void {
        if (!self.pending or self.complete or serial == 0 or serial <= self.receipt) return error.Stale;
        self.pending = false; self.receipt = serial;
        switch (reply) {
            .rejected => |value| { self.rejected = .{ .status = value.status, .rpc = value.rpc }; self.complete = true; },
            .caps => |caps| {
                if (self.operation != .caps) return error.State;
                self.capabilities = caps;
                if (!self.crossbar() or self.obsolete) self.complete = true else self.operation = .assign;
            },
            .assigned => |value| {
                if (self.operation != .assign or !self.crossbar()) return error.State;
                self.assignment = value; self.complete = true;
            },
        }
    }
};
