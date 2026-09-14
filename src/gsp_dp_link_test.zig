//! DP checks extend the existing display-command and native Device groups.
const std = @import("std");
const t = std.testing;
const dp = @import("gsp_dp_link.zig");
const link = @import("gsp_display_link.zig");
const boot = @import("gsp_boot_mode.zig");
const helpers = @import("gsp_display_commands_test.zig");
const a = @import("r4os").abi;
const vectors = @embedFile("fixtures/display-dp-570.144.bin");
fn put(bytes: []u8, offset: usize, value: u32) void { std.mem.writeInt(u32, bytes[offset..][0..4], value, .little); }
pub fn reference(wanted: u32) []const u8 {
    var offset: usize = 0;
    while (offset < vectors.len) {
        const id = std.mem.readInt(u32, vectors[offset..][0..4], .little);
        const len = std.mem.readInt(u32, vectors[offset+4..][0..4], .little);
        offset += 8;
        if (id == wanted) return vectors[offset..][0..len];
        offset += len;
    }
    unreachable;
}
pub fn receiver(snapshot: *@import("gsp_outputs.zig").Snapshot) void {
    snapshot.topology.routes[0].resource.?.protocol = 8;
    snapshot.topology.routes[0].connectors.?.data[0].kind = 0x46;
    snapshot.receivers[0].connected = true; snapshot.receivers[0].status = .valid_edid;
    snapshot.receivers[0].report.digital = true; snapshot.receivers[0].report.hdmi = false;
    snapshot.receivers[0].report.bits_per_color = 8;
}
pub fn scanout(raw: *@import("boot_scanout.zig").Raw) void { raw.sors[3] = 0x802; raw.heads[1].hdmi = 0; }
/// The model supplies physical responses to actual encoded requests; it
/// never advances Work or fabricates its final proof/ACK receipt.
pub fn respond(work: *const dp.Work, bytes: []u8, bad_training: bool) void {
    const data = bytes[24..];
    switch (work.stage) {
        .source => { put(data, 8, 4); put(data, 12, 3); data[26] = 1; data[30] = 1; },
        .caps, .extended_caps => {
            put(data, 36, 16);
            @memset(data[20..36], 0);
            data[20] = 0x14; data[21] = 30; data[22] = 0x84; data[23] = 0x80; data[26] = 1;
            if (work.stage == .caps) data[34] = 0x80;
        },
        .repeaters => { put(data, 36, 8); @memset(data[20..28], 0); },
        .color_caps => { put(data, 36, 1); data[20] = 8; },
        .power => { put(data, 36, 1); data[20] = 2; },
        .power_on => put(data, 36, 1),
        .train => if (bad_training) { put(data, 16, 0x80000000); },
        .link_config => {
            put(data, 36, 2); data[20] = work.candidates[work.index].rate;
            data[21] = work.candidates[work.index].lanes | 0x80;
        },
        .link_status => { put(data, 36, 8); @memcpy(data[20..28], &[_]u8{1,0,0x77,0x77,1,0,0,0}); },
        .stream, .mute, .vsc, .hdr => {},
        .complete, .post_complete => unreachable,
    }
}
fn record(bytes: []const u8) @import("gsp_message.zig").Record {
    return .{ .shape = .{ .message_bytes = @intCast(bytes.len), .checksum_bytes = 0, .storage_bytes = @intCast(bytes.len), .elements = 1 },
        .queue_sequence = 0, .rpc = .{ .function = 76, .result = 0 }, .payload = bytes };
}
fn tag(stage: dp.Stage) u32 { return switch (stage) {
    .source => 0, .caps => 1, .extended_caps => 2, .repeaters => 3, .power => 4, .power_on => 5,
    .link_config => 6, .link_status => 7, .train => 8, .stream => 9, .mute => 10, else => unreachable,
}; }
pub fn check() !void {
    const snapshot = try t.allocator.create(@import("gsp_outputs.zig").Snapshot); defer t.allocator.destroy(snapshot);
    helpers.outputFixture(snapshot, 11, 12); receiver(snapshot);
    var raw = helpers.bootFixture(1920, 1080); scanout(&raw);
    const info: a.GfxNativeBootInfo = .{ .generation = 3, .physical_address = 0xd0000000,
        .byte_length = 8192 * 1080, .pitch = 8192, .width = 1920, .height = 1080, .format = a.gfx_buffer_format_xrgb8888 };
    const saved = try boot.bind(try boot.capture(&raw, &info, 3), snapshot, 11, 4);
    const object: @import("gsp_display_rpc.zig").Object = .{ .epoch = 11, .client = 12, .display = 13 };
    const plan = try link.derive(saved, object, snapshot);
    try t.expect(plan.transport == .dp and !plan.mode.transport_hdmi);
    try t.expectError(error.Unsupported, @import("gsp_hdmi_link.zig").derive(saved, object, snapshot));
    var work = link.Work.init(plan);
    var serial: u64 = 0;
    while (work.phase == .before_scanout and serial < 20) {
        const stage = work.dp.?.stage;
        work.length = try work.encode(&work.request);
        // Layout and SST watermarks come from the pinned C headers and the
        // unmodified original isModePossibleSST body, not a second Zig model.
        try t.expectEqualSlices(u8, reference(tag(stage)), work.request[0..work.length]);
        work.pending = true;
        var reply = work.request;
        respond(&work.dp.?, reply[0..work.length], false);
        serial += 1;
        try work.consume(record(reply[0..work.length]), serial, serial * std.time.ns_per_ms);
    }
    try t.expect(serial < 20 and work.readyScanout() and work.dpResult().?.stream.audio_48k);
    try work.scanoutComplete(); try t.expect(work.phase == .after_scanout);
    for (0..2) |index| {
        work.length = try work.encode(&work.request);
        if (index == 0) {
            try t.expectEqual(@as(usize, 40), work.length);
            try t.expectEqual(@as(u32, 0x730289), std.mem.readInt(u32, work.request[8..12], .little));
            try t.expectEqualSlices(u8, &.{7,0,0,0,0,0,0,0}, work.request[32..40]);
        } else {
            try t.expectEqual(@as(usize, 84), work.length);
            try t.expectEqual(@as(u32, 0x105), std.mem.readInt(u32, work.request[32..36], .little));
            try t.expectEqualSlices(u8, &.{0,0x87,29,0x4c,1,26,0,0}, work.request[45..53]);
        }
        work.pending = true; serial += 1;
        try work.consume(record(work.request[0..work.length]), serial, serial * std.time.ns_per_ms);
    }
    try t.expect(work.phase == .complete);
    const completed = work.dpResult().?;
    try t.expect(completed.config.rate == 30 and completed.config.lanes == 4 and completed.attempts == 1);
    // Actual extended DPCD read, 30-bpp training admission and both DP
    // packets. The common transaction must wait for their acknowledgements.
    var hdr = saved;
    hdr.signal.bpc = 10; hdr.signal.dp_vsc = true;
    hdr.color = .{ .format = .xr30, .bpc = 10, .transfer = .pq, .primaries = .bt2020,
        .range = .limited, .reference_white = 2_030_000, .peak = 10_000_000,
        .metadata = .{ .max_mastering = 1000, .max_cll = 1000, .max_fall = 400 } };
    const monitor = &snapshot.receivers[0].report;
    monitor.bits_per_color = 10; monitor.colorimetry = 0x80;
    monitor.hdr_present = true; monitor.hdr_eotf = 12; monitor.hdr_static = 1;
    try t.expectError(error.Incomplete, link.derive(hdr, object, snapshot));
    hdr.color_pipeline = .{ .linear_composition = true, .output_transform = true, .opaque_output = true };
    const hdr_plan = try link.derive(hdr, object, snapshot);
    var colored = link.Work.init(hdr_plan);
    var color_steps: u64 = 0;
    var witnessed_vsc = false;
    while (colored.phase != .complete and color_steps < 24) {
        if (colored.phase == .scanout) { try colored.scanoutComplete(); continue; }
        const stage = colored.dp.?.stage;
        colored.length = try colored.encode(&colored.request);
        if (stage == .color_caps) try t.expectEqual(@as(u32, 0x2210), std.mem.readInt(u32, colored.request[40..44], .little));
        if (stage == .vsc) {
            try t.expect(colored.phase == .after_scanout and colored.dp.?.color.?.bpp == 30);
            try t.expectEqualSlices(u8, &.{0,7,5,19}, colored.request[45..49]);
            try t.expectEqualSlices(u8, &.{6,0x82,1}, colored.request[65..68]);
            witnessed_vsc = true;
        }
        if (stage == .hdr) {
            try t.expect(witnessed_vsc and colored.phase == .after_scanout);
            try t.expectEqual(@as(u32, 0x101), std.mem.readInt(u32, colored.request[32..36], .little));
            try t.expectEqualSlices(u8, &.{0,0x87,29,0x4c,1,26,2,0}, colored.request[45..53]);
            var rejected = colored.dp.?;
            var failure = colored.request;
            put(&failure, 12, 0x57);
            try t.expectError(error.RmRejected, rejected.consume(record(failure[0..colored.length]), 0));
            try t.expect(rejected.stage == .hdr);
        }
        colored.pending = true;
        var reply = colored.request;
        respond(&colored.dp.?, reply[0..colored.length], false);
        color_steps += 1;
        try colored.consume(record(reply[0..colored.length]), color_steps, color_steps * std.time.ns_per_ms);
    }
    try t.expect(witnessed_vsc and color_steps < 24 and colored.phase == .complete);
    var missing_caps = colored.dp.?; missing_caps.stage = .color_caps;
    var missing: [dp.max_bytes]u8 = undefined;
    const missing_length = try missing_caps.encode(&missing);
    respond(&missing_caps, missing[0..missing_length], false); missing[44] = 0;
    try t.expectError(error.Unsupported, missing_caps.consume(record(missing[0..missing_length]), 0));
    var bandwidth = hdr;
    bandwidth.signal.clock = 180_000_000;
    try t.expectError(error.Bandwidth, dp.stream(bandwidth, completed.source, completed.sink, .{ .rate = 6, .lanes = 4 }));
    bandwidth.signal.bpc = 8;
    _ = try dp.stream(bandwidth, completed.source, completed.sink, .{ .rate = 6, .lanes = 4 });
    // Source support is independent of receiver HDR/VSC declarations.
    missing_caps = colored.dp.?; missing_caps.stage = .source;
    const source_length = try missing_caps.encode(&missing);
    respond(&missing_caps, missing[0..source_length], false); put(&missing, 36, 1);
    try t.expectError(error.Unsupported, missing_caps.consume(record(missing[0..source_length]), 0));
    monitor.bits_per_color = 8;
    try t.expectError(error.Unsupported, link.derive(hdr, object, snapshot));
    var status = completed.lane_status;
    status[2] &= ~@as(u8, 1); try t.expect(!dp.trained(status, 4)); // Clock recovery missing.
    status = completed.lane_status; status[3] &= ~@as(u8, 0x20); try t.expect(!dp.trained(status, 4)); // EQ missing.
    status = completed.lane_status; status[4] = 0; try t.expect(!dp.trained(status, 4)); // Alignment missing.
    var bad = saved; bad.signal.clock = 2_000_000_000;
    try t.expectError(error.Bandwidth, dp.stream(bad, completed.source, completed.sink, completed.config));
    // Retry a politely delayed RM training operation, preserving all config
    // inputs. A third deferral fails; there is no busy-loop or new mode.
    var train = work.dp.?; train.stage = .train; train.result = null; train.attempts = 0;
    var bytes: [dp.max_bytes]u8 = undefined;
    var n = try train.encode(&bytes); put(&bytes, 12, 3); put(&bytes, 44, 5);
    try train.consume(record(bytes[0..n]), 0);
    try t.expect(!train.ready(4 * std.time.ns_per_ms) and train.ready(5 * std.time.ns_per_ms));
    try train.consume(record(bytes[0..n]), 5 * std.time.ns_per_ms);
    try t.expectError(error.RetryExhausted, train.consume(record(bytes[0..n]), 10 * std.time.ns_per_ms));
    // Every fallback is still a valid RGB8 stream. Exhaustion cannot select
    // an insufficient rate or authorize Core/Window admission.
    train = work.dp.?; train.stage = .train; train.result = null; train.attempts = 0;
    var tries: u8 = 0;
    while (true) {
        n = try train.encode(&bytes); put(&bytes, 40, 0x80000000);
        tries += 1;
        train.consume(record(bytes[0..n]), 0) catch |err| { try t.expect(err == error.LinkTraining); break; };
        _ = try dp.stream(saved, train.source.?, train.sink.?, train.candidates[train.index]);
    }
    try t.expect(tries == train.count and tries <= 12 and train.result == null);
    // One failed readback also falls back instead of treating RM success as
    // proof that all sink lanes completed clock recovery/equalization.
    train = work.dp.?; train.stage = .link_status; train.result = null;
    n = try train.encode(&bytes); respond(&train, bytes[0..n], false); bytes[46] = 0;
    try train.consume(record(bytes[0..n]), 0);
    try t.expect(train.stage == .train and train.index == 1 and train.result == null);
    @import("gsp_display_audio_test.zig").install(&snapshot.receivers[0].report);
    const audio = @import("gsp_display_audio.zig");
    const audio_plan = try audio.derive(saved, object, snapshot);
    try t.expect(audio_plan.data.?.bytes[5] & 15 == 4 and audio_plan.data.?.stereo_48k_s16);
    for ([_]audio.Operation{ .mute, .unmute, .disable, .enable }, [_]u32{ 10, 11, 12, 13 }) |op, id| {
        var encoded: [audio.max_bytes]u8 = undefined;
        const length = try audio.encode(audio_plan, op, &encoded);
        try t.expectEqualSlices(u8, reference(id), encoded[0..length]);
    }
    snapshot.topology.routes[0].connectors.?.data[0].kind = 0x47;
    try t.expectError(error.Unsupported, boot.bind(saved, snapshot, 11, 4)); // AUX does not grant eDP/backlight/USB-C.
    // A passive DP++ path is TMDS. Physical DVI remains DVI in the common
    // catalog and never gains audio just by having a digital EDID.
    raw.sors[3] = 0x102;
    snapshot.topology.routes[0].resource.?.protocol = 1;
    snapshot.topology.routes[0].connectors.?.data[0].kind = 0x31;
    const dvi = try boot.bind(try boot.capture(&raw, &info, 3), snapshot, 11, 4);
    try t.expect(!dvi.hasAudio() and (try link.derive(dvi, object, snapshot)).transport == .hdmi);
    var published: a.GfxReceiverInfo = .{};
    try @import("gsp_catalog.zig").encode(&published, &snapshot.topology.routes[0], &snapshot.receivers[0]);
    try t.expect(published.connector_kind == a.gfx_output_kind_dvi);
    snapshot.topology.routes[0].connectors.?.data[0].kind = 0x46;
    _ = try boot.bind(dvi, snapshot, 11, 4);
    try t.expectError(error.Unsupported, audio.derive(dvi, object, snapshot));
}
