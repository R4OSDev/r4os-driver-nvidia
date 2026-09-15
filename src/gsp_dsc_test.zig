const std = @import("std");
const t = std.testing;
const dsc = @import("gsp_dsc.zig");
const caps = @import("gsp_link_caps.zig");
pub fn request() !dsc.Request {
    return .{ .clock = .{ .numerator = 1_188_000_000 }, .width = 3840, .height = 2160, .bpc = 10, .hblank = 560, .source = .{ .advertised = true, .usable = true, .formats = 1, .line_buffer_pixels = 65536, .rate_buffer_bytes = 8192, .bpp_increment_x16 = 1, .max_slices = 8, .line_buffer_bits = 12 }, .sink = caps.DscSink.decode(.{ 1, 0x21, 0, 7, 0x2b, 1, 1, 0, 0, 1, 6, 2, 8, 1, 0, 0 }), .payload_bps = try dsc.fecPayload(30, 4), .rate = 30, .lanes = 4 };
}
pub fn check() !void {
    try hdmiPps();
    try hdmiCapacity();
    try watermark();
    try selectedMode();
    const input = try request();
    const plan = try dsc.generate(input);
    try t.expectEqualSlices(u8, @embedFile("fixtures/dsc-pps-570.144.bin"), &plan.bytes());
    try t.expect(plan.bpp_x16 == 256 and plan.slices == 4 and plan.slice_width == 960 and plan.chunk_bytes == 1920 and
        plan.rc_buffer_bytes == 1024 and plan.flatnessThreshold() == 8);
    try t.expectEqual(@as(u64, 25_297_920_000), try dsc.fecPayload(30, 4));
    var invalid = input;
    invalid.source.usable = false;
    try t.expectError(error.Unsupported, dsc.generate(invalid));
    invalid = input;
    invalid.sink.bpc_mask = 1;
    try t.expectError(error.Unsupported, dsc.generate(invalid));
    invalid = input;
    invalid.payload_bps = 9_504_000_000;
    try t.expectError(error.Bandwidth, dsc.generate(invalid));
    invalid = input;
    invalid.source.rate_buffer_bytes = 512;
    try t.expectError(error.Pps, dsc.generate(invalid));
    invalid = input;
    invalid.sink.rc_buffer_bytes = 512;
    try t.expectError(error.Pps, dsc.generate(invalid));
    invalid = input;
    invalid.source.line_buffer_pixels = 65537;
    try t.expectError(error.Parameter, dsc.generate(invalid));
    invalid = input;
    invalid.clock.denominator = 0;
    try t.expectError(error.Parameter, dsc.generate(invalid));
    invalid = input;
    invalid.sink.slice_clock_mhz = 100;
    try t.expectError(error.Unsupported, dsc.generate(invalid));
    invalid = input;
    invalid.source.bpp_increment_x16 = 3;
    try t.expectError(error.Parameter, dsc.generate(invalid));
    invalid = input;
    invalid.clock = .{ .numerator = 1_188_000_000_000, .denominator = 1001 };
    const fractional = try dsc.generate(invalid);
    try t.expect(fractional.bpp_x16 == 256 and fractional.slices == 4);
}
fn hdmiPps() !void {
    const hdmi = @import("gsp_hdmi_dsc.zig");
    const source = (try request()).source;
    const input: hdmi.Request = .{ .clock = .{ .numerator = 1_188_000_000 }, .width = 3840, .height = 2160,
        .hblank = 560, .bpc = 10, .source = source,
        .receiver = .{ .advertised = true, .supported_fields = true, .bpc_mask = 3, .max_frl = .lanes4_12g,
            .max_slices = 8, .max_slice_clock_mhz = 400, .max_chunk_bytes = 8192 },
        .rate = .lanes4_12g, .bpp_x16 = 192, .slice_width = 960, .slices = 4 };
    const plan = try hdmi.pps(input);
    try t.expectEqualSlices(u8, @embedFile("fixtures/hdmi-pps-570.144.bin"), &plan.bytes());
    try t.expect(plan.bpp_x16 == 192 and plan.slices == 4 and plan.chunk_bytes == 1440);
    var invalid = input;
    invalid.bpp_x16 = 193;
    try t.expectError(error.Parameter, hdmi.pps(invalid));
    invalid = input;
    invalid.receiver.bpc_mask = 1;
    try t.expectError(error.Unsupported, hdmi.pps(invalid));
    invalid = input;
    invalid.receiver.max_chunk_bytes = 4096;
    try t.expectError(error.Bandwidth, hdmi.pps(invalid));
    invalid = input;
    invalid.slices = 8;
    try t.expectError(error.Parameter, hdmi.pps(invalid));
    invalid = input;
    invalid.source.usable = false;
    try t.expectError(error.Unsupported, hdmi.pps(invalid));
}
pub fn hdmiRespond(work: *const @import("gsp_hdmi_dsc.zig").Work, data: []u8) void {
    switch (work.stage) {
        .source => @memcpy(data[36..64], @import("gsp_frl_link_test.zig").reference(0)[36..64]),
        .layout => {
            const slices: u32 = if (work.input.width <= 960) 1 else if (work.input.width <= 1920) 2 else 4;
            put(data, 48, slices); put(data, 52, (work.input.width + slices - 1) / slices); data[128] = 1;
        },
        .precalc => {}, //No precomputed VIC in this synthetic capacity model.
        .preconfig => { put(data, 108, 2); put(data, 112, 192); },
        .capacity => {
            put(data, 60, @intFromEnum(work.rate)); put(data, 64, work.bpp);
            data[68] = 1;
            const limit: u16 = if (work.input.receiver.all_bpp) 201 else 192;
            const fits = @intFromEnum(work.rate) >= 2 and work.bpp <= limit;
            @memset(data[69..73], @intFromBool(fits));
            put(data, 80, 5760); put(data, 84, 1920); put(data, 88, 240); put(data, 92, 125);
        },
        .complete => unreachable,
    }
}
fn hdmiCapacity() !void {
    const hdmi = @import("gsp_hdmi_dsc.zig");
    const wire = @embedFile("fixtures/hdmi-dsc-wire-570.144.bin");
    const input: hdmi.Input = .{ .clock = .{ .numerator = 1_188_000_000 }, .width = 3840, .height = 2160,
        .total = 4400, .bpc = 10, .vic = 118, .maximum = .lanes4_12g,
        .receiver = .{ .advertised = true, .supported_fields = true, .bpc_mask = 3, .max_frl = .lanes4_12g,
            .max_slices = 8, .max_slice_clock_mhz = 400, .max_chunk_bytes = 8192 } };
    var original: ?hdmi.Plan = null;
    for (0..5) |scenario| {
        var work: hdmi.Work = .{ .input = input };
        if (scenario == 1) work.input.receiver.all_bpp = true;
        if (scenario >= 3) work.input.fixed = original.?;
        var serial: u64 = 0;
        while (work.stage != .complete and serial < 64) {
            var data: [132]u8 = undefined;
            const length = try work.encode(&data);
            const stage = work.stage;
            if (scenario == 0 and stage == .layout) try t.expectEqualSlices(u8, wire[0..132], data[0..length]);
            if (scenario == 0 and stage == .capacity and work.bpp == 192 and work.rate == .lanes3_6g)
                try t.expectEqualSlices(u8, wire[264..396], data[0..length]);
            hdmiRespond(&work, data[0..length]);
            if (scenario == 0 and stage == .layout) try t.expectEqualSlices(u8, wire[132..264], data[0..length]);
            if (scenario == 0 and stage == .capacity and work.bpp == 192 and work.rate == .lanes3_6g)
                try t.expectEqualSlices(u8, wire[396..528], data[0..length]);
            if (scenario == 2 and stage == .precalc) data[116] = 1;
            if (scenario == 4 and stage == .capacity) {
                put(&data, 88, 241); //A changed HC raster cannot reuse the old IMP/PPS plan.
                try t.expectError(error.Stale, work.consume(data[0..length], serial + 1));
                try t.expect(work.result == null); break;
            }
            serial += 1;
            try work.consume(data[0..length], serial);
        }
        try t.expect(serial < 64);
        if (scenario == 4) continue;
        const plan = work.result.?;
        try t.expect(work.stage == .complete and work.receipt != 0 and plan.rate == .lanes3_6g and
            plan.params.bpp_x16 == @as(u16, if (scenario == 1) 201 else 192));
        if (scenario == 0) {
            original = plan;
            try t.expectEqualSlices(u8, @embedFile("fixtures/hdmi-pps-570.144.bin"), &plan.params.bytes());
        }
        if (scenario == 3) try t.expectEqualDeep(original.?, plan);
    }
    var work: hdmi.Work = .{ .input = input };
    var data: [132]u8 = undefined;
    _ = try work.encode(&data); hdmiRespond(&work, data[0..64]);
    try work.consume(data[0..64], 1);
    _ = try work.encode(&data); hdmiRespond(&work, &data); put(&data, 52, 959);
    try t.expectError(error.Payload, work.consume(&data, 2));
    try t.expect(work.stage == .layout and work.result == null);
}
fn selectedMode() !void {
    const helper = @import("gsp_display_commands_test.zig");
    const boot = @import("gsp_boot_mode.zig");
    const output = @import("gsp_outputs.zig");
    const snapshot = try t.allocator.create(output.Snapshot);
    defer t.allocator.destroy(snapshot);
    helper.outputFixture(snapshot, 11, 12);
    @import("gsp_dp_link_test.zig").receiver(snapshot);
    var raw = helper.bootFixture(3840, 2160);
    @import("gsp_dp_link_test.zig").scanout(&raw);
    const abi = @import("r4os").abi;
    var mode = try boot.bind(try boot.capture(&raw, &abi.GfxNativeBootInfo{ .generation = 3, .physical_address = 0xd0000000, .byte_length = 15360 * 2160, .pitch = 15360, .width = 3840, .height = 2160, .format = abi.gfx_buffer_format_xrgb8888 }, 3), snapshot, 11, 4);
    const input = try request();
    const capture = &snapshot.receivers[0];
    capture.dp = .{ .source_state = .complete, .source = .{ .rate = 30, .increased_watermark = true, .dp14 = true, .fec = true, .dsc = input.source }, .dpcd_state = .complete, .dpcd = .{ 0x14, 30, 0x84, 0x80, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .receiver = .{ .dsc_state = .complete, .dsc = input.sink, .fec_state = .complete, .fec = true }, .repeaters_state = .complete, .receipt_serial = 12 };
    mode.signal.clock = 1_188_000_000;
    mode.signal.bpc = 10;
    mode.color = @import("gsp_color_signal.zig").sdr;
    mode.color.?.format = .xr30;
    mode.color.?.bpc = 10;
    mode.color_pipeline = .{ .linear_composition = true, .output_transform = true, .opaque_output = true };
    capture.report.bits_per_color = 10;
    const selected = try @import("gsp_dp_mode.zig").select(mode, capture);
    try t.expect(selected.signal.dp_dsc != null and selected.signal.dp_dsc.?.rate == 30 and
        selected.signal.dp_dsc.?.params.bpp_x16 == 256);
    try boot.validate(selected.signal, selected.head);
    try linkTransaction(selected, snapshot);
    try coreAndImp(selected);
    capture.report.bits_per_color = 8;
    const compressed_depth = try @import("gsp_dp_mode.zig").select(mode, capture);
    try t.expectEqualDeep(selected, compressed_depth);
    // The independent decoder depth, not an inflated EDID depth, authorizes
    // RGB10 through this admitted PPS and the normal color/link transaction.
    _ = try @import("gsp_display_link.zig").derive(compressed_depth, .{ .epoch = 11, .client = 12, .display = 13 }, snapshot);
    capture.report.bits_per_color = 10;
    capture.dp.receiver.fec = false;
    try t.expectError(error.Bandwidth, @import("gsp_dp_mode.zig").select(mode, capture));
    mode.signal.clock = 148_500_000;
    try t.expect((try @import("gsp_dp_mode.zig").select(mode, capture)).signal.dp_dsc == null);
}
fn put(data: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, data[at..][0..4], value, .little);
}
fn record(bytes: []const u8) @import("gsp_message.zig").Record {
    return .{ .shape = .{ .message_bytes = @intCast(bytes.len), .checksum_bytes = 0, .storage_bytes = @intCast(bytes.len), .elements = 1 }, .queue_sequence = 0, .rpc = .{ .function = 76, .result = 0 }, .payload = bytes };
}
fn linkTransaction(selected: @import("gsp_boot_mode.zig").Plan, snapshot: *const @import("gsp_outputs.zig").Snapshot) !void {
    const link = @import("gsp_display_link.zig");
    const plan = try link.derive(selected, .{ .epoch = 11, .client = 12, .display = 13 }, snapshot);
    try stopTransactions(plan);
    for (0..5) |scenario| {
        var work = link.Work.init(plan);
        var serial: u64 = 0;
        var fec_steps: u8 = 0;
        var failed = false;
        while (work.phase != .complete and serial < 40) {
            if (work.phase == .scanout) {
                try t.expect(work.readyScanout() and fec_steps == 5);
                const actual = work.dpResult().?;
                try t.expect(actual.complete(selected) and actual.fec_receipt != 0 and actual.decoder_receipt > actual.fec_receipt);
                try work.scanoutComplete();
                continue;
            }
            const stage = work.dp.?.stage;
            work.length = try work.encode(&work.request);
            work.pending = true;
            var reply = work.request;
            @import("gsp_dp_link_test.zig").respond(&work.dp.?, reply[0..work.length], false);
            if (stage == .source) {
                const data = reply[24..];
                data[29] = 1;
                data[36] = 1;
                put(data, 40, 1);
                put(data, 44, 64);
                put(data, 48, 8);
                put(data, 52, 1);
                put(data, 56, 8);
                put(data, 60, 12);
                if (scenario == 1) data[29] = 0;
            }
            if (stage == .train) {
                try t.expect(std.mem.readInt(u32, work.request[32..36], .little) & (1 << 15) != 0);
                try t.expect(work.dp.?.count == 1);
            }
            if (stage == .fec_clear) {
                fec_steps += 1;
                try t.expect(work.request[44] == 3);
            }
            if (stage == .fec_enable) {
                fec_steps += 1;
                try t.expect(work.length == 36 and std.mem.readInt(u32, work.request[8..12], .little) == 0x73137a and work.request[32] == 1);
                if (scenario == 2) put(&reply, 12, 0x55);
            }
            if (stage == .fec_status) {
                fec_steps += 1;
                if (scenario == 3) reply[44] = 0;
            }
            if (stage == .dsc_enable) {
                fec_steps += 1;
                try t.expect(work.request[44] == 1);
            }
            if (stage == .dsc_verify) {
                fec_steps += 1;
                if (scenario == 4) reply[44] = 0;
            }
            serial += 1;
            work.consume(record(reply[0..work.length]), serial, serial * std.time.ns_per_ms) catch |err| {
                try t.expect(scenario != 0 and (err == error.Bandwidth or err == error.RmRejected or err == error.LinkTraining));
                try t.expect(!work.readyScanout() and work.dpResult() == null);
                failed = true;
                break;
            };
        }
        try t.expect(serial < 40 and failed == (scenario != 0));
        if (scenario == 0) try t.expect(work.phase == .complete and work.dpResult().?.compressed != null);
    }
}
fn stopTransactions(plan: @import("gsp_display_link.zig").Plan) !void {
    const link = @import("gsp_display_link.zig");
    for ([_]bool{ true, false }) |present| {
        var work = try link.Work.stopExtended(plan, present);
        var serial: u64 = 0;
        while (work.phase != .complete and serial < 4) {
            work.length = try work.encode(&work.request);
            work.pending = true;
            var reply = work.request;
            if (work.clear_dp.?.stage == .fec_disable) {
                try t.expect(work.length == 36 and work.request[32] == 0);
                var rejected = work;
                put(&reply, 12, 0x55);
                try t.expectError(error.RmRejected, rejected.consume(record(reply[0..work.length]), serial + 1, 0));
                try t.expect(!rejected.cleared() and rejected.phase == .before_scanout);
                put(&reply, 12, 0);
            } else {
                try t.expect(present and work.length == 72 and std.mem.readInt(u32, work.request[40..44], .little) == 0x160);
                put(&reply, 60, 1);
                if (work.clear_dp.?.stage == .decoder_verify) {
                    var stale = work;
                    reply[44] = 1;
                    try t.expectError(error.LinkTraining, stale.consume(record(reply[0..work.length]), serial + 1, 0));
                    try t.expect(!stale.cleared());
                    reply[44] = 0;
                } else try t.expect(work.request[44] == 0);
            }
            serial += 1;
            try work.consume(record(reply[0..work.length]), serial, serial * std.time.ns_per_ms);
        }
        try t.expect(serial == @as(u64, if (present) 3 else 1) and work.cleared() and !work.readyScanout());
    }
    var restored = link.Work.init(plan);
    try restored.clearPrevious(plan);
    var serial: u64 = 0;
    while (!restored.cleared() and serial < 4) {
        restored.length = try restored.encode(&restored.request);
        restored.pending = true;
        var reply = restored.request;
        if (restored.clear_dp.?.stage != .fec_disable) put(&reply, 60, 1);
        serial += 1;
        try restored.consume(record(reply[0..restored.length]), serial, serial * std.time.ns_per_ms);
    }
    try t.expect(restored.cleared() and restored.phase == .before_scanout and restored.dp.?.stage == .source and !restored.readyScanout());
    var invalid = plan;
    invalid.mode.signal.sor = 2;
    var rejected = link.Work.init(invalid);
    try t.expectError(error.Stale, rejected.clearPrevious(plan));
}
fn method(program: @import("gsp_display_commands.zig").Program, address: u32) !u32 {
    var index: usize = 0;
    while (index < program.count) {
        const header = program.words[index];
        const count = (header >> 18) & 1023;
        const start = header & 0x3ffc;
        if (address >= start and (address - start) / 4 < count) return program.words[index + 1 + (address - start) / 4];
        index += 1 + count;
    }
    return error.MissingMethod;
}
pub fn hdmiCore(selected: @import("gsp_boot_mode.zig").Plan) !void {
    const commands = @import("gsp_display_commands.zig");
    const encoded = try commands.core(.{ .notifier = 0x1234, .windows = 255, .initialize = true,
        .route = .{ .head = selected.head, .window = selected.window }, .signal = selected.signal });
    const vector = @embedFile("fixtures/hdmi-dsc-wire-570.144.bin")[528..];
    for (0..3) |i| try t.expectEqual(std.mem.readInt(u32, vector[i * 8 + 4 ..][0..4], .little),
        try method(encoded, selected.head * 0x400 + std.mem.readInt(u32, vector[i * 8 ..][0..4], .little)));
    const address = std.mem.readInt(u32, vector[24..28], .little);
    for (selected.signal.hdmi_dsc.?.params.pps, 0..) |value, i|
        try t.expectEqual(value, try method(encoded, selected.head * 0x400 + address + @as(u32, @intCast(i)) * 4));
    for (0..2) |i| try t.expectEqual(std.mem.readInt(u32, vector[32 + i * 8 ..][0..4], .little),
        try method(encoded, selected.head * 0x400 + std.mem.readInt(u32, vector[28 + i * 8 ..][0..4], .little)));
    const imp = @import("gsp_mode_control.zig");
    var bytes: [imp.max_bytes]u8 = undefined;
    _ = try imp.encode(.{ .epoch = selected.epoch, .client = 12, .device = 13, .display = 14, .control = 15 }, .possible, selected, &bytes);
    const head = bytes[32..124];
    try t.expect(head[75] == 1 and std.mem.readInt(u16, head[76..78], .little) == 192 and
        std.mem.readInt(u32, head[80..84], .little) == 8 and std.mem.readInt(u32, head[84..88], .little) == 960);
}
fn coreAndImp(selected: @import("gsp_boot_mode.zig").Plan) !void {
    const commands = @import("gsp_display_commands.zig");
    const config: commands.Config = .{ .notifier = 0x1234, .windows = 255, .initialize = true, .route = .{ .head = selected.head, .window = selected.window }, .signal = selected.signal };
    const encoded = try commands.core(config);
    const vector = @embedFile("fixtures/dsc-link-570.144.bin")[264..];
    for (0..3) |i| {
        const address = std.mem.readInt(u32, vector[i * 8 ..][0..4], .little);
        const expected = std.mem.readInt(u32, vector[i * 8 + 4 ..][0..4], .little);
        try t.expectEqual(expected, try method(encoded, address));
    }
    const pps_address = std.mem.readInt(u32, vector[24..28], .little);
    for (selected.signal.dp_dsc.?.params.pps, 0..) |value, i| try t.expectEqual(value, try method(encoded, pps_address + @as(u32, @intCast(i)) * 4));
    var ordinary = config;
    ordinary.signal.?.dp_dsc = null;
    ordinary.clear_dsc = true;
    const cleared = try commands.core(ordinary);
    try t.expect(try method(cleared, selected.head * 0x400 + 0x22d4) == 0 and try method(cleared, selected.head * 0x400 + 0x22d8) == 0);
    const imp = @import("gsp_mode_control.zig");
    var bytes: [imp.max_bytes]u8 = undefined;
    _ = try imp.encode(.{ .epoch = 11, .client = 12, .device = 13, .display = 14, .control = 15 }, .possible, selected, &bytes);
    const head = bytes[32..124];
    try t.expect(head[75] == 1 and std.mem.readInt(u16, head[76..78], .little) == 256 and
        std.mem.readInt(u32, head[80..84], .little) == 8 and std.mem.readInt(u32, head[84..88], .little) == 960);
}
fn watermark() !void {
    const fec = @import("gsp_dp_watermark.zig");
    const bytes = @embedFile("fixtures/dsc-link-570.144.bin");
    for (0..6) |index| {
        const row = bytes[index * 44 ..][0..44];
        var words: [11]u32 = undefined;
        for (&words, 0..) |*value, i| value.* = std.mem.readInt(u32, row[i * 4 ..][0..4], .little);
        const width: u16 = @intCast((words[3] + 3) / 4);
        const input: fec.Input = .{ .clock = .{ .numerator = words[2] }, .width = words[3], .total = words[4], .bpp_x16 = @intCast(words[5]), .rate = @intCast(words[0]), .lanes = @intCast(words[1]), .enhanced = true, .increased = true, .compression = .{ .count = 4, .width = width, .chunk_bytes = @intCast((@as(u32, width) * words[5] + 127) / 128) } };
        if (words[6] == 0) {
            try t.expectError(error.Bandwidth, fec.withFec(input));
            continue;
        }
        const actual = try fec.withFec(input);
        try t.expect(actual.audio_48k and actual.watermark == words[7] and actual.hblank == words[8] and actual.vblank == words[9] and words[10] == 64);
    }
}
