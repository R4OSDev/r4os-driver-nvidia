// CPU-only interpretation of NVIDIA 570.144's VBIOS FWSEC formats. Original
// R4OS code; format sources and their MIT notices are recorded in PROVENANCE.
// No loader, DMA mapping, signature patch, GPU write or authentication occurs.
const std = @import("std");
const vbios = @import("vbios.zig");

pub const Error = error{ Bounds, Missing, Version, Limit, Duplicate, Overlap, Layout, Unsupported, SignatureVersion };
pub const max_entries = 8;
pub const signature_bytes = 384;
pub const Range = struct {
    offset: u32 = 0,
    bytes: u32 = 0,
    pub fn slice(self: Range, rom: []const u8) Error![]const u8 {
        return span(rom, self.offset, self.bytes);
    }
};
// These are firmware declarations, not offsets into the CPU ROM/load image.
// In particular, the measured command output starts at 01000000. The RM FRTS
// preparer never dereferences it. Deliberately provide no CPU slice accessor.
pub const FirmwareBuffer = struct { address: u32 = 0, bytes: u32 = 0 };
pub const Interface = struct {
    table: Range = .{},
    mapper: Range = .{},
    signature: u32 = 0,
    version: u16 = 0,
    declared_bytes: u16 = 0,
    command_input: Range = .{},
    command_output: FirmwareBuffer = .{},
    image_buffer: FirmwareBuffer = .{},
    build_timestamp_raw: u32 = 0,
    ucode_signature_raw: u32 = 0,
    initial_command: u32 = 0,
    features: u32 = 0,
    commands: [2]u32 = .{ 0, 0 },
};
pub const Entry = struct {
    table_index: u8 = 0,
    application: u8 = 0,
    target: u8 = 0,
    descriptor_version: u8 = 0,
    flags: u8 = 0,
    descriptor: Range = .{},
    image: Range = .{},
    code: Range = .{},
    data: Range = .{},
    signatures: Range = .{},
    signature_slot: Range = .{},
    stored_bytes: u32 = 0,
    uncompressed_bytes: u32 = 0,
    imem_pa: u32 = 0,
    imem_va: u32 = 0,
    imem_secure_pa: u32 = 0,
    imem_secure_bytes: u32 = 0,
    imem_nonsecure_bytes: u32 = 0,
    entry_point: u32 = 0,
    dmem_pa: u32 = 0,
    interface_offset: u32 = 0,
    engine_mask: u16 = 0,
    ucode_id: u8 = 0,
    signature_count: u8 = 0,
    signature_versions: u16 = 0,
    reserved_raw: u16 = 0,
    interface: Interface = .{},
};
pub const Catalog = struct {
    expansion_rom_offset: u32 = 0,
    table: Range = .{},
    table_entries: u8 = 0,
    // Preserved for diagnosis. The pinned RM uses each vDesc, not these hints.
    descriptor_version_hint: u8 = 0,
    descriptor_bytes_hint: u8 = 0,
    count: u8 = 0,
    entries: [max_entries]Entry = .{Entry{}} ** max_entries,
};

/// `board` must be the vbios.parse result for the same immutable CPU copy.
/// Everything is further confined to its validated PCI chain (not PROM tail).
/// A rejected catalog publishes no partial entries. Unknown applications are
/// skipped; malformed FWSEC entries reject the catalog, never guess a variant.
pub fn parse(bytes: []const u8, board: *const vbios.Result) Error!Catalog {
    if (bytes.len > vbios.max_rom_bytes) return error.Limit;
    const rom = try span(bytes, 0, board.rom_bytes);
    const token = board.falcon orelse return error.Missing;
    if (token.version != 2) return error.Version;
    if (token.bytes < 4 or token.offset == 0) return error.Bounds;
    const data = try span(rom, token.offset, token.bytes);
    const bias = board.expansion_rom_offset orelse return error.Layout;
    const pointer = u32le(data, 0);
    if (pointer == 0) return error.Missing;
    const table_offset = @as(u64, bias) + pointer;
    const header = try span(rom, table_offset, 6);
    if (header[0] != 1) return error.Version;
    const size: u32 = header[1];
    const stride: u32 = header[2];
    const count = header[3];
    if (size < 6 or size > 64 or stride < 6 or stride > 32 or count > 64) return error.Limit;
    if (count == 0) return error.Missing;
    var result: Catalog = .{
        .expansion_rom_offset = bias,
        .table = try range(rom, table_offset, size + stride * count),
        .table_entries = count,
        .descriptor_version_hint = header[4],
        .descriptor_bytes_hint = header[5],
    };
    for (0..count) |index| {
        const record = try span(rom, table_offset + size + stride * index, 6);
        if (record[0] != 0x05 and record[0] != 0x45 and record[0] != 0x85) continue;
        if (result.count == max_entries) return error.Limit;
        const desc_pointer = u32le(record, 2);
        if (desc_pointer == 0) return error.Bounds;
        var entry = try descriptor(rom, @as(u64, bias) + desc_pointer);
        entry.table_index = @intCast(index);
        entry.application = record[0];
        entry.target = record[1];
        try disjoint(result.table, entry.descriptor);
        try disjoint(result.table, entry.image);
        // Aliased or conflicting firmware entries are not independent choices.
        for (result.entries[0..result.count]) |*prior| {
            if (prior.application == entry.application and prior.target == entry.target) return error.Duplicate;
            try disjoint(prior.descriptor, entry.descriptor);
            try disjoint(prior.image, entry.descriptor);
            try disjoint(prior.descriptor, entry.image);
            try disjoint(prior.image, entry.image);
        }
        result.entries[result.count] = entry;
        result.count += 1;
    }
    if (result.count == 0) return error.Missing;
    return result;
}

fn descriptor(rom: []const u8, offset: u64) Error!Entry {
    const word = u32le(try span(rom, offset, 4), 0);
    if (word & 1 == 0) return error.Version;
    if (word & 0xfa != 0) return error.Unsupported;
    const version: u8 = @truncate(word >> 8);
    const size = word >> 16;
    const minimum: u32 = switch (version) {
        2 => 60,
        3 => 44,
        else => return error.Version,
    };
    if (size < minimum) return error.Bounds;
    const desc = try span(rom, offset, size);
    var entry: Entry = .{
        .descriptor = try range(rom, offset, size),
        .descriptor_version = version,
        .flags = @truncate(word),
        .stored_bytes = u32le(desc, 4),
    };
    if (entry.stored_bytes == 0) return error.Layout;
    const image_offset = offset + size;
    if (version == 2) {
        entry.uncompressed_bytes = u32le(desc, 8);
        entry.entry_point = u32le(desc, 12);
        entry.interface_offset = u32le(desc, 16);
        entry.imem_pa = u32le(desc, 20);
        entry.imem_va = u32le(desc, 28);
        const code_bytes = u32le(desc, 24);
        const secure_va = u32le(desc, 32);
        const secure_bytes = u32le(desc, 36);
        const data_offset = u32le(desc, 40);
        entry.dmem_pa = u32le(desc, 44);
        const data_bytes = u32le(desc, 48);
        if (code_bytes == 0 or data_bytes == 0 or secure_bytes > code_bytes or secure_va < entry.imem_va) return error.Layout;
        entry.imem_nonsecure_bytes = code_bytes - secure_bytes;
        entry.imem_secure_bytes = try aligned(secure_bytes);
        const secure_pa = @as(u64, secure_va) - entry.imem_va + entry.imem_pa;
        if (secure_pa > std.math.maxInt(u32)) return error.Bounds;
        entry.imem_secure_pa = @intCast(secure_pa);
        // The loader's CPU code/data staging buffers are 256-byte aligned.
        if (@as(u64, entry.imem_pa) + code_bytes > try aligned(code_bytes) or
            @as(u64, entry.dmem_pa) + data_bytes > try aligned(data_bytes)) return error.Bounds;
        if (@as(u64, entry.imem_secure_pa) + entry.imem_secure_bytes > try aligned(code_bytes)) return error.Bounds;
        entry.code = try range(rom, image_offset, code_bytes);
        entry.data = try range(rom, image_offset + data_offset, data_bytes);
        try disjoint(entry.code, entry.data);
        // V2's RM loader consumes these explicit code/data extents. StoredSize,
        // UncompressedSize and alternate sizes do not authorize decompression.
        entry.image = try range(rom, image_offset, @max(code_bytes, @as(u64, data_offset) + data_bytes));
    } else {
        entry.interface_offset = u32le(desc, 12);
        entry.imem_pa = u32le(desc, 16);
        const code_bytes = u32le(desc, 20);
        entry.imem_va = u32le(desc, 24);
        entry.dmem_pa = u32le(desc, 28);
        const data_bytes = u32le(desc, 32);
        entry.engine_mask = u16le(desc, 36);
        entry.ucode_id = desc[38];
        entry.signature_count = desc[39];
        entry.signature_versions = u16le(desc, 40);
        // RM reads this word but never interprets it. The measured GA106 ROM
        // carries 9249 here. Preserve it; zero is not a format requirement.
        entry.reserved_raw = u16le(desc, 42);
        if (code_bytes == 0 or data_bytes == 0 or entry.signature_count == 0) return error.Layout;
        entry.image = try range(rom, image_offset, try aligned(entry.stored_bytes));
        if (@as(u64, code_bytes) + data_bytes > entry.image.bytes) return error.Bounds;
        entry.code = try range(rom, image_offset, code_bytes);
        entry.data = try range(rom, image_offset + code_bytes, data_bytes);
        const pkc_offset = u32le(desc, 8);
        // The signature is patched through pMappedData, so require the whole
        // slot in initialized DMEM, even if trailing image padding would fit.
        if (@as(u64, pkc_offset) + signature_bytes > data_bytes) return error.Bounds;
        entry.signature_slot = try range(rom, @as(u64, entry.data.offset) + pkc_offset, signature_bytes);
        entry.signatures = try range(rom, offset + 44, size - 44);
        if (@as(u32, entry.signature_count) * signature_bytes != entry.signatures.bytes or
            @popCount(entry.signature_versions) != entry.signature_count) return error.Layout;
    }
    entry.interface = try parseInterface(rom, &entry);
    if (entry.signature_slot.bytes != 0) {
        try disjoint(entry.signature_slot, entry.interface.table);
        try disjoint(entry.signature_slot, entry.interface.mapper);
        try disjoint(entry.signature_slot, entry.interface.command_input);
    }
    return entry;
}

fn parseInterface(rom: []const u8, entry: *const Entry) Error!Interface {
    const head_range = try dmemRange(rom, entry, entry.interface_offset, 4);
    const header = try head_range.slice(rom);
    if (header[0] != 1) return error.Version;
    // Only the exact layout actually consumed by the pinned FRTS loader is
    // admitted. It uses sizeof(header/entry), not extensible strides.
    if (header[1] != 4 or header[2] != 8) return error.Unsupported;
    if (header[3] < 2 or header[3] > 32) return error.Limit;
    var result: Interface = .{ .table = try dmemRange(rom, entry, entry.interface_offset, 4 + @as(u32, header[3]) * 8) };
    const table = try result.table.slice(rom);
    var found = false;
    for (0..header[3]) |index| {
        const record = table[4 + index * 8 ..][0..8];
        if (u32le(record, 0) != 4) continue;
        if (found) return error.Duplicate;
        found = true;
        const pointer = u32le(record, 4);
        result.mapper = try dmemRange(rom, entry, pointer, 64);
        const mapper = try result.mapper.slice(rom);
        result.signature = u32le(mapper, 0);
        result.version = u16le(mapper, 4);
        result.declared_bytes = u16le(mapper, 6);
        if (result.version != 3) return error.Version;
        if (result.declared_bytes < 64) return error.Bounds;
        result.mapper = try dmemRange(rom, entry, pointer, result.declared_bytes);
        result.command_input = try dmemRange(rom, entry, u32le(mapper, 8), u32le(mapper, 12));
        // Only command_input is patched through the host's mapped DMEM. Other
        // advertised buffers belong to a firmware address space not established
        // by this descriptor; their raw values confer no CPU/GPU memory access.
        result.command_output = .{ .address = u32le(mapper, 16), .bytes = u32le(mapper, 20) };
        result.image_buffer = .{ .address = u32le(mapper, 24), .bytes = u32le(mapper, 28) };
        result.build_timestamp_raw = u32le(mapper, 36);
        result.ucode_signature_raw = u32le(mapper, 40);
        result.initial_command = u32le(mapper, 44);
        result.features = u32le(mapper, 48);
        result.commands = .{ u32le(mapper, 52), u32le(mapper, 56) };
    }
    if (!found) return error.Missing;
    try disjoint(result.table, result.mapper);
    try disjoint(result.command_input, result.table);
    try disjoint(result.command_input, result.mapper);
    // No command is submitted here. Capacity is reported for the future
    // command writer, which must check the selected command's complete size.
    return result;
}

fn dmemRange(rom: []const u8, entry: *const Entry, offset: u32, length: u32) Error!Range {
    const bias = if (entry.descriptor_version == 2) entry.dmem_pa else 0;
    if (offset < bias or @as(u64, offset) + length > entry.data.bytes) return error.Bounds;
    return range(rom, @as(u64, entry.data.offset) + offset - bias, length);
}

/// Pure index calculation; the caller must supply a measured fuse version.
/// Returning a ROM range does not validate the RSA signature or authorize use.
pub fn signatureForFuse(entry: *const Entry, fuse_version: u32) Error!Range {
    if (entry.descriptor_version != 3) return error.Unsupported;
    if (fuse_version >= 16) return error.SignatureVersion;
    const mask = @as(u16, 1) << @as(u4, @intCast(fuse_version));
    if (entry.signature_versions & mask == 0) return error.SignatureVersion;
    const index: u32 = @popCount(entry.signature_versions & (mask - 1));
    if (index >= entry.signature_count or @as(u64, index + 1) * signature_bytes > entry.signatures.bytes) return error.Bounds;
    const offset = @as(u64, entry.signatures.offset) + index * signature_bytes;
    if (offset > std.math.maxInt(u32)) return error.Bounds;
    return .{ .offset = @intCast(offset), .bytes = signature_bytes };
}

pub fn sha256(rom: []const u8, value: Range) Error![64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(try value.slice(rom), &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Limited raw evidence after rejection. This never returns a firmware view:
/// malformed sizes are capped, each read is checked independently, and all
/// records must be labelled unvalidated by the caller's existing diagnostic.
pub fn diagnose(bytes: []const u8, board: *const vbios.Result, sink: anytype) void {
    if (bytes.len > vbios.max_rom_bytes) return;
    const rom = span(bytes, 0, board.rom_bytes) catch return;
    const token = board.falcon orelse return;
    if (token.version != 2 or token.bytes < 4) return;
    const data = span(rom, token.offset, @min(token.bytes, 16)) catch return;
    sink.record("fwsec-bit-p", token.offset, data);
    const bias = board.expansion_rom_offset orelse return;
    const table_offset = @as(u64, bias) + u32le(data, 0);
    const header = span(rom, table_offset, 6) catch return;
    sink.record("fwsec-table-header", @intCast(table_offset), header);
    if (header[0] != 1 or header[1] < 6 or header[2] < 6) return;
    const count: usize = @min(header[3], 64);
    var emitted: usize = 0;
    for (0..count) |index| {
        const at = table_offset + header[1] + @as(u64, header[2]) * index;
        const record = span(rom, at, 6) catch return;
        if (record[0] != 0x05 and record[0] != 0x45 and record[0] != 0x85) continue;
        if (emitted == max_entries) return;
        emitted += 1;
        sink.record("fwsec-table-entry", @intCast(at), record);
        const offset = @as(u64, bias) + u32le(record, 2);
        const word = u32le(span(rom, offset, 4) catch continue, 0);
        const version = (word >> 8) & 0xff;
        const size = word >> 16;
        const minimum: u32 = switch (version) {
            2 => 60,
            3 => 44,
            else => 4,
        };
        const desc = span(rom, offset, @min(size, minimum)) catch continue;
        sink.record("fwsec-descriptor", @intCast(offset), desc);
        if (minimum == 4 or desc.len < minimum) continue;
        const data_at = offset + size + @as(u64, u32le(desc, if (version == 2) 40 else 20));
        const data_bytes = u32le(desc, if (version == 2) 48 else 32);
        const raw = span(rom, data_at, @min(data_bytes, 128)) catch continue;
        sink.record("fwsec-dmem", @intCast(data_at), raw);
        const dmem = span(rom, data_at, data_bytes) catch continue;
        const interface_at = u32le(desc, if (version == 2) 16 else 12);
        const physical_bias = if (version == 2) u32le(desc, 44) else 0;
        if (interface_at < physical_bias) continue;
        const interface_offset = interface_at - physical_bias;
        const interface_head = span(dmem, interface_offset, 4) catch continue;
        if (interface_head[1] < 4 or interface_head[2] < 8 or interface_head[3] > 32) continue;
        const interface_data = span(dmem, interface_offset, interface_head[1] + @as(u64, interface_head[2]) * interface_head[3]) catch continue;
        sink.record("fwsec-interface", @intCast(data_at + interface_offset), interface_data);
        for (0..interface_head[3]) |interface_index| {
            const interface_entry = interface_data[interface_head[1] + @as(usize, interface_head[2]) * interface_index ..][0..8];
            if (u32le(interface_entry, 0) != 4) continue;
            const pointer = u32le(interface_entry, 4);
            if (pointer < physical_bias) continue;
            const mapper = span(dmem, pointer - physical_bias, 64) catch continue;
            sink.record("fwsec-mapper", @intCast(data_at + pointer - physical_bias), mapper);
        }
    }
}
fn disjoint(left: Range, right: Range) Error!void {
    if (left.bytes != 0 and right.bytes != 0 and left.offset < @as(u64, right.offset) + right.bytes and
        right.offset < @as(u64, left.offset) + left.bytes) return error.Overlap;
}
fn aligned(value: u32) Error!u32 {
    if (value > vbios.max_rom_bytes) return error.Limit;
    return (value + 255) & ~@as(u32, 255);
}
fn range(rom: []const u8, offset: u64, length: u64) Error!Range {
    _ = try span(rom, offset, length);
    return .{ .offset = @intCast(offset), .bytes = @intCast(length) };
}
fn span(bytes: []const u8, offset: u64, length: u64) Error![]const u8 {
    if (offset > bytes.len or length > bytes.len - offset) return error.Bounds;
    return bytes[@intCast(offset)..][0..@intCast(length)];
}
fn u16le(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}
fn u32le(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
