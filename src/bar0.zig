//! One resident GA106 BAR0 mapping with bounded, address-stable borrowers.
//! Views never carry a kernel unmap handle. The mapping grants no register
//! policy, device mutation, reset or quiescence; each consumer owns that work.
//! Serialized driver init/work owner only, never concurrent or IRQ mutation.
//! A pinned IRQ consumer may use an immutable View while retaining its lease;
//! acquisition, validation and release of that lease remain in Init/Work.
const std = @import("std");
const r4os = @import("r4os");
const identity = @import("identity.zig");
const a = r4os.abi;
pub const max_borrowers = 8;
pub const Error = error{ Busy, Profile, Api, Mapping, Stale, Bounds, Capacity, Exhausted };
pub const View = struct { cpu_address: u64, physical_address: u64, byte_length: u64 };
const Borrower = struct { address: usize = 0, serial: u64 = 0 };
pub const Owner = struct {
    self_address: usize = 0,
    api: ?*const a.DriverApi = null,
    memory: ?r4os.driver_memory.Context = null,
    pci: identity.Pci = .{},
    bar: identity.Bar = .{},
    chip_id: u16 = 0,
    chip_revision: u8 = 0,
    window: a.GfxMmioWindow = .{},
    stamp: a.GfxMmioWindow = .{},
    borrowers: [max_borrowers]Borrower = @splat(.{}),
    serial: u64 = 0,
    ready: bool = false,
    cleanup_needed: bool = false,
    last_status: i32 = 0,

    pub fn open(self: *Owner, ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, chip: identity.Chip) Error!void {
        if (self.self_address != 0) return error.Busy;
        const bar = snapshot.bars[0];
        if (identity.decision(snapshot) != .identity_words_only or chip.id != 0x176 or
            bar.bytes < 0x821000 or bar.bytes > 0x100000000 or bar.bytes & 4095 != 0 or
            bar.base > std.math.maxInt(u64) - bar.bytes) return error.Profile;
        const memory = ctx.memory() orelse return error.Api;
        self.* = .{ .self_address = @intFromPtr(self), .api = ctx.api, .memory = memory, .pci = snapshot.pci, .bar = bar, .chip_id = chip.id, .chip_revision = chip.revision, .serial = self.serial, .cleanup_needed = true };
        self.last_status = memory.mmioMap(&.{ .resource_base = bar.base, .resource_bytes = bar.bytes, .byte_length = bar.bytes, .cache_policy = a.gfx_buffer_cache_uncached }, &self.window);
        self.stamp = self.window; // Retain any descriptor, including partial failure.
        if (self.last_status != a.gfx_buffer_result_ok) return error.Mapping;
        const window = &self.window;
        if (window.version != 1 or window.size < @sizeOf(a.GfxMmioWindow) or window.handle.id == 0 or window.handle.generation == 0 or
            window.cpu_address == 0 or window.cpu_address & 4095 != 0 or window.cpu_address > std.math.maxInt(u64) - bar.bytes or
            window.physical_address != bar.base or window.byte_length != bar.bytes or window.cache_policy != a.gfx_buffer_cache_uncached) return error.Mapping;
        self.ready = true;
    }
    pub fn valid(self: *const Owner) bool {
        return self.self_address != 0 and self.self_address == @intFromPtr(self) and self.ready and
            self.api != null and self.memory != null and std.meta.eql(self.window, self.stamp);
    }
    fn matches(self: *const Owner, ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, chip: identity.Chip) bool {
        return self.valid() and self.api == ctx.api and identity.decision(snapshot) == .identity_words_only and
            std.meta.eql(self.pci, snapshot.pci) and std.meta.eql(self.bar, snapshot.bars[0]) and
            chip.id == self.chip_id and chip.revision == self.chip_revision;
    }
    pub fn borrowedCount(self: *const Owner) usize {
        var count: usize = 0;
        for (&self.borrowers) |*borrower| count += @intFromBool(borrower.address != 0);
        return count;
    }
    pub fn close(self: *Owner) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or self.borrowedCount() != 0 or !std.meta.eql(self.window, self.stamp)) return false;
        self.ready = false;
        if (self.memory) |memory| {
            if (self.window.handle.id != 0) {
                const handle = self.window.handle;
                self.last_status = memory.mmioUnmap(&handle, 1);
                if (self.last_status != a.gfx_buffer_result_ok) return false;
                self.window = .{};
                self.stamp = .{};
            }
            if (self.cleanup_needed) {
                self.last_status = memory.collect();
                if (self.last_status != a.gfx_buffer_result_ok) return false;
            }
        }
        self.* = .{ .serial = self.serial };
        return true;
    }
};

pub const Lease = struct {
    self_address: usize = 0,
    owner: ?*Owner = null,
    slot: usize = 0,
    serial: u64 = 0,
    stamp: a.GfxMmioWindow = .{},

    /// No allocation or kernel call after publishing either owner address.
    pub fn acquire(self: *Lease, owner: *Owner, ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, chip: identity.Chip) Error!void {
        if (self.self_address != 0) return error.Busy;
        if (!owner.matches(ctx, snapshot, chip)) return error.Stale;
        if (owner.serial == std.math.maxInt(u64)) return error.Exhausted;
        for (&owner.borrowers, 0..) |*borrower, index| {
            if (borrower.address != 0) continue;
            owner.serial += 1;
            self.* = .{ .self_address = @intFromPtr(self), .owner = owner, .slot = index, .serial = owner.serial, .stamp = owner.window };
            borrower.* = .{ .address = self.self_address, .serial = self.serial };
            return;
        }
        return error.Capacity;
    }
    pub fn valid(self: *const Lease) bool {
        if (self.self_address == 0 or self.self_address != @intFromPtr(self) or self.slot >= max_borrowers) return false;
        const owner = self.owner orelse return false;
        const borrower = owner.borrowers[self.slot];
        return owner.valid() and borrower.address == self.self_address and borrower.serial == self.serial and
            std.meta.eql(owner.window, self.stamp);
    }
    pub fn view(self: *const Lease, offset: u64, bytes: u64) Error!View {
        if (!self.valid()) return error.Stale;
        if (bytes == 0 or offset > self.stamp.byte_length or bytes > self.stamp.byte_length - offset) return error.Bounds;
        return .{ .cpu_address = self.stamp.cpu_address + offset, .physical_address = self.stamp.physical_address + offset, .byte_length = bytes };
    }
    /// Exact descriptor for an existing port's bounds/identity checks. Its
    /// handle is observational: a borrower releases only through this lease.
    pub fn whole(self: *const Lease) Error!a.GfxMmioWindow {
        if (!self.valid()) return error.Stale;
        return self.stamp;
    }
    pub fn release(self: *Lease) bool {
        if (self.self_address == 0) return true;
        if (!self.valid()) return false;
        self.owner.?.borrowers[self.slot] = .{};
        self.* = .{};
        return true;
    }
};
