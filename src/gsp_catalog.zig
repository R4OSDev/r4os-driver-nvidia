//! Pure metadata bridge for the one serialized native driver. The kernel
//! source holds no GPU resources and must close even when firmware/DMA stays
//! retained. Receiver acquisition/HPD belongs to gsp_runtime, parsing to R4GFX.
// Connector type definitions: NVIDIA 570.144 ctrl0073specific.h (MIT).
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 1993-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
//  * SPDX-License-Identifier: MIT
//  *
//  * Permission is hereby granted, free of charge, to any person obtaining a
//  * copy of this software and associated documentation files (the "Software"),
//  * to deal in the Software without restriction, including without limitation
//  * the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  * and/or sell copies of the Software, and to permit persons to whom the
//  * Software is furnished to do so, subject to the following conditions:
//  *
//  * The above copyright notice and this permission notice shall be included in
//  * all copies or substantial portions of the Software.
//  *
//  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  * DEALINGS IN THE SOFTWARE.
//  */
const std = @import("std");
const r4os = @import("r4os");
const gfx = @import("r4gfx_outputs");
const a = r4os.abi;
const outputs = @import("gsp_outputs.zig");
const topology = @import("gsp_topology.zig");
const receiver = @import("gsp_receiver.zig");
const Context = @TypeOf(@as(r4os.r4dev.DriverContext, undefined).graphicsOutputs().?);

pub const Owner = struct {
    context: ?Context = null,
    binding: a.GfxReceiverSource = .{},
    sequence: u64 = 0,
    captured_generation: u64 = 0,
    published: bool = false,
    last_status: i32 = 0,
    records: [a.gfx_receiver_max_outputs]a.GfxReceiverInfo = @splat(.{}),

    pub fn open(self: *Owner, ctx: *const r4os.r4dev.DriverContext, adapter: u32) !void {
        if (self.binding.generation != 0) return error.Busy;
        const context = ctx.graphicsOutputs() orelse return error.Api;
        if (!context.supportsReceivers()) return error.Api;
        self.last_status = context.registerSource(adapter, &self.binding);
        if (self.last_status != a.gfx_output_ok) return error.Catalog;
        self.context = context;
    }
    fn replace(self: *Owner, count: u32) !void {
        const context = self.context orelse return error.State;
        const next = try std.math.add(u64, self.sequence, 1);
        const update: a.GfxReceiverUpdate = .{ .source = self.binding, .sequence = next,
            .count = count, .receivers = if (count == 0) 0 else @intFromPtr(&self.records) };
        self.last_status = context.replaceReceivers(&update);
        if (self.last_status != a.gfx_output_ok) return error.Catalog;
        self.sequence = next;
        self.published = count != 0;
    }
    pub fn invalidate(self: *Owner) !void {
        if (self.published) try self.replace(0);
    }
    pub fn publish(self: *Owner, snapshot: *const outputs.Snapshot) !void {
        if (!snapshot.coherent or snapshot.generation == 0 or snapshot.count != snapshot.topology.count or
            snapshot.count > self.records.len or snapshot.topology.rejected != null or snapshot.final_rejection != null) return error.Catalog;
        if (snapshot.generation == self.captured_generation) return;
        if (snapshot.generation < self.captured_generation) return error.Stale;
        for (snapshot.receivers[0..snapshot.count], snapshot.topology.routes[0..snapshot.count], 0..) |*capture, *route, index| {
            if (capture.display_id != route.id or capture.epoch != snapshot.topology.epoch or
                capture.client != snapshot.topology.client) return error.Binding;
            try encode(&self.records[index], route, capture);
        }
        try self.replace(@intCast(snapshot.count));
        self.captured_generation = snapshot.generation;
    }
    pub fn close(self: *Owner) bool {
        if (self.binding.generation == 0) return true;
        const context = self.context orelse return false;
        self.last_status = context.closeSource(&self.binding);
        // Generic driver stop/reset may already have revoked this exact
        // metadata source. Stale cannot retain or release any GPU resource.
        if (self.last_status != a.gfx_output_ok and self.last_status != a.gfx_output_error_stale) return false;
        self.binding = .{};
        self.published = false;
        return true;
    }
};

pub fn encode(output: *a.GfxReceiverInfo, route: *const topology.Route, capture: *const receiver.Capture) !void {
    if (route.id == 0 or capture.status == .pending or capture.edid_bytes > capture.bytes.len) return error.State;
    output.* = .{ .connector_id = route.id, .connector_kind = kind(route) };
    output.flags = if (capture.connected) |connected| (if (connected) a.gfx_output_flag_connected else 0) else a.gfx_output_flag_connection_unknown;
    switch (capture.status) {
        .pending => unreachable,
        .not_supported, .query_rejected => output.flags |= a.gfx_output_flag_query_failed,
        .edid_missing => output.flags |= a.gfx_output_flag_edid_missing,
        .edid_rejected => output.flags |= a.gfx_output_flag_query_failed | a.gfx_output_flag_edid_missing,
        .invalid_edid => output.flags |= a.gfx_output_flag_edid_invalid,
        .unsupported_data => output.flags |= a.gfx_output_flag_edid_invalid | a.gfx_output_flag_receiver_incomplete,
        .incomplete_edid => output.flags |= a.gfx_output_flag_receiver_incomplete,
        .valid_edid, .disconnected => {},
    }
    if (capture.connected != true) {
        // Missing presence is not evidence of an attached receiver with a
        // missing/invalid EDID. Common receiver metadata carries no modes or
        // EDID in that state, independently of a retained source boot route.
        output.flags &= ~(a.gfx_output_flag_edid_missing | a.gfx_output_flag_edid_invalid);
        return;
    }
    // A malformed partial block is never padded into a fictional valid EDID.
    // Keep only complete diagnostic blocks and report the incomplete tail.
    output.edid_bytes = @intCast(capture.edid_bytes / 128 * 128);
    if (output.edid_bytes != capture.edid_bytes) output.flags |= a.gfx_output_flag_receiver_incomplete;
    @memcpy(output.edid[0..output.edid_bytes], capture.bytes[0..output.edid_bytes]);
    if (capture.status != .valid_edid and capture.status != .incomplete_edid) return;
    for (capture.report.modes[0..capture.report.mode_count]) |timing| {
        const mode = gfx.modeFromTiming(timing, output.mode_count + 1) orelse {
            output.flags |= a.gfx_output_flag_receiver_incomplete;
            continue;
        };
        if (output.mode_count == output.modes.len) {
            output.flags |= a.gfx_output_flag_receiver_incomplete;
            break;
        }
        output.modes[output.mode_count] = mode;
        output.mode_count += 1;
        if (output.preferred_mode_id == 0 and mode.flags & a.gfx_output_mode_preferred != 0) output.preferred_mode_id = mode.mode_id;
    }
}

// Physical connector values from the already pinned NVIDIA 570.144
// ctrl0073specific.h. Neither a sink HDMI VSDB nor an SOR protocol proves
// the physical socket type. Ambiguous/multiple records remain unknown.
fn kind(route: *const topology.Route) u32 {
    if (route.wiring.relation == .virtual) return 0;
    const connectors = route.connectors orelse return 0;
    if (!connectors.present()) return 0;
    const physical = if (route.wiring.physical_status == .matched) route.wiring.physical.? else
        if (route.wiring.physical_status == .unavailable and connectors.count == 1) connectors.data[0] else return 0;
    return switch (physical.kind) {
        0x61, 0x63 => a.gfx_output_kind_hdmi,
        0x46, 0x48 => a.gfx_output_kind_displayport,
        0x47 => a.gfx_output_kind_edp,
        else => 0,
    };
}
