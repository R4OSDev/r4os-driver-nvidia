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
    try checkGraphics();
    try checkGraphicsContexts();
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

fn checkGraphicsContexts() !void {
    const gr = @import("gsp_gr_context.zig");
    const context = @import("gsp_context_wire.zig");
    const reference = @embedFile("fixtures/gr-context-570.144.bin");
    const plan = try gr.Plan.decode(reference[0..gr.info_bytes]);
    try t.expect(plan.count == 9 and plan.buffers[0].bytes == 0x58000 and plan.buffers[4].alignment == 0x200000);
    var config: wire.Config = .{ .context = .{ .epoch = 7, .client = 1, .device = 2, .subdevice = 3,
        .vaspace = 4, .group = 5, .share = 6, .internal_client = 9, .internal_subdevice = 10 },
        .handle = 7, .rm_engine = 1, .runqueue = 0, .address = 0x50000000, .instance = 0x10000000,
        .userd = 0x8000004000, .methods = 0x30000000, .method_bytes = 0x6000, .system_userd = true,
        .engine = .graphics, .object_handle = 8, .object_class = 0xc797 };
    var request: [wire.max_bytes]u8 = undefined;
    for ([_]bool{true, false}, 0..) |golden_context, variant| {
        var promotion: gr.Promotion = .{ .golden = golden_context };
        for (plan.buffers[0..plan.count], 0..) |requirement, i| {
            if (!golden_context and requirement.id == 11) continue;
            const initialize = requirement.initialize and (golden_context or !requirement.global);
            const nonmapped = initialize and requirement.id == 10;
            promotion.entries[promotion.count] = .{ .id = requirement.id, .initialize = initialize, .nonmapped = nonmapped,
                .physical = if (initialize) 0x40000000 + i * 0x1000000 + (if (golden_context) @as(u64, 0) else 0x30000000) else 0,
                .address = if (nonmapped) 0 else 0x20000000 + i * 0x1000000 + (if (!golden_context and !requirement.global) @as(u64, 0x40000000) else 0),
                .bytes = if (initialize) requirement.bytes else 0 };
            promotion.count += 1;
        }
        config.graphics = promotion;
        const data = try wire.encode(config, .promote_graphics, &request);
        try t.expectEqualSlices(u8, reference[gr.info_bytes + variant * 560..][0..560], data[24..]);
        const flags = reference[2784..];
        try t.expect(wire.word(data, 4) == config.context.subdevice and wire.word(data, 8) == wire.word(flags, 20));
        var reply_bytes = request;
        var record: message.Record = .{ .shape = .{ .message_bytes = 664, .checksum_bytes = 664, .storage_bytes = 4096, .elements = 1 },
            .queue_sequence = 0, .rpc = .{ .function = 76, .result = 0 }, .payload = &reply_bytes };
        try t.expect((try wire.decode(config, .promote_graphics, data, record)) == .ok);
        reply_bytes[102] ^= 1; try t.expectError(error.Payload, wire.decode(config, .promote_graphics, data, record)); reply_bytes[102] ^= 1;
        record.payload = reply_bytes[0..24]; try t.expectError(error.Payload, wire.decode(config, .promote_graphics, data, record));
        std.mem.writeInt(u32, reply_bytes[12..16], 0x57, .little);
        try t.expect((try wire.decode(config, .promote_graphics, data, record)).rejected == 0x57);
        const alloc = try wire.encode(config, .allocate, &request);
        try t.expect(wire.word(alloc, 52) == wire.word(flags, if (golden_context) 4 else 0));
        try t.expect(wire.word(alloc, 276) == wire.word(flags, if (golden_context) 12 else 8));
    }
    var info_request: [context.max_bytes]u8 = undefined;
    const query = try context.encode(config.context, 1, 0, .graphics_info, &info_request);
    try t.expect(query.len == 1688 and wire.word(query, 0) == 9 and wire.word(query, 4) == 10 and
        wire.word(query, 8) == wire.word(reference, 2800) and wire.word(query, 16) == 1664);
    var malformed = reference[0..1664].*;
    std.mem.writeInt(u32, malformed[4..8], 3, .little);
    try t.expectError(error.Bounds, gr.Plan.decode(&malformed));
    std.mem.writeInt(u32, malformed[0..4], 0, .little);
    try t.expectError(error.Unsupported, gr.Plan.decode(&malformed));
}

fn checkGraphics() !void {
    const gr = @import("gsp_gr_wire.zig");
    const reference = @embedFile("fixtures/graphics-570.144.bin");
    var config: wire.Config = .{ .context = .{ .epoch = 7, .client = 1, .device = 2, .subdevice = 3,
        .vaspace = 4, .group = 5, .share = 6 }, .handle = 7, .rm_engine = 1, .runqueue = 0,
        .address = 0x50000000, .instance = 0x10000000, .userd = 0x8000004000, .methods = 0x30000000,
        .method_bytes = 0x6000, .system_userd = true, .engine = .graphics, .object_handle = 8, .object_class = 0xc797 };
    var request: [wire.max_bytes]u8 = undefined;
    const data = try wire.encode(config, .allocate_graphics, &request);
    try t.expect(data.len == 48 and wire.word(data, 4) == config.handle and wire.word(data, 8) == config.object_handle and
        wire.word(data, 12) == gr.class and wire.word(data, 20) == 16);
    try t.expectEqualSlices(u8, reference[0..16], data[32..48]);
    var reply = data[0..48].*;
    var record: message.Record = .{ .shape = .{ .message_bytes = 128, .checksum_bytes = 128, .storage_bytes = 4096, .elements = 1 },
        .queue_sequence = 0, .rpc = .{ .function = 103, .result = 0 }, .payload = &reply };
    std.mem.writeInt(u32, reply[44..48], 0x81234567, .little);
    try t.expectEqual(@as(u32, 0x81234567), (try wire.decode(config, .allocate_graphics, data, record)).ok);
    reply[36] = 1;
    try t.expectError(error.Payload, wire.decode(config, .allocate_graphics, data, record));
    reply[36] = 0; record.payload = reply[0..32];
    try t.expectError(error.Payload, wire.decode(config, .allocate_graphics, data, record));
    std.mem.writeInt(u32, reply[16..20], 0x57, .little);
    try t.expectEqual(@as(u32, 0x57), (try wire.decode(config, .allocate_graphics, data, record)).rejected);
    config.object_class = 0xc697;
    try t.expectError(error.Unsupported, wire.encode(config, .allocate_graphics, &request));
    config.object_class = gr.class; config.rm_engine = 19;
    try t.expectError(error.Unsupported, wire.encode(config, .allocate_graphics, &request));
    config.rm_engine = 1;
    try t.expectError(error.Unsupported, wire.encode(config, .allocate_copy, &request));
    const barrier = try gr.encode(gr.class, .barrier, 0x50002200, 1);
    try t.expectEqualSlices(u8, reference[16..], std.mem.sliceAsBytes(barrier.slice()));
    try t.expectError(error.Unsupported, gr.encode(0xc697, .barrier, 0x50002200, 1));
    try t.expectError(error.Bounds, gr.encode(gr.class, .barrier, 0x10000000000, 1));
    try t.expectError(error.Bounds, gr.encode(gr.class, .barrier, 0x50002200, 0));
    for ([_]u16{0x162,0x176,0x192,0x1b2}, [_]u32{0xc597,0xc797,0xc997,0xcd97}) |chip, class| {
        config.chip_id = chip; config.object_class = class;
        const allocation = try wire.encode(config, .allocate_graphics, &request);
        try t.expectEqual(class, wire.word(allocation, 12));
        const completion = try gr.encode(class, .barrier, 0x50002200, 7);
        try t.expectEqual(class, completion.data[1]);
        try t.expectEqual(@as(u32,0x1000f010), completion.data[10]);
        config.object_class = if (class == 0xc797) 0xc997 else 0xc797;
        try t.expectError(error.Unsupported, wire.encode(config, .allocate_graphics, &request));
    }
}
