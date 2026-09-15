// NVIDIA 570.144/src/common/sdk/nvidia/inc/class/cl00de.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2022-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// NVIDIA 570.144/src/common/sdk/nvidia/inc/ctrl/ctrl2080/ctrl2080perf.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2005-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//! Workload demand only: firmware arbitrates voltage, clocks, display floors
//! and board limits. No forced P-state, PLL write or protection override.
const std = @import("std");
pub const hold_ns = 250 * std.time.ns_per_ms;
pub const renew_ns = std.time.ns_per_s;
pub const duration_seconds: u16 = 2;
pub const Reason = enum { idle, settling, desktop, multi_output, render, fullscreen, video, compute, limited, stopping };
pub const Availability = enum { unprobed, available, rejected };
pub const Activity = struct {
    copy: bool = false, render: bool = false, video: bool = false, compute: bool = false,
    display_commit: bool = false, cursor: bool = false, fullscreen: bool = false,
    outputs: u8 = 0, stopping: bool = false,
};
pub const Limits = struct {
    // Only a fresh firmware mask is authoritative; an unavailable sensor
    // never authorizes higher board limits. The firmware always owns them.
    throttle_mask: ?u32 = null,
    pub fn constrained(self: Limits) bool {
        const mask = self.throttle_mask orelse return false;
        // Power cap, hardware slowdown, thermal slowdown and power brakes.
        return mask & 0xec != 0;
    }
};
pub const Request = struct { serial: u64, level: u2, seconds: u16, reason: Reason, issued_ns: u64 };
pub const Owner = struct {
    available: Availability = .unprobed,
    rejection: ?u32 = null,
    reason: Reason = .idle,
    last_now: u64 = 0,
    last_activity: ?u64 = null,
    last_high_activity: ?u64 = null,
    last_accepted: u64 = 0,
    accepted_level: u2 = 0,
    accepted_until: u64 = 0,
    serial: u64 = 0,
    pending: ?Request = null,
    accepted_requests: u64 = 0,

    pub fn next(self: *Owner, now: u64, activity: Activity, limits: Limits) !?Request {
        if (now == 0 or now < self.last_now) return error.Clock;
        if (activity.outputs > 8) return error.Parameter;
        self.last_now = now;
        var level: u2 = 0;
        if (activity.stopping) self.reason = .stopping else if (limits.constrained()) self.reason = .limited else if (activity.compute) {
            self.reason = .compute; level = 2;
        } else if (activity.fullscreen and (activity.copy or activity.render)) {
            self.reason = .fullscreen; level = 2;
        } else if (activity.render) {
            self.reason = .render; level = 2;
        } else if (activity.video) {
            self.reason = .video; level = 1;
        } else if (activity.copy or activity.display_commit or activity.cursor) {
            self.reason = if (activity.outputs > 1) .multi_output else .desktop; level = 1;
        } else if (self.last_activity) |last| {
            self.reason = if (now - last < hold_ns) .settling else .idle;
        } else self.reason = .idle;
        if (level == 2) self.last_high_activity = now;
        if (level == 1) if (self.last_high_activity) |last| {
            if (now - last < hold_ns) level = 2;
        };
        if (level != 0) self.last_activity = now;
        if (self.pending != null or self.available == .rejected) return null;
        // Display presence and vblank alone do not renew performance demand.
        // Keep the prior finite request briefly when work has just stopped.
        if (self.reason == .settling) return null;
        if (self.accepted_level != 0 and now >= self.accepted_until) self.accepted_level = 0;
        if (level == self.accepted_level and (level == 0 or now - self.last_accepted < renew_ns)) return null;
        self.serial = std.math.add(u64, self.serial, 1) catch return error.Overflow;
        const value: Request = .{ .serial = self.serial, .level = level,
            .seconds = if (level == 0) 0 else duration_seconds, .reason = self.reason, .issued_ns = now };
        self.pending = value;
        return value;
    }
    pub fn complete(self: *Owner, request: Request, status: u32, now: u64) !void {
        const pending = self.pending orelse return error.State;
        if (!std.meta.eql(pending, request)) return error.Stale;
        if (now == 0 or now < self.last_now or now < request.issued_ns) return error.Clock;
        self.last_now = now;
        self.pending = null;
        if (status != 0) {
            self.available = .rejected;
            self.rejection = status;
            return;
        }
        self.available = .available;
        self.accepted_level = request.level;
        self.last_accepted = now;
        self.accepted_until = now +| (@as(u64, request.seconds) * std.time.ns_per_s);
        self.accepted_requests +|= 1;
    }
};
