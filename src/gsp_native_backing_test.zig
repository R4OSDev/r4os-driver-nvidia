// Additional storage cases in the existing RM transport group.
const std = @import("std");
const t = std.testing;
const wire = @import("gsp_vram_wire.zig");
const message = @import("gsp_message.zig");
const backing = @import("gsp_native_backing.zig");
pub fn check() !void {
    const allocation = @import("gsp_allocation.zig");
    // A near application timeout must not shorten an admitted RM operation.
    try t.expectEqual(@as(u64, 5_000_000_010), try allocation.operationDeadline(10, 11));
    try t.expectError(error.Timeout, allocation.operationDeadline(11, 11));
    try t.expectError(error.Overflow, allocation.operationDeadline(std.math.maxInt(u64) - 1, std.math.maxInt(u64)));
    const binding: wire.Binding = .{ .space = .{ .epoch = 7, .client = 0xc1d00000, .device = 0x10000000,
        .handle = 0x10000006, .base = 0x200000, .bytes = 0x100000000, .big_page_bytes = 65536 }, .memory = 0x10000007, .virtual = 0x10000008 };
    var policy: backing.Policy = .{ .capabilities = .{ .binding = .{ .epoch = 7, .client = binding.space.client, .device = binding.space.device }, .raw = .{0,0,2} }, .physical_bytes = 0x100000000 };
    try policy.validate(binding.space, 65536);
    policy.capabilities.raw[2] = 0; try t.expectError(error.Unsupported, policy.validate(binding.space, 65536)); policy.capabilities.raw[2] = 2;
    policy.capabilities.binding.epoch += 1; try t.expectError(error.Stale, policy.validate(binding.space, 65536)); policy.capabilities.binding.epoch -= 1;
    try t.expectError(error.Bounds, policy.validate(binding.space, policy.physical_bytes + 65536));
    const golden = @embedFile("fixtures/native-storage-570.144.bin");
    var request: [160]u8 = undefined; var response: [160]u8 = undefined;
    var address: u64 = 0; var offset: usize = 0;
    for (std.enums.values(wire.Operation)) |op| {
        const data = try wire.encodeLayout(binding, 64 * 1024 * 1024, .{ .contiguous = true }, op, address, &request);
        try t.expectEqualSlices(u8, golden[offset..][0..data.bytes.len], data.bytes);
        @memcpy(response[0..data.bytes.len], golden[offset + data.bytes.len..][0..data.bytes.len]);
        const record: message.Record = .{ .shape = .{ .message_bytes = data.bytes.len + 80, .checksum_bytes = data.bytes.len + 80, .storage_bytes = 4096, .elements = 1 },
            .queue_sequence = 0, .rpc = .{ .function = data.function, .result = 0 }, .payload = response[0..data.bytes.len] };
        const decoded = try wire.decode(binding, 64 * 1024 * 1024, op, data.bytes, record, address);
        try t.expect(decoded == .ok);
        if (op == .allocate_virtual) address = decoded.ok;
        if (op == .allocate_memory) {
            try t.expect(decoded.ok == 0x80000000);
            response[59] ^= 0x18;
            try t.expectError(error.Payload, wire.decode(binding, 64 * 1024 * 1024, op, data.bytes, record, address));
        }
        offset += data.bytes.len * 2;
    }
    try t.expect(offset == 896 and offset == golden.len);
    // The independent original C allocation fixture keeps all wire offsets
    // and bytes. Only original CURSOR / display / ISO fields differ.
    const encoded = try wire.encodeLayout(binding, 64 * 1024 * 1024,
        .{ .contiguous = true, .cursor = true }, .allocate_memory, 0, &request);
    const cursor_fixture = @embedFile("fixtures/cursor-storage-570.144.bin");
    try t.expectEqual(@as(usize, 320), cursor_fixture.len);
    try t.expectEqualSlices(u8, cursor_fixture[0..160], encoded.bytes);
    try t.expect(std.mem.readInt(u32, encoded.bytes[40..44], .little) & 0x1000 == 0);
    @memcpy(&response, cursor_fixture[160..320]);
    std.mem.writeInt(u32, response[64..68], 6, .little);
    const record: message.Record = .{ .shape = .{ .message_bytes = 240, .checksum_bytes = 240, .storage_bytes = 4096, .elements = 1 },
        .queue_sequence = 0, .rpc = .{ .function = encoded.function, .result = 0 }, .payload = &response };
    try t.expect((try wire.decode(binding, 64 * 1024 * 1024, .allocate_memory, encoded.bytes, record, 0)).ok == 0x80000000);
    response[36] = 0; // Original IMAGE type cannot replace CURSOR.
    try t.expectError(error.Payload, wire.decode(binding, 64 * 1024 * 1024, .allocate_memory, encoded.bytes, record, 0));
    response[36] = 5;
    response[62] ^= 4; // Returned ISO may not be removed or invented.
    try t.expectError(error.Payload, wire.decode(binding, 64 * 1024 * 1024, .allocate_memory, encoded.bytes, record, 0));
    response[62] ^= 4;
    response[41] ^= 0x10; // Nor may a new NO_SCANOUT request appear.
    try t.expectError(error.Payload, wire.decode(binding, 64 * 1024 * 1024, .allocate_memory, encoded.bytes, record, 0));
    try t.expectError(error.Bounds, wire.encodeLayout(binding, 65536, .{ .cursor = true, .scanout = true }, .allocate_memory, 0, &request));
    try t.expectError(error.Bounds, wire.encodeLayout(binding, 65536, .{ .cursor = true, .blocklinear = true }, .allocate_memory, 0, &request));
    const lut = try wire.encodeLayout(binding, 64 * 1024 * 1024,
        .{ .contiguous = true, .lut = true }, .allocate_memory, 0, &request);
    const lut_fixture = @embedFile("fixtures/display-identity-allocation570.144.bin");
    try t.expectEqual(@as(usize, 320), lut_fixture.len);
    try t.expectEqualSlices(u8, lut_fixture[0..160], lut.bytes);
    @memcpy(&response, lut_fixture[160..320]);
    const lut_record: message.Record = .{ .shape = record.shape, .queue_sequence = 0,
        .rpc = .{ .function = lut.function, .result = 0 }, .payload = &response };
    try t.expect((try wire.decode(binding, 64 * 1024 * 1024, .allocate_memory, lut.bytes, lut_record, 0)).ok == 0x80000000);
    response[62] ^= 4;
    try t.expectError(error.Payload, wire.decode(binding, 64 * 1024 * 1024, .allocate_memory, lut.bytes, lut_record, 0));
    try t.expectError(error.Bounds, wire.encodeLayout(binding, 65536, .{ .lut = true, .cursor = true }, .allocate_memory, 0, &request));
    try t.expectError(error.Bounds, wire.encodeLayout(binding, 65536, .{ .lut = true, .scanout = true }, .allocate_memory, 0, &request));
    try t.expectError(error.Bounds, wire.encodeLayout(binding, 65536, .{ .lut = true, .privileged = true }, .allocate_memory, 0, &request));
    policy.role = .lut; try t.expect(policy.needsIso());
    std.debug.print("[nvidia-identity-storage] original C IMAGE/display/ISO allocation; exact full packet, negative mixed roles and changed returned ISO\n", .{});
    std.debug.print("[nvidia-cursor-storage] original C cursor/ISO/NO_SCANOUT wire bytes and exact generic-kind reply; unrelated type/attribute changes rejected\n", .{});
}
