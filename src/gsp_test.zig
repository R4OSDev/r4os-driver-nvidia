const std = @import("std");
const t = std.testing;
const boot = @import("gsp_boot.zig");
const layout = @import("gsp_layout.zig");
const preflight = @import("fwsec_state.zig");
const radix = @import("gsp_radix.zig");
const wpr = @import("gsp_wpr.zig");
const init = @import("gsp_init.zig");
const message = @import("gsp_message.zig");

test "GSP message framing bounds complete records before checksum and preserves caller state" {
    const profile = message.Profile{ .chip_id = 0x176 };
    const rpc = message.Rpc{ .function = 0xdeadbeef, .sequence = 0x12345678 };
    const output = try t.allocator.alloc(u8, message.max_bytes);
    defer t.allocator.free(output);
    const payload = try t.allocator.alloc(u8, message.max_bytes);
    defer t.allocator.free(payload);
    for (payload, 0..) |*byte, index| byte.* = @truncate(index * 37 + 11);
    for ([_]usize{ 0, 1, 7, 4016, 4017, message.max_payload_bytes }, 0..) |length, index| {
        @memset(output, 0xa5);
        const sequence: u32 = std.math.maxInt(u32) - @as(u32, @intCast(index));
        const shape = try message.encode(profile, sequence, rpc, payload[0..length], output);
        const prefix = try message.inspectPrefix(profile, output[0..message.header_bytes]);
        try t.expectEqualDeep(shape, prefix);
        const record = try message.decode(profile, output[0..shape.storage_bytes], sequence);
        try t.expectEqualDeep(rpc, record.rpc);
        try t.expectEqual(sequence, record.queue_sequence);
        try t.expectEqualSlices(u8, payload[0..length], record.payload);
        try t.expect(std.mem.allEqual(u8, output[shape.message_bytes..shape.storage_bytes], 0));
        try t.expect(std.mem.allEqual(u8, output[shape.storage_bytes..], 0xa5));
        try t.expectError(error.Sequence, message.decode(profile, output[0..shape.storage_bytes], sequence +% 1));
        try t.expectError(error.Length, message.decode(profile, output[0 .. shape.storage_bytes - 1], sequence));
    }
    const sequence = 0x99887766;
    const shape = try message.encode(profile, sequence, rpc, payload[0..1], output);
    const baseline = try t.allocator.dupe(u8, output[0..shape.storage_bytes]);
    defer t.allocator.free(baseline);
    const Invalid = struct { offset: usize, value: u32, failure: anyerror };
    const invalid = [_]Invalid{
        .{ .offset = 40, .value = 0, .failure = error.Elements },
        .{ .offset = 40, .value = 17, .failure = error.Elements },
        .{ .offset = 40, .value = 2, .failure = error.Elements },
        .{ .offset = 56, .value = 0, .failure = error.Length },
        .{ .offset = 56, .value = 31, .failure = error.Length },
        .{ .offset = 56, .value = 65489, .failure = error.Length },
        .{ .offset = 56, .value = 0xffffffff, .failure = error.Length },
        .{ .offset = 48, .value = 0x03010000, .failure = error.Version },
        .{ .offset = 52, .value = 0, .failure = error.Signature },
        .{ .offset = 32, .value = std.mem.readInt(u32, baseline[32..36], .little) ^ 1, .failure = error.Checksum },
    };
    for (invalid) |case| {
        @memcpy(output[0..baseline.len], baseline);
        std.mem.writeInt(u32, output[case.offset..][0..4], case.value, .little);
        try t.expectError(case.failure, message.decode(profile, output[0..baseline.len], sequence));
    }
    @memcpy(output[0..baseline.len], baseline);
    output[shape.message_bytes] = 1;
    try t.expectError(error.Padding, message.decode(profile, output[0..baseline.len], sequence));
    @memcpy(output[0..baseline.len], baseline);
    output[message.header_bytes] ^= 1;
    try t.expectError(error.Checksum, message.decode(profile, output[0..baseline.len], sequence));
    @memcpy(output[0..baseline.len], baseline);
    output[baseline.len - 1] = 0x7f; // Stale bytes beyond the checksummed message are not payload.
    _ = try message.decode(profile, output[0..baseline.len], sequence);
    output[0] ^= 0x12; // Cleartext auth/AAD bytes are opaque, never evidence of authentication.
    output[32] ^= 0x12;
    _ = try message.decode(profile, output[0..baseline.len], sequence);
    try t.expectError(error.Profile, message.decode(.{ .chip_id = 0x176, .confidential_compute = true }, output[0..baseline.len], sequence));
    try t.expectError(error.Length, message.inspectPrefix(profile, output[0 .. message.header_bytes - 1]));
    try t.expectError(error.Length, message.decode(profile, output, sequence));
    @memset(output, 0xa5);
    try t.expectError(error.Profile, message.encode(.{ .chip_id = 0x177 }, 0, rpc, payload[0..1], output));
    try t.expectError(error.Profile, message.encode(.{ .chip_id = 0x176, .confidential_compute = true }, 0, rpc, payload[0..1], output));
    try t.expectError(error.Length, message.encode(profile, 0, rpc, payload, output));
    try t.expectError(error.Output, message.encode(profile, 0, rpc, &.{}, output[0..4095]));
    try t.expectError(error.Overlap, message.encode(profile, 0, rpc, output[128..129], output));
    try t.expect(std.mem.allEqual(u8, output, 0xa5));
}

test "GSP initialization encodes self-mapped queues and ordered Libos logs without partial output" {
    const output = try t.allocator.alignedAlloc(u8, comptime std.mem.Alignment.fromByteUnits(8), init.output_bytes);
    defer t.allocator.free(output);
    const queues = [_]init.Span{
        .{ .address = 0xa00000000, .bytes = 4096 },
        .{ .address = 0xb00000000, .bytes = 65536 },
        .{ .address = 0xc00000000, .bytes = 112 * 4096 },
    };
    var good: init.Bindings = .{
        .chip_id = 0x176,
        .libos = .{ .address = 0x900000000, .bytes = 4096 },
        .rm = .{ .address = 0x900001000, .bytes = 4096 },
        .logs = undefined,
        .queues = &queues,
        // FWSEC uses a 256-byte-aligned, 59904-byte DMA span, not full pages.
        .excluded = &.{.{ .address = 0xd00000100, .bytes = 59904 }},
    };
    for (&good.logs, 0..) |*span, i| span.* = .{ .address = 0x910000000 + i * 0x20000, .bytes = 65536 };
    const report = try init.encode(&good, output);
    try t.expectEqual(@as(usize, 864256), output.len);
    try t.expectEqual(@as(u64, 0xa00000000), report.queues_address);
    try t.expectEqual(@as(usize, 129), report.queue_page_count);
    try t.expectEqual(@as(u64, 0x4c4f47494e4954), word(output, 0)); // LOGINIT numeric id, not an ASCII byte copy.
    for (good.logs, 0..) |span, i| {
        try t.expectEqual(span.address, word(output, i * 32 + 8));
        try t.expectEqual(@as(u64, 65536), word(output, i * 32 + 16));
        try t.expectEqualSlices(u8, &.{ 1, 1, 0, 0, 0, 0, 0, 0 }, output[i * 32 + 24 ..][0..8]);
        const log = output[init.logs_offset + i * init.log_bytes ..][0..init.log_bytes];
        try t.expectEqual(@as(u64, 0), word(log, 0));
        for (0..16) |page| try t.expectEqual(span.address + page * 4096, word(log, 8 + page * 8));
        try t.expect(std.mem.allEqual(u8, log[136..], 0));
    }
    try t.expectEqual(@as(u64, 0x524d41524753), word(output, 5 * 32));
    try t.expectEqual(good.rm.address, word(output, 5 * 32 + 8));
    try t.expect(std.mem.allEqual(u8, output[6 * 32 .. 4096], 0));
    const rm = output[init.rm_offset..][0..4096];
    try t.expectEqual(report.queues_address, word(rm, 0));
    try t.expectEqual(@as(u64, 129), word(rm, 8));
    try t.expectEqual(@as(u64, 4096), word(rm, 16));
    try t.expectEqual(@as(u64, 0x41000), word(rm, 24));
    try t.expect(std.mem.allEqual(u8, rm[32..48], 0));
    try t.expectEqual(@as(u8, 1), rm[48]);
    try t.expect(std.mem.allEqual(u8, rm[49..], 0));
    const queue = output[init.queues_offset..];
    try t.expectEqual(queues[0].address, word(queue, 0));
    try t.expectEqual(queues[1].address, word(queue, 8));
    try t.expectEqual(queues[2].address, word(queue, 17 * 8));
    try t.expectEqual(queues[2].address + 111 * 4096, word(queue, 128 * 8));
    try t.expect(std.mem.allEqual(u8, queue[129 * 8 .. 4096], 0));
    const header = queue[init.command_offset..][0..32];
    const expected = [_]u32{ 0, 262144, 4096, 63, 0, 1, 32, 4096 };
    for (expected, 0..) |value, i| try t.expectEqual(value, std.mem.readInt(u32, header[i * 4 ..][0..4], .little));
    // Includes the status header: no fabricated firmware-side queue/ready state.
    try t.expect(std.mem.allEqual(u8, queue[4096 + 32 ..], 0));
    @memset(output, 0xa5);
    for (0..18) |case| {
        var input = good;
        var spans = queues;
        input.queues = &spans;
        const failure: anyerror = switch (case) {
            0 => blk: {
                input.chip_id = 0x174;
                break :blk error.Profile;
            },
            1 => blk: {
                input.libos.bytes = 8192;
                break :blk error.Size;
            },
            2 => blk: {
                input.logs[4].bytes = 32768;
                break :blk error.Size;
            },
            3 => blk: {
                input.rm.address = 0;
                break :blk error.Address;
            },
            4 => blk: {
                input.logs[0].address = radix.dma_mask - 4095;
                break :blk error.Address;
            },
            5 => blk: {
                input.libos.address += 1;
                break :blk error.Alignment;
            },
            6 => blk: {
                input.rm.address = input.libos.address;
                break :blk error.Overlap;
            },
            7 => blk: {
                input.logs[4].address = input.logs[0].address + 4096;
                break :blk error.Overlap;
            },
            8 => blk: {
                spans[2].address = spans[1].address;
                break :blk error.Overlap;
            },
            9 => blk: {
                spans[1].address = input.logs[0].address;
                break :blk error.Overlap;
            },
            10 => blk: {
                input.excluded = &.{.{ .address = spans[2].address + spans[2].bytes - 4096, .bytes = 4096 }};
                break :blk error.Overlap;
            },
            11 => blk: {
                spans[2].bytes -= 4096;
                break :blk error.Size;
            },
            12 => blk: {
                spans[2].bytes += 4096;
                break :blk error.Size;
            },
            13 => blk: {
                spans[0].bytes -= 1;
                break :blk error.Alignment;
            },
            14 => blk: {
                input.excluded = &.{.{ .address = spans[2].address + spans[2].bytes - 1, .bytes = 59904 }};
                break :blk error.Overlap;
            },
            15 => blk: {
                input.excluded = &.{.{ .address = input.libos.address - 59903, .bytes = 59904 }};
                break :blk error.Overlap;
            },
            16 => blk: {
                input.excluded = &.{.{ .address = radix.dma_mask, .bytes = 2 }};
                break :blk error.Address;
            },
            else => blk: {
                input.excluded = &.{.{ .address = 1, .bytes = 0 }};
                break :blk error.Address;
            },
        };
        try t.expectError(failure, init.encode(&input, output));
        try t.expect(std.mem.allEqual(u8, output, 0xa5));
    }
    var bad = good;
    bad.queues = &.{};
    try t.expectError(error.Segments, init.encode(&bad, output));
    try t.expectError(error.Size, init.encode(&good, output[1..]));
    try t.expect(std.mem.allEqual(u8, output, 0xa5));
    // The small input description may share caller storage: encoding completes
    // validation and snapshots all values before clearing any destination byte.
    const alias: *[3]init.Span = @ptrCast(@alignCast(output.ptr));
    alias.* = queues;
    var aliased = good;
    aliased.queues = alias;
    _ = try init.encode(&aliased, output);
    try t.expectEqual(@as(u64, 0xc00000000), word(output, init.queues_offset + 17 * 8));
}

fn word(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

test "GSP radix encodes scattered DMA pages, rejects aliases atomically and zeros padding" {
    // One page beyond a leaf table exercises a real level transition and a
    // partial final data page. All three physical spans are discontiguous.
    const need = try radix.requirements(2 * 1024 * 1024 + 17);
    try t.expectEqual(@as(usize, 513), need.levels[3].pages);
    try t.expectEqual(@as(usize, 2), need.levels[2].pages);
    try t.expectEqual(@as(usize, 16384), need.table_bytes);
    const image = try t.allocator.alloc(u8, need.image_bytes);
    defer t.allocator.free(image);
    @memset(image, 0x79);
    const output = try t.allocator.alloc(u8, need.allocation_bytes);
    defer t.allocator.free(output);
    const segments = [_]radix.Segment{
        .{ .address = 0x100000000, .bytes = 4096 },
        .{ .address = 0x200000000, .bytes = need.allocation_bytes - 8192 },
        .{ .address = 0x8000000, .bytes = 4096 },
    };
    try t.expectEqual(@as(u64, 0x100000000), try radix.encode(image, &segments, output));
    try t.expectEqual(@as(u64, 0x200000000), word(output, 0));
    try t.expectEqual(@as(u64, 0x200001000), word(output, 4096));
    try t.expectEqual(@as(u64, 0x200002000), word(output, 4096 + 8));
    try t.expectEqual(@as(u64, 0x200003000), word(output, 8192));
    try t.expectEqual(@as(u64, 0x8000000), word(output, 8192 + 512 * 8));
    try t.expect(std.mem.allEqual(u8, output[8..4096], 0));
    try t.expect(std.mem.allEqual(u8, output[4096 + 16 .. 8192], 0));
    try t.expect(std.mem.allEqual(u8, output[8192 + 513 * 8 .. need.table_bytes], 0));
    try t.expectEqualSlices(u8, image, output[need.table_bytes..][0..image.len]);
    try t.expect(std.mem.allEqual(u8, output[need.table_bytes + image.len ..], 0));
    try t.expect(std.mem.allEqual(u8, image, 0x79));
    @memset(output, 0xa5);
    for (0..7) |case| {
        var bad = segments;
        const failure: anyerror = switch (case) {
            0 => blk: {
                bad[0].address = 0;
                break :blk error.Address;
            },
            1 => blk: {
                bad[0].address = radix.dma_mask - 4094;
                break :blk error.Address;
            },
            2 => blk: {
                bad[0].address += 1;
                break :blk error.Alignment;
            },
            3 => blk: {
                bad[2].address = bad[1].address;
                break :blk error.Overlap;
            },
            4 => blk: {
                bad[2].bytes = 8192;
                break :blk error.Capacity;
            },
            5 => blk: {
                bad[1].bytes -= 4096;
                break :blk error.Capacity;
            },
            else => blk: {
                bad[0].bytes = 0;
                break :blk error.Address;
            },
        };
        try t.expectError(failure, radix.encode(image, &bad, output));
        try t.expect(std.mem.allEqual(u8, output, 0xa5));
    }
    try t.expectError(error.Overlap, radix.encode(output[need.table_bytes..][0..image.len], &segments, output));
    try t.expectError(error.Segments, radix.encode(image, &.{}, output));
    try t.expectError(error.Capacity, radix.encode(image, &segments, output[1..]));
    try t.expect(std.mem.allEqual(u8, output, 0xa5));
    const actual = try radix.requirements(63541248);
    try t.expectEqual(@as(usize, 15513), actual.levels[3].pages);
    try t.expectEqual(@as(usize, 135168), actual.table_bytes);
    try t.expectEqual(@as(usize, 63676416), actual.allocation_bytes);
    try t.expectError(error.ImageSize, radix.requirements(0));
    try t.expectError(error.ImageSize, radix.requirements(std.math.maxInt(usize)));
}

fn descriptorFixture() [84]u8 {
    // Decoded production descriptor fields, not executable boot image bytes.
    const fields = [_]u32{ 5, 20480, 2176, 22656, 16, 0, 0, 0, 0, 2048, 2048, 4096, 6144, 10496, 1, 0, 0, 0, 0, 24576, 0 };
    var bytes: [84]u8 = undefined;
    for (fields, 0..) |value, index| put(&bytes, index, value);
    return bytes;
}
fn put(bytes: []u8, index: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[index * 4 ..][0..4], value, .little);
}
fn observed() preflight.Raw {
    return .{
        .values = .{ 0x80420100, 0x47f7, 0x10, 0x80, 2, 0, 0x10, 1, 12288, 0x1ffffe00, 0, 0, 0x10e09 },
        .present = 0x1fff,
    };
}

test "GSP WPR metadata keeps first-boot defaults and rejects incomplete or overlapping DMA bindings" {
    const descriptor = descriptorFixture();
    const input = wpr.Input{ .chip_id = 0x176, .raw = observed(), .image_bytes = wpr.image_bytes, .descriptor = &descriptor, .signature_bytes = 4096 };
    const prepared = try wpr.prepare(&input);
    const template = &prepared.unbound_template;
    try t.expectEqual(@as(u64, 0xdc3aae21371a60b3), word(template, 0));
    try t.expectEqual(@as(u64, 1), word(template, 8));
    for ([_]usize{ 16, 32, 72 }) |offset| try t.expectEqual(@as(u64, 0), word(template, offset));
    try t.expectEqual(@as(u64, 63541248), word(template, 24));
    try t.expectEqual(@as(u64, 24576), word(template, 40));
    try t.expectEqual(@as(u64, 6144), word(template, 48));
    try t.expectEqual(@as(u64, 2048), word(template, 56));
    try t.expectEqual(@as(u64, 0), word(template, 64));
    try t.expectEqual(@as(u64, 4096), word(template, 80));
    try t.expect(std.mem.allEqual(u8, template[200..], 0));
    const need = try radix.requirements(input.image_bytes);
    // Explicitly synthetic, unordered physical spans, including data beyond
    // the root page. No released OssiPC address is reused as a live binding.
    const good = [_]radix.Segment{
        .{ .address = 0x200000000, .bytes = 4096 },
        .{ .address = 0x100000000, .bytes = need.allocation_bytes - 4096 },
    };
    const binding = wpr.Bindings{
        .gsp_segments = &good,
        .boot_image = .{ .address = 0x300000000, .bytes = 24576 },
        .signature = .{ .address = 0x300006000, .bytes = 4096 },
    };
    const encoded = try wpr.encode(&input, &binding);
    try t.expectEqual(good[0].address, word(&encoded, 16));
    try t.expectEqual(binding.boot_image.address, word(&encoded, 32));
    try t.expectEqual(binding.signature.address, word(&encoded, 72));
    try t.expect(std.mem.allEqual(u8, encoded[200..], 0));
    var queue = binding;
    queue.crash_queue = .{ .address = 0x300007000, .bytes = 16384 };
    const crash = try wpr.encode(&input, &queue);
    try t.expectEqual(queue.crash_queue.?.address, word(&crash, 224));
    try t.expectEqual(@as(u32, 16384), std.mem.readInt(u32, crash[232..236], .little));
    try t.expect(std.mem.allEqual(u8, crash[200..224], 0));
    try t.expect(std.mem.allEqual(u8, crash[236..], 0));
    for (0..15) |case| {
        var spans = good;
        var bad = queue;
        bad.gsp_segments = &spans;
        const failure: anyerror = switch (case) {
            0 => blk: {
                bad.gsp_segments = &.{};
                break :blk error.Segments;
            },
            1 => blk: {
                spans[0].address = 0;
                break :blk error.Address;
            },
            2 => blk: {
                spans[1].address = radix.dma_mask - 4095;
                break :blk error.Address;
            },
            3 => blk: {
                spans[0].address += 1;
                break :blk error.Alignment;
            },
            4 => blk: {
                spans[1].bytes -= 4096;
                break :blk error.Capacity;
            },
            5 => blk: {
                spans[1].bytes += 4096;
                break :blk error.Capacity;
            },
            6 => blk: {
                spans[0].address = spans[1].address;
                break :blk error.Overlap;
            },
            7 => blk: {
                bad.boot_image.bytes = 20480;
                break :blk error.WrongSize;
            },
            8 => blk: {
                bad.signature.bytes = 8192;
                break :blk error.SignatureSize;
            },
            9 => blk: {
                bad.signature.address = bad.boot_image.address + 4096;
                break :blk error.Overlap;
            },
            10 => blk: {
                bad.signature.address = spans[1].address + 8192;
                break :blk error.Overlap;
            },
            11 => blk: {
                bad.crash_queue.?.address = bad.boot_image.address;
                break :blk error.Overlap;
            },
            12 => blk: {
                bad.crash_queue.?.bytes = 1 << 32;
                break :blk error.CrashQueueSize;
            },
            13 => blk: {
                bad.crash_queue.?.address = radix.dma_mask - 4095;
                break :blk error.Address;
            },
            else => blk: {
                bad.boot_image.address += 1;
                break :blk error.Alignment;
            },
        };
        try t.expectError(failure, wpr.encode(&input, &bad));
    }
    var changed = input;
    changed.image_bytes += 1;
    try t.expectError(error.ImageSize, wpr.prepare(&changed));
    changed = input;
    changed.signature_bytes = 0;
    try t.expectError(error.SignatureSize, wpr.prepare(&changed));
    var broken = descriptor;
    broken[48] ^= 1;
    changed = input;
    changed.descriptor = &broken;
    try t.expectError(error.WrongHash, wpr.prepare(&changed));
    changed = input;
    changed.raw.put(.wpr_lo, 0x1000);
    changed.raw.put(.wpr_hi, 0x2000);
    try t.expectError(error.WprActive, wpr.prepare(&changed));
    try t.expectEqualDeep(prepared, try wpr.prepare(&input));
}

test "GSP production boot descriptor admission rejects truncation, overlap and wrong artifacts" {
    const good = descriptorFixture();
    const info = try boot.inspect(&good, 24576);
    try t.expectEqual(@as(u32, 6144), info.monitor_code.offset);
    try t.expectEqual(@as(u32, 10496), info.monitor_code.bytes);
    try t.expectEqual(@as(u32, 2048), info.monitor_data.offset);
    try t.expectEqual(@as(u32, 0), info.manifest.offset);
    for (0..good.len) |length| try t.expectError(error.WrongSize, boot.inspect(good[0..length], 24576));
    const Case = struct { index: usize, value: u32, failure: anyerror };
    for ([_]Case{
        .{ .index = 0, .value = 4, .failure = error.DescriptorVersion },
        .{ .index = 1, .value = 0xfffffff0, .failure = error.Bounds },
        .{ .index = 2, .value = 0, .failure = error.Bounds },
        .{ .index = 3, .value = 24576, .failure = error.Bounds },
        .{ .index = 4, .value = 0xffffffff, .failure = error.Bounds },
        .{ .index = 8, .value = 2048, .failure = error.Overlap },
        .{ .index = 10, .value = 0, .failure = error.Overlap },
        .{ .index = 12, .value = 24576, .failure = error.Bounds },
        .{ .index = 14, .value = 0, .failure = error.UnsupportedDescriptor },
        .{ .index = 19, .value = 24577, .failure = error.Bounds },
        .{ .index = 20, .value = 1, .failure = error.UnsupportedDescriptor },
    }) |case| {
        var bytes = good;
        put(&bytes, case.index, case.value);
        try t.expectError(case.failure, boot.inspect(&bytes, 24576));
    }
    for ([_]usize{ 5, 6, 7, 15, 16, 17, 18 }) |index| {
        var bytes = good;
        put(&bytes, index, 1);
        try t.expectError(error.UnsupportedDescriptor, boot.inspect(&bytes, 24576));
    }
    try t.expectError(error.Bounds, boot.inspect(&good, 24575));
    try t.expectError(error.WrongSize, boot.inspect(&good, 0));
    var fake_image: [boot.image.bytes]u8 = @splat(0);
    try t.expectError(error.WrongHash, boot.verify(&fake_image, &good));
    try t.expectError(error.WrongSize, boot.verify(fake_image[0..24575], &good));
    // The actual admitted production files are exercised by inspect-gsp-layout.
}

test "GA106 first boot keeps WPR layout in the prescribed top 256 MB and never reuses active WPR" {
    const raw = observed();
    const image_bytes = 63541248;
    const plan = try layout.firstBoot(0x176, &raw, image_bytes, 24576);
    // Independent pinned-RM calculation for OssiPC's actual 12 GB observation.
    try t.expectEqual(@as(u64, 0x300000000), plan.fb_bytes);
    try t.expectEqual(@as(?u64, 0x10e0000), plan.current_vga_base);
    try t.expect(plan.vga_relocation_required);
    try t.expectEqual(@as(u64, 0x2fffe0000), plan.vga.offset);
    try t.expectEqual(@as(u64, 0x2ffee0000), plan.frts.offset);
    try t.expectEqual(@as(u64, 0x2ffeda000), plan.boot.offset);
    try t.expectEqual(@as(u64, 0x2fc240000), plan.firmware.offset);
    try t.expectEqual(@as(u64, 0x2f4200000), plan.heap.offset);
    try t.expectEqual(@as(u64, 128 * layout.mb), plan.heap.bytes);
    try t.expectEqual(@as(u64, 0x2f4100000), plan.wpr.offset);
    try t.expectEqual(@as(u64, 0x2f4000000), plan.reserved.offset);
    try t.expectEqual(@as(u64, 192 * layout.mb), plan.reserved.bytes);
    try t.expectEqual(@as(u64, 192 * layout.mb), plan.heap_limit_bytes);
    try t.expectEqualDeep(raw, observed());
    const Case = struct { reg: preflight.Register, value: u32, failure: anyerror };
    for ([_]Case{
        .{ .reg = .fb_mb, .value = 255, .failure = error.PrescrubbedCapacity },
        .{ .reg = .fb_mb, .value = (1 << 20) + 1, .failure = error.Framebuffer },
        .{ .reg = .vga, .value = 0xbadf0000, .failure = error.ProtectedRegister },
        .{ .reg = .engine, .value = 1, .failure = error.EngineState },
        .{ .reg = .cpuctl, .value = 0, .failure = error.EngineState },
        .{ .reg = .dmacmd, .value = 3, .failure = error.EngineState },
        .{ .reg = .bcr, .value = 0x11, .failure = error.EngineState },
        .{ .reg = .riscv_cpuctl, .value = 0x80, .failure = error.EngineState },
        .{ .reg = .hwcfg2, .value = 0x1400, .failure = error.EngineState },
    }) |case| {
        var changed = raw;
        changed.put(case.reg, case.value);
        try t.expectError(case.failure, layout.firstBoot(0x176, &changed, image_bytes, 24576));
    }
    var changed = raw;
    changed.put(.wpr_lo, 0x1000);
    changed.put(.wpr_hi, 0x2000);
    try t.expectError(error.WprActive, layout.firstBoot(0x176, &changed, image_bytes, 24576));
    try t.expectError(error.UnsupportedChip, layout.firstBoot(0x172, &raw, image_bytes, 24576));
    for ([_]u64{ 0, 64 * layout.mb + 1, std.math.maxInt(u64) }) |size|
        try t.expectError(error.ImageSize, layout.firstBoot(0x176, &raw, size, 24576));
    for ([_]u64{ 0, layout.mb + 1, std.math.maxInt(u64) }) |size|
        try t.expectError(error.ImageSize, layout.firstBoot(0x176, &raw, image_bytes, size));
    // Exercise alignment padding, the 40-bit address limit, heap clamping,
    // and the absence of a display/VGA block using relational range checks.
    for ([_]u32{ 256, 10 * 1024, 10 * 1024 + 1, 12 * 1024, 1 << 20 }) |fb_mb| {
        for ([_]u32{ 0, 1, 2, 3 }) |mode| {
            changed = raw;
            changed.put(.fb_mb, fb_mb);
            const fb = @as(u64, fb_mb) * layout.mb;
            if (mode == 1) changed.put(.vga, @as(u32, @intCast((fb - 0x20000) >> 16)) << 8 | 8);
            if (mode == 2) changed.put(.vga, @as(u32, @intCast((fb - 0x30000) >> 16)) << 8 | 8);
            if (mode == 3) {
                changed.put(.display_fuse, 1);
                changed.present &= ~(@as(u16, 1) << @intFromEnum(preflight.Register.vga));
            }
            const candidate = try layout.firstBoot(0x176, &changed, image_bytes, 24576);
            const ranges = [_]layout.Range{ candidate.non_wpr_heap, candidate.metadata_reservation, candidate.heap, candidate.firmware, candidate.boot, candidate.frts, candidate.vga };
            try t.expect(candidate.reserved.offset >= candidate.prescrubbed.offset);
            try t.expectEqual(fb, candidate.reserved.end());
            try t.expectEqual(candidate.vga.offset & ~@as(u64, 0x1ffff), candidate.wpr.end());
            for (ranges, 0..) |range, index| {
                try t.expect(range.bytes > 0 and range.end() <= fb);
                if (index > 0) try t.expect(ranges[index - 1].end() <= range.offset);
            }
            try t.expect(candidate.heap.bytes >= layout.min_heap_bytes);
            try t.expect(candidate.heap.bytes <= candidate.heap_limit_bytes);
            try t.expectEqual(mode == 0, candidate.vga_relocation_required);
            if (mode == 3) try t.expectEqual(@as(?u64, null), candidate.current_vga_base);
            if (fb_mb == 1 << 20) try t.expectEqual(candidate.heap_limit_bytes, candidate.heap.bytes);
        }
    }
}
