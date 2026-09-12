//! Original-header vectors extend the existing RM transport group.
const std = @import("std");
const t = std.testing;
const wire = @import("gsp_display_channel_wire.zig");
const root = @import("gsp_display_engine_wire.zig");
const message = @import("gsp_message.zig");
pub const golden = @embedFile("fixtures/display-channels-570.144.bin");
const registers = @embedFile("fixtures/display-retirement-ga102.bin");
const wimm = @embedFile("fixtures/display-wimm-570.144.bin");
pub const ops = [_]wire.Operation{ .pushbuffer, .allocate, .free };
pub fn response(kind: wire.Kind, op: wire.Operation) []const u8 {
    const vectors = if (kind == .immediate) wimm else golden;
    var offset: usize = switch (kind) { .core => 96, .window => 432, .immediate => 0 };
    for (ops) |item| { const bytes = wire.length(item); if (item == op) return vectors[offset + bytes..][0..bytes]; offset += bytes * 2; }
    unreachable;
}
pub fn check() !void {
    const binding: root.Binding = .{ .epoch = 7, .client = 0xc1d00000, .device = 0x10000000, .root = 0x10000009,
        .internal_client = 0xcaf00001, .internal_subdevice = 0xcaf00003 };
    var request: [80]u8 = undefined; var bytes: [80]u8 = undefined;
    var record: message.Record = .{ .shape = .{ .message_bytes = 128, .checksum_bytes = 128, .storage_bytes = 4096, .elements = 1 },
        .queue_sequence = 0, .rpc = .{ .function = 76, .result = 0 }, .payload = golden[48..96] };
    const instance = try root.encodeInstance(binding, 0x24000000, &request);
    try t.expectEqualSlices(u8, golden[0..48], instance);
    try t.expect(try root.decode(binding, .instance, instance, record) == .ok);
    @memcpy(bytes[0..48], record.payload); bytes[32] ^= 1; record.payload = bytes[0..48];
    try t.expectError(error.Payload, root.decode(binding, .instance, instance, record));
    try t.expectError(error.Bounds, root.encodeInstance(binding, 0, &request));
    try t.expectError(error.Bounds, root.encodeInstance(binding, 0x24001000, &request));
    var offset: usize = 96;
    for ([_]wire.Kind{ .core, .window, .immediate }, 0..) |kind, i| {
        if (kind == .immediate) { try t.expectEqual(golden.len, offset); offset = 0; }
        const vectors = if (kind == .immediate) wimm else golden;
        const config: wire.Config = .{ .root = binding, .kind = kind, .index = if (i == 0) 0 else 3,
            .handle = @intCast(0x1000000a + i), .physical = 0x8000000000 + i * 0x100000 };
        for (ops) |op| {
            const data = try wire.encode(config, op, &request);
            try t.expectEqualSlices(u8, vectors[offset..][0..data.len], data);
            @memcpy(bytes[0..data.len], response(kind, op)); record.payload = bytes[0..data.len]; record.rpc.function = wire.function(op);
            try t.expect(try wire.decode(config, op, data, record) == .ok);
            const header: usize = if (op == .allocate) 32 else if (op == .free) 16 else 24;
            const status_at: usize = if (op == .allocate) 16 else 12;
            std.mem.writeInt(u32, bytes[status_at..][0..4], 0x57, .little); record.payload = bytes[0..header];
            const rejected = try wire.decode(config, op, data, record);
            try t.expect(rejected == .rejected and rejected.rejected == 0x57);
            bytes[0] ^= 1; try t.expectError(error.Unexpected, wire.decode(config, op, data, record));
            @memcpy(bytes[0..data.len], response(kind, op)); record.payload = bytes[0..data.len];
            if (op != .free) { bytes[header] ^= 1; try t.expectError(error.Payload, wire.decode(config, op, data, record)); }
            offset += data.len * 2;
        }
        var forged = config; forged.physical += 1; try t.expectError(error.Bounds, wire.encode(forged, .pushbuffer, &request));
        forged = config; forged.physical = @as(u64, 1) << 40; try t.expectError(error.Bounds, wire.encode(forged, .pushbuffer, &request));
    }
    try t.expectEqual(@as(usize, 336), offset);
    try t.expectError(error.Bounds, wire.slot(.core, 1)); try t.expectError(error.Bounds, wire.slot(.window, 8));
    try t.expectError(error.Bounds, wire.slot(.immediate, 8));
    try t.expectEqual(@as(usize, 12), try wire.slot(.immediate, 3));
    for ([_][]const u8{ registers, wimm[336..] }) |rows| for (0..rows.len / 28) |i| {
        const row = rows[i * 28..][0..28]; const kind: wire.Kind = @enumFromInt(root.word(row, 0));
        try t.expectEqual(root.word(row, 8), try wire.controlRegister(kind, root.word(row, 4)));
        try t.expectEqual(root.word(row, 12), try wire.statusRegister(kind, root.word(row, 4)));
        try t.expectEqual(root.word(row, 24) != 0, wire.retired(kind, root.word(row, 16), root.word(row, 20)));
    };
}
