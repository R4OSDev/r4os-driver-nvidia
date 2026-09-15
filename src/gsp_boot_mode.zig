// Derived class-field portions: NVIDIA 570.144 clc67d.h, MIT.
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2020 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//! Single-output RGB boot-mode adoption, derived from the retained armed
//! snapshot. Receiver discovery supplies an identity, never new timings or
//! permission to exceed the already running link. No EDID fallback modes.
const std = @import("std");
const a = @import("r4os").abi;
const scanout = @import("boot_scanout.zig");
const outputs = @import("gsp_outputs.zig");
pub const Error = error{ Bounds, Descriptor, Unsupported, Routing, Stale };
pub const Signal = struct {
    sor: u32,
    sor_control: u32,
    display_id: u32 = 0,
    clock: u32,
    total: u32,
    sync_end: u32,
    blank_end: u32,
    blank_start: u32,
    viewport: u32,
    polarity: u32,
    hdmi: u32,
    min_frame_idle: u32,
    bpc: u8 = 8,
    dp_vsc: bool = false,
    mst: ?@import("gsp_mst_binding.zig").Stamp = null,
    //Requested wire encoding; the retained DCB route keeps its identity.
    hdmi_frl: bool = false,
    dp_dsc: ?@import("gsp_dsc.zig").DpPlan = null,
    hdmi_dsc: ?@import("gsp_dsc.zig").HdmiPlan = null,
};
pub const Plan = struct {
    epoch: u64 = 0,
    held_generation: u64 = 0,
    boot_generation: u64,
    output_generation: u64 = 0,
    receipt_serial: u64 = 0,
    head: u32,
    window: u32,
    width: u32,
    height: u32,
    refresh_micro_hz: u64,
    // Zero identifies the retained firmware timing. Other values identify
    // the published mode in the current receiver capture, never an index
    // into its raw parser array. Runtime rederives either source at each gate.
    receiver_mode_id: u32 = 0,
    cta_vic: u8 = 0,
    transport_hdmi: bool = false,
    frl_max_rate: u8 = 0,
    hdmi_dsc_sink: @import("gsp_dsc.zig").links.HdmiDsc = .{},
    hdmi_dsc_only: bool = false,
    cursor_size: u16 = 0,
    color: ?@import("gsp_color_signal.zig").color.Signal = null,
    color_pipeline: @import("gsp_color_signal.zig").color.Pipeline = .{
        .linear_composition = false, .output_transform = false, .opaque_output = false },
    signal: Signal,
    pub fn displayPort(self: Plan) bool { return isDisplayPort(self.signal); }
    pub fn hasAudio(self: Plan) bool {
        if (self.signal.mst != null and self.head >= 4) return false; // RM exposes four MST audio device entries.
        return self.transport_hdmi or self.displayPort();
    }
    /// Equality of the receiver-selected request, excluding only the HDMI
    /// compression parameters that the real RM capacity query must supply.
    /// This comparison is not an admission receipt.
    pub fn sameIntent(self: Plan, other: Plan) bool {
        var left = self; var right = other;
        left.signal.hdmi_dsc = null; right.signal.hdmi_dsc = null;
        return std.meta.eql(left, right);
    }
};
pub fn isDisplayPort(signal: Signal) bool {
    const protocol = scanout.protocol(signal.sor_control);
    return protocol == .dp_a or protocol == .dp_b;
}

/// Pure preflight: no allocation, state mutation, RPC or MMIO. In particular,
/// unknown/cloned routes and stereo/YUV/FRL are not silently changed to RGB.
pub fn capture(raw: *const scanout.Raw, boot: *const a.GfxNativeBootInfo, window: u32) Error!Plan {
    if (boot.version != 1 or boot.size < @sizeOf(a.GfxNativeBootInfo) or boot.generation == 0 or
        boot.physical_address == 0 or boot.width == 0 or boot.height == 0 or
        boot.width > 0x7fff or boot.height > 0x7fff or boot.pitch < @as(u64, boot.width) * 4 or
        @as(u64, boot.pitch) * boot.height > boot.byte_length) return error.Descriptor;
    if (boot.format != a.gfx_buffer_format_xrgb8888) return error.Unsupported;
    if (window >= 8 or raw.windowCount() > 8 or window >= raw.windowCount() or raw.headCount() > 8 or raw.sorCount() > 8 or
        raw.window_mask & ~@as(u32, 255) != 0 or raw.window_mask & (@as(u32, 1) << @intCast(window)) == 0) return error.Bounds;
    const heads = scanout.routedHeads(raw);
    if (@popCount(heads) != 1 or heads & ~raw.headMask() != 0) return error.Routing;
    const head: u32 = @ctz(heads);
    const sors = scanout.headSors(raw, head);
    if (@popCount(sors) != 1) return error.Routing;
    const sor: u32 = @ctz(sors);
    if (head >= raw.headCount() or sor >= raw.sorCount()) return error.Routing;
    const source = &raw.heads[head];
    const timing = scanout.timing(source) catch return error.Unsupported;
    // The firmware's compressed PPS/FEC state has no admitted receiver
    // proof. Retain bootfb for that case; a later driver-owned DSC mode is
    // established through the full capability/training transaction.
    if (source.dsc_control & 1 != 0 or source.dsc_pps_control & 1 != 0) return error.Unsupported;
    // One progressive RGB8 signal without repetition, scaling, frame lock,
    // pixel-clock hopping or colour-space override.
    const protocol = scanout.protocol(raw.sors[sor]);
    if (protocol != .tmds_a and protocol != .tmds_b and protocol != .dp_a and protocol != .dp_b) return error.Unsupported;
    if ((protocol == .dp_a or protocol == .dp_b) and timing.hdmi_enabled) return error.Unsupported;
    if (source.get(.control) != 0 or source.get(.clock_config) & ~@as(u32, 1) != 0 or
        timing.depth_code != 4 or source.get(.output) & 0x01000000 != 0 or
        raw.sors[sor] & ~@as(u32, 0x10fff) != 0 or
        source.color.get(.point_in) != 0 or source.color.get(.point_out_adjust) != 0 or
        source.color.get(.hdmi) & ~@as(u32, 0xff1) != 0 or source.color.get(.hdmi) & 7 > 1) return error.Unsupported;
    const size: scanout.Size = .{ .x = @intCast(boot.width), .y = @intCast(boot.height) };
    if (!std.meta.eql(timing.active, size) or !std.meta.eql(timing.viewport_in, size) or
        !std.meta.eql(timing.viewport_out, size)) return error.Unsupported;
    const leading = @as(u32, timing.blank_end.y) + 1;
    const trailing = @as(u32, timing.total.y) - leading - boot.height;
    if (leading < 2 or leading > 0x7fff or trailing > 0x7fff) return error.Bounds;
    return .{ .boot_generation = boot.generation, .head = head, .window = window,
        .width = boot.width, .height = boot.height, .refresh_micro_hz = timing.raster_micro_hz,
        .transport_hdmi = timing.hdmi_enabled,
        .signal = .{ .sor = sor, .sor_control = raw.sors[sor], .clock = source.get(.clock),
            .total = source.get(.total), .sync_end = source.get(.sync_end), .blank_end = source.get(.blank_end),
            .blank_start = source.get(.blank_start), .viewport = source.get(.viewport_in),
            .polarity = source.get(.output) & 12, .hdmi = source.color.get(.hdmi),
            .min_frame_idle = leading | (trailing << 16) } };
}

/// Bind the saved signal to one coherent actual RM route. Unassigned heads
/// after firmware startup are allowed; a conflicting assignment is not.
pub fn bind(saved: Plan, snapshot: *const outputs.Snapshot, epoch: u64, held_generation: u64) Error!Plan {
    if (saved.head >= 8 or saved.window >= 8 or saved.signal.sor >= 8) return error.Bounds;
    if (epoch == 0 or held_generation == 0 or !snapshot.coherent or snapshot.generation == 0 or
        snapshot.final_receipt_serial == 0 or snapshot.topology.epoch != epoch or snapshot.topology.client == 0 or
        snapshot.topology.rejected != null or snapshot.final_rejection != null or
        snapshot.count != snapshot.topology.count or snapshot.count > snapshot.topology.routes.len) return error.Stale;
    const head_count = snapshot.topology.head_count orelse return error.Routing;
    if (head_count > snapshot.topology.heads.len or saved.head >= head_count) return error.Routing;
    if (saved.signal.mst) |stamp| {
        if (!saved.displayPort() or stamp.handle.epoch != epoch or saved.signal.display_id != stamp.display_id) return error.Stale;
        const view = try @import("gsp_mst_binding.zig").derive(snapshot, stamp.display_id);
        if (!std.meta.eql(stamp, view.stamp) or view.slot.sor != saved.signal.sor or
            8 + view.slot.link != (saved.signal.sor_control >> 8) & 15) return error.Stale;
        const active = snapshot.topology.activeHeads(stamp.display_id) orelse return error.Routing;
        if (active != 0 and active != @as(u32, 1) << @intCast(saved.head)) return error.Routing;
        const current = snapshot.topology.heads[saved.head].display_id orelse return error.Routing;
        if (current != 0 and current != stamp.display_id) return error.Routing;
        var result = saved;
        result.epoch = epoch; result.held_generation = held_generation;
        result.output_generation = snapshot.generation; result.receipt_serial = snapshot.final_receipt_serial;
        return result;
    }
    var id: u32 = 0;
    const head_mask = @as(u32, 1) << @intCast(saved.head);
    for (snapshot.topology.routes[0..snapshot.count], snapshot.receivers[0..snapshot.count]) |*route, *receiver| {
        if (route.id == 0 or route.id & (route.id - 1) != 0 or receiver.display_id != route.id or
            receiver.epoch != epoch or receiver.client != snapshot.topology.client) return error.Stale;
        const resource = route.resource orelse continue;
        if (resource.index != saved.signal.sor or resource.kind != 2 or resource.dynamic or resource.location != 0 or
            resource.protocol != (saved.signal.sor_control >> 8) & 15) continue;
        if (saved.displayPort() and receiver.dp.receiver.mst_state == .complete and receiver.dp.receiver.mst)
            return error.Unsupported; // A branch's physical root is not an SST display.
        const active = snapshot.topology.activeHeads(route.id) orelse return error.Routing;
        if (active != 0 and active != head_mask) return error.Routing;
        const physical = route.connectors orelse return error.Routing;
        if (!physical.present() or physical.count != 1) return error.Unsupported;
        const kind = physical.data[0].kind;
        if (saved.displayPort()) {
            // External SST only. eDP panel power/backlight, Type-C alt-mode
            // and MST routes need their own capabilities and owners.
            if (kind != 0x46 and kind != 0x48) return error.Unsupported;
        } else switch (kind) {
            0x61, 0x63, 0x46, 0x48, 0x30, 0x31 => {}, // Actual TMDS, including a passive DP++ adapter.
            else => return error.Unsupported,
        }
        if (id != 0) return error.Routing;
        id = route.id;
    }
    if (id == 0) return error.Routing;
    var result = saved;
    result.epoch = epoch; result.held_generation = held_generation;
    result.output_generation = snapshot.generation; result.receipt_serial = snapshot.final_receipt_serial;
    result.signal.display_id = id;
    return result;
}

pub fn validate(signal: Signal, head: u32) Error!void {
    if ((signal.bpc != 8 and signal.bpc != 10) or (signal.dp_vsc and !isDisplayPort(signal))) return error.Unsupported;
    if (signal.mst) |stamp| {
        if (!isDisplayPort(signal) or signal.dp_dsc != null or signal.dp_vsc) return error.Unsupported;
        if (stamp.display_id != signal.display_id or stamp.handle.epoch == 0 or stamp.handle.serial == 0 or
            stamp.root == 0 or stamp.root & (stamp.root - 1) != 0 or stamp.root == stamp.display_id) return error.Descriptor;
    }
    if (head >= 8 or signal.sor >= 8 or signal.display_id == 0 or signal.display_id & (signal.display_id - 1) != 0 or
        signal.sor_control & 255 != @as(u32, 1) << @intCast(head) or signal.sor_control & ~@as(u32, 0x10fff) != 0 or
        signal.polarity & ~@as(u32, 12) != 0 or signal.hdmi & ~@as(u32, 0xff1) != 0) return error.Descriptor;
    if (scanout.protocol(signal.sor_control) != .tmds_a and scanout.protocol(signal.sor_control) != .tmds_b and !isDisplayPort(signal)) return error.Unsupported;
    if (isDisplayPort(signal) and (signal.hdmi != 0 or signal.hdmi_frl)) return error.Unsupported;
    if (signal.hdmi_frl and signal.hdmi != 0) return error.Unsupported;
    if (signal.hdmi_dsc) |compressed| {
        if (!signal.hdmi_frl or isDisplayPort(signal) or signal.dp_dsc != null or compressed.rate == .none) return error.Unsupported;
        const pps = compressed.params.bytes();
        if (pps[0] != 0x12 or pps[3] >> 4 != signal.bpc or pps[4] & 0x1c != 0x10 or pps[88] != 0 or
            std.mem.readInt(u16, pps[6..8], .big) != signal.viewport >> 16 or std.mem.readInt(u16, pps[8..10], .big) != signal.viewport & 0xffff or
            compressed.params.bpp_x16 < 128 or compressed.params.bpp_x16 >= @as(u16, signal.bpc) * 48 or
            compressed.params.slices == 0 or compressed.params.slices > 16 or compressed.params.slice_width == 0 or
            compressed.params.slice_height < 8 or compressed.params.chunk_bytes == 0 or compressed.hc_active_bytes == 0 or
            compressed.hc_active_tri_bytes == 0 or compressed.blank_ratio_x1k > 1000) return error.Descriptor;
    }
    if(signal.dp_dsc) |dsc| {
        if(!isDisplayPort(signal)) return error.Unsupported;
        _=@import("gsp_dsc.zig").fecPayload(dsc.rate,dsc.lanes) catch return error.Descriptor;
        const pps=dsc.params.bytes();
        if((pps[0]!=0x11 and pps[0]!=0x12) or pps[3]>>4!=signal.bpc or pps[4]&0x1c!=0x10 or pps[88]!=0 or
            std.mem.readInt(u16,pps[6..8],.big)!=signal.viewport>>16 or std.mem.readInt(u16,pps[8..10],.big)!=signal.viewport&0xffff or
            dsc.params.bpp_x16<128 or dsc.params.bpp_x16>=@as(u16,signal.bpc)*3*16 or dsc.params.slices==0 or dsc.params.slices>24 or
            dsc.params.slice_width==0 or dsc.params.slice_height<8 or dsc.params.chunk_bytes==0) return error.Descriptor;
    }
    var source: scanout.Head = .{};
    source.words = .{ 0x40 | signal.polarity, 0, signal.clock, 0, signal.viewport, signal.viewport,
        signal.total, signal.sync_end, signal.blank_end, signal.blank_start };
    const timing = scanout.timing(&source) catch return error.Descriptor;
    if (!std.meta.eql(timing.active, timing.viewport_in) or timing.active.x == 0 or timing.active.y == 0) return error.Descriptor;
    const leading = @as(u32, timing.blank_end.y) + 1;
    const trailing = @as(u32, timing.total.y) - leading - timing.active.y;
    if (signal.min_frame_idle != leading | (trailing << 16)) return error.Descriptor;
}
