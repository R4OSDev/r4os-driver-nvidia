//! Part of the existing display command/Device test groups. Complete C
//! payloads come from the pinned original NVIDIA headers, not this encoder.
const std = @import("std");
const t = std.testing;
const link = @import("gsp_hdmi_link.zig");
const vectors = @embedFile("fixtures/display-hdmi-570.144.bin");
fn word(at: usize) u32 { return std.mem.readInt(u32, vectors[at..][0..4], .little); }
pub fn reference(op: link.Operation, plan: link.Plan) ![]const u8 {
    if (op == .avi and plan.mode.cta_vic != 0) {
        const receiver = @embedFile("fixtures/display-receiver-hdmi-570.144.bin");
        var offset: usize = 4;
        for (0..std.mem.readInt(u32, receiver[0..4], .little)) |_| {
            const vic = std.mem.readInt(u32, receiver[offset..][0..4], .little);
            const n = std.mem.readInt(u32, receiver[offset + 4..][0..4], .little);
            offset += 8;
            if (vic == plan.mode.cta_vic) return receiver[offset..][0..n];
            offset += n;
        }
        return error.Fixture;
    }
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
/// Independent packet field checks for the live colored mode fixture. Legacy
/// transactions continue using the complete original-header C vectors above.
pub fn checkColorRequest(plan: link.Plan, op: link.Operation, bytes: []const u8) !void {
    const signal = plan.mode.color orelse return error.Fixture;
    try t.expectEqual(plan.mode.signal.display_id, std.mem.readInt(u32, bytes[28..32], .little));
    if (op != .avi and op != .gcp and op != .hdr_disable) {
        const expected = try reference(op, plan);
        try t.expectEqualSlices(u8, expected[32..], bytes[32..]);
        return;
    }
    if (op == .hdr_disable and signal.transfer == .srgb) {
        try t.expect(bytes.len == 40 and std.mem.readInt(u32, bytes[8..12], .little) == 0x730289 and bytes[32] == 0x87);
        return;
    }
    try t.expect(bytes.len == 84 and std.mem.readInt(u32, bytes[8..12], .little) == 0x730288);
    const packet = bytes[45..];
    const length = std.mem.readInt(u32, bytes[36..40], .little);
    if (op == .gcp) {
        try t.expect(length == 10 and packet[0] == 3 and packet[3] == 0x10 and packet[4] == @as(u8, if (signal.bpc == 10) 5 else 0));
        return;
    }
    var sum: u8 = 0;
    for (packet[0..length]) |value| sum +%= value;
    try t.expectEqual(@as(u8, 0), sum);
    if (op == .avi) {
        try t.expect(length == 17 and packet[0] == 0x82 and packet[1] == 2 and packet[2] == 13 and packet[7] == plan.mode.cta_vic);
        try t.expectEqual(@as(u8, if (signal.primaries == .bt2020) 0xc0 else 0), packet[5]);
        const range: u8 = if (signal.range == .full) 8 else 4;
        try t.expectEqual(range | @as(u8, if (signal.primaries == .bt2020) 0x60 else 0), packet[6]);
    } else {
        const metadata = signal.metadata orelse return error.Fixture;
        try t.expect(length == 30 and packet[0] == 0x87 and packet[1] == 1 and packet[2] == 26 and packet[5] == 0);
        try t.expectEqual(@as(u8, if (signal.transfer == .pq) 2 else 3), packet[4]);
        for (metadata.primaries, 0..) |value, i| try t.expectEqual(value, std.mem.readInt(u16, packet[6 + i * 2..][0..2], .little));
        for (metadata.white, 0..) |value, i| try t.expectEqual(value, std.mem.readInt(u16, packet[18 + i * 2..][0..2], .little));
        for ([_]u16{ metadata.max_mastering, metadata.min_mastering, metadata.max_cll, metadata.max_fall }, 0..) |value, i|
            try t.expectEqual(value, std.mem.readInt(u16, packet[22 + i * 2..][0..2], .little));
    }
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
    // The live transaction uses the shared receiver/source/link admission,
    // including 30-bpp TMDS cost, real HDR payload and matching AVI/GCP.
    receiver.report.max_tmds_hz = 600_000_000;
    receiver.report.hdmi_deep_color = 1;
    receiver.report.rgb_quantization_selectable = true;
    receiver.report.colorimetry = 0x80;
    receiver.report.hdr_present = true;
    receiver.report.hdr_eotf = 12;
    receiver.report.hdr_static = 1;
    var hdr = saved;
    hdr.signal.clock = 148_500_000;
    hdr.signal.bpc = 10;
    hdr.color = .{ .format = .xr30, .bpc = 10, .primaries = .bt2020, .transfer = .pq, .range = .limited,
        .reference_white = 2_030_000, .peak = 10_000_000,
        .metadata = .{ .max_mastering = 1000, .min_mastering = 50, .max_cll = 1000, .max_fall = 400 } };
    try t.expectError(error.Incomplete, link.derive(hdr, object, snapshot));
    hdr.color_pipeline = .{ .linear_composition = true, .output_transform = true, .opaque_output = true };
    const encoded_hdr = try link.derive(hdr, object, snapshot);
    try t.expect(encoded_hdr.color.?.tmds_hz == 185_625_000 and !encoded_hdr.color.?.clear_hdr);
    var packet: [link.max_bytes]u8 = undefined;
    try t.expectEqual(@as(usize, 84), try link.encode(encoded_hdr, .hdr_disable, &packet));
    try t.expectEqualSlices(u8, &.{ 0x87, 1, 26, 0xc3, 2, 0 }, packet[45..51]);
    try t.expectEqualSlices(u8, &.{ 0xe8, 3, 50, 0, 0xe8, 3, 0x90, 1 }, packet[67..75]);
    _ = try link.encode(encoded_hdr, .avi, &packet);
    try t.expect(packet[50] == 0xc0 and packet[51] == 0x64);
    _ = try link.encode(encoded_hdr, .gcp, &packet);
    try t.expect(packet[49] == 5);
    receiver.report.hdmi_deep_color = 0;
    try t.expectError(error.Unsupported, link.derive(hdr, object, snapshot));
    receiver.report.hdmi_deep_color = 1;
    hdr.signal.clock = 594_000_000;
    try t.expectError(error.Bandwidth, link.derive(hdr, object, snapshot));
    hdr.signal.clock = 148_500_000;
    hdr.color.?.range = .full;
    receiver.report.rgb_quantization_selectable = false;
    hdr.cta_vic = 16; hdr.receiver_mode_id = 1; receiver.connected = true;
    try t.expectError(error.Unsupported, link.derive(hdr, object, snapshot));
    snapshot.coherent = false;
    try t.expectError(error.Stale, link.derive(saved, object, snapshot));
}
