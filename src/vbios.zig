const std = @import("std");

pub const max_rom_bytes = 1024 * 1024;
pub const max_ports = 32;
pub const Error = error{ Bounds, Signature, Version, Checksum, Limit, Identity, Missing, Duplicate, Overlap, Reference, Unsupported };
pub const Port = struct {
    index: u8 = 0,
    kind: u8 = 0,
    ccb: u8 = 0xf,
    connector: u8 = 0xf,
    heads: u8 = 0,
    or_mask: u8 = 0,
    location: u8 = 0,
    bus: u8 = 0,
    i2c: ?u8 = null,
    aux: ?u8 = null,
    connector_type: ?u8 = null,
    raw_path: u32 = 0,
    raw_config: u32 = 0,
};
pub const Result = struct {
    image_count: u8 = 0,
    rom_bytes: u32 = 0,
    image_offset: u32 = 0,
    image_bytes: u32 = 0,
    // This is only the x86 initialization checksum range, not authentication.
    checksum_bytes: u32 = 0,
    pci_extension_offset: u32 = 0,
    pci_extension_bytes: u16 = 0,
    pci_device: u16 = 0,
    first_extension_offset: ?u32 = null,
    // RM adds this bias to Falcon table/descriptor pointers. It is NOT the
    // first extension's address: intervening EFI images shift the pointers.
    // null records an impossible subtraction without disabling passive DCB.
    expansion_rom_offset: ?u32 = 0,
    bit_offset: u16 = 0,
    bit_entries: u8 = 0,
    falcon: ?FalconData = null,
    vbios_version: [5]u8 = .{0} ** 5,
    version_present: bool = false,
    dcb_offset: u16 = 0,
    dcb_version: u8 = 0,
    ccb_version: u8 = 0,
    port_count: u8 = 0,
    ports: [max_ports]Port = .{Port{}} ** max_ports,
};
pub const FalconData = struct { version: u8, offset: u32, bytes: u16 };

pub const PromStart = struct { offset: u32, ifr_version: u8 };
/// Pure interpretation of the pinned NVIDIA IFR envelope. Inputs are already
/// CPU copies; offsets never authorize reads outside the one-MB PROM aperture.
pub fn promStart(bytes: []const u8) Error!PromStart {
    if (bytes.len == 0 or bytes.len > max_rom_bytes) return error.Limit;
    const header = try span(bytes, 0, 12);
    if (u16le(header, 0) == 0xaa55) return .{ .offset = 0, .ifr_version = 0 };
    if (u32le(header, 0) != 0x4947564e) return error.Signature;
    const fixed1 = u32le(header, 4);
    const version: u8 = @truncate(fixed1 >> 8);
    const offset = switch (version) {
        1, 2 => u32le(try span(bytes, ((fixed1 >> 16) & 0x7fff) + 4, 4), 0),
        3 => blk: {
            const size = u32le(header, 8) & 0xfffff;
            const status = u32le(try span(bytes, size, 4), 0);
            const directory = try span(bytes, @as(u64, status) + 4096, 12);
            if (u32le(directory, 0) != 0x44524652) return error.Signature;
            break :blk u32le(directory, 8);
        },
        else => return error.Version,
    };
    if (offset < 12 or offset & 3 != 0) return error.Bounds;
    if (u16le(try span(bytes, offset, 0x1a), 0) != 0xaa55) return error.Signature;
    return .{ .offset = offset, .ifr_version = version };
}

/// No allocation, I/O, firmware execution or global publication. On failure the
/// caller receives an error, never a partially valid topology. All pointers
/// are ROM offsets, never arbitrary physical addresses. Display table pointers
/// are x86-relative; BIT 'p' uses the whole PCI ROM as in the pinned RM reader.
pub fn parse(rom: []const u8, expected_device: ?u16) Error!Result {
    if (rom.len == 0 or rom.len > max_rom_bytes) return error.Limit;
    var result: Result = .{};
    var cursor: usize = 0;
    var selected: ?[]const u8 = null;
    while (true) {
        if (result.image_count == 16) return error.Limit;
        const head = try span(rom, cursor, 0x1a);
        const signature = u16le(head, 0);
        if (signature != 0xaa55 and signature != 0x4e56 and signature != 0xbb77) return error.Signature;
        const pcir: usize = u16le(head, 0x18);
        if (pcir < 0x1c or pcir & 3 != 0) return error.Bounds;
        const pci = try span(rom, cursor + pcir, 0x18);
        if (!std.mem.eql(u8, pci[0..4], "PCIR") and !std.mem.eql(u8, pci[0..4], "NPDS") and !std.mem.eql(u8, pci[0..4], "RGIS")) return error.Signature;
        const revision = pci[0x0c];
        if (revision != 0 and revision != 3) return error.Version;
        const pci_bytes: usize = u16le(pci, 0x0a);
        if (pci_bytes < (if (revision == 3) @as(usize, 0x1c) else 0x18)) return error.Bounds;
        var image_bytes = @as(usize, u16le(pci, 0x10)) * 512;
        if (image_bytes == 0) return error.Bounds;
        var last = pci[0x15] & 0x80 != 0;
        var extension_bytes: u16 = 0;
        // NVIDIA's extension describes private subimages inside the standard
        // PCI image length. The pinned RM parser walks this same envelope.
        // Only documented revisions are accepted; it never skips a checksum.
        const extension_offset = (pcir + pci_bytes + 15) & ~@as(usize, 15);
        if (extension_offset + 4 <= image_bytes) {
            const extension_sig = u32le(try span(rom, cursor + extension_offset, 4), 0);
            if (extension_sig == 0x4544504e) {
                const extension = try span(rom, cursor + extension_offset, 10);
                const version = u16le(extension, 4);
                if (version != 0x100 and version != 0x101) return error.Version;
                const length = u16le(extension, 6);
                if (length < 10 or extension_offset + length > image_bytes) return error.Bounds;
                const whole_extension = try span(rom, cursor + extension_offset, length);
                extension_bytes = length;
                const subimage_bytes = @as(usize, u16le(extension, 8)) * 512;
                if (subimage_bytes == 0 or subimage_bytes > image_bytes or extension_offset + length > subimage_bytes) return error.Bounds;
                if (length > 10) last = whole_extension[10] & 0x80 != 0 else if (subimage_bytes < image_bytes) last = false;
                image_bytes = subimage_bytes;
            }
        }
        const image = try span(rom, cursor, image_bytes);
        _ = try span(image, pcir, pci_bytes);
        if (u16le(pci, 4) != 0x10de) return error.Identity;
        // RM's VBIOS_EXT (e0) images have private NV/NPDS or NV/RGIS
        // envelopes, not executable PCI option ROMs. Their device field is
        // container metadata (2200 on the measured GA106), not the board's
        // PCI device. Never use it to admit an x86/EFI image or execute code.
        const private_data = pci[0x14] == 0xe0 and signature != 0xaa55 and !std.mem.eql(u8, pci[0..4], "PCIR");
        if (!private_data) {
            if (expected_device) |device| {
                if (u16le(pci, 6) != device and !try deviceListContains(image, pcir, revision, device)) return error.Identity;
            }
        }
        if (pci[0x14] == 0) {
            if (signature != 0xaa55) return error.Signature;
            if (selected != null) return error.Duplicate;
            const initialization = @as(usize, head[2]) * 512;
            if (initialization == 0) return error.Bounds;
            if (sum(try span(image, 0, initialization)) != 0) return error.Checksum;
            selected = image;
            result.image_offset = @intCast(cursor);
            result.image_bytes = @intCast(image.len);
            result.checksum_bytes = @intCast(initialization);
            result.pci_extension_offset = if (extension_bytes != 0) @intCast(extension_offset) else 0;
            result.pci_extension_bytes = extension_bytes;
            result.pci_device = u16le(pci, 6);
        } else if (pci[0x14] == 3) {
            if (signature != 0xaa55) return error.Signature;
            if (u32le(image, 4) != 0x00000ef1) return error.Signature;
            const initialization = @as(usize, u16le(image, 2)) * 512;
            if (initialization == 0) return error.Bounds;
            _ = try span(image, 0, initialization);
        } else if (pci[0x14] == 0xe0) {
            if (result.first_extension_offset == null) result.first_extension_offset = @intCast(cursor);
        } else return error.Unsupported;
        result.image_count += 1;
        cursor += image.len;
        if (last) break;
    }
    result.rom_bytes = @intCast(cursor);
    const image = selected orelse return error.Missing;
    if (result.first_extension_offset) |offset| {
        if (offset != 0) result.expansion_rom_offset = if (offset >= result.image_bytes) offset - result.image_bytes else null;
    }
    var ranges: Ranges = .{};
    const header = try span(image, 0, 0x38);
    try ranges.add(0, 0x1a);
    try ranges.add(0x36, 2);
    const pcir = u16le(header, 0x18);
    try ranges.add(pcir, u16le(image, pcir + 0x0a));
    if (result.pci_extension_bytes != 0) try ranges.add(result.pci_extension_offset, result.pci_extension_bytes);
    try parseBit(rom[0..cursor], image, &ranges, &result);
    try parseDcb(image, &ranges, &result);
    return result;
}

fn deviceListContains(image: []const u8, pcir: usize, revision: u8, device: u16) Error!bool {
    if (revision != 3) return false;
    const offset = u16le(image, pcir + 8);
    if (offset == 0 or offset & 1 != 0) return false;
    var matched = false;
    for (0..64) |index| {
        const entry = u16le(try span(image, pcir + offset + index * 2, 2), 0);
        if (entry == 0) return matched;
        matched = matched or entry == device;
    }
    return error.Limit;
}

fn parseBit(rom: []const u8, image: []const u8, ranges: *Ranges, result: *Result) Error!void {
    const signature = "\xff\xb8BIT\x00";
    const offset = std.mem.indexOf(u8, image, signature) orelse return error.Missing;
    if (offset > 0xffff or std.mem.indexOf(u8, image[offset + signature.len ..], signature) != null) return error.Duplicate;
    const header = try span(image, offset, 12);
    if (u16le(header, 6) != 0x0100) return error.Version;
    const size: usize = header[8];
    const stride: usize = header[9];
    const count: usize = header[10];
    if (size < 12 or size > 64 or stride < 6 or stride > 32 or count == 0 or count > 64) return error.Limit;
    const table = try span(image, offset, size + stride * count);
    if (sum(table[0..size]) != 0) return error.Checksum;
    try ranges.add(offset, table.len);
    result.bit_offset = @intCast(offset);
    result.bit_entries = @intCast(count);
    var ids: [256]bool = .{false} ** 256;
    for (0..count) |index| {
        const entry = table[size + stride * index ..][0..stride];
        const id = entry[0];
        if (ids[id]) return error.Duplicate;
        ids[id] = true;
        const length: usize = u16le(entry, 2);
        const pointer: usize = if (stride >= 8) u32le(entry, 4) else u16le(entry, 4);
        // BIT 'b' describes a BIOS data range, not a regular table pointer.
        // Unknown pointer semantics are refused instead of reinterpreted.
        if (id == 'b') return error.Unsupported;
        if (id == 'p') {
            result.falcon = .{ .version = entry[1], .offset = @intCast(pointer), .bytes = @intCast(length) };
            if (length != 0) {
                if (pointer == 0) return error.Bounds;
                _ = try span(rom, pointer, length);
                const bit_start = result.image_offset + offset;
                if (pointer < bit_start + table.len and bit_start < pointer + length) return error.Overlap;
            }
            continue;
        }
        if (length == 0) continue;
        if (pointer == 0) return error.Bounds;
        const data = try span(image, pointer, length);
        if (pointer < offset + table.len and offset < pointer + length) return error.Overlap;
        if (id == 'i') {
            if (entry[1] != 2) return error.Version;
            if (data.len < 5) return error.Bounds;
            try ranges.add(pointer, length);
            result.vbios_version = .{ data[3], data[2], data[1], data[0], data[4] };
            result.version_present = true;
        }
    }
}

const SmallTable = struct { version: u8, count: u8, stride: u8, records: []const u8 };
fn smallTable(image: []const u8, offset: usize, header_min: u8, stride_min: u8, ranges: *Ranges) Error!SmallTable {
    if (offset == 0) return error.Missing;
    const header = try span(image, offset, 4);
    const size: usize = header[1];
    const count = header[2];
    const stride = header[3];
    if (size < header_min or size > 64 or count > 16 or stride < stride_min or stride > 16) return error.Limit;
    const bytes = try span(image, offset, size + @as(usize, count) * stride);
    try ranges.add(offset, bytes.len);
    return .{ .version = header[0], .count = count, .stride = stride, .records = bytes[size..] };
}

fn parseDcb(image: []const u8, ranges: *Ranges, result: *Result) Error!void {
    const offset: usize = u16le(image, 0x36);
    if (offset == 0) return error.Missing;
    const header = try span(image, offset, 23);
    if (header[0] != 0x40 and header[0] != 0x41) return error.Version;
    if (u32le(header, 6) != 0x4edcbdcb) return error.Signature;
    const size: usize = header[1];
    const count: usize = header[2];
    const stride: usize = header[3];
    if (size < 23 or size > 64 or count > max_ports or stride != 8) return error.Limit;
    const table = try span(image, offset, size + count * stride);
    try ranges.add(offset, table.len);
    result.dcb_offset = @intCast(offset);
    result.dcb_version = header[0];
    const ccb_offset = u16le(header, 4);
    const connector_offset = u16le(header, 0x14);
    const ccb: ?SmallTable = if (ccb_offset == 0) null else try smallTable(image, ccb_offset, 6, 4, ranges);
    const connectors: ?SmallTable = if (connector_offset == 0) null else try smallTable(image, connector_offset, 4, 2, ranges);
    if (ccb) |value| {
        if (value.version != 0x41) return error.Version;
        result.ccb_version = value.version;
    }
    if (connectors) |value| {
        if (value.version != 0x30 and value.version != 0x40) return error.Version;
    }
    for (0..count) |index| {
        const entry = table[size + index * stride ..][0..8];
        const path = u32le(entry, 0);
        const config = u32le(entry, 4);
        const kind: u8 = @truncate(path & 0xf);
        if (kind == 0xe) break;
        if (kind == 0xf or path == 0) continue;
        if (kind != 0 and kind != 1 and kind != 2 and kind != 3 and kind != 5 and kind != 6) return error.Unsupported;
        var port: Port = .{
            .index = @intCast(index),
            .kind = kind,
            .ccb = @truncate((path >> 4) & 0xf),
            .connector = @truncate((path >> 12) & 0xf),
            .heads = @truncate((path >> 8) & 0xf),
            .bus = @truncate((path >> 16) & 0xf),
            .location = @truncate((path >> 20) & 3),
            .or_mask = @truncate((path >> 24) & 0xf),
            .raw_path = path,
            .raw_config = config,
        };
        if (port.ccb != 0xf) {
            const comms = ccb orelse return error.Reference;
            if (port.ccb >= comms.count) return error.Reference;
            const raw = u32le(comms.records, @as(usize, port.ccb) * comms.stride);
            const i2c: u8 = @truncate(raw & 0x1f);
            const aux: u8 = @truncate((raw >> 5) & 0x1f);
            port.i2c = if (i2c == 0x1f) null else i2c;
            port.aux = if (aux == 0x1f) null else aux;
        }
        if (port.connector != 0xf) {
            const physical = connectors orelse return error.Reference;
            if (port.connector >= physical.count) return error.Reference;
            port.connector_type = physical.records[@as(usize, port.connector) * physical.stride];
        }
        result.ports[result.port_count] = port;
        result.port_count += 1;
    }
}

const Ranges = struct {
    const Range = struct { start: usize = 0, end: usize = 0 };
    // Header, DCB pointer, PCI, optional NPDE, BIT header/data and DCB/CCB/connector.
    values: [9]Range = .{Range{}} ** 9,
    count: usize = 0,
    fn add(self: *Ranges, start: usize, length: usize) Error!void {
        if (self.count == self.values.len) return error.Limit;
        for (self.values[0..self.count]) |prior| {
            if (start < prior.end and prior.start < start + length) return error.Overlap;
        }
        self.values[self.count] = .{ .start = start, .end = start + length };
        self.count += 1;
    }
};
fn span(bytes: []const u8, offset: usize, length: usize) Error![]const u8 {
    if (offset > bytes.len or length > bytes.len - offset) return error.Bounds;
    return bytes[offset..][0..length];
}
fn u16le(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}
fn u32le(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
fn sum(bytes: []const u8) u8 {
    var total: u8 = 0;
    for (bytes) |byte| {
        total +%= byte;
    }
    return total;
}
