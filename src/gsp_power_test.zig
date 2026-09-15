const std = @import("std");
const t = std.testing;
const wire = @import("gsp_power_wire.zig");
const policy = @import("gsp_power_policy.zig");
const message = @import("gsp_exchange.zig").message;
pub fn check() !void {
    try @import("gsp_power_clock.zig").check();
    const binding: wire.Binding = .{ .epoch = 1, .client = 0xc1, .subdevice = 0xd2 };
    var bytes: [wire.max_bytes + 8]u8 = @splat(0xa5);
    var value = try wire.encode(binding, .{ .attach = 0x12345000 }, &bytes);
    try t.expect(value.len == 32 and std.mem.readInt(u32, value[8..12], .little) == 0x20800afe and
        std.mem.readInt(u64, value[24..32], .little) == 0x12345000 and bytes[32] == 0xa5);
    value = try wire.encode(binding, .{ .poll = .{ .mask = 0x1b, .interval_ms = 1000 } }, &bytes);
    try t.expect(value.len == 40 and std.mem.readInt(u32, value[8..12], .little) == 0x20800aff and
        std.mem.readInt(u64, value[24..32], .little) == 0x1b and std.mem.readInt(u32, value[32..36], .little) == 1000 and
        std.mem.readInt(u32, value[36..40], .little) == 0 and bytes[40] == 0xa5);
    value = try wire.encode(binding, .{ .boost = .{ .level = 2, .seconds = 2 } }, &bytes);
    try t.expect(value[24] == 2 and value[25] == 0 and value[26] == 0 and value[27] == 0 and
        std.mem.readInt(u32, value[8..12], .little) == 0x20800a9a and std.mem.readInt(u32, value[28..32], .little) == 2);
    try t.expectError(error.Address, wire.encode(binding, .{ .attach = 1 }, &bytes));
    try t.expectError(error.Payload, wire.encode(binding, .{ .boost = .{ .level = 0, .seconds = 2 } }, &bytes));
    try t.expectError(error.Payload, wire.encode(binding, .{ .boost = .{ .level = 2, .seconds = 3600 } }, &bytes));
    for ([_]wire.Operation{ .{ .attach = 0x12345000 }, .detach,
        .{ .poll = .{ .mask = 0x1b, .interval_ms = 1000 } }, .{ .boost = .{ .level = 2, .seconds = 2 } } }) |operation| {
        value = try wire.encode(binding, operation, &bytes);
        var reply: [wire.max_bytes]u8 = undefined;
        @memcpy(reply[0..value.len], value);
        var record: message.Record = .{ .shape = .{ .message_bytes = 80 + value.len, .checksum_bytes = 80 + value.len, .storage_bytes = 4096, .elements = 1 },
            .queue_sequence = 0, .rpc = .{ .function = 76, .result = 0 }, .payload = reply[0..value.len] };
        try t.expect(try wire.decode(binding, operation, record) == .acknowledged);
        reply[24] ^= 1;
        try t.expectError(error.Payload, wire.decode(binding, operation, record));
        reply[24] ^= 1; reply[0] ^= 1;
        try t.expectError(error.Unexpected, wire.decode(binding, operation, record));
        reply[0] ^= 1; reply[12] = 0x56; record.payload = reply[0..24];
        try t.expect((try wire.decode(binding, operation, record)).rejected == 0x56);
        reply[12] = 0;
        try t.expectError(error.Payload, wire.decode(binding, operation, record));
    }
    value = try wire.encode(binding, .timer, &bytes);
    try t.expect(value.len == 32 and std.mem.readInt(u32, value[8..12], .little) == 0x20800403 and std.mem.allEqual(u8, value[24..32], 0));
    std.mem.writeInt(u64, bytes[24..32], 1_790_000_000_000_000_000, .little);
    const timer_record: message.Record = .{ .shape = .{ .message_bytes = 112, .checksum_bytes = 112, .storage_bytes = 4096, .elements = 1 },
        .queue_sequence = 0, .rpc = .{ .function = 76, .result = 0 }, .payload = bytes[0..32] };
    try t.expect((try wire.decode(binding, .timer, timer_record)).timer == 1_790_000_000_000_000_000);
    var owner: policy.Owner = .{};
    const start: u64 = std.time.ns_per_s;
    try t.expect(try owner.next(start, .{ .outputs = 2 }, .{}) == null);
    const desktop = (try owner.next(start + 1, .{ .display_commit = true, .outputs = 2 }, .{})).?;
    try t.expect(desktop.level == 1 and desktop.reason == .multi_output);
    try t.expect(try owner.next(start + 2, .{ .render = true }, .{}) == null);
    var stale = desktop; stale.serial += 1;
    try t.expectError(error.Stale, owner.complete(stale, 0, start + 3));
    try owner.complete(desktop, 0, start + 3);
    const render = (try owner.next(start + 4, .{ .render = true, .fullscreen = true }, .{})).?;
    try t.expect(render.level == 2 and render.reason == .fullscreen and render.seconds == 2);
    try owner.complete(render, 0, start + 5);
    try t.expect(try owner.next(start + 6, .{ .copy = true, .outputs = 2 }, .{}) == null);
    try t.expect(try owner.next(start + 7, .{ .outputs = 2 }, .{}) == null and owner.reason == .settling);
    const clear = (try owner.next(start + policy.hold_ns + 10, .{ .outputs = 2 }, .{})).?;
    try t.expect(clear.level == 0 and clear.seconds == 0 and clear.reason == .idle);
    try owner.complete(clear, 0, start + policy.hold_ns + 11);
    const busy = (try owner.next(2 * start, .{ .render = true }, .{})).?;
    try owner.complete(busy, 0, 2 * start + 1);
    const limited = (try owner.next(2 * start + 2, .{ .render = true }, .{ .throttle_mask = 1 << 5 })).?;
    try t.expect(limited.level == 0 and limited.reason == .limited);
    try owner.complete(limited, 0x56, 2 * start + 3);
    try t.expect(owner.available == .rejected and owner.rejection.? == 0x56);
    try t.expect(try owner.next(3 * start, .{ .compute = true }, .{}) == null);
    const saved = owner;
    try t.expectError(error.Clock, owner.next(1, .{}, .{}));
    try t.expect(std.meta.eql(saved, owner));
}
