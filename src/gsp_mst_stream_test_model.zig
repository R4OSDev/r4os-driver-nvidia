//! Independent branch/source state for the existing native Device fixture.
//! Replies traverse its real Exchange. Core/Window observations are replayed
//! from submitted push words, never inferred from a requested mode or a flag.
const std = @import("std");
const t = std.testing;
const wire = @import("gsp_mst_wire.zig");
const display = @import("gsp_display_rpc.zig");
const link = @import("gsp_mst_link.zig");
const outputs = @import("gsp_outputs.zig");
const runtime = @import("gsp_runtime.zig");
pub var enabled = false;
pub var root_present = true;
pub var reject_allocate = false;
pub var rejected = false;
pub var core_count: u32 = 0;
pub var act_count: u32 = 0;
var last_core: u64 = 0;
var last_window: u64 = 0;
var active: [8]u32 = @splat(0);
var sources: [8]?@import("gsp_mst_control.zig").Stream = @splat(null);
var slots: [64]u8 = @splat(0);
var pbn: [8]u16 = @splat(0);
var trained: ?@import("gsp_mst_payload.zig").Link = null;
var status: u8 = 0;
var response: [512]u8 = @splat(0);
var response_count: usize = 0;
var sender: ?wire.Sender = null;
var packet: [48]u8 = @splat(0);
var packet_count: usize = 0;
var outgoing: [48]u8 = @splat(0);
pub fn unassigned(snapshot: *outputs.Snapshot) !void {
    enabled = false;
    const serial = snapshot.final_receipt_serial;
    if (serial <= 4 or !snapshot.coherent) return error.IncompleteMstFixtureCapture;
    const resource: display.Resource = .{ .index = 0xffffffff, .kind = 2, .protocol = 8, .location = 0, .dynamic = false,
        .root_port_id = 0, .dcb_index = 27, .vbios_address = 0, .lit_by_vbios = false, .dither_type = 0, .dither_algo = 0 };
    snapshot.count = 2; snapshot.topology.count = 2; snapshot.topology.supported = .{ .displays = 12, .ddc = 12 };
    snapshot.topology.routes[1] = .{ .id = 8, .resource = resource,
        .connectors = .{ .flags = 1, .ddc_partners = 8, .platform = 0, .count = 1,
            .data = .{ .{ .index = 5, .kind = 0x46 }, .{}, .{}, .{} } } };
    snapshot.receivers[1] = .{ .epoch = snapshot.topology.epoch, .client = snapshot.topology.client, .display_id = 8,
        .receipt_serial = serial - 4, .status = .edid_missing, .connected = true, .resource = resource,
        .dp = .{ .dpcd_state = .complete, .receiver = .{ .mst_state = .complete, .mst = true } } };
    snapshot.receivers[1].dp.dpcd[0..7].* = .{ 0x14, 30, 0x84, 0x80, 0, 0, 1 };
}
pub fn install(snapshot: *outputs.Snapshot, store: *outputs.mst.Store) !void {
    enabled = true; root_present = true; rejected = false; reject_allocate = false; core_count = 0; act_count = 0;
    last_core = 0; last_window = 0; active = @splat(0); sources = @splat(null); slots = @splat(0); pbn = @splat(0);
    trained = null; status = 0; sender = null; packet_count = 0; outgoing = @splat(0);
    const captured_heads = snapshot.topology.head_count orelse return error.MissingCapturedHeadCount;
    for (snapshot.topology.heads[0..captured_heads], 0..) |head, index| {
        active[index] = head.display_id orelse return error.MissingCapturedHead;
    }
    const serial = snapshot.final_receipt_serial;
    if (serial <= 4 or !snapshot.coherent) return error.IncompleteMstFixtureCapture;
    const resource: display.Resource = .{ .index = 2, .kind = 2, .protocol = 8, .location = 0, .dynamic = false,
        .root_port_id = 0, .dcb_index = 27, .vbios_address = 0, .lit_by_vbios = false, .dither_type = 0, .dither_algo = 0 };
    snapshot.count = 3; snapshot.topology.count = 3;
    // The older single-output capture fixture has no SUPPORTED observation.
    // This complete MST capture includes both physical ports and its RM ID.
    snapshot.topology.supported = .{ .displays = 28, .ddc = 28 };
    snapshot.topology.routes[1] = .{ .id = 8, .resource = resource,
        .connectors = .{ .flags = 1, .ddc_partners = 8, .platform = 0, .count = 1,
            .data = .{ .{ .index = 5, .kind = 0x46 }, .{}, .{}, .{} } } };
    snapshot.receivers[1] = .{ .epoch = snapshot.topology.epoch, .client = snapshot.topology.client, .display_id = 8,
        .receipt_serial = serial - 4, .status = .edid_missing, .connected = true, .resource = resource,
        .dp = .{ .source_state = .complete, .source = .{ .rate = 30, .increased_watermark = false, .mst = true },
            .dpcd_state = .complete, .receiver = .{ .mst_state = .complete, .mst = true } } };
    const capture = &snapshot.receivers[1];
    capture.dp.dpcd[0..7].* = .{ 0x14, 30, 0x84, 0x80, 0, 0, 1 };
    const root = try store.root(8);
    root.resource = resource; root.source = capture.dp.source; root.dpcd = capture.dp.dpcd; root.enabled_receipt = serial - 4;
    root.graph = .{ .epoch = snapshot.topology.epoch, .generation = snapshot.generation, .root = 8,
        .branch_count = 1, .edge_count = 1, .sink_count = 1, .coherent = true, .completion_receipt = serial - 3 };
    const port: wire.Port = .{ .number = 1, .peer = .sink, .connected = true, .revision = 0x14, .guid = @splat(30), .streams = 1, .sinks = 1 };
    var branch: wire.Branch = .{ .guid = @splat(9), .count = 2 };
    branch.ports[0] = .{ .number = 0, .input = true, .peer = .upstream, .messaging = true, .connected = true };
    branch.ports[1] = port;
    root.graph.branches[0] = .{ .descriptor = branch, .receipt = serial - 4 };
    root.graph.edges[0] = .{ .port = port, .resources = .{ .port = 1, .streams = 1, .fec = false, .total_pbn = 2000, .free_pbn = 1800 }, .receipt = serial - 4 };
    snapshot.receivers[2] = .{ .epoch = snapshot.topology.epoch, .client = snapshot.topology.client, .display_id = 16 };
    try @import("gsp_receiver_mode_test.zig").install(&snapshot.receivers[2]);
    const leaf = &snapshot.receivers[2];
    root.graph.sinks[0] = .{ .edge = 0, .path_count = 1, .state = .valid, .caps = root.dpcd,
        .edid_bytes = leaf.edid_bytes, .report = leaf.report, .receipt = serial - 4 };
    @memcpy(root.graph.sinks[0].bytes[0..leaf.edid_bytes], leaf.bytes[0..leaf.edid_bytes]);
    try store.registry.synchronize(&root.graph, 2, 0, 12);
    const handle = try store.registry.handle(0);
    if (store.registry.slots[handle.slot].state == .reserved) {
        _ = try store.registry.allocate(handle); try store.registry.allocated(handle, 16, serial - 2);
    } else try t.expect(store.registry.slots[handle.slot].state == .allocated and store.registry.slots[handle.slot].display_id == 16);
    var dynamic = resource; dynamic.dynamic = true; dynamic.root_port_id = 8;
    try store.registry.resource(handle, dynamic, serial - 1);
    snapshot.topology.routes[2] = .{ .id = 16, .resource = dynamic };
    if (!store.capture(&snapshot.topology.routes[2], leaf, snapshot.topology.epoch, snapshot.topology.client, snapshot.generation))
        return error.IncompleteMstFixtureLeaf;
    // This Device fixture supplies a completed receiver capture. The live
    // discovery/clear/rejection exchange is exercised by checkLiveMst.
    root.payload_dirty = false;
    snapshot.mst = store;
}
fn put(bytes: []u8, at: usize, value: u32) void { std.mem.writeInt(u32, bytes[at..][0..4], value, .little); }
fn word(bytes: []const u8, at: usize) u32 { return std.mem.readInt(u32, bytes[at..][0..4], .little); }
pub fn respond(request: link.Request, bytes: []u8, snapshot: *const outputs.Snapshot) !void {
    try t.expect(enabled);
    switch (request) {
        .control => |query| switch (query) {
            .train => |value| { try t.expect(trained == null); trained = .{ .rate = value.rate, .lanes = value.lanes }; },
            .stream => |value| { try t.expect(trained != null and value.sor == 2); sources[value.head] = value; },
            .trigger => {},
            .rate => |value| if (value.check) { put(bytes, 36, word(bytes, 36) | 0x80000000); },
            .clear_vsc, .clear_hdr => |id| try t.expect(id == 16 and active[0] == 16),
            .act => {
                try t.expect(root_present);
                var table: [64]u8 = @splat(0);
                for (sources, 0..) |source, head| if (source) |value| {
                    if (value.pbn == 0) continue;
                    for (value.start..value.end + 1) |slot| { try t.expect(table[slot] == 0); table[slot] = @intCast(head + 1); }
                };
                try t.expectEqualSlices(u8, &slots, &table); status |= 2; act_count += 1;
            },
            else => return error.UnexpectedMstControl,
        },
        .query => |query| switch (query) {
            .connected => |mask| put(bytes, 32, if (root_present) mask & 8 else 0),
            .resource => |id| {
                var found = false;
                for (snapshot.topology.routes[0..snapshot.count]) |route| if (route.id == id) {
                    const value = route.resource.?;
                    put(bytes, 32, value.index); put(bytes, 36, value.kind); put(bytes, 40, value.protocol);
                    put(bytes, 44, value.dither_type); put(bytes, 48, value.dither_algo); put(bytes, 52, value.location);
                    put(bytes, 56, value.root_port_id); put(bytes, 60, value.dcb_index);
                    std.mem.writeInt(u64, bytes[64..72], value.vbios_address, .little);
                    bytes[72] = @intFromBool(value.lit_by_vbios); bytes[73] = @intFromBool(value.dynamic); found = true;
                };
                try t.expect(found);
            },
            .dp_source => { put(bytes, 32, 4); bytes[48] = 1; },
            .heads => put(bytes, 32, snapshot.topology.head_count.?),
            .active => |head| put(bytes, 36, active[head]),
            .aux => |query_aux| {
                try t.expect(query_aux.display_id == 8 and root_present);
                put(bytes, 60, display.aux_wire.length(query_aux.operation));
                switch (query_aux.operation) {
                    .caps => @memcpy(bytes[44..60], &snapshot.receivers[1].dp.dpcd),
                    .mst_caps, .power => bytes[44] = 1,
                    .repeaters, .power_on => {},
                    .link_config => { bytes[44] = trained.?.rate; bytes[45] = trained.?.lanes | 0x80; },
                    .link_status => @memcpy(bytes[44..52], &[_]u8{ 1, 0, 0x77, 0x77, 1, 0, 0, 0 }),
                    .mst => |op| switch (op) {
                        .control => bytes[44] = 7,
                        .guid => @memset(bytes[44..60], 9),
                        .payload_status => |clear| { if (clear) status = 0 else bytes[44] = status; },
                        .payload_table => |part| for (0..16) |index| {
                            const at = @as(usize, part) * 16 + index; bytes[44 + index] = if (at == 0) status else slots[at];
                        },
                        .payload => |value| {
                            if (value.id == 0) {
                                for (sources) |source| if (source) |stream| try t.expect(stream.pbn == 0);
                                @memset(&slots, 0);
                            } else if (value.count == 0) {
                                try t.expect(slots[value.start] == value.id);
                                var table: [64]u8 = @splat(0); var next: usize = 1;
                                for (slots[1..]) |id| if (id != 0 and id != value.id) { table[next] = id; next += 1; };
                                slots = table;
                            } else {
                                for (slots[1..value.start]) |id| try t.expect(id != 0);
                                for (slots[value.start..]) |id| try t.expect(id == 0);
                                @memset(slots[value.start..][0..value.count], value.id);
                            }
                            status |= 1;
                        },
                        .irq => |irq| {
                            if (irq.ack) |ack| { try t.expect(ack == 0x10 and packet_count != 0); packet_count = 0; }
                            else {
                                if (packet_count == 0) {
                                    packet_count = (try sender.?.next(response[0..response_count], &packet)).?;
                                    const header = try wire.decodeHeader(packet[0..packet_count]);
                                    packet[0] &= 0xf0; packet[header.size() - 1] &= 0xf0;
                                    packet[header.size() - 1] |= try wire.headerCrc(packet[0..header.size()], header.size() * 8 - 4);
                                }
                                bytes[44] = 0x10;
                            }
                        },
                        .mailbox => |mailbox| {
                            if (mailbox.box == .down_request) {
                                @memcpy(outgoing[mailbox.offset..][0..mailbox.count], mailbox.data[0..mailbox.count]);
                                const header = try wire.decodeHeader(outgoing[0..@as(usize, mailbox.offset) + mailbox.count]);
                                const length = header.size() + header.payload_bytes;
                                if (@as(usize, mailbox.offset) + mailbox.count == length) {
                                    const frame = try wire.decode(outgoing[0..length]); const body = frame.body;
                                    @memset(&response, 0); response[0] = body[0];
                                    switch (body[0]) {
                                        1 => {
                                            @memset(response[1..17], 9); response[17] = 2; response[18] = 0x90; response[19] = 0xc0;
                                            response[20] = 0x31; response[21] = 0x40; response[22] = 0x14;
                                            @memset(response[23..39], 30); response[39] = 0x11; response_count = 40;
                                        },
                                        0x10 => {
                                            response[1] = body[1] | 2; std.mem.writeInt(u16, response[2..4], 2000, .big);
                                            std.mem.writeInt(u16, response[4..6], 1800 - pbn[1], .big); response_count = 6;
                                        },
                                        0x11 => {
                                            try t.expect(body[2] == 1);
                                            pbn[1] = std.mem.readInt(u16, body[3..5], .big);
                                            if (pbn[1] != 0) try t.expect(active[0] == 16 and status & 2 != 0);
                                            response[1] = body[1] & 0xf0; @memcpy(response[2..5], body[2..5]); response_count = 5;
                                            if (pbn[1] != 0 and reject_allocate) {
                                                reject_allocate = false; rejected = true;
                                                response[0] |= 0x80; @memset(response[1..17], 9);
                                                response[17] = 8; response_count = 19;
                                            }
                                        },
                                        0x12 => { response[1] = body[1]; std.mem.writeInt(u16, response[2..4], pbn[body[2]], .big); response_count = 4; },
                                        0x14 => { @memset(&pbn, 0); response_count = 1; },
                                        else => return error.UnexpectedMstSideband,
                                    }
                                    sender = .{ .route = header.route, .sequence = header.sequence, .path = header.path, .broadcast = header.broadcast };
                                    packet_count = 0;
                                }
                            } else if (mailbox.box == .down_reply) @memcpy(bytes[44..][0..mailbox.count], packet[mailbox.offset..][0..mailbox.count])
                            else return error.UnexpectedMstMailbox;
                        },
                        else => return error.UnexpectedMstAux,
                    },
                    else => return error.UnexpectedMstAux,
                }
            },
            else => return error.UnexpectedMstQuery,
        },
    }
}
pub fn executeScanout(run: *runtime.Owner) !void {
    const work = &run.display_work.?;
    const model = @import("gsp_display_test_model.zig").Model;
    const scan = @import("boot_scanout.zig");
    if (work.core.phase == .submitted and work.core.ticket.?.point != last_core) {
        const owner = &run.display_channels[work.core.handle.slot].?;
        const program = owner.ring.program.?;
        try t.expect(owner.ring.published and work.window.?.phase == .submitted);
        var offset: usize = 0;
        while (offset < program.count) {
            const header = program.words[offset]; offset += 1;
            const count = (header >> 18) & 0x7ff; const method = header & 0x3fff;
            for (0..count) |index| {
                const address = method + @as(u32, @intCast(index)) * 4;
                model.words[(scan.armed_base + address) / 4] = program.words[offset + index];
                if (address >= 0x2020 and address <= 0x3c20 and (address - 0x2020) % 0x400 == 0)
                    active[(address - 0x2020) / 0x400] = program.words[offset + index];
            }
            offset += count;
        }
        last_core = work.core.ticket.?.point; core_count += 1;
    }
    if ((work.core.phase == .submitted or work.core.phase == .complete) and work.core.ticket.?.point == last_core and
        work.window.?.phase == .submitted and work.window.?.ticket.?.point != last_window) {
        const part = &work.window.?;
        const owner = &run.display_channels[part.handle.slot].?;
        const program = owner.ring.program.?;
        try t.expect(owner.ring.published);
        var offset: usize = 0;
        while (offset < program.count) {
            const header = program.words[offset]; offset += 1;
            const count = (header >> 18) & 0x7ff; const method = header & 0x3fff;
            for (0..count) |index| model.words[(scan.window_armed_base + @as(u32, part.handle.slot - 1) * 0x1000 + method) / 4 + index] = program.words[offset + index];
            offset += count;
        }
        const words: [*]u32 = @ptrFromInt(part.notifier.cpu.cpu_address);
        if (part.notifier.window_used & (@as(u2, 1) << @intCast((part.notifier.offset ^ 16) / 16)) != 0)
            words[(part.notifier.offset ^ 16) / 4] = 2 << 30;
        last_window = part.ticket.?.point;
    }
}
