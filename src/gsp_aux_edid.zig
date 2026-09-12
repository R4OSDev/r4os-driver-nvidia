// AUX protocol reference notices; original R4OS ownership code remains Apache-2.0.
// Linux/drivers/gpu/drm/display/drm_dp_helper.c
// /*
//  * Copyright © 2009 Keith Packard
//  *
//  * Permission to use, copy, modify, distribute, and sell this software and its
//  * documentation for any purpose is hereby granted without fee, provided that
//  * the above copyright notice appear in all copies and that both that copyright
//  * notice and this permission notice appear in supporting documentation, and
//  * that the name of the copyright holders not be used in advertising or
//  * publicity pertaining to distribution of the software without specific,
//  * written prior permission.  The copyright holders make no representations
//  * about the suitability of this software for any purpose.  It is provided "as
//  * is" without express or implied warranty.
//  *
//  * THE COPYRIGHT HOLDERS DISCLAIM ALL WARRANTIES WITH REGARD TO THIS SOFTWARE,
//  * INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS, IN NO
//  * EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY SPECIAL, INDIRECT OR
//  * CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE,
//  * DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
//  * TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE
//  * OF THIS SOFTWARE.
//  */
// Nvidia/Nouveau/drivers/gpu/drm/nouveau/nvkm/subdev/gsp/rm/r535/disp.c
// /*
//  * Copyright 2023 Red Hat Inc.
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
//  * THE COPYRIGHT HOLDER(S) OR AUTHOR(S) BE LIABLE FOR ANY CLAIM, DAMAGES OR
//  * OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
//  * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  * OTHER DEALINGS IN THE SOFTWARE.
//  */
//! One EDID block over the bounded AUX allowlist. Partial data stays private
//! until all 128 bytes complete; failures explicitly close an open I2C MOT.
const std = @import("std");
const wire = @import("gsp_aux_wire.zig");
pub const Error = error{ State, Query, Clock, FirmwareResult };
pub const State = enum { segment, offset, read, stop, complete, rejected };
pub const Reader = struct {
    block: u8,
    state: State,
    force_zero: bool,
    status_query: bool = false,
    cursor: u8 = 0,
    bytes: [128]u8 = @splat(0),
    rm_retries: u8 = 0,
    defer_retries: u8 = 0,
    retries: u16 = 0,
    retry_at_ns: u64 = 0,
    failure_status: ?u32 = null,
    failure_reply: ?wire.ReplyType = null,
    aborting: bool = false,
    pub fn init(block: u8, force_zero: bool) Error!Reader {
        if (block >= 32) return error.Query;
        return .{ .block = block, .force_zero = force_zero, .state = if (block >= 2 or force_zero) .segment else .offset };
    }
    pub fn query(self: *const Reader, display_id: u32) Error!wire.Request {
        return .{ .display_id = display_id, .operation = switch (self.state) {
            .segment => if (self.status_query) .segment_status else .{ .segment = self.block / 2 },
            .offset => if (self.status_query) .offset_status else .{ .offset = self.block % 2 * 128 + self.cursor },
            .read => .{ .read = .{ .count = @min(16, 128 - self.cursor), .last = self.cursor >= 112 } },
            .stop => .stop,
            else => return error.State,
        } };
    }
    pub fn abort(self: *Reader, open: bool) void {
        self.aborting = true;
        self.state = if (open) .stop else .rejected;
        self.retry_at_ns = 0;
        self.status_query = false;
    }
    fn delay(self: *Reader, now: u64, delay_ns: u64) Error!void {
        self.retry_at_ns = std.math.add(u64, now, delay_ns) catch return error.Clock;
        self.retries += 1;
    }
    pub fn consume(self: *Reader, reply: wire.Reply, now: u64, open: bool) Error!void {
        if (self.state == .complete or self.state == .rejected) return error.State;
        if (reply.status != 0) {
            if ((reply.status == 3 or reply.status == 0x66) and self.rm_retries < 2) {
                self.rm_retries += 1;
                try self.delay(now, @max(500 * std.time.ns_per_us, @as(u64, reply.retry_ms) * std.time.ns_per_ms));
                return;
            }
            self.failure_status = reply.status;
            if (self.state == .stop) return error.FirmwareResult;
            self.abort(open);
            return;
        }
        if (reply.kind == .defer_reply or reply.kind == .i2c_defer or
            (reply.kind == .ack and reply.count == 0 and self.state != .stop and self.state != .read)) {
            if (self.defer_retries < 7) {
                self.defer_retries += 1;
                if (reply.kind == .i2c_defer and (self.state == .segment or self.state == .offset)) self.status_query = true;
                try self.delay(now, 500 * std.time.ns_per_us);
                return;
            }
            self.failure_reply = reply.kind;
            if (self.state == .stop) return error.FirmwareResult;
            self.abort(open);
            return;
        }
        if (reply.kind != .ack or (reply.count == 0 and self.state == .read)) {
            self.failure_reply = reply.kind;
            if (self.state == .stop) return error.FirmwareResult;
            self.abort(open);
            return;
        }
        self.rm_retries = 0;
        self.defer_retries = 0;
        self.retry_at_ns = 0;
        self.status_query = false;
        switch (self.state) {
            .segment => self.state = .offset,
            .offset => self.state = .read,
            .read => {
                const last = self.cursor >= 112;
                if (reply.count > 128 - self.cursor or reply.count > 16) return error.State;
                @memcpy(self.bytes[self.cursor..][0..reply.count], reply.data[0..reply.count]);
                self.cursor += reply.count;
                if (self.cursor == 128) self.state = .complete else if (last) {
                    // The short final read already sent STOP. Restart selection
                    // at the exact next byte, including the segment if needed.
                    self.state = if (self.block >= 2 or self.force_zero) .segment else .offset;
                }
            },
            .stop => self.state = .rejected,
            else => return error.State,
        }
    }
};
