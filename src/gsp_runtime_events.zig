// Runtime notification ABI: NVIDIA570.144 (MIT); framing/delivery also
// informed by Nouveau (MIT). Original R4OS receipt/lifetime policy: Apache-2.0.
// Nvidia570.144/src/nvidia/generated/g_rpc-structures.h
// /*
//  * SPDX-FileCopyrightText: Copyright (c) 2008-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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
// Nvidia570.144/src/nvidia/inc/kernel/vgpu/rpc_global_enums.h
// Except where noted otherwise, the individual files within this package are
// licensed as MIT:
//
//     Copyright (c) 2021 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
//
//     Permission is hereby granted, free of charge, to any person obtaining a
//     copy of this software and associated documentation files (the "Software"),
//     to deal in the Software without restriction, including without limitation
//     the rights to use, copy, modify, merge, publish, distribute, sublicense,
//     and/or sell copies of the Software, and to permit persons to whom the
//     Software is furnished to do so, subject to the following conditions:
//
//     The above copyright notice and this permission notice shall be included in
//     all copies or substantial portions of the Software.
//
//     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//     IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//     FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
//     THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//     LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//     FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//     DEALINGS IN THE SOFTWARE.
// Nvidia570.144/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c
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
// Nvidia570.144/src/common/sdk/nvidia/inc/class/cl2080_notification.h
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
// Nouveau/drivers/gpu/drm/nouveau/nvkm/subdev/gsp/rm/r535/gsp.c
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
//! Bounded notification delivery from the sole GSP runtime exchange.
//! Receipts remain borrowed through actual owner delivery and queue ACK.
//! This layer neither creates RM event objects nor interprets a notification
//! as a completed modeset, connected monitor, successful recovery or GPU idle.
const std = @import("std");
const boot = @import("gsp_boot_events.zig");
const exchange = @import("gsp_exchange.zig");
const display_rpc = @import("gsp_display_rpc.zig");
const transport = exchange.transport;
const message = transport.message;
pub const Error = exchange.Error || error{ Unsupported, Denied, SequencerRequired };
pub const Kind = enum(u32) {
    post_event = 0x1003,
    rc_triggered = 0x1004,
    mmu_fault_queued = 0x1005,
    os_error = 0x1006,
    rg_line_intr = 0x1007,
    libos_print = 0x100c,
    display_modeset = 0x1011,
    extdev_intr_service = 0x1012,
    lockdown = 0x101c,
    nocat = 0x1020,
    fecs_error = 0x1021,
    recovery_action = 0x1022,
};
pub const Display = union(enum) {
    hotplug: struct { plug_mask: u32, unplug_mask: u32 },
    dp_irq: u32,
};
pub const Post = struct {
    client: u32,
    event: u32,
    index: u32,
    data: u32,
    info16: u16,
    status: u32,
    notify_list: bool,
    payload: []const u8,

    /// Call only after the RM event owner matched client/event/index to its
    /// live registration. Masks are change notifications, not fresh EDID or
    /// connection proof. Preserve every bit and simultaneous plug/unplug.
    pub fn display(self: Post) Error!?Display {
        switch (self.index) {
            1 => {
                if (self.payload.len != 8) return error.Payload;
                return .{ .hotplug = .{ .plug_mask = word(self.payload, 0), .unplug_mask = word(self.payload, 4) } };
            },
            7 => {
                if (self.payload.len != 4) return error.Payload;
                return .{ .dp_irq = word(self.payload, 0) };
            },
            else => return null,
        }
    }
};
pub const Rc = struct {
    engine_type: u32,
    channel: u32,
    gfid: u32,
    exception_level: u32,
    exception_type: u32,
    scope: u32,
    partition: u16,
    fault_address: u64,
    fault_type: u32,
    callback_needed: bool,
    journal: []const u8,
};
pub const Event = union(Kind) {
    post_event: Post,
    rc_triggered: Rc,
    mmu_fault_queued: void,
    os_error: boot.OsError,
    rg_line_intr: struct { head: u32, interrupts: u32 },
    libos_print: struct { engine: u32, bytes: []const u8 },
    display_modeset: struct { start: bool, iso_bandwidth_kbps: u32, floor_bandwidth_kbps: u32 },
    extdev_intr_service: struct { loss: u8, gain: u8, misc: u8, rm_status: bool },
    lockdown: bool,
    nocat: boot.Nocat,
    fecs_error: struct { graphics_index: u32, error_type: u8 },
    recovery_action: struct { action_type: u32, value: bool },
};
fn word(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
fn boolean(value: u8) Error!bool {
    if (value > 1) return error.Payload;
    return value == 1;
}
/// Fixed570.144 layouts. The original C sizeof and flexible-array offset can
/// differ: POST_EVENT has a32-byte base but eventData begins at byte29. Its
/// variable extent is sizeof(base)+eventDataSize, as checked by Nouveau.
/// C padding is not another field and is never required to contain zero.
pub fn decode(record: message.Record) Error!Event {
    if (record.rpc.cpu_rm_gfid != 0) return error.Guest;
    if (record.rpc.function == 0x1002) return error.SequencerRequired;
    const kind = std.enums.fromInt(Kind, record.rpc.function) orelse return error.UnknownEvent;
    const bytes = record.payload;
    if (bytes.len > message.max_payload_bytes) return error.Payload;
    switch (kind) {
        .post_event => {
            if (bytes.len < 32 or word(bytes, 24) != bytes.len - 32) return error.Payload;
            return .{ .post_event = .{
                .client = word(bytes, 0),
                .event = word(bytes, 4),
                .index = word(bytes, 8),
                .data = word(bytes, 12),
                .info16 = std.mem.readInt(u16, bytes[16..18], .little),
                .status = word(bytes, 20),
                .notify_list = try boolean(bytes[28]),
                .payload = bytes[29..][0..word(bytes, 24)],
            } };
        },
        .rc_triggered => {
            if (bytes.len < 48 or word(bytes, 44) != bytes.len - 48) return error.Payload;
            if (word(bytes, 8) != 0) return error.Guest; // Fixed bare-metal PF profile.
            return .{ .rc_triggered = .{
                .engine_type = word(bytes, 0),
                .channel = word(bytes, 4),
                .gfid = word(bytes, 8),
                .exception_level = word(bytes, 12),
                .exception_type = word(bytes, 16),
                .scope = word(bytes, 20),
                .partition = std.mem.readInt(u16, bytes[24..26], .little),
                .fault_address = @as(u64, word(bytes, 28)) | (@as(u64, word(bytes, 32)) << 32),
                .fault_type = word(bytes, 36),
                .callback_needed = try boolean(bytes[40]),
                .journal = bytes[48..],
            } };
        },
        .mmu_fault_queued => {
            if (bytes.len != 0) return error.Payload;
            return .mmu_fault_queued;
        },
        .rg_line_intr => {
            if (bytes.len != 8) return error.Payload;
            return .{ .rg_line_intr = .{ .head = word(bytes, 0), .interrupts = word(bytes, 4) } };
        },
        .display_modeset => {
            if (bytes.len != 12) return error.Payload;
            return .{ .display_modeset = .{ .start = try boolean(bytes[0]), .iso_bandwidth_kbps = word(bytes, 4), .floor_bandwidth_kbps = word(bytes, 8) } };
        },
        .extdev_intr_service => {
            if (bytes.len != 4) return error.Payload;
            return .{ .extdev_intr_service = .{ .loss = bytes[0], .gain = bytes[1], .misc = bytes[2], .rm_status = try boolean(bytes[3]) } };
        },
        .fecs_error => {
            if (bytes.len != 8) return error.Payload;
            return .{ .fecs_error = .{ .graphics_index = word(bytes, 0), .error_type = bytes[4] } };
        },
        .recovery_action => {
            if (bytes.len != 8) return error.Payload;
            return .{ .recovery_action = .{ .action_type = word(bytes, 0), .value = try boolean(bytes[4]) } };
        },
        .os_error, .libos_print, .lockdown, .nocat => {
            const common = try boot.decode(record);
            return switch (common) {
                .os_error => |v| .{ .os_error = v },
                .libos_print => |v| .{ .libos_print = .{ .engine = v.engine, .bytes = v.bytes } },
                .lockdown => |v| .{ .lockdown = v },
                .nocat => |v| .{ .nocat = v },
                else => unreachable,
            };
        },
    }
}
pub const Scope = struct { epoch: u64, deadline: u64, ticket: transport.Ticket };
pub const Sink = struct {
    context: *anyopaque,
    generation: *const fn (*anyopaque) u64,
    /// Pure capability/registration admission, including exact live RM
    /// client/event/index and notify-list semantics for POST_EVENT. A missing
    /// registration must not be treated as successful or broadcast by guess.
    admit: *const fn (*anyopaque, Scope, Event) error{ Denied, Unsupported }!void,
    /// One bounded local delivery, or copy into the actual owner's work queue.
    /// Never recurse into RPC polling/sending. Borrowed byte slices must not
    /// escape this callback; copy them if later work needs them. Log owners
    /// must escape controls and never use firmware text as a format string.
    deliver: *const fn (*anyopaque, Scope, Event) anyerror!void,
};
/// One serialized runtime owner. Do not copy a live dispatch or enter another
/// handler recursively; callbacks must not drive its Session/Exchange. The
/// event and all borrowed backing remain immutable until completion/failure.
pub const Dispatch = struct {
    owner: *exchange.Exchange,
    display_owner: ?*display_rpc.Channel = null,
    sink: Sink,
    scope: Scope,
    event: Event,
    attempted: bool = false,
    delivered: bool = false,
    acknowledged: bool = false,
    failed: bool = false,
    failure: ?anyerror = null,

    /// Only non-sequencer notifications. CPU-sequencer receipts stay with
    /// RuntimeSequencer and cannot be acknowledged by an ordinary event sink.
    pub fn init(owner: *exchange.Exchange, sink: Sink) Error!Dispatch {
        const pending = owner.pending orelse return error.State;
        if (pending.response) return error.State;
        if (pending.record.rpc.function == 0x1002) return error.SequencerRequired;
        errdefer owner.reject(pending.ticket) catch {};
        const receipt = try owner.borrow(pending.ticket);
        var self: Dispatch = .{ .owner = owner, .sink = sink, .scope = .{ .epoch = owner.session.epoch, .deadline = owner.deadline.?, .ticket = pending.ticket }, .event = try decode(receipt.record) };
        try self.guard();
        try sink.admit(sink.context, self.scope, self.event);
        try self.guard();
        return self;
    }
    /// Display queries cache their semantic dispatch as well as the shared
    /// receipt. Complete through that owner so ACK and cache release agree.
    pub fn initDisplay(owner: *display_rpc.Channel, sink: Sink) Error!Dispatch {
        const pending = owner.pending orelse return error.State;
        if ((try owner.borrow(pending.ticket)).value != .notification) return error.State;
        var result = try init(&owner.exchange, sink);
        result.display_owner = owner;
        return result;
    }
    fn guard(self: *Dispatch) Error!void {
        if (self.failed) return error.State;
        if (self.display_owner) |owner| {
            if (&owner.exchange != self.owner or (try owner.borrow(self.scope.ticket)).value != .notification) return error.State;
        }
        _ = try self.owner.borrow(self.scope.ticket);
        self.scope.deadline = @min(self.scope.deadline, self.owner.deadline.?);
        try self.owner.guard(self.scope.deadline);
        if (self.sink.generation(self.sink.context) != self.scope.epoch) return error.Stale;
    }
    /// Callback effects occur at most once. On any failure retain both the
    /// exact receipt and delivery state; a later step must not retry delivery
    /// merely because an ACK may not have become visible.
    pub fn step(self: *Dispatch) Error!void {
        if (self.failed) return error.State;
        if (self.acknowledged) return;
        errdefer |err| {
            self.failed = true;
            if (self.failure == null) self.failure = err;
            self.owner.reject(self.scope.ticket) catch {};
        }
        try self.guard();
        if (self.attempted) return error.State;
        self.attempted = true;
        self.sink.deliver(self.sink.context, self.scope, self.event) catch |err| {
            self.failure = err;
            return error.Handler;
        };
        self.delivered = true;
        try self.guard();
        if (self.display_owner) |owner| try owner.complete(self.scope.ticket) else try self.owner.complete(self.scope.ticket);
        self.acknowledged = true;
    }
};
