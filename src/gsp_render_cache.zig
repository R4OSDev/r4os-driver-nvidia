//! Device-generation shader and packet storage. Upload completion is supplied
//! only by the runtime's actual CE path; a CPU write does not make it ready.
const std = @import("std");
const render = @import("r4nv_render");
const storage = @import("gsp_native_backing.zig");
pub const Kind = enum { programs, packet };
// Fixed programs and one reusable descriptor/vertex/color packet. Physical
// allocation granularity is included; this cache cannot grow with frames.
pub const budget_bytes: u64 = 128 * 1024;
pub const slot_budget_bytes: u64 = budget_bytes / 2;
pub const Owner = struct {
    self_address: usize = 0,
    programs: storage.Use = .{},
    packet: storage.Use = .{},
    epoch: u64 = 0,
    program_point: u32 = 0,
    packet_point: u32 = 0,
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
    uploaded_bytes: u64 = 0,

    pub fn initialize(self: *Owner, epoch: u64) !void {
        if (self.self_address != 0 or epoch == 0) return error.State;
        self.* = .{ .self_address = @intFromPtr(self), .epoch = epoch };
    }
    pub fn valid(self: *const Owner) bool {
        return self.self_address == @intFromPtr(self) and self.epoch != 0 and !self.failed and
            self.additional_count < render.batch_capacity and self.pending_count < render.batch_capacity;
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
        if (self.program_point == 0 or self.packet_point == 0 or self.draw == null) return false;
        // binding verifies generation, backing identity, adapter/owner and
        // address/format bounds before any descriptor bytes can be reused.
        const current = try self.binding();
        if (!current.matches(draws)) return false;
        self.packet_reuses +|= 1;
        return true;
    }
    pub fn beginUpload(self: *Owner, kind: Kind, draw: ?render.Draw, bytes: []u8) !void {
        return self.beginUploadList(kind, if (draw) |value| &.{value} else &.{}, bytes);
    }
    pub fn beginUploadList(self: *Owner, kind: Kind, draws: []const render.Draw, bytes: []u8) !void {
        if (!self.valid() or self.borrowed or self.uploading != null) return error.Busy;
        if ((kind == .programs and draws.len != 0) or
            (kind == .packet and (draws.len == 0 or draws.len > render.batch_capacity))) return error.Descriptor;
        const info = self.buffer(kind).info() orelse return error.State;
        if (info.epoch != self.epoch) return error.Stale;
        try (render.Range{ .address = info.address, .bytes = info.bytes }).validate(256,
            if (kind == .programs) render.shader_bytes else render.packet_bytes * draws.len);
        switch (kind) {
            .programs => {
                if (self.program_point != 0) return error.State;
                try render.shaderUpload(bytes);
            },
            .packet => {
                if (self.program_point == 0) return error.State;
                try render.packetUploadList(draws, bytes);
                self.pending_draw = draws[0];
                self.pending_count = draws.len - 1;
                @memcpy(self.pending_additional[0..self.pending_count], draws[1..]);
                // Invalidate the previous packet before any changed bytes
                // can reach the GPU, including a subsequently canceled copy.
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
            self.program_point = point; self.program_uploads +|= 1; self.uploaded_bytes +|= render.shader_bytes;
        } else {
            self.draw = self.pending_draw orelse return error.State;
            self.additional_count = self.pending_count;
            @memcpy(self.additional[0..self.additional_count], self.pending_additional[0..self.pending_count]);
            self.pending_count = 0;
            self.pending_draw = null; self.packet_point = point;
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
        const programs = self.programs.info() orelse return error.Stale;
        const packet = self.packet.info() orelse return error.Stale;
        if (programs.epoch != self.epoch or packet.epoch != self.epoch or programs.adapter != packet.adapter or programs.driver_owner != packet.driver_owner) return error.Stale;
        const result: render.Binding = .{ .draw = self.draw orelse return error.State,
            .additional = self.additional[0..self.additional_count],
            .programs = .{ .address = programs.address, .bytes = programs.bytes },
            .packet = .{ .address = packet.address, .bytes = packet.bytes } };
        try result.validate();
        return result;
    }
    pub fn acquire(self: *Owner) !render.Binding {
        if (self.borrowed) return error.Busy;
        const result = try self.binding();
        self.borrowed = true; return result;
    }
    pub fn release(self: *Owner) !void {
        if (!self.valid() or !self.borrowed) return error.State;
        self.borrowed = false;
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
