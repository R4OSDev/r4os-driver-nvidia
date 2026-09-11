//! CPU-only bounded plans/copies for the pinned GSP command/status rings.
//! Stable caller-owned snapshots only. No DMA, linking writes, acknowledgement,
//! cursor/sequence mutation or firmware-ready claim. Runtime publication and
//! coherency belong to a separate execution owner.
// Layout, swap routing and cursor arithmetic adapted from NVIDIA 570.144
// msgq.c/msgq_priv.h. Original R4OS admission/copy interfaces: Apache-2.0.
// NVIDIA portions: MIT.
// Copyright (c) 2018-2019 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
const message = @import("gsp_message.zig");
pub const queue_bytes = 256 * 1024;
pub const header_bytes = 32;
pub const Error = message.Error || error{ NotReady, Header, Cursor, Unavailable };
pub const Queue = enum { command, status };
pub const Location = struct { queue: Queue, offset: usize };
pub const Layout = struct { rx_offset: u32, entries_offset: u32, slots: u32, flags: u32 };
pub const Header = struct { layout: Layout, write: u32 };
pub const Link = struct { command: Header, status: Header, swapped: bool, command_read: Location, status_read: Location };
pub const Span = struct { offset: usize = 0, bytes: usize = 0 };
pub const Plan = struct {
    spans: [2]Span,
    span_count: usize,
    slots: u32,
    available_before: u32,
    current_cursor: u32,
    next_cursor: u32,
};
pub const Received = struct { plan: Plan, record: message.Record };
fn word(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
fn validate(layout: Layout) Error!void {
    if (layout.flags & ~@as(u32, 1) != 0 or
        layout.rx_offset < header_bytes or layout.rx_offset > queue_bytes - 4 or layout.rx_offset % 4 != 0 or
        layout.entries_offset < layout.rx_offset + 4 or layout.entries_offset % message.element_bytes != 0 or
        layout.entries_offset > queue_bytes - 2 * message.element_bytes or
        layout.slots != (queue_bytes - layout.entries_offset) / message.element_bytes) return error.Header;
}
pub fn inspect(bytes: []const u8) Error!Header {
    if (bytes.len != header_bytes) return error.Length;
    if (std.mem.allEqual(u8, bytes, 0)) return error.NotReady;
    if (word(bytes, 0) != 0 or word(bytes, 4) != queue_bytes or word(bytes, 8) != message.element_bytes) return error.Header;
    const result = Header{ .layout = .{ .rx_offset = word(bytes, 24), .entries_offset = word(bytes, 28), .slots = word(bytes, 12), .flags = word(bytes, 20) }, .write = word(bytes, 16) };
    try validate(result.layout);
    if (result.write >= result.layout.slots) return error.Cursor;
    return result;
}

/// Compute routing only. Agreement requires both swap bits; each ring retains
/// its own admitted RX-header offset (e.g. CPU 32, firmware 64).
pub fn inspectLink(command: []const u8, status: []const u8) Error!Link {
    const own = try inspect(command);
    const peer = try inspect(status);
    const swapped = own.layout.flags & peer.layout.flags & 1 != 0;
    const own_rx = Location{ .queue = .command, .offset = own.layout.rx_offset };
    const peer_rx = Location{ .queue = .status, .offset = peer.layout.rx_offset };
    return .{ .command = own, .status = peer, .swapped = swapped, .command_read = if (swapped) peer_rx else own_rx, .status_read = if (swapped) own_rx else peer_rx };
}
fn available(layout: Layout, read: u32, write: u32) Error!u32 {
    try validate(layout);
    if (read >= layout.slots or write >= layout.slots) return error.Cursor;
    return if (write >= read) write - read else layout.slots - read + write;
}
fn plan(layout: Layout, cursor: u32, count: u32, capacity: u32) Error!Plan {
    if (count == 0 or count > message.max_elements) return error.Elements;
    if (count > capacity) return error.Unavailable;
    const first = @min(count, layout.slots - cursor);
    const second = count - first;
    return .{
        .spans = .{
            .{ .offset = layout.entries_offset + @as(usize, cursor) * message.element_bytes, .bytes = @as(usize, first) * message.element_bytes },
            if (second == 0) .{} else .{ .offset = layout.entries_offset, .bytes = @as(usize, second) * message.element_bytes },
        },
        .span_count = if (second == 0) 1 else 2,
        .slots = count,
        .available_before = capacity,
        .current_cursor = cursor,
        .next_cursor = if (second == 0 and cursor + count < layout.slots) cursor + count else second,
    };
}
pub fn receive(layout: Layout, read: u32, write: u32, count: u32) Error!Plan {
    return plan(layout, read, count, try available(layout, read, write));
}
pub fn transmit(layout: Layout, write: u32, read: u32, count: u32) Error!Plan {
    const used = try available(layout, read, write);
    return plan(layout, write, count, layout.slots - used - 1);
}
fn overlap(first: []const u8, second: []const u8) bool {
    if (first.len == 0 or second.len == 0) return false;
    const a = @intFromPtr(first.ptr);
    const b = @intFromPtr(second.ptr);
    return if (a >= b) a - b < second.len else b - a < first.len;
}

/// Scratch is disposable on failure. Queue/cursors remain unchanged, and a
/// returned plan is not a published acknowledgement or sequence advancement.
pub fn gather(profile: message.Profile, layout: Layout, read: u32, write: u32, sequence: u32, snapshot: []const u8, scratch: []u8) Error!Received {
    if (snapshot.len != queue_bytes) return error.Length;
    const first = try receive(layout, read, write, 1);
    const offset = first.spans[0].offset;
    const shape = try message.inspectPrefix(profile, snapshot[offset..][0..message.header_bytes]);
    const transfer = try receive(layout, read, write, shape.elements);
    if (scratch.len < shape.storage_bytes) return error.Output;
    const output = scratch[0..shape.storage_bytes];
    if (overlap(snapshot, output)) return error.Overlap;
    var copied: usize = 0;
    for (transfer.spans[0..transfer.span_count]) |span| {
        @memcpy(output[copied..][0..span.bytes], snapshot[span.offset..][0..span.bytes]);
        copied += span.bytes;
    }
    return .{ .plan = transfer, .record = try message.decode(profile, output, sequence) };
}

/// Scatter a complete already encoded/validated record into a CPU shadow.
/// All admission happens before any queue byte changes. Publishing its slots
/// and then its write cursor, with proper synchronization, is caller work.
pub fn scatter(profile: message.Profile, layout: Layout, write: u32, read: u32, sequence: u32, encoded: []const u8, shadow: []u8) Error!Plan {
    if (shadow.len != queue_bytes) return error.Length;
    const record = try message.decode(profile, encoded, sequence);
    const transfer = try transmit(layout, write, read, record.shape.elements);
    if (overlap(encoded, shadow)) return error.Overlap;
    var copied: usize = 0;
    for (transfer.spans[0..transfer.span_count]) |span| {
        @memcpy(shadow[span.offset..][0..span.bytes], encoded[copied..][0..span.bytes]);
        copied += span.bytes;
    }
    return transfer;
}
