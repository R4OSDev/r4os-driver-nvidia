// CPU-only preparation from the pinned 570.144 FWSEC/FRTS implementation.
// No authentication, DMA address, GPU upload or command execution is implied.
const std = @import("std");
const fwsec = @import("fwsec.zig");
const vbios = @import("vbios.zig");
pub const Error = fwsec.Error || error{ Fuse, Capacity, Address };
pub const Fuses = struct { debug_disable_raw: u32, ucode_version_raw: u32, ucode_id: u8 };
pub const Command = union(enum) { sb, frts: u64 };
pub const Selection = struct { entry: fwsec.Entry, signature: fwsec.Range, fuse_version: u32, debug: bool };
pub const Prepared = struct { selection: Selection, bytes: u32, command: u32 };

pub fn debugEnabled(raw: u32) Error!bool {
    if (raw == 0xffffffff) return error.Fuse;
    return raw & 1 == 0;
}

// GA100 HAL (also selected for GA106) uses highest-set-bit + 1 on the
// complete register, not population count or truncation to the field mask.
pub fn fuseVersion(raw: u32) Error!u32 {
    if (raw == 0xffffffff) return error.Fuse;
    return 32 - @as(u32, @clz(raw));
}

pub fn supported(entry: *const fwsec.Entry) bool {
    return (entry.application == 0x45 or entry.application == 0x85) and
        entry.target == 7 and entry.descriptor_version == 3 and entry.flags == 1 and
        entry.engine_mask == 0x400 and entry.ucode_id >= 1 and entry.ucode_id <= 16;
}

// Never substitute production for debug, use a legacy entry, or silently
// choose among multiple targets. The catalog must come from fwsec.parse.
pub fn variant(catalog: *const fwsec.Catalog, debug: bool) Error!fwsec.Entry {
    if (catalog.count > catalog.entries.len) return error.Limit;
    const application: u8 = if (debug) 0x45 else 0x85;
    var chosen: ?fwsec.Entry = null;
    for (catalog.entries[0..catalog.count]) |*entry| {
        if (entry.application != application) continue;
        if (chosen != null) return error.Duplicate;
        chosen = entry.*;
    }
    const entry = chosen orelse return error.Missing;
    if (!supported(&entry)) return error.Unsupported;
    return entry;
}

pub fn select(rom: []const u8, board: *const vbios.Result, fuses: Fuses) Error!Selection {
    const catalog = try fwsec.parse(rom, board);
    const debug = try debugEnabled(fuses.debug_disable_raw);
    const entry = try variant(&catalog, debug);
    if (fuses.ucode_id != entry.ucode_id) return error.Fuse;
    const version = try fuseVersion(fuses.ucode_version_raw);
    return .{ .entry = entry, .signature = try fwsec.signatureForFuse(&entry, version), .fuse_version = version, .debug = debug };
}

// Byte layout is checked by Tools/Bootstrap/FwsecAbi.c against the original
// NVIDIA typedefs. Explicit LE writes avoid host ABI and uninitialized padding.
pub fn commandBytes(command: Command) Error!struct { data: [48]u8, length: u32, id: u32 } {
    var data: [48]u8 = @splat(0);
    put(&data, 0, 1);
    put(&data, 4, 24);
    put(&data, 20, 2); // Read VBIOS through firmware; no caller image address.
    switch (command) {
        .sb => return .{ .data = data, .length = 24, .id = 0x19 },
        .frts => |offset| {
            // This only encodes a caller-supplied FB offset. The future loader
            // must independently establish GPU ownership and WPR boundaries.
            if (offset == 0 or offset & 0xfff != 0 or
                offset / 4096 > @as(u64, std.math.maxInt(u32)) + 1 - 0x100) return error.Address;
            put(&data, 24, 1);
            put(&data, 28, 20);
            put(&data, 32, @intCast(offset / 4096));
            put(&data, 36, 0x100);
            put(&data, 40, 2);
            return .{ .data = data, .length = 48, .id = 0x15 };
        },
    }
}

/// Reparse the same immutable ROM instead of trusting caller-edited Entry or
/// Selection offsets. Every rejection precedes the first destination write.
/// Only the returned prefix of output is modified; the ROM cannot alias it.
pub fn prepare(rom: []const u8, board: *const vbios.Result, fuses: Fuses, command: Command, output: []u8) Error!Prepared {
    const selection = try select(rom, board, fuses);
    const entry = &selection.entry;
    const payload = try commandBytes(command);
    if (output.len < entry.image.bytes) return error.Capacity;
    if (entry.interface.command_input.bytes < payload.length) return error.Capacity;
    const source = try entry.image.slice(rom);
    const signature = try selection.signature.slice(rom);
    const slot = try relative(entry.image, entry.signature_slot, fwsec.signature_bytes);
    const mapper = try relative(entry.image, entry.interface.mapper, 64);
    const input = try relative(entry.image, entry.interface.command_input, payload.length);
    const destination = output[0..entry.image.bytes];
    const src_end = std.math.add(usize, @intFromPtr(rom.ptr), rom.len) catch return error.Bounds;
    const dst_end = std.math.add(usize, @intFromPtr(destination.ptr), destination.len) catch return error.Bounds;
    if (@intFromPtr(rom.ptr) < dst_end and @intFromPtr(destination.ptr) < src_end) return error.Overlap;
    @memcpy(destination, source);
    put(destination, mapper + 44, payload.id);
    @memcpy(destination[input..][0..payload.length], payload.data[0..payload.length]);
    @memcpy(destination[slot..][0..fwsec.signature_bytes], signature);
    return .{ .selection = selection, .bytes = entry.image.bytes, .command = payload.id };
}

fn relative(image: fwsec.Range, part: fwsec.Range, needed: u32) Error!u32 {
    if (part.bytes < needed or part.offset < image.offset or
        @as(u64, part.offset) + part.bytes > @as(u64, image.offset) + image.bytes) return error.Bounds;
    return part.offset - image.offset;
}
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
