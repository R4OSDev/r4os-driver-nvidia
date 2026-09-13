//! Serialized display/audio transition. Only copied route metadata enters the
//! common catalog. Physical controls use Runtime's exact RM command receipts.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const runtime = @import("gsp_runtime.zig");
const wire = runtime.hdmi_audio;
const Catalog = @import("gsp_catalog.zig").Owner;
pub const Phase = enum { idle, pending, submit, wait, finish, failed };
pub const Owner = struct {
    catalog: ?*Catalog = null,
    location: u32 = 0,
    device: u32 = 0,
    phase: Phase = .idle,
    plan: ?wire.Plan = null,
    enabled: bool = false,
    receiver_sequence: u64 = 0,
    revision: u64 = 0,
    operation: wire.Operation = .mute,
    work_sequence: u64 = 0,
    deadline: u64 = 0,
    last_status: i32 = 0,
    failure: ?anyerror = null,
    settled: bool = false,

    pub fn attach(self: *Owner, catalog: *Catalog, pci: @import("identity.zig").Pci) void {
        if (catalog.context == null or !catalog.context.?.supportsAudio()) return;
        self.* = .{ .catalog = catalog, .location = (@as(u32, pci.bus_kind) << 24) | (@as(u32, pci.bus) << 8) |
            (@as(u32, pci.device) << 3) | pci.function, .device = @as(u32, pci.vendor_id) | (@as(u32, pci.device_id) << 16) };
    }
    pub fn busy(self: *const Owner) bool { return self.phase != .idle and self.phase != .failed; }
    pub fn afterStop(self: *Owner) void {
        // Preserve the source's monotonic publication revision across every
        // reconnect; the next transition derives a new ELD from its capture.
        const old = self.*;
        self.* = .{ .catalog = old.catalog, .location = old.location, .device = old.device, .revision = old.revision };
    }
    pub fn beforeInitial(self: *Owner, product: anytype) !bool {
        if (self.catalog == null or !product.mode.?.transport_hdmi or self.settled or self.phase == .failed) return true;
        _ = try self.drive(product, product.mode.?, false);
        return !self.busy();
    }
    pub fn step(self: *Owner, product: anytype) !bool {
        if (self.catalog == null) return false;
        const image = try product.running.?.displayImageStatus(product.engine.?, product.mode.?.window) orelse return false;
        const mode = image.boot_mode orelse return false;
        if (!mode.transport_hdmi) return false;
        const enabling = product.modes.job == null or product.modes.job.?.operation == a.gfx_mode_operation_confirm;
        return self.drive(product, mode, enabling);
    }
    fn drive(self: *Owner, product: anytype, mode: runtime.boot_mode.Plan, enabling: bool) !bool {
        return self.advance(product, mode, enabling) catch |err| {
            if (err == error.Busy) return false;
            self.quarantine(product, err);
            return false;
        };
    }
    fn advance(self: *Owner, product: anytype, mode: runtime.boot_mode.Plan, enabling: bool) !bool {
        const run = product.running.?;
        const catalog = self.catalog.?;
        if (!self.busy()) {
            if (self.settled and self.plan != null and std.meta.eql(self.plan.?.mode, mode) and
                self.enabled == enabling and self.receiver_sequence == catalog.sequence) return false;
            const snapshot = run.nativeOutputs() orelse return error.Busy;
            const plan = try wire.derive(mode, run.nativeObject() orelse return error.Busy, snapshot);
            self.plan = plan; self.enabled = enabling; self.receiver_sequence = catalog.sequence;
            self.deadline = product.last_clock +| (5 * std.time.ns_per_s);
            self.phase = .pending; self.operation = .mute; self.work_sequence = 0;
            self.failure = null; self.settled = false;
            return true;
        }
        if (product.last_clock >= self.deadline) return error.Deadline;
        if (self.receiver_sequence != catalog.sequence) return error.Stale;
        switch (self.phase) {
            .pending => {
                try self.publish(a.gfx_audio_route_pending);
                self.phase = .submit;
            },
            .submit => {
                self.work_sequence = try run.beginHdmiAudio(self.plan.?, self.operation, self.deadline);
                self.phase = .wait;
            },
            .wait => {
                if (run.audio_work != null) return false;
                const result = run.audio_result orelse return error.Completion;
                if (result.sequence != self.work_sequence or result.operation != self.operation or result.receipt == 0) return error.Completion;
                if (result.status != 0) return error.RmRejected;
                switch (self.operation) {
                    .mute => { self.operation = .clear; self.phase = .submit; },
                    .clear => if (self.enabled and self.plan.?.data != null) {
                        self.operation = .publish; self.phase = .submit;
                    } else { self.phase = .finish; },
                    .publish => if (self.plan.?.data.?.stereo_48k_s16) {
                        self.operation = .unmute; self.phase = .submit;
                    } else { self.phase = .finish; },
                    .unmute => self.phase = .finish,
                }
            },
            .finish => {
                const state: u32 = if (!self.enabled) a.gfx_audio_route_pending else
                    if (self.plan.?.data == null) a.gfx_audio_route_absent else
                    if (self.plan.?.data.?.stereo_48k_s16) a.gfx_audio_route_ready else a.gfx_audio_route_unsupported;
                try self.publish(state);
                self.settled = true; self.phase = .idle;
                var text: [192]u8 = undefined;
                const line = try std.fmt.bufPrintZ(&text, "NVIDIA HDMI audio: connector={x} head={d} entry=0 revision={d} state={d} PCM=48000,stereo,S16 video=preserved",
                    .{self.plan.?.mode.signal.display_id, self.plan.?.mode.head, self.revision, state});
                product.ctx.?.logInfo(line);
            },
            .idle, .failed => unreachable,
        }
        return true;
    }
    fn publish(self: *Owner, state: u32) !void {
        const plan = self.plan orelse return error.State;
        const catalog = self.catalog orelse return error.State;
        const revision = try std.math.add(u64, self.revision, 1);
        var route: a.GfxAudioRoute = .{ .source = catalog.binding, .receiver_sequence = catalog.sequence,
            .revision = revision, .connector_id = plan.mode.signal.display_id, .hda_location = self.location,
            .hda_device = self.device, .head_id = plan.mode.head, .device_entry = 0, .state = state, .port_id = plan.portId() };
        if (state == a.gfx_audio_route_ready) {
            route.eld_bytes = plan.data.?.bytes.len;
            route.eld = plan.data.?.bytes;
        }
        self.last_status = catalog.context.?.publishAudio(&route);
        if (self.last_status == a.gfx_output_error_busy) return error.Busy;
        if (self.last_status != a.gfx_output_ok) return error.Catalog;
        self.revision = revision;
    }
    pub fn quarantine(self: *Owner, product: anytype, err: anyerror) void {
        if (self.catalog == null) return;
        if (self.failure == null) {
            self.failure = err;
            self.publish(a.gfx_audio_route_failed) catch {};
            product.ctx.?.logError("NVIDIA HDMI audio: unavailable, route invalidated; video resources retained");
        }
        self.phase = .failed; self.settled = true;
    }
};
