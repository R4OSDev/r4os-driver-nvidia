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
    transport_hdmi: bool = false,
    signal: Signal,
};

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
    // One progressive RGB8 signal without repetition, scaling, frame lock,
    // pixel-clock hopping or colour-space override.
    const protocol = scanout.protocol(raw.sors[sor]);
    if (protocol != .tmds_a and protocol != .tmds_b) return error.Unsupported;
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
    var id: u32 = 0;
    const head_mask = @as(u32, 1) << @intCast(saved.head);
    for (snapshot.topology.routes[0..snapshot.count], snapshot.receivers[0..snapshot.count]) |*route, *receiver| {
        if (route.id == 0 or route.id & (route.id - 1) != 0 or receiver.display_id != route.id or
            receiver.epoch != epoch or receiver.client != snapshot.topology.client) return error.Stale;
        const resource = route.resource orelse continue;
        if (resource.index != saved.signal.sor or resource.kind != 2 or resource.dynamic or resource.location != 0 or
            resource.protocol != (saved.signal.sor_control >> 8) & 15) continue;
        const active = snapshot.topology.activeHeads(route.id) orelse return error.Routing;
        if (active != 0 and active != head_mask) return error.Routing;
        const physical = route.connectors orelse return error.Routing;
        if (!physical.present() or physical.count != 1 or (physical.data[0].kind != 0x61 and physical.data[0].kind != 0x63)) return error.Unsupported;
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
    if (head >= 8 or signal.sor >= 8 or signal.display_id == 0 or signal.display_id & (signal.display_id - 1) != 0 or
        signal.sor_control & 255 != @as(u32, 1) << @intCast(head) or signal.sor_control & ~@as(u32, 0x10fff) != 0 or
        signal.polarity & ~@as(u32, 12) != 0 or signal.hdmi & ~@as(u32, 0xff1) != 0) return error.Descriptor;
    if (scanout.protocol(signal.sor_control) != .tmds_a and scanout.protocol(signal.sor_control) != .tmds_b) return error.Unsupported;
    var source: scanout.Head = .{};
    source.words = .{ 0x40 | signal.polarity, 0, signal.clock, 0, signal.viewport, signal.viewport,
        signal.total, signal.sync_end, signal.blank_end, signal.blank_start };
    const timing = scanout.timing(&source) catch return error.Descriptor;
    if (!std.meta.eql(timing.active, timing.viewport_in) or timing.active.x == 0 or timing.active.y == 0) return error.Descriptor;
    const leading = @as(u32, timing.blank_end.y) + 1;
    const trailing = @as(u32, timing.total.y) - leading - timing.active.y;
    if (signal.min_frame_idle != leading | (trailing << 16)) return error.Descriptor;
}
