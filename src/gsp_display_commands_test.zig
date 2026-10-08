//! Original NVIDIA class definitions and Nouveau C DRF macros provide the
//! complete reference packets. Part of the existing transport test group.
const std = @import("std");
const t = std.testing;
const commands = @import("gsp_display_commands.zig");
const push = @import("gsp_display_push.zig");
const fixture = @embedFile("fixtures/display-commands.bin");
fn word(at: usize) u32 { return std.mem.readInt(u32, fixture[at..][0..4], .little); }
pub fn check() !void {
    try t.expect(fixture.len == 524 and word(0) == 4);
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
    try checkIdentityLut();
    try checkImages();
    try checkDetach();
    try checkBootMode();
    try @import("gsp_receiver_mode_test.zig").check();
    try @import("gsp_hdmi_link_test.zig").check();
    try @import("gsp_dp_link_test.zig").check();
    try @import("gsp_display_audio_test.zig").check();
    try @import("gsp_vrr_control_test.zig").check();
    try checkPosition();
    try @import("gsp_cursor_image_test.zig").check();
}
fn checkDetach() !void {
    const vectors = @embedFile("fixtures/display-detach.bin");
    var at: usize = 0;
    for (0..2) |_| {
        var fields: [6]u32 = undefined;
        for (&fields) |*field| { field.* = std.mem.readInt(u32, vectors[at..][0..4], .little); at += 4; }
        for ([_]commands.Kind{ .core, .window }, 0..) |kind, index| {
            const config: commands.Config = .{ .kind = kind, .notifier = 0x1234, .windows = 255, .initialize = false,
                .route = .{ .head = fields[0], .window = fields[1] }, .detach_sor = fields[2],
                .notifier_offset = if (kind == .window) @intCast(fields[3]) else 0 };
            const result = try commands.encode(config);
            try t.expectEqual(fields[4 + index], result.count);
            for (result.words[0..result.count]) |value| {
                try t.expectEqual(std.mem.readInt(u32, vectors[at..][0..4], .little), value); at += 4;
            }
            var invalid = config; invalid.initialize = true; try t.expectError(error.Descriptor, commands.encode(invalid));
            invalid = config; invalid.detach_sor = 8; try t.expectError(error.Descriptor, commands.encode(invalid));
            invalid = config; invalid.cursor_usage = 256; try t.expectError(error.Descriptor, commands.encode(invalid));
            invalid = config; invalid.with_position = true; try t.expectError(error.Descriptor, commands.encode(invalid));
        }
    }
    try t.expectEqual(vectors.len, at);
    var shared: commands.Config = .{ .notifier = 0x1234, .windows = 2, .initialize = false,
        .route = .{ .head = 1, .window = 1 }, .detach_sor = 2, .mst_sor_control = 0x804 };
    const encoded = try commands.encode(shared);
    var found = false;
    var cursor: usize = 0;
    while (cursor < encoded.count) {
        const header = encoded.words[cursor]; cursor += 1;
        const count = (header >> 18) & 0x7ff;
        if (header & 0x3fff == 0x340) {
            try t.expect(count == 1 and encoded.words[cursor] == 0x804); found = true;
        }
        cursor += count;
    }
    try t.expect(found);
    shared.mst_sor_control = 0x806;
    try t.expectError(error.Descriptor, commands.encode(shared)); // Departing head must be removed.
    shared.mst_sor_control = 0x104;
    try t.expectError(error.Descriptor, commands.encode(shared)); // TMDS cannot share an MST SOR.
    shared.mst_sor_control = 0;
    _ = try commands.encode(shared); // Last stream disables the SOR.
    shared.kind = .window;
    try t.expectError(error.Descriptor, commands.encode(shared));
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
    raw.heads[1].hdmi = 0x40000000;
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
    // Replay the actual emitted route methods against two active peers.
    // A candidate modeset may clear unused firmware routes, never a peer.
    var peers = config; peers.initialize = false; peers.preserve_windows = 0x11;
    var ownership = peers; ownership.signal = null; ownership.ownership_only = true;
    var signaled_ownership = ownership; signaled_ownership.signal = config.signal;
    const ownership_packet = try commands.encode(signaled_ownership);
    // The independent original C packet remains the timing/output oracle.
    // Cursor/OLUT methods are deliberately absent before owner assignment.
    var checked: usize = 0;
    var before_owner = true;
    var at: usize = 0;
    while (at < ownership_packet.count) {
        const header = ownership_packet.words[at]; at += 1;
        const count = (header >> 18) & 0x7ff;
        const method = header & 0x3fff;
        for (0..count) |i| {
            const address = method + @as(u32, @intCast(i)) * 4;
            if (address == 0x1000 + bound.window * 0x80) before_owner = false;
            if (address >= 0x2000) {
                try t.expect(before_owner);
                for ([_]u32{0x2088,0x208c,0x2090,0x2094,0x2098,0x209c,0x20a0,0x2288}) |deferred|
                    try t.expect(address != deferred + bound.head * 0x400);
                var found = false; var pos: usize = 0;
                while (pos < reference.len) {
                    const original_header = std.mem.readInt(u32, reference[pos..][0..4], .little); pos += 4;
                    const original_count = (original_header >> 18) & 0x7ff;
                    const original_method = original_header & 0x3fff;
                    for (0..original_count) |j| if (original_method + @as(u32,@intCast(j))*4 == address) {
                        try t.expectEqual(std.mem.readInt(u32,reference[pos+j*4..][0..4],.little),ownership_packet.words[at+i]);
                        found = true;
                    };
                    pos += original_count * 4;
                }
                try t.expect(found); checked += 1;
            }
            if (address == 0x218 or address == 0x21c) try t.expectEqual(@as(u32,0),ownership_packet.words[at+i]);
        }
        at += count;
    }
    try t.expect(checked >= 30 and !before_owner);
    for ([_]commands.Program{ try commands.encode(peers), try commands.encode(ownership), ownership_packet }) |changing| {
        var routes: [8]u32 = @splat(7); routes[0] = 2; routes[4] = 0;
        var offset: usize = 0;
        while (offset < changing.count) {
            const header = changing.words[offset]; offset += 1;
            const count = (header >> 18) & 0x7ff;
            const method = header & 0x3fff;
            for (0..count) |i| {
                const address = method + @as(u32, @intCast(i)) * 4;
                if (address >= 0x1000 and address <= 0x1380 and (address - 0x1000) % 0x80 == 0)
                    routes[(address - 0x1000) / 0x80] = changing.words[offset + i];
            }
            offset += count;
        }
        try t.expectEqualSlices(u32, &.{ 2, 15, 15, bound.head, 0, 15, 15, 15 }, &routes);
    }
    ownership.signal = config.signal; ownership.cursor_image = .{ .head = bound.head };
    try t.expectError(error.Descriptor, commands.encode(ownership)); ownership.cursor_image = null;
    ownership.signal.?.display_id = 0; try t.expectError(error.Descriptor, commands.encode(ownership));
    ownership.signal = null; ownership.preserve_windows = 8; try t.expectError(error.Descriptor, commands.encode(ownership));
    peers.initialize = true; try t.expectError(error.Descriptor, commands.encode(peers));
    peers.initialize = false; peers.preserve_windows = 8; try t.expectError(error.Descriptor, commands.encode(peers));
    raw.heads[1].words[2] ^= 1;
    try t.expect(!std.meta.eql(saved, try mode.capture(&raw, &boot, 3)));
    // Real OssiPC/Hisense boot: HEAD_SET_CONTROL=0x180, progressive RGB8,
    // slave/master NO_LOCK and inactive INTERNAL_SCAN_LOCK_0 selector.
    // It must derive the same signal and original reference packet as zero.
    for ([_]u32{ 0x10, 0x100, 0x180, 0x1f0, 0x180000, 0x180180 }) |control| {
        raw = bootFixture(1920, 1080);
        raw.heads[1].words[1] = control;
        try t.expect(std.meta.eql(saved, try mode.capture(&raw, &boot, 3)));
    }
    // Active locks, interlace/stereo/YUV and bits outside the two inactive
    // pin selectors retain the original strict admission boundary.
    for ([_]u32{ 1, 2, 4, 8, 0x200, 0x580, 0xd80, 0x1180, 0x200000, 0x580180, 0xd80180, 0x1000000 }) |control| {
        raw = bootFixture(1920, 1080);
        raw.heads[1].words[1] = control;
        try t.expectError(error.Unsupported, mode.capture(&raw, &boot, 3));
    }
    raw = bootFixture(1920, 1080); raw.sors[3] |= 1; try t.expectError(error.Routing, mode.capture(&raw, &boot, 3));
    raw = bootFixture(1920, 1080); raw.sors[3] = 0xc02; try t.expectError(error.Unsupported, mode.capture(&raw, &boot, 3));
    raw = bootFixture(1920, 1080); raw.heads[1].words[4] -= 1; try t.expectError(error.Unsupported, mode.capture(&raw, &boot, 3));
    raw = bootFixture(1920, 1080); raw.heads[1].dsc_control = 1; try t.expectError(error.Unsupported, mode.capture(&raw, &boot, 3));
    raw = bootFixture(1920, 1080); raw.heads[1].dsc_pps_control = 1; try t.expectError(error.Unsupported, mode.capture(&raw, &boot, 3));
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
    try t.expect(vectors.len == 1008 and std.mem.readInt(u32, vectors[0..4], .little) == 4);
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

fn methodValue(program: commands.Program, method: u32) !u32 {
    var at: usize = 0; var found: ?u32 = null;
    while (at < program.count) {
        const header = program.words[at]; at += 1;
        const count = (header >> 18) & 0x7ff;
        const base = header & 0x3fff;
        for (0..count) |i| if (base + @as(u32, @intCast(i)) * 4 == method) {
            try t.expect(found == null);
            found = program.words[at + i];
        };
        at += count;
    }
    return found orelse error.MissingMethod;
}
fn checkIdentityLut() !void {
    errdefer |err| std.debug.print("identity original C: {s}\n", .{@errorName(err)});
    const lut = @import("gsp_display_identity_lut.zig");
    const original = @embedFile("fixtures/display-identity-lut570.144.bin");
    var data: [lut.bytes]u8 = undefined;
    try lut.fill(&data);
    try t.expectEqualSlices(u8, original, &data);
    try t.expect((try lut.firstDifference(&data)) == null);
    data[32] ^= 1;
    try t.expectEqual(@as(?u32, 32), try lut.firstDifference(&data));
    try t.expectError(error.Bounds, lut.fill(data[0 .. data.len - 1]));
    const a = @import("r4os").abi;
    var raw = bootFixture(1920, 1080);
    const boot: a.GfxNativeBootInfo = .{ .generation = 3, .physical_address = 0xd0000000,
        .byte_length = 8192 * 1080, .pitch = 8192, .width = 1920, .height = 1080, .format = a.gfx_buffer_format_xrgb8888 };
    const saved = try commands.boot_mode.capture(&raw, &boot, 3);
    const snapshot = try t.allocator.create(@import("gsp_outputs.zig").Snapshot); defer t.allocator.destroy(snapshot);
    outputFixture(snapshot, 11, 12);
    const bound = try commands.boot_mode.bind(saved, snapshot, 11, 4);
    var signal = bound.signal;
    signal.sor_control = (signal.sor_control & ~@as(u32, 255)) | 1;
    const control: lut.Controls = .{ .head = 0, .window = 3, .input = 0x100000ee, .output = 0x100000ef };
    const core: commands.Config = .{ .notifier = 0x1234, .windows = 255, .initialize = false,
        .route = .{ .head = 0, .window = 3 }, .signal = signal, .identity_lut = control };
    const window: commands.Config = .{ .kind = .window, .notifier = 0x1235, .windows = 255, .initialize = true,
        .route = core.route, .identity_lut = control,
        .scanout = .{ .dma = 0x5678, .channel = 4, .format = a.gfx_buffer_format_xrgb8888,
            .width = 1920, .height = 1080, .pitch = 7680, .bytes = 7680 * 1080, .offset = 0 } };
    const cpacket = try commands.encode(core);
    const wpacket = try commands.encode(window);
    const values = @embedFile("fixtures/display-identity-controls570.144.bin");
    try t.expectEqual(@as(usize, 176), values.len);
    for (0 .. values.len / 8) |i| {
        const address = std.mem.readInt(u32, values[i * 8 ..][0..4], .little);
        const expected = std.mem.readInt(u32, values[i * 8 + 4 ..][0..4], .little);
        try t.expectEqual(expected, try methodValue(if (address >= 0x2000) cpacket else wpacket, address));
    }
    var ownership = core; ownership.ownership_only = true;
    const before_image = try commands.encode(ownership);
    try t.expectError(error.MissingMethod, methodValue(before_image, 0x2288));
    try t.expectError(error.MissingMethod, methodValue(before_image, 0x2240));
    var bad = window; bad.identity_lut.?.head = 1;
    try t.expectError(error.Descriptor, commands.encode(bad));
    bad = window; bad.identity_lut.?.output = control.input;
    try t.expectError(error.Descriptor, commands.encode(bad));
    const imp = @import("gsp_mode_control.zig");
    const offsets = @embedFile("fixtures/display-identity-imp570.144.bin");
    try t.expect(offsets.len == 28);
    try t.expectEqual(@as(u32, 92), std.mem.readInt(u32, offsets[0..4], .little));
    try t.expectEqual(@as(u32, 36), std.mem.readInt(u32, offsets[4..8], .little));
    var request: [imp.length(.possible)]u8 = undefined;
    var plain: [imp.length(.possible)]u8 = undefined;
    var mode = bound; mode.native_lut = true;
    const binding: imp.Binding = .{ .epoch = 11, .client = 12, .device = 0x10000000, .display = 0x10000001, .control = 0x10000002 };
    _ = try imp.encode(binding, .possible, mode, &request);
    _ = try imp.encode(binding, .possible, bound, &plain);
    const h = 24 + 8 + std.mem.readInt(u32, offsets[8..12], .little);
    const w = 24 + 744 + std.mem.readInt(u32, offsets[12..16], .little);
    const usage = std.mem.readInt(u32, offsets[24..28], .little);
    try t.expectEqual(usage, request[h]); try t.expectEqual(usage, request[w]);
    for (request, plain, 0..) |actual, previous, index| try t.expectEqual(if (index == h or index == w) @as(u8, @intCast(usage)) else previous, actual);
    try t.expect(request[24 + 744 + std.mem.readInt(u32, offsets[16..20], .little)] == 0); // No TMO requested.
    std.debug.print("[nvidia-identity-lut] original full C/SoftFloat tables, C67D/C67E controls and original IMP layout; old no-LUT packets unchanged\n", .{});
}
