const std = @import("std");
const t = std.testing;
const reset = @import("gsp_reset.zig");
const core = @import("gsp_core.zig");
const identity = @import("identity.zig");
const boot0: u32 = 0xb76000a1;
const word: u32 = 0x250410de;
const Model = struct {
    clock: u64 = 1000000,
    epoch: u64 = 7,
    config: [1024]u32 = @splat(0),
    triggered_at: u64 = 0,
    triggers: u32 = 0,
    pci_reads: u32 = 0,
    writes: u32 = 0,
    mirror_writes: u32 = 0,
    admitted: bool = true,
    stuck_transactions: bool = false,
    gfw_protected: bool = false,
    gfw_missing: bool = false,
    falcon_running: bool = false,
    counter_stuck: bool = false,
    foreign_identity: bool = false,
    posted_trigger: bool = false,
    fail_resume: bool = false,
    writes_to_sibling: u32 = 0,
    fn init() Model {
        var self: Model = .{};
        self.config[0] = word;
        self.config[1] = 7 | (0xab00 << 16); // status must not be echoed
        self.config[4] = 0xf0000000;
        self.config[6] = 0xc000000c;
        self.config[0x78 / 4] = 0x10;
        self.config[reset.reg.device_capability / 4] = 1 << 28;
        self.config[reset.reg.device_control / 4] = 0x2800;
        self.config[0x60 / 4] = 5; // disabled MSI capability
        self.config[0xb0 / 4] = 0x11; // disabled MSI-X capability
        return self;
    }
    fn snapshot(self: *const Model) identity.Snapshot {
        var value: identity.Snapshot = .{
            .pci = .{ .bus_kind = 2, .bus = 1, .vendor_id = 0x10de, .device_id = 0x2504, .class_code = 3 },
            .command = 7, .caps = .{ .pcie = 0x78, .power_state = 0, .msi = 0x60, .msix = 0xb0 },
        };
        for (&value.bars, 0..) |*bar, index| bar.raw = self.config[4 + index];
        return value;
    }
    fn cast(raw: *anyopaque) *Model { return @ptrCast(@alignCast(raw)); }
    fn generation(raw: *anyopaque) u64 { return cast(raw).epoch; }
    fn now(raw: *anyopaque) u64 { return cast(raw).clock; }
    fn admit(raw: *anyopaque, epoch: u64) !void {
        const self = cast(raw);
        if (!self.admitted or self.epoch != epoch) return error.Admission;
    }
    fn accessible(self: *const Model) !void {
        if (self.triggered_at != 0 and self.clock - self.triggered_at < reset.quiet_ns) return error.EarlyAccess;
    }
    fn pciRead(raw: *anyopaque, offset: u16) !u32 {
        const self = cast(raw);
        try self.accessible();
        self.pci_reads += 1;
        if (offset >= 4096 or offset & 3 != 0) return error.Register;
        if (offset == 0 and self.foreign_identity and self.triggers != 0) return 0x123410de;
        if (offset == reset.reg.device_control and self.stuck_transactions) return self.config[offset / 4] | (1 << 21);
        if (offset == reset.reg.downstream and !self.counter_stuck) self.config[offset / 4] &= ~@as(u32, 1 << 9);
        return self.config[offset / 4];
    }
    fn pciWrite(raw: *anyopaque, offset: u16, value: u32) !void {
        const self = cast(raw);
        try self.accessible();
        self.writes += 1;
        if (offset == 4) {
            try t.expectEqual(@as(u32, 0), value >> 16);
            self.config[1] = value;
            if (value & 4 != 0 and self.fail_resume) return error.Posted;
            return;
        }
        if (offset == reset.reg.device_control) {
            try t.expect(value & (1 << 15) != 0 and value >> 16 == 0 and self.config[1] & 4 == 0);
            self.triggers += 1;
            self.triggered_at = self.clock;
            self.config[1] = 0;
            for (4..10) |index| self.config[index] = 0;
            self.config[offset / 4] = 0;
            if (self.posted_trigger) return error.Posted;
            return;
        }
        if (offset != reset.reg.downstream and !(offset >= 0x10 and offset <= 0x24)) return error.Register;
        self.config[offset / 4] = value;
    }
    fn read(raw: *anyopaque, address: u32) !u32 {
        const self = cast(raw);
        try self.accessible();
        try t.expect(self.triggers == 1 and self.config[1] & 6 == 2);
        return switch (address) {
            0 => boot0,
            4 => 0,
            core.reg.cpuctl => if (self.falcon_running) 0 else core.bits.halted,
            reset.reg.gfw_permission => if (self.gfw_protected) 0 else 1,
            reset.reg.gfw_progress => blk: {
                try t.expect(!self.gfw_protected);
                break :blk if (self.gfw_missing) 0 else 0xff;
            },
            else => error.Register,
        };
    }
    fn write(raw: *anyopaque, address: u32, value: u32) !void {
        const self = cast(raw);
        try self.accessible();
        try t.expect(self.config[1] & 6 == 2);
        if (address < reset.reg.config_base or address >= reset.reg.config_base + 4096) return error.Register;
        const offset: u16 = @intCast(address - reset.reg.config_base);
        try t.expect(reset.layout.contains(&reset.layout.writable, offset) and offset != 4);
        if (offset == reset.reg.device_control) try t.expectEqual(@as(u32, 0), value & 0xffff8000);
        self.config[offset / 4] = value;
        self.mirror_writes += 1;
    }
    fn io(self: *Model) reset.Io {
        return .{ .context = self, .generation = generation, .now_ns = now, .admit = admit,
            .pci_read = pciRead, .pci_write = pciWrite, .read32 = read, .write32 = write };
    }
    fn drive(self: *Model, operation: *reset.Reset) !void {
        for (0..1200) |_| {
            if (try operation.step()) return;
            self.clock += if (operation.phase == .quiet) reset.quiet_ns / 4 else 5 * std.time.ns_per_ms;
        }
        return error.Unbounded;
    }
};

/// Integrated into the existing firmware/native owner test group.
pub fn checks() !void {
    var valid_count: u32 = 0; var writable_count: u32 = 0;
    for (&reset.layout.valid, &reset.layout.writable) |*valid, *writable| {
        try t.expect(writable.* & ~valid.* == 0);
        valid_count += @popCount(valid.*); writable_count += @popCount(writable.*);
    }
    try t.expectEqual(@as(u32, 472), valid_count);
    try t.expectEqual(@as(u32, 350), writable_count);
    var model = Model.init();
    var saved: reset.Config = .{};
    try saved.capture(&model.snapshot(), boot0, 0, model.io());
    try t.expect(model.writes == 0 and model.mirror_writes == 0);
    var operation: reset.Reset = .{};
    try operation.open(&saved, model.epoch, model.io());
    try t.expect(operation.quiescence() == null);
    var moved = operation;
    try t.expectError(error.State, moved.step());
    try t.expectEqual(reset.Phase.disable_dma, operation.phase);
    try model.drive(&operation);
    const proof = operation.quiescence() orelse return error.NoProof;
    try t.expect(proof.valid(model.epoch) and !proof.valid(model.epoch + 1));
    try t.expectEqual(@as(u32, 1), model.triggers);
    try t.expectEqual(@as(u32, 349), model.mirror_writes);
    try t.expectEqual(@as(u32, 0), model.config[1] & 4);
    try t.expectError(error.Busy, operation.open(&saved, model.epoch, model.io()));
    try operation.resumeDma();
    try t.expect(!proof.valid(model.epoch) and operation.quiescence() == null);
    try t.expect(model.config[1] & 4 != 0);

    inline for (.{ .stuck_transactions, .gfw_protected, .gfw_missing, .falcon_running, .counter_stuck,
        .foreign_identity, .posted_trigger }) |mode| {
        var failure_model = Model.init();
        var config: reset.Config = .{};
        try config.capture(&failure_model.snapshot(), boot0, 0, failure_model.io());
        @field(failure_model, @tagName(mode)) = true;
        var failed: reset.Reset = .{};
        try failed.open(&config, failure_model.epoch, failure_model.io());
        const expected: anyerror = switch (mode) {
            .foreign_identity => error.IdentityChanged, .posted_trigger => error.Posted, else => error.Timeout,
        };
        try t.expectError(expected, failure_model.drive(&failed));
        try t.expect(failed.failure != null and failed.failure.? == expected and failed.quiescence() == null and failed.failed_phase != null);
        const writes = failure_model.writes;
        try t.expectError(expected, failed.step());
        try t.expectEqual(writes, failure_model.writes);
        try t.expect(failure_model.triggers <= 1);
    }
    var unsupported = Model.init();
    unsupported.config[reset.reg.device_capability / 4] = 0;
    var missing: reset.Config = .{};
    try t.expectError(error.Unsupported, missing.capture(&unsupported.snapshot(), boot0, 0, unsupported.io()));
    try t.expect(!missing.valid() and unsupported.writes == 0);
    var unopened: reset.Reset = .{};
    try t.expectError(error.Unsupported, unopened.open(&missing, unsupported.epoch, unsupported.io()));

    var changed = Model.init(); var config: reset.Config = .{}; var stale: reset.Reset = .{};
    try config.capture(&changed.snapshot(), boot0, 0, changed.io());
    try stale.open(&config, changed.epoch, changed.io());
    changed.epoch += 1;
    try t.expectError(error.Stale, stale.step());
    try t.expect(stale.quiescence() == null and changed.writes == 0);

    var posted = Model.init(); var post_config: reset.Config = .{}; var post: reset.Reset = .{};
    try post_config.capture(&posted.snapshot(), boot0, 0, posted.io());
    try post.open(&post_config, posted.epoch, posted.io());
    try posted.drive(&post);
    const old_proof = post.quiescence().?;
    posted.fail_resume = true;
    try t.expectError(error.Posted, post.resumeDma());
    try t.expect(!old_proof.valid(posted.epoch) and post.quiescence() == null);
}
