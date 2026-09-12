// DCB decoding adaptation: Nouveau original notices below (MIT).
// Nouveau/drivers/gpu/drm/nouveau/nvkm/subdev/bios/i2c.c
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
// Nouveau/drivers/gpu/drm/nouveau/nvkm/subdev/bios/conn.c
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
// Passive DCB metadata only. No GPIO numbers, connection state, MMIO access
// or firmware ownership can be inferred from these wiring declarations.
// Field definitions: pinned NVIDIA DCB 4.x specification, CCB 4.1 and
// connector table 3.0/4.0; cross-checked against Nouveau bios/i2c.c and conn.c.
const std = @import("std");
pub const max_entries = 16;

pub const Communication = struct {
    index: u8 = 0,
    entry_bytes: u8 = 0,
    raw: u32 = 0,
    i2c: ?u8 = null,
    aux: ?u8 = null,
    speed_code: u8 = 0,
    // null means default/unknown, never permission for unlimited bus speed.
    max_i2c_hz: ?u32 = null,
    reserved_bits: u32 = 0,
    display_paths: u32 = 0,
    connector_mask: u16 = 0,
};
pub const Connector = struct {
    index: u8 = 0,
    entry_bytes: u8 = 0,
    raw: u32 = 0,
    kind: u8 = 0xff,
    location: u8 = 0,
    // These are sets of named GPIO functions A..G/A..D, NOT pin indices
    // or live signal levels. Extended bits are unavailable in short records.
    hpd_mask: u8 = 0,
    dp_dvi_mask: u8 = 0,
    mux_mask: ?u8 = null,
    self_refresh: ?bool = null,
    lcd_id: ?u8 = null,
    reserved_bits: u32 = 0,
    // DCB4.1 DFP masks name fixed pad macros, not candidate SORs. Other
    // paths keep the encoder mask. Neither describes the active RM route.
    display_paths: u32 = 0,
    heads: u8 = 0,
    encoder_mask: u8 = 0,
    pad_mask: u8 = 0,
    logical_bus_mask: u16 = 0,
    ccb_mask: u16 = 0,
};

pub fn communication(index: u8, bytes: []const u8) error{Bounds}!Communication {
    if (index >= max_entries or bytes.len < 4 or bytes.len > 16) return error.Bounds;
    const raw = std.mem.readInt(u32, bytes[0..4], .little);
    const drive: u8 = @intCast(raw & 31);
    const aux: u8 = @intCast((raw >> 5) & 31);
    const speed: u8 = @intCast(raw >> 28);
    return .{
        .index = index,
        .entry_bytes = @intCast(bytes.len),
        .raw = raw,
        .i2c = if (drive == 31) null else drive,
        .aux = if (aux == 31) null else aux,
        .speed_code = speed,
        .max_i2c_hz = switch (speed) {
            1 => 100_000,
            2 => 200_000,
            3 => 400_000,
            4 => 800_000,
            5 => 1_600_000,
            6 => 3_400_000,
            7 => 60_000,
            8 => 300_000,
            else => null,
        },
        .reserved_bits = raw & 0x0ffffc00,
    };
}

pub fn connector(index: u8, bytes: []const u8) error{Bounds}!Connector {
    if (index >= max_entries or bytes.len < 2 or bytes.len > 16) return error.Bounds;
    var raw: u32 = 0;
    for (bytes[0..@min(bytes.len, 4)], 0..) |byte, i| raw |= @as(u32, byte) << @as(u5, @intCast(8 * i));
    var result = Connector{
        .index = index,
        .entry_bytes = @intCast(bytes.len),
        .raw = raw,
        .kind = bytes[0],
        .location = bytes[1] & 15,
        .hpd_mask = (bytes[1] >> 4) & 3,
        .dp_dvi_mask = bytes[1] >> 6,
    };
    if (bytes.len >= 4) {
        result.hpd_mask |= ((bytes[2] & 3) << 2) | ((bytes[3] & 7) << 4);
        result.dp_dvi_mask |= bytes[2] & 12;
        result.mux_mask = bytes[2] >> 4;
        result.self_refresh = bytes[3] & 8 != 0;
        result.lcd_id = (bytes[3] >> 4) & 7;
        result.reserved_bits = raw & 0x80000000;
    }
    return result;
}
