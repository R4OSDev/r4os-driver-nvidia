//! Bounded branch/port/EDID acquisition. The RM owner executes each action
//! over the actual physical root, preserving its generation and receipts.
//! Virtual display-ID allocation and stream activation are separate owners.
const std = @import("std");
const wire = @import("gsp_mst_wire.zig");
const aux = @import("gsp_aux_wire.zig");
const edid = @import("r4gfx_edid");
pub const max_branches = 8;
pub const max_sinks = 16;
pub const max_edges = 120;
pub const Branch = struct {
    route: wire.Route = .{},
    expected_guid: wire.Guid = @splat(0),
    parent_edge: ?u8 = null,
    path_count: u8 = 0,
    path: [15]u8 = @splat(0),
    descriptor: ?wire.Branch = null,
    receipt: u64 = 0,
};
pub const Edge = struct {
    branch: u8 = 0,
    port: wire.Port = .{},
    resources: ?wire.Path = null,
    receipt: u64 = 0,
};
pub const Sink = struct {
    edge: u8 = 0,
    path_count: u8 = 0,
    path: [15]u8 = @splat(0),
    state: enum { pending, valid, incomplete, missing, invalid, unsupported } = .pending,
    caps: ?[16]u8 = null,
    edid_bytes: usize = 0,
    bytes: [edid.max_blocks * 128]u8 = @splat(0),
    report: edid.Report = .{},
    receipt: u64 = 0,
};
pub const Graph = struct {
    epoch: u64 = 0,
    generation: u64 = 0,
    root: u32 = 0,
    branch_count: u8 = 0,
    edge_count: u8 = 0,
    sink_count: u8 = 0,
    branches: [max_branches]Branch = @splat(.{}),
    edges: [max_edges]Edge = @splat(.{}),
    sinks: [max_sinks]Sink = @splat(.{}),
    coherent: bool = false,
    completion_receipt: u64 = 0,
};
pub const Action = union(enum) {
    sideband: struct { route: wire.Route, request: wire.Request },
    root_aux: aux.Mst,
};
pub const Observation = union(enum) { sideband: wire.Reply, root_aux: aux.Reply };
pub const Stage = enum { branch, guid_write, resources, caps, edid, edid_verify, verify, complete, cancelled };
pub const Builder = struct {
    graph: *Graph,
    epoch: u64,
    generation: u64,
    root: u32,
    seed: wire.Guid,
    deadline: u64,
    stage: Stage = .branch,
    branch: u8 = 0,
    port: u8 = 0,
    verify_branch: u8 = 0,
    sink: u8 = 0,
    block: u8 = 0,
    blocks: u8 = 1,
    pending: bool = false,
    last_receipt: u64,
    failure: ?anyerror = null,

    /// seed is a per-device boot identifier, not a made-up observation. It
    /// is used only if a branch needs a GUID, with a real write/readback.
    pub fn init(graph: *Graph, epoch: u64, generation: u64, root: u32, seed: wire.Guid, after_receipt: u64, deadline: u64) !Builder {
        if (epoch == 0 or generation == 0 or root == 0 or root & (root - 1) != 0 or after_receipt == 0 or deadline == 0 or
            std.mem.allEqual(u8, &seed, 0)) return error.Descriptor;
        graph.epoch = epoch;
        graph.generation = generation;
        graph.root = root;
        graph.branch_count = 1;
        graph.edge_count = 0;
        graph.sink_count = 0;
        graph.coherent = false;
        graph.completion_receipt = 0;
        for (&graph.branches) |*entry| entry.* = .{};
        for (&graph.edges) |*entry| entry.* = .{};
        for (&graph.sinks) |*entry| entry.* = .{};
        return .{ .graph = graph, .epoch = epoch, .generation = generation, .root = root, .seed = seed, .deadline = deadline, .last_receipt = after_receipt };
    }
    pub fn invalidate(self: *Builder) void {
        self.stage = .cancelled;
        self.graph.coherent = false;
    }
    fn guard(self: *const Builder, generation: u64, now: u64) !void {
        if (self.failure != null or self.stage == .cancelled or generation != self.generation or self.graph.generation != self.generation or
            self.graph.epoch != self.epoch or self.graph.root != self.root) return error.Stale;
        if (now >= self.deadline) return error.Deadline;
    }
    fn action(self: *const Builder) !Action {
        const branch = &self.graph.branches[self.branch];
        const edge = &self.graph.edges[self.graph.sinks[self.sink].edge];
        const request: wire.Request = switch (self.stage) {
            .branch => .link_address,
            .guid_write => {
                if (branch.parent_edge) |index| {
                    const parent = &self.graph.edges[index];
                    return .{ .sideband = .{ .route = self.graph.branches[parent.branch].route, .request = .{ .dpcd_write = .{ .port = parent.port.number, .address = 0x30, .count = 16, .bytes = branch.expected_guid } } } };
                }
                return .{ .root_aux = .{ .guid_write = branch.expected_guid } };
            },
            .resources => .{ .enum_path = branch.descriptor.?.ports[self.port].number },
            .caps => .{ .dpcd_read = .{ .port = edge.port.number, .address = 0, .count = 16 } },
            .edid, .edid_verify => .{ .edid = .{ .port = edge.port.number, .block = if (self.stage == .edid_verify) 0 else self.block } },
            .verify => return .{ .sideband = .{ .route = self.graph.branches[self.verify_branch].route, .request = .link_address } },
            .complete, .cancelled => return error.State,
        };
        return .{ .sideband = .{ .route = branch.route, .request = request } };
    }
    pub fn prepare(self: *Builder, generation: u64, now: u64) !?Action {
        try self.guard(generation, now);
        if (self.pending) return error.Pending;
        if (self.stage == .complete) return null;
        const value = try self.action();
        self.pending = true;
        return value;
    }
    fn nextPort(self: *Builder) void {
        const current = &self.graph.branches[self.branch];
        while (self.port < current.descriptor.?.count) : (self.port += 1) {
            const port = current.descriptor.?.ports[self.port];
            if (port.input or (!port.connected and !port.legacy_connected)) continue;
            self.stage = .resources;
            return;
        }
        self.branch += 1;
        self.port = 0;
        self.stage = if (self.branch < self.graph.branch_count) .branch else .verify;
        // Keep action()'s branch index in range during final verification.
        if (self.stage == .verify) self.branch = self.graph.branch_count - 1;
    }
    fn nextSink(self: *Builder) void {
        self.port += 1;
        self.nextPort();
    }
    fn guid(self: *const Builder, route: wire.Route) wire.Guid {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(&self.seed);
        hash.update(&.{route.depth});
        hash.update(&route.ports);
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        var result = digest[0..16].*;
        result[6] = (result[6] & 15) | 0x40;
        result[8] = (result[8] & 63) | 0x80;
        return result;
    }
    fn acceptBranch(self: *Builder, value: wire.Branch, serial: u64) !void {
        const current = &self.graph.branches[self.branch];
        if (std.mem.allEqual(u8, &value.guid, 0)) {
            if (!std.mem.allEqual(u8, &current.expected_guid, 0)) return error.Stale;
            current.expected_guid = self.guid(current.route);
            self.stage = .guid_write;
            return;
        }
        if (!std.mem.allEqual(u8, &current.expected_guid, 0) and !std.mem.eql(u8, &current.expected_guid, &value.guid)) return error.Stale;
        for (self.graph.branches[0..self.branch]) |*previous| if (std.mem.eql(u8, &previous.descriptor.?.guid, &value.guid)) return error.Routing;
        current.expected_guid = value.guid;
        current.descriptor = value;
        current.receipt = serial;
        if (current.parent_edge) |edge| {
            const parent = &self.graph.edges[edge];
            const parent_branch = &self.graph.branches[parent.branch];
            // Writing an initially empty downstream GUID may update the
            // parent's descriptor. Accept only this exact known change.
            for (parent_branch.descriptor.?.ports[0..parent_branch.descriptor.?.count]) |*port|
                if (port.number == parent.port.number and std.mem.allEqual(u8, &port.guid, 0)) {
                    port.guid = value.guid;
                };
        }
        self.nextPort();
    }
    fn acceptResources(self: *Builder, value: ?wire.Path, serial: u64) !void {
        const branch = &self.graph.branches[self.branch];
        const port = branch.descriptor.?.ports[self.port];
        if (self.graph.edge_count == max_edges) return error.Capacity;
        if (value) |path| if (path.port != port.number) return error.Stale;
        const edge = self.graph.edge_count;
        self.graph.edges[edge] = .{ .branch = self.branch, .port = port, .resources = value, .receipt = serial };
        self.graph.edge_count += 1;
        if (value == null) {
            self.port += 1;
            self.nextPort();
            return;
        }
        var path = branch.path;
        if (branch.path_count == path.len) return error.Capacity;
        path[branch.path_count] = edge;
        if (port.peer == .branch and port.messaging) {
            if (self.graph.branch_count == max_branches) return error.Capacity;
            self.graph.branches[self.graph.branch_count] = .{ .route = try branch.route.child(port.number), .expected_guid = port.guid, .parent_edge = edge, .path_count = branch.path_count + 1, .path = path };
            self.graph.branch_count += 1;
            self.port += 1;
            self.nextPort();
        } else if (port.peer == .sink or port.peer == .legacy or port.peer == .upstream or port.peer == .branch) {
            if (self.graph.sink_count == max_sinks) return error.Capacity;
            self.sink = self.graph.sink_count;
            self.graph.sink_count += 1;
            const sink = &self.graph.sinks[self.sink];
            sink.edge = edge;
            sink.path_count = branch.path_count + 1;
            sink.path = path;
            self.block = 0;
            self.blocks = 1;
            self.stage = .caps;
        } else {
            self.port += 1;
            self.nextPort();
        }
    }
    fn parseSink(self: *Builder) bool {
        const sink = &self.graph.sinks[self.sink];
        edid.parse(sink.bytes[0..sink.edid_bytes], &sink.report) catch |err| {
            sink.state = if (err == error.TooLarge or err == error.Capacity) .unsupported else .invalid;
            return false;
        };
        sink.state = if (sink.report.complete()) .valid else .incomplete;
        return true;
    }
    pub fn consume(self: *Builder, generation: u64, observed: Observation, serial: u64, now: u64) !void {
        if (!self.pending or serial <= self.last_receipt) return error.Stale;
        self.pending = false;
        self.last_receipt = serial;
        if (self.stage == .cancelled or generation != self.generation) {
            self.invalidate();
            return;
        }
        errdefer |err| {
            self.failure = err;
            self.graph.coherent = false;
        }
        try self.guard(generation, now);
        const expected = try self.action();
        if (expected == .root_aux) {
            if (observed != .root_aux or observed.root_aux.status != 0 or observed.root_aux.kind != .ack or observed.root_aux.count != 16) return error.Aux;
            self.stage = .branch;
            return;
        }
        if (observed != .sideband) return error.Unexpected;
        const reply = observed.sideband;
        const rejected = reply == .nack;
        if (rejected and reply.nack.op != expected.sideband.request.op()) return error.Stale;
        switch (self.stage) {
            .branch => if (reply == .branch) {
                try self.acceptBranch(reply.branch, serial);
            } else return error.Topology,
            .guid_write => {
                if (reply != .ack or reply.ack != .dpcd_write) return error.Topology;
                self.stage = .branch;
            },
            .resources => if (reply == .path or rejected) {
                try self.acceptResources(if (rejected) null else reply.path, serial);
            } else return error.Topology,
            .caps => {
                if (!rejected) {
                    if (reply != .data or reply.data.bytes.len != 16 or reply.data.port != expected.sideband.request.port().?) return error.Payload;
                    self.graph.sinks[self.sink].caps = reply.data.bytes[0..16].*;
                }
                self.stage = .edid;
            },
            .edid, .edid_verify => {
                const sink = &self.graph.sinks[self.sink];
                sink.receipt = serial;
                if (rejected) {
                    if (self.stage == .edid_verify) return error.Stale;
                    if (sink.edid_bytes == 0) {
                        sink.state = .missing;
                        self.nextSink();
                    } else {
                        _ = self.parseSink();
                        self.stage = .edid_verify;
                    }
                    return;
                }
                if (reply != .data or reply.data.bytes.len != 128 or reply.data.port != expected.sideband.request.port().?) return error.Payload;
                if (self.stage == .edid_verify) {
                    if (!std.mem.eql(u8, sink.bytes[0..128], reply.data.bytes)) return error.Stale;
                    self.nextSink();
                    return;
                }
                @memcpy(sink.bytes[@as(usize, self.block) * 128 ..][0..128], reply.data.bytes);
                sink.edid_bytes += 128;
                if (self.block == 0) {
                    if (!self.parseSink()) {
                        self.nextSink();
                        return;
                    }
                    if (sink.bytes[126] >= edid.max_blocks) {
                        sink.state = .unsupported;
                        self.nextSink();
                        return;
                    }
                    self.blocks = sink.bytes[126] + 1;
                }
                self.block += 1;
                if (self.block == self.blocks) {
                    _ = self.parseSink();
                    self.stage = .edid_verify;
                }
            },
            .verify => {
                const branch = &self.graph.branches[self.verify_branch];
                if (reply != .branch or !std.meta.eql(branch.descriptor.?, reply.branch)) return error.Stale;
                branch.receipt = serial;
                self.verify_branch += 1;
                if (self.verify_branch == self.graph.branch_count) {
                    self.graph.coherent = true;
                    self.graph.completion_receipt = serial;
                    self.stage = .complete;
                }
            },
            else => return error.State,
        }
    }
};
