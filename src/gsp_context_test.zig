// Additional cases in the existing RM transport group.
const std = @import("std");
const t = std.testing;
const wire = @import("gsp_context_wire.zig");
const message = @import("gsp_message.zig");
pub const ops = [_]wire.Operation{.classes,.engines,.engines,.method_size,.group,.share,.free_share,.free_group};
pub const golden = @embedFile("fixtures/context-570.144.bin");
pub fn response(index: usize) []const u8 {
    var offset: usize = 0;
    for (ops[0..index]) |op| offset += wire.length(op) * 2;
    const bytes = wire.length(ops[index]);
    return golden[offset + bytes..][0..bytes];
}
pub fn check() !void {
    try checkCopyTopology();
    const binding: wire.Binding = .{ .epoch = 7, .client = 0xc1d00000, .device = 0x10000000,
        .subdevice = 0x10000001, .vaspace = 0x10000006, .group = 0x10000009, .share = 0x1000000a };
    const types = @embedFile("fixtures/context-engines-570.144.bin");
    for (0..28) |i| try t.expectEqual(wire.word(types, i * 8 + 4), try wire.nvEngine(wire.word(types, i * 8)));
    try t.expectError(error.Unsupported, wire.nvEngine(0));
    for (0..8) |i| {
        try t.expectEqual(@as(u32, @intCast(0x13 + i)), try wire.nvEngine(@intCast(29 + i)));
        try t.expectEqual(@as(u32, @intCast(i)), try wire.nvdecInstance(@intCast(29 + i)));
    }
    try t.expectError(error.Unsupported, wire.nvEngine(37));
    try t.expectError(error.Unsupported, wire.nvdecInstance(28));
    try t.expectError(error.Unsupported, wire.nvdecInstance(37));
    var request: [wire.max_bytes]u8 = undefined;
    var reply: [wire.max_bytes]u8 = undefined;
    // NVA06C_CTRL_CMD_SET_TIMESLICE / NVA06C_CTRL_TIMESLICE_PARAMS from
    // the pinned original ctrla06c.h: group target, eight-byte microseconds.
    const slice = try wire.encode(binding, 19, 0, .timeslice, &request);
    try t.expect(slice.len == 32 and wire.word(slice,4) == binding.group and wire.word(slice,8) == 0xa06c0103 and
        wire.word(slice,16) == 8 and std.mem.readInt(u64,slice[24..32],.little) == 2000);
    @memcpy(reply[0..32],slice);
    var timeslice_record: message.Record = .{ .shape = .{ .message_bytes = 112, .checksum_bytes = 112, .storage_bytes = 4096, .elements = 1 },
        .queue_sequence = 0, .rpc = .{ .function = 76, .result = 0 }, .payload = reply[0..32] };
    try t.expect((try wire.decode(binding,19,0,.timeslice,slice,timeslice_record)) == .ok);
    reply[28] ^= 1;
    try t.expectError(error.Payload,wire.decode(binding,19,0,.timeslice,slice,timeslice_record));
    reply[28] ^= 1; reply[12] = 0x56;
    timeslice_record.payload = reply[0..24];
    try t.expect((try wire.decode(binding,19,0,.timeslice,slice,timeslice_record)).rejected == 0x56);
    var offset: usize = 0;
    for (ops, 0..) |op, index| {
        const base: u32 = if (index >= 2) 32 else 0;
        const data = try wire.encode(binding, 19, base, op, &request);
        try t.expectEqualSlices(u8, golden[offset..][0..data.len], data);
        @memcpy(reply[0..data.len], response(index));
        var record: message.Record = .{ .shape = .{ .message_bytes = data.len + 80, .checksum_bytes = data.len + 80, .storage_bytes = 4096, .elements = 1 },
            .queue_sequence = 0, .rpc = .{ .function = wire.function(op), .result = 0 }, .payload = reply[0..data.len] };
        const result = try wire.decode(binding, 19, base, op, data, record);
        try t.expect(result == .ok);
        if (op == .engines) {
            const engine = wire.engine(result.ok, 0);
            try t.expect(engine.data[2] == @as(u32, if (index == 1) 1 else 19) and engine.count == 1);
        }
        if (op == .classes) try t.expect(wire.supports(result.ok, 0xc56f) and !wire.supports(result.ok, 0xc86f));
        // A known RM rejection may omit allocation parameters, but every
        // identifying header field still has to match the actual request.
        const header: usize = if (wire.function(op) == 76) 24 else if (wire.function(op) == 103) 32 else 16;
        const status_at: usize = if (wire.function(op) == 103) 16 else 12;
        std.mem.writeInt(u32, reply[status_at..][0..4], 0x57, .little); record.payload = reply[0..header];
        const rejection = try wire.decode(binding, 19, base, op, data, record);
        try t.expect(rejection == .rejected and rejection.rejected == 0x57);
        reply[0] ^= 1;
        try t.expectError(error.Unexpected, wire.decode(binding, 19, base, op, data, record));
        @memcpy(reply[0..data.len], response(index)); record.payload = reply[0..data.len];
        record.rpc.result = message.pending;
        try t.expectError(error.FirmwareResult, wire.decode(binding, 19, base, op, data, record));
        record.rpc.result = 0;
        if (op == .engines) {
            reply[32] = 2;
            try t.expectError(error.Bounds, wire.decode(binding, 19, base, op, data, record));
            @memcpy(reply[0..data.len], response(index)); reply[116] = 3;
            try t.expectError(error.Bounds, wire.decode(binding, 19, base, op, data, record));
        }
        if (op == .classes) { reply[24] = 101; try t.expectError(error.Bounds, wire.decode(binding, 19, base, op, data, record)); }
        if (op == .share) { reply[36] ^= 1; try t.expectError(error.Payload, wire.decode(binding, 19, base, op, data, record)); }
        offset += data.len * 2;
    }
    try t.expect(offset == 14112 and offset == golden.len);
}

pub fn checkCopyTopology() !void {
    const graphics = wire.engine(response(1)[24..],0);
    var copy = wire.engine(response(2)[24..],0);
    var topology: wire.CopyTopology = .{};
    try t.expect(topology.paired(graphics) == null);
    try topology.add(copy); // COPY10: an unrelated asynchronous runlist.
    try t.expect(topology.paired(graphics) == null);
    try t.expectError(error.Payload,topology.add(copy));
    copy.data[2] = 20;
    copy.data[3] = graphics.data[3];
    try topology.add(copy); // Same ID, different PRI base still is not GRCE.
    try t.expect(topology.paired(graphics) == null);
    copy.data[2] = 21;
    copy.data[11] = graphics.data[11];
    try topology.add(copy);
    try t.expectEqual(@as(?u32,21),topology.paired(graphics));
    try t.expectEqual(@as(u32,0x36),try wire.nvEngine(topology.paired(graphics).?));
    copy.data[2] = 9;
    try topology.add(copy);
    try t.expectEqual(@as(?u32,9),topology.paired(graphics));
    var invalid = graphics;
    invalid.data[11] = 0;
    try t.expect(topology.paired(invalid) == null);
    invalid = graphics;
    invalid.pbdma[0] += 1;
    try t.expect(topology.paired(invalid) == null);
}
