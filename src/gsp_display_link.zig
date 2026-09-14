//! One link transaction around the common Core/Window scanout. Protocol
//! owners encode only their own controls; no second display/queue lifetime.
const std = @import("std");
const hdmi = @import("gsp_hdmi_link.zig");
pub const dp = @import("gsp_dp_link.zig");
const boot = @import("gsp_boot_mode.zig");
const display = @import("gsp_display_rpc.zig");
const outputs = @import("gsp_outputs.zig");
const exchange = @import("gsp_exchange.zig");
pub const function: u32 = 76;
pub const Phase = hdmi.Phase;
pub const max_bytes = @max(hdmi.max_bytes, dp.max_bytes);
pub const Plan = struct {
    object: display.Object,
    mode: boot.Plan,
    transport: union(enum) { hdmi: hdmi.Plan, dp: dp.Plan },
};
pub fn derive(saved: boot.Plan, object: display.Object, snapshot: *const outputs.Snapshot) !Plan {
    return .{ .object = object, .mode = saved, .transport = if (saved.displayPort())
        .{ .dp = try dp.derive(saved, object, snapshot) } else .{ .hdmi = try hdmi.derive(saved, object, snapshot) } };
}
pub const Work = struct {
    plan: Plan,
    phase: Phase = .before_scanout,
    operation: enum { hdmi, dp },
    hdmi: ?hdmi.Work = null,
    dp: ?dp.Work = null,
    pending: bool = false,
    acknowledged: u8 = 0,
    last_receipt: u64 = 0,
    last_status: ?u32 = null,
    rpc_error: bool = false,
    request: [max_bytes]u8 = @splat(0),
    length: usize = 0,
    pub fn init(plan: Plan) Work {
        return switch (plan.transport) {
            .hdmi => |value| .{ .plan = plan, .operation = .hdmi, .hdmi = .{ .plan = value } },
            .dp => |value| .{ .plan = plan, .operation = .dp, .dp = .{ .plan = value } },
        };
    }
    pub fn ready(self: *const Work, now: u64) bool {
        return if (self.dp) |*value| value.ready(now) else true;
    }
    pub fn encode(self: *const Work, bytes: *[max_bytes]u8) !usize {
        if (self.hdmi) |*value| {
            var buffer: [hdmi.max_bytes]u8 = undefined;
            const n = try hdmi.encode(value.plan, value.operation, &buffer);
            @memcpy(bytes[0..n], buffer[0..n]); return n;
        }
        if (self.dp) |*value| return value.encode(bytes);
        return error.State;
    }
    pub fn matches(self: *const Work, channel: *const exchange.Exchange, deadline: u64) bool {
        if (!self.pending or (self.phase != .before_scanout and self.phase != .after_scanout) or
            channel.phase != .prepared or channel.deadline != deadline or channel.function != function or
            channel.request.ptr != self.request[0..].ptr or channel.request.len != self.length) return false;
        if (self.operation == .hdmi) {
            const value = self.hdmi orelse return false;
            if (self.dp != null or self.plan.transport != .hdmi or !std.meta.eql(self.plan.transport.hdmi, value.plan) or
                self.phase != value.phase or self.acknowledged != value.acknowledged) return false;
        } else {
            const value = self.dp orelse return false;
            if (self.hdmi != null or self.plan.transport != .dp or !std.meta.eql(self.plan.transport.dp, value.plan) or
                self.phase != .before_scanout or value.stage == .complete) return false;
        }
        var expected: [max_bytes]u8 = undefined;
        const n = self.encode(&expected) catch return false;
        return n == self.length and std.mem.eql(u8, expected[0..n], self.request[0..n]);
    }
    pub fn consume(self: *Work, record: exchange.message.Record, serial: u64, now: u64) !void {
        if (!self.pending or serial == 0 or serial <= self.last_receipt) return error.Stale;
        self.last_receipt = serial; self.pending = false;
        if (self.hdmi) |*value| {
            const reply = try hdmi.decode(value.plan, value.operation, record);
            self.last_status = reply.status; self.rpc_error = reply.rpc_error;
            if (reply.status != 0) return error.RmRejected;
            value.pending = true;
            try value.afterAck(serial);
            self.phase = value.phase; self.acknowledged = value.acknowledged;
        } else if (self.dp) |*value| {
            defer { self.last_status = value.last_rm_status; self.rpc_error = record.rpc.result != 0; }
            try value.consume(record, now);
            self.acknowledged += 1;
            if (value.stage == .complete) self.phase = .scanout;
        } else return error.State;
    }
    pub fn readyScanout(self: *const Work) bool {
        if (self.phase != .scanout or self.pending or self.last_receipt == 0) return false;
        if (self.dp) |*value| return value.stage == .complete and value.result != null;
        return self.acknowledged == @as(u8, if (self.plan.mode.transport_hdmi) 3 else 2);
    }
    pub fn scanoutComplete(self: *Work) !void {
        if (!self.readyScanout()) return error.State;
        if (self.hdmi) |*value| { try value.scanoutComplete(); self.phase = value.phase; }
        else self.phase = .complete;
    }
    pub fn dpResult(self: *const Work) ?dp.Result { return if (self.dp) |value| value.result else null; }
};
