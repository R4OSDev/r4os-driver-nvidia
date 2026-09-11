//! Bounded CPU framing for the pinned GA106 cleartext GSP/RPC transport.
//! Inputs must be stable, caller-owned CPU snapshots, never live DMA views.
//! This codec owns no queue, advances no sequence/cursor and acknowledges
//! nothing. A separate transport owner must synchronize, gather and publish.
// Field layout/assignment and checksum from NVIDIA 570.144
// message_queue_priv.h, message_queue_cpu.c, g_rpc-message-header.h,
// rpc_headers.h and rpc_common.c. Original R4OS admission/interfaces: Apache-2.0.
// NVIDIA portions: MIT.
// Copyright (c) 2019-2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2019-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2008-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2017-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// Copyright (c) 2020-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
const std = @import("std");
const firmware = @import("firmware.zig");
pub const element_bytes = 4096;
pub const max_elements = 16;
pub const max_bytes = max_elements * element_bytes;
pub const outer_bytes = 48;
pub const rpc_bytes = 32;
pub const header_bytes = outer_bytes + rpc_bytes;
pub const max_payload_bytes = max_bytes - header_bytes;
pub const header_version: u32 = 0x03000000;
pub const signature: u32 = 0x43505256;
pub const pending: u32 = 0xffffffff;
pub const Error = error{ Profile, Length, Elements, Version, Signature, Sequence, Checksum, Padding, Output, Overlap };
pub const Profile = struct { chip_id: u16, confidential_compute: bool = false };
pub const Rpc = struct {
    function: u32,
    result: u32 = pending,
    result_private: u32 = pending,
    sequence: u32 = 0,
    cpu_rm_gfid: u32 = 0,
};
pub const Shape = struct {
    message_bytes: usize,
    checksum_bytes: usize,
    storage_bytes: usize,
    elements: u32,
};
pub const Record = struct { shape: Shape, queue_sequence: u32, rpc: Rpc, payload: []const u8 };

comptime {
    if (!std.mem.eql(u8, firmware.lock.rm_version, "570.144") or
        !std.mem.eql(u8, firmware.lock.source_commit, "8ec351aeb96a93a4bb69ccc12a542bf8a8df2b6f"))
        @compileError("GSP framing requires a new original-source ABI comparison");
}
fn profileCheck(profile: Profile) Error!void {
    if (profile.chip_id != 0x176 or profile.confidential_compute) return error.Profile;
}
fn word(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
fn put(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
fn shapeFor(message_bytes: usize) Shape {
    std.debug.assert(message_bytes >= header_bytes and message_bytes <= max_bytes);
    const elements = (message_bytes + element_bytes - 1) / element_bytes;
    return .{ .message_bytes = message_bytes, .checksum_bytes = std.mem.alignForward(usize, message_bytes, 8), .storage_bytes = elements * element_bytes, .elements = @intCast(elements) };
}
fn checksum(bytes: []const u8) u32 {
    std.debug.assert(bytes.len != 0 and bytes.len <= max_bytes and bytes.len % 8 == 0);
    // XOR of 64-bit words, folded high/low, equals XOR of little-endian u32s.
    // Byte reads avoid imposing the original C pointer's alignment on callers.
    var value: u32 = 0;
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 4) value ^= word(bytes, offset);
    return value;
}

/// A size admission only. The transport can gather at most 16 complete slots
/// after this succeeds; sequence, checksum and RPC payload are not yet accepted.
pub fn inspectPrefix(profile: Profile, bytes: []const u8) Error!Shape {
    try profileCheck(profile);
    if (bytes.len < header_bytes) return error.Length;
    const elements = word(bytes, 40);
    if (elements == 0 or elements > max_elements) return error.Elements;
    const length = word(bytes, outer_bytes + 8);
    if (length < rpc_bytes or length > max_bytes - outer_bytes) return error.Length;
    const shape = shapeFor(outer_bytes + @as(usize, length));
    if (shape.elements != elements) return error.Elements;
    if (word(bytes, outer_bytes) != header_version) return error.Version;
    if (word(bytes, outer_bytes + 4) != signature) return error.Signature;
    return shape;
}

/// Accept exactly the gathered slot span. Padding to eight bytes is part of
/// the checksum; unused bytes later in the final slot are not message bytes.
/// Unknown function/result values remain opaque for the later RPC dispatcher.
pub fn decode(profile: Profile, bytes: []const u8, expected_queue_sequence: u32) Error!Record {
    const shape = try inspectPrefix(profile, bytes);
    if (bytes.len != shape.storage_bytes) return error.Length;
    if (!std.mem.allEqual(u8, bytes[shape.message_bytes..shape.checksum_bytes], 0)) return error.Padding;
    if (checksum(bytes[0..shape.checksum_bytes]) != 0) return error.Checksum;
    const sequence = word(bytes, 36);
    if (sequence != expected_queue_sequence) return error.Sequence;
    return .{
        .shape = shape,
        .queue_sequence = sequence,
        .rpc = .{ .function = word(bytes, 60), .result = word(bytes, 64), .result_private = word(bytes, 68), .sequence = word(bytes, 72), .cpu_rm_gfid = word(bytes, 76) },
        .payload = bytes[header_bytes..shape.message_bytes],
    };
}

/// Encode into caller storage, leaving it untouched on admission failure.
/// Payload must not overlap the written slot span; no hidden staging allocation.
pub fn encode(profile: Profile, queue_sequence: u32, rpc: Rpc, payload: []const u8, output: []u8) Error!Shape {
    try profileCheck(profile);
    if (payload.len > max_payload_bytes) return error.Length;
    const shape = shapeFor(header_bytes + payload.len);
    if (output.len < shape.storage_bytes) return error.Output;
    const data = output[0..shape.storage_bytes];
    if (payload.len != 0) {
        const source = @intFromPtr(payload.ptr);
        const target = @intFromPtr(data.ptr);
        // Subtraction avoids address-end overflow in this alias check.
        if (if (source >= target) source - target < data.len else target - source < payload.len) return error.Overlap;
    }
    @memset(data, 0);
    put(data, 36, queue_sequence);
    put(data, 40, shape.elements);
    put(data, outer_bytes, header_version);
    put(data, outer_bytes + 4, signature);
    put(data, outer_bytes + 8, @intCast(rpc_bytes + payload.len));
    put(data, 60, rpc.function);
    put(data, 64, rpc.result);
    put(data, 68, rpc.result_private);
    put(data, 72, rpc.sequence);
    put(data, 76, rpc.cpu_rm_gfid);
    @memcpy(data[header_bytes..shape.message_bytes], payload);
    put(data, 32, checksum(data[0..shape.checksum_bytes]));
    return shape;
}
