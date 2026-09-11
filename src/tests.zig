const std = @import("std");
const t = std.testing;
const pci = @import("identity.zig");
const vbios = @import("vbios.zig");
comptime {
    _ = @import("wait_policy.zig");
    _ = @import("fwsec_test.zig");
    _ = @import("gsp_test.zig");
    _ = @import("gsp_transport_test.zig");
    _ = @import("booter.zig");
}

test "PROM IFR versions and private ROM subimages stay within the supplied aperture" {
    const rom = fixture();
    var bytes: [8192]u8 = .{0} ** 8192;
    @memcpy(bytes[512..][0..rom.len], &rom);
    put32(&bytes, 0, 0x4947564e);
    for ([_]u8{ 1, 2 }) |version| {
        put32(&bytes, 4, (@as(u32, 16) << 16) | (@as(u32, version) << 8));
        put32(&bytes, 20, 512);
        const start = try vbios.promStart(&bytes);
        try t.expectEqual(@as(u32, 512), start.offset);
        try t.expectEqual(version, start.ifr_version);
        try t.expectEqual(@as(u8, 2), (try vbios.parse(bytes[start.offset..], 0x2504)).port_count);
    }
    put32(&bytes, 4, 3 << 8);
    put32(&bytes, 8, 32);
    put32(&bytes, 32, 0);
    put32(&bytes, 4096, 0x44524652);
    put32(&bytes, 4104, 512);
    try t.expectEqual(@as(u32, 512), (try vbios.promStart(&bytes)).offset);
    put32(&bytes, 32, 0xffffffff);
    try t.expectError(error.Bounds, vbios.promStart(&bytes));
    put32(&bytes, 4, 4 << 8);
    try t.expectError(error.Version, vbios.promStart(&bytes));
    put32(&bytes, 4, (16 << 16) | (1 << 8));
    for ([_]u32{ 0, 511, 0xfffffffc, bytes.len }) |offset| {
        put32(&bytes, 20, offset);
        try t.expectError(error.Bounds, vbios.promStart(&bytes));
    }
    try t.expectEqual(@as(u32, 0), (try vbios.promStart(&rom)).offset);
    // A standard aggregate length encloses one x86 and one opaque vendor
    // extension. The latter is bounded but never treated as executable code.
    var chain: [2048]u8 = .{0} ** 2048;
    @memcpy(chain[0..rom.len], &rom);
    put16(&chain, 0x50, 4);
    @memcpy(chain[0x60..0x64], "NPDE");
    put16(&chain, 0x64, 0x100);
    put16(&chain, 0x66, 12);
    put16(&chain, 0x68, 2);
    chain[0x6a] = 0;
    checksum(chain[0..1024], 1023);
    const second = chain[1024..];
    put16(second, 0, 0x4e56);
    put16(second, 0x18, 0x40);
    @memcpy(second[0x40..0x44], "NPDS");
    put16(second, 0x44, 0x10de);
    put16(second, 0x46, 0x2200); // Private container ID observed on GA106.
    put16(second, 0x4a, 0x18);
    put16(second, 0x50, 2);
    second[0x54] = 0xe0;
    second[0x55] = 0x80;
    const result = try vbios.parse(&chain, 0x2504);
    try t.expectEqual(@as(u8, 2), result.image_count);
    try t.expectEqual(@as(u32, 2048), result.rom_bytes);
    try t.expectEqual(@as(u32, 1024), result.image_bytes);
    try t.expectEqual(@as(u8, 2), result.port_count);
    try t.expectEqual(@as(u16, 0x2504), result.pci_device);
    // Private container metadata is not permission for another executable
    // board identity, another vendor, or a disguised standard PCI ROM.
    for ([_]u8{ 0, 3 }) |code| {
        second[0x54] = code;
        try t.expectError(error.Identity, vbios.parse(&chain, 0x2504));
    }
    second[0x54] = 0xe0;
    put16(second, 0x44, 0x1002);
    try t.expectError(error.Identity, vbios.parse(&chain, 0x2504));
    put16(second, 0x44, 0x10de);
    put16(second, 0, 0xaa55);
    try t.expectError(error.Identity, vbios.parse(&chain, 0x2504));
    put16(second, 0, 0x4e56);
    @memcpy(second[0x40..0x44], "PCIR");
    try t.expectError(error.Identity, vbios.parse(&chain, 0x2504));
    @memcpy(second[0x40..0x44], "NPDS");
    try t.expectError(error.Identity, vbios.parse(&chain, 0x2200));
    chain[1023] ^= 1;
    try t.expectError(error.Checksum, vbios.parse(&chain, 0x2504));
    chain[1023] ^= 1;
    put16(&chain, 0x68, 0);
    try t.expectError(error.Bounds, vbios.parse(&chain, 0x2504));
    put16(&chain, 0x68, 5);
    try t.expectError(error.Bounds, vbios.parse(&chain, 0x2504));
    put16(&chain, 0x68, 2);
    put16(&chain, 0x64, 0x102);
    try t.expectError(error.Version, vbios.parse(&chain, 0x2504));
}

const device = pci.Pci{ .bus_kind = 2, .bus = 9, .vendor_id = 0x10de, .device_id = 0x2504, .class_code = 3 };
const Config = struct {
    words: [1024]u32 = .{0} ** 1024,
    reads: usize = 0,
    max_offset: u16 = 0,
    pub fn read(self: *@This(), offset: u16) u32 {
        std.debug.assert(offset & 3 == 0 and offset <= 0xffc);
        self.reads += 1;
        self.max_offset = @max(self.max_offset, offset);
        return self.words[offset / 4];
    }
    fn set(self: *@This(), offset: usize, value: u32) void {
        self.words[offset / 4] = value;
    }
    fn init() Config {
        var self: Config = .{};
        self.set(0, 0x250410de);
        self.set(4, 0x100002);
        self.set(8, 0x030000a1);
        self.set(0x10, 0xe0000000);
        self.set(0x14, 0x0000000c);
        self.set(0x18, 2);
        self.set(0x2c, 0x12341458);
        self.set(0x34, 0x40);
        self.set(0x3c, 0x010b);
        self.set(0x40, 0x005001);
        self.set(0x50, 0x00100010);
        self.set(0x100, 0x00010015);
        self.set(0x104, 1 << (8 + 4));
        self.set(0x108, 1 | (1 << 5) | (8 << 8));
        return self;
    }
};

test "passive PCI capture preserves full 64-bit BAR and current ReBAR size without probing" {
    var reader = Config.init();
    const before = reader.words;
    const snapshot = try pci.capture(device, &reader);
    try t.expectEqual(@as(u16, 0x1458), snapshot.subsystem_vendor);
    try t.expectEqual(@as(u16, 0x1234), snapshot.subsystem_device);
    try t.expectEqual(@as(u8, 0xa1), snapshot.revision);
    try t.expectEqual(@as(u64, 0x2_0000_0000), snapshot.bars[1].base);
    try t.expectEqual(@as(u64, 256 * 1024 * 1024), snapshot.bars[1].bytes);
    try t.expectEqual(@as(u64, 0), snapshot.bars[0].bytes);
    try t.expectEqual(pci.BarKind.upper, snapshot.bars[2].kind);
    try t.expectEqual(pci.ProbeDecision.identity_words_only, pci.decision(&snapshot));
    try t.expectEqualSlices(u32, &before, &reader.words);
    try t.expect(reader.reads < 40);
    var legacy = device;
    legacy.bus_kind = 1;
    reader = Config.init();
    const old = try pci.capture(legacy, &reader);
    try t.expectEqual(@as(u64, 0), old.bars[1].bytes);
    try t.expect(reader.max_offset <= 0xfc);
}

test "unknown PCI IDs, D3 and chip mismatches never admit native initialization" {
    var reader = Config.init();
    var snapshot = try pci.capture(device, &reader);
    snapshot.pci.device_id = 0xbeef;
    try t.expectEqual(pci.ProbeDecision.unknown_pci_id, pci.decision(&snapshot));
    snapshot.pci.device_id = 0x2504;
    snapshot.command = 0;
    try t.expectEqual(pci.ProbeDecision.decode_disabled, pci.decision(&snapshot));
    snapshot.command = 2;
    snapshot.caps.power_state = 3;
    try t.expectEqual(pci.ProbeDecision.power_unavailable, pci.decision(&snapshot));
    try t.expect(pci.chip(0x176000a1, 0) != null);
    for ([_]u32{ 0, 0xffffffff, 0x172000a1, 0x176001a1, 0x196000a1 }) |boot0| try t.expect(pci.chip(boot0, 0) == null);
    for ([_]u32{ 0xffffffff, 0x100, 0x10000, 0x20000 }) |boot1| try t.expect(pci.chip(0x176000a1, boot1) == null);
    var audio = device;
    audio.function = 1;
    audio.class_code = 4;
    audio.subclass = 3;
    try t.expect(pci.isHdaSibling(device, audio));
    audio.device = 1;
    try t.expect(!pci.isHdaSibling(device, audio));
    audio.device = 0;
    audio.bus_kind = 1;
    try t.expect(!pci.isHdaSibling(device, audio));
}

test "malformed PCI capability chains and BAR assignments fail within bounded reads" {
    const Case = struct { offset: usize, value: u32, failure: anyerror };
    for ([_]Case{
        .{ .offset = 0x40, .value = 0x4001, .failure = error.Capability },
        .{ .offset = 0x34, .value = 0x41, .failure = error.Capability },
        .{ .offset = 0x100, .value = 0x10010015, .failure = error.Capability },
        .{ .offset = 0x108, .value = 0x0801, .failure = error.Capability },
        .{ .offset = 0x108, .value = 0x0822, .failure = error.Resource },
        .{ .offset = 0x108, .value = 0x0921, .failure = error.Resource },
        .{ .offset = 0x10, .value = 0xe0000006, .failure = error.Resource },
        .{ .offset = 0x24, .value = 0xf0000004, .failure = error.Resource },
        .{ .offset = 0, .value = 0xffffffff, .failure = error.Disappeared },
    }) |case| {
        var reader = Config.init();
        reader.set(case.offset, case.value);
        try t.expectError(case.failure, pci.capture(device, &reader));
        try t.expect(reader.reads < 60);
    }
}

fn put16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}
fn put32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
fn checksum(bytes: []u8, index: usize) void {
    bytes[index] = 0;
    var sum: u8 = 0;
    for (bytes) |value| {
        sum +%= value;
    }
    bytes[index] = 0 -% sum;
}
pub fn fixture() [1024]u8 {
    var rom: [1024]u8 = .{0} ** 1024;
    put16(&rom, 0, 0xaa55);
    rom[2] = 2;
    put16(&rom, 0x18, 0x40);
    put16(&rom, 0x36, 0x100);
    @memcpy(rom[0x40..0x44], "PCIR");
    put16(&rom, 0x44, 0x10de);
    put16(&rom, 0x46, 0x2504);
    put16(&rom, 0x4a, 0x18);
    put16(&rom, 0x50, 2);
    rom[0x55] = 0x80;
    @memcpy(rom[0x80..0x86], "\xff\xb8BIT\x00");
    put16(&rom, 0x86, 0x100);
    rom[0x88] = 12;
    rom[0x89] = 6;
    rom[0x8a] = 1;
    rom[0x8c] = 'i';
    rom[0x8d] = 2;
    put16(&rom, 0x8e, 5);
    put16(&rom, 0x90, 0xc0);
    @memcpy(rom[0xc0..0xc5], &[_]u8{ 0x30, 0x20, 0x04, 0x94, 0x01 });
    rom[0x100] = 0x41;
    rom[0x101] = 23;
    rom[0x102] = 3;
    rom[0x103] = 8;
    put16(&rom, 0x104, 0x180);
    put32(&rom, 0x106, 0x4edcbdcb);
    put16(&rom, 0x114, 0x1c0);
    put32(&rom, 0x117, 0x01000102); // TMDS, CCB0, connector0, head0, OR0.
    put32(&rom, 0x11f, 0x02001216); // DP, CCB1, connector1, head1, OR1.
    put32(&rom, 0x127, 0x0000000e);
    rom[0x180] = 0x41;
    rom[0x181] = 6;
    rom[0x182] = 2;
    rom[0x183] = 4;
    rom[0x184] = 0xff;
    rom[0x185] = 0xff;
    put32(&rom, 0x186, 3 | (31 << 5));
    put32(&rom, 0x18a, 31 | (2 << 5));
    rom[0x1c0] = 0x40;
    rom[0x1c1] = 4;
    rom[0x1c2] = 2;
    rom[0x1c3] = 4;
    rom[0x1c4] = 0x61;
    rom[0x1c8] = 0x46;
    checksum(rom[0x80..0x8c], 11);
    checksum(&rom, rom.len - 1);
    return rom;
}

test "modern BIT DCB CCB and connector extraction keeps raw facts and null ports" {
    const rom = fixture();
    const before = rom;
    const info = try vbios.parse(&rom, 0x2504);
    try t.expectEqual(@as(u8, 2), info.port_count);
    try t.expectEqualSlices(u8, &[_]u8{ 0x94, 4, 0x20, 0x30, 1 }, &info.vbios_version);
    try t.expectEqual(@as(?u8, 3), info.ports[0].i2c);
    try t.expectEqual(@as(?u8, null), info.ports[0].aux);
    try t.expectEqual(@as(?u8, 2), info.ports[1].aux);
    try t.expectEqual(@as(?u8, null), info.ports[1].i2c);
    try t.expectEqual(@as(?u8, 0x61), info.ports[0].connector_type);
    try t.expectEqual(@as(?u8, 0x46), info.ports[1].connector_type);
    try t.expectEqualSlices(u8, &before, &rom);
    try t.expectError(error.Identity, vbios.parse(&rom, 0xbeef));
    try t.expectError(error.Limit, vbios.parse(rom[0..0], null));
    for (1..rom.len) |length| {
        try t.expectError(error.Bounds, vbios.parse(rom[0..length], null));
        var sink: DiagnosticSink = .{ .rom = rom[0..length] };
        @import("vbios_diagnostic.zig").inspect(sink.rom, &sink);
    }
    var sink: DiagnosticSink = .{ .rom = &rom };
    @import("vbios_diagnostic.zig").inspect(&rom, &sink);
    try t.expect(sink.records >= 7);
}

const DiagnosticSink = struct {
    rom: []const u8,
    records: usize = 0,
    pub fn record(self: *DiagnosticSink, _: []const u8, offset: usize, bytes: []const u8) void {
        std.debug.assert(offset <= self.rom.len and bytes.len <= self.rom.len - offset);
        std.debug.assert(std.mem.eql(u8, self.rom[offset..][0..bytes.len], bytes));
        self.records += 1;
    }
};

test "corrupt firmware lengths versions checksums and routing references are rejected" {
    const Case = struct { offset: usize, value: u8, failure: anyerror };
    for ([_]Case{
        .{ .offset = 0, .value = 0, .failure = error.Signature },
        .{ .offset = 0x4c, .value = 2, .failure = error.Version },
        .{ .offset = 0x88, .value = 11, .failure = error.Limit },
        .{ .offset = 0x8e, .value = 4, .failure = error.Bounds },
        .{ .offset = 0x8d, .value = 3, .failure = error.Version },
        .{ .offset = 0x100, .value = 0x42, .failure = error.Version },
        .{ .offset = 0x101, .value = 10, .failure = error.Limit },
        .{ .offset = 0x102, .value = 33, .failure = error.Limit },
        .{ .offset = 0x103, .value = 7, .failure = error.Limit },
        .{ .offset = 0x106, .value = 0, .failure = error.Signature },
        .{ .offset = 0x117, .value = 0x22, .failure = error.Reference },
        .{ .offset = 0x118, .value = 0x21, .failure = error.Reference },
        .{ .offset = 0x180, .value = 0x40, .failure = error.Version },
        .{ .offset = 0x181, .value = 5, .failure = error.Limit },
        .{ .offset = 0x1c0, .value = 0x41, .failure = error.Version },
        .{ .offset = 0x114, .value = 0x80, .failure = error.Overlap },
    }) |case| {
        var rom = fixture();
        rom[case.offset] = case.value;
        checksum(rom[0x80..0x8c], 11);
        checksum(&rom, rom.len - 1);
        try t.expectError(case.failure, vbios.parse(&rom, null));
        var sink: DiagnosticSink = .{ .rom = &rom };
        @import("vbios_diagnostic.zig").inspect(&rom, &sink);
    }
    var rom = fixture();
    rom[0x8b] +%= 1;
    checksum(&rom, rom.len - 1);
    try t.expectError(error.Checksum, vbios.parse(&rom, null));
    rom = fixture();
    rom[rom.len - 1] +%= 1;
    try t.expectError(error.Checksum, vbios.parse(&rom, null));
}

test "chained EFI images remain distinct and ROM device lists are bounded" {
    var rom: [1536]u8 = .{0} ** 1536;
    @memcpy(rom[0..1024], &fixture());
    rom[0x55] = 0;
    checksum(rom[0..1024], 1023);
    const efi = rom[1024..];
    put16(efi, 0, 0xaa55);
    put16(efi, 2, 1);
    put32(efi, 4, 0xef1);
    put16(efi, 0x18, 0x40);
    @memcpy(efi[0x40..0x44], "PCIR");
    put16(efi, 0x44, 0x10de);
    put16(efi, 0x46, 0x2504);
    put16(efi, 0x4a, 0x1c);
    efi[0x4c] = 3;
    put16(efi, 0x50, 1);
    efi[0x54] = 3;
    efi[0x55] = 0x80;
    const result = try vbios.parse(&rom, 0x2504);
    try t.expectEqual(@as(u8, 2), result.image_count);
    try t.expectEqual(@as(u32, 1024), result.image_bytes);
    efi[0x55] = 0;
    try t.expectError(error.Bounds, vbios.parse(&rom, 0x2504));
    efi[0x55] = 0x80;
    put16(efi, 0x46, 0xbeef);
    put16(efi, 0x48, 0x40);
    put16(efi, 0x80, 0x2504);
    put16(efi, 0x82, 0);
    _ = try vbios.parse(&rom, 0x2504);
    for (0..64) |index| put16(efi, 0x80 + index * 2, 0x2504);
    try t.expectError(error.Limit, vbios.parse(&rom, 0x2504));
}

test "BIT duplicates and explicit DCB skip or EOL never produce invented ports" {
    var rom = fixture();
    rom[0x8a] = 2;
    @memcpy(rom[0x92..0x98], rom[0x8c..0x92]);
    checksum(rom[0x80..0x8c], 11);
    checksum(&rom, 1023);
    try t.expectError(error.Duplicate, vbios.parse(&rom, null));
    rom = fixture();
    rom[0x117] = 0xf;
    checksum(&rom, 1023);
    const skip = try vbios.parse(&rom, null);
    try t.expectEqual(@as(u8, 1), skip.port_count);
    try t.expectEqual(@as(u8, 1), skip.ports[0].index);
    rom[0x117] = 0xe;
    checksum(&rom, 1023);
    const end = try vbios.parse(&rom, null);
    try t.expectEqual(@as(u8, 0), end.port_count);
}

test "all single-bit fixture mutations and pointer extremes remain bounded" {
    const valid = fixture();
    for (0..valid.len) |index| for (0..8) |bit| {
        var rom = valid;
        rom[index] ^= @as(u8, 1) << @as(u3, @intCast(bit));
        checksum(&rom, 1023);
        if (vbios.parse(&rom, null)) |result| {
            try t.expect(result.port_count <= vbios.max_ports);
            try t.expect(result.image_bytes <= rom.len);
        } else |_| {}
    };
    for ([_]usize{ 0x18, 0x36, 0x90, 0x104, 0x114 }) |offset| {
        var rom = valid;
        put16(&rom, offset, 0xffff);
        checksum(&rom, 1023);
        if (vbios.parse(&rom, null)) |_| return error.InvalidPointerAccepted else |_| {}
    }
}
