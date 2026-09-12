// Additional storage cases in the existing RM transport group.
const std = @import("std");
const t = std.testing;
const wire = @import("gsp_vram_wire.zig");
const message = @import("gsp_message.zig");
const backing = @import("gsp_native_backing.zig");
pub fn check() !void {
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
}
