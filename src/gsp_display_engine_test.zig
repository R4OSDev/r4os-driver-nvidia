//! Original-header vectors extend the existing RM transport group.
const std = @import("std");
const t = std.testing;
const wire = @import("gsp_display_engine_wire.zig");
const message = @import("gsp_message.zig");
pub const golden = @embedFile("fixtures/display-engine-570.144.bin");
pub const ops = [_]wire.Operation{ .classes, .static_info, .allocate, .preserve, .free };
pub fn response(op: wire.Operation) []const u8 {
    var offset: usize = 0;
    for (ops) |item| { const bytes = wire.length(item); if (op == item) return golden[offset + bytes..][0..bytes]; offset += bytes * 2; }
    unreachable;
}
pub fn check() !void {
    const binding: wire.Binding = .{ .epoch = 7, .client = 0xc1d00000, .device = 0x10000000, .root = 0x10000009,
        .internal_client = 0xcaf00001, .internal_subdevice = 0xcaf00003 };
    var request: [wire.max_bytes]u8 = undefined; var bytes: [wire.max_bytes]u8 = undefined;
    var offset: usize = 0;
    for (ops) |op| {
        const data = try wire.encode(binding, op, &request);
        try t.expectEqualSlices(u8, golden[offset..][0..data.len], data);
        @memcpy(bytes[0..data.len], response(op));
        var record: message.Record = .{ .shape = .{ .message_bytes = data.len + 80, .checksum_bytes = data.len + 80, .storage_bytes = 4096, .elements = 1 },
            .queue_sequence = 0, .rpc = .{ .function = wire.function(op), .result = 0 }, .payload = bytes[0..data.len] };
        const decoded = try wire.decode(binding, op, data, record); try t.expect(decoded == .ok);
        if (op == .classes) try t.expect(wire.supports(decoded.ok));
        if (op == .static_info) {
            const hw = try wire.staticInfo(decoded.ok);
            try t.expect(hw.heads == 4 and hw.windows == 255 and hw.channels == 81 and hw.external_mux and !hw.internal_mux);
        }
        const header: usize = if (op == .allocate) 32 else if (op == .free) 16 else 24;
        const status_at: usize = if (op == .allocate) 16 else 12;
        std.mem.writeInt(u32, bytes[status_at..][0..4], 0x57, .little); record.payload = bytes[0..header];
        const rejected = try wire.decode(binding, op, data, record);
        try t.expect(rejected == .rejected and rejected.rejected == 0x57);
        bytes[0] ^= 1; try t.expectError(error.Unexpected, wire.decode(binding, op, data, record));
        @memcpy(bytes[0..data.len], response(op)); record.payload = bytes[0..data.len];
        if (op == .static_info) {
            bytes[32] = 2; try t.expectError(error.Bounds, wire.decode(binding, op, data, record));
            @memcpy(bytes[0..data.len], response(op)); bytes[36] = 9;
            try t.expectError(error.Bounds, wire.decode(binding, op, data, record));
        }
        if (op == .preserve) { bytes[28] = 0; try t.expectError(error.Payload, wire.decode(binding, op, data, record)); }
        record.rpc.result = 0x57; try t.expectError(error.FirmwareResult, wire.decode(binding, op, data, record));
        offset += data.len * 2;
    }
    try t.expectEqual(@as(usize, 1136), offset);
    var forged = binding; forged.internal_client = binding.client;
    try t.expectError(error.Handle, wire.encode(forged, .static_info, &request));
}
