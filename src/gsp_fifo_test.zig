// Original-C vectors extend the existing RM transport test group.
const std = @import("std");
const t = std.testing;
const wire = @import("gsp_fifo_wire.zig");
const message = @import("gsp_message.zig");
pub const golden = @embedFile("fixtures/fifo-570.144.bin");
pub const ops = [_]wire.Operation{.allocate,.allocate,.bind,.token,.enable,.disable,.free};
pub fn response(index: usize) []const u8 {
    var at: usize = 0;
    for (ops[0..index]) |op| at += wire.length(op) * 2;
    const bytes = wire.length(ops[index]); return golden[at + bytes..][0..bytes];
}
pub fn check() !void {
    try @import("gsp_copy_test.zig").check();
    var config: wire.Config = .{ .context = .{ .epoch = 7, .client = 0xc1d00000, .device = 0x10000000, .subdevice = 0x10000001,
        .vaspace = 0x10000006, .group = 0x10000009, .share = 0x1000000a }, .handle = 0x1000000d, .rm_engine = 19, .runqueue = 0,
        .address = 0x600000, .instance = 0x10000000, .userd = 0x20000000, .methods = 0x30000000, .method_bytes = 0x6000 };
    var request: [wire.max_bytes]u8 = undefined; var reply: [wire.max_bytes]u8 = undefined;
    var offset: usize = 0;
    for (ops, 0..) |op, index| {
        config.runqueue = if (index == 1) 1 else 0;
        const data = try wire.encode(config, op, &request);
        try t.expectEqualSlices(u8, golden[offset..][0..data.len], data);
        @memcpy(reply[0..data.len], response(index));
        var record: message.Record = .{ .shape = .{ .message_bytes = data.len + 80, .checksum_bytes = data.len + 80, .storage_bytes = 4096, .elements = 1 },
            .queue_sequence = 0, .rpc = .{ .function = wire.function(op), .result = 0 }, .payload = reply[0..data.len] };
        const result = try wire.decode(config, op, data, record);
        try t.expect(result == .ok);
        if (op == .allocate) try t.expect(result.ok == 37);
        if (op == .token) try t.expect(result.ok == 0x13572468);
        const header: usize = if (op == .allocate) 32 else if (op == .free) 16 else 24;
        const status_at: usize = if (op == .allocate) 16 else 12;
        std.mem.writeInt(u32, reply[status_at..][0..4], 0x57, .little); record.payload = reply[0..header];
        const rejected = try wire.decode(config, op, data, record);
        try t.expect(rejected == .rejected and rejected.rejected == 0x57);
        reply[0] ^= 1; try t.expectError(error.Unexpected, wire.decode(config, op, data, record));
        @memcpy(reply[0..data.len], response(index)); record.payload = reply[0..data.len];
        if (op == .allocate) {
            reply[56] ^= 1; try t.expectError(error.Payload, wire.decode(config, op, data, record));
            @memcpy(reply[0..data.len], response(index)); @memset(reply[164..168], 0);
            try t.expectError(error.Payload, wire.decode(config, op, data, record));
        }
        if (op == .token) { @memset(reply[24..28], 0); try t.expect((try wire.decode(config, op, data, record)).ok == 0); }
        if (op == .enable) { reply[25] = 1; try t.expectError(error.Payload, wire.decode(config, op, data, record)); }
        offset += data.len * 2;
    }
    try t.expect(offset == 1848 and offset == golden.len);
    config.userd = config.instance; try t.expectError(error.Bounds, wire.encode(config, .allocate, &request));
    config.userd = 0x20000000; config.runqueue = 2; try t.expectError(error.Bounds, wire.encode(config, .allocate, &request));
}
