//! Coalesced receiver work owned by the serialized GSP task. IRQs only wake
//! that task; authenticated RM masks are hints, never connection/EDID proof.
const std = @import("std");
const events = @import("gsp_runtime_events.zig");
const outputs = @import("gsp_outputs.zig");

pub const quiet_ns = 100 * std.time.ns_per_ms;
pub const burst_ns = std.time.ns_per_s;
pub const cooldown_ns = std.time.ns_per_s;
pub const max_retries = 2;

pub const Work = struct {
    epoch: u64 = 0,
    sequence: u64 = 0,
    scan_sequence: u64 = 0,
    pending: bool = false,
    capturing: bool = false,
    first_ns: u64 = 0,
    last_ns: u64 = 0,
    last_clock: u64 = 0,
    not_before_ns: u64 = 0,
    plug_mask: u32 = 0,
    unplug_mask: u32 = 0,
    dp_mask: u32 = 0,
    retries: u8 = 0,
    scans: u64 = 0,
    exhausted: u64 = 0,

    fn guard(self: *const Work, epoch: u64, now: u64) !void {
        if (epoch == 0 or self.epoch != epoch) return error.Stale;
        if (now == std.math.maxInt(u64) or now < self.last_clock) return error.Clock;
    }
    pub fn refresh(self: *Work, epoch: u64, now: u64) !void {
        try self.guard(epoch, now);
        const next = try std.math.add(u64, self.sequence, 1);
        if (!self.pending) {
            self.first_ns = now;
            self.plug_mask = 0; self.unplug_mask = 0; self.dp_mask = 0;
        }
        self.sequence = next;
        self.pending = true;
        self.last_ns = now;
        self.last_clock = now;
        self.retries = 0; // A real new event may start a new finite attempt set.
    }
    pub fn note(self: *Work, epoch: u64, now: u64, hint: events.Display) !void {
        try self.refresh(epoch, now);
        switch (hint) {
            .hotplug => |v| { self.plug_mask |= v.plug_mask; self.unplug_mask |= v.unplug_mask; },
            .dp_irq => |mask| self.dp_mask |= mask,
        }
    }
    pub fn dueNs(self: *const Work) u64 {
        return @max(self.not_before_ns, @min(self.last_ns +| quiet_ns, self.first_ns +| burst_ns));
    }
    pub fn due(self: *const Work, epoch: u64, now: u64) !bool {
        try self.guard(epoch, now);
        return self.pending and !self.capturing and now >= self.dueNs();
    }
    pub fn started(self: *Work, epoch: u64, now: u64) !void {
        try self.guard(epoch, now);
        if (self.capturing) return error.Busy;
        const scans = try std.math.add(u64, self.scans, 1);
        self.scan_sequence = self.sequence;
        self.pending = false;
        self.capturing = true;
        self.last_clock = now;
        self.scans = scans;
    }
    pub fn finished(self: *Work, epoch: u64, now: u64, transient: bool) !void {
        try self.guard(epoch, now);
        if (!self.capturing) return error.State;
        self.capturing = false;
        self.last_clock = now;
        self.not_before_ns = now +| cooldown_ns;
        // A notification received during acquisition already owns a fresh
        // pending batch. No retry may consume or replace that event.
        if (self.pending) return;
        if (!transient) { self.retries = 0; return; }
        if (self.retries == max_retries) { self.exhausted +|= 1; return; }
        self.retries += 1;
        self.pending = true;
        self.first_ns = now; self.last_ns = now;
    }
};

/// Only explicit current connection replies prove absence. Missing EDID,
/// rejected queries and unknown presence are distinct from TV power state.
pub fn retrySnapshot(snapshot: *const outputs.Snapshot) bool {
    if (!snapshot.coherent or snapshot.topology.rejected != null or snapshot.final_rejection != null) return true;
    for (snapshot.receivers[0..snapshot.count]) |*capture| {
        if (capture.connected == false) continue;
        switch (capture.status) {
            .pending, .query_rejected, .edid_missing, .edid_rejected, .invalid_edid, .incomplete_edid => return true,
            .not_supported, .unsupported_data, .valid_edid, .disconnected => {},
        }
    }
    return false;
}

pub const ReceiverState = enum { query_failed, unknown, disconnected, edid_pending, connected, unsupported };
pub const Observation = struct {
    generation: u64,
    receipt: u64,
    state: ReceiverState,
    fingerprint: ?[32]u8 = null,
};
/// Power state is not observable from HPD/EDID alone. A connected TV that
/// supplies no usable EDID is edid_pending, never a fabricated standby flag.
pub fn observe(snapshot: *const outputs.Snapshot, connector: u32) !Observation {
    if (connector == 0 or @popCount(connector) != 1 or snapshot.generation == 0 or
        snapshot.count > snapshot.receivers.len or snapshot.count != snapshot.topology.count) return error.Stale;
    var value: Observation = .{ .generation = snapshot.generation, .receipt = snapshot.final_receipt_serial, .state = .query_failed };
    if (!snapshot.coherent or snapshot.final_receipt_serial == 0 or snapshot.topology.rejected != null or snapshot.final_rejection != null) return value;
    value.state = .unknown;
    var seen = false;
    for (snapshot.receivers[0..snapshot.count]) |*capture| if (capture.display_id == connector) {
        if (seen or capture.epoch != snapshot.topology.epoch or capture.client != snapshot.topology.client) return error.Stale;
        seen = true;
        if (capture.connected == false) { value.state = .disconnected; continue; }
        value.state = switch (capture.status) {
            .query_rejected => .query_failed,
            .not_supported, .unsupported_data => .unsupported,
            .pending, .edid_missing, .edid_rejected, .invalid_edid, .incomplete_edid, .disconnected =>
                if (capture.connected == true) .edid_pending else .unknown,
            .valid_edid => if (capture.connected == true and capture.report.complete()) .connected else .unknown,
        };
        if (value.state == .connected) {
            if (capture.edid_bytes == 0 or capture.edid_bytes > capture.bytes.len or capture.edid_bytes % 128 != 0) return error.Stale;
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(capture.bytes[0..capture.edid_bytes], &hash, .{});
            value.fingerprint = hash;
        }
    };
    return value;
}
