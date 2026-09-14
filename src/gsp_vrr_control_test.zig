//! Extends the existing display-command group. Byte fixtures were compiled
//! independently from the original NVIDIA C headers by VrrWire.c.
const std = @import("std");
const t = std.testing;
const vrr = @import("gsp_vrr_control.zig");
const helper = @import("gsp_display_commands_test.zig");
const runtime = @import("gsp_runtime.zig");
const a = @import("r4os").abi;
const vectors = @embedFile("fixtures/display-vrr-570.144.bin");
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn reference(wanted: u32) ![]const u8 {
    var at: usize = 0;
    while (at < vectors.len) {
        const id = word(vectors, at);
        const n = word(vectors, at + 4);
        at += 8;
        if (id == wanted) return vectors[at..][0..n];
        at += n;
    }
    return error.Fixture;
}
fn referenceId(work: vrr.Work) !u32 {
    return switch (work.phase) {
        .notify => if (work.enabled) 1 else 2,
        .pstate_initial => 3,
        .pstate_active => 4,
        .pstate_inactive => 5,
        .pstate_off => 6,
        .arm => if (work.enabled) 7 else 8,
        .disarm => if (work.enabled) 9 else 10,
        .clear_elv => 11,
        .link_packet => if (work.enabled) 12 else 13,
        else => error.Fixture,
    };
}
fn record(bytes: []const u8) @import("gsp_message.zig").Record {
    return .{ .shape = .{ .message_bytes = bytes.len, .checksum_bytes = 0, .storage_bytes = bytes.len, .elements = 1 }, .queue_sequence = 0, .rpc = .{ .function = 76, .result = 0 }, .payload = bytes };
}
pub fn check() !void {
    var raw = helper.bootFixture(1920, 1080);
    raw.heads[1].words[2] &= 0x7fffffff;
    const boot: a.GfxNativeBootInfo = .{ .generation = 3, .physical_address = 0xd0000000, .byte_length = 8192 * 1080, .pitch = 8192, .width = 1920, .height = 1080, .format = a.gfx_buffer_format_xrgb8888 };
    const saved = try runtime.boot_mode.capture(&raw, &boot, 3);
    const snapshot = try t.allocator.create(@import("gsp_outputs.zig").Snapshot);
    defer t.allocator.destroy(snapshot);
    helper.outputFixture(snapshot, 11, 12);
    snapshot.receivers[0].connected = true;
    snapshot.receivers[0].status = .valid_edid;
    snapshot.receivers[0].report.digital = true;
    snapshot.receivers[0].report.hdmi = true;
    snapshot.receivers[0].report.max_tmds_hz = 165_000_000;
    snapshot.receivers[0].report.refresh.hdmi = .{ .refresh = .{ .min_millihz = 50_000, .max_millihz = 75_000 } };
    const bound = try runtime.boot_mode.bind(saved, snapshot, 11, 4);
    const object: @import("gsp_display_rpc.zig").Object = .{ .epoch = 11, .client = 12, .display = 13 };
    const link: runtime.DisplayLink = .{ .plan = try runtime.display_link.derive(bound, object, snapshot), .acknowledged = 7, .receipt = 11 };
    const plan = try vrr.derive(bound, object, snapshot, link, 0xc67d);
    try pacingCheck(plan.refresh);
    try t.expect(plan.refresh.timeout_us == 20000 and plan.refresh.max_vtotal == 1350 and !plan.refresh.lfc);
    try t.expectError(error.Unsupported, vrr.derive(bound, object, snapshot, link, 0xc37d));
    snapshot.generation += 1;
    try t.expectError(error.Stale, vrr.derive(bound, object, snapshot, link, 0xc67d));
    snapshot.generation -= 1;
    snapshot.receivers[0].report.warnings = vrr.edid.Warning.missing;
    try t.expectError(error.Incomplete, vrr.derive(bound, object, snapshot, link, 0xc67d));
    snapshot.receivers[0].report.warnings = 0;
    for ([_]bool{ true, false }) |enabled| {
        var work = try vrr.Work.init(plan, enabled, 1, 2_000_000_000);
        var receipt: u64 = 1;
        for (0..16) |_| {
            if (work.phase == .complete) break;
            if (work.phase == .core) {
                const config = try work.coreConfig(0x1234, 255);
                const program = try vrr.commands.encode(config);
                const expected = try reference(if (enabled) 14 else 15);
                try t.expectEqual(expected.len, @as(usize, program.count) * 4);
                for (program.words[0..program.count], 0..) |value, i| try t.expectEqual(word(expected, i * 4), value);
                var invalid = config;
                invalid.initialize = true;
                try t.expectError(error.Descriptor, vrr.commands.encode(invalid));
                invalid = config;
                invalid.refresh_control.?.head = 8;
                try t.expectError(error.Descriptor, vrr.commands.encode(invalid));
                try t.expectError(error.Stale, work.completed(10));
                try work.submitted(10);
                try t.expectError(error.Stale, work.completed(11));
                try work.completed(10);
                continue;
            }
            work.length = try work.encode(&work.request);
            try t.expectEqualSlices(u8, try reference(try referenceId(work)), work.request[0..work.length]);
            work.pending = true;
            var bytes = work.request;
            try work.consume(record(bytes[0..work.length]), receipt, receipt + 1);
            receipt += 1;
        }
        try t.expect(work.phase == .complete and work.core_completed and !work.pending);
    }
    var bad = try vrr.Work.init(plan, true, 1, 2_000_000_000);
    bad.length = try bad.encode(&bad.request);
    bad.pending = true;
    var bytes = bad.request;
    bytes[28] ^= 1;
    try t.expectError(error.Unexpected, bad.consume(record(bytes[0..bad.length]), 1, 2));
    try t.expect(bad.phase == .link_packet and !bad.core_completed);
    bad = try vrr.Work.init(plan, true, 1, 2_000_000_000);
    bad.length = try bad.encode(&bad.request);
    bad.pending = true;
    bytes = bad.request;
    put(&bytes, 12, 0x56);
    try t.expectError(error.RmRejected, bad.consume(record(bytes[0..bad.length]), 1, 2));
    try t.expect(bad.last_status == 0x56 and !bad.core_completed);
    var dp = plan;
    dp.mode.transport_hdmi = false;
    dp.mode.signal.hdmi = 0;
    dp.mode.signal.sor_control = 0x802;
    try auxSequence(dp, true, false);
    try auxSequence(dp, false, false);
    try auxSequence(dp, true, true);
    var deferred = try vrr.Work.init(dp, true, 1, 2_000_000_000);
    for (0..4) |i| {
        deferred.length = try deferred.encode(&deferred.request);
        deferred.pending = true;
        bytes = deferred.request;
        put(&bytes, 64, 2); // Native AUX DEFER.
        const now = @as(u64, @intCast(i)) * 1_000_000 + 1;
        if (i == 3) {
            try t.expectError(error.Aux, deferred.consume(record(bytes[0..deferred.length]), i + 1, now));
        } else {
            try deferred.consume(record(bytes[0..deferred.length]), i + 1, now);
            try t.expect(!deferred.ready(now) and deferred.ready(now + 100_000) and deferred.phase == .link_read);
        }
    }
}
fn pacingCheck(plan: vrr.edid.vrr.Plan) !void {
    const Pacing = @import("gsp_refresh_pacing.zig").State;
    var pacing: Pacing = .{};
    try pacing.begin(1, plan, true, 100);
    try t.expect(!pacing.allowFrame(101) and pacing.scheduler.state == .enabling);
    try pacing.completed(true, 102);
    try t.expect(!pacing.allowFrame(103) and pacing.observer.summary().samples == 0);
    const base = 100_000_000;
    pacing.observe(.{ .sequence = 1, .frame_counter = 65535, .observed_ns = base });
    try t.expect(!pacing.allowFrame(base + plan.min_period_ns - 1));
    try t.expect(pacing.allowFrame(base + plan.min_period_ns));
    pacing.observe(.{ .sequence = 2, .frame_counter = 0, .observed_ns = base + 18_000_000 });
    try t.expect(pacing.observer.summary().samples == 1 and pacing.scheduler.state == .active);
    pacing.observe(.{ .sequence = 3, .frame_counter = 2, .observed_ns = base + 36_000_000 });
    try t.expect(pacing.observer.summary().samples == 0 and pacing.scheduler.previous_period_ns == 0);
    pacing.checkClock(base + 36_000_000 + plan.max_period_ns * 3 + 1);
    try t.expect(pacing.scheduler.state == .disabling and pacing.scheduler.reason == .stale_clock and
        !pacing.allowFrame(base + 100_000_000));
    try pacing.begin(1, plan, false, base + 100_000_000);
    try pacing.completed(false, base + 110_000_000);
    try t.expect(pacing.scheduler.state == .faulted and pacing.allowFrame(base + 120_000_000));
    try t.expectError(error.State, pacing.begin(1, plan, true, base + 121_000_000));
    try pacing.clearFault();
    try pacing.begin(1, plan, true, base + 122_000_000);
    try pacing.completed(true, base + 123_000_000);
    pacing.observe(.{ .sequence = 4, .frame_counter = 3, .observed_ns = base + 140_000_000 });
    for (0..3) |i| pacing.observe(.{ .sequence = 5 + i, .frame_counter = @intCast(4 + i),
        .observed_ns = base + 150_000_000 + i * 10_000_000 });
    try t.expect(pacing.scheduler.state == .disabling and pacing.scheduler.reason == .timing_fault);
    const output: a.GfxOutputTarget = .{ .adapter_id = 1, .connector_id = 2,
        .device_generation = 3, .connection_generation = 4, .display_generation = 1 };
    try t.expectError(error.State, pacing.bindTarget(output));
    try pacing.completed(false, base + 180_000_000);
    try t.expect(try pacing.bindTarget(output));
    pacing.fault(.user_flicker);
    try t.expect(!try pacing.bindTarget(output));
    try t.expect(pacing.scheduler.fault == .user_flicker);
    var replacement = output;
    replacement.connection_generation += 1;
    try t.expect(try pacing.bindTarget(replacement));
    try t.expect(pacing.scheduler.fault == .none and pacing.scheduler.state == .fixed and
        pacing.observer.summary().samples == 0 and pacing.scheduler.generation == output.display_generation);
}
fn auxSequence(plan: vrr.Plan, enabled: bool, mismatch: bool) !void {
    var work = try vrr.Work.init(plan, enabled, 1, 2_000_000_000);
    var downspread: u8 = if (enabled) 0x10 else 0x90;
    var receipt: u64 = 1;
    for (0..20) |_| {
        if (work.phase == .complete) break;
        if (work.phase == .core) {
            try work.submitted(10);
            try work.completed(10);
            continue;
        }
        work.length = try work.encode(&work.request);
        work.pending = true;
        var bytes = work.request;
        if (work.phase == .link_read or work.phase == .link_write or work.phase == .link_verify) {
            try t.expect(word(&bytes, 8) == 0x731341 and word(&bytes, 40) == 0x107);
            if (work.phase == .link_write) {
                try t.expect(word(&bytes, 36) == 8);
                downspread = bytes[44];
                try t.expect(downspread == @as(u8, if (enabled) 0x90 else 0x10));
            } else try t.expect(word(&bytes, 36) == 9);
            put(&bytes, 60, 1);
            put(&bytes, 64, 0);
            bytes[44] = downspread;
            if (mismatch and work.phase == .link_verify) {
                bytes[44] ^= 128;
                try t.expectError(error.Aux, work.consume(record(bytes[0..work.length]), receipt, receipt + 1));
                try t.expect(!work.core_completed);
                return;
            }
        }
        try work.consume(record(bytes[0..work.length]), receipt, receipt + 1);
        receipt += 1;
    }
    try t.expect(work.phase == .complete and work.core_completed);
}
