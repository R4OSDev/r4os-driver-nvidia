// /*
//  * SPDX-FileCopyrightText: Copyright (c) 1993-2021 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2010-2021 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2010-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// Protocol algorithms/layouts: NVIDIA 570.144 dp_crc.cpp,
// dp_messageheader.cpp, dp_splitter.cpp and dp_messagecodings.cpp.
// Full original reference notices retained above.
//! Bounded DisplayPort MST sideband framing. A route excludes the GPU's
//! physical port; an empty route addresses the first downstream branch.
//! Decoding produces observations only, never RM IDs or allocation receipts.
const std = @import("std");
pub const Error = error{ Bounds, Payload, Stale, Unsupported };
pub const packet_bytes = 48;
pub const message_bytes = 512;
pub const Route = struct {
    depth: u8 = 0,
    ports: [14]u8 = @splat(0),
    pub fn valid(self: Route) bool {
        if (self.depth > self.ports.len) return false;
        for (self.ports, 0..) |port, i| if (port > 15 or (i >= self.depth and port != 0)) return false;
        return true;
    }
    pub fn child(self: Route, port: u8) Error!Route {
        if (!self.valid() or port > 15 or self.depth == self.ports.len) return error.Bounds;
        var result = self;
        result.ports[result.depth] = port;
        result.depth += 1;
        return result;
    }
};
pub const Header = struct {
    route: Route = .{},
    remaining: u8 = 0,
    broadcast: bool = false,
    path: bool = false,
    start: bool = true,
    end: bool = true,
    sequence: u1 = 0,
    payload_bytes: u8 = 0, // Includes body CRC.
    pub fn size(self: Header) usize {
        return 3 + (@as(usize, self.route.depth) + 1) / 2;
    }
};
pub fn headerCrc(input: []const u8, bits: usize) Error!u4 {
    if (bits > input.len * 8) return error.Bounds;
    return @intCast(crc(input, bits, 4, 0x13));
}
pub fn bodyCrc(input: []const u8) u8 {
    return @intCast(crc(input, input.len * 8, 8, 0xd5));
}
fn crc(input: []const u8, bits: usize, comptime width: u4, comptime polynomial: u16) u16 {
    var remainder: u16 = 0;
    for (0..bits + width) |i| {
        remainder <<= 1;
        if (i < bits) remainder |= (input[i / 8] >> @as(u3, @intCast(7 - i % 8))) & 1;
        if (remainder & (@as(u16, 1) << width) != 0) remainder ^= polynomial;
    }
    return remainder & ((@as(u16, 1) << width) - 1);
}
pub fn encodeHeader(header: Header, output: []u8) Error!usize {
    if (!header.route.valid() or header.payload_bytes < 2 or header.payload_bytes + header.size() > packet_bytes or
        (header.broadcast and (header.route.depth != 0 or header.remaining != 6)) or
        (!header.broadcast and header.remaining > header.route.depth)) return error.Payload;
    const count = header.size();
    if (output.len < count) return error.Bounds;
    var bytes: [10]u8 = @splat(0);
    bytes[0] = ((header.route.depth + 1) << 4) | header.remaining;
    for (header.route.ports[0..header.route.depth], 0..) |port, i|
        bytes[1 + i / 2] |= port << @as(u3, if (i % 2 == 0) 4 else 0);
    bytes[count - 2] = (@as(u8, @intFromBool(header.broadcast)) << 7) |
        (@as(u8, @intFromBool(header.path)) << 6) | header.payload_bytes;
    bytes[count - 1] = (@as(u8, @intFromBool(header.start)) << 7) |
        (@as(u8, @intFromBool(header.end)) << 6) | (@as(u8, header.sequence) << 4);
    bytes[count - 1] |= try headerCrc(bytes[0..count], count * 8 - 4);
    @memcpy(output[0..count], bytes[0..count]);
    return count;
}
pub fn decodeHeader(input: []const u8) Error!Header {
    if (input.len < 3) return error.Bounds;
    const lct = input[0] >> 4;
    if (lct == 0) return error.Payload;
    var result: Header = .{ .route = .{ .depth = lct - 1 }, .remaining = input[0] & 15 };
    const count = result.size();
    if (input.len < count) return error.Bounds;
    for (result.route.ports[0..result.route.depth], 0..) |*port, i|
        port.* = (input[1 + i / 2] >> @as(u3, if (i % 2 == 0) 4 else 0)) & 15;
    if (result.route.depth % 2 != 0 and input[1 + result.route.depth / 2] & 15 != 0) return error.Payload;
    result.broadcast = input[count - 2] & 0x80 != 0;
    result.path = input[count - 2] & 0x40 != 0;
    result.payload_bytes = input[count - 2] & 63;
    result.start = input[count - 1] & 0x80 != 0;
    result.end = input[count - 1] & 0x40 != 0;
    result.sequence = @truncate(input[count - 1] >> 4);
    if (input[count - 1] & 0x20 != 0 or result.payload_bytes < 2 or count + result.payload_bytes > packet_bytes or
        (result.broadcast and (result.route.depth != 0 or result.remaining > 6)) or
        (!result.broadcast and result.remaining > result.route.depth) or
        try headerCrc(input[0..count], count * 8 - 4) != input[count - 1] & 15) return error.Payload;
    return result;
}
pub const Fragment = struct { header: Header, body: []const u8, used: usize };
pub fn decode(input: []const u8) Error!Fragment {
    const header = try decodeHeader(input);
    const used = header.size() + header.payload_bytes;
    if (input.len < used) return error.Bounds;
    const body = input[header.size() .. used - 1];
    if (bodyCrc(body) != input[used - 1]) return error.Payload;
    return .{ .header = header, .body = body, .used = used };
}
pub const Sender = struct {
    route: Route,
    sequence: u1,
    path: bool = false,
    broadcast: bool = false,
    offset: usize = 0,
    pub fn next(self: *Sender, body: []const u8, output: []u8) Error!?usize {
        if (!self.route.valid() or body.len == 0 or body.len > message_bytes or self.offset > body.len) return error.Bounds;
        if (self.offset == body.len) return null;
        var header: Header = .{ .route = if (self.broadcast) .{} else self.route, .remaining = if (self.broadcast) 6 else self.route.depth, .sequence = self.sequence, .path = self.path, .broadcast = self.broadcast, .start = self.offset == 0 };
        const count = @min(body.len - self.offset, packet_bytes - header.size() - 1);
        header.end = self.offset + count == body.len;
        header.payload_bytes = @intCast(count + 1);
        if (output.len < header.size() + count + 1) return error.Bounds;
        const at = try encodeHeader(header, output);
        @memcpy(output[at..][0..count], body[self.offset..][0..count]);
        output[at + count] = bodyCrc(body[self.offset..][0..count]);
        self.offset += count;
        return at + count + 1;
    }
};
pub const Assembly = struct {
    route: Route,
    sequence: u1,
    path: bool = false,
    broadcast: bool = false,
    bytes: [message_bytes]u8 = @splat(0),
    count: usize = 0,
    started: bool = false,
    complete: bool = false,
    pub fn consume(self: *Assembly, frame: Fragment) Error!void {
        const h = frame.header;
        if (self.complete or h.remaining != 0 or !std.meta.eql(self.route, h.route) or self.sequence != h.sequence or
            self.path != h.path or self.broadcast != h.broadcast or self.started == h.start) return error.Stale;
        if (frame.body.len == 0 or frame.body.len > self.bytes.len - self.count) return error.Bounds;
        @memcpy(self.bytes[self.count..][0..frame.body.len], frame.body);
        self.count += frame.body.len;
        self.started = true;
        self.complete = h.end;
    }
    pub fn body(self: *const Assembly) Error![]const u8 {
        if (!self.complete) return error.Stale;
        return self.bytes[0..self.count];
    }
};
pub const Op = enum(u8) { link_address = 1, connection_status = 2, enum_path = 0x10, allocate = 0x11, query = 0x12, resource_status = 0x13, clear = 0x14, dpcd_read = 0x20, dpcd_write = 0x21, i2c_read = 0x22, power_up = 0x24, power_down = 0x25 };
pub const Request = union(enum) {
    link_address: void,
    enum_path: u8,
    allocate: struct { port: u8, id: u8, pbn: u16, sink: ?u4 = 0 },
    query: struct { port: u8, id: u8 },
    clear: void,
    dpcd_read: struct { port: u8, address: u32, count: u8 },
    dpcd_write: struct { port: u8, address: u32, count: u8, bytes: [16]u8 = @splat(0) },
    edid: struct { port: u8, block: u8 },
    power_up: u8,
    power_down: u8,
    pub fn op(self: Request) Op {
        return switch (self) {
            .link_address => .link_address,
            .enum_path => .enum_path,
            .allocate => .allocate,
            .query => .query,
            .clear => .clear,
            .dpcd_read => .dpcd_read,
            .dpcd_write => .dpcd_write,
            .edid => .i2c_read,
            .power_up => .power_up,
            .power_down => .power_down,
        };
    }
    pub fn path(self: Request) bool {
        return self == .allocate or self == .enum_path or self == .clear;
    }
    pub fn port(self: Request) ?u8 {
        return switch (self) {
            .link_address, .clear => null,
            .enum_path, .power_up, .power_down => |value| value,
            .allocate => |value| value.port,
            .query => |value| value.port,
            .dpcd_read => |value| value.port,
            .dpcd_write => |value| value.port,
            .edid => |value| value.port,
        };
    }
    pub fn encode(self: Request, output: []u8) Error!usize {
        var bytes: [24]u8 = @splat(0);
        bytes[0] = @intFromEnum(self.op());
        if (self.port()) |value| if (value > 15) return error.Bounds;
        var count: usize = 1;
        switch (self) {
            .link_address, .clear => {},
            .enum_path, .power_up, .power_down => |value| {
                bytes[1] = value << 4;
                count = 2;
            },
            .allocate => |value| {
                if (value.id == 0 or value.id > 63 or (value.pbn == 0 and value.sink != null)) return error.Payload;
                bytes[1] = (value.port << 4) | @intFromBool(value.sink != null);
                bytes[2] = value.id;
                std.mem.writeInt(u16, bytes[3..5], value.pbn, .big);
                count = 5;
                if (value.sink) |sink| {
                    bytes[5] = @as(u8, sink) << 4;
                    count = 6;
                }
            },
            .query => |value| {
                if (value.id == 0 or value.id > 63) return error.Payload;
                bytes[1] = value.port << 4;
                bytes[2] = value.id;
                count = 3;
            },
            .dpcd_read => |value| {
                if (value.address > 0xfffff or value.count == 0 or value.count > 16 or value.address + value.count > 0x100000) return error.Bounds;
                bytes[1] = (value.port << 4) | @as(u8, @intCast(value.address >> 16));
                bytes[2] = @truncate(value.address >> 8);
                bytes[3] = @truncate(value.address);
                bytes[4] = value.count;
                count = 5;
            },
            .dpcd_write => |value| {
                if (value.address > 0xfffff or value.count == 0 or value.count > 16 or value.address + value.count > 0x100000) return error.Bounds;
                bytes[1] = (value.port << 4) | @as(u8, @intCast(value.address >> 16));
                bytes[2] = @truncate(value.address >> 8);
                bytes[3] = @truncate(value.address);
                bytes[4] = value.count;
                @memcpy(bytes[5..][0..value.count], value.bytes[0..value.count]);
                count = 5 + @as(usize, value.count);
            },
            .edid => |value| {
                if (value.block >= 32) return error.Bounds;
                const segment = value.block / 2;
                bytes[1] = (value.port << 4) | @as(u8, if (segment == 0) 1 else 2);
                count = 2;
                if (segment != 0) {
                    @memcpy(bytes[count..][0..4], &[_]u8{ 0x30, 1, segment, 0x10 });
                    count += 4;
                }
                @memcpy(bytes[count..][0..6], &[_]u8{ 0x50, 1, (value.block % 2) * 128, 0x10, 0x50, 128 });
                count += 6;
            },
        }
        if (output.len < count) return error.Bounds;
        @memcpy(output[0..count], bytes[0..count]);
        return count;
    }
};
pub const Guid = [16]u8;
pub const Peer = enum(u3) { none = 0, upstream = 1, branch = 2, sink = 3, legacy = 4, _ };
pub const Port = struct {
    number: u4 = 0,
    input: bool = false,
    peer: Peer = .none,
    messaging: bool = false,
    connected: bool = false,
    legacy_connected: bool = false,
    revision: u8 = 0,
    guid: Guid = @splat(0),
    streams: u4 = 0,
    sinks: u4 = 0,
};
pub const Branch = struct { guid: Guid, count: u4, ports: [15]Port = @splat(.{}) };
pub const Path = struct { port: u4, streams: u3, fec: bool, total_pbn: u16, free_pbn: u16, downstream_pbn: ?u16 = null };
pub const Reply = union(enum) {
    nack: struct { op: Op, guid: Guid, reason: u8, data: u8 },
    branch: Branch,
    path: Path,
    allocated: struct { port: u4, id: u7, pbn: u16 },
    queried: struct { port: u4, pbn: u16 },
    data: struct { port: u4, bytes: []const u8 },
    ack: Op,
};
pub fn reply(request: Request, bytes: []const u8) Error!Reply {
    if (bytes.len == 0 or bytes[0] & 0x7f != @intFromEnum(request.op())) return error.Stale;
    if (bytes[0] & 0x80 != 0) {
        if (bytes.len != 19) return error.Payload;
        return .{ .nack = .{ .op = request.op(), .guid = bytes[1..17].*, .reason = bytes[17], .data = bytes[18] } };
    }
    switch (request) {
        .link_address => {
            // A newly attached branch can have an uninitialized GUID. The
            // topology owner must write and re-query it before publication.
            if (bytes.len < 18 or bytes[17] & 0xf0 != 0) return error.Payload;
            var branch: Branch = .{ .guid = bytes[1..17].*, .count = @intCast(bytes[17]) };
            var seen: u16 = 0;
            var at: usize = 18;
            for (branch.ports[0..branch.count]) |*port| {
                if (bytes.len - at < 2) return error.Bounds;
                port.input = bytes[at] & 0x80 != 0;
                port.peer = @enumFromInt(@as(u3, @truncate(bytes[at] >> 4)));
                port.number = @truncate(bytes[at]);
                if (seen & (@as(u16, 1) << port.number) != 0) return error.Payload;
                seen |= @as(u16, 1) << port.number;
                port.messaging = bytes[at + 1] & 0x80 != 0;
                port.connected = bytes[at + 1] & 0x40 != 0;
                port.legacy_connected = !port.input and bytes[at + 1] & 0x20 != 0;
                if (bytes[at + 1] & @as(u8, if (port.input) 63 else 31) != 0) return error.Payload;
                at += 2;
                if (!port.input) {
                    if (bytes.len - at < 18) return error.Bounds;
                    port.revision = bytes[at];
                    port.guid = bytes[at + 1 ..][0..16].*;
                    port.streams = @truncate(bytes[at + 17] >> 4);
                    port.sinks = @truncate(bytes[at + 17]);
                    at += 18;
                }
            }
            if (at != bytes.len) return error.Payload;
            return .{ .branch = branch };
        },
        .enum_path => |port| {
            if ((bytes.len != 6 and bytes.len != 8) or bytes[1] >> 4 != port) return error.Payload;
            const result: Path = .{ .port = @intCast(port), .streams = @truncate(bytes[1] >> 1), .fec = bytes[1] & 1 != 0, .total_pbn = std.mem.readInt(u16, bytes[2..4], .big), .free_pbn = std.mem.readInt(u16, bytes[4..6], .big), .downstream_pbn = if (bytes.len == 8) std.mem.readInt(u16, bytes[6..8], .big) else null };
            if (result.free_pbn > result.total_pbn) return error.Payload;
            return .{ .path = result };
        },
        .allocate => |value| {
            if (bytes.len != 5 or bytes[1] != value.port << 4 or bytes[2] != value.id or std.mem.readInt(u16, bytes[3..5], .big) != value.pbn) return error.Payload;
            return .{ .allocated = .{ .port = @intCast(value.port), .id = @intCast(value.id), .pbn = value.pbn } };
        },
        .query => |value| {
            if (bytes.len != 4 or bytes[1] != value.port << 4) return error.Payload;
            return .{ .queried = .{ .port = @intCast(value.port), .pbn = std.mem.readInt(u16, bytes[2..4], .big) } };
        },
        .edid, .dpcd_read => {
            const count: usize = if (request == .edid) 128 else request.dpcd_read.count;
            if (bytes.len != count + 3 or bytes[1] != request.port().? or bytes[2] != count) return error.Payload;
            return .{ .data = .{ .port = @intCast(request.port().?), .bytes = bytes[3..] } };
        },
        .dpcd_write => |value| {
            if (bytes.len != 2 or bytes[1] != value.port) return error.Payload;
        },
        .power_up, .power_down => |value| {
            if (bytes.len != 2 or bytes[1] != value << 4) return error.Payload;
        },
        .clear => if (bytes.len != 1) return error.Payload,
    }
    return .{ .ack = request.op() };
}
pub const Notification = union(enum) {
    connection: struct { guid: Guid, port: u4, peer: Peer, input: bool, messaging: bool, connected: bool, legacy_connected: bool },
    resources: struct { guid: Guid, port: u4, streams: u3, fec: bool, available_pbn: u16 },
};
pub fn notification(bytes: []const u8) Error!Notification {
    if (bytes.len == 0) return error.Bounds;
    if (bytes[0] == @intFromEnum(Op.connection_status)) {
        if (bytes.len != 19 or bytes[1] & 15 != 0 or bytes[18] & 0x80 != 0) return error.Payload;
        return .{ .connection = .{ .guid = bytes[2..18].*, .port = @truncate(bytes[1] >> 4), .peer = @enumFromInt(@as(u3, @truncate(bytes[18]))), .input = bytes[18] & 8 != 0, .messaging = bytes[18] & 16 != 0, .connected = bytes[18] & 32 != 0, .legacy_connected = bytes[18] & 64 != 0 } };
    }
    if (bytes[0] == @intFromEnum(Op.resource_status)) {
        if (bytes.len != 20) return error.Payload;
        return .{ .resources = .{ .guid = bytes[2..18].*, .port = @truncate(bytes[1] >> 4), .streams = @truncate(bytes[1] >> 1), .fec = bytes[1] & 1 != 0, .available_pbn = std.mem.readInt(u16, bytes[18..20], .big) } };
    }
    return error.Unsupported;
}
