// Bounded, unvalidated byte records from an already copied PROM. This is not
// a second topology parser: these records never authorize hardware access or
// publish ports. They explain rejected firmware without logging a whole ROM.
const std = @import("std");
const vbios = @import("vbios.zig");

pub fn inspect(rom: []const u8, sink: anytype) void {
    if (rom.len == 0 or rom.len > vbios.max_rom_bytes) return;
    var cursor: usize = 0;
    var selected: ?[]const u8 = null;
    var selected_offset: usize = 0;
    for (0..16) |_| {
        const head = span(rom, cursor, 0x38) orelse break;
        sink.record("image", cursor, head);
        const pcir = le16(head, 0x18);
        const pci = span(rom, cursor + pcir, 0x18) orelse break;
        sink.record("pci", cursor + pcir, pci);
        if (!std.mem.eql(u8, pci[0..4], "PCIR") and !std.mem.eql(u8, pci[0..4], "NPDS") and !std.mem.eql(u8, pci[0..4], "RGIS")) break;
        var bytes = @as(usize, le16(pci, 0x10)) * 512;
        var last = pci[0x15] & 0x80 != 0;
        const ext_offset = (@as(usize, pcir) + le16(pci, 0x0a) + 15) & ~@as(usize, 15);
        if (span(rom, cursor + ext_offset, 16)) |ext| {
            if (std.mem.eql(u8, ext[0..4], "NPDE")) {
                sink.record("npde", cursor + ext_offset, ext);
                if (le16(ext, 6) > 10) last = ext[10] & 0x80 != 0;
                bytes = @as(usize, le16(ext, 8)) * 512;
            }
        }
        if (bytes == 0) break;
        const image = span(rom, cursor, bytes) orelse break;
        if (pci[0x0c] == 3 and le16(pci, 8) != 0) {
            const list = @as(usize, pcir) + le16(pci, 8);
            if (span(image, list, 128)) |data| sink.record("pci-devices", cursor + list, data);
        }
        if (pci[0x14] == 0 and selected == null) {
            selected = image;
            selected_offset = cursor;
        }
        cursor += bytes;
        if (last) break;
    }
    const image = selected orelse return;
    if (std.mem.indexOf(u8, image, "\xff\xb8BIT\x00")) |offset| {
        if (span(image, offset, 12)) |head| {
            sink.record("bit-header", selected_offset + offset, head);
            const bytes = @as(usize, head[8]) + @as(usize, head[9]) * head[10];
            if (head[8] >= 12 and head[8] <= 64 and head[9] >= 6 and head[9] <= 32 and head[10] <= 64 and bytes <= 448) {
                if (span(image, offset, bytes)) |table| {
                    sink.record("bit", selected_offset + offset, table);
                    for (0..head[10]) |index| {
                        const entry = table[head[8] + index * head[9] ..][0..6];
                        if (entry[0] == 'i' or entry[0] == 'b') {
                            const pointer = le16(entry, 4);
                            const length = @min(le16(entry, 2), 64);
                            if (span(image, pointer, length)) |data| sink.record("bit-data", selected_offset + pointer, data);
                        }
                    }
                }
            }
        }
    }
    const head = span(image, 0, 0x38) orelse return;
    const dcb_offset = le16(head, 0x36);
    const dcb = span(image, dcb_offset, 23) orelse return;
    smallTable(image, selected_offset, dcb_offset, "dcb", sink);
    smallTable(image, selected_offset, le16(dcb, 4), "ccb", sink);
    smallTable(image, selected_offset, le16(dcb, 0x14), "connectors", sink);
}

fn smallTable(image: []const u8, base: usize, offset: usize, label: []const u8, sink: anytype) void {
    if (offset == 0) return;
    const head = span(image, offset, 4) orelse return;
    const length = @as(usize, head[1]) + @as(usize, head[2]) * head[3];
    if (head[1] < 4 or head[1] > 64 or head[2] > 32 or head[3] > 16 or length > 320) {
        sink.record(label, base + offset, head);
        return;
    }
    if (span(image, offset, length)) |bytes| sink.record(label, base + offset, bytes);
}
fn span(bytes: []const u8, offset: usize, length: usize) ?[]const u8 {
    if (offset > bytes.len or length > bytes.len - offset) return null;
    return bytes[offset..][0..length];
}
fn le16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}
