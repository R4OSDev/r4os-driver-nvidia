// Original headers generate the wire vectors independently of Zig codecs.
// Runs in the existing RM transport test group, not a separate gate.
const std = @import("std");
const t = std.testing;
const fifo = @import("gsp_fifo_wire.zig");
const copy = @import("gsp_copy_wire.zig");
const message = @import("gsp_message.zig");
const golden = @embedFile("fixtures/copy-570.144.bin");
fn record(function: u32, payload: []const u8) message.Record {
    return .{ .shape = .{ .message_bytes = payload.len + 80, .checksum_bytes = payload.len + 80, .storage_bytes = 4096, .elements = 1 },
        .queue_sequence = 0, .rpc = .{ .function = function, .result = 0 }, .payload = payload };
}
pub fn check() !void {
    try checkScheduling();
    var config: fifo.Config = .{ .context = .{ .epoch = 7, .client = 0xc1d00000, .device = 0x10000000, .subdevice = 0x10000001,
        .vaspace = 0x10000006, .group = 0x10000009, .share = 0x1000000a }, .handle = 0x1000000d, .rm_engine = 19, .runqueue = 0,
        .address = 0x600000, .instance = 0x10000000, .userd = 0x8000004000, .methods = 0x30000000, .method_bytes = 0x6000,
        .system_userd = true, .engine = .copy, .object_handle = 0x1000000e, .object_class = 0xc7b5 };
    try t.expect(golden.len == 1196);
    for ([_]u32{8,512,0x8c,0x88,0x90}, 0..) |value, i| try t.expect(fifo.word(golden, i * 4) == value);
    var request: [fifo.max_bytes]u8 = undefined;
    var offset: usize = 20;
    const sys = try fifo.encode(config, .allocate, &request);
    try t.expectEqualSlices(u8, golden[offset..][0..400], sys); offset += 400;
    try t.expect((try fifo.decode(config, .allocate, sys, record(103, golden[offset..][0..400]))).ok == 37); offset += 400;
    for ([_]u32{0xc6b5,0xc7b5}, 0..) |class, i| {
        config.object_class = class;
        const allocation = try fifo.encode(config, .allocate_copy, &request);
        try t.expectEqualSlices(u8, golden[offset..][0..40], allocation); offset += 40;
        try t.expect((try fifo.decode(config, .allocate_copy, allocation, record(103, golden[offset..][0..40]))) == .ok);
        var changed: [40]u8 = golden[offset..][0..40].*; changed[36] ^= 1;
        try t.expectError(error.Payload, fifo.decode(config, .allocate_copy, allocation, record(103, &changed))); offset += 40;
        const encoded = try copy.encode(class, .{ .source = 0x1000001021, .target = 0x1200002081, .bytes = 4091 }, 0x602200, @intCast(37 + i));
        for (encoded, 0..) |value, index| try t.expect(fifo.word(golden, offset + index * 4) == value); offset += 68;
        const gp = try copy.entry(0xabcde01000);
        try t.expect(fifo.word(golden, offset) == gp[0] and fifo.word(golden, offset + 4) == gp[1]); offset += 8;
        const free = try fifo.encode(config, .free_copy, &request);
        try t.expectEqualSlices(u8, golden[offset..][0..16], free); offset += 16;
        try t.expect((try fifo.decode(config, .free_copy, free, record(10, golden[offset..][0..16]))) == .ok); offset += 16;
    }
    try t.expect(offset == golden.len);
    try t.expectError(error.Bounds, copy.entry(1 << 40));
    try t.expectError(error.Bounds, copy.entry((1 << 40) - 64));
    try t.expectError(error.Bounds, copy.entry(4097));
    try t.expectError(error.Bounds, copy.encode(0xc7b5, .{ .source = 4096, .target = 4097, .bytes = 4 }, 8192, 1));
    try t.expectError(error.Bounds, copy.encode(0xc7b5, .{ .source = (1 << 49) - 2, .target = 4096, .bytes = 4 }, 8192, 1));
    try t.expectError(error.Bounds, copy.encode(0xc7b5, .{ .source = 4096, .target = 8192, .bytes = 4 }, 12288, 0));
    config.address = (1 << 40) - 8192; try t.expectError(error.Bounds, fifo.encode(config, .allocate, &request));
    config.address = 0x600000; config.userd = 1 << 40; try t.expectError(error.Bounds, fifo.encode(config, .allocate, &request));
    try checkRows();
}

fn checkScheduling() !void {
    const scheduling = @import("gsp_work_scheduling.zig");
    const a = @import("r4os").abi;
    var scheduler: scheduling.Owner = .{};
    // Three queues cannot buy one producer three turns. Rejoining inherits
    // its other live queues' producer turn; unknown old kernels use timelines.
    const producers = [_]u64{ 10, 10, 10, 20, 30 };
    for (producers, 0..) |producer, i| try scheduler.admit(i, .{ .producer_kind = 2,
        .producer_id = producer, .producer_generation = 9, .fence = .{ .timeline = i + 1 } });
    for ([_]usize{0, 3, 4, 1, 3, 4, 2, 3, 4, 0}) |expected| {
        try t.expectEqual(expected, scheduler.choose().?);
        try scheduler.yield(expected);
    }
    try scheduler.release(1);
    try scheduler.admit(1, .{ .producer_kind = 2, .producer_id = 10, .producer_generation = 9, .fence = .{ .timeline = 99 } });
    try t.expectEqual(@as(usize,3), scheduler.choose().?);
    try scheduler.admit(5, .{ .size = 272, .fence = .{ .timeline = 55 } });
    try scheduler.admit(6, .{ .size = 272, .fence = .{ .timeline = 66 } });
    try scheduler.admit(7, .{ .size = 272, .fence = .{ .timeline = 77 } });
    try t.expect(scheduler.free() == null and scheduler.high_water == scheduling.capacity);
    var continuous: scheduling.Owner = .{};
    try continuous.admit(0,.{ .producer_kind = 2, .producer_id = 1, .producer_generation = 1, .fence = .{ .timeline = 1 } });
    for (0..8) |round| {
        try t.expectEqual(@as(usize,0),continuous.choose().?);
        try continuous.yield(0);
        try continuous.admit(1,.{ .producer_kind = 2, .producer_id = 2, .producer_generation = 1, .fence = .{ .timeline = round+2 } });
        // The returning short producer gets at most its next turn.
        const selected = continuous.choose().?;
        if (selected == 0) { try continuous.yield(0); try t.expectEqual(@as(usize,1),continuous.choose().?); }
        try continuous.release(1);
    }
    try t.expectError(error.Descriptor, blk: {
        var invalid: scheduling.Owner = .{};
        break :blk invalid.admit(0, a.GfxDriverJob{ .producer_kind = 2, .fence = .{ .timeline = 1 } });
    });
    const limit = scheduling.copy_bytes;
    const cases = [_]copy.Transfer{
        .{ .source = 0x10000000, .target = 0x20000000, .bytes = 3 * limit + 17 },
        .{ .source = 0x10000000, .target = 0x20000000, .bytes = 8192,
            .rows = .{ .count = 511, .source_pitch = 8256, .target_pitch = 8320 } },
        .{ .source = 0x10000000, .target = 0x20000000, .bytes = 2 * limit + 16,
            .rows = .{ .count = 2, .source_pitch = 2 * limit + 64, .target_pitch = 2 * limit + 128 } },
        .{ .source = 0x10000000, .target = 0x20000000, .bytes = 8192,
            .rows = .{ .count = 511, .source_pitch = 16384, .target_pitch = 8192 },
            .source_block = .{ .width = 16384, .height = 1024, .x = 128, .y = 31, .log2_gobs = 2 } },
    };
    for (cases) |transfer| {
        var offset: u64 = 0;
        const total = try copy.logicalBytes(transfer);
        while (offset < total) {
            const part = try copy.slice(transfer, offset, limit);
            try t.expect(part.next > offset and part.next <= total and part.next - offset <= limit);
            try t.expectEqual(part.next - offset, try copy.logicalBytes(part.transfer));
            if (transfer.rows) |rows| {
                const row = offset / transfer.bytes;
                const column = offset % transfer.bytes;
                if (part.transfer.source_block) |block| {
                    try t.expect(part.transfer.source == transfer.source and block.x == transfer.source_block.?.x + column and
                        block.y == transfer.source_block.?.y + row);
                } else try t.expectEqual(transfer.source + row * rows.source_pitch + column, part.transfer.source);
                try t.expectEqual(transfer.target + row * rows.target_pitch + column, part.transfer.target);
            } else try t.expectEqual(transfer.source + offset, part.transfer.source);
            _ = try copy.encodeTransfer(0xc7b5, part.transfer, 0x30000000, 1);
            offset = part.next;
        }
        try t.expectError(error.Bounds, copy.slice(transfer, total, limit));
        try t.expectError(error.Bounds, copy.slice(transfer, 0, 0));
    }
}
fn checkRows() !void {
    const expected = @embedFile("fixtures/copy-2d.bin");
    try t.expect(expected.len == 220 and fifo.word(expected, 0) == 2);
    var offset: usize = 4;
    var transfer: copy.Transfer = .{ .source = 0x1000001020, .target = 0x1200002080, .bytes = 44,
        .rows = .{ .count = 4, .source_pitch = 260, .target_pitch = 512 } };
    for ([_]u32{0xc6b5,0xc7b5}, 0..) |class, i| {
        for ([_]u32{class,260,512,44,4,19}) |value| { try t.expectEqual(value, fifo.word(expected, offset)); offset += 4; }
        const encoded = try copy.encodeTransfer(class, transfer, 0x602200, @intCast(37 + i));
        try t.expect(encoded.count == 19);
        for (encoded.slice()) |value| { try t.expectEqual(value, fifo.word(expected, offset)); offset += 4; }
        for (try copy.entryWords(0xabcde01000, encoded.count)) |value| { try t.expectEqual(value, fifo.word(expected, offset)); offset += 4; }
    }
    try t.expect(offset == expected.len and try transfer.span(false) == 824 and try transfer.span(true) == 1580);
    try t.expectError(error.Bounds, copy.entryWords((1 << 40) - 72, 19));
    try t.expectError(error.Bounds, copy.entryWords(4096, 18));
    transfer.rows.?.count = 0; try t.expectError(error.Bounds, copy.encodeTransfer(0xc7b5, transfer, 8192, 1));
    transfer.rows.?.count = 4; transfer.rows.?.source_pitch = 40;
    try t.expectError(error.Bounds, copy.encodeTransfer(0xc7b5, transfer, 8192, 1));
    transfer.rows.?.source_pitch = 260; transfer.target = (1 << 49) - 1000;
    try t.expectError(error.Bounds, copy.encodeTransfer(0xc7b5, transfer, 8192, 1));
    transfer.target = transfer.source + 800;
    try t.expectError(error.Bounds, copy.encodeTransfer(0xc7b5, transfer, 8192, 1));
}
