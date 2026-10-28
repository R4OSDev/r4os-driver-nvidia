//! Device-generation shader storage and three immutable resident packets.
//! CE publishes bytes, GR retires their borrow; neither USERD nor a deadline
//! allows a packet to be overwritten while the device can still read it.
const std = @import("std");
const a = @import("r4os").abi;
const render = @import("r4nv_render");
const storage = @import("gsp_native_backing.zig");
pub const Kind = enum { programs, packet };
// Three full 16-draw packets fit in the already charged 64-KB packet BO.
// Programs occupy the other 64 KB. No growth with frames or producers.
pub const budget_bytes: u64 = 128 * 1024;
pub const slot_budget_bytes: u64 = budget_bytes / 2;
pub const packet_slots = 3;
pub const packet_storage_bytes = packet_slots * render.packet_capacity_bytes;
comptime { if (packet_storage_bytes > slot_budget_bytes) @compileError("render packet ring budget"); }
const Packet = struct {
    draw: ?render.Draw = null,
    additional: [render.batch_capacity - 1]render.Draw = undefined,
    count: usize = 0,
    ce_point: u32 = 0,
    queue_fence: a.GfxFence = .{},
    gr_submitted: u32 = 0,
    gr_completed: u32 = 0,
};
pub const Owner = struct {
    self_address: usize = 0,
    programs: storage.Use = .{},
    packet: storage.Use = .{},
    epoch: u64 = 0,
    class: u32 = 0,
    program_point: u32 = 0,
    packet_point: u32 = 0,
    packets: [packet_slots]Packet = @splat(.{}),
    packet_slot: usize = 0,
    next_packet: usize = 0,
    submission_point: u32 = 0,
    draw: ?render.Draw = null,
    additional: [render.batch_capacity - 1]render.Draw = undefined,
    additional_count: usize = 0,
    pending_draw: ?render.Draw = null,
    pending_additional: [render.batch_capacity - 1]render.Draw = undefined,
    pending_count: usize = 0,
    uploading: ?Kind = null,
    borrowed: bool = false,
    failed: bool = false,
    program_uploads: u64 = 0,
    packet_uploads: u64 = 0,
    packet_reuses: u64 = 0,
    packet_rebinds: u64 = 0,
    last_reuse_rebound: bool = false,
    last_reuse_resident: bool = false,
    resident_reuses: u64 = 0,
    resident_completed: u64 = 0,
    // CPU-only bounded comparison; the resident GPU packet is never written.
    previous_packet: [render.packet_bytes]u8 = undefined,
    candidate_packet: [render.packet_bytes]u8 = undefined,
    uploaded_bytes: u64 = 0,

    pub fn initialize(self: *Owner, epoch: u64) !void {
        return self.initializeFor(epoch, 0xc797);
    }
    pub fn initializeFor(self: *Owner, epoch: u64, class: u32) !void {
        if (self.self_address != 0 or epoch == 0) return error.State;
        _ = try render.shaderBytesFor(class);
        self.* = .{ .self_address = @intFromPtr(self), .epoch = epoch, .class = class };
    }
    pub fn valid(self: *const Owner) bool {
        return self.self_address == @intFromPtr(self) and self.epoch != 0 and render.profiles.get(self.class) != null and !self.failed and
            self.additional_count < render.batch_capacity and self.pending_count < render.batch_capacity and
            self.packet_slot < packet_slots and self.next_packet < packet_slots;
    }
    pub fn buffer(self: *Owner, kind: Kind) *storage.Use {
        return if (kind == .programs) &self.programs else &self.packet;
    }
    pub fn reservedBytes(self: *const Owner) u64 {
        var bytes: u64 = 0;
        // Retained/partially closed storage still consumes its reservation.
        for ([_]*const storage.Use{&self.programs,&self.packet}) |use| if (use.source_stamp) |source| { bytes +|= source.physical.bytes; };
        return bytes;
    }
    pub fn admitStorage(self: *Owner, kind: Kind, bytes: u64) !void {
        if (!self.valid() or self.borrowed or self.uploading != null or self.buffer(kind).self_address != 0) return error.Busy;
        if (bytes == 0 or bytes > slot_budget_bytes or self.reservedBytes() > budget_bytes-bytes) return error.Exhausted;
    }
    pub fn reusePacket(self: *Owner, draw: render.Draw) !bool {
        return self.reusePacketList(&.{draw});
    }
    pub fn reusePacketList(self: *Owner, draws: []const render.Draw) !bool {
        if (!self.valid() or self.borrowed or self.uploading != null) return error.Busy;
        self.last_reuse_rebound = false;
        self.last_reuse_resident = false;
        if (draws.len == 0 or draws.len > render.batch_capacity) return error.Descriptor;
        if (self.program_point == 0) return false;
        const ranges = try self.storageRanges();
        // Check against the entire private packet BO, including other slots.
        try (render.Binding{ .class = self.class, .draw = draws[0], .additional = draws[1..],
            .programs = ranges.programs, .packet = ranges.packet }).validate();
        // Prefer the current slot, then inspect the other bounded residents.
        for (0..packet_slots) |offset| {
            const slot = (self.packet_slot + offset) % packet_slots;
            const packet = &self.packets[slot];
            if (packet.ce_point == 0 or packet.draw == null or packet.count + 1 != draws.len or
                packet.gr_submitted != packet.gr_completed) continue;
            const current = try self.packetBinding(slot);
            const rebound = !current.matches(draws);
            if (rebound) {
                var same = true;
                for (draws, 0..) |draw, index| {
                    try render.packetUpload(if (index == 0) current.draw else current.additional[index-1], &self.previous_packet);
                    try render.packetUpload(draw, &self.candidate_packet);
                    if (!std.mem.eql(u8, &self.previous_packet, &self.candidate_packet)) { same = false; break; }
                }
                if (!same) continue;
            }
            self.last_reuse_resident = slot != self.packet_slot;
            if (self.last_reuse_resident) self.resident_reuses +|= 1;
            packet.draw = draws[0];
            std.mem.copyForwards(render.Draw, packet.additional[0..packet.count], draws[1..]);
            self.selectPacket(slot);
            if (rebound) { self.packet_rebinds +|= 1; self.last_reuse_rebound = true; }
            self.packet_reuses +|= 1;
            return true;
        }
        return false;
    }
    pub fn beginUpload(self: *Owner, kind: Kind, draw: ?render.Draw, bytes: []u8) !void {
        return self.beginUploadList(kind, if (draw) |value| &.{value} else &.{}, bytes);
    }
    pub fn beginUploadList(self: *Owner, kind: Kind, draws: []const render.Draw, bytes: []u8) !void {
        if (!self.valid() or self.borrowed or self.uploading != null) return error.Busy;
        self.last_reuse_rebound = false;
        self.last_reuse_resident = false;
        if ((kind == .programs and draws.len != 0) or
            (kind == .packet and (draws.len == 0 or draws.len > render.batch_capacity))) return error.Descriptor;
        const info = self.buffer(kind).info() orelse return error.State;
        if (info.epoch != self.epoch) return error.Stale;
        try (render.Range{ .address = info.address, .bytes = info.bytes }).validate(256,
            if (kind == .programs) try render.shaderBytesFor(self.class) else render.packet_bytes * draws.len);
        switch (kind) {
            .programs => {
                if (self.program_point != 0) return error.State;
                try render.shaderUploadFor(self.class, bytes);
            },
            .packet => {
                if (self.program_point == 0) return error.State;
                const slot = self.next_packet;
                const old = &self.packets[slot];
                if (old.gr_submitted != old.gr_completed) return error.Retained;
                if (info.bytes < packet_storage_bytes) return error.Bounds;
                try render.packetUploadList(draws, bytes);
                self.packet_slot = slot;
                self.next_packet = (slot + 1) % packet_slots;
                old.* = .{};
                self.pending_draw = draws[0];
                self.pending_count = draws.len - 1;
                @memcpy(self.pending_additional[0..self.pending_count], draws[1..]);
                // Invalidate only this destination before any changed byte
                // can reach it. Other completed residents remain immutable.
                self.packet_point = 0;
                self.draw = null;
                self.additional_count = 0;
            },
        }
        self.uploading = kind;
    }
    pub fn completeUpload(self: *Owner, kind: Kind, point: u32) !void {
        if (!self.valid() or self.uploading != kind or point == 0) return error.State;
        if (kind == .programs) {
            self.program_point = point; self.program_uploads +|= 1; self.uploaded_bytes +|= try render.shaderBytesFor(self.class);
        } else {
            self.draw = self.pending_draw orelse return error.State;
            self.additional_count = self.pending_count;
            @memcpy(self.additional[0..self.additional_count], self.pending_additional[0..self.pending_count]);
            self.pending_count = 0;
            self.pending_draw = null; self.packet_point = point;
            const packet = &self.packets[self.packet_slot];
            packet.* = .{ .draw = self.draw, .count = self.additional_count, .ce_point = point };
            @memcpy(packet.additional[0..packet.count], self.additional[0..self.additional_count]);
            self.packet_uploads +|= 1; self.uploaded_bytes +|= render.packet_bytes * (1 + self.additional_count);
        }
        self.uploading = null;
    }
    pub fn cancelUpload(self: *Owner) !void {
        if (!self.valid() or self.uploading == null) return error.State;
        self.uploading = null; self.pending_draw = null; self.pending_count = 0;
    }
    pub fn binding(self: *const Owner) !render.Binding {
        if (!self.valid() or self.uploading != null or self.program_point == 0 or self.packet_point == 0) return error.State;
        var result = try self.packetBinding(self.packet_slot);
        // The active mirror is stamped by render_job; edits must remain
        // visible to that owner's existing descriptor validation.
        result.draw = self.draw orelse return error.State;
        result.additional = self.additional[0..self.additional_count];
        try result.validate();
        return result;
    }
    fn storageRanges(self: *const Owner) !struct { programs: render.Range, packet: render.Range } {
        const programs = self.programs.info() orelse return error.Stale;
        const packet = self.packet.info() orelse return error.Stale;
        if (programs.epoch != self.epoch or packet.epoch != self.epoch or programs.adapter != packet.adapter or programs.driver_owner != packet.driver_owner) return error.Stale;
        return .{ .programs = .{ .address = programs.address, .bytes = programs.bytes }, .packet = .{ .address = packet.address, .bytes = packet.bytes } };
    }
    fn packetBinding(self: *const Owner, slot: usize) !render.Binding {
        const ranges = try self.storageRanges();
        const packet = &self.packets[slot];
        if (packet.ce_point == 0 or packet.draw == null or packet.count >= render.batch_capacity or ranges.packet.bytes < packet_storage_bytes) return error.State;
        const result: render.Binding = .{ .class = self.class, .draw = packet.draw.?,
            .additional = packet.additional[0..packet.count],
            .programs = ranges.programs,
            .packet = .{ .address = ranges.packet.address + slot * render.packet_capacity_bytes, .bytes = render.packet_capacity_bytes } };
        try result.validate();
        return result;
    }
    fn selectPacket(self: *Owner, slot: usize) void {
        const packet = &self.packets[slot];
        self.packet_slot = slot; self.packet_point = packet.ce_point; self.draw = packet.draw;
        self.additional_count = packet.count;
        @memcpy(self.additional[0..packet.count], packet.additional[0..packet.count]);
    }
    pub fn uploadOffset(self: *const Owner) u64 {
        return if (self.uploading == .packet) self.packet_slot * render.packet_capacity_bytes else 0;
    }
    pub fn bindQueueFence(self: *Owner, fence: a.GfxFence) !void {
        if (!self.borrowed or self.submission_point != 0 or fence.timeline == 0 or fence.point == 0 or
            fence.device_generation == 0 or fence.reset_generation == 0) return error.Binding;
        self.packets[self.packet_slot].queue_fence = fence;
    }
    pub fn submitted(self: *Owner, point: u32) !void {
        if (!self.valid() or !self.borrowed or self.submission_point != 0 or point == 0) return error.State;
        const packet = &self.packets[self.packet_slot];
        if (packet.gr_submitted != packet.gr_completed) return error.Retained;
        self.submission_point = point; packet.gr_submitted = point;
    }
    pub fn completed(self: *Owner, point: u32) !void {
        if (!self.valid() or !self.borrowed or point == 0 or point != self.submission_point) return error.State;
        const packet = &self.packets[self.packet_slot];
        if (packet.gr_submitted != point) return error.Stale;
        packet.gr_completed = point; self.submission_point = 0;
        if (self.last_reuse_resident) self.resident_completed +|= 1;
    }
    pub fn acquire(self: *Owner) !render.Binding {
        if (self.borrowed) return error.Busy;
        const result = try self.binding();
        self.packets[self.packet_slot].queue_fence = .{};
        self.borrowed = true; return result;
    }
    pub fn release(self: *Owner) !void {
        if (!self.valid() or !self.borrowed or self.submission_point != 0) return error.State;
        self.borrowed = false;
    }
    pub fn releaseAfterReset(self: *Owner, proof: @import("gsp_reset.zig").Quiescence) bool {
        // stop() deliberately marks this cache failed. Only the exact old
        // epoch's reset proof may revoke that failed owner's outstanding use.
        if (self.self_address != @intFromPtr(self) or !self.borrowed or !proof.valid(self.epoch)) return false;
        self.submission_point = 0; self.borrowed = false;
        return true;
    }
    pub fn close(self: *Owner, quiesced: bool) bool {
        if (self.self_address == 0) return true;
        if (!self.valid() or self.uploading != null or self.borrowed or !quiesced) return false;
        if (!self.packet.close(true) or !self.programs.close(true)) return false;
        self.* = .{}; return true;
    }
    pub fn closeAfterReset(self: *Owner, proof: @import("gsp_reset.zig").Quiescence) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or !proof.valid(self.epoch) or self.borrowed or self.uploading != null) return false;
        if (!self.packet.closeAfterReset(proof) or !self.programs.closeAfterReset(proof)) return false;
        self.* = .{}; return true;
    }
};
