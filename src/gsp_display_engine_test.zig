//! Original-header vectors extend the existing RM transport group.
const std = @import("std");
const t = std.testing;
const wire = @import("gsp_display_engine_wire.zig");
const message = @import("gsp_message.zig");
pub const golden = @embedFile("fixtures/display-engine-570.144.bin");
pub const ops = [_]wire.Operation{ .classes, .static_info, .allocate, .preserve, .free };
pub fn response(op: wire.Operation) []const u8 {
    var offset: usize = 0;
    for (ops) |item| { const bytes = wire.length(item); if (op == item) return golden[offset + bytes..][0..bytes]; offset += bytes * 2; }
    unreachable;
}
pub fn check() !void {
    const binding: wire.Binding = .{ .epoch = 7, .client = 0xc1d00000, .device = 0x10000000, .root = 0x10000009,
        .internal_client = 0xcaf00001, .internal_subdevice = 0xcaf00003 };
    var request: [wire.max_bytes]u8 = undefined; var bytes: [wire.max_bytes]u8 = undefined;
    var offset: usize = 0;
    for (ops) |op| {
        const data = try wire.encode(binding, op, &request);
        try t.expectEqualSlices(u8, golden[offset..][0..data.len], data);
        @memcpy(bytes[0..data.len], response(op));
        var record: message.Record = .{ .shape = .{ .message_bytes = data.len + 80, .checksum_bytes = data.len + 80, .storage_bytes = 4096, .elements = 1 },
            .queue_sequence = 0, .rpc = .{ .function = wire.function(op), .result = 0 }, .payload = bytes[0..data.len] };
        const decoded = try wire.decode(binding, op, data, record); try t.expect(decoded == .ok);
        if (op == .classes) try t.expect(wire.supports(decoded.ok));
        if (op == .static_info) {
            const hw = try wire.staticInfo(decoded.ok);
            try t.expect(hw.heads == 4 and hw.windows == 255 and hw.channels == 81 and hw.external_mux and !hw.internal_mux);
        }
        const header: usize = if (op == .allocate) 32 else if (op == .free) 16 else 24;
        const status_at: usize = if (op == .allocate) 16 else 12;
        std.mem.writeInt(u32, bytes[status_at..][0..4], 0x57, .little); record.payload = bytes[0..header];
        const rejected = try wire.decode(binding, op, data, record);
        try t.expect(rejected == .rejected and rejected.rejected == 0x57);
        bytes[0] ^= 1; try t.expectError(error.Unexpected, wire.decode(binding, op, data, record));
        @memcpy(bytes[0..data.len], response(op)); record.payload = bytes[0..data.len];
        if (op == .static_info) {
            bytes[32] = 2; try t.expectError(error.Bounds, wire.decode(binding, op, data, record));
            @memcpy(bytes[0..data.len], response(op)); bytes[36] = 9;
            try t.expectError(error.Bounds, wire.decode(binding, op, data, record));
        }
        if (op == .preserve) { bytes[28] = 0; try t.expectError(error.Payload, wire.decode(binding, op, data, record)); }
        record.rpc.result = 0x57; try t.expectError(error.FirmwareResult, wire.decode(binding, op, data, record));
        offset += data.len * 2;
    }
    try t.expectEqual(@as(usize, 1136), offset);
    var forged = binding; forged.internal_client = binding.client;
    try t.expectError(error.Handle, wire.encode(forged, .static_info, &request));
    try checkModeControl();
}
fn checkModeControl() !void {
    const mode = @import("gsp_mode_control.zig");
    const plans = @import("gsp_boot_mode.zig");
    const vectors = @import("gsp_display_commands_test.zig");
    const a = @import("r4os").abi;
    const fixture = @embedFile("fixtures/display-mode-control-570.144.bin");
    const raw = vectors.bootFixture(1920, 1080);
    const boot: a.GfxNativeBootInfo = .{ .generation = 3, .physical_address = 0xd0000000,
        .byte_length = 8192 * 1080, .pitch = 8192, .width = 1920, .height = 1080, .format = a.gfx_buffer_format_xrgb8888 };
    const saved = try plans.capture(&raw, &boot, 3);
    const snapshot = try t.allocator.create(@import("gsp_outputs.zig").Snapshot); defer t.allocator.destroy(snapshot);
    vectors.outputFixture(snapshot, 11, 12);
    const plan = try plans.bind(saved, snapshot, 11, 4);
    const binding: mode.Binding = .{ .epoch = 11, .client = 12, .device = 13, .display = 14, .control = 15 };
    var request: [mode.max_bytes]u8 = undefined; var bytes: [mode.max_bytes]u8 = undefined;
    var offset: usize = 0;
    for (std.enums.values(mode.Operation)) |op| {
        const data = try mode.encode(binding, op, plan, &request);
        try t.expectEqualSlices(u8, fixture[offset..][0..data.len], data);
        const reply = fixture[offset + data.len..][0..data.len];
        @memcpy(bytes[0..data.len], reply);
        var record: message.Record = .{ .shape = .{ .message_bytes = data.len + 80, .checksum_bytes = data.len + 80, .storage_bytes = 4096, .elements = 1 },
            .queue_sequence = 0, .rpc = .{ .function = mode.function(op), .result = 0 }, .payload = bytes[0..data.len] };
        const decoded = try mode.decode(binding, op, plan, data, record); try t.expect(decoded == .ok);
        const header: usize = if (op == .allocate) 32 else if (op == .free) 16 else 24;
        const status_at: usize = if (op == .allocate) 16 else 12;
        std.mem.writeInt(u32, bytes[status_at..][0..4], 0x57, .little); record.payload = bytes[0..header];
        const rejected = try mode.decode(binding, op, plan, data, record);
        try t.expect(rejected == .rejected and rejected.rejected == 0x57);
        bytes[0] ^= 1; try t.expectError(error.Unexpected, mode.decode(binding, op, plan, data, record));
        @memcpy(bytes[0..data.len], reply); record.payload = bytes[0..data.len - 1];
        try t.expectError(error.Payload, mode.decode(binding, op, plan, data, record));
        record.payload = bytes[0..data.len];
        if (op == .pclk) {
            try t.expect(mode.word(decoded.ok, 8) == 0 and mode.word(decoded.ok, 12) == 600000);
            bytes[28] ^= 1; try t.expectError(error.Payload, mode.decode(binding, op, plan, data, record));
            @memcpy(bytes[0..data.len], reply); @memset(bytes[36..40], 0);
            try t.expectError(error.Payload, mode.decode(binding, op, plan, data, record));
        }
        if (op == .possible) {
            for ([_]usize{ 32, 24 + 1904, 24 + 1905, 24 + 1913, 24 + 2044 }) |at| {
                @memcpy(bytes[0..data.len], reply); bytes[at] = 2;
                try t.expectError(error.Payload, mode.decode(binding, op, plan, data, record));
            }
            @memcpy(bytes[0..data.len], reply); std.mem.writeInt(u32, bytes[2032..2036], 9, .little);
            try t.expectError(error.Payload, mode.decode(binding, op, plan, data, record));
        }
        record.rpc.result = 0x57; try t.expectError(error.FirmwareResult, mode.decode(binding, op, plan, data, record));
        offset += data.len * 2;
    }
    try t.expectEqual(fixture.len, offset);
    var stale = plan; stale.output_generation = 0;
    try t.expectError(error.Stale, mode.encode(binding, .possible, stale, &request));
    var alias = binding; alias.control = binding.device;
    try t.expectError(error.Handle, mode.encode(alias, .allocate, plan, &request));
    // Two different physical timings in one actual original-header IMP
    // request. The earlier single-head byte vectors remain unchanged.
    var second = plan;
    second.head = 0; second.window = 0; second.width = 1280; second.height = 720;
    second.refresh_micro_hz = 100_000_000;
    second.signal.sor = 2; second.signal.sor_control = 0x101; second.signal.display_id = 8;
    second.signal.clock = 123_750_000; second.signal.total = 1650 | (750 << 16);
    second.signal.sync_end = 39 | (4 << 16); second.signal.blank_end = 259 | (24 << 16);
    second.signal.blank_start = 1539 | (744 << 16); second.signal.viewport = 1280 | (720 << 16);
    second.signal.min_frame_idle = 25 | (5 << 16);
    var topology = mode.Topology.single(plan); try topology.append(second);
    const dual = try mode.encodeTopology(binding, .possible, plan, topology, &request);
    try t.expectEqualSlices(u8, @embedFile("fixtures/display-topology-570.144.bin"), dual);
    const accepted = request;
    var duplicate = topology; duplicate.plans[1].?.head = plan.head;
    duplicate.plans[1].?.signal.sor_control = 0x100 | (@as(u32, 1) << @intCast(plan.head));
    try t.expectError(error.Routing, mode.encodeTopology(binding, .possible, plan, duplicate, &request));
    try t.expectEqualSlices(u8, &accepted, &request);
    duplicate = topology; duplicate.plans[1].?.epoch += 1;
    try t.expectError(error.Stale, mode.encodeTopology(binding, .possible, plan, duplicate, &request));
    try t.expectEqualSlices(u8, &accepted, &request);
    duplicate = topology; duplicate.plans[7] = second;
    try t.expectError(error.Descriptor, mode.encodeTopology(binding, .possible, plan, duplicate, &request));
    try t.expectEqualSlices(u8, &accepted, &request);
    // The product collects every other active Window, replacing only the
    // candidate's own Head. DMA flips do not alter that timing snapshot.
    const Runtime = @import("gsp_runtime.zig");
    const running = try t.allocator.create(Runtime.Owner); defer t.allocator.destroy(running); running.* = .{};
    var active = std.mem.zeroes(Runtime.ActiveDisplayImage);
    active.boot_mode = second; active.head = second.head;
    running.display_images[second.window] = active;
    try t.expectEqualDeep(topology, try running.modeTopology(plan));
    active.image.dma += 1; running.display_images[second.window] = active;
    try t.expectEqualDeep(topology, try running.modeTopology(plan));
    active.boot_mode.?.signal.clock += 1000; running.display_images[second.window] = active;
    try t.expect(!std.meta.eql(topology, try running.modeTopology(plan)));
    running.display_images[second.window] = null;
    try t.expectEqualDeep(mode.Topology.single(plan), try running.modeTopology(plan));
}
