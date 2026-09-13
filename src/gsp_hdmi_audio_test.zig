const std = @import("std");
const t = std.testing;
const audio = @import("gsp_hdmi_audio.zig");
const vectors = @embedFile("fixtures/display-audio-570.144.bin");
pub fn reference(operation: audio.Operation) []const u8 {
    var offset: usize = 4;
    for (0..4) |_| {
        const op = std.mem.readInt(u32, vectors[offset..][0..4], .little);
        const length = std.mem.readInt(u32, vectors[offset+4..][0..4], .little);
        offset += 8;
        if (op == @intFromEnum(operation)) return vectors[offset..][0..length];
        offset += length;
    }
    unreachable;
}
pub fn install(report: *@import("r4gfx_edid").Report) void {
    report.manufacturer = .{'O','S','S'}; report.product = 0x79;
    report.name = @splat(0); @memcpy(report.name[0..4], "OSSI");
    report.cta_revision = 3; report.basic_audio = true;
    report.audio_count = 1;
    report.audio[0] = .{ .format = 1, .channels = 2, .rates = 7, .detail = 1 };
}
pub fn check() !void {
    const helpers = @import("gsp_display_commands_test.zig");
    const a = @import("r4os").abi;
    const snapshot = try t.allocator.create(@import("gsp_outputs.zig").Snapshot);
    defer t.allocator.destroy(snapshot);
    helpers.outputFixture(snapshot, 11, 12);
    const raw = helpers.bootFixture(1920, 1080);
    const boot: a.GfxNativeBootInfo = .{ .generation = 3, .physical_address = 0xd0000000,
        .byte_length = 8192 * 1080, .pitch = 8192, .width = 1920, .height = 1080, .format = a.gfx_buffer_format_xrgb8888 };
    const mode = @import("gsp_boot_mode.zig");
    const saved = try mode.bind(try mode.capture(&raw, &boot, 3), snapshot, 11, 4);
    const object: @import("gsp_display_rpc.zig").Object = .{ .epoch = 11, .client = 12, .display = 13 };
    var plan = try audio.derive(saved, object, snapshot);
    var bytes: [audio.max_bytes]u8 = undefined;
    try t.expect(plan.data == null);
    try t.expectError(error.Unsupported, audio.encode(plan, .unmute, &bytes));
    const receiver = &snapshot.receivers[0];
    receiver.connected = true; receiver.status = .valid_edid;
    receiver.report = .{ .digital = true, .hdmi = true };
    install(&receiver.report);
    plan = try audio.derive(saved, object, snapshot);
    try t.expect(plan.data.?.stereo_48k_s16 and plan.mode.head == 1);
    for ([_]audio.Operation{ .mute, .clear, .publish, .unmute }) |op| {
        const expected = reference(op);
        const length = try audio.encode(plan, op, &bytes);
        try t.expectEqualSlices(u8, expected, bytes[0..length]);
        var record: @import("gsp_message.zig").Record = .{ .shape = .{ .message_bytes = @intCast(length), .checksum_bytes = 0, .storage_bytes = @intCast(length), .elements = 1 },
            .queue_sequence = 0, .rpc = .{ .function = audio.function, .result = 0 }, .payload = bytes[0..length] };
        try t.expect((try audio.decode(plan, op, record)).status == 0);
        bytes[length - 1] ^= 1;
        try t.expectError(error.Unexpected, audio.decode(plan, op, record));
        record.rpc.result = 0x65;
        try t.expect((try audio.decode(plan, op, record)).rpc_error);
    }
    receiver.report.basic_audio = false; receiver.report.audio[0].detail = 4;
    plan = try audio.derive(saved, object, snapshot);
    try t.expect(!plan.data.?.stereo_48k_s16);
    try t.expectError(error.Unsupported, audio.encode(plan, .unmute, &bytes));
    receiver.report.warnings |= @import("r4gfx_edid").Warning.checksum;
    try t.expect((try audio.derive(saved, object, snapshot)).data == null);
}
