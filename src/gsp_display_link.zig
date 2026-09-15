//! One link transaction around the common Core/Window scanout. Protocol
//! owners encode only their own controls; no second display/queue lifetime.
const std = @import("std");
const hdmi = @import("gsp_hdmi_link.zig");
pub const dp = @import("gsp_dp_link.zig");
pub const frl = @import("gsp_frl_link.zig");
pub const dp_stop = @import("gsp_dp_stop.zig");
pub const mst = @import("gsp_mst_link.zig");
pub const mst_restore = @import("gsp_mst_restore.zig");
const boot = @import("gsp_boot_mode.zig");
const display = @import("gsp_display_rpc.zig");
const outputs = @import("gsp_outputs.zig");
const exchange = @import("gsp_exchange.zig");
pub const function: u32 = 76;
pub const Phase = hdmi.Phase;
pub const max_bytes = @max(mst.max_bytes, @max(frl.max_bytes, @max(hdmi.max_bytes, dp.max_bytes)));
pub const Plan = struct {
    object: display.Object,
    mode: boot.Plan,
    transport: union(enum) { hdmi: hdmi.Plan, dp: dp.Plan, mst: mst.Plan },
    frl: ?frl.Plan = null,
    pub fn extended(self: Plan) bool { return self.frl != null or self.mode.signal.dp_dsc != null or self.transport == .mst; }
};
pub fn derive(saved: boot.Plan, object: display.Object, snapshot: *const outputs.Snapshot) !Plan {
    return .{ .object = object, .mode = saved, .frl = if (saved.signal.hdmi_frl) try frl.derive(saved, object) else null,
        .transport = if (saved.signal.mst != null) .{ .mst = try mst.derive(saved, object, snapshot) } else if (saved.displayPort())
        .{ .dp = try dp.derive(saved, object, snapshot) } else .{ .hdmi = try hdmi.derive(saved, object, snapshot) } };
}
pub const Work = struct {
    plan: Plan,
    phase: Phase = .before_scanout,
    operation: enum { hdmi, dp, mst },
    hdmi: ?hdmi.Work = null,
    dp: ?dp.Work = null,
    mst: ?mst.Work = null,
    mst_rebuild: ?mst_restore.Work = null,
    frl: ?frl.Work = null,
    clear_frl: ?frl.Work = null,
    clear_dp: ?dp_stop.Work = null,
    clear_receipt: u64 = 0,
    stop_only: bool = false,
    mutated: bool = false,
    pending: bool = false,
    acknowledged: u8 = 0,
    last_receipt: u64 = 0,
    last_status: ?u32 = null,
    rpc_error: bool = false,
    request: [max_bytes]u8 = @splat(0),
    length: usize = 0,
    pub fn init(plan: Plan) Work {
        return switch (plan.transport) {
            .hdmi => |value| .{ .plan = plan, .operation = .hdmi, .hdmi = .{ .plan = value },
                .frl = if (plan.frl) |native| .{ .plan = native } else null },
            .dp => |value| .{ .plan = plan, .operation = .dp, .dp = .{ .plan = value } },
            .mst => .{ .plan = plan, .operation = .mst },
        };
    }
    /// Reserve only after the ordinary image/channel preflight succeeded.
    /// The work may move until prepare pins its resident address.
    pub fn reserveMst(self: *Work, snapshot: *const outputs.Snapshot, store: *@import("gsp_mst_discovery.zig").Store, deadline: u64) !void {
        if (self.operation != .mst) return;
        if (self.plan.transport != .mst or self.mst != null or self.mst_rebuild != null or self.pending or self.last_receipt != 0) return error.State;
        self.mst = try mst.Work.init(self.plan.transport.mst, snapshot, store, deadline);
    }
    pub fn restoreMst(failed: *const Work, deadline: u64) !Work {
        if (failed.operation != .mst or failed.pending or failed.mst_rebuild != null) return error.State;
        const source = if (failed.mst) |*value| value else return error.State;
        return .{ .plan = failed.plan, .operation = .mst, .last_receipt = failed.last_receipt,
            .mst_rebuild = try mst_restore.Work.init(source, deadline) };
    }
    pub fn stopMst(plan: Plan, proof: mst.Result, image: @import("gsp_mst_registry.zig").Image,
        store: *@import("gsp_mst_discovery.zig").Store, deadline: u64) !Work
    {
        if (plan.transport != .mst) return error.Descriptor;
        return .{ .plan = plan, .operation = .mst, .stop_only = true,
            .mst_rebuild = try mst_restore.Work.initStop(plan.transport.mst, proof, image, store, deadline) };
    }
    pub fn prepare(self: *Work, now: u64) !bool {
        if (self.mst_rebuild) |*value| return value.prepare(now);
        if (self.mst) |*value| return value.prepare(now);
        if (self.operation == .mst) return error.State;
        return true;
    }
    pub fn submitted(self: *Work) !void {
        if (self.mst_rebuild) |*value| { try value.submitted(); self.mutated = true; }
        else if (self.mst) |*value| { try value.submitted(); self.mutated = value.root.transaction.first_posted != 0; }
    }
    pub fn cancelUnsubmitted(self: *Work) !void {
        if (self.pending or self.mst_rebuild != null) return error.State;
        if (self.mst) |*value| try value.cancelUnsubmitted();
    }
    pub fn retainAmbiguous(self: *Work, reason: anyerror) void {
        if (self.mst_rebuild) |*value| value.retainAmbiguous(reason)
        else if (self.mst) |*value| value.retainAmbiguous(reason);
    }
    pub fn ready(self: *const Work, now: u64) bool {
        if (self.mst_rebuild) |*value| return value.ready(now);
        if (self.mst) |*value| return value.ready(now);
        if (self.clear_dp) |*prior| if (prior.active()) return prior.ready(now);
        return if (self.dp) |*value| value.ready(now) else true;
    }
    pub fn extended(self: *const Work) bool { return self.plan.extended() or self.clear_frl != null or self.clear_dp != null; }
    pub fn cleared(self: *const Work) bool {
        if (self.clear_receipt == 0) return false;
        if (self.mst_rebuild) |*value| return self.stop_only and value.stop_only and value.stage == .complete and value.completion_receipt == self.clear_receipt;
        if (self.clear_frl) |*prior| return self.clear_dp == null and prior.stage == .disabled;
        if (self.clear_dp) |*prior| return prior.stage == .disabled;
        return false;
    }
    pub fn stopExtended(plan: Plan, receiver_present: bool) !Work {
        if (plan.frl != null) return stopFrl(plan);
        if (plan.mode.signal.dp_dsc == null or plan.transport != .dp) return error.Descriptor;
        return .{ .plan = plan, .operation = .dp, .stop_only = true,
            .clear_dp = .{ .plan = plan.transport.dp, .receiver_present = receiver_present } };
    }
    pub fn clearPrevious(self: *Work, previous: Plan) !void {
        if (previous.frl != null) return self.clearPreviousFrl(previous);
        if (self.phase != .before_scanout or self.pending or self.last_receipt != 0 or self.stop_only or self.clear_dp != null or self.clear_frl != null)
            return error.State;
        if (previous.mode.signal.dp_dsc == null or previous.transport != .dp or self.plan.transport != .dp or
            !sameRoute(previous, self.plan)) return error.Stale;
        self.clear_dp = .{ .plan = previous.transport.dp };
    }
    fn sameRoute(previous: Plan, next: Plan) bool {
        return std.meta.eql(previous.object, next.object) and previous.mode.window == next.mode.window and
            previous.mode.head == next.mode.head and previous.mode.signal.sor == next.mode.signal.sor and
            previous.mode.signal.display_id == next.mode.signal.display_id;
    }
    /// Disable a known FRL route after its Core has stopped, or before an
    /// unsubmitted failed candidate is discarded. This proves no scanout.
    pub fn stopFrl(plan: Plan) !Work {
        return .{ .plan = plan, .operation = .hdmi, .stop_only = true,
            .clear_frl = .{ .plan = plan.frl orelse return error.Descriptor, .stage = .disable } };
    }
    pub fn clearPreviousFrl(self: *Work, previous: Plan) !void {
        if (self.phase != .before_scanout or self.pending or self.last_receipt != 0 or self.stop_only or self.clear_frl != null or self.clear_dp != null)
            return error.State;
        const prior = previous.frl orelse return error.Descriptor;
        if (!std.meta.eql(previous.object, self.plan.object) or previous.mode.window != self.plan.mode.window or
            previous.mode.head != self.plan.mode.head or previous.mode.signal.sor != self.plan.mode.signal.sor or
            previous.mode.signal.display_id != self.plan.mode.signal.display_id) return error.Stale;
        self.clear_frl = .{ .plan = prior, .stage = .disable };
    }
    pub fn encode(self: *const Work, bytes: *[max_bytes]u8) !usize {
        if (self.mst_rebuild) |*value| return value.encode(bytes);
        if (self.mst) |*value| return value.encode(bytes);
        if (self.clear_dp) |*prior| {
            if (self.clear_frl != null or !std.meta.eql(prior.plan.object, self.plan.object) or
                prior.plan.mode.signal.display_id != self.plan.mode.signal.display_id or prior.plan.mode.signal.sor != self.plan.mode.signal.sor or
                prior.plan.mode.head != self.plan.mode.head or prior.plan.mode.window != self.plan.mode.window) return error.Stale;
            if (prior.active()) return prior.encode(bytes);
        }
        if (self.clear_frl) |*prior| {
            if (!std.meta.eql(prior.plan.object, self.plan.object) or
                prior.plan.mode.signal.display_id != self.plan.mode.signal.display_id or prior.plan.mode.signal.sor != self.plan.mode.signal.sor or
                prior.plan.mode.head != self.plan.mode.head or prior.plan.mode.window != self.plan.mode.window or
                (prior.stage != .disable and prior.stage != .disabled)) return error.Stale;
            if (prior.active()) return prior.encode(bytes);
        }
        if (self.stop_only) return error.State;
        if (self.plan.mode.signal.hdmi_frl != (self.frl != null)) return error.Descriptor;
        if (self.frl) |*value| if (value.active()) return value.encode(bytes);
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
        if (self.operation == .mst) {
            if (self.plan.transport != .mst or self.hdmi != null or self.dp != null or self.frl != null or self.clear_dp != null or self.clear_frl != null) return false;
            if (self.mst_rebuild) |*value| {
                if (self.mst != null or !std.meta.eql(value.plan, self.plan.transport.mst) or !value.pendingAt(deadline) or
                    self.stop_only != value.stop_only or value.stage == .scanout or value.stage == .complete or
                    (self.phase == .after_scanout) != (value.core != null)) return false;
            } else if (self.mst) |*value| {
                if (self.stop_only or !std.meta.eql(value.plan, self.plan.transport.mst) or !value.pendingAt(deadline) or
                    value.stage == .scanout or value.stage == .complete or (self.phase == .after_scanout) != (value.core_point != 0)) return false;
            } else return false;
        } else if (self.stop_only) {
            if (self.phase != .before_scanout or self.hdmi != null or self.dp != null or self.frl != null) return false;
            if (self.clear_frl) |*prior| {
                if (self.operation != .hdmi or self.clear_dp != null or prior.stage != .disable or self.plan.frl == null or
                    !std.meta.eql(self.plan.frl.?, prior.plan)) return false;
            } else if (self.clear_dp) |*prior| {
                if (self.operation != .dp or !prior.active() or self.plan.transport != .dp or
                    !std.meta.eql(self.plan.transport.dp, prior.plan)) return false;
            } else return false;
        } else if (self.operation == .hdmi) {
            const value = self.hdmi orelse return false;
            if (self.frl) |*native| {
                if (self.plan.frl == null or !std.meta.eql(self.plan.frl.?, native.plan)) return false;
            } else if (self.plan.frl != null) return false;
            const expected_phase: Phase = if (self.frl != null and value.phase == .scanout and self.frl.?.stage != .complete) .before_scanout else value.phase;
            if (self.dp != null or self.plan.transport != .hdmi or !std.meta.eql(self.plan.transport.hdmi, value.plan) or
                self.phase != expected_phase or self.acknowledged != value.acknowledged) return false;
        } else {
            const value = self.dp orelse return false;
            if (self.hdmi != null or self.plan.transport != .dp or !std.meta.eql(self.plan.transport.dp, value.plan) or
                value.stage == .complete or value.stage == .post_complete or
                (self.phase == .after_scanout) != (value.stage == .vsc or value.stage == .hdr)) return false;
        }
        var expected: [max_bytes]u8 = undefined;
        const n = self.encode(&expected) catch return false;
        return n == self.length and std.mem.eql(u8, expected[0..n], self.request[0..n]);
    }
    pub fn consume(self: *Work, record: exchange.message.Record, serial: u64, now: u64) !void {
        if (!self.pending or serial == 0 or serial <= self.last_receipt) return error.Stale;
        self.last_receipt = serial; self.pending = false;
        if (self.operation == .mst) {
            self.rpc_error = record.rpc.result != 0;
            self.last_status = if (record.payload.len >= 16) std.mem.readInt(u32, record.payload[12..16], .little) else null;
            if (self.mst_rebuild) |*value| {
                try value.consume(record, serial, now);
                if (value.stage == .scanout) self.phase = .scanout;
                if (value.stage == .complete) { self.phase = .complete; self.clear_receipt = value.completion_receipt; self.acknowledged = 2; }
            } else if (self.mst) |*value| {
                try value.consume(record, serial, now);
                if (value.stage == .scanout) { self.phase = .scanout; self.acknowledged = 1; }
                if (value.stage == .complete) { self.phase = .complete; self.acknowledged = 2; }
            } else return error.State;
            return;
        }
        if (self.clear_dp) |*prior| if (prior.active()) {
            self.mutated = true;
            defer { self.last_status = prior.last_status; self.rpc_error = prior.rpc_error; }
            try prior.consume(record, now);
            if (prior.stage == .disabled) {
                self.clear_receipt = serial;
                if (self.stop_only) self.phase = .complete;
            }
            return;
        };
        if (self.clear_frl) |*prior| if (prior.active()) {
            self.mutated = true;
            defer { self.last_status = prior.last_status; self.rpc_error = prior.rpc_error; }
            try prior.consume(record, serial);
            if (prior.stage != .disabled) return error.State;
            self.clear_receipt = serial;
            if (self.stop_only) self.phase = .complete;
            return;
        };
        if (self.frl) |*native| if (native.active()) {
            if (native.stage == .train or native.stage == .disable) self.mutated = true;
            defer { self.last_status = native.last_status; self.rpc_error = native.rpc_error; }
            try native.consume(record, serial);
            if (native.stage == .complete) self.phase = .scanout;
            return;
        };
        if (self.hdmi) |*value| {
            self.mutated = true;
            const reply = try hdmi.decode(value.plan, value.operation, record);
            self.last_status = reply.status; self.rpc_error = reply.rpc_error;
            if (reply.status != 0) return error.RmRejected;
            value.pending = true;
            try value.afterAck(serial);
            self.phase = value.phase; self.acknowledged = value.acknowledged;
            if (value.phase == .scanout) if (self.frl) |*native| {
                try native.startTraining(); self.phase = .before_scanout;
            };
        } else if (self.dp) |*value| {
            const stage = value.stage;
            if (value.mutating()) self.mutated = true;
            defer { self.last_status = value.last_rm_status; self.rpc_error = record.rpc.result != 0; }
            try value.consume(record, now);
            if (stage == .fec_status and value.stage == .dsc_enable) value.fec_receipt = serial;
            if (stage == .dsc_verify and value.stage == .stream) value.decoder_receipt = serial;
            self.acknowledged += 1;
            if (value.stage == .complete) self.phase = .scanout;
            if (value.stage == .post_complete) self.phase = .complete;
        } else return error.State;
    }
    pub fn readyScanout(self: *const Work) bool {
        if (self.stop_only or self.phase != .scanout or self.pending or self.last_receipt == 0) return false;
        if (self.operation == .mst) return self.mst_rebuild == null and self.mst != null and self.mst.?.stage == .scanout and
            self.mst.?.failure == null and self.mst.?.training != null and self.mst.?.request == null and self.acknowledged == 1;
        if (self.clear_frl) |*prior| if (prior.stage != .disabled or self.clear_receipt == 0) return false;
        if (self.clear_dp) |*prior| if (prior.stage != .disabled or self.clear_receipt == 0) return false;
        if (self.plan.mode.signal.hdmi_frl != (self.frl != null)) return false;
        if (self.frl) |*native| if (native.stage != .complete or native.result == null or native.result.?.training_receipt == 0 or
            !std.meta.eql(native.result.?.compressed, self.plan.mode.signal.hdmi_dsc) or
            (native.result.?.compressed != null and native.result.?.capacity_receipt <= native.result.?.training_receipt)) return false;
        if (self.dp) |*value| return value.stage == .complete and value.result != null and value.result.?.complete(self.plan.mode);
        return self.acknowledged == @as(u8, if (self.plan.mode.transport_hdmi) 3 else 2);
    }
    pub fn scanoutComplete(self: *Work) !void {
        if (!self.readyScanout()) return error.State;
        if (self.hdmi) |*value| { try value.scanoutComplete(); self.phase = value.phase; }
        else if (self.dp) |*value| { try value.scanoutComplete(); self.phase = .after_scanout; }
        else return error.State;
    }
    pub fn scanoutCompleted(self: *Work, core_point: u64, window_point: u64) !void {
        if (self.operation != .mst) return self.scanoutComplete();
        if (!self.readyScanout()) return error.State;
        try self.mst.?.scanoutComplete(core_point, window_point); self.phase = .after_scanout;
    }
    pub fn rebuildScanout(self: *Work, core: mst_restore.Core) !void {
        if (self.operation != .mst or self.phase != .scanout or self.pending) return error.State;
        const value = if (self.mst_rebuild) |*work| work else return error.State;
        try value.scanoutRestored(core); self.phase = .after_scanout;
    }
    pub fn mstResult(self: *const Work) ?mst.Result { return if (self.mst) |*value| value.result else null; }
    pub fn dpResult(self: *const Work) ?dp.Result { return if (self.dp) |value| value.result else null; }
    pub fn frlResult(self: *const Work) ?frl.Result {
        if (self.frl) |*native| if (native.stage == .complete) return native.result;
        return null;
    }
};
