//! Exclusive first-boot VRAM reservation bound to the real display/VGA
//! snapshots and the exact prepared GSP metadata. All framebuffer memory
//! remains unavailable to general allocations during this boot reservation:
//! the old scanout's GPU mapping has not yet been resolved. No GPU command,
//! VGA relocation, page table or post-submission recovery is provided here.
const std = @import("std");
const capture = @import("boot_vram.zig");
const storage = @import("gsp_boot_storage.zig");
const layout = @import("gsp_layout.zig");
const boot = @import("gsp_boot.zig");
const wpr = @import("gsp_wpr.zig");
pub const Target = enum { non_wpr_heap, metadata, heap, firmware, boot_image, frts, vga };
pub const Binding = struct { owner: usize, epoch: u64, serial: u64, target: Target, range: layout.Range };
pub const Lease = struct {
    self_address: usize = 0,
    display: ?*capture.Capture = null,
    backing: ?*storage.Storage = null,
    epoch: u64 = 0,
    serial: u64 = 0,
    plan: ?layout.Plan = null,
    allocation: u64 = 0,
    mapping: u64 = 0,
    pin: u64 = 0,
    cpu_address: u64 = 0,
    metadata_address: u64 = 0,

    /// Serialized native init/work owner. Reject every stale input before
    /// publishing either borrow; no fallible operation follows publication.
    pub fn acquire(self: *Lease, display: *capture.Capture, backing: *storage.Storage) !void {
        if (self.self_address != 0) return error.Busy;
        if (self.serial == std.math.maxInt(u64)) return error.Exhausted;
        if (!display.ready or display.self_address != @intFromPtr(display) or display.borrower != 0 or
            backing.vram_owner != 0 or backing.execution_owner != 0 or backing.image.execution_owner != 0) return error.Owner;
        const ctx = display.context orelse return error.Owner;
        if (backing.context == null or backing.context.?.api != ctx.api) return error.Owner;
        const report = backing.report orelse return error.Storage;
        const staged = backing.vram_plan orelse return error.Storage;
        const allocation = backing.allocation;
        if (allocation.handle == 0 or allocation.cpu_address == 0 or allocation.byte_length != storage.pack_bytes or
            allocation.cpu_address > std.math.maxInt(u64) - storage.pack_bytes or
            backing.mapping.handle == 0 or backing.pin.handle == 0 or backing.mapping.pin_handle != backing.pin.handle or
            report.metadata_bytes != wpr.bytes) return error.Storage;
        const raw = try display.reobserve();
        const plan = try layout.firstBoot(display.chip.?.id, &raw, report.image.image_bytes, boot.image.bytes);
        if (!std.meta.eql(staged, plan)) return error.PlanChanged;
        const data: [*]const u8 = @ptrFromInt(allocation.cpu_address);
        if (!wpr.matchesPlan(data[storage.metadata_offset..][0..wpr.bytes], &plan)) return error.MetadataChanged;
        const epoch = display.boot.held_generation;
        if (epoch == 0) return error.Owner;
        self.* = .{ .self_address = @intFromPtr(self), .display = display, .backing = backing, .epoch = epoch, .serial = self.serial + 1, .plan = plan,
            .allocation = allocation.handle, .mapping = backing.mapping.handle, .pin = backing.pin.handle,
            .cpu_address = allocation.cpu_address, .metadata_address = report.metadata_address };
        display.borrower = self.self_address;
        backing.vram_owner = self.self_address;
    }

    fn owns(self: *const Lease) bool {
        if (self.self_address == 0 or self.self_address != @intFromPtr(self) or self.epoch == 0) return false;
        const display = self.display orelse return false;
        const backing = self.backing orelse return false;
        const report = backing.report orelse return false;
        return display.self_address == @intFromPtr(display) and display.ready and display.borrower == self.self_address and
            display.boot.held_generation == self.epoch and backing.vram_owner == self.self_address and
            backing.context != null and display.context != null and backing.context.?.api == display.context.?.api and
            backing.allocation.handle == self.allocation and backing.allocation.cpu_address == self.cpu_address and
            backing.allocation.byte_length == storage.pack_bytes and backing.mapping.handle == self.mapping and
            backing.mapping.pin_handle == self.pin and backing.pin.handle == self.pin and report.metadata_address == self.metadata_address;
    }

    /// A binding names one exact subregion of this reservation, not an MMIO
    /// write authorization. Recheck it before binding a future firmware command.
    pub fn binding(self: *const Lease, target: Target) !Binding {
        if (!self.owns()) return error.Stale;
        const plan = self.plan orelse return error.Stale;
        if (self.backing.?.vram_plan == null or !std.meta.eql(self.backing.?.vram_plan.?, plan)) return error.PlanChanged;
        const data: [*]const u8 = @ptrFromInt(self.cpu_address);
        if (!wpr.matchesPlan(data[storage.metadata_offset..][0..wpr.bytes], &plan)) return error.MetadataChanged;
        const range = switch (target) {
            .non_wpr_heap => plan.non_wpr_heap,
            .metadata => plan.metadata_reservation,
            .heap => plan.heap,
            .firmware => plan.firmware,
            .boot_image => plan.boot,
            .frts => plan.frts,
            .vga => plan.vga,
        };
        return .{ .owner = self.self_address, .epoch = self.epoch, .serial = self.serial, .target = target, .range = range };
    }

    pub fn validates(self: *const Lease, value: Binding) bool {
        if (value.owner != @intFromPtr(self) or value.epoch != self.epoch or value.serial != self.serial) return false;
        const current = self.binding(value.target) catch return false;
        return std.meta.eql(current.range, value.range);
    }

    /// Only after the unsubmitted DMA execution lease was released. Neither
    /// corrupt CPU metadata nor a clock timeout manufactures GPU quiescence.
    /// The current diagnostic never submits; any retained run blocks this path.
    pub fn releaseBeforeSubmission(self: *Lease) bool {
        if (self.self_address == 0) return true;
        if (!self.owns() or self.backing.?.execution_owner != 0 or self.backing.?.image.execution_owner != 0) return false;
        self.display.?.borrower = 0;
        self.backing.?.vram_owner = 0;
        self.* = .{ .serial = self.serial };
        return true;
    }
};
