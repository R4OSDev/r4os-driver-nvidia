const std = @import("std");
const t = std.testing;
const fwsec = @import("fwsec.zig");
const vbios = @import("vbios.zig");
const preparation = @import("fwsec_prepare.zig");
const load = @import("fwsec_load.zig");
const preflight = @import("fwsec_state.zig");

pub fn preflightFixture() preflight.Raw {
    var raw: preflight.Raw = .{};
    for (0..preflight.addresses.len) |index| raw.put(@enumFromInt(index), 0);
    raw.put(.hwcfg, 256 | (256 << 9)); // 64 KB IMEM and DMEM.
    raw.put(.hwcfg2, 0x80000400);
    raw.put(.cpuctl, 0x10);
    raw.put(.dmacmd, 2);
    raw.put(.riscv_cpuctl, 0x90);
    raw.put(.bcr, 0x111);
    raw.put(.fb_mb, 12 * 1024);
    raw.put(.vga, 0x2fffe08); // 40-bit address: 12 GB minus 128 KB.
    return raw;
}

test "FWSEC preflight rejects inaccessible state and bounds TCM against actual capacity" {
    const raw = preflightFixture();
    const decoded = try preflight.decode(&raw);
    try t.expectEqual(@as(u32, 65536), decoded.imem_bytes);
    try t.expectEqual(@as(u32, 65536), decoded.dmem_bytes);
    try t.expectEqual(@as(u64, 0x300000000), decoded.fb_bytes);
    try t.expectEqual(@as(u64, 0x2fffe0000), decoded.reserved_base);
    try t.expect(decoded.riscv_active and decoded.riscv_selected and decoded.bcr_valid and !decoded.wpr_up);
    var changed = raw;
    changed.put(.hwcfg2, 0x400); // RESET_READY not asserted is not a failure.
    try t.expect(!(try preflight.decode(&changed)).reset_ready_hint);
    changed.put(.vga, 0x10008);
    const old_vga = try preflight.decode(&changed);
    try t.expect(old_vga.vga_relocation_needed);
    try t.expectEqual(@as(u64, 0x1000000), old_vga.reserved_base);
    changed.put(.vga, 0);
    try t.expectEqual(@as(u64, 0x2fff00000), (try preflight.decode(&changed)).reserved_base);
    for (0..preflight.addresses.len) |index| {
        changed = raw;
        changed.present &= ~(@as(u16, 1) << @as(u4, @intCast(index)));
        try t.expectError(error.MissingRegister, preflight.decode(&changed));
        for ([_]u32{ 0xffffffff, 0xbadf0000, 0xbadf5040 }) |blocked| {
            changed = raw;
            changed.put(@enumFromInt(index), blocked);
            try t.expectError(error.ProtectedRegister, preflight.decode(&changed));
        }
    }
    changed = raw;
    changed.put(.hwcfg2, 0);
    changed.put(.display_fuse, 1);
    changed.put(.bcr, 0xbadf0000);
    changed.put(.riscv_cpuctl, 0xbadf0000);
    changed.put(.vga, 0xbadf0000);
    const disabled = try preflight.decode(&changed);
    try t.expect(!disabled.riscv_enabled and !disabled.display_enabled);
    for ([_]u32{ 0, 0x100001 }) |fb| {
        changed = raw;
        changed.put(.fb_mb, fb);
        try t.expectError(error.Framebuffer, preflight.decode(&changed));
    }
    changed = raw;
    changed.put(.vga, 0x3000008);
    try t.expectError(error.Framebuffer, preflight.decode(&changed));
    changed = raw;
    changed.put(.wpr_hi, 0x3000000);
    try t.expectError(error.WprRange, preflight.decode(&changed));
    changed.put(.wpr_hi, 0x2000000);
    changed.put(.wpr_lo, 0x2000010);
    try t.expectError(error.WprRange, preflight.decode(&changed));
    changed.put(.wpr_lo, 0x1ff0000);
    try t.expect((try preflight.decode(&changed)).wpr_up);
    const rom = ga106Fixture();
    const board = try vbios.parse(&rom, 0x2504);
    var image: [1280]u8 = undefined;
    const prepared = try preparation.prepare(&rom, &board, .{ .debug_disable_raw = 1, .ucode_version_raw = 8, .ucode_id = 9 }, .sb, &image);
    var plan = try load.plan(&prepared, 0x1234567800, image.len);
    plan.imem.destination = 65536 - plan.imem.bytes;
    plan.dmem.destination = 65536 - plan.dmem.bytes;
    try decoded.checkTcm(&plan); // Exact end is valid; the following byte is not.
    plan.imem.destination += 1;
    try t.expectError(error.Capacity, decoded.checkTcm(&plan));
    plan.imem.destination -= 1;
    plan.dmem.destination += 1;
    try t.expectError(error.Capacity, decoded.checkTcm(&plan));
    plan.dmem.destination = 0xffffff00;
    try t.expectError(error.Capacity, decoded.checkTcm(&plan));
}

test "FWSEC DMA plan preserves high address bits and rejects truncated or wrapping transfers" {
    const rom = ga106Fixture();
    const board = try vbios.parse(&rom, 0x2504);
    var image: [1280]u8 = undefined;
    const prepared = try preparation.prepare(&rom, &board, .{ .debug_disable_raw = 1, .ucode_version_raw = 8, .ucode_id = 9 }, .sb, &image);
    const address: u64 = 0x1234567800;
    const result = try load.plan(&prepared, address, image.len);
    try t.expectEqual(address, result.imem.base);
    try t.expectEqual(address + 256, result.dmem.base);
    try t.expectEqual(@as(u32, 0x614), result.imem.command);
    try t.expectEqual(@as(u32, 0x600), result.dmem.command);
    try t.expectEqual(@as(u32, 512), result.signature_address);
    var relocated = prepared;
    relocated.selection.entry.imem_va = 0x1000;
    relocated.selection.entry.imem_pa = 0x2000;
    const remapped = try load.plan(&relocated, address, image.len);
    try t.expectEqual(address, remapped.imem.base + remapped.imem.source_offset);
    try t.expectEqual(@as(u32, 0x2000), remapped.imem.destination);
    try t.expectError(error.Address, load.plan(&relocated, 256, image.len));
    try t.expectError(error.Bounds, load.plan(&prepared, address, image.len - 1));
    for ([_]u64{ 0, load.dma_mask - 255, load.dma_mask + 1, std.math.maxInt(u64) }) |invalid|
        try t.expectError(error.Address, load.plan(&prepared, invalid, image.len));
    try t.expectError(error.Alignment, load.plan(&prepared, address + 1, image.len));
    for (0..6) |fault| {
        var invalid = prepared;
        const entry = &invalid.selection.entry;
        switch (fault) {
            0 => entry.imem_pa = 0x1000000,
            1 => entry.dmem_pa = 0xffff00,
            2 => entry.code.bytes -= 1,
            3 => entry.data.offset += 256,
            4 => entry.signature_slot.offset = entry.data.offset + entry.data.bytes,
            5 => entry.ucode_id = 0,
            else => unreachable,
        }
        if (load.plan(&invalid, address, image.len)) |_| return error.UnexpectedLoadPlan else |_| {}
    }
}

pub fn ga106Fixture() [8192]u8 {
    var rom = fixture(3);
    rom[0xc07] = 7;
    put16(&rom, 0x1024, 0x400);
    rom[0x1026] = 9;
    return rom;
}

test "FWSEC GA106 fuse selection rejects ambiguous variants and preserves full register version" {
    for ([_]struct { raw: u32, version: u32 }{
        .{ .raw = 0, .version = 0 },           .{ .raw = 1, .version = 1 }, .{ .raw = 3, .version = 2 },
        .{ .raw = 5, .version = 3 },           .{ .raw = 8, .version = 4 }, .{ .raw = 0x10000, .version = 17 },
        .{ .raw = 0x80000000, .version = 32 },
    }) |case| try t.expectEqual(case.version, try preparation.fuseVersion(case.raw));
    try t.expectError(error.Fuse, preparation.fuseVersion(0xffffffff));
    try t.expectError(error.Fuse, preparation.debugEnabled(0xffffffff));
    try t.expect(try preparation.debugEnabled(2));
    try t.expect(!try preparation.debugEnabled(3));
    var rom = ga106Fixture();
    const board = try vbios.parse(&rom, 0x2504);
    var fuses: preparation.Fuses = .{ .debug_disable_raw = 1, .ucode_version_raw = 8, .ucode_id = 9 };
    const selected = try preparation.select(&rom, &board, fuses);
    try t.expectEqual(@as(u32, 4), selected.fuse_version);
    try t.expectEqual(@as(u32, 0x11ac), selected.signature.offset);
    try t.expect(!selected.debug);
    fuses.ucode_id = 8;
    try t.expectError(error.Fuse, preparation.select(&rom, &board, fuses));
    fuses.ucode_id = 9;
    fuses.ucode_version_raw = 0x10000;
    try t.expectError(error.SignatureVersion, preparation.select(&rom, &board, fuses));
    fuses.ucode_version_raw = 1;
    fuses.debug_disable_raw = 0;
    try t.expectError(error.Missing, preparation.select(&rom, &board, fuses));
    rom[0xc06] = 0x45;
    try t.expect((try preparation.select(&rom, &board, fuses)).debug);
    var catalog = try fwsec.parse(&rom, &board);
    catalog.entries[1] = catalog.entries[0];
    catalog.entries[1].target = 8;
    catalog.count = 2;
    try t.expectError(error.Duplicate, preparation.variant(&catalog, true));
    for (0..5) |field| {
        catalog.count = 1;
        catalog.entries[0] = selected.entry;
        switch (field) {
            0 => catalog.entries[0].target = 1,
            1 => catalog.entries[0].flags = 5,
            2 => catalog.entries[0].engine_mask = 4,
            3 => catalog.entries[0].ucode_id = 0,
            4 => catalog.entries[0].ucode_id = 17,
            else => unreachable,
        }
        try t.expectError(error.Unsupported, preparation.variant(&catalog, false));
    }
}

test "FWSEC CPU preparation patches only command and selected signature with atomic rejection" {
    var rom = ga106Fixture();
    const original = rom;
    const board = try vbios.parse(&rom, 0x2504);
    const fuses: preparation.Fuses = .{ .debug_disable_raw = 1, .ucode_version_raw = 8, .ucode_id = 9 };
    const selected = try preparation.select(&rom, &board, fuses);
    const entry = &selected.entry;
    var buffer: [4096]u8 = @splat(0xa7);
    for ([_]preparation.Command{ .sb, .{ .frts = 0x123456000 } }) |command| {
        @memset(&buffer, 0xa7);
        const result = try preparation.prepare(&rom, &board, fuses, command, buffer[16..]);
        try t.expectEqualDeep(original, rom);
        const payload = try preparation.commandBytes(command);
        const slot = entry.signature_slot.offset - entry.image.offset;
        const init = entry.interface.mapper.offset - entry.image.offset + 44;
        const input = entry.interface.command_input.offset - entry.image.offset;
        const output = buffer[16..][0..result.bytes];
        try t.expectEqualSlices(u8, try selected.signature.slice(&rom), output[slot..][0..384]);
        try t.expectEqualSlices(u8, payload.data[0..payload.length], output[input..][0..payload.length]);
        try t.expectEqual(payload.id, std.mem.readInt(u32, output[init..][0..4], .little));
        for (output, 0..) |byte, index| {
            if ((index >= slot and index < slot + 384) or (index >= init and index < init + 4) or
                (index >= input and index < input + payload.length)) continue;
            try t.expectEqual(rom[entry.image.offset + index], byte);
        }
        for (buffer[0..16]) |byte| try t.expectEqual(@as(u8, 0xa7), byte);
        for (buffer[16 + result.bytes ..]) |byte| try t.expectEqual(@as(u8, 0xa7), byte);
    }
    // Values independently compared with the original C ABI exporter.
    const sb = try preparation.commandBytes(.sb);
    try t.expectEqualStrings("010000001800000000000000000000000000000002000000", &std.fmt.bytesToHex(sb.data[0..24].*, .lower));
    const frts = try preparation.commandBytes(.{ .frts = 0x123456000 });
    try t.expectEqualStrings("010000001800000000000000000000000000000002000000010000001400000056341200000100000200000000000000", &std.fmt.bytesToHex(frts.data, .lower));
    @memset(&buffer, 0xa7);
    try t.expectError(error.Capacity, preparation.prepare(&rom, &board, fuses, .sb, buffer[0 .. entry.image.bytes - 1]));
    for ([_]u64{ 0, 1, 0x12345, 0xffffffff000, std.math.maxInt(u64) }) |offset|
        try t.expectError(error.Address, preparation.prepare(&rom, &board, fuses, .{ .frts = offset }, &buffer));
    _ = try preparation.commandBytes(.{ .frts = 0xffffff00000 }); // Last complete 1 MB region.
    try t.expectError(error.Overlap, preparation.prepare(&rom, &board, fuses, .sb, rom[entry.image.offset..]));
    try t.expectEqualDeep(original, rom);
    // Even a previously valid board result cannot authorize stale entry data.
    put32(&rom, entry.interface.mapper.offset + 12, 23);
    try t.expectError(error.Capacity, preparation.prepare(&rom, &board, fuses, .sb, &buffer));
    rom = original;
    put32(&rom, 0x1008, 256);
    try t.expectError(error.Overlap, preparation.prepare(&rom, &board, fuses, .sb, &buffer));
    for (buffer) |byte| try t.expectEqual(@as(u8, 0xa7), byte);
}

// Synthetic format examples only. Neither a real board ROM nor signed code.
pub fn fixture(version: u8) [8192]u8 {
    var rom: [8192]u8 = .{0} ** 8192;
    const base = @import("tests.zig").fixture();
    @memcpy(rom[0..base.len], &base);
    rom[0x55] = 0;
    rom[0x89] = 8;
    rom[0x8a] = 2;
    rom[0x94] = 'p';
    rom[0x95] = 2;
    put16(&rom, 0x96, 4);
    put32(&rom, 0x98, 0x600); // Full-ROM BIT data, outside x86 initialization.
    checksum(rom[0x80..0x8c], 11);
    checksum(rom[0..1024], 1023);
    for ([_]usize{ 0x400, 0x800 }) |offset| {
        const block = rom[offset..];
        put16(block, 0, if (offset == 0x400) 0xaa55 else 0x4e56);
        put16(block, 2, 2);
        put32(block, 4, if (offset == 0x400) 0xef1 else 0);
        put16(block, 0x18, 0x40);
        @memcpy(block[0x40..0x44], if (offset == 0x400) "PCIR" else "NPDS");
        put16(block, 0x44, 0x10de);
        put16(block, 0x46, if (offset == 0x400) 0x2504 else 0x2200);
        put16(block, 0x4a, 0x18);
        put16(block, 0x50, if (offset == 0x400) 2 else 12);
        block[0x54] = if (offset == 0x400) 3 else 0xe0;
        block[0x55] = if (offset == 0x400) 0 else 0x80;
    }
    put32(&rom, 0x600, 0x800); // Bias 0x800 - 0x400 = 0x400, table at c00.
    @memcpy(rom[0xc00..0xc06], &[_]u8{ 1, 6, 6, 1, 0, 0 });
    rom[0xc06] = 0x85;
    rom[0xc07] = 1;
    put32(&rom, 0xc08, 0xc00); // Descriptor at 1000 after bias.
    const size: u32 = if (version == 3) 44 + 2 * fwsec.signature_bytes else 60;
    const code: u32 = if (version == 3) 256 else 512;
    const desc = rom[0x1000..];
    put32(desc, 0, (size << 16) | (@as(u32, version) << 8) | 1);
    put32(desc, 4, code + 1024);
    if (version == 3) {
        put32(desc, 8, 512);
        put32(desc, 20, code);
        put32(desc, 32, 1024);
        put16(desc, 36, 4);
        desc[38] = 0x29;
        desc[39] = 2;
        put16(desc, 40, 0x12); // Fuse versions 1 and 4; index != fuse value.
        @memset(desc[44..][0..fwsec.signature_bytes], 0x21);
        @memset(desc[44 + fwsec.signature_bytes ..][0..fwsec.signature_bytes], 0x84);
    } else {
        put32(desc, 8, code + 1024);
        put32(desc, 12, 0x100);
        put32(desc, 24, code);
        put32(desc, 28, 0x100);
        put32(desc, 32, 0x200);
        put32(desc, 36, 256);
        put32(desc, 40, code);
        put32(desc, 48, 1024);
    }
    const data = rom[0x1000 + size + code ..][0..1024];
    @memcpy(data[0..4], &[_]u8{ 1, 4, 8, 2 });
    put32(data, 4, 1);
    put32(data, 12, 4);
    put32(data, 16, 64);
    const mapper = data[64..];
    put32(mapper, 0, 0x53454346); // Opaque diagnostic signature, no magic claim.
    put16(mapper, 4, 3);
    put16(mapper, 6, 64);
    put32(mapper, 8, 256);
    put32(mapper, 12, 64);
    put32(mapper, 16, 320);
    put32(mapper, 20, 64);
    put32(mapper, 24, 384);
    put32(mapper, 28, 64);
    put32(mapper, 52, (1 << 0x15) | (1 << 0x19));
    return rom;
}

test "FWSEC V2/V3 respect PCI expansion bias, full-width BIT data and sparse fuse signatures" {
    for ([_]u8{ 2, 3 }) |version| {
        const rom = fixture(version);
        const board = try vbios.parse(&rom, 0x2504);
        try t.expectEqual(@as(?u32, 0x800), board.first_extension_offset);
        try t.expectEqual(@as(?u32, 0x400), board.expansion_rom_offset);
        try t.expectEqual(@as(u32, 0x600), board.falcon.?.offset);
        const catalog = try fwsec.parse(&rom, &board);
        try t.expectEqual(@as(u8, 1), catalog.count);
        try t.expectEqual(@as(u32, 0xc00), catalog.table.offset);
        const entry = &catalog.entries[0];
        try t.expectEqual(@as(u32, 0x1000), entry.descriptor.offset);
        try t.expectEqual(version, entry.descriptor_version);
        try t.expectEqual(@as(u32, 64), entry.interface.command_input.bytes);
        try t.expectEqual(entry.data.offset + 256, entry.interface.command_input.offset);
        if (version == 3) {
            try t.expectEqual(@as(u8, 2), entry.signature_count);
            const first = try fwsec.signatureForFuse(entry, 1);
            const second = try fwsec.signatureForFuse(entry, 4);
            try t.expectEqual(@as(u32, 0x102c), first.offset);
            try t.expectEqual(@as(u32, 0x11ac), second.offset);
            for (try first.slice(&rom)) |byte| try t.expectEqual(@as(u8, 0x21), byte);
            for (try second.slice(&rom)) |byte| try t.expectEqual(@as(u8, 0x84), byte);
            for ([_]u32{ 0, 2, 3, 5, 15, 16, 31, 32, 0xffffffff }) |fuse|
                try t.expectError(error.SignatureVersion, fwsec.signatureForFuse(entry, fuse));
        } else {
            try t.expectEqual(@as(u32, 256), entry.imem_nonsecure_bytes);
            try t.expectEqual(@as(u32, 256), entry.imem_secure_pa);
            try t.expectError(error.Unsupported, fwsec.signatureForFuse(entry, 1));
        }
        const before = try fwsec.sha256(&rom, entry.image);
        var changed = rom;
        changed[entry.data.offset + 900] ^= 1;
        try t.expect(!std.mem.eql(u8, &before, &(try fwsec.sha256(&changed, entry.image))));
        try t.expectEqualDeep(rom, fixture(version));
    }
    // A high word must not be discarded and redirected to a valid low table.
    var rom = fixture(3);
    put32(&rom, 0x98, 0x10600);
    checksum(rom[0..1024], 1023);
    try t.expectError(error.Bounds, vbios.parse(&rom, 0x2504));
    // A genuinely valid 32-bit pointer beyond 64 KB remains intact as well.
    var large: [0x12000]u8 = .{0} ** 0x12000;
    @memcpy(large[0..rom.len], &rom);
    put16(&large, 0x850, (large.len - 0x800) / 512);
    put32(&large, 0x10600, 0x800);
    const board = try vbios.parse(&large, 0x2504);
    try t.expectEqual(@as(u32, 0x10600), board.falcon.?.offset);
    try t.expectEqual(@as(u8, 1), (try fwsec.parse(&large, &board)).count);
    // Measured on OssiPC's 94.06.2f.00.d6 VBIOS: RM's Reserved word is
    // nonzero. It is opaque metadata, not a signature or a zero constraint.
    rom = fixture(3);
    put16(&rom, 0x102a, 0x9249);
    const measured_field = try fwsec.parse(&rom, &(try vbios.parse(&rom, 0x2504)));
    try t.expectEqual(@as(u16, 0x9249), measured_field.entries[0].reserved_raw);
    // Exact interface/mapper metadata read from the GA106 board. Firmware
    // bodies/signatures remain synthetic. Its input ends at the last loaded
    // DMEM byte; output and NVF workspace do not reside in the loaded image.
    const data_offset = measured_field.entries[0].data.offset;
    put32(&rom, 0x1004, 256 + 2048);
    put32(&rom, 0x1008, 0x5a4);
    put32(&rom, 0x100c, 28);
    put32(&rom, 0x1020, 2048);
    @memset(rom[data_offset..][0..2048], 0);
    _ = try std.fmt.hexToBytes(rom[data_offset + 28 ..][0..20], "01040802040000006005000005000000ac070000");
    _ = try std.fmt.hexToBytes(rom[data_offset + 0x560 ..][0..64], "444d415003004000c0070000400000000000000100010000000900000026000000000000c8040000d004000000000000040000000040040000000000ac070000");
    const measured_map = try fwsec.parse(&rom, &(try vbios.parse(&rom, 0x2504)));
    const mapped = &measured_map.entries[0];
    try t.expectEqual(data_offset + 1984, mapped.interface.command_input.offset);
    try t.expectEqual(@as(u32, 64), mapped.interface.command_input.bytes);
    try t.expectEqual(@as(u32, 0x01000000), mapped.interface.command_output.address);
    try t.expectEqual(@as(u32, 256), mapped.interface.command_output.bytes);
    try t.expectEqual(@as(u32, 0x900), mapped.interface.image_buffer.address);
    try t.expectEqual(@as(u32, 0x2600), mapped.interface.image_buffer.bytes);
    // One extra input byte really would overrun mapped CPU data and is refused.
    put32(&rom, data_offset + 0x560 + 12, 65);
    try t.expectError(error.Bounds, fwsec.parse(&rom, &(try vbios.parse(&rom, 0x2504))));
}

test "FWSEC rejects overflowing pointers, broken signatures and command ranges without partial output" {
    const original = fixture(3);
    const board = try vbios.parse(&original, 0x2504);
    const catalog = try fwsec.parse(&original, &board);
    const entry = catalog.entries[0];
    const mapper = entry.interface.mapper.offset;
    const Case = struct { offset: usize, value: u32, failure: anyerror };
    for ([_]Case{
        .{ .offset = 0x600, .value = 0xffffff00, .failure = error.Bounds },
        .{ .offset = 0xc08, .value = 0xffffff00, .failure = error.Bounds },
        .{ .offset = 0x1000, .value = (812 << 16) | 0x300, .failure = error.Version },
        .{ .offset = 0x1000, .value = (812 << 16) | 0x403, .failure = error.Unsupported },
        .{ .offset = 0x1000, .value = (40 << 16) | 0x301, .failure = error.Bounds },
        .{ .offset = 0x1004, .value = 0xffffffff, .failure = error.Limit },
        .{ .offset = 0x1008, .value = 700, .failure = error.Bounds },
        .{ .offset = 0x1008, .value = 256, .failure = error.Overlap },
        .{ .offset = 0x100c, .value = 0xfffffffc, .failure = error.Bounds },
        .{ .offset = 0x1014, .value = 0xfffffe00, .failure = error.Bounds },
        .{ .offset = 0x1020, .value = 0xfffffe00, .failure = error.Bounds },
        .{ .offset = 0x1028, .value = 0x13, .failure = error.Layout },
        .{ .offset = mapper + 8, .value = 0xfffffff0, .failure = error.Bounds },
        .{ .offset = mapper + 12, .value = 0xffffffff, .failure = error.Bounds },
        .{ .offset = mapper + 8, .value = 80, .failure = error.Overlap },
        .{ .offset = mapper + 8, .value = 4, .failure = error.Overlap },
        .{ .offset = entry.data.offset + 16, .value = 1000, .failure = error.Bounds },
        .{ .offset = entry.data.offset + 4, .value = 4, .failure = error.Version },
    }) |case| {
        var rom = original;
        put32(&rom, case.offset, case.value);
        try t.expectError(case.failure, fwsec.parse(&rom, &board));
    }
    var invalid = board;
    invalid.expansion_rom_offset = null;
    try t.expectError(error.Layout, fwsec.parse(&original, &invalid));
    invalid = board;
    invalid.falcon.?.version = 1;
    try t.expectError(error.Version, fwsec.parse(&original, &invalid));
    invalid.falcon = null;
    try t.expectError(error.Missing, fwsec.parse(&original, &invalid));
    // A complete supplied file cannot hide an image extending past the
    // validated PCI chain into the remaining PROM aperture.
    invalid = board;
    invalid.rom_bytes = entry.image.offset + entry.image.bytes - 1;
    try t.expectError(error.Bounds, fwsec.parse(&original, &invalid));
    for (0..original.len) |length| try t.expectError(error.Bounds, fwsec.parse(original[0..length], &board));
    var duplicate = original;
    put32(&duplicate, entry.data.offset + 4, 4);
    put32(&duplicate, entry.data.offset + 8, 64);
    try t.expectError(error.Duplicate, fwsec.parse(&duplicate, &board));
    duplicate = original;
    duplicate[0xc03] = 2;
    @memcpy(duplicate[0xc0c..0xc12], duplicate[0xc06..0xc0c]);
    try t.expectError(error.Duplicate, fwsec.parse(&duplicate, &board));
    duplicate[0xc0c] = 0x45;
    try t.expectError(error.Overlap, fwsec.parse(&duplicate, &board));
    duplicate[0xc0c] = 0x20; // Other Falcon applications do not select FWSEC.
    try t.expectEqual(@as(u8, 1), (try fwsec.parse(&duplicate, &board)).count);
    var v2 = fixture(2);
    const board2 = try vbios.parse(&v2, 0x2504);
    put32(&v2, 0x1024, 513);
    try t.expectError(error.Layout, fwsec.parse(&v2, &board2));
    v2 = fixture(2);
    put32(&v2, 0x1020, 0x80);
    try t.expectError(error.Layout, fwsec.parse(&v2, &board2));
    v2 = fixture(2);
    put32(&v2, 0x1028, 256);
    try t.expectError(error.Overlap, fwsec.parse(&v2, &board2));
}

pub fn put16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}
pub fn put32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
fn checksum(bytes: []u8, index: usize) void {
    bytes[index] = 0;
    var sum: u8 = 0;
    for (bytes) |value| sum +%= value;
    bytes[index] = 0 -% sum;
}
