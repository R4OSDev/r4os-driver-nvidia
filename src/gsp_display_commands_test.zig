//! Original NVIDIA class definitions and Nouveau C DRF macros provide the
//! complete reference packets. Part of the existing transport test group.
const std = @import("std");
const t = std.testing;
const commands = @import("gsp_display_commands.zig");
const push = @import("gsp_display_push.zig");
const fixture = @embedFile("fixtures/display-commands.bin");
fn word(at: usize) u32 { return std.mem.readInt(u32, fixture[at..][0..4], .little); }
pub fn check() !void {
    try t.expect(fixture.len == 484 and word(0) == 4);
    var at: usize = 4;
    for (0..word(0)) |_| {
        const result = try commands.core(.{ .windows = word(at), .notifier = word(at + 4), .initialize = word(at + 8) == 1 });
        const count = word(at + 12); at += 16;
        try t.expectEqual(count, result.count);
        for (result.words[0..result.count]) |value| { try t.expectEqual(word(at), value); at += 4; }
    }
    try t.expectEqual(word(at), push.jump_zero);
    try t.expectEqual(@as(u16, 1022), try push.cursor(word(at + 4)));
    try t.expectEqual(@as(u16, 1023), try push.cursor(word(at + 8)));
    try t.expect(word(at + 12) == 16 and word(at + 16) == 0 and word(at + 20) == 1 << 30 and word(at + 24) == 2 << 30);
    try t.expect(at + 28 == fixture.len);
    try t.expectError(error.Bounds, commands.core(.{ .notifier = 1, .windows = 256, .initialize = true }));
    try t.expectError(error.Handle, commands.core(.{ .notifier = 0, .windows = 1, .initialize = true }));
    try t.expectError(error.Completion, push.cursor(0xffffffff));
    try checkImages();
    try checkBootMode();
    try checkPosition();
}
fn checkPosition() !void {
    const vectors = @embedFile("fixtures/display-position.bin");
    try t.expect(vectors.len == 124 and std.mem.readInt(u32, vectors[0..4], .little) == 4);
    var at: usize = 4;
    for (0..4) |_| {
        const config: commands.Config = .{ .kind = .immediate, .notifier = 0, .windows = 9, .initialize = true,
            .route = .{ .head = 1, .window = 3 }, .position = .{
                .x = @intCast(std.mem.readInt(i32, vectors[at..][0..4], .little)),
                .y = @intCast(std.mem.readInt(i32, vectors[at + 4..][0..4], .little)) } };
        at += 8;
        const result = try commands.encode(config);
        try t.expectEqual(@as(u16, 5), result.count);
        for (result.words[0..result.count]) |value| { try t.expectEqual(std.mem.readInt(u32, vectors[at..][0..4], .little), value); at += 4; }
        var invalid = config; invalid.notifier = 1; try t.expectError(error.Descriptor, commands.encode(invalid));
        invalid = config; invalid.position = null; try t.expectError(error.Descriptor, commands.encode(invalid));
        invalid = config; invalid.route.?.window = 2; try t.expectError(error.Bounds, commands.encode(invalid));
    }
    const image: commands.image.Image = .{ .dma = 123, .channel = 4, .width = 65, .height = 20, .pitch = 512,
        .format = 0x34325258, .bytes = 10240, .offset = 0 };
    const result = try commands.window(.{ .kind = .window, .notifier = 12, .windows = 9, .initialize = false,
        .scanout = image, .route = .{ .window = 3, .head = 1 }, .with_position = true });
    for (result.words[result.count - 2..result.count]) |value| { try t.expectEqual(std.mem.readInt(u32, vectors[at..][0..4], .little), value); at += 4; }
    try t.expectEqual(vectors.len, at);
    try t.expectEqual(@as(u32, 0x6b3000), try push.userBase(.immediate, 3));
}
pub fn bootFixture(width: u32, height: u32) @import("boot_scanout.zig").Raw {
    var raw: @import("boot_scanout.zig").Raw = .{ .capabilities = 0x0802, .window_mask = 255, .counts = 0x800402 };
    raw.sors[3] = 0x102;
    const size = width | (height << 16);
    raw.heads[1].words = .{ 0x40, 0, 0x80000000 | 148500000, 1, size, size,
        (width + 280) | ((height + 45) << 16), 43 | (4 << 16), 191 | (40 << 16),
        (width + 191) | ((height + 40) << 16) };
    return raw;
}
pub fn outputFixture(snapshot: *@import("gsp_outputs.zig").Snapshot, epoch: u64, client: u32) void {
    snapshot.* = .{ .generation = 7, .final_receipt_serial = 9, .coherent = true,
        .topology = .{ .epoch = epoch, .client = client, .head_count = 2, .count = 1 }, .count = 1 };
    snapshot.topology.heads[0].display_id = 0;
    snapshot.topology.heads[1].display_id = 4;
    snapshot.topology.routes[0] = .{ .id = 4,
        .resource = .{ .index = 3, .kind = 2, .protocol = 1, .dither_type = 0, .dither_algo = 0,
            .location = 0, .root_port_id = 0, .dcb_index = 6, .vbios_address = 0, .lit_by_vbios = true, .dynamic = false },
        .connectors = .{ .flags = 1, .ddc_partners = 0, .count = 1, .platform = 0,
            .data = .{ .{ .kind = 0x61, .index = 1 }, .{}, .{}, .{} } } };
    // A powered-off receiver can have no EDID. Adoption uses only the saved
    // running timing, and must not turn this into an advertised new mode.
    snapshot.receivers[0] = .{ .epoch = epoch, .client = client, .display_id = 4, .status = .edid_missing };
}
fn checkBootMode() !void {
    const mode = commands.boot_mode;
    const a = @import("r4os").abi;
    var raw = bootFixture(1920, 1080);
    const boot: a.GfxNativeBootInfo = .{ .generation = 3, .physical_address = 0xd0000000,
        .byte_length = 8192 * 1080, .pitch = 8192, .width = 1920, .height = 1080, .format = a.gfx_buffer_format_xrgb8888 };
    const saved = try mode.capture(&raw, &boot, 3);
    try t.expect(saved.head == 1 and saved.signal.sor == 3 and saved.refresh_micro_hz == 59940059);
    const snapshot = try t.allocator.create(@import("gsp_outputs.zig").Snapshot); defer t.allocator.destroy(snapshot);
    outputFixture(snapshot, 11, 12);
    const bound = try mode.bind(saved, snapshot, 11, 4);
    try t.expect(bound.epoch == 11 and bound.held_generation == 4 and bound.boot_generation == 3 and
        bound.output_generation == 7 and bound.receipt_serial == 9 and bound.signal.display_id == 4);
    const config: commands.Config = .{ .notifier = 0x1234, .windows = 255, .initialize = true,
        .route = .{ .head = bound.head, .window = bound.window }, .signal = bound.signal };
    const result = try commands.core(config);
    const reference = @embedFile("fixtures/display-boot-mode.bin");
    try t.expectEqual(@as(usize, result.count) * 4, reference.len);
    for (result.words[0..result.count], 0..) |value, i| try t.expectEqual(std.mem.readInt(u32, reference[i * 4..][0..4], .little), value);
    raw.heads[1].words[2] ^= 1;
    try t.expect(!std.meta.eql(saved, try mode.capture(&raw, &boot, 3)));
    raw.heads[1].words[1] = 8; try t.expectError(error.Unsupported, mode.capture(&raw, &boot, 3));
    raw = bootFixture(1920, 1080); raw.sors[3] |= 1; try t.expectError(error.Routing, mode.capture(&raw, &boot, 3));
    raw = bootFixture(1920, 1080); raw.sors[3] = 0xc02; try t.expectError(error.Unsupported, mode.capture(&raw, &boot, 3));
    raw = bootFixture(1920, 1080); raw.heads[1].words[4] -= 1; try t.expectError(error.Unsupported, mode.capture(&raw, &boot, 3));
    snapshot.coherent = false; try t.expectError(error.Stale, mode.bind(saved, snapshot, 11, 4)); snapshot.coherent = true;
    snapshot.topology.heads[0].display_id = 4; try t.expectError(error.Routing, mode.bind(saved, snapshot, 11, 4));
    snapshot.topology.heads[0].display_id = 0; snapshot.topology.heads[1].display_id = 0;
    try t.expect(std.meta.eql(bound, try mode.bind(saved, snapshot, 11, 4)));
    snapshot.topology.routes[0].resource.?.index = 2; try t.expectError(error.Routing, mode.bind(saved, snapshot, 11, 4));
    var invalid = config; invalid.signal.?.clock = 0; try t.expectError(error.Descriptor, commands.core(invalid));
    invalid = config; invalid.signal.?.min_frame_idle ^= 1; try t.expectError(error.Descriptor, commands.core(invalid));
    invalid = config; invalid.route = null; try t.expectError(error.Descriptor, commands.core(invalid));
}
fn checkImages() !void {
    const vectors = @embedFile("fixtures/display-image.bin");
    try t.expect(vectors.len == 984 and std.mem.readInt(u32, vectors[0..4], .little) == 4);
    var at: usize = 4;
    for (0..4) |_| {
        var fields: [15]u32 = undefined;
        for (&fields) |*field| { field.* = std.mem.readInt(u32, vectors[at..][0..4], .little); at += 4; }
        const image: commands.image.Image = .{ .dma = fields[7], .channel = 1 + fields[3], .width = fields[8], .height = fields[9],
            .pitch = fields[10], .format = fields[11], .offset = fields[12], .bytes = fields[13] };
        const config: commands.Config = .{ .kind = if (fields[0] == 0) .core else .window, .initialize = fields[1] == 1,
            .windows = fields[2], .route = .{ .window = fields[3], .head = fields[4] }, .notifier = fields[5],
            .notifier_offset = if (fields[0] == 0) 0 else @intCast(fields[6]), .scanout = if (fields[0] == 0) null else image };
        const result = try commands.encode(config);
        try t.expectEqual(fields[14], result.count);
        for (result.words[0..result.count]) |value| { try t.expectEqual(std.mem.readInt(u32, vectors[at..][0..4], .little), value); at += 4; }
        if (config.kind == .window) {
            var invalid = config;
            invalid.notifier_offset = 8; try t.expectError(error.Descriptor, commands.encode(invalid));
            invalid = config; invalid.scanout.?.bytes -= 1; try t.expectError(error.Bounds, commands.encode(invalid));
            invalid = config; invalid.scanout.?.pitch += 1; try t.expectError(error.Bounds, commands.encode(invalid));
            invalid = config; invalid.scanout.?.format = 0; try t.expectError(error.Unsupported, commands.encode(invalid));
            invalid = config; invalid.route.?.window = 8; try t.expectError(error.Bounds, commands.encode(invalid));
        }
    }
    try t.expect(at == vectors.len);
}
