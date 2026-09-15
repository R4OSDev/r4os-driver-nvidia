// NVIDIA570.144/src/common/sdk/nvidia/inc/ctrl/ctrl2080/ctrl2080tmr.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2008-2015 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//! GPU global-timer samples; not a job duration or a CPU/GPU epoch mapping.
const std = @import("std");
const a = @import("r4os").abi;
pub const Owner = struct {
    metric: a.GfxTelemetryMetric = .{},
    received_ns: u64 = 0,
    previous: ?u64 = null,
    rejected: ?u32 = null,
    faulted: bool = false,
    pub fn accept(self: *Owner, gpu_ns: u64, sent_ns: u64, received_ns: u64) void {
        self.metric = .{};
        if (self.faulted or sent_ns == 0 or sent_ns < self.received_ns or received_ns < sent_ns or
            received_ns > std.math.maxInt(i64) or gpu_ns == 0 or gpu_ns > std.math.maxInt(i64)) {
            self.faulted = true; self.metric.status = a.gfx_telemetry_malformed; return;
        }
        self.metric.source_stamp = gpu_ns;
        self.received_ns = received_ns;
        if (self.previous) |previous| {
            if (gpu_ns < previous) { self.faulted = true; self.metric.status = a.gfx_telemetry_malformed; return; }
            if (gpu_ns == previous) { self.metric.status = a.gfx_telemetry_stale; return; }
            self.metric.flags = 1;
            self.metric.values[1] = @intCast(gpu_ns - previous);
        }
        self.metric.status = a.gfx_telemetry_fresh;
        self.metric.values[0] = @intCast(gpu_ns);
        self.metric.values[2] = @intCast(sent_ns);
        self.metric.values[3] = @intCast(received_ns);
        self.previous = gpu_ns;
    }
    pub fn snapshot(self: *const Owner, now: u64, max_age: u64) a.GfxTelemetryMetric {
        var output = self.metric;
        if (output.status == a.gfx_telemetry_fresh and (now < self.received_ns or now - self.received_ns >= max_age)) {
            output.status = a.gfx_telemetry_stale; output.flags = 0; output.values = @splat(0);
        }
        return output;
    }
};
pub fn check() !void {
    const t = std.testing;
    var value: Owner = .{};
    value.accept(1_790_000_000_000_000_000, 100, 120);
    try t.expect(value.metric.status == a.gfx_telemetry_fresh and value.metric.flags == 0 and value.metric.values[2] == 100 and value.metric.values[3] == 120);
    value.accept(1_790_000_001_000_000_000, 1_000_000_100, 1_000_000_120);
    try t.expect(value.metric.flags == 1 and value.metric.values[1] == 1_000_000_000);
    const stale = value.snapshot(4_000_000_120, 3 * std.time.ns_per_s);
    try t.expect(stale.status == a.gfx_telemetry_stale and stale.values[0] == 0);
    value.accept(1234, 2_000_000_100, 2_000_000_120);
    try t.expect(value.faulted and value.metric.status == a.gfx_telemetry_malformed and value.metric.values[0] == 0);
    value.accept(1_800_000_000_000_000_000, 3_000_000_100, 3_000_000_120);
    try t.expect(value.metric.status == a.gfx_telemetry_malformed);
}
