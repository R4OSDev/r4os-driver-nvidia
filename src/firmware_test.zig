const std = @import("std");
const t = std.testing;
const fw = @import("firmware.zig");

const table = 4352;
const names = "\x00.fwimage\x00.fwversion\x00.fwsignature_ga10x\x00.shstrtab\x00";
fn put(comptime T: type, bytes: []u8, off: usize, value: T) void {
    std.mem.writeInt(T, bytes[off..][0..@sizeOf(T)], value, .little);
}
fn section(bytes: []u8, index: usize, name: []const u8, kind: u32, flags: u64, offset: u64, size: u64) void {
    const off = table + index * 64;
    put(u32, bytes, off, @intCast(std.mem.indexOf(u8, names, name).?));
    put(u32, bytes, off + 4, kind);
    put(u64, bytes, off + 8, flags);
    put(u64, bytes, off + 24, offset);
    put(u64, bytes, off + 32, size);
    put(u64, bytes, off + 48, 1);
}
fn fixture() [4672]u8 {
    var bytes = [_]u8{0} ** 4672;
    @memcpy(bytes[0..7], "\x7fELF\x02\x01\x01");
    put(u16, &bytes, 16, 1);
    put(u16, &bytes, 18, 243);
    put(u32, &bytes, 20, 1);
    put(u64, &bytes, 40, table);
    put(u16, &bytes, 52, 64);
    put(u16, &bytes, 58, 64);
    put(u16, &bytes, 60, 5);
    put(u16, &bytes, 62, 4);
    @memcpy(bytes[80..88], "570.144\x00");
    @memcpy(bytes[4200..][0..names.len], names);
    section(&bytes, 1, ".fwimage", 1, 3, 64, 16);
    section(&bytes, 2, ".fwversion", 1, 0, 80, 8);
    section(&bytes, 3, ".fwsignature_ga10x", 1, 0, 96, 4096);
    section(&bytes, 4, ".shstrtab", 3, 0, 4200, names.len);
    return bytes;
}

test "NVIDIA firmware structural profile is bounded and never authenticates synthetic firmware" {
    const bytes = fixture();
    const layout = try fw.inspect(&bytes, .ga10x);
    try t.expectEqual(@as(usize, 16), layout.image.bytes);
    try t.expectEqual(@as(usize, 96), layout.signature.offset);
    try t.expectError(error.WrongSize, fw.verify(&bytes, .ga10x));
    try t.expectError(error.MissingSignature, fw.inspect(&bytes, .tu10x));
    var changed = bytes;
    changed[80] = '6';
    try t.expectError(error.WrongVersion, fw.inspect(&changed, .ga10x));
    changed = bytes;
    changed[87] = 'X';
    try t.expectError(error.WrongVersion, fw.inspect(&changed, .ga10x));
    changed = bytes;
    put(u64, &changed, table + 3 * 64 + 32, 4095);
    try t.expectError(error.BadSignature, fw.inspect(&changed, .ga10x));
    changed = bytes;
    put(u64, &changed, table + 3 * 64 + 24, 64);
    try t.expectError(error.Overlap, fw.inspect(&changed, .ga10x));
    changed = bytes;
    put(u32, &changed, table + 3 * 64, 1);
    try t.expectError(error.DuplicateName, fw.inspect(&changed, .ga10x));
    changed = bytes;
    put(u64, &changed, 40, std.math.maxInt(u64));
    try t.expectError(error.BadSection, fw.inspect(&changed, .ga10x));
    changed = bytes;
    put(u16, &changed, 60, 0);
    try t.expectError(error.BadSectionTable, fw.inspect(&changed, .ga10x));
    // Every incomplete byte prefix and every individual metadata bit must
    // terminate without an out-of-bounds access, even if still well formed.
    for (0..bytes.len) |end| {
        if (fw.inspect(bytes[0..end], .ga10x)) |_| return error.TruncatedAccepted else |_| {}
    }
    for (0..512 + 5 * 64 * 8) |bit| {
        changed = bytes;
        const offset = if (bit < 512) bit / 8 else table + (bit - 512) / 8;
        changed[offset] ^= @as(u8, 1) << @intCast(bit % 8);
        _ = fw.inspect(&changed, .ga10x) catch continue;
    }
}

const Reader = struct {
    now: u64 = 1,
    next_now: ?u64 = null,
    calls: usize = 0,
    short: bool = false,
    fail: bool = false,
    largest: usize = 0,
    expected_offset: usize = 0,
    pub fn nowNs(self: *@This()) u64 {
        return self.now;
    }
    pub fn readAt(self: *@This(), resource: []const u8, offset: usize, out: []u8, deadline: u64) !usize {
        try t.expectEqualStrings(fw.specification(.ga10x).resource, resource);
        try t.expectEqual(self.expected_offset, offset);
        try t.expect(out.len <= fw.read_chunk_bytes);
        try t.expect(self.now < deadline);
        self.calls += 1;
        self.largest = @max(self.largest, out.len);
        self.expected_offset += out.len;
        if (self.next_now) |now| self.now = now;
        if (self.fail) return error.Io;
        @memset(out, 0);
        return out.len - @intFromBool(self.short);
    }
};

test "NVIDIA firmware loader retains no admissible view after read deadline corruption or close" {
    const storage = try t.allocator.alloc(u8, fw.specification(.ga10x).bytes);
    defer t.allocator.free(storage);
    try t.expectError(error.WrongSize, fw.Load.begin(.ga10x, storage[0..1], 1, 10));
    try t.expectError(error.InvalidDeadline, fw.Load.begin(.ga10x, storage, 1, 0));
    try t.expectError(error.InvalidDeadline, fw.Load.begin(.ga10x, storage, std.math.maxInt(u64), 1));
    var load = try fw.Load.begin(.ga10x, storage, 1, 10);
    var reader = Reader{ .now = 11 };
    try t.expectError(error.Timeout, load.step(&reader));
    try t.expectEqual(@as(usize, 0), reader.calls);
    try t.expect(load.ready() == null);
    try t.expectError(error.BadState, load.step(&reader));
    load.close();
    load.close();
    try t.expectEqual(@as(usize, 0), load.storage.len);
    inline for (.{ error.ShortRead, error.ReadFailed, error.Timeout, error.ClockRegression }) |expected| {
        load = try fw.Load.begin(.ga10x, storage, 1, 10);
        reader = .{
            .short = expected == error.ShortRead,
            .fail = expected == error.ReadFailed,
            .next_now = if (expected == error.Timeout) 11 else if (expected == error.ClockRegression) 0 else null,
        };
        try t.expectError(expected, load.step(&reader));
        try t.expectEqual(fw.Load.State.failed, load.state);
        try t.expect(load.ready() == null);
    }
    load = try fw.Load.begin(.ga10x, storage, 1, 10);
    reader = .{};
    while (load.filled + fw.read_chunk_bytes < storage.len) {
        try t.expectEqual(fw.Load.State.reading, try load.step(&reader));
        try t.expect(load.ready() == null);
    }
    try t.expectError(error.WrongHash, load.step(&reader));
    try t.expectEqual(@as(usize, (storage.len + fw.read_chunk_bytes - 1) / fw.read_chunk_bytes), reader.calls);
    try t.expect(load.ready() == null);
    load.close();
}
