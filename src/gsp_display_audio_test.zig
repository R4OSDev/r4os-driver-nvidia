const std = @import("std");
const t = std.testing;
const audio = @import("gsp_display_audio.zig");
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
    try checkMonitorPower(saved, object);
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
fn checkMonitorPower(mode: @import("gsp_boot_mode.zig").Plan, object: @import("gsp_display_rpc.zig").Object) !void {
    const power = @import("gsp_monitor_power.zig");
    const deadline = 100 * std.time.ns_per_s;
    var bytes: [power.max_bytes]u8 = undefined;
    for ([_]bool{false, true}) |on| {
        var work = try power.Work.init(.{ .object = object, .mode = mode, .kind = .digital, .sink_control = true }, on, 7, deadline);
        const length = try work.encode(&bytes);
        try t.expect(length == 44 and word(&bytes, 8) == 0x730295 and word(&bytes, 16) == 20 and
            word(&bytes, 24) == 0 and word(&bytes, 28) == mode.signal.display_id and word(&bytes, 32) == @intFromBool(on) and
            word(&bytes, 36) == 0 and word(&bytes, 40) == 0);
        work.pending = true;
        var reply = powerReply(bytes[0..length]);
        bytes[28] ^= 1;
        try t.expectError(error.Unexpected, work.consume(reply, 1, 8));
        bytes[28] ^= 1;
        reply.rpc.result = 0x57;
        try t.expectError(error.RmRejected, work.consume(reply, 1, 8));
        reply.rpc.result = 0;
        try work.consume(reply, 1, 8);
        try t.expect(work.stage == .complete and work.receipt == 8);
    }
    var dp = mode;
    dp.transport_hdmi = false; dp.signal.sor_control = 0x802;
    var off = try power.Work.init(.{ .object = object, .mode = dp, .kind = .dp_sst, .sink_control = true }, false, 9, deadline);
    try t.expect(try off.encode(&bytes) == 72 and word(&bytes, 8) == 0x731341 and word(&bytes, 40) == 0x600 and bytes[44] == 2);
    off.pending = true;
    put(&bytes, 60, 1);
    try off.consume(powerReply(&bytes), 1, 10);
    try t.expect(off.stage == .main_link and off.receipt == 10);
    const length = try off.encode(&bytes);
    try t.expect(length == 36 and word(&bytes, 8) == 0x731356 and word(&bytes, 32) == 0);
    try off.consume(powerReply(bytes[0..length]), 2, 11);
    try t.expect(off.stage == .complete and off.receipt == 11);
    var on = try power.Work.init(.{ .object = object, .mode = dp, .kind = .dp_sst, .sink_control = true }, true, 12, deadline);
    try t.expect(try on.encode(&bytes) == 72 and word(&bytes, 40) == 0x600 and bytes[44] == 1);
    on.pending = true; on.attempts = 1;
    put(&bytes, 64, 2); // AUX_DEFER must not grant a power receipt.
    try on.consume(powerReply(&bytes), 1, 13);
    try t.expect(on.stage == .sink and on.receipt == 0 and on.not_before > 1);
    on.attempts = 40;
    try t.expectError(error.RetryExhausted, on.consume(powerReply(&bytes), 2, 14));
    put(&bytes, 64, 0); put(&bytes, 60, 1);
    try on.consume(powerReply(&bytes), 3, 15);
    try t.expect(on.stage == .complete and on.receipt == 15 and on.not_before > 3);
    const old = try power.Work.init(.{ .object = object, .mode = dp, .kind = .dp_sst, .sink_control = false }, true, 16, deadline);
    try t.expect(old.stage == .complete and old.receipt == 0); // DP 1.0 has no sink D-state control.
}
fn powerReply(bytes: []const u8) @import("gsp_message.zig").Record {
    return .{ .shape = .{ .message_bytes = @intCast(bytes.len), .checksum_bytes = 0, .storage_bytes = @intCast(bytes.len), .elements = 1 },
        .queue_sequence = 0, .rpc = .{ .function = 76, .result = 0 }, .payload = bytes };
}
fn word(bytes: []const u8, offset: usize) u32 { return std.mem.readInt(u32, bytes[offset..][0..4], .little); }
fn put(bytes: []u8, offset: usize, value: u32) void { std.mem.writeInt(u32, bytes[offset..][0..4], value, .little); }
