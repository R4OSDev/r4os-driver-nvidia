const std = @import("std");
const t = std.testing;
const frl = @import("gsp_frl_link.zig");
const common = @import("gsp_display_link.zig");
const boot = @import("gsp_boot_mode.zig");
const display = @import("gsp_display_rpc.zig");
const outputs = @import("gsp_outputs.zig");
const vectors = @embedFile("fixtures/display-links-570.144.bin");
fn word(bytes: []const u8, at: usize) u32 { return std.mem.readInt(u32, bytes[at..][0..4], .little); }
fn put(bytes: []u8, at: usize, value: u32) void { std.mem.writeInt(u32, bytes[at..][0..4], value, .little); }
pub fn reference(tag: u32) []const u8 {
    var pos: usize = 0;
    while (pos < vectors.len) {
        const id = word(vectors, pos); const size = word(vectors, pos + 4); pos += 8;
        if (id == tag) return vectors[pos..][0..size];
        pos += size;
    }
    unreachable;
}
pub fn respond(work: *const frl.Work, bytes: []u8) void {
    switch (work.stage) {
        .source => @memcpy(bytes[24..32], reference(1)),
        .dsc => @import("gsp_dsc_test.zig").hdmiRespond(&work.dsc_work.?, bytes[24..]),
        .capacity, .recheck => {
            @memcpy(bytes[84..120], reference(3)[60..96]);
            put(bytes, 84, @intFromEnum(work.rate));
            put(bytes, 88, @as(u32, work.plan.mode.signal.bpc) * 48);
        },
        .train, .disable => {}, //Echo of the selected actual rate, no fake LT.
        else => unreachable,
    }
}
fn record(bytes: []const u8) @import("gsp_message.zig").Record {
    return .{ .shape = .{ .message_bytes = @intCast(bytes.len), .checksum_bytes = 0, .storage_bytes = @intCast(bytes.len), .elements = 1 },
        .queue_sequence = 0, .rpc = .{ .function = 76, .result = 0 }, .payload = bytes };
}
pub fn check(saved: boot.Plan, object: display.Object, original: *const outputs.Snapshot) !void {
    var stage: []const u8 = "receiver";
    errdefer std.debug.print("FRL check failed during {s}\n", .{stage});
    const snapshot = try t.allocator.create(outputs.Snapshot); defer t.allocator.destroy(snapshot);
    snapshot.* = original.*;
    const receiver = &snapshot.receivers[0];
    receiver.connected = true; receiver.status = .valid_edid;
    receiver.report = .{ .digital = true, .hdmi = true, .scdc = true, .max_tmds_hz = 600_000_000,
        .hdmi_deep_color = 1, .rgb_quantization_selectable = true,
        .hdmi_links = .{ .max_frl_raw = 6, .max_frl = .lanes4_12g } };
    var higher = saved;
    higher.receiver_mode_id = 1;
    higher.width = 3840; higher.height = 2160; higher.refresh_micro_hz = 120_000_000;
    higher.signal.clock = 1_188_000_000; higher.signal.bpc = 10;
    higher.signal.total = 4400 | (2250 << 16); higher.signal.viewport = 3840 | (2160 << 16);
    higher.signal.sync_end = 87 | (9 << 16); higher.signal.blank_end = 383 | (81 << 16);
    higher.signal.blank_start = 4223 | (2241 << 16); higher.signal.min_frame_idle = 82 | (8 << 16);
    higher.color = @import("gsp_color_signal.zig").sdr;
    higher.color.?.format = .xr30; higher.color.?.bpc = 10;
    higher.color_pipeline = .{ .linear_composition = true, .output_transform = true, .opaque_output = true };
    higher = try frl.select(higher, &receiver.report);
    try t.expect(higher.signal.hdmi_frl and higher.frl_max_rate == 6);
    const plan = try common.derive(higher, object, snapshot);
    try t.expect(plan.frl != null and plan.transport.hdmi.caps == 53 and plan.transport.hdmi.color.?.tmds_hz == 0);
    try compressedLink(higher, object, snapshot);

    //Independent original C ABI records, not output from another Zig encoder.
    stage = "original C wire";
    const dp_caps = try @import("gsp_link_caps.zig").DpSource.decode(reference(0));
    try t.expect(dp_caps.mst and dp_caps.fec and dp_caps.single_head_mst and dp_caps.dsc.usable);
    var native: frl.Work = .{ .plan = plan.frl.?, .stage = .capacity, .source_max = .lanes4_12g, .rate = .lanes4_12g };
    var encoded: [frl.max_bytes]u8 = undefined;
    const size = try native.encode(&encoded);
    try t.expectEqualSlices(u8, reference(2), encoded[24..size]);
    respond(&native, encoded[0..size]);
    try native.consume(record(encoded[0..size]), 1);
    try t.expect(native.stage == .admitted and native.result.?.training_receipt == 0);
    try native.startTraining();
    const training_size = try native.encode(&encoded);
    try t.expectEqualSlices(u8, reference(4), encoded[24..training_size]);

    var work = common.Work.init(plan);
    stage = "common before scanout";
    var serial: u64 = 0;
    while (work.phase == .before_scanout and serial < 20) {
        work.length = try work.encode(&work.request); work.pending = true;
        var reply = work.request;
        if (work.frl.?.active()) respond(&work.frl.?, reply[0..work.length]);
        serial += 1;
        try work.consume(record(reply[0..work.length]), serial, serial * std.time.ns_per_ms);
        if (work.frl.?.stage != .complete) try t.expect(!work.readyScanout());
    }
    try t.expect(serial < 20 and work.readyScanout());
    //RM may use horizontal blanking:4x10G admits this timing after the real
    //capacity reply, despite the nominal RGB10 rate exceeding its coding ceiling.
    try t.expect(work.frlResult().?.rate == .lanes4_10g and work.frlResult().?.training_receipt != 0);
    try work.scanoutComplete();
    stage = "common packets";
    while (work.phase == .after_scanout and serial < 30) {
        work.length = try work.encode(&work.request); work.pending = true; serial += 1;
        try work.consume(record(work.request[0..work.length]), serial, serial * std.time.ns_per_ms);
    }
    try t.expect(work.phase == .complete and work.acknowledged == 7);

    stage = "FRL and HDMI VRR admission";
    receiver.report.refresh.hdmi = .{ .refresh = .{ .min_millihz = 60_000, .max_millihz = 144_000 } };
    const vrr = @import("gsp_vrr_control.zig");
    var proven: @import("gsp_runtime.zig").DisplayLink = .{ .plan = plan,
        .acknowledged = work.acknowledged, .receipt = work.last_receipt, .frl = work.frlResult() };
    const variable = try vrr.derive(higher, object, snapshot, proven, 0xc67d);
    try t.expect(variable.refresh.max_vtotal == 4500 and variable.refresh.timeout_us == 16666 and !variable.refresh.lfc);
    proven.frl.?.training_receipt = 0;
    try t.expectError(error.Unsupported, vrr.derive(higher, object, snapshot, proven, 0xc67d));

    const commands = @import("gsp_display_commands.zig");
    stage = "C67D protocol";
    const program = try commands.core(.{ .notifier = 77, .windows = @as(u32, 1) << @as(u5, @intCast(higher.window)),
        .initialize = false, .route = .{ .head = higher.head, .window = higher.window }, .signal = higher.signal });
    var pos: usize = 0; var sor_seen = false;
    while (pos < program.count) {
        const header = program.words[pos]; const count = (header >> 18) & 1023;
        if (header & 0x3fff == 0x300 + higher.signal.sor * 0x20) {
            try t.expect(count == 1 and program.words[pos + 1] == word(reference(5), 0)); sor_seen = true;
        }
        pos += count + 1;
    }
    try t.expect(sor_seen);

    const training = native;
    stage = "training rejection and disable";
    for (0..5) |failure| {
        native = training;
        const count = try native.encode(&encoded);
        switch (failure) {
            0 => put(&encoded, 32, 0), //NV_OK + NONE is a failed link.
            1 => put(&encoded, 32, 4), //Negotiated rate cannot carry the mode.
            2 => encoded[36] = 1, //Fake LT must never be accepted.
            3 => put(&encoded, 12, 0x57), //RM rejects the operation.
            4 => encoded[37] = 1, //Skipped LT is retained as such, followed by recheck.
            else => unreachable,
        }
        if (failure == 4) {
            try native.consume(record(encoded[0..count]), 3);
            try t.expect(native.stage == .recheck and native.training_skipped);
            const recheck_size = try native.encode(&encoded); respond(&native, encoded[0..recheck_size]);
            encoded[96] = 0; //No video transport despite the earlier training reply.
            try t.expectError(error.Bandwidth, native.consume(record(encoded[0..recheck_size]), 4));
        } else {
            const expected: anyerror = switch (failure) { 0 => error.LinkTraining, 1 => error.Bandwidth, 2 => error.Unexpected, else => error.RmRejected };
            try t.expectError(expected, native.consume(record(encoded[0..count]), 3));
        }
        native.startDisable();
        const disabled_size = try native.encode(&encoded);
        try t.expect(word(&encoded, 8) == 0x73029a and word(&encoded, 32) == 0 and encoded[36] == 0);
        try native.consume(record(encoded[0..disabled_size]), 5);
        try t.expect(native.stage == .disabled and native.result == null);
    }
    const ordinary = try frl.select(saved, &receiver.report);
    stage = "TMDS restoration";
    try t.expect(!ordinary.signal.hdmi_frl and ordinary.frl_max_rate == 0);
    receiver.report.hdmi_links = null;
    const unadmitted = try frl.select(higher, &receiver.report);
    try t.expect(!unadmitted.signal.hdmi_frl);
    try t.expectError(error.Bandwidth, common.derive(unadmitted, object, snapshot));
    const tmds = try common.derive(ordinary, object, snapshot);
    var restored = common.Work.init(tmds);
    try restored.clearPreviousFrl(plan);
    restored.length = try restored.encode(&restored.request); restored.pending = true;
    try t.expect(word(&restored.request, 8) == 0x73029a and word(&restored.request, 32) == 0);
    var bad_restore = restored;
    var bad_reply = restored.request; bad_reply[28] ^= 8;
    try t.expectError(error.Unexpected, bad_restore.consume(record(bad_reply[0..restored.length]), 1, 0));
    try t.expect(!bad_restore.readyScanout() and bad_restore.clear_receipt == 0);
    try restored.consume(record(restored.request[0..restored.length]), 1, 0);
    try t.expect(restored.clear_receipt == 1 and restored.clear_frl.?.stage == .disabled);
    restored.length = try restored.encode(&restored.request);
    try t.expect(word(&restored.request, 8) == 0x730293); //Only after FRL-off ACK: ordinary HDMI caps.
}
fn compressedLink(saved: boot.Plan, object: display.Object, original: *const outputs.Snapshot) !void {
    const snapshot = try t.allocator.create(outputs.Snapshot); defer t.allocator.destroy(snapshot);
    snapshot.* = original.*;
    const receiver = &snapshot.receivers[0].report;
    receiver.hdmi_links = .{ .max_frl_raw = 2, .max_frl = .lanes3_6g,
        .dsc = .{ .advertised = true, .supported_fields = true, .bpc_mask = 3, .max_frl = .lanes3_6g,
            .max_slices = 8, .max_slice_clock_mhz = 400, .max_chunk_bytes = 8192 } };
    const intent = try frl.select(saved, receiver);
    const pending = try common.derive(intent, object, snapshot);
    try t.expect(pending.transport.hdmi.deferred_dsc and intent.signal.hdmi_dsc == null);
    var query: frl.Work = .{ .plan = pending.frl.? };
    var serial: u64 = 0;
    while (query.stage != .admitted and serial < 40) {
        var bytes: [frl.max_bytes]u8 = undefined;
        const count = try query.encode(&bytes); respond(&query, bytes[0..count]); serial += 1;
        try query.consume(record(bytes[0..count]), serial);
    }
    const admitted = try query.admittedMode();
    try @import("gsp_dsc_test.zig").hdmiCore(admitted);
    try t.expect(admitted.signal.hdmi_dsc != null and admitted.sameIntent(intent) and !std.meta.eql(admitted, intent) and
        query.result.?.training_receipt == 0 and query.result.?.capacity_receipt != 0);
    const selected = try common.derive(admitted, object, snapshot);
    try t.expect(!selected.transport.hdmi.deferred_dsc);
    var sink_bytes: [@import("gsp_hdmi_link.zig").max_bytes]u8 = undefined;
    const sink_count = try @import("gsp_hdmi_link.zig").encode(selected.transport.hdmi, .caps, &sink_bytes);
    try t.expectEqualSlices(u8, @embedFile("fixtures/hdmi-dsc-wire-570.144.bin")[572..584], sink_bytes[24..sink_count]);
    var work = common.Work.init(selected);
    while (work.phase == .before_scanout and serial < 80) {
        work.length = try work.encode(&work.request); work.pending = true;
        var bytes = work.request;
        if (work.frl.?.active()) respond(&work.frl.?, bytes[0..work.length]);
        serial += 1; try work.consume(record(bytes[0..work.length]), serial, serial * std.time.ns_per_ms);
    }
    try t.expect(work.readyScanout() and serial < 80);
    const proof = work.frlResult().?;
    try t.expectEqualDeep(admitted.signal.hdmi_dsc.?, proof.compressed.?);
    try t.expect(proof.capacity_receipt > proof.training_receipt and proof.training_receipt > query.result.?.capacity_receipt);
    try work.scanoutComplete();
    while (work.phase == .after_scanout and serial < 90) {
        work.length = try work.encode(&work.request); work.pending = true;
        serial += 1; try work.consume(record(work.request[0..work.length]), serial, serial * std.time.ns_per_ms);
    }
    const active: @import("gsp_runtime.zig").DisplayLink = .{ .plan = selected, .acknowledged = work.acknowledged,
        .receipt = work.last_receipt, .frl = work.frlResult() };
    try t.expect(active.complete() and work.phase == .complete);
    var stale = active; stale.plan.mode.signal.hdmi_dsc = null; try t.expect(!stale.complete());
    var state: @import("r4os").abi.GfxOutputColorState = .{ .depths = 3 };
    try @import("gsp_output_color.zig").linkFacts(&state, active);
    try t.expect(state.link_kind == 2 and state.link_flags == 3 and state.compressed_bpp_x16 == 192 and state.dsc_depths == 3);
}
