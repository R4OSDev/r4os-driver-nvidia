// GPIO metadata adaptation: complete original MIT notices follow.
// drivers/gpu/drm/nouveau/nvkm/subdev/bios/gpio.c
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
// drivers/gpu/drm/nouveau/nvkm/subdev/gpio/base.c
// /*
//  * Copyright 2011 Red Hat Inc.
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
// Bounded CPU copies of internal GPIO assignment tables. This is firmware
// metadata, not live GPIO state or authority to program/reset/read a GPU.
// Field facts: pinned NVIDIA DCB4.x GPIO4.0/4.1 and Nouveau bios/gpio.c.
const std = @import("std");
pub const max_entries = 255; // The table's complete u8 entry-count domain.
pub const Error = error{ Bounds, Version, Limit };
pub const hpd_functions = [_]u8{ 7, 8, 81, 82, 94, 95, 96 };
pub const Entry = struct {
    raw: u32,
    extra: ?u8,
    // Six-byte GPIO4.1 entries are present on the measured GA106. Nouveau
    // advances by the advertised stride and decodes the same five-byte
    // prefix. Retain the remaining byte without inventing its semantics.
    extension_byte: ?u8,
    line: u8,
    function: u8,
    dedicated_lock: bool,
    initialize_on: ?bool,
    output_select: ?u8,
    input_select: ?u8,
    gsync: ?bool,
    lock_pin: ?u8,
    off: u2,
    on: u2,
    pwm: bool,
    reserved_bits: u32,

    // Both states must describe input direction and opposite physical
    // levels. A GPIO definition that drives the wire is not HPD sensing.
    pub fn inputPolarity(self: Entry) ?bool {
        if (self.dedicated_lock or self.reserved_bits != 0 or
            self.off & 2 == 0 or self.on & 2 == 0 or self.off == self.on)
            return null;
        if (self.lock_pin) |pin| if (pin != 15) return null;
        return self.on & 1 != 0;
    }
};
pub const Status = enum { missing, ambiguous, invalid_input, mapped };
pub const Hpd = struct {
    function: u8 = 0,
    status: Status = .missing,
    matches: u16 = 0,
    entry_index: ?u8 = null,
    line: ?u8 = null,
    active_high: ?bool = null,
};
pub const Catalog = struct {
    offset: u16 = 0,
    version: u8 = 0,
    header_bytes: u8 = 0,
    entry_bytes: u8 = 0,
    count: u8 = 0,
    byte_length: u16 = 0,
    // External expander tables are not read/resolved by this internal table
    // reader. A missing internal function is not proof it is absent there.
    external_table_offset: ?u16 = null,
    raw: [max_entries][6]u8 = .{[_]u8{0} ** 6} ** max_entries,
    hpd: [7]Hpd = .{Hpd{}} ** 7,

    pub fn entry(self: *const Catalog, index: usize) Error!Entry {
        if (index >= self.count) return error.Bounds;
        if (self.entry_bytes > 6) return error.Limit;
        return decode(self.version, self.raw[index][0..self.entry_bytes]);
    }
};

pub fn decode(version: u8, bytes: []const u8) Error!Entry {
    if (version != 0x40 and version != 0x41) return error.Version;
    if (!supportedStride(version, bytes.len)) return error.Bounds;
    const raw = std.mem.readInt(u32, bytes[0..4], .little);
    const modern = version == 0x41;
    const extra: u8 = if (modern) bytes[4] else 0;
    return .{
        .raw = raw,
        .extra = if (modern) extra else null,
        .extension_byte = if (bytes.len == 6) bytes[5] else null,
        .line = @intCast(raw & (if (modern) @as(u32, 63) else 31)),
        .function = @truncate(raw >> 8),
        .dedicated_lock = modern and raw & 64 != 0,
        .initialize_on = if (modern) raw & 128 != 0 else null,
        .output_select = if (modern) @truncate(raw >> 16) else null,
        .input_select = if (modern) @intCast((raw >> 24) & 31) else null,
        .gsync = if (modern) raw & (1 << 29) != 0 else null,
        .lock_pin = if (modern) extra & 15 else null,
        .off = @intCast(if (modern) (extra >> 4) & 3 else (raw >> 27) & 3),
        .on = @intCast(if (modern) extra >> 6 else (raw >> 29) & 3),
        .pwm = raw & (1 << 31) != 0,
        .reserved_bits = if (modern) raw & (1 << 30) else 0,
    };
}

// The caller admits the entire returned byte_length into its disjoint ROM
// range catalog. All entry bytes are copied; no borrowed ROM view survives.
pub fn parse(image: []const u8, offset: u16) Error!Catalog {
    const header = try span(image, offset, 4);
    const version = header[0];
    if (version != 0x40 and version != 0x41) return error.Version;
    const size = header[1];
    const count = header[2];
    const stride = header[3];
    if (size < 6 or size > 64 or !supportedStride(version, stride)) return error.Limit;
    const length = @as(usize, size) + @as(usize, count) * stride;
    const bytes = try span(image, offset, length);
    const external = std.mem.readInt(u16, bytes[4..6], .little);
    var result = Catalog{
        .offset = offset,
        .version = version,
        .header_bytes = size,
        .entry_bytes = stride,
        .count = count,
        .byte_length = @intCast(length),
        .external_table_offset = if (external == 0) null else external,
    };
    for (0..count) |i| @memcpy(result.raw[i][0..stride], bytes[@as(usize, size) + i * stride ..][0..stride]);
    for (hpd_functions, &result.hpd) |function, *hpd| {
        hpd.function = function;
        for (0..count) |i| {
            const item = try result.entry(i);
            if (item.function != function) continue;
            hpd.matches += 1;
            if (hpd.matches != 1) {
                hpd.status = .ambiguous;
                hpd.entry_index = null;
                hpd.line = null;
                hpd.active_high = null;
                continue;
            }
            hpd.entry_index = @intCast(i);
            if (item.inputPolarity()) |polarity| {
                hpd.status = .mapped;
                hpd.line = item.line;
                hpd.active_high = polarity;
            } else hpd.status = .invalid_input;
        }
    }
    return result;
}

fn supportedStride(version: u8, bytes: usize) bool {
    return if (version == 0x41) bytes == 5 or bytes == 6 else bytes == 4;
}

fn span(bytes: []const u8, offset: usize, length: usize) Error![]const u8 {
    if (offset > bytes.len or length > bytes.len - offset) return error.Bounds;
    return bytes[offset..][0..length];
}
