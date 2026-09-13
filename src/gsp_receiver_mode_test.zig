//! Extends the existing display-command and actual Device groups.
const std = @import("std");
const t = std.testing;
const boot = @import("gsp_boot_mode.zig");
const modes = @import("gsp_receiver_mode.zig");
const helpers = @import("gsp_display_commands_test.zig");
const receiver = @import("gsp_receiver.zig");
const a = @import("r4os").abi;
const vectors = @embedFile("fixtures/display-receiver-mode-570.144.bin");
fn word(at: usize) u32 { return std.mem.readInt(u32, vectors[at..][0..4], .little); }

pub fn check() !void {
    const snapshot = try t.allocator.create(@import("gsp_outputs.zig").Snapshot); defer t.allocator.destroy(snapshot);
    helpers.outputFixture(snapshot, 11, 12);
    const raw = helpers.bootFixture(1920, 1080);
    const info: a.GfxNativeBootInfo = .{ .generation = 3, .physical_address = 0xd0000000,
        .byte_length = 8192 * 1080, .pitch = 8192, .width = 1920, .height = 1080, .format = a.gfx_buffer_format_xrgb8888 };
    const saved = try boot.bind(try boot.capture(&raw, &info, 3), snapshot, 11, 4);
    try t.expectError(error.Stale, modes.select(saved, snapshot, 1));
    const capture = &snapshot.receivers[0];
    capture.connected = true; capture.status = .valid_edid;
    capture.report = .{ .digital = true, .hdmi = true, .bits_per_color = 8, .max_tmds_hz = 165_000_000, .mode_count = 5 };
    // This recognizable but incomplete timing must not consume ID 1.
    capture.report.modes[0] = .{ .width = 800, .height = 600, .nominal_millihz = 60000, .flags = receiver.edid.timing.incomplete };
    try t.expect(word(0) == 4 and vectors.len == 308);
    for (0..word(0)) |index| {
        const at = 4 + index * 76;
        capture.report.modes[index + 1] = .{ .width = word(at), .height = word(at + 4), .h_total = word(at + 8), .v_total = word(at + 12),
            .h_start = word(at + 16), .h_end = word(at + 20), .v_start = word(at + 24), .v_end = word(at + 28),
            .clock_hz = word(at + 32), .flags = word(at + 36), .vic = @intCast(word(at + 40)) };
    }
    var published: a.GfxReceiverInfo = .{};
    try @import("gsp_catalog.zig").encode(&published, &snapshot.topology.routes[0], capture);
    try t.expect(published.mode_count == 4 and published.flags & a.gfx_output_flag_receiver_incomplete != 0);
    for (0..4) |index| {
        const plan = try modes.select(saved, snapshot, @intCast(index + 1));
        const signal = plan.signal;
        const fields = [_]u32{ signal.clock, signal.total, signal.sync_end, signal.blank_end, signal.blank_start, signal.viewport, signal.polarity, signal.min_frame_idle };
        for (fields, 0..) |field, i| try t.expectEqual(word(4 + index * 76 + 44 + i * 4), field);
        try t.expect(plan.receiver_mode_id == published.modes[index].mode_id and plan.width == published.modes[index].width and
            plan.height == published.modes[index].height and plan.refresh_micro_hz / 1000 == published.modes[index].refresh_millihz);
        try t.expect(plan.boot_generation == saved.boot_generation and plan.signal.sor == saved.signal.sor and
            plan.epoch == saved.epoch and plan.output_generation == saved.output_generation and plan.receipt_serial == saved.receipt_serial);
        const link = try @import("gsp_hdmi_link.zig").derive(plan, .{ .epoch = 11, .client = 12, .display = 13 }, snapshot);
        try t.expect(link.receiver_known and link.hdmi_vic == 0 and plan.signal.hdmi == 0);
        if (plan.cta_vic != 0) {
            var encoded: [@import("gsp_hdmi_link.zig").max_bytes]u8 = undefined;
            const n = try @import("gsp_hdmi_link.zig").encode(link, .avi, &encoded);
            try t.expectEqualSlices(u8, try @import("gsp_hdmi_link_test.zig").reference(.avi, link), encoded[0..n]);
        }
    }
    try t.expectError(error.Descriptor, modes.select(saved, snapshot, 0));
    try t.expectError(error.Unsupported, modes.select(saved, snapshot, 5));
    const timing = capture.report.modes[1];
    capture.report.modes[1].flags |= receiver.edid.timing.interlaced;
    try t.expectError(error.Unsupported, modes.select(saved, snapshot, 1));
    capture.report.modes[1] = timing; capture.report.modes[1].flags |= receiver.edid.timing.y420_only;
    try t.expectError(error.Unsupported, modes.select(saved, snapshot, 1));
    capture.report.modes[1] = timing; capture.report.modes[1].vic = 193;
    try t.expectError(error.Unsupported, modes.select(saved, snapshot, 1));
    capture.report.modes[1] = timing; capture.report.warnings = receiver.edid.Warning.missing;
    try t.expectError(error.Stale, modes.select(saved, snapshot, 1));
    capture.report.warnings = 0; capture.connected = null;
    try t.expectError(error.Stale, modes.select(saved, snapshot, 1));
    capture.connected = true; capture.report.bits_per_color = 6;
    try t.expectError(error.Unsupported, modes.select(saved, snapshot, 1));
    capture.report.bits_per_color = 8; snapshot.generation += 1;
    try t.expectError(error.Stale, modes.select(saved, snapshot, 1));
    snapshot.generation -= 1;
    const link = @import("gsp_hdmi_link.zig");
    const object: @import("gsp_display_rpc.zig").Object = .{ .epoch = 11, .client = 12, .display = 13 };
    capture.report.modes[1].clock_hz = 297_000_000; capture.report.max_tmds_hz = 0;
    try t.expectError(error.Unsupported, link.derive(try modes.select(saved, snapshot, 1), object, snapshot));
    capture.report.max_tmds_hz = 300_000_000;
    _ = try link.derive(try modes.select(saved, snapshot, 1), object, snapshot);
    capture.report.max_tmds_hz = 600_000_000; capture.report.modes[1].clock_hz = 594_000_000;
    try t.expectError(error.Unsupported, link.derive(try modes.select(saved, snapshot, 1), object, snapshot));
    capture.report.scdc = true;
    _ = try link.derive(try modes.select(saved, snapshot, 1), object, snapshot);
    // Source mode IDs cannot reach entries omitted by the bounded catalog.
    capture.report.mode_count = 65;
    @memset(capture.report.modes[0..65], timing);
    _ = try modes.select(saved, snapshot, 64);
    try t.expectError(error.Unsupported, modes.select(saved, snapshot, 65));
}

/// An actual complete EDID parse supplies the small receiver mode used by
/// the Device model. Synthetic dimensions keep real buffer paths bounded.
pub fn install(capture: *receiver.Capture) !void {
    @memset(&capture.bytes, 0);
    const base = capture.bytes[0..128];
    @memcpy(base[0..8], &[_]u8{ 0, 255, 255, 255, 255, 255, 255, 0 });
    base[8] = 4; base[9] = 67; base[18] = 1; base[19] = 4; base[20] = 0xa2; base[24] = 2;
    @memset(base[38..54], 1);
    const d = base[54..72];
    d[0] = 100; // 1 MHz, exactly representable in EDID 10 kHz units.
    d[2] = 65; d[3] = 24; d[4] = 1; // 280 horizontal blanking pixels.
    d[5] = 20; d[6] = 45; d[8] = 88; d[9] = 44; d[10] = 0x45; d[17] = 0x1e;
    // A second, differently sized real EDID timing drives replacement of
    // the imported SYSTEM shadow and native VRAM scanout in the Device case.
    @memcpy(base[72..90], d);
    base[72] = 120; base[74] = 96; base[77] = 24;
    base[126] = 1;
    finish(base);
    const cta = capture.bytes[128..256];
    @memcpy(cta[0..12], &[_]u8{ 2, 3, 12, 0, 0x67, 3, 12, 0, 0x10, 0, 0, 33 });
    finish(cta);
    capture.connected = true; capture.status = .valid_edid; capture.edid_bytes = 256;
    try receiver.edid.parse(capture.bytes[0..256], &capture.report);
    try t.expect(capture.report.complete() and capture.report.hdmi and capture.report.max_tmds_hz == 165_000_000 and capture.report.mode_count == 2);
}
fn finish(bytes: []u8) void { var sum: u8 = 0; for (bytes[0..127]) |b| sum +%= b; bytes[127] = 0 -% sum; }
