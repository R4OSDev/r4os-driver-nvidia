//! Cursor protocol cases share the existing original-header transport group.
const std = @import("std");
const t = std.testing;
const pio = @import("gsp_cursor_pio.zig");
const head = @import("gsp_head_events.zig");
pub fn check(commands: []const u8) !void {
    const point: pio.Point = .{ .x = -17, .y = 29 };
    for (pio.methods, 0..) |method, i| {
        try t.expectEqual(std.mem.readInt(u32, commands[i * 8..][0..4], .little), method);
        try t.expectEqual(std.mem.readInt(u32, commands[i * 8 + 4..][0..4], .little), pio.value(point, i));
    }
    var owner: pio.Owner = .{};
    const idle: pio.Sample = .{ .free = 4, .control = 1, .state = 0x40000 };
    const event: head.Sample = .{ .sequence = 1, .observed_ns = 11 };
    try t.expectError(error.Bounds, owner.begin(32768, 0, 10, 100));
    try t.expectError(error.Bounds, owner.begin(0, -32769, 10, 100));
    try t.expectEqual(@as(u64, 1), try owner.begin(-17, 29, 10, 100));
    try t.expectError(error.Busy, owner.begin(1, 1, 10, 100));
    owner.pending.?.point.x += 1;
    try t.expectError(error.Stale, owner.prepare(12, event));
    owner.pending.?.point.x -= 1;
    try owner.prepare(12, event);
    try owner.publish(100);
    try t.expectError(error.State, owner.publish(100));
    try t.expect(!try owner.observe(idle, event, 13));
    var later = event; later.sequence = 2; later.observed_ns = 13;
    var busy = idle; busy.state = 0x50000;
    try t.expect(!try owner.observe(busy, later, 14));
    busy = idle; busy.free = 3;
    try t.expect(!try owner.observe(busy, later, 14));
    try t.expect(try owner.observe(idle, later, 14));
    try t.expectEqualDeep(point, owner.completed.?.point);
    try t.expect(owner.completed.?.sequence == 1 and owner.completed.?.submitted_ns == 12 and owner.completed.?.drained_ns == 14);
    _ = try owner.begin(-32768, 32767, 15, 20);
    try owner.prepare(16, later); try owner.publish(20);
    try t.expectError(error.Timeout, owner.observe(idle, later, 20));
    try t.expect(owner.pending != null and owner.pending.?.published);
    owner = .{ .issued = std.math.maxInt(u64) };
    try t.expectError(error.Exhausted, owner.begin(0, 0, 1, 2));
    try t.expectError(error.Completion, pio.idle(.{ .free = 0xffffffff, .control = 1, .state = 0x40000 }));
}
