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
    try checkAdditionalRoute();
    try checkSorAssignment();
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

fn checkSorAssignment() !void {
    const sor = @import("gsp_sor_assignment.zig");
    const original = @embedFile("fixtures/display-sor-570.144.bin");
    const request: sor.Request = .{ .object = .{ .epoch = 11, .client = 12, .display = 13 },
        .display_id = 8, .protected = .{ 0, 4, 0, 0 } };
    var bytes: [sor.max_bytes]u8 = undefined;
    try t.expectEqualSlices(u8, original[0..26], bytes[0..try sor.encode(request, .caps, &bytes)]);
    try t.expectEqualSlices(u8, original[52..156], bytes[0..try sor.encode(request, .assign, &bytes)]);
    const Record = @import("gsp_exchange.zig").message.Record;
    const caps: Record = .{ .shape = .{ .message_bytes = 26, .checksum_bytes = 0, .storage_bytes = 26, .elements = 1 },
        .queue_sequence = 0, .rpc = .{ .function = sor.function, .result = 0 }, .payload = original[26..52] };
    const assigned: Record = .{ .shape = .{ .message_bytes = 104, .checksum_bytes = 0, .storage_bytes = 104, .elements = 1 },
        .queue_sequence = 0, .rpc = .{ .function = sor.function, .result = 0 }, .payload = original[156..260] };
    var work: sor.Work = .{ .request = request, .generation = 7, .sequence = 1, .deadline = 100, .pending = true };
    try t.expect(!work.crossbar() and !work.complete);
    try work.consume(try sor.decode(request, .caps, caps), 1);
    try t.expect(work.crossbar() and !work.complete and work.operation == .assign);
    work.pending = true;
    try work.consume(try sor.decode(request, .assign, assigned), 2);
    try t.expect(work.complete and work.assignment.?.sor == 2 and work.assignment.?.displays[1] == 4);
    try t.expectError(error.Stale, work.consume(try sor.decode(request, .assign, assigned), 2));
    // A firmware rejection is a failed additional-output admission, never
    // an invented assignment or permission to steal the primary SOR.
    var bad = original[156..260].*;
    var record = assigned; record.payload = &bad;
    std.mem.writeInt(u32, bad[12..16], 0x57, .little);
    try t.expect((try sor.decode(request, .assign, record)).rejected.status == 0x57);
    bad = original[156..260].*;
    std.mem.writeInt(u32, bad[52..56], 16, .little);
    std.mem.writeInt(u32, bad[72..76], 16, .little);
    try t.expectError(error.Binding, sor.decode(request, .assign, record));
    bad = original[156..260].*;
    std.mem.writeInt(u32, bad[84..88], 2, .little);
    try t.expectError(error.Binding, sor.decode(request, .assign, record));
    bad = original[156..260].*; bad[96] |= 4;
    try t.expectError(error.Binding, sor.decode(request, .assign, record));
    bad = original[156..260].*; bad[32] = 0;
    try t.expectError(error.Payload, sor.decode(request, .assign, record));
    var invalid = request; invalid.protected[2] = 8;
    try t.expectError(error.Descriptor, sor.encode(invalid, .assign, &bytes));
    // An explicit non-crossbar capability response completes without a setter.
    var fixed: sor.Work = .{ .request = request, .generation = 7, .sequence = 2, .deadline = 100, .pending = true };
    try fixed.consume(.{ .caps = .{ 0, 0 } }, 1);
    try t.expect(fixed.complete and !fixed.crossbar() and fixed.assignment == null);
}

fn checkAdditionalRoute() !void {
    const route = @import("gsp_output_route.zig");
    const snapshot = try t.allocator.create(@import("gsp_outputs.zig").Snapshot); defer t.allocator.destroy(snapshot);
    helpers.outputFixture(snapshot, 11, 12);
    snapshot.count = 2; snapshot.topology.count = 2;
    snapshot.topology.window_heads = @splat(0);
    @memcpy(snapshot.topology.window_heads.?[0..4], &[_]u8{ 1, 1, 2, 2 });
    snapshot.topology.routes[1] = snapshot.topology.routes[0];
    snapshot.topology.routes[1].id = 8;
    snapshot.topology.routes[1].resource.?.index = 2;
    snapshot.topology.routes[1].connectors.?.data[0].index = 5;
    snapshot.receivers[1] = .{ .epoch = 11, .client = 12, .display_id = 8 };
    try install(&snapshot.receivers[1]);
    var raw = helpers.bootFixture(1920, 1080);
    raw.capabilities = 0x0c03; // Real modeled masks: heads0/1, SOR2/3.
    const hardware: @import("gsp_display_engine_wire.zig").StaticInfo = .{ .capabilities = 0, .windows = 15,
        .fb_remapper = true, .heads = 2, .i2c_port = 0, .internal_displays = 0, .embedded_dp = 0,
        .external_mux = false, .internal_mux = false, .channels = 81 };
    const source: route.Source = .{ .epoch = 11, .held_generation = 4, .boot_generation = 3 };
    const primary: a.GfxNativeBootInfo = .{ .generation = 3, .physical_address = 0xd0000000,
        .byte_length = 8192 * 1080, .pitch = 8192, .width = 1920, .height = 1080, .format = a.gfx_buffer_format_xrgb8888 };
    const first = try boot.bind(try boot.capture(&raw, &primary, 3), snapshot, 11, 4);
    var used: [8]?route.Claim = @splat(null);
    used[3] = try route.identify(first, snapshot);
    snapshot.topology.routes[1].resource.?.index = 0xffffffff;
    const assigning = try route.assignment(.{ .epoch = 11, .client = 12, .display = 13 }, snapshot, &used, 8);
    try t.expect(assigning.request.excluded() == 8 and assigning.request.protected[3] == 4 and assigning.connector.index == 5);
    try t.expectError(error.Unsupported, route.choose(source, &raw, hardware, snapshot, &used, 8, 1));
    snapshot.topology.routes[1].resource.?.index = 2;
    const second = try route.choose(source, &raw, hardware, snapshot, &used, 8, 1);
    try t.expect(second.claim.head == 0 and second.claim.window == 0 and second.claim.sor == 2 and second.claim.connector.index == 5);
    try t.expect(second.plan.width == 65 and second.plan.height == 20 and second.plan.signal.clock == 1_000_000 and
        second.plan.signal.sor_control == 0x101 and second.plan.receiver_mode_id == 1 and second.plan.cursor_size == 0);
    try t.expectEqualDeep(second.plan, try route.derive(source, &raw, hardware, snapshot, second.claim, 1));
    try t.expect((try route.derive(source, &raw, hardware, snapshot, second.claim, 2)).width == 96);
    try t.expectError(error.Descriptor, route.derive(source, &raw, hardware, snapshot, second.claim, 0));
    used[0] = second.claim;
    try t.expectError(error.Busy, route.choose(source, &raw, hardware, snapshot, &used, 8, 1));
    used[0] = null;
    snapshot.topology.heads[0].display_id = 8;
    try t.expectEqualDeep(second.plan, try route.derive(source, &raw, hardware, snapshot, second.claim, 1));
    try t.expectError(error.Routing, route.choose(source, &raw, hardware, snapshot, &used, 8, 1));
    snapshot.topology.heads[0].display_id = 4;
    try t.expectError(error.Routing, route.derive(source, &raw, hardware, snapshot, second.claim, 1));
    snapshot.topology.heads[0].display_id = null;
    try t.expectError(error.Routing, route.derive(source, &raw, hardware, snapshot, second.claim, 1));
    snapshot.topology.heads[0].display_id = 0;
    snapshot.topology.window_heads.?[0] = 2;
    try t.expectError(error.Unsupported, route.derive(source, &raw, hardware, snapshot, second.claim, 1));
    const alternate = try route.choose(source, &raw, hardware, snapshot, &used, 8, 1);
    try t.expect(alternate.claim.window == 1 and alternate.claim.head == 0);
    snapshot.topology.window_heads.?[0] = 1;
    snapshot.topology.routes[1].connectors.?.data[0].index = 1;
    try t.expectError(error.Busy, route.choose(source, &raw, hardware, snapshot, &used, 8, 1));
    snapshot.topology.routes[1].connectors.?.data[0].index = 5;
    snapshot.topology.routes[1].resource.?.dynamic = true;
    try t.expectError(error.Unsupported, route.choose(source, &raw, hardware, snapshot, &used, 8, 1));
    snapshot.topology.routes[1].resource.?.dynamic = false;
    snapshot.receivers[1].connected = false;
    try t.expectError(error.Stale, route.choose(source, &raw, hardware, snapshot, &used, 8, 1));
    snapshot.receivers[1].connected = true;
    raw.capabilities &= ~@as(u32, 0x400);
    try t.expectError(error.Unsupported, route.derive(source, &raw, hardware, snapshot, second.claim, 1));
    raw.capabilities |= 0x400;
    snapshot.topology.routes[1].connectors.?.data[0].kind = 0x46;
    snapshot.topology.routes[1].resource.?.protocol = 8;
    const dp = try route.choose(source, &raw, hardware, snapshot, &used, 8, 1);
    try t.expect(dp.plan.displayPort() and !dp.plan.transport_hdmi and dp.plan.signal.sor_control == 0x801);
    try t.expectError(error.Routing, route.derive(source, &raw, hardware, snapshot, second.claim, 1));
    snapshot.topology.window_heads = null;
    try t.expectError(error.Unsupported, route.derive(source, &raw, hardware, snapshot, dp.claim, 1));
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
