//! Part of the existing display command/Device test groups. Complete C
//! payloads come from the pinned original NVIDIA headers, not this encoder.
const std = @import("std");
const t = std.testing;
const link = @import("gsp_hdmi_link.zig");
const vectors = @embedFile("fixtures/display-hdmi-570.144.bin");
fn word(at: usize) u32 { return std.mem.readInt(u32, vectors[at..][0..4], .little); }
pub fn reference(op: link.Operation, plan: link.Plan) ![]const u8 {
    var at: usize = 4;
    for (0..word(0)) |_| {
        const n = word(at + 16);
        const found = word(at) == @intFromEnum(op) and word(at + 4) == @intFromBool(plan.mode.transport_hdmi) and
            word(at + 8) == plan.hdmi_vic and word(at + 12) == plan.caps;
        at += 20;
        if (found) return vectors[at..][0..n];
        at += n;
    }
    return error.Fixture;
}
pub fn check() !void {
    const mode = @import("gsp_boot_mode.zig");
    const helpers = @import("gsp_display_commands_test.zig");
    const a = @import("r4os").abi;
    var raw = helpers.bootFixture(1920, 1080);
    const boot: a.GfxNativeBootInfo = .{ .generation = 3, .physical_address = 0xd0000000,
        .byte_length = 8192 * 1080, .pitch = 8192, .width = 1920, .height = 1080, .format = a.gfx_buffer_format_xrgb8888 };
    const snapshot = try t.allocator.create(@import("gsp_outputs.zig").Snapshot); defer t.allocator.destroy(snapshot);
    helpers.outputFixture(snapshot, 11, 12);
    const saved = try mode.bind(try mode.capture(&raw, &boot, 3), snapshot, 11, 4);
    const object: @import("gsp_display_rpc.zig").Object = .{ .epoch = 11, .client = 12, .display = 13 };
    const plan = try link.derive(saved, object, snapshot);
    try t.expect(plan.mode.transport_hdmi and plan.caps == 0 and !plan.receiver_known);
    var at: usize = 4;
    try t.expect(word(0) == 14);
    for (0..word(0)) |_| {
        var value = plan;
        const op: link.Operation = @enumFromInt(word(at));
        value.mode.transport_hdmi = word(at + 4) != 0;
        value.hdmi_vic = @intCast(word(at + 8)); value.caps = word(at + 12);
        const length = word(at + 16); at += 20;
        var encoded: [link.max_bytes]u8 = undefined;
        try t.expectEqual(length, try link.encode(value, op, &encoded));
        try t.expectEqualSlices(u8, vectors[at..][0..length], encoded[0..length]);
        // Setter success validates the complete retained input, including the
        // inline packet. Error responses cannot be mistaken for success.
        var record: @import("gsp_message.zig").Record = .{ .shape = .{ .message_bytes = length, .checksum_bytes = 0, .storage_bytes = length, .elements = 1 }, .queue_sequence = 0,
            .rpc = .{ .function = link.function, .result = 0 }, .payload = encoded[0..length] };
        try t.expect((try link.decode(value, op, record)).status == 0);
        encoded[length - 1] ^= 1;
        try t.expectError(error.Unexpected, link.decode(value, op, record)); encoded[length - 1] ^= 1;
        std.mem.writeInt(u32, encoded[12..16], 0x57, .little);
        try t.expect((try link.decode(value, op, record)).status == 0x57);
        record.rpc.result = 0x65;
        try t.expect((try link.decode(value, op, record)).rpc_error);
        at += length;
    }
    try t.expectEqual(vectors.len, at);
    raw.heads[1].hdmi = 0;
    const dvi = try link.derive(try mode.bind(try mode.capture(&raw, &boot, 3), snapshot, 11, 4), object, snapshot);
    try t.expect(!dvi.mode.transport_hdmi);
    var work: link.Work = .{ .plan = dvi };
    work.pending = true; try work.afterAck(1); work.pending = true; try work.afterAck(2);
    try t.expect(work.phase == .scanout and work.acknowledged == 2);
    try work.scanoutComplete(); try t.expect(work.phase == .complete);
    var higher = saved; higher.signal.clock = 594_000_000;
    try t.expectError(error.Unsupported, link.derive(higher, object, snapshot));
    const receiver = &snapshot.receivers[0];
    receiver.status = .valid_edid;
    receiver.report = .{ .digital = true, .hdmi = true, .scdc = true, .scrambling_low_rates = true, .max_tmds_hz = 600_000_000 };
    const fast = try link.derive(higher, object, snapshot);
    try t.expect(fast.caps == 7 and fast.receiver_known);
    receiver.report.scdc = false;
    try t.expectError(error.Unsupported, link.derive(higher, object, snapshot));
    receiver.status = .incomplete_edid;
    try t.expect((try link.derive(saved, object, snapshot)).caps == 0);
    try t.expectError(error.Unsupported, link.derive(higher, object, snapshot));
    receiver.status = .valid_edid; receiver.report.scdc = true; receiver.report.max_tmds_hz = 340_000_000;
    higher.signal.clock = 0x80000000 | 340_340_000;
    _ = try link.derive(higher, object, snapshot); // Exact 340 MHz, not rounded.
    higher.signal.clock += 1;
    try t.expectError(error.Unsupported, link.derive(higher, object, snapshot));
    snapshot.coherent = false;
    try t.expectError(error.Stale, link.derive(saved, object, snapshot));
}
