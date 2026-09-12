// Reference attribution (Nouveau MIT); R4OS bounded implementation is Apache-2.0.
// Nvidia/Nouveau/drivers/gpu/drm/nouveau/nvkm/subdev/bios/xpio.c
// /*
//  * Copyright 2012 Red Hat Inc.
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
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
//  * THE COPYRIGHT HOLDER(S) OR AUTHOR(S) BE LIABLE FOR ANY CLAIM, DAMAGES OR
//  * OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
//  * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  * OTHER DEALINGS IN THE SOFTWARE.
//  *
//  * Authors: Ben Skeggs
//  */
//! Bounded external GPIO metadata from NVIDIA's DCB4.x specification.
//! The master and each specific table have their OWN headers. External
//! function numbers are type-specific: 7/8 are never internal HPD A/B.
//! No expander access, pin programming or live connection inference.
const std = @import("std");
const gpio = @import("vbios_gpio.zig");
pub const max_tables = 16;
pub const max_entries = 256; // Total accepted entries, not a per-table truncation.
pub const Error = error{ Bounds, Version, Limit };
pub const Range = struct { offset: u16 = 0, bytes: u16 = 0 };
pub const Table = struct {
    index: u8 = 0,
    range: Range = .{},
    header_bytes: u8 = 0,
    count: u8 = 0,
    first: u16 = 0,
    kind: u8 = 0,
    address: u8 = 0, // Original shifted seven-bit address; bit0 must be zero.
    flags: u8 = 0,
    ccb: ?u8 = null,
    i2c: ?u8 = null,
    aux: ?u8 = null,
    bus_known: bool = false,
    interrupt: ?gpio.Hpd = null,

    pub fn knownWiring(self: Table) bool {
        return self.kind >= 1 and self.kind <= 10 and self.address != 0 and
            self.address & 1 == 0 and self.flags & 0xec == 0 and self.flags & 3 <= 1 and
            self.ccb != null and self.i2c != null and self.bus_known;
    }
};
pub const Signal = struct {
    status: gpio.Status = .missing,
    matches: u16 = 0,
    table: ?u8 = null,
    entry: ?u8 = null,
    line: ?u8 = null,
    active_high: ?bool = null,
};
pub const Catalog = struct {
    master: Range = .{},
    master_count: u8 = 0,
    table_count: u8 = 0,
    entry_count: u16 = 0,
    tables: [max_tables]Table = @splat(.{}),
    raw: [max_entries][4]u8 = @splat(@splat(0)),

    pub fn entry(self: *const Catalog, table: usize, index: usize) Error!gpio.Entry {
        if (table >= self.table_count or index >= self.tables[table].count or
            self.tables[table].first + index >= self.entry_count) return error.Bounds;
        // Specific-table 4.0 uses its documented four-byte entry, even
        // when the INTERNAL GPIO table uses a 4.1 five/six-byte stride.
        return gpio.decode(0x40, &self.raw[self.tables[table].first + index]);
    }
    /// Only external type9 functions 1..4 name Connector DP2DVI A..D.
    /// Type9 is deprecated on Fermi+; preserving its wiring is not support
    /// for executing that encoder. Other types cannot become HPD inputs.
    pub fn dongle(self: *const Catalog, ccb: u8, bit: u2) Signal {
        var result: Signal = .{};
        for (self.tables[0..self.table_count], 0..) |*table, ti| {
            if (table.kind != 9 or table.ccb != ccb) continue;
            for (0..table.count) |i| {
                const item = self.entry(ti, i) catch continue;
                if (item.function != @as(u8, bit) + 1) continue;
                result.matches += 1;
                if (result.matches > 1) {
                    result.status = .ambiguous;
                    result.table = null; result.entry = null;
                    result.line = null; result.active_high = null;
                    continue;
                }
                result.table = table.index; result.entry = @intCast(i);
                if (table.knownWiring() and item.inputPolarity() != null) {
                    result.status = .mapped; result.line = item.line;
                    result.active_high = item.inputPolarity();
                } else result.status = .invalid_input;
            }
        }
        return result;
    }
};

/// Copies all accepted entries. The caller admits master/specific ranges
/// into the same disjoint ROM catalog as BIT/DCB/CCB/internal GPIO.
pub fn parse(image: []const u8, offset: u16) Error!Catalog {
    const master = try header(image, offset, 4, 2);
    if (master.count > max_tables) return error.Limit;
    var result: Catalog = .{ .master = .{ .offset = offset, .bytes = master.length }, .master_count = master.count };
    for (0..master.count) |index| {
        const pointer = std.mem.readInt(u16, image[@as(usize, offset) + master.size + index * 2 ..][0..2], .little);
        if (pointer == 0) continue;
        const specific = try header(image, pointer, 7, 4);
        if (@as(usize, result.entry_count) + specific.count > max_entries) return error.Limit;
        const bytes = image[pointer..][0..specific.length];
        result.tables[result.table_count] = .{ .index = @intCast(index),
            .range = .{ .offset = pointer, .bytes = specific.length },
            .header_bytes = specific.size, .count = specific.count, .first = result.entry_count,
            .kind = bytes[4], .address = bytes[5], .flags = bytes[6] };
        for (0..specific.count) |i| @memcpy(&result.raw[result.entry_count + i], bytes[specific.size + i * 4 ..][0..4]);
        result.entry_count += specific.count;
        result.table_count += 1;
    }
    return result;
}
const Header = struct { size: u8, count: u8, length: u16 };
fn header(image: []const u8, offset: usize, min_size: u8, stride: u8) Error!Header {
    if (offset > image.len or image.len - offset < 4) return error.Bounds;
    const bytes = image[offset..];
    if (bytes[0] != 0x40) return error.Version;
    if (bytes[1] < min_size or bytes[1] > 64 or bytes[3] != stride) return error.Limit;
    const length = @as(u16, bytes[1]) + @as(u16, bytes[2]) * stride;
    if (length > bytes.len) return error.Bounds;
    return .{ .size = bytes[1], .count = bytes[2], .length = length };
}
