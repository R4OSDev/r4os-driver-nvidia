// Raster conversion derived from NVIDIA 570.144 nvkms-evo.c/clc67d.h (MIT).
// SPDX-FileCopyrightText: Copyright (c) 2014 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-FileCopyrightText: Copyright (c) 2020 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: MIT
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
//! Native RGB8 timing selection on the retained single-head TMDS route.
//! R4GFX owns parsing and published mode IDs. This layer converts one exact
//! current receiver timing; no synthesized modes, cached EDID or MMIO.
const std = @import("std");
const boot = @import("gsp_boot_mode.zig");
const outputs = @import("gsp_outputs.zig");
const catalog = @import("gsp_catalog.zig");
const receiver = @import("gsp_receiver.zig");
const timing = receiver.edid.timing;

/// The caller supplies the freshly recaptured and bound boot route. A mode
/// ID is local to this exact output generation and final RM receipt.
pub fn select(saved: boot.Plan, snapshot: *const outputs.Snapshot, id: u32) !boot.Plan {
    if (id == 0 or saved.receiver_mode_id != 0 or saved.cta_vic != 0) return error.Descriptor;
    if (!std.meta.eql(saved, try boot.bind(saved, snapshot, saved.epoch, saved.held_generation))) return error.Stale;
    for (snapshot.receivers[0..snapshot.count]) |*capture| if (capture.display_id == saved.signal.display_id) {
        if (capture.connected != true or capture.status != .valid_edid or !capture.report.complete()) return error.Stale;
        const report = &capture.report;
        if (!report.digital or report.colors & 1 == 0 or (report.bits_per_color != 0 and report.bits_per_color < 8)) return error.Unsupported;
        var modes: catalog.Modes = .{ .report = report };
        while (modes.next()) |entry| if (entry.mode.mode_id == id) {
            const value = entry.timing;
            // The currently negotiated scanout path has no interlace,
            // repetition, YUV, DSC, scaling or extended AVI VIC encoding.
            if (value.flags & (timing.interlaced | timing.y420_only | timing.incomplete) != 0 or
                value.vic > 127 or value.clock_hz > 0x7fffffff or value.h_total > 0x7fff or value.v_total > 0x7fff)
                return error.Unsupported;
            const h_end = value.h_total - value.h_start;
            const v_end = value.v_total - value.v_start;
            const h_sync = value.h_end - value.h_start;
            const v_sync = value.v_end - value.v_start;
            // Hardware raster origin is at sync, with inclusive sync/blank
            // ends. Total size has no minus-one adjustment (nvkms-evo.c).
            if (h_sync >= h_end or v_sync >= v_end or v_end < 2) return error.Unsupported;
            var result = saved;
            result.receiver_mode_id = id;
            result.cta_vic = if (report.hdmi) @intCast(value.vic) else 0;
            result.transport_hdmi = report.hdmi;
            result.width = value.width; result.height = value.height;
            result.refresh_micro_hz = value.clock_hz * 1_000_000 / (@as(u64, value.h_total) * value.v_total);
            result.signal.clock = @intCast(value.clock_hz);
            result.signal.total = pair(value.h_total, value.v_total);
            result.signal.sync_end = pair(h_sync - 1, v_sync - 1);
            result.signal.blank_end = pair(h_end - 1, v_end - 1);
            result.signal.blank_start = pair(value.width + h_end - 1, value.height + v_end - 1);
            result.signal.viewport = pair(value.width, value.height);
            result.signal.polarity = (if (value.flags & timing.h_positive == 0) @as(u32, 4) else 0) |
                (if (value.flags & timing.v_positive == 0) @as(u32, 8) else 0);
            result.signal.hdmi = 0; // Normal 2D AVI; retire any boot HDMI-VIC VSI.
            result.signal.min_frame_idle = pair(v_end, value.v_start - value.height);
            try boot.validate(result.signal, result.head);
            return result;
        };
        return error.Unsupported;
    };
    return error.Stale;
}
fn pair(x: u32, y: u32) u32 { return x | (y << 16); }
