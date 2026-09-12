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
    var config: fifo.Config = .{ .context = .{ .epoch = 7, .client = 0xc1d00000, .device = 0x10000000, .subdevice = 0x10000001,
        .vaspace = 0x10000006, .group = 0x10000009, .share = 0x1000000a }, .handle = 0x1000000d, .rm_engine = 19, .runqueue = 0,
        .address = 0x600000, .instance = 0x10000000, .userd = 0x8000004000, .methods = 0x30000000, .method_bytes = 0x6000,
        .system_userd = true, .copy_handle = 0x1000000e, .copy_class = 0xc7b5 };
    try t.expect(golden.len == 1196);
    for ([_]u32{8,512,0x8c,0x88,0x90}, 0..) |value, i| try t.expect(fifo.word(golden, i * 4) == value);
    var request: [fifo.max_bytes]u8 = undefined;
    var offset: usize = 20;
    const sys = try fifo.encode(config, .allocate, &request);
    try t.expectEqualSlices(u8, golden[offset..][0..400], sys); offset += 400;
    try t.expect((try fifo.decode(config, .allocate, sys, record(103, golden[offset..][0..400]))).ok == 37); offset += 400;
    for ([_]u32{0xc6b5,0xc7b5}, 0..) |class, i| {
        config.copy_class = class;
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
}
