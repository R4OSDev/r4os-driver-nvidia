//! Retire the FEC/receiver part of one admitted DP DSC route. Core encoder
//! retirement belongs to the interlocked display transaction. On HPD the
//! old receiver is no longer addressable; only the source is touched.
const std = @import("std");
const dp = @import("gsp_dp_link.zig");
const aux = @import("gsp_aux_wire.zig");
const exchange = @import("gsp_exchange.zig");
pub const Work = struct {
    plan: dp.Plan,
    receiver_present: bool = true,
    stage: enum { fec_disable, decoder_disable, decoder_verify, disabled } = .fec_disable,
    retries: u8 = 0,
    not_before: u64 = 0,
    last_status: ?u32 = null,
    rpc_error: bool = false,

    pub fn active(self: *const Work) bool {
        return self.stage != .disabled;
    }
    pub fn ready(self: *const Work, now: u64) bool {
        return self.active() and now >= self.not_before;
    }
    fn request(self: *const Work) ?aux.Request {
        return .{ .display_id = self.plan.mode.signal.display_id, .operation = switch (self.stage) {
            .decoder_disable => .{ .dsc_enable = false },
            .decoder_verify => .dsc_control,
            else => return null,
        } };
    }
    pub fn encode(self: *const Work, bytes: []u8) !usize {
        if (!self.plan.mode.displayPort() or self.plan.mode.signal.dp_dsc == null or self.plan.mode.epoch == 0 or
            self.plan.mode.epoch != self.plan.object.epoch or self.plan.object.client == 0 or self.plan.object.display == 0 or
            bytes.len < dp.max_bytes or !self.active()) return error.Descriptor;
        @memset(bytes, 0);
        put(bytes, 0, self.plan.object.client);
        put(bytes, 4, self.plan.object.display);
        if (self.request()) |query| {
            if (!self.receiver_present) return error.State;
            put(bytes, 8, aux.command);
            put(bytes, 16, aux.bytes);
            put(bytes, 20, aux.rpc_flags);
            _ = try aux.encode(query, bytes[24..]);
            return 24 + aux.bytes;
        }
        put(bytes, 8, 0x73137a);
        put(bytes, 16, 12);
        put(bytes, 28, self.plan.mode.signal.display_id);
        return 36; // CONFIGURE_FEC.bEnableFec=false, including all padding.
    }
    fn retry(self: *Work, now: u64, delay_ms: u32) !void {
        if (delay_ms == 0 or delay_ms > 500 or self.retries >= 2) return error.RetryExhausted;
        self.retries += 1;
        self.not_before = now +| @as(u64, delay_ms) * std.time.ns_per_ms;
    }
    pub fn consume(self: *Work, record: exchange.message.Record, now: u64) !void {
        var expected: [dp.max_bytes]u8 = undefined;
        const length = try self.encode(&expected);
        const bytes = record.payload;
        if (record.rpc.function != 76 or record.rpc.cpu_rm_gfid != 0) return error.Unexpected;
        self.rpc_error = record.rpc.result != 0;
        if (self.rpc_error) return error.RmRejected;
        if (bytes.len != length) return error.Payload;
        if (!std.mem.eql(u8, bytes[0..12], expected[0..12]) or !std.mem.eql(u8, bytes[16..24], expected[16..24])) return error.Unexpected;
        const status = std.mem.readInt(u32, bytes[12..16], .little);
        self.last_status = status;
        if (self.request()) |query| {
            const reply = try aux.decode(query, status, bytes[24..]);
            if ((status == 3 or status == 0x66) and reply.retry_ms != 0) return self.retry(now, reply.retry_ms);
            if (status != 0) return error.RmRejected;
            if (reply.kind == .defer_reply) return self.retry(now, 1);
            if (reply.kind != .ack or reply.count != 1) return error.Aux;
            if (self.stage == .decoder_verify and reply.data[0] & 3 != 0) return error.LinkTraining;
            self.stage = if (self.stage == .decoder_disable) .decoder_verify else .disabled;
        } else {
            if (status != 0) return error.RmRejected;
            if (!std.mem.eql(u8, bytes[24..], expected[24..length])) return error.Unexpected;
            self.stage = if (self.receiver_present) .decoder_disable else .disabled;
        }
        self.retries = 0;
        self.not_before = 0;
    }
};
fn put(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
