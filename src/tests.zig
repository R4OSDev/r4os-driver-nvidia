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
    try checkConnectorTopology(&rom, &info);
    try checkGpioTopology(&rom);
    try checkExternalTopology();
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

pub fn portFixture() [1024]u8 {
    var rom = fixture();
    put16(&rom, 0x36, 0x220);
    @memcpy(rom[0x220..][0..23], rom[0x100..][0..23]);
    rom[0x222] = 28;
    @memset(rom[0x237..][0 .. 28 * 8], 0xff);
    put32(&rom, 0x30f, 0x01000102); // DCB slot27, independently of RM ID.
    put32(&rom, 0x313, 0);
    put16(&rom, 0x22a, 0x330);
    @memcpy(rom[0x330..][0..6], &[_]u8{ 0x41, 6, 1, 5, 0x50, 3 });
    put32(&rom, 0x336, 0x00000703); rom[0x33a] = 0xef;
    rom[0x184] = 0; rom[0x185] = 1;
    rom[0x1c5] = 0x54; // Relative location4, internal HPD A, DP2DVI A.
    @memcpy(rom[0x350..][0..10], &[_]u8{ 0x40, 4, 3, 2, 0, 0, 0x70, 3, 0x90, 3 });
    @memcpy(rom[0x370..][0..7], &[_]u8{ 0x40, 7, 1, 4, 9, 0x40, 0 });
    put32(&rom, 0x377, 0x70000101); // External type9 DP2DVI A input.
    @memcpy(rom[0x390..][0..7], &[_]u8{ 0x40, 7, 1, 4, 7, 0x42, 0 });
    put32(&rom, 0x397, 0x70000702); // Type7 function7 is not HPD A.
    checksum(&rom, 1023);
    return rom;
}

fn checkExternalTopology() !void {
    var rom = portFixture();
    const board = try vbios.parse(&rom, 0x2504);
    try t.expect(board.port_count == 1 and board.ports[0].index == 27);
    try t.expect(board.ports[0].assignment == .pad_macro and board.ports[0].output_mask == 1 and board.ports[0].link_mask.? == 0);
    try t.expect(board.connectors[0].pad_mask == 1 and board.connectors[0].encoder_mask == 0);
    var legacy = rom; legacy[0x220] = 0x40; checksum(&legacy, 1023);
    const legacy_board = try vbios.parse(&legacy, null);
    try t.expect(legacy_board.ports[0].assignment == .encoder and legacy_board.connectors[0].encoder_mask == 1 and legacy_board.connectors[0].pad_mask == 0);
    legacy = rom; legacy[0x312] |= 0x10; checksum(&legacy, 1023);
    try t.expect((try vbios.parse(&legacy, null)).ports[0].virtual);
    try t.expect(board.primary_ccb.? == 0 and board.secondary_ccb.? == 1);
    const external = &board.external_gpio.?;
    try t.expect(external.master_count == 3 and external.table_count == 2 and external.entry_count == 2);
    try t.expect(external.tables[0].index == 1 and external.tables[0].ccb.? == 0 and external.tables[0].i2c.? == 3);
    try t.expect((try external.entry(0, 0)).function == 1 and (try external.entry(1, 0)).function == 7);
    try t.expect(board.gpio_table.?.hpd[0].matches == 1 and board.gpio_table.?.hpd[0].line.? == 3);
    const signal = external.dongle(0, 0);
    try t.expect(signal.status == .mapped and signal.table.? == 1 and signal.line.? == 1 and signal.active_high.?);
    try t.expect(external.dongle(1, 0).status == .missing and external.dongle(0, 1).status == .missing);
    try t.expectError(error.Bounds, external.entry(2, 0));
    try t.expectError(error.Bounds, external.entry(0, 1));
    for (0..0x39b) |length| try t.expectError(error.Bounds, vbios.xpio.parse(rom[0..length], 0x350));
    // Each level reads its own header; no inherited internal GPIO4.1 stride.
    var malformed = rom;
    malformed[0x350] = 0x41; checksum(&malformed, 1023);
    try t.expectError(error.Version, vbios.parse(&malformed, null));
    malformed = rom; malformed[0x373] = 5; checksum(&malformed, 1023);
    try t.expectError(error.Limit, vbios.parse(&malformed, null));
    malformed = rom; malformed[0x352] = 17; checksum(&malformed, 1023);
    try t.expectError(error.Limit, vbios.parse(&malformed, null));
    malformed = rom; put16(&malformed, 0x358, 0x370); checksum(&malformed, 1023);
    try t.expectError(error.Overlap, vbios.parse(&malformed, null));
    malformed = rom; put16(&malformed, 0x334, 0x1c0); checksum(&malformed, 1023);
    try t.expectError(error.Limit, vbios.parse(&malformed, null));
    malformed = rom; malformed[0x376] = 0x10; checksum(&malformed, 1023);
    const secondary = try vbios.parse(&malformed, null);
    try t.expect(secondary.external_gpio.?.tables[0].ccb.? == 1 and secondary.external_gpio.?.tables[0].aux.? == 2);
    try t.expect(!secondary.external_gpio.?.tables[0].knownWiring()); // No PMGR I2C on secondary pad.
    malformed = rom; malformed[0x184] = 0xff; checksum(&malformed, 1023);
    try t.expect((try vbios.parse(&malformed, null)).external_gpio.?.tables[0].ccb == null);
    for ([_]u8{ 1, 2, 4, 8, 0x20, 0x40, 0x80 }) |flag| {
        var item = external.tables[0]; item.flags = flag;
        try t.expectEqual(flag == 1, item.knownWiring());
    }
    for ([_]u8{ 0, 11, 0xff }) |kind| {
        var retained = external.*; retained.tables[0].kind = kind;
        try t.expect(retained.dongle(0, 0).status == .missing and !retained.tables[0].knownWiring());
    }
    malformed = rom; malformed[0x376] = 1; malformed[0x332] = 2;
    put32(&malformed, 0x33b, 0x0000630a); malformed[0x33f] = 0xbf; checksum(&malformed, 1023);
    const irq = (try vbios.parse(&malformed, null)).external_gpio.?.tables[0].interrupt.?;
    try t.expect(irq.status == .mapped and irq.function == 99 and irq.line.? == 10 and !irq.active_high.?);
    malformed[0x376] = 2; checksum(&malformed, 1023);
    try t.expect((try vbios.parse(&malformed, null)).external_gpio.?.tables[0].interrupt == null);
    var ambiguous = external.*;
    ambiguous.tables[1].kind = 9; ambiguous.raw[1] = ambiguous.raw[0];
    try t.expect(ambiguous.dongle(0, 0).status == .ambiguous and ambiguous.dongle(0, 0).line == null);
    // Full u8 count is accepted for one table; a second cannot overflow
    // the explicitly bounded total entry storage.
    var large: [2200]u8 = @splat(0);
    @memcpy(large[0..8], &[_]u8{ 0x40, 4, 2, 2, 16, 0, 0x30, 4 });
    @memcpy(large[16..][0..7], &[_]u8{ 0x40, 7, 255, 4, 7, 0x40, 0 });
    @memcpy(large[0x430..][0..7], &[_]u8{ 0x40, 7, 1, 4, 7, 0x42, 0 });
    try t.expect((try vbios.xpio.parse(&large, 0)).entry_count == 256);
    large[0x432] = 2;
    try t.expectError(error.Limit, vbios.xpio.parse(&large, 0));
    rom[0x377] = 0;
    try t.expect((try external.entry(0, 0)).line == 1); // Independent retained copy.
}

fn checkConnectorTopology(rom: *const [1024]u8, info: *const vbios.Result) !void {
    const wiring = vbios.topology;
    try t.expectEqual(@as(u8, 2), info.communication_count);
    try t.expectEqual(@as(u8, 2), info.connector_count);
    try t.expectEqual(@as(u8, 0x40), info.connector_version);
    try t.expectEqual(@as(u32, 1), info.connectors[0].display_paths);
    try t.expectEqual(@as(u32, 2), info.connectors[1].display_paths);
    try t.expectEqual(@as(u16, 2), info.communications[1].connector_mask);
    try t.expectEqual(@as(?u32, null), info.communications[0].max_i2c_hz);
    // DP and TMDS alternatives share one physical connector and one pad.
    var paired = rom.*;
    put32(&paired, 0x11f, 0x02070206);
    checksum(&paired, 1023);
    const pair = try vbios.parse(&paired, 0x2504);
    try t.expectEqual(@as(u32, 3), pair.connectors[0].display_paths);
    try t.expectEqual(@as(u8, 3), pair.connectors[0].heads);
    try t.expectEqual(@as(u8, 3), pair.connectors[0].pad_mask);
    try t.expectEqual(@as(u16, 0x81), pair.connectors[0].logical_bus_mask);
    try t.expectEqual(@as(u16, 1), pair.connectors[0].ccb_mask);
    try t.expectEqual(@as(u32, 3), pair.communications[0].display_paths);
    try t.expectEqual(@as(u16, 1), pair.communications[0].connector_mask);
    try t.expectEqual(@as(u32, 0), pair.connectors[1].display_paths);
    paired[0x117] = 0xf;
    checksum(&paired, 1023);
    const skipped = try vbios.parse(&paired, null);
    try t.expectEqual(@as(u32, 2), skipped.connectors[0].display_paths);
    try t.expectEqual(@as(u32, 2), skipped.communications[0].display_paths);
    paired[0x1c4] = 0xff;
    checksum(&paired, 1023);
    try t.expectError(error.Reference, vbios.parse(&paired, null));
    // Explicitly absent references do not alias physical connector/pad zero.
    paired = rom.*;
    put32(&paired, 0x11f, 0x0200f2f6);
    checksum(&paired, 1023);
    const absent = try vbios.parse(&paired, null);
    try t.expectEqual(@as(?u8, null), absent.ports[1].connector_type);
    try t.expectEqual(@as(?u8, null), absent.ports[1].aux);
    try t.expectEqual(@as(u32, 1), absent.communications[0].display_paths);
    try t.expectEqual(@as(u32, 0), absent.communications[1].display_paths);
    try t.expectEqual(@as(u32, 0), absent.connectors[1].display_paths);

    const speeds = [_]?u32{ null, 100_000, 200_000, 400_000, 800_000, 1_600_000, 3_400_000, 60_000, 300_000, null, null, null, null, null, null, null };
    for (speeds, 0..) |hz, code| {
        var raw: [4]u8 = undefined;
        put32(&raw, 0, (@as(u32, @intCast(code)) << 28) | 0x400 | (5 << 5) | 4);
        const comms = try wiring.communication(15, &raw);
        try t.expectEqual(hz, comms.max_i2c_hz);
        try t.expectEqual(@as(u8, @intCast(code)), comms.speed_code);
        try t.expectEqual(@as(u32, 0x400), comms.reserved_bits);
        try t.expectEqual(@as(?u8, 4), comms.i2c);
        try t.expectEqual(@as(?u8, 5), comms.aux);
    }
    const unused = try wiring.communication(0, &.{ 0xff, 3, 0, 0 });
    try t.expect(unused.i2c == null and unused.aux == null);
    const full = try wiring.connector(15, &.{ 0x61, 0xf9, 0xff, 0xff });
    try t.expectEqual(@as(u8, 0x7f), full.hpd_mask);
    try t.expectEqual(@as(u8, 15), full.dp_dvi_mask);
    try t.expectEqual(@as(?u8, 15), full.mux_mask);
    try t.expectEqual(@as(?bool, true), full.self_refresh);
    try t.expectEqual(@as(?u8, 7), full.lcd_id);
    try t.expectEqual(@as(u32, 0x80000000), full.reserved_bits);
    try t.expectEqual(@as(u8, 9), full.location);
    // High HPD functions are not GPIO pin indices; retain each distinct bit.
    for ([_]u5{ 12, 13, 16, 17, 24, 25, 26 }, 0..) |shift, bit| {
        var raw: [4]u8 = undefined;
        put32(&raw, 0, (@as(u32, 1) << shift) | 0x61);
        const item = try wiring.connector(0, &raw);
        try t.expectEqual(@as(u8, 1) << @as(u3, @intCast(bit)), item.hpd_mask);
    }
    for (2..4) |len| {
        const short = try wiring.connector(0, (&[_]u8{ 0x61, 0x91, 0xff })[0..len]);
        try t.expectEqual(@as(u8, 1), short.hpd_mask);
        try t.expectEqual(@as(u8, 2), short.dp_dvi_mask);
        try t.expect(short.mux_mask == null and short.lcd_id == null and short.self_refresh == null);
    }
    try t.expectError(error.Bounds, wiring.connector(16, &.{ 0x61, 0 }));
    try t.expectError(error.Bounds, wiring.connector(0, &.{0x61}));
    try t.expectError(error.Bounds, wiring.communication(0, &.{ 1, 2, 3 }));
}

fn checkGpioTopology(rom: *const [1024]u8) !void {
    const gpio = vbios.gpio;
    try t.expect((try vbios.parse(rom, null)).gpio_table == null);
    var table: [6 + 7 * 5]u8 = .{0} ** (6 + 7 * 5);
    @memcpy(table[0..4], &[_]u8{ 0x41, 6, 7, 5 });
    for (gpio.hpd_functions, 0..) |function, i| {
        put32(&table, 6 + i * 5, @as(u32, @intCast(i + 10)) | (@as(u32, function) << 8) | (@as(u32, @intCast(i + 1)) << 24));
        table[6 + i * 5 + 4] = if (i & 1 == 0) 0xef else 0xbf;
    }
    const saved = try gpio.parse(&table, 0);
    try t.expectEqual(@as(u16, table.len), saved.byte_length);
    for (&saved.hpd, 0..) |*hpd, i| {
        try t.expectEqual(gpio.Status.mapped, hpd.status);
        try t.expectEqual(@as(u16, 1), hpd.matches);
        try t.expectEqual(@as(?u8, @intCast(i + 10)), hpd.line);
        try t.expectEqual(@as(?bool, i & 1 == 0), hpd.active_high);
        const item = try saved.entry(i);
        try t.expectEqual(@as(?u8, @intCast(i + 1)), item.input_select);
        try t.expectEqual(@as(?u8, 15), item.lock_pin);
    }
    // The final record has exactly five bytes; no 32-bit read of byte4.
    try t.expectEqual(@as(u8, 96), (try saved.entry(6)).function);
    for (0..table.len) |len| try t.expectError(error.Bounds, gpio.parse(table[0..len], 0));
    try t.expectError(error.Bounds, saved.entry(7));
    var image = rom.*;
    put16(&image, 0x10a, 0x220);
    @memcpy(image[0x220..][0..table.len], &table);
    checksum(&image, 1023);
    const board = try vbios.parse(&image, 0x2504);
    try t.expectEqualDeep(saved.hpd, board.gpio_table.?.hpd);
    // OssiPC GPIO header: 41 06 24 06. The sixth byte is opaque, while
    // records must advance by six rather than aliasing the next entry.
    var extended: [6 + 36 * 6]u8 = .{0} ** (6 + 36 * 6);
    @memcpy(extended[0..4], &[_]u8{ 0x41, 6, 36, 6 });
    for (0..36) |i| {
        extended[6 + i * 6 + 1] = 0xff;
        extended[6 + i * 6 + 5] = @intCast(i + 128);
    }
    for (0..7) |i| @memcpy(extended[6 + i * 6 ..][0..5], table[6 + i * 5 ..][0..5]);
    const extended_saved = try gpio.parse(&extended, 0);
    try t.expectEqual(@as(u16, extended.len), extended_saved.byte_length);
    try t.expectEqualDeep(saved.hpd, extended_saved.hpd);
    for (0..36) |i| {
        const item = try extended_saved.entry(i);
        try t.expectEqual(@as(?u8, @intCast(i + 128)), item.extension_byte);
        try t.expectEqualSlices(u8, extended[6 + i * 6 ..][0..6], &extended_saved.raw[i]);
    }
    try t.expect((try saved.entry(0)).extension_byte == null);
    try t.expectError(error.Bounds, extended_saved.entry(36));
    for (0..extended.len) |len| try t.expectError(error.Bounds, gpio.parse(extended[0..len], 0));
    @memcpy(image[0x220..][0..extended.len], &extended);
    checksum(&image, 1023);
    const extended_board = try vbios.parse(&image, 0x2504);
    var expected_extended = extended_saved;
    expected_extended.offset = 0x220;
    try t.expectEqualDeep(expected_extended, extended_board.gpio_table.?);
    extended[6 + 35 * 6 + 5] = 0;
    try t.expectEqual(@as(?u8, 163), (try extended_saved.entry(35)).extension_byte);
    try t.expectError(error.Bounds, gpio.decode(0x40, extended_saved.raw[0][0..6]));
    try t.expectError(error.Bounds, gpio.decode(0x41, extended_saved.raw[0][0..4]));
    table[7] = 0xff;
    try t.expectEqual(@as(u8, 7), (try saved.entry(0)).function);
    table[7] = 7;
    // External expanders remain explicitly unparsed, without dereferencing
    // an external table pointer or pretending an internal miss proves absence.
    put16(&table, 4, 0x1234);
    const external = try gpio.parse(&table, 0);
    try t.expectEqual(@as(?u16, 0x1234), external.external_table_offset);
    try t.expectEqualDeep(saved.hpd, external.hpd);

    var one: [11]u8 = .{ 0x41, 6, 1, 5, 0, 0, 63, 7, 0, 0, 0xef };
    const high_pin = try gpio.parse(&one, 0);
    try t.expectEqual(@as(?u8, 63), high_pin.hpd[0].line); // Metadata, not GA106 admission (32 lines).
    for ([_]struct { word: u32, extra: u8 }{
        .{ .word = 0x00000740, .extra = 0xef }, // Dedicated lock, no GPIO.
        .{ .word = 0x40000701, .extra = 0xef }, // Reserved bit.
        .{ .word = 0x00000701, .extra = 0xe0 }, // HPD cannot be a lock pin.
        .{ .word = 0x00000701, .extra = 0xcf }, // OFF drives output.
        .{ .word = 0x00000701, .extra = 0xff }, // Input levels indistinguishable.
    }) |fault| {
        put32(&one, 6, fault.word);one[10] = fault.extra;
        const bad = try gpio.parse(&one, 0);
        try t.expectEqual(gpio.Status.invalid_input, bad.hpd[0].status);
        try t.expect(bad.hpd[0].line == null and bad.hpd[0].active_high == null);
    }
    put32(&one, 6, 0x0000ff01);one[10] = 0xef;
    try t.expectEqual(gpio.Status.missing, (try gpio.parse(&one, 0)).hpd[0].status);
    one[0] = 0x42;
    try t.expectError(error.Version, gpio.parse(&one, 0));one[0] = 0x41;
    one[3] = 8;
    try t.expectError(error.Limit, gpio.parse(&one, 0));
    var old: [10]u8 = .{ 0x40, 6, 1, 4, 0, 0, 0, 0, 0, 0 };
    put32(&old, 6, 0xf000071f);
    const legacy = try gpio.parse(&old, 0);
    const legacy_entry = try legacy.entry(0);
    try t.expectEqual(@as(?u8, 31), legacy.hpd[0].line);
    try t.expectEqual(@as(?bool, true), legacy.hpd[0].active_high);
    try t.expect(legacy_entry.extra == null and legacy_entry.input_select == null and legacy_entry.pwm);

    // Accept the full count field, but never silently choose one duplicate.
    var full: [6 + gpio.max_entries * 5]u8 = .{0} ** (6 + gpio.max_entries * 5);
    @memcpy(full[0..4], &[_]u8{ 0x41, 6, 255, 5 });
    for (0..gpio.max_entries) |i| {
        put32(&full, 6 + i * 5, 0x701);full[6 + i * 5 + 4] = 0xef;
    }
    const duplicate = try gpio.parse(&full, 0);
    try t.expectEqual(@as(u8, 255), duplicate.count);
    try t.expectEqual(@as(u16, 255), duplicate.hpd[0].matches);
    try t.expectEqual(gpio.Status.ambiguous, duplicate.hpd[0].status);
    try t.expect(duplicate.hpd[0].entry_index == null and duplicate.hpd[0].line == null);
    // GPIO and CCB may not claim the same ROM bytes, even when both headers
    // independently fit their versions and bounds.
    image = rom.*;
    std.mem.copyBackwards(u8, image[0x18b..0x18f], image[0x18a..0x18e]);
    image[0x183] = 5;put16(&image, 0x10a, 0x180);checksum(&image, 1023);
    try t.expectError(error.Overlap, vbios.parse(&image, null));
    put16(&image, 0x10a, 0xfffc);checksum(&image, 1023);
    try t.expectError(error.Bounds, vbios.parse(&image, null));
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
