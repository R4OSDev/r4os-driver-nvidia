// NVIDIA570.144/src/common/sdk/nvidia/inc/nverror.h
// /*
//  * Copyright (c) 1993-2024, NVIDIA CORPORATION. All rights reserved.
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
//  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
//  * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  * DEALINGS IN THE SOFTWARE.
//  */
//
// NVIDIA570.144/src/common/sdk/nvidia/inc/nvstatuscodes.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2014-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//
// NVIDIA570.144/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2019-2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
//
//! Resident worker-owned diagnostic journal. Hardware CHID, opaque work token
//! and RM session cid are distinct. Candidate ownership is never an exact match.
const std = @import("std");
const a = @import("r4os").abi;
const events = @import("gsp_runtime_events.zig");
pub const Source = enum { xid, rc, mmu_queue, fecs, recovery, nocat, rm, host, irq };
pub const Kind = enum { information, mmu, fifo, copy_engine, context, invalid_channel, resource, device, unknown };
pub const Operation = enum { event, channel, context, mapping, native_buffer, submit, teardown, interrupt, display_engine, display_channel };
pub const Record = struct {
    serial: u64 = 0,
    epoch: u64 = 0,
    time_ns: u64 = 0,
    source: Source = .host,
    kind: Kind = .unknown,
    operation: Operation = .event,
    rm_handle: u32 = 0,
    fatal: bool = false,
    code: u64 = 0,
    previous_xid: u32 = 0,
    hardware_channel: ?u32 = null,
    runlist: ?u32 = null,
    nv_engine: ?u32 = null,
    fault_address: ?u64 = null,
    fault_type: u32 = 0,
    scope: u32 = 0,
    exception_level: u32 = 0,
    partition: u16 = 0,
    callback_needed: bool = false,
    diagnostic_bytes: u32 = 0,
    text: [160]u8 = @splat(0),
    text_bytes: u16 = 0,
    receipt: ?events.Scope = null,
    acknowledged: bool = false,
    candidate_channels: u16 = 0,
    candidate_rm_handle: u32 = 0,
    candidate_rm_cid: u32 = 0,
    active_fence: a.GfxFence = .{},
    copy_point: u32 = 0,
    source_address_match: bool = false,
    target_address_match: bool = false,
    irq: u8 = 0,
    irq_raw: u32 = 0,
    irq_mask: u32 = 0,
    irq_received: u64 = 0,
    irq_messages: u64 = 0,
};
pub fn xidKind(code: u32) Kind {
    return switch (code) {
        23, 87 => .information, // RC logging enabled / telemetry report.
        31 => .mmu,
        32, 80 => .fifo,
        39, 40, 41, 70, 71, 72, 75, 76, 77, 85 => .copy_engine,
        13, 43, 44, 45, 69 => .context,
        48, 58, 79 => .device,
        else => .unknown,
    };
}
pub fn rmKind(status: u32) Kind {
    return switch (status) { 0x1a, 0x51 => .resource, 0x21 => .invalid_channel, else => .unknown };
}
fn hardware(value: u32) ?u32 { return if (value == std.math.maxInt(u32)) null else value; }
fn retainText(record: *Record, text: []const u8) void {
    record.text_bytes = @intCast(@min(text.len, record.text.len));
    @memcpy(record.text[0..record.text_bytes], text[0..record.text_bytes]);
}
pub fn host(operation: Operation, err: anyerror, fatal: bool) Record {
    var record: Record = .{ .source = .host, .operation = operation, .code = @intFromError(err), .fatal = fatal,
        .kind = switch (err) { error.Memory, error.Exhausted, error.OutOfMemory => .resource, else => .unknown } };
    retainText(&record, @errorName(err));
    return record;
}
pub fn event(scope: events.Scope, value: events.Event, now: u64) ?Record {
    var record: Record = .{ .epoch = scope.epoch, .time_ns = now, .receipt = scope };
    switch (value) {
        .os_error => |v| {
            record.source = .xid; record.kind = xidKind(v.xid); record.code = v.xid; record.previous_xid = v.previous_xid;
            record.hardware_channel = hardware(v.channel); record.runlist = hardware(v.runlist); retainText(&record, v.text);
            record.fatal = record.kind != .information;
        },
        .rc_triggered => |v| {
            record.source = .rc; record.kind = xidKind(v.exception_type); record.fatal = true; record.code = v.exception_type;
            record.hardware_channel = hardware(v.channel); record.nv_engine = v.engine_type;
            record.scope = v.scope; record.exception_level = v.exception_level; record.partition = v.partition;
            record.fault_address = v.fault_address; record.fault_type = v.fault_type; record.callback_needed = v.callback_needed;
            record.diagnostic_bytes = @intCast(v.journal.len);
        },
        .mmu_fault_queued => { record.source = .mmu_queue; record.kind = .mmu; record.fatal = true; },
        .fecs_error => |v| { record.source = .fecs; record.kind = .context; record.code = v.error_type; record.fatal = true; },
        .recovery_action => |v| { record.source = .recovery; record.kind = .device; record.code = v.action_type; record.fatal = v.value; },
        .nocat => |v| {
            // This is a journal record, not by itself a quiescence/fatality
            // declaration. Preserve its raw diagnostics alongside RC/XID.
            record.source = .nocat; record.code = v.error_code; record.scope = v.flags;
            record.fault_type = v.bugcheck; record.exception_level = v.tdr_reason;
            record.diagnostic_bytes = @intCast(v.diagnostic.len); retainText(&record, v.source);
        },
        else => return null,
    }
    return record;
}
pub const Journal = struct {
    records: [16]Record = @splat(.{}),
    first_fatal: ?Record = null,
    serial: u64 = 0,
    dropped: u64 = 0,
    pending: bool = false,
    pub fn append(self: *Journal, value: Record) !*Record {
        self.serial = std.math.add(u64, self.serial, 1) catch return error.Exhausted;
        const record = &self.records[(self.serial - 1) % self.records.len];
        if (record.serial != 0) self.dropped +|= 1;
        record.* = value; record.serial = self.serial;
        if (value.fatal) {
            self.pending = true;
            if (self.first_fatal == null) self.first_fatal = record.*;
        }
        return record;
    }
    pub fn acknowledge(self: *Journal, scope: events.Scope) void {
        for (&self.records) |*record| if (record.receipt) |receipt| if (std.meta.eql(receipt.ticket, scope.ticket) and receipt.epoch == scope.epoch) {
            record.acknowledged = true;
        };
        if (self.first_fatal) |*first| if (first.receipt) |receipt| if (std.meta.eql(receipt.ticket, scope.ticket) and receipt.epoch == scope.epoch) {
            first.acknowledged = true;
        };
    }
};
