//! Whole held boot-surface translation and immutable dependency-page backup.
//! Driver init/work owner only. This records existing mappings, never changes
//! them, and provides no firmware/DMA quiescence or scanout recovery grant.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const boot = @import("boot_vram.zig");
const reader = @import("bar1_reader.zig");
const walk = @import("bar1_walk.zig");
const layout = @import("gsp_layout.zig");
pub const max_surface_bytes = 64 * 1024 * 1024;
pub const max_ranges = 1024;
pub const max_pages = 128;
const backup_bytes = max_pages * 4096;
pub const Report = struct { bytes: u64, ranges: usize, pages: usize, format: walk.Format, sha256: [32]u8, window_writes: u32 };
pub const Capture = struct {
    self_address: usize = 0,
    parent: ?*boot.Capture = null,
    epoch: u64 = 0,
    memory: ?r4os.driver_memory.Context = null,
    io: reader.Reader = .{},
    reference: a.GfxBufferReference = .{},
    map: a.GfxBufferMap = .{},
    stamp: a.GfxBufferMap = .{},
    ranges: [max_ranges]walk.Span = undefined,
    range_count: usize = 0,
    pages: [max_pages]u64 = undefined,
    page_count: usize = 0,
    control: ?walk.Control = null,
    format: walk.Format = .physical,
    framebuffer_bytes: u64 = 0,
    surface_bytes: u64 = 0,
    scratch: [4096]u8 = undefined,
    ready: bool = false,
    last_status: i32 = 0,

    pub fn capture(self: *Capture, parent: *boot.Capture) !Report {
        if (self.self_address != 0) return error.Busy;
        const info = parent.original_boot orelse return error.Owner;
        if (parent.mapping_owner != 0 or parent.borrower != 0 or parent.self_address != @intFromPtr(parent) or !parent.ready) return error.Owner;
        if (info.byte_length == 0 or info.byte_length > max_surface_bytes) return error.Capacity;
        self.self_address = @intFromPtr(self);
        self.parent = parent;
        self.epoch = parent.boot.held_generation;
        self.memory = parent.memory;
        self.surface_bytes = info.byte_length;
        parent.mapping_owner = self.self_address;
        try self.io.open(parent);
        self.framebuffer_bytes = self.io.framebuffer_bytes;
        var offset: u64 = 0;
        while (offset < info.byte_length) {
            const result = try walk.resolve(.{ .epoch = self.epoch, .deadline = self.io.deadline, .boot0 = self.io.boot0, .boot1 = self.io.boot1, .bar = parent.snapshot.?.bars[1], .framebuffer_bytes = self.framebuffer_bytes, .cpu_physical = try std.math.add(u64, info.physical_address, offset), .bytes = info.byte_length - offset }, self.io.port());
            if (self.control) |control| {
                if (!std.meta.eql(control, result.control) or self.format != result.format) return error.Unstable;
            } else {
                self.control = result.control;
                self.format = result.format;
            }
            try self.addRange(result.mapped);
            for (result.entries[0..result.entry_count]) |*entry| try self.preserve(entry);
            offset += result.mapped.bytes;
        }
        // Compare every complete page, including unused bytes and paths shared
        // by earlier leaves. A raw 8/16-byte entry is never called a backup.
        for (self.pages[0..self.page_count], 0..) |address, index| {
            try self.io.read(address, &self.scratch);
            if (!std.mem.eql(u8, &self.scratch, self.data()[index * 4096 ..][0..4096])) return error.Unstable;
        }
        if (!std.meta.eql(self.control.?, try self.io.controls())) return error.Unstable;
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        if (self.page_count != 0) digest.update(self.data()[0 .. self.page_count * 4096]);
        var hash: [32]u8 = undefined;
        digest.final(&hash);
        const writes = self.io.window_writes;
        if (!self.io.close()) return error.Cleanup;
        if (self.map.lease.id != 0) {
            self.last_status = self.memory.?.bufferUnmap(&self.map.lease);
            if (self.last_status != a.gfx_buffer_result_ok) return error.Buffer;
            self.map = .{};
            self.stamp = .{};
            try self.mapBackup(a.gfx_buffer_map_read);
        }
        self.ready = true;
        return .{ .bytes = info.byte_length, .ranges = self.range_count, .pages = self.page_count, .format = self.format, .sha256 = hash, .window_writes = writes };
    }
    fn data(self: *const Capture) []u8 {
        const pointer: [*]u8 = @ptrFromInt(self.map.cpu_address);
        return pointer[0..backup_bytes];
    }
    fn mapBackup(self: *Capture, access: u32) !void {
        self.last_status = self.memory.?.bufferMap(&self.reference.reference, access, 0, backup_bytes, &self.map);
        self.stamp = self.map;
        if (self.last_status != a.gfx_buffer_result_ok or self.map.lease.id == 0 or self.map.cpu_address == 0 or
            self.map.byte_length != backup_bytes or self.map.cpu_address > std.math.maxInt(u64) - backup_bytes) return error.Buffer;
    }
    fn preserve(self: *Capture, entry: *const walk.Entry) !void {
        const address = entry.address & ~@as(u64, 4095);
        const offset: usize = @intCast(entry.address - address);
        if (entry.bytes > 4096 - offset) return error.Bounds;
        var index: usize = 0;
        while (index < self.page_count and self.pages[index] != address) : (index += 1) {}
        if (index == self.page_count) {
            if (index == max_pages) return error.Capacity;
            if (self.reference.reference.id == 0) {
                self.last_status = self.memory.?.bufferCreate(&.{ .byte_length = backup_bytes, .alignment = 4096, .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write }, &self.reference);
                if (self.last_status != a.gfx_buffer_result_ok) return error.Buffer;
                try self.mapBackup(a.gfx_buffer_map_write);
            }
            try self.io.read(address, self.data()[index * 4096 ..][0..4096]);
            self.pages[index] = address;
            self.page_count += 1;
        }
        if (!std.mem.eql(u8, entry.value[0..entry.bytes], self.data()[index * 4096 + offset ..][0..entry.bytes])) return error.Unstable;
    }
    fn addRange(self: *Capture, value: walk.Span) !void {
        if (value.bytes == 0) return error.Bounds;
        if (self.range_count != 0) {
            const previous = &self.ranges[self.range_count - 1];
            if (previous.address + previous.bytes == value.address) {
                previous.bytes += value.bytes;
                return;
            }
        }
        if (self.range_count == max_ranges) return error.Capacity;
        self.ranges[self.range_count] = value;
        self.range_count += 1;
    }
    pub fn valid(self: *const Capture, parent: *const boot.Capture) bool {
        return self.self_address == @intFromPtr(self) and self.ready and self.parent == parent and
            parent.self_address == @intFromPtr(parent) and parent.ready and parent.mapping_owner == self.self_address and
            parent.boot.held_generation == self.epoch and self.epoch != 0 and self.io.self_address == 0 and
            (self.page_count == 0 or (self.reference.reference.id != 0 and self.map.lease.id != 0 and std.meta.eql(self.map, self.stamp)));
    }
    fn overlaps(address: u64, bytes: u64, reserved: layout.Range) bool {
        return address < reserved.end() and reserved.offset < address + bytes;
    }
    /// The old surface and every full dependency page must survive all planned
    /// GSP destinations. General VRAM allocation remains blocked by the lease.
    pub fn admit(self: *Capture, parent: *boot.Capture, plan: *const layout.Plan) !void {
        if (!self.valid(parent)) return error.MappingOwner;
        if (self.framebuffer_bytes != plan.fb_bytes) return error.PlanChanged;
        for (self.ranges[0..self.range_count]) |range|
            if (overlaps(range.address, range.bytes, plan.reserved)) return error.BootSurfaceCollision;
        for (self.pages[0..self.page_count]) |address|
            if (overlaps(address, 4096, plan.reserved)) return error.BootTableCollision;
        self.reobserve(parent) catch |err| {
            if (!self.io.close()) return error.Cleanup;
            return err;
        };
    }
    fn reobserve(self: *Capture, parent: *boot.Capture) !void {
        const control = self.control orelse return error.MappingOwner;
        try self.io.open(parent);
        if (!std.meta.eql(control, try self.io.controls())) return error.BootMappingChanged;
        for (self.pages[0..self.page_count], 0..) |address, index| {
            try self.io.read(address, &self.scratch);
            // Even bytes outside the previously used PTEs must match. A
            // stable descriptor alone cannot prove the saved translation.
            if (!std.mem.eql(u8, &self.scratch, self.data()[index * 4096 ..][0..4096])) return error.BootMappingChanged;
        }
        if (!std.meta.eql(control, try self.io.controls())) return error.BootMappingChanged;
        if (!self.io.close()) return error.Cleanup;
        _ = try parent.reobserve();
    }
    pub fn close(self: *Capture) bool {
        if (self.self_address == 0) return true;
        const parent = self.parent orelse return false;
        if (self.self_address != @intFromPtr(self) or parent.self_address != @intFromPtr(parent) or
            parent.mapping_owner != self.self_address or parent.borrower != 0 or parent.boot.held_generation != self.epoch) return false;
        if (!self.io.close()) return false;
        if (!std.meta.eql(self.map, self.stamp)) return false;
        if (self.map.lease.id != 0) {
            self.last_status = self.memory.?.bufferUnmap(&self.map.lease);
            if (self.last_status != a.gfx_buffer_result_ok) return false;
            self.map = .{};
            self.stamp = .{};
        }
        if (self.reference.reference.id != 0) {
            self.last_status = self.memory.?.bufferRelease(&self.reference.reference);
            if (self.last_status != a.gfx_buffer_result_ok) return false;
            self.reference = .{};
        }
        parent.mapping_owner = 0;
        self.* = .{};
        return true;
    }
};
