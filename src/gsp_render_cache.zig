//! Device-generation shader and packet storage. Upload completion is supplied
//! only by the runtime's actual CE path; a CPU write does not make it ready.
const std = @import("std");
const render = @import("r4nv_render");
const storage = @import("gsp_native_backing.zig");
pub const Kind = enum { programs, packet };
pub const Owner = struct {
    self_address: usize = 0,
    programs: storage.Use = .{},
    packet: storage.Use = .{},
    epoch: u64 = 0,
    program_point: u32 = 0,
    packet_point: u32 = 0,
    draw: ?render.Draw = null,
    pending_draw: ?render.Draw = null,
    uploading: ?Kind = null,
    borrowed: bool = false,
    failed: bool = false,

    pub fn initialize(self: *Owner, epoch: u64) !void {
        if (self.self_address != 0 or epoch == 0) return error.State;
        self.* = .{ .self_address = @intFromPtr(self), .epoch = epoch };
    }
    pub fn valid(self: *const Owner) bool {
        return self.self_address == @intFromPtr(self) and self.epoch != 0 and !self.failed;
    }
    pub fn buffer(self: *Owner, kind: Kind) *storage.Use {
        return if (kind == .programs) &self.programs else &self.packet;
    }
    pub fn beginUpload(self: *Owner, kind: Kind, draw: ?render.Draw, bytes: []u8) !void {
        if (!self.valid() or self.borrowed or self.uploading != null) return error.Busy;
        const info = self.buffer(kind).info() orelse return error.State;
        if (info.epoch != self.epoch) return error.Stale;
        try (render.Range{ .address = info.address, .bytes = info.bytes }).validate(256,
            if (kind == .programs) render.shader_bytes else render.packet_bytes);
        switch (kind) {
            .programs => {
                if (draw != null or self.program_point != 0) return error.State;
                try render.shaderUpload(bytes);
            },
            .packet => {
                if (self.program_point == 0) return error.State;
                const value = draw orelse return error.Descriptor;
                try render.packetUpload(value, bytes);
                self.pending_draw = value;
                // Invalidate the previous packet before any changed bytes
                // can reach the GPU, including a subsequently canceled copy.
                self.packet_point = 0;
                self.draw = null;
            },
        }
        self.uploading = kind;
    }
    pub fn completeUpload(self: *Owner, kind: Kind, point: u32) !void {
        if (!self.valid() or self.uploading != kind or point == 0) return error.State;
        if (kind == .programs) self.program_point = point else {
            self.draw = self.pending_draw orelse return error.State;
            self.pending_draw = null; self.packet_point = point;
        }
        self.uploading = null;
    }
    pub fn cancelUpload(self: *Owner) !void {
        if (!self.valid() or self.uploading == null) return error.State;
        self.uploading = null; self.pending_draw = null;
    }
    pub fn binding(self: *const Owner) !render.Binding {
        if (!self.valid() or self.uploading != null or self.program_point == 0 or self.packet_point == 0) return error.State;
        const programs = self.programs.info() orelse return error.Stale;
        const packet = self.packet.info() orelse return error.Stale;
        if (programs.epoch != self.epoch or packet.epoch != self.epoch or programs.adapter != packet.adapter or programs.driver_owner != packet.driver_owner) return error.Stale;
        const result: render.Binding = .{ .draw = self.draw orelse return error.State,
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
};
