//! Additional cases inside the existing real Device/receiver test group.
const std = @import("std");
const t = std.testing;
const hotplug = @import("gsp_hotplug.zig");

pub fn check() !void {
    var work: hotplug.Work = .{ .epoch = 7 };
    try t.expect(!try work.due(7, 0));
    try work.note(7, 1, .{ .hotplug = .{ .plug_mask = 0x80000000, .unplug_mask = 1 } });
    try work.note(7, 2, .{ .hotplug = .{ .plug_mask = 1, .unplug_mask = 0x80000000 } });
    try work.note(7, 3, .{ .dp_irq = 4 });
    try t.expect(work.plug_mask == 0x80000001 and work.unplug_mask == 0x80000001 and work.dp_mask == 4);
    try t.expect(!try work.due(7, hotplug.quiet_ns));
    try t.expect(try work.due(7, 3 + hotplug.quiet_ns));
    try work.started(7, 3 + hotplug.quiet_ns);
    try t.expect(!work.pending and work.capturing and work.scan_sequence == 3);
    try t.expectError(error.Busy, work.started(7, 3 + hotplug.quiet_ns));
    try work.note(7, 4 + hotplug.quiet_ns, .{ .dp_irq = 8 });
    try work.finished(7, 5 + hotplug.quiet_ns, true);
    try t.expect(work.pending and work.retries == 0 and work.dp_mask == 8);
    const due = work.dueNs();
    try t.expect(!try work.due(7, due - 1));
    try work.started(7, due);
    try work.finished(7, due + 1, false);
    try t.expect(!try work.due(7, due + 20 * std.time.ns_per_s));

    // A continuing bounce cannot postpone the first acquisition indefinitely.
    work = .{ .epoch = 7 };
    for (0..12) |i| try work.note(7, i * hotplug.quiet_ns, .{ .dp_irq = 1 });
    try t.expect(work.dueNs() == hotplug.burst_ns and try work.due(7, work.last_ns));
    try work.started(7, work.last_ns);
    var now = work.last_ns + 1;
    for (0..hotplug.max_retries + 1) |attempt| {
        try work.finished(7, now, true);
        if (attempt == hotplug.max_retries) break;
        now = work.dueNs();
        try t.expect(try work.due(7, now));
        try work.started(7, now);
        now += 1;
    }
    try t.expect(!work.pending and work.exhausted == 1 and work.scans == 3);
    try t.expect(!try work.due(7, now + 100 * std.time.ns_per_s));
    try t.expectError(error.Stale, work.note(8, now, .{ .dp_irq = 1 }));
    try t.expectError(error.Clock, work.note(7, 0, .{ .dp_irq = 1 }));
    try work.note(7, now + 1, .{ .hotplug = .{ .plug_mask = 1, .unplug_mask = 0 } });
    try t.expect(work.pending and work.retries == 0);

    var snapshot: @import("gsp_outputs.zig").Snapshot = .{ .coherent = true, .count = 1 };
    snapshot.receivers[0].connected = false;
    snapshot.receivers[0].status = .disconnected;
    try t.expect(!hotplug.retrySnapshot(&snapshot));
    snapshot.receivers[0].connected = true;
    snapshot.receivers[0].status = .edid_missing;
    try t.expect(hotplug.retrySnapshot(&snapshot));
    snapshot.receivers[0].status = .valid_edid;
    try t.expect(!hotplug.retrySnapshot(&snapshot));
    try checkReceiverReturn(&snapshot);
}

fn checkReceiverReturn(snapshot: *@import("gsp_outputs.zig").Snapshot) !void {
    const helpers = @import("gsp_display_commands_test.zig");
    const a = @import("r4os").abi;
    const boot = @import("gsp_boot_mode.zig");
    const reconnect = @import("gsp_reconnect.zig");
    helpers.outputFixture(snapshot, 7, 12);
    const initial = try hotplug.observe(snapshot, 4);
    try t.expect(initial.state == .unknown and initial.fingerprint == null);
    snapshot.receivers[0].connected = false;
    try t.expect((try hotplug.observe(snapshot, 4)).state == .disconnected);
    snapshot.receivers[0].connected = true;
    try t.expect((try hotplug.observe(snapshot, 4)).state == .edid_pending);
    try @import("gsp_receiver_mode_test.zig").install(&snapshot.receivers[0]);
    const valid = try hotplug.observe(snapshot, 4);
    try t.expect(valid.state == .connected and valid.fingerprint != null);
    snapshot.receivers[0].bytes[10] ^= 1;
    snapshot.receivers[0].bytes[127] -%= 1;
    try @import("gsp_receiver.zig").edid.parse(snapshot.receivers[0].bytes[0..snapshot.receivers[0].edid_bytes], &snapshot.receivers[0].report);
    const changed = try hotplug.observe(snapshot, 4);
    try t.expect(!std.meta.eql(valid.fingerprint, changed.fingerprint));
    var raw = helpers.bootFixture(65, 20);
    const firmware: a.GfxNativeBootInfo = .{ .generation = 3, .physical_address = 0xd0000000,
        .byte_length = 512 * 20, .pitch = 512, .width = 65, .height = 20, .format = a.gfx_buffer_format_xrgb8888 };
    const base = try boot.bind(try boot.capture(&raw, &firmware, 3), snapshot, 7, 4);
    const object: @import("gsp_display_rpc.zig").Object = .{ .epoch = 7, .client = 12, .display = 13 };
    var previous = (try reconnect.choose(base, snapshot, object, base)).plan;
    try t.expect(previous.width == 65 and previous.height == 20 and previous.receiver_mode_id == 1);
    previous.receiver_mode_id = 99; // Old local ID is not an admission source.
    snapshot.generation += 1; snapshot.final_receipt_serial += 1;
    const fresh = try boot.bind(base, snapshot, 7, 4);
    const chosen = try reconnect.choose(fresh, snapshot, object, previous);
    try t.expect(!chosen.resize and chosen.plan.receiver_mode_id == 1 and chosen.plan.output_generation == snapshot.generation);
    previous.width = 800; previous.height = 600;
    try t.expect((try reconnect.choose(fresh, snapshot, object, previous)).resize);
    snapshot.receivers[0].status = .edid_missing;
    try t.expectError(error.Unavailable, reconnect.choose(fresh, snapshot, object, previous));
    try t.expectError(error.Stale, reconnect.choose(base, snapshot, object, previous));
}
