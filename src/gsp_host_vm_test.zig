//! Host-only additions to the existing virtual-memory owner test group.
const std = @import("std");
const t = std.testing;
const page = @import("gsp_host_page.zig");
const tlb = @import("gsp_host_tlb.zig");
const wire = @import("gsp_host_vm_wire.zig");
const Model = struct {
    epoch: u64 = 7,
    time: u64 = 10,
    low: u32 = 0,
    high: u32 = 0,
    busy: bool = false,
    reads: usize = 0,
    writes: usize = 0,
    submitted: bool = false,
    fail_write: usize = 0,
    bad_read: bool = false,
    stale_write: bool = false,
    fn ptr(ctx: *anyopaque) *Model { return @ptrCast(@alignCast(ctx)); }
    fn generation(ctx: *anyopaque) u64 { return ptr(ctx).epoch; }
    fn now(ctx: *anyopaque) u64 { return ptr(ctx).time; }
    fn read(ctx: *anyopaque, address: u32) !u32 {
        const self = ptr(ctx);
        self.reads += 1;
        if (self.bad_read) return 0xffffffff;
        return switch (address) {
            tlb.pdb_low => self.low,
            tlb.pdb_high => self.high,
            tlb.invalidate => if (self.busy) tlb.trigger else 0,
            else => error.Address,
        };
    }
    fn write(ctx: *anyopaque, address: u32, value: u32) !void {
        const self = ptr(ctx);
        self.writes += 1;
        switch (address) {
            tlb.pdb_low => self.low = value,
            tlb.pdb_high => self.high = value,
            tlb.invalidate => {
                if (value != tlb.command) return error.Command;
                self.submitted = true;
            },
            else => return error.Address,
        }
        if (self.stale_write) self.epoch += 1;
        if (self.writes == self.fail_write) return error.WrittenButFailed;
    }
    fn io(self: *Model) tlb.Io { return .{ .context = self, .generation = generation, .now_ns = now, .read32 = read, .write32 = write }; }
};
pub fn check() !void {
    try checkTables();
    try checkBoundedMappings();
    // Original-C byte/field oracle is in the existing FWSEC ABI gate.
    // Here exercise rejected inputs, VA boundary indices and state ownership.
    try t.expectError(error.Address, page.directory(0));
    try t.expectError(error.Alignment, page.directory(4097));
    try t.expectError(error.Address, page.directory(page.system_limit));
    try t.expectError(error.Address, page.page(page.video_limit, .{ .aperture = .video }));
    try t.expectError(error.Kind, page.page(0, .{ .aperture = .video, .kind = 7 }));
    try t.expectEqual(@as(u64, 0x89), try page.page(0, .{ .aperture = .video }));
    try t.expectError(error.Bounds, page.extent(page.va_limit - 4096, 8192));
    for (std.enums.values(page.Level)) |level| {
        try t.expectEqual(@as(u16, 0), try page.index(level, 0));
        try t.expectEqual(page.count(level) - 1, try page.index(level, page.va_limit - 1));
        try t.expectEqual(@as(u16, 1), try page.index(level, @as(u64, 1) << page.shift(level)));
        try t.expectError(error.Address, page.index(level, page.va_limit));
    }
    var zeros: [4096]u8 = @splat(0);
    try t.expect(try page.empty(&zeros, .root));
    zeros[4095] = 1;
    try t.expect(!try page.empty(&zeros, .root));
    const binding: wire.Binding = .{ .epoch = 7, .client = 1, .device = 2, .vaspace = 3, .root_dma = 0x12345678000 };
    for ([_]wire.Operation{ .bind, .unbind }) |operation| {
        var bytes: [wire.max_bytes]u8 = undefined;
        const encoded = try wire.encode(binding, operation, &bytes);
        var record: @import("gsp_message.zig").Record = .{ .shape = .{ .message_bytes = encoded.len + 80, .checksum_bytes = encoded.len + 80, .storage_bytes = 4096, .elements = 1 },
            .queue_sequence = 1, .rpc = .{ .function = wire.function, .result = 0 }, .payload = encoded };
        try t.expect((try wire.decode(binding, operation, record)) == .ok);
        bytes[12] = 0x2a;
        try t.expectEqual(@as(u32, 0x2a), (try wire.decode(binding, operation, record)).rejected);
        bytes[12] = 0;
        bytes[24] ^= 1;
        try t.expectError(error.Unexpected, wire.decode(binding, operation, record));
        bytes[24] ^= 1;
        record.rpc.result = 0x2a;
        try t.expectError(error.FirmwareResult, wire.decode(binding, operation, record));
    }
    {
        var model: Model = .{ .busy = true };
        var op = try tlb.Operation.init(7, binding.root_dma, 4, 100);
        for (0..3) |_| try t.expect(!try op.step(model.io()));
        try t.expectEqual(@as(usize, 0), model.writes);
        model.busy = false;
        var steps: usize = 0;
        while (!try op.step(model.io())) : (steps += 1) {
            try t.expect(steps < 12);
            try t.expect(op.receipt(model.io()) == null);
        }
        try t.expect(model.submitted and model.writes == 3);
        const receipt = op.receipt(model.io()).?;
        try t.expectEqual(@intFromPtr(&op), receipt.owner);
        try t.expectEqual(binding.root_dma, receipt.root_dma);
        try t.expectEqual(@as(u64, 4), receipt.serial);
        var copy = op;
        try t.expect(copy.receipt(model.io()) == null);
        try t.expectError(error.Stale, copy.step(model.io()));
        model.epoch += 1;
        try t.expect(op.receipt(model.io()) == null);
    }
    // Every possibly visible write is retained on errors, including a failed
    // callback after a hardware side effect; no success receipt is minted.
    for (1..4) |fail_write| {
        var model: Model = .{ .fail_write = fail_write };
        var op = try tlb.Operation.init(7, binding.root_dma, 1, 100);
        for (0..10) |_| {
            _ = op.step(model.io()) catch |err| {
                try t.expectEqual(error.Io, err);
                break;
            };
        }
        try t.expect(op.phase == .failed and op.effects_possible);
        try t.expect(op.receipt(model.io()) == null);
        try t.expectEqual(fail_write, model.writes);
        try t.expectError(error.State, op.step(model.io()));
    }
    {
        var model: Model = .{};
        var op = try tlb.Operation.init(7, binding.root_dma, 1, 100);
        while (op.phase != .waiting) _ = try op.step(model.io());
        model.busy = true;
        for (0..5) |_| try t.expect(!try op.step(model.io()));
        model.time = 100;
        try t.expectError(error.Deadline, op.step(model.io()));
        try t.expect(op.receipt(model.io()) == null and op.effects_possible);
    }
    {
        var model: Model = .{};
        var op = try tlb.Operation.init(7, binding.root_dma, 1, 100);
        while (op.phase != .final_low) _ = try op.step(model.io());
        model.low ^= 16;
        try t.expectError(error.Register, op.step(model.io()));
        try t.expect(op.receipt(model.io()) == null);
    }
    {
        var model: Model = .{ .bad_read = true };
        var op = try tlb.Operation.init(7, binding.root_dma, 1, 100);
        try t.expectError(error.Register, op.step(model.io()));
        try t.expect(!op.effects_possible);
    }
    {
        var model: Model = .{ .stale_write = true };
        var op = try tlb.Operation.init(7, binding.root_dma, 1, 100);
        try t.expect(!try op.step(model.io()));
        try t.expectError(error.Stale, op.step(model.io()));
        try t.expect(op.effects_possible and op.receipt(model.io()) == null);
    }
    {
        var model: Model = .{};
        var op = try tlb.Operation.init(7, binding.root_dma, 1, 100);
        try t.expect(!try op.step(model.io()));
        model.time -= 1;
        try t.expectError(error.Deadline, op.step(model.io()));
        try t.expect(!op.effects_possible);
    }
}

const vm = @import("gsp_host_vm.zig");
const Tables = struct {
    const Node = struct {
        table: vm.Table = .{},
        dma: u64 = 0,
        cpu: [512]u64 align(4096) = @splat(0),
        next: ?*Node = null,
    };
    first: ?*Node = null,
    serial: u64 = 0,
    allocations: usize = 0,
    releases: usize = 0,
    fail_at: usize = 0,
    backing_valid: bool = true,
    fn ptr(ctx: *anyopaque) *Tables { return @ptrCast(@alignCast(ctx)); }
    fn allocate(ctx: *anyopaque) vm.Error!*vm.Table {
        const self = ptr(ctx);
        if (self.fail_at != 0 and self.allocations + 1 == self.fail_at) return error.Memory;
        const node = t.allocator.create(Node) catch return error.Memory;
        node.* = .{ .next = self.first };
        self.serial += 1;
        node.table.dma = 0x12300000000 + self.serial * 4096;
        node.dma = node.table.dma;
        node.table.cpu = &node.cpu;
        self.first = node;
        self.allocations += 1;
        return &node.table;
    }
    fn release(ctx: *anyopaque, table: *vm.Table) vm.Error!void {
        const self = ptr(ctx);
        var link = &self.first;
        while (link.*) |node| : (link = &node.next) {
            if (&node.table != table) continue;
            link.* = node.next;
            t.allocator.destroy(node);
            self.releases += 1;
            return;
        }
        return error.Descriptor;
    }
    fn valid(ctx: *anyopaque, table: *const vm.Table) bool {
        const self = ptr(ctx);
        if (!self.backing_valid) return false;
        var cursor = self.first;
        while (cursor) |node| : (cursor = node.next) {
            if (&node.table == table) return table.dma == node.dma and table.cpu == @as([*]volatile u64, &node.cpu);
        }
        return false;
    }
    fn backend(self: *Tables) vm.Backend { return .{ .context = self, .allocate = allocate, .valid = valid, .release = release }; }
    fn destroy(self: *Tables) void {
        while (self.first) |node| { self.first = node.next; t.allocator.destroy(node); }
    }
    fn byDma(self: *Tables, dma: u64) !*[512]u64 {
        var node = self.first;
        while (node) |value| : (node = value.next) if (value.table.dma == dma) return &value.cpu;
        return error.MissingPage;
    }
    // Independent hardware walker: exact 49-bit v2 index slices, with the
    // small-page half of a dual PDE. It does not call the implementation's
    // index/stride/lookup helpers and follows actual encoded bus addresses.
    fn walk(self: *Tables, root: u64, address: u64) !u64 {
        var table = try self.byDma(root);
        const offsets = [_]usize{ @intCast((address >> 47) & 3), @intCast((address >> 38) & 511),
            @intCast((address >> 29) & 511), @intCast(((address >> 21) & 255) * 2 + 1) };
        for (offsets, 0..) |at, level| {
            const word = table[at];
            if (word == 0) return 0;
            try t.expectEqual(@as(u64, 12), word & 255);
            if (level == 3) try t.expectEqual(@as(u64, 0), table[at - 1]);
            table = try self.byDma((word & 0x003fffffffffff00) << 4);
        }
        return table[@intCast((address >> 12) & 511)];
    }
};
const Pages = struct {
    bytes: u64 = 3 * 4096,
    valid_epoch: u64 = 7,
    base: u64 = 0x65400000000,
    stride: u64 = 3,
    clock: ?*Model = null,
    page_ns: u64 = 0,
    fn ptr(ctx: *const anyopaque) *const Pages { return @ptrCast(@alignCast(ctx)); }
    fn valid(ctx: *const anyopaque, epoch: u64) bool { return ptr(ctx).valid_epoch == epoch; }
    fn physical(ctx: *const anyopaque, offset: u64) vm.Error!u64 {
        const self = ptr(ctx);
        if (offset >= self.bytes or offset & 4095 != 0) return error.Bounds;
        if (self.clock) |clock| clock.time += self.page_ns;
        return self.base + offset * self.stride; // Default: deliberately noncontiguous RAM.
    }
    fn source(self: *const Pages) vm.Source {
        return .{ .context = self, .valid = valid, .physical = physical, .bytes = self.bytes,
            .policy = .{ .aperture = .system_coherent, .read_only = true, .kind = 6 } };
    }
};
fn finish(vm_owner: *vm.Owner, binding: *vm.Binding) !void {
    var steps: usize = 0;
    while (!try vm_owner.poll(binding)) : (steps += 1) try t.expect(steps < 100);
}
fn checkBoundedMappings() !void {
    var tables: Tables = .{};
    defer tables.destroy();
    var model: Model = .{};
    var owner: vm.Owner = .{};
    try owner.prepare(7, 4096, page.va_limit - 4096, tables.backend(), model.io());
    try owner.bindSubmitted();
    try owner.bindConfirmed();
    const root = try owner.rootAddress();
    var range: vm.Range = .{};
    var binding: vm.Binding = .{};
    const source: Pages = .{ .bytes = 16 * 1024 * 1024, .base = 0x200000000, .stride = 1 };
    var video = source.source(); video.policy.aperture = .video;
    const address = try owner.reserve(&range, source.bytes, 65536, 0);
    try owner.beginMap(&range, &binding, 0, video, model.time + 5 * std.time.ns_per_s);
    // The physical162 failure reached only ~10MB under a5s graphics phase.
    // A2ms dispatcher cadence must leave time for16MB and the real TLB ACK.
    for (0..2) |operation| {
        if (operation == 1) try owner.beginUnmap(&binding, model.time + 5 * std.time.ns_per_s, true);
        var polls: usize = 0;
        while (true) : (polls += 1) {
            const before = owner.work.?.offset;
            if (try owner.poll(&binding)) break;
            try t.expect(owner.work.?.offset - before <= 1024 * 1024);
            if (operation == 0) try t.expect(!binding.mapped);
            if (owner.work.?.phase == .invalidating) try t.expectEqual(@as(usize, 0), tables.releases);
            model.time += 2 * std.time.ns_per_ms;
            try t.expect(polls < 1000);
        }
        if (operation == 0) {
            try t.expect(binding.mapped and model.submitted);
            for (0..4096) |i| {
                const physical = source.base + i * 4096;
                try t.expectEqual(@as(u64, 0x06000000000000c9) | (physical >> 4), try tables.walk(root, address + i * 4096));
            }
        } else try t.expect(!binding.mapped and tables.allocations == tables.releases + 1);
    }
    try owner.releaseRange(&range);
    try owner.unbindConfirmed();
    try owner.close();
    try t.expectEqual(tables.allocations, tables.releases);

    // Expensive page providers make a poll yield early without losing the
    // original deadline. A true deadline still retains all partial edits.
    try owner.prepare(7, 4096, page.va_limit - 4096, tables.backend(), model.io());
    try owner.bindSubmitted(); try owner.bindConfirmed();
    _ = try owner.reserve(&range, 65536, 65536, 0);
    const slow: Pages = .{ .bytes = 65536, .clock = &model, .page_ns = std.time.ns_per_ms };
    try owner.beginMap(&range, &binding, 0, slow.source(), model.time + 10 * std.time.ns_per_ms);
    const started = model.time;
    try t.expect(!try owner.poll(&binding));
    try t.expect(model.time - started <= 2 * std.time.ns_per_ms and owner.work.?.offset > 0 and owner.work.?.offset < slow.bytes);
    const held = tables.releases;
    model.time = owner.work.?.deadline;
    try t.expectError(error.Deadline, owner.poll(&binding));
    try t.expect(!binding.mapped and owner.work != null and tables.releases == held);
}
fn checkTables() !void {
    var tables: Tables = .{};
    defer tables.destroy();
    var model: Model = .{};
    var owner: vm.Owner = .{};
    try owner.prepare(7, 0x1000, page.va_limit - 4096, tables.backend(), model.io());
    const root = try owner.rootAddress();
    owner.root.?.dma ^= 4096;
    try t.expectError(error.Descriptor, owner.rootAddress());
    owner.root.?.dma ^= 4096;
    owner.root.?.level = .leaf;
    try t.expectError(error.Descriptor, owner.rootAddress());
    owner.root.?.level = .root;
    tables.backing_valid = false;
    try t.expectError(error.Descriptor, owner.rootAddress());
    tables.backing_valid = true;
    try t.expectEqual(root, try owner.rootAddress());
    try owner.bindSubmitted();
    try owner.bindConfirmed();
    var range: vm.Range = .{};
    const address = try owner.reserve(&range, 5 * 4096, 4096, 0x1ffff000);
    var conflict: vm.Range = .{};
    try t.expectError(error.Busy, owner.reserve(&conflict, 4096, 4096, address + 4096));
    try t.expectError(error.Alignment, owner.reserve(&conflict, 4096, 0, 0));
    try t.expectError(error.Alignment, owner.reserve(&conflict, 4096, @as(u64, 1) << 63, 0));
    var source: Pages = .{};
    var first: vm.Binding = .{};
    var second: vm.Binding = .{};
    try owner.beginMap(&range, &first, 0, source.source(), 100);
    try t.expectError(error.Busy, owner.releaseRange(&range));
    try finish(&owner, &first);
    try t.expect(first.mapped);
    for (0..3) |i| {
        const offset = i * 4096;
        const physical = 0x65400000000 + offset * 3;
        // Cached=false, RO, atomic-disable, system-coherent, valid and kind6.
        try t.expectEqual(@as(u64, 0x06000000000000cd) | (physical >> 4), try tables.walk(root, address + offset));
    }
    const single: Pages = .{ .bytes = 4096 };
    try owner.beginMap(&range, &second, 4 * 4096, single.source(), 100);
    try finish(&owner, &second);
    try t.expectError(error.Busy, owner.beginUnmap(&first, 100, false));
    const before = tables.releases;
    try owner.beginUnmap(&first, 100, true);
    while (owner.work.?.phase != .invalidating) try t.expect(!try owner.poll(&first));
    try t.expectEqual(before, tables.releases);
    try finish(&owner, &first);
    try t.expect(!first.mapped and first.range == null);
    try t.expectEqual(@as(u64, 0), try tables.walk(root, address));
    try t.expectEqual(@as(u64, 0), try tables.walk(root, address + 2 * 4096));
    try t.expect(try tables.walk(root, address + 4 * 4096) != 0);
    try owner.beginUnmap(&second, 100, true);
    try finish(&owner, &second);
    try owner.releaseRange(&range);
    try t.expectError(error.Busy, owner.close());
    try owner.unbindConfirmed();
    try owner.close();
    try t.expect(tables.first == null and tables.allocations == tables.releases);
    {
        var partial_tables: Tables = .{ .fail_at = 4 };
        defer partial_tables.destroy();
        var partial: vm.Owner = .{};
        try partial.prepare(7, 4096, page.va_limit - 4096, partial_tables.backend(), model.io());
        try partial.bindSubmitted();
        try partial.bindConfirmed();
        var reserved: vm.Range = .{};
        var mapping: vm.Binding = .{};
        _ = try partial.reserve(&reserved, 4096, 4096, (@as(u64, 3) << 47) + 4096);
        try partial.beginMap(&reserved, &mapping, 0, single.source(), 100);
        try t.expectError(error.Memory, partial.poll(&mapping));
        try t.expect(partial.failure.? == error.Memory and partial_tables.allocations == 3 and partial_tables.releases == 0);
        try t.expect(mapping.range == &reserved and !mapping.mapped);
        try t.expectError(error.Retained, partial.close());
    }
    // Invalidating a removed mapping must keep every detached page until HW
    // confirms completion. A deadline cannot turn into apparent retirement.
    try owner.prepare(7, 0x1000, page.va_limit - 4096, tables.backend(), model.io());
    try owner.bindSubmitted();
    try owner.bindConfirmed();
    _ = try owner.reserve(&range, 4096, 4096, 0);
    try owner.beginMap(&range, &first, 0, single.source(), 100);
    try finish(&owner, &first);
    const held = tables.releases;
    try owner.beginUnmap(&first, 100, true);
    while (owner.work.?.phase != .invalidating) try t.expect(!try owner.poll(&first));
    model.busy = true;
    for (0..3) |_| try t.expect(!try owner.poll(&first));
    model.time = 100;
    try t.expectError(error.Deadline, owner.poll(&first));
    try t.expectError(error.Retained, owner.releaseRange(&range));
    try t.expect(first.range == &range and first.mapped and owner.retired != null);
    try t.expectEqual(held, tables.releases);
    // t.allocator destruction below is host teardown, not a GPU reset proof.
}
