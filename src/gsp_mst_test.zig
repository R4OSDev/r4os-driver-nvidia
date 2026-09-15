//! Extends the existing transport test group; no additional gate or guest run.
const std = @import("std");
const t = std.testing;
const wire = @import("gsp_mst_wire.zig");
const aux = @import("gsp_aux_wire.zig");
const transport = @import("gsp_mst_transport.zig");
pub fn check() !void {
    const original = @embedFile("fixtures/mst-wire-570.144.bin");
    try t.expect(original.len == 1308);
    for (0..8) |index| {
        const vector = original[124 + index * 148 ..][0..148];
        try t.expectEqual(vector[2], try wire.headerCrc(vector[4..20], @as(usize, vector[0]) * 8 - 4));
        try t.expectEqual(vector[3], wire.bodyCrc(vector[20..][0..vector[1]]));
        var header = vector[4..20].*;
        header[vector[0] - 1] |= vector[2];
        // The CRC corpus also includes a CRC-only payload. Its checksum is
        // defined, but a protocol message needs at least one body byte.
        if (header[vector[0] - 2] & 63 < 2) {
            try t.expectError(error.Payload, wire.decodeHeader(header[0..vector[0]]));
            continue;
        }
        const parsed = try wire.decodeHeader(header[0..vector[0]]);
        var encoded: [16]u8 = @splat(0xa5);
        try t.expectEqual(vector[0], try wire.encodeHeader(parsed, &encoded));
        try t.expectEqualSlices(u8, header[0..vector[0]], encoded[0..vector[0]]);
        try t.expect(encoded[vector[0]] == 0xa5);
    }
    try fragmentation();
    try messages();
    try exchange();
    try controls(original[0..124]);
    try budgets();
    try upstream();
    try topology();
    try checkRegistry();
}
fn checkRegistry() !void {
    const ids = @import("gsp_mst_registry.zig");
    const graph = &TopologyModel.graph;
    var registry: ids.Registry = .{};
    try registry.synchronize(graph, 2, 0, 12);
    try t.expect(registry.slots[0].state == .reserved and registry.slots[1].state == .reserved);
    const first = try registry.handle(0);
    const second = try registry.handle(1);
    var serial = graph.completion_receipt + 1;
    const Resource = struct { dynamic: bool = true, root_port_id: u32 = 4, index: u32 = 2, kind: u32 = 2, protocol: u32 = 8, location: u32 = 0 };
    for ([_]ids.Handle{ first, second }, 0..) |handle, index| {
        const query = try registry.allocate(handle);
        try t.expect(query.allocate == 4);
        graph.generation += 1;
        graph.completion_receipt += 1;
        try t.expectError(error.Pending, registry.synchronize(graph, 2, 0, 12));
        graph.generation -= 1;
        graph.completion_receipt -= 1;
        try registry.allocated(handle, @as(u32, 16) << @as(u5, @intCast(index)), serial);
        serial += 1;
        try t.expectError(error.Stale, registry.resource(handle, Resource{ .dynamic = false }, serial));
        try registry.resource(handle, Resource{}, serial);
        serial += 1;
        if (index == 1) try registry.publish(handle, graph.generation);
    }
    const Mode = struct { epoch: u64 = 7, output_generation: u64 = 11, head: u32 = 1, window: u32 = 2, signal: struct { display_id: u32 = 16, sor: u32 = 2 } = .{} };
    const Link = struct {
        valid: bool = true,
        pub fn complete(self: @This()) bool {
            return self.valid;
        }
    };
    const Displayed = struct { boot_mode: ?Mode = .{}, image: struct { dma: u32 = 500 } = .{}, core_point: u64 = 10, window_point: u64 = 11, link: ?Link = .{} };
    const displayed: Displayed = .{};
    const route: ids.RouteHold = .{ .head = 1, .window = 2 };
    try registry.holdRoute(first, route);
    try t.expectError(error.Retained, registry.holdRoute(second, route));
    const stream_lease: ids.StreamLease = .{ .epoch = 7, .root = 4, .serial = 1 };
    try t.expectError(error.Duplicate, registry.holdStreams(stream_lease, &.{ first, first }));
    try t.expect(registry.slots[0].stream_lease == null);
    try registry.holdStreams(stream_lease, &.{ first, second });
    try t.expectError(error.Retained, registry.holdStreams(stream_lease, &.{first}));
    try registry.activated(first, displayed);
    try t.expect(!registry.slots[0].published and registry.slots[0].image != null);
    try registry.publish(first, graph.generation);
    try t.expectError(error.Stale, registry.activated(first, displayed)); // A stale frame is not a new active image.
    try t.expectError(error.Retained, registry.free(first));
    // A later real root capture removed both leaves. Assigned IDs and the
    // current image remain owned throughout unpublication and detach.
    graph.generation += 1;
    graph.completion_receipt = serial + 1;
    graph.sink_count = 0;
    graph.edge_count = 0;
    graph.branch_count = 1;
    graph.branches[0].descriptor.?.count = 1;
    try registry.synchronize(graph, 2, 0, 12);
    try t.expect(registry.slots[0].state == .retiring and registry.slots[0].display_id == 16 and registry.slots[0].image != null);
    // A posted flip may complete while HPD recapture is retiring this ID.
    // Its last image must replace the previous one before any release.
    var latest = displayed; latest.window_point += 1;
    try registry.activated(first, latest);
    try registry.unpublish(first);
    try t.expectError(error.Retained, registry.free(first));
    const Retired = struct { epoch: u64, image: Displayed, core_point: u64, window_point: u64, observed_ns: u64, link_stop_receipt: u64 };
    var retired: Retired = .{ .epoch = 7, .image = latest, .core_point = 11, .window_point = 13, .observed_ns = 1000, .link_stop_receipt = serial + 10 };
    retired.window_point = 12;
    try t.expectError(error.Stale, registry.detached(first, retired));
    retired.window_point = 13;
    retired.image.image.dma = 501;
    try t.expectError(error.Stale, registry.detached(first, retired));
    retired.image.image.dma = 500;
    try registry.detached(first, retired);
    try t.expectError(error.Retained, registry.free(first));
    try t.expectError(error.Retained, registry.releaseRoute(first, route));
    var wrong_lease = stream_lease; wrong_lease.serial += 1;
    try t.expectError(error.Stale, registry.releaseStreams(wrong_lease, &.{ first, second }));
    try t.expect(registry.slots[0].stream_lease != null and registry.slots[1].stream_lease != null);
    try registry.releaseStreams(stream_lease, &.{ first, second });
    try t.expectError(error.Retained, registry.free(first));
    try registry.releaseRoute(first, route);
    try t.expect((try registry.free(first)).free == 16);
    try t.expect(registry.slots[0].display_id == 16 and registry.slots[0].pending == .free);
    try t.expectError(error.Stale, registry.freed(first, retired.link_stop_receipt));
    try registry.freed(first, retired.link_stop_receipt + 1);
    try t.expectError(error.Stale, registry.free(first));
    try registry.unpublish(second);
    try t.expect((try registry.free(second)).free == 32);
    try registry.freed(second, retired.link_stop_receipt + 2);
    for (&registry.slots) |*slot| try t.expect(slot.state == .vacant and slot.display_id == 0);
}
const TopologyModel = struct {
    var graph: @import("gsp_mst_topology.zig").Graph = .{};
};
fn topology() !void {
    const topo = @import("gsp_mst_topology.zig");
    var edid: [128]u8 = @splat(0);
    @memcpy(edid[0..8], &[_]u8{ 0, 255, 255, 255, 255, 255, 255, 0 });
    edid[8] = 0x49;
    edid[9] = 0xcf;
    edid[18] = 1;
    edid[19] = 4;
    edid[20] = 0xa5;
    edid[24] = 2;
    @memset(edid[38..54], 1);
    for ([_]usize{ 72, 90, 108 }) |at| edid[at + 3] = 0x10;
    @memcpy(edid[54..72], &[_]u8{ 2, 0x3a, 0x80, 0x18, 0x71, 0x38, 0x2d, 0x40, 0x58, 0x2c, 0x45, 0, 0, 0, 0, 0, 0, 0x1a });
    for (edid[0..127]) |byte| edid[127] -%= byte;
    const Case = enum { normal, uninitialized_guid, changed_edid, changed_branch, rejected_edid };
    for (std.enums.values(Case)) |case| {
        const graph = &TopologyModel.graph;
        var builder = try topo.Builder.init(graph, 7, 11, 4, @splat(9), 10, 1000);
        var root_guid: wire.Guid = @splat(if (case == .uninitialized_guid) 0 else 9);
        var serial: u64 = 10;
        var writes: usize = 0;
        var failed = false;
        for (1..100) |now| {
            const action = try builder.prepare(11, now) orelse break;
            try t.expectError(error.Pending, builder.prepare(11, now));
            var response: topo.Observation = undefined;
            var mutated = edid;
            var caps: [16]u8 = @splat(0);
            caps[0] = 0x14;
            caps[1] = 30;
            caps[2] = 0x84;
            switch (action) {
                .root_aux => |op| {
                    try t.expect(case == .uninitialized_guid and op == .guid_write and writes == 0 and !graph.coherent);
                    root_guid = op.guid_write;
                    writes += 1;
                    response = .{ .root_aux = .{ .count = 16 } };
                },
                .sideband => |query| {
                    const downstream = query.route.depth != 0;
                    const request = query.request;
                    switch (request) {
                        .link_address => {
                            var branch: wire.Branch = .{ .guid = if (downstream) @splat(20) else root_guid, .count = if (downstream) 2 else 3 };
                            branch.ports[0] = .{ .number = 0, .input = true, .peer = .upstream, .messaging = true, .connected = true };
                            branch.ports[1] = .{ .number = if (downstream) 3 else 1, .peer = if (downstream) .sink else .branch, .messaging = !downstream, .connected = true, .guid = @splat(if (downstream) 30 else 20), .streams = 1, .sinks = 1 };
                            if (!downstream) branch.ports[2] = .{ .number = 2, .peer = .sink, .connected = true, .guid = @splat(31), .streams = 1, .sinks = 1 };
                            if (case == .changed_branch and builder.stage == .verify) branch.ports[1].connected = false;
                            response = .{ .sideband = .{ .branch = branch } };
                        },
                        .enum_path => |port| response = .{ .sideband = .{ .path = .{ .port = @intCast(port), .streams = 1, .fec = false, .total_pbn = 2000, .free_pbn = 1800 } } },
                        .dpcd_read => |query_caps| response = .{ .sideband = .{ .data = .{ .port = @intCast(query_caps.port), .bytes = &caps } } },
                        .edid => |query_edid| {
                            try t.expect(query_edid.block == 0);
                            if (case == .changed_edid and builder.stage == .edid_verify) mutated[10] ^= 1;
                            response = if (case == .rejected_edid and !downstream) .{ .sideband = .{ .nack = .{ .op = .i2c_read, .guid = root_guid, .reason = 8, .data = 0 } } } else .{ .sideband = .{ .data = .{ .port = @intCast(query_edid.port), .bytes = &mutated } } };
                        },
                        else => return error.TestUnexpectedResult,
                    }
                },
            }
            serial += 1;
            builder.consume(11, response, serial, now) catch |err| {
                try t.expect(err == error.Stale and (case == .changed_edid or case == .changed_branch));
                try t.expect(!graph.coherent and graph.completion_receipt == 0);
                failed = true;
                break;
            };
        }
        if (case == .changed_edid or case == .changed_branch) {
            try t.expect(failed);
            continue;
        }
        try t.expect(!failed and graph.coherent and graph.completion_receipt == serial and builder.stage == .complete);
        try t.expect(graph.branch_count == 2 and graph.edge_count == 3 and graph.sink_count == 2);
        const expected_state: @TypeOf(graph.sinks[0].state) = if (case == .rejected_edid) .missing else .valid;
        errdefer std.debug.print("MST topology case={s} sinks={s}/{s} warnings={x}/{x}\n", .{ @tagName(case), @tagName(graph.sinks[0].state), @tagName(graph.sinks[1].state), graph.sinks[0].report.warnings, graph.sinks[1].report.warnings });
        try t.expectEqual(expected_state, graph.sinks[0].state);
        try t.expectEqual(@as(@TypeOf(expected_state), .valid), graph.sinks[1].state);
        try t.expect(graph.sinks[1].path_count == 2 and graph.sinks[1].path[0] == 0 and graph.sinks[1].path[1] == 2);
        try t.expect(graph.sinks[1].report.mode_count == 1 and graph.sinks[1].report.modes[0].width == 1920);
        if (case == .uninitialized_guid) try t.expect(writes == 1 and std.mem.eql(u8, &root_guid, &graph.branches[0].descriptor.?.guid));
    }
}
fn upstream() !void {
    const up = @import("gsp_mst_upstream.zig");
    const route = try (wire.Route{}).child(3);
    var body: [19]u8 = @splat(0);
    body[0] = 2;
    body[1] = 0x40;
    @memset(body[2..18], 9);
    body[18] = 0x33;
    var sender: wire.Sender = .{ .route = route, .sequence = 1 };
    var incoming: [48]u8 = @splat(0);
    const count = (try sender.next(&body, &incoming)).?;
    try inbound(incoming[0..count]);
    for ([_]bool{ true, false }) |accepted| {
        var work = try up.Work.init(4, 11, 1000);
        var outgoing: [48]u8 = @splat(0);
        var sent: usize = 0;
        var serial: u64 = 0;
        var clear = false;
        for (1..20) |now| {
            if (work.stage == .received) {
                const notice = (try work.notification(11)).connection;
                try t.expect(notice.port == 4 and notice.connected and notice.peer == .sink and clear);
                try t.expect(std.meta.eql(route, work.assembly.?.route));
                try work.respond(11, now, accepted);
            }
            const query = try work.prepare(11, now) orelse {
                try t.expect(work.stage == .complete);
                break;
            };
            var reply: aux.Reply = .{ .count = aux.length(query.operation) };
            switch (query.operation.mst) {
                .irq => |irq| if (irq.ack) |bits| {
                    try t.expect(bits == 0x20);
                    clear = true;
                } else {
                    reply.data[0] = 0x30;
                },
                .mailbox => |box| if (box.box == .up_request) {
                    @memcpy(reply.data[0..box.count], incoming[box.offset..][0..box.count]);
                } else {
                    try t.expect(clear and box.box == .up_reply and box.offset == sent);
                    @memcpy(outgoing[sent..][0..box.count], box.data[0..box.count]);
                    sent += box.count;
                },
                else => return error.TestUnexpectedResult,
            }
            serial += 1;
            try work.consume(11, reply, serial, now);
        }
        try t.expect(work.stage == .complete and work.down_pending and work.received_receipt != 0 and work.response_receipt > work.received_receipt);
        const frame = try wire.decode(outgoing[0..sent]);
        try t.expectEqualSlices(u8, &.{if (accepted) @as(u8, 2) else 0x82}, frame.body);
        try t.expect(std.meta.eql(route, frame.header.route) and frame.header.sequence == 1);
        try t.expectError(error.Stale, work.notification(12));
    }
    var empty = try up.Work.init(4, 11, 100);
    _ = (try empty.prepare(11, 1)).?;
    try empty.consume(11, .{ .count = 1, .data = .{0x10} ++ @as([15]u8, @splat(0)) }, 1, 2);
    try t.expect(empty.stage == .empty and empty.down_pending and empty.response_receipt == 0);
    var cancelled = try up.Work.init(4, 11, 100);
    _ = (try cancelled.prepare(11, 1)).?;
    cancelled.invalidate();
    try cancelled.consume(12, .{ .count = 1 }, 1, 2);
    try t.expect(cancelled.pending == null and cancelled.received_receipt == 0 and cancelled.stage == .cancelled);
}
fn controls(original: []const u8) !void {
    const control = @import("gsp_mst_control.zig");
    const queries = [_]control.Query{ .{ .allocate = 4 }, .{ .free = 16 }, .{ .stream = .{ .head = 1, .sor = 2, .link = 1, .hblank = 777, .vblank = 123, .start = 1, .end = 22, .pbn = 1320, .timeslice_pbn = 1320 } }, .{ .act = 4 } };
    var output: [85]u8 = @splat(0xa5);
    var at: usize = 0;
    for (queries) |query| {
        const count = try query.encode(&output);
        try t.expectEqualSlices(u8, original[at..][0..count], output[0..count]);
        try t.expect(output[84] == 0xa5);
        if (query == .allocate) {
            try t.expectError(error.Payload, query.decode(0, output[0..count]));
            std.mem.writeInt(u32, output[16..20], 16, .little);
            try t.expect(try query.decode(0, output[0..count]) == 16);
            std.mem.writeInt(u32, output[16..20], 4, .little);
            try t.expectError(error.Payload, query.decode(0, output[0..count]));
            std.mem.writeInt(u32, output[16..20], 3, .little);
            try t.expectError(error.Payload, query.decode(0, output[0..count]));
        } else try t.expect(try query.decode(0, output[0..count]) == 0);
        try t.expectError(error.RmRejected, query.decode(0x57, output[0..count]));
        at += count;
    }
    var stop = queries[2];
    stop.stream.start = 1;
    stop.stream.end = 0;
    stop.stream.pbn = 0;
    stop.stream.timeslice_pbn = 0;
    _ = try stop.encode(&output);
    stop.stream.pbn = 1;
    try t.expectError(error.Descriptor, stop.encode(&output));
    const stream_ref = @embedFile("fixtures/mst-stream-570.144.bin");
    const rate: control.Query = .{ .rate = .{ .head = 1, .sor = 2, .enable = true } };
    try t.expectEqualSlices(u8, stream_ref[0..16], output[0..try rate.encode(&output)]);
    _ = try rate.decode(0, stream_ref[0..16]);
    var rate_check = rate;
    rate_check.rate.immediate = true; rate_check.rate.check = true;
    try t.expectEqualSlices(u8, stream_ref[16..32], output[0..try rate_check.encode(&output)]);
    try t.expectError(error.Pending, rate_check.decode(0, stream_ref[16..32]));
    _ = try rate_check.decode(0, stream_ref[32..48]);
    try t.expectError(error.RmRejected, rate_check.decode(0x57, stream_ref[32..48]));
    @memcpy(output[0..16], stream_ref[32..48]); output[12] ^= 4;
    try t.expectError(error.Payload, rate_check.decode(0, output[0..16]));
    const trigger: control.Query = .{ .trigger = .{ .head = 1, .sor = 2 } };
    try t.expectEqualSlices(u8, stream_ref[48..64], output[0..try trigger.encode(&output)]);
    _ = try trigger.decode(0, stream_ref[48..64]);
    const train: control.Query = .{ .train = .{ .root = 4, .rate = 30, .lanes = 4, .enhanced = true } };
    try t.expectEqualSlices(u8, stream_ref[64..92], output[0..try train.encode(&output)]);
    _ = try train.decode(0, stream_ref[64..92]);
    output[16] = 1;
    try t.expectError(error.LinkTraining, train.decode(0, output[0..28]));
    output[20] = 5;
    const retry = try train.training(0x66, output[0..28]);
    try t.expect(retry.failure == 1 and retry.retry_ms == 5 and retry.status == 0x66);
    try t.expectError(error.Pending, train.decode(0x66, output[0..28]));
    output[4] = 16;
    try t.expectError(error.Payload, train.training(0x66, output[0..28]));
}
fn budgets() !void {
    const payload = @import("gsp_mst_payload.zig");
    const reference = @embedFile("fixtures/mst-budget-570.144.bin");
    for (0..6) |i| {
        const vector = reference[i * 48 ..][0..48];
        const link: payload.Link = .{ .rate = @intCast(word(vector, 12)), .lanes = @intCast(word(vector, 16)) };
        const timing: payload.Timing = .{ .clock = .{ .numerator = word(vector, 0) }, .width = word(vector, 4), .total = word(vector, 8), .bpc = @intCast(word(vector, 20)) };
        if (word(vector, 32) > 63 or word(vector, 24) == 0) {
            try t.expectError(error.Bandwidth, payload.demand(link, timing));
            continue;
        }
        const result = try payload.demand(link, timing);
        try t.expect(result.audio_48k);
        try t.expectEqual(word(vector, 28), result.pbn);
        try t.expectEqual(word(vector, 32), result.slots);
        try t.expectEqual(word(vector, 36), result.hblank);
        try t.expectEqual(word(vector, 40), result.vblank);
        try t.expectEqual(word(vector, 44), result.timeslice_pbn);
    }
    const link: payload.Link = .{ .rate = 30, .lanes = 4 };
    const timing: payload.Timing = .{ .clock = .{ .numerator = 148500000 }, .width = 1920, .total = 2200, .bpc = 8 };
    var paths = [_]payload.Path{ .{ .total_pbn = 3780, .free_pbn = 3780 }, .{ .total_pbn = 1000, .free_pbn = 1000 }, .{ .total_pbn = 1000, .free_pbn = 1000 } };
    var wanted = [_]payload.Wanted{ .{ .display_id = 16, .payload_id = 1, .head = 0, .timing = timing, .path_count = 2 }, .{ .display_id = 32, .payload_id = 2, .head = 1, .timing = timing, .path_count = 2 } };
    wanted[0].path[1] = 1;
    wanted[1].path[1] = 2;
    const both = try payload.plan(link, &paths, &wanted);
    try t.expect(both.count == 2 and both.slots == 18 and both.used_pbn == 1064 and both.allocations[1].start == 10);
    wanted[1].path[1] = 1;
    try t.expectError(error.Bandwidth, payload.plan(link, &paths, &wanted)); // Shared branch exhausted.
    wanted[1].path[1] = 2;
    paths[0].free_pbn = 1000;
    try t.expectError(error.Bandwidth, payload.plan(link, &paths, &wanted)); // Root path exhausted.
    paths[0].owned_pbn = 532;
    _ = try payload.plan(link, &paths, &wanted); // The old owned reservation can be replaced.
    const removed = try payload.plan(link, &paths, wanted[1..]);
    try t.expect(removed.slots == 9 and removed.allocations[0].display_id == 32 and removed.allocations[0].start == 1);
    wanted[1].payload_id = 1;
    try t.expectError(error.Duplicate, payload.plan(link, &paths, &wanted));
    var rational = timing;
    rational.clock = .{ .numerator = 148500000000, .denominator = 1001 };
    try t.expect((try payload.demand(link, rational)).pbn == 531);
}
fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn inbound(packet: []u8) !void {
    const header = try wire.decodeHeader(packet);
    packet[0] &= 0xf0; // Branch forwarding consumed LCR; RAD remains intact.
    packet[header.size() - 1] &= 0xf0;
    packet[header.size() - 1] |= try wire.headerCrc(packet, header.size() * 8 - 4);
}
fn fragmentation() !void {
    const route = try (try (wire.Route{}).child(2)).child(7);
    var source: [512]u8 = undefined;
    for (&source, 0..) |*value, i| value.* = @truncate(i * 23);
    var sender: wire.Sender = .{ .route = route, .sequence = 1 };
    var assembly: wire.Assembly = .{ .route = route, .sequence = 1 };
    var bytes: [49]u8 = @splat(0xa5);
    var fragments: usize = 0;
    while (try sender.next(&source, bytes[0..48])) |count| {
        try t.expect(count <= 48 and bytes[48] == 0xa5);
        try inbound(bytes[0..count]);
        const parsed = try wire.decode(bytes[0..count]);
        const before = assembly;
        var wrong = parsed;
        wrong.header.sequence ^= 1;
        try t.expectError(error.Stale, assembly.consume(wrong));
        try t.expectEqualDeep(before, assembly);
        for (0..count) |length| try t.expectError(error.Bounds, wire.decode(bytes[0..length]));
        bytes[count - 1] ^= 1;
        try t.expectError(error.Payload, wire.decode(bytes[0..count]));
        bytes[count - 1] ^= 1;
        try assembly.consume(parsed);
        if (fragments == 0) try t.expectError(error.Stale, assembly.consume(parsed));
        fragments += 1;
    }
    try t.expect(fragments > 10 and assembly.complete);
    try t.expectEqualSlices(u8, &source, try assembly.body());
    try t.expectError(error.Stale, assembly.consume(try wire.decode(bytes[0 .. (try wire.decodeHeader(&bytes)).size() + (try wire.decodeHeader(&bytes)).payload_bytes])));
    var full: wire.Route = .{ .depth = 14, .ports = @splat(15) };
    try t.expect(full.valid());
    try t.expectError(error.Bounds, full.child(1));
    full.depth = 15;
    try t.expect(!full.valid());
}
fn messages() !void {
    var output: [25]u8 = @splat(0xa5);
    const request: wire.Request = .{ .edid = .{ .port = 3, .block = 2 } };
    const expected = [_]u8{ 0x22, 0x32, 0x30, 1, 1, 0x10, 0x50, 1, 0, 0x10, 0x50, 128 };
    try t.expectEqualSlices(u8, &expected, output[0..try request.encode(&output)]);
    try t.expect(output[12] == 0xa5);
    @memset(&output, 0xa5);
    try t.expectError(error.Bounds, request.encode(output[0..11]));
    try t.expect(std.mem.allEqual(u8, &output, 0xa5));
    var branch: [40]u8 = @splat(0);
    branch[0] = 1;
    @memset(branch[1..17], 9);
    branch[17] = 2;
    branch[18] = 0x90;
    branch[19] = 0xc0; // Input port 0, upstream source.
    branch[20] = 0x32;
    branch[21] = 0x40;
    branch[22] = 0x14;
    @memset(branch[23..39], 0x31);
    branch[39] = 0x11;
    const parsed = (try wire.reply(.link_address, &branch)).branch;
    try t.expect(parsed.count == 2 and parsed.ports[0].input and parsed.ports[1].number == 2 and parsed.ports[1].peer == .sink);
    branch[20] = 0x30;
    try t.expectError(error.Payload, wire.reply(.link_address, &branch)); // Duplicate port.
    branch[20] = 0x32;
    for (0..branch.len) |count| try t.expectError(if (count == 0) error.Stale else if (count < 18) error.Payload else error.Bounds, wire.reply(.link_address, branch[0..count]));
    const allocation: wire.Request = .{ .allocate = .{ .port = 3, .id = 7, .pbn = 600 } };
    try t.expectEqualSlices(u8, &.{ 0x11, 0x31, 7, 2, 0x58, 0 }, output[0..try allocation.encode(&output)]);
    try t.expect((try wire.reply(allocation, &.{ 0x11, 0x30, 7, 2, 0x58 })).allocated.pbn == 600);
    try t.expectError(error.Payload, wire.reply(allocation, &.{ 0x11, 0x30, 7, 2, 0x57 }));
    try t.expectError(error.Payload, wire.reply(.{ .enum_path = 3 }, &.{ 0x10, 0x30, 0, 10, 0, 11 }));
    const path = (try wire.reply(.{ .enum_path = 3 }, &.{ 0x10, 0x35, 6, 0, 5, 0 })).path;
    try t.expect(path.fec and path.streams == 2 and path.total_pbn == 1536 and path.free_pbn == 1280);
    var notify: [20]u8 = @splat(0);
    notify[0] = 0x13;
    notify[1] = 0x35;
    @memset(notify[2..18], 9);
    notify[18] = 2;
    notify[19] = 88;
    try t.expect((try wire.notification(&notify)).resources.available_pbn == 600);
    notify[0] = 2;
    notify[1] = 0x30;
    notify[18] = 0x32;
    const connection = (try wire.notification(notify[0..19])).connection;
    try t.expect(connection.connected and connection.messaging and connection.peer == .branch and !connection.input);
}
fn exchange() !void {
    const request: wire.Request = .{ .edid = .{ .port = 3, .block = 2 } };
    const route = try (wire.Route{}).child(7);
    var body: [131]u8 = undefined;
    body[0] = 0x22;
    body[1] = 3;
    body[2] = 128;
    for (body[3..], 0..) |*byte, i| byte.* = @truncate(i * 17);
    var sender: wire.Sender = .{ .route = route, .sequence = 1 };
    var rx: [48]u8 = @splat(0);
    var rx_count = (try sender.next(&body, &rx)).?;
    try inbound(rx[0..rx_count]);
    var work = try transport.Work.init(4, 11, std.time.ns_per_s, route, 1, request);
    var writes: [48]u8 = @splat(0);
    var count: usize = 0;
    var now: u64 = 1;
    var serial: u64 = 0;
    var clears: usize = 0;
    var deferred = false;
    var saw_wait = false;
    for (0..100) |_| {
        now += std.time.ns_per_ms;
        const query = try work.prepare(11, now) orelse {
            if (work.stage == .complete) break;
            continue;
        };
        try t.expectError(error.Pending, work.prepare(11, now));
        var reply: aux.Reply = .{ .count = aux.length(query.operation) };
        if (!deferred) {
            deferred = true;
            serial += 1;
            try work.consume(11, .{ .kind = .defer_reply }, serial, now);
            try t.expect(try work.prepare(11, now) == null);
            continue;
        }
        var raw: [49]u8 = @splat(0xa5);
        _ = try aux.encode(query, &raw);
        try t.expect(raw[48] == 0xa5);
        const operation = query.operation.mst;
        switch (operation) {
            .mailbox => |value| if (value.box == .down_request) {
                try t.expect(value.offset == count);
                @memcpy(writes[count..][0..value.count], value.data[0..value.count]);
                count += value.count;
            } else {
                try t.expect(value.box == .down_reply and value.offset < rx_count);
                @memcpy(reply.data[0..value.count], rx[value.offset..][0..value.count]);
            },
            .irq => |irq| if (irq.ack) |bits| {
                try t.expect(bits == 0x10);
                clears += 1;
            } else {
                reply.data[0] = if (saw_wait) 0x30 else 0x20;
                saw_wait = true;
            },
            else => return error.TestUnexpectedResult,
        }
        if (!operation.write()) @memcpy(raw[20..36], &reply.data);
        std.mem.writeInt(u32, raw[36..40], reply.count, .little);
        const decoded = try aux.decode(query, 0, raw[0..48]);
        serial += 1;
        try work.consume(11, decoded, serial, now);
        if (operation == .irq and operation.irq.ack != null and work.stage != .complete) {
            rx_count = (try sender.next(&body, &rx)).?;
            try inbound(rx[0..rx_count]);
        }
    }
    try t.expect(work.stage == .complete and clears > 1 and work.up_pending and work.completion_receipt == serial);
    try t.expectEqualSlices(u8, body[3..], (try work.result(11)).data.bytes);
    try t.expectError(error.Stale, work.result(12));
    var expected: [24]u8 = undefined;
    try t.expectEqualSlices(u8, expected[0..try request.encode(&expected)], (try wire.decode(writes[0..count])).body);
    // Invalidating a sent request still consumes its receipt, without a
    // mailbox acknowledgement or result becoming valid for the next branch.
    var cancel = try transport.Work.init(4, 11, 100, .{}, 0, .link_address);
    const pending = (try cancel.prepare(11, 1)).?;
    cancel.invalidate();
    try cancel.consume(12, .{ .count = aux.length(pending.operation) }, 10, 2);
    try t.expect(cancel.pending == null and cancel.stage == .cancelled and cancel.completion_receipt == 0);
    try t.expectError(error.Stale, cancel.result(12));
    var timeout = try transport.Work.init(4, 11, 100, .{}, 0, .link_address);
    try t.expectError(error.Deadline, timeout.prepare(11, 100));
    try t.expectError(error.Query, aux.encode(.{ .display_id = 4, .operation = .{ .mst = .{ .mailbox = .{ .box = .down_request, .offset = 40, .count = 16 } } } }, &writes));
}
